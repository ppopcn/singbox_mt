#!/usr/bin/env bash
#
# singbox_mt.sh - 在 Debian / Ubuntu 上一键部署 sing-box-extended MTPROXY 服务端
#
# 项目: https://github.com/shtorm-7/sing-box-extended
# 功能: 自动检测架构 -> 下载官方预编译二进制 -> 生成 ee(FakeTLS) secret
#       -> 写入配置 -> 注册 systemd -> 启动 -> 输出 t.me 代理链接
#
# 用法:
#   sudo bash singbox_mt.sh                 # 默认端口 443, 随机 secret
#   sudo PORT=8443 bash singbox_mt.sh       # 自定义端口
#   sudo DOMAIN=www.google.com bash singbox_mt.sh   # 自定义伪装域名
#   sudo bash singbox_mt.sh uninstall       # 卸载
#   sudo bash singbox_mt.sh info            # 查看当前配置与链接
#
# 环境变量:
#   PORT          监听端口            默认 443
#   DOMAIN        FakeTLS 伪装域名    默认从内置候选里随机选
#   SERVER_ADDR   强制指定对外 IP     默认自动探测
#   USER_NAME     MTPROXY 用户名      默认 user1
#   VERSION       sing-box 版本 tag   默认自动取最新
#   MIRROR        GitHub 加速前缀     默认空(会自动回退内置镜像)
#   CONCURRENCY   并发上限            默认 8192
#   AUTO_UPDATE   自动更新 Telegram DC 列表  默认 0(关闭, 启动更快、更稳)
#
set -euo pipefail

# ---------------------------------------------------------------- 常量定义 --
SERVICE_NAME="singbox-mt"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/mtproxy.json"
BIN_PATH="${INSTALL_DIR}/sing-box"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
REPO="shtorm-7/sing-box-extended"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

PORT="${PORT:-443}"
USER_NAME="${USER_NAME:-user1}"
CONCURRENCY="${CONCURRENCY:-8192}"
VERSION="${VERSION:-}"
MIRROR="${MIRROR:-}"
DOMAIN="${DOMAIN:-}"
SERVER_ADDR="${SERVER_ADDR:-}"
AUTO_UPDATE="${AUTO_UPDATE:-0}"

# 伪装域名候选: 需为可正常提供 TLS 1.3 且在国内可直连的大站
DEFAULT_DOMAINS=(
  "www.cloudflare.com"
  "www.microsoft.com"
  "www.bing.com"
  "www.apple.com"
  "www.amazon.com"
)

# ---------------------------------------------------------------- 输出美化 --
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_RST=''
fi

info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

# ---------------------------------------------------------------- 前置检查 --
check_root() {
  [[ ${EUID} -eq 0 ]] || die "请用 root 运行: sudo bash $0"
}

check_os() {
  [[ -r /etc/os-release ]] || warn "未检测到 /etc/os-release, 继续尝试"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      debian|ubuntu|linuxmint|pop|raspbian|armbian|kali)
        ok "系统: ${PRETTY_NAME:-$ID}" ;;
      *)
        warn "当前系统 ${PRETTY_NAME:-unknown} 非 Debian/Ubuntu 系, 仍尝试继续"
        ;;
    esac
  fi
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl, 无法使用 systemd 托管"
}

# 依赖: curl 或 wget 二选一, 其余按需安装
check_deps() {
  local missing=()
  command -v curl   >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing+=(curl)
  command -v tar    >/dev/null 2>&1 || missing+=(tar)
  command -v ss     >/dev/null 2>&1 || missing+=(iproute2)

  if ((${#missing[@]})); then
    info "安装依赖: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || die "apt-get update 失败"
    apt-get install -y -qq "${missing[@]}" >/dev/null || die "依赖安装失败"
  fi
  ok "依赖就绪"
}

# ---------------------------------------------------------------- 下载辅助 --
# 内置几个常用 GitHub 加速前缀, 直连失败时自动依次尝试
FALLBACK_MIRRORS=(
  "https://ghfast.top/https://github.com"
  "https://gh-proxy.com/https://github.com"
)

# 统一下载入口: 支持任意前缀镜像, curl/wget 双后端, 失败自动换镜像
fetch() {
  local url="$1" out="$2" full rc=1 candidates=() m

  # 组装候选地址: 用户指定的镜像优先, 然后直连, 最后内置镜像
  if [[ -n "$MIRROR" ]]; then
    candidates+=("${MIRROR%/}/${url}")
  fi
  candidates+=("$url")
  for m in "${FALLBACK_MIRRORS[@]}"; do
    # 仅对 github.com 链接套用加速前缀
    if [[ "$url" == https://github.com/* ]]; then
      candidates+=("${m}/${url#https://github.com/}")
    fi
  done

  for full in "${candidates[@]}"; do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL --retry 1 --connect-timeout 12 --max-time 300 -o "$out" "$full" 2>/dev/null; then
        rc=0; break
      fi
    else
      if wget -q --tries=1 --timeout=15 -O "$out" "$full" 2>/dev/null; then
        rc=0; break
      fi
    fi
    warn "下载失败, 尝试下一个源: ${full}"
  done

  return $rc
}

fetch_stdout() {
  local url="$1" out
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 "$url" 2>/dev/null)" && { printf '%s' "$out"; return 0; }
  else
    out="$(wget -qO- --tries=2 --timeout=20 "$url" 2>/dev/null)" && { printf '%s' "$out"; return 0; }
  fi
  return 1
}

# ------------------------------------------------------------ 架构/平台识别 --
# 把 uname 输出映射到发布包里的架构名
detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)   echo "amd64" ;;
    aarch64|arm64)  echo "arm64" ;;
    armv7l|armv7)   echo "armv7" ;;
    armv6l|armv6)   echo "armv6" ;;
    i386|i486|i586|i686) echo "386" ;;
    riscv64)        echo "riscv64" ;;
    loongarch64|loong64) echo "loong64" ;;
    s390x)          echo "s390x" ;;
    mips64)         echo "mips64" ;;
    mips64el)       echo "mips64le" ;;
    mipsel)         echo "mipsle" ;;
    mips)           echo "mips" ;;
    *) die "不支持的 CPU 架构: $machine" ;;
  esac
}

# ------------------------------------------------------------ 版本与文件名 --
# 从 GitHub API 解析指定架构 tarball 的下载地址、sha256 与版本号
# 输出: "<url>|<sha256>|<tag>"  (sha256 可能为空)
# 用 | 分隔而非空格, 避免空字段被 here-string 折叠
resolve_release() {
  local arch="$1" json tag ver asset result=""

  json="$(fetch_stdout "$API_URL")" || die "无法获取 Release 信息(网络受限?), 可尝试: MIRROR=https://ghfast.top/ sudo -E bash $0"
  [[ -n "$json" ]] || die "Release 接口返回空内容"

  # 优先用 python3 做结构化解析, 更可靠
  if command -v python3 >/dev/null 2>&1; then
    result="$(printf '%s' "$json" | python3 -c '
import json, sys
arch = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
tag = d.get("tag_name", "")
ver = tag[1:] if tag.startswith("v") else tag
want = "sing-box-%s-linux-%s.tar.gz" % (ver, arch)
for a in d.get("assets", []):
    if a.get("name") == want:
        digest = a.get("digest") or ""
        if digest.startswith("sha256:"):
            digest = digest[7:]
        else:
            digest = ""
        print("%s|%s|%s" % (a.get("browser_download_url", ""), digest, tag))
        break
else:
    print("|%s|%s" % ("", tag))
' "$arch" 2>/dev/null)" || result=""
  fi

  # 回退: 纯文本匹配(不依赖 python3)
  if [[ -z "$result" ]]; then
    tag="$(printf '%s\n' "$json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -e 's/.*"\([^"]*\)"$/\1/')"
    ver="${tag#v}"
    asset="sing-box-${ver}-linux-${arch}.tar.gz"
    local url
    url="$(printf '%s\n' "$json" | grep -o "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*${asset}\"" | head -n1 | sed -e 's/.*"\(https[^"]*\)"$/\1/')"
    result="${url}||${tag}"
  fi

  [[ "$result" == *"|"*"|"* ]] || die "解析 Release 信息失败"

  # 拆出 tag, 若 URL 为空则按命名规则构造
  tag="${result##*|}"
  [[ -n "$tag" ]] || die "解析 tag_name 失败"
  ver="${tag#v}"
  asset="sing-box-${ver}-linux-${arch}.tar.gz"
  url="${result%%|*}"

  if [[ -z "$url" ]]; then
    warn "Release 中未找到 ${asset}, 按命名规则构造下载地址"
    url="https://github.com/${REPO}/releases/download/${tag}/${asset}"
  fi

  local digest="${result#*|}"
  digest="${digest%|*}"

  printf '%s|%s|%s\n' "$url" "$digest" "$tag"
}

# ---------------------------------------------------------------- 安装二进制 --
install_binary() {
  local arch url digest tag tmpdir tarball

  arch="$(detect_arch)"
  ok "CPU 架构: ${arch}"

  info "解析最新版本..."
  local resolved
  resolved="$(resolve_release "$arch")"
  url="${resolved%%|*}"
  digest="${resolved#*|}"; digest="${digest%|*}"
  tag="${resolved##*|}"
  ok "版本: ${tag}"
  info "下载: ${url}"

  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  tarball="${tmpdir}/sb.tar.gz"

  fetch "$url" "$tarball" || die "下载失败。若为网络问题可加镜像重试: MIRROR=https://ghfast.top/ sudo -E bash $0"

  # 完整性校验(仅在 Release 提供 digest 时)
  if [[ -n "$digest" ]]; then
    local actual
    actual="$(sha256sum "$tarball" | awk '{print $1}')"
    if [[ "$actual" == "$digest" ]]; then
      ok "SHA256 校验通过"
    else
      die "SHA256 不匹配! 期望 ${digest}, 实际 ${actual}"
    fi
  else
    warn "Release 未提供 SHA256, 跳过校验"
  fi

  tar -xzf "$tarball" -C "$tmpdir" || die "解包失败"
  local extracted
  extracted="$(find "$tmpdir" -maxdepth 2 -type f -name 'sing-box' | head -n1)"
  [[ -n "$extracted" ]] || die "包内未找到 sing-box 可执行文件"

  install -m 0755 "$extracted" "$BIN_PATH" || die "写入 ${BIN_PATH} 失败"
  ok "已安装: ${BIN_PATH}"

  "$BIN_PATH" version | head -n1
}

# -------------------------------------------------------------- secret 生成 --
# mtg 的 secret 字节布局 (见 mtglib/secret.go Set/GenerateSecret):
#   [0xee][16 字节随机 key][hostname 明文 latin1]
#   整个字节串以 hex 序列化输出。
# 例: ee + 32 hex + "www.cloudflare.com" 的 hex
gen_secret() {
  local domain="$1" key_hex
  key_hex="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf 'ee%s' "$key_hex"
  printf '%s' "$domain" | od -An -tx1 | tr -d ' \n'
}

# ------------------------------------------------------------ 对外 IP 探测 --
detect_public_ip() {
  local ip=""
  local urls=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://ipinfo.io/ip"
    "https://4.ipw.cn"
  )
  for u in "${urls[@]}"; do
    ip="$(fetch_stdout "$u" 2>/dev/null | tr -d '[:space:]')" || continue
    # 简单校验: 允许 IPv4, 保持保守只接受 IPv4, 因为 Telegram 链接对 v6 支持差
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- 写配置文件 --
write_config() {
  local secret="$1" auto_update_json

  # JSON 布尔值必须是 true/false, 不能是 1/0
  if [[ "$AUTO_UPDATE" == "1" ]]; then
    auto_update_json="true"
  else
    auto_update_json="false"
  fi

  mkdir -p "$CONFIG_DIR"

  # 备份已有配置
  if [[ -f "$CONFIG_FILE" ]]; then
    local bak
    bak="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "$CONFIG_FILE" "$bak"
    warn "旧配置已备份: ${bak}"
  fi

  cat >"$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "default"
      }
    ]
  },
  "inbounds": [
    {
      "type": "mtproxy",
      "tag": "mtp-in",
      "listen": "::",
      "listen_port": ${PORT},      "users": [
        {
          "name": "${USER_NAME}",
          "secret": "${secret}"
        }
      ],
      "concurrency": ${CONCURRENCY},
      "domain_fronting_port": 443,
      "prefer_ip": "prefer-ipv4",
      "auto_update": ${auto_update_json},
      "allow_fallback_on_unknown_dc": false,
      "tolerate_time_skewness": "5m",
      "idle_timeout": "5m",
      "handshake_timeout": "10s",
      "doppelganger_urls": [],
      "doppelganger_per_raid": 10,
      "doppelganger_each": "6h",
      "throttle_max_connections": 0,
      "throttle_check_interval": "5s"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct",
    "default_domain_resolver": "default"
  }
}
EOF

  chmod 600 "$CONFIG_FILE"
  ok "配置已写入: ${CONFIG_FILE}"
}

# ---------------------------------------------------------------- 注册服务 --
write_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box MTPROXY Server (extended)
Documentation=https://github.com/${REPO}
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  ok "systemd 服务已注册: ${SERVICE_FILE}"
}

# ---------------------------------------------------------------- 防火墙放行 --
open_firewall() {
  # ufw
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 && ok "ufw 已放行 ${PORT}/tcp" || warn "ufw 放行失败"
  fi
  # firewalld
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld 已放行 ${PORT}/tcp"
  fi
  # iptables 不做自动改动, 避免破坏现有规则
}

# ------------------------------------------------------------ 连通性自检 --
# auto_update 开启时会拉取 Telegram DC 列表, 若出口网络被限制会拖慢启动
# 这里先探测一次, 不通则临时关闭自动更新, 保证服务能立刻起来
probe_upstream() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 8 bash -c 'exec 3<>/dev/tcp/core.telegram.org/443' 2>/dev/null
  else
    bash -c 'exec 3<>/dev/tcp/core.telegram.org/443' 2>/dev/null
  fi
}

# ---------------------------------------------------------------- 启动验证 --
start_service() {
  if [[ "$AUTO_UPDATE" == "1" ]]; then
    info "检测到 Telegram DC 更新源连通性..."
    if probe_upstream; then
      ok "上游可达, 保留 auto_update"
    else
      warn "无法连接 core.telegram.org, 本次自动关闭 auto_update (不影响代理功能)"
      sed -i 's/"auto_update": true/"auto_update": false/' "$CONFIG_FILE"
    fi
  fi

  info "启动服务..."
  systemctl restart "$SERVICE_NAME" || die "服务启动失败, 查看日志: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
  sleep 2

  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    die "服务未能保持运行"
  fi

  # 端口监听检查
  local listen_ok=0
  if command -v ss >/dev/null 2>&1; then
    for _ in 1 2 3 4 5; do
      if ss -lntp 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
        listen_ok=1; break
      fi
      sleep 1
    done
  else
    listen_ok=1
  fi
  ((listen_ok)) || { journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2; die "端口 ${PORT} 未监听"; }
  ok "服务运行中, 端口 ${PORT} 已监听"
}

# ---------------------------------------------------------------- 链接输出 --
build_link() {
  local server="$1" secret="$2"
  printf 'https://t.me/proxy?server=%s&port=%s&secret=%s' "$server" "$PORT" "$secret"
}

print_summary() {
  local server="$1" secret="$2" link
  link="$(build_link "$server" "$secret")"

  echo
  hr
  printf '%s  MTPROXY 部署完成%s\n' "$C_BLD$C_GRN" "$C_RST"
  hr
  printf '  服务器 IP   : %s\n' "$server"
  printf '  端口        : %s\n' "$PORT"
  printf '  用户        : %s\n' "$USER_NAME"
  printf '  Secret 模式 : ee (FakeTLS)\n'
  printf '  配置文件    : %s\n' "$CONFIG_FILE"
  printf '  二进制      : %s\n' "$BIN_PATH"
  printf '  服务名      : %s\n' "$SERVICE_NAME"
  echo
  printf '%s  Telegram 代理链接:%s\n' "$C_BLD" "$C_RST"
  printf '%s\n' "$link"
  echo
  printf '  丢浏览器打开或发给 Telegram 好友即可导入。\n'
  echo
  hr
  printf '  管理命令\n'
  hr
  printf '  %s status %s     查看状态\n' "systemctl" "$SERVICE_NAME"
  printf '  %s restart %s    重启\n'  "systemctl" "$SERVICE_NAME"
  printf '  %s stop %s       停止\n'  "systemctl" "$SERVICE_NAME"
  printf '  %s -u %s -f     实时日志\n' "journalctl" "$SERVICE_NAME"
  printf '  bash %s info      重新打印此信息\n' "$(basename "$0")"
  printf '  bash %s uninstall 卸载\n' "$(basename "$0")"
  echo
}

# ---------------------------------------------------------------- 信息查询 --
cmd_info() {
  [[ -f "$CONFIG_FILE" ]] || die "未找到配置 ${CONFIG_FILE}, 请先运行部署"
  local secret server
  secret="$(grep -m1 '"secret"' "$CONFIG_FILE" | sed -e 's/.*"secret"[[:space:]]*:[[:space:]]*"//' -e 's/".*//')"
  [[ -n "$secret" ]] || die "配置中未解析到 secret"

  if [[ -n "$SERVER_ADDR" ]]; then
    server="$SERVER_ADDR"
  else
    server="$(detect_public_ip)" || die "无法探测公网 IP, 请用 SERVER_ADDR=x.x.x.x 指定"
  fi
  print_summary "$server" "$secret"
}

# ------------------------------------------------------------------ 卸载 --
cmd_uninstall() {
  info "开始卸载..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null || true

  if [[ "${KEEP_CONFIG:-0}" == "1" ]]; then
    warn "保留配置: ${CONFIG_FILE}"
  else
    rm -f "$CONFIG_FILE"
    ok "已删除配置"
  fi
  rm -f "$BIN_PATH"
  ok "已删除二进制"
  echo
  ok "卸载完成。若不再需要, 可手动清理 ${CONFIG_DIR}"
}

# ------------------------------------------------------------------ 主流程 --
main() {
  local action="${1:-install}"

  check_root

  case "$action" in
    install)
      check_os
      check_deps

      [[ -n "$DOMAIN" ]] || DOMAIN="${DEFAULT_DOMAINS[RANDOM % ${#DEFAULT_DOMAINS[@]}]}"
      ok "FakeTLS 伪装域名: ${DOMAIN}"

      install_binary

      local secret server
      secret="$(gen_secret "$DOMAIN")"
      [[ ${#secret} -gt 34 ]] || die "secret 生成异常: ${secret}"
      ok "secret 已生成 (长度 ${#secret})"

      write_config "$secret"
      write_service
      open_firewall
      start_service

      if [[ -n "$SERVER_ADDR" ]]; then
        server="$SERVER_ADDR"
      else
        server="$(detect_public_ip)" || server=""
      fi
      if [[ -z "$server" ]]; then
        warn "自动探测公网 IP 失败, 请手动替换下面链接中的 <YOUR_IP>"
        server="<YOUR_IP>"
      fi

      print_summary "$server" "$secret"
      ;;

    info)
      cmd_info
      ;;

    uninstall|remove)
      cmd_uninstall
      ;;

    -h|--help|help)
      sed -n '2,30p' "$0" | sed -e 's/^# \{0,1\}//'
      ;;

    *)
      die "未知命令: ${action} (可用: install / info / uninstall)"
      ;;
  esac
}

main "$@"

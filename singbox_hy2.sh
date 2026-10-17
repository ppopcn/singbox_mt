#!/usr/bin/env bash
#
# singbox_hy2.sh - 在 Debian / Ubuntu 上一键部署 Hysteria2 服务端
#
# 特性: 自签 TLS 证书 + QUIC(UDP) + 可选 salamander 混淆, 输出 hysteria2:// 链接。
#       证书默认自签(客户端需 allowInsecure / 跳过证书校验), 也可用 CERT_FILE /
#       KEY_FILE 指向已有正规证书。
#
# 用法:
#   sudo bash singbox_hy2.sh                            # 默认 443/udp, 随机密码
#   sudo PORT=8443 PASSWORD=mypass bash singbox_hy2.sh
#   sudo DOMAIN=www.bing.com bash singbox_hy2.sh
#   sudo bash singbox_hy2.sh info                       # 重新打印密码与链接
#   sudo bash singbox_hy2.sh uninstall                  # 卸载
#
# 环境变量:
#   PORT         监听端口(UDP)      默认 443
#   PASSWORD     认证密码           默认随机 16 字节
#   DOMAIN       TLS 域名/SNI       默认从内置候选随机
#   OBFS         salamander 混淆密码 默认空(不启用)
#   CERT_FILE    TLS 证书路径       默认 /etc/sing-box/cert.pem(不存在则自签)
#   KEY_FILE     TLS 私钥路径       默认 /etc/sing-box/key.pem
#   SERVER_ADDR  对外 IP            默认自动探测
#   MIRROR       GitHub 加速前缀    默认空(内置镜像自动回退)
#
set -euo pipefail

# ---------------------------------------------------------------- 常量定义 --
SERVICE_NAME="singbox-hy2"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/hy2.json"
BIN_PATH="${INSTALL_DIR}/sing-box"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
REPO="shtorm-7/sing-box-extended"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

PORT="${PORT:-443}"
PASSWORD="${PASSWORD:-}"
DOMAIN="${DOMAIN:-}"
OBFS="${OBFS:-}"
SERVER_ADDR="${SERVER_ADDR:-}"
VERSION="${VERSION:-}"
MIRROR="${MIRROR:-}"
CERT_FILE="${CERT_FILE:-${CONFIG_DIR}/cert.pem}"
KEY_FILE="${KEY_FILE:-${CONFIG_DIR}/key.pem}"
LISTEN_PROTO="udp"

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
hr()    { printf '%s\n' "------------------------------------------------------------"; }

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
        warn "当前系统 ${PRETTY_NAME:-unknown} 非 Debian/Ubuntu 系, 仍尝试继续" ;;
    esac
  fi
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl, 无法使用 systemd 托管"
}

check_deps() {
  local missing=()
  command -v curl   >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing+=(curl)
  command -v tar    >/dev/null 2>&1 || missing+=(tar)
  command -v ss     >/dev/null 2>&1 || missing+=(iproute2)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)

  if ((${#missing[@]})); then
    info "安装依赖: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || die "apt-get update 失败"
    apt-get install -y -qq "${missing[@]}" >/dev/null || die "依赖安装失败"
  fi
  ok "依赖就绪"
}

# ---------------------------------------------------------------- 下载辅助 --
FALLBACK_MIRRORS=(
  "https://ghfast.top/https://github.com"
  "https://gh-proxy.com/https://github.com"
)

fetch() {
  local url="$1" out="$2" full rc=1 candidates=() m

  if [[ -n "$MIRROR" ]]; then
    candidates+=("${MIRROR%/}/${url}")
  fi
  candidates+=("$url")
  for m in "${FALLBACK_MIRRORS[@]}"; do
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
# 输出: "<url>|<sha256>|<tag>"
resolve_release() {
  local arch="$1" json tag ver asset result=""

  json="$(fetch_stdout "$API_URL")" || die "无法获取 Release 信息(网络受限?), 可尝试: MIRROR=https://ghfast.top/ sudo -E bash $0"
  [[ -n "$json" ]] || die "Release 接口返回空内容"

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
        digest = digest[7:] if digest.startswith("sha256:") else ""
        print("%s|%s|%s" % (a.get("browser_download_url", ""), digest, tag))
        break
else:
    print("|%s|%s" % ("", tag))
' "$arch" 2>/dev/null)" || result=""
  fi

  if [[ -z "$result" ]]; then
    tag="$(printf '%s\n' "$json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -e 's/.*"\([^"]*\)"$/\1/')"
    ver="${tag#v}"
    asset="sing-box-${ver}-linux-${arch}.tar.gz"
    local url
    url="$(printf '%s\n' "$json" | grep -o "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*${asset}\"" | head -n1 | sed -e 's/.*"\(https[^"]*\)"$/\1/')"
    result="${url}||${tag}"
  fi

  [[ "$result" == *"|"*"|"* ]] || die "解析 Release 信息失败"

  local url digest
  tag="${result##*|}"
  [[ -n "$tag" ]] || die "解析 tag_name 失败"
  ver="${tag#v}"
  asset="sing-box-${ver}-linux-${arch}.tar.gz"
  url="${result%%|*}"
  digest="${result#*|}"; digest="${digest%|*}"

  if [[ -z "$url" ]]; then
    warn "Release 中未找到 ${asset}, 按命名规则构造下载地址"
    url="https://github.com/${REPO}/releases/download/${tag}/${asset}"
  fi

  printf '%s|%s|%s\n' "$url" "$digest" "$tag"
}

# ---------------------------------------------------------------- 安装二进制 --
install_binary() {
  local arch url digest tag tmpdir tarball resolved

  arch="$(detect_arch)"
  ok "CPU 架构: ${arch}"

  info "解析最新版本..."
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

  if [[ -n "$digest" ]]; then
    local actual
    actual="$(sha256sum "$tarball" | awk '{print $1}')"
    [[ "$actual" == "$digest" ]] || die "SHA256 不匹配! 期望 ${digest}, 实际 ${actual}"
    ok "SHA256 校验通过"
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

# ---------------------------------------------------------------- 凭据生成 --
rand_token() {
  local bytes="${1:-16}"
  head -c "$bytes" /dev/urandom | base64 | tr -d '\r\n=' | tr '+/' '-_'
}

# ------------------------------------------------------------ 自签证书 --
ensure_cert() {
  local domain="$1"

  if [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
    ok "复用已有证书: ${CERT_FILE}"
    return 0
  fi

  info "生成自签证书 (CN=${domain}, 10 年有效期)..."
  mkdir -p "$(dirname "$CERT_FILE")" "$(dirname "$KEY_FILE")"
  if openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$KEY_FILE" -out "$CERT_FILE" \
      -subj "/CN=${domain}" \
      -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1; then
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    ok "证书已生成: ${CERT_FILE}"
  else
    # 老版本 openssl 不支持 -addext
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${domain}" >/dev/null 2>&1 \
      || die "自签证书生成失败"
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    ok "证书已生成(无 SAN): ${CERT_FILE}"
  fi
}

# ------------------------------------------------------------ 对外 IP 探测 --
detect_public_ip() {
  local ip="" u
  local urls=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://ipinfo.io/ip"
    "https://4.ipw.cn"
  )
  for u in "${urls[@]}"; do
    ip="$(fetch_stdout "$u" 2>/dev/null | tr -d '[:space:]')" || continue
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$ip"; return 0
    fi
  done
  return 1
}

# -------------------------------------------------------------- JSON 读取 --
json_get() {
  local file="$1" key="$2" val=""
  if command -v python3 >/dev/null 2>&1; then
    val="$(python3 - "$file" "$key" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
key = sys.argv[2]
out = []
def walk(o):
    if isinstance(o, dict):
        if key in o:
            out.append(str(o[key]))
            raise SystemExit
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
try:
    walk(d)
except SystemExit:
    pass
if out:
    print(out[0])
PY
)" || val=""
  fi
  val="${val//$'\r'/}"
  if [[ -z "$val" ]]; then
    val="$(grep -m1 "\"${key}\"" "$file" 2>/dev/null | sed -e 's/.*:[[:space:]]*"//' -e 's/".*//')"
  fi
  [[ -n "$val" ]] && printf '%s' "$val"
  return 0
}

# ---------------------------------------------------------------- 写配置文件 --
write_config() {
  local obfs_block=""
  if [[ -n "$OBFS" ]]; then
    obfs_block="      \"obfs\": {
        \"type\": \"salamander\",
        \"password\": \"${OBFS}\"
      },
"
  fi

  mkdir -p "$CONFIG_DIR"

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
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "password": "${PASSWORD}"
        }
      ],
      "ignore_client_bandwidth": true,
      "masquerade": "https://${DOMAIN}",
${obfs_block}      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": [
          "h3"
        ],
        "min_version": "1.3",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
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

  "$BIN_PATH" check -c "$CONFIG_FILE" >/dev/null 2>&1 \
    && ok "配置校验通过" \
    || { "$BIN_PATH" check -c "$CONFIG_FILE"; die "配置校验失败"; }
}

# ---------------------------------------------------------------- 注册服务 --
write_service() {
  local desc="$1"
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=${desc}
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

# ---------------------------------------------------------------- 端口检查 --
port_busy() {
  local port="$1" proto="$2" flag="-lnt"
  [[ "$proto" == "udp" ]] && flag="-lnu"
  command -v ss >/dev/null 2>&1 || return 1
  ss "$flag" 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${port}\$"
}

# ---------------------------------------------------------------- 防火墙放行 --
open_firewall() {
  local proto="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${PORT}/${proto}" >/dev/null 2>&1 && ok "ufw 已放行 ${PORT}/${proto}" || warn "ufw 放行失败"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PORT}/${proto}" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld 已放行 ${PORT}/${proto}"
  fi
}

# ---------------------------------------------------------------- 启动验证 --
start_service() {
  info "启动服务..."
  systemctl restart "$SERVICE_NAME" || true
  sleep 2

  if ! systemctl is-active --quiet "$SERVICE_NAME" && grep -q '"listen": "::"' "$CONFIG_FILE"; then
    warn "启动失败, 尝试改用 IPv4 监听..."
    sed -i 's/"listen": "::"/"listen": "0.0.0.0"/' "$CONFIG_FILE"
    systemctl restart "$SERVICE_NAME" || true
    sleep 2
  fi

  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    die "服务未能保持运行"
  fi

  local flag="-lnt"
  [[ "$LISTEN_PROTO" == "udp" ]] && flag="-lnu"
  local listen_ok=0
  if command -v ss >/dev/null 2>&1; then
    for _ in 1 2 3 4 5; do
      if ss "$flag" 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${PORT}\$"; then
        listen_ok=1; break
      fi
      sleep 1
    done
  else
    listen_ok=1
  fi
  ((listen_ok)) || { journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2; die "端口 ${PORT}/${LISTEN_PROTO} 未监听"; }
  ok "服务运行中, ${PORT}/${LISTEN_PROTO} 已监听"
}

# ---------------------------------------------------------------- 链接输出 --
print_summary() {
  local server="$1" link obfs_q=""
  link="hysteria2://${PASSWORD}@${server}:${PORT}/?sni=${DOMAIN}&insecure=1"
  if [[ -n "$OBFS" ]]; then
    link="${link}&obfs=salamander&obfs-password=${OBFS}"
    obfs_q="salamander"
  fi
  link="${link}#hy2-${PORT}"

  echo
  hr
  printf '%s  Hysteria2 部署完成%s\n' "$C_BLD$C_GRN" "$C_RST"
  hr
  printf '  服务器 IP   : %s\n' "$server"
  printf '  端口        : %s/udp\n' "$PORT"
  printf '  密码        : %s\n' "$PASSWORD"
  printf '  SNI / 域名  : %s\n' "$DOMAIN"
  printf '  混淆        : %s\n' "${obfs_q:-关闭}"
  printf '  证书        : %s (自签, 客户端需跳过校验)\n' "$CERT_FILE"
  printf '  配置文件    : %s\n' "$CONFIG_FILE"
  printf '  二进制      : %s\n' "$BIN_PATH"
  printf '  服务名      : %s\n' "$SERVICE_NAME"
  echo
  printf '%s  hysteria2:// 链接%s\n' "$C_BLD" "$C_RST"
  printf '%s\n' "$link"
  echo
  printf '  UDP 端口需在云厂商安全组放行; 客户端允许不安全证书才能用自签证书。\n'
  echo
  hr
  printf '  管理命令\n'
  hr
  printf '  systemctl status %s    查看状态\n' "$SERVICE_NAME"
  printf '  systemctl restart %s   重启\n' "$SERVICE_NAME"
  printf '  journalctl -u %s -f    实时日志\n' "$SERVICE_NAME"
  printf '  bash %s info           重新打印此信息\n' "$(basename "$0")"
  printf '  bash %s uninstall      卸载\n' "$(basename "$0")"
  echo
}

# ---------------------------------------------------------------- 信息查询 --
cmd_info() {
  [[ -f "$CONFIG_FILE" ]] || die "未找到配置 ${CONFIG_FILE}, 请先运行部署"
  PASSWORD="$(json_get "$CONFIG_FILE" password)"
  PORT="$(json_get "$CONFIG_FILE" listen_port)"
  DOMAIN="$(json_get "$CONFIG_FILE" server_name)"
  [[ -n "$PASSWORD" ]] || die "配置中未解析到 password"

  local server
  if [[ -n "$SERVER_ADDR" ]]; then
    server="$SERVER_ADDR"
  else
    server="$(detect_public_ip)" || die "无法探测公网 IP, 请用 SERVER_ADDR=x.x.x.x 指定"
  fi
  print_summary "$server"
}

# ------------------------------------------------------------------ 卸载 --
cmd_uninstall() {
  info "开始卸载 ${SERVICE_NAME}..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null || true

  if [[ "${KEEP_CONFIG:-0}" == "1" ]]; then
    warn "保留配置与证书: ${CONFIG_FILE}"
  else
    rm -f "$CONFIG_FILE"
    ok "已删除配置"
    if [[ -f "$CERT_FILE" ]]; then
      warn "证书保留: ${CERT_FILE} (供其他 TLS 服务复用, 不需要可手动删除)"
    fi
  fi

  local others
  others="$(find /etc/systemd/system -maxdepth 1 -name 'singbox-*.service' 2>/dev/null || true)"
  if [[ -z "$others" ]]; then
    rm -f "$BIN_PATH"
    ok "已删除二进制"
  else
    warn "检测到其他 sing-box 服务, 保留 ${BIN_PATH}"
  fi
  echo
  ok "卸载完成。若不再需要, 可手动清理 ${CONFIG_DIR}"
}

# ------------------------------------------------------------------ 帮助 --
usage() {
  cat <<'USAGE'
singbox_hy2.sh - 一键部署 Hysteria2 服务端 (sing-box-extended)

用法:
  sudo bash singbox_hy2.sh                     # 安装 (默认 443/udp)
  sudo bash singbox_hy2.sh info                # 查看配置与链接
  sudo bash singbox_hy2.sh uninstall           # 卸载
  sudo bash singbox_hy2.sh help                # 本帮助

常用自定义 (环境变量):
  PORT=8443                                  # 监听端口 (UDP)
  PASSWORD=xxx                               # 认证密码
  DOMAIN=www.bing.com                        # TLS 域名 / SNI
  OBFS=xxx                                   # 开启 salamander 混淆
  CERT_FILE=... KEY_FILE=...                 # 使用已有证书
  SERVER_ADDR=1.2.3.4                        # 指定对外 IP
  MIRROR=https://ghfast.top/https://github.com

管理:
  systemctl status|restart|stop singbox-hy2
  journalctl -u singbox-hy2 -f
USAGE
}

# ------------------------------------------------------------------ 主流程 --
main() {
  local action="${1:-install}"

  case "$action" in
    -h|--help|help)
      usage; return 0 ;;
  esac

  check_root

  case "$action" in
    install)
      check_os
      check_deps

      if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "检测到 ${SERVICE_NAME} 正在运行, 先停止..."
        systemctl stop "$SERVICE_NAME" || true
      fi

      port_busy "$PORT" udp && die "端口 ${PORT}/udp 已被其他程序占用, 请换端口: PORT=xxxx"

      [[ -n "$DOMAIN" ]] || DOMAIN="${DEFAULT_DOMAINS[RANDOM % ${#DEFAULT_DOMAINS[@]}]}"
      ok "TLS 域名/SNI: ${DOMAIN}"

      install_binary
      ensure_cert "$DOMAIN"

      [[ -n "$PASSWORD" ]] || PASSWORD="$(rand_token 16)"
      ok "密码已生成: ${PASSWORD}"
      [[ -z "$OBFS" ]] || ok "已启用 salamander 混淆"

      write_config
      write_service "sing-box Hysteria2 Server"
      open_firewall udp
      start_service

      local server
      if [[ -n "$SERVER_ADDR" ]]; then
        server="$SERVER_ADDR"
      else
        server="$(detect_public_ip)" || server=""
      fi
      if [[ -z "$server" ]]; then
        warn "自动探测公网 IP 失败, 请手动替换链接中的 <YOUR_IP>"
        server="<YOUR_IP>"
      fi

      print_summary "$server"
      ;;

    info)      cmd_info ;;
    uninstall|remove) cmd_uninstall ;;
    *) die "未知命令: ${action} (可用: install / info / uninstall / help)" ;;
  esac
}

main "$@"

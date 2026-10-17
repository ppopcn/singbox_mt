#!/usr/bin/env bash
#
# singbox_tuic.sh - 在 Debian / Ubuntu / Alpine 上一键部署 TUIC v5 服务端
#
# 特性: QUIC(UDP) + BBR 拥塞控制 + 自签 TLS 证书, 输出 tuic:// 链接。
#
# 用法:
#   sudo bash singbox_tuic.sh                           # 默认 443/udp, 随机 UUID/密码
#   sudo PORT=8443 bash singbox_tuic.sh
#   sudo UUID=xxxx PASSWORD=yours bash singbox_tuic.sh
#   sudo bash singbox_tuic.sh info                      # 重新打印凭据与链接
#   sudo bash singbox_tuic.sh uninstall                 # 卸载
#
# 环境变量:
#   PORT         监听端口            默认 443 (udp)
#   UUID         用户 UUID           默认随机
#   PASSWORD     认证密码            默认随机
#   DOMAIN       TLS 域名 / SNI      默认从内置候选随机
#   CONGESTION   拥塞控制            默认 bbr (bbr / cubic / new_reno)
#   CERT_FILE    TLS 证书路径        默认 /etc/sing-box/cert.pem(不存在则自签)
#   KEY_FILE     TLS 私钥路径        默认 /etc/sing-box/key.pem
#   SERVER_ADDR  对外 IP             默认自动探测
#   MIRROR       GitHub 加速前缀     默认空(自动回退内置镜像)
#   SINGBOX_TAG  sing-box 版本 tag   默认锁定的 v1.14.1-extended-2.7.2
#
set -euo pipefail

# ---------------------------------------------------------------- 元信息 ----
SERVICE_NAME="singbox-tuic"
SERVICE_DESC="sing-box TUIC v5 Server (extended)"
SHORT_NAME="tuic"
PROC_LABEL="TUIC v5"
CONFIG_FILE="/etc/sing-box/tuic.json"
RAW_FILE="singbox_tuic.sh"

NEED_CERT=1
NEED_DOMAIN=1
PORT_SPECS=("PORT:udp")

PORT="${PORT:-443}"
UUID="${UUID:-}"
PASSWORD="${PASSWORD:-}"
CONGESTION="${CONGESTION:-bbr}"
DOMAIN="${DOMAIN:-}"

# ================================================================ 公共层 ====
# 本文件是 build.sh 拼接进各协议脚本的公共骨架, 不单独执行, 也不带 shebang。
#
# 调用方(协议段)必须先定义:
#   SERVICE_NAME   systemd / OpenRC 单元名, 如 singbox-tuic
#   SERVICE_DESC   单元描述
#   SHORT_NAME     协议短名, 用于本地命令 singbox-<short>
#   PROC_LABEL     展示名, 如 "TUIC v5"
#   CONFIG_FILE    配置路径
#   PORT_SPECS=("PORT:tcp" "VMESS_PORT:tcp")   变量名:协议(逗号分隔可多协议)
#   NEED_CERT      1 = 需要 TLS 证书(自签或复用)
#   NEED_DOMAIN    1 = 需要伪装域名 / SNI(为空时从候选随机)
#
# 协议段必须提供:
#   render_config         把 JSON 输出到 stdout(不带备份/chmod/校验)
#   prepare_secrets       生成或复用凭据到全局变量
#   load_credentials      从 CONFIG_FILE 反读凭据到全局变量(info 用)
#   print_summary <ip>    打印凭据与客户端链接
#   usage                 帮助文本
# 可选:
#   port_validate_hook    端口交叉校验(如两端口不能相同)
#   pre_start_hook        启动前动作(如探测上游)
# ============================================================================

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
BIN_PATH="${INSTALL_DIR}/sing-box"
REPO="shtorm-7/sing-box-extended"

# TLS 协议共用一套证书; 想用正规证书覆盖这两个变量即可
CERT_FILE="${CERT_FILE:-${CONFIG_DIR}/cert.pem}"
KEY_FILE="${KEY_FILE:-${CONFIG_DIR}/key.pem}"

# 版本固定: 上游更新可能改动入站字段, 导致本项目配置失效, 因此锁版本。
# 需要试新版时: SINGBOX_TAG=v1.15.0-extended-2.8.0 bash singbox_xxx.sh
SINGBOX_TAG="${SINGBOX_TAG:-v1.14.1-extended-2.7.2}"
SINGBOX_API="https://api.github.com/repos/${REPO}/releases"

MIRROR="${MIRROR:-}"
SERVER_ADDR="${SERVER_ADDR:-}"
LOG_LEVEL="${LOG_LEVEL:-warn}"
FORCE_BIN="${FORCE_BIN:-0}"
KEEP_CONFIG="${KEEP_CONFIG:-0}"

RAW_URL="https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/${RAW_FILE}"

DEFAULT_DOMAINS=(
  "www.cloudflare.com"
  "www.microsoft.com"
  "www.bing.com"
  "www.apple.com"
  "www.amazon.com"
)

FALLBACK_MIRRORS=(
  "https://ghfast.top/https://github.com"
  "https://gh-proxy.com/https://github.com"
)

# 由 detect_platform 填充
OS_FAMILY=""
INIT_SYSTEM=""
SERVICE_FILE=""

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
notify() { printf '\n%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }

# ---------------------------------------------------------------- 前置检查 --
check_root() {
  [[ ${EUID} -eq 0 ]] || die "请用 root 运行: sudo bash $0"
}

# 识别发行版族与 init 系统, 后续平台相关操作都据此分流
detect_platform() {
  local id="" id_like="" pretty=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    id_like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-}")"
  fi

  case "$id" in
    alpine)
      OS_FAMILY="alpine" ;;
    debian|ubuntu|linuxmint|pop|raspbian|armbian|kali|devuan|neon|elementary)
      OS_FAMILY="debian" ;;
    *)
      if [[ "$id_like" == *alpine* ]]; then
        OS_FAMILY="alpine"
      elif [[ "$id_like" == *debian* || "$id_like" == *ubuntu* ]]; then
        OS_FAMILY="debian"
      else
        OS_FAMILY="unknown"
      fi
      ;;
  esac

  case "$OS_FAMILY" in
    alpine)
      INIT_SYSTEM="openrc"
      SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
      ok "系统: ${pretty:-Alpine Linux} (Alpine 系 / OpenRC)"
      ;;
    debian)
      INIT_SYSTEM="systemd"
      SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
      ok "系统: ${pretty:-Debian} (Debian 系 / systemd)"
      ;;
    *)
      if command -v apk >/dev/null 2>&1; then
        OS_FAMILY="alpine"; INIT_SYSTEM="openrc"
        SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
        warn "系统 ${pretty:-unknown} 未识别, 检测到 apk, 按 Alpine/OpenRC 处理"
      elif command -v apt-get >/dev/null 2>&1; then
        OS_FAMILY="debian"; INIT_SYSTEM="systemd"
        SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
        warn "系统 ${pretty:-unknown} 未识别, 检测到 apt-get, 按 Debian/systemd 处理"
      else
        die "无法识别的系统 (${pretty:-unknown}), 仅支持 Debian 系与 Alpine"
      fi
      ;;
  esac

  case "$INIT_SYSTEM" in
    systemd)
      command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl, 无法用 systemd 托管服务"
      ;;
    openrc)
      command -v rc-service >/dev/null 2>&1 || {
        warn "未检测到 OpenRC, 尝试安装"
        apk add --no-cache openrc >/dev/null 2>&1 || die "OpenRC 安装失败"
      }
      command -v rc-update >/dev/null 2>&1 || die "未找到 rc-update, OpenRC 不可用"
      ;;
  esac
}

# 兼容旧入口名
check_os() { detect_platform; }

check_deps() {
  local pkgs=() need_curl=0
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || need_curl=1
  command -v tar  >/dev/null 2>&1 || pkgs+=(tar)
  command -v ss   >/dev/null 2>&1 || pkgs+=(iproute2)
  ((NEED_CERT)) && { command -v openssl >/dev/null 2>&1 || pkgs+=(openssl); }

  if ((need_curl)); then
    pkgs+=(curl)
  fi
  if [[ "$OS_FAMILY" == "alpine" ]] && ! command -v curl >/dev/null 2>&1; then
    pkgs+=(curl)
  fi

  if ((${#pkgs[@]})); then
    local uniq
    uniq="$(printf '%s\n' "${pkgs[@]}" | awk '!seen[$0]++')"
    info "安装依赖: $(printf '%s' "$uniq" | tr '\n' ' ')"
    case "$OS_FAMILY" in
      alpine)
        # shellcheck disable=SC2086
        apk add --no-cache $uniq >/dev/null 2>&1 || die "apk add 失败"
        ;;
      debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || die "apt-get update 失败"
        # shellcheck disable=SC2086
        apt-get install -y -qq $uniq >/dev/null || die "依赖安装失败"
        ;;
      *)
        die "未知发行版, 无法自动安装依赖: ${pkgs[*]}"
        ;;
    esac
  fi
  ok "依赖就绪"
}

# ---------------------------------------------------------------- 下载辅助 --
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
    out="$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 "$url" 2>/dev/null)" \
      && { printf '%s' "$out"; return 0; }
  else
    out="$(wget -qO- --tries=2 --timeout=20 "$url" 2>/dev/null)" \
      && { printf '%s' "$out"; return 0; }
  fi
  return 1
}

# ------------------------------------------------------------ 架构/平台识别 --
detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)        echo "amd64" ;;
    aarch64|arm64)       echo "arm64" ;;
    armv7l|armv7)        echo "armv7" ;;
    armv6l|armv6)        echo "armv6" ;;
    i386|i486|i586|i686) echo "386" ;;
    riscv64)             echo "riscv64" ;;
    loongarch64|loong64) echo "loong64" ;;
    s390x)               echo "s390x" ;;
    mips64)              echo "mips64" ;;
    mips64el)            echo "mips64le" ;;
    mipsel)              echo "mipsle" ;;
    mips)                echo "mips" ;;
    *) die "不支持的 CPU 架构: $machine" ;;
  esac
}

# ------------------------------------------------------------ 版本与文件名 --
# 输出: "<url>|<sha256>|<tag>"  sha256 可能为空(接口不可用时降级)
#
# 该 release 里个别架构只提供 glibc / musl 变体(如 loong64), 所以按发行版顺序
# 依次尝试候选资产名, 取第一个真实存在的; 接口不可用时退回默认命名。
resolve_release() {
  local arch="$1" tag="$SINGBOX_TAG" ver base name url digest="" json

  if [[ "$tag" == "latest" ]]; then
    json="$(fetch_stdout "${SINGBOX_API}/latest")" || json=""
    tag="$(printf '%s' "$json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -n1 | sed -e 's/.*"\([^"]*\)"$/\1/')"
    [[ -n "$tag" ]] || die "无法解析最新版本(网络受限?), 可用 SINGBOX_TAG=v... 指定"
  fi

  ver="${tag#v}"
  base="sing-box-${ver}-linux-${arch}"

  local candidates=("${base}.tar.gz" "${base}-glibc.tar.gz" "${base}-musl.tar.gz")
  if [[ "$OS_FAMILY" == "alpine" ]]; then
    candidates=("${base}-musl.tar.gz" "${base}.tar.gz" "${base}-glibc.tar.gz")
  fi

  json="$(fetch_stdout "${SINGBOX_API}/tags/${tag}" 2>/dev/null)" || json=""
  name=""
  if [[ -n "$json" ]]; then
    local picked
    picked="$(printf '%s' "$json" | python3 -c '
import json, sys
want = sys.argv[1:]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
assets = {a.get("name"): (a.get("digest") or "") for a in d.get("assets", [])}
for n in want:
    if n in assets:
        dg = assets[n]
        print("%s|%s" % (n, dg[7:] if dg.startswith("sha256:") else ""))
        break
' "${candidates[@]}" 2>/dev/null)" || picked=""
    if [[ -n "$picked" ]]; then
      name="${picked%%|*}"
      digest="${picked#*|}"
    fi
  fi

  if [[ -z "$name" ]]; then
    name="${base}.tar.gz"
    if [[ -n "$json" ]]; then
      die "版本 ${tag} 没有适配 ${arch} 的发布包 (试过 ${candidates[*]})"
    fi
    warn "接口不可用, 按命名规则构造下载地址"
  fi

  url="https://github.com/${REPO}/releases/download/${tag}/${name}"
  printf '%s|%s|%s\n' "$url" "$digest" "$tag"
}

# ---------------------------------------------------------------- 安装二进制 --
# 已装同版本则直接复用, 避免每个协议都重新下载一次 20MB
install_binary() {
  local arch url digest tag tmpdir tarball resolved extracted cur

  arch="$(detect_arch)"
  ok "CPU 架构: ${arch}"

  # 版本已锁定且本地就是该版本: 直接复用, 完全不碰网络
  if [[ "$SINGBOX_TAG" != "latest" && "$FORCE_BIN" != "1" && -x "$BIN_PATH" ]]; then
    cur="$("$BIN_PATH" version 2>/dev/null | head -n1)"
    if [[ "$cur" == *"${SINGBOX_TAG#v}"* ]]; then
      ok "已安装 ${cur}, 跳过下载"
      return 0
    fi
  fi

  info "解析版本..."
  resolved="$(resolve_release "$arch")"
  url="${resolved%%|*}"
  digest="${resolved#*|}"; digest="${digest%|*}"
  tag="${resolved##*|}"
  ok "版本: ${tag}"

  if [[ -x "$BIN_PATH" ]]; then
    cur="$("$BIN_PATH" version 2>/dev/null | head -n1)"
    if [[ "$cur" == *"${tag#v}"* ]]; then
      if [[ "$FORCE_BIN" != "1" ]]; then
        ok "已安装同版本 (${cur}), 跳过下载"
        return 0
      fi
      warn "FORCE_BIN=1, 强制重新下载"
    else
      warn "现有二进制版本不符: ${cur:-未知}"
      local active
      active="$(list_other_services)"
      [[ -z "$active" ]] || warn "以下服务仍在使用旧二进制, 升级后需重启: $(echo $active)"
    fi
  fi

  info "下载: ${url}"
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  tarball="${tmpdir}/sb.tar.gz"

  fetch "$url" "$tarball" \
    || die "下载失败。若为网络问题可加镜像重试: MIRROR=https://ghfast.top/ sudo -E bash $0"

  if [[ -n "$digest" ]]; then
    local actual
    actual="$(sha256sum "$tarball" | awk '{print $1}')"
    [[ "$actual" == "$digest" ]] || die "SHA256 不匹配! 期望 ${digest}, 实际 ${actual}"
    ok "SHA256 校验通过"
  else
    warn "接口未返回 SHA256, 跳过校验 (版本 ${tag})"
  fi

  tar -xzf "$tarball" -C "$tmpdir" || die "解包失败"
  extracted="$(find "$tmpdir" -maxdepth 2 -type f -name 'sing-box' | head -n1)"
  [[ -n "$extracted" ]] || die "包内未找到 sing-box 可执行文件"

  # 先落到同目录临时文件再 mv, 避免升级中途崩溃留下半个二进制
  install -m 0755 "$extracted" "${BIN_PATH}.new" || die "写入 ${BIN_PATH} 失败"
  mv -f "${BIN_PATH}.new" "$BIN_PATH"
  ok "已安装: ${BIN_PATH}"
  "$BIN_PATH" version | head -n1
}

# 列出除自身外仍活跃的 sing-box 服务(升级二进制时提示用)
list_other_services() {
  local out=""
  case "$INIT_SYSTEM" in
    systemd)
      out="$(systemctl list-units --type=service --state=active --no-legend 'singbox-*' 2>/dev/null \
        | awk '{print $1}' | grep -v "^${SERVICE_NAME}.service$" || true)"
      ;;
    openrc)
      local f
      for f in /etc/init.d/singbox-*; do
        [[ -e "$f" ]] || continue
        local n; n="$(basename "$f")"
        [[ "$n" == "$SERVICE_NAME" ]] && continue
        rc-service "$n" status 2>/dev/null | grep -q "status: started" && out+="${n} "
      done
      ;;
  esac
  printf '%s' "$out"
}

# ---------------------------------------------------------------- 凭据生成 --
gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\n' </proc/sys/kernel/random/uuid
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid;print(uuid.uuid4())'
  else
    printf '%04x%04x-%04x-4%03x-%04x-%04x%04x%04x' \
      $RANDOM $RANDOM $RANDOM $((RANDOM % 4096)) $((RANDOM % 16384 + 32768)) \
      $RANDOM $RANDOM $RANDOM
  fi
}

rand_token() {
  local bytes="${1:-16}"
  head -c "$bytes" /dev/urandom | base64 | tr -d '\r\n=' | tr '+/' '-_'
}

# ---------------------------------------------------------------- 证书 ------
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
    chmod 600 "$KEY_FILE"; chmod 644 "$CERT_FILE"
    ok "证书已生成: ${CERT_FILE}"
  else
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${domain}" >/dev/null 2>&1 \
      || die "自签证书生成失败"
    chmod 600 "$KEY_FILE"; chmod 644 "$CERT_FILE"
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

# 生成链接时使用的地址: 优先 SERVER_ADDR, 其次自动探测, 失败占位
public_addr() {
  local ip
  if [[ -n "$SERVER_ADDR" ]]; then
    printf '%s' "$SERVER_ADDR"; return 0
  fi
  if ip="$(detect_public_ip)"; then
    printf '%s' "$ip"; return 0
  fi
  warn "自动探测公网 IP 失败, 链接里用 <YOUR_IP> 占位"
  printf '%s' "<YOUR_IP>"
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

# 取某个 key 的全部值(按出现顺序), 用于多入站的 uuid / 端口
json_get_all() {
  local file="$1" key="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PY' 2>/dev/null && return 0
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
key = sys.argv[2]
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == key:
                print(v)
            else:
                walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(d)
PY
  fi
  grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
    | sed -e 's/.*"\([^"]*\)"$/\1/'
  grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]\+" "$file" 2>/dev/null \
    | sed -e 's/.*:[[:space:]]*//'
}

# ---------------------------------------------------------------- 写配置 ----
# 备份 -> 渲染 -> 600 -> 校验; render_config 由协议段提供
write_config() {
  mkdir -p "$CONFIG_DIR"

  local bak=""
  if [[ -f "$CONFIG_FILE" ]]; then
    bak="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "$CONFIG_FILE" "$bak"
    warn "旧配置已备份: ${bak}"
  fi

  render_config >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  ok "配置已写入: ${CONFIG_FILE}"

  if "$BIN_PATH" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    ok "配置校验通过"
  else
    "$BIN_PATH" check -c "$CONFIG_FILE" || true
    if [[ -n "$bak" ]]; then
      cp -f "$bak" "$CONFIG_FILE"
      warn "已回滚到备份配置: ${bak}"
    fi
    die "配置校验失败"
  fi
}

# ---------------------------------------------------------------- 注册服务 --
write_service() {
  case "$INIT_SYSTEM" in
    systemd) write_service_systemd ;;
    openrc)  write_service_openrc ;;
  esac
}

write_service_systemd() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=${SERVICE_DESC}
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
KillSignal=SIGTERM
TimeoutStopSec=15
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

write_service_openrc() {
  mkdir -p /etc/init.d

  cat >"$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="${SERVICE_DESC}"

command="${BIN_PATH}"
command_args="run -c ${CONFIG_FILE}"
command_background="yes"
command_user="root"
pidfile="/run/\${RC_SVCNAME}.pid"

output_log="/var/log/\${RC_SVCNAME}.log"
error_log="/var/log/\${RC_SVCNAME}.log"

start_pre() {
    checkpath --directory --mode 0755 /var/log
}

stop() {
    local pf="\${pidfile}"
    ebegin "Stopping \${RC_SVCNAME}"
    if [ -f "\${pf}" ]; then
        local pid
        pid="\$(cat "\${pf}" 2>/dev/null)"
        if [ -n "\${pid}" ] && kill -0 "\${pid}" 2>/dev/null; then
            kill -TERM "\${pid}" 2>/dev/null
            local i=0
            while [ \$i -lt 10 ] && kill -0 "\${pid}" 2>/dev/null; do
                sleep 1
                i=\$((i + 1))
            done
            if kill -0 "\${pid}" 2>/dev/null; then
                ewend 1 "force killing \${RC_SVCNAME} (pid \${pid})"
                kill -KILL "\${pid}" 2>/dev/null
                sleep 1
            fi
        fi
        rm -f "\${pf}"
    fi
    eend 0
}

depend() {
    need net
    after firewall
}
EOF

  chmod 0755 "$SERVICE_FILE"
  rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 \
    || warn "rc-update add 失败, 开机自启可能未生效"
  ok "OpenRC 服务已注册: ${SERVICE_FILE}"
}

service_restart() {
  case "$INIT_SYSTEM" in
    systemd) systemctl restart "$SERVICE_NAME" ;;
    openrc)  rc-service "$SERVICE_NAME" restart 2>/dev/null \
      || rc-service "$SERVICE_NAME" start ;;
  esac
}

service_stop() {
  case "$INIT_SYSTEM" in
    systemd) systemctl stop "$SERVICE_NAME" 2>/dev/null || true ;;
    openrc)  rc-service "$SERVICE_NAME" stop 2>/dev/null || true ;;
  esac
}

service_is_active() {
  case "$INIT_SYSTEM" in
    systemd) systemctl is-active --quiet "$SERVICE_NAME" ;;
    openrc)  rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "status: started" ;;
  esac
}

service_logs() {
  local n="${1:-30}"
  case "$INIT_SYSTEM" in
    systemd) journalctl -u "$SERVICE_NAME" -n "$n" --no-pager 2>/dev/null || true ;;
    openrc)
      if [[ -f "/var/log/${SERVICE_NAME}.log" ]]; then
        tail -n "$n" "/var/log/${SERVICE_NAME}.log"
      else
        echo "(暂无日志: /var/log/${SERVICE_NAME}.log)"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------- 端口 ------
# 端口是否被占用(含被本服务自己监听), proto 支持 "tcp" / "udp" / "tcp,udp"
port_busy() {
  local port="$1" proto="$2" p flag
  command -v ss >/dev/null 2>&1 || return 1
  for p in ${proto//,/ }; do
    flag="-lnt"
    [[ "$p" == "udp" ]] && flag="-lnu"
    if ss "$flag" 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${port}\$"; then
      return 0
    fi
  done
  return 1
}

# 校验并归一化所有声明端口; PORT_SPECS = ("PORT:tcp" ...)
resolve_ports() {
  local spec name proto p

  # 协议段可在此补默认端口(如 VMess 取 VLESS+1)
  if declare -F port_defaults_hook >/dev/null; then
    port_defaults_hook
  fi

  for spec in "${PORT_SPECS[@]}"; do
    name="${spec%%:*}"; proto="${spec#*:}"
    p="${!name}"
    [[ "$p" =~ ^[0-9]+$ ]] || die "${name} 必须是数字: ${p}"
    p="$((10#$p))"          # 10# 避免 0808 被当成八进制
    printf -v "$name" '%s' "$p"
    ((p >= 1 && p <= 65535)) || die "${name} 超出范围 (1-65535): ${p}"
    if port_busy "$p" "$proto"; then
      die "端口 ${p}/${proto} 已被占用, 请换端口: ${name}=<新端口>"
    fi
  done

  if declare -F port_validate_hook >/dev/null; then
    port_validate_hook
  fi
  ok "端口: $(port_summary)"
}

port_summary() {
  local spec name proto out=""
  for spec in "${PORT_SPECS[@]}"; do
    name="${spec%%:*}"; proto="${spec#*:}"
    out+="${!name}/${proto} "
  done
  printf '%s' "${out% }"
}

open_firewall() {
  local spec name proto p
  for spec in "${PORT_SPECS[@]}"; do
    name="${spec%%:*}"; proto="${spec#*:}"
    for p in ${proto//,/ }; do
      if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${!name}/${p}" >/dev/null 2>&1 \
          && ok "ufw 已放行 ${!name}/${p}" || warn "ufw 放行失败"
      fi
      if command -v firewall-cmd >/dev/null 2>&1 \
        && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${!name}/${p}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ok "firewalld 已放行 ${!name}/${p}"
      fi
      if [[ "$OS_FAMILY" == "alpine" ]] && command -v iptables >/dev/null 2>&1; then
        if iptables -S INPUT 2>/dev/null | head -n1 | grep -q '\-P INPUT DROP'; then
          warn "INPUT 默认 DROP, 需手动放行: iptables -A INPUT -p ${p} --dport ${!name} -j ACCEPT"
        fi
      fi
    done
  done
}

# ---------------------------------------------------------------- 启动 ------
wait_listen() {
  local port="$1" proto="$2" i
  for i in 1 2 3 4 5; do
    port_busy "$port" "$proto" && return 0
    sleep 1
  done
  return 1
}

start_service() {
  if declare -F pre_start_hook >/dev/null; then
    pre_start_hook
  fi

  info "启动服务..."
  service_restart || { service_logs 50 >&2; die "服务启动失败"; }
  sleep 2

  # 双栈监听个别网络环境下起不来, 回退 IPv4
  if ! service_is_active && grep -q '"listen": "::"' "$CONFIG_FILE"; then
    warn "启动失败, 尝试改用 IPv4 监听..."
    sed -i 's/"listen": "::"/"listen": "0.0.0.0"/g' "$CONFIG_FILE"
    service_restart || true
    sleep 2
  fi

  if ! service_is_active; then
    service_logs 30 >&2
    die "服务未能保持运行"
  fi

  local spec name proto bad=0
  for spec in "${PORT_SPECS[@]}"; do
    name="${spec%%:*}"; proto="${spec#*:}"
    if ! wait_listen "${!name}" "$proto"; then
      warn "端口 ${!name}/${proto} 未监听"
      bad=1
    fi
  done
  ((bad)) && { service_logs 30 >&2; die "服务端口未全部就绪"; }

  ok "服务运行中, $(port_summary) 已监听"
}

# ---------------------------------------------------------------- 本地安装 --
# 把脚本自身装到 /usr/local/bin/singbox-<short>, 让 info/uninstall 无需联网重下
install_self() {
  local dest="${INSTALL_DIR}/singbox-${SHORT_NAME}"
  local src="$0"

  if [[ -f "$src" && "$src" != /dev/* && -r "$src" && "$(basename "$src")" != bash ]]; then
    install -m 0755 "$src" "$dest" 2>/dev/null && { ok "本地命令: ${dest}"; return 0; }
  fi
  if fetch "$RAW_URL" "${dest}.tmp"; then
    install -m 0755 "${dest}.tmp" "$dest" && rm -f "${dest}.tmp" \
      && { ok "本地命令: ${dest}"; return 0; }
  fi
  rm -f "${dest}.tmp" 2>/dev/null || true
  warn "未能安装本地命令, 可用远程方式管理: curl -fsSL ${RAW_URL} | sudo bash -s -- info"
}

# ------------------------------------------------------------ 管理命令块 ----
print_manage_block() {
  local cmd="singbox-${SHORT_NAME}"
  echo
  hr
  printf '  管理命令\n'
  hr
  case "$INIT_SYSTEM" in
    systemd)
      printf '  systemctl status %s    查看状态\n' "$SERVICE_NAME"
      printf '  systemctl restart %s   重启\n' "$SERVICE_NAME"
      printf '  journalctl -u %s -f    实时日志\n' "$SERVICE_NAME"
      ;;
    openrc)
      printf '  rc-service %s status   查看状态\n' "$SERVICE_NAME"
      printf '  rc-service %s restart  重启\n' "$SERVICE_NAME"
      printf '  tail -f /var/log/%s.log 实时日志\n' "$SERVICE_NAME"
      ;;
  esac
  printf '  %s info           重新打印此信息\n' "$cmd"
  printf '  %s logs           查看最近日志\n' "$cmd"
  printf '  %s uninstall      卸载\n' "$cmd"
  printf '  远程用法: curl -fsSL %s | sudo bash -s -- info\n' "$RAW_URL"
  echo
}

# ---------------------------------------------------------------- 信息查询 --
cmd_info() {
  [[ -f "$CONFIG_FILE" ]] || die "未找到配置 ${CONFIG_FILE}, 请先运行部署"
  load_credentials
  print_summary "$(public_addr)"
}

# ------------------------------------------------------------------ 卸载 ---
cmd_uninstall() {
  info "开始卸载 ${SERVICE_NAME}..."

  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop "$SERVICE_NAME" 2>/dev/null || true
      systemctl disable "$SERVICE_NAME" 2>/dev/null || true
      rm -f "$SERVICE_FILE"
      systemctl daemon-reload 2>/dev/null || true
      ;;
    openrc)
      rc-service "$SERVICE_NAME" stop 2>/dev/null || true
      rc-update del "$SERVICE_NAME" default 2>/dev/null || true
      rm -f "$SERVICE_FILE"
      rm -f "/var/log/${SERVICE_NAME}.log"
      ;;
  esac

  if [[ "$KEEP_CONFIG" == "1" ]]; then
    warn "保留配置: ${CONFIG_FILE}"
  else
    rm -f "$CONFIG_FILE"
    ok "已删除配置"
  fi

  rm -f "${INSTALL_DIR}/singbox-${SHORT_NAME}"

  local others
  others="$(list_other_services)"
  if [[ -z "$others" ]]; then
    rm -f "$BIN_PATH"
    ok "已删除二进制"
  else
    warn "检测到其他 sing-box 服务仍在, 保留 ${BIN_PATH}: $(echo $others)"
  fi
  echo
  ok "卸载完成。若不再需要, 可手动清理 ${CONFIG_DIR}"
}

# ------------------------------------------------------------------ 主流程 --
do_install() {
  check_os
  check_deps
  resolve_ports

  if ((NEED_DOMAIN)); then
    [[ -n "$DOMAIN" ]] || DOMAIN="${DEFAULT_DOMAINS[RANDOM % ${#DEFAULT_DOMAINS[@]}]}"
    ok "域名 / SNI: ${DOMAIN}"
  fi

  if service_is_active 2>/dev/null; then
    info "检测到 ${SERVICE_NAME} 正在运行, 先停止..."
    service_stop
  fi

  install_binary

  if ((NEED_CERT)); then
    ensure_cert "$DOMAIN"
  fi

  prepare_secrets
  write_config
  write_service
  open_firewall
  start_service
  install_self
  print_summary "$(public_addr)"
}

main() {
  local action="${1:-install}"

  case "$action" in
    -h|--help|help) usage; return 0 ;;
  esac

  check_root

  case "$action" in
    install)          do_install ;;
    info)             check_os; cmd_info ;;
    uninstall|remove) check_os; cmd_uninstall ;;
    logs)             check_os; service_logs "${2:-50}" ;;
    *) die "未知命令: ${action} (可用: install / info / uninstall / logs / help)" ;;
  esac
}

# ---------------------------------------------------------------- 配置 ------
render_config() {
  cat <<EOF
{
  "log": {
    "level": "${LOG_LEVEL}",
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
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "${PASSWORD}"
        }
      ],
      "congestion_control": "${CONGESTION}",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
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
}

# ---------------------------------------------------------------- 凭据 ------
prepare_secrets() {
  [[ -n "$UUID" ]] || UUID="$(gen_uuid)"
  [[ -n "$PASSWORD" ]] || PASSWORD="$(rand_token 16)"
  ok "UUID: ${UUID}"
  ok "密码: ${PASSWORD}"
}

load_credentials() {
  UUID="$(json_get "$CONFIG_FILE" uuid)"
  PASSWORD="$(json_get "$CONFIG_FILE" password)"
  PORT="$(json_get "$CONFIG_FILE" listen_port)"
  DOMAIN="$(json_get "$CONFIG_FILE" server_name)"
  CONGESTION="$(json_get "$CONFIG_FILE" congestion_control)"
  [[ -n "$UUID" && -n "$PASSWORD" ]] || die "配置中未解析到 uuid/password"
  PORT="${PORT:-443}"
  CONGESTION="${CONGESTION:-bbr}"
}

# ---------------------------------------------------------------- 输出 ------
print_summary() {
  local server="$1" link
  # 自签证书必须跳过校验: 两种写法都带上, 客户端按各自习惯取其一
  link="tuic://${UUID}:${PASSWORD}@${server}:${PORT}?congestion_control=${CONGESTION}&udp_relay_mode=native&alpn=h3&sni=${DOMAIN}&allow_insecure=1&allowInsecure=1#tuic-${PORT}"

  echo
  hr
  printf '%s  TUIC v5 部署完成%s\n' "$C_BLD$C_GRN" "$C_RST"
  hr
  printf '  服务器 IP   : %s\n' "$server"
  printf '  端口        : %s/udp\n' "$PORT"
  printf '  UUID        : %s\n' "$UUID"
  printf '  密码        : %s\n' "$PASSWORD"
  printf '  SNI / 域名  : %s\n' "$DOMAIN"
  printf '  拥塞控制    : %s\n' "$CONGESTION"
  printf '  证书        : %s (自签, 客户端需跳过校验)\n' "$CERT_FILE"
  printf '  配置文件    : %s\n' "$CONFIG_FILE"
  printf '  二进制      : %s\n' "$BIN_PATH"
  printf '  服务名      : %s\n' "$SERVICE_NAME"
  echo
  printf '%s  tuic:// 链接%s\n' "$C_BLD" "$C_RST"
  printf '%s\n' "$link"
  echo
  printf '  UDP 端口需在云厂商安全组放行; 客户端允许不安全证书才能用自签证书。\n'
  print_manage_block
}

# ---------------------------------------------------------------- 帮助 ------
usage() {
  cat <<'USAGE'
singbox_tuic.sh - 一键部署 TUIC v5 服务端 (sing-box-extended)

用法:
  sudo bash singbox_tuic.sh             # 安装 (默认 443/udp)
  sudo bash singbox_tuic.sh info        # 查看凭据与链接
  sudo bash singbox_tuic.sh uninstall   # 卸载
  sudo bash singbox_tuic.sh logs        # 查看最近日志
  sudo bash singbox_tuic.sh help        # 本帮助

常用自定义 (环境变量):
  PORT=8443                                  # 监听端口
  UUID=xxx PASSWORD=yyy                      # 用户凭据
  CONGESTION=bbr                             # bbr / cubic / new_reno
  CERT_FILE=... KEY_FILE=...                 # 使用已有证书(不填则自签)
  SERVER_ADDR=1.2.3.4                        # 指定对外 IP
  MIRROR=https://ghfast.top/https://github.com
  SINGBOX_TAG=v1.14.1-extended-2.7.2         # 覆盖锁定的内核版本
USAGE
}

main "$@"

#!/usr/bin/env bash
#
# singbox_all.sh - 一键部署 sing-box 全协议服务端 (all-in-one, 单进程单配置)
#
# 架构: 只运行 **一个** sing-box 进程、注册 **一个** 服务(singbox-all)、
#       使用 **一份** 合并配置(/etc/sing-box/all.json), 6 个入站并存:
#         MTPROXY / Hysteria2 / TUIC v5 / Shadowsocks / VLESS / VMess
#       分发与运行都只有这一个脚本文件。
#
# 默认端口计划 (443 的 TCP 与 UDP 互不冲突, 分别给 MT 与 HY2; TUIC 让出 443 用 8443):
#   MTPROXY       443/tcp
#   Hysteria2     443/udp
#   TUIC v5       8443/udp
#   Shadowsocks   8388/tcp+udp
#   VLESS         8989/tcp      (TLS + WS, 路径 /vless)
#   VMess         8990/tcp      (TLS + WS, 路径 /vmess)
#
# 跨系统支持:
#   Debian 系              systemd + apt,      防火墙 ufw / iptables
#   RHEL 系(CentOS 等)    systemd + dnf/yum,  防火墙 firewalld / iptables
#   Alpine                 OpenRC + apk,       防火墙 iptables(自动持久化)
#   脚本会识别发行版与 init 系统, 自动放行防火墙并尽力持久化规则。
#
# 用法:
#   sudo bash singbox_all.sh                    # 全部安装
#   sudo PROTOCOLS=mt,hy2 bash singbox_all.sh   # 只启用指定协议(mt hy2 tuic ssr vless)
#   sudo bash singbox_all.sh plan               # 只打印/校验端口计划, 不安装
#   sudo bash singbox_all.sh status             # 查看服务状态与端口
#   sudo bash singbox_all.sh info               # 重新打印全部凭据与链接
#   sudo bash singbox_all.sh logs [N]           # 查看最近 N 行日志
#   sudo bash singbox_all.sh uninstall          # 卸载
#
# 端口环境变量 (只在显式指定时才覆盖; 重装时未指定的端口沿用上次实际值):
#   MT_PORT / HY2_PORT / TUIC_PORT / SSR_PORT / VLESS_PORT / VMESS_PORT
# 凭据环境变量 (缺省随机, 重装自动从合并配置复用):
#   DOMAIN(全部 TLS 协议共用 SNI) MT_USER_NAME MT_CONCURRENCY MT_AUTO_UPDATE
#   HY2_PASSWORD HY2_OBFS TUIC_UUID TUIC_PASSWORD TUIC_CONGESTION
#   SSR_PASSWORD SSR_METHOD VLESS_UUID VMESS_UUID VLESS_PATH VMESS_PATH
# 通用: SERVER_ADDR / MIRROR / SINGBOX_TAG / LOG_LEVEL / FORCE_BIN
#
set -euo pipefail

RAW_FILE="singbox_all.sh"

SERVICE_NAME="singbox-all"
SERVICE_DESC="sing-box All-in-One Server (extended)"
SHORT_NAME="all"
CONFIG_FILE="/etc/sing-box/all.json"

NEED_CERT=1
NEED_DOMAIN=1

PROTO_LIST="${PROTOCOLS:-mt,hy2,tuic,ssr,vless}"
PROTO_LIST="${PROTO_LIST//,/ }"

# 端口计划: 先记录用户是否显式指定(重装时未指定的端口要沿用已有配置)
MT_PORT_SET=0
[[ -n "${MT_PORT+x}" ]] && MT_PORT_SET=1
HY2_PORT_SET=0
[[ -n "${HY2_PORT+x}" ]] && HY2_PORT_SET=1
TUIC_PORT_SET=0
[[ -n "${TUIC_PORT+x}" ]] && TUIC_PORT_SET=1
SSR_PORT_SET=0
[[ -n "${SSR_PORT+x}" ]] && SSR_PORT_SET=1
VLESS_PORT_SET=0
[[ -n "${VLESS_PORT+x}" ]] && VLESS_PORT_SET=1
VMESS_PORT_SET=0
[[ -n "${VMESS_PORT+x}" ]] && VMESS_PORT_SET=1

MT_PORT="${MT_PORT:-443}"
HY2_PORT="${HY2_PORT:-443}"
TUIC_PORT="${TUIC_PORT:-8443}"
SSR_PORT="${SSR_PORT:-8388}"
VLESS_PORT="${VLESS_PORT:-8989}"
VMESS_PORT="${VMESS_PORT:-8990}"

MT_USER_NAME="${MT_USER_NAME:-user1}"
MT_CONCURRENCY="${MT_CONCURRENCY:-8192}"
MT_AUTO_UPDATE="${MT_AUTO_UPDATE:-0}"
HY2_PASSWORD="${HY2_PASSWORD:-}"
HY2_OBFS="${HY2_OBFS:-}"
TUIC_UUID="${TUIC_UUID:-}"
TUIC_PASSWORD="${TUIC_PASSWORD:-}"
TUIC_CONGESTION="${TUIC_CONGESTION:-bbr}"
SSR_PASSWORD="${SSR_PASSWORD:-}"
SSR_METHOD="${SSR_METHOD:-aes-256-gcm}"
VLESS_UUID="${VLESS_UUID:-}"
VMESS_UUID="${VMESS_UUID:-}"
VLESS_PATH="${VLESS_PATH:-/vless}"
VMESS_PATH="${VMESS_PATH:-/vmess}"
SECRET=""

# 用户显式指定的伪装域名 / SNI, 全部 TLS 协议共用; 留空则沿用旧配置或随机
USER_DOMAIN="${DOMAIN:-}"

# @@LIB@@

# ------------------------------------------------------------ 计划与工具 ----
normalize_protocols() {
  local out="" p
  for p in $PROTO_LIST; do
    [[ -n "$p" ]] || continue
    case "$p" in
      mt|hy2|tuic|ssr|vless) out+="${p}"$'\n' ;;
      *) die "未知协议: ${p} (可用: mt hy2 tuic ssr vless, 用 PROTOCOLS=mt,hy2,... 选择)" ;;
    esac
  done
  [[ -n "$out" ]] || die "PROTOCOLS 解析结果为空"
  PROTO_LIST="$(printf '%s' "$out" | awk '!seen[$0]++' | tr '\n' ' ')"
  PROTO_LIST="${PROTO_LIST% }"

  # 是否需要 TLS 证书: 有任一 TLS 协议才装 openssl
  NEED_CERT=0
  if want_proto hy2 || want_proto tuic || want_proto vless; then
    NEED_CERT=1
  fi
}

want_proto() { [[ " $PROTO_LIST " == *" $1 "* ]]; }

# 协议计划端口(空格分隔)
ports_of() {
  case "$1" in
    mt)    printf '%s' "$MT_PORT" ;;
    hy2)   printf '%s' "$HY2_PORT" ;;
    tuic)  printf '%s' "$TUIC_PORT" ;;
    ssr)   printf '%s' "$SSR_PORT" ;;
    vless) printf '%s %s' "$VLESS_PORT" "$VMESS_PORT" ;;
  esac
}

# 协议占用的网络协议族
proto_nets() {
  case "$1" in
    mt|vless) printf 'tcp' ;;
    hy2|tuic) printf 'udp' ;;
    ssr)      printf 'tcp udp' ;;
  esac
}

# 两组合网络协议是否有交集
_nets_overlap() {
  local a b
  for a in $1; do
    for b in $2; do
      [[ "$a" == "$b" ]] && return 0
    done
  done
  return 1
}

# 端口是否不可用: 系统已占用, 或与已分配端口网络族重叠
plan_port_conflict() { # port nets assigned("port:nets ...")
  local a
  if port_busy "$1" "$2"; then return 0; fi
  for a in $3; do
    if [[ "${a%%:*}" == "$1" ]] && _nets_overlap "${a#*:}" "$2"; then
      return 0
    fi
  done
  return 1
}

plan_summary() {
  local p out=""
  for p in $PROTO_LIST; do
    out+="${p}=$(ports_of "$p" | tr ' ' '/') "
  done
  printf '%s' "${out% }"
}

# 装前统一校验端口计划, 避免装到一半才发现互相打架
validate_plan() {
  local p pp e entries="" found port protos a b

  if want_proto vless; then
    [[ "$VLESS_PORT" != "$VMESS_PORT" ]] \
      || die "VLESS_PORT 与 VMESS_PORT 不能相同 (sing-box 每端口只能一个入站)"
  fi

  for p in $PROTO_LIST; do
    for pp in $(ports_of "$p"); do
      found=""
      for e in $entries; do
        if [[ "${e%%:*}" == "$pp" ]]; then found="$e"; break; fi
      done
      if [[ -n "$found" ]]; then
        entries="${entries/ ${found} / ${pp}:${found#*:},${p} }"
      else
        entries+=" ${pp}:${p} "
      fi
    done
  done

  for e in $entries; do
    port="${e%%:*}"; protos="${e#*:}"
    [[ "$protos" == *,* ]] || continue
    for a in ${protos//,/ }; do
      for b in ${protos//,/ }; do
        [[ "$a" == "$b" ]] && continue
        if _nets_overlap "$(proto_nets "$a")" "$(proto_nets "$b")"; then
          die "端口计划冲突: ${a} 与 ${b} 都要用 ${port} 端口, 请用大写的 ${a}_PORT / ${b}_PORT 环境变量错开"
        fi
      done
    done
  done

  ok "端口计划: $(plan_summary)"
}

# 从合并配置里按入站 type 取字段, 路径形如 users.0.password
# 无 python3 / 字段缺失时返回空(凭据会重新生成)
inbound_pick() { # <type> <path>
  [[ -f "$CONFIG_FILE" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$CONFIG_FILE" "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
want, field = sys.argv[2], sys.argv[3]
for ib in d.get("inbounds", []):
    if ib.get("type") != want:
        continue
    cur = ib
    ok = True
    for part in field.split("."):
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                ok = False
        elif isinstance(cur, dict):
            cur = cur[part] if part in cur else None
            if cur is None:
                ok = False
        else:
            ok = False
        if not ok:
            break
    if ok and isinstance(cur, (str, int)) and not isinstance(cur, bool):
        print(cur)
    break
PY
}

# OpenRC 未初始化(容器/chroot)时兜底, 保证服务能注册自启
ensure_openrc_ready() {
  [[ "$INIT_SYSTEM" == "openrc" ]] || return 0
  if [[ ! -e /run/openrc/softlevel ]]; then
    mkdir -p /run/openrc 2>/dev/null && touch /run/openrc/softlevel 2>/dev/null || true
    warn "OpenRC 未初始化(容器/chroot?), 已写入 /run/openrc/softlevel; 真实系统可忽略"
  fi
}

# 旧版按协议拆分的 5 个服务迁移为单一 singbox-all 服务
migrate_legacy() {
  local svc f found=0
  for svc in singbox-mt singbox-hy2 singbox-tuic singbox-ssr singbox-vless; do
    case "$INIT_SYSTEM" in
      systemd) f="/etc/systemd/system/${svc}.service" ;;
      openrc)  f="/etc/init.d/${svc}" ;;
      *)       f="" ;;
    esac
    [[ -n "$f" && -e "$f" ]] || continue
    found=1
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
      systemctl stop "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true
    else
      rc-service "$svc" stop 2>/dev/null || true
      rc-update del "$svc" default 2>/dev/null || true
    fi
    rm -f "$f" "/usr/local/bin/${svc}"
  done
  if ((found)); then
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
      systemctl daemon-reload 2>/dev/null || true
    fi
    warn "已移除旧版拆分服务(singbox-mt/hy2/tuic/ssr/vless), 统一为 ${SERVICE_NAME}"
    warn "旧配置 json 保留在 ${CONFIG_DIR}, 确认无误后可手动清理"
  fi
}

# ------------------------------------------------------------- 端口解析 ----
# 优先级: 显式环境变量 > 已有合并配置(按入站类型匹配) > 内置默认
# 逐项校验 + 冲突处理(询问 -> 超时自动挑), 结果回写 MT_PORT 等变量并生成 PORT_SPECS
resolve_plan_ports() {
  local entries=(
    "mt:MT_PORT:mtproxy:tcp"
    "hy2:HY2_PORT:hysteria2:udp"
    "tuic:TUIC_PORT:tuic:udp"
    "ssr:SSR_PORT:shadowsocks:tcp,udp"
    "vless:VLESS_PORT:vless:tcp"
    "vless:VMESS_PORT:vmess:tcp"
  )
  local e proto var type nets p ep newp f assigned=""

  # 自动挑端口时避开全部计划端口(本项旧端口已废弃, 一并避开无妨)
  local planned=""
  for proto in $PROTO_LIST; do
    planned+="$(ports_of "$proto") "
  done
  PORT_EXTRA_BLOCKLIST="${planned% }"

  PORT_SPECS=()
  for e in "${entries[@]}"; do
    IFS=: read -r proto var type nets <<<"$e"
    want_proto "$proto" || continue

    p="${!var:-}"
    f="${var}_SET"
    if [[ "${!f:-0}" != "1" ]]; then
      ep="$(inbound_pick "$type" listen_port)"
      if [[ -n "$ep" ]]; then
        p="$ep"
        info "沿用已有配置端口 ${var}=${p}"
      fi
    fi

    [[ "$p" =~ ^[0-9]+$ ]] || die "${var} 必须是数字: ${p}"
    p="$((10#$p))"
    ((p >= 1 && p <= 65535)) || die "${var} 超出范围 (1-65535): ${p}"

    if plan_port_conflict "$p" "$nets" "$assigned"; then
      newp="$(ask_port "$var" "$p" "$nets")" || newp=""
      if [[ -z "$newp" ]]; then
        newp="$(pick_free_port "$nets" $assigned)" \
          || die "端口 ${p} 无法使用, 且自动挑选失败, 请显式指定 ${var}=<端口>"
        warn "端口 ${p} 不可用, ${var} 自动改用 ${newp}"
      else
        ok "${var} 端口已改为 ${newp}"
      fi
      p="$newp"
    fi

    printf -v "$var" '%s' "$p"
    assigned+=" ${p}:${nets}"
    PORT_SPECS+=("${var}:${nets}")
  done

  ok "端口: $(port_summary)"
}

# ---------------------------------------------------------------- 凭据 ------
prepare_all_secrets() {
  # 重装时从合并配置复用旧凭据, 否则已有客户端会全部失效
  if want_proto mt; then
    [[ -n "$SECRET" ]] || SECRET="$(inbound_pick mtproxy users.0.secret)"
    [[ -n "$SECRET" ]] || SECRET="$(_mt_gen_secret "$DOMAIN")"
    [[ ${#SECRET} -gt 34 ]] || die "secret 生成异常: ${SECRET}"
    ok "MTPROXY secret 已生成 (长度 ${#SECRET})"
  fi

  if want_proto hy2; then
    [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$(inbound_pick hysteria2 users.0.password)"
    [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$(rand_token 16)"
    [[ -n "$HY2_OBFS" ]] || HY2_OBFS="$(inbound_pick hysteria2 obfs.password)"
    ok "Hysteria2 密码: ${HY2_PASSWORD}"
    [[ -z "$HY2_OBFS" ]] || ok "Hysteria2 混淆: salamander"
  fi

  if want_proto tuic; then
    [[ -n "$TUIC_UUID" ]] || TUIC_UUID="$(inbound_pick tuic users.0.uuid)"
    [[ -n "$TUIC_PASSWORD" ]] || TUIC_PASSWORD="$(inbound_pick tuic users.0.password)"
    [[ -n "$TUIC_UUID" ]] || TUIC_UUID="$(gen_uuid)"
    [[ -n "$TUIC_PASSWORD" ]] || TUIC_PASSWORD="$(rand_token 16)"
    ok "TUIC UUID: ${TUIC_UUID}  密码: ${TUIC_PASSWORD}"
  fi

  if want_proto ssr; then
    [[ -n "$SSR_PASSWORD" ]] || SSR_PASSWORD="$(inbound_pick shadowsocks password)"
    [[ -n "$SSR_PASSWORD" ]] || SSR_PASSWORD="$(rand_token 16)"
    ok "Shadowsocks 密码: ${SSR_PASSWORD}"
  fi

  if want_proto vless; then
    [[ -n "$VLESS_UUID" ]] || VLESS_UUID="$(inbound_pick vless users.0.uuid)"
    [[ -n "$VMESS_UUID" ]] || VMESS_UUID="$(inbound_pick vmess users.0.uuid)"
    [[ -n "$VLESS_UUID" ]] || VLESS_UUID="$(gen_uuid)"
    [[ -n "$VMESS_UUID" ]] || VMESS_UUID="$(gen_uuid)"
    ok "VLESS UUID: ${VLESS_UUID}"
    ok "VMess UUID: ${VMESS_UUID}"
  fi
}

# info: 从合并配置反读全部凭据
load_all_credentials() {
  if want_proto mt; then
    MT_PORT="$(inbound_pick mtproxy listen_port)"
    MT_PORT="${MT_PORT:-443}"
    SECRET="$(inbound_pick mtproxy users.0.secret)"
    [[ -n "$SECRET" ]] || die "配置中未解析到 MTPROXY secret"
    MT_USER_NAME="$(inbound_pick mtproxy users.0.name)"
    MT_USER_NAME="${MT_USER_NAME:-user1}"
  fi
  if want_proto hy2; then
    HY2_PORT="$(inbound_pick hysteria2 listen_port)"
    HY2_PORT="${HY2_PORT:-443}"
    HY2_PASSWORD="$(inbound_pick hysteria2 users.0.password)"
    [[ -n "$HY2_PASSWORD" ]] || die "配置中未解析到 Hysteria2 密码"
    HY2_OBFS="$(inbound_pick hysteria2 obfs.password)"
  fi
  if want_proto tuic; then
    TUIC_PORT="$(inbound_pick tuic listen_port)"
    TUIC_PORT="${TUIC_PORT:-8443}"
    TUIC_UUID="$(inbound_pick tuic users.0.uuid)"
    TUIC_PASSWORD="$(inbound_pick tuic users.0.password)"
    TUIC_CONGESTION="$(inbound_pick tuic congestion_control)"
    TUIC_CONGESTION="${TUIC_CONGESTION:-bbr}"
    [[ -n "$TUIC_UUID" && -n "$TUIC_PASSWORD" ]] || die "配置中未解析到 TUIC 凭据"
  fi
  if want_proto ssr; then
    SSR_PORT="$(inbound_pick shadowsocks listen_port)"
    SSR_PORT="${SSR_PORT:-8388}"
    SSR_PASSWORD="$(inbound_pick shadowsocks password)"
    SSR_METHOD="$(inbound_pick shadowsocks method)"
    SSR_METHOD="${SSR_METHOD:-aes-256-gcm}"
    [[ -n "$SSR_PASSWORD" ]] || die "配置中未解析到 Shadowsocks 密码"
  fi
  if want_proto vless; then
    VLESS_PORT="$(inbound_pick vless listen_port)"
    VLESS_PORT="${VLESS_PORT:-8989}"
    VMESS_PORT="$(inbound_pick vmess listen_port)"
    VMESS_PORT="${VMESS_PORT:-$((VLESS_PORT + 1))}"
    VLESS_UUID="$(inbound_pick vless users.0.uuid)"
    VMESS_UUID="$(inbound_pick vmess users.0.uuid)"
    VLESS_PATH="${VLESS_PATH:-/vless}"
    VMESS_PATH="${VMESS_PATH:-/vmess}"
    [[ -n "$VLESS_UUID" && -n "$VMESS_UUID" ]] || die "配置中未解析到 VLESS/VMess UUID"
  fi
  if [[ -z "$USER_DOMAIN" ]]; then
    DOMAIN="$(inbound_pick hysteria2 tls.server_name)"
    [[ -n "$DOMAIN" ]] || DOMAIN="$(inbound_pick tuic tls.server_name)"
    [[ -n "$DOMAIN" ]] || DOMAIN="$(inbound_pick vless tls.server_name)"
  else
    DOMAIN="$USER_DOMAIN"
  fi
}

# ---------------------------------------------------------------- 入站 ------
_mt_gen_secret() {
  local domain="$1" key_hex
  key_hex="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf 'ee%s' "$key_hex"
  printf '%s' "$domain" | od -An -tx1 | tr -d ' \n'
}

_mt_inbound() {
  local auto_update_json="false"
  if [[ "$MT_AUTO_UPDATE" == "1" ]]; then auto_update_json="true"; fi

  cat <<EOF
    {
      "type": "mtproxy",
      "tag": "mtp-in",
      "listen": "::",
      "listen_port": ${MT_PORT},
      "users": [
        {
          "name": "${MT_USER_NAME}",
          "secret": "${SECRET}"
        }
      ],
      "concurrency": ${MT_CONCURRENCY},
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
EOF
}

_hy2_inbound() {
  local obfs_block=""
  if [[ -n "$HY2_OBFS" ]]; then
    obfs_block='      "obfs": {
        "type": "salamander",
        "password": "'"${HY2_OBFS}"'"
      },
'
  fi

  cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${HY2_PASSWORD}"
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
EOF
}

_tuic_inbound() {
  cat <<EOF
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [
        {
          "uuid": "${TUIC_UUID}",
          "password": "${TUIC_PASSWORD}"
        }
      ],
      "congestion_control": "${TUIC_CONGESTION}",
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
EOF
}

_ssr_inbound() {
  cat <<EOF
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${SSR_PORT},
      "network": [
        "tcp",
        "udp"
      ],
      "method": "${SSR_METHOD}",
      "password": "${SSR_PASSWORD}"
    }
EOF
}

_vless_inbound() {
  cat <<EOF
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${VLESS_UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": [
          "http/1.1"
        ],
        "min_version": "1.2",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      },
      "transport": {
        "type": "ws",
        "path": "${VLESS_PATH}"
      }
    }
EOF
}

_vmess_inbound() {
  cat <<EOF
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": ${VMESS_PORT},
      "users": [
        {
          "uuid": "${VMESS_UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": [
          "http/1.1"
        ],
        "min_version": "1.2",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      },
      "transport": {
        "type": "ws",
        "path": "${VMESS_PATH}"
      }
    }
EOF
}

# 合并配置: 单文件包含全部启用协议的入站, 单进程加载
render_config() {
  local inbs=() ib joined=""

  if want_proto mt;    then inbs+=("$(_mt_inbound)"); fi
  if want_proto hy2;   then inbs+=("$(_hy2_inbound)"); fi
  if want_proto tuic;  then inbs+=("$(_tuic_inbound)"); fi
  if want_proto ssr;   then inbs+=("$(_ssr_inbound)"); fi
  if want_proto vless; then
    inbs+=("$(_vless_inbound)")
    inbs+=("$(_vmess_inbound)")
  fi

  for ib in "${inbs[@]}"; do
    [[ -n "$joined" ]] && joined+=","
    joined+="$ib"
  done

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
${joined}
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

# ---------------------------------------------------------------- 链接 ------
_mt_link() {
  local server="$1"
  printf 'https://t.me/proxy?server=%s&port=%s&secret=%s' "$server" "$MT_PORT" "$SECRET"
}

_hy2_link() {
  local server="$1" link
  link="hysteria2://${HY2_PASSWORD}@${server}:${HY2_PORT}/?sni=${DOMAIN}&insecure=1"
  if [[ -n "$HY2_OBFS" ]]; then
    link="${link}&obfs=salamander&obfs-password=${HY2_OBFS}"
  fi
  printf '%s' "${link}#hy2-${HY2_PORT}"
}

_tuic_link() {
  local server="$1"
  # 自签证书必须跳过校验: 两种写法都带上, 客户端按各自习惯取其一
  printf 'tuic://%s:%s@%s:%s?congestion_control=%s&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=1&allowInsecure=1#tuic-%s' \
    "$TUIC_UUID" "$TUIC_PASSWORD" "$server" "$TUIC_PORT" \
    "$TUIC_CONGESTION" "$DOMAIN" "$TUIC_PORT"
}

_ssr_link() {
  local server="$1" userinfo
  userinfo="$(printf '%s:%s' "$SSR_METHOD" "$SSR_PASSWORD" | base64 | tr -d '\r\n=' | tr '+/' '-_')"
  printf 'ss://%s@%s:%s#ss-%s' "$userinfo" "$server" "$SSR_PORT" "$SSR_PORT"
}

_vless_link() {
  local server="$1"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s&allowInsecure=1#vless-%s' \
    "$VLESS_UUID" "$server" "$VLESS_PORT" "$DOMAIN" "$DOMAIN" \
    "$(printf '%s' "$VLESS_PATH" | sed 's|/|%2F|g')" "$VLESS_PORT"
}

_vmess_link() {
  local server="$1" json
  # allowInsecure=1: 自签证书需跳过校验, 与 VLESS 链接保持一致
  json="$(printf '{"v":"2","ps":"vmess-%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","alpn":"http/1.1","fp":"chrome","allowInsecure":"1"}' \
    "$VMESS_PORT" "$server" "$VMESS_PORT" "$VMESS_UUID" "$DOMAIN" "$VMESS_PATH" "$DOMAIN")"
  printf 'vmess://%s' "$(printf '%s' "$json" | base64 | tr -d '\r\n')"
}

# ---------------------------------------------------------------- 输出 ------
# 协议小节标题: ── [N] 名称 · 监听 ──────────
_sec_head() { # $1=序号 $2=名称 $3=监听描述
  printf '\n  %s── %s %s ─────────────────────────────%s\n' \
    "$C_BLD$C_BLU" "$1" "$2" "$C_RST"
  printf '  监听 : %s%s%s\n' "$C_YEL" "$3" "$C_RST"
}

_link_line() { printf '  链接 : %s%s%s\n' "$C_GRN" "$1" "$C_RST"; }

print_summary_all() {
  local server="$1" r _n _l _d
  local rows=()

  echo
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"
  printf '   %s sing-box All-in-One 部署完成 %s\n' "$C_BLD$C_GRN" "$C_RST"
  printf '  %s============================================================%s\n' "$C_BLD$C_BLU" "$C_RST"

  # ---- 服务器信息 ----
  printf '\n  %s▍服务器信息%s\n' "$C_BLD$C_YEL" "$C_RST"
  printf '  服务器 IP     : %s%s%s\n' "$C_BLD" "$server" "$C_RST"
  printf '  配置文件      : %s (单文件含全部入站)\n' "$CONFIG_FILE"
  printf '  二进制        : %s\n' "$BIN_PATH"
  printf '  服务名        : %s (单进程)\n' "$SERVICE_NAME"
  printf '  初始化系统    : %s\n' "$INIT_SYSTEM"
  if want_proto hy2 || want_proto tuic || want_proto vless; then
    printf '  证书          : %s (自签, 客户端需跳过校验)\n' "$CERT_FILE"
    printf '  SNI / 域名    : %s\n' "$DOMAIN"
  fi

  # ---- 入站总览表 ----
  if want_proto mt;    then rows+=("MTPROXY|${MT_PORT}/tcp|FakeTLS 伪装"); fi
  if want_proto hy2;   then rows+=("Hysteria2|${HY2_PORT}/udp|QUIC"); fi
  if want_proto tuic;  then rows+=("TUIC v5|${TUIC_PORT}/udp|QUIC + BBR"); fi
  if want_proto ssr;   then rows+=("Shadowsocks|${SSR_PORT}/tcp+udp|AEAD 加密"); fi
  if want_proto vless; then
    rows+=("VLESS|${VLESS_PORT}/tcp|TLS + WS")
    rows+=("VMess|${VMESS_PORT}/tcp|TLS + WS")
  fi

  printf '\n  %s▍入站总览%s\n' "$C_BLD$C_YEL" "$C_RST"
  printf '  协议            监听端口       说明\n'
  printf '  %s\n' "────────────────────────────────────────────"
  for r in "${rows[@]}"; do
    IFS='|' read -r _n _l _d <<<"$r"
    printf '  %-15s %-14s %s\n' "$_n" "$_l" "$_d"
  done

  # ---- 各协议凭据与链接 ----
  printf '\n  %s▍连接信息%s\n' "$C_BLD$C_YEL" "$C_RST"
  if want_proto mt; then
    _sec_head "[1]" "MTPROXY" "${MT_PORT}/tcp"
    _link_line "$(_mt_link "$server")"
  fi
  if want_proto hy2; then
    _sec_head "[2]" "Hysteria2" "${HY2_PORT}/udp"
    printf '  密码 : %s\n' "$HY2_PASSWORD"
    [[ -n "$HY2_OBFS" ]] && printf '  混淆 : salamander / %s\n' "$HY2_OBFS"
    _link_line "$(_hy2_link "$server")"
  fi
  if want_proto tuic; then
    _sec_head "[3]" "TUIC v5" "${TUIC_PORT}/udp"
    printf '  UUID : %s\n' "$TUIC_UUID"
    printf '  密码 : %s\n' "$TUIC_PASSWORD"
    _link_line "$(_tuic_link "$server")"
  fi
  if want_proto ssr; then
    _sec_head "[4]" "Shadowsocks" "${SSR_PORT}/tcp+udp"
    printf '  加密 : %s\n' "$SSR_METHOD"
    printf '  密码 : %s\n' "$SSR_PASSWORD"
    _link_line "$(_ssr_link "$server")"
  fi
  if want_proto vless; then
    _sec_head "[5]" "VLESS" "${VLESS_PORT}/tcp"
    printf '  UUID : %s    WS 路径: %s\n' "$VLESS_UUID" "$VLESS_PATH"
    _link_line "$(_vless_link "$server")"
    _sec_head "[6]" "VMess" "${VMESS_PORT}/tcp"
    printf '  UUID : %s    WS 路径: %s\n' "$VMESS_UUID" "$VMESS_PATH"
    _link_line "$(_vmess_link "$server")"
  fi

  # ---- 客户端提示 ----
  printf '\n  %s▍客户端提示%s\n' "$C_BLD$C_YEL" "$C_RST"
  printf '  · TLS 协议记得开启 "允许不安全证书 / allowInsecure"\n'
  printf '  · Shadowsocks 客户端请选 "Shadowsocks", 不是 "ShadowsocksR"\n'
  print_manage_block
}

# ------------------------------------------------------------------ 主流程 --
do_install_all() {
  check_os
  check_deps
  validate_plan

  # 先停自身(重装), 再迁移清理旧版拆分服务, 避免端口被旧进程占用
  if service_is_active 2>/dev/null; then
    info "检测到 ${SERVICE_NAME} 正在运行, 先停止..."
    service_stop
  fi
  migrate_legacy

  resolve_plan_ports

  # 域名: 用户指定 > 旧配置(任意 TLS 入站) > 随机
  if [[ -z "$USER_DOMAIN" ]]; then
    DOMAIN="$(inbound_pick hysteria2 tls.server_name)"
    [[ -n "$DOMAIN" ]] || DOMAIN="$(inbound_pick tuic tls.server_name)"
    [[ -n "$DOMAIN" ]] || DOMAIN="$(inbound_pick vless tls.server_name)"
    [[ -n "$DOMAIN" ]] || DOMAIN="${DEFAULT_DOMAINS[RANDOM % ${#DEFAULT_DOMAINS[@]}]}"
  else
    DOMAIN="$USER_DOMAIN"
  fi
  ok "域名 / SNI: ${DOMAIN}"

  install_binary

  if want_proto hy2 || want_proto tuic || want_proto vless; then
    ensure_cert "$DOMAIN"
  fi

  prepare_all_secrets
  write_config
  write_service
  ensure_openrc_ready
  open_firewall
  start_service
  install_self
  print_summary_all "$(public_addr)"
}

cmd_status() {
  if service_is_active 2>/dev/null; then
    ok "${SERVICE_NAME}: 运行中"
  else
    warn "${SERVICE_NAME}: 未运行"
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    printf '  端口: %s\n' "$(existing_ports | tr '\n' ' ')"
  else
    printf '  状态: 未安装 (未找到 %s)\n' "$CONFIG_FILE"
  fi
}

cmd_info() {
  [[ -f "$CONFIG_FILE" ]] || die "未找到配置 ${CONFIG_FILE}, 请先运行部署"
  load_all_credentials
  print_summary_all "$(public_addr)"
}

usage_all() {
  cat <<'USAGE'
singbox_all.sh - 一键部署 sing-box 全协议服务端 (单进程 + 单合并配置)

架构: 只跑一个 sing-box 进程、注册一个服务(singbox-all),
      /etc/sing-box/all.json 里同时挂全部入站:
        MTPROXY 443/tcp / Hysteria2 443/udp / TUIC 8443/udp
        Shadowsocks 8388/tcp+udp / VLESS 8989/tcp / VMess 8990/tcp
      (443 的 TCP 与 UDP 互不冲突, 分别给 MT 与 HY2; TUIC 让出 443)

用法:
  sudo bash singbox_all.sh                    # 全部安装
  sudo PROTOCOLS=mt,hy2 bash singbox_all.sh   # 只启用指定协议(mt hy2 tuic ssr vless)
  sudo bash singbox_all.sh plan               # 只打印/校验端口计划, 不安装
  sudo bash singbox_all.sh status             # 查看服务状态与端口
  sudo bash singbox_all.sh info               # 重新打印全部凭据与链接
  sudo bash singbox_all.sh logs [N]           # 查看最近 N 行日志
  sudo bash singbox_all.sh uninstall          # 卸载
  sudo bash singbox_all.sh help               # 本帮助

端口环境变量 (显式指定才覆盖, 重装未指定则沿用上次实际端口):
  MT_PORT=443 HY2_PORT=443 TUIC_PORT=8443 SSR_PORT=8388 VLESS_PORT=8989 VMESS_PORT=8990

凭据环境变量 (缺省随机, 重装自动从合并配置复用):
  DOMAIN=www.bing.com                        # 全部 TLS 协议共用 SNI
  MT_USER_NAME=user1 MT_CONCURRENCY=8192 MT_AUTO_UPDATE=0
  HY2_PASSWORD=xxx HY2_OBFS=xxx              # OBFS 开启 salamander 混淆
  TUIC_UUID=xxx TUIC_PASSWORD=xxx TUIC_CONGESTION=bbr
  SSR_PASSWORD=xxx SSR_METHOD=aes-256-gcm
  VLESS_UUID=xxx VMESS_UUID=xxx VLESS_PATH=/vless VMESS_PATH=/vmess
  CERT_FILE=... KEY_FILE=...                 # 使用已有证书(不填则自签一份共用)

通用环境变量:
  SERVER_ADDR=1.2.3.4                        # 指定对外 IP
  MIRROR=https://ghfast.top/https://github.com
  SINGBOX_TAG=v1.14.1-extended-2.7.2         # 覆盖锁定的内核版本
  LOG_LEVEL=debug                            # 日志级别(默认 info)
  FORCE_BIN=1                                # 强制重新下载内核

跨系统支持:
  Debian/Ubuntu   systemd + apt,     防火墙 ufw / iptables
  CentOS/RHEL 系  systemd + dnf/yum, 防火墙 firewalld / iptables
  Alpine          OpenRC + apk,      防火墙 iptables(规则自动保存并开机恢复)
  旧版拆分的 singbox-mt/hy2/... 服务会在安装时自动迁移为单一 singbox-all。

端口冲突时: 会提示输入新端口, 10 秒不输入则自动挑一个不常用的可用端口
  (PORT_PROMPT_TIMEOUT=10 可改等待秒数)。
USAGE
}

main() {
  local action="${1:-install}"

  case "$action" in
    -h|--help|help) usage_all; return 0 ;;
  esac

  normalize_protocols

  case "$action" in
    plan) validate_plan; return 0 ;;
  esac

  check_root

  case "$action" in
    install)          do_install_all ;;
    status)           check_os; cmd_status ;;
    info)             check_os; cmd_info ;;
    logs)             check_os; service_logs "${2:-50}" ;;
    uninstall|remove) check_os; cmd_uninstall ;;
    *) die "未知命令: ${action} (可用: install / plan / status / info / uninstall / logs / help)" ;;
  esac
}

main "$@"

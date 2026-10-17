#!/usr/bin/env bash
#
# singbox_vless_vmess.sh - 在 Debian / Ubuntu / Alpine 上一键部署 VLESS + VMess 服务端
#
# 形态: VLESS over TLS + WebSocket 与 VMess over TLS + WebSocket。sing-box 每个
#       端口只能挂一个协议入站, 所以两个协议占两个端口。
#
# 端口分配规则:
#   指定 PORT      -> VLESS 用 PORT, VMess 自动用 PORT+1  (如 PORT=443 -> 443 / 444)
#   未指定 PORT    -> VLESS 用 8989, VMess 用 8990
#   指定 VMESS_PORT -> 覆盖 VMess 端口 (优先于 PORT+1)
#
# 用法:
#   sudo bash singbox_vless_vmess.sh                       # 8989 vless + 8990 vmess
#   sudo PORT=443 bash singbox_vless_vmess.sh              # 443 vless + 444 vmess
#   sudo PORT=443 VMESS_PORT=8443 bash singbox_vless_vmess.sh  # 分别指定
#   sudo bash singbox_vless_vmess.sh info                  # 重新打印凭据与链接
#   sudo bash singbox_vless_vmess.sh uninstall             # 卸载
#
# 环境变量:
#   PORT         VLESS 端口          默认 8989
#   VMESS_PORT   VMess 端口          默认 PORT+1 (PORT 未指定时为 8990)
#   UUID         VLESS UUID          默认随机
#   VMESS_UUID   VMess UUID          默认随机
#   DOMAIN       TLS 域名/SNI        默认从内置候选随机
#   VLESS_PATH   VLESS WS 路径       默认 /vless
#   VMESS_PATH   VMess WS 路径       默认 /vmess
#   CERT_FILE    TLS 证书路径        默认 /etc/sing-box/cert.pem(不存在则自签)
#   KEY_FILE     TLS 私钥路径        默认 /etc/sing-box/key.pem
#   SERVER_ADDR  对外 IP             默认自动探测
#   MIRROR       GitHub 加速前缀     默认空(自动回退内置镜像)
#   SINGBOX_TAG  sing-box 版本 tag   默认锁定的 v1.14.1-extended-2.7.2
#
set -euo pipefail

# ---------------------------------------------------------------- 元信息 ----
SERVICE_NAME="singbox-vless"
SERVICE_DESC="sing-box VLESS + VMess Server (extended)"
SHORT_NAME="vless"
PROC_LABEL="VLESS + VMess"
CONFIG_FILE="/etc/sing-box/vless_vmess.json"
RAW_FILE="singbox_vless_vmess.sh"

NEED_CERT=1
NEED_DOMAIN=1
PORT_SPECS=("PORT:tcp" "VMESS_PORT:tcp")
PORT_DEFAULTS="PORT=8989"

PORT="${PORT:-}"
VMESS_PORT="${VMESS_PORT:-}"   # 留空表示待推导, 由 port_defaults_hook 决定
UUID="${UUID:-}"
VMESS_UUID="${VMESS_UUID:-}"
DOMAIN="${DOMAIN:-}"
VLESS_PATH="${VLESS_PATH:-/vless}"
VMESS_PATH="${VMESS_PATH:-/vmess}"

# @@LIB@@

# ---------------------------------------------------------------- 端口 ------
port_defaults_hook() {
  [[ -n "$VMESS_PORT" ]] && return 0
  [[ "$PORT" =~ ^[0-9]+$ ]] || return 0     # 非数字交给通用校验报错
  local p
  p="$((10#$PORT))"
  ((p <= 65534)) || die "PORT=65535 时无法自动分配 VMess 端口, 请显式指定 VMESS_PORT"
  VMESS_PORT=$((p + 1))
  info "未指定 VMESS_PORT, VMess 端口自动设为 PORT+1 = ${VMESS_PORT}"
}

port_validate_hook() {
  [[ "$PORT" != "$VMESS_PORT" ]] \
    || die "VLESS 与 VMess 不能用同一个端口 (sing-box 每端口只能一个入站)"
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
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}"
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
    },
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
  # 重装时复用旧 UUID, 否则已有客户端会全部失效
  [[ -n "$UUID" ]] || UUID="$(config_pick inbounds.0.users.0.uuid)"
  [[ -n "$VMESS_UUID" ]] || VMESS_UUID="$(config_pick inbounds.1.users.0.uuid)"
  [[ -n "$UUID" ]] || UUID="$(gen_uuid)"
  [[ -n "$VMESS_UUID" ]] || VMESS_UUID="$(gen_uuid)"
  ok "VLESS UUID: ${UUID}"
  ok "VMess UUID: ${VMESS_UUID}"
}

load_credentials() {
  local uuids=() ports=()
  while IFS= read -r line; do [[ -n "$line" ]] && uuids+=("$line"); done \
    < <(json_get_all "$CONFIG_FILE" uuid | tr -d '\r')
  while IFS= read -r line; do [[ -n "$line" ]] && ports+=("$line"); done \
    < <(json_get_all "$CONFIG_FILE" listen_port | tr -d '\r')

  UUID="${uuids[0]:-}"
  VMESS_UUID="${uuids[1]:-}"
  PORT="${ports[0]:-8989}"
  VMESS_PORT="${ports[1]:-}"
  [[ -n "$VMESS_PORT" ]] || VMESS_PORT=$((PORT + 1))
  DOMAIN="$(json_get "$CONFIG_FILE" server_name)"
  [[ -n "$UUID" && -n "$VMESS_UUID" ]] || die "配置中未解析到两个 UUID"
}

# ---------------------------------------------------------------- 链接 ------
build_vless_link() {
  local server="$1"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s&allowInsecure=1#vless-%s' \
    "$UUID" "$server" "$PORT" "$DOMAIN" "$DOMAIN" \
    "$(printf '%s' "$VLESS_PATH" | sed 's|/|%2F|g')" "$PORT"
}

build_vmess_link() {
  local server="$1" json
  # allowInsecure=1: 自签证书需跳过校验, 与 VLESS 链接保持一致; 不加则 TLS 握手直接失败
  json="$(printf '{"v":"2","ps":"vmess-%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","alpn":"http/1.1","fp":"chrome","allowInsecure":"1"}' \
    "$VMESS_PORT" "$server" "$VMESS_PORT" "$VMESS_UUID" "$DOMAIN" "$VMESS_PATH" "$DOMAIN")"
  printf 'vmess://%s' "$(printf '%s' "$json" | base64 | tr -d '\r\n')"
}

print_summary() {
  local server="$1" vless_link vmess_link
  vless_link="$(build_vless_link "$server")"
  vmess_link="$(build_vmess_link "$server")"

  echo
  hr
  printf '%s  VLESS + VMess 部署完成%s\n' "$C_BLD$C_GRN" "$C_RST"
  hr
  printf '  服务器 IP   : %s\n' "$server"
  printf '  SNI / 域名  : %s\n' "$DOMAIN"
  printf '  证书        : %s (自签, 客户端需跳过校验)\n' "$CERT_FILE"
  printf '  配置文件    : %s\n' "$CONFIG_FILE"
  printf '  二进制      : %s\n' "$BIN_PATH"
  printf '  服务名      : %s\n' "$SERVICE_NAME"
  echo
  printf '  %s\n' "VLESS  : ${PORT}/tcp  TLS + WS  路径 ${VLESS_PATH}"
  printf '  %s\n' "VMess  : ${VMESS_PORT}/tcp  TLS + WS  路径 ${VMESS_PATH}"
  printf '  UUID   : %s\n' "$UUID"
  printf '  V-UUID : %s\n' "$VMESS_UUID"
  echo
  printf '%s  VLESS 链接%s\n' "$C_BLD" "$C_RST"
  printf '%s\n' "$vless_link"
  echo
  printf '%s  VMess 链接%s\n' "$C_BLD" "$C_RST"
  printf '%s\n' "$vmess_link"
  echo
  printf '  客户端记得开启 "允许不安全证书 / allowInsecure"。\n'
  print_manage_block
}

# ---------------------------------------------------------------- 帮助 ------
usage() {
  cat <<'USAGE'
singbox_vless_vmess.sh - 一键部署 VLESS + VMess 服务端 (sing-box-extended)

用法:
  sudo bash singbox_vless_vmess.sh             # 安装 (vless 8989 / vmess 8990)
  sudo PORT=443 bash singbox_vless_vmess.sh    # 安装 (vless 443 / vmess 444)
  sudo bash singbox_vless_vmess.sh info        # 查看凭据与链接
  sudo bash singbox_vless_vmess.sh uninstall   # 卸载
  sudo bash singbox_vless_vmess.sh logs        # 查看最近日志
  sudo bash singbox_vless_vmess.sh help        # 本帮助

端口规则:
  PORT=8989                       # VLESS 端口; VMess 自动取 PORT+1
  VMESS_PORT=8990                 # 单独覆盖 VMess 端口 (优先于 PORT+1)

常用自定义 (环境变量):
  UUID=xxx VMESS_UUID=yyy                    # 用户 UUID
  DOMAIN=www.bing.com                        # TLS 域名 / SNI
  VLESS_PATH=/vless VMESS_PATH=/vmess        # WS 路径
  CERT_FILE=... KEY_FILE=...                 # 使用已有证书(不填则自签)
  SERVER_ADDR=1.2.3.4                        # 指定对外 IP
  MIRROR=https://ghfast.top/https://github.com
  SINGBOX_TAG=v1.14.1-extended-2.7.2         # 覆盖锁定的内核版本
  LOG_LEVEL=debug                      # 日志级别(默认 info)
  FORCE_BIN=1                          # 强制重新下载内核

端口冲突时: 会提示输入新端口, 10 秒不输入则自动挑一个不常用的可用端口
  (PORT_PROMPT_TIMEOUT=10 可改等待秒数)
USAGE
}

main "$@"

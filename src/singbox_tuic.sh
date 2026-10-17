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

# @@LIB@@

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

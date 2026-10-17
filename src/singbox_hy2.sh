#!/usr/bin/env bash
#
# singbox_hy2.sh - 在 Debian / Ubuntu / Alpine 上一键部署 Hysteria2 服务端
#
# 特性: QUIC(UDP) + 自签 TLS 证书 + 可选 salamander 混淆, 输出 hysteria2:// 链接。
#
# 用法:
#   sudo bash singbox_hy2.sh                            # 默认 443/udp, 随机密码
#   sudo PORT=8443 DOMAIN=www.bing.com bash singbox_hy2.sh
#   sudo OBFS=myobfs bash singbox_hy2.sh                # 开启 salamander 混淆
#   sudo bash singbox_hy2.sh info                       # 重新打印凭据与链接
#   sudo bash singbox_hy2.sh uninstall                  # 卸载
#
# 环境变量:
#   PORT         监听端口            默认 443 (udp)
#   PASSWORD     认证密码            默认随机
#   OBFS         salamander 混淆密码 默认空(不启用)
#   DOMAIN       TLS 域名 / SNI      默认从内置候选随机
#   CERT_FILE    TLS 证书路径        默认 /etc/sing-box/cert.pem(不存在则自签)
#   KEY_FILE     TLS 私钥路径        默认 /etc/sing-box/key.pem
#   SERVER_ADDR  对外 IP             默认自动探测
#   MIRROR       GitHub 加速前缀     默认空(自动回退内置镜像)
#   SINGBOX_TAG  sing-box 版本 tag   默认锁定的 v1.14.1-extended-2.7.2
#
set -euo pipefail

# ---------------------------------------------------------------- 元信息 ----
SERVICE_NAME="singbox-hy2"
SERVICE_DESC="sing-box Hysteria2 Server (extended)"
SHORT_NAME="hy2"
PROC_LABEL="Hysteria2"
CONFIG_FILE="/etc/sing-box/hy2.json"
RAW_FILE="singbox_hy2.sh"

NEED_CERT=1
NEED_DOMAIN=1
PORT_SPECS=("PORT:udp")

PORT="${PORT:-443}"
PASSWORD="${PASSWORD:-}"
OBFS="${OBFS:-}"
DOMAIN="${DOMAIN:-}"

# @@LIB@@

# ---------------------------------------------------------------- 配置 ------
render_config() {
  local obfs_block=""
  if [[ -n "$OBFS" ]]; then
    obfs_block="      \"obfs\": {
        \"type\": \"salamander\",
        \"password\": \"${OBFS}\"
      },
"
  fi

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
}

# ---------------------------------------------------------------- 凭据 ------
prepare_secrets() {
  [[ -n "$PASSWORD" ]] || PASSWORD="$(rand_token 16)"
  ok "密码: ${PASSWORD}"
  [[ -z "$OBFS" ]] || ok "混淆: salamander"
}

load_credentials() {
  PASSWORD="$(json_get "$CONFIG_FILE" password)"
  PORT="$(json_get "$CONFIG_FILE" listen_port)"
  DOMAIN="$(json_get "$CONFIG_FILE" server_name)"
  [[ -n "$PASSWORD" ]] || die "配置中未解析到 password"
  PORT="${PORT:-443}"

  # 混淆密码和用户密码同名, 只在启用混淆时按 salamander 定位
  if grep -q '"salamander"' "$CONFIG_FILE"; then
    OBFS="$(awk '/salamander/{f=1} f && /"password"/ {gsub(/.*:[[:space:]]*"|".*/, ""); print; exit}' \
      "$CONFIG_FILE")"
  else
    OBFS=""
  fi
}

# ---------------------------------------------------------------- 输出 ------
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
  print_manage_block
}

# ---------------------------------------------------------------- 帮助 ------
usage() {
  cat <<'USAGE'
singbox_hy2.sh - 一键部署 Hysteria2 服务端 (sing-box-extended)

用法:
  sudo bash singbox_hy2.sh             # 安装 (默认 443/udp)
  sudo bash singbox_hy2.sh info        # 查看凭据与链接
  sudo bash singbox_hy2.sh uninstall   # 卸载
  sudo bash singbox_hy2.sh logs        # 查看最近日志
  sudo bash singbox_hy2.sh help        # 本帮助

常用自定义 (环境变量):
  PORT=8443 DOMAIN=www.bing.com        # 端口与 SNI
  OBFS=myobfs                          # 开启 salamander 混淆
  CERT_FILE=... KEY_FILE=...           # 使用已有证书(不填则自签)
  SERVER_ADDR=1.2.3.4                  # 指定对外 IP
  MIRROR=https://ghfast.top/https://github.com
  SINGBOX_TAG=v1.14.1-extended-2.7.2   # 覆盖锁定的内核版本
USAGE
}

main "$@"

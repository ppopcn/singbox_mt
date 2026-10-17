#!/usr/bin/env bash
#
# singbox_ssr.sh - 在 Debian / Ubuntu / Alpine 上一键部署 Shadowsocks 服务端
#
# 说明: sing-box 并不实现 ShadowsocksR(SSR), 这里部署的是 Shadowsocks AEAD
#       aes-256-gcm, 客户端请选 "Shadowsocks" 而不是 "ShadowsocksR"。
#
# 用法:
#   sudo bash singbox_ssr.sh                     # 默认 8388 (TCP+UDP)
#   sudo PORT=8443 PASSWORD=mypass bash singbox_ssr.sh
#   sudo bash singbox_ssr.sh info                # 重新打印凭据与链接
#   sudo bash singbox_ssr.sh uninstall           # 卸载
#
# 环境变量:
#   PORT         监听端口            默认 8388 (tcp+udp)
#   PASSWORD     连接密码            默认随机
#   METHOD       加密方式            默认 aes-256-gcm
#   SERVER_ADDR  对外 IP             默认自动探测
#   MIRROR       GitHub 加速前缀     默认空(自动回退内置镜像)
#   SINGBOX_TAG  sing-box 版本 tag   默认锁定的 v1.14.1-extended-2.7.2
#
set -euo pipefail

# ---------------------------------------------------------------- 元信息 ----
SERVICE_NAME="singbox-ssr"
SERVICE_DESC="sing-box Shadowsocks Server (extended)"
SHORT_NAME="ssr"
PROC_LABEL="Shadowsocks (AEAD)"
CONFIG_FILE="/etc/sing-box/ssr.json"
RAW_FILE="singbox_ssr.sh"

NEED_CERT=0
NEED_DOMAIN=0
PORT_SPECS=("PORT:tcp,udp")
PORT_DEFAULTS="PORT=8388"

PORT="${PORT:-}"
PASSWORD="${PASSWORD:-}"
METHOD="${METHOD:-aes-256-gcm}"

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
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${PORT},
      "network": [
        "tcp",
        "udp"
      ],
      "method": "${METHOD}",
      "password": "${PASSWORD}"
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
  # 重装时复用旧凭据, 否则已有客户端会全部失效
  [[ -n "$PASSWORD" ]] || PASSWORD="$(config_pick inbounds.0.password)"
  [[ -n "$PASSWORD" ]] || PASSWORD="$(rand_token 16)"
  ok "密码: ${PASSWORD}"
}

load_credentials() {
  PASSWORD="$(json_get "$CONFIG_FILE" password)"
  METHOD="$(json_get "$CONFIG_FILE" method)"
  PORT="$(json_get "$CONFIG_FILE" listen_port)"
  [[ -n "$PASSWORD" ]] || die "配置中未解析到密码"
  METHOD="${METHOD:-aes-256-gcm}"
  PORT="${PORT:-8388}"
}

# ---------------------------------------------------------------- 输出 ------
print_summary() {
  local server="$1" userinfo link
  userinfo="$(printf '%s:%s' "$METHOD" "$PASSWORD" | base64 | tr -d '\r\n=' | tr '+/' '-_')"
  link="ss://${userinfo}@${server}:${PORT}#ss-${PORT}"

  echo
  hr
  printf '%s  Shadowsocks (AEAD) 部署完成%s\n' "$C_BLD$C_GRN" "$C_RST"
  hr
  printf '  服务器 IP   : %s\n' "$server"
  printf '  端口        : %s\n' "$PORT"
  printf '  加密方式    : %s\n' "$METHOD"
  printf '  密码        : %s\n' "$PASSWORD"
  printf '  配置文件    : %s\n' "$CONFIG_FILE"
  printf '  二进制      : %s\n' "$BIN_PATH"
  printf '  服务名      : %s\n' "$SERVICE_NAME"
  echo
  printf '%s  客户端参数%s\n' "$C_BLD" "$C_RST"
  printf '  地址 / 端口 : %s / %s\n' "$server" "$PORT"
  printf '  加密 / 密码 : %s / %s\n' "$METHOD" "$PASSWORD"
  echo
  printf '%s  ss:// 链接 (SIP002)%s\n' "$C_BLD" "$C_RST"
  printf '%s\n' "$link"
  echo
  printf '  客户端请选 "Shadowsocks", 不是 "ShadowsocksR"。\n'
  print_manage_block
}

# ---------------------------------------------------------------- 帮助 ------
usage() {
  cat <<'USAGE'
singbox_ssr.sh - 一键部署 Shadowsocks (aes-256-gcm) 服务端

用法:
  sudo bash singbox_ssr.sh             # 安装 (默认 8388, TCP+UDP)
  sudo bash singbox_ssr.sh info        # 查看凭据与链接
  sudo bash singbox_ssr.sh uninstall   # 卸载
  sudo bash singbox_ssr.sh logs        # 查看最近日志
  sudo bash singbox_ssr.sh help        # 本帮助

常用自定义 (环境变量):
  PORT=8388                                  # 监听端口
  PASSWORD=xxx METHOD=aes-256-gcm            # 密码与加密方式
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

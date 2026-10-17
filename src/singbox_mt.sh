#!/usr/bin/env bash
#
# singbox_mt.sh - 在 Debian / Ubuntu / Alpine 上一键部署 sing-box-extended MTPROXY 服务端
#
# 项目: https://github.com/shtorm-7/sing-box-extended
# 功能: 自动检测架构与发行版 -> 复用或下载预编译二进制 -> 生成 ee(FakeTLS) secret
#       -> 写入配置 -> 注册服务(systemd / OpenRC) -> 启动 -> 输出 t.me 代理链接
#
# 支持系统:
#   Debian 系  Debian / Ubuntu / 衍生版    服务用 systemd, 包管理 apt
#   Alpine 系  Alpine Linux                服务用 OpenRC, 包管理 apk
#
# 用法:
#   bash singbox_mt.sh                        # 默认端口 443, 随机伪装域名
#   PORT=8443 bash singbox_mt.sh              # 自定义端口
#   DOMAIN=www.google.com bash singbox_mt.sh  # 自定义伪装域名
#   bash singbox_mt.sh uninstall              # 卸载
#   bash singbox_mt.sh info                   # 查看当前配置与链接
#
# 环境变量:
#   PORT          监听端口            默认 443
#   DOMAIN        FakeTLS 伪装域名    默认从内置候选里随机选
#   SERVER_ADDR   强制指定对外 IP     默认自动探测
#   USER_NAME     MTPROXY 用户名      默认 user1
#   CONCURRENCY   并发上限            默认 8192
#   AUTO_UPDATE   自动更新 Telegram DC 列表  默认 0(关闭, 启动更快、更稳)
#   MIRROR        GitHub 加速前缀     默认空(会自动回退内置镜像)
#   SINGBOX_TAG   sing-box 版本 tag   默认锁定的 v1.14.1-extended-2.7.2
#
set -euo pipefail

# ---------------------------------------------------------------- 元信息 ----
SERVICE_NAME="singbox-mt"
SERVICE_DESC="sing-box MTPROXY Server (extended)"
SHORT_NAME="mt"
PROC_LABEL="MTPROXY"
CONFIG_FILE="/etc/sing-box/mtproxy.json"
RAW_FILE="singbox_mt.sh"

NEED_CERT=0
NEED_DOMAIN=1
PORT_SPECS=("PORT:tcp")

PORT="${PORT:-443}"
DOMAIN="${DOMAIN:-}"
USER_NAME="${USER_NAME:-user1}"
CONCURRENCY="${CONCURRENCY:-8192}"
AUTO_UPDATE="${AUTO_UPDATE:-0}"

SECRET=""

# @@LIB@@

# -------------------------------------------------------------- secret ------
# mtg 的 secret 字节布局 (见 mtglib/secret.go Set/GenerateSecret):
#   [0xee][16 字节随机 key][hostname 明文 latin1]
#   整个字节串以 hex 序列化输出。
gen_secret() {
  local domain="$1" key_hex
  key_hex="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf 'ee%s' "$key_hex"
  printf '%s' "$domain" | od -An -tx1 | tr -d ' \n'
}

# ---------------------------------------------------------------- 配置 ------
render_config() {
  local auto_update_json
  if [[ "$AUTO_UPDATE" == "1" ]]; then
    auto_update_json="true"
  else
    auto_update_json="false"
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
      "type": "mtproxy",
      "tag": "mtp-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "${USER_NAME}",
          "secret": "${SECRET}"
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
}

# ---------------------------------------------------------------- 凭据 ------
prepare_secrets() {
  SECRET="$(gen_secret "$DOMAIN")"
  [[ ${#SECRET} -gt 34 ]] || die "secret 生成异常: ${SECRET}"
  ok "secret 已生成 (长度 ${#SECRET})"
}

load_credentials() {
  SECRET="$(json_get "$CONFIG_FILE" secret)"
  [[ -n "$SECRET" ]] || die "配置中未解析到 secret"
  PORT="$(json_get "$CONFIG_FILE" listen_port)"
  USER_NAME="$(json_get "$CONFIG_FILE" name)"
  PORT="${PORT:-443}"
  USER_NAME="${USER_NAME:-user1}"
}

# ------------------------------------------------------------ 启动前探测 ----
# auto_update 开启时会拉取 Telegram DC 列表, 出口被限制时会拖慢启动;
# 先探测一次, 不通就临时关掉, 保证服务能立刻起来
probe_upstream() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 8 bash -c 'exec 3<>/dev/tcp/core.telegram.org/443' 2>/dev/null
  else
    bash -c 'exec 3<>/dev/tcp/core.telegram.org/443' 2>/dev/null
  fi
}

pre_start_hook() {
  [[ "$AUTO_UPDATE" == "1" ]] || return 0
  info "检测到 Telegram DC 更新源连通性..."
  if probe_upstream; then
    ok "上游可达, 保留 auto_update"
  else
    warn "无法连接 core.telegram.org, 本次自动关闭 auto_update (不影响代理功能)"
    sed -i 's/"auto_update": true/"auto_update": false/' "$CONFIG_FILE"
  fi
}

# ---------------------------------------------------------------- 输出 ------
build_link() {
  local server="$1"
  printf 'https://t.me/proxy?server=%s&port=%s&secret=%s' "$server" "$PORT" "$SECRET"
}

print_summary() {
  local server="$1" link
  link="$(build_link "$server")"

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
  printf '  初始化系统  : %s\n' "$INIT_SYSTEM"
  echo
  printf '%s  Telegram 代理链接:%s\n' "$C_BLD" "$C_RST"
  printf '%s\n' "$link"
  echo
  printf '  丢浏览器打开或发给 Telegram 好友即可导入。\n'
  print_manage_block
}

# ---------------------------------------------------------------- 帮助 ------
usage() {
  cat <<'USAGE'
singbox_mt.sh - 一键部署 MTPROXY 服务端 (sing-box-extended)

用法:
  bash singbox_mt.sh             # 安装 (默认 443, 随机伪装域名)
  bash singbox_mt.sh info        # 查看配置与链接
  bash singbox_mt.sh uninstall   # 卸载
  bash singbox_mt.sh logs        # 查看最近日志
  bash singbox_mt.sh help        # 本帮助

常用自定义 (环境变量):
  PORT=443                                   # 监听端口
  DOMAIN=www.google.com                      # FakeTLS 伪装域名
  USER_NAME=user1 CONCURRENCY=8192           # 用户名与并发上限
  AUTO_UPDATE=1                              # 启动时更新 Telegram DC 列表
  SERVER_ADDR=1.2.3.4                        # 指定对外 IP
  MIRROR=https://ghfast.top/https://github.com
  SINGBOX_TAG=v1.14.1-extended-2.7.2         # 覆盖锁定的内核版本
USAGE
}

main "$@"

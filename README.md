# singbox_mt

在 Debian / Ubuntu / Alpine 上**一键部署 MTPROXY 服务端**的 Shell 脚本，基于 [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended)（sing-box 的增强分支）。

运行一条命令，脚本会自动完成：识别发行版与架构 → 下载官方预编译二进制 → 生成 FakeTLS secret → 写配置 → 注册服务 → 启动 → 输出 Telegram 代理链接。

```bash
bash singbox_mt.sh
```

输出形如：

```
https://t.me/proxy?server=1.2.3.4&port=443&secret=ee13c2...777772e636c6f7564666c6172652e636f6d
```

把这个链接发给 Telegram 联系人，或直接在手机浏览器打开，即可导入代理。

## 为什么用它

官方 sing-box 没有 MTPROXY 入站。这个脚本用的是 `sing-box-extended`，它额外提供了 `mtproxy` 入站（底层是 [mtg-multi](https://github.com/dolonet/mtg-multi) 内核），同时保留了 sing-box 全套路由与出站能力。

相比直接部署 mtg，好处是：**Telegram 流量出来之后怎么走，由 sing-box 的 `outbounds` 和 `route` 决定**——可以走 WARP、可以多链路聚合、也可以按规则分流。

## 环境要求

脚本会自动识别发行版族，走对应的包管理与服务管理路径。

| 项目 | Debian 系 | Alpine 系 |
|---|---|---|
| 发行版 | Debian 10+ / Ubuntu 18.04+ / 衍生版 | Alpine 3.16+ |
| 包管理 | `apt` | `apk` |
| 服务管理 | `systemd` | `OpenRC` |
| 自动补装依赖 | curl、tar、iproute2 | bash、curl、openrc、iproute2 |
| 架构 | amd64 / arm64 / armv7 / armv6 / 386 / riscv64 / loong64 / mips 系列 | 同左 |

其他要求：root 权限。

> **Alpine 用户注意**：Alpine 默认没有 bash。脚本第一行是 `#!/usr/bin/env bash`，所以必须用 `bash singbox_mt.sh` 调用（脚本会自动 `apk add bash`），不能直接 `./singbox_mt.sh`，也不能用 `sh` 执行。

## 用法

### 快速开始

```bash
bash singbox_mt.sh
```

默认行为：监听 `443`、用户名 `user1`、FakeTLS 模式、伪装域名从内置候选里随机挑一个。

### 自定义参数

所有参数通过环境变量传入：

```bash
# 换端口
PORT=8443 bash singbox_mt.sh

# 指定伪装域名
DOMAIN=www.bing.com bash singbox_mt.sh

# 组合使用，并指定对外 IP（自动探测失败时用）
PORT=8443 DOMAIN=www.apple.com SERVER_ADDR=1.2.3.4 bash singbox_mt.sh
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `443` | 监听端口（TCP） |
| `DOMAIN` | 随机 | FakeTLS 伪装域名，需支持 TLS 1.3 |
| `SERVER_ADDR` | 自动探测 | 生成链接时使用的对外 IP |
| `USER_NAME` | `user1` | MTPROXY 用户名 |
| `CONCURRENCY` | `8192` | 连接并发上限 |
| `AUTO_UPDATE` | `0` | 是否自动更新 Telegram DC 列表 |
| `MIRROR` | 空 | GitHub 加速前缀，如 `https://ghfast.top/https://github.com` |

### 其他命令

```bash
bash singbox_mt.sh info        # 重新打印配置与链接
bash singbox_mt.sh uninstall   # 卸载（KEEP_CONFIG=1 可保留配置）
bash singbox_mt.sh help        # 查看帮助
```

## 其他协议脚本

除 MTPROXY 外，仓库还提供四个独立脚本。骨架与 `singbox_mt.sh` 一致（下载 sing-box-extended → SHA256 校验 → 写配置并 `sing-box check` → 注册服务 → 放行防火墙 → 输出客户端链接），差别只在协议入站配置。

| 脚本 | 协议 | 默认端口 | 输出链接 |
|---|---|---|---|
| `singbox_ssr.sh` | Shadowsocks `aes-256-gcm` | `8388`（TCP+UDP） | `ss://` |
| `singbox_hy2.sh` | Hysteria2（QUIC） | `443/udp` | `hysteria2://` |
| `singbox_tuic.sh` | TUIC v5（QUIC） | `443/udp` | `tuic://` |
| `singbox_vless_vmess.sh` | VLESS + VMess（TLS+WS） | `8989` + `8990` | `vless://`、`vmess://` |

四个脚本都支持 `install`（默认）/ `info` / `uninstall` / `help`，也可一行部署：

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_hy2.sh | sudo bash
curl -fsSL .../singbox_hy2.sh | sudo bash -s -- info
curl -fsSL .../singbox_hy2.sh | sudo bash -s -- uninstall
```

> 这四个脚本目前用 **systemd** 托管，仅支持 Debian / Ubuntu 系；Alpine / OpenRC 支持目前只在 `singbox_mt.sh` 上实现。

### singbox_ssr.sh — Shadowsocks

一行部署：

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_ssr.sh | sudo bash
```

> sing-box 没有实现 ShadowsocksR（SSR）协议，本脚本部署的是 **Shadowsocks AEAD `aes-256-gcm`**。客户端请选择 "Shadowsocks"，不要选 "ShadowsocksR"。

单端口 TCP + UDP，输出 SIP002 格式的 `ss://` 链接（`base64url(method:password)@ip:port`）。

```bash
sudo bash singbox_ssr.sh
sudo PORT=8443 PASSWORD=mypass bash singbox_ssr.sh
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `8388` | 监听端口（TCP + UDP） |
| `PASSWORD` | 随机 | 连接密码（16 字节 base64url） |
| `METHOD` | `aes-256-gcm` | 加密方式 |
| `SERVER_ADDR` | 自动探测 | 对外 IP |

### singbox_hy2.sh — Hysteria2

一行部署：

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_hy2.sh | sudo bash
```

QUIC（UDP）入站，自签 TLS 证书 + 可选 salamander 混淆，并带一个伪装站点（`masquerade`）用于抵抗探测。

```bash
sudo bash singbox_hy2.sh
sudo PORT=8443 DOMAIN=www.bing.com bash singbox_hy2.sh
sudo OBFS=myobfs bash singbox_hy2.sh        # 开启 salamander 混淆
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `443` | 监听端口（UDP） |
| `PASSWORD` | 随机 | 认证密码 |
| `DOMAIN` | 随机 | TLS 域名 / SNI |
| `OBFS` | 空 | salamander 混淆密码，空则不启用 |
| `CERT_FILE` / `KEY_FILE` | `/etc/sing-box/cert.pem`、`key.pem` | 不存在则自签 |

生成的链接形如：

```
hysteria2://PASSWORD@1.2.3.4:443/?sni=www.bing.com&insecure=1#hy2-443
```

自签证书必须让客户端跳过校验（`insecure` / `allowInsecure`）。想用正规证书，把 `CERT_FILE` / `KEY_FILE` 指向已有文件即可。

### singbox_tuic.sh — TUIC v5

一行部署：

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_tuic.sh | sudo bash
```

QUIC（UDP）入站，默认 BBR 拥塞控制，UUID + 密码双认证，同样支持自签或复用已有证书。

```bash
sudo bash singbox_tuic.sh
sudo CONGESTION=cubic bash singbox_tuic.sh
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `443` | 监听端口（UDP） |
| `UUID` | 随机 | 用户 UUID |
| `PASSWORD` | 随机 | 认证密码 |
| `DOMAIN` | 随机 | TLS 域名 / SNI |
| `CONGESTION` | `bbr` | 拥塞控制（`bbr` / `cubic` / `new_reno`） |
| `CERT_FILE` / `KEY_FILE` | 同 hy2 | 不存在则自签 |

生成的链接形如：

```
tuic://UUID:PASSWORD@1.2.3.4:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&allow_insecure=1&allowInsecure=1#tuic-443
```

### singbox_vless_vmess.sh — VLESS + VMess

一行部署：

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_vless_vmess.sh | sudo bash
```

VLESS 与 VMess 都走 **TLS + WebSocket**，路径分别是 `/vless` 和 `/vmess`。

> sing-box 的一个端口只能挂一个协议入站，所以两个协议用两个端口。**端口分配规则**：指定 `PORT` 时 VLESS 用 `PORT`、VMess 自动用 `PORT+1`（如 `PORT=443` → `443` + `444`）；都不指定时用 `8989` + `8990`；`VMESS_PORT` 可单独覆盖 VMess 端口。如果一定要单端口，需要前面再挂 nginx/caddy 按 WS 路径分流，本脚本不做这层。

```bash
sudo bash singbox_vless_vmess.sh              # 8989 + 8990
sudo PORT=443 bash singbox_vless_vmess.sh     # 443  + 444
sudo PORT=443 VMESS_PORT=8443 bash singbox_vless_vmess.sh   # 443 + 8443
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `8989` | VLESS 端口 |
| `VMESS_PORT` | `PORT+1`（`PORT` 未指定时为 `8990`） | VMess 端口，显式指定时优先 |
| `UUID` / `VMESS_UUID` | 随机 | 各自的用户 UUID |
| `DOMAIN` | 随机 | TLS 域名 / SNI |
| `VLESS_PATH` / `VMESS_PATH` | `/vless`、`/vmess` | WS 路径 |
| `CERT_FILE` / `KEY_FILE` | 同 hy2 | 不存在则自签 |

输出两条链接：

```
vless://UUID@1.2.3.4:8989?encryption=none&security=tls&sni=www.bing.com&fp=chrome&type=ws&host=www.bing.com&path=%2Fvless&allowInsecure=1#vless-8989

vmess://eyJ2IjoiMiIsInBzIjoi...
```

> 自签证书必须跳过校验，两条链接里已经带上：VLESS 用 `allowInsecure=1`，VMess 的 JSON 里有 `"allowInsecure":"1"`。若客户端仍提示证书错误，手动打开「允许不安全证书」即可。

客户端记得打开「允许不安全证书」。

## 部署后

服务名统一为 `singbox-mt`，但管理命令按系统不同：

> 其他协议脚本的服务名分别是 `singbox-ssr` / `singbox-hy2` / `singbox-tuic` / `singbox-vless`，把下面命令里的 `singbox-mt` 换掉即可。

**Debian（systemd）**

```bash
systemctl status singbox-mt     # 查看状态
systemctl restart singbox-mt    # 重启
systemctl stop singbox-mt       # 停止
journalctl -u singbox-mt -f     # 实时日志
```

**Alpine（OpenRC）**

```bash
rc-service singbox-mt status    # 查看状态
rc-service singbox-mt restart   # 重启
rc-service singbox-mt stop      # 停止
tail -f /var/log/singbox-mt.log # 实时日志
```

文件位置：

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/sing-box` | 二进制 |
| `/etc/sing-box/mtproxy.json` | 配置文件（权限 600） |
| `/etc/systemd/system/singbox-mt.service` | Debian 服务单元 |
| `/etc/init.d/singbox-mt` | Alpine OpenRC 服务脚本 |
| `/var/log/singbox-mt.log` | Alpine 日志 |

修改配置后重启服务生效。若改了 `secret` 或端口，别忘了重新生成链接（`info` 命令会用当前配置重新打印）。

## 关于 secret

本项目使用 **FakeTLS 模式**（`ee` 前缀），这是 mtg 的推荐做法，能抵御针对流量长度的统计分析。

secret 的字节布局是：

```
[0xee] [16 字节随机密钥] [域名明文 ASCII]
```

整个字节串以 hex 序列化。脚本据此生成，例如伪装 `www.cloudflare.com`：

```
ee + 32位hex + "www.cloudflare.com" 的hex
```

> 注意：mtg 只接受 `ee` 前缀。`dd` 前缀与无前缀形式属于历史遗留，当前版本会直接报 `incorrect first byte of secret` 拒绝加载。

## 常见问题

**链接能生成但连不上？**

脚本只负责服务端。客户端到服务器的网络路径不在它的管辖范围内——如果服务器 IP 本身无法被 Telegram 直连，链接再正确也连不通。这种情况下需要额外加一层前置。

**启动日志里没有报错，但也没连上？**

先确认防火墙。脚本会自动放行 ufw / firewalld，但**云厂商的安全组需要你手动开**（TCP 端口）。

**国内机器下载很慢或失败？**

脚本已内置两个镜像自动回退（`ghfast.top`、`gh-proxy.com`），直连失败会自动尝试。也可以手动指定：

```bash
MIRROR=https://ghfast.top/https://github.com bash singbox_mt.sh
```

**`auto_update` 要不要开？**

默认关闭。开启后会从 `core.telegram.org` 拉取 DC 列表，若出口网络受限会导致启动等待超时。脚本在 `AUTO_UPDATE=1` 时会先做连通性探测，不通则自动降级。

**FakeTLS 伪装域名怎么选？**

选一个**支持 TLS 1.3 且在你的服务器所在网络可正常访问**的大站。域名和客户端实际访问的目标不一致会影响伪装效果，客户端侧配置需与此保持一致。

**Alpine 上 `rc-service stop` 卡住或停止不干净？**

已知问题：sing-box 收到 SIGTERM 后可能长时间不退出。脚本为 OpenRC 写入了自定义 `stop()`：先发 SIGTERM 等最多 10 秒，仍未退出则自动 SIGKILL，并清理 pidfile。Debian 侧则由 systemd 的 `TimeoutStopSec=15` 兜底。

**Alpine 上服务起不来，提示 openrc 未启动？**

如果在容器或 chroot 里运行，OpenRC 需要先标记软运行级别：`mkdir -p /run/openrc && touch /run/openrc/softlevel`。真实 Alpine 系统（PID 1 为 openrc-init）不需要这步。

## 已验证

在 `v1.14.1-extended-2.7.2` 上实测：

- SHA256 校验与 Release 摘要一致
- 官方包自带 `with_mtproxy` 标签，无需自编译
- **二进制为静态链接**，glibc 与 musl 变体在 Alpine 上均可运行
- `sing-box check -c` 通过（Debian / Alpine 双环境）
- 实际监听成功，启动耗时 `0.00s`，日志无警告
- Alpine 容器内完整跑通：平台识别 → 依赖检查 → secret 生成 → 配置写入 → OpenRC 服务注册 → 进程监听 → 链接输出
- OpenRC `stop()` 的 TERM→KILL 降级逻辑单测通过

## 许可

脚本本身可自由使用与修改。`sing-box-extended` 遵循 GPL-3.0，分发二进制时请遵守其许可条款。

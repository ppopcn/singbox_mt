# singbox_mt

在 Debian / Ubuntu 上**一键部署代理服务端**的 Shell 脚本合集，全部基于 [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended)（sing-box 的增强分支）。

每个脚本都是独立的单文件，跑一条命令就会完成：下载官方预编译二进制 → 生成凭据/证书 → 写配置 → 注册 systemd → 启动 → 输出客户端链接。

| 脚本 | 服务端 | 默认端口 | 输出链接 |
|---|---|---|---|
| `singbox_mt.sh` | MTPROXY（Telegram） | `443/tcp` | `https://t.me/proxy?...` |
| `singbox_ssr.sh` | Shadowsocks `aes-256-gcm` | `8388/tcp+udp` | `ss://...` |
| `singbox_hy2.sh` | Hysteria2（QUIC） | `443/udp` | `hysteria2://...` |
| `singbox_tuic.sh` | TUIC v5（QUIC） | `443/udp` | `tuic://...` |
| `singbox_vless_vmess.sh` | VLESS + VMess（TLS+WS） | `8989/tcp` + `8990/tcp` | `vless://...`、`vmess://...` |

> 所有脚本共用同一个二进制 `/usr/local/bin/sing-box`，配置与证书都在 `/etc/sing-box/`，但各自注册独立的 systemd 单元（`singbox-mt` / `singbox-ssr` / `singbox-hy2` / `singbox-tuic` / `singbox-vless`），互不影响。卸载某个脚本时只有最后一个服务被移除才会删掉二进制。

## 快速开始

```bash
sudo bash singbox_mt.sh          # MTPROXY
sudo bash singbox_ssr.sh         # Shadowsocks
sudo bash singbox_hy2.sh         # Hysteria2
sudo bash singbox_tuic.sh        # TUIC
sudo bash singbox_vless_vmess.sh # VLESS + VMess
```

也支持远程一行执行：

```bash
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_hy2.sh | bash
```

所有脚本都支持三个子命令：`info`（重新打印凭据与链接）、`uninstall`（卸载）、`help`。

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Debian 10+ / Ubuntu 18.04+（其他 Debian 系也可，会提示但不阻断） |
| 权限 | root |
| 架构 | amd64 / arm64 / armv7 / armv6 / 386 / riscv64 / loong64 / mips 系列 |
| 依赖 | 自动安装 `curl`、`tar`、`iproute2`，TLS 类脚本另装 `openssl` |
| 进程管理 | systemd |

---

# singbox_mt.sh — MTPROXY

提供 Telegram 的 MTProto 代理。官方 sing-box 没有 MTPROXY 入站，这个脚本用的是 `sing-box-extended`，它额外提供了 `mtproxy` 入站（底层是 [mtg-multi](https://github.com/dolonet/mtg-multi) 内核），同时保留 sing-box 全套路由与出站能力。

相比直接部署 mtg，好处是：**Telegram 流量出来之后怎么走，由 sing-box 的 `outbounds` 和 `route` 决定**——可以走 WARP、可以多链路聚合、也可以按规则分流。

默认行为：监听 `443`、用户名 `user1`、FakeTLS 模式、伪装域名从内置候选里随机挑一个。输出形如：

```
https://t.me/proxy?server=1.2.3.4&port=443&secret=ee13c2...777772e636c6f7564666c6172652e636f6d
```

把这个链接发给 Telegram 联系人，或直接在手机浏览器打开，即可导入代理。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `443` | 监听端口（TCP） |
| `DOMAIN` | 随机 | FakeTLS 伪装域名，需支持 TLS 1.3 |
| `SERVER_ADDR` | 自动探测 | 生成链接时使用的对外 IP |
| `USER_NAME` | `user1` | MTPROXY 用户名 |
| `CONCURRENCY` | `8192` | 连接并发上限 |
| `AUTO_UPDATE` | `0` | 是否自动更新 Telegram DC 列表 |
| `MIRROR` | 空 | GitHub 加速前缀，如 `https://ghfast.top/https://github.com` |

---

# singbox_ssr.sh — Shadowsocks (aes-256-gcm)

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

---

# singbox_hy2.sh — Hysteria2

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

---

# singbox_tuic.sh — TUIC v5

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
tuic://UUID:PASSWORD@1.2.3.4:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&allow_insecure=1#tuic-443
```

---

# singbox_vless_vmess.sh — VLESS + VMess

VLESS 与 VMess 都走 **TLS + WebSocket**，路径分别是 `/vless` 和 `/vmess`。

> sing-box 的一个端口只能挂一个协议入站，所以两个协议用两个端口：默认 VLESS `8989`、VMess `8990`（`VMESS_PORT` 可改）。如果一定要单端口，需要前面再挂 nginx/caddy 按 WS 路径分流，本脚本不做这层。

```bash
sudo bash singbox_vless_vmess.sh
sudo PORT=8989 VMESS_PORT=8990 bash singbox_vless_vmess.sh
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `8989` | VLESS 端口 |
| `VMESS_PORT` | `8990` | VMess 端口 |
| `UUID` / `VMESS_UUID` | 随机 | 各自的用户 UUID |
| `DOMAIN` | 随机 | TLS 域名 / SNI |
| `VLESS_PATH` / `VMESS_PATH` | `/vless`、`/vmess` | WS 路径 |
| `CERT_FILE` / `KEY_FILE` | 同 hy2 | 不存在则自签 |

输出两条链接：

```
vless://UUID@1.2.3.4:8989?encryption=none&security=tls&sni=www.bing.com&fp=chrome&type=ws&host=www.bing.com&path=%2Fvless&allowInsecure=1#vless-8989

vmess://eyJ2IjoiMiIsInBzIjoi...
```

客户端记得打开「允许不安全证书」。

---

## 部署后

每个服务都是独立的 systemd 单元，例如 Hysteria2：

```bash
systemctl status singbox-hy2     # 查看状态
systemctl restart singbox-hy2    # 重启
systemctl stop singbox-hy2       # 停止
journalctl -u singbox-hy2 -f     # 实时日志
```

文件位置：

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/sing-box` | 二进制（各脚本共用） |
| `/etc/sing-box/*.json` | 配置文件（权限 600） |
| `/etc/sing-box/cert.pem`、`key.pem` | 自签 TLS 证书（TLS 类脚本共用） |
| `/etc/systemd/system/singbox-*.service` | systemd 单元 |

修改配置后重启对应服务生效。若改了密码/端口/UUID，`info` 命令会用当前配置重新打印链接。

## 关于 secret

MTPROXY 使用 **FakeTLS 模式**（`ee` 前缀），这是 mtg 的推荐做法，能抵御针对流量长度的统计分析。

secret 的字节布局是：

```
[0xee] [16 字节随机密钥] [域名明文 ASCII]
```

整个字节串以 hex 序列化。

> 注意：mtg 只接受 `ee` 前缀。`dd` 前缀与无前缀形式属于历史遗留，当前版本会直接报 `incorrect first byte of secret` 拒绝加载。

## 常见问题

**链接能生成但连不上？**

脚本只负责服务端。客户端到服务器的网络路径不在它的管辖范围内——如果服务器 IP 本身无法被直连，链接再正确也连不通。

**启动日志里没有报错，但也没连上？**

先确认防火墙。脚本会自动放行 ufw / firewalld，但**云厂商的安全组需要你手动开**：MTPROXY / Shadowsocks / VLESS / VMess 开 TCP，Hysteria2 / TUIC 开 **UDP**。

**Hysteria2 / TUIC 客户端报证书错误？**

证书是自签的，客户端必须允许不安全证书。要用正规证书就把 `CERT_FILE` / `KEY_FILE` 指向自己的文件（例如 acme.sh 签发的）。

**国内机器下载很慢或失败？**

脚本已内置两个镜像自动回退（`ghfast.top`、`gh-proxy.com`），直连失败会自动尝试。也可以手动指定：

```bash
sudo MIRROR=https://ghfast.top/https://github.com bash singbox_hy2.sh
```

**`auto_update` 要不要开？**

默认关闭。开启后会从 `core.telegram.org` 拉取 DC 列表，若出口网络受限会导致启动等待超时。脚本在 `AUTO_UPDATE=1` 时会先做连通性探测，不通则自动降级。

**FakeTLS 伪装域名怎么选？**

选一个**支持 TLS 1.3 且在你的服务器所在网络可正常访问**的大站。域名和客户端实际访问的目标不一致会影响伪装效果，客户端侧配置需与此保持一致。

## 已验证

在 `v1.14.1-extended-2.7.2` 上实测：

- SHA256 校验与 Release 摘要一致
- 官方包自带 `with_mtproxy` 标签，无需自编译
- `sing-box check -c` 通过（MTPROXY / Shadowsocks / Hysteria2 / TUIC / VLESS / VMess 六种入站配置）
- 实际监听成功，启动耗时 `0.00s`，日志无警告

## 许可

脚本本身可自由使用与修改。`sing-box-extended` 遵循 GPL-3.0，分发二进制时请遵守其许可条款。

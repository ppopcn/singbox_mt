# singbox_mt

在 Debian / Ubuntu / CentOS 等 RHEL 系 / Alpine 上**一键部署 sing-box 服务端**的 Shell 脚本，基于 [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended)（sing-box 的增强分支）。

运行一条命令，脚本会自动完成：识别发行版与架构 → 复用或下载官方预编译二进制 → 生成 FakeTLS secret → 写配置 → 注册服务 → 启动 → 输出 Telegram 代理链接。

同一仓库另有四个协议脚本（Shadowsocks / Hysteria2 / TUIC / VLESS+VMess），与 MTPROXY 共用同一套安装骨架，差别只在协议配置。内核版本被**锁定**在 `v1.14.1-extended-2.7.2`，避免上游改字段后配置失配。

```bash
bash singbox_mt.sh
```

输出形如：

```
https://t.me/proxy?server=1.2.3.4&port=443&secret=ee13c2...777772e636c6f7564666c6172652e636f6d
```

把这个链接发给 Telegram 联系人，或直接在手机浏览器打开，即可导入代理。

## 一键全家桶：singbox_all.sh

一条命令装齐 **5 个协议服务端**，架构是**单进程 + 单合并配置**：只运行一个 sing-box 进程、注册一个服务 `singbox-all`，全部入站挂在同一份 `/etc/sing-box/all.json` 里（分发与运行都只有这一个脚本文件）：

```bash
# 一键运行
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_all.sh | sudo bash

# 本地执行
sudo bash singbox_all.sh
```

默认端口计划（443 的 TCP 与 UDP 互不冲突，分别给 MT 与 HY2；TUIC 是 QUIC，让出 443 用 8443）：

| 协议 | 默认端口 | 说明 |
|---|---|---|
| MTPROXY | `443/tcp` | TCP 443 伪装最佳 |
| Hysteria2 | `443/udp` | QUIC 443 伪装最佳 |
| TUIC v5 | `8443/udp` | BBR 拥塞控制 |
| Shadowsocks | `8388/tcp+udp` | aes-256-gcm |
| VLESS / VMess | `8989` / `8990` tcp | TLS + WS |

```bash
sudo PROTOCOLS=mt,hy2 bash singbox_all.sh   # 只启用指定协议 (mt hy2 tuic ssr vless)
sudo bash singbox_all.sh plan               # 只打印/校验端口计划，不安装
sudo bash singbox_all.sh status             # 服务状态与端口
sudo bash singbox_all.sh info               # 重新打印全部凭据与链接
sudo bash singbox_all.sh logs [N]           # 最近 N 行日志
sudo bash singbox_all.sh uninstall          # 卸载
```

端口用专用变量覆盖（显式指定才生效，重装未指定则沿用上次实际端口）：
`MT_PORT` / `HY2_PORT` / `TUIC_PORT` / `SSR_PORT` / `VLESS_PORT` / `VMESS_PORT`。
凭据变量按协议加前缀：`HY2_PASSWORD`、`TUIC_UUID`、`SSR_PASSWORD`、`VLESS_UUID`…，
`DOMAIN` 为全部 TLS 协议共用的 SNI。装前会统一校验端口计划，互相打架直接报错；
冲突自动挑端口时也会避开其他协议计划使用的端口。重装会从合并配置里按入站类型复用全部凭据，客户端不会失效。

> **hy2 与 TUIC 都要 443 怎么办？** 两个都装、错开端口即可：TCP 443 与 UDP 443 是两个独立端口。MT 占 TCP 443，HY2 占 UDP 443，TUIC 用 8443——不想要的协议用 `PROTOCOLS=` 去掉就行。

**跨系统与防火墙/服务托管**，脚本统一处理：

| 系统 | 包管理 | 服务托管 | 防火墙处理 |
|---|---|---|---|
| Debian / Ubuntu | `apt` | systemd（`systemctl enable` 自启） | ufw 活跃则放行；iptables INPUT 默认 DROP 时自动插入 ACCEPT |
| CentOS / Rocky / Alma / Fedora | `dnf`/`yum` | systemd | firewalld 活跃则 `--permanent` 放行并 reload；未运行则提示 |
| Alpine | `apk` | OpenRC（`rc-update add default` 自启，容器内自动补 softlevel 标记） | iptables 放行并 `iptables-save` 持久化 + 开机恢复 |

无论哪种系统，**云厂商安全组都需要在控制台手动放行端口**。旧版按协议拆分的 5 个服务（singbox-mt/hy2/…）会在安装时被自动迁移为单一 `singbox-all`。

## 为什么用它

官方 sing-box 没有 MTPROXY 入站。这个脚本用的是 `sing-box-extended`，它额外提供了 `mtproxy` 入站（底层是 [mtg-multi](https://github.com/dolonet/mtg-multi) 内核），同时保留了 sing-box 全套路由与出站能力。

相比直接部署 mtg，好处是：**Telegram 流量出来之后怎么走，由 sing-box 的 `outbounds` 和 `route` 决定**——可以走 WARP、可以多链路聚合、也可以按规则分流。

## 环境要求

脚本会自动识别发行版族，走对应的包管理与服务管理路径。

| 项目 | Debian 系 | RHEL 系 | Alpine 系 |
|---|---|---|---|
| 发行版 | Debian 10+ / Ubuntu 18.04+ / 衍生版 | CentOS 7+ / Rocky / Alma / Fedora 等 | Alpine 3.16+ |
| 包管理 | `apt` | `dnf` / `yum` | `apk` |
| 服务管理 | `systemd` | `systemd` | `OpenRC` |
| 自动补装依赖 | curl、tar、iproute2 | 同左（python3 尽力补装） | bash、curl、openrc、iproute2 |
| 架构 | amd64 / arm64 / armv7 / armv6 / 386 / riscv64 / loong64 / mips 系列 | 同左 | 同左 |

其他要求：root 权限。RHEL 系注意：CentOS 7 已 EOL，官方源迁移到 vault 后需自行修源才能补装依赖；SELinux 为 Enforcing 时服务由 systemd 以 root 运行通常不受影响。

> **Alpine 用户注意**：Alpine 默认没有 bash，也没有 sudo。脚本必须用 bash 执行（不能 `sh`、不能 `./`），所以首次运行前先补上 bash；Alpine 默认以 root 登录，首次**去掉 `sudo`**（此时 sudo 还没装、`curl | sudo bash` 会报 `sudo: not found`）：
>
> ```bash
> apk add -U bash && curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_all.sh | bash
> ```
>
> 脚本运行中会自动补装 sudo，之后的命令就可以正常带 `sudo` 了。

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

### 端口冲突怎么办

同一台机器装第二个协议时，默认端口很可能已经被占（`hy2` 与 `tuic` 都用 `443/udp`）。脚本不会直接报错退出，而是：

1. 打印占用者（`ss` 能识别到进程名时），**提示输入新端口，等待 10 秒**；
2. 10 秒内不输入、直接回车、或环境没有终端（cron / 无 tty），就**自动挑一个不常用端口**（`20000-60000`，排除 22/80/443/3306/3389 等常用端口、其他 `singbox-*` 已声明的端口，并用真实 bind 校验一次）；
3. 明确提示「端口与原计划不同，云服务器记得在安全组放行新端口」。

```bash
# 交互式换端口：直接跑，按提示输入
sudo bash singbox_hy2.sh

# 不想交互：显式指定，优先级最高
sudo PORT=28443 bash singbox_hy2.sh

# 缩短/延长等待时间（秒）
sudo PORT_PROMPT_TIMEOUT=3 bash singbox_hy2.sh
```

**重装不会改端口和凭据。** 只要不显式传参，脚本会从上一次的 `/etc/sing-box/<协议>.json` 里沿用端口、UUID、密码、混淆密码、SNI，已有客户端因此不会失效。显式传 `PORT=...` 才会改。

> 端口是否冲突按协议分别判断：`443/udp` 和 `443/tcp` 并不冲突，只有同协议同端口才算占用。

### 其他命令

```bash
bash singbox_mt.sh info        # 重新打印配置与链接
bash singbox_mt.sh logs        # 查看最近日志（默认 50 行）
bash singbox_mt.sh uninstall   # 卸载（KEEP_CONFIG=1 可保留配置）
bash singbox_mt.sh help        # 查看帮助
```

安装完成后脚本会把自身装到 `/usr/local/bin/singbox-<协议>`，之后可以直接用本地命令管理，不必再联网：

```bash
singbox-mt info
singbox-hy2 logs 100
singbox-tuic uninstall
```

## 其他协议脚本

除 MTPROXY 外，仓库还提供四个独立脚本。骨架与 `singbox_mt.sh` 一致（下载 sing-box-extended → SHA256 校验 → 写配置并 `sing-box check` → 注册服务 → 放行防火墙 → 输出客户端链接），差别只在协议入站配置。

| 脚本 | 协议 | 默认端口 | 输出链接 |
|---|---|---|---|
| `singbox_all.sh` | **全部 5 个协议一次装** | 见上文全家桶端口表 | 各协议链接 |
| `singbox_ssr.sh` | Shadowsocks `aes-256-gcm` | `8388`（TCP+UDP） | `ss://` |
| `singbox_hy2.sh` | Hysteria2（QUIC） | `443/udp` | `hysteria2://` |
| `singbox_tuic.sh` | TUIC v5（QUIC） | `443/udp` | `tuic://` |
| `singbox_vless_vmess.sh` | VLESS + VMess（TLS+WS） | `8989` + `8990` | `vless://`、`vmess://` |

四个脚本都支持 `install`（默认）/ `info` / `logs` / `uninstall` / `help`，也可一行部署：

```bash
curl -fsSL https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_hy2.sh | sudo bash
curl -fsSL .../singbox_hy2.sh | sudo bash -s -- info
curl -fsSL .../singbox_hy2.sh | sudo bash -s -- uninstall
```

> 五个脚本共用同一套公共层，Debian / Ubuntu 走 systemd、Alpine 走 OpenRC 都由它统一处理（MTPROXY 已在 Alpine 容器实测，其余协议复用同一实现）。

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

## 仓库结构

```
lib/common.sh             公共骨架：日志 / 检查 / 下载 / 版本 / 证书 / 服务 / 端口 / 卸载 / main
src/singbox_*.sh          各协议差异段：元信息 + render_config + 凭据 + print_summary + usage
build.sh                  把 src 与 lib 拼成单文件脚本
singbox_*.sh              构建产物（仓库根目录，也就是 curl 直接跑的那些）
```

**根目录的 `singbox_*.sh` 不要直接改**，改完 `src/` 或 `lib/` 后重新生成：

```bash
./build.sh            # 生成 6 个脚本
./build.sh --check    # 只检查产物是否最新（CI 用）
```

### 新增一个协议

1. 复制 `src/singbox_tuic.sh` 改名，修改元信息块里的 `SERVICE_NAME` / `SHORT_NAME` / `CONFIG_FILE` / `PORT_SPECS` / `NEED_CERT`；
2. 实现 `render_config`（输出 JSON 到 stdout）、`prepare_secrets`、`load_credentials`、`print_summary`、`usage`；
3. 跑 `./build.sh`，根目录会自动多出对应的 `singbox_xxx.sh`。

公共流程（下载 → 校验 → 写配置 → 注册服务 → 放行防火墙 → 启动 → 输出）以及 `info` / `logs` / `uninstall` 全部由 `lib` 提供，不用重复实现。

### 端口声明

端口用 `PORT_SPECS` 声明，公共层据此做校验、占用检测、防火墙放行与监听验证：

```bash
PORT_SPECS=("PORT:tcp")              # 单端口 TCP
PORT_SPECS=("PORT:tcp,udp")          # 单端口双协议（Shadowsocks）
PORT_SPECS=("PORT:udp")              # QUIC 系（Hysteria2 / TUIC）
PORT_SPECS=("PORT:tcp" "VMESS_PORT:tcp")   # 双入站
```

协议若需要派生默认值（如 VMess 取 `PORT+1`），实现 `port_defaults_hook`；需要交叉校验（如两端口不能相同）就实现 `port_validate_hook`。默认端口用 `PORT_DEFAULTS="PORT=443"` 声明，不要写成 `PORT="${PORT:-443}"` —— 公共层需要区分「用户显式指定」与「默认值」，才能正确沿用上一次配置里的端口。

端口取值的优先级是：**显式环境变量 > 已有 `CONFIG_FILE` 里的 `listen_port` > `PORT_DEFAULTS` > `port_defaults_hook` 推导**。

交互输入统一走 `/dev/tty`（不是 stdin）：`curl ... | bash` 时 stdin 就是脚本自身，读 stdin 会把后半段脚本吃掉。

### 内核版本与二进制复用

- 版本锁定在 `SINGBOX_TAG`，默认 `v1.14.1-extended-2.7.2`；要试新版显式覆盖：`SINGBOX_TAG=v1.15.0-extended-2.8.0 sudo bash singbox_tuic.sh`
- 已装同版本时直接复用，不再下载（装第二个协议不会再拉一遍 20MB）；`FORCE_BIN=1` 强制重下
- 下载地址与 SHA256 都从该 tag 的 Release 接口取，个别架构只有 glibc / musl 变体（如 loong64）会自动选适配包

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
- 抽出公共层（`lib/common.sh` + `src/` + `build.sh`）后，五个脚本生成的**配置 JSON 与客户端链接与重构前逐字节一致**
- 端口推导用例：`PORT=443` → 443/444、默认 → 8989/8990、`PORT=0808` → 808/809、`PORT=abc` / `PORT=70000` 明确报错
- 同版本二进制复用生效（第二个协议不再下载）、`loong64` 自动选中 `-glibc` 变体
- 端口冲突用例：`443` 被占用时输入 `23456` → 采用 23456；输入非法值 → 重问；输入被占用的端口 → 重问；超时 / 空回车 / 无终端 → 自动挑选 20000-60000 且避开常用端口
- 重装幂等：同一机器连续两次 `do_install`，生成的配置逐字节一致（端口、UUID、密码、混淆、SNI 全部复用）

## 许可

脚本本身可自由使用与修改。`sing-box-extended` 遵循 GPL-3.0，分发二进制时请遵守其许可条款。

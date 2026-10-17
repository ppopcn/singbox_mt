# singbox_mt

在 Debian / Ubuntu 上**一键部署 MTPROXY 服务端**的 Shell 脚本，基于 [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended)（sing-box 的增强分支）。

运行一条命令，脚本会自动完成：下载官方预编译二进制 → 生成 FakeTLS secret → 写配置 → 注册 systemd → 启动 → 输出 Telegram 代理链接。

```bash
sudo bash singbox_mt.sh
```
```OR
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/ppopcn/singbox_mt/refs/heads/main/singbox_mt.sh | bash
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

| 项目 | 要求 |
|---|---|
| 系统 | Debian 10+ / Ubuntu 18.04+（其他 Debian 系也可，会提示但不阻断） |
| 权限 | root |
| 架构 | amd64 / arm64 / armv7 / armv6 / 386 / riscv64 / loong64 / mips 系列 |
| 依赖 | 自动安装 `curl`、`tar`、`iproute2` |
| 进程管理 | systemd |

## 用法

### 快速开始

```bash
sudo bash singbox_mt.sh
```

默认行为：监听 `443`、用户名 `user1`、FakeTLS 模式、伪装域名从内置候选里随机挑一个。

### 自定义参数

所有参数通过环境变量传入：

```bash
# 换端口
sudo PORT=8443 bash singbox_mt.sh

# 指定伪装域名
sudo DOMAIN=www.bing.com bash singbox_mt.sh

# 组合使用，并指定对外 IP（自动探测失败时用）
sudo PORT=8443 DOMAIN=www.apple.com SERVER_ADDR=1.2.3.4 bash singbox_mt.sh
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
sudo bash singbox_mt.sh info        # 重新打印配置与链接
sudo bash singbox_mt.sh uninstall   # 卸载（KEEP_CONFIG=1 可保留配置）
sudo bash singbox_mt.sh help        # 查看帮助
```

## 部署后

服务已注册为 systemd 单元 `singbox-mt`：

```bash
systemctl status singbox-mt     # 查看状态
systemctl restart singbox-mt    # 重启
systemctl stop singbox-mt       # 停止
journalctl -u singbox-mt -f     # 实时日志
```

文件位置：

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/sing-box` | 二进制 |
| `/etc/sing-box/mtproxy.json` | 配置文件（权限 600） |
| `/etc/systemd/system/singbox-mt.service` | systemd 单元 |

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
sudo MIRROR=https://ghfast.top/https://github.com bash singbox_mt.sh
```

**`auto_update` 要不要开？**

默认关闭。开启后会从 `core.telegram.org` 拉取 DC 列表，若出口网络受限会导致启动等待超时。脚本在 `AUTO_UPDATE=1` 时会先做连通性探测，不通则自动降级。

**FakeTLS 伪装域名怎么选？**

选一个**支持 TLS 1.3 且在你的服务器所在网络可正常访问**的大站。域名和客户端实际访问的目标不一致会影响伪装效果，客户端侧配置需与此保持一致。

## 已验证

在 `v1.14.1-extended-2.7.2` 上实测：

- SHA256 校验与 Release 摘要一致
- 官方包自带 `with_mtproxy` 标签，无需自编译
- `sing-box check -c` 通过
- 实际监听成功，启动耗时 `0.00s`，日志无警告

## 许可

脚本本身可自由使用与修改。`sing-box-extended` 遵循 GPL-3.0，分发二进制时请遵守其许可条款。

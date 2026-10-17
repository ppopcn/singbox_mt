# singbox_mt 项目约定

## 脚本风格

- 命名：`singbox_<协议>.sh`，每个脚本都是**单文件、自包含**（可以 `curl ... | bash` 直接跑），不抽公共库。
- 骨架固定：`check_root` / `check_os` / `check_deps` / `fetch` + 镜像回退 / `detect_arch` / `resolve_release` / `install_binary`（SHA256 校验）/ 写配置 + `sing-box check` / `write_service` / `open_firewall` / `start_service` / `print_summary` / `cmd_info` / `cmd_uninstall` / `usage`。
- 子命令统一：`install`（默认）、`info`、`uninstall`、`help`。参数全部走环境变量（`PORT`、`PASSWORD`、`UUID`、`DOMAIN`、`SERVER_ADDR`、`MIRROR`）。
- 二进制固定 `/usr/local/bin/sing-box`（来自 `shtorm-7/sing-box-extended`），配置在 `/etc/sing-box/<协议>.json`（600），证书共用 `cert.pem`/`key.pem`。
- systemd 单元命名 `singbox-<协议>`；卸载时若还有其他 `singbox-*.service` 就**不删**二进制。
- 行宽 100 左右，中文注释 + 三段式排版（常量 / 输出美化 / 各函数），`set -euo pipefail`。

## 排错经验

- 本机是 Windows，`core.autocrlf=true`：提交前确认 `.sh` 在 index 里是 LF（已有 `.gitattributes` 兜底）。
- 验证配置最快的方式：下载 release 的 windows-amd64 包，用 `sing-box.exe check -c` 跑一遍。

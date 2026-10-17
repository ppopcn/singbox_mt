#!/usr/bin/env bash
#
# build.sh - 把 src/ 里的协议差异段与 lib/common.sh 拼成单文件脚本
#
# 仓库根目录的 singbox_*.sh 是构建产物, 不要直接改, 改 src/ 与 lib/ 后重新生成:
#   ./build.sh            # 生成
#   ./build.sh --check    # 只在有差异时报错(CI 用)
#
set -euo pipefail
cd "$(dirname "$0")"

LIB="lib/common.sh"
OUT_DIR=".build"
[[ -f "$LIB" ]] || { echo "缺少 $LIB" >&2; exit 1; }

check=0
[[ "${1:-}" == "--check" ]] && check=1

mkdir -p "$OUT_DIR"
cleanup() { rm -f "${OUT_DIR}"/*.sh 2>/dev/null || true; rmdir "$OUT_DIR" 2>/dev/null || true; }
trap cleanup EXIT

rc=0
for src in src/singbox_*.sh; do
  [[ -e "$src" ]] || continue
  name="$(basename "$src")"

  awk -v lib="$LIB" '
    /^# @@LIB@@$/ {
      while ((getline line < lib) > 0) print line
      close(lib)
      next
    }
    { print }
  ' "$src" >"${OUT_DIR}/${name}"

  if ((check)); then
    if ! diff -q "$name" "${OUT_DIR}/${name}" >/dev/null 2>&1; then
      echo "需要重新生成: $name" >&2
      rc=1
    fi
  else
    mv "${OUT_DIR}/${name}" "$name"
    chmod +x "$name"
    echo "生成 $name  ($(wc -l <"$name") 行)"
  fi
done

((check)) && ((rc == 0)) && echo "构建产物已是最新"
exit $rc

#!/usr/bin/env bash
# Linux X11 冒烟测试：在 Xvfb 虚拟显示里拉起 Mint，确认：
#   1. 应用能撑过 20 秒不崩（GL / GTK / 插件初始化全链路）
#   2. 截屏留档供人工检查
# 用独立的 $HOME，避免污染真实用户配置。
#
# 用法：smoke_x11.sh <bundle 二进制> <输出目录>
set -uo pipefail

BIN="${1:?用法: smoke_x11.sh <bundle> <outdir>}"
OUT="${2:?用法: smoke_x11.sh <bundle> <outdir>}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"

export DISPLAY="${SMOKE_DISPLAY:-:99}"
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  Xvfb "$DISPLAY" -screen 0 1280x800x24 +extension GLX +extension RANDR \
    >"$OUT/xvfb.log" 2>&1 &
  XVFB_PID=$!
  trap '[ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 30); do
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
    sleep 0.5
  done
fi
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || { echo "Xvfb 起不来"; exit 1; }

export LIBGL_ALWAYS_SOFTWARE=1
export HOME="$OUT/home"
mkdir -p "$HOME"

"$BIN" >"$OUT/app.log" 2>&1 &
APP_PID=$!

ALIVE=no
for _ in $(seq 1 10); do
  sleep 2
  kill -0 "$APP_PID" 2>/dev/null || break
done
if kill -0 "$APP_PID" 2>/dev/null; then
  ALIVE=yes
  sleep 2
  import -display "$DISPLAY" -window root "$OUT/x11.png" 2>"$OUT/import.log" ||
    xwd -display "$DISPLAY" -root -silent | convert - "$OUT/x11.png" 2>/dev/null ||
    echo "截屏失败（不影响存活判定）"
fi
kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null

echo "==== app.log（前 80 行）===="
head -80 "$OUT/app.log" || true

if [ "$ALIVE" = yes ]; then
  echo "SMOKE X11: OK（进程存活 20s+）"
else
  echo "SMOKE X11: FAIL（进程提前退出）"
  exit 1
fi

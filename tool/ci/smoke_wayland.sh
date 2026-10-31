#!/usr/bin/env bash
# Linux Wayland 冒烟测试：weston headless 合成器里强制 GDK_BACKEND=wayland
# 拉起 Mint，验证 GTK Wayland 路径（含窗口模糊的 Wayland 代码编译/注册/降级）。
# weston 没有 KDE 模糊协议 → 能力探测应如实返回不支持，应用照常存活。
#
# 用法：smoke_wayland.sh <bundle 二进制> <输出目录>
set -uo pipefail

BIN="${1:?用法: smoke_wayland.sh <bundle> <outdir>}"
OUT="${2:?用法: smoke_wayland.sh <bundle> <outdir>}"
mkdir -p "$OUT"

export XDG_RUNTIME_DIR="$OUT/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

weston --backend=headless-backend.so --socket=wayland-mint-smoke \
  --width=1280 --height=800 >"$OUT/weston.log" 2>&1 &
WESTON_PID=$!
trap 'kill "$WESTON_PID" 2>/dev/null || true' EXIT

export WAYLAND_DISPLAY=wayland-mint-smoke
for _ in $(seq 1 30); do
  [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
  sleep 0.5
done
[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] || { echo "weston headless 起不来"; tail -40 "$OUT/weston.log"; exit 1; }

export GDK_BACKEND=wayland
export LIBGL_ALWAYS_SOFTWARE=1
export HOME="$OUT/home"
mkdir -p "$HOME"

"$BIN" >"$OUT/app.log" 2>&1 &
APP_PID=$!

sleep 20
ALIVE=no
kill -0 "$APP_PID" 2>/dev/null && ALIVE=yes
kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null

echo "==== app.log（前 80 行）===="
head -80 "$OUT/app.log" || true

if [ "$ALIVE" = yes ]; then
  echo "SMOKE Wayland: OK（进程存活 20s+）"
else
  echo "SMOKE Wayland: FAIL（进程提前退出）"
  exit 1
fi

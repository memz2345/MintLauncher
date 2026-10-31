#!/usr/bin/env bash
# 多场景截图巡游：同一个 bundle 反复拉起（页面 / 界面风格 / 主题模式走
# 环境变量钩子 MINT_TEST_PAGE / MINT_UI_STYLE / MINT_THEME_MODE，不用重
# 编），每个场景等首帧稳定后 `import` 截一张，存 $OUT 供 CI artifact 下载。
#
# 用法：screenshot_tour.sh <bundle 二进制> <输出目录>
set -uo pipefail

BIN="${1:?用法: screenshot_tour.sh <bundle> <outdir>}"
OUT="${2:?用法: screenshot_tour.sh <bundle> <outdir>}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"

export DISPLAY="${SMOKE_DISPLAY:-:99}"
XVFB_PID=""
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  Xvfb "$DISPLAY" -screen 0 1280x800x24 +extension GLX +extension RANDR \
    >"$OUT/xvfb.log" 2>&1 &
  XVFB_PID=$!
  for _ in $(seq 1 30); do
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
    sleep 0.5
  done
fi
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || { echo "Xvfb 起不来"; exit 1; }
cleanup() { [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null; }
trap cleanup EXIT

export LIBGL_ALWAYS_SOFTWARE=1

shoot() {
  local name="$1"
  shift
  export HOME="$OUT/home-$name"
  mkdir -p "$HOME"
  env "$@" "$BIN" >"$OUT/log-$name.txt" 2>&1 &
  local pid=$!
  sleep 15
  if kill -0 "$pid" 2>/dev/null; then
    import -display "$DISPLAY" -window root "$OUT/shot-$name.png" 2>/dev/null ||
      echo "shot-$name: 截屏失败（进程活着）"
    echo "shot-$name: OK"
  else
    echo "shot-$name: FAIL（进程提前退出，见 log-$name.txt）"
  fi
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

shoot home
shoot downloads MINT_TEST_PAGE=downloads
shoot settings MINT_TEST_PAGE=settings
shoot version_manager MINT_TEST_PAGE=version_manager
shoot fluent MINT_UI_STYLE=fluent
shoot dark MINT_THEME_MODE=dark
echo "TOUR DONE"

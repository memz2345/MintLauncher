#!/usr/bin/env bash
# KDE 窗口模糊端到端探针：Xvfb 里跑真 KWin，启动时带
# --dart-define=MINT_TEST_BACKDROP=acrylic 编译的应用，验证：
#   1. 能力探测认出 KWin（_NET_SUPPORTING_WM_CHECK → "KWin"）
#   2. Dart 侧 setBackdrop → 原生 _KDE_NET_WM_BLUR_BEHIND_REGION 原子
#      真的设置到了窗口上（xprop 能读到）
# KWin 在 Xvfb 里可能开不了混成（无 GL），但模糊原子只是个窗口属性，
# 设置路径不需要混成 —— 本探针验证的是「我们这半边」的接线。
#
# 用法：kwin_blur_probe.sh <bundle 二进制> <输出目录>
set -uo pipefail

BIN="${1:?用法: kwin_blur_probe.sh <bundle> <outdir>}"
OUT="${2:?用法: kwin_blur_probe.sh <bundle> <outdir>}"
mkdir -p "$OUT"

export DISPLAY="${PROBE_DISPLAY:-:98}"
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  Xvfb "$DISPLAY" -screen 0 1280x800x24 +extension GLX +extension RANDR \
    >"$OUT/xvfb.log" 2>&1 &
  XVFB_PID=$!
  trap '[ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true' EXIT
  sleep 3
fi

export LIBGL_ALWAYS_SOFTWARE=1
export HOME="$OUT/home"
export XDG_RUNTIME_DIR="$OUT/xdg"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

RESULT="$OUT/result.txt"
: >"$RESULT"

dbus-run-session -- bash -ce '
  BIN="$1"; OUT="$2"
  kwin_x11 --replace >"$OUT/kwin.log" 2>&1 &
  KWIN_PID=$!
  sleep 12

  echo "==== 窗口管理器 ====" >>"$OUT/result.txt"
  xprop -root _NET_SUPPORTING_WM_CHECK >>"$OUT/result.txt" 2>&1 || true
  WMID=$(xprop -root _NET_SUPPORTING_WM_CHECK | grep -oE "window id # 0x[0-9a-f]+" | grep -oE "0x[0-9a-f]+")
  [ -n "$WMID" ] && xprop -id "$WMID" _NET_WM_NAME >>"$OUT/result.txt" 2>&1

  "$BIN" >"$OUT/app.log" 2>&1 &
  APP_PID=$!
  sleep 22

  echo "==== 模糊原子 ====" >>"$OUT/result.txt"
  WID=$(xdotool search --onlyvisible --class mint 2>/dev/null | head -1)
  if [ -z "$WID" ]; then
    WID=$(xprop -root _NET_CLIENT_LIST | grep -oE "0x[0-9a-f]+" | tail -1)
  fi
  echo "window id: $WID" >>"$OUT/result.txt"
  if [ -n "$WID" ]; then
    xprop -id "$WID" WM_CLASS >>"$OUT/result.txt" 2>&1 || true
    xprop -id "$WID" _KDE_NET_WM_BLUR_BEHIND_REGION >>"$OUT/result.txt" 2>&1 || true
  fi

  import -display "$DISPLAY" -window root "$OUT/kwin.png" 2>/dev/null || true
  kill "$APP_PID" 2>/dev/null
  kill "$KWIN_PID" 2>/dev/null
' _ "$BIN" "$OUT"

echo "==== 探针结果 ===="
cat "$RESULT"

# 原子必须真的在窗口上（CARDINAL 输出），WM 名必须是 KWin。
if grep -q "_KDE_NET_WM_BLUR_BEHIND_REGION(CARDINAL)" "$RESULT" &&
   grep -q "KWin" "$RESULT"; then
  echo "KWIN BLUR PROBE: OK（模糊原子已设置）"
  exit 0
else
  echo "KWIN BLUR PROBE: FAIL（原子缺失或 WM 探测失败，属 best-effort 探针）"
  exit 1
fi

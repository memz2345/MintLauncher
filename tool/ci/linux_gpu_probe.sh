#!/usr/bin/env bash
# Linux 选卡链路探针：在 Xvfb 里用真二进制跑一次 Mint，用
# MINT_GPU_PROBE_OUT=<文件> 让应用把「三档偏好合成出的启动环境」+
# 「真起一个 /bin/sh 子进程把 DRI_PRIME 读回来」写进文件，这里核对期望值。
#
# GitHub 的 Linux runner 没有 GPU，所以这里验的是**传递层**（启动器有没有把
# 变量交到子进程手里），不是「画面落在哪块卡」—— 后者要真机，见 README
# 「启动选项」表的「渲染显卡」一行。
#
# 用法：linux_gpu_probe.sh <bundle 二进制> <输出目录>
set -uo pipefail

BIN="${1:?用法: linux_gpu_probe.sh <bundle> <outdir>}"
OUT="${2:?用法: linux_gpu_probe.sh <bundle> <outdir>}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"

export DISPLAY="${SMOKE_DISPLAY:-:99}"
XVFB_PID=""
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

# 独立 HOME 免得污染真实配置；父进程必须没有 DRI_PRIME，否则「自动」档的
# 「子进程读到 <>」就没意义了。
export HOME="$OUT/home"
mkdir -p "$HOME"
unset DRI_PRIME

RESULT="$OUT/gpu-probe.txt"
rm -f "$RESULT"

MINT_GPU_PROBE_OUT="$RESULT" "$BIN" >"$OUT/gpu-probe.log" 2>&1 &
APP_PID=$!
for _ in $(seq 1 40); do
  [ -s "$RESULT" ] && break
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 1
done
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

if [ ! -s "$RESULT" ]; then
  echo "探针没写结果（$RESULT）。应用日志尾部："
  tail -40 "$OUT/gpu-probe.log" || true
  exit 1
fi

cat "$RESULT"

fail=0
check() {
  local desc="$1" pattern="$2"
  if grep -qF "$pattern" "$RESULT"; then
    echo "  OK  $desc"
  else
    echo "  FAIL $desc（找不到：$pattern）"
    fail=1
  fi
}

check "Linux 不写注册表偏好" '注册表通道可用：false'
check "高性能合成 DRI_PRIME=1" '合成环境 {DRI_PRIME: 1}'
check "节能合成 DRI_PRIME=0" '合成环境 {DRI_PRIME: 0}'
check "自动档不合成变量" '自动（跟随系统）  合成环境 {}'
check "按卡名指定在 Linux 退化成不干预" '指定显卡（adapter:1002&13C0&88771043）  合成环境 {}'
check "CPU 软件渲染时不再设显卡" '高性能 + CPU 软件渲染  合成环境 {}'
check "子进程确实读到 DRI_PRIME=1" '子进程读到 <1>'
check "子进程确实读到 DRI_PRIME=0" '子进程读到 <0>'
check "自动档子进程没有 DRI_PRIME" '子进程读到 <>'

exit "$fail"

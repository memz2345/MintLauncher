#!/usr/bin/env bash
# iOS「应用内启动游戏」探针执行器（CI 用）。
#
# 两阶段（2026-11-02）：
#   阶段1  应用内 posix_spawn（真实启动链路）：重拉应用（IosGameLaunchProbe
#          读沙盒 game_probe.json），轮询 game_probe_result.txt。实测 JVM、
#          MC 主类、LWJGL 初始化都能起来；但模拟器应用活在 CoreSimulator
#          的 bootstrap 域里，子进程连不上宿主 WindowServer，GLFW 建窗挂死
#          ——这一步只证明「应用能自己把游戏进程跑起来」。
#   阶段2  宿主 GUI 会话兜底起窗口：CI 直接执行应用生成的**同一份启动脚本**
#          （mint_game_launch.sh —— 同一个 java、同一份 classpath），游戏
#          窗口开在 runner 桌面，screencapture 连拍留证 ——「模拟器宿主跑
#          真 Minecraft」的截图证据。
#
# 用法：bash tool/ci/ios_probe_game.sh <simulator-udid>
set -euo pipefail

UDID="${1:?usage: ios_probe_game.sh <simulator-udid>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHOTS="$ROOT/build/shots"
mkdir -p "$SHOTS"
DATA="$(xcrun simctl get_app_container "$UDID" dev.mint.mint data)"
RESULT="$DATA/Documents/game_probe_result.txt"
LOG="$DATA/Documents/game-launch.log"
SCRIPT="$DATA/Documents/mint_game_launch.sh"

rm -f "$RESULT"
xcrun simctl terminate "$UDID" dev.mint.mint >/dev/null 2>&1 || true
xcrun simctl launch --console-pty "$UDID" dev.mint.mint \
  >"$SHOTS/game-console.log" 2>&1 &

# ── 阶段1：等应用内探针出结果（10 分钟上限）──
got_result=0
lwjgl_seen=0
for _ in $(seq 1 150); do # 150 * 4s = 10 分钟上限
  sleep 4
  if [ "$lwjgl_seen" = 0 ] && [ -f "$LOG" ] &&
     grep -qi "lwjgl version" "$LOG" 2>/dev/null; then
    lwjgl_seen=1
    echo "== 游戏日志出现 LWJGL version（应用内 JVM 已起，等探针终局）"
  fi
  if [ -f "$RESULT" ]; then
    got_result=1
    break
  fi
done

echo "==== 阶段1：应用内 posix_spawn 结果 ===="
if [ "$got_result" = 1 ]; then
  cat "$RESULT"
  cp "$RESULT" "$SHOTS/game_probe_result.txt"
else
  echo "!! 探针超时（10 分钟无结果文件）"
  printf '%s\n' "!! iOS 游戏探针超时：应用进程没有写出 game_probe_result.txt" \
    >"$SHOTS/game_probe_result.txt"
fi
# 过程日志（progress / 子进程文件写测试）一并带走 —— 应用中途被杀时
# result 没有终局，只有这里有线索。注意：echo 里 $f 后面不能紧跟全角
# 括号（macOS runner 的 bash 会把它吃进变量名，上一轮就是这么炸的）。
for f in game_probe_progress.txt spawn-file-test.txt spawn-trace.log; do
  if [ -f "$DATA/Documents/$f" ]; then
    cp "$DATA/Documents/$f" "$SHOTS/$f" || true
    echo "==== ${f} tail-30 ===="
    tail -30 "$SHOTS/$f" || true
  else
    echo "(no ${f})"
  fi
done
if [ -f "$LOG" ]; then
  tail -200 "$LOG" >"$SHOTS/game-launch-tail.log" || true
  echo "==== game-launch.log 尾部（阶段1）===="
  tail -30 "$SHOTS/game-launch-tail.log" || true
else
  printf '%s\n' "(无 game-launch.log — 子进程没起来，看 spawn-trace.log)" \
    >"$SHOTS/game-launch-tail.log"
fi
# 阶段1 桌面留证：bootstrap 域无 WindowServer，预期没有游戏窗口。
screencapture -x "$SHOTS/ios-host-phase1.png" 2>/dev/null || true
# 收掉应用内拉起的孤儿 java（SIGTERM 只杀得到 bash），给阶段2 让路。
pkill -f "MintLauncher/minecraft" 2>/dev/null || true
xcrun simctl terminate "$UDID" dev.mint.mint >/dev/null 2>&1 || true
sleep 2

# ── 阶段2：宿主 GUI 会话兜底起窗口 + 桌面连拍 ──
echo "==== 阶段2：宿主会话起游戏窗口（同一启动脚本）===="
if [ ! -f "$SCRIPT" ]; then
  echo "(跳过：应用没有生成 mint_game_launch.sh)"
else
  rm -f "$LOG"
  bash "$SCRIPT" >"$SHOTS/game-host-console.log" 2>&1 &
  host_pid=$!
  lwjgl2=0
  for _ in $(seq 1 75); do # 75 * 4s = 5 分钟
    sleep 4
    if [ -f "$LOG" ] && grep -qi "lwjgl version" "$LOG" 2>/dev/null; then
      lwjgl2=1
      break
    fi
    kill -0 "$host_pid" 2>/dev/null || break
  done
  if [ "$lwjgl2" = 1 ]; then
    echo "== LWJGL 起来了 — 等 45s 让窗口画出来，然后连拍桌面"
    sleep 45
    screencapture -x "$SHOTS/ios-host-game-1.png" 2>/dev/null || true
    sleep 40
    screencapture -x "$SHOTS/ios-host-game-2.png" 2>/dev/null || true
    sleep 50
    screencapture -x "$SHOTS/ios-host-game-3.png" 2>/dev/null || true
    ls -la "$SHOTS"/ios-host-game-*.png 2>/dev/null || true
  else
    echo "!! 宿主会话里游戏也没走到 LWJGL（看 game-host-console.log / game-launch.log）"
    screencapture -x "$SHOTS/ios-host-phase2-fail.png" 2>/dev/null || true
  fi
  # 尸检材料：宿主会话 java 的统一日志（WindowServer / GLFW 报错在这）。
  log show --last 10m --predicate 'process == "java"' --style compact \
    >"$SHOTS/java-unified-log.txt" 2>&1 || true
  # GPU 环境留档：GitHub macOS runner 是无 GPU 的 VM（Apple
  # Virtualization.framework 客户机），NSGL 找不到 pixel format 时游戏
  # 弹 GLFW error 65545 对话框退出 —— 这是 CI 硬件墙，不是启动器问题，
  # 有 GPU 的真 Mac 上这步能过。截图（弹窗）+ 这份留档即终局证据。
  system_profiler SPDisplaysDataType >"$SHOTS/host-gpu-info.txt" 2>&1 || true
  if grep -qi "GLFW error" "$LOG" 2>/dev/null; then
    echo "!! 窗口已建成但 GL 上下文失败（CI VM 无 OpenGL 渲染器，见弹窗截图）"
    grep -i "GLFW error" "$LOG" | head -3 || true
  fi
  # 收摊：先杀 java（bash 补一行 java-exit 进 console 日志），再收 bash。
  pkill -f "MintLauncher/minecraft" 2>/dev/null || true
  sleep 3
  kill "$host_pid" 2>/dev/null || true
  if [ -f "$LOG" ]; then
    tail -60 "$LOG" >"$SHOTS/game-launch-tail.log" || true
  fi
fi
echo "==== 应用 console 尾部 ===="
tail -40 "$SHOTS/game-console.log" || true

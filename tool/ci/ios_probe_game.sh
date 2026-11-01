#!/usr/bin/env bash
# iOS「应用内启动游戏」探针执行器（CI 用）。
#
# 重拉应用（IosGameLaunchProbe 读沙盒 game_probe.json），轮询结果文件；
# 游戏日志里出现 LWJGL 行后在 runner 桌面连拍三张（游戏窗口开在桌面，
# 不在模拟器屏幕里）——「模拟器宿主跑真 Minecraft」的截图证据。
# 60 分钟无结果视为超时（1.20.4 的 JVM 冷启动在 2 vCPU runner 上可能
# 要几分钟，类加载全是第一次）。
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

rm -f "$RESULT"
xcrun simctl terminate "$UDID" dev.mint.mint >/dev/null 2>&1 || true
xcrun simctl launch --console-pty "$UDID" dev.mint.mint \
  >"$SHOTS/game-console.log" 2>&1 &

lwjgl_seen=0
shots_taken=0
got_result=0
for _ in $(seq 1 150); do # 150 * 4s = 10 分钟上限
  sleep 4
  if [ "$lwjgl_seen" = 0 ] && [ -f "$LOG" ] &&
     grep -qi "lwjgl version" "$LOG" 2>/dev/null; then
    lwjgl_seen=1
    echo "== 游戏日志出现 LWJGL version — 等 45s 让窗口画出来，然后连拍桌面"
  fi
  if [ "$lwjgl_seen" = 1 ] && [ "$shots_taken" = 0 ]; then
    sleep 45
    screencapture -x "$SHOTS/ios-host-game-1.png" 2>/dev/null || true
    sleep 40
    screencapture -x "$SHOTS/ios-host-game-2.png" 2>/dev/null || true
    sleep 50
    screencapture -x "$SHOTS/ios-host-game-3.png" 2>/dev/null || true
    shots_taken=1
    ls -la "$SHOTS"/ios-host-game-*.png 2>/dev/null || true
  fi
  if [ -f "$RESULT" ]; then
    got_result=1
    break
  fi
done

echo "==== 游戏探针结果 ===="
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
  tail -60 "$LOG" >"$SHOTS/game-launch-tail.log" || true
else
  printf '%s\n' "(无 game-launch.log — 子进程可能没起来，看 spawn-trace.log)" \
    >"$SHOTS/game-launch-tail.log"
fi
if [ "$lwjgl_seen" = 0 ]; then
  # 没等到游戏：也拍一张桌面做诊断（应用 / 报错窗口在上面）。
  screencapture -x "$SHOTS/ios-host-desktop.png" 2>/dev/null || true
fi
# 收摊：杀掉残留的游戏子进程（命令行里带沙盒游戏目录路径，行内匹配）
pkill -f "MintLauncher/minecraft" 2>/dev/null || true
xcrun simctl terminate "$UDID" dev.mint.mint >/dev/null 2>&1 || true
echo "==== 应用 console 尾部 ===="
tail -40 "$SHOTS/game-console.log" || true

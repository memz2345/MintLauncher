#!/usr/bin/env bash
# iOS「应用内安装 Mod」探针执行器（CI 用）。
#
# 往沙盒写 mod_probe.json → 重拉应用（IosModProbe 在控制器初始化后读标记，
# 走 Modrinth 版本查询 → Downloader 下载（sha1 校验）→ 落版本 mods 目录）→
# 轮询 mod_probe_result.txt；装完后重拉「内容管理」页截图留证。
#
# 用法：bash tool/ci/ios_mod_probe.sh <simulator-udid>
set -euo pipefail

UDID="${1:?usage: ios_mod_probe.sh <simulator-udid>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHOTS="$ROOT/build/shots"
mkdir -p "$SHOTS"

DATA="$(xcrun simctl get_app_container "$UDID" dev.mint.mint data)"
RESULT="$DATA/Documents/mod_probe_result.txt"
GAME_JSON="$DATA/Documents/game_probe.json"

restore() {
  rm -f "$DATA/Documents/mod_probe.json"
  if [ -f "$GAME_JSON.off" ]; then
    mv "$GAME_JSON.off" "$GAME_JSON" || true
  fi
}
trap restore EXIT

rm -f "$RESULT" "$DATA/Documents/mod_probe_progress.txt" \
      "$SHOTS/mod_probe_result.txt" "$SHOTS/mod_probe_progress.txt"
# 游戏探针标记暂时收起，免得同一次启动又把游戏拉起来。
if [ -f "$GAME_JSON" ]; then mv "$GAME_JSON" "$GAME_JSON.off"; fi
cat > "$DATA/Documents/mod_probe.json" <<JSON
{"version":"1.20.4","mods":["fabric-api"]}
JSON

xcrun simctl terminate "$UDID" dev.mint.mint >/dev/null 2>&1 || true
xcrun simctl launch --console-pty "$UDID" dev.mint.mint \
  >"$SHOTS/mod-console.log" 2>&1 &

got=0
for _ in $(seq 1 120); do # 120 * 4s = 8 分钟上限
  sleep 4
  if [ -f "$RESULT" ]; then
    got=1
    break
  fi
done

echo "==== Mod 安装探针结果 ===="
if [ "$got" = 1 ]; then
  cat "$RESULT"
  cp "$RESULT" "$SHOTS/mod_probe_result.txt"
  cp "$DATA/Documents/mod_probe_progress.txt" \
    "$SHOTS/mod_probe_progress.txt" 2>/dev/null || true
else
  echo "!! 探针超时（8 分钟无结果文件）"
  printf '%s\n' "!! iOS Mod 安装探针超时：应用没有写出 mod_probe_result.txt" \
    >"$SHOTS/mod_probe_result.txt"
  tail -40 "$SHOTS/mod-console.log" || true
fi

# 装完后重拉应用落「内容管理」页：截图里应能看到刚装好的 Mod。
rm -f "$DATA/Documents/mod_probe.json"
printf '%s' '{"page":"content","themeMode":"light"}' \
  >"$DATA/Documents/mint_test_config.json"
xcrun simctl terminate "$UDID" dev.mint.mint >/dev/null 2>&1 || true
sleep 2
# 先拍一张 SpringBoard 基线：iOS 26 默认壁纸本身就 >3MB，不能再用文件大小
# 当「是不是应用画面」的判据（上一轮就是这么把桌面当截图收了的）。
xcrun simctl io "$UDID" screenshot "$SHOTS/ios-mod-springboard.png" || true
xcrun simctl launch --console-pty "$UDID" dev.mint.mint \
  >"$SHOTS/mod-console-content.log" 2>&1 &
# 固定等 15s（首帧 + 页面推入 + 壁纸解码），再连拍一张稳定的。
sleep 15
xcrun simctl io "$UDID" screenshot "$SHOTS/ios-mod-content.png" || true
sleep 8
xcrun simctl io "$UDID" screenshot "$SHOTS/ios-mod-content-stable.png" || true
if [ -f "$SHOTS/ios-mod-content-stable.png" ]; then
  mv "$SHOTS/ios-mod-content-stable.png" "$SHOTS/ios-mod-content.png"
fi
ls -la "$SHOTS"/ios-mod-content.png "$SHOTS"/ios-mod-springboard.png 2>/dev/null || true
# 应用 console + 最近 2 分钟 Runner 统一日志（Dart 异常 / 原生崩溃都在这里）。
xcrun simctl spawn "$UDID" log show --last 2m \
  --predicate 'process == "Runner"' --style compact \
  >"$SHOTS/mod-unified-log.txt" 2>&1 || true
tail -30 "$SHOTS/mod-console-content.log" || true

# 宿主侧 mods 目录清单：文件确实落进 iOS 沙盒的证据。
MODS="$DATA/Documents/MintLauncher/minecraft/mods"
{
  ls -la "$MODS" 2>/dev/null || echo "(没有 $MODS)"
} >"$SHOTS/mod-probe-mods-dir.txt"
cat "$SHOTS/mod-probe-mods-dir.txt"

xcrun simctl terminate "$UDID" dev.mint.mint >/dev/null 2>&1 || true

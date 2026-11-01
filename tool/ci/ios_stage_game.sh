#!/usr/bin/env bash
# iOS「应用内启动游戏」探针的素材预置（CI 用）。
#
# 1. 宿主 mac 上用 e2e 工具链安装 Minecraft（natives 要按宿主 macOS 选
#    分类器，模拟器里装会选错）；
# 2. Adoptium JRE 21 mac/aarch64 原样塞进沙盒（游戏子进程是 macOS 进程，
#    不需要重打平台标签）；
# 3. 游戏目录 / 客户端 jar / 探针配置放进应用沙盒，IosGameLaunchProbe
#    启动时接管。
#
# 用法：bash tool/ci/ios_stage_game.sh <simulator-udid>
set -euo pipefail

UDID="${1:?usage: ios_stage_game.sh <simulator-udid>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/ios-game"
VERSION="${MINT_PROBE_VERSION:-1.20.4}"
mkdir -p "$BUILD"

echo "==== 1. 宿主安装 Minecraft ${VERSION}（e2e 工具链 --install-only）===="
MINT_E2E_MIRROR=official dart run tool/e2e_launch_test.dart "$VERSION" \
  --install-only 2>&1 | tee "$BUILD/e2e-install.log"

GAME="$HOME/Library/Application Support/MintLauncher/minecraft"
JAR="$GAME/versions/$VERSION/$VERSION.jar"
if [ ! -f "$JAR" ]; then
  echo "!! 没找到 ${JAR}（宿主安装失败？看 $BUILD/e2e-install.log）"
  exit 1
fi

echo "==== 2. 下载 Adoptium JRE 21 (mac/aarch64) ===="
LINK="$(curl -fsSL \
  'https://api.adoptium.net/v3/assets/latest/21/hotspot?os=mac&architecture=aarch64&image_type=jre' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["binary"]["package"]["link"])')"
echo "$LINK"
curl -fsSL --retry 3 -o "$BUILD/jre21-mac.tar.gz" "$LINK"
rm -rf "$BUILD/jdk"
mkdir -p "$BUILD/jdk"
tar -xzf "$BUILD/jre21-mac.tar.gz" -C "$BUILD/jdk"
JDK_HOME="$(find "$BUILD/jdk" -type f -path '*/Contents/Home/bin/java' \
  -print -quit | sed -E 's#/bin/java$##')"
if [ -z "$JDK_HOME" ]; then
  echo "!! 解压后没找到 Contents/Home"
  exit 1
fi

echo "==== 3. 预置进应用沙盒 ===="
DATA="$(xcrun simctl get_app_container "$UDID" dev.mint.mint data)"
rm -rf "$DATA/Documents/macos_jdk" "$DATA/Documents/MintLauncher"
# 保持 Contents/Home 布局（探针按 macos_jdk/Contents/Home/bin/java 找）
mkdir -p "$DATA/Documents/macos_jdk/Contents"
cp -R "$JDK_HOME" "$DATA/Documents/macos_jdk/Contents/Home"
mkdir -p "$DATA/Documents/MintLauncher"
cp -R "$GAME" "$DATA/Documents/MintLauncher/minecraft"
cp "$JAR" "$DATA/Documents/mc-client.jar"
rm -f "$DATA/Documents/game_probe.json" \
      "$DATA/Documents/game_probe_result.txt" \
      "$DATA/Documents/game_probe_progress.txt" \
      "$DATA/Documents/game-launch.log" \
      "$DATA/Documents/spawn-trace.log" \
      "$DATA/Documents/spawn-file-test.txt" \
      "$DATA/Documents/mint_game_launch.sh"
cat > "$DATA/Documents/game_probe.json" <<JSON
{"version":"$VERSION","memoryMb":2048,"width":854,"height":480}
JSON
du -sh "$DATA/Documents/MintLauncher/minecraft" "$DATA/Documents/macos_jdk"
ls -la "$DATA/Documents"

#!/usr/bin/env bash
# iOS 模拟器「应用内起 JVM」实验（CI 用）。
#
# 背景：iOS 模拟器的 dlopen 会校验 Mach-O 的 LC_BUILD_VERSION 平台标签，
# macOS 版 libjvm.dylib 直接加载会被拒：
#   incompatible platform (have 'macOS', need 'iOS-simulator')
# 这里把 Temurin macOS arm64 JRE 里的所有 Mach-O 重打成 ios-simulator、
# 重新 ad-hoc 签名，塞进应用沙盒，让 ios_jvm_probe.dart 用 FFI dlopen +
# JNI_CreateJavaVM + System.getProperty 验证「JVM 与 Java 代码能跑」。
#
# 用法：bash tool/ci/ios_jvm_probe.sh <simulator-udid>
set -euo pipefail

UDID="${1:?usage: ios_jvm_probe.sh <simulator-udid>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/ios-jre"
mkdir -p "$BUILD" "$ROOT/build/shots"

DATA="$(xcrun simctl get_app_container "$UDID" dev.mint.mint data)"
DOCS="$DATA/Documents"
mkdir -p "$DOCS"

if [ ! -f "$BUILD/libjvm.dylib.ready" ]; then
  echo "==== 1. 下载 Temurin macOS arm64 JRE 21 ===="
  LINK="$(curl -fsSL \
    'https://api.adoptium.net/v3/assets/latest/21/hotspot?os=mac&architecture=aarch64&image_type=jre' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["binary"]["package"]["link"])')"
  echo "$LINK"
  curl -fsSL --retry 3 -o "$BUILD/jre21-mac.tar.gz" "$LINK"

  echo "==== 2. 解压 ===="
  rm -rf "$BUILD/jre"
  mkdir -p "$BUILD/jre"
  tar -xzf "$BUILD/jre21-mac.tar.gz" -C "$BUILD/jre"
  HOME_DIR="$(find "$BUILD/jre" -type f -path '*/Contents/Home/lib/server/libjvm.dylib' \
    -print -quit | sed -E 's#/lib/server/libjvm\.dylib$##')"
  if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
    echo "!! 解压后没找到 Contents/Home"
    exit 1
  fi
  echo "java.home=$HOME_DIR"

  echo "==== 3. 重打平台标签 macos -> ios-simulator + ad-hoc 重签 ===="
  retagged=0
  while IFS= read -r -d '' f; do
    if ! file -b "$f" | grep -q 'Mach-O'; then
      continue
    fi
    tmp="$f.retag"
    if vtool -set-build-version ios-simulator 17.0 17.0 -replace \
        -output "$tmp" "$f" >/dev/null 2>&1 \
      || vtool -set-build-version ios-simulator 17.0 17.0 \
        -output "$tmp" "$f" >/dev/null 2>&1; then
      mv "$tmp" "$f"
      codesign --force --sign - --timestamp=none "$f" >/dev/null 2>&1 || true
      retagged=$((retagged + 1))
    else
      rm -f "$tmp"
    fi
  done < <(find "$HOME_DIR" -type f -print0)
  echo "retagged=$retagged"

  echo "==== 4. 校验 libjvm 平台标签 ===="
  vtool -show-build "$HOME_DIR/lib/server/libjvm.dylib" | tee "$BUILD/libjvm.build.txt"

  rm -rf "$DOCS/jvm_ios_sim"
  cp -R "$HOME_DIR" "$DOCS/jvm_ios_sim"
  touch "$BUILD/libjvm.dylib.ready"
else
  echo "==== 复用已重打的 JRE ===="
  if [ ! -d "$DOCS/jvm_ios_sim" ]; then
    SRC="$(find "$BUILD/jre" -type f -path '*/Contents/Home/lib/server/libjvm.dylib' \
      -print -quit | sed -E 's#/lib/server/libjvm\.dylib$##')"
    cp -R "$SRC" "$DOCS/jvm_ios_sim"
  fi
fi

echo "==== 5. 触发应用内探针 ===="
rm -f "$DOCS/jvm_probe_result.txt" "$DOCS/run_jvm_probe"
touch "$DOCS/run_jvm_probe"
xcrun simctl terminate "$UDID" dev.mint.mint >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" dev.mint.mint >/dev/null 2>&1 || true

for _ in $(seq 1 48); do
  sleep 5
  if [ -f "$DOCS/jvm_probe_result.txt" ]; then
    break
  fi
done

echo "==== JVM probe result ===="
if [ -f "$DOCS/jvm_probe_result.txt" ]; then
  cat "$DOCS/jvm_probe_result.txt"
  cp "$DOCS/jvm_probe_result.txt" "$ROOT/build/shots/jvm_probe_result.txt"
else
  echo "(无结果文件)"
  printf '%s\n' "!! iOS JVM 探针没有产出结果（应用可能被 watchdog 杀掉）" \
    >"$ROOT/build/shots/jvm_probe_result.txt"
fi

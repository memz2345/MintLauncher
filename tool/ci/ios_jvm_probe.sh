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
  # vtool 的 platform 参数是 XNU 的数字枚举，不是字符串：
  #   1 = macOS、2 = iOS、7 = IOSSIMULATOR（iOS 模拟器）。
  # 参考：https://bogo.wtf/arm64-to-sim-dylibs.html
  retagged=0
  failed=0
  while IFS= read -r -d '' f; do
    if ! file -b "$f" | grep -q 'Mach-O'; then
      continue
    fi
    tmp="$f.retag"
    codesign --remove-signature "$f" >/dev/null 2>&1 || true
    if vtool -arch arm64 -set-build-version 7 17.0 17.0 -replace \
        -output "$tmp" "$f" >/dev/null 2>&1; then
      mv "$tmp" "$f"
      codesign --force --sign - --timestamp=none "$f" >/dev/null 2>&1 || true
      retagged=$((retagged + 1))
    else
      failed=$((failed + 1))
      if [ "$failed" -le 3 ]; then
        echo "!! vtool 失败: $f"
        vtool -arch arm64 -set-build-version 7 17.0 17.0 -replace \
          -output "$tmp" "$f" 2>&1 | head -6 || true
      fi
      rm -f "$tmp"
    fi
  done < <(find "$HOME_DIR" -type f -print0)
  echo "retagged=$retagged failed=$failed"

  echo "==== 3.5 依赖路径改写：macOS 绝对框架路径 → 短路径符号链接农场 ===="
  # 上一轮 JNI_CreateJavaVM 死因：libjava.dylib 硬编码依赖
  #   /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
  # iOS 模拟器 runtime 里没有 Versions/A 这套 macOS 布局（框架是平铺的）。
  #
  # 直接把依赖改写成 runtimeRoot 绝对路径行不通：install_name_tool 不允许
  # 把 load command 里的字符串改长（"larger updated load commands do not
  # fit"），而 runtimeRoot 前缀（~110 字符）远比 /System/Library 长。
  # 所以在根上建一个**符号链接农场** /m/<短码>，每个码 → 模拟器 runtime
  # 的对应 framework，改写后的依赖串（/m/<码>/<名字>）恒短于原串。
  # /usr/lib 的依赖上一轮 dlopen(libjvm) 已验证能解析（宿主 dyld 兜底），
  # 保持原样不动，少改少错。
  FARM=/m/mint-sim-jre
  sudo rm -rf "$FARM"
  sudo mkdir -p "$FARM"
  RUNTIME_ROOT="$(python3 - "$UDID" <<'PY'
import json, subprocess, sys
udid = sys.argv[1]
devices = json.loads(subprocess.run(
    ['xcrun', 'simctl', 'list', 'devices', '-j'],
    capture_output=True, text=True).stdout)['devices']
rt_id = next((rt for rt, lst in devices.items()
              for d in lst if d.get('udid') == udid), None)
if not rt_id:
    sys.exit('!! devices.json 里找不到这台模拟器的 runtime')
runtimes = json.loads(subprocess.run(
    ['xcrun', 'simctl', 'list', 'runtimes', '-j'],
    capture_output=True, text=True).stdout)['runtimes']
rt = next((r for r in runtimes if r['identifier'] == rt_id), None)
if not rt or not rt.get('runtimeRoot'):
    sys.exit(f'!! runtime {rt_id} 没有 runtimeRoot')
print(rt['runtimeRoot'])
PY
)"
  echo "runtimeRoot=$RUNTIME_ROOT"
  if [ ! -d "$RUNTIME_ROOT/System/Library/Frameworks/CoreFoundation.framework" ]; then
    echo "!! runtimeRoot 里没有 CoreFoundation.framework，改写方案不成立"
    exit 1
  fi

  python3 - "$HOME_DIR" "$RUNTIME_ROOT" "$FARM" "$BUILD/rewrite-map.txt" <<'PY'
import os, re, subprocess, sys

home, rr, farm, map_path = sys.argv[1:5]
MAGICS = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe',
          b'\xfe\xed\xfa\xcf', b'\xbe\xba\xfe\xca')
# /System/Library/Frameworks/<F>.framework[/Versions/<V>]/<leaf>
FW_RE = re.compile(
    r'^/System/Library/((?:Private)?Frameworks/([^/]+)\.framework)'
    r'(/Versions/[^/]+)?/(.+)$')

mapping = {}  # dep 前缀 -> /m/... 短路径

def short_path(dep):
    """依赖串 → 农场短路径（必须不长于原串，install_name_tool 才肯改）。"""
    if not dep.startswith('/System/Library/'):
        return None
    m = FW_RE.match(dep)
    if m:
        framework_dir, fw_name, _, leaf = m.groups()
        if framework_dir not in mapping:
            code = f'f{len(mapping):02d}'
            target = f'{rr}/System/Library/{framework_dir}'
            subprocess.run(['sudo', 'ln', '-sfn', target, f'{farm}/{code}'],
                           check=True)
            mapping[framework_dir] = f'{farm}/{code}'
            print(f'  {farm}/{code} -> {target}')
        # 丢掉 Versions 段：/m/f00/<leaf> 直接是平铺框架二进制
        new = f'{mapping[framework_dir]}/{leaf}'
    else:
        # 非框架的 /System/Library/...（如有）：整段映射到 runtime
        new = rr + dep
        if len(new) > len(dep):
            print(f'  !! 跳过（改写后会变长）: {dep}')
            return None
    if len(new) > len(dep):
        print(f'  !! 跳过（改写后会变长）: {dep}')
        return None
    return new

def deps_of(path):
    out = subprocess.run(['otool', '-L', path],
                         capture_output=True, text=True).stdout
    return [l.split(' (')[0].strip().split()[0]
            for l in out.splitlines()[1:] if l.strip()]

changed = 0
for dirpath, _, files in os.walk(home):
    for name in files:
        f = os.path.join(dirpath, name)
        with open(f, 'rb') as fh:
            if fh.read(4) not in MAGICS:
                continue
        rewrote = False
        for dep in deps_of(f):
            new = short_path(dep)
            if new and new != dep:
                r = subprocess.run(['install_name_tool', '-change', dep,
                                    new, f], capture_output=True, text=True)
                if r.returncode != 0:
                    print(f'  !! install_name_tool 失败 {f}: '
                          f'{r.stderr.strip()[:120]}')
                else:
                    rewrote = True
        if rewrote:
            changed += 1
            subprocess.run(['codesign', '--force', '--sign', '-',
                            '--timestamp=none', f], capture_output=True)
print(f'rewrite_files={changed} frameworks_mapped={len(mapping)}')
open(map_path, 'w').write(
    '\n'.join(f'{k} -> {v}' for k, v in mapping.items()) + '\n')
PY

  echo "==== 3.6 改写后依赖审计（农场里解析不到的依赖只记日志，boot 到才算数）===="
  python3 - "$HOME_DIR" "$FARM" "$BUILD/missing-deps.txt" <<'PY'
import os, subprocess, sys
home, farm, out_path = sys.argv[1:4]
MAGICS = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe',
          b'\xfe\xed\xfa\xcf', b'\xbe\xba\xfe\xca')
missing = {}
for dirpath, _, files in os.walk(home):
    for name in files:
        f = os.path.join(dirpath, name)
        with open(f, 'rb') as fh:
            if fh.read(4) not in MAGICS:
                continue
        out = subprocess.run(['otool', '-L', f],
                             capture_output=True, text=True).stdout
        for l in out.splitlines()[1:]:
            if not l.strip():
                continue
            dep = l.split(' (')[0].strip().split()[0]
            if dep.startswith(farm) and not os.path.exists(dep):
                missing.setdefault(dep, []).append(os.path.relpath(f, home))
lines = [f'MISSING {d}  <- {len(u)} 个文件, e.g. {u[0]}'
         for d, u in sorted(missing.items())]
lines.append(f'total_missing={len(missing)}')
open(out_path, 'w').write('\n'.join(lines) + '\n')
print('\n'.join(lines))
PY

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
# --console-pty 把应用 stdout/stderr 留在文件里：JVM/dyld 崩进程时，
# 唯一能看到原因的地方（Dart 的 catch 捕获不到 native 崩溃）。
xcrun simctl launch --console-pty "$UDID" dev.mint.mint \
  >"$ROOT/build/shots/jvm-console.log" 2>&1 &

for _ in $(seq 1 48); do
  sleep 5
  if [ -f "$DOCS/jvm_probe_result.txt" ]; then
    break
  fi
done

# 模拟器进程的统一日志（dyld / watchdog 终止原因）。
xcrun simctl spawn "$UDID" log show --last 10m \
  --predicate 'process == "Runner"' --style compact \
  >"$ROOT/build/shots/jvm-unified-log.txt" 2>&1 || true

echo "==== JVM probe result ===="
if [ -f "$DOCS/jvm_probe_result.txt" ]; then
  cat "$DOCS/jvm_probe_result.txt"
  cp "$DOCS/jvm_probe_result.txt" "$ROOT/build/shots/jvm_probe_result.txt"
else
  echo "(无结果文件)"
  printf '%s\n' "!! iOS JVM 探针没有产出结果（应用可能在 dlopen / JVM 创建时崩溃）" \
    >"$ROOT/build/shots/jvm_probe_result.txt"
  echo "==== 应用 console 尾部 ===="
  tail -80 "$ROOT/build/shots/jvm-console.log" || true
  echo "==== 统一日志尾部 ===="
  tail -40 "$ROOT/build/shots/jvm-unified-log.txt" || true
fi
# 改写映射 / 依赖审计一并带走（artifact + Release 都要能对账）。
for f in rewrite-map.txt missing-deps.txt libjvm.build.txt; do
  [ -f "$BUILD/$f" ] && cp "$BUILD/$f" "$ROOT/build/shots/jvm-$f" || true
done
xcrun simctl terminate "$UDID" dev.mint.mint >/dev/null 2>&1 || true

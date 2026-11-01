import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// iOS 起 JVM 探针（「试一下能不能启动游戏」的第一性实验）。
///
/// 真机路线（PojavLauncher_iOS）：OpenJDK 移植 + JIT 特权（AltStore/
/// TrollStore）+ MetalANGLE 渲染 —— 大工程，见 README。但 **iOS 模拟器**
/// 的进程本质上跑在 macOS 上：允许 JIT（无 W^X 限制）、允许 dlopen 未
/// 签名的 dylib。所以先在模拟器里验证最底层的一环 —— 用 FFI 直接
/// `dlopen` macOS arm64 的 `libjvm.dylib` 并调用 `JNI_CreateJavaVM`，
/// 看「应用内起 JVM」在模拟器上通不通。通了，模拟器上连 JIT 都是全速的；
/// 不通，拿到第一手的失败原因。
///
/// 触发：沙盒 `Documents/run_jvm_probe` 标记文件（CI 塞入）。流程在
/// 后台 isolate 跑（下载 ~50MB + 解压 + 起虚拟机），结果写
/// `Documents/jvm_probe_result.txt` 后删标记。
class IosJvmProbe {
  IosJvmProbe._();

  /// main.dart 在 iOS 上后台调用；没有标记文件时立即返回。
  static void maybeRun(String docsPath) {
    final marker = File(p.join(docsPath, 'run_jvm_probe'));
    if (!marker.existsSync()) return;
    unawaited(
      Isolate.run(() => run(docsPath)).catchError((Object e) {
        _append(docsPath, '!! 探针 isolate 异常: $e');
      }),
    );
  }

  static void _append(String docsPath, String line) {
    try {
      File(p.join(docsPath, 'jvm_probe_result.txt'))
          .writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  static Future<void> run(String docsPath) async {
    final resultFile = File(p.join(docsPath, 'jvm_probe_result.txt'));
    final buf = StringBuffer();
    buf.writeln('=== iOS JVM probe ${DateTime.now().toIso8601String()} ===');
    try {
      // ── 1. 查 Adoptium 的 macOS arm64 JRE ──
      buf.writeln('[1] 查询 Adoptium JRE 21 (mac/aarch64)...');
      final link = await _fetchJreLink(21);
      buf.writeln('    $link');

      // ── 2. 下载 ──
      final tarPath = p.join(docsPath, 'jre21-mac.tar.gz');
      buf.writeln('[2] 下载到 ${p.basename(tarPath)}...');
      await _download(link, tarPath, buf);

      // ── 3. 解压（手动逐条写，顺带打印清单定位问题）──
      buf.writeln('[3] 解压...');
      final home = _extractSync(tarPath, p.join(docsPath, 'jvm_probe'), buf);
      buf.writeln('    java.home=$home');

      // ── 4. dlopen libjvm ──
      final libjvm = p.join(home, 'lib', 'server', 'libjvm.dylib');
      buf.writeln('[4] dlopen $libjvm');
      final dylib = DynamicLibrary.open(libjvm);
      buf.writeln('    OK');

      // ── 5. JNI_CreateJavaVM ──
      final create = dylib
          .lookupFunction<
            Int32 Function(
              Pointer<Pointer<Void>>,
              Pointer<Pointer<Void>>,
              Pointer<JavaVMInitArgs>,
            ),
            int Function(
              Pointer<Pointer<Void>>,
              Pointer<Pointer<Void>>,
              Pointer<JavaVMInitArgs>,
            )
          >('JNI_CreateJavaVM');

      final options = calloc<JavaVMOption>(2);
      final homeOpt = '-Djava.home=$home'.toNativeUtf8();
      final heapOpt = '-Xmx512m'.toNativeUtf8();
      options[0].optionString = homeOpt.cast();
      options[0].extraInfo = nullptr;
      options[1].optionString = heapOpt.cast();
      options[1].extraInfo = nullptr;
      final args = calloc<JavaVMInitArgs>();
      args.ref.version = 0x00010008; // JNI_VERSION_1_8
      args.ref.nOptions = 2;
      args.ref.options = options;
      args.ref.ignoreUnrecognized = 1;

      final vmOut = calloc<Pointer<Void>>();
      final envOut = calloc<Pointer<Void>>();
      buf.writeln('[5] JNI_CreateJavaVM(JNI_VERSION_1_8, 2 options)...');
      final rc = create(vmOut, envOut, args);
      buf.writeln('    rc=$rc (${rc == 0 ? 'JNI_OK ✅' : '失败 ❌'})');
      if (rc != 0) {
        buf.writeln('== ❌ JVM 未能启动 ==');
        throw 'JNI_CreateJavaVM rc=$rc';
      }

      // ── 6. JNIEnv 函数表取 GetVersion（index 4，前面是 4 个 reserved）──
      final env = envOut.value;
      final table = env
          .cast<Pointer<NativeFunction<Int32 Function(Pointer<Void>)>>>();
      final getVersion = table[4]
          .asFunction<int Function(Pointer<Void>)>();
      final jniVersion = getVersion(env);
      buf.writeln(
        '[6] JNIEnv->GetVersion() = 0x${jniVersion.toRadixString(16)} '
        '(JNI ${jniVersion >> 16}.${jniVersion & 0xFFFF})',
      );

      // ── 7. JavaVM 函数表 DestroyJavaVM（index 3）正常收摊 ──
      final vm = vmOut.value;
      final vmTable = vm
          .cast<Pointer<NativeFunction<Int32 Function(Pointer<Void>)>>>();
      final destroy = vmTable[3].asFunction<int Function(Pointer<Void>)>();
      final drc = destroy(vm);
      buf.writeln('[7] DestroyJavaVM rc=$drc');
      buf.writeln('== ✅ 应用内起 JVM 成功（iOS 模拟器）——启动游戏的');
      buf.writeln('   下一环是 LWJGL + MC 主类调用，见 README iOS 章节 ==');
    } catch (e, st) {
      buf.writeln('!! 失败: $e');
      buf.writeln('== ❌ 探针失败 ==');
      buf.writeln(st.toString());
    }
    resultFile.parent.createSync(recursive: true);
    resultFile.writeAsStringSync('${buf.toString()}\n');
    try {
      File(p.join(docsPath, 'run_jvm_probe')).deleteSync();
    } catch (_) {}
    // 大文件不留着占沙盒。
    try {
      Directory(p.join(docsPath, 'jvm_probe'))
          .deleteSync(recursive: true);
      File(p.join(docsPath, 'jre21-mac.tar.gz')).deleteSync();
    } catch (_) {}
  }

  static Future<String> _fetchJreLink(int major) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse(
          'https://api.adoptium.net/v3/assets/latest/$major/hotspot'
          '?os=mac&architecture=aarch64&image_type=jre',
        ),
      );
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      final list = jsonDecode(body) as List<dynamic>;
      if (list.isEmpty) throw 'Adoptium 无结果';
      final binary = (list.first as Map<String, dynamic>)['binary']
          as Map<String, dynamic>;
      return (binary['package'] as Map<String, dynamic>)['link'] as String;
    } finally {
      client.close();
    }
  }

  static Future<void> _download(String url, String dest, StringBuffer buf) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      final sink = File(dest).openWrite();
      var total = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        total += chunk.length;
      }
      await sink.flush();
      await sink.close();
      buf.writeln('    ${(total / (1 << 20)).toStringAsFixed(1)} MB');
    } finally {
      client.close();
    }
  }

  static String _extractSync(
    String tarPath,
    String destRoot,
    StringBuffer buf,
  ) {
    final tarBytes = GZipDecoder().decodeBytes(File(tarPath).readAsBytesSync());
    final archive = TarDecoder().decodeBytes(tarBytes);
    String? home;
    var written = 0;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final outPath = p.join(destRoot, entry.name);
      if (!p.normalize(outPath).startsWith(p.normalize(destRoot))) {
        continue; // 防路径穿越
      }
      File(outPath)
        ..createSync(recursive: true)
        ..writeAsBytesSync(entry.readBytes() ?? Uint8List(0));
      written++;
      // <destRoot>/<jdk>/Contents/Home/lib/server/libjvm.dylib
      if (entry.name.endsWith('/Contents/Home/lib/server/libjvm.dylib')) {
        buf.writeln('    命中条目: ${entry.name}');
        final marker = '/Contents/Home/';
        final idx = outPath.indexOf(marker);
        home = outPath.substring(0, idx + marker.length - 1);
      }
    }
    buf.writeln('    写出 $written 个文件');
    if (home == null) {
      final root = Directory(destRoot);
      final listing = root.existsSync()
          ? root
                .listSync()
                .map((e) => p.basename(e.path))
                .take(20)
                .join(', ')
          : '(目录不存在)';
      buf.writeln('    destRoot 顶层: $listing');
      throw '解压后没找到 Contents/Home';
    }
    return home;
  }
}

// ─────────────── FFI 结构（JNI invoke interface 的最小子集） ───────────────

/// `typedef struct { char *optionString; void *extraInfo; } JavaVMOption;`
final class JavaVMOption extends Struct {
  external Pointer<Char> optionString;
  external Pointer<Void> extraInfo;
}

/// `typedef struct { jint version; jint nOptions; JavaVMOption *options;
///    jboolean ignoreUnrecognized; } JavaVMInitArgs;`（arm64 上 24 字节，
/// 与 C 布局一致）。
final class JavaVMInitArgs extends Struct {
  @Int32()
  external int version;

  @Int32()
  external int nOptions;

  external Pointer<JavaVMOption> options;

  @Uint8()
  external int ignoreUnrecognized;
}

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
      File(
        p.join(docsPath, 'jvm_probe_result.txt'),
      ).writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  static Future<void> run(String docsPath) async {
    final resultFile = File(p.join(docsPath, 'jvm_probe_result.txt'));
    final buf = StringBuffer();
    buf.writeln('=== iOS JVM probe ${DateTime.now().toIso8601String()} ===');
    try {
      // ── 1. 预置 JRE（CI 把 macOS JRE 重打成 ios-simulator 平台标签 +
      //    重签后塞进沙盒）优先；没有就走原来的 macOS 下载（平台校验必挂，
      //    保留这条路径是为了拿到「没打标签时」的对照错误）。
      String home;
      final staged = p.join(docsPath, 'jvm_ios_sim');
      if (File(p.join(staged, 'lib', 'server', 'libjvm.dylib')).existsSync()) {
        home = staged;
        buf.writeln('[1] 使用 CI 预置的 iOS-simulator 重签 JRE');
        buf.writeln('    java.home=$home');
      } else {
        buf.writeln('[1] 查询 Adoptium JRE 21 (mac/aarch64)...');
        final link = await _fetchJreLink(21);
        buf.writeln('    $link');

        final tarPath = p.join(docsPath, 'jre21-mac.tar.gz');
        buf.writeln('[2] 下载到 ${p.basename(tarPath)}...');
        await _download(link, tarPath, buf);

        buf.writeln('[3] 解压...');
        home = _extractSync(tarPath, p.join(docsPath, 'jvm_probe'), buf);
        buf.writeln('    java.home=$home');
      }

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
      final getVersion = table[4].asFunction<int Function(Pointer<Void>)>();
      final jniVersion = getVersion(env);
      buf.writeln(
        '[6] JNIEnv->GetVersion() = 0x${jniVersion.toRadixString(16)} '
        '(JNI ${jniVersion >> 16}.${jniVersion & 0xFFFF})',
      );

      // ── 7. 真正跑一段 Java：System.getProperty("java.version") ──
      // 只证明「虚拟机对象起来了」不够；能走 JNI 调进 Java 标准库，
      // 才说明这个 iOS-simulator JRE 是可用的。
      try {
        buf.writeln('[7] System.getProperty(java.version / java.vm.name)');
        buf.writeln('    java.version=${_javaProperty(env, 'java.version')}');
        buf.writeln('    java.vm.name=${_javaProperty(env, 'java.vm.name')}');
      } catch (e) {
        buf.writeln('!! [7] Java 属性读取失败: $e');
      }

      // ── 8. JavaVM 函数表 DestroyJavaVM（index 3）正常收摊 ──
      final vm = vmOut.value;
      final vmTable = vm
          .cast<Pointer<NativeFunction<Int32 Function(Pointer<Void>)>>>();
      final destroy = vmTable[3].asFunction<int Function(Pointer<Void>)>();
      final drc = destroy(vm);
      buf.writeln('[8] DestroyJavaVM rc=$drc');
      buf.writeln('== ✅ 应用内起 JVM 并执行 Java 代码成功（iOS 模拟器）==');
      buf.writeln('   下一环是 LWJGL 图形后端 / MC 主类，见 README iOS 章节');
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
      Directory(p.join(docsPath, 'jvm_probe')).deleteSync(recursive: true);
      File(p.join(docsPath, 'jre21-mac.tar.gz')).deleteSync();
    } catch (_) {}
  }

  /// 走 JNI 调 `System.getProperty(key)`，返回 Java 字符串。
  ///
  /// 函数表索引见 JNI 规范：FindClass=6、GetStaticMethodID=113、
  /// CallStaticObjectMethodA=116、NewStringUTF=167、GetStringUTFChars=169、
  /// ReleaseStringUTFChars=170、ExceptionOccurred=15、ExceptionClear=17
  ///（16 是 ExceptionDescribe，别用错）。
  static String _javaProperty(Pointer<Void> env, String key) {
    final findClass = env
        .cast<
          Pointer<
            NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)>
          >
        >()[6]
        .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)>();
    final getStaticMethodId = env
        .cast<
          Pointer<
            NativeFunction<
              Pointer<Void> Function(
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Utf8>,
                Pointer<Utf8>,
              )
            >
          >
        >()[113]
        .asFunction<
          Pointer<Void> Function(
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          )
        >();
    final newStringUtf = env
        .cast<
          Pointer<
            NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)>
          >
        >()[167]
        .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)>();
    final callStaticObjectA = env
        .cast<
          Pointer<
            NativeFunction<
              Pointer<Void> Function(
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Void>,
              )
            >
          >
        >()[116]
        .asFunction<
          Pointer<Void> Function(
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
          )
        >();
    final getStringUtfChars = env
        .cast<
          Pointer<
            NativeFunction<
              Pointer<Utf8> Function(
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Void>,
              )
            >
          >
        >()[169]
        .asFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
        >();
    final releaseStringUtfChars = env
        .cast<
          Pointer<
            NativeFunction<
              Void Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>)
            >
          >
        >()[170]
        .asFunction<
          void Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>)
        >();
    final exceptionOccurred = env
        .cast<
          Pointer<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>
        >()[15]
        .asFunction<Pointer<Void> Function(Pointer<Void>)>();
    final exceptionClear = env
        .cast<Pointer<NativeFunction<Void Function(Pointer<Void>)>>>()[17]
        .asFunction<void Function(Pointer<Void>)>();

    void checkException() {
      final exc = exceptionOccurred(env);
      if (exc != nullptr) {
        exceptionClear(env);
        throw 'JNI exception（属性 $key）';
      }
    }

    final systemName = 'java/lang/System'.toNativeUtf8();
    final methodName = 'getProperty'.toNativeUtf8();
    final signature = '(Ljava/lang/String;)Ljava/lang/String;'.toNativeUtf8();
    final keyJava = key.toNativeUtf8();
    Pointer<Void> systemClass = nullptr;
    Pointer<Void> methodId = nullptr;
    Pointer<Void> javaKey = nullptr;
    Pointer<Void> value = nullptr;
    Pointer<Uint64> arg = nullptr;
    Pointer<Utf8> chars = nullptr;
    try {
      systemClass = findClass(env, systemName);
      checkException();
      if (systemClass == nullptr) throw 'FindClass(java/lang/System) 返回 null';
      methodId = getStaticMethodId(env, systemClass, methodName, signature);
      checkException();
      if (methodId == nullptr) throw 'GetStaticMethodID 返回 null';
      javaKey = newStringUtf(env, keyJava);
      checkException();
      if (javaKey == nullptr) throw 'NewStringUTF 返回 null';
      // jvalue 是 8 字节 union；第一个成员就是对象指针。
      arg = calloc<Uint64>();
      arg.value = javaKey.address;
      value = callStaticObjectA(env, systemClass, methodId, arg.cast<Void>());
      checkException();
      if (value == nullptr) throw 'System.getProperty($key) 返回 null';
      chars = getStringUtfChars(env, value, nullptr);
      if (chars == nullptr) throw 'GetStringUTFChars 返回 null';
      return chars.toDartString();
    } finally {
      if (chars != nullptr) releaseStringUtfChars(env, value, chars);
      if (arg != nullptr) calloc.free(arg);
      calloc.free(systemName);
      calloc.free(methodName);
      calloc.free(signature);
      calloc.free(keyJava);
    }
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
      final binary =
          (list.first as Map<String, dynamic>)['binary']
              as Map<String, dynamic>;
      return (binary['package'] as Map<String, dynamic>)['link'] as String;
    } finally {
      client.close();
    }
  }

  static Future<void> _download(
    String url,
    String dest,
    StringBuffer buf,
  ) async {
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
          ? root.listSync().map((e) => p.basename(e.path)).take(20).join(', ')
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

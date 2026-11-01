import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'account.dart';
import 'arguments.dart';
import 'game_dir.dart';
import 'launch_builder.dart';
import 'version_model.dart';

/// iOS「应用内启动游戏」探针（第二轮实验，与 [IosJvmProbe] 互补）。
///
/// 上一轮证明：iOS 模拟器进程内 `dlopen` macOS JVM 可以过平台校验，但
/// `JNI_CreateJavaVM` 死在 macOS 框架路径；真 iOS 的 JVM 要按 ios-simulator
/// 目标编译（社区暂无产物）。但**模拟器进程本质是 macOS 进程**——
/// `posix_spawn` 没有真机的沙盒禁令（真机禁 fork/exec，模拟器不禁），
/// 所以这一轮把游戏当 **macOS 子进程** 拉起来：游戏窗口开在 CI runner 的
/// 桌面上（有全套 AppKit + OpenGL），Minecraft 真的能跑出主菜单。
/// 模拟器专属的作弊路线；真机仍必须走 Pojav 的同进程 dlopen（README）。
///
/// 应用内做的事是真实链路：GameDir → 版本 json → LaunchBuilder 构建命令
/// （osx 规则）→ posix_spawn → 盯日志判定启动结果。只有「起进程」这一步
/// 借了宿主身份。安装好的游戏目录与 JRE 由 CI 用宿主 e2e 工具链预置
/// （natives 要按 macOS 选，模拟器里装会选错分类器）。
///
/// 触发：CI 往沙盒 Documents 写 `game_probe.json`
/// （`{"version":"1.20.4","memoryMb":2048}`）。流程在后台 isolate 跑，
/// 结果写 `Documents/game_probe_result.txt`，游戏日志在
/// `Documents/game-launch.log`（CI 连拍 runner 桌面时游戏还活着，
/// 结果出来后留 180 秒再收摊）。
class IosGameLaunchProbe {
  IosGameLaunchProbe._();

  /// main.dart 在 iOS 上后台调用；没有标记文件时立即返回。
  static void maybeRun(String docsPath) {
    if (!File(p.join(docsPath, 'game_probe.json')).existsSync()) return;
    unawaited(
      Isolate.run(() => run(docsPath)).catchError((Object e) {
        _append(docsPath, '!! 探针 isolate 异常: $e');
      }),
    );
  }

  static void _append(String docsPath, String line) {
    try {
      File(
        p.join(docsPath, 'game_probe_result.txt'),
      ).writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  static Future<void> run(String docsPath) async {
    // 过程写 _progress（CI 只轮询 result —— 结果文件必须只在终局出现，
    // 否则 CI 会在探针刚启动时就把应用杀掉）。
    final resultFile = File(p.join(docsPath, 'game_probe_result.txt'));
    final progressFile = File(p.join(docsPath, 'game_probe_progress.txt'));
    final buf = StringBuffer();

    void flush() {
      try {
        progressFile.parent.createSync(recursive: true);
        progressFile.writeAsStringSync('${buf.toString()}\n');
      } catch (_) {}
    }

    void finish() {
      try {
        resultFile.writeAsStringSync('${buf.toString()}\n');
      } catch (_) {}
    }

    buf.writeln(
      '=== iOS game launch probe ${DateTime.now().toIso8601String()} ===',
    );
    flush();
    var spawnPid = 0;
    try {
      // ── 1. 读配置 ──
      final config =
          jsonDecode(
                File(p.join(docsPath, 'game_probe.json')).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final versionId = (config['version'] as String?) ?? '1.20.4';
      final memoryMb = (config['memoryMb'] as num?)?.toInt() ?? 2048;
      final width = (config['width'] as num?)?.toInt() ?? 854;
      final height = (config['height'] as num?)?.toInt() ?? 480;
      buf.writeln('[1] version=$versionId memory=${memoryMb}MB');

      // ── 2. 检查 CI 预置的素材 ──
      // iOS 的 GameDir.defaultGameDir() = Documents/MintLauncher/minecraft
      // （launcherDataDir=Documents/MintLauncher + 'minecraft'）。isolate 里
      // 不能调 path_provider（MethodChannel 不进后台 isolate），按同一布局
      // 直接拼。
      final gameRoot = p.join(docsPath, 'MintLauncher', 'minecraft');
      final gameDir = GameDir(gameRoot);
      final versionJsonPath = gameDir.versionJson(versionId);
      final versionJarPath = gameDir.versionJar(versionId);
      final nativesPath = gameDir.nativesDir(versionId);
      final javaExe = p.join(
        docsPath,
        'macos_jdk',
        'Contents',
        'Home',
        'bin',
        'java',
      );
      final missing = <String>[
        if (!File(versionJsonPath).existsSync()) versionJsonPath,
        if (!File(versionJarPath).existsSync()) versionJarPath,
        if (!Directory(nativesPath).existsSync()) nativesPath,
        if (!File(javaExe).existsSync()) javaExe,
      ];
      if (missing.isNotEmpty) {
        buf.writeln('!! CI 预置素材缺失: ${missing.join(', ')}');
        buf.writeln('== ❌ 探针失败（素材没就位）==');
        finish();
        return;
      }
      final mode = File(javaExe).statSync().mode;
      buf.writeln('[2] 素材齐 java.mode=${mode.toRadixString(8)}');

      // ── 3. 解析版本 + 构建启动命令（osx 规则：-XstartOnFirstThread 等）──
      // 库规则同样按 osx + arm64 求值：不然 osx 专属库（java-objc 等）会被
      // iOS 进程视角踢出 class path；arch 解析不出来落到 'x86' 更是把主
      // jar 全踢空（见 LibraryRule 注释）。
      LibraryRule.osNameOverride = 'osx';
      LibraryRule.osArchOverride = 'arm64';
      final version = await GameVersion.resolve(versionId,
          jsonDecode(File(versionJsonPath).readAsStringSync())
              as Map<String, dynamic>, (id) async {
        final f = File(gameDir.versionJson(id));
        return f.existsSync()
            ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
            : null;
      });
      buf.writeln(
        '[3] mainClass=${version.mainClass} javaMajor=${version.javaMajor} '
        'libs=${version.libraries.length}',
      );
      final account = createOfflineAccount('MintTester');
      final command = const LaunchBuilder().build(
        LaunchOptions(
          javaExe: javaExe,
          version: version,
          gameDir: gameDir,
          versionId: versionId,
          playerName: account.name,
          playerUuid: account.uuid,
          memoryMb: memoryMb,
          width: width,
          height: height,
          fullscreen: false,
        ),
        // 游戏子进程是 macOS 进程：按 osx + arm64 求值规则，
        // 否则 -XstartOnFirstThread 全丢（见 LaunchBuilder.build 注释）。
        expander: const ArgumentExpander(osName: 'osx', arch: 'arm64'),
      );
      buf.writeln('[4] 命令行: ${command.quote()}');
      flush();

      // ── 5. 写启动脚本（exec + 日志重定向，posix_spawn 只带两个参数）──
      // 脚本第一行先把 bash 自己的输出重定向到 spawn-trace.log —— 文件
      // 出现 = bash exec 成功；内容能看到 cd / exec 死在哪一步。
      final logPath = p.join(docsPath, 'game-launch.log');
      final scriptPath = p.join(docsPath, 'mint_game_launch.sh');
      File(scriptPath).writeAsStringSync(
        _script(command, gameRoot, logPath, docsPath),
      );
      buf.writeln('[5] 启动脚本: $scriptPath');
      flush();

      // ── 6. posix_spawn（应用进程内拉起 macOS 子进程）──
      buf.writeln('[6] posix_spawn /bin/bash $scriptPath ...');
      flush();
      spawnPid = _posixSpawn('/bin/bash', [scriptPath]);
      buf.writeln('    pid=$spawnPid rc=0（spawn 成功）');
      flush();

      // ── 7. 盯日志：LWJGL 行 = 启动成功（与 e2e 同一判定）──
      final watched = _watch(spawnPid, logPath, buf, flush);
      if (watched.lwjgl) {
        buf.writeln(
          '== ✅ 游戏进程启动成功（macOS 子进程，窗口在 runner 桌面，'
          'CI screencapture 连拍中）==',
        );
        // 给 CI 留连拍窗口（LWJGL 行出现 ≠ 主菜单已画出，后面才是窗口）。
        buf.writeln('== 180 秒后收摊（CI 连拍窗口）==');
        flush();
        await Future<void>.delayed(const Duration(seconds: 180));
      } else {
        buf.writeln(
          '== ❌ 游戏没有走到 LWJGL 初始化（详见上方日志尾）==',
        );
      }
      final killRc = _kill(spawnPid, 15);
      buf.writeln('[8] kill(pid, SIGTERM) rc=$killRc');
      buf.writeln('== 探针结束 ==');
    } catch (e, st) {
      buf.writeln('!! 失败: $e');
      buf.writeln('== ❌ 探针失败 ==');
      buf.writeln(st.toString());
      if (spawnPid != 0) _kill(spawnPid, 15);
    }
    flush();
    // 结果文件只在终局写（CI 靠它判断探针跑完了）。
    finish();
  }

  /// 生成 bash 启动脚本：cd 到游戏根（现代版本不带 --gameDir，靠 cwd），
  /// exec java + 全部参数，stdout/stderr 进日志文件。
  static String _script(
    LaunchCommand command,
    String gameRoot,
    String logPath,
    String docsPath,
  ) {
    String q(String s) => "'${s.replaceAll("'", r"'\''")}'";
    final sb = StringBuffer()
      ..writeln('#!/bin/bash')
      ..writeln('# 由 IosGameLaunchProbe 生成（iOS 应用内启动游戏探针）')
      ..writeln('exec > ${q(p.join(docsPath, 'spawn-trace.log'))} 2>&1')
      ..writeln('echo "bash-start pid=\$\$ date=\$(date)"')
      ..writeln('cd ${q(gameRoot)} || { echo "cd 失败"; exit 2; }')
      ..write('echo "exec java..."');
    sb.writeln(' && exec ${q(command.executable)} '
        '${command.args.map(q).join(' ')} > ${q(logPath)} 2>&1');
    return sb.toString();
  }

  /// 轮询游戏日志，最久 330 秒。
  /// 成功 = `LWJGL version`（1.13+ 小写 / 1.7.10 大写统一按小写比）；
  /// 失败 = 主类异常或进程退出。每一步都落盘，崩了也有尸检材料。
  static ({bool lwjgl, bool crashed}) _watch(
    int pid,
    String logPath,
    StringBuffer buf,
    void Function() flush,
  ) {
    var lwjgl = false;
    var crashed = false;
    var lastSize = 0;
    final tail = <String>[];
    for (var i = 0; i < 82; i++) {
      // 82 * 4s ≈ 330s
      final state = _waitpidNoHang(pid);
      final alive = state == null; // null = 还活着
      try {
        final f = File(logPath);
        if (f.existsSync()) {
          final bytes = f.readAsBytesSync();
          if (bytes.length > lastSize) {
            lastSize = bytes.length;
            final text = utf8.decode(bytes, allowMalformed: true);
            final lines = text.split('\n');
            tail
              ..clear()
              ..addAll(lines.where((l) => l.trim().isNotEmpty).toList().takeLast(25));
            for (final l in lines) {
              final low = l.toLowerCase();
              if (low.contains('lwjgl version')) lwjgl = true;
              if (l.contains('Exception in thread "main"') ||
                  (l.contains('Unable to') && l.contains('main class'))) {
                crashed = true;
              }
            }
          }
        }
      } catch (_) {}
      if (lwjgl || (crashed && !alive)) {
        break;
      }
      if (i % 5 == 0 || lwjgl || crashed || !alive) {
        buf.writeln(
          '[7] t=${i * 4}s pid=${state ?? '活着'} '
          'lwjgl=$lwjgl crashed=$crashed 日志=${lastSize}B',
        );
        flush();
      }
      if (crashed && i > 10) break; // 主类异常后多等 40s 收尾日志
      sleep(const Duration(seconds: 4));
    }
    buf.writeln('---- 游戏日志尾 ----');
    for (final l in tail) {
      buf.writeln('  | $l');
    }
    buf.writeln('---- 日志尾结束 ----');
    flush();
    return (lwjgl: lwjgl, crashed: crashed);
  }

  // ─────────────────── FFI：posix_spawn / kill ───────────────────

  /// pid_t 在 darwin 上是 int（32 位）。
  static int _posixSpawn(String path, List<String> argv) {
    final dylib = DynamicLibrary.process();
    final spawn = dylib.lookupFunction<
        Int32 Function(
            Pointer<Int32>,
            Pointer<Utf8>,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Pointer<Utf8>>,
            Pointer<Pointer<Utf8>>),
        int Function(
            Pointer<Int32>,
            Pointer<Utf8>,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Pointer<Utf8>>,
            Pointer<Pointer<Utf8>>)>('posix_spawn');
    final environ = dylib
        .lookup<Pointer<Pointer<Utf8>>>('environ')
        .value; // 子进程继承应用环境（模拟器进程 = macOS 进程）
    final pidOut = calloc<Int32>();
    final exe = path.toNativeUtf8();
    final cArgv = calloc<Pointer<Utf8>>(argv.length + 2);
    for (var i = 0; i < argv.length; i++) {
      cArgv[i] = argv[i].toNativeUtf8();
    }
    cArgv[argv.length] = nullptr;
    try {
      final rc = spawn(
        pidOut,
        exe,
        nullptr, // file_actions：继承 stdout（console-pty 抓得到）
        nullptr, // attrp
        cArgv,
        environ,
      );
      if (rc != 0) {
        throw 'posix_spawn rc=$rc errno=$rc（模拟器进程也不允许 spawn？）';
      }
      return pidOut.value;
    } finally {
      calloc.free(pidOut);
      calloc.free(exe);
      for (var i = 0; i < argv.length; i++) {
        calloc.free(cArgv[i]);
      }
      calloc.free(cArgv);
    }
  }

  /// kill(2)。信号 0 只探测存活。
  static int _kill(int pid, int sig) {
    final kill = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
          'kill',
        );
    return kill(pid, sig);
  }

  /// waitpid(WNOHANG)：null = 还活着；否则返回可读的退出描述
  ///（顺带把僵尸收掉，返回值里的状态就是尸检结论）。
  static String? _waitpidNoHang(int pid) {
    final waitpid = DynamicLibrary.process().lookupFunction<
        Int32 Function(Int32, Pointer<Int32>, Int32),
        int Function(int, Pointer<Int32>, int)>('waitpid');
    final status = calloc<Int32>();
    try {
      final rc = waitpid(pid, status, 1); // WNOHANG = 1 (darwin)
      if (rc == 0) return null;
      if (rc < 0) return 'waitpid错误(rc<0)';
      final s = status.value;
      if (s & 0x7F == 0) return '退出码 ${(s >> 8) & 0xFF}';
      if (s & 0x7F == 0x7F) return ' stopped/继续（少见）';
      return '被信号 ${s & 0x7F} 杀死${s & 0x80 != 0 ? '（core dump）' : ''}';
    } finally {
      calloc.free(status);
    }
  }
}

extension<T> on Iterable<T> {
  List<T> takeLast(int n) => n >= length ? toList() : toList().sublist(length - n);
}

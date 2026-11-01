// 端到端冒烟测试（不依赖 Flutter UI）：
//
//   dart run tool/e2e_launch_test.dart [版本id] [--keep-running] [--install-only]
//
// 流程：清单 → 安装（库/客户端/资源/natives）→ 找 Java（没有就下载 JRE）
//       → 构建启动命令（离线账户）→ 起进程 → 观察输出 90 秒 → 结束。
//
// 默认使用启动器的真实游戏目录（GUI 之后再打开能直接看到装好的版本）。
// --install-only：装完就停（CI 的 iOS 探针用 —— natives 必须按宿主 macOS
// 选分类器，模拟器里装会选错；启动由应用内 IosGameLaunchProbe 负责）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mint/services/launcher/account.dart';
import 'package:mint/services/launcher/downloader.dart';
import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/launcher/java_runtime.dart';
import 'package:mint/services/launcher/launch_builder.dart';
import 'package:mint/services/launcher/manifest.dart';
import 'package:mint/services/launcher/version_installer.dart';
import 'package:mint/services/launcher/version_model.dart';

Future<void> main(List<String> rawArgs) async {
  final args = rawArgs.toList();
  final keepRunning = args.remove('--keep-running');
  final installOnly = args.remove('--install-only');
  final versionId = args.isEmpty ? null : args.first;

  final root = await GameDir.defaultGameDir();
  final gameDir = GameDir(root);
  stdout.writeln('== 游戏目录: $root');

  // CI（GitHub 海外机器）用 MINT_E2E_MIRROR=official 直连官方源更快；
  // 本地默认 auto（BMCLAPI 优先，失败回官方）。
  final mirror =
      Platform.environment['MINT_E2E_MIRROR'] == 'official'
      ? Mirror.official
      : Mirror.auto;
  final dl = Downloader(mirror: mirror);
  try {
    // ── 清单 ──
    stdout.writeln('== 拉取版本清单…');
    final manifest = await VersionManifest.fetch(dl);
    stdout.writeln(
      '   latest=${manifest.latest.release} snapshot=${manifest.latest.snapshot} '
      '(${manifest.versions.length} 个版本)',
    );

    final target = versionId ?? manifest.latest.release;
    final entry = manifest.find(target);
    if (entry == null) {
      stderr.writeln('!! 清单里没有版本 $target');
      exitCode = 2;
      return;
    }
    stdout.writeln('== 目标版本: $target（${entry.type}）');

    // ── 安装 ──
    final installer = VersionInstaller(gameDir: gameDir, downloader: dl);
    var lastPhase = '';
    await installer.install(
      target,
      onProgress: (p) {
        final phase = p.phase.label;
        if (phase != lastPhase || p.fraction % 0.1 < 0.001) {
          stdout.writeln('   [$phase] ${(p.fraction * 100).toStringAsFixed(0)}% ${p.detail}');
          lastPhase = phase;
        }
      },
      onLog: (line) => stdout.writeln('   · $line'),
    );

    // ── Java ──
    if (installOnly) {
      stdout.writeln('== --install-only：安装完成，跳过 Java 与启动');
      return;
    }
    stdout.writeln('== 检测 Java…');
    final javaService = JavaService(gameDir: gameDir);
    final json = jsonDecode(File(gameDir.versionJson(target)).readAsStringSync())
        as Map<String, dynamic>;
    final version = await GameVersion.resolve(target, json, (id) async {
      final f = File(gameDir.versionJson(id));
      return f.existsSync()
          ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
          : null;
    });
    var java = await javaService.pickFor(version.javaMajor);
    if (java == null) {
      final major = version.javaMajor > 0 ? version.javaMajor : 21;
      stdout.writeln('   没找到，下载 JRE $major…');
      java = await javaService.downloadJre(major, onLog: (l) => stdout.writeln('   · $l'));
    }
    stdout.writeln('== Java: $java');

    // ── 构建命令 ──
    final account = createOfflineAccount('MintTester');
    stdout.writeln('== 离线账户: ${account.name} / ${account.uuid}');
    final command = const LaunchBuilder().build(
      LaunchOptions(
        javaExe: java.executablePath,
        version: version,
        gameDir: gameDir,
        versionId: target,
        playerName: account.name,
        playerUuid: account.uuid,
        memoryMb: 2048,
        width: 854,
        height: 480,
        fullscreen: false,
      ),
    );
    stdout.writeln('== 启动命令：');
    stdout.writeln('   ${command.executable} ${command.args.join(' ')}');

    // ── 起进程 ──
    stdout.writeln('== 启动游戏进程…');
    final process = await Process.start(
      command.executable,
      command.args,
      workingDirectory: root,
    );
    var sawLwjgl = false;
    var sawCrash = false;
    final subscriptionErrors = <String>[];
    final done = Completer<void>();

    Timer(const Duration(seconds: 90), () {
      if (!done.isCompleted) {
        stdout.writeln('== 90 秒观察期结束');
        done.complete();
      }
    });

    void handleLine(String source, String line) {
      if (line.trim().isEmpty) return;
      stdout.writeln('   | $line');
      // 1.7.10 记「LWJGL Version: 2.9.4」，1.13+ 记「LWJGL version 3.x」
      // —— 统一按小写比。
      if (line.toLowerCase().contains('lwjgl version')) sawLwjgl = true;
      if (line.contains('Exception in thread "main"') ||
          line.contains('Unable to') && line.contains('main class')) {
        sawCrash = true;
        subscriptionErrors.add(line);
      }
    }

    // 游戏输出里有非 UTF-8 字节（部分转义的日志/本地化串），宽松解码别噎死
    const forgivingUtf8 = Utf8Codec(allowMalformed: true);
    process.stdout.transform(forgivingUtf8.decoder).listen((l) => handleLine('out', l));
    process.stderr.transform(forgivingUtf8.decoder).listen((l) => handleLine('err', l));

    int exitCodeOfGame = -999;
    if (!keepRunning) {
      unawaited(process.exitCode.then((code) {
        exitCodeOfGame = code;
        if (!done.isCompleted) done.complete();
      }));
      await done.future;
      if (exitCodeOfGame == -999 && process.pid > 0) {
        // 还活着：90 秒观察期到点，主动结束
        stdout.writeln('== 游戏进程存活（PID ${process.pid}），kill 之');
        process.kill();
        exitCodeOfGame = await process.exitCode;
      }
      stdout.writeln('== exitCode=$exitCodeOfGame sawLwjgl=$sawLwjgl sawCrash=$sawCrash');
      if (sawCrash) {
        exitCode = 3;
      } else if (!sawLwjgl && exitCodeOfGame != 0) {
        // 没有 LWJGL 日志且异常退出：多半没跑起来
        exitCode = 4;
      } else {
        stdout.writeln('== ✅ 冒烟通过');
      }
    } else {
      stdout.writeln('== --keep-running：进程挂着，Ctrl+C 退出');
      await process.exitCode;
    }
  } catch (e, st) {
    stderr.writeln('!! 失败: $e');
    stderr.writeln(st.toString());
    exitCode = 1;
  } finally {
    dl.close();
  }
}

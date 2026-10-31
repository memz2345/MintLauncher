// 加载器组合安装矩阵（无头端到端，不依赖 Flutter UI / SharedPreferences）：
//
//   dart run tool/e2e_loader_matrix.dart [游戏目录] [MC版本] [--no-launch] [--only=名字,名字]
//
// 组合（HMCL 同款补装流程，版本隔离开）：
//   fabric      Fabric + Fabric API
//   fabric-of   Fabric + Fabric API + OptiFine（预期冲突：OF 不支持 Fabric）
//   forge       单 Forge
//   forge-of    Forge + OptiFine
//
// 每个组合：装原版本体（幂等跳过）→ 装加载器 → 装 Fabric API / OptiFine →
// 构建启动命令 → 起进程观察 75 秒（LWJGL / Setting user / 崩溃标记）。
// 结果表写到 <游戏目录>/matrix-report.md 并打印 stdout。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mint/services/launcher/account.dart';
import 'package:mint/services/launcher/downloader.dart';
import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/launcher/java_runtime.dart';
import 'package:mint/services/launcher/launch_builder.dart';
import 'package:mint/services/launcher/modloader.dart';
import 'package:mint/services/launcher/modrinth.dart';
import 'package:mint/services/launcher/optifine.dart';
import 'package:mint/services/launcher/version_installer.dart';
import 'package:mint/services/launcher/version_model.dart';
import 'package:mint/src/enums.dart' show GraphicsBackend;

const watchSeconds = 75;

Future<void> main(List<String> rawArgs) async {
  final args = rawArgs.toList();
  final noLaunch = args.remove('--no-launch');
  final onlyArg = args.where((a) => a.startsWith('--only=')).firstOrNull;
  args.removeWhere((a) => a.startsWith('--only='));
  final only = onlyArg == null
      ? null
      : onlyArg.substring(7).split(',').map((s) => s.trim()).toSet();

  final root = args.isNotEmpty ? args[0] : r'H:\mctest';
  final mc = args.length > 1 ? args[1] : '1.20.1';
  final gameDir = GameDir(root);
  Directory(root).createSync(recursive: true);
  stdout.writeln('== 游戏目录: $root · MC $mc');

  final dl = Downloader(mirror: Mirror.auto);
  final results = <_ComboResult>[];
  try {
    // ── 原版本体（幂等：已存在只补缺失文件）──
    stdout.writeln('== 安装原版 $mc（已装会跳过下载）…');
    final installer = VersionInstaller(
      gameDir: gameDir,
      downloader: dl,
      verifyFiles: false,
    );
    await installer.install(
      mc,
      onLog: (line) => stdout.writeln('   · $line'),
      onProgress: (p) {
        stdout.writeln('   [${p.phase.label}] ${(p.fraction * 100).toStringAsFixed(0)}% ${p.detail}');
      },
    );

    // ── Java（1.20.1 要 17；系统有就用系统的）──
    final javaService = JavaService(gameDir: gameDir);
    var java = await javaService.pickFor(17);
    if (java == null) {
      stdout.writeln('== 没有现成 Java 17，下载…');
      java = await javaService.downloadJre(
        17,
        onLog: (l) => stdout.writeln('   · $l'),
      );
    }
    stdout.writeln('== Java: $java');

    final service = ModloaderService(gameDir: gameDir, downloader: dl);
    final optifineService = OptiFineService(gameDir: gameDir, downloader: dl);

    // ── 版本清单（只挑一次）──
    stdout.writeln('== 拉取 Fabric / Forge / OptiFine 清单…');
    final fabricList = await service.fabricVersions(mc);
    final forgeList = await service.forgeVersions(mc);
    final ofList = (await optifineService.versions())
        .where((e) => e.mcVersion == mc)
        .toList();
    final fabricVer = fabricList.isEmpty ? null : fabricList.first.version;
    final forgeVer = forgeList.isEmpty
        ? null
        : (forgeList.firstWhere((v) => v.recommended, orElse: () => forgeList.first)).version;
    final ofEntry = ofList.isEmpty ? null : ofList.first;
    stdout.writeln(
      '   Fabric=$fabricVer Forge=$forgeVer OptiFine=${ofEntry == null ? '无' : '${ofEntry.type} ${ofEntry.patch}'}',
    );
    if (fabricVer == null || forgeVer == null || ofEntry == null) {
      stderr.writeln('!! 清单不齐，中止');
      exitCode = 2;
      return;
    }

    final combos = <String>[
      'fabric',
      'fabric-of',
      'forge',
      'forge-of',
    ];

    for (final combo in combos) {
      if (only != null && !only.contains(combo)) continue;
      results.add(await runCombo(
        combo,
        gameDir: gameDir,
        dl: dl,
        service: service,
        optifineService: optifineService,
        javaExe: java.executablePath,
        mc: mc,
        fabricVer: fabricVer,
        forgeVer: forgeVer,
        ofEntry: ofEntry,
        noLaunch: noLaunch,
      ));
    }
  } catch (e, st) {
    stderr.writeln('!! 矩阵中断: $e\n$st');
    results.add(_ComboResult('（中断）', install: '❌ $e'));
  } finally {
    dl.close();
  }

  // ── 报告 ──
  final buf = StringBuffer('# 加载器组合矩阵 · MC $mc · ${DateTime.now()}\n\n'
      '| 组合 | 安装 | 启动 | 说明 |\n|---|---|---|---|\n');
  for (final r in results) {
    buf.writeln('| ${r.name} | ${r.install} | ${r.launch} | ${r.note} |');
  }
  final report = File('$root${Platform.pathSeparator}matrix-report.md');
  report.writeAsStringSync(buf.toString());
  stdout.writeln('\n== 结果 ==\n$buf');
  stdout.writeln('== 报告已写入 ${report.path}');
  // 下载器的 keep-alive 连接会吊住 isolate，显式退出。
  exit(results.every((r) => r.ok) ? 0 : 1);
}

Future<_ComboResult> runCombo(
  String combo, {
  required GameDir gameDir,
  required Downloader dl,
  required ModloaderService service,
  required OptiFineService optifineService,
  required String javaExe,
  required String mc,
  required String fabricVer,
  required String forgeVer,
  required OptiFineEntry ofEntry,
  required bool noLaunch,
}) async {
  final log = (String line) => stdout.writeln('   [$combo] $line');
  String versionId = '';

  try {
    switch (combo) {
      case 'fabric' || 'fabric-of':
        versionId = await service.installFabricFamily(
          ModLoader.fabric,
          mc,
          fabricVer,
          onLog: log,
        );
        // 补依赖库（profile json 只写了 json，库要拉）。
        await VersionInstaller(
          gameDir: gameDir,
          downloader: dl,
          verifyFiles: false,
        ).install(versionId, onLog: log);
        log('Fabric 版本 $versionId 就绪');

        // Fabric API → 版本隔离目录的 mods/。
        final modrinth = ModrinthService(
          downloader: dl,
          gameHomeDir: gameDir.versionDir(versionId),
        );
        final api = await modrinth.versionsOf(
          'fabric-api',
          gameVersion: mc,
          loaders: const ['fabric'],
        );
        if (api.isEmpty) throw Exception('Modrinth 没有 fabric-api（$mc）');
        await modrinth.install(
          api.first,
          type: ModrinthProjectType.mod,
          onLog: log,
        );
        log('Fabric API ${api.first.versionNumber} 装好了');

        if (combo == 'fabric-of') {
          // OptiFine 官方只支持原版 / Forge；这里验证报错是不是清晰的冲突提示。
          versionId = await optifineService.install(
            versionId,
            mcVersion: mc,
            entry: ofEntry,
            javaExe: javaExe,
            onLog: log,
          );
          log('居然装上了：$versionId');
        }
      case 'forge' || 'forge-of':
        await service.installViaOfficialInstaller(
          ModLoader.forge,
          mc,
          forgeVer,
          javaExe: javaExe,
          onLog: log,
        );
        versionId = ModloaderService.versionIdFor(ModLoader.forge, mc, forgeVer);
        await VersionInstaller(
          gameDir: gameDir,
          downloader: dl,
          verifyFiles: false,
        ).install(versionId, onLog: log);
        log('Forge 版本 $versionId 就绪');

        if (combo == 'forge-of') {
          versionId = await optifineService.install(
            versionId,
            mcVersion: mc,
            entry: ofEntry,
            javaExe: javaExe,
            onLog: log,
          );
          log('OptiFine 组合版本 $versionId 就绪');
        }
    }
  } catch (e) {
    return _ComboResult(
      combo,
      install: '❌ $e'.replaceAll('\n', ' '),
      launch: '—',
      note: combo == 'fabric-of'
          ? '预期内冲突（OF 不支持 Fabric）不算失败？先记安装失败'
          : '安装阶段失败',
    );
  }

  // 到这里 installOk 恒为 true（失败已在上面 catch 里返回）。
  if (noLaunch) {
    return _ComboResult(combo, install: '✅', launch: '—', note: '只装不启动');
  }

  // ── 启动观察 ──
  try {
    final json = jsonDecode(
      File(gameDir.versionJson(versionId)).readAsStringSync(),
    ) as Map<String, dynamic>;
    final version = await GameVersion.resolve(versionId, json, (id) async {
      final f = File(gameDir.versionJson(id));
      return f.existsSync()
          ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
          : null;
    });
    final account = createOfflineAccount('MintMatrix');
    final home = gameDir.versionDir(versionId); // 版本隔离
    Directory(home).createSync(recursive: true);
    final command = const LaunchBuilder().build(
      LaunchOptions(
        javaExe: javaExe,
        version: version,
        gameDir: gameDir,
        versionId: versionId,
        playerName: account.name,
        playerUuid: account.uuid,
        memoryMb: 2048,
        width: 854,
        height: 480,
        fullscreen: false,
        gameHome: home,
        graphicsBackend: GraphicsBackend.auto,
      ),
    );
    stdout.writeln('   [$combo] 启动 $versionId（PID 待分配）…');
    final process = await Process.start(
      command.executable,
      command.args,
      workingDirectory: home,
    );

    var sawLwjgl = false;
    var sawUser = false;
    var sawCrash = false;
    final crashLines = <String>[];
    final done = Completer<void>();
    int gameExit = -999;
    unawaited(process.exitCode.then((code) {
      gameExit = code;
      if (!done.isCompleted) done.complete();
    }));
    Timer(const Duration(seconds: watchSeconds), () {
      if (!done.isCompleted) done.complete();
    });

    void handle(String line) {
      if (line.trim().isEmpty) return;
      stdout.writeln('   [$combo|game] $line');
      if (line.contains('Backend library: LWJGL') ||
          line.contains('LWJGL Version')) {
        sawLwjgl = true;
      }
      if (line.contains('Setting user:')) sawUser = true;
      if (line.contains('Exception in thread "main"') ||
          line.contains('Crash report saved') ||
          line.contains('# There is insufficient memory') ||
          line.contains('Failed to launch')) {
        sawCrash = true;
        crashLines.add(line);
      }
    }

    const forgivingUtf8 = Utf8Codec(allowMalformed: true);
    process.stdout.transform(forgivingUtf8.decoder).listen(
          handle,
          onError: (Object e) => stdout.writeln('   [$combo] stdout 读取错误: $e'),
        );
    process.stderr.transform(forgivingUtf8.decoder).listen(handle);
    await done.future;
    if (gameExit == -999) {
      process.kill();
      gameExit = await process.exitCode;
    }

    final launched = sawLwjgl && !sawCrash;
    final ok = launched && sawUser;
    return _ComboResult(
      combo,
      install: '✅',
      launch: sawCrash
          ? '❌ 崩溃'
          : sawLwjgl
          ? '✅'
          : '⚠️ 未见 LWJGL（exit=$gameExit）',
      ok: ok,
      note: 'exit=$gameExit LWJGL=$sawLwjgl user=$sawUser'
          '${crashLines.isEmpty ? '' : ' crash=${crashLines.first}'}'
          ' · 版本 $versionId',
    );
  } catch (e) {
    return _ComboResult(combo, install: '✅', launch: '❌ $e', note: '启动阶段失败');
  }
}

class _ComboResult {
  _ComboResult(this.name, {this.install = '', this.launch = '', this.ok = false, this.note = ''});

  final String name;
  final String install;
  final String launch;
  final bool ok;
  final String note;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

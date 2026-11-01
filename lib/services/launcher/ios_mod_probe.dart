import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:mint/services/settings_service.dart';

import 'downloader.dart';
import 'game_dir.dart';
import 'modrinth.dart';

/// iOS「应用内安装 Mod」探针（CI 用）。
///
/// 触发：CI 往沙盒 Documents 写 `mod_probe.json`
/// （`{"version":"1.20.4","mods":["fabric-api"]}`）。main 在
/// LauncherController 初始化后调用 —— 这样能拿到真实的版本隔离设置，
/// 探针落盘的 mods 目录和「内容管理」页读的是同一条路径。
///
/// 安装走真实链路：Modrinth 版本查询 → Downloader（sha1 校验）→ 写入
/// mods 目录。结果写 `Documents/mod_probe_result.txt`；过程中只写
/// `mod_probe_progress.txt`（CI 轮询 result，结果文件必须只在终局出现）。
class IosModProbe {
  IosModProbe._();

  static void maybeRun(
    String docsPath,
    GameDir gameDir,
    SettingsService settings,
  ) {
    final marker = File(p.join(docsPath, 'mod_probe.json'));
    if (!marker.existsSync()) return;
    unawaited(
      run(docsPath, gameDir, settings, marker).catchError((Object e) {
        _writeResult(docsPath, '!! 探针异常: $e\n');
      }),
    );
  }

  static void _writeResult(String docsPath, String text) {
    try {
      File(p.join(docsPath, 'mod_probe_result.txt')).writeAsStringSync(text);
    } catch (_) {}
  }

  static Future<void> run(
    String docsPath,
    GameDir gameDir,
    SettingsService settings,
    File marker,
  ) async {
    final progress = File(p.join(docsPath, 'mod_probe_progress.txt'));
    final buf = StringBuffer();
    Downloader? opened;

    void flush() {
      try {
        progress.writeAsStringSync(buf.toString());
      } catch (_) {}
    }

    try {
      final config =
          jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
      final versionId = (config['version'] as String?) ?? '1.20.4';
      final slugs = config['mods'] is List
          ? [
              for (final s in config['mods'] as List)
                if (s is String && s.isNotEmpty) s,
            ]
          : <String>['fabric-api'];
      final isolated = settings.effectiveFor(versionId).isolation;
      final modsDir = gameDir.modsDir(versionId, isolated: isolated);

      buf.writeln(
        '=== iOS mod install probe ${DateTime.now().toIso8601String()} ===',
      );
      buf.writeln('[1] version=$versionId isolated=$isolated');
      buf.writeln('[2] modsDir=$modsDir');
      flush();

      final dl = Downloader(mirror: Mirror.official, concurrency: 4);
      opened = dl;
      final service = ModrinthService(
        downloader: dl,
        gameHomeDir: gameDir.gameHome(versionId, isolated: isolated),
      );

      var index = 0;
      for (final slug in slugs) {
        index++;
        buf.writeln('[$index] 查询 Modrinth 项目 $slug …');
        flush();
        final versions = await service.versionsOf(
          slug,
          gameVersion: versionId,
          loaders: const ['fabric'],
        );
        buf.writeln('    可用版本 ${versions.length} 个');
        ModrinthVersionFile? chosen;
        for (final v in versions) {
          final file = v.primaryFile;
          if (file == null || file.filename.isEmpty) continue;
          if (!v.gameVersions.contains(versionId)) continue;
          chosen = v;
          break;
        }
        if (chosen == null) {
          buf.writeln('!! $slug 没有适用于 $versionId 的可下载版本');
          flush();
          continue;
        }
        final file = chosen.primaryFile!;
        buf.writeln(
          '    选中 ${chosen.name} ${chosen.versionNumber}'
          ' → ${file.filename} (${file.size}B)',
        );
        flush();
        final path = await service.install(
          chosen,
          type: ModrinthProjectType.mod,
          destDir: modsDir,
          onLog: (line) {
            buf.writeln('    $line');
            flush();
          },
        );
        final installed = File(path);
        final size = installed.existsSync() ? installed.lengthSync() : 0;
        buf.writeln('    ${size > 0 ? '✅' : '❌'} $path ($size B)');
        flush();
      }

      buf.writeln('[3] 最终 mods 目录内容：');
      final mods = gameDir.modsOf(versionId, isolated: isolated);
      if (mods.isEmpty) {
        buf.writeln('    (空)');
      } else {
        for (final f in mods) {
          buf.writeln('    - ${p.basename(f.path)} (${f.lengthSync()}B)');
        }
      }
      buf.writeln('== 探针结束 ==');
      _writeResult(docsPath, buf.toString());
    } catch (e, st) {
      buf.writeln('!! $e');
      buf.writeln('$st');
      _writeResult(docsPath, buf.toString());
    } finally {
      opened?.close();
    }
  }
}

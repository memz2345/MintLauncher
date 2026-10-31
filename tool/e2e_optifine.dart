// OptiFine 安装端到端验证（dart run tool/e2e_optifine.dart）。
//
// 前提：/tmp(of_test)/mcdir/versions/1.20.1/ 里已有原版 json+jar（本次
// 会话实测时下载的）；安装器从 BMCLAPI 真实下载，走完整流程：
//   下载安装器 → Patcher 补丁 → mods.toml 清理 → launchwrapper 安装
//   → 生成版本 json。
import 'dart:io';

import 'package:mint/services/launcher/downloader.dart';
import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/launcher/optifine.dart';

Future<void> main() async {
  final vanillaSrc = Directory(
    'C:/Users/memz2345/AppData/Local/Temp/of_test/mcdir/versions/1.20.1',
  );
  if (!vanillaSrc.existsSync()) {
    stderr.writeln('先准备原版 1.20.1：$vanillaSrc 不存在');
    exit(2);
  }

  final gameRoot = await Directory.systemTemp.createTemp('mint_of_e2e');
  stdout.writeln('游戏目录：${gameRoot.path}');
  final gd = GameDir(gameRoot.path);

  // 原版本体就位
  final dst = Directory(gd.versionDir('1.20.1'));
  dst.createSync(recursive: true);
  for (final f in vanillaSrc.listSync()) {
    if (f is File) f.copySync(pJoin(dst.path, f.uri.pathSegments.last));
  }
  stdout.writeln('原版 json/jar 就位：'
      '${File(gd.versionJson('1.20.1')).lengthSync()} / '
      '${File(gd.versionJar('1.20.1')).lengthSync()} 字节');

  final dl = Downloader(mirror: Mirror.bmcl, concurrency: 4);
  final service = OptiFineService(gameDir: gd, downloader: dl);
  try {
    // ── 清单 ──
    final versions = await service.versions();
    final entries1201 =
        versions.where((e) => e.mcVersion == '1.20.1').toList();
    stdout.writeln('清单共 ${versions.length} 条，1.20.1 有 '
        '${entries1201.length} 条');
    final entry = entries1201
        .where((e) => e.filename == 'OptiFine_1.20.1_HD_U_I6.jar')
        .first;
    stdout.writeln('目标：${entry.filename} → edition=${entry.edition}，'
        'url=${entry.downloadUrl}');

    // ── 安装 ──
    final id = await service.install(
      '1.20.1',
      mcVersion: '1.20.1',
      entry: entry,
      javaExe: 'java',
      onLog: (line) => stdout.writeln('  | $line'),
    );
    stdout.writeln('生成版本：$id');

    // ── 校验 ──
    final failures = <String>[];
    void check(bool ok, String what) {
      stdout.writeln('${ok ? "PASS" : "FAIL"}  $what');
      if (!ok) failures.add(what);
    }

    final vjsonFile = File(gd.versionJson(id));
    check(vjsonFile.existsSync(), '版本 json 存在');
    final vjson =
        vjsonFile.readAsStringSync();
    check(vjson.contains('"inheritsFrom": "1.20.1"'), 'inheritsFrom 指向原版');
    check(
      vjson.contains('net.minecraft.launchwrapper.Launch'),
      'mainClass = Launch',
    );
    check(vjson.contains('optifine.OptiFineTweaker'), 'game 参数含 tweakClass');
    check(vjson.contains('optifine:OptiFine:1.20.1_HD_U_I6'), 'OptiFine 库声明');
    check(vjson.contains('optifine:launchwrapper-of:2.3'), '捆绑 launchwrapper 声明');

    final libJar = File(pJoin(gd.libraries,
        'optifine/OptiFine/1.20.1_HD_U_I6/OptiFine-1.20.1_HD_U_I6.jar'));
    check(libJar.existsSync() && libJar.lengthSync() > 1024 * 1024,
        'OptiFine 库 jar 存在（${libJar.existsSync() ? libJar.lengthSync() : 0} 字节）');
    // mods.toml 必须被删掉
    var hasModsToml = false;
    final zipBytes = libJar.readAsBytesSync();
    // 简单字节嗅探：mods.toml 文件名不应出现在 zip 中央目录（快速近似校验，
    // 准确校验用 archive 解压比对条目名）。
    hasModsToml = String.fromCharCodes(zipBytes).contains('META-INF/mods.toml');
    check(!hasModsToml, '库 jar 不含 META-INF/mods.toml');

    final lw = File(pJoin(
      gd.libraries, 'optifine/launchwrapper-of/2.3/launchwrapper-of-2.3.jar',
    ));
    check(lw.existsSync(), 'launchwrapper-of-2.3.jar 就位');

    if (failures.isEmpty) {
      stdout.writeln('✅ E2E 全部通过');
      exit(0);
    } else {
      stderr.writeln('❌ ${failures.length} 项失败');
      exit(1);
    }
  } finally {
    dl.close();
  }
}

String pJoin(String a, [String b = '', String c = '']) {
  var path = a;
  if (b.isNotEmpty) path += Platform.pathSeparator + b;
  if (c.isNotEmpty) path += Platform.pathSeparator + c;
  return path;
}

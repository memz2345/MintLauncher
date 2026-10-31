// 整合包导出的单测（ModpackExporter）：
// 规则引擎（通配 / 反选 / 目录规则 / 靠后覆盖靠前）、两种格式的清单结构、
// 文件收集与排除（隔离目录里的版本 json/jar 不进包、日志排除、
// OptiFine 跳过、子项反选抠存档）。联网匹配用假 HttpClient 不可行，
// 走 checkHosted: false；托管条目回填用公开的组装路径已覆盖。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/launcher/modpack_exporter.dart';

void main() {
  late Directory temp;
  late String home;
  late GameDir gameDir;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mint_export_test_');
    home = p.join(temp.path, 'versions', '1.20.1-forge-47.2.0');
    Directory(home).createSync(recursive: true);
    gameDir = GameDir(temp.path);
    // mcVersionOf 沿 inheritsFrom 链取基版本，造一个最小版本 json。
    File(
      p.join(home, '1.20.1-forge-47.2.0.json'),
    ).writeAsStringSync('{"inheritsFrom":"1.20.1","type":"release"}');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  void touch(String rel, [String content = 'x']) {
    final f = File(p.join(home, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  Map<String, String> zipEntries(String path) {
    final archive = ar.ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    return {
      for (final e in archive)
        if (e.isFile)
          e.name: utf8.decode(e.content as List<int>, allowMalformed: true),
    };
  }

  group('规则引擎', () {
    test('精确 / 通配 / 目录 / 字符集规则', () {
      const r = ModpackExporter.ruleMatches;
      // 精确匹配（无通配 → 不做正则）。
      expect(r('options.txt', 'options.txt'), isTrue);
      expect(r('config/options.txt', 'options.txt'), isFalse);
      // 大小写不敏感（PCL2 双方转小写再 Like）。
      expect(r('mods/foo.jar', 'MODS/FOO.JAR'), isTrue);
      // * 跨目录段（VB Like 的 * 不受分隔符限制）。
      expect(r('config/spark/sub/a.json', 'config/spark/*.json'), isTrue);
      expect(r('config/spark/sub/a.json', 'config/spark/config.json'), isFalse);
      // ? 单字符。
      expect(r('mods/a.jar', 'mods/?.jar'), isTrue);
      expect(r('mods/ab.jar', 'mods/?.jar'), isFalse);
      // 目录规则 = 前缀匹配。
      expect(r('kubejs/probe/x.js', 'kubejs*/'), isTrue);
      expect(r('kubejsx/other.txt', 'kubejs*/'), isTrue);
      // 字符集与反选字符集。
      expect(r('mods/b.jar', 'mods/[ab].jar'), isTrue);
      expect(r('mods/c.jar', 'mods/[ab].jar'), isFalse);
      expect(r('mods/c.jar', 'mods/[!ab].jar'), isTrue);
    });

    test('靠后的行覆盖靠前的，! 开头反选', () {
      const rules = [
        'config/',
        '!config/jei/world/',
        'config/worldedit/worldedit.properties',
      ];
      expect(ModpackExporter.resolveRules(rules, 'config/a.json'), isTrue);
      expect(
        ModpackExporter.resolveRules(rules, 'config/jei/world/x.dat'),
        isFalse,
      );
      expect(
        ModpackExporter.resolveRules(
          rules,
          'config/worldedit/worldedit.properties',
        ),
        isTrue,
      );
      // 默认排除放最后：日志即使在 mods 里也不收。
      const withExclude = ['mods/', '!*.log'];
      expect(
        ModpackExporter.resolveRules(withExclude, 'mods/foo.log'),
        isFalse,
      );
      // 没命中任何包含规则 → 不收（隔离目录的版本 json/jar 因此自然排除）。
      expect(
        ModpackExporter.resolveRules(withExclude, '1.20.1-forge-47.2.0.jar'),
        isNull,
      );
      // 注释行与空行忽略。
      expect(
        ModpackExporter.resolveRules(['# 注释', '', 'mods/'], 'mods/a.jar'),
        isTrue,
      );
    });

    test('通配转义：子项名称里的特殊字符按字面量匹配', () {
      // 目录子项的规则带尾斜杠（前缀语义），与 subItemsOf 的产出一致。
      final rule = 'saves/${ModpackExporter.escapeGlob('世界 [测试] *v1?')}/';
      expect(
        ModpackExporter.ruleMatches('saves/世界 [测试] *v1?/level.dat', rule),
        isTrue,
      );
      expect(
        ModpackExporter.ruleMatches('saves/世界 x/level.dat', rule),
        isFalse,
      );
    });
  });

  group('选项与子项', () {
    test('requireModLoader / requireModLoaderOrOptiFine 门控', () {
      final vanilla = ModpackExporter.optionsFor(
        modable: false,
        hasOptiFine: false,
      );
      final forge = ModpackExporter.optionsFor(
        modable: true,
        hasOptiFine: false,
      );
      final optifine = ModpackExporter.optionsFor(
        modable: false,
        hasOptiFine: true,
      );
      expect(vanilla.any((o) => o.key == 'mods'), isFalse);
      expect(vanilla.any((o) => o.key == 'shaderpacks'), isFalse);
      expect(forge.any((o) => o.key == 'mods'), isTrue);
      expect(optifine.any((o) => o.key == 'shaderpacks'), isTrue);
      // 个人信息类选项默认不勾选。
      expect(
        vanilla.firstWhere((o) => o.key == 'basicPersonal').defaultChecked,
        isFalse,
      );
    });

    test('subItemsOf 扫出存档目录与资源包压缩包，空目录跳过', () {
      Directory(p.join(home, 'saves', '世界一')).createSync(recursive: true);
      touch('saves/世界一/level.dat');
      Directory(p.join(home, 'saves', '空目录')).createSync(recursive: true);
      touch('resourcepacks/清爽资源.zip');
      final saves = ModpackExporter.options.firstWhere((o) => o.key == 'saves');
      final subs = ModpackExporter.subItemsOf(saves, home);
      expect(subs.map((s) => s.title), ['世界一']);
      final rp = ModpackExporter.options.firstWhere(
        (o) => o.key == 'resourcepacks',
      );
      final rpSubs = ModpackExporter.subItemsOf(rp, home);
      expect(rpSubs.map((s) => s.title), contains('清爽资源.zip'));
      // 子项规则已转义并可命中。
      expect(
        ModpackExporter.ruleMatches(
          'saves/世界一/level.dat'.toLowerCase(),
          subs.first.rule.toLowerCase(),
        ),
        isTrue,
      );
    });
  });

  group('导出', () {
    test('CurseForge 格式：manifest + 收集/排除规则生效', () async {
      touch('mods/Admin.jar');
      touch('mods/broken.disabled');
      touch('config/jei/world/personal.dat');
      touch('config/spark/session.json');
      touch('config/spark/config.json');
      touch('logs/latest.log', 'log');
      touch('saves/世界一/level.dat');
      touch('saves/世界一/session.lock');
      touch('servers.dat', 'srv');
      touch('LICENCE.txt', 'MIT');
      touch('options.txt', 'music=0');
      // 隔离目录里的版本 jar 与启动器缓存不应进包（不命中任何包含规则）。
      touch('1.20.1-forge-47.2.0.jar', 'jar');
      touch('usercache.json', '[]');

      final result = await ModpackExporter(gameDir: gameDir).export(
        '1.20.1-forge-47.2.0',
        home: home,
        name: '测试包',
        author: 'tester',
        packVersion: '1.0.0',
        format: ModpackExportFormat.curseForge,
        checkHosted: false,
        destFile: p.join(temp.path, 'out.zip'),
      );

      final entries = zipEntries(result.path);
      expect(entries.keys, contains('manifest.json'));
      expect(entries.keys, contains('overrides/mods/Admin.jar'));
      expect(entries.keys, contains('overrides/config/spark/config.json'));
      expect(entries.keys, contains('overrides/options.txt'));
      expect(entries.keys, contains('overrides/servers.dat'));
      expect(entries.keys, contains('overrides/LICENCE.txt'));
      expect(entries.keys, contains('overrides/安装说明.txt'));
      // 排除与门控。
      expect(entries.keys, isNot(contains('overrides/logs/latest.log')));
      expect(entries.keys, isNot(contains('overrides/mods/broken.disabled')));
      expect(
        entries.keys,
        isNot(contains('overrides/config/jei/world/personal.dat')),
      );
      expect(
        entries.keys,
        isNot(contains('overrides/config/spark/session.json')),
      );
      expect(entries.keys, contains('overrides/saves/世界一/level.dat'));
      expect(entries.keys, isNot(contains('overrides/saves/世界一/session.lock')));
      expect(
        entries.keys.where((k) => k.contains('1.20.1-forge-47.2.0')),
        isEmpty,
      );

      final manifest =
          jsonDecode(entries['manifest.json']!) as Map<String, dynamic>;
      expect(manifest['manifestType'], 'minecraftModpack');
      expect(manifest['name'], '测试包');
      expect((manifest['minecraft'] as Map)['version'], '1.20.1');
      expect(
        ((manifest['minecraft'] as Map)['modLoaders'] as List).single['id'],
        'forge-47.2.0',
      );
      expect(
        result.fileCount,
        6,
      ); // Admin.jar / spark config / options / servers / LICENCE / 存档
      expect(result.hostedCount, 0);
    });

    test('勾选存档选项后打包；反选子项可抠掉单个世界', () async {
      touch('mods/A.jar');
      touch('saves/世界一/level.dat');
      touch('saves/世界二/level.dat');
      final saves = ModpackExporter.options.firstWhere((o) => o.key == 'saves');
      final subs = ModpackExporter.subItemsOf(saves, home);

      Future<Set<String>> run(Map<String, bool> subChecked) async {
        final r = await ModpackExporter(gameDir: gameDir).export(
          '1.20.1-forge-47.2.0',
          home: home,
          name: 'n',
          author: 'a',
          packVersion: '1',
          format: ModpackExportFormat.curseForge,
          checkHosted: false,
          optionChecked: {'saves': true},
          subItemChecked: subChecked,
          destFile: p.join(temp.path, 'out.zip'),
        );
        return zipEntries(r.path).keys.toSet();
      }

      final all = await run({
        for (final s in subs) '${saves.key}/${s.title}': true,
      });
      expect(all, contains('overrides/saves/世界一/level.dat'));
      expect(all, contains('overrides/saves/世界二/level.dat'));

      final partial = await run({
        for (final s in subs) '${saves.key}/${s.title}': s.title != '世界一',
      });
      expect(partial, isNot(contains('overrides/saves/世界一/level.dat')));
      expect(partial, contains('overrides/saves/世界二/level.dat'));
    });

    test('Modrinth 格式：index 结构、依赖键与未匹配文件直接打包', () async {
      touch('mods/Custom.jar');
      touch('resourcepacks/Pack.zip');
      final result = await ModpackExporter(gameDir: gameDir).export(
        '1.20.1-forge-47.2.0',
        home: home,
        name: 'MR 包',
        author: 'tester',
        packVersion: '2.0',
        format: ModpackExportFormat.modrinth,
        checkHosted: false,
        destFile: p.join(temp.path, 'out.mrpack'),
      );

      final entries = zipEntries(result.path);
      expect(entries.keys, contains('modrinth.index.json'));
      expect(entries.keys, isNot(contains('manifest.json')));
      final index =
          jsonDecode(entries['modrinth.index.json']!) as Map<String, dynamic>;
      expect(index['formatVersion'], 1);
      expect(index['game'], 'minecraft');
      expect(index['versionId'], '2.0');
      expect(index['name'], 'MR 包');
      expect((index['dependencies'] as Map)['minecraft'], '1.20.1');
      expect((index['dependencies'] as Map)['forge'], '47.2.0');
      expect(index['files'], isEmpty); // 联网匹配关闭 → 全部进 overrides
      expect(entries.keys, contains('overrides/mods/Custom.jar'));
      expect(result.fileCount, 2); // mods/Custom.jar + resourcepacks/Pack.zip
    });

    test('Quilt 版本的依赖键是 quilt-loader（PCL2 只写三种，Mint 补齐）', () async {
      final quiltHome = p.join(
        temp.path,
        'versions',
        'quilt-loader-0.26.0-1.20.1',
      );
      Directory(quiltHome).createSync(recursive: true);
      File(
        p.join(quiltHome, 'quilt-loader-0.26.0-1.20.1.json'),
      ).writeAsStringSync('{"inheritsFrom":"1.20.1"}');
      touch('mods/A.jar');

      final result = await ModpackExporter(gameDir: gameDir).export(
        'quilt-loader-0.26.0-1.20.1',
        home: quiltHome,
        name: 'q',
        author: 'a',
        packVersion: '1',
        format: ModpackExportFormat.modrinth,
        checkHosted: false,
        destFile: p.join(temp.path, 'out.mrpack'),
      );
      final index =
          jsonDecode(zipEntries(result.path)['modrinth.index.json']!)
              as Map<String, dynamic>;
      expect((index['dependencies'] as Map)['quilt-loader'], '0.26.0');
    });

    test('OptiFine jar 因许可证跳过并记录', () async {
      touch('mods/Preview_OptiFine_1.20.1_HD_U_I6.jar');
      touch('mods/normal.jar');
      final result = await ModpackExporter(gameDir: gameDir).export(
        '1.20.1-forge-47.2.0',
        home: home,
        name: 'n',
        author: 'a',
        packVersion: '1',
        format: ModpackExportFormat.modrinth,
        checkHosted: false,
        destFile: p.join(temp.path, 'out.mrpack'),
      );
      final entries = zipEntries(result.path).keys.toSet();
      expect(
        entries,
        isNot(contains('overrides/mods/Preview_OptiFine_1.20.1_HD_U_I6.jar')),
      );
      expect(entries, contains('overrides/mods/normal.jar'));
      expect(result.skippedOptiFine, ['Preview_OptiFine_1.20.1_HD_U_I6.jar']);
    });

    test('取消回调中断导出', () async {
      touch('mods/A.jar');
      touch('mods/B.jar');
      expect(
        () => ModpackExporter(gameDir: gameDir).export(
          '1.20.1-forge-47.2.0',
          home: home,
          name: 'n',
          author: 'a',
          packVersion: '1',
          format: ModpackExportFormat.curseForge,
          checkHosted: false,
          destFile: p.join(temp.path, 'out.zip'),
          isCancelled: () => true,
        ),
        throwsA(isException),
      );
    });

    test('进度回调从 0 推进到 1', () async {
      touch('mods/A.jar');
      var last = 0.0;
      await ModpackExporter(gameDir: gameDir).export(
        '1.20.1-forge-47.2.0',
        home: home,
        name: 'n',
        author: 'a',
        packVersion: '1',
        format: ModpackExportFormat.curseForge,
        checkHosted: false,
        destFile: p.join(temp.path, 'out.zip'),
        onProgress: (f, _) => last = f,
      );
      expect(last, 1);
    });
  });
}

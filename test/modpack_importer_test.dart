// 整合包识别 / 解压的单测（ModpackImporter）：
// 合成四种格式的 zip，逐一验证 inspect 的识别结果与
// extractPrefixes / extractPlain 的落盘行为
// （client-overrides 覆盖 overrides、路径穿越拦截、MultiMC .minecraft 前缀）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/launcher/modloader.dart';
import 'package:mint/services/launcher/modpack_importer.dart';

/// 合成一个 zip（files: 相对路径 → 内容，UTF-8 编码）。
String buildZip(Directory dir, String name, Map<String, String> files) {
  final archive = ar.Archive();
  files.forEach((path, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ar.ArchiveFile(path, bytes.length, bytes));
  });
  final dest = '${dir.path}${Platform.pathSeparator}$name';
  File(dest).writeAsBytesSync(ar.ZipEncoder().encode(archive));
  return dest;
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mint_modpack_test_');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('Modrinth .mrpack：识别 + client-overrides 覆盖 overrides', () {
    final mrpack = buildZip(temp, 'pack.mrpack', {
      'modrinth.index.json':
          '{"name":"Test Pack","dependencies":{"minecraft":"1.20.1",'
          '"fabric-loader":"0.15.11"},'
          '"files":[{"path":"mods/foo.jar","hashes":{"sha1":"x"},'
          '"downloads":["https://example.com/foo.jar"],'
          '"env":{"client":"required"}}]}',
      'overrides/config.json': '{"a":1}',
      'overrides/mods/keep.jar': 'fake',
      'client-overrides/config.json': '{"a":2}',
    });
    final d = ModpackImporter.inspect(mrpack);
    expect(d.kind, ModpackKind.modrinth);
    expect(d.name, 'Test Pack');
    expect(d.gameVersion, '1.20.1');
    expect(d.loader?.label, 'Fabric');
    expect(d.loaderVersion, '0.15.11');

    final out = '${temp.path}${Platform.pathSeparator}out';
    ModpackImporter.extractPrefixes(
      mrpack,
      out,
      prefixes: [
        '${d.rootPrefix}overrides/',
        '${d.rootPrefix}client-overrides/',
      ],
    );
    expect(
      File('$out${Platform.pathSeparator}config.json').readAsStringSync(),
      '{"a":2}',
      reason: 'client-overrides 应覆盖 overrides 同名文件',
    );
    expect(
      File(
        '$out${Platform.pathSeparator}mods${Platform.pathSeparator}keep.jar',
      ).existsSync(),
      isTrue,
    );
  });

  test('CurseForge manifest：识别 + overrides 落盘 + 路径穿越拦截', () {
    final curse = buildZip(temp, 'curse.zip', {
      'manifest.json':
          '{"manifestType":"minecraftModpack","name":"CF Pack",'
          '"minecraft":{"version":"1.19.2",'
          '"modLoaders":[{"id":"forge-43.2.0","primary":true}]},'
          '"overrides":"overrides",'
          '"files":[{"projectID":1,"fileID":3482815,"required":true,'
          '"path":"mods\\\\jei.jar"}]}',
      'overrides/config.toml': 'x',
      'overrides/../evil.txt': 'evil',
    });
    final d = ModpackImporter.inspect(curse);
    expect(d.kind, ModpackKind.curseForge);
    expect(d.gameVersion, '1.19.2');
    expect(d.loader?.label, 'Forge');
    expect(d.loaderVersion, '43.2.0');
    expect(d.overridesPrefix, 'overrides/');
    expect(d.curseFiles.single['fileID'], 3482815);

    final out = '${temp.path}${Platform.pathSeparator}out';
    ModpackImporter.extractPrefixes(curse, out, prefixes: [d.overridesPrefix]);
    expect(
      File('$out${Platform.pathSeparator}config.toml').existsSync(),
      isTrue,
    );
    expect(
      File('${temp.path}${Platform.pathSeparator}evil.txt').existsSync(),
      isFalse,
      reason: '`..` 路径穿越必须被拦截',
    );
  });

  test('MultiMC：mmc-pack.json 识别 + .minecraft 前缀落盘', () {
    final mmc = buildZip(temp, 'mmc.zip', {
      'mmc-pack.json':
          '{"components":[{"uid":"net.minecraft","version":"1.20.1"},'
          '{"uid":"net.fabricmc.fabric-loader","version":"0.15.11"}]}',
      'instance.cfg': 'name=MMC实例',
      '.minecraft/options.txt': 'x',
    });
    final d = ModpackImporter.inspect(mmc);
    expect(d.kind, ModpackKind.multiMc);
    expect(d.name, 'MMC实例');
    expect(d.gameVersion, '1.20.1');
    expect(d.loader?.label, 'Fabric');
    expect(d.overridesPrefix, contains('.minecraft/'));

    final out = '${temp.path}${Platform.pathSeparator}out';
    ModpackImporter.extractPrefixes(mmc, out, prefixes: [d.overridesPrefix]);
    expect(
      File('$out${Platform.pathSeparator}options.txt').existsSync(),
      isTrue,
    );
  });

  test('HMCL 旧整合包：modpack.json + minecraft/pack.json', () {
    final hmcl = buildZip(temp, 'hmcl.zip', {
      'modpack.json': '{"name":"HMCL 包","gameVersion":"1.12.2"}',
      'minecraft/pack.json':
          '{"libraries":[{"name":"net.minecraftforge:forge:1.12.2-14.23.5.2847"}]}',
      'minecraft/config.cfg': 'x',
    });
    final d = ModpackImporter.inspect(hmcl);
    expect(d.kind, ModpackKind.hmcl);
    expect(d.gameVersion, '1.12.2');
    expect(d.loader, ModLoader.forge);
    // pack.json 的 Forge 坐标带 MC 前缀（1.12.2-14.23.5.2847），
    // importer 已剥成纯 Forge 版本；MultiMC components 的版本由
    // 控制器侧 _normalizeLoaderVersion 剥。
    expect(d.loaderVersion, '14.23.5.2847');
    expect(d.overridesPrefix, 'minecraft/');
  });

  test('普通 zip：剥一层外壳目录落盘；非 zip/mrpack 拒收', () {
    final plain = buildZip(temp, 'plain.zip', {
      'PackName/mods/a.jar': 'a',
      'PackName/config/b.toml': 'b',
    });
    final d = ModpackImporter.inspect(plain);
    expect(d.kind, ModpackKind.plain);
    final out = '${temp.path}${Platform.pathSeparator}out';
    ModpackImporter.extractPlain(plain, out);
    expect(
      File(
        '$out${Platform.pathSeparator}mods${Platform.pathSeparator}a.jar',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '$out${Platform.pathSeparator}config${Platform.pathSeparator}b.toml',
      ).existsSync(),
      isTrue,
    );

    expect(
      () => ModpackImporter.inspect(
        '${temp.path}${Platform.pathSeparator}nope.rar',
      ),
      throwsException,
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mint/services/launcher/game_dir.dart';

void main() {
  late Directory temp;
  late GameDir gameDir;

  void version(String id, Map<String, Object?> json) {
    final dir = Directory(p.join(temp.path, 'versions', id))
      ..createSync(recursive: true);
    File(p.join(dir.path, '$id.json')).writeAsStringSync(jsonEncode(json));
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mint_meta_test_');
    gameDir = GameDir(temp.path);
    version('1.20.4', {
      'type': 'release',
      'mainClass': 'net.minecraft.client.main.Main',
    });
    version('Fabulously Optimized', {
      'type': 'release',
      'inheritsFrom': '1.20.4',
      'mainClass': 'net.fabricmc.loader.impl.launch.knot.KnotClient',
    });
    version('1.20.1-forge-47.2.0', {
      'type': 'release',
      'inheritsFrom': '1.20.1',
      'libraries': [
        {'name': 'net.minecraftforge:forge:1.20.1-47.2.0'},
      ],
    });
    version('24w14a', {'type': 'snapshot'});
    version('c0.0.13a', {'type': 'old_alpha'});
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('整合包目录名不含加载器时，从 json 识别 Fabric', () {
    final meta = gameDir.metaOf('Fabulously Optimized');
    expect(meta.loader, 'fabric');
    expect(meta.type, 'release');
    expect(meta.mcVersion, '1.20.4');
  });

  test('Forge / 快照 / 远古版类型不被合并成原版', () {
    expect(gameDir.metaOf('1.20.1-forge-47.2.0').loader, 'forge');
    expect(gameDir.metaOf('1.20.1-forge-47.2.0').mcVersion, '1.20.1');
    expect(gameDir.metaOf('24w14a').type, 'snapshot');
    expect(gameDir.metaOf('c0.0.13a').type, 'old_alpha');
    expect(gameDir.metaOf('c0.0.13a').loader, isEmpty);
  });

  test('原版 release 不误判为加载器', () {
    final meta = gameDir.metaOf('1.20.4');
    expect(meta.loader, isEmpty);
    expect(meta.type, 'release');
    expect(meta.mcVersion, '1.20.4');
  });
}

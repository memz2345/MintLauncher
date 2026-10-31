// 版本隔离求值（PCL2 LaunchArgumentIndieV2 五档 + mods/saves 自动检测）
// 与 GameDir.factsOf 画像的单测。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/src/enums.dart';

void main() {
  late Directory temp;
  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('mint_isolation_test_');
    settings = SettingsService();
    await settings.load();
    // 生产环境由 LauncherController.init 注入；测试里直接指到临时目录。
    SettingsService.versionFactsProbe = (id) => GameDir(temp.path).factsOf(id);
  });

  tearDown(() {
    SettingsService.versionFactsProbe = null;
    temp.deleteSync(recursive: true);
  });

  Directory makeVersion(
    String id, {
    List<String> files = const [],
    String type = 'release',
  }) {
    final dir = Directory(
      '${temp.path}${Platform.pathSeparator}versions${Platform.pathSeparator}$id',
    )..createSync(recursive: true);
    File(
      '${dir.path}${Platform.pathSeparator}$id.json',
    ).writeAsStringSync('{"id":"$id","type":"$type"}');
    for (final f in files) {
      File('${dir.path}${Platform.pathSeparator}$f')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    return dir;
  }

  group('isolationFor（PCL2 五档 + mods/saves 自动）', () {
    test('关闭档：默认不隔离；版本目录有 mods 文件则无条件隔离', () {
      makeVersion('1.20.4');
      makeVersion('packed', files: ['mods/some-mod.jar']);
      settings.isolationMode = IsolationMode.off;

      expect(settings.isolationFor('1.20.4'), isFalse);
      // PCL2 PathIndie：mods 有文件 → 自动隔离，优先于全局「关闭」。
      expect(settings.isolationFor('packed'), isTrue);
    });

    test('saves 只有子目录才算（PCL2 同款：EnumerateDirectories）', () {
      makeVersion('worlds', files: ['saves/some_world/level.dat']);
      makeVersion('empty-saves', files: ['saves/.keep']);
      settings.isolationMode = IsolationMode.off;
      expect(settings.isolationFor('worlds'), isTrue);
      expect(settings.isolationFor('empty-saves'), isFalse);
    });

    test('单版本覆盖优先于全局档位与自动检测', () {
      makeVersion('packed', files: ['mods/a.jar']);
      makeVersion('plain');
      settings.isolationMode = IsolationMode.off;
      settings.updateVersionSettings(
        'packed',
        VersionSettings()..isolation = false,
      );
      settings.updateVersionSettings(
        'plain',
        VersionSettings()..isolation = true,
      );
      expect(settings.isolationFor('packed'), isFalse);
      expect(settings.isolationFor('plain'), isTrue);
    });

    test('五档对 modable / 老版本快照的求值', () {
      makeVersion('fabric-loader-1.20.4');
      makeVersion('1.20.4');
      makeVersion('1.2.5', type: 'old_beta');

      settings.isolationMode = IsolationMode.loaders;
      expect(settings.isolationFor('fabric-loader-1.20.4'), isTrue);
      expect(settings.isolationFor('1.20.4'), isFalse);

      settings.isolationMode = IsolationMode.oldSnapshots;
      expect(settings.isolationFor('1.2.5'), isTrue);
      expect(settings.isolationFor('1.20.4'), isFalse);

      settings.isolationMode = IsolationMode.oldAndLoaders;
      expect(settings.isolationFor('1.2.5'), isTrue);
      expect(settings.isolationFor('fabric-loader-1.20.4'), isTrue);

      settings.isolationMode = IsolationMode.all;
      expect(settings.isolationFor('1.20.4'), isTrue);
    });

    test('旧布尔配置迁移：true → 全部隔离', () async {
      SharedPreferences.setMockInitialValues({
        'mint.launcher_config': '{"versionIsolation":true}',
      });
      final migrated = SettingsService();
      await migrated.load();
      expect(migrated.isolationMode, IsolationMode.all);
    });
  });

  group('GameDir.factsOf', () {
    test('modable / 老版本 / 快照识别', () {
      final gameDir = GameDir(temp.path);
      makeVersion('fabric-loader-0.16-1.20.4');
      makeVersion('1.20.4');
      makeVersion('1.2.5', type: 'old_beta');
      makeVersion('24w14a', type: 'snapshot');

      expect(gameDir.factsOf('fabric-loader-0.16-1.20.4').modable, isTrue);
      expect(gameDir.factsOf('1.20.4').modable, isFalse);
      expect(gameDir.factsOf('1.2.5').oldOrSnapshot, isTrue);
      expect(gameDir.factsOf('1.20.4').oldOrSnapshot, isFalse);
      expect(gameDir.factsOf('24w14a').oldOrSnapshot, isTrue);
    });
  });
}

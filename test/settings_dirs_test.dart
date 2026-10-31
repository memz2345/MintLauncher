import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/settings_service.dart';
import 'package:mint/src/enums.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('多游戏目录：各自记住选中版本，版本设置按目录隔离', () async {
    final settings = SettingsService();
    await settings.load();
    final a = p.normalize('C:/Games/A');
    final b = p.normalize('C:/Games/B');

    settings.addGameDir(a);
    settings.selectedVersion = 'a-1.20.4';
    settings.updateVersionSettings(
      'a-1.20.4',
      VersionSettings(memoryMb: 1111)..isolation = true,
    );

    settings.addGameDir(b);
    settings.selectedVersion = 'b-1.20.4';
    settings.updateVersionSettings(
      'b-1.20.4',
      VersionSettings(memoryMb: 2222)..isolation = false,
    );

    expect(settings.gameDirs, [a, b]);
    expect(settings.gameDir, b);
    expect(settings.selectedVersion, 'b-1.20.4');

    settings.setActiveGameDir(a);
    expect(settings.selectedVersion, 'a-1.20.4');
    expect(settings.effectiveFor('a-1.20.4').memoryMb, 1111);
    expect(settings.effectiveFor('a-1.20.4').isolation, true);

    settings.setActiveGameDir(b);
    expect(settings.selectedVersion, 'b-1.20.4');
    expect(settings.effectiveFor('b-1.20.4').memoryMb, 2222);
    expect(settings.effectiveFor('b-1.20.4').isolation, false);

    // 移除目录不删除其他目录的选中记忆。
    settings.removeGameDir(b);
    expect(settings.gameDir, a);
    expect(settings.selectedVersion, 'a-1.20.4');
  });

  test('多目录 / 窗口材质随 JSON 持久化', () async {
    final settings = SettingsService();
    await settings.load();
    final a = p.normalize('C:/Games/A');
    final b = p.normalize('C:/Games/B');
    settings.addGameDir(a);
    settings.selectedVersion = 'a-1.20.4';
    settings.registerGameDir(b);
    await settings.setWindowEffect(WindowBackdropMode.acrylic);
    await settings.setBackdropTint(0.61);
    await settings.setEdgeScrollHaptic(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final reloaded = SettingsService();
    await reloaded.load();
    expect(reloaded.gameDirs, containsAll([a, b]));
    expect(reloaded.gameDir, a);
    expect(reloaded.selectedVersion, 'a-1.20.4');
    expect(reloaded.windowEffect, WindowBackdropMode.acrylic);
    expect(reloaded.backdropTint, closeTo(0.61, 0.001));
    expect(reloaded.edgeScrollHaptic, isFalse);
  });
}

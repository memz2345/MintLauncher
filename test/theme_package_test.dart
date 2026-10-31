import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/theme_package.dart';

/// 用真实的 MIUI 主题包（E:\qqshare\1.mtz）验证解析器。
/// 文件不存在时跳过（CI / 别的机器没有这个包）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('解析 1.mtz：声明、壁纸、图标、开机动画、颜色', () async {
    const path = r'E:\qqshare\1.mtz';
    if (!File(path).existsSync()) {
      // ignore: avoid_print
      print('跳过：$path 不存在');
      return;
    }
    final temp = await Directory.systemTemp.createTemp('mint-theme-test-');
    addTearDown(() async {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    final library = MintThemeLibrary.instance;
    library.rootOverride = temp.path;
    await library.load();
    final theme = await library.import(path);

    expect(theme.title, contains('芙卡洛斯'));
    expect(theme.version, 'HyperOS2.0');
    expect(theme.author, isNotEmpty);
    expect(theme.wallpaper, isNotEmpty);
    expect(File(theme.wallpaper).existsSync(), isTrue);
    expect(theme.lockWallpaper, isNotEmpty);
    expect(File(theme.lockWallpaper).existsSync(), isTrue);
    // com.android.settings 声明的设置/关于窗口背景（window_bg_light/dark）。
    expect(theme.settingsWindowBackground, isNotEmpty);
    expect(File(theme.settingsWindowBackground).existsSync(), isTrue);
    expect(theme.settingsWindowBackgroundDark, isNotEmpty);
    expect(File(theme.settingsWindowBackgroundDark).existsSync(), isTrue);
    // 全模块背景图（背景预览器的素材源）：拨号盘 / 各应用窗口背景，浅色 +
    // 夜间各一份，路径全部真实存在。
    expect(theme.backgrounds, isNotEmpty);
    expect(
      theme.backgrounds.any((b) => b.name == 'dialerpad_background'),
      isTrue,
      reason: '1.mtz 的 contacts 模块声明了拨号盘背景（浅蓝芙宁娜那张）',
    );
    expect(
      theme.backgrounds.any((b) => b.name == 'window_bg'),
      isTrue,
      reason: 'contacts 等模块声明 window_bg',
    );
    expect(
      theme.backgrounds.any((b) => b.dark),
      isTrue,
      reason: 'nightmode/ 下的夜间版背景也要收进来',
    );
    for (final b in theme.backgrounds) {
      expect(File(b.path).existsSync(), isTrue, reason: '${b.module}/${b.name}');
      expect(b.module, isNotEmpty);
    }
    // 关于页页头字标：HyperOS 主题声明的是 xiaomi_os_logo（宽字标）。
    expect(theme.settingsIcon, isNotEmpty);
    expect(File(theme.settingsIcon).existsSync(), isTrue);
    expect(theme.assetsVersion, kThemeAssetsVersion);
    // 音量条（miui.systemui.plugin 的 miui_volume_* + ic_miui_volume_media）。
    expect(theme.volumeIcon, isNotEmpty);
    expect(File(theme.volumeIcon).existsSync(), isTrue);
    expect(theme.volumeIconMuted, isNotEmpty);
    expect(File(theme.volumeIconMuted).existsSync(), isTrue);
    expect(theme.volumeAccentColor?.toARGB32(), 0xFFADDCFF);
    expect(theme.volumeTrackColor?.toARGB32(), 0x4E60C0FD);
    expect(theme.volumeColumnHeight, 165);
    expect(theme.accent, isNotNull);
    expect(theme.accent!.toARGB32(), 0xFF60C0FD);
    expect(theme.icons.length, greaterThanOrEqualTo(60));
    expect(theme.icons.first.packageName, isNotEmpty);
    expect(File(theme.icons.first.path).existsSync(), isTrue);
    expect(theme.bootAnimationDir, isNotEmpty);
    expect(File('${theme.bootAnimationDir}/desc.txt').existsSync(), isTrue);
    expect(
      File('${theme.bootAnimationDir}/part0/miui_boot_001.png').existsSync(),
      isTrue,
    );
    expect(theme.colors.length, greaterThan(100));
    // 控件样式：主题没有开关图片，但有开关 / 返回 / 滚动条等颜色声明。
    expect(theme.controls['switch'], isNotNull);
    expect(theme.controls['back']?.toUpperCase(), contains('60C0FD'));
    expect(theme.controls['scrollbar'], isNotNull);
    expect(theme.switchColor, isNotNull);
    expect(theme.backColor, isNotNull);
    // 卡片 / 弹窗选中项：主题用主色 30% 的半透明遮罩。
    expect(theme.cardColor, isNotNull);
    expect(theme.cardColor!.a, lessThan(1.0));
    expect(theme.dialogSelectedColor, isNotNull);
    expect(theme.widgetAssets['backArt'], isNotEmpty);
    expect(theme.widgetAssets['button'], isNotEmpty);
    expect(File(theme.widgetAssets['backArt']!).existsSync(), isTrue);
    expect(theme.modules.length, greaterThan(5));
    expect(theme.previews, isNotEmpty);

    // 重新加载：theme.json 缓存能完整还原。
    library.rootOverride = temp.path;
    final reloaded = MintThemeLibrary.instance;
    await reloaded.load();
    final cached = reloaded.byId(theme.id);
    expect(cached, isNotNull);
    expect(cached!.title, theme.title);
    expect(cached.icons.length, theme.icons.length);
    expect(cached.bootAnimationDir, theme.bootAnimationDir);
    expect(cached.controls, theme.controls);
    expect(cached.widgetAssets, theme.widgetAssets);

    // 老缓存补齐：模拟「早于素材解析导入」的 theme.json（没有 settings / volume
    // 素材、assetsVersion 落后），load() 要能从原 .mtz 里补解出来。
    final manifest = File('${theme.dir}/theme.json');
    final old = Map<String, Object?>.from(
      jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>,
    )
      ..remove('settingsWindowBackground')
      ..remove('settingsWindowBackgroundDark')
      ..remove('settingsIcon')
      ..remove('volumeIcon')
      ..remove('volumeIconMuted')
      ..remove('assetsVersion');
    manifest.writeAsStringSync(jsonEncode(old));
    await library.load(force: true);
    await library.upgradeAssets();
    final upgraded = library.byId(theme.id)!;
    expect(upgraded.settingsWindowBackground, theme.settingsWindowBackground);
    expect(upgraded.settingsIcon, theme.settingsIcon);
    expect(upgraded.volumeIcon, theme.volumeIcon);
    expect(upgraded.backgrounds.length, theme.backgrounds.length);
    expect(upgraded.assetsVersion, kThemeAssetsVersion);
    // 补齐结果写回了缓存：再 load 一次不用重解，值也还在。
    await library.load(force: true);
    expect(library.byId(theme.id)!.settingsIcon, theme.settingsIcon);
  });
}

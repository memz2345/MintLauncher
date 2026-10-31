import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/settings_service.dart';
import 'package:mint/services/texture_set_state.dart';
import 'package:mint/services/theme_package.dart';
import 'package:mint/ui/pages/about_page.dart';
import 'package:mint/widgets/bg_effect_background.dart';

late Directory _temp;

Future<void> _setUp() async {
  SharedPreferences.setMockInitialValues({});
  _temp = await Directory.systemTemp.createTemp('mint_about_test_');
  MintThemeLibrary.instance.rootOverride = _temp.path;
  await MintThemeLibrary.instance.load();
}

Future<void> _tearDown() async {
  MintThemeLibrary.instance.rootOverride = null;
  if (_temp.existsSync()) _temp.deleteSync(recursive: true);
}

Future<SettingsService> _settings() async {
  final settings = SettingsService();
  await settings.load();
  return settings;
}

Widget _wrap(SettingsService settings, {Key? pageKey}) {
  return ChangeNotifierProvider<SettingsService>.value(
    value: settings,
    child: MiuixThemeController(
      isDark: true,
      child: MaterialApp(
        home: MintAboutPage(key: pageKey, miuix: true),
      ),
    ),
  );
}

/// 滚到「高级设置」卡片并打开弹层（弹层里的开关顺序：效果背景 / 动态背景 / 卡片模糊）。
Future<void> _openAdvanced(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('高级设置'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.text('高级设置'));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

/// 在临时主题目录里造一个已导入的主题缓存（theme.json），供关于页测试套用。
Future<void> _writeTheme(
  String id, {
  Map<String, Object?> override = const {},
}) async {
  final dir = Directory('${_temp.path}/$id')..createSync(recursive: true);
  File('${dir.path}/theme.json').writeAsStringSync(
    jsonEncode({
      'id': id,
      'dir': dir.path,
      'title': '测试主题',
      'author': '测试作者',
      'designer': '测试设计',
      'version': '1.2.3',
      'uiVersion': '15',
      'description': '这是一段主题描述',
      'importedAt': '2026-10-29T00:00:00.000',
      'wallpaper': '',
      'lockWallpaper': '',
      'accent': null,
      'fontFile': '',
      'bootAnimationDir': '',
      'icons': <Object>[],
      'previews': <Object>[],
      'modules': <Object>[],
      'colors': <String, String>{},
      'strings': <String, String>{},
      'controls': <String, String>{},
      'widgetAssets': <String, String>{},
      'sourcePath': '',
      ...override,
    }),
  );
  await MintThemeLibrary.instance.load(force: true);
}

Future<SettingsService> _applyTheme(String id) async {
  final settings = await _settings();
  await settings.applyThemePackage(id);
  return settings;
}

void main() {
  setUp(_setUp);
  tearDown(_tearDown);

  testWidgets('没有主题时关于页回落到原来的 Mint 内容', (tester) async {
    final settings = await _settings();
    await tester.pumpWidget(_wrap(settings));
    // 默认背景是 OS3 动效（Ticker 常驻），不能 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Mint Launcher'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主题有 description.xml 声明时显示 mtz 的关于信息', (tester) async {
    const id = 'about_theme';
    await _writeTheme(id);
    final settings = await _applyTheme(id);

    await tester.pumpWidget(_wrap(settings));
    await tester.pumpAndSettle();

    expect(find.text('测试主题'), findsWidgets);
    expect(find.text('测试作者'), findsWidgets);
    expect(find.text('这是一段主题描述'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主题没声明关于页图标时，页头不画启动器的 M 徽标', (tester) async {
    const id = 'about_theme_no_icon';
    await _writeTheme(id);
    final settings = await _applyTheme(id);

    await tester.pumpWidget(_wrap(settings));
    await tester.pumpAndSettle();

    expect(find.text('测试主题'), findsWidgets);
    expect(find.text('M'), findsNothing);
  });

  testWidgets('主题声明了关于页图标时，页头画主题那张图', (tester) async {
    const id = 'about_theme_icon';
    // 1x1 透明像素，当作主题声明的 xiaomi_os_logo。
    final icon = File('${_temp.path}/$id/os_logo.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNg'
          'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
        ),
      );
    await _writeTheme(
      id,
      override: {'settingsIcon': icon.path, 'settingsAssetsScanned': true},
    );
    final settings = await _applyTheme(id);

    await tester.pumpWidget(_wrap(settings));
    await tester.pumpAndSettle();

    expect(find.text('M'), findsNothing);
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('有主题时高级设置照样能打开，动效开关置灰、卡片模糊可用', (tester) async {
    const id = 'about_theme_texture';
    await _writeTheme(id);
    final settings = await _applyTheme(id);

    await tester.pumpWidget(_wrap(settings));
    await tester.pumpAndSettle();
    await _openAdvanced(tester);

    final switches = find.byType(MiuixSwitch);
    expect(switches, findsNWidgets(3));
    // 有主题 → 动效层不画，效果背景 / 动态背景置灰；卡片模糊跟背景图无关，可用。
    expect(tester.widget<MiuixSwitch>(switches.first).enabled, isFalse);
    expect(tester.widget<MiuixSwitch>(switches.at(1)).enabled, isFalse);
    expect(tester.widget<MiuixSwitch>(switches.last).enabled, isTrue);

    await tester.tap(switches.last);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(settings.textureSettings['blurEnable'], isFalse);
    // ignore: avoid_print
    print('DBG after-switch: sheet? ${find.text('完成').evaluate().length} 高级设置=${find.text('高级设置').evaluate().length}');

    // 先关掉弹层再换页面实例：pumpWidget 对同类型根 widget 是原地更新
    // （MaterialApp / Navigator 状态沿用），旧弹层路由会一直留在栈上，
    // 「高级设置」会同时命中页面行和弹层标题。弹层可拖拽、内容可滚，
    // 「完成」按钮不一定在可视区，直接点弹层上方的 barrier 关闭。
    await tester.tapAt(const Offset(400, 40));
    await tester.pumpAndSettle();
    // 换一个新页面实例：参数从设置里读回来，不用重设。
    await tester.pumpWidget(_wrap(settings, pageKey: const ValueKey('second')));
    await tester.pumpAndSettle();
    await _openAdvanced(tester);
    expect(
      tester.widget<MiuixSwitch>(find.byType(MiuixSwitch).last).value,
      isFalse,
    );
  });

  testWidgets('没有主题时动效背景在画，所以动效开关可用', (tester) async {
    final settings = await _settings();
    await tester.pumpWidget(_wrap(settings));
    // 默认背景是 OS3 动效（Ticker 常驻），不能 pumpAndSettle。
    await tester.pump(const Duration(milliseconds: 300));
    await _openAdvanced(tester);

    final switches = find.byType(MiuixSwitch);
    expect(tester.widget<MiuixSwitch>(switches.first).enabled, isTrue);
    expect(tester.widget<MiuixSwitch>(switches.at(1)).enabled, isTrue);
  });

  test('纹理集参数 toMap / fromMap 往返', () {
    final state = TextureSetState(defaultBlur: true)
      ..set((s) {
        s.blurRadius = 120;
        s.blurEnable = false;
        s.blendIndex = 3;
      })
      ..setVariant(BgEffectVariant.os2);
    final restored = TextureSetState.fromMap(state.toMap(), defaultBlur: true);
    expect(restored.variant, BgEffectVariant.os2);
    expect(restored.blurRadius, 120);
    expect(restored.blurEnable, isFalse);
    expect(restored.blendPreset.label, blendModePresets[3].label);
    // 空 map（第一次用）→ 全部默认，blurEnable 跟随传入的默认值。
    final fresh = TextureSetState.fromMap(const {}, defaultBlur: false);
    expect(fresh.blurEnable, isFalse);
    expect(fresh.variant, BgEffectVariant.os3);
    expect(fresh.blurRadius, 60);
  });
}

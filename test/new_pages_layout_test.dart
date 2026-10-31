import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/launcher/account.dart';
import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/manifest.dart';
import 'package:mint/services/launcher/modloader.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/ui/pages/accounts_page.dart';
import 'package:mint/ui/pages/game_install_page.dart';
import 'package:mint/ui/pages/loader_install_page.dart';
import 'package:mint/ui/pages/home_page.dart';
import 'package:mint/ui/pages/settings_page.dart';
import 'package:mint/ui/pages/version_manager_page.dart';
import 'package:mint/ui/widgets/pcl_hover.dart';

late Directory _temp;
late Directory _second;
late SettingsService _settings;
late LauncherController _controller;

Future<void> _setUp() async {
  SharedPreferences.setMockInitialValues({});
  _temp = await Directory.systemTemp.createTemp('mint_ui_test_');
  final versionDir = Directory('${_temp.path}/versions/1.20.4')
    ..createSync(recursive: true);
  File('${versionDir.path}/1.20.4.json').writeAsStringSync(
    '{"id":"1.20.4","type":"release","releaseTime":"2023-12-07T12:00:00+00:00"}',
  );
  _second = await Directory.systemTemp.createTemp('mint_ui_test_second_');
  final fabricDir = Directory(
    '${_second.path}/versions/fabric-loader-0.16-1.20.4',
  )..createSync(recursive: true);
  File(
    '${fabricDir.path}/fabric-loader-0.16-1.20.4.json',
  ).writeAsStringSync('{"id":"fabric-loader-0.16-1.20.4","type":"release"}');
  _settings = SettingsService();
  await _settings.load();
  _settings.gameDir = _temp.path;
  _controller = LauncherController(settings: _settings);
  await _controller.init();
  _controller.manifest = VersionManifest(
    latest: const Latest(release: '1.20.4', snapshot: '24w01a'),
    versions: const [
      ManifestVersion(
        id: '1.20.4',
        url: '',
        type: 'release',
        releaseTime: '2023-12-07T12:00:00+00:00',
      ),
    ],
  );
}

Future<void> _tearDown() async {
  _controller.dispose();
  await _temp.delete(recursive: true);
  await _second.delete(recursive: true);
}

Widget _wrap(bool miuix, Widget child) {
  final app = MaterialApp(home: child);
  if (!miuix) return app;
  return MiuixThemeController(isDark: true, child: app);
}

Widget _providers(Widget child) => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(value: _settings),
    ChangeNotifierProvider<LauncherController>.value(value: _controller),
  ],
  child: child,
);

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(_setUp);
  tearDown(_tearDown);

  for (final miuix in [false, true]) {
    testWidgets('一键安装页 ${miuix ? 'miuix' : 'Material'} 宽屏 / 窄屏均可渲染', (
      tester,
    ) async {
      _setSize(tester, const Size(1180, 760));
      await tester.pumpWidget(
        _providers(
          _wrap(miuix, GameInstallPage(miuix: miuix, initialVersion: '1.20.4')),
        ),
      );
      // 可用加载器列表走网络预取：测试环境 HTTP 统一 400，推进时间让
      // 下载器的退避重试全部走完，避免留下 pending timer。
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.textContaining('安装 1.20.4'), findsWidgets);
      expect(find.text('模组加载器'), findsOneWidget);
      expect(tester.takeException(), isNull);

      _setSize(tester, const Size(480, 800));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('账户页 ${miuix ? 'miuix' : 'Material'} 窄屏可渲染', (tester) async {
      _settings.addAccount(createOfflineAccount('TestPlayer'));
      _setSize(tester, const Size(480, 800));
      await tester.pumpWidget(
        _providers(
          _wrap(
            miuix,
            AccountsPage(
              miuix: miuix,
              settings: _settings,
              controller: _controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前账户'), findsOneWidget);
      expect(find.text('TestPlayer'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('主页 ${miuix ? 'miuix' : 'Material'}：右侧信息栏 + 启动 FAB', (
      tester,
    ) async {
      _settings.addAccount(createOfflineAccount('TestPlayer'));
      _setSize(tester, const Size(1180, 760));
      await tester.pumpWidget(_providers(_wrap(miuix, HomePage(miuix: miuix))));
      await tester.pumpAndSettle();
      expect(find.text('TestPlayer'), findsOneWidget);
      expect(find.text('版本管理'), findsOneWidget);
      expect(find.text('当前版本：1.20.4'), findsOneWidget);
      expect(find.text('启动游戏'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('加载器过滤规则对齐 PCL2', () {
    expect(LoaderCompat.supports(ModLoader.forge, '1.20.4', 'release'), isTrue);
    expect(
      LoaderCompat.supports(ModLoader.forge, '24w01a', 'snapshot'),
      isFalse,
    );
    expect(
      LoaderCompat.supports(ModLoader.fabric, '1.13.2', 'release'),
      isFalse,
    );
    expect(LoaderCompat.supports(ModLoader.fabric, '1.14', 'release'), isTrue);
    expect(
      LoaderCompat.supports(ModLoader.neoforge, '1.20.1', 'release'),
      isFalse,
    );
    expect(
      LoaderCompat.supports(ModLoader.neoforge, '1.20.2', 'release'),
      isTrue,
    );
    expect(LoaderCompat.supports(ModLoader.quilt, '1.14', 'release'), isTrue);
    expect(
      LoaderCompat.supports(ModLoader.fabric, '1.20.4', 'old_alpha'),
      isFalse,
    );
  });

  testWidgets('版本管理页 miuix：左侧目录切换 + 右侧版本列表', (tester) async {
    _settings.registerGameDir(_second.path);
    final secondName = _settings.gameDirName(_second.path);
    _setSize(tester, const Size(1180, 760));
    await tester.pumpWidget(
      _providers(_wrap(true, const VersionManagerPage(miuix: true))),
    );
    await tester.pumpAndSettle();

    expect(find.text('版本管理'), findsWidgets);
    expect(find.text('游戏目录'), findsOneWidget);
    expect(find.text('添加游戏目录'), findsOneWidget);
    expect(find.text('1.20.4'), findsWidgets);
    expect(find.text(secondName), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 点左侧第二个目录：切当前游戏目录，右侧列表换成 Fabric 版本。
    await tester.tap(find.text(secondName));
    await tester.pumpAndSettle();
    expect(_settings.gameDir, _second.path);
    expect(find.text('fabric-loader-0.16-1.20.4'), findsWidgets);
    expect(tester.takeException(), isNull);

    // 窄屏（目录选择条 + 列表）也不能溢出。
    _setSize(tester, const Size(480, 800));
    await tester.pumpAndSettle();
    expect(find.text('fabric-loader-0.16-1.20.4'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('版本行按下高亮盖满整行（ripple / 悬浮底板不缩在内容区）', (tester) async {
    _setSize(tester, const Size(1180, 760));
    await tester.pumpWidget(
      _providers(_wrap(false, const VersionManagerPage(miuix: false))),
    );
    await tester.pumpAndSettle();

    final subtitle = find.textContaining('Minecraft 1.20.4 · 原版');
    expect(subtitle, findsOneWidget);
    final surface = find
        .ancestor(of: subtitle, matching: find.byType(PclHoverSurface))
        .first;
    final rowRect = tester.getRect(surface);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: rowRect.center);
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.down(rowRect.center);
    await tester.pump(const Duration(milliseconds: 160));
    final layer = find.descendant(
      of: surface,
      matching: find.byKey(const ValueKey('pcl.hover.fade')),
    );
    expect(layer, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    final layerRect = tester.getRect(layer);
    // 按下底板必须和整行同宽同高，不能只盖住文字那一段（允许 PCL 那
    // 0.996 的收放缩放带来的几像素差）。
    expect(layerRect.width, greaterThan(rowRect.width * 0.98));
    expect(layerRect.height, greaterThan(rowRect.height - 6));
    // 文字列只有整行的一部分：底板比它宽才说明盖满了行尾动作按钮区。
    final subtitleRect = tester.getRect(subtitle);
    expect(layerRect.width, greaterThan(subtitleRect.width + 80));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('设置页窄屏：取消分类选择，所有设置单页铺开', (tester) async {
    _setSize(tester, const Size(480, 800));
    await tester.pumpWidget(
      _providers(_wrap(false, const SettingsPage(miuix: false))),
    );
    await tester.pumpAndSettle();
    // 竖屏单页：不再有分类胶囊（ChoiceChip）；启动分区直接可见。
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('启动'), findsWidgets);
    await tester.tap(find.text('启动').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 单页滚动可达网络分区的内容（下载线程数）。
    final scrollable = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('下载线程数'),
      320,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('下载线程数'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页：左分类进外观，窗口材质用独立选择页', (tester) async {
    _setSize(tester, const Size(1180, 760));
    await tester.pumpWidget(
      _providers(_wrap(true, const SettingsPage(miuix: true))),
    );
    await tester.pumpAndSettle();

    // 设置已改成 HMCL 式左分类 / 右内容；窗口材质在外观分类里。
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('窗口背景材质'),
      320,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('窗口背景材质')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    expect(find.text('窗口背景材质'), findsOneWidget);

    // 带选项的弹窗已改成独立页面（共用母页）。
    await tester.tap(find.text('窗口背景材质'));
    await tester.pumpAndSettle();
    if (Platform.isLinux) {
      // Linux 只有系统模糊一种实现，选项收敛成 关闭 / 窗口模糊（系统）。
      expect(find.text('关闭'), findsOneWidget);
      expect(find.text('窗口模糊（系统）'), findsOneWidget);
      expect(find.text('云母 Mica'), findsNothing);
    } else {
      expect(find.text('云母 Mica'), findsOneWidget);
      expect(find.text('亚克力 Acrylic'), findsOneWidget);
      expect(find.text('Aero 毛玻璃'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}

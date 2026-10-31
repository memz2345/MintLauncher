import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/manifest.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/window_caption_signals.dart';
import 'package:mint/src/loading_indicator_m3e.dart';
import 'package:mint/ui/pages/common.dart';
import 'package:mint/ui/pages/vanilla_versions_page.dart';
import 'package:mint/ui/pages/version_settings_page.dart';
import 'package:mint/ui/widgets/mint_collapsible_card.dart';
import 'package:mint/ui/widgets/mint_refresh.dart';
import 'package:mint/ui/widgets/pcl_hover.dart';

late Directory _temp;
late SettingsService _settings;
late LauncherController _controller;

Future<void> _setUp() async {
  SharedPreferences.setMockInitialValues({});
  _temp = await Directory.systemTemp.createTemp('mint_ui2_test_');
  final versionDir = Directory('${_temp.path}/versions/1.20.4')
    ..createSync(recursive: true);
  File('${versionDir.path}/1.20.4.json').writeAsStringSync(
    '{"id":"1.20.4","type":"release","releaseTime":"2023-12-07T12:00:00+00:00"}',
  );
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
      ManifestVersion(
        id: '24w01a',
        url: '',
        type: 'snapshot',
        releaseTime: '2024-01-03T10:30:00+00:00',
      ),
      ManifestVersion(
        id: 'b1.7.3',
        url: '',
        type: 'old_beta',
        releaseTime: '2011-07-08T00:00:00+00:00',
      ),
    ],
  );
}

Future<void> _tearDown() async {
  _controller.dispose();
  await _temp.delete(recursive: true);
}

Widget _wrap(bool miuix, Widget child) {
  final app = MaterialApp(home: Scaffold(body: child));
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

  group('PCL2 动画移植', () {
    testWidgets('悬浮底板淡入 / 淡出而不是直接换色', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: PclHoverSurface(
                  onTap: () {},
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text('条目'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final fade = find.byKey(const ValueKey('pcl.hover.fade'));
      expect(fade, findsNothing);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('条目')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(fade, findsOneWidget);
      final mid = tester.widget<Opacity>(fade).opacity;
      expect(mid, greaterThan(0));
      expect(mid, lessThan(1));

      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<Opacity>(fade).opacity, 1);

      await gesture.moveTo(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(tester.widget<Opacity>(fade).opacity, lessThan(1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(fade, findsNothing);
    });

    testWidgets('可折叠大卡片：折叠后内容从树上摘掉，再展开恢复', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 520,
                child: MintCollapsibleCard(
                  miuix: false,
                  title: '正式版',
                  subtitle: '3 个版本',
                  children: const [
                    Padding(padding: EdgeInsets.all(16), child: Text('1.20.4')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('1.20.4'), findsOneWidget);
      await tester.tap(find.text('正式版'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      expect(find.text('1.20.4'), findsNothing);

      await tester.tap(find.text('正式版'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1.20.4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('原版下载页按类型分组，行说明只有发布日期和时间', (tester) async {
    _setSize(tester, const Size(900, 800));
    await tester.pumpWidget(
      _providers(_wrap(false, const VanillaVersionsPage(miuix: false))),
    );
    await tester.pumpAndSettle();

    expect(find.text('正式版'), findsOneWidget);
    expect(find.text('快照'), findsOneWidget);
    expect(find.text('远古版'), findsOneWidget);
    expect(find.text('1.20.4'), findsOneWidget);
    expect(
      find.text(formatReleaseTime('2023-12-07T12:00:00+00:00')),
      findsOneWidget,
    );
    // 下载图标：已安装（1.20.4）和未安装的行右侧都要有。
    expect(find.byIcon(Icons.download_outlined), findsWidgets);
    // 快照默认折叠：内容不参与布局。
    expect(find.text('24w01a'), findsNothing);

    await tester.tap(find.text('快照'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('24w01a'), findsOneWidget);
    expect(
      find.text(formatReleaseTime('2024-01-03T10:30:00+00:00')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final miuix in [false, true]) {
    testWidgets('版本设置 ${miuix ? 'miuix' : 'Material'} 左侧分类切换右侧内容', (
      tester,
    ) async {
      _setSize(tester, const Size(1180, 760));
      await tester.pumpWidget(
        _providers(
          _wrap(miuix, VersionSettingsPage(miuix: miuix, versionId: '1.20.4')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('版本信息'), findsOneWidget);
      expect(find.text('自动连接服务器'), findsNothing);

      await tester.tap(find.text('启动').first);
      await tester.pumpAndSettle();
      expect(find.text('自动连接服务器'), findsOneWidget);
      expect(find.text('版本隔离'), findsOneWidget);

      await tester.tap(find.text('高级').first);
      await tester.pumpAndSettle();
      expect(find.text('JVM 参数'), findsWidgets);
      expect(find.text('环境变量'), findsWidgets);
      expect(tester.takeException(), isNull);

      _setSize(tester, const Size(560, 820));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('M3E 下拉刷新：过阈值松手会触发 onRefresh', (tester) async {
    _setSize(tester, const Size(520, 720));
    var refreshed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MintRefreshView(
            miuix: false,
            onRefresh: () async {
              refreshed++;
              await Future<void>.delayed(const Duration(milliseconds: 20));
            },
            child: ListView.builder(
              physics: kMintPageScrollPhysics,
              itemCount: 30,
              itemBuilder: (context, i) =>
                  SizedBox(height: 48, child: Text('row $i')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(260, 200));
    await gesture.moveBy(const Offset(0, 340));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();

    expect(refreshed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('miuix 下拉刷新：页面元素下移并触发 onRefresh', (tester) async {
    _setSize(tester, const Size(520, 720));
    var refreshed = 0;
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          home: Scaffold(
            body: MintRefreshView(
              miuix: true,
              onRefresh: () async {
                refreshed++;
                await Future<void>.delayed(const Duration(milliseconds: 20));
              },
              child: ListView.builder(
                physics: kMintPageScrollPhysics,
                itemCount: 30,
                itemBuilder: (context, i) =>
                    SizedBox(height: 48, child: Text('mrow $i')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(260, 200));
    await gesture.moveBy(const Offset(0, 320));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpAndSettle();

    expect(refreshed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动刷新（顶栏按钮路径）：Material 浮出 M3E 指示器', (tester) async {
    _setSize(tester, const Size(520, 720));
    var refreshed = 0;
    final controller = MintRefreshController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MintRefreshView(
            miuix: false,
            controller: controller,
            onRefresh: () async {
              refreshed++;
              await Future<void>.delayed(const Duration(milliseconds: 80));
            },
            child: ListView.builder(
              physics: kMintPageScrollPhysics,
              itemCount: 30,
              itemBuilder: (context, i) =>
                  SizedBox(height: 48, child: Text('row $i')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoadingIndicatorM3E), findsNothing);

    // 顶栏「刷新」按钮等价于 controller.refresh()：不拖动列表也要出指示器。
    unawaited(controller.refresh());
    await tester.pump();
    expect(refreshed, 1);
    expect(find.byType(LoadingIndicatorM3E), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(LoadingIndicatorM3E), findsOneWidget);
    await tester.pumpAndSettle();
    // 刷新完成后指示器收起。
    expect(find.byType(LoadingIndicatorM3E), findsNothing);
    expect(controller.isRefreshing, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动刷新：miuix 页面元素整体下推', (tester) async {
    _setSize(tester, const Size(520, 720));
    var refreshed = 0;
    final controller = MintRefreshController();
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          home: Scaffold(
            body: MintRefreshView(
              miuix: true,
              controller: controller,
              onRefresh: () async {
                refreshed++;
                await Future<void>.delayed(const Duration(milliseconds: 300));
              },
              child: ListView.builder(
                physics: kMintPageScrollPhysics,
                itemCount: 30,
                itemBuilder: (context, i) =>
                    SizedBox(height: 48, child: Text('mrow $i')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('mrow 0')).dy;

    unawaited(controller.refresh());
    await tester.pump();
    expect(refreshed, 1);
    // 内容被指示圈 + 文案下推（300ms 的刷新窗口内处于下压状态）。
    // 分两帧推进：弹簧是逐帧驱动的，一帧跳 120ms 会错过中间态。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(find.text('mrow 0')).dy, greaterThan(before));
    await tester.pumpAndSettle();
    // 完成后弹回原位。
    expect(tester.getTopLeft(find.text('mrow 0')).dy, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('原生标题栏信号能驱动最大化按钮悬浮态与点击计数', (tester) async {
    final signals = WindowCaptionSignals.instance;
    signals.reset();
    addTearDown(signals.reset);
    signals.bind();

    Future<void> emit(String method, Object arguments) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'mint/window_chrome',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            (_) {},
          );
    }

    await emit('maximizeHover', true);
    expect(signals.maximizeHover.value, isTrue);
    final before = signals.maximizeClick.value;
    await emit('maximizeClick', true);
    expect(signals.maximizeClick.value, before + 1);
    await emit('maximizeHover', false);
    expect(signals.maximizeHover.value, isFalse);
  });
}

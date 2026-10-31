import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/src/enums.dart';
import 'package:mint/services/window_caption_signals.dart';
import 'package:mint/ui/mint_icons.dart';
import 'package:mint/ui/window_chrome.dart';
import 'package:mint/widgets/mdui_ripple.dart' show mintSplashFactory;
import 'package:mint/ui/widgets/mint_page.dart';

void main() {
  setUp(() {
    // 返回箭头跟界面风格走（MintBackIcon）：测试断言的是 Material 的
    // arrow_back，先把全局风格钉在 material。
    MintUiStyle.current = UiStyle.materialExpressive;
    WindowCaptionSignals.instance.reset();
    final chrome = MintWindowChrome.instance;
    chrome.reset();
    chrome.enabled = true;
  });

  tearDown(() {
    MintUiStyle.current = UiStyle.miuix;
    WindowCaptionSignals.instance.reset();
    final chrome = MintWindowChrome.instance;
    chrome.enabled = false;
    chrome.reset();
  });

  testWidgets('小标题二级页把 back / 标题 / 操作托管到窗口标题栏', (tester) async {
    final navKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: [MintWindowChrome.instance.observer],
          builder: (context, child) => Column(
            children: [
              MintWindowTitleBar(navigatorKey: navKey),
              Expanded(child: child!),
            ],
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MintPageScaffold(
                        miuix: true,
                        title: '版本管理',
                        showBack: true,
                        actions: [
                          MintTopBarAction(
                            miuix: true,
                            icon: Icons.tune,
                            tooltip: '操作',
                            onPressed: () {},
                          ),
                        ],
                        body: (_) => const SizedBox.expand(),
                      ),
                    ),
                  ),
                  child: const Text('push'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 根页面：标题栏显示应用名，没有页面返回箭头。
    expect(find.text('Mint Launcher'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();

    // 二级页：窗口标题栏只显示主标题，页面内不再重复。
    expect(find.text('版本管理'), findsOneWidget);
    expect(find.text('测试副标题'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.text('Mint Launcher'), findsNothing);

    // back 与右上角三大金刚同宽同高，并贴左/右边缘（对称）。
    final backButton = find.byKey(const ValueKey('caption-back'));
    final closeButton = find.byKey(const ValueKey('caption-close'));
    expect(tester.getSize(backButton), tester.getSize(closeButton));
    expect(tester.getTopLeft(backButton).dx, 0);
    expect(
      tester.getTopLeft(closeButton).dx + tester.getSize(closeButton).width,
      tester.getSize(find.byType(MintCaptionBar)).width,
    );

    // 最小化按钮 hover 有 state layer，点击会出 ripple。
    Color? bgOf(Finder finder) {
      final decoration = tester.widget<AnimatedContainer>(finder).decoration;
      return decoration is BoxDecoration ? decoration.color : null;
    }

    final minBg = find.byKey(const ValueKey('caption-bg-最小化'));
    expect(bgOf(minBg), Colors.transparent);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('caption-min'))),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(bgOf(minBg), isNot(Colors.transparent));
    await mouse.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 120));

    // 最大化热区在原生非客户区，hover / 点击都走 mint/window_chrome 通道。
    final maxBg = find.byKey(const ValueKey('caption-bg-最大化'));
    expect(bgOf(maxBg), Colors.transparent);
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'mint/window_chrome',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('maximizeHover', true),
          ),
          (_) {},
        );
    await tester.pump(const Duration(milliseconds: 120));
    expect(bgOf(maxBg), isNot(Colors.transparent));

    // 四个 caption 按钮都用 InkWell 的原生水波（Windows 下 splashFactory
    // 换成 mdui 观感，非 Windows 保持 InkRipple）。
    for (final label in ['返回', '最小化', '最大化', '关闭']) {
      final ink = tester.widget<InkWell>(
        find.byKey(ValueKey('caption-ink-$label')),
      );
      expect(ink.splashFactory, mintSplashFactory);
    }

    // 原生点击没有指针事件可喂 InkWell：Dart 在按钮中心合成 pointer
    // down，松手信号再合成 up，走完整 InkWell tap 语义。
    var toggleCalls = 0;
    const channel = MethodChannel('mint/window_chrome');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'toggleMaximize') toggleCalls++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<void> nativeMessage(String method, [Object? args]) async {
      await messenger.handlePlatformMessage(
        'mint/window_chrome',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
    }

    await nativeMessage('maximizeClick', true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const ValueKey('caption-ink-最大化')), findsOneWidget);
    expect(toggleCalls, 0, reason: '按下只出水波，松手才动作');
    expect(bgOf(maxBg), isNot(Colors.transparent), reason: '按下态已生效');

    await nativeMessage('maximizeRelease', true);
    await tester.pump();
    expect(toggleCalls, 1, reason: '合成 pointer up 触发 InkWell.onTap');
    await tester.pumpAndSettle();

    // 拖出按钮 / 失焦：release=false 只取消水波，不触发点击。
    await nativeMessage('maximizeClick', true);
    await tester.pump(const Duration(milliseconds: 60));
    await nativeMessage('maximizeRelease', false);
    await tester.pump();
    expect(toggleCalls, 1);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.text('Mint Launcher'), findsOneWidget);
    expect(find.text('版本管理'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Material 二级页托管标题栏后正文不再垫页面顶栏', (tester) async {
    // 托管后窗口标题栏在 Navigator 之上，页面内没有顶栏；正文再垫 56px
    // 就是标题栏下面那块莫名的空白。
    EdgeInsets? padding;
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          navigatorObservers: [MintWindowChrome.instance.observer],
          home: MintPageScaffold(
            miuix: false,
            title: '设置',
            showBack: true,
            body: (p) {
              padding = p;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(MintWindowChrome.instance.currentPage?.title, '设置');
    expect(padding, EdgeInsets.zero);
  });
}

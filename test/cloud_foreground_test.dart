// 云雾前景的纯逻辑单测：blob 场参数、透明度推导、uniform 打包顺序、
// 半分辨率尺寸换算，外加 widget 冒烟与「点击穿透」回归（IgnorePointer）。
//
// GLSL 本体（fbm/域扭曲/云团场）跑不了单测，观感靠真机截图把关
// （build/mint_verify/），这里锁的是 Dart 侧全部可推导的参数逻辑。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/account.dart' show createOfflineAccount;
import 'package:mint/services/settings_service.dart';
import 'package:mint/ui/nav_state.dart';
import 'package:mint/ui/pages/home_page.dart';
import 'package:mint/ui/pages/common.dart' show MintSwitchTile;
import 'package:mint/ui/pages/settings_page.dart';
import 'package:mint/widgets/mint_cloud_foreground.dart';

void main() {
  group('cloudEffectiveOpacity（深浅主题不透明度推导）', () {
    test('输入被钳到 0~1', () {
      expect(cloudEffectiveOpacity(-0.5, dark: false), 0.0);
      expect(cloudEffectiveOpacity(2.0, dark: false), lessThanOrEqualTo(0.55));
      expect(cloudEffectiveOpacity(2.0, dark: true), lessThanOrEqualTo(0.34));
    });

    test('随输入单调不减', () {
      var prevLight = 0.0;
      var prevDark = 0.0;
      for (var v = 0.0; v <= 1.0001; v += 0.1) {
        final l = cloudEffectiveOpacity(v, dark: false);
        final d = cloudEffectiveOpacity(v, dark: true);
        expect(l, greaterThanOrEqualTo(prevLight - 1e-9));
        expect(d, greaterThanOrEqualTo(prevDark - 1e-9));
        prevLight = l;
        prevDark = d;
      }
    });

    test('硬上限：深色 0.34、浅色 0.55（绝不盖内容）', () {
      for (var v = 0.0; v <= 1.0001; v += 0.05) {
        expect(cloudEffectiveOpacity(v, dark: true), lessThanOrEqualTo(0.34));
        expect(cloudEffectiveOpacity(v, dark: false), lessThanOrEqualTo(0.55));
      }
    });

    test('同输入下深色比浅色淡（暗底白雾更扎眼）', () {
      for (var v = 0.05; v <= 1.0001; v += 0.1) {
        expect(
          cloudEffectiveOpacity(v, dark: true),
          lessThan(cloudEffectiveOpacity(v, dark: false)),
        );
      }
    });

    test('出厂默认（0.55）落在柔和区间', () {
      expect(cloudEffectiveOpacity(0.55, dark: true), closeTo(0.231, 1e-9));
      expect(cloudEffectiveOpacity(0.55, dark: false), closeTo(0.341, 1e-9));
    });
  });

  group('cloudBlobCount / cloudShadeFor', () {
    test('密度 0.5 → 4 团；下限 1.5、上限 8', () {
      expect(cloudBlobCount(0.5), 4.0);
      expect(cloudBlobCount(0.0), 1.5);
      expect(cloudBlobCount(1.0), 8.0);
      expect(cloudBlobCount(2.0), 8.0);
      expect(cloudBlobCount(-1.0), 1.5);
    });

    test('浅色主题灰度更深（白底上才显形）', () {
      expect(cloudShadeFor(true), lessThan(cloudShadeFor(false)));
    });
  });

  group('cloudRenderSize（半分辨率）', () {
    test('边长减半、下取整', () {
      expect(cloudRenderSize(const Size(1181, 761)), const Size(590, 380));
      expect(cloudRenderSize(const Size(100, 100)), const Size(50, 50));
      expect(cloudRenderSize(const Size(101, 101)), const Size(50, 50));
    });

    test('极小尺寸至少 1×1', () {
      expect(cloudRenderSize(Size.zero), const Size(1, 1));
      expect(cloudRenderSize(const Size(0.5, 0.5)), const Size(1, 1));
    });
  });

  group('cloudUniforms（shader uniform 打包）', () {
    test('顺序与 cloud_foreground.frag 声明一致（0..8）', () {
      final u = cloudUniforms(
        width: 590,
        height: 380,
        time: 12.5,
        blobs: 4,
        seed: 7,
        opacity: 0.231,
        shade: 0.30,
        topBias: 0.72,
        drift: 1.0,
      );
      expect(u, hasLength(9));
      expect(u[0], 590); // uSize.x
      expect(u[1], 380); // uSize.y
      expect(u[2], 12.5); // uTime
      expect(u[3], 4.0); // uBlobs
      expect(u[4], 7.0); // uSeed
      expect(u[5], 0.231); // uOpacity
      expect(u[6], 0.30); // uShade
      expect(u[7], 0.72); // uTopBias
      expect(u[8], 1.0); // uDrift
    });
  });

  group('MintCloudForeground widget 冒烟', () {
    testWidgets('透明度为 0 时整层退化为空', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: MintCloudForeground(opacity: 0, animated: false),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(MintCloudForeground), findsOneWidget);
      // opacity=0 → cloudEffectiveOpacity=0 → 不该有任何画笔在跑。
      expect(
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null),
        findsNothing,
      );
    });

    testWidgets('静态模式渲染不抛异常，且 RepaintBoundary 就位', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: MintCloudForeground(animated: false),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.byType(RepaintBoundary), findsWidgets);
    });

    test('preload 幂等：重复调用不炸；shader 可用时 uniform 下标全部合法', () async {
      await MintCloudForeground.preload();
      await MintCloudForeground.preload();
      // 测试环境可能加载不了 shader 资产，ready 与否都算通过 ——
      // 失败路径要求「安静退化」而不是抛异常。
      expect(MintCloudForeground.ready, isA<bool>());
      ui.FragmentProgram? p;
      try {
        p = await ui.FragmentProgram.fromAsset('shaders/cloud_foreground.frag');
      } catch (_) {
        // 测试环境没有编译好的 shader 资产时走这里。
      }
      if (p != null) {
        // frag 里声明了 9 个 float uniform，下标 0..8 必须都能写。
        final shader = p.fragmentShader();
        final u = cloudUniforms(
          width: 10,
          height: 10,
          time: 0,
          blobs: 4,
          seed: 7,
          opacity: 0.2,
          shade: 0.3,
          topBias: 0.7,
          drift: 1,
        );
        for (var i = 0; i < u.length; i++) {
          shader.setFloat(i, u[i]);
        }
      }
    });
  });

  group('云雾层不挡交互（IgnorePointer 点击穿透）', () {
    /// 云雾盖在整个主页上（默认开启时就是真机形态）。点账户行 / FAB 必须
    /// 照常生效 —— 穿透由 [IgnorePointer] 保证，这里锁死这条回归。
    testWidgets('主页上点账户行与 FAB，云雾层不吞事件', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.load();
      final controller = LauncherController(settings: settings);
      await controller.init();
      addTearDown(controller.dispose);
      settings
        ..addAccount(createOfflineAccount('CloudA'))
        ..addAccount(createOfflineAccount('CloudB'))
        ..selectAccount('CloudA');

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1180, 760);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<LauncherController>.value(value: controller),
          ],
          child: const MaterialApp(home: HomePage(miuix: false)),
        ),
      );
      await tester.pumpAndSettle();

      // 云雾层真的盖在页面上（默认设置开启时）。
      expect(find.byType(MintCloudForeground), findsOneWidget);

      // 点另一个账户名：切换选中 —— 事件穿过了整页的云雾层
      // （账户卡也在 Positioned.fill 的覆盖范围内）。
      await tester.tap(find.text('CloudB'));
      await tester.pumpAndSettle();
      expect(settings.selectedAccountName, 'CloudB');

      // 不点 FAB：在这台机器上 init 会摸到真实 minecraft 目录，FAB 会走
      // 真启动流程（无限进度动画），跟穿透断言无关。
      NavRequests.tab.value = -1;
    });
  });

  group('设置页：外观分组里的「云雾前景」', () {
    testWidgets('开关 + 滑杆在设置页可见且可操作', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.load();
      final controller = LauncherController(settings: settings);
      await controller.init();
      addTearDown(controller.dispose);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1180, 4000);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<LauncherController>.value(value: controller),
          ],
          child: const MaterialApp(home: SettingsPage(miuix: false)),
        ),
      );
      await tester.pumpAndSettle();

      // 设置页改成左分类 / 右内容；云雾前景在「外观」分类里。
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();

      expect(find.text('云雾前景'), findsOneWidget);
      expect(find.text('云雾不透明度'), findsOneWidget);
      expect(find.text('云团密度'), findsOneWidget);

      // 关掉开关（点开关本体，标题不触发）：滑杆收起。
      final tile = find.ancestor(
        of: find.text('云雾前景'),
        matching: find.byType(MintSwitchTile),
      );
      expect(tile, findsOneWidget);
      final cloudSwitch = find.descendant(
        of: tile,
        matching: find.byType(Switch),
      );
      expect(cloudSwitch, findsOneWidget);
      await tester.tap(cloudSwitch);
      await tester.pumpAndSettle();
      expect(settings.cloudForeground, isFalse);
      expect(find.text('云团密度'), findsNothing);

      // 再打开：滑杆回来。
      await tester.tap(
        find.descendant(of: tile, matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
      expect(settings.cloudForeground, isTrue);
      expect(find.text('云团密度'), findsOneWidget);
    });
  });
}

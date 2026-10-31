import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/widgets/mdui_ripple.dart';

void main() {
  group('mdui v1 直径 / 半径', () {
    const row = Rect.fromLTWH(0, 0, 400, 60);

    test('直径 = max(元素对角线, 48px)', () {
      final diagonal = (const Offset(400, 60)).distance;
      expect(MduiInkRipple.diameterFor(row), closeTo(diagonal, 0.01));
      expect(MduiInkRipple.radiusFor(row), closeTo(diagonal / 2, 0.01));
      // 最终圆是「居中 + 对角线直径」，必然盖满整行。
      expect(MduiInkRipple.radiusFor(row) * 2, greaterThan(row.width));
      expect(MduiInkRipple.radiusFor(row) * 2, greaterThan(row.height));
    });

    test('小元素取 48px 直径下限', () {
      const box = Rect.fromLTWH(0, 0, 10, 10);
      expect(MduiInkRipple.diameterFor(box), 48.0);
      expect(MduiInkRipple.radiusFor(box), 24.0);
    });

    test('半径与按点无关（v1 圆心会滑到元素中心）', () {
      final a = MduiInkRipple.radiusFor(row);
      final b = MduiInkRipple.radiusFor(const Rect.fromLTWH(100, 200, 300, 50));
      expect(a, isNot(equals(b)));
      // 同一个矩形不管按在哪里，半径都是对角线一半。
      expect(MduiInkRipple.radiusFor(row), closeTo(a, 1e-9));
    });
  });

  group('mdui v1 收场透明度', () {
    test('fill：1 → 0.35（300ms）', () {
      expect(MduiInkRipple.fillOpacity(0), 1.0);
      expect(MduiInkRipple.fillOpacity(0.5), closeTo(1 - 0.65 * 0.5, 0.0001));
      expect(MduiInkRipple.fillOpacity(1), closeTo(0.35, 0.0001));
    });

    test('out：0.35 → 0（600ms）', () {
      expect(MduiInkRipple.outOpacity(0), closeTo(0.35, 0.0001));
      expect(MduiInkRipple.outOpacity(0.5), closeTo(0.175, 0.0001));
      expect(MduiInkRipple.outOpacity(1), 0.0);
    });
  });

  group('mintSplashColor（M3 按压态档位）', () {
    test('深浅色都是 10%', () {
      expect(
        mintSplashColor(Brightness.dark),
        Colors.white.withValues(alpha: 0.10),
      );
      expect(
        mintSplashColor(Brightness.light),
        Colors.black.withValues(alpha: 0.10),
      );
    });
  });

  group('MduiInkRipple 生命周期（widget 测试）', () {
    BuildContext? innerContext;
    var removed = false;

    Future<void> pumpHost(WidgetTester tester) async {
      removed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            color: Colors.white,
            child: Builder(
              builder: (context) {
                innerContext = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
    }

    MduiInkRipple spawnRipple({
      bool contained = false,
      RectCallback? rectCallback,
      void Function()? onRemoved,
    }) {
      final controller = Material.of(innerContext!);
      final box = innerContext!.findRenderObject()! as RenderBox;
      return MduiInkRipple(
        controller: controller,
        referenceBox: box,
        position: const Offset(8, 30),
        color: mintSplashColor(Brightness.dark),
        textDirection: TextDirection.ltr,
        containedInkWell: contained,
        rectCallback: rectCallback,
        onRemoved: onRemoved ?? () => removed = true,
      );
    }

    testWidgets('confirm：fill 300ms + out 600ms = 900ms 收场', (tester) async {
      await pumpHost(tester);
      final ripple = spawnRipple();
      await tester.pump();

      ripple.confirm();
      await tester.pump();
      // fill 300ms（结束时才启动 out），再走 out 600ms。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 500));
      expect(removed, isFalse);
      await tester.pump(const Duration(milliseconds: 700));
      expect(removed, isTrue);
    });

    testWidgets('cancel 也走 v1 的 fill → out（没有快速取消）', (tester) async {
      await pumpHost(tester);
      final ripple = spawnRipple();
      await tester.pump();

      ripple.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 500));
      expect(removed, isFalse);
      await tester.pump(const Duration(milliseconds: 700));
      expect(removed, isTrue);
    });

    testWidgets('重复 confirm 只走一次收场', (tester) async {
      await pumpHost(tester);
      final ripple = spawnRipple();
      await tester.pump();

      ripple.confirm();
      ripple.confirm();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 700));
      expect(removed, isTrue);
    });

    testWidgets('动画中途手动 dispose 不炸（标题栏按钮拆除路径）', (tester) async {
      await pumpHost(tester);
      final box = innerContext!.findRenderObject()! as RenderBox;
      final ripple = spawnRipple(
        contained: true,
        rectCallback: () => Offset.zero & box.size,
      );
      await tester.pump();
      ripple.confirm();
      await tester.pump(const Duration(milliseconds: 50));
      ripple.dispose();
      await tester.pump();
    });

    testWidgets('mintSplashFactory 在桌面平台是 mdui 工厂', (tester) async {
      await pumpHost(tester);
      if (mintUsesMduiRipple) {
        expect(mintSplashFactory, isA<MduiRippleSplashFactory>());
      } else {
        expect(mintSplashFactory, InkRipple.splashFactory);
      }
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/launcher/android_display.dart';

void main() {
  group('Android 画面比例 = 横向渲染分辨率（不拉伸）', () {
    test('100% = 屏幕原生：1.5K 屏是 2800×1260，不再被 720p 基准卡住', () {
      const settings = AndroidDisplaySettings(
        mode: AndroidAspectMode.fill,
        screenAspect: 2800 / 1260,
        screenWidth: 2800,
        screenHeight: 1260,
      );
      expect(settings.renderHeight, 1260);
      expect(settings.renderWidth, 2800);
      expect(settings.resolutionLabel, '2800 × 1260');
      expect(settings.nativeResolutionLabel, '2800 × 1260');
      expect(settings.scaleLabel, '原生');
    });

    test('适应屏幕固定 16:9 → 原生高度下 2240×1260', () {
      const settings = AndroidDisplaySettings(
        screenAspect: 2.222,
        screenWidth: 2800,
        screenHeight: 1260,
      );
      expect(settings.effectiveAspect, closeTo(16 / 9, 1e-6));
      expect(settings.renderWidth, 2240);
      expect(settings.renderHeight, 1260);
      expect(settings.resolutionLabel, '2240 × 1260');
    });

    test('渲染精度缩放屏幕原生高度：50% / 75%', () {
      const half = AndroidDisplaySettings(
        resolutionScale: 0.5,
        screenWidth: 2800,
        screenHeight: 1260,
      );
      expect(half.renderHeight, 630);
      expect(half.renderWidth, 1120);
      expect(half.resolutionLabel, '1120 × 630');
      expect(half.scaleLabel, '50%');

      const balanced = AndroidDisplaySettings(
        mode: AndroidAspectMode.fill,
        resolutionScale: 0.75,
        screenAspect: 2800 / 1260,
        screenWidth: 2800,
        screenHeight: 1260,
      );
      // 945 取偶数 → 946（个别 GL 驱动对奇数高度不友好）。
      expect(balanced.renderHeight, 946);
      expect(balanced.renderWidth, 2102);
      expect(balanced.resolutionLabel, '2102 × 946');

      // 拖动窗口时精度不能丢。
      final dragged = AndroidDisplaySettings.fromWindow(
        windowWidth: 0.7,
        windowHeight: 0.7,
        screenAspect: 2,
        screenWidth: 2800,
        screenHeight: 1260,
        resolutionScale: 0.75,
      );
      expect(dragged.resolutionScale, 0.75);
      expect(dragged.screenWidth, 2800);
      expect(dragged.screenHeight, 1260);
      expect(dragged.renderHeight, 946);
    });

    test('铺满屏幕按屏幕比例加宽 → 原生 2800×1260', () {
      const settings = AndroidDisplaySettings(
        mode: AndroidAspectMode.fill,
        screenAspect: 2800 / 1260,
        screenWidth: 2800,
        screenHeight: 1260,
      );
      expect(settings.renderWidth, 2800);
    });

    test('自定义比例：4:3 → 1440×1080；21:9 → 2520×1080', () {
      expect(
        const AndroidDisplaySettings(
          mode: AndroidAspectMode.custom,
          ratio: 4 / 3,
        ).renderWidth,
        1440,
      );
      expect(
        const AndroidDisplaySettings(
          mode: AndroidAspectMode.custom,
          ratio: 21 / 9,
        ).renderWidth,
        2520,
      );
    });

    test('宽度永远是偶数（GL 驱动兼容）', () {
      final settings = const AndroidDisplaySettings(
        mode: AndroidAspectMode.custom,
        ratio: 1.34,
      );
      expect(settings.renderWidth.isEven, isTrue);
    });

    test('精度夹在 25% ~ 100%（100% 就是原生，不做超采样）', () {
      expect(AndroidDisplaySettings.minScale, 0.25);
      expect(AndroidDisplaySettings.maxScale, 1.0);
    });

    test('旧版 "stretch" 迁移到「铺满屏幕」', () {
      expect(AndroidAspectMode.fromId('stretch'), AndroidAspectMode.fill);
      expect(AndroidAspectMode.fromId('fill'), AndroidAspectMode.fill);
      expect(AndroidAspectMode.fromId('nonsense'), AndroidAspectMode.fit);
    });

    group('游戏窗口大小（拖窗口）', () {
      test('默认全屏，标签是「全屏」', () {
        const settings = AndroidDisplaySettings();
        expect(settings.windowWidth, 1);
        expect(settings.windowHeight, 1);
        expect(settings.isFullscreen, isTrue);
        expect(settings.windowLabel, '全屏');
      });

      test('拉小到 70% → 标签与缓冲比例同步（画面不变形）', () {
        final settings = AndroidDisplaySettings.fromWindow(
          windowWidth: 0.7,
          windowHeight: 0.7,
          screenAspect: 2.0,
        );
        expect(settings.windowLabel, '70% × 70%');
        expect(settings.isFullscreen, isFalse);
        // 矩形宽高比 = 屏幕比 × (w/h) = 2.0 → 缓冲也按 2.0 渲染。
        expect(settings.effectiveAspect, closeTo(2.0, 1e-6));
        expect(settings.mode, AndroidAspectMode.custom);
      });

      test('只拉横向：矩形变窄 → 缓冲比例变窄（横向分辨率下降）', () {
        final settings = AndroidDisplaySettings.fromWindow(
          windowWidth: 0.8,
          windowHeight: 1.0,
          screenAspect: 2.0,
        );
        expect(settings.effectiveAspect, closeTo(1.6, 1e-6));
        // 比例下限 4:3，触底后多余的收窄退化成黑边，绝不拉伸。
        final extreme = AndroidDisplaySettings.fromWindow(
          windowWidth: 0.1,
          windowHeight: 1.0,
          screenAspect: 2.0,
        );
        expect(
          extreme.effectiveAspect,
          closeTo(AndroidDisplaySettings.minRatio, 1e-6),
        );
      });

      test('窗口比例被夹在 35% ~ 100%', () {
        expect(AndroidDisplaySettings.clampWindow(0.05), 0.35);
        expect(AndroidDisplaySettings.clampWindow(1.8), 1.0);
        final settings = AndroidDisplaySettings.fromWindow(
          windowWidth: 9,
          windowHeight: 0.01,
          screenAspect: 2.0,
        );
        expect(settings.windowWidth, 1.0);
        expect(settings.windowHeight, 0.35);
      });
    });
  });
}

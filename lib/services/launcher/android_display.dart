import 'dart:io';

import 'package:flutter/services.dart';

/// Android 游戏画面的渲染分辨率模式（与原生 GameDisplaySettings.Mode 对齐）。
///
/// 改的是**渲染分辨率**而不是把画面拉伸：100% = 屏幕原生像素（横屏短边），
/// 宽度按目标比例算（1260p 屏 + 16:9 → 2240×1260，75% → 1680×945）。
/// SurfaceView 再按同样的比例等比放到屏幕上，所以画面永远不变形。
enum AndroidAspectMode {
  fit('fit', '适应屏幕', '保持 16:9 等比缩放；屏幕更宽时左右留黑边，画面不变形'),
  fill('fill', '铺满屏幕', '按屏幕比例提高横向渲染宽度，铺满屏幕但不拉伸画面'),
  custom('custom', '自定义比例', '按横向比例设定渲染宽度，等比缩放不变形');

  const AndroidAspectMode(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static AndroidAspectMode fromId(String? id) {
    // 旧版本存过 "stretch"（真拉伸）；迁移到「按屏幕比例改横向分辨率」。
    if (id == 'stretch') return fill;
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return fit;
  }
}

/// 启动器 → 原生的画面设置。
///
/// 存在原生 filesDir/game_display.json：游戏在 `:game` 独立进程里，这个
/// 文件是两边（启动器设置页 / 游戏内菜单）唯一的同步点。
///
/// 两组设置：
///  - [windowWidth] / [windowHeight] = 画面在屏幕上占的矩形（屏幕宽/高百分比），
///    改完**即时生效**（只是重排 SurfaceView），拉小后周围是黑边；
///  - [mode] / [ratio] / [resolutionScale] = 渲染分辨率（GL 缓冲实际像素）：
///    100% = 屏幕原生高度 [screenHeight] × 精度倍率，宽度按目标比例算。
///    运行中改会走 FCL 的 framebuffer-size 事件实时下发，下次启动由
///    `--width/--height` 与 options.txt 保持一致。
class AndroidDisplaySettings {
  const AndroidDisplaySettings({
    this.mode = AndroidAspectMode.fit,
    this.ratio = 16 / 9,
    this.screenAspect = 16 / 9,
    this.screenWidth = 1920,
    this.screenHeight = 1080,
    this.windowWidth = 1,
    this.windowHeight = 1,
    this.resolutionScale = 1,
  });

  final AndroidAspectMode mode;

  /// 宽 / 高。仅 [mode] 为 custom 时使用。
  final double ratio;

  /// 当前设备横屏下的屏幕宽高比（原生探测）。
  final double screenAspect;

  /// 屏幕原生像素（横屏）。100% 精度就是按这个高度渲染。
  final int screenWidth;
  final int screenHeight;

  /// 画面占屏幕宽 / 高的百分比（即时生效，1.0 = 顶到屏幕边缘）。
  final double windowWidth;
  final double windowHeight;

  /// 渲染精度：相对屏幕原生高度的倍率（1.0 = 原生，0.75 = 75%）。
  final double resolutionScale;

  static const double minRatio = 4 / 3;
  static const double maxRatio = 21 / 9;

  /// 窗口最小只能拉到屏幕的 35%，否则画面小到没法玩。
  static const double minWindow = 0.35;
  static const double maxWindow = 1.0;

  static const double minScale = 0.25;
  static const double maxScale = 1.0;

  static const scalePresets = <({String label, double value})>[
    (label: '25%', value: 0.25),
    (label: '50%', value: 0.5),
    (label: '75%', value: 0.75),
    (label: '原生', value: 1.0),
  ];

  static const presets = <({String label, double ratio})>[
    (label: '4:3', ratio: 4 / 3),
    (label: '16:9', ratio: 16 / 9),
    (label: '18:9', ratio: 18 / 9),
    (label: '19.5:9', ratio: 19.5 / 9),
    (label: '21:9', ratio: 21 / 9),
  ];

  static const windowPresets = <({String label, double value})>[
    (label: '100%', value: 1.0),
    (label: '85%', value: 0.85),
    (label: '70%', value: 0.7),
    (label: '55%', value: 0.55),
    (label: '40%', value: 0.4),
  ];

  static double clampWindow(double value) => value.clamp(minWindow, maxWindow);

  static String ratioLabel(double ratio) {
    for (final p in presets) {
      if ((ratio - p.ratio).abs() < 0.015) return p.label;
    }
    return '${ratio.toStringAsFixed(2)}:1';
  }

  double get effectiveAspect => switch (mode) {
    AndroidAspectMode.fit => 16 / 9,
    AndroidAspectMode.fill =>
      screenAspect.isFinite && screenAspect > 0 ? screenAspect : 16 / 9,
    AndroidAspectMode.custom => ratio,
  };

  /// 实际渲染高度（屏幕原生高度 × 精度倍率，取偶数）。
  int get renderHeight {
    final base = screenHeight > 0 ? screenHeight : 1080;
    final height = (base * resolutionScale).round();
    return (height.isEven ? height : height + 1).clamp(240, 4320);
  }

  /// 实际渲染宽度（偶数，避免个别 GL 驱动对奇数宽度的兼容问题）。
  int get renderWidth {
    final width = (renderHeight * effectiveAspect).round();
    return width.isEven ? width : width + 1;
  }

  String get resolutionLabel => '$renderWidth × $renderHeight';

  /// 屏幕原生分辨率（100% 精度）。
  String get nativeResolutionLabel => '$screenWidth × $screenHeight';

  String get scaleLabel => resolutionScale >= 0.995
      ? '原生'
      : '${(resolutionScale * 100).round()}%';

  bool get isFullscreen => windowWidth >= 0.995 && windowHeight >= 0.995;

  String get windowLabel => isFullscreen
      ? '全屏'
      : '${(windowWidth * 100).round()}% × ${(windowHeight * 100).round()}%';

  String get summary => switch (mode) {
    AndroidAspectMode.fit => '16:9 · $resolutionLabel',
    AndroidAspectMode.fill => '铺满屏幕 · $resolutionLabel',
    AndroidAspectMode.custom => '${ratioLabel(ratio)} · $resolutionLabel',
  };

  /// 按「画面占屏幕的百分比」换算：矩形宽高比就是缓冲宽高比，
  /// 所以画面永远等比缩放、不会变形（和游戏内拖角标同一套规则）。
  factory AndroidDisplaySettings.fromWindow({
    required double windowWidth,
    required double windowHeight,
    required double screenAspect,
    int screenWidth = 1920,
    int screenHeight = 1080,
    double resolutionScale = 1,
  }) {
    final w = clampWindow(windowWidth);
    final h = clampWindow(windowHeight);
    final aspect = (screenAspect * w / h).clamp(minRatio, maxRatio);
    return AndroidDisplaySettings(
      mode: AndroidAspectMode.custom,
      ratio: aspect.toDouble(),
      screenAspect: screenAspect,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      windowWidth: w,
      windowHeight: h,
      resolutionScale: resolutionScale.clamp(minScale, maxScale),
    );
  }

  AndroidDisplaySettings copyWith({
    AndroidAspectMode? mode,
    double? ratio,
    double? screenAspect,
    int? screenWidth,
    int? screenHeight,
    double? windowWidth,
    double? windowHeight,
    double? resolutionScale,
  }) => AndroidDisplaySettings(
    mode: mode ?? this.mode,
    ratio: (ratio ?? this.ratio).clamp(minRatio, maxRatio),
    screenAspect: screenAspect ?? this.screenAspect,
    screenWidth: screenWidth ?? this.screenWidth,
    screenHeight: screenHeight ?? this.screenHeight,
    windowWidth: clampWindow(windowWidth ?? this.windowWidth),
    windowHeight: clampWindow(windowHeight ?? this.windowHeight),
    resolutionScale: (resolutionScale ?? this.resolutionScale).clamp(
      minScale,
      maxScale,
    ),
  );
}

class AndroidDisplay {
  AndroidDisplay._();

  static const MethodChannel _channel = MethodChannel('mint/fcl');

  static AndroidDisplaySettings? _cache;

  static Future<AndroidDisplaySettings> load({bool force = false}) async {
    if (!force && _cache != null) return _cache!;
    if (!Platform.isAndroid) return const AndroidDisplaySettings();
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'display.get',
      );
      final screenWidth = (map?['screenWidth'] as num?)?.toInt() ?? 1920;
      final screenHeight = (map?['screenHeight'] as num?)?.toInt() ?? 1080;
      final settings = AndroidDisplaySettings(
        mode: AndroidAspectMode.fromId(map?['mode'] as String?),
        ratio: (map?['ratio'] as num?)?.toDouble() ?? 16 / 9,
        screenAspect:
            (map?['screenAspect'] as num?)?.toDouble() ??
            (screenHeight > 0 ? screenWidth / screenHeight : 16 / 9),
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        windowWidth: (map?['windowWidth'] as num?)?.toDouble() ?? 1,
        windowHeight: (map?['windowHeight'] as num?)?.toDouble() ?? 1,
        resolutionScale: ((map?['resolutionScale'] as num?)?.toDouble() ?? 1)
            .clamp(
              AndroidDisplaySettings.minScale,
              AndroidDisplaySettings.maxScale,
            ),
      );
      _cache = settings;
      return settings;
    } catch (_) {
      return const AndroidDisplaySettings();
    }
  }

  static Future<void> save(AndroidDisplaySettings settings) async {
    _cache = settings;
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('display.set', {
        'mode': settings.mode.id,
        'ratio': settings.ratio.clamp(
          AndroidDisplaySettings.minRatio,
          AndroidDisplaySettings.maxRatio,
        ),
        'windowWidth': AndroidDisplaySettings.clampWindow(settings.windowWidth),
        'windowHeight': AndroidDisplaySettings.clampWindow(
          settings.windowHeight,
        ),
        'resolutionScale': settings.resolutionScale.clamp(
          AndroidDisplaySettings.minScale,
          AndroidDisplaySettings.maxScale,
        ),
      });
    } catch (_) {}
  }
}

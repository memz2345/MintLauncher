import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// mdui v1（mdui.org，Material Design CSS 框架）涟漪的 Flutter 移植。
///
/// 对照 `mdui@1.0.2` 源码逐项还原（`src/ripple.js` + `dist/css/mdui.css`）：
///
///  · **直径**：`max(元素对角线, 48px)` —— JS 里 `Math.max(hypot(w, h), 48)`
///    就是这条公式；涟漪一定盖满整个元素，不存在「只盖一半」。
///  · **圆心**：wave 初始锚在按下点，1400ms 内一边放大一边**平移到元素
///    中心**（`translate3d(-x + w/2, -y + h/2, 0) scale(1)`）。所以松手后
///    看到的最终涟漪是「居中 + 对角线直径」的整圆。
///  · **按下**：`scale(0) → scale(1)`，transition 1400ms，CSS 默认 ease。
///  · **松手**：先加 `.mdui-ripple-wave-fill`（opacity 0.35，300ms，同时
///    把 transform 收到最终位置），等 fill 结束再加 `.mdui-ripple-wave-out`
///    （opacity 0，600ms）后移除。没有「快速 cancel」分支 —— v1 的鼠标 /
///    触摸结束都走 fill → out。
///  · **颜色**：默认 `rgba(0,0,0,.1)`；有背景色的容器用白色 30%。Mint 的
///    深色卡片用 [mintSplashColor] 的 10% 白，避免 mdui 的 30% 白盖住文字
///    （颜色档位见文件末尾；半径 / 圆心 / 节奏完全按 v1）。
///
/// 与 Flutter 原生 [InkRipple] 的差别是有意的：水流更长、最后会淡到 0.35
/// 再消失，这正是 mdui v1 的「长尾」观感。
class MduiInkRipple extends InteractiveInkFeature {
  MduiInkRipple({
    required MaterialInkController controller,
    required super.referenceBox,
    required Offset position,
    required super.color,
    TextDirection? textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    super.customBorder,
    BorderRadius? borderRadius,
    super.onRemoved,
    double? radius,
  }) : _position = position,
       _borderRadius = borderRadius ?? BorderRadius.zero,
       _textDirection = textDirection ?? TextDirection.ltr,
       _clipCallback = _mduiClipCallback(
         referenceBox,
         containedInkWell,
         rectCallback,
       ),
       super(controller: controller) {
    _bounds = rectCallback?.call() ?? (Offset.zero & referenceBox.size);
    // 外部显式给了半径（InkResponse.radius）就尊重它；否则按 mdui v1 的
    // 「对角线直径 / 2」。
    _targetRadius = radius ?? radiusFor(_bounds);

    _expandController = AnimationController(
      duration: kMduiRipplePressDuration,
      vsync: controller.vsync,
    )..addListener(controller.markNeedsPaint);
    _expand = _expandController.drive(
      Tween<double>(begin: 0, end: 1).chain(CurveTween(curve: _ease)),
    );
    _expandController.forward();

    _fillController =
        AnimationController(
            duration: kMduiRippleFillDuration,
            vsync: controller.vsync,
          )
          ..addListener(controller.markNeedsPaint)
          ..addStatusListener((status) {
            if (status.isCompleted) _outController.forward();
          });

    _outController =
        AnimationController(
            duration: kMduiRippleOutDuration,
            vsync: controller.vsync,
          )
          ..addListener(controller.markNeedsPaint)
          ..addStatusListener((status) {
            if (status.isCompleted) dispose();
          });

    controller.addInkFeature(this);
  }

  static RectCallback? _mduiClipCallback(
    RenderBox referenceBox,
    bool containedInkWell,
    RectCallback? rectCallback,
  ) {
    if (rectCallback != null) return rectCallback;
    if (containedInkWell) return () => Offset.zero & referenceBox.size;
    return null;
  }

  // ─────────────── mdui v1 的时长常量（源码逐项对应） ───────────────

  /// 按下扩散 / 圆心滑动时长：CSS `transition-duration: 1400ms`。
  static const Duration kMduiRipplePressDuration = Duration(milliseconds: 1400);

  /// `.mdui-ripple-wave-fill`：300ms，opacity → 0.35。
  static const Duration kMduiRippleFillDuration = Duration(milliseconds: 300);

  /// `.mdui-ripple-wave-out`：600ms，opacity → 0。
  static const Duration kMduiRippleOutDuration = Duration(milliseconds: 600);

  /// mdui 的直径下限 48px（半径 24）。
  static const double kMduiRippleMinDiameter = 48.0;

  /// fill 阶段的目标透明度：CSS `.mdui-ripple-wave-fill { opacity: .35 }`。
  static const double kMduiRippleFillOpacity = 0.35;

  static const Curve _ease = Curves.ease;

  final Offset _position;
  final BorderRadius _borderRadius;
  final TextDirection _textDirection;
  final RectCallback? _clipCallback;

  late final Rect _bounds;
  late final double _targetRadius;

  late final AnimationController _expandController;
  late final Animation<double> _expand;
  late final AnimationController _fillController;
  late final AnimationController _outController;

  bool _released = false;

  /// mdui v1 的直径：`max(hypot(width, height), 48)`。
  static double diameterFor(Rect bounds) => math.max(
    math.sqrt(bounds.width * bounds.width + bounds.height * bounds.height),
    kMduiRippleMinDiameter,
  );

  /// 半径 = 直径 / 2。按下点在哪儿都一样 —— 圆心最后会滑到元素中心。
  static double radiusFor(Rect bounds) => diameterFor(bounds) / 2;

  /// fill 阶段透明度（入参 0..1）：1 → 0.35。
  static double fillOpacity(double t) =>
      lerpDouble(1.0, kMduiRippleFillOpacity, t.clamp(0.0, 1.0))!;

  /// out 阶段透明度（入参 0..1）：0.35 → 0。
  static double outOpacity(double t) =>
      lerpDouble(kMduiRippleFillOpacity, 0.0, t.clamp(0.0, 1.0))!;

  /// 当前透明度倍数：按下 1，fill 渐到 .35，out 渐到 0。
  double get _opacity {
    if (!_released) return 1.0;
    if (_outController.value > 0) return outOpacity(_outController.value);
    return fillOpacity(_fillController.value);
  }

  void _release() {
    if (_released) return;
    _released = true;
    // v1 在松手时把过渡时长缩短到 300ms，让还没走完的扩散快速落位。
    _expandController
      ..duration = kMduiRippleFillDuration
      ..forward();
    _fillController.forward();
  }

  @override
  void confirm() => _release();

  @override
  void cancel() => _release();

  @override
  void dispose() {
    _expandController.stop();
    _fillController.stop();
    _outController.stop();
    _expandController.dispose();
    _fillController.dispose();
    _outController.dispose();
    super.dispose();
  }

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    final t = _expand.value;
    // 圆心从按下点滑到元素中心（v1 的 translate3d 就是做这件事）。
    final center = Offset.lerp(_position, _bounds.center, t)!;
    final radius = _targetRadius * t;
    final paint = Paint()..color = color.withValues(alpha: color.a * _opacity);
    paintInkCircle(
      canvas: canvas,
      transform: transform,
      paint: paint,
      center: center,
      textDirection: _textDirection,
      radius: radius,
      customBorder: customBorder,
      borderRadius: _borderRadius,
      clipCallback: _clipCallback,
    );
  }
}

/// 挂到 `ThemeData.splashFactory`：InkWell / Material 的点击涟漪全部换成
/// mdui v1 观感。
class MduiRippleSplashFactory extends InteractiveInkFeatureFactory {
  const MduiRippleSplashFactory();

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) {
    return MduiInkRipple(
      controller: controller,
      referenceBox: referenceBox,
      position: position,
      color: color,
      textDirection: textDirection,
      containedInkWell: containedInkWell,
      rectCallback: rectCallback,
      borderRadius: borderRadius,
      customBorder: customBorder,
      radius: radius,
      onRemoved: onRemoved,
    );
  }
}

/// 是否用 mdui 的自定义涟漪。
///
/// 只有**桌面三平台**（Windows / macOS / Linux）用：桌面鼠标交互本来就没有
/// 系统的水波纹语义，mdui v1 那种「1400ms 慢慢晕开 + 900ms 收场」的长尾是
/// 这套 UI 的定调。移动端（Android / iOS）保持 Flutter 原生 [InkRipple]。
bool get mintUsesMduiRipple =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 当前平台用的 splash factory：桌面 → mdui 涟漪，其它 → 原生 InkRipple。
InteractiveInkFeatureFactory get mintSplashFactory => mintUsesMduiRipple
    ? const MduiRippleSplashFactory()
    : InkRipple.splashFactory;

/// 涟漪颜色，统一取 M3 的按压态 state layer 档位（onSurface 10% 系）：
/// 浅色 = 黑 10%（即 mdui v1 浅色的原值 rgba(0,0,0,.1)），深色 = 白 10%
/// （M3 深色按压态同为 10%；mdui v1 深色的 rgba(255,255,255,.3) 太浓，
/// 会盖住行内的文字和图标）。半径 / 圆心 / 时长都按 mdui v1，只有颜色
/// 按 Mint 的可读性要求调淡。
Color mintSplashColor(Brightness brightness) => brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.10)
    : Colors.black.withValues(alpha: 0.10);

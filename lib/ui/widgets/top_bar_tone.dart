import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:mint/ui/widgets/page_background.dart';

/// 顶栏元素颜色：黑或白，由顶栏背后的实际背景决定。
///
/// 有背景图时采样图片**顶部区域**的平均亮度（顶栏 + 大标题都落在这一段），
/// 再按页面背景图的不透明度与画布底色混合；没有背景图就按明暗直接用纯黑 /
/// 纯白。结果通过 [MintTopBarToneScope] 下发，back / 标题 / 动作图标全部
/// 用同一个颜色 —— 不再出现「蓝色返回箭头 + 黑色标题」混搭。
class MintTopBarTone extends StatefulWidget {
  const MintTopBarTone({
    super.key,
    required this.baseColor,
    required this.builder,
    this.backgroundImage,
    this.sampleStart = 0,
    this.sampleEnd = 0.22,
    this.sampleLeft = 0,
    this.sampleRight = 1,
    this.threshold = 0.5,
  });

  /// 背景图画布底色（与 `PageBackground.baseColor` 一致）。
  final Color baseColor;

  /// 页面用独立背景图时（关于页用主题的设置窗口背景），显式传进来；
  /// null = 跟随全局 PageBackground。
  final ({String path, double opacity, double blur})? backgroundImage;

  /// 采样背景图的区间（归一化 0..1）。默认取顶部 22%（顶栏）；
  /// 关于页大标题在图片中部，单独取标题所在的那一条。
  final double sampleStart;
  final double sampleEnd;
  final double sampleLeft;
  final double sampleRight;

  /// 亮度高于该值用黑字，否则白字。关于页大标题压在浅色卡片上时用低一点。
  final double threshold;

  final Widget Function(BuildContext context, Color foreground) builder;

  @override
  State<MintTopBarTone> createState() => _MintTopBarToneState();
}

class _MintTopBarToneState extends State<MintTopBarTone> {
  Color _tone = Colors.black;
  String? _key;
  int _token = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(MintTopBarTone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.baseColor != widget.baseColor) _resolve(force: true);
  }

  void _resolve({bool force = false}) {
    final brightness = Theme.of(context).brightness;
    final fallback = brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final image =
        widget.backgroundImage ?? mintActivePageBackgroundImage(context);
    final key = image == null
        ? 'none|${brightness.name}|${widget.baseColor.toARGB32()}'
        : MintTopBarToneResolver.keyFor(
            path: image.path,
            opacity: image.opacity,
            base: widget.baseColor,
            sampleStart: widget.sampleStart,
            sampleEnd: widget.sampleEnd,
            sampleLeft: widget.sampleLeft,
            sampleRight: widget.sampleRight,
            threshold: widget.threshold,
          );
    if (!force && key == _key) return;
    _key = key;
    // 任何一次解析开始都让旧图的结果作废（切壁纸 / 关背景图时很常见）。
    final token = ++_token;

    if (image == null) {
      _tone = fallback;
      return;
    }
    final cached = MintTopBarToneResolver.cached(key);
    if (cached != null) {
      _tone = cached;
      return;
    }
    _tone = fallback;
    MintTopBarToneResolver.resolve(
      path: image.path,
      opacity: image.opacity,
      base: widget.baseColor,
      fallback: fallback,
      sampleStart: widget.sampleStart,
      sampleEnd: widget.sampleEnd,
      sampleLeft: widget.sampleLeft,
      sampleRight: widget.sampleRight,
      threshold: widget.threshold,
    ).then((color) {
      if (!mounted || token != _token) return;
      setState(() => _tone = color);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MintTopBarToneScope(
      color: _tone,
      child: IconTheme.merge(
        data: IconThemeData(color: _tone),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: _tone),
          child: widget.builder(context, _tone),
        ),
      ),
    );
  }
}

/// 顶栏前景色作用域：叶子组件（返回箭头等）直接读它。
class MintTopBarToneScope extends InheritedWidget {
  const MintTopBarToneScope({
    super.key,
    required this.color,
    required super.child,
  });

  final Color color;

  static Color? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<MintTopBarToneScope>()
        ?.color;
  }

  static Color of(BuildContext context, Color fallback) =>
      maybeOf(context) ?? fallback;

  @override
  bool updateShouldNotify(MintTopBarToneScope oldWidget) =>
      color != oldWidget.color;
}

/// 渐变模糊带 / 实色栏的压字底色：跟随前景色取反。
///
/// 黑字配浅色栏、白字配深色栏，保证栏体与文字的对比度不随壁纸翻转。
Color mintTopBarScrimFor(Color foreground) =>
    foreground.computeLuminance() > 0.5 ? Colors.black : Colors.white;

/// 背景图顶部亮度采样（按路径缓存；图片顶部 22% 视为顶栏区域）。
class MintTopBarToneResolver {
  MintTopBarToneResolver._();

  static final Map<String, Color> _cache = {};

  static String keyFor({
    required String path,
    required double opacity,
    required Color base,
    double sampleStart = 0,
    double sampleEnd = 0.22,
    double sampleLeft = 0,
    double sampleRight = 1,
    double threshold = 0.5,
  }) =>
      '$path|${opacity.toStringAsFixed(3)}|${base.toARGB32()}|'
      '${sampleStart.toStringAsFixed(3)}|${sampleEnd.toStringAsFixed(3)}|'
      '${sampleLeft.toStringAsFixed(3)}|${sampleRight.toStringAsFixed(3)}|'
      '${threshold.toStringAsFixed(3)}';

  static Color? cached(String key) => _cache[key];

  static Future<Color> resolve({
    required String path,
    required double opacity,
    required Color base,
    required Color fallback,
    double sampleStart = 0,
    double sampleEnd = 0.22,
    double sampleLeft = 0,
    double sampleRight = 1,
    double threshold = 0.5,
  }) async {
    final key = keyFor(
      path: path,
      opacity: opacity,
      base: base,
      sampleStart: sampleStart,
      sampleEnd: sampleEnd,
      sampleLeft: sampleLeft,
      sampleRight: sampleRight,
      threshold: threshold,
    );
    final cached = _cache[key];
    if (cached != null) return cached;
    final color = await _sample(
      path: path,
      opacity: opacity,
      base: base,
      fallback: fallback,
      sampleStart: sampleStart,
      sampleEnd: sampleEnd,
      sampleLeft: sampleLeft,
      sampleRight: sampleRight,
      threshold: threshold,
    );
    _cache[key] = color;
    return color;
  }

  static Future<Color> _sample({
    required String path,
    required double opacity,
    required Color base,
    required Color fallback,
    required double sampleStart,
    required double sampleEnd,
    required double sampleLeft,
    required double sampleRight,
    required double threshold,
  }) async {
    ui.Image? image;
    ui.Codec? codec;
    try {
      final bytes = await File(path).readAsBytes();
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return fallback;
      final width = image.width;
      final height = image.height;
      final startY = (height * sampleStart.clamp(0.0, 0.9)).floor().clamp(
        0,
        height - 1,
      );
      final endY = (height * sampleEnd.clamp(0.0, 1.0)).ceil().clamp(
        startY + 1,
        height,
      );
      final startX = (width * sampleLeft.clamp(0.0, 0.9)).floor().clamp(
        0,
        width - 1,
      );
      final endX = (width * sampleRight.clamp(0.0, 1.0)).ceil().clamp(
        startX + 1,
        width,
      );
      var r = 0;
      var g = 0;
      var b = 0;
      var weight = 0;
      for (var y = startY; y < endY; y++) {
        for (var x = startX; x < endX; x++) {
          final i = (y * width + x) * 4;
          final a = data.getUint8(i + 3);
          if (a < 24) continue;
          r += data.getUint8(i) * a;
          g += data.getUint8(i + 1) * a;
          b += data.getUint8(i + 2) * a;
          weight += a;
        }
      }
      if (weight == 0) return fallback;
      final average = Color.fromARGB(
        255,
        r ~/ weight,
        g ~/ weight,
        b ~/ weight,
      );
      final effective = Color.alphaBlend(
        average.withValues(alpha: opacity.clamp(0.0, 1.0)),
        base,
      );
      return effective.computeLuminance() > threshold
          ? Colors.black
          : Colors.white;
    } catch (_) {
      return fallback;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}

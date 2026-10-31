import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

/// 云雾前景层 —— Kimi（月之暗面）K3.1 Pro 博客页头同风格的「液态云雾」。
///
/// 视觉参考 <https://www.kimi.ai/blog/kimi-k3-1-pro>：白色柔雾团里带大理石
/// 漩涡等高线，缓慢漂移/形变。Kimi 的 PNG 素材有版权不能入库，这里用
/// `shaders/cloud_foreground.frag` 程序化生成同观感：fbm + 两层域扭曲出
/// 大理石纹，双层（远/近）blob 密度场聚成「飘过的云团」并给速度差视差。
///
/// ## 性能（三重省电）
///
/// 1. **半分辨率光栅**：着色器先光栅到 1/2 边长的离屏 [ui.Image]
///    （[ui.Picture.toImageSync]，GPU 侧完成，不占 UI 线程），再线性放大
///    上屏。云雾是极低频图像，半分辨率肉眼无损，片元开销降到 ~1/4。
///    `toImageSync` 不可用时（个别软件渲染 / 测试环境）自动退回全分辨率
///    直绘（`_directPaint`）。
/// 2. **30fps 节流**：云的演化以「分钟」计，30fps 与 60fps 肉眼无差，
///    Ticker 按帧间隔量化，中间帧直接跳过。
/// 3. **不上屏就不算**：[CustomPainter.paint] 上报「本帧真的画了」；页签
///    切走（PageView 保活但不再重绘）时 Ticker 只做一次布尔判断就返回，
///    不推进时间、不重新光栅。[TickerMode] 关闭时 Ticker 干脆不响
///    （SingleTickerProviderStateMixin 的自带语义）。
///
/// ## 交互与可读性
///
/// 纯前景装饰：外层务必套 [IgnorePointer]（本组件不自带，把选择权留给
/// 用法）。不透明度由 [cloudEffectiveOpacity] 按深浅主题分别打折+封顶，
/// 防止「白雾盖内容」（mdui_ripple 的前车之鉴）。
///
/// ```dart
/// Stack(children: [
///   ...页面内容,
///   Positioned.fill(
///     child: IgnorePointer(child: MintCloudForeground(opacity: 0.55)),
///   ),
/// ])
/// ```
class MintCloudForeground extends StatefulWidget {
  const MintCloudForeground({
    super.key,
    this.opacity = 0.55,
    this.density = 0.5,
    this.speed = 1.0,
    this.topBias = 0.7,
    this.seed = 7,
    this.animated = true,
  });

  /// 用户设定的不透明度（0~1）。实际 shader 主 alpha 会经
  /// [cloudEffectiveOpacity] 按深浅主题打折 + 封顶。
  final double opacity;

  /// 云团密度（0~1）→ 近层 blob 数量见 [cloudBlobCount]。
  final double density;

  /// 漂移/演化速度倍率（喂给 shader 的 uDrift）。
  final double speed;

  /// 上半屏偏置 0~1：1 = 云雾集中在顶部（主页用），0 = 上下均匀。
  final double topBias;

  /// 种子：换一个数 = 换一批云团布局。
  final double seed;

  /// false = 静态（光栅一帧后不再推进时间），测试 / 省电场景用。
  final bool animated;

  // ── 着色器程序：进程内只编译一次 ─────────────────────────────────────
  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram>? _loading;

  /// 预编译着色器（建议在 `main()` 里调一次）。可以重复调用；失败时组件
  /// 安静地什么都不画 —— 纯装饰，缺了不伤功能。
  static Future<void> preload() async {
    if (_program != null) return;
    const path = 'shaders/cloud_foreground.frag';
    try {
      _program = await (_loading ??= ui.FragmentProgram.fromAsset(path));
    } catch (e) {
      _loading = null;
      debugPrint('cloud_foreground.frag 加载失败，云雾前景不渲染：$e');
    }
  }

  /// 着色器是否可用（已编译好）。测试 / 判定用。
  static bool get ready => _program != null;

  /// 测试环境（flutter test 的 binding）默认把云雾冻结成静态：无限推进的
  /// 动画会让测试里的 `pumpAndSettle` 永远等不到安静。要专门测动画行为，
  /// 在测试里把这个开关设回 true。
  ///
  /// 用 binding 类型名判断而不是 `FLUTTER_TEST` 环境变量：后者在部分
  /// flutter 版本/平台上并不出现在测试进程的 env 里（踩过）。
  static bool animateInTests = false;

  static bool get _inTestBinding => WidgetsBinding.instance.runtimeType
      .toString()
      .contains('TestWidgetsFlutterBinding');

  @override
  State<MintCloudForeground> createState() => _MintCloudForegroundState();
}

class _MintCloudForegroundState extends State<MintCloudForeground>
    with SingleTickerProviderStateMixin {
  /// 目标帧间隔：30fps。云雾演化以分钟计，60fps 是白烧 GPU。
  static const double _kFrameInterval = 1 / 30;

  Ticker? _ticker;

  /// 半分辨率光栅失败后的退化标记：painter 直接全分辨率跑 shader。
  bool _directPaint = false;

  /// Dart 侧累加的演化时间（秒）。只在「真的上屏」时推进 —— 页签切走
  /// （PageView 保活但不重绘）时时间冻结，回来也不跳变（delta 封顶）。
  double _simTime = 0;
  double _lastNow = 0;
  double _lastAdvance = 0;
  bool _paintedSinceTick = false;

  /// 深浅主题缓存在 didChangeDependencies（dependOnInheritedWidget 只能在
  /// build / didChangeDependencies 里调，Ticker 回调里不行）。
  bool _dark = false;

  Size? _layoutSize;
  ui.Image? _image;
  Size? _imageSize;

  /// 静态补帧 / 换尺寸重光栅的 postFrame 在途标记（防重复排）。
  bool _renderScheduled = false;

  @override
  void initState() {
    super.initState();
    MintCloudForeground.preload().then((_) {
      if (!mounted) return;
      setState(_syncTicker);
      _scheduleRender();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = _isDarkOf(context);
    if (dark != _dark) {
      _dark = dark;
      // 深浅互换 → 不透明度/灰度都变了，重光栅一帧。
      _scheduleRender();
    }
  }

  /// 主题亮度（跟随 ThemeMode，MINT_THEME_MODE 截图钩子也走这里）。
  /// 没有 Material 祖先时退回平台亮度 —— 本组件是纯装饰，不该炸页面。
  static bool _isDarkOf(BuildContext context) {
    Brightness? brightness;
    try {
      brightness = Theme.of(context).brightness;
    } catch (_) {
      brightness = null;
    }
    return (brightness ?? MediaQuery.platformBrightnessOf(context)) ==
        Brightness.dark;
  }

  @override
  void didUpdateWidget(covariant MintCloudForeground old) {
    super.didUpdateWidget(old);
    // 外观参数变了：重光栅（静态模式下这是唯一更新途径）。
    if (old.opacity != widget.opacity ||
        old.density != widget.density ||
        old.speed != widget.speed ||
        old.topBias != widget.topBias ||
        old.seed != widget.seed ||
        old.animated != widget.animated) {
      _syncTicker();
      _scheduleRender();
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  /// 实际是否推进动画：widget 开关 × 测试环境冻结（见 [animateInTests]）。
  bool get _effectiveAnimated =>
      widget.animated &&
      (MintCloudForeground.animateInTests ||
          !MintCloudForeground._inTestBinding);

  void _syncTicker() {
    if (!_effectiveAnimated || !MintCloudForeground.ready) {
      _ticker?.stop();
      return;
    }
    final t = _ticker;
    if (t == null) {
      _ticker = createTicker(_onTick)..start();
    } else if (!t.isActive) {
      t.start();
    }
  }

  void _onTick(Duration elapsed) {
    final size = _layoutSize;
    if (size == null || size.isEmpty) return;
    final now = elapsed.inMicroseconds / 1e6;
    // 上一帧没上屏（页签切走 / 层被裁掉）：什么都不算，省下整次光栅。
    final wasPainted = _paintedSinceTick;
    _paintedSinceTick = false;
    if (_image != null && !wasPainted) return;
    if (now - _lastAdvance < _kFrameInterval) return;
    _lastAdvance = now;
    // delta 封顶：长时间不可见后回来，云不「瞬移」。
    _simTime += (now - _lastNow).clamp(0.0, 0.12);
    _lastNow = now;
    if (!_directPaint) {
      _render(size);
    } else {
      // 直绘退化路径：painter 拿新时间全分辨率画。
      setState(() {});
    }
  }

  /// 布局 / 参数 / 亮度变化后的统一入口：postFrame 里重光栅一帧。
  void _scheduleRender() {
    if (_renderScheduled || !MintCloudForeground.ready) return;
    final size = _layoutSize;
    if (size == null || size.isEmpty) return;
    _renderScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renderScheduled = false;
      if (!mounted) return;
      if (!_directPaint) _render(size);
      setState(() {});
    });
  }

  void _render(Size fullSize) {
    final program = MintCloudForeground._program;
    if (program == null) return;
    final half = cloudRenderSize(fullSize);
    if (half.isEmpty) return;

    final shader = program.fragmentShader();
    configureCloudShader(
      shader,
      renderSize: half,
      time: _simTime,
      blobs: cloudBlobCount(widget.density),
      seed: widget.seed,
      opacity: cloudEffectiveOpacity(widget.opacity, dark: _dark),
      shade: cloudShadeFor(_dark),
      topBias: widget.topBias,
      drift: widget.speed,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, Offset.zero & half);
    canvas.drawRect(Offset.zero & half, Paint()..shader = shader);
    final picture = recorder.endRecording();
    try {
      final img = picture.toImageSync(half.width.round(), half.height.round());
      final old = _image;
      _image = img;
      _imageSize = half;
      old?.dispose();
    } catch (e) {
      // 半分辨率光栅不可用（个别软件渲染 / 测试环境）：退回全分辨率直绘。
      _directPaint = true;
      _image?.dispose();
      _image = null;
      debugPrint('cloud_foreground toImageSync 失败，退回直绘：$e');
    } finally {
      picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final opacity = cloudEffectiveOpacity(widget.opacity, dark: _dark);
    if (opacity <= 0 || !MintCloudForeground.ready) {
      _ticker?.stop();
      return const SizedBox.expand();
    }
    _syncTicker();
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _layoutSize) {
          _layoutSize = size;
          _scheduleRender();
        }
        return RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _CloudPainter(
              image: _image,
              imageSize: _imageSize,
              direct: _directPaint,
              blobs: cloudBlobCount(widget.density),
              seed: widget.seed,
              opacity: opacity,
              shade: cloudShadeFor(_dark),
              topBias: widget.topBias,
              drift: widget.speed,
              time: _simTime,
              onPainted: () => _paintedSinceTick = true,
            ),
          ),
        );
      },
    );
  }
}

/// 云雾的画笔：优先画半分辨率离屏图（放大铺满），退化时直接跑 shader。
class _CloudPainter extends CustomPainter {
  _CloudPainter({
    required this.image,
    required this.imageSize,
    required this.direct,
    required this.time,
    required this.blobs,
    required this.seed,
    required this.opacity,
    required this.shade,
    required this.topBias,
    required this.drift,
    required this.onPainted,
  });

  final ui.Image? image;
  final Size? imageSize;
  final bool direct;
  final double time;
  final double blobs;
  final double seed;
  final double opacity;
  final double shade;
  final double topBias;
  final double drift;
  final VoidCallback onPainted;

  @override
  void paint(Canvas canvas, Size size) {
    onPainted();
    if (direct) {
      final program = MintCloudForeground._program;
      if (program == null) return;
      final shader = program.fragmentShader();
      configureCloudShader(
        shader,
        renderSize: size,
        time: time,
        blobs: blobs,
        seed: seed,
        opacity: opacity,
        shade: shade,
        topBias: topBias,
        drift: drift,
      );
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
      return;
    }
    final img = image;
    final src = imageSize;
    if (img == null || src == null || src.isEmpty) return;
    // 半分辨率离屏图 → 双线性放大铺满。云是低频图，放大几乎无损。
    canvas.drawImageRect(
      img,
      Offset.zero & src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_CloudPainter old) =>
      old.image != image ||
      old.direct != direct ||
      (direct && old.time != time);
}

// ───────────────────────── 纯逻辑（单测覆盖） ─────────────────────────

/// 用户设置 → shader 主 alpha。深色主题白雾在暗底上更扎眼，系数与上限都
/// 更低；浅色主题雾本来就淡，上限略高。两条硬上限是「绝不盖内容」的保险。
@visibleForTesting
double cloudEffectiveOpacity(double opacity, {required bool dark}) {
  final base = opacity.clamp(0.0, 1.0);
  final scaled = base * (dark ? 0.42 : 0.62);
  return scaled.clamp(0.0, dark ? 0.34 : 0.55);
}

/// 深浅主题的涡纹灰度深度：浅色主题雾要带点灰才在白底上显形；
/// 深色主题雾更纯白柔和。
@visibleForTesting
double cloudShadeFor(bool dark) => dark ? 0.30 : 0.85;

/// 密度滑杆（0~1）→ 近层 blob 数量。下限 1.5：再稀也要有一团云在飘。
@visibleForTesting
double cloudBlobCount(double density) =>
    (density.clamp(0.0, 1.0) * 8.0).clamp(1.5, 8.0);

/// 全尺寸 → 半分辨率渲染尺寸（下取整，至少 1×1）。
@visibleForTesting
Size cloudRenderSize(Size full) => Size(
  math.max(1.0, (full.width * 0.5).floorToDouble()),
  math.max(1.0, (full.height * 0.5).floorToDouble()),
);

/// 按 cloud_foreground.frag 的声明顺序写 uniform（0..8 号 float）。
@visibleForTesting
void configureCloudShader(
  ui.FragmentShader shader, {
  required Size renderSize,
  required double time,
  required double blobs,
  required double seed,
  required double opacity,
  required double shade,
  required double topBias,
  required double drift,
}) {
  final uniforms = cloudUniforms(
    width: renderSize.width,
    height: renderSize.height,
    time: time,
    blobs: blobs,
    seed: seed,
    opacity: opacity,
    shade: shade,
    topBias: topBias,
    drift: drift,
  );
  for (var i = 0; i < uniforms.length; i++) {
    shader.setFloat(i, uniforms[i]);
  }
}

/// cloud_foreground.frag 的 uniform 打包（0..8 号 float）。顺序错了画面
/// 不会报错、只会「玄学抽风」，所以集中打包并在单测里锁死顺序。
@visibleForTesting
List<double> cloudUniforms({
  required double width,
  required double height,
  required double time,
  required double blobs,
  required double seed,
  required double opacity,
  required double shade,
  required double topBias,
  required double drift,
}) => <double>[
  width, // 0    uSize.x
  height, // 1   uSize.y
  time, // 2     uTime
  blobs, // 3    uBlobs
  seed, // 4     uSeed
  opacity, // 5  uOpacity
  shade, // 6    uShade
  topBias, // 7  uTopBias
  drift, // 8    uDrift
];

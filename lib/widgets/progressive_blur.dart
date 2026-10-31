import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 渐进模糊的「强端」：模糊在这一侧最重，到对侧干净地溶解为完全清晰。
enum ProgressiveBlurDirection {
  /// 顶边最强，向下逐渐清晰（顶栏 / 状态栏的经典用法）。
  topToBottom,

  /// 底边最强，向上逐渐清晰（底栏 / 悬浮工具条）。
  bottomToTop,

  /// 左边最强，向右逐渐清晰。
  leftToRight,

  /// 右边最强，向左逐渐清晰。
  rightToLeft;

  /// 着色器 `uDirection` 的取值（0 上 / 1 下 / 2 左 / 3 右）。
  double get _uniform => index.toDouble();
}

/// 渐进（渐变）背景模糊 —— Signal / iOS 26 头部那种观感：一层干净的高斯
/// 磨砂，在某一侧最强、平滑衰减到对侧完全清晰。垫在半透明顶栏后面，滚上来
/// 的内容就是「溶解进栏里」而不是撞上一条硬边。
///
/// ## 为什么不是「先模糊再 ShaderMask 淡出」
///
/// 那套配方在 Impeller 上不成立：[BackdropFilter] 抓到的 backdrop 不在祖先
/// [ShaderMask] 的 layer 组里，遮罩遮出来是空气，画面上只剩半透明色。
///
/// 这里改用 [ui.ImageFilter.shader]：片元着色器直接作为 [BackdropFilter] 的
/// 滤镜，引擎会把抓到的 backdrop 绑到着色器的 sampler 上，各后端都可靠。
/// `shaders/progressive_blur.frag` 用「重要性采样 + 双趟可分离高斯」，sigma
/// 按到强边的距离渐变（归一化用组件自己的设备像素矩形，因为绑定的纹理是
/// 整个屏幕）。
///
/// 淡入淡出请驱动 [maxSigma]（0 → 满值），不要在外层套 [Opacity] ——
/// 祖先 Opacity 会另起 backdrop root，模糊就糊不到页面上滚来的内容了。
///
/// ```dart
/// Stack(
///   children: [
///     const Positioned(top: 0, left: 0, right: 0, height: 96,
///       child: ProgressiveBlur(maxSigma: 20)),
///     // ... 半透明顶栏 ...
///   ],
/// )
/// ```
///
/// 在 `main()` 里调一次 [preload] 预编译着色器（不影响正确性，只是让首帧
/// 不用等编译）。
class ProgressiveBlur extends StatefulWidget {
  const ProgressiveBlur({
    super.key,
    this.maxSigma = 18,
    this.direction = ProgressiveBlurDirection.topToBottom,
    this.falloff = 1.2,
  });

  /// 强边处的模糊 sigma（逻辑像素）。0 = 完全不糊（直通）。
  final double maxSigma;

  /// 模糊最强的边（到对侧溶解为清晰）。
  final ProgressiveBlurDirection direction;

  /// 渐变 gamma。>1 把模糊收在强边附近，对侧溶解得更干净。
  final double falloff;

  // ── 着色器程序：进程内只编译一次 ─────────────────────────────────────
  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram>? _loading;

  /// 预编译着色器，让第一次画顶栏时不用等编译。可以重复调用（只编译一次）。
  /// 不会抛异常：失败时组件退化成均匀模糊。
  static Future<void> preload() async {
    if (_program != null) return;
    const path = 'shaders/progressive_blur.frag';
    try {
      _program = await (_loading ??= ui.FragmentProgram.fromAsset(path));
    } catch (e) {
      // 优雅降级：组件退回 BackdropFilter 均匀模糊。
      _loading = null;
      debugPrint('progressive_blur.frag 加载失败，退回均匀模糊：$e');
    }
  }

  /// 着色器是否可用（已编译好）。测试 / 判定用。
  static bool get ready => _program != null;

  @override
  State<ProgressiveBlur> createState() => _ProgressiveBlurState();
}

class _ProgressiveBlurState extends State<ProgressiveBlur> {
  // 同一个程序的实例：一个算 X 方向、一个算 Y 方向。
  ui.FragmentShader? _hShader;
  ui.FragmentShader? _vShader;

  @override
  void initState() {
    super.initState();
    _makeShaders();
    if (_hShader == null) {
      ProgressiveBlur.preload().then((_) {
        if (mounted) setState(_makeShaders);
      });
    }
  }

  void _makeShaders() {
    final p = ProgressiveBlur._program;
    if (p != null && _hShader == null) {
      _hShader = p.fragmentShader();
      _vShader = p.fragmentShader();
    }
  }

  @override
  void dispose() {
    _hShader?.dispose();
    _vShader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.maxSigma <= 0) return const SizedBox.expand();

    final h = _hShader;
    final v = _vShader;
    // 兜底：着色器还没编译好，或后端跑不了 shader filter（桌面 Skia 的
    // `isShaderFilterSupported` 就是 false）。这里用**分片 BackdropFilter**
    // 逼近变半径：每片各自 ClipRect + 固定 sigma，从上到下递减。
    //
    // 关键是**不能在外面套 Opacity** —— 祖先 Opacity 会另起 backdrop root，
    // 每片就只能糊到 layer 组内部（空气），画面上只剩色块。分片本身不碰
    // Opacity，所以每片都能正常采样页面内容；片与片之间是模糊图（低频），
    // 8 片的 sigma 台阶肉眼几乎看不出接缝。
    if (h == null || v == null || !ui.ImageFilter.isShaderFilterSupported) {
      return _SliceFallbackBlur(maxSigma: widget.maxSigma);
    }

    // 绑定的纹理（以及 uSize 的 0,1 两个 float）是**整个 backdrop** 而不是
    // 本组件，所以着色器需要本组件自己的设备像素矩形来归一化渐变 —— 那两半
    // 只能在 paint 时刻取，见 [_RenderProgressiveBlur]。
    return _ProgressiveBlurLayer(
      hShader: h,
      vShader: v,
      maxSigma: widget.maxSigma,
      falloff: widget.falloff,
      direction: widget.direction,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      child: const SizedBox.expand(),
    );
  }
}

/// 着色器不可用时的降落伞：纵向切 [slices] 片，每片固定 sigma、从上往下递减。
///
/// 片边界理论上会有 sigma 台阶，但模糊结果本身是低频图，8 片 + 降采样后
/// 靠肉眼在手机/桌面上分不出来。比「一整块均匀模糊」强得多 —— 均匀模糊在
/// 带子下边缘会留一道硬边，而渐变模糊存在的意义正是消掉那道边。
class _SliceFallbackBlur extends StatelessWidget {
  const _SliceFallbackBlur({required this.maxSigma});

  final double maxSigma;

  static const int slices = 8;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < slices; i++)
          Expanded(
            child: ClipRect(
              child: BackdropFilter(
                // 用该片中心处的强度，而不是上边缘 —— 否则整条带会偏糊。
                filter: ui.ImageFilter.blur(
                  sigmaX: _sigmaAt((i + 0.5) / slices),
                  sigmaY: _sigmaAt((i + 0.5) / slices),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }

  /// 与着色器同一套衰减：`maxSigma * (1 - t)^1.2`。
  double _sigmaAt(double t) {
    final s = (maxSigma * math.pow(1 - t.clamp(0.0, 1.0), 1.2)).toDouble();
    // 0.6 是肉眼刚好能看出「糊了」的下限，太低等于没画。
    return s < 0.6 ? 0 : s;
  }
}

/// 描述模糊区域的 8 个 uniform，按程序声明顺序（float 下标 2-9）。
@visibleForTesting
List<double> progressiveBlurUniforms({
  required Offset origin,
  required Size size,
  required double devicePixelRatio,
  required double maxSigma,
  required double falloff,
  required ProgressiveBlurDirection direction,
  required double axis,
}) => <double>[
  maxSigma * devicePixelRatio,
  falloff,
  direction._uniform,
  axis, // 0 = 水平，1 = 垂直
  origin.dx * devicePixelRatio,
  origin.dy * devicePixelRatio,
  size.width * devicePixelRatio,
  size.height * devicePixelRatio,
];

/// 以 backdrop filter 的形式套上两趟着色器。
///
/// 用 RenderObject 而不是 [LayoutBuilder] + [BackdropFilter]，是因为区域矩形
/// 只有到 paint 时刻才知道、也只有那时才保持最新：祖先把组件移来移去（拖拽、
/// 滚动、动画 inset）时是靠**重绘**而不是重建，在 build / post-frame 里读到的
/// offset 在整个运动期间都是过期的，渐变就会按错误的矩形归一化。
class _ProgressiveBlurLayer extends SingleChildRenderObjectWidget {
  const _ProgressiveBlurLayer({
    required this.hShader,
    required this.vShader,
    required this.maxSigma,
    required this.falloff,
    required this.direction,
    required this.devicePixelRatio,
    required Widget super.child,
  });

  final ui.FragmentShader hShader;
  final ui.FragmentShader vShader;
  final double maxSigma;
  final double falloff;
  final ProgressiveBlurDirection direction;
  final double devicePixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderProgressiveBlur(
        hShader: hShader,
        vShader: vShader,
        maxSigma: maxSigma,
        falloff: falloff,
        direction: direction,
        devicePixelRatio: devicePixelRatio,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderProgressiveBlur renderObject,
  ) => renderObject.update(
    hShader: hShader,
    vShader: vShader,
    maxSigma: maxSigma,
    falloff: falloff,
    direction: direction,
    devicePixelRatio: devicePixelRatio,
  );
}

class _RenderProgressiveBlur extends RenderProxyBox {
  _RenderProgressiveBlur({
    required ui.FragmentShader hShader,
    required ui.FragmentShader vShader,
    required double maxSigma,
    required double falloff,
    required ProgressiveBlurDirection direction,
    required double devicePixelRatio,
  }) : _hShader = hShader,
       _vShader = vShader,
       _maxSigma = maxSigma,
       _falloff = falloff,
       _direction = direction,
       _devicePixelRatio = devicePixelRatio;

  ui.FragmentShader _hShader;
  ui.FragmentShader _vShader;
  double _maxSigma;
  double _falloff;
  ProgressiveBlurDirection _direction;
  double _devicePixelRatio;

  /// 一次比较全部字段：它们总是同一次重建里一起到的。着色器按 identity 比
  /// —— 它们是 State 持有的长生命周期实例，不是值。
  void update({
    required ui.FragmentShader hShader,
    required ui.FragmentShader vShader,
    required double maxSigma,
    required double falloff,
    required ProgressiveBlurDirection direction,
    required double devicePixelRatio,
  }) {
    if (identical(_hShader, hShader) &&
        identical(_vShader, vShader) &&
        _maxSigma == maxSigma &&
        _falloff == falloff &&
        _direction == direction &&
        _devicePixelRatio == devicePixelRatio) {
      return;
    }
    _hShader = hShader;
    _vShader = vShader;
    _maxSigma = maxSigma;
    _falloff = falloff;
    _direction = direction;
    _devicePixelRatio = devicePixelRatio;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  BackdropFilterLayer? get layer => super.layer as BackdropFilterLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    // backdrop layer 自身坐标系里的偏移 —— 也就是着色器 FlutterFragCoord()
    // 的坐标空间。
    final origin = localToGlobal(Offset.zero);
    _configure(_hShader, 0, origin);
    _configure(_vShader, 1, origin);

    // 可分离两趟：先水平（内层）再垂直（外层）= 干净的二维高斯。
    (layer ??= BackdropFilterLayer()).filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(_vShader),
      inner: ui.ImageFilter.shader(_hShader),
    );
    context.pushLayer(layer!, super.paint, offset);
  }

  void _configure(ui.FragmentShader shader, double axis, Offset origin) {
    final uniforms = progressiveBlurUniforms(
      origin: origin,
      size: size,
      devicePixelRatio: _devicePixelRatio,
      maxSigma: _maxSigma,
      falloff: _falloff,
      direction: _direction,
      axis: axis,
    );
    for (var i = 0; i < uniforms.length; i++) {
      shader.setFloat(2 + i, uniforms[i]);
    }
  }
}

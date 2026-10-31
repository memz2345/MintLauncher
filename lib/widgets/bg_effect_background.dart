// 关于页「效果背景」：InstallerX-Revived 的 BgEffectBackground 移植。
//
// 原版是 Compose 侧的 RuntimeShader（AGSL）+ 每帧驱动：4 个彩色光斑按
// sin/cos 游走、颜色在 3 组预设间循环插值，Perlin 噪声做去饱和提亮。
// Flutter 侧对应 FragmentProgram（shaders/bg_effect.frag，本仓库随包编译），
// 光斑位置与颜色循环在宿主（本文件）每帧算好再喂给 uniform —— 与原版
// BgEffectPainter.updatePointsAnim/updateColors 的分工一致。
// SPDX-License-Identifier: Apache-2.0

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 效果变体：OS3 是 InstallerX 现在这套（紫罗兰/粉蓝），OS2 是上一代
/// （更暖的粉橙蓝）。两者共用同一个着色器，差别只在预设数据。
enum BgEffectVariant { os2, os3 }

/// 一份效果背景预设（对应 InstallerX `BgEffectConfig.Config`）。
class BgEffectPreset {
  const BgEffectPreset({
    required this.points,
    required this.colors1,
    required this.colors2,
    required this.colors3,
    required this.colorInterpPeriod,
    required this.lightOffset,
    required this.saturateOffset,
    required this.pointOffset,
  });

  /// 4 个光斑的 (x, y, 半径)，归一化 bound 空间。
  final List<double> points;

  /// 3 组颜色（4 个 × rgba），背景在这三组之间循环插值。
  final List<double> colors1;
  final List<double> colors2;
  final List<double> colors3;

  /// 颜色循环一轮的周期（秒）；越大换色越慢。
  final double colorInterpPeriod;
  final double lightOffset;
  final double saturateOffset;
  final double pointOffset;

  /// 循环序取色：InstallerX 的 colorsForCycleIndex —— 序号对 4 取模，
  /// 1 → colors1、3 → colors3，其余 → colors2（即 c2→c1→c2→c3 循环）。
  List<double> colorsForCycleIndex(int index) => switch (index % 4) {
    1 => colors1,
    3 => colors3,
    _ => colors2,
  };
}

/// OS3 预设（手机）。浅色取自 InstallerX `OS3_PHONE_LIGHT`，深色是它
/// 深色主题那套紫罗兰色调（alpha 压低、漂移更快）。
const BgEffectPreset kOs3PhoneLight = BgEffectPreset(
  points: [0.8, 0.2, 1.0, 0.8, 0.9, 1.0, 0.2, 0.9, 1.0, 0.2, 0.2, 1.0],
  colors1: [
    1.0, 0.9, 0.94, 1.0, //
    1.0, 0.84, 0.89, 1.0, //
    0.97, 0.73, 0.82, 1.0, //
    0.64, 0.65, 0.98, 1.0, //
  ],
  colors2: [
    0.58, 0.74, 1.0, 1.0, //
    1.0, 0.9, 0.93, 1.0, //
    0.74, 0.76, 1.0, 1.0, //
    0.97, 0.77, 0.84, 1.0, //
  ],
  colors3: [
    0.98, 0.86, 0.9, 1.0, //
    0.6, 0.73, 0.98, 1.0, //
    0.92, 0.93, 1.0, 1.0, //
    0.56, 0.69, 1.0, 1.0, //
  ],
  colorInterpPeriod: 5.0,
  lightOffset: 0.1,
  saturateOffset: 0.2,
  pointOffset: 0.2,
);

const BgEffectPreset kOs3PhoneDark = BgEffectPreset(
  points: [0.8, 0.2, 1.0, 0.8, 0.9, 1.0, 0.2, 0.9, 1.0, 0.2, 0.2, 1.0],
  colors1: [
    0.72, 0.62, 0.98, 0.55, //
    0.45, 0.35, 0.85, 0.50, //
    0.58, 0.44, 0.92, 0.55, //
    0.38, 0.30, 0.72, 0.45, //
  ],
  colors2: [
    0.55, 0.45, 0.95, 0.50, //
    0.42, 0.32, 0.80, 0.55, //
    0.66, 0.52, 0.98, 0.50, //
    0.35, 0.28, 0.68, 0.45, //
  ],
  colors3: [
    0.62, 0.50, 0.98, 0.55, //
    0.50, 0.40, 0.88, 0.50, //
    0.72, 0.60, 1.0, 0.45, //
    0.40, 0.33, 0.78, 0.50, //
  ],
  colorInterpPeriod: 8.0,
  lightOffset: 0.0,
  saturateOffset: 0.17,
  pointOffset: 0.4,
);

/// OS2 预设（手机）：暖粉/橙/蓝，颜色循环周期极长 ≈ 静态（原版同款处理）。
const BgEffectPreset kOs2PhoneLight = BgEffectPreset(
  points: [0.8, 0.2, 1.0, 0.8, 0.9, 0.62, 0.2, 0.9, 1.0, 0.2, 0.2, 0.8],
  colors1: [
    0.57, 0.76, 0.98, 1.0, //
    0.98, 0.85, 0.68, 1.0, //
    0.98, 0.75, 0.93, 1.0, //
    0.73, 0.70, 0.98, 1.0, //
  ],
  colors2: [
    0.57, 0.76, 0.98, 1.0, //
    0.98, 0.85, 0.68, 1.0, //
    0.98, 0.75, 0.93, 1.0, //
    0.73, 0.70, 0.98, 1.0, //
  ],
  colors3: [
    0.57, 0.76, 0.98, 1.0, //
    0.98, 0.85, 0.68, 1.0, //
    0.98, 0.75, 0.93, 1.0, //
    0.73, 0.70, 0.98, 1.0, //
  ],
  colorInterpPeriod: 100.0,
  lightOffset: 0.1,
  saturateOffset: 0.2,
  pointOffset: 0.2,
);

const BgEffectPreset kOs2PhoneDark = BgEffectPreset(
  points: [0.8, 0.2, 1.0, 0.8, 0.9, 0.62, 0.2, 0.9, 1.0, 0.2, 0.2, 0.8],
  colors1: [
    0.45, 0.58, 0.85, 0.50, //
    0.80, 0.62, 0.45, 0.50, //
    0.80, 0.52, 0.72, 0.50, //
    0.52, 0.50, 0.82, 0.45, //
  ],
  colors2: [
    0.45, 0.58, 0.85, 0.50, //
    0.80, 0.62, 0.45, 0.50, //
    0.80, 0.52, 0.72, 0.50, //
    0.52, 0.50, 0.82, 0.45, //
  ],
  colors3: [
    0.45, 0.58, 0.85, 0.50, //
    0.80, 0.62, 0.45, 0.50, //
    0.80, 0.52, 0.72, 0.50, //
    0.52, 0.50, 0.82, 0.45, //
  ],
  colorInterpPeriod: 100.0,
  lightOffset: 0.0,
  saturateOffset: 0.17,
  pointOffset: 0.3,
);

/// uniform 在 shader 里的 float 下标（顺序必须与 bg_effect.frag 声明一致）。
abstract final class _Uniform {
  static const resolution = 0; // vec2
  static const animTime = 2; // float
  static const bound = 3; // vec4
  static const translateY = 7; // float
  static const points = 8; // vec3 ×4
  static const pointsAnim = 20; // vec2 ×4
  static const colors = 28; // vec4 ×4
  static const alphaMulti = 44;
  static const noiseScale = 45;
  static const pointRadiusMulti = 46;
  static const saturateOffset = 47;
  static const lightOffset = 48;
  static const dpr = 49;
}

/// 效果背景：铺满父级画一层会动的彩色光斑，[child] 画在其上。
///
/// [variant] 选预设代次；[dark] 不给时跟随 [Theme];[dynamic] 关掉后时间冻结
/// （光斑停在当前位置、颜色不循环）；[enabled] 是 Texture Set 里的
/// 「效果背景」总开关，关掉就什么都不画（露出底下的 surface）。
/// [isFullSize] 渐变占屏比例：false 占上面一半（InstallerX 关于页同款），
/// true 占 80%。[alpha] 整体淡出（关于页随滚动把背景压下去）。
/// [saturateOffset] 覆盖预设的噪声去饱和强度（纹理集的「噪点」滑条），
/// null = 用预设值。
class BgEffectBackground extends StatefulWidget {
  const BgEffectBackground({
    super.key,
    this.variant = BgEffectVariant.os3,
    this.dark,
    this.dynamic = true,
    this.enabled = true,
    this.isFullSize = false,
    this.alpha = 1.0,
    this.saturateOffset,
    this.child,
  });

  final BgEffectVariant variant;
  final bool? dark;
  final bool dynamic;
  final bool enabled;
  final bool isFullSize;
  final double alpha;
  final double? saturateOffset;
  final Widget? child;

  @override
  State<BgEffectBackground> createState() => _BgEffectBackgroundState();
}

class _BgEffectBackgroundState extends State<BgEffectBackground>
    with SingleTickerProviderStateMixin {
  /// 着色器程序加载完成的通知（一次性的静态事件，所有实例共享）。
  /// 用 ValueNotifier 而不是裸字段：加载是异步的，晚到时要叫醒已挂载的
  /// 实例从「静态径向渐变兜底」切回真着色器。
  static final ValueNotifier<ui.FragmentProgram?> _program$ = ValueNotifier(
    null,
  );
  static bool _loadFailed = false;

  late final Ticker _ticker;

  /// 动画时间（秒）。用 ValueNotifier 做成 CustomPaint 的 repaint listenable：
  /// 每帧只叫醒背景这一层重绘，不 setState 重建整棵子树 —— 整页重建在低端
  /// 设备上会把帧时间顶爆，画面就会出现不同区域的「新旧帧拼贴」。
  final ValueNotifier<double> _time$ = ValueNotifier(0);

  /// 本实例的 FragmentShader：**跨帧复用**（InstallerX 的 BgEffectPainter
  /// 也是懒建一个 RuntimeShader 然后只改 uniform）。每帧新建会让底层
  /// uniform 缓冲反复分配/回收，在 Impeller + 模拟器上会出画块撕裂。
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadProgram();
    _program$.addListener(_onProgramLoaded);
    _ticker = createTicker(_onTick);
    if (widget.dynamic) _ticker.start();
  }

  static void _loadProgram() {
    if (_program$.value != null || _loadFailed) return;
    ui.FragmentProgram.fromAsset('shaders/bg_effect.frag').then(
      (p) => _program$.value = p,
      onError: (Object e) {
        _loadFailed = true;
        debugPrint('BgEffectBackground: shader load failed: $e');
      },
    );
  }

  void _onProgramLoaded() {
    if (mounted) setState(() {});
  }

  void _onTick(Duration elapsed) {
    // 掉帧追帧没有意义，直接用秒数推进（动画是连续函数）。
    _time$.value = elapsed.inMicroseconds / 1e6;
  }

  @override
  void didUpdateWidget(BgEffectBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.dynamic != oldWidget.dynamic) {
      if (widget.dynamic) {
        _time$.value = 0;
        if (!_ticker.isActive) _ticker.start();
      } else {
        _ticker.stop();
      }
    }
  }

  @override
  void dispose() {
    _program$.removeListener(_onProgramLoaded);
    _ticker.dispose();
    _time$.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = widget.dark ?? Theme.of(context).brightness == Brightness.dark;
    final program = _program$.value;
    // 程序到手才建 shader；加载失败就一直是 null（走兜底画法）。
    if (program != null) _shader ??= program.fragmentShader();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _BgEffectPainter(
            variant: widget.variant,
            dark: dark,
            timeOf: () => _time$.value,
            dynamic: widget.dynamic,
            enabled: widget.enabled,
            isFullSize: widget.isFullSize,
            alpha: widget.alpha,
            saturateOffset: widget.saturateOffset,
            shader: _shader,
            dpr: MediaQuery.devicePixelRatioOf(context),
            repaint: _time$,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _BgEffectPainter extends CustomPainter {
  _BgEffectPainter({
    required this.variant,
    required this.dark,
    required this.timeOf,
    required this.dynamic,
    required this.enabled,
    required this.isFullSize,
    required this.alpha,
    required this.saturateOffset,
    required this.shader,
    required this.dpr,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final BgEffectVariant variant;
  final bool dark;

  /// 取当前动画时间（秒）。时间每帧都变，走 [repaint] listenable 驱动，
  /// 不能当 painter 的字段比（字段在重建前不会更新）。
  final double Function() timeOf;

  double get time => timeOf();

  final bool dynamic;
  final bool enabled;
  final bool isFullSize;
  final double alpha;
  final double? saturateOffset;

  /// 设备像素比：抖动噪声的坐标要从逻辑像素换算回物理像素（见 shader 注释）。
  final double dpr;

  /// 跨帧复用的着色器（uniform 每次 paint 原地重写，与 InstallerX 同款）。
  final ui.FragmentShader? shader;

  BgEffectPreset get _preset {
    if (variant == BgEffectVariant.os2) {
      return dark ? kOs2PhoneDark : kOs2PhoneLight;
    }
    return dark ? kOs3PhoneDark : kOs3PhoneLight;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!enabled || size.isEmpty || alpha <= 0) return;
    final preset = _preset;

    // 着色器还没加载好（或加载失败）时退回静态径向渐变：
    // 4 个光斑摆在预设位置上，第一帧就不空白。
    final shader = this.shader;
    if (shader == null) {
      _paintFallback(canvas, size, preset);
      return;
    }

    final bound = _computeBound(size);
    shader
      ..setFloat(_Uniform.resolution, size.width)
      ..setFloat(_Uniform.resolution + 1, size.height)
      ..setFloat(_Uniform.animTime, time)
      ..setFloat(_Uniform.bound + 0, bound.$1)
      ..setFloat(_Uniform.bound + 1, bound.$2)
      ..setFloat(_Uniform.bound + 2, bound.$3)
      ..setFloat(_Uniform.bound + 3, bound.$4)
      ..setFloat(_Uniform.translateY, 0.0);
    for (var i = 0; i < 4; i++) {
      final px = preset.points[i * 3];
      final py = preset.points[i * 3 + 1];
      final radius = preset.points[i * 3 + 2];
      shader
        ..setFloat(_Uniform.points + i * 3 + 0, px)
        ..setFloat(_Uniform.points + i * 3 + 1, py)
        ..setFloat(_Uniform.points + i * 3 + 2, radius);
      // 光斑游走：x 按 sin、y 按 cos，y 的相位取动画后的 x（原版同款）。
      final animX = dynamic
          ? px + math.sin(time + py) * preset.pointOffset
          : px;
      final animY = dynamic
          ? py + math.cos(time + animX) * preset.pointOffset
          : py;
      shader
        ..setFloat(_Uniform.pointsAnim + i * 2 + 0, animX)
        ..setFloat(_Uniform.pointsAnim + i * 2 + 1, animY);
    }
    final colors = _cycleColors(preset);
    for (var i = 0; i < 16; i++) {
      shader.setFloat(_Uniform.colors + i, colors[i]);
    }
    shader
      ..setFloat(_Uniform.alphaMulti, alpha)
      ..setFloat(_Uniform.noiseScale, 1.5)
      ..setFloat(_Uniform.pointRadiusMulti, 1.0)
      ..setFloat(
        _Uniform.saturateOffset,
        saturateOffset ?? preset.saturateOffset,
      )
      ..setFloat(_Uniform.lightOffset, preset.lightOffset)
      ..setFloat(_Uniform.dpr, dpr);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  /// 渐变映射区：竖屏取上面一半（fullSize 时 80%），横屏按宽高比居中。
  (double, double, double, double) _computeBound(Size size) {
    final drawHeight = size.height * (isFullSize ? 0.8 : 0.5);
    final hRatio = drawHeight / size.height;
    if (size.width <= size.height) {
      return (0.0, 1.0 - hRatio, 1.0, hRatio);
    }
    final aspect = size.width / size.height;
    final contentCenterY = 1.0 - hRatio / 2.0;
    return (0.0, contentCenterY - aspect / 2.0, 1.0, aspect);
  }

  /// 颜色循环：时间按 period*0.5 秒一格推进，格与格之间线性插值；
  /// dynamic 关闭时冻结在第 0 格（= colors2，原版一致）。
  List<double> _cycleColors(BgEffectPreset preset) {
    if (!dynamic) return preset.colors2;
    final stageF = time / (preset.colorInterpPeriod * 0.5);
    final base = stageF.floor();
    final t = stageF - base;
    // 平滑一下格间的跳变（原版用 spring，这里用 smoothstep 足够像）。
    final frac = t * t * (3.0 - 2.0 * t);
    final a = preset.colorsForCycleIndex(base);
    final b = preset.colorsForCycleIndex(base + 1);
    return [for (var i = 0; i < 16; i++) a[i] + (b[i] - a[i]) * frac];
  }

  /// 无着色器时的兜底：4 个径向渐变光斑（静态、无噪声），观感是同款配色。
  void _paintFallback(Canvas canvas, Size size, BgEffectPreset preset) {
    final bound = _computeBound(size);
    final colors = preset.colorsForCycleIndex(0);
    for (var i = 0; i < 4; i++) {
      final px = preset.points[i * 3];
      final py = preset.points[i * 3 + 1];
      final radius = preset.points[i * 3 + 2];
      final center = Offset(
        bound.$1 * size.width + px * bound.$3 * size.width,
        (bound.$2 + (1.0 - py) * bound.$4) * size.height,
      );
      final r = radius * bound.$3 * size.width * 0.8;
      final a = (colors[i * 4 + 3] * alpha).clamp(0.0, 1.0);
      if (a <= 0) continue;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = ui.Gradient.radial(
            center,
            r,
            [
              Color.fromARGB(
                (a * 255).round(),
                (colors[i * 4] * 255).round(),
                (colors[i * 4 + 1] * 255).round(),
                (colors[i * 4 + 2] * 255).round(),
              ),
              Color.fromARGB(
                (a * 255).round(),
                (colors[i * 4] * 255).round(),
                (colors[i * 4 + 1] * 255).round(),
                (colors[i * 4 + 2] * 255).round(),
              ),
              const Color(0x00000000),
            ],
            [0.0, 0.55, 1.0],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_BgEffectPainter oldDelegate) =>
      oldDelegate.variant != variant ||
      oldDelegate.dark != dark ||
      oldDelegate.dynamic != dynamic ||
      oldDelegate.enabled != enabled ||
      oldDelegate.isFullSize != isFullSize ||
      oldDelegate.alpha != alpha ||
      oldDelegate.saturateOffset != saturateOffset ||
      oldDelegate.dpr != dpr ||
      oldDelegate.shader != shader;
}

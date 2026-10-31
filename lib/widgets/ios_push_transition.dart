// lib/widgets/ios_push_transition.dart
//
// 全局页面 push 转场（配置于 ThemeData.pageTransitionsTheme，应用于所有
// MaterialPageRoute）。动画照 **miuix-nav 的 `NavTransitions.MiuixDefault`**
// 搬过来，也就是 KernelSU 管理器的页面切换同款：
//
//   - 新页面：**全宽从尾侧滑入**（d: -1 → 0，translationX: +width → 0）；
//     转场全程保持设定圆角，落位后平滑收成直角（[kIosPushCornerHold] 与
//     [_cornerCollapseMs] 可调）；
//   - 旧页面（被覆盖层）：向首侧**视差 1/4 屏宽**（[kIosPushCoveredParallax]）
//     + **alpha 衰减 10%**（[kIosPushCoveredAlphaDrop]）——
//     `NavTransitions.MiuixDefault` 的 covered 处理；
//   - **压暗**：一层全屏、**静止**、压在最上层之下的遮罩，峰值
//     [kIosPushDimOpacity] × 覆盖进度。这是 `NavDisplayEffects.dimAmount`
//     × `NavTransition.scrimFraction`，默认那条 scrimFraction 随深度**线性**。
//     它**不跟着旧页面平移** —— 参考实现里 scrim「spans the whole entering
//     surface」，连露出的背景一起压暗；
//   - **曲线**：miuix-nav「程序化转场」的停靠曲线（`NavSettleEasing`，把欠
//     阻尼弹簧的阶跃响应烘焙成 Easing，见 [MiuixNavSettleCurve]）；
//   - **打断**：见 [MiuixNavSettleDriver]。
//
// ⚠️ 名字里的 Ios* 是历史遗留（这套转场最早是 iOS 风格），现在跑的是
// miuix-nav 的几何与曲线；改名会连带动 app_theme / common / 测试一串引用，
// 先留着。
//
// 与已有自定义动画的共存（互不干扰）：
//   - FrostedHeroRoute / PageRouteBuilder（投币页、设置搜索跳转等）自带
//     transitionsBuilder，不经 PageTransitionsTheme，完全不受影响；
//   - MaterialPageRoute.canTransitionTo 对非 Material 路由返回 false：
//     被 FrostedHeroRoute 或半透明弹层（opaque:false）覆盖时，旧页面的
//     secondaryAnimation 不会被驱动，本转场的旧页面效果自然跳过；
//   - 根节点使用 [IosBackdropScale] 的页面自带「iOS 景深缩放」退场动画，
//     会向 [CustomSecondaryTransitionRoutes] 注册所在路由；本转场检测到
//     （且其效果处于开启状态）时跳过自身的旧页面效果，避免双重退场。
//     ⚠️ 但**只有该页此刻真的会缩**时才登记，见该类的注释。
//
// 预测式返回（Android 14+）：
//   - [PredictiveBackGestureDetector] 把系统侧滑返回的进度逐帧 seek 到路由
//     控制器，本转场识别到「被手指 seek」时退化成 1:1 跟手（对应 miuix-nav
//     的 snap 模式：手势期间几何不做缓动，手指走多远页面走多远）；
//   - 松手时接回停靠曲线，**交接处速度连续**（见 [MiuixNavSettleDriver]）。
//
// 性能：
//   - 压暗层是纯半透明色块（无 BackdropFilter / 无 ImageFiltered），
//     不触发 saveLayer、不重光栅化背景；
//   - 被覆盖页的 alpha 衰减在 d == 0（页面正常展示）时完全不挂 Opacity 层；
//   - 转场静止期只剩恒等平移 + 半径 0 圆角，开销可忽略。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mint/widgets/hero_gesture_curve.dart';
import 'package:mint/widgets/predictive_back_detector.dart';

/// 压暗遮罩的最大不透明度（`NavDisplayEffects.dimAmount` 的默认值 0.5）。
///
/// 最终 alpha = 本值 × 覆盖进度（深度线性），所以是「逐渐压暗到半黑」。
const double kIosPushDimOpacity = 0.50;

/// 被覆盖页向首侧视差的屏宽比例
/// （`NavTransitions.MiuixDefault`：`width * 0.25f`）。
const double kIosPushCoveredParallax = 0.25;

/// 被覆盖页的 alpha 衰减上限
/// （`NavTransitions.MiuixDefault`：`alpha = 1f - 0.1f * coverProgress`）。
const double kIosPushCoveredAlphaDrop = 0.10;

/// 页面落位后、圆角开始收起前的等待时长。
///
/// 现在是 **0：转场动画一结束马上开始收角**（收的过程本身是
/// [_cornerCollapseMs] 的渐变，不会显得突兀）。想要「先停一下再消失」的
/// 节奏，把它调成 `Duration(seconds: 1)` 就行。
const Duration kIosPushCornerHold = Duration.zero;

/// 圆角收直的过程时长（太长会看到明显的「缩角」，太短会跳）。
const int _cornerCollapseMs = 480;

/// pop 起手把圆角从直角恢复成卡片的时长（比收角略快，跟手起步更利落）。
const int _cornerRestoreMs = 320;

/// 「本路由已自带旧页面退场动画」注册表。
///
/// 页面根节点使用 [IosBackdropScale]（iOS 景深缩放）等自定义退场效果时，
/// **且该效果此刻真的会跑**时，将所在路由注册到此表；
/// [IosPushPageTransitionsBuilder] 检测到后跳过自身的旧页面动画，避免两种
/// 退场效果叠加。
class CustomSecondaryTransitionRoutes {
  CustomSecondaryTransitionRoutes._();

  static final Set<PageRoute<dynamic>> _routes = <PageRoute<dynamic>>{};

  static void register(PageRoute<dynamic> route) => _routes.add(route);

  static void unregister(PageRoute<dynamic> route) => _routes.remove(route);

  static bool contains(PageRoute<dynamic> route) => _routes.contains(route);
}

/// miuix-nav 风格 push 转场构建器（配置于 ThemeData.pageTransitionsTheme）。
class IosPushPageTransitionsBuilder extends PageTransitionsBuilder {
  /// 有自定义旧页面退场效果的页面（景深缩放等）全局开关：本转场检测到
  /// 注册过的路由且开关开启时让位，避免双重退场。
  static bool heroTransitionBlurEnabled = true;

  const IosPushPageTransitionsBuilder({
    /// 新页面入场起始圆角（显示设置中可调）。
    this.cornerRadius = 26.0,

    /// 压暗遮罩的最大不透明度（0 = 不压暗）。见 [kIosPushDimOpacity]。
    this.dimOpacity = kIosPushDimOpacity,

    /// 被覆盖页向首侧视差的屏宽比例。见 [kIosPushCoveredParallax]。
    this.underneathFraction = kIosPushCoveredParallax,

    /// 被覆盖页的 alpha 衰减上限。见 [kIosPushCoveredAlphaDrop]。
    this.coveredAlphaDrop = kIosPushCoveredAlphaDrop,

    /// 转场时长（push / pop 一致，毫秒）。
    ///
    /// 500 = miuix-nav 的 `PROGRAMMATIC_DURATION_MILLIS`：曲线
    /// [_transitionCurve] 的节奏是按这个窗口烘焙的，改短整条曲线会等比变急。
    this.transitionMs = 500,

    /// 是否接管 Android 14+ 的预测式返回手势（跟手拖动返回）。
    /// 非 Android 平台没有手势事件上来，开启也无害。
    this.predictiveBack = true,
  });

  final double cornerRadius;
  final double dimOpacity;
  final double underneathFraction;
  final double coveredAlphaDrop;
  final int transitionMs;
  final bool predictiveBack;

  @override
  Duration get transitionDuration => Duration(milliseconds: transitionMs);

  @override
  Duration get reverseTransitionDuration =>
      Duration(milliseconds: transitionMs);

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    Widget build(bool popGestureInProgress) => _IosPushPageTransition(
      route: route,
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      cornerRadius: cornerRadius,
      dimOpacity: dimOpacity,
      underneathFraction: underneathFraction,
      coveredAlphaDrop: coveredAlphaDrop,
      stepSeconds: transitionMs / 1000.0,
      popGestureInProgress: popGestureInProgress,
      child: child,
    );

    // 路由为空（部分自定义转场会传 null）或关闭预测式返回 → 原路径。
    if (!predictiveBack || route == null) return build(false);

    return PredictiveBackGestureDetector(
      route: route,
      builder: (context, popGestureInProgress) => HeroGestureCurve(
        linear: popGestureInProgress,
        child: build(popGestureInProgress),
      ),
    );
  }
}

/// miuix-nav「程序化转场」的停靠曲线（KernelSU 管理器页面切换同款）。
///
/// 来源：compose-miuix-ui/miuix 的
/// `miuix-nav/.../nav/runtime/NavSettleEasing.kt` —— 把一条欠阻尼弹簧的
/// **阶跃响应点对点烘焙成 Easing**，再配固定时长的 tween 播放：
///
///   x(t) = e^(r·t) · (-cos(w·t) + c₂·sin(w·t)) + 1
///   r = -c/2,  w = √(4k - c²)/2,  c₂ = r/w
///   k = ω²,  ω = 2π/response,  c = damping·4π/response
///
/// KernelSU 的页面 push / pop 走 `NavMotion.Default.programmatic`，就是
/// `NavSettleEasing(response = 0.8, damping = 0.95)` 这条。
///
/// 手感特征：**中段起速快、尾巴长而缓** —— t = 0.2 时已到 ≈48%，
/// t = 1 才 ≈99.93%（上游 tween 在末帧把这点残差拍平，所以这里 t ≥ 1
/// 直接吸附到 1，免得页面落位后永远留 0.07% 屏宽的亚像素偏移）。
/// 参数在 0..1 上单调，不会过冲回弹；两端导数都是 0（阶跃响应本来就从
/// 静止起、到静止收），所以接上/接下都很顺。
class MiuixNavSettleCurve extends Curve {
  MiuixNavSettleCurve({this.response = 0.8, this.damping = 0.95}) {
    final omega = 2 * math.pi / response;
    final k = omega * omega;
    final c = damping * 4 * math.pi / response;
    _w = math.sqrt(4 * k - c * c) / 2;
    _r = -c / 2;
    _c2 = _r / _w;
  }

  /// 弹簧振荡周期，以「播放时长」为单位（上游默认 0.8）。
  final double response;

  /// 阻尼比（< 1，欠阻尼；上游默认 0.95）。
  final double damping;

  late final double _w;
  late final double _r;
  late final double _c2;

  @override
  double transformInternal(double t) {
    // 末帧吸附：上游 tween 同样把它拍成 1（transform(1) ≈ 0.99933）。
    if (t >= 1) return 1;
    final decay = math.exp(_r * t);
    return decay * (-math.cos(_w * t) + _c2 * math.sin(_w * t)) + 1;
  }

  /// 曲线对 t 的一阶导（解析解，不是数值差分）。
  ///
  ///   x'(t) = e^(r·t) · [ r·(-cos(w·t) + c₂·sin(w·t))
  ///                       + w·sin(w·t) + c₂·w·cos(w·t) ]
  ///
  /// t ≥ 1 时已经吸附成常数 1，导数自然为 0。
  /// [MiuixNavSettleDriver] 要靠它在打断处把速度交接过去（首导数连续）。
  double derivative(double t) {
    if (t >= 1) return 0;
    final decay = math.exp(_r * t);
    final base = -math.cos(_w * t) + _c2 * math.sin(_w * t);
    return decay *
        (_r * base + _w * math.sin(_w * t) + _c2 * _w * math.cos(_w * t));
  }
}

/// 全项目共用的一条曲线实例。退场不另配：pop 时动画值回退，同一条曲线跑出来
/// 天然是镜像的缓入（miuix 也是正反两向共用同一条 settle 曲线）。
final MiuixNavSettleCurve _transitionCurve = MiuixNavSettleCurve();

/// 把路由控制器的**线性** 0..1 驱动映射成速度连续的视觉进度。
///
/// 对应 miuix-nav `NavDriver.settleProgrammatic` 的分派规则：
///
///   · **静止起步 + 整步**（上游 `usesProgrammaticCurve`：`velocity == 0 &&
///     |distance| >= 0.999`）→ 固定时长 tween + [MiuixNavSettleCurve]，
///     就是 `NavMotion.programmatic`；
///   · **其余**（打断续跑 / 手势落点续跑 / 半程续跑）→ **带初速度**的停靠
///     曲线，交接处首导数连续 —— 这正是「打断」不顿的关键。
///
/// ### 为什么带初速度的那条不用实时弹簧
///
/// 上游用的是实时弹簧（`NavSettleSpec.Spring(dampingRatio 1, stiffness 146)`，
/// 约半秒收敛）。但 Flutter 的路由生命周期由控制器的 raw 值决定：raw 一到
/// 0/1，路由就出栈、页面就被拆掉。视觉进度**必须恰好在同一时刻**落到终点，
/// 弹簧的长尾会被出栈那一刀切掉（实测：从 0.844 逆向时弹簧在出栈瞬间还剩
/// 0.295，硬切就是明显的跳变）。
///
/// 所以这里换成同样落在终点、同样保初速度、且解析可解的**临界阻尼 Hermite**：
///
///   g(s) = y₀(2s³-3s²+1) + m₀(s³-2s²+s) + y₁(-2s³+3s²),   s ∈ [0,1]
///
/// 它精确满足上游最看重的那几条性质：
///   · **首导数连续**：g'(0) = m₀ = 初速度 × 本段时长，速度交接不跳；
///   · **精确落点**：g(1) = y₁，且 g'(1) = 0（到静止收，同阶跃响应）；
///   · **不过冲**：g(s) - y₁ = (1-s)²[(y₀-y₁)(2s+1) + m₀s]，只要把 m₀ 夹在
///     无过冲界内（`m₀ ≥ -3(y₀-y₁)` / 反向对称），全程不越过目标 ——
///     对应上游 `NavSettleSpec.Spring.clampOvershoot` 的 no-overshoot 语义。
///
/// ### 为什么不需要时钟也能算速度
///
/// Flutter 的 `AnimationController.forward()/reverse()` 是**恒速**的
/// （`_animateToInternal` 里 `simulationDuration = duration × remainingFraction`，
/// 所以 raw 恒以 1/stepSeconds 的速度走完）。于是本段时长
/// `T = |Δraw| × stepSeconds`、raw 速度 `= ±1/stepSeconds`，都可由 raw 轨迹
/// 推出。唯一例外是**手指拖动**阶段（控制器被逐帧 seek，速度取决于手指），
/// 那里靠采样时钟做数值微分。
class MiuixNavSettleDriver {
  MiuixNavSettleDriver({
    required this.stepSeconds,
    MiuixNavSettleCurve? curve,
    this.stopwatch,
  }) : _curve = curve ?? MiuixNavSettleCurve();

  /// raw 走完 0→1 的名义时长（= 路由的 transitionDuration，秒）。
  final double stepSeconds;

  /// 单调时钟；只在手指拖动阶段做速度微分用。测试里可注入确定值。
  final Stopwatch? stopwatch;

  /// [stopwatch] 没给时的兜底时钟（首次用到才启动）。
  Stopwatch? _fallbackWatch;

  final MiuixNavSettleCurve _curve;

  // ── 连续状态（跨帧保留，打断靠它们保持位置/速度连续）──
  double _value = 0;
  double _raw = 0;
  double _rawVel = 0; // raw 对时间的导数（1/秒）
  double _lastTime = 0;
  bool _primed = false;

  // ── 当前 leg（一段从 rawStart 走到 rawTarget 的运动）──
  bool _legLive = false;
  bool _legEasing = true;
  double _legRawStart = 0;
  double _legRawTarget = 1;
  double _legValueStart = 0;
  double _legSlope0 = 0; // 本段起点的 dValue/dRaw

  // ── 手势（1:1 跟手，grab-anchor 模型：首帧落回采样点，零跳变）──
  bool _inGesture = false;
  double _grabRaw = 0;
  double _grabValue = 0;

  /// 当前视觉进度（0 = 完全在屏外，1 = 完全就位）。
  double get value => _value;

  /// 重置回「整步起点」的静止状态（raw = 0、value = 0，无进行中的 leg）。
  ///
  /// 框架在每条路由**入场的第一帧**会把路由置 offstage，并把 `animation`
  /// 换成 `kAlwaysCompleteAnimation`（value = 1.0，供 HeroController 测量
  /// Hero 终点位置，见 `ModalRoute.offstage` 文档与 heroes.dart 的
  /// `toRoute.offstage = toRoute.animation!.value == 0.0`）。这一帧子树不绘制，
  /// 但若让状态机在此采样，就会被播种到「已落位」（value=1），之后真实动画
  /// 从 0 起步 —— 状态机整条轨迹全乱：入场页起手一段几乎不动，被覆盖层
  /// 却在正常视差，两层错位、中间漏出黑边。
  /// 正确姿势是**跳过该帧**并调用本方法把状态重置回起点，让真实动画的
  /// 第一个采样从 raw=0 的整步 leg 起跑（烘焙曲线整段生效，与 miuix-nav
  /// 「几何是同一个 d 的纯函数」一致）。pop 没有 offstage 帧，不受影响。
  void reset() {
    _value = 0;
    _raw = 0;
    _rawVel = 0;
    _legM0 = 0;
    _legSlope0 = 0;
    _legLive = false;
    _inGesture = false;
    _primed = true;
    _lastTime = _now(null);
  }

  /// 当前视觉速度（每秒的进度）。
  double get velocity => _slopeAt(_raw) * _rawVel;

  double _now(double? nowSeconds) {
    if (nowSeconds != null) return nowSeconds;
    final watch = stopwatch ?? (_fallbackWatch ??= Stopwatch()..start());
    return watch.elapsedMicroseconds / 1e6;
  }

  /// 喂入一帧 raw，返回视觉进度。
  ///
  /// [fingerDriven] 为 true 表示 raw 正被手指逐帧 seek（预测式返回拖动中），
  /// 此时退化成 1:1 跟手；松手后传 false，从落点带速度接回停靠曲线。
  /// [nowSeconds] 是单调时钟（秒），不传就用 [stopwatch]。
  double sample(double raw, {bool fingerDriven = false, double? nowSeconds}) {
    final now = _now(nowSeconds);
    final dt = _primed ? now - _lastTime : 0.0;
    final draw = _primed ? raw - _raw : 0.0;
    // 交接要用**打断前**的 raw 速度（惯性往哪边带就靠它），必须赶在
    // 下面覆盖 _rawVel 之前抓住。
    final rawVelBefore = _rawVel;
    // raw 速度做数值微分；帧间隔异常（0 或超大）时沿用上一帧的值，
    // 免得建树那一帧把速度算成 0 或爆炸。
    if (dt > 1e-6 && dt < 0.5) _rawVel = draw / dt;

    if (!_primed) {
      // 首帧：用曲线的「理想位置」播种，路由中途建树时不会从 0 猛跳。
      _primed = true;
      _raw = raw;
      _value = _curve.transform(raw);
      _legSlope0 = _curve.derivative(raw);
      _lastTime = now;
      return _value;
    }

    if (fingerDriven) {
      if (!_inGesture) {
        // grab-anchor：首帧落回采样点，位置零跳变；斜率固定 1（1:1 跟手）。
        _inGesture = true;
        _grabRaw = _raw;
        _grabValue = _value;
        _legLive = false;
      }
      _value = _grabValue + (raw - _grabRaw);
      _legSlope0 = 1.0;
    } else {
      if (_inGesture) {
        // 松手：从落点带速度接回停靠曲线。
        _inGesture = false;
        _legLive = false;
      }
      final dir = draw == 0 ? 0.0 : (draw > 0 ? 1.0 : -1.0);
      if (dir != 0 && (!_legLive || dir != _legDir)) {
        // 从**上一帧**的位置起跳：运动发生在两帧之间，锚在当前帧会让整段
        // 慢一帧（首帧算出来恒等于起点）。
        _startLeg(_raw, rawVelBefore);
      }
      if (_legLive) _value = _legValueAt(raw);
    }

    _raw = raw;
    _lastTime = now;
    return _value;
  }

  double get _legDir => _legRawTarget > _legRawStart ? 1.0 : -1.0;

  /// 当前 leg 的 s 空间初斜率（= 初速度 × 本段时长）。
  double _legM0 = 0;

  /// 开一段新 leg，把当前的位置/速度交接过去（首导数连续）。
  ///
  /// [rawStart] 是**上一帧**的 raw（运动发生在两帧之间，从那里起跳）；
  /// [rawVelBefore] 是**打断前**的 raw 速度 —— 惯性往哪边带由它决定。
  /// （不能用当前帧的 rawVel：那已经是反向之后的速度，符号正好是反的。）
  void _startLeg(double rawStart, double rawVelBefore) {
    // 先取旧 leg 在此刻的 dValue/dRaw —— 下面会把 leg 状态整个换掉。
    final slope0 = _slopeAt(rawStart);
    final target = _rawVel >= 0 ? 1.0 : 0.0;
    final span = target - rawStart; // 带符号：本段在 raw 轴上的位移
    final visualVel = slope0 * rawVelBefore;

    // 已经在目标上（span == 0）：直接落位，别建段，免得后面除零。
    if (span == 0) {
      _legLive = false;
      _value = target;
      _legSlope0 = 0;
      _legM0 = 0;
      return;
    }

    _legLive = true;
    _legRawStart = rawStart;
    _legRawTarget = target;
    _legValueStart = _value;

    // 上游 usesProgrammaticCurve：静止起步 + 整步才走那条烘焙曲线。
    final distance = (target - _value).abs();
    if (visualVel.abs() < 1e-9 && distance >= 0.999) {
      _legEasing = true;
      _legM0 = 0;
      _legSlope0 = 0;
      return;
    }

    // 带初速度的落点曲线：m₀ = 初速度 × 本段时长。
    // 本段时长 = |Δraw| × stepSeconds（收尾动画恒以 1/stepSeconds 走 raw），
    // 但初速度要按**交接前那一刻**的手指/仿真速度算，所以是
    // slope0 × rawVel，而不是 slope0 × |rawVel| —— 符号关系到「惯性往哪边带」。
    _legEasing = false;
    var m0 = visualVel * span.abs() * stepSeconds;
    // 无过冲夹制（clampOvershoot）：只砍掉「只可能变成越过目标的回弹」的那
    // 部分速度，慢速释放仍然全速交接，位置/速度都不跳。
    final d = _legValueStart - target;
    if (d > 0) {
      m0 = math.max(m0, -3 * d);
    } else if (d < 0) {
      m0 = math.min(m0, -3 * d);
    } else {
      m0 = 0;
    }
    _legM0 = m0;
    _legSlope0 = m0 / span;
  }

  double get _legSpan => _legRawTarget - _legRawStart;

  double _legValueAt(double raw) {
    final s = ((raw - _legRawStart) / _legSpan).clamp(0.0, 1.0);
    final target = _legRawTarget;
    if (_legEasing) {
      return _legValueStart + (target - _legValueStart) * _curve.transform(s);
    }
    final s2 = s * s;
    final s3 = s2 * s;
    return _legValueStart * (2 * s3 - 3 * s2 + 1) +
        _legM0 * (s3 - 2 * s2 + s) +
        target * (-2 * s3 + 3 * s2);
  }

  /// 当前 leg 在 raw 处的 dValue/dRaw（打断交接时用它算速度）。
  double _slopeAt(double raw) {
    if (!_legLive) return _legSlope0;
    final s = ((raw - _legRawStart) / _legSpan).clamp(0.0, 1.0);
    final target = _legRawTarget;
    double dValueDs;
    if (_legEasing) {
      dValueDs = (target - _legValueStart) * _curve.derivative(s);
    } else {
      final s2 = s * s;
      dValueDs =
          _legValueStart * (6 * s2 - 6 * s) +
          _legM0 * (3 * s2 - 4 * s + 1) +
          target * (-6 * s2 + 6 * s);
    }
    return _legSpan == 0 ? 0.0 : dValueDs / _legSpan;
  }
}

class _IosPushPageTransition extends StatefulWidget {
  const _IosPushPageTransition({
    required this.route,
    required this.animation,
    required this.secondaryAnimation,
    required this.cornerRadius,
    required this.dimOpacity,
    required this.underneathFraction,
    required this.coveredAlphaDrop,
    required this.stepSeconds,
    required this.popGestureInProgress,
    required this.child,
  });

  final PageRoute<dynamic>? route;

  /// 本路由自身的入场动画（push 时 0 → 1，pop 时 1 → 0）。
  final Animation<double> animation;

  /// 上方路由压栈时驱动本页退场（被覆盖时 0 → 1）。
  final Animation<double> secondaryAnimation;

  final double cornerRadius;
  final double dimOpacity;
  final double underneathFraction;
  final double coveredAlphaDrop;
  final double stepSeconds;

  /// 是否正处于预测式返回跟手阶段。
  final bool popGestureInProgress;

  final Widget child;

  @override
  State<_IosPushPageTransition> createState() => _IosPushPageTransitionState();
}

class _IosPushPageTransitionState extends State<_IosPushPageTransition>
    with SingleTickerProviderStateMixin {
  /// 页面子树锚点：压暗层挂载 / 卸载、退场分支切换等结构变化时，
  /// 通过 GlobalKey 复用同一 Element，保住页面 State 不丢。
  final GlobalKey _pageKey = GlobalKey();

  /// 入场位移的驱动（本路由的 animation）。
  late final MiuixNavSettleDriver _enterDriver = MiuixNavSettleDriver(
    stepSeconds: widget.stepSeconds,
    curve: _transitionCurve,
  );

  /// 被覆盖层的驱动（secondaryAnimation）。
  ///
  /// 单独一份而不是和入场共用：没有上层路由时 secondaryAnimation 恒为 0，
  /// 两条轨迹并不相同。上层压栈时两者看的是同一个控制器，算出来的进度
  /// 天然一致（参考实现里它们本来就是同一个 `animatedTop`）。
  late final MiuixNavSettleDriver _coverDriver = MiuixNavSettleDriver(
    stepSeconds: widget.stepSeconds,
    curve: _transitionCurve,
  );

  /// 圆角收起动画：1 = 设定圆角，0 = 直角。
  late final AnimationController _cornerCtrl;

  /// 收角前的等待计时器（[kIosPushCornerHold] 为 0 时用不到）。
  Timer? _cornerTimer;

  AnimationStatus? _lastStatus;

  @override
  void initState() {
    super.initState();
    _cornerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _cornerCollapseMs),
      value: 1.0,
    );
    widget.animation.addStatusListener(_onAnimationStatus);
    _applyStatus(widget.animation.status);
  }

  @override
  void didUpdateWidget(covariant _IosPushPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onAnimationStatus);
      widget.animation.addStatusListener(_onAnimationStatus);
      _lastStatus = null;
      _applyStatus(widget.animation.status);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onAnimationStatus);
    _cornerTimer?.cancel();
    _cornerCtrl.dispose();
    super.dispose();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == _lastStatus) return;
    _lastStatus = status;
    _applyStatus(status);
  }

  /// 转场状态 → 圆角保持策略。
  ///   · forward / reverse（正在滑）：立刻保持圆角；
  ///   · completed（已就位）：按 [kIosPushCornerHold] 等待后平滑收直；
  ///   · dismissed（页面已离场不可见）：复位，准备下一次入场。
  void _applyStatus(AnimationStatus status) {
    _cornerTimer?.cancel();
    switch (status) {
      case AnimationStatus.forward:
        // push 起手：页面还在屏外，直接给足圆角，无跳变
        _cornerCtrl.value = 1.0;
        break;
      case AnimationStatus.reverse:
        // pop 起手：页面此刻可能已是直角，平滑恢复成圆角卡片再滑出去
        if (_cornerCtrl.value < 1.0) {
          _cornerCtrl.animateTo(
            1.0,
            duration: const Duration(milliseconds: _cornerRestoreMs),
            curve: Curves.easeOutCubic,
          );
        }
        break;
      case AnimationStatus.completed:
        // 转场一结束就收角（kIosPushCornerHold = 0）；留了等待时长的话
        // 才排延时器。收角本身是 [_cornerCollapseMs] 的渐变。
        if (kIosPushCornerHold <= Duration.zero) {
          _collapseCorner();
        } else {
          _cornerTimer = Timer(kIosPushCornerHold, () {
            if (mounted) _collapseCorner();
          });
        }
        break;
      case AnimationStatus.dismissed:
        _cornerCtrl.value = 1.0;
        break;
    }
  }

  /// 把圆角从设定值平滑收到直角。
  void _collapseCorner() {
    _cornerCtrl.animateTo(
      0.0,
      duration: const Duration(milliseconds: _cornerCollapseMs),
      curve: Curves.easeInOutCubicEmphasized,
    );
  }

  /// 此刻 raw 是不是正被手指逐帧 seek（预测式返回拖动中）。
  ///
  /// 判据是「有手势在跑 **且** 控制器没在跑仿真」：拖动时框架是直接写
  /// `controller.value` 的（`isAnimating` 为 false），松手后的收尾动画则
  /// 是 `reverse(from:)` / `forward()`（`isAnimating` 为 true）。
  /// 只看手势标志不够 —— 它直到收尾动画跑完才翻 false，那段时间应该走
  /// 停靠曲线而不是继续 1:1。
  bool _fingerDriven(Animation<double> source) {
    if (!widget.popGestureInProgress &&
        !(widget.route?.navigator?.userGestureInProgress ?? false)) {
      return false;
    }
    Animation<double>? anim = source;
    if (anim is ProxyAnimation) anim = anim.parent;
    final ctrl = anim is AnimationController ? anim : null;
    return ctrl != null && !ctrl.isAnimating;
  }

  @override
  Widget build(BuildContext context) {
    // ── 入场首帧的 offstage 预热帧：不采样、不施加变换 ──
    // 框架每条路由入场的第一帧会把路由置 offstage 并把 animation 顶成
    // kAlwaysCompleteAnimation（value=1.0，Hero 测量用），这一帧子树不绘制。
    // 驱动器若在此采样会被播种到「已落位」，之后真实动画从 0 起步、
    // 状态机整条轨迹全乱（入场页起手不动 + 与被覆盖层错位漏黑边）。
    // 所以这里把两个驱动器重置回整步起点，几何按恒等处理（反正不可见），
    // 让真实动画的第一帧从 raw=0 的整步 leg 起跑。详见 [MiuixNavSettleDriver.reset]。
    final bool warmUp = widget.route?.offstage ?? false;
    if (warmUp) {
      _enterDriver.reset();
      _coverDriver.reset();
    }

    // ── 新页面入场：全宽从尾侧滑入 + 圆角渐变归零 ──
    // 位移与圆角合进同一个 AnimatedBuilder：少一层 widget、少一次监听。
    final Widget entering = AnimatedBuilder(
      animation: Listenable.merge([widget.animation, _cornerCtrl]),
      child: widget.child,
      builder: (context, child) {
        final raw = widget.animation.value.clamp(0.0, 1.0).toDouble();
        final t = warmUp
            ? 1.0
            : _enterDriver.sample(
                raw,
                fingerDriven: _fingerDriven(widget.animation),
              );
        // 圆角：**全程恒为设定值**，只由 _cornerCtrl 决定（落位静止满
        // kIosPushCornerHold 后才 1 → 0 平滑收直）。
        final radius = widget.cornerRadius * _cornerCtrl.value;
        return FractionalTranslation(
          translation: Offset(1 - t, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            // 圆角归零时降级为 hardEdge：矩形裁剪无需抗锯齿，省掉一层
            // 抗锯齿裁剪。只改 clipBehavior，不切换子树结构，不重建 State。
            clipBehavior: radius > 0.001 ? Clip.antiAlias : Clip.hardEdge,
            child: child,
          ),
        );
      },
    );

    // ── 本页自带旧页面退场动画（IosBackdropScale 景深缩放）→ 让位 ──
    final route = widget.route;
    final bool hasCustomSecondary =
        route != null &&
        CustomSecondaryTransitionRoutes.contains(route) &&
        IosPushPageTransitionsBuilder.heroTransitionBlurEnabled;
    if (hasCustomSecondary) {
      return KeyedSubtree(key: _pageKey, child: entering);
    }

    // ── 本页作为旧页面被覆盖：视差 + alpha 衰减 + 全屏压暗 ──
    // 三层各走各的，跟 miuix-nav 一致：
    //   · 视差 / alpha 属于 covered 处理，跟着覆盖进度走；
    //   · 压暗是**正交的 effects 层**（NavDisplayEffects），全屏、静止、
    //     压在最上层之下，所以它不套在 FractionalTranslation 里 ——
    //     参考实现的 scrim「spans the whole entering surface」，连露出的
    //     背景一起压暗，而不是跟着旧页面一起滑走。
    return AnimatedBuilder(
      animation: widget.secondaryAnimation,
      child: KeyedSubtree(key: _pageKey, child: entering),
      builder: (context, child) {
        final raw = widget.secondaryAnimation.value.clamp(0.0, 1.0).toDouble();
        final d = warmUp
            ? 0.0
            : _coverDriver.sample(
                raw,
                fingerDriven: _fingerDriven(widget.secondaryAnimation),
              );
        // alpha 衰减：d == 0（页面正常展示）时不挂 Opacity 层，
        // 免得静止期白白付一次 saveLayer。
        final alpha = 1 - widget.coveredAlphaDrop * d;
        final Widget page = alpha < 0.999
            ? Opacity(opacity: alpha, child: child!)
            : child!;
        return Stack(
          children: <Widget>[
            FractionalTranslation(
              translation: Offset(-widget.underneathFraction * d, 0),
              child: page,
            ),
            if (widget.dimOpacity * d > 0.001)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Color.fromRGBO(0, 0, 0, widget.dimOpacity * d),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

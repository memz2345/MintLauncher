// lib/widgets/predictive_back_detector.dart
//
// Android 14+ 预测式返回（Predictive Back）手势探测器，供各自定义转场共用。
//
// 为什么需要它：
//   系统侧滑返回的进度只经 `SystemChannels.backGesture` 送到 Dart 层，
//   由 `WidgetsBindingObserver` 分发给「第一个返回 true 的观察者」。
//   Flutter 自带的 `PredictiveBackPageTransitionsBuilder` 只服务
//   `PageTransitionsTheme` 那条路径；本项目里自带 transitionsBuilder 的
//   自定义路由（FrostedHeroRoute）不经主题，得自己挂探测器。
//
// 它做了什么：
//   把系统手势进度转成当前路由控制器的进度（`TransitionRoute` 已实现
//   `PredictiveBackRoute`），剩下的全交给框架：
//     - 下层页面的 secondaryAnimation 回弹 ← navigator.didStartUserGesture()
//     - Hero 飞行跟手 ← HeroController.didStartUserGesture 会立刻启动
//       isUserGestureTransition 飞行，并在手势期间抑制飞行结束
//     - commit 后真正 pop / cancel 后回位 ← TransitionRoute._handleDragEnd
//       ⚠️ commit 分支有个框架坑（`reverse(from: upperBound)`，会跳回全屏
//          重放整段退场），由 handleCommitBackGesture 里的补正兜住，
//          详见该方法与 [controllerOf] 的注释。
//
// 调用方只需要在 `popGestureInProgress` 为 true 时把自家曲线退化成线性：
// 控制器已被手势逐帧 seek，再套缓动曲线会让起手一大段几乎不动，跟手感明显变差。
//
// 页面用 PopScope(canPop:false) 拦返回时怎么办：
//   canPop:false 会让 `ModalRoute.popGestureEnabled` 变 false，本探测器据此
//   拒绝接管手势 —— 这对「此刻不该返回」的页面（全屏播放中要先退全屏）是对的，
//   但对「返回前必须先落地一次重建」的整页 Hero 页面（视频/番剧/专栏页，
//   见 zoom_hero_exit.dart）就成了误伤：它们稳态下 canPop 恒为 false，
//   于是永远没有跟手返回。这类页面通过 [PredictiveBackHook] 把两件事分开声明。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;

/// 路由级「预测式返回」挂钩：让 `PopScope(canPop: false)` 的页面也能跟手返回。
///
/// 页面在 `didChangeDependencies` 里 [register]、`dispose` 里 [unregister]
/// （注册/注销的生命周期写法可参考 `widgets/ios_backdrop.dart` 的
/// `IosBackdropScale`；路由弹栈后自动注销，无泄漏）。
///
/// ⚠️ [allow] 必须覆盖 PopScope 的每一条否决理由：手势 commit 走的是
/// `TransitionRoute._handleDragEnd` → `navigator.pop()`，它**绕过** canPop，
/// PopScope 再也拦不住（`onPopInvokedWithResult` 只会收到 didPop:true）。
/// 全屏要先退全屏、宽屏评论面板的嵌套 Navigator 还能返回……这些都得在
/// [allow] 里自己判掉，否则一次拖动就会越过它们直接弹栈。
class PredictiveBackHook {
  const PredictiveBackHook({
    required this.allow,
    required this.prepare,
    required this.restore,
  });

  /// 此刻能不能跟手返回（不含 canPop —— 那一条正是本挂钩要绕过的）。
  final bool Function() allow;

  /// 手势开始、Hero 飞行启动**之前**落地准备。
  ///
  /// 探测器本来就延后一帧才启动飞行（详见下面 `handleStartBackGesture`），
  /// 这里触发的重建会和 Hero 曲线线性化搭同一班车落地，帧尾 `HeroController`
  /// 扫到的就是准备好的那棵树。
  final VoidCallback prepare;

  /// 手势**取消**后复原（commit 时不调用：页面马上就要出栈了）。
  ///
  /// 由探测器在收尾动画跑完、Hero 飞行把 child 从 placeholder 换回来之后
  /// 再延一帧调用，实现里不必自己等时机，但要自己判 `mounted`。
  final VoidCallback restore;

  static final Map<ModalRoute<dynamic>, PredictiveBackHook> _hooks =
      <ModalRoute<dynamic>, PredictiveBackHook>{};

  static void register(ModalRoute<dynamic> route, PredictiveBackHook hook) =>
      _hooks[route] = hook;

  static void unregister(ModalRoute<dynamic> route) => _hooks.remove(route);

  static PredictiveBackHook? of(ModalRoute<dynamic> route) => _hooks[route];
}

class PredictiveBackGestureDetector extends StatefulWidget {
  const PredictiveBackGestureDetector({
    super.key,
    required this.route,
    required this.builder,
  });

  /// 要接管的路由。
  ///
  /// 用 [ModalRoute] 而不是 `PageRoute`：自定义转场里通过
  /// `ModalRoute.of(context)` 只能拿到 `ModalRoute<dynamic>`。
  /// 它已经是 `TransitionRoute` 子类，天然实现 `PredictiveBackRoute`
  /// （handleStartBackGesture 等），也带 `popGestureInProgress`。
  final ModalRoute<dynamic> route;

  /// [popGestureInProgress] 为 true 时应切到「跟手（线性）」分支。
  final Widget Function(BuildContext context, bool popGestureInProgress)
  builder;

  /// 取出驱动 [route] 转场的 [AnimationController]。
  ///
  /// `TransitionRoute.animation` 拿到的**不是**控制器本身，而是它的
  /// 「视图」（实测 `AnimationController.toString()` 以 `➩ProxyAnimation`
  /// 收尾，`identical(route.animation, route.controller)` 为 false，
  /// 而 `(route.animation as ProxyAnimation).parent` 才是控制器）。
  /// 视图只有 getter，改值必须用控制器，所以这里拆一层。
  ///
  /// 不用 `route.controller`：那是框架的 `@protected` 成员，仓外访问会触
  /// 发 `invalid_use_of_protected_member`。
  ///
  /// 底部菜单（widgets/predictive_back_sheet.dart）补 commit 进度时也用这个，
  /// 别再复制一份。
  static AnimationController? controllerOf(ModalRoute<dynamic> route) {
    Animation<double>? animation = route.animation;
    if (animation is ProxyAnimation) animation = animation.parent;
    return animation is AnimationController ? animation : null;
  }

  @override
  State<PredictiveBackGestureDetector> createState() =>
      _PredictiveBackGestureDetectorState();
}

class _PredictiveBackGestureDetectorState
    extends State<PredictiveBackGestureDetector>
    with WidgetsBindingObserver {
  /// 只有「最顶层 + 允许手势 pop」的路由才接管本次手势；栈内下层路由的
  /// 探测器一律返回 false。
  ///
  /// （分发语义更正：`WidgetsBinding._handleStartBackGesture` 是把**所有**
  ///   返回 true 的观察者都收进 `_backGestureObservers`、之后逐个转发
  ///   update/commit/cancel，并不是「第一个返回 true 的独占整个手势」。
  ///   实际只有 isCurrent 的那条路由会返回 true，效果等同。）
  ///
  /// `popGestureEnabled` 为 false 时再问一次 [PredictiveBackHook]：
  /// canPop:false 的整页 Hero 页面靠它拿到跟手返回（见文件头）。
  bool get _enabled =>
      widget.route.isCurrent &&
      (widget.route.popGestureEnabled || _hookAllows());

  PredictiveBackHook? get _hook => PredictiveBackHook.of(widget.route);

  /// 挂钩旁路：把 `popGestureEnabled` 里**被绕过的那一条之外**的检查补齐。
  ///
  /// 跳过的只有 `hasScopedWillPopCallback || popDisposition == doNotPop`
  /// —— 那正是 canPop:false，也正是本挂钩存在的意义。其余（首条路由、
  /// 内部处理、转场尚未结束、已有手势在跑）一条都不能少。
  bool _hookAllows() {
    final hook = _hook;
    if (hook == null) return false;
    final ModalRoute<dynamic> route = widget.route;
    if (route.isFirst) return false;
    if (route.willHandlePopInternally) return false;
    // animation 为 null（路由尚未安装控制器）时一律不接管
    if (route.animation?.isCompleted != true) return false;
    if (route.popGestureInProgress) return false;
    return hook.allow();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _removeRestoreListener();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 最新一次手势进度换算出的路由进度（控制器 1 = 页面完全在屏）。
  double _latestProgress = 0;

  /// 已经收到 start、但还没真正把飞行交给框架的那一帧。
  bool _pendingStart = false;

  /// 帧尾是否**真的**把 start 转发给了路由控制器。
  ///
  /// 没转发就不能转发 commit / cancel：`TransitionRoute._handleDragEnd` 收尾时
  /// 会调 `navigator.didStopUserGesture()`，而它 `assert(_userGesturesInProgress > 0)`
  /// —— 缺了配对的 `didStartUserGesture()`，debug 直接断言，release 下计数变负，
  /// 此后 `didStartUserGesture` 的 `== 1` 分支永远进不去，全 app 的跟手 Hero
  /// 飞行都不再启动（预测式返回静默失效）。
  bool _routeGestureStarted = false;

  /// 已经调过 `hook.prepare()`、还欠一次 `hook.restore()`。
  bool _prepared = false;

  /// 复原已经在排队（防重入：取消后收尾期间又收到事件时不重复排）。
  bool _restorePending = false;

  ValueNotifier<bool>? _gestureNotifier;
  VoidCallback? _restoreListener;

  /// 跟手进行中：要么还在等延迟启动的那一帧，要么框架已接管
  /// （`popGestureInProgress` 直到 commit/cancel 的收尾动画跑完才翻 false）。
  bool get _active => _pendingStart || widget.route.popGestureInProgress;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 实体 / 虚拟返回键不跟手，交回系统走普通 pop
    if (!_enabled || backEvent.isButtonEvent) return false;
    // 控制器 1 = 页面完全在屏，系统 progress 0 = 刚起手，故取反
    _latestProgress = 1 - backEvent.progress;

    // 飞行启动前先把页面准备好（整页 Hero 重新挂上、播放器停止输出画面）。
    // 必须赶在帧尾之前：HeroController 在 didStartUserGesture 里**同步**扫
    // from/to Hero，扫到的得是已经挂好 Hero 的那棵树。
    _hook?.prepare();
    _prepared = true;

    if (mounted) setState(() => _pendingStart = true);

    // 故意延后一帧再启动飞行：HeroController 在 didStartUserGesture 里
    // **同步**启动飞行，并从 Hero widget 上读走 curve 缓存下来 —— 同帧内
    // 换曲线根本来不及（实测探针曲线打的仍是旧的那条）。先让本帧的重建把
    // Hero 换成线性曲线，帧尾再启动，飞行才会用上线性。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.route.isCurrent) {
        // 用最新进度启动，避免延迟的这一帧把手势回退到起点
        widget.route.handleStartBackGesture(progress: _latestProgress);
        _routeGestureStarted = true;
      }
      setState(() => _pendingStart = false);
    });
    return true;
  }

  // 以下三个只有「start 时返回 true 的接管者」才会收到，不必再判断 enabled
  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    // 飞行还没启动时也照常写控制器：TransitionRoute 只检查 isCurrent，
    // 提前写入的值会被帧尾的 handleStartBackGesture 沿用（_latestProgress）。
    _latestProgress = 1 - backEvent.progress;
    widget.route.handleUpdateBackGestureProgress(progress: _latestProgress);
  }

  @override
  void handleCommitBackGesture() {
    _cancelPendingRestore();
    // 页面即将出栈，欠的那次复原直接销账
    _prepared = false;
    if (!_routeGestureStarted) return;
    _routeGestureStarted = false;

    final ModalRoute<dynamic> route = widget.route;
    // 先记下用户实际拖到的进度：框架的 commit 收尾马上会把它抹掉。
    final AnimationController? controller =
        PredictiveBackGestureDetector.controllerOf(route);
    final double resumeFrom = controller?.value ?? _latestProgress;

    route.handleCommitBackGesture();

    // ⚠️ 框架坑：`TransitionRoute._handleDragEnd` 的 commit 分支（Flutter 3.44
    //    widgets/routes.dart，由 PR #154718「shared element transition for
    //    predictive back」引入）在 `navigator.pop()` 之后还补了一句
    //
    //        _controller.reverse(from: _controller.upperBound);
    //
    //    也就是**先把控制器拉回 1.0 再反向**。表现是「拖到一半松手 → 页面
    //    弹回满屏 → 再整段滑出」：退场动画从最初开始重放，跟用户已经推进的
    //    进度彻底脱节（cancel 分支只用 forward()，从当前值继续，没这毛病）。
    //
    //    这里在同一帧（尚未渲染，用户看不到中间态）把控制器拨回拖到的位置
    //    再继续反向 —— 视觉上从落点续滑到出屏，与 Android 原生预测式返回
    //    一致。控制器本来就停在 1.0（没拖动 / 已拖到满进度）时不动，保持
    //    框架原行为；将来框架自己修好了，这里也退化为无副作用的空操作。
    if (controller != null &&
        controller.isAnimating &&
        resumeFrom > 0 &&
        resumeFrom < 1) {
      controller.reverse(from: resumeFrom);
    }
  }

  @override
  void handleCancelBackGesture() {
    if (_routeGestureStarted) {
      _routeGestureStarted = false;
      widget.route.handleCancelBackGesture();
    }
    if (_prepared) _scheduleRestore();
  }

  /// 取消后复原的时机：等 `popGestureInProgress` 落回 false（收尾动画跑完、
  /// `_HeroFlight` 已经 `endFlight` 把 child 从 placeholder 换回来）**再延一帧**。
  ///
  /// 不能等路由 animation 变 completed：`_handleDragEnd(animateForward: true)`
  /// 在控制器本来就停在 1.0 时会跳过 `forward()` 并同步 `didStopUserGesture()`，
  /// 那个 completed 永远等不到，页面就永久卡在「Hero 还挂着」的准备态。
  void _scheduleRestore() {
    if (_restorePending) return;
    _restorePending = true;

    final ValueNotifier<bool>? notifier =
        widget.route.navigator?.userGestureInProgressNotifier;
    if (notifier == null || !notifier.value) {
      _restoreAfterFrame();
      return;
    }
    // 注册得比 `_HeroFlight` 的同类监听晚（它是在拖动期间挂上去的），
    // 所以 notifier 一响，飞行收尾先跑、我们后跑，顺序正好。
    late final VoidCallback listener;
    listener = () {
      if (notifier.value) return; // 只认落回 false 的那一次
      _removeRestoreListener();
      _restoreAfterFrame();
    };
    _gestureNotifier = notifier;
    _restoreListener = listener;
    notifier.addListener(listener);
  }

  void _restoreAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restorePending = false;
      if (!mounted || !_prepared) return;
      _prepared = false;
      _hook?.restore();
    });
  }

  void _cancelPendingRestore() {
    _removeRestoreListener();
    _restorePending = false;
  }

  void _removeRestoreListener() {
    final notifier = _gestureNotifier;
    final listener = _restoreListener;
    if (notifier != null && listener != null) {
      notifier.removeListener(listener);
    }
    _gestureNotifier = null;
    _restoreListener = null;
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _active);
}

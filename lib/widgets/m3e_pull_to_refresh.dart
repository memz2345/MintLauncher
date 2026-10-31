import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../src/loading_indicator_m3e.dart';

/// M3E 下拉刷新容器。
///
/// 从 Compose Material3 `PullToRefresh.kt` 的 `PullToRefreshDefaults.LoadingIndicator`
/// 那条路径移植（InstallerX `ApplyPage.kt` 用的就是它）：常量、位移公式、
/// 过阈值的张力曲线、以及「拖拽时定态形变 + 刷新时不定态」的切换都照原实现。
/// 手势采集部分 Flutter 没有 NestedScrollConnection 可消费滚动增量，
/// 所以沿用 SDK `RefreshIndicator` 那套 NotificationListener 观测方案。
class M3EPullToRefresh extends StatefulWidget {
  const M3EPullToRefresh({
    super.key,
    required this.isRefreshing,
    required this.onRefresh,
    required this.child,
    this.threshold = _kPositionalThreshold,
    this.edgeOffset = 0.0,
    this.color,
    this.containerColor,
    this.enabled = true,
    this.notificationPredicate = _defaultNotificationPredicate,
    this.semanticsLabel,
  });

  /// 是否正在刷新。由调用方托管：松手过阈值时本组件回调 [onRefresh]，
  /// 调用方置 true 开始干活、干完置 false，指示器随之收起。
  /// 若调用方不托管（恒为 false），则 [onRefresh] 返回的 Future 完成时自动收起。
  final bool isRefreshing;

  final Future<void> Function() onRefresh;

  final Widget child;

  /// 触发刷新的位移阈值（逻辑像素）。对应 `PullToRefreshDefaults.PositionalThreshold`。
  final double threshold;

  /// 指示器槽距容器顶部的偏移。页面有常驻顶栏时传顶栏高度，
  /// 让指示器从顶栏下方滑出（InstallerX 里是 `padding(top = calculateTopPadding())`）。
  final double edgeOffset;

  final Color? color;
  final Color? containerColor;

  final bool enabled;

  final bool Function(ScrollNotification) notificationPredicate;

  final String? semanticsLabel;

  @override
  State<M3EPullToRefresh> createState() => _M3EPullToRefreshState();
}

/// 对应 `PullToRefreshDefaults.PositionalThreshold` / `IndicatorMaxDistance`。
const double _kPositionalThreshold = 80.0;
const double _kIndicatorMaxDistance = 80.0;

/// 对应 Compose 私有常量 `DragMultiplier`：手指位移先折半再参与判定与定位。
const double _kDragMultiplier = 0.5;

/// 对应 `LoaderIndicatorWidth/Height`（= `LoadingIndicatorDefaults.ContainerWidth/Height`）。
const double _kIndicatorSize = 48.0;

/// 收起 / 吸附到阈值用的弹簧。Compose `Animatable.animateTo` 的默认 `spring()`
/// 是 `DampingRatioNoBouncy`(1.0) + `StiffnessMedium`(1500)，即临界阻尼。
final SpringDescription _kSpring = SpringDescription.withDampingRatio(
  ratio: 1.0,
  stiffness: 1500.0,
  mass: 1.0,
);

bool _defaultNotificationPredicate(ScrollNotification n) => n.depth == 0;

enum _PullStatus {
  /// 没在下拉，也没在刷新。
  idle,

  /// 手指还按着，位移跟着走。
  drag,

  /// 已触发刷新，指示器停在阈值处转不定态。
  refresh,
}

class _M3EPullToRefreshState extends State<M3EPullToRefresh>
    with SingleTickerProviderStateMixin {
  /// `PullToRefreshState.distanceFraction`：0 = 隐藏，1 = 到阈值，最大 2.0。
  /// 用 unbounded 控制器承载，既能被拖拽直接写值，也能被弹簧动画驱动。
  late final AnimationController _fraction;

  /// 本轮拖拽累计的原始位移；null = 没在拖。
  double? _distancePulled;

  _PullStatus _status = _PullStatus.idle;

  @override
  void initState() {
    super.initState();
    _fraction = AnimationController.unbounded(vsync: this);
    if (widget.isRefreshing) {
      _status = _PullStatus.refresh;
      _fraction.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant M3EPullToRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRefreshing == widget.isRefreshing) return;
    if (widget.isRefreshing) {
      if (_status != _PullStatus.refresh) {
        setState(() => _status = _PullStatus.refresh);
        _animateFractionTo(1.0);
      }
    } else if (_status == _PullStatus.refresh) {
      _finishRefresh();
    }
  }

  @override
  void dispose() {
    _fraction.dispose();
    super.dispose();
  }

  // ---- Compose PullToRefreshModifierNode 的位移数学 ----

  /// `calculateVerticalOffset()`：阈值内线性，超过阈值后按张力曲线衰减，
  /// 最多再走一个阈值（`linearTension` 夹在 0..2 → 位移上限 2×threshold）。
  double _verticalOffsetFor(double distancePulled) {
    final adjusted = distancePulled * _kDragMultiplier;
    final threshold = widget.threshold;
    if (adjusted <= threshold) return adjusted;

    final overshootPercent = (adjusted / threshold).abs() - 1.0;
    final linearTension = overshootPercent.clamp(0.0, 2.0);
    final tensionPercent = linearTension - (linearTension * linearTension) / 4;
    return threshold + threshold * tensionPercent;
  }

  double _fractionFor(double distancePulled) =>
      _verticalOffsetFor(distancePulled) / widget.threshold;

  // ---- 手势采集（沿用 SDK RefreshIndicator 的 NotificationListener 方案） ----

  bool _shouldStart(ScrollNotification n) {
    final userDragged =
        (n is ScrollStartNotification && n.dragDetails != null) ||
        (n is ScrollUpdateNotification && n.dragDetails != null);
    if (!userDragged) return false;
    // 只认「竖直列表已经贴顶」这一种起点。
    final atTop =
        n.metrics.axisDirection == AxisDirection.down &&
        n.metrics.extentBefore == 0.0;
    return atTop && _status == _PullStatus.idle && _fraction.value == 0.0;
  }

  bool _handleScrollNotification(ScrollNotification n) {
    if (!widget.enabled || !widget.notificationPredicate(n)) return false;

    if (_shouldStart(n)) {
      _fraction.stop();
      setState(() {
        _distancePulled = 0.0;
        _status = _PullStatus.drag;
      });
      return false;
    }

    final pulled = _distancePulled;
    if (pulled == null) return false;

    if (n is ScrollUpdateNotification) {
      _accumulate(pulled, n.scrollDelta, n.metrics.axisDirection);
    } else if (n is OverscrollNotification) {
      _accumulate(pulled, n.overscroll, n.metrics.axisDirection);
    } else if (n is ScrollEndNotification) {
      _settle();
    }
    return false;
  }

  /// 贴顶下拉时 scrollDelta / overscroll 都是负值，取反后累加成正的位移。
  void _accumulate(double pulled, double? delta, AxisDirection direction) {
    if (delta == null || direction != AxisDirection.down) return;
    final next = math.max(0.0, pulled - delta);
    setState(() {
      _distancePulled = next;
      _fraction.value = _fractionFor(next);
    });
  }

  /// 抑制 Material 自己的拉伸光晕 /  glow，别跟本组件的指示器叠在一起。
  bool _handleIndicatorNotification(OverscrollIndicatorNotification n) {
    if (n.depth != 0 || !n.leading) return false;
    if (_status != _PullStatus.drag) return false;
    n.disallowIndicator();
    return true;
  }

  /// 松手结算：过了阈值就触发刷新并吸附到 1，否则弹回 0。
  void _settle() {
    final pulled = _distancePulled;
    if (pulled == null) return;
    _distancePulled = null;

    final armed = pulled * _kDragMultiplier > widget.threshold;
    if (armed && _status != _PullStatus.refresh) {
      setState(() => _status = _PullStatus.refresh);
      _animateFractionTo(1.0);
      _invokeRefresh();
      return;
    }
    setState(() => _status = _PullStatus.idle);
    _animateFractionTo(widget.isRefreshing ? 1.0 : 0.0);
  }

  void _invokeRefresh() {
    // 调用方托管 isRefreshing 时，收起由 didUpdateWidget 负责；
    // 这里兜「没人托管」的情况，免得指示器永久挂着。_finishRefresh 幂等，
    // 两条路径都触发也不会重复动画。
    widget.onRefresh().whenComplete(() {
      if (!mounted) return;
      if (!widget.isRefreshing && _status == _PullStatus.refresh) {
        _finishRefresh();
      }
    });
  }

  void _finishRefresh() {
    setState(() => _status = _PullStatus.idle);
    _animateFractionTo(0.0);
  }

  void _animateFractionTo(double target) {
    _fraction
        .animateWith(SpringSimulation(_kSpring, _fraction.value, target, 0.0))
        // 弹簧只收敛到容差内，_tick 不会吸附终点；不补这一下 fraction 会停在
        // 0.0004 之类的残值上，指示器卸不掉、下一次拖拽也会被 _shouldStart 挡掉。
        // TickerFuture 被取消时主 future 永不完成，所以不会写回过期目标。
        .then((_) {
          if (mounted) _fraction.value = target;
        });
  }

  // ---- 绘制 ----

  @override
  Widget build(BuildContext context) {
    final scrollable = NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: NotificationListener<OverscrollIndicatorNotification>(
        onNotification: _handleIndicatorNotification,
        child: widget.child,
      ),
    );

    return Stack(
      // 指示器会画到自己那个零高度槽之外，别让 Stack 裁掉。
      clipBehavior: Clip.none,
      children: [
        scrollable,
        Positioned(
          top: widget.edgeOffset,
          left: 0,
          right: 0,
          height: 0,
          child: AnimatedBuilder(
            animation: _fraction,
            builder: (context, _) => _buildIndicator(_fraction.value),
          ),
        ),
      ],
    );
  }

  Widget _buildIndicator(double fraction) {
    if (fraction <= 0.0 && _status != _PullStatus.refresh) {
      return const SizedBox.shrink();
    }

    final refreshing = _status == _PullStatus.refresh;
    // IndicatorBox 的 placeWithLayer：translationY = fraction * maxDistance - height，
    // 再裁掉顶边以上的部分，指示器就像从顶栏后面滑出来。
    final translationY = fraction * _kIndicatorMaxDistance - _kIndicatorSize;

    // Compose 那段 drawWithContent：越过阈值后整体继续逆时针转，
    // 从 fraction-1 起算，避免某些形状在切换瞬间看着跳一下。
    final overshootDegrees = !refreshing && fraction > 1.0
        ? -(fraction - 1.0) * 180.0
        : 0.0;

    return ClipRect(
      clipper: const _ClipBelowTopEdge(),
      child: OverflowBox(
        // 槽本身是 `Positioned(left:0, right:0, height:0)` —— 宽度是**紧约束**
        // （整页宽）。不放宽度，下面那个 SizedBox(48, 48) 的 48 会被紧约束吃掉：
        // SizedBox 变成「整页宽 × 48」，M3E 指示器拿到 size.width = 整页宽后
        // 按 `size.width * scaleFactor` 去缩放形状 —— 于是画出一坨跨屏的巨形
        // （实测就是这样，猎奇得很）。这里把宽高都放开，让指示器拿到它自己的
        // 48×48，再靠 alignment 居中。
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: 0,
        maxHeight: double.infinity,
        alignment: Alignment.topCenter,
        child: Transform.translate(
          offset: Offset(0, translationY),
          child: Transform.rotate(
            angle: overshootDegrees * (math.pi / 180.0),
            child: SizedBox(
              width: _kIndicatorSize,
              height: _kIndicatorSize,
              child: LoadingIndicatorM3E(
                variant: LoadingIndicatorM3EVariant.contained,
                // 拖拽阶段定态（形变跟着位移走），刷新中切回不定态。
                value: refreshing ? null : fraction.clamp(0.0, 1.0),
                color: widget.color,
                containerColor: widget.containerColor,
                semanticLabel: widget.semanticsLabel,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 只裁顶边以上，下方放开让指示器溢出可见。
/// 对应 Compose `clipRect(top = 0f, left/right = ±MAX, bottom = +MAX)`。
class _ClipBelowTopEdge extends CustomClipper<Rect> {
  const _ClipBelowTopEdge();

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(-512.0, 0.0, size.width + 512.0, 512.0);

  @override
  bool shouldReclip(_ClipBelowTopEdge oldClipper) => false;
}

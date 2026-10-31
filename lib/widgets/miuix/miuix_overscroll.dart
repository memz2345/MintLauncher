import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/widgets/mint_scroll_behavior.dart';

/// miuix 风格的越界（overscroll）行为。
///
/// Android 上 Material 的越界默认是 `StretchingOverscrollIndicator`：把整个
/// 视口**纵向拉伸**。miuix 不是拉伸，而是内容**整体位移**（`overScrollOutOfBound`
/// 里那个 `offset`），位移量走原版的立方阻尼曲线 `x - x² + x³/3`，松手用标准
/// 弹簧（dampingRatio 1.0 / naturalPeriod 0.4s，即 `folmeSpring(1.0, 0.4)`）回位。
///
/// 实现走 `ScrollBehavior.buildOverscrollIndicator` —— 与 Material 的拉伸
/// 指示器同一个挂载点（`Scrollable._buildChrome`），因此：
/// - 只包住滚动视口，不会连顶栏一起动；
/// - 页面里**不需要**任何改动，改一次 app 级的 `scrollBehavior` 就够；
/// - 物理仍保持 Clamping，`OverscrollNotification` 照常派发，
///   所以依赖它的下拉刷新（`MiuixPullToRefresh`）不受影响。
///
/// 对应原版 `Modifier.overScrollVertical()`。
///
/// 滚动条策略继承 [MintScrollbarBehavior]：浮动大标题页不画滚动条
/// （内容从毛玻璃标题下穿过时，滚动条会跟着探进标题里）。
class MiuixOverscrollBehavior extends MintScrollbarBehavior {
  const MiuixOverscrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    switch (axisDirectionToAxis(details.direction)) {
      case Axis.horizontal:
        return child;
      case Axis.vertical:
        return MiuixOverscrollIndicator(
          axisDirection: details.direction,
          child: child,
        );
    }
  }
}

/// 把越界量翻译成整体位移的指示器：`ClipRect` + `Transform.translate`。
///
/// 结构照 `StretchingOverscrollIndicator`（通知监听 + 裁切 + 变换），
/// 只把「纵向缩放」换成「整体平移」，并把位移曲线换成 miuix 的阻尼。
///
/// 位移的收放对应 Compose 版 `OverscrollNode` 的三段语义：
/// - 拖出边界：`OverscrollNotification` 累积 raw 并按阻尼映射成位移；
/// - **反向拖回**：`ScrollUpdateNotification` 里与累积量同号的滚动增量先用来
///   回卷位移（对应 Compose `onPreScroll` 的 consume——原版是先回卷位移、
///   余量才给列表；Flutter 的 Clamping 物理拿不到 pre-scroll 消耗，只能在
///   通知里同步回卷，否则位移会一直钉在最大值，顶栏先折叠回去、内容还压在
///   下面，看上去就是一根「超大收缩标题栏」）；
/// - 松手：弹簧回 0。
class MiuixOverscrollIndicator extends StatefulWidget {
  const MiuixOverscrollIndicator({
    super.key,
    required this.axisDirection,
    required this.child,
  });

  final AxisDirection axisDirection;

  final Widget child;

  @override
  State<MiuixOverscrollIndicator> createState() =>
      _MiuixOverscrollIndicatorState();
}

class _MiuixOverscrollIndicatorState extends State<MiuixOverscrollIndicator>
    with SingleTickerProviderStateMixin {
  /// 越界位移的弹簧回位。
  ///
  /// **必须在 initState 里创建**，不能用 `late final ... = AnimationController(...)`
  /// 的惰性初始化：没滚动过的列表（短页面 / 从没越界过）一辈子不会碰它，
  /// 而 dispose 里 `_settle.dispose()` 会触发惰性初始化 → `createTicker` 去查
  /// `TickerMode` 祖先，此刻 element 已 deactivate，直接抛
  /// 「Looking up a deactivated widget's ancestor is unsafe」（miuix 模式下
  /// 每个竖向列表都挂本指示器，推入/弹出任何页面都会撞上）。
  late final AnimationController _settle;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController.unbounded(vsync: this)
      ..addListener(_onSettleTick);
  }

  /// 累积的**原始**触摸越界量（对应原版 `rawTouchAccumulation`）。
  /// 符号约定：正 = 顶端越界（内容被向下压），负 = 底端越界（内容被向上抬）。
  double _raw = 0;

  /// 阻尼后的实际位移（对应原版 `offset`）。
  double _offset = 0;

  double _range = 1;

  void _onSettleTick() {
    final value = _settle.value;
    if (value == _offset) return;
    setState(() => _offset = value);
    if (value.abs() < 0.5 && !_settle.isAnimating) {
      setState(() {
        _offset = 0;
        _raw = 0;
      });
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// 该方向的越界量 → 位移方向的符号。
  ///
  /// 普通竖向列表（`AxisDirection.down`）在顶部往下拉时派发的 `overscroll`
  /// 是负的，而内容应该**向下**（正 y）位移，所以取反；底部反之。
  /// `AxisDirection.up`（reverse 列表）整体反号。
  double get _directionSign =>
      widget.axisDirection == AxisDirection.down ? -1.0 : 1.0;

  /// 越界量落回触摸量的逆阻尼（对应原版 `SpringMath.obtainTouchDistance`）：
  /// `T = range - range^(2/3) · sign(range − 3d) · |range − 3d|^(1/3)`。
  /// 弹簧回位途中手指再次按住越界时，用它把 raw 从当前位移重新同步出来，
  /// 避免把已回卷的部分叠加回去（对应原版 `syncRawAccumulationFromOffset`）。
  double _obtainTouchDistance(double offset, double range) {
    var d = offset.abs();
    final maxOffset = _dampedOffset(range, range).abs();
    if (d <= 0) return 0;
    if (d >= maxOffset) d = maxOffset;
    final base = range - 3 * d;
    final part2 =
        math.pow(range, 2 / 3).toDouble() *
        base.sign *
        math.pow(base.abs(), 1 / 3).toDouble();
    return range - part2;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification.metrics.axis != Axis.vertical) return false;

    if (notification is OverscrollNotification) {
      _range = math.max(notification.metrics.viewportDimension, 1.0);
      // 弹簧回位途中再次越界：先按当前位移反解 raw，再接着累积。
      if (_settle.isAnimating) {
        _raw = _offset.sign * _obtainTouchDistance(_offset, _range);
        _settle.stop();
      }
      _raw = (_raw + _directionSign * notification.overscroll).clamp(
        -_range,
        _range,
      );
      setState(() => _offset = _dampedOffset(_raw, _range));
    } else if (notification is ScrollUpdateNotification) {
      _range = math.max(notification.metrics.viewportDimension, 1.0);
      final delta = notification.scrollDelta ?? 0;
      // 有累积位移、且这次滚动正把它带回列表内部（delta 与 raw 同号：
      // 顶端越界时回滚是 pixels 增大即 delta>0，底端越界相反），先把位移
      // 一比一回卷掉——不够卷的部分才体现为列表真实滚动。
      if (delta != 0 && _raw != 0 && delta.sign == _raw.sign) {
        // 弹簧回位途中被滚动接管：raw 里还是回位前的旧账，先按当前位移
        // 反解（对应原版 syncRawAccumulationFromOffset），否则回卷会把
        // 已收回去的位移又拉出来。
        if (_settle.isAnimating) {
          _raw = _offset.sign * _obtainTouchDistance(_offset, _range);
        }
        _settle.stop();
        final next = _raw - delta;
        if (next * _raw <= 0) {
          // 回卷越过 0：位移完全收回。
          if (_raw != 0 || _offset != 0) {
            setState(() {
              _raw = 0;
              _offset = 0;
            });
          }
        } else {
          setState(() {
            _raw = next;
            _offset = _dampedOffset(_raw, _range);
          });
        }
      }
    } else if (notification is ScrollEndNotification) {
      // 松手：从当前位置用 miuix 标准弹簧回到 0（对应原版 startSpringAnimation）。
      if (_offset.abs() > 0.5 && !_settle.isAnimating) {
        _settle.value = _offset;
        _settle.animateWith(
          SpringSimulation(
            folmeSpring(damping: 1.0, response: 0.4),
            _offset,
            0,
            0,
          ),
        );
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 没有越界就不插任何变换层，省掉每帧的 Transform。
    if (_offset == 0) {
      return NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: widget.child,
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ClipRect(
        child: Transform.translate(
          offset: Offset(0, _offset),
          child: widget.child,
        ),
      ),
    );
  }
}

/// miuix 的越界阻尼：`damping(x) = x - x² + x³/3`（x 为归一化越界量）。
///
/// 与 Kotlin `SpringMath.obtainDampingDistance` 同构；x=1 时约为 1/3，
/// 也就是越界量最多转换成 1/3 视口高的位移。
double _dampedOffset(double raw, double range) {
  if (raw == 0) return 0;
  final x = (raw.abs() / range).clamp(0.0, 1.0);
  final damped = (x - x * x + x * x * x / 3) * range;
  return raw.sign * damped;
}

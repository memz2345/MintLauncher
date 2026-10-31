import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// 可折叠大标题的滚动行为（项目版，local2api 同款）：补上 flutter_miuix
/// 对「内容不满一屏」的短页面缺的那半截折叠。
///
/// 包版 [MiuixExitUntilCollapsedScrollBehavior] 的折叠量按 `pixels -
/// minScrollExtent` 记账，短页面（可滚行程小于展开量）永远记不到账。项目统一
/// 用 `ClampingScrollPhysics`（下拉刷新与越界位移都靠 `OverscrollNotification`，
/// 不能用允许越界的物理），于是短页面的 pixels 一直钉在 0，上拉只剩一条
/// OverscrollNotification（位移由 `MiuixOverscrollIndicator` 画），标题
/// **完全不折叠** —— 内容都顶进标题栏了，大标题还杵在那儿。
///
/// 补法：短页面下把手指拖动产生的未消费越界量 1:1 记进折叠量 ——
/// `overscroll > 0`（内容往上越界）折叠，`overscroll < 0`（顶部下拉）展开；
/// 松手仍由父类的短页吸附逻辑按 50% 交接线停靠到近端，不会停在半折叠态。
///
/// 长页面不掺和：折叠已由位置同步管住，这里再记一次会双倍记账（顶部回弹时抖动）。
class MiuixShortPageScrollBehavior extends MiuixExitUntilCollapsedScrollBehavior {
  MiuixShortPageScrollBehavior({
    super.state,
    super.canScroll,
    super.snapOnRelease,
    super.snapDuration,
    super.snapCurve,
    super.lockSmallTitleUntilTop,
  });

  /// 最近一次滚动体度量（[MiuixShortPageScrollListener] 从
  /// `ScrollMetricsNotification` 喂进来），用来判断是不是短页面。
  ScrollMetrics? _metrics;

  void observeMetrics(ScrollMetrics metrics) => _metrics = metrics;

  /// 桌面端鼠标滚轮的折叠补丁：滚轮走 `ScrollPosition.pointerScroll`，目标位置
  /// 被钳在 `[min, max]` 内，短页面 max == min 时**一条通知都不发**，没账可记，
  /// 所以在指针层直接补。
  void foldByPointerScroll(double dy) {
    if (dy == 0) return;
    final expansion = _expansion;
    if (expansion == null) return;
    final metrics = _metrics;
    if (metrics != null &&
        (metrics.maxScrollExtent - metrics.minScrollExtent) >= expansion - 1.0) {
      return; // 长页面：位置同步已经覆盖
    }
    // setter 自带钳制到 [limit, 0]：折到底停住，反向滚逐步恢复。
    state.heightOffset = state.heightOffset - dy;
  }

  @override
  bool handleScroll(ScrollNotification notification) {
    super.handleScroll(notification);
    if (notification is OverscrollNotification) {
      _foldByOverscroll(notification);
    }
    return false;
  }

  /// 展开量（大标题那一段能折叠的像素数）；还没测出来或顶栏被钉死时为 null。
  double? get _expansion {
    final limit = state.heightOffsetLimit;
    if (!limit.isFinite || limit >= 0) return null;
    return -limit;
  }

  /// 把未消费的越界量直接记进折叠量（等价原版嵌套滚动的 onPostScroll 段）。
  void _foldByOverscroll(OverscrollNotification n) {
    // 只看直接子滚动体的竖向滚动，跟父类同一套过滤。
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return;
    // 只跟手指：惯性 / 吸附动画引发的越界（dragDetails 为空）不算，
    // 否则松手后的回弹会把标题又拽回去。
    if (n.dragDetails == null) return;
    final expansion = _expansion;
    if (expansion == null) return;
    if ((n.metrics.maxScrollExtent - n.metrics.minScrollExtent) >=
        expansion - 1.0) {
      return; // 长页面：位置同步已经覆盖
    }
    state.heightOffset = state.heightOffset - n.overscroll;
  }
}

/// [MiuixShortPageScrollBehavior] 的接线（比包版 `MiuixScrollBehaviorListener`
/// 多干两件事，构造参数一致，是个 drop-in 替换）：
///
/// 1. 把 `ScrollMetricsNotification`（布局/尺寸变化时必发）喂给
///    [MiuixShortPageScrollBehavior.observeMetrics]，让 behavior 判断短/长页面；
/// 2. 在指针层监听滚轮，短页面下走
///    [MiuixShortPageScrollBehavior.foldByPointerScroll]；触屏拖动仍走
///    `OverscrollNotification` 那条通路。
class MiuixShortPageScrollListener extends StatelessWidget {
  const MiuixShortPageScrollListener({
    super.key,
    required this.behavior,
    required this.child,
  });

  final MiuixShortPageScrollBehavior behavior;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<Notification>(
      onNotification: (notification) {
        if (notification is ScrollMetricsNotification) {
          behavior.observeMetrics(notification.metrics);
        } else if (notification is ScrollNotification) {
          behavior.handleScroll(notification);
        }
        return false;
      },
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            behavior.foldByPointerScroll(event.scrollDelta.dy);
          }
        },
        child: child,
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全局「快速滑动碰边」触觉反馈（自 local2api `edge_scroll_haptic.dart` 移植）：
/// fling 撞到列表顶/底时轻震一下，让「到底了」有手感。
///
/// 两条触发路径（两种滚动物理下行为不同）：
///   - OverscrollNotification：clamping 物理下 fling 撞边钳停时仍带 velocity
///     过冲通知 → 速度过阈值即震；
///   - ScrollUpdateNotification 落在边界：bouncing 物理下 fling 撞边无过冲
///     通知、位置直接越界 → 用「本帧落在边界且位移量大」近似判定快速撞击。
///
/// 慢速拖拽（下拉刷新的缓动、慢慢蹭到顶）速度/位移都小，不会触发；
/// 全局 250ms 冷却，防止按住过冲时马达连响。
class EdgeScrollHaptic extends StatelessWidget {
  const EdgeScrollHaptic({super.key, required this.child});

  final Widget child;

  /// 过冲速度阈值（逻辑像素/秒）。
  static const double _velocityThreshold = 900;

  /// clamping 撞边判定：单帧位移阈值（px/帧，fling 一般 20+）。
  static const double _deltaThreshold = 16;

  static DateTime _lastHaptic = DateTime.fromMillisecondsSinceEpoch(0);

  static void _fire() {
    final now = DateTime.now();
    if (now.difference(_lastHaptic) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastHaptic = now;
    HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is OverscrollNotification) {
          if (n.velocity.abs() >= _velocityThreshold) _fire();
          return false;
        }
        if (n is ScrollUpdateNotification) {
          final m = n.metrics;
          final delta = n.scrollDelta ?? 0;
          if (delta.abs() < _deltaThreshold) return false;
          final atBottom = m.pixels >= m.maxScrollExtent - 0.5 && delta > 0;
          final atTop = m.pixels <= m.minScrollExtent + 0.5 && delta < 0;
          if (atBottom || atTop) _fire();
        }
        return false;
      },
      child: child,
    );
  }
}

import 'package:flutter/material.dart';

/// 一级页左右平移切换的统一参数。
///
/// 对应 Compose `HorizontalPager.animateToPage` 的默认 spring
/// （`StiffnessMediumLow` + 临界阻尼，约 0.3s 收敛）：这里用等价的
/// 时长 + `fastOutSlowIn`（Compose 的 `FastOutSlowInEasing`）逼近。
/// miuix 与 Material 两套壳共用，保证「点底栏」与「左右滑动」观感一致。
const Duration kPageTransitionDuration = Duration(milliseconds: 340);
const Curve kPageTransitionCurve = Curves.fastOutSlowIn;

/// 程序化跳页时「把路过的中间页吞掉」的守卫。
///
/// [PageView.onPageChanged] 在 1 → 3 的 `animateToPage` 途中会依次报 1、2。
/// 直接拿它驱动导航高亮的话，常驻侧栏 / 底栏的中间项会跟着闪一下 ——
/// 那不是用户点的，只是路过。这里记下「正在跳往哪一页」，途中的报告一律
/// 丢掉；落到目标页，或者用户自己拖拽（`dragDetails` 非空）时，才把
/// 更新权交回去。
///
/// 三个壳（Material 侧栏 / miuix 侧栏 / miuix 底栏）共用这一份。
mixin PagerJumpGuard<T extends StatefulWidget> on State<T> {
  int? _pagerTarget;

  /// 跳页目标（null = 当前没有程序化跳页在进行）。
  int? get pagerTarget => _pagerTarget;

  /// 开始一次程序化跳页 —— 在 [PageController.animateToPage] 之前调用。
  void beginPagerJump(int target) => _pagerTarget = target;

  /// 结束一次程序化跳页 —— 动画完成回调里调用（幂等）。
  void endPagerJump() => _pagerTarget = null;

  /// 这一页变化该不该被忽略？
  ///
  /// true = 跳页途中的中间页，调用方直接 return；false = 可以同步高亮了
  /// （落到目标页时顺手清掉目标）。
  bool ignorePagerReport(int index) {
    final target = _pagerTarget;
    if (target == null) return false;
    if (index == target) {
      _pagerTarget = null;
      return false;
    }
    return true;
  }

  /// 包在 [PageView] 外层：用户一拖拽就立刻接管。
  ///
  /// 否则一次长得离谱的跳页动画还没结束，用户抓住中间页拖走，就再也收不到
  /// 后续的 onPageChanged 了。
  Widget guardPagerGestures(Widget child) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _pagerTarget = null;
        }
        return false;
      },
      child: child,
    );
  }
}

/// 强制保活的一级页包装。
///
/// 两个壳原来都用 `IndexedStack`：三页全部保活，滚动位置、车道探测结果
/// 这类状态切页不丢。换成 `PageView` 之后默认只保留当前页附近，离屏页会被
/// 回收，状态就没了 —— 所以每一页都套一层这个，恢复原来的保活语义。
class KeepAlivePage extends StatefulWidget {
  const KeepAlivePage({super.key, required this.child});

  final Widget child;

  @override
  State<KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

import 'package:flutter/material.dart';

/// 一级 tab 的共享状态：Material / miuix / fluent 三棵壳是独立的 State，
/// 换风格时整棵壳重建，tab 位置和滚动位置靠这个单例续命
/// （local2api HomeShellNav 同款思路）。
class HomeNavState {
  HomeNavState._();

  static final HomeNavState instance = HomeNavState._();

  int index = 0;
  final Map<int, double> pagePixels = {};

  /// 常驻一级页：首页 / 下载 / 更多（三项都是底栏 tab，不再 push）。
  static const int tabCount = 3;
}

/// 跨页跳 tab 请求（页面里点「前往下载页」之类）：-1 = 无请求。
/// 值 = 目标 tab 序号；壳收到后消费置回 -1。
class NavRequests {
  NavRequests._();

  static final ValueNotifier<int> tab = ValueNotifier<int>(-1);

  /// 搜索请求（Ctrl+F）：值 = 自增序号，页面自行消费。
  static final ValueNotifier<int> search = ValueNotifier<int>(0);

  /// 刷新请求（F5）：值 = 自增序号。
  static final ValueNotifier<int> refresh = ValueNotifier<int>(0);

  /// 打开版本管理页（Ctrl+M）：值 = 自增序号。
  static final ValueNotifier<int> manage = ValueNotifier<int>(0);

  static void requestTab(int index) => tab.value = index;

  static void requestSearch() => search.value++;

  static void requestRefresh() => refresh.value++;

  static void requestVersionManager() => manage.value++;
}

/// 横竖屏切换时，窄屏（底栏）与宽屏（侧栏）是同一棵 build 里的两套布局：
/// PageView 会从旧位置卸载、在新位置重新挂到同一个 [PageController] 上，
/// 新 position 从 `initialPage`（壳创建时通常是 0）开始 —— 底栏高亮还在
/// 原来的 tab，内容却跳回首页，就是「横竖屏一切 tab 失效」。
///
/// local2api 的窄/宽是两个独立 State，靠 `HomeShellNav` + 转回窄屏时
/// `jumpToPage` 对齐；Mint 合并成一个 State 后同样要在布局形态变化的
/// 下一帧把分页器拉回共享 index。
mixin HomePagerLayoutKeeper<T extends StatefulWidget> on State<T> {
  bool? _lastWide;
  int? _restoringTo;

  /// 正在从共享 index 恢复分页器：这期间 PageView 报上来的中间页不要
  /// 反向覆盖 tab 高亮。
  bool get homePagerRestoring => _restoringTo != null;

  /// 在 build 里、拿到 `wide` 之后调用。
  void syncHomePagerForLayout({
    required bool wide,
    required PageController pager,
    required int currentIndex,
    required void Function(int index) applyIndex,
  }) {
    final changed = _lastWide != null && _lastWide != wide;
    _lastWide = wide;
    if (!changed) return;

    final target = HomeNavState.instance.index;
    if (target != currentIndex) applyIndex(target);
    _restoringTo = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (pager.hasClients) {
        final page = pager.positions.length == 1 ? pager.page?.round() : null;
        if (page != target) pager.jumpToPage(target);
      }
      _restoringTo = null;
    });
  }
}

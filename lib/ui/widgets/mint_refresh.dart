import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/widgets/m3e_pull_to_refresh.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

/// 手动刷新入口（local2api 同款接线）。
///
/// 顶栏「刷新」按钮调用 [refresh] 后，本控制器把 MintRefreshView 置为
/// 刷新态——两套风格都以「已拉到阈值」的姿态出现指示器：
/// · Material：M3E 指示器从顶栏下浮出、不定态旋转；
/// · miuix：指示圈 + 文案把页面元素整体下推。
/// 与手势下拉共用同一个 onRefresh，完成后一起收起。
class MintRefreshController {
  _MintRefreshViewState? _state;

  bool get isRefreshing => _state?._refreshing ?? false;

  Future<void> refresh() {
    final state = _state;
    if (state == null) return Future.value();
    return state._run();
  }

  void _attach(_MintRefreshViewState state) => _state = state;
  void _detach(_MintRefreshViewState state) {
    if (identical(_state, state)) _state = null;
  }
}

/// 双风格下拉刷新入口。
///
/// · Material：local2api 同款 `M3EPullToRefresh` —— 顶栏下浮出 M3E
///   形变指示器，内容保持原位；
/// · miuix：`MiuixPullToRefresh` —— 指示圈 + 文案把页面元素整体下推，
///   对应 InstallerX `PullToRefresh(topAppBarScrollBehavior = …)` 的接线。
///
/// [topInset] 是页面顶栏在 body 坐标系里占的高度；指示器从顶栏下面出来。
/// 页面的滚动体仍需自己保留顶部 padding（大标题页的内容从栏下穿过）。
class MintRefreshView extends StatefulWidget {
  const MintRefreshView({
    super.key,
    required this.miuix,
    required this.onRefresh,
    required this.child,
    this.topInset = 0,
    this.enabled = true,
    this.controller,
  });

  final bool miuix;
  final Future<void> Function() onRefresh;
  final Widget child;
  final double topInset;
  final bool enabled;

  /// 顶栏刷新按钮等手动触发用；不传则只有手势下拉。
  final MintRefreshController? controller;

  @override
  State<MintRefreshView> createState() => _MintRefreshViewState();
}

class _MintRefreshViewState extends State<MintRefreshView> {
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant MintRefreshView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    super.dispose();
  }

  Future<void> _run() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    if (mintMiuixOf(context, widget.miuix)) {
      final colors = MiuixTheme.of(context).colors;
      return MiuixPullToRefresh(
        isRefreshing: _refreshing,
        // MiuixPullToRefresh 的 onRefresh 是 VoidCallback；状态由本组件
        // 提升管理，回调返回的 Future 完成后再收起。
        onRefresh: () => unawaited(_run()),
        contentPadding: EdgeInsets.only(top: widget.topInset),
        color: colors.onSurfaceVariantSummary,
        circleSize: 22,
        refreshTexts: const ['下拉刷新', '松开刷新', '正在刷新…', '已刷新'],
        refreshTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: colors.onSurfaceVariantSummary,
        ),
        child: widget.child,
      );
    }

    return M3EPullToRefresh(
      isRefreshing: _refreshing,
      onRefresh: _run,
      edgeOffset: widget.topInset,
      semanticsLabel: '下拉刷新',
      child: widget.child,
    );
  }
}

/// 页面主滚动体用的物理：内容不满一屏也要接受拖拽，到顶后仍由 Clamping 钳住
/// 并派发 OverscrollNotification。两件事靠它：
///  · 下拉刷新在短页面上也能拉出来；
///  · miuix 大标题折叠 —— 短页面的折叠量就是从越界通知里记的
///    （见 widgets/miuix/miuix_short_page_scroll_behavior.dart）。
const ScrollPhysics kMintPageScrollPhysics = AlwaysScrollableScrollPhysics(
  parent: ClampingScrollPhysics(),
);

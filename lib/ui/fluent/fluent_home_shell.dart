import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/window_backdrop.dart';
import 'package:mint/ui/nav_state.dart';
import 'package:mint/ui/fluent/fluent_side_bar.dart';
import 'package:mint/ui/pages/download_hub_page.dart';
import 'package:mint/ui/pages/home_page.dart';
import 'package:mint/ui/pages/more_page.dart';
import 'package:mint/ui/pages/version_manager_page.dart';
import 'package:mint/ui/widgets/page_background.dart'
    show MintPageBackgroundKey, MintPageBackgroundScope;
import 'package:mint/widgets/page_switcher.dart';

import '../home_shell.dart' show kSideBarBreakpoint;

/// Fluent（Windows 11）主框架：宽屏 = fluent_ui 的 [fluent.NavigationView]
/// 展开侧栏（Win11 样式指示条 + FluentIcons），窄屏 = 底部 pane。
/// 一级页仍是同一个 PageView 分页器（与 Material / miuix 壳同一套），
/// 页面本体走 Material 叶子（由 FluentTheme 桥过来的配色渲染）。
class FluentHomeShell extends StatefulWidget {
  const FluentHomeShell({super.key, required this.controller});

  final LauncherController controller;

  @override
  State<FluentHomeShell> createState() => _FluentHomeShellState();
}

class _FluentHomeShellState extends State<FluentHomeShell>
    with PagerJumpGuard<FluentHomeShell>, HomePagerLayoutKeeper<FluentHomeShell> {
  int _index = HomeNavState.instance.index;

  final PageController _pager = PageController(
    initialPage: HomeNavState.instance.index,
  );

  @override
  void initState() {
    super.initState();
    NavRequests.tab.addListener(_onTabRequest);
    NavRequests.manage.addListener(_onManageRequest);
  }

  @override
  void dispose() {
    NavRequests.tab.removeListener(_onTabRequest);
    NavRequests.manage.removeListener(_onManageRequest);
    _pager.dispose();
    super.dispose();
  }

  void _onTabRequest() {
    final target = NavRequests.tab.value;
    if (target < 0) return;
    NavRequests.tab.value = -1;
    if (target == _index) return;
    _onNavigate(target);
  }

  void _onManageRequest() {
    if (!mounted) return;
    openVersionManager(context, false);
  }

  void _onNavigate(int i) {
    // 三个入口都是常驻一级分页（首页 / 下载 / 更多），PageView 直切。
    if (i == _index) return;
    setState(() {
      _index = i;
      HomeNavState.instance.index = i;
    });
    if (_pager.hasClients) {
      beginPagerJump(i);
      _pager
          .animateToPage(
            i,
            duration: kPageTransitionDuration,
            curve: kPageTransitionCurve,
          )
          .whenComplete(endPagerJump);
    }
  }

  static const _tabs = [
    // 侧栏精简：首页 / 下载 / 更多。FluentIcons 是 Segoe Fluent 字形。
    (fluent.FluentIcons.home, '首页'),
    (fluent.FluentIcons.download, '下载'),
    (fluent.FluentIcons.more, '更多'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final glass = WindowBackdrop.instance.isActive;
    final wide = MediaQuery.sizeOf(context).width >= kSideBarBreakpoint;
    // 横竖屏切换会换布局分支，PageView 重新 attach 后停在首页；
    // 下一帧拉回当前 tab（详见 HomePagerLayoutKeeper）。
    syncHomePagerForLayout(
      wide: wide,
      pager: _pager,
      currentIndex: _index,
      applyIndex: (i) => _index = i,
    );

    final pages = [
      MintPageBackgroundScope(
        keyId: MintPageBackgroundKey.home.id,
        child: HomePage(miuix: false),
      ),
      MintPageBackgroundScope(
        keyId: MintPageBackgroundKey.download.id,
        child: DownloadHubPage(miuix: false, embedded: true),
      ),
      const MintPageBackgroundScope(
        keyId: '',
        child: MintMorePage(miuix: false, embedded: true),
      ),
    ];

    // NavigationView 的 body 背景取 FluentTheme.scaffoldBackgroundColor，
    // 这里置透明，由外层 Material 容器统一铺底（玻璃模式透出 DWM 材质）。
    final pager = Material(
      type: MaterialType.transparency,
      child: guardPagerGestures(
        PageView(
          controller: _pager,
          onPageChanged: (i) {
            if (homePagerRestoring) return;
            if (ignorePagerReport(i)) return;
            if (i == _index) return;
            setState(() {
              _index = i;
              HomeNavState.instance.index = i;
            });
          },
          children: [for (final page in pages) KeepAlivePage(child: page)],
        ),
      ),
    );

    if (wide) {
      // 宽屏：自绘的可折叠 WinUI 侧栏（48 ↔ 220，汉堡按钮收起/展开，
      // 状态落盘）。fluent 自带 NavigationPane 的 compact 是浮层、展开状态
      // 也没法持久化，所以这里自己搭一遍。侧栏本身是 8px 圆角卡片
      //（QwenTtsMic 的 WinUI CardStyle），和内容之间不再画分隔线。
      return _withSnackHost(
        ColoredBox(
          color: glass ? Colors.transparent : cs.surface,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FluentCollapsibleSideBar(
                currentIndex: _index,
                onNavigate: _onNavigate,
                tabs: [for (final t in _tabs) (t.$1, t.$2)],
              ),
              Expanded(
                // 页面区实际宽度写回 MediaQuery：Material 大标题栏按窗口宽
                // 计算的内边距在以侧栏为参照时才对得上（miuix 壳同款修法）。
                child: LayoutBuilder(
                  builder: (context, constraints) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                    ),
                    child: pager,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return _withSnackHost(
      ColoredBox(
        color: glass ? Colors.transparent : cs.surface,
        child: fluent.NavigationView(
          pane: fluent.NavigationPane(
            selected: _index,
            // 窄窗口：WinUI 惯例是顶部水平 pane（fluent 没有底部导航）。
            displayMode: fluent.PaneDisplayMode.top,
            onChanged: _onNavigate,
            size: const fluent.NavigationPaneSize(topHeight: 48),
            items: [
              for (final t in _tabs)
                fluent.PaneItem(
                  icon: fluent.Icon(t.$1, size: 20),
                  title: Text(t.$2),
                  body: const SizedBox.shrink(),
                ),
            ],
          ),
          paneBodyBuilder: (item, child) => pager,
        ),
      ),
    );
  }

  /// fluent 壳里没有 Material Scaffold，而非 miuix 风格的
  /// [showMintSnack] 走 `ScaffoldMessenger.showSnackBar` —— 没有任何已注册
  /// Scaffold 时会命中 debug 断言（"no descendant Scaffolds to present to"）。
  /// 这里给整棵壳包一层透明 Scaffold 当宿主，Snackbar 照常浮层显示。
  Widget _withSnackHost(Widget child) => Scaffold(
    backgroundColor: Colors.transparent,
    resizeToAvoidBottomInset: false,
    body: child,
  );
}

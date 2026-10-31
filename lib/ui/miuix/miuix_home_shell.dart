import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/download_center.dart';
import 'package:mint/services/liquid_glass_bar_service.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/window_backdrop.dart';
import 'package:mint/ui/home_shell.dart' show kHomeTabs, kSideBarBreakpoint;
import 'package:mint/ui/nav_state.dart';
import 'package:mint/ui/pages/download_hub_page.dart';
import 'package:mint/ui/pages/home_page.dart';
import 'package:mint/ui/pages/more_page.dart';
import 'package:mint/ui/pages/version_manager_page.dart';
import 'package:mint/widgets/floating_bottom_bar.dart';
import 'package:mint/ui/widgets/native_glass_bottom_bar.dart';
import 'package:mint/ui/widgets/page_background.dart'
    show
        MintPageBackgroundKey,
        MintPageBackgroundScope,
        MintShellBackgroundScope,
        PageBackground;
import 'package:mint/widgets/page_switcher.dart';

/// miuix（HyperOS）主框架：宽屏 = MiuixNavigationRail（可折叠，Folme 弹簧），
/// 窄屏 = local2api 同款悬浮胶囊底栏。首页 / 下载是一级分页，「更多」推入设置页。
class MiuixHomeShell extends StatefulWidget {
  const MiuixHomeShell({super.key, required this.controller});

  final LauncherController controller;

  @override
  State<MiuixHomeShell> createState() => _MiuixHomeShellState();
}

class _MiuixHomeShellState extends State<MiuixHomeShell>
    with
        PagerJumpGuard<MiuixHomeShell>,
        HomePagerLayoutKeeper<MiuixHomeShell>,
        RouteAware {
  int _index = HomeNavState.instance.index;

  /// 原生液态玻璃底栏（Android 窄屏）。
  late final NativeGlassBarBinding _glassBar;
  ModalRoute<void>? _route;
  bool _isTopRoute = true;

  /// 下载 / 设置返回后重建底栏，指示器归位首页（同 Material 壳）。
  int _barEpoch = 0;

  final PageController _pager = PageController(
    initialPage: HomeNavState.instance.index,
  );

  /// 侧栏展开控制器（Material 壳同款持久化，两壳互不影响各自记住状态）。
  final MiuixNavigationRailState _railState = MiuixNavigationRailState();

  @override
  void initState() {
    super.initState();
    _glassBar = NativeGlassBarBinding();
    LiquidGlassBarService.bindTabSelected(_onNativeTabTap);
    NavRequests.tab.addListener(_onTabRequest);
    NavRequests.manage.addListener(_onManageRequest);
    _restoreRailExpanded();
    _railState.addListener(_persistRail);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || route == _route) return;
    if (_route != null) liquidGlassBarRouteObserver.unsubscribe(this);
    _route = route;
    liquidGlassBarRouteObserver.subscribe(this, route);
    _isTopRoute = route.isCurrent;
  }

  @override
  void didPushNext() {
    _isTopRoute = false;
    unawaited(_glassBar.hide());
  }

  @override
  void didPopNext() {
    _isTopRoute = true;
    if (mounted) setState(() {});
  }

  void _onNativeTabTap(int index) => _onNavigate(index);

  Future<void> _restoreRailExpanded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('mint.miuixRailExpanded') ?? false) _railState.expand();
    } catch (_) {}
  }

  /// 组件内置的展开/收起按钮直接调 state.toggle()，这里监听落盘。
  Future<void> _persistRail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('mint.miuixRailExpanded', _railState.isExpanded);
    } catch (_) {}
  }

  @override
  void dispose() {
    NavRequests.tab.removeListener(_onTabRequest);
    NavRequests.manage.removeListener(_onManageRequest);
    if (_route != null) liquidGlassBarRouteObserver.unsubscribe(this);
    LiquidGlassBarService.unbindTabSelected(_onNativeTabTap);
    _glassBar.dispose();
    _railState.dispose();
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
    openVersionManager(context, true);
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

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kSideBarBreakpoint;
    // 横竖屏切换会换布局分支，PageView 重新 attach 后停在首页；
    // 下一帧拉回当前 tab（详见 HomePagerLayoutKeeper）。
    syncHomePagerForLayout(
      wide: wide,
      pager: _pager,
      currentIndex: _index,
      applyIndex: (i) => _index = i,
    );
    final settings = context.watch<SettingsService>();
    final useNativeBar =
        Platform.isAndroid &&
        !wide &&
        settings.glassBottomBar &&
        _isTopRoute &&
        LiquidGlassBarService.enabled;

    final glassTabs = [
      for (final (i, t) in kHomeTabs.indexed)
        LiquidGlassBarTab(
          id: t.$3,
          label: t.$3,
          icon: t.$1,
          selectedIcon: t.$2,
          badge: i == 1 && DownloadCenter.instance.hasActive,
        ),
    ];
    if (useNativeBar) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          _glassBar.sync(
            context: context,
            enabled: true,
            index: _index,
            tabs: glassTabs,
            accent: Theme.of(context).colorScheme.primary,
          ),
        );
      });
    } else if (_glassBar.shown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_glassBar.hide());
      });
    }

    final pages = [
      // 宽屏下每页自己画背景：包上按页背景作用域（预览器可给首页 / 下载
      // 指定不同的图）。窄屏的背景在壳层统一铺（见下方 scope）。
      // 「更多」没有专属按页背景，回落全局 / 主题壁纸（scope 传空键）。
      MintPageBackgroundScope(
        keyId: MintPageBackgroundKey.home.id,
        child: HomePage(miuix: true),
      ),
      MintPageBackgroundScope(
        keyId: MintPageBackgroundKey.download.id,
        child: DownloadHubPage(miuix: true, embedded: true),
      ),
      const MintPageBackgroundScope(
        keyId: '',
        child: MintMorePage(miuix: true, embedded: true),
      ),
    ];

    // Material(transparency)：MiuixScaffold 不提供 Material 祖先，页面里的
    // TextField / InkWell 等会抛 "No Material widget found"（下载页搜索框
    // 实测红屏）。在这里包一次，全部 miuix 页面受益；transparency 不画东西。
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
      final miuix = MiuixTheme.of(context);
      final glass = WindowBackdrop.instance.isActive;
      final railColors = MiuixNavigationRailDefaults.colors(context);
      return MiuixScaffold(
        containerColor: glass ? Colors.transparent : null,
        content: (padding) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MiuixNavigationRail(
              state: _railState,
              colors: glass
                  ? MiuixNavigationRailColors(
                      background: Colors.transparent,
                      content: railColors.content,
                      indicator: railColors.indicator,
                      divider: railColors.divider,
                    )
                  : null,
              expandContentDescription: '展开侧栏',
              collapseContentDescription: '收起侧栏',
              // HyperOS 侧栏没有圆角卡片包着：给个标题头 + 底色融合。
              // AnimatedBuilder 跟随展开/收起动画重绘标题文字。
              // 只放徽标：折叠态下文字会伸出窄栏被右侧内容裁半（「Mi」）。
              // 展开态的 HyperOS 侧栏也不需要重复应用名，页面大标题已经说明了。
              header: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: miuix.colors.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'M',
                    style: TextStyle(
                      color: miuix.colors.onPrimary,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              children: [
                for (final (i, t) in kHomeTabs.indexed)
                  MiuixNavigationRailItem(
                    selected: _index == i,
                    icon: Icon(_index == i ? t.$2 : t.$1),
                    label: t.$3,
                    onPressed: () => _onNavigate(i),
                  ),
              ],
            ),
            Expanded(
              // MiuixTopAppBar 内部用 MediaQuery.sizeOf(context).width 来
              // 计算折叠小标题的居中位置。页面挂在 rail 右侧时，直接按
              // 全窗宽居中会整体向右偏半个侧栏宽（展开 240dp 时最明显）。
              // 这里用 LayoutBuilder 把页面区的实际宽高写回 MediaQuery，
              // 顶栏就会按自身宽度居中（local2api 同款修法）。
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
      );
    }

    final glass = WindowBackdrop.instance.isActive;
    final shell = MiuixScaffold(
      // 背景由外层整屏 PageBackground 提供（连底栏下面一起铺），
      // MiuixScaffold 自己保持透明。
      containerColor: Colors.transparent,
      bottomBar: useNativeBar
          ? SizedBox(height: LiquidGlassBarService.slotHeight(context))
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                // 底栏跟着 DownloadCenter 重建：有任务时「下载」挂红点。
                child: ListenableBuilder(
                  listenable: DownloadCenter.instance,
                  builder: (context, _) => FloatingBottomBar(
                    key: ValueKey('home-bar-miuix-$_barEpoch'),
                    blurred: true,
                    blurSigma: 12,
                    // iOS 26+:底栏交给系统液态玻璃(GlassBridge)。
                    systemGlass: Platform.isIOS && settings.iosLiquidGlass,
                    selectedIndex: _index,
                    onSelected: _onNavigate,
                    items: [
                      for (final (i, t) in kHomeTabs.indexed)
                        FloatingBottomBarItem(
                          label: t.$3,
                          badge: i == 1 && DownloadCenter.instance.hasActive,
                          iconBuilder: (selected) =>
                              Icon(selected ? t.$2 : t.$1),
                        ),
                    ],
                    colors: FloatingBottomBarColors(
                      containerColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainer.withValues(alpha: 0.72),
                      indicatorColor: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.15),
                      contentColor: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant,
                      activeContentColor: Theme.of(
                        context,
                      ).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
      content: (padding) => Padding(
        padding: EdgeInsets.only(bottom: padding.bottom),
        child: pager,
      ),
    );
    final framed = MintShellBackgroundScope(
      active: true,
      child: Stack(
        children: [
          Positioned.fill(
            // 窄屏的背景铺在壳层（连底栏下面一起），按当前 tab 套按页背景
            // 作用域：预览器给首页 / 下载指定的图在这里切换（「更多」空键
            // = 回落全局 / 主题壁纸）。
            child: MintPageBackgroundScope(
              keyId: switch (_index) {
                0 => MintPageBackgroundKey.home.id,
                1 => MintPageBackgroundKey.download.id,
                _ => '',
              },
              child: PageBackground(
                baseColor: glass ? null : MiuixTheme.of(context).colors.surface,
              ),
            ),
          ),
          Positioned.fill(child: shell),
        ],
      ),
    );
    // 布局诊断：--dart-define=MINT_DEBUG_LAYOUT=true 时把媒体尺寸 / 实际约束
    // 直接画在首页上（移动端 logcat 被 vivo 吞掉，只能看上屏数据）。
    if (!const bool.fromEnvironment('MINT_DEBUG_LAYOUT')) return framed;
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          Positioned.fill(child: framed),
          Positioned(
            left: 8,
            top: 180,
            child: Text(
              'mq=${MediaQuery.sizeOf(context)} dpr=${MediaQuery.devicePixelRatioOf(context)} '
              'cons=${constraints.biggest} useNative=$useNativeBar wide=$wide',
              style: const TextStyle(
                color: Colors.red,
                fontSize: 14,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/download_center.dart';
import 'package:mint/services/ios_liquid_glass.dart';
import 'package:mint/services/liquid_glass_bar_service.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/window_backdrop.dart';
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
import 'package:mint/widgets/app_tooltip.dart';
import 'package:mint/widgets/page_switcher.dart';

/// 宽屏阈值（local2api / NaviFlash 同款）。
const double kSideBarBreakpoint = 768;

/// 底栏 / 侧栏的三个入口（未选中图标，选中图标，标题）。
/// 首页 / 下载是一级分页；「更多」推入设置页（设置不再是常驻 tab，
/// 但仍然从这里直达 —— HMCL 式独立设置页）。
const List<(IconData, IconData, String)> kHomeTabs = [
  (Icons.home_outlined, Icons.home, '首页'),
  (Icons.download_outlined, Icons.download, '下载'),
  (Icons.more_horiz, Icons.more_horiz, '更多'),
];

/// Material 主框架：宽屏 = 可折叠侧栏 + 内容圆角卡片；
/// 窄屏 = 悬浮胶囊底栏（local2api FloatingBottomBar 同款：
/// 毛玻璃胶囊 + 可拖动指示器）。下载是一级分页，「更多」推入设置页。
class MaterialHomeShell extends StatefulWidget {
  const MaterialHomeShell({super.key, required this.controller});

  final LauncherController controller;

  @override
  State<MaterialHomeShell> createState() => _MaterialHomeShellState();
}

class _MaterialHomeShellState extends State<MaterialHomeShell>
    with
        PagerJumpGuard<MaterialHomeShell>,
        HomePagerLayoutKeeper<MaterialHomeShell>,
        RouteAware {
  int _index = HomeNavState.instance.index;

  /// 原生液态玻璃底栏（Android 窄屏）。显示/换页/隐藏都走这个 binding。
  late final NativeGlassBarBinding _glassBar;
  ModalRoute<void>? _route;
  bool _isTopRoute = true;

  /// 底栏重建序号：从设置 / 二级页返回后重建一次，指示器归位（FloatingBottomBar
  /// 的指示器由内部控制器驱动，重建最省事）。
  int _barEpoch = 0;

  final PageController _pager = PageController(
    initialPage: HomeNavState.instance.index,
  );

  @override
  void initState() {
    super.initState();
    _glassBar = NativeGlassBarBinding();
    LiquidGlassBarService.bindTabSelected(_onNativeTabTap);
    NavRequests.tab.addListener(_onTabRequest);
    NavRequests.manage.addListener(_onManageRequest);
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

  @override
  void dispose() {
    NavRequests.tab.removeListener(_onTabRequest);
    NavRequests.manage.removeListener(_onManageRequest);
    if (_route != null) liquidGlassBarRouteObserver.unsubscribe(this);
    LiquidGlassBarService.unbindTabSelected(_onNativeTabTap);
    _glassBar.dispose();
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= kSideBarBreakpoint;
    // 横竖屏切换会换布局分支，PageView 重新 attach 后停在首页；
    // 下一帧拉回当前 tab（详见 HomePagerLayoutKeeper）。
    syncHomePagerForLayout(
      wide: wide,
      pager: _pager,
      currentIndex: _index,
      applyIndex: (i) => _index = i,
    );
    final glass = WindowBackdrop.instance.isActive;
    final settings = context.watch<SettingsService>();
    // Android：Compose 原生栏（开关 glassBottomBar）。
    // iOS 26+：UITabBarController 原生 Liquid Glass 栏（开关 iosLiquidGlass）。
    final nativeBarEnabled =
        (Platform.isAndroid && settings.glassBottomBar) ||
        (Platform.isIOS &&
            settings.iosLiquidGlass &&
            IosLiquidGlass.instance.cachedAvailable == true);
    final useNativeBar =
        nativeBarEnabled &&
        !wide &&
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

    if (wide) {
      // ── 宽屏：可折叠侧栏 + 圆角内容卡片（local2api 同款布局）──
      return Scaffold(
        backgroundColor: glass ? Colors.transparent : cs.surfaceContainerLow,
        body: SafeArea(
          top: true,
          bottom: false,
          left: false,
          right: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RepaintBoundary(
                child: CollapsibleSideBar(
                  currentIndex: _index,
                  onNavigate: _onNavigate,
                ),
              ),
              Expanded(
                child: RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: ColoredBox(
                        color: glass
                            ? cs.surfaceContainer.withValues(alpha: 0.24)
                            : cs.surfaceContainer,
                        child: Stack(
                          children: [
                            Positioned.fill(
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
                                  children: [
                                    for (final page in pages)
                                      KeepAlivePage(child: page),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ── 窄屏：底栏 ──
    // 背景图铺到外壳整屏（含底栏下面），页面内部不再重复画背景；
    // Scaffold 自身保持透明，悬浮胶囊/原生玻璃栏才能折射到壁纸。
    return MintShellBackgroundScope(
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
                baseColor: glass ? null : cs.surfaceContainer,
              ),
            ),
          ),
          Positioned.fill(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              extendBody: true,
              body: Stack(
                children: [
                  Positioned.fill(
                    bottom: useNativeBar
                        ? LiquidGlassBarService.slotHeight(context)
                        : 80,
                    child: guardPagerGestures(
                      PageView(
                        controller: _pager,
                        onPageChanged: (i) {
                          if (homePagerRestoring) return;
                          setState(() {
                            _index = i;
                            HomeNavState.instance.index = i;
                          });
                        },
                        children: [
                          for (final page in pages) KeepAlivePage(child: page),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: useNativeBar
                  ? SizedBox(height: LiquidGlassBarService.slotHeight(context))
                  : SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        // 底栏跟着 DownloadCenter 重建：有任务时「下载」
                        // 挂红点（下载器一键直达的提示）。
                        child: ListenableBuilder(
                          listenable: DownloadCenter.instance,
                          builder: (context, _) => FloatingBottomBar(
                            key: ValueKey('home-bar-material-$_barEpoch'),
                            blurred: true,
                            blurSigma: 12,
                            // iOS 26+:底栏交给系统液态玻璃(GlassBridge)。
                            systemGlass:
                                Platform.isIOS && settings.iosLiquidGlass,
                            selectedIndex: _index,
                            onSelected: _onNavigate,
                            items: [
                              for (final (i, t) in kHomeTabs.indexed)
                                FloatingBottomBarItem(
                                  label: t.$3,
                                  badge:
                                      i == 1 &&
                                      DownloadCenter.instance.hasActive,
                                  iconBuilder: (selected) =>
                                      Icon(selected ? t.$2 : t.$1),
                                ),
                            ],
                            colors: FloatingBottomBarColors(
                              containerColor: cs.surfaceContainer.withValues(
                                alpha: 0.72,
                              ),
                              indicatorColor: cs.primary.withValues(
                                alpha: 0.15,
                              ),
                              contentColor: cs.onSurfaceVariant,
                              activeContentColor: cs.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 可折叠桌面侧栏（local2api CollapsibleSideBar 移植）：
///   · 收起 = M3 竖向导航栏（NavigationIndicator 胶囊 + 纯图标）
///   · 展开 = 胶囊 list（图标 + 文字，选中 primaryContainer）
///   · 顶部 menu 按钮（逐像素对位，原位展开/收起），状态持久化
class CollapsibleSideBar extends StatefulWidget {
  const CollapsibleSideBar({
    super.key,
    required this.currentIndex,
    required this.onNavigate,
  });

  final int currentIndex;
  final ValueChanged<int> onNavigate;

  // ── 宽度 ──
  /// 收起态宽度 = M3 竖向导航栏。
  static const double minWidth = 80;

  /// 展开态宽度（胶囊 list）。
  static const double expandedWidth = 224;

  /// 展开 / 收起动画时长与曲线（宽度、胶囊过渡共用）。
  static const Duration animDuration = Duration(milliseconds: 260);
  static const Curve animCurve = Curves.easeInOutCubic;

  // ── 展开 / 收起状态：全局共享并持久化 ──
  static final ValueNotifier<bool> expanded = ValueNotifier(false);
  static bool _loaded = false;

  static Future<void> loadExpandedState() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      expanded.value = prefs.getBool('mint.sideBarExpanded') ?? false;
    } catch (_) {}
  }

  static Future<void> toggle() async {
    expanded.value = !expanded.value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('mint.sideBarExpanded', expanded.value);
    } catch (_) {}
  }

  @override
  State<CollapsibleSideBar> createState() => _CollapsibleSideBarState();
}

class _CollapsibleSideBarState extends State<CollapsibleSideBar> {
  @override
  void initState() {
    super.initState();
    CollapsibleSideBar.loadExpandedState();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: CollapsibleSideBar.expanded,
      builder: (context, isExpanded, _) {
        // RepaintBoundary 隔离宽度动画；Clip.hardEdge 裁掉揭示动画中
        // 多出来的部分。展开态内容**固定按 224 定宽布局**（OverflowBox
        // 打破父级紧约束）：80→224 的展开动画期间，行内的 icon + 间距
        // （约 38px）会被中间宽度（低到 24px）的紧约束挤爆，debug 下一帧
        // 一个 RenderFlex overflow；最大化触发布局切换时会连着刷异常
        // 卡住渲染。定宽 + 左对齐揭示后行永远按最终宽度布局，不再溢出。
        return RepaintBoundary(
          child: AnimatedContainer(
            duration: CollapsibleSideBar.animDuration,
            curve: CollapsibleSideBar.animCurve,
            width: isExpanded
                ? CollapsibleSideBar.expandedWidth
                : CollapsibleSideBar.minWidth,
            color: Colors.transparent,
            clipBehavior: Clip.hardEdge,
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: isExpanded
                  ? CollapsibleSideBar.expandedWidth
                  : CollapsibleSideBar.minWidth,
              minWidth: isExpanded
                  ? CollapsibleSideBar.expandedWidth
                  : CollapsibleSideBar.minWidth,
              child: KeyedSubtree(
                key: ValueKey(isExpanded),
                child: SizedBox(
                  width: isExpanded
                      ? CollapsibleSideBar.expandedWidth
                      : CollapsibleSideBar.minWidth,
                  child: isExpanded
                      ? _buildExpandedList(context)
                      : _buildCollapsedRail(context),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 收起态：顶部 menu 按钮 + Mint 徽标沉顶、导航图标纵列沉底。
  Widget _buildCollapsedRail(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tabs = kHomeTabs;
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: CollapsibleSideBar.minWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 顶部：menu 胶囊按钮（锚点与展开态逐像素对位）──
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: CollapsibleSideBar.minWidth,
                    height: 44,
                    child: Center(
                      child: _CapsuleIconButton(
                        icon: Icons.menu,
                        tooltip: '展开侧栏',
                        onTap: CollapsibleSideBar.toggle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // ── Mint 徽标 ──
            Center(
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(
                  'M',
                  style: TextStyle(
                    color: cs.onPrimary,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
              ),
            ),
            const Spacer(),
            // ── 底部导航：图标纵列（M3 NavigationIndicator 胶囊）──
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < tabs.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    _CollapsedNavItem(
                      icon: tabs[i].$2,
                      outlinedIcon: tabs[i].$1,
                      label: tabs[i].$3,
                      isSelected: widget.currentIndex == i,
                      onTap: () => widget.onNavigate(i),
                    ),
                  ],
                ],
              ),
            ),
            SafeArea(top: false, child: const SizedBox(height: 4)),
          ],
        ),
      ),
    );
  }

  /// 展开态：徽标头 + Gmail 风格胶囊 list。
  Widget _buildExpandedList(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tabs = kHomeTabs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 顶部：menu_open 按钮（与收起态同锚点）──
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: _CapsuleIconButton(
                    icon: Icons.menu_open,
                    tooltip: '收起侧栏',
                    onTap: CollapsibleSideBar.toggle,
                  ),
                ),
              ),
            ),
          ),
        ),
        // ── Mint 徽标 + 名字 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(
                  'M',
                  style: TextStyle(
                    color: cs.onPrimary,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // 侧栏揭示动画期间容器可能比内容窄：文字可收缩，避免溢出。
              Flexible(
                child: Text(
                  'Mint',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
            children: [
              for (var i = 0; i < tabs.length; i++)
                _CapsuleListItem(
                  icon: tabs[i].$1,
                  selectedIcon: tabs[i].$2,
                  title: tabs[i].$3,
                  isSelected: widget.currentIndex == i,
                  onTap: () => widget.onNavigate(i),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 收起态单项：M3 NavigationIndicator 胶囊 + 选中时才出现的文字。
class _CollapsedNavItem extends StatefulWidget {
  const _CollapsedNavItem({
    required this.icon,
    required this.outlinedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final IconData outlinedIcon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_CollapsedNavItem> createState() => _CollapsedNavItemState();
}

class _CollapsedNavItemState extends State<_CollapsedNavItem>
    with SingleTickerProviderStateMixin {
  /// 与 NavigationRail 完全相同的指示器驱动（200ms controller，
  /// 选中 forward / 取消 reverse，emphasized 曲线由组件内部叠加）。
  late final AnimationController _indicatorController;

  @override
  void initState() {
    super.initState();
    _indicatorController = AnimationController(
      duration: kThemeAnimationDuration,
      vsync: this,
      value: widget.isSelected ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(_CollapsedNavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSelected != oldWidget.isSelected) {
      widget.isSelected
          ? _indicatorController.forward()
          : _indicatorController.reverse();
    }
  }

  @override
  void dispose() {
    _indicatorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selectedFg = cs.onPrimaryContainer;
    final iconWidget = AnimatedSwitcher(
      duration: kThemeAnimationDuration,
      switchInCurve: Curves.easeInOutCubicEmphasized,
      switchOutCurve: Curves.easeInOutCubicEmphasized.flipped,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: Icon(
        key: ValueKey<bool>(widget.isSelected),
        widget.isSelected ? widget.icon : widget.outlinedIcon,
        size: 24,
        color: widget.isSelected ? selectedFg : cs.onSurfaceVariant,
      ),
    );
    final pill = SizedBox(
      width: 56,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          NavigationIndicator(
            animation: _indicatorController,
            color: cs.primaryContainer,
            width: 56,
            height: 32,
            shape: const StadiumBorder(),
          ),
          iconWidget,
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onTap,
                borderRadius: BorderRadius.circular(16),
                child: pill,
              ),
            ),
            // 仅选中项显示文字，AnimatedSize 高度过渡 + 淡入。
            AnimatedSize(
              duration: CollapsibleSideBar.animDuration,
              curve: CollapsibleSideBar.animCurve,
              alignment: Alignment.topCenter,
              child: widget.isSelected
                  ? Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: kThemeAnimationDuration,
                        curve: Curves.easeInOutCubicEmphasized,
                        builder: (context, opacity, child) =>
                            Opacity(opacity: opacity, child: child),
                        child: Text(
                          widget.label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                            height: 1,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox(height: 2),
            ),
          ],
        ),
      ),
    );
  }
}

/// 展开态胶囊项：紧凑胶囊（宽度自适应文字，非全宽拉伸）。
class _CapsuleListItem extends StatelessWidget {
  const _CapsuleListItem({
    required this.icon,
    required this.selectedIcon,
    required this.title,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: AnimatedContainer(
          duration: CollapsibleSideBar.animDuration,
          curve: CollapsibleSideBar.animCurve,
          decoration: BoxDecoration(
            color: isSelected ? cs.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(28),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(28),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: kThemeAnimationDuration,
                      switchInCurve: Curves.easeInOutCubicEmphasized,
                      switchOutCurve: Curves.easeInOutCubicEmphasized.flipped,
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: Icon(
                        key: ValueKey<bool>(isSelected),
                        isSelected ? selectedIcon : icon,
                        size: 22,
                        color: isSelected
                            ? cs.onPrimaryContainer
                            : cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Flexible(
                      child: AnimatedDefaultTextStyle(
                        duration: kThemeAnimationDuration,
                        curve: Curves.easeInOutCubicEmphasized,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: isSelected
                              ? cs.onPrimaryContainer
                              : cs.onSurfaceVariant,
                        ),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部 menu 按钮：44×44 正圆热区，仅图标。
class _CapsuleIconButton extends StatelessWidget {
  const _CapsuleIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppTooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 22, color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

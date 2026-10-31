import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/settings_service.dart';
import 'package:mint/ui/pages/common.dart' show MintSnackScope;
import 'package:mint/services/window_backdrop.dart';
import 'package:mint/ui/mint_icons.dart';
import 'package:mint/ui/window_chrome.dart';
import 'package:mint/ui/widgets/mint_progressive_band.dart';
import 'package:mint/ui/widgets/page_background.dart';
import 'package:mint/ui/widgets/top_bar_tone.dart';
import 'package:mint/widgets/mint_scroll_behavior.dart';
import 'package:mint/widgets/miuix/miuix_short_page_scroll_behavior.dart';

/// 统一页面骨架：一级页用「可折叠大标题」，二级页用「返回 + 居中/左对齐小标题」。
///
/// 标题栏参考 local2api：
///  · miuix  —— [MiuixTopAppBar] + [MiuixExitUntilCollapsedScrollBehavior]
///    （毛玻璃 + 大标题折叠模糊，滚动时收缩成居中栏标题）
///  · Material —— ExpressiveSliverAppBar 同款大标题：展开时大标题压在内容上，
///    滚动后收成 56 高的毛玻璃工具栏，小标题淡入并钉住
///
/// 关键点（之前「滚轮一滚标题就没了」就是栽在这里）：折叠状态必须由**滚动
/// 通知**驱动。miuix 侧靠 [MiuixShortPageScrollListener] 把每个
/// [ScrollNotification] 喂给 behavior；Material 侧由本组件自己监听。
/// 页面里的主滚动体请用 `ClampingScrollPhysics`（与 local2api 一致），否则
/// 越界回弹会把折叠量拉回展开态。
class MintPageScaffold extends StatefulWidget {
  const MintPageScaffold({
    super.key,
    required this.miuix,
    required this.title,
    required this.body,
    this.largeTitle,
    this.actions = const [],
    this.leading,
    this.showBack = false,
    this.floatingActionButton,
    this.bottomBar,
    this.bare = false,
    this.pinBar = false,
    this.pageBackgroundKey,
  });

  final bool miuix;

  /// 顶栏标题；二级页即居中标题，一级页是折叠后的小标题。
  final String title;

  /// 一级页的大标题。null = 小标题栏（日志、安装进度等不需要大标题的页面）。
  final String? largeTitle;

  /// 右侧动作。建议用 [MintTopBarAction]，保证两套风格尺寸一致。
  final List<Widget> actions;

  /// 左侧自定义导航图标；为 null 且 [showBack] 时使用默认返回箭头。
  final Widget? leading;

  /// 二级页：显示返回按钮，并使用不透明页面底色。
  final bool showBack;

  final Widget? floatingActionButton;

  /// 常驻底部操作栏（安装页的「开始安装」等），会自动避开系统手势区。
  final Widget? bottomBar;

  /// 不画页面标题栏 / 顶栏，内容直接铺满（首页改版后不再显示「启动 / Mint」）。
  final bool bare;

  /// 顶栏恒为小标题栏（miuix 下不再升级成大标题）。
  ///
  /// 给内容**不是整页滚动体**的二级页用（版本管理的双栏布局）：那种页面
  /// 折叠量没人记账，miuix 大标题永远收不回来，渐变模糊带也不会出现。
  /// 钉住小标题栏后走 [_MiuixSmallBar] / [_MaterialSmallBar]，顶栏常驻
  /// 渐变模糊带，内容从栏下滚过即被糊住。
  final bool pinBar;

  /// 按页背景键（MintPageBackgroundKey.id）：mtz 背景预览器把某张图指定到
  /// 本页时，PageBackground 优先用那张图。null = 不参与按页指定。
  final String? pageBackgroundKey;

  /// 内容构建器。[padding] 是标题栏**当前**占用的空间：
  /// 顶部应原样垫进主滚动体的 padding（内容才能从栏下滑过、被毛玻璃糊住），
  /// 底部在有底栏时也会带上让位距离。
  final Widget Function(EdgeInsets padding) body;

  @override
  State<MintPageScaffold> createState() => _MintPageScaffoldState();
}

class _MintPageScaffoldState extends State<MintPageScaffold> {
  /// miuix 折叠行为：大标题页 + 所有二级页（miuix 下二级页也会升级为大标题）。
  /// 用项目版子类而不是包版：短页面（内容不满一屏）只要被拖进标题栏区域就该
  /// 折叠，包版按滚动位置记账，那种页面永远记不到账。
  /// Material 分支不使用它，创建了也不会影响渲染。
  /// [MintPageScaffold.pinBar] 页没有大标题，自然也不需要折叠行为。
  late final MiuixShortPageScrollBehavior? _behavior =
      widget.largeTitle != null ||
          (widget.showBack && !widget.bare && !widget.pinBar)
      ? MiuixShortPageScrollBehavior()
      : null;

  /// Material 侧折叠进度（0 = 完全展开，1 = 收成工具栏）。
  double _fraction = 0;

  /// miuix 页面自己的 Snackbar 宿主（路由 pop 时一起销毁）。
  final MiuixSnackbarHostState _snackHost = MiuixSnackbarHostState();

  /// 当前路由（窗口标题栏托管需要 route 作为注册键）。
  Route<dynamic>? _route;
  bool _registeredInTitleBar = false;

  /// 小标题二级页在 Windows 上把 back / 标题 / 顶栏操作交给窗口标题栏，
  /// 页面内不再画第二条顶栏。大标题页和根 tab 页保持原样。
  bool get _hostedInWindow =>
      MintWindowChrome.instance.enabled &&
      widget.showBack &&
      widget.largeTitle == null &&
      _route != null;

  /// 渐变模糊顶栏开关（设置里默认开）。
  ///
  /// 这里只看设置，不再用 `ImageFilter.isShaderFilterSupported` 一刀切：
  /// [ProgressiveBlur] 在 shader filter 不可用时会自己退化成「分片
  /// BackdropFilter」逼近变半径模糊，画面仍然是透明栏 + 渐变模糊。
  /// 之前那层门槛把 miuix 二级页逼回实色栏，深色主题下就是一条黑带。
  ///
  /// 极简测试环境可能没挂 [SettingsService]，读不到就按默认值走（与
  /// [SettingsService.progressiveTopBar] 的默认值一致：**默认开**）。
  bool _progressiveTopBarOf(BuildContext context) {
    try {
      return context.watch<SettingsService>().progressiveTopBar;
    } catch (_) {
      return true;
    }
  }

  /// Material 工具栏高度（local2api `kFrostedPageBarHeight` 同款）。
  static const double _toolbarHeight = 56;

  /// 大标题区高度：展开总高 = 状态栏 + 56 + 96 = local2api
  /// `ExpressiveSliverAppBar` 的 expandedHeight 152（再 + 状态栏）。
  /// 之前只有 56，大标题紧贴工具栏、字号被迫压小，看着像条横幅。
  static const double _largeTitleBlock = 96;

  double get _expandedHeight =>
      MediaQuery.paddingOf(context).top + _toolbarHeight + _largeTitleBlock;

  bool _onScrollNotification(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final f = (n.metrics.pixels / _largeTitleBlock).clamp(0.0, 1.0);
    // 每像素 setState 会浪费帧；0.01 的步进完全看不出来。
    if ((f - _fraction).abs() < 0.01 && f != 0 && f != 1) return false;
    if (f != _fraction && mounted) setState(() => _fraction = f);
    return false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    final route = _route;
    if (_registeredInTitleBar && route != null) {
      MintWindowChrome.instance.removePage(route);
    }
    _snackHost.dispose();
    super.dispose();
  }

  Widget? _resolvedLeading(BuildContext context) {
    if (widget.leading != null) return widget.leading;
    if (!widget.showBack) return null;
    return MintTopBarAction(
      miuix: mintMiuixOf(context),
      tooltip: '返回',
      // 三套风格各自的返回箭头（fluent：chrome_back / miuix：矢量 back /
      // Material：arrow_back）。
      child: const MintBackIcon(size: 22),
      onPressed: () => Navigator.of(context).maybePop(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hosted = _hostedInWindow;
    final route = _route;
    if (hosted && route != null) {
      MintWindowChrome.instance.setPage(
        route,
        MintPageChrome(
          title: widget.title,
          showBack: widget.showBack,
          actions: widget.actions,
        ),
      );
      _registeredInTitleBar = true;
    } else if (_registeredInTitleBar && route != null) {
      MintWindowChrome.instance.removePage(route);
      _registeredInTitleBar = false;
    }

    final leading = hosted ? null : _resolvedLeading(context);
    // 渐变模糊顶栏（设置里默认开）。只对「浮动大标题」页有意义 —— 小标题栏
    // 是实心的，没有内容从它下面滚过。
    final progressive = _progressiveTopBarOf(context);
    final miuix = mintMiuixOf(context, widget.miuix);
    // miuix 下所有二级页也升级为大标题（local2api 的一级页观感）：
    // 返回键在大标题左侧，滚动后收成小标题并钉住。pinBar 页钉住小标题栏
    // （内容不是整页滚动体，折叠无人记账，大标题只会杵在原地）。
    final miuixLargeTitle =
        widget.largeTitle ??
        (!widget.pinBar && miuix && widget.showBack && !widget.bare
            ? widget.title
            : null);
    if (miuix) {
      return _buildMiuix(
        context,
        leading,
        hosted,
        progressive,
        miuixLargeTitle,
      );
    }

    // 按页背景：整个页面（含标题栏）包进作用域，PageBackground / 顶栏取色
    // 都按这把钥匙解析「按页指定」的背景图。
    Widget scope(Widget child) => widget.pageBackgroundKey == null
        ? child
        : MintPageBackgroundScope(
            keyId: widget.pageBackgroundKey!,
            child: child,
          );

    if (widget.bare) {
      return scope(_materialHost(context, widget.body(EdgeInsets.zero)));
    }

    final large = widget.largeTitle != null;
    if (large) {
      final content = Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  // 浮动大标题页：标记给滚动条策略，thumb 不探进标题。
                  child: MintFloatingTitleScope(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _onScrollNotification,
                      child: widget.body(EdgeInsets.only(top: _expandedHeight)),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: MintTopBarTone(
                    baseColor: Theme.of(context).colorScheme.surface,
                    builder: (context, foreground) => _MaterialLargeBar(
                      title: widget.title,
                      largeTitle: widget.largeTitle!,
                      leading: leading,
                      actions: widget.actions,
                      fraction: _fraction,
                      progressive: progressive,
                      foreground: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.bottomBar != null)
            SafeArea(top: false, child: widget.bottomBar!),
        ],
      );
      return scope(_materialHost(context, content));
    }

    // 二级页/紧凑页：顶栏**浮在内容上**，内容从栏下滚过并被模糊溶解
    // （local2api 的 FrostedPageBar 同款）。渐变档是渐进模糊、降级档是均匀
    // 毛玻璃，两者都是浮层，所以不再有「实心栏要另起一套布局」的分支。
    // 托管给窗口标题栏时不画页面内的小标题栏。
    final barTop = MediaQuery.paddingOf(context).top;
    final barHeight = barTop + _toolbarHeight;
    final bar = hosted
        ? null
        : MintTopBarTone(
            baseColor: Theme.of(context).colorScheme.surface,
            builder: (context, foreground) => _MaterialSmallBar(
              title: widget.title,
              leading: leading,
              actions: widget.actions,
              height: barHeight,
              progressive: progressive,
              foreground: foreground,
            ),
          );
    final smallContent = Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                // 托管给窗口标题栏时页面内没有顶栏，不能再给正文垫一条
                // 顶栏的高度 —— 否则标题栏下面永远是 56px 空白。
                child: widget.body(
                  hosted ? EdgeInsets.zero : EdgeInsets.only(top: barHeight),
                ),
              ),
              if (bar != null)
                Positioned(top: 0, left: 0, right: 0, child: bar),
            ],
          ),
        ),
        if (widget.bottomBar != null)
          SafeArea(top: false, child: widget.bottomBar!),
      ],
    );
    return scope(_materialHost(context, smallContent));
  }

  /// 一级页透明（壳的 Scaffold 负责 SnackBar）；
  /// 二级页自带 ScaffoldMessenger + Scaffold，SnackBar 才能压在推入页上。
  ///
  /// 两级都在内容底下垫 [PageBackground]（local2api 同款）：没启用背景图
  /// 时它什么都不画（观感与从前完全一致）；启用后页面背景 / 标题栏 /
  /// 内容全部浮在同一张图上，透明层不再互相叠出脏色。
  Widget _materialHost(BuildContext context, Widget content) {
    final glass = WindowBackdrop.instance.isActive;
    if (!widget.showBack) {
      final page = Material(color: Colors.transparent, child: content);
      // 首页外壳把背景图铺到了底栏下面，这里不能再画第二层（裁切不同会接缝）。
      if (MintShellBackgroundScope.of(context)) return page;
      return Stack(
        children: [
          const Positioned.fill(child: PageBackground()),
          Positioned.fill(child: page),
        ],
      );
    }
    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // 非玻璃模式给一层 surface 画布（同旧 Scaffold 底色）；
            // 玻璃模式不垫色，Mica 从全局 tint 层透上来。
            Positioned.fill(
              child: PageBackground(
                baseColor: glass ? null : Theme.of(context).colorScheme.surface,
              ),
            ),
            Positioned.fill(child: content),
          ],
        ),
      ),
    );
  }

  Widget _buildMiuix(
    BuildContext context,
    Widget? leading,
    bool hosted,
    bool progressive,
    String? largeTitle,
  ) {
    final colors = MiuixTheme.of(context).colors;
    final glass = WindowBackdrop.instance.isActive;
    final large = largeTitle != null;

    // 顶栏元素统一颜色：取背景图顶部亮度（黑/白），back、标题、动作
    // 都由 [MintTopBarTone] 在同一作用域里下发。渐变模糊带的压字色取
    // 前景色的反色（黑字配白栏、白字配黑栏），任何壁纸下都保持对比度。
    final Widget? topBar = widget.bare || hosted
        ? null
        : MintTopBarTone(
            baseColor: colors.surface,
            builder: (context, foreground) {
              final scrim = mintTopBarScrimFor(foreground);
              final bar = large
                  ? (progressive
                        ? _MiuixGradientTopBar(
                            title: widget.title,
                            largeTitle: largeTitle,
                            navigationIcon: leading,
                            actions: widget.actions,
                            scrollBehavior: _behavior,
                            tint: scrim,
                            foreground: foreground,
                          )
                        : MiuixTopAppBar(
                            title: widget.title,
                            largeTitle: largeTitle,
                            titleColor: foreground,
                            largeTitleColor: foreground,
                            navigationIcon: leading,
                            actions: widget.actions,
                            scrollBehavior: _behavior,
                            // 材质模式下用 blurTintAlpha 控制整条栏的遮罩，
                            // 别让大标题区比正文更黑；栏色取反色并留透明，
                            // 渐变档关闭时也不会变成一整块实色。
                            color: scrim.withValues(alpha: glass ? 0.40 : 0.82),
                            blurred: true,
                            blurTintAlpha: glass ? 0.25 : 0.55,
                            largeTitleBlurRadius: 12,
                          ))
                  : _MiuixSmallBar(
                      title: widget.title,
                      navigationIcon: leading,
                      actions: widget.actions,
                      progressive: progressive,
                      tint: scrim,
                      solidColor: scrim.withValues(alpha: glass ? 0.32 : 0.82),
                      foreground: foreground,
                    );
              return MiuixContentColor(color: foreground, child: bar);
            },
          );

    final scaffold = MiuixScaffold(
      // 底色交给外层 Stack 的 PageBackground / 全局玻璃 tint：
      // 页面自画不透明底色会把背景图整个盖死。
      containerColor: Colors.transparent,
      floatingActionButton: widget.floatingActionButton,
      snackbarHost: MiuixSnackbarHost(state: _snackHost),
      bottomBar: widget.bottomBar == null
          ? null
          : SafeArea(top: false, child: widget.bottomBar!),
      topBar: topBar,
      content: (padding) {
        final content = widget.body(padding);
        // 大标题页内容从标题栏下滑过：标记给滚动条策略（thumb 别进标题）。
        final wrapped = large
            ? MintFloatingTitleScope(child: content)
            : content;
        final behavior = _behavior;
        if (behavior == null) return wrapped;
        return MiuixShortPageScrollListener(behavior: behavior, child: wrapped);
      },
    );

    final scoped = MintSnackScope(
      host: _snackHost,
      // MiuixScaffold 不提供 Material 祖先；MiuixTextField / IconButton /
      // InkWell 里的 Material 依赖会直接抛 "No Material widget found"。
      // 包一层透明 Material（local2api 的 MiuixHomeShell 同款处理）。
      child: Material(type: MaterialType.transparency, child: scaffold),
    );
    // 按页背景：整个页面（含标题栏）包进作用域，PageBackground / 顶栏取色
    // 都按这把钥匙解析「按页指定」的背景图。
    final paged = widget.pageBackgroundKey == null
        ? scoped
        : MintPageBackgroundScope(
            keyId: widget.pageBackgroundKey!,
            child: scoped,
          );
    // 一级页 / 二级页统一：PageBackground 在最底层（非玻璃模式垫 surface
    // 画布，玻璃模式直接透 Mica；启用背景图时图片铺在画布上）。
    // 首页壳已铺满整屏背景时跳过，图片才能一直延伸到悬浮底栏下面。
    if (MintShellBackgroundScope.of(context)) return paged;
    return Stack(
      children: [
        Positioned.fill(
          child: PageBackground(baseColor: glass ? null : colors.surface),
        ),
        Positioned.fill(child: paged),
      ],
    );
  }
}

/// 常驻底部操作栏：一条与页面同色的浅底 + 顶部分隔线。
class MintBottomBar extends StatelessWidget {
  const MintBottomBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.35)),
        ),
      ),
      child: child,
    );
  }
}

/// 顶栏动作按钮：两套风格统一的 40×40 热区。
class MintTopBarAction extends StatelessWidget {
  const MintTopBarAction({
    super.key,
    required this.miuix,
    this.icon,
    required this.tooltip,
    required this.onPressed,
    this.child,
  });

  final bool miuix;
  final IconData? icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // 标题栏动作槽内：换成与三大金刚同规格的方形按钮（46×44 + 方形
    // InkRipple），页面内的顶栏仍是圆形 IconButton / MiuixIconButton。
    if (MintCaptionActionScope.maybeOf(context)) {
      return MintSquareCaptionAction(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: icon,
        child: child,
      );
    }
    final content = child ?? Icon(icon, size: 22);
    if (miuix) {
      return MiuixIconButton(onPressed: onPressed, child: content);
    }
    // 顶栏可能被托管到 Navigator 之上的自绘窗口标题栏（那里没有 Overlay，
    // 带 tooltip 的 IconButton 会 assert）；用 Semantics 保留可访问名称。
    return Semantics(
      label: tooltip,
      button: true,
      child: IconButton(
        onPressed: onPressed,
        icon: content,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// 圆形头像动作（顶栏右侧的账户入口）。
class MintAvatarAction extends StatelessWidget {
  const MintAvatarAction({
    super.key,
    required this.miuix,
    required this.name,
    required this.onPressed,
  });

  final bool miuix;
  final String name;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final avatar = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
      child: Text(
        initial,
        style: TextStyle(
          color: cs.onPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      ),
    );
    if (miuix) {
      return MiuixIconButton(onPressed: onPressed, child: avatar);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: IconButton(
        onPressed: onPressed,
        tooltip: '账户',
        icon: avatar,
        padding: EdgeInsets.zero,
      ),
    );
  }
}

// ───────────────────────── miuix 渐变模糊顶栏 ─────────────────────────

/// miuix 侧的「渐变模糊顶栏」（local2api / AppMarket 同款）：
///
/// - 顶栏本体**全透明**（不开毛玻璃、不做大标题模糊）—— 只有字样与动作图标；
/// - 顶部叠一条**渐进模糊带**，高度 = 状态栏 + 52dp（顶栏折叠后的高度），
///   模糊从顶边满强度沿衰减曲线过渡到底边完全清晰，叠 `surface @ 30%` 压字
///   （色一路淡到 0）。整条带的强度跟着顶栏折叠度淡入：内容没滚进来时带是
///   隐形的，滚入后逐渐显形。
///
/// 带子画在顶栏**之下**（`Stack` 先画的在下）：AppMarket 是盖在栏上的，因为
/// 它那条栏折叠后没有文字；我们折叠后要显示小标题与动作图标，盖上去会被
/// surface@30% 洗淡一层。放在下面 —— 内容糊了，字还是清的。
class _MiuixGradientTopBar extends StatelessWidget {
  const _MiuixGradientTopBar({
    required this.title,
    required this.largeTitle,
    required this.tint,
    required this.foreground,
    this.navigationIcon,
    this.actions,
    this.scrollBehavior,
  });

  final String title;
  final String largeTitle;
  final Color tint;
  final Color foreground;
  final Widget? navigationIcon;
  final List<Widget>? actions;
  final MiuixScrollBehavior? scrollBehavior;

  @override
  Widget build(BuildContext context) {
    final state = scrollBehavior?.state;
    final bandHeight = MintGradientBar.bandHeightOf(
      context,
      MintGradientBar.miuixBandHeight,
    );
    return Stack(
      children: [
        if (state != null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: ListenableBuilder(
                listenable: state,
                builder: (context, _) {
                  final t = state.collapsedFraction.clamp(0.0, 1.0);
                  if (t <= 0.001) return const SizedBox.shrink();
                  return MintProgressiveBand(
                    height: bandHeight,
                    intensity: t,
                    tint: tint,
                    maxSigma: MintGradientBar.maxSigma,
                    tintAlphaTop: MintGradientBar.tintAlphaTop,
                  );
                },
              ),
            ),
          ),
        MiuixTopAppBar(
          title: title,
          largeTitle: largeTitle,
          titleColor: foreground,
          largeTitleColor: foreground,
          navigationIcon: navigationIcon,
          actions: actions,
          scrollBehavior: scrollBehavior,
          // 透明只有样式：没有底色、不开毛玻璃、不做大标题模糊。
          color: Colors.transparent,
          blurred: false,
          largeTitleBlurRadius: 0,
        ),
      ],
    );
  }
}

/// miuix 小标题栏：默认也是「透明栏 + 顶部渐进模糊带」。
///
/// 之前二级页用 [MiuixSmallTopAppBar] 的默认实色底，深色主题下就是一条
/// 纯黑横带（截图里和内容完全断开）。local2api 的二级页 / AppMarket 的
/// 导航页都是透明栏 + 顶部渐变模糊：内容从栏下滚过，只有滚入时才在顶上
/// 慢慢糊开。设置里关掉「渐变模糊顶栏」或渲染路径不支持着色器时，退回
/// 原来的实色栏，保证任何环境都有背景可读。
class _MiuixSmallBar extends StatelessWidget {
  const _MiuixSmallBar({
    required this.title,
    this.navigationIcon,
    this.actions,
    required this.progressive,
    required this.tint,
    required this.solidColor,
    required this.foreground,
  });

  final String title;
  final Widget? navigationIcon;
  final List<Widget>? actions;
  final bool progressive;
  final Color tint;
  final Color solidColor;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    if (!progressive) {
      // 不支持渐进模糊 / 用户关掉开关时：半透明 + 均匀毛玻璃，而不是退回
      // 实色（深色主题下就是截图里那条全黑横带）。
      final tint = solidColor.a < 0.99
          ? solidColor
          : solidColor.withValues(alpha: 0.82);
      return ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: MiuixSmallTopAppBar(
            title: title,
            navigationIcon: navigationIcon,
            actions: actions,
            color: tint,
            titleColor: foreground,
          ),
        ),
      );
    }
    // 小标题栏净高 50（MiuixTopAppBarDefaults.smallTopAppBarCenterHeight），
    // 带高再加状态栏，与栏体完全对齐；固定 intensity=1 —— 二级页的内容
    // 本来就从栏下开始滚，不存在「没滚进来」的展开态。
    final bandHeight =
        (MediaQuery.paddingOf(context).top +
                MiuixTopAppBarDefaults.smallTopAppBarCenterHeight)
            .clamp(56.0, 200.0);
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(
            child: MintProgressiveBand(
              height: bandHeight,
              intensity: 1,
              tint: tint,
              maxSigma: MintGradientBar.maxSigma,
              tintAlphaTop: MintGradientBar.tintAlphaTop,
            ),
          ),
        ),
        MiuixSmallTopAppBar(
          title: title,
          navigationIcon: navigationIcon,
          actions: actions,
          color: Colors.transparent,
          titleColor: foreground,
        ),
      ],
    );
  }
}

// ───────────────────────── Material 标题栏 ─────────────────────────

/// 展开态大标题栏：底部大标题 + 折叠后毛玻璃工具栏（local2api
/// `ExpressiveSliverAppBar` 的「栏下穿过」语义）。
///
/// 规格照搬 local2api，几处与旧实现不同（旧版「有点丑」基本都在这里）：
///  - 展开总高 152（+ 状态栏），大标题区 96 而不是 56 —— 大标题才有呼吸空间；
///  - 大标题用 `headlineMedium` + w500（28sp）而不是硬编码 32/700，左内边距
///    16、距底 28，与 local2api 逐项对齐；
///  - 折叠小标题 16/600，透明度**直接等于折叠度**（local2api
///    `Opacity(collapsedFraction)`），不再有 0.35 之后的阈值跳变；
///  - 渐变档的压字色从 0.42 提到 0.7，跟 local2api 的 `blurOpacity` 一致：
///    0.42 太透，小标题压在亮内容上会看不清。
class _MaterialLargeBar extends StatelessWidget {
  const _MaterialLargeBar({
    required this.title,
    required this.largeTitle,
    required this.leading,
    required this.actions,
    required this.fraction,
    required this.progressive,
    required this.foreground,
  });

  final String title;
  final String largeTitle;
  final Widget? leading;
  final List<Widget> actions;
  final double fraction;

  /// 渐变模糊（true）还是老的均匀毛玻璃（false）。
  final bool progressive;

  /// 顶栏元素统一颜色（黑/白，由背景亮度决定）。
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final f = fraction.clamp(0.0, 1.0);
    final barH = topInset + _MintPageScaffoldState._toolbarHeight;
    final largeOpacity = (1 - f * 2.0).clamp(0.0, 1.0);

    return SizedBox(
      height:
          topInset +
          _MintPageScaffoldState._toolbarHeight +
          _MintPageScaffoldState._largeTitleBlock,
      child: Stack(
        children: [
          // 折叠后的毛玻璃（没滚时不画，省一次 backdrop 采样）。
          // 只铺工具栏高度：大标题区在折叠后是空的，跟着糊一整块会显得
          // 顶栏「很厚」，内容像被压住。
          //
          // 渐变模式（progressive）：sigma 从 0 长到满值，下缘溶解、无硬边，
          // 所以也不画那条 0.5 的分割线 —— 那正是渐变模糊要避免的东西。
          if (f > 0.01)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: barH,
              child: progressive
                  ? MintProgressiveBand(
                      height: barH,
                      intensity: f,
                      tint: mintTopBarScrimFor(foreground),
                      maxSigma: 12,
                      tintAlphaTop: 0.7,
                    )
                  : ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(
                          sigmaX: 12 * f,
                          sigmaY: 12 * f,
                        ),
                        child: ColoredBox(
                          color: mintTopBarScrimFor(
                            foreground,
                          ).withValues(alpha: 0.86 * f),
                        ),
                      ),
                    ),
            ),
          // 工具栏：返回 + 折叠小标题 + 动作。
          Positioned(
            top: topInset,
            left: 0,
            right: 0,
            height: _MintPageScaffoldState._toolbarHeight,
            child: Row(
              children: [
                SizedBox(width: leading == null ? 16 : 8),
                ?leading,
                if (leading != null) const SizedBox(width: 12),
                Expanded(
                  child: Opacity(
                    key: const ValueKey('mint.material.smallTitle'),
                    opacity: f,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: foreground,
                      ),
                    ),
                  ),
                ),
                ...actions,
                const SizedBox(width: 8),
              ],
            ),
          ),
          // 展开态大标题（贴着工具栏下缘，随滚动上移淡出）。
          // IgnorePointer：折叠后它还在树上但透明，不能挡住下方内容的点击。
          Positioned(
            left: 16,
            right: 16,
            bottom: 28,
            child: IgnorePointer(
              child: Opacity(
                key: const ValueKey('mint.material.largeTitle'),
                opacity: largeOpacity,
                child: Transform.translate(
                  offset: Offset(0, -18 * f),
                  child: Text(
                    largeTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: foreground,
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

/// Material 小标题栏（二级页/紧凑一级页）。
///
/// 和 local2api 的 `FrostedPageBar` 同规格：净高 56（状态栏由 SafeArea 处理）、
/// 返回键后 12 间距、标题 16/600。
///
/// 两种模糊档都**浮在内容之上**（内容从栏下滚过并被糊掉）：
///  - 渐变档 —— 顶边满强度往下溶解的渐进模糊带（`maxSigma: 12`,
///    `tintAlphaTop: 0.75`），intensity 恒为 1，不跟折叠度走；shader filter
///    不可用时由 [ProgressiveBlur] 自己用分片 BackdropFilter 兜底；
///  - 设置里关掉渐变档 —— 均匀 `BackdropFilter` + `surface @ 0.75`
///    （local2api 的 `FrostedPanel`），仍然是毛玻璃而不是实心板。
class _MaterialSmallBar extends StatelessWidget {
  const _MaterialSmallBar({
    required this.title,
    required this.leading,
    required this.actions,
    required this.height,
    required this.progressive,
    required this.foreground,
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final double height;
  final bool progressive;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final row = SafeArea(
      bottom: false,
      child: SizedBox(
        height: _MintPageScaffoldState._toolbarHeight,
        child: Row(
          children: [
            const SizedBox(width: 8),
            ?leading,
            if (leading != null) const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ),
            ...actions,
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
    if (progressive) {
      return SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: MintProgressiveBand(
                  height: height,
                  intensity: 1,
                  tint: mintTopBarScrimFor(foreground),
                  maxSigma: 12,
                  tintAlphaTop: 0.75,
                ),
              ),
            ),
            Positioned.fill(child: row),
          ],
        ),
      );
    }
    // 没有 fragment shader 也要保住「内容从栏下穿过」的观感：均匀模糊 + 半透
    // 明底色，比直接铺一层实心 surface 干净得多。
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          color: mintTopBarScrimFor(foreground).withValues(alpha: 0.75),
          child: row,
        ),
      ),
    );
  }
}

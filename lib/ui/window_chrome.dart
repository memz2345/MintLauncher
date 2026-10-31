import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'package:mint/services/download_center.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/src/enums.dart';
import 'package:mint/services/window_backdrop.dart';
import 'package:mint/services/window_caption_signals.dart';
import 'package:mint/ui/mint_icons.dart';
import 'package:mint/widgets/mdui_ripple.dart' show mintSplashFactory;
import 'package:mint/ui/pages/download_manager_page.dart';

/// 自绘窗口标题栏高度（逻辑像素）。native 侧顶部保留几像素缩放热区，
/// 所以按钮顶边稍微靠近边缘也能点中。
const double kMintCaptionHeight = 44;

/// 标题栏按钮宽度。返回键、最小化/最大化/关闭统一用这一宽度，
/// 与原生 caption 的 46dp 对齐（Snap Layouts 的命中矩形也按它算）。
const double kMintCaptionButtonWidth = 46;

/// 某个二级页在窗口标题栏里的描述。
@immutable
class MintPageChrome {
  const MintPageChrome({
    required this.title,
    required this.showBack,
    required this.actions,
  });

  final String title;
  final bool showBack;
  final List<Widget> actions;
}

/// 标题栏状态总线。
///
/// 主应用的标题栏画在 Navigator **上面**（不属于任何页面），所以页面要
/// 把自己的标题 / back / 操作注册进来；再配合 [MintNavigatorObserver]
/// 只显示当前 route 的那份，推入/弹出/对话框都不会串。
class MintWindowChrome extends ChangeNotifier {
  MintWindowChrome._();

  static final MintWindowChrome instance = MintWindowChrome._();

  /// 只有真正画了自绘标题栏的平台才让页面把顶栏托管上来。
  /// 由 MintApp 在构建前设置；widget 测试默认 false，页面保持原来的顶栏。
  bool enabled = false;

  final MintNavigatorObserver observer = MintNavigatorObserver();

  Route<dynamic>? _route;
  final Map<Route<dynamic>, MintPageChrome> _pages = {};
  bool _notifyScheduled = false;

  Route<dynamic>? get currentRoute => _route;

  MintPageChrome? get currentPage => _route == null ? null : _pages[_route];

  void setCurrentRoute(Route<dynamic>? route) {
    if (identical(route, _route)) return;
    _route = route;
    // NavigatorObserver 的 didPush 可能在 Navigator 构建期间触发；直接
    // notify 会让上面的标题栏在 build 中 markNeedsBuild，必须延到帧后。
    _scheduleNotify();
  }

  void setPage(Route<dynamic> route, MintPageChrome page) {
    final old = _pages[route];
    _pages[route] = page;
    if (!identical(route, _route)) return;
    if (old != null &&
        old.title == page.title &&
        old.showBack == page.showBack &&
        old.actions.length == page.actions.length) {
      return;
    }
    _scheduleNotify();
  }

  void removePage(Route<dynamic> route) {
    final removed = _pages.remove(route);
    if (removed != null && identical(route, _route)) _scheduleNotify();
  }

  bool hasPage(Route<dynamic> route) => _pages.containsKey(route);

  /// 测试用：清空路由/页面注册，避免单例跨测试串状态。
  void reset() {
    _route = null;
    _pages.clear();
    notifyListeners();
  }

  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }
}

/// 只把真正的页面路由当「当前页」；对话框 / 菜单是 PopupRoute，不参与。
class MintNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) MintWindowChrome.instance.setCurrentRoute(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PageRoute) return;
    MintWindowChrome.instance.setCurrentRoute(
      previousRoute is PageRoute ? previousRoute : null,
    );
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PageRoute) return;
    if (identical(MintWindowChrome.instance.currentRoute, route)) {
      MintWindowChrome.instance.setCurrentRoute(
        previousRoute is PageRoute ? previousRoute : null,
      );
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute is PageRoute) {
      MintWindowChrome.instance.setCurrentRoute(newRoute);
    }
  }
}

/// 主应用顶部标题栏：根页面显示应用名；二级页显示 back + 标题 + 操作。
class MintWindowTitleBar extends StatelessWidget {
  const MintWindowTitleBar({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    final chrome = MintWindowChrome.instance;
    return AnimatedBuilder(
      animation: chrome,
      builder: (context, _) {
        if (!chrome.enabled) return const SizedBox.shrink();
        final page = chrome.currentPage;
        final hosted = page != null && page.showBack;
        final canPop = navigatorKey.currentState?.canPop() ?? false;
        return MintCaptionBar(
          title: hosted ? page.title : 'Mint Launcher',
          leading: hosted
              ? (canPop
                    ? _CaptionChromeButton(
                        key: const ValueKey('caption-back'),
                        tooltip: '返回',
                        onPressed: () => navigatorKey.currentState?.maybePop(),
                        child: const MintBackIcon(size: 22),
                      )
                    : const _AppBadge())
              : const _AppBadge(),
          actions: hosted ? page.actions : const [],
          navigatorKey: navigatorKey,
        );
      },
    );
  }
}

/// 通用自绘标题栏。主窗口和独立日志窗口共用。
class MintCaptionBar extends StatefulWidget {
  const MintCaptionBar({
    super.key,
    required this.title,
    this.leading,
    this.actions = const [],
    this.navigatorKey,
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;

  /// 给了就在三大金刚左侧显示「下载」按钮（有任务时才出现）。
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<MintCaptionBar> createState() => _MintCaptionBarState();
}

class _MintCaptionBarState extends State<MintCaptionBar> with WindowListener {
  bool _maximized = false;
  bool _fullscreen = false;
  DateTime? _lastTitleTap;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WindowCaptionSignals.instance.bind();
    _syncState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncState() async {
    try {
      final maximized = await windowManager.isMaximized();
      final fullscreen = await windowManager.isFullScreen();
      if (!mounted) return;
      if (_maximized != maximized || _fullscreen != fullscreen) {
        setState(() {
          _maximized = maximized;
          _fullscreen = fullscreen;
        });
      }
    } catch (_) {
      // 测试 / 窗口尚未就绪。
    }
  }

  @override
  void onWindowMaximize() {
    WindowBackdrop.instance.reapplyCaption();
    setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    WindowBackdrop.instance.reapplyCaption();
    setState(() => _maximized = false);
  }

  @override
  void onWindowFocus() => WindowBackdrop.instance.reapplyCaption();

  @override
  void onWindowEnterFullScreen() => setState(() => _fullscreen = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _fullscreen = false);

  Future<void> _minimize() async {
    try {
      await windowManager.minimize();
    } catch (_) {}
  }

  Future<void> _toggleMaximize() async {
    try {
      // WS_CAPTION 保留后，SC_MAXIMIZE / SC_RESTORE 的缩放动画由 DWM
      // 原生播放；这里只负责触发。补一次状态同步，不依赖
      // window_manager 的 WM_SIZE 事件是否会漏。
      await WindowCaptionSignals.instance.toggleMaximize();
      Future<void>.delayed(const Duration(milliseconds: 120), _syncState);
      return;
    } catch (_) {}
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {}
  }

  Future<void> _close() async {
    try {
      await windowManager.close();
    } catch (_) {}
  }

  Future<void> _drag() async {
    try {
      await windowManager.startDragging();
    } catch (_) {}
  }

  Future<void> _systemMenu(TapUpDetails details) async {
    // Windows 用原生系统菜单（GetSystemMenu + TrackPopupMenu）：还原 / 移动 /
    // 大小 / 最小化 / 最大化 / 关闭 的文案、灰置状态、Alt+F4 提示都由系统
    // 提供，和资源管理器一致。原生通道不可用（测试 / 非 Windows）再回退到
    // 自绘菜单。
    if (Platform.isWindows) {
      try {
        await WindowCaptionSignals.instance.showSystemMenu();
        return;
      } catch (_) {
        // 回退到下面的自绘菜单。
      }
    }
    await showMintCaptionMenu(
      context,
      position: details.globalPosition,
      items: [
        // Windows 系统菜单同款布局：还原/最大化互斥显示，关闭带 Alt+F4。
        if (_maximized)
          MintCaptionMenuItem(
            label: '还原(R)',
            icon: Icons.filter_none,
            onPressed: _toggleMaximize,
          )
        else
          MintCaptionMenuItem(
            label: '最大化(X)',
            icon: Icons.crop_square,
            onPressed: _toggleMaximize,
          ),
        MintCaptionMenuItem(
          label: '移动(M)',
          icon: Icons.open_with,
          onPressed: () => windowManager.startDragging(),
        ),
        MintCaptionMenuItem(
          label: '大小(S)',
          icon: Icons.open_in_full,
          // 最大化状态不允许拉伸（热区也收掉了）。
          onPressed: _maximized
              ? null
              : () => windowManager.startResizing(ResizeEdge.bottomRight),
        ),
        const MintCaptionMenuItem.separator(),
        MintCaptionMenuItem(
          label: '最小化(N)',
          icon: Icons.remove,
          onPressed: _minimize,
        ),
        if (_maximized)
          MintCaptionMenuItem(label: '最大化(X)', icon: Icons.crop_square)
        else
          MintCaptionMenuItem(label: '还原(R)', icon: Icons.filter_none),
        MintCaptionMenuItem(
          label: '关闭(C)',
          icon: Icons.close,
          onPressed: _close,
          // Alt+F4 由主窗口 GlobalShortcutHost 兑现；日志窗口没有这个
          // 宿主，不标快捷键。
          trailing: widget.navigatorKey != null ? 'Alt+F4' : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_fullscreen) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final glass = WindowBackdrop.instance.isActive;
    // 材质模式下标题栏必须完全透明，让 DWM 的 Mica/Acrylic 从窗口底色
    // 透上来；再叠一层 surface 半透明会把材质压成一块死黑。
    final bg = glass ? Colors.transparent : cs.surface;
    final titleColor = cs.onSurface;

    return Material(
      type: MaterialType.transparency,
      child: Container(
        height: kMintCaptionHeight,
        decoration: BoxDecoration(
          color: bg,
          border: Border(
            bottom: BorderSide(
              color: cs.outlineVariant.withValues(alpha: glass ? 0.18 : 0.35),
            ),
          ),
        ),
        child: ClipRect(
          child: Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              if (widget.leading != null) widget.leading!,
              if (widget.leading == null) const SizedBox(width: 12),
              Expanded(
                child: MouseRegion(
                  cursor: SystemMouseCursors.basic,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => _drag(),
                    onTapUp: (_) {
                      final now = DateTime.now();
                      final last = _lastTitleTap;
                      if (last != null &&
                          now.difference(last) <
                              const Duration(milliseconds: 500)) {
                        _lastTitleTap = null;
                        _toggleMaximize();
                      } else {
                        _lastTitleTap = now;
                      }
                    },
                    onSecondaryTapUp: (details) => _systemMenu(details),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        // 自绘 caption 只保留一个主标题：副标题会让 44px 的
                        // 系统栏挤成两行，和原生窗口观感差太多。
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: titleColor.withValues(alpha: 0.92),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 页面托管的顶栏动作：统一塞进 44px 高的槽里。IconButton 默认
              // 48×48 的最小约束，直接摆进 44 高的 Row 会上下各溢 2px 压到
              // 页面内容上（这就是「顶栏按钮和内容重叠」的来源）。
              for (final action in widget.actions)
                _CaptionActionSlot(child: action),
              // 下载中才出现：位于最小化左侧，点了进下载管理页。
              if (widget.navigatorKey != null)
                _CaptionDownloadButton(navigatorKey: widget.navigatorKey!),
              _CaptionChromeButton(
                key: const ValueKey('caption-min'),
                tooltip: '最小化',
                onPressed: _minimize,
                child: _captionGlyph(glyph: 0xE921, fallbackIcon: Icons.remove),
              ),
              _CaptionChromeButton(
                key: const ValueKey('caption-max'),
                tooltip: _maximized ? '还原' : '最大化',
                maximize: true,
                onPressed: _toggleMaximize,
                child: _MaximizeGlyph(restored: _maximized),
              ),
              _CaptionChromeButton(
                key: const ValueKey('caption-close'),
                tooltip: '关闭',
                close: true,
                onPressed: _close,
                child: _captionGlyph(glyph: 0xE8BB, fallbackIcon: Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppBadge extends StatelessWidget {
  const _AppBadge();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 10, right: 8),
      child: Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.primary,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          'M',
          style: TextStyle(
            color: cs.onPrimary,
            fontSize: 11.5,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

/// 标题栏里托管的页面动作槽：固定 44×44 居中对齐。
///
/// 页面顶栏的 IconButton 自带 48×48 的最小约束（M3 默认），直接放进 44 高的
/// caption 里会上下各溢 2px，压在页面正文上 —— 这就是之前「顶栏按钮和内容
/// 重叠」的来源。槽位把高度钉死，超出的部分由整条栏的 ClipRect 裁掉。
class _CaptionActionSlot extends StatelessWidget {
  const _CaptionActionSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kMintCaptionButtonWidth,
      height: kMintCaptionHeight,
      // 标记「在标题栏里」：MintTopBarAction 据此把圆形 IconButton 换成
      // 与三大金刚同规格的方形按钮（MintSquareCaptionAction）。
      child: MintCaptionActionScope(child: child),
    );
  }
}

/// 标题栏的下载按钮：只在有任务在跑时出现，位于最小化左侧。
///
/// 图标外套一圈进度环（总进度），点击进下载管理页 —— PCL2 的「下载」入口
/// 同款：不占侧栏，任务一开始就长在标题栏上。
class _CaptionDownloadButton extends StatelessWidget {
  const _CaptionDownloadButton({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  void _open(BuildContext context) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    // 已经在下载管理页上就别叠第二层（连点标题栏按钮会堆一摞路由）。
    if (MintWindowChrome.instance.currentPage?.title == '下载管理') return;
    final miuix = context.read<SettingsService>().uiStyle.isMiuix;
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadManagerPage(miuix: miuix),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final center = DownloadCenter.instance;
    return AnimatedBuilder(
      animation: center,
      builder: (context, _) {
        if (!center.hasActive) return const SizedBox.shrink();
        final progress = center.overallProgress;
        final cs = Theme.of(context).colorScheme;
        return _CaptionChromeButton(
          key: const ValueKey('caption-download'),
          tooltip: progress == null
              ? '下载管理'
              : '下载管理 · ${(progress * 100).toStringAsFixed(0)}%',
          onPressed: () => _open(context),
          child: SizedBox(
            width: 24,
            height: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 进度环：material/miuix/fluent 都用同一个几何，只是颜色跟主题。
                if (progress != null)
                  Positioned.fill(
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 1.8,
                      backgroundColor: cs.onSurface.withValues(alpha: 0.14),
                      valueColor: AlwaysStoppedAnimation(cs.primary),
                    ),
                  ),
                const MintDownloadIcon(size: 13),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 单个标题栏按钮：46×44 热区 + M3 风格 state layer + **Flutter 原生
/// InkRipple**（Material/InkWell 提供，非自绘）。
///
/// 最大化按钮位于原生 Snap Layouts 热区里，Flutter 收不到鼠标事件，
/// 所以它的 hover / 点击由原生 `mint/window_chrome` 通道回传（见
/// [WindowCaptionSignals]）；原生点击没有指针事件可喂给 InkWell，
/// 这里通过 [MaterialInkController] 手动种一个真·InkRipple。
/// 返回键和另外两个金刚走普通指针事件，InkWell 自己出 ripple。
class _CaptionChromeButton extends StatefulWidget {
  const _CaptionChromeButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.close = false,
    this.maximize = false,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Widget child;
  final bool close;

  /// 监听原生最大化热区的 hover / click。
  final bool maximize;

  @override
  State<_CaptionChromeButton> createState() => _CaptionChromeButtonState();
}

class _CaptionChromeButtonState extends State<_CaptionChromeButton> {
  bool _hover = false;
  bool _pressed = false;

  /// 最大化按钮的 InkWell 被原生热区盖住，收不到真实指针事件。原生按下 /
  /// 松开经 [WindowCaptionSignals] 回传后，这里在按钮中心合成一对 pointer
  /// down / up（或 cancel），让水波、按压态、点击时序都和其余金刚完全同源。
  final GlobalKey _buttonKey = GlobalKey();
  static int _syntheticPointerSeed = 0x4D4E0000;
  final int _syntheticPointer = _syntheticPointerSeed++;
  int? _activeSyntheticPointer;
  Offset? _syntheticPosition;
  int _syntheticViewId = 0;

  @override
  void initState() {
    super.initState();
    if (widget.maximize) {
      final signals = WindowCaptionSignals.instance;
      signals.maximizeHover.addListener(_onNativeHover);
      signals.maximizeClick.addListener(_onNativeClick);
      signals.maximizeRelease.addListener(_onNativeRelease);
      _hover = signals.maximizeHover.value;
    }
  }

  @override
  void dispose() {
    if (widget.maximize) {
      final signals = WindowCaptionSignals.instance;
      signals.maximizeHover.removeListener(_onNativeHover);
      signals.maximizeClick.removeListener(_onNativeClick);
      signals.maximizeRelease.removeListener(_onNativeRelease);
    }
    super.dispose();
  }

  void _onNativeHover() {
    if (!mounted) return;
    final value = WindowCaptionSignals.instance.maximizeHover.value;
    if (value == _hover) return;
    setState(() => _hover = value);
  }

  void _onNativeClick() {
    if (!mounted) return;
    // 上次 release 信号万一漏了，先把旧指针取消，别让 InkWell 卡在按下态。
    if (_activeSyntheticPointer != null) {
      _finishSyntheticPress(activate: false);
    }
    final box = _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final position = box.localToGlobal(box.size.center(Offset.zero));
    _syntheticViewId = View.of(context).viewId;
    _activeSyntheticPointer = _syntheticPointer;
    _syntheticPosition = position;
    setState(() => _pressed = true);
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        pointer: _syntheticPointer,
        position: position,
        viewId: _syntheticViewId,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
        device: 0x4D4E,
      ),
    );
  }

  void _onNativeRelease() {
    if (!mounted) return;
    final activate = WindowCaptionSignals.instance.maximizeReleaseActivated;
    if (_activeSyntheticPointer == null) {
      // 没合成 down（按钮还没布局）时至少别把点击丢了。
      if (activate) widget.onPressed();
      return;
    }
    _finishSyntheticPress(activate: activate);
  }

  void _finishSyntheticPress({required bool activate}) {
    final position = _syntheticPosition;
    _activeSyntheticPointer = null;
    _syntheticPosition = null;
    if (position != null) {
      GestureBinding.instance.handlePointerEvent(
        activate
            ? PointerUpEvent(
                pointer: _syntheticPointer,
                position: position,
                viewId: _syntheticViewId,
                kind: PointerDeviceKind.mouse,
              )
            : PointerCancelEvent(
                pointer: _syntheticPointer,
                position: position,
                viewId: _syntheticViewId,
                kind: PointerDeviceKind.mouse,
              ),
      );
    }
    if (mounted) setState(() => _pressed = false);
  }

  Color _splashColor(ColorScheme cs) =>
      (widget.close ? Colors.white : cs.onSurface).withValues(alpha: 0.18);

  void _setHover(bool value) {
    if (!widget.maximize &&
        value &&
        WindowCaptionSignals.instance.maximizeHover.value) {
      // 指针从最大化热区移到别的金刚上：原生不一定再给 NCHITTEST。
      WindowCaptionSignals.instance.maximizeHover.value = false;
    }
    if (_hover == value) return;
    setState(() => _hover = value);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final closeRed = const Color(0xFFC42B1C);
    Color bg = Colors.transparent;
    Color fg = cs.onSurface.withValues(alpha: 0.82);
    if (widget.close && (_hover || _pressed)) {
      bg = _pressed ? const Color(0xFFB22A1B) : closeRed;
      fg = Colors.white;
    } else if (_hover) {
      bg = cs.onSurface.withValues(alpha: _pressed ? 0.14 : 0.07);
    } else if (_pressed) {
      bg = cs.onSurface.withValues(alpha: 0.10);
    }

    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: SizedBox(
          key: _buttonKey,
          width: kMintCaptionButtonWidth,
          height: kMintCaptionHeight,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedContainer(
                  key: ValueKey('caption-bg-${widget.tooltip}'),
                  duration: const Duration(milliseconds: 90),
                  curve: Curves.easeOutCubic,
                  color: bg,
                ),
                // 悬浮/按压底色仍由上面的 AnimatedContainer 画（Windows
                // caption 风格）；InkWell 的 hover/highlight 置透明，只借
                // 它的 ripple 与点击语义。最大化按钮的 pointer down/up 由
                // 原生热区信号合成（见 _onNativeClick）。
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: ValueKey('caption-ink-${widget.tooltip}'),
                    onTap: widget.onPressed,
                    hoverColor: Colors.transparent,
                    focusColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    splashColor: _splashColor(cs),
                    splashFactory: mintSplashFactory,
                    child: Center(
                      child: IconTheme(
                        data: IconThemeData(color: fg),
                        child: DefaultTextStyle(
                          style: TextStyle(color: fg),
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Semantics(label: widget.tooltip, button: true, child: button);
  }
}

Widget _captionGlyph({required int glyph, required IconData fallbackIcon}) =>
    _CaptionGlyph(glyph: glyph, fallbackIcon: fallbackIcon);

class _CaptionGlyph extends StatelessWidget {
  const _CaptionGlyph({required this.glyph, required this.fallbackIcon});

  final int glyph;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final color =
        DefaultTextStyle.of(context).style.color ??
        Theme.of(context).colorScheme.onSurface;
    if (!Platform.isWindows) {
      return Icon(fallbackIcon, size: 16, color: color);
    }
    return Text(
      String.fromCharCode(glyph),
      style: TextStyle(
        fontFamily: 'Segoe Fluent Icons',
        fontFamilyFallback: const ['Segoe MDL2 Assets'],
        fontSize: 10,
        height: 1,
        color: color,
        decoration: TextDecoration.none,
      ),
    );
  }
}

/// 最大化 / 还原字形放在一个组件里，跟随标题栏状态切换。
class _MaximizeGlyph extends StatelessWidget {
  const _MaximizeGlyph({required this.restored});

  final bool restored;

  @override
  Widget build(BuildContext context) {
    return _CaptionGlyph(
      glyph: restored ? 0xE923 : 0xE922,
      fallbackIcon: restored ? Icons.filter_none : Icons.crop_square,
    );
  }
}

/// 贴边缩放热区。
///
/// 自绘窗口后 Flutter 子窗口铺满客户区，原生 WM_NCHITTEST 在子窗口上收不到；
/// 这里用 5px 透明热区接管鼠标，拖动时调 window_manager.startResizing，
/// 和系统 caption 的手感一致。主窗口和日志子窗口共用。
class MintWindowResizeFrame extends StatefulWidget {
  const MintWindowResizeFrame({super.key, required this.child});

  final Widget child;

  @override
  State<MintWindowResizeFrame> createState() => _MintWindowResizeFrameState();
}

class _MintWindowResizeFrameState extends State<MintWindowResizeFrame>
    with WindowListener {
  static const double _edge = 5;
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _sync();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  /// 全屏**或最大化**时收掉拉伸热区：startResizing 走 NC 尺寸循环，
  /// 不经过 WM_NCHITTEST 的 IsZoomed 守卫，最大化后仍会把窗口拉变形，
  /// 客户区与窗口矩形错开就会出现「内容断头」。
  Future<void> _sync() async {
    try {
      final hidden =
          await windowManager.isMaximized() ||
          await windowManager.isFullScreen();
      if (!mounted) return;
      if (hidden != _hidden) setState(() => _hidden = hidden);
    } catch (_) {
      // 测试 / 窗口尚未就绪。
    }
  }

  @override
  void onWindowMaximize() {
    if (!_hidden) setState(() => _hidden = true);
  }

  @override
  void onWindowUnmaximize() {
    if (_hidden) setState(() => _hidden = false);
  }

  @override
  void onWindowEnterFullScreen() => setState(() => _hidden = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _hidden = false);

  @override
  Widget build(BuildContext context) {
    if (_hidden) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: _edge,
          child: const _ResizeHandle(
            edge: ResizeEdge.top,
            cursor: SystemMouseCursors.resizeUpDown,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: _edge,
          child: const _ResizeHandle(
            edge: ResizeEdge.bottom,
            cursor: SystemMouseCursors.resizeUpDown,
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          left: 0,
          width: _edge,
          child: const _ResizeHandle(
            edge: ResizeEdge.left,
            cursor: SystemMouseCursors.resizeLeftRight,
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: _edge,
          child: const _ResizeHandle(
            edge: ResizeEdge.right,
            cursor: SystemMouseCursors.resizeLeftRight,
          ),
        ),
        const Positioned(
          left: 0,
          top: 0,
          width: _edge * 2,
          height: _edge * 2,
          child: _ResizeHandle(
            edge: ResizeEdge.topLeft,
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
          ),
        ),
        const Positioned(
          right: 0,
          top: 0,
          width: _edge * 2,
          height: _edge * 2,
          child: _ResizeHandle(
            edge: ResizeEdge.topRight,
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
          ),
        ),
        const Positioned(
          left: 0,
          bottom: 0,
          width: _edge * 2,
          height: _edge * 2,
          child: _ResizeHandle(
            edge: ResizeEdge.bottomLeft,
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
          ),
        ),
        const Positioned(
          right: 0,
          bottom: 0,
          width: _edge * 2,
          height: _edge * 2,
          child: _ResizeHandle(
            edge: ResizeEdge.bottomRight,
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
          ),
        ),
      ],
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.edge, required this.cursor});

  final ResizeEdge edge;
  final MouseCursor cursor;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) async {
          // 双保险：热区已在最大化时收掉，这里再挡一次异步竞态
          // （最大化事件与指针按下几乎同时到达的情况）。
          try {
            if (await windowManager.isMaximized() ||
                await windowManager.isFullScreen()) {
              return;
            }
          } catch (_) {}
          windowManager.startResizing(edge).catchError((_) {});
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ───────────────────────── 标题栏右键菜单 ─────────────────────────

/// 标题栏右键菜单的一条目。[onPressed] 为 null = 灰置（Windows 同款）。
class MintCaptionMenuItem {
  const MintCaptionMenuItem({
    required this.label,
    this.icon,
    this.trailing,
    this.onPressed,
    this.isSeparator = false,
  });

  /// 分隔线。
  const MintCaptionMenuItem.separator()
    : label = '',
      icon = null,
      trailing = null,
      onPressed = null,
      isSeparator = true;

  final String label;
  final IconData? icon;
  final String? trailing;
  final VoidCallback? onPressed;
  final bool isSeparator;
}

/// 标题栏右键菜单的宿主：包住整个窗口内容，内部垫一层专属 [Overlay]，
/// 菜单以 OverlayEntry 形式盖在所有内容之上。
///
/// 为什么不用 showMenu：标题栏在 MaterialApp builder 里，位于 Navigator
/// **之外**（主窗口与日志窗口同构），向上找不到 Navigator / Overlay，
/// PopupRoute 无处安放。自建宿主层后两个窗口行为一致。
class MintCaptionMenuHost extends StatefulWidget {
  const MintCaptionMenuHost({super.key, required this.child});

  final Widget child;

  @override
  State<MintCaptionMenuHost> createState() => _MintCaptionMenuHostState();
}

class _MintCaptionMenuHostState extends State<MintCaptionMenuHost> {
  final GlobalKey<OverlayState> _overlayKey = GlobalKey<OverlayState>();
  final Set<OverlayEntry> _openEntries = {};

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        // 菜单层：零条目时无 hit target，不影响正文。
        Positioned.fill(child: Overlay(key: _overlayKey)),
      ],
    );
  }

  void _insert(OverlayEntry entry) {
    _openEntries.add(entry);
    _overlayKey.currentState?.insert(entry);
  }

  void _remove(OverlayEntry entry) {
    if (!_openEntries.remove(entry)) return;
    if (_overlayKey.currentState == null) return;
    entry.remove();
  }
}

/// 弹出标题栏右键菜单（自绘，Windows 系统菜单观感）。关闭方式：
/// 点菜单外任意位置 / 选中一条目。菜单宽约 232、按条目数自适应高度，
/// 越靠近屏幕右/下缘自动往里收。
Future<void> showMintCaptionMenu(
  BuildContext context, {
  required Offset position,
  required List<MintCaptionMenuItem> items,
  bool showAltF4Hint = false,
}) async {
  final hostState = context
      .findAncestorStateOfType<_MintCaptionMenuHostState>();
  if (hostState == null) return;
  final theme = Theme.of(context);
  final size = MediaQuery.sizeOf(context);

  const menuWidth = 232.0;
  final itemHeight = 34.0;
  final dividerCount = items.where((i) => i.isSeparator).length;
  final menuHeight =
      (items.length - dividerCount) * itemHeight + dividerCount * 9 + 12;
  final left = (position.dx + menuWidth > size.width - 8)
      ? size.width - menuWidth - 8
      : position.dx;
  final top = (position.dy + menuHeight > size.height - 8)
      ? size.height - menuHeight - 8
      : position.dy;

  late final OverlayEntry entry;
  void dismiss() => hostState._remove(entry);

  entry = OverlayEntry(
    builder: (menuContext) => Theme(
      data: theme,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            // 捕获层：点外面（左键/右键/滚动拖拽）就收。opaque = 模态：
            // 收起菜单的同时不误触底下的页面控件（Windows 系统菜单同款）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: dismiss,
                onSecondaryTap: dismiss,
                onPanStart: (_) => dismiss(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: _CaptionMenuCard(items: items, onDismiss: dismiss),
            ),
          ],
        ),
      ),
    ),
  );
  hostState._insert(entry);
}

class _CaptionMenuCard extends StatelessWidget {
  const _CaptionMenuCard({required this.items, required this.onDismiss});

  final List<MintCaptionMenuItem> items;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHigh,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 232,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items)
              if (item.isSeparator)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Divider(
                    height: 9,
                    thickness: 1,
                    color: cs.outlineVariant.withValues(alpha: 0.45),
                  ),
                )
              else
                _CaptionMenuItemRow(item: item, onDismiss: onDismiss),
          ],
        ),
      ),
    );
  }
}

class _CaptionMenuItemRow extends StatefulWidget {
  const _CaptionMenuItemRow({required this.item, required this.onDismiss});

  final MintCaptionMenuItem item;
  final VoidCallback onDismiss;

  @override
  State<_CaptionMenuItemRow> createState() => _CaptionMenuItemRowState();
}

class _CaptionMenuItemRowState extends State<_CaptionMenuItemRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = widget.item.onPressed != null;
    final fg = enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.38);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                widget.onDismiss();
                widget.item.onPressed!();
              }
            : null,
        child: Container(
          height: 34,
          color: _hover && enabled
              ? cs.onSurface.withValues(alpha: 0.07)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: widget.item.icon == null
                    ? null
                    : Icon(widget.item.icon, size: 15, color: fg),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.item.label,
                  style: TextStyle(fontSize: 13, color: fg),
                ),
              ),
              if (widget.item.trailing != null)
                Text(
                  widget.item.trailing!,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 标题栏内托管的方形动作 ─────────────────────────

/// 标记当前处于标题栏动作槽：[MintTopBarAction] 据此把圆形 IconButton
/// 换成与三大金刚同规格的方形按钮（46×44 + 方形 InkRipple）。
class MintCaptionActionScope extends InheritedWidget {
  const MintCaptionActionScope({super.key, required super.child});

  static bool maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MintCaptionActionScope>() !=
      null;

  @override
  bool updateShouldNotify(MintCaptionActionScope oldWidget) => false;
}

/// 标题栏里的方形动作按钮：与 [_CaptionChromeButton] 同一观感 ——
/// 46×44 热区、90ms hover state layer、**方形 InkRipple**（rectCallback
/// 铺满整个按钮，不是 IconButton 默认的圆形）。
class MintSquareCaptionAction extends StatefulWidget {
  const MintSquareCaptionAction({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.child,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? child;

  @override
  State<MintSquareCaptionAction> createState() =>
      _MintSquareCaptionActionState();
}

class _MintSquareCaptionActionState extends State<MintSquareCaptionAction> {
  bool _hover = false;
  bool _pressed = false;

  Color _splashColor(ColorScheme cs) => cs.onSurface.withValues(alpha: 0.18);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Color bg = Colors.transparent;
    if (_hover) bg = cs.onSurface.withValues(alpha: _pressed ? 0.14 : 0.07);
    if (_pressed) bg = cs.onSurface.withValues(alpha: 0.10);

    return Semantics(
      label: widget.tooltip,
      button: true,
      child: MouseRegion(
        cursor: widget.onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Listener(
          onPointerDown: (_) => setState(() => _pressed = true),
          onPointerUp: (_) => setState(() => _pressed = false),
          onPointerCancel: (_) => setState(() => _pressed = false),
          child: SizedBox(
            width: kMintCaptionButtonWidth,
            height: kMintCaptionHeight,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 90),
                    curve: Curves.easeOutCubic,
                    color: bg,
                  ),
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: widget.onPressed,
                      hoverColor: Colors.transparent,
                      focusColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      splashColor: _splashColor(cs),
                      splashFactory: InkRipple.splashFactory,
                      child: Center(
                        child: IconTheme(
                          data: IconThemeData(
                            color: cs.onSurface.withValues(alpha: 0.82),
                          ),
                          child: widget.child ?? Icon(widget.icon, size: 22),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

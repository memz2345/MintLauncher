import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/window_backdrop.dart';
import 'package:mint/widgets/app_tooltip.dart';

/// Fluent（Windows 11）风格的可折叠侧栏。
///
/// 与 Material 壳的 [CollapsibleSideBar] 同一套交互（图标栏 ↔ 完整列表，
/// 宽度动画 + 状态持久化），但视觉换成 WinUI NavigationView 的语言：
/// 48dp 图标栏、40dp 行高、4dp 圆角、accent 色左侧指示条、Fluent 的
/// hover/press 反馈（`HoverButton`）。
///
/// fluent_ui 自带 NavigationPane 的 compact 模式是**浮层**（盖住内容），
/// 而且展开状态藏在组件私有 State 里、没法持久化 —— 所以宽屏这里自绘，
/// 窄屏仍走 fluent 的 `PaneDisplayMode.top`。
class FluentCollapsibleSideBar extends StatefulWidget {
  const FluentCollapsibleSideBar({
    super.key,
    required this.currentIndex,
    required this.onNavigate,
    required this.tabs,
  });

  final int currentIndex;
  final ValueChanged<int> onNavigate;

  /// (图标, 标题)。图标用 FluentIcons。
  final List<(IconData, String)> tabs;

  // ── 宽度 ──
  static const double minWidth = 48;
  static const double expandedWidth = 220;

  static const Duration animDuration = Duration(milliseconds: 220);
  static const Curve animCurve = Curves.easeOutCubic;

  // ── 展开状态（全局共享 + 落盘）──
  static final ValueNotifier<bool> expanded = ValueNotifier(false);
  static bool _loaded = false;

  static Future<void> loadExpandedState() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      expanded.value = prefs.getBool('mint.fluentPaneExpanded') ?? true;
    } catch (_) {}
  }

  static Future<void> toggle() async {
    expanded.value = !expanded.value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('mint.fluentPaneExpanded', expanded.value);
    } catch (_) {}
  }

  @override
  State<FluentCollapsibleSideBar> createState() =>
      _FluentCollapsibleSideBarState();
}

class _FluentCollapsibleSideBarState extends State<FluentCollapsibleSideBar> {
  @override
  void initState() {
    super.initState();
    FluentCollapsibleSideBar.loadExpandedState();
  }

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: FluentCollapsibleSideBar.expanded,
      builder: (context, isExpanded, _) {
        // 动画期间容器比内容窄：用 OverflowBox 让内容始终按最终宽度布局，
        // 外层裁切只做揭示（与 Material 侧栏同一个坑的解法）。
        //
        // 卡面语言照 QwenTtsMic 的 WinUI CardStyle：8px 圆角 + 1px card stroke
        // + 卡底色，整体从窗口边缘缩 6px 当浮起的一块。
        final glass = WindowBackdrop.instance.isActive;
        final cs = Theme.of(context).colorScheme;
        final cardBg = glass
            ? cs.surfaceContainerLow.withValues(alpha: 0.72)
            : cs.surfaceContainerLow;
        return RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 5, 6),
            child: AnimatedContainer(
              duration: FluentCollapsibleSideBar.animDuration,
              curve: FluentCollapsibleSideBar.animCurve,
              width: isExpanded
                  ? FluentCollapsibleSideBar.expandedWidth
                  : FluentCollapsibleSideBar.minWidth,
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.resources.cardStrokeColorDefault,
                ),
              ),
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: isExpanded
                    ? FluentCollapsibleSideBar.expandedWidth
                    : FluentCollapsibleSideBar.minWidth,
                maxWidth: isExpanded
                    ? FluentCollapsibleSideBar.expandedWidth
                    : FluentCollapsibleSideBar.minWidth,
                child: SizedBox(
                  width: isExpanded
                      ? FluentCollapsibleSideBar.expandedWidth
                      : FluentCollapsibleSideBar.minWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      _PaneToggleButton(expanded: isExpanded),
                      const SizedBox(height: 4),
                      _Header(expanded: isExpanded),
                      const SizedBox(height: 6),
                      Expanded(
                        child: ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            for (final (i, tab) in widget.tabs.indexed)
                              _NavItem(
                                icon: tab.$1,
                                label: tab.$2,
                                expanded: isExpanded,
                                selected: widget.currentIndex == i,
                                onPressed: () => widget.onNavigate(i),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          isExpanded ? 14 : 0,
                          4,
                          isExpanded ? 14 : 0,
                          10,
                        ),
                        child: isExpanded
                            ? Text(
                                'Mint Launcher',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.typography.caption?.copyWith(
                                  color: theme.resources.textFillColorTertiary,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 顶部汉堡按钮：WinUI NavigationView 的 PaneToggleButton 同款位置。
class _PaneToggleButton extends StatelessWidget {
  const _PaneToggleButton({required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: expanded ? 8 : 4, right: expanded ? 8 : 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _HoverIcon(
          icon: fluent.FluentIcons.global_nav_button,
          tooltip: expanded ? '收起侧栏' : '展开侧栏',
          onPressed: FluentCollapsibleSideBar.toggle,
        ),
      ),
    );
  }
}

/// 徽标头：折叠只留方块，展开加名字。
class _Header extends StatelessWidget {
  const _Header({required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final badge = Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'M',
        style: TextStyle(
          color: theme.brightness == Brightness.dark
              ? Colors.white
              : Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(expanded ? 14 : 10, 0, 10, 0),
      child: Row(
        children: [
          badge,
          if (expanded) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Mint',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.bodyStrong,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一行导航项。选中 = 左侧 accent 指示条 + 淡底；hover 用 Fluent 的
/// subtleFill；折叠态只留图标并挂 tooltip。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.expanded,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool expanded;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final fg = selected
        ? theme.resources.textFillColorPrimary
        : theme.resources.textFillColorSecondary;

    final row = fluent.HoverButton(
      onPressed: onPressed,
      builder: (context, states) {
        final hovered = states.isHovered || states.isPressed;
        final bg = selected
            ? accent.withValues(alpha: hovered ? 0.16 : 0.10)
            : (hovered
                  ? theme.resources.subtleFillColorSecondary
                  : Colors.transparent);
        return Container(
          height: 40,
          margin: EdgeInsets.symmetric(
            horizontal: expanded ? 6 : 4,
            vertical: 1,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // 选中指示条（WinUI 的 3×16 竖条）：AnimatedSwitcher 让它从
              // 左侧滑入 + 淡入，取消选中时反向淡出（WinUI NavigationView
              // 的指示条动效）。
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: FluentCollapsibleSideBar.animDuration,
                  switchInCurve: FluentCollapsibleSideBar.animCurve,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(-0.6, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: selected
                      ? Align(
                          key: const ValueKey('pane-indicator'),
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 3,
                            height: 16,
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(
                          key: ValueKey('pane-indicator-off'),
                        ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                    width: expanded ? 42 : 40,
                    child: Center(
                      child: fluent.Icon(icon, size: 17, color: fg),
                    ),
                  ),
                  if (expanded)
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.typography.body?.copyWith(
                          color: fg,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );

    if (expanded) return row;
    return AppTooltip(message: label, child: row);
  }
}

/// 40×36 的图标按钮（Fluent 的 hover / press 反馈）。
class _HoverIcon extends StatelessWidget {
  const _HoverIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    return AppTooltip(
      message: tooltip,
      child: fluent.HoverButton(
        onPressed: onPressed,
        builder: (context, states) {
          final hovered = states.isHovered || states.isPressed;
          return Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: hovered
                  ? theme.resources.subtleFillColorSecondary
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: fluent.Icon(
              icon,
              size: 16,
              color: theme.resources.textFillColorPrimary,
            ),
          );
        },
      ),
    );
  }
}

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/window_backdrop.dart';
import 'package:mint/src/enums.dart';
import 'package:mint/ui/mint_icons.dart';
import 'package:mint/widgets/app_tooltip.dart';

/// 页面级「侧边选项」卡片：圆角卡面 + 可折叠 + 状态持久化。
///
/// 版本管理（游戏目录）、版本设置（分类）这类左右两栏页面共用：
///   · 圆角跟风格走：fluent 8（WinUI CardStyle 同款）、miuix / Material 20
///   · 头部一行标题 + 折叠按钮（页面自己的动作按钮也塞这一行）
///   · 折叠后收到 56dp 图标栏，`collapsedChild` 由页面给（图标 + tooltip）
///   · 展开状态按 [storageKey] 落盘，`defaultExpanded` 决定首次进来是开还是收
class MintCollapsiblePane extends StatefulWidget {
  const MintCollapsiblePane({
    super.key,
    required this.miuix,
    required this.storageKey,
    required this.title,
    required this.child,
    this.collapsedChild,
    this.headerExpanded,
    this.headerCollapsed,
    this.headerTrailing,
    this.titleIcon,
    this.expandedWidth = 264,
    this.collapsedWidth = 56,
    this.defaultExpanded = true,
  });

  final bool miuix;

  /// 持久化键（`mint.pane.<key>`）。
  final String storageKey;

  final String title;

  /// 展开态内容。
  final Widget child;

  /// 折叠态内容（一般是图标列）。
  final Widget? collapsedChild;

  /// 自定义头部（展开态）；给了就不画默认的「标题」行。
  final Widget? headerExpanded;

  /// 折叠态头部（一般只留图标）。
  final Widget? headerCollapsed;

  /// 头部右侧动作（展开态），排在折叠按钮左边。
  final Widget? headerTrailing;

  /// 默认标题行左侧的小图标。
  final Widget? titleIcon;

  final double expandedWidth;
  final double collapsedWidth;
  final bool defaultExpanded;

  static const Duration duration = Duration(milliseconds: 220);
  static const Curve curve = Curves.easeOutCubic;

  static final Map<String, ValueNotifier<bool>> _states = {};

  static ValueNotifier<bool> stateOf(String key, bool fallback) {
    return _states.putIfAbsent(key, () {
      final notifier = ValueNotifier<bool>(fallback);
      _restore(key, notifier, fallback);
      return notifier;
    });
  }

  static Future<void> _restore(
    String key,
    ValueNotifier<bool> notifier,
    bool fallback,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      notifier.value = prefs.getBool('mint.pane.$key') ?? fallback;
    } catch (_) {}
  }

  static Future<void> _persist(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('mint.pane.$key', value);
    } catch (_) {}
  }

  @override
  State<MintCollapsiblePane> createState() => _MintCollapsiblePaneState();
}

class _MintCollapsiblePaneState extends State<MintCollapsiblePane> {
  late final ValueNotifier<bool> _expanded = MintCollapsiblePane.stateOf(
    widget.storageKey,
    widget.defaultExpanded,
  );

  void _toggle() {
    _expanded.value = !_expanded.value;
    MintCollapsiblePane._persist(widget.storageKey, _expanded.value);
  }

  double _radius(BuildContext context) => mintFluentOf(context) ? 8 : 20;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final glass = WindowBackdrop.instance.isActive;
    final bg = glass
        ? cs.surfaceContainerLow.withValues(alpha: 0.72)
        : cs.surfaceContainerLow;
    final border = cs.outlineVariant.withValues(alpha: glass ? 0.35 : 0.5);

    return ValueListenableBuilder<bool>(
      valueListenable: _expanded,
      builder: (context, expanded, _) {
        final width = expanded ? widget.expandedWidth : widget.collapsedWidth;
        return RepaintBoundary(
          child: AnimatedContainer(
            duration: MintCollapsiblePane.duration,
            curve: MintCollapsiblePane.curve,
            width: width,
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(_radius(context)),
              border: Border.all(color: border),
            ),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: width,
              maxWidth: width,
              // 动画途中容器比内容窄：内容始终按目标宽度布局，外层裁掉多余部分，
              // 避免行内的 icon + 文字被中间宽度挤爆（Material 侧栏同款修法）。
              child: SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(context, expanded),
                    Expanded(
                      child: expanded
                          ? widget.child
                          : (widget.collapsedChild ?? const SizedBox.shrink()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, bool expanded) {
    final cs = Theme.of(context).colorScheme;
    final toggle = _PaneToggleButton(
      expanded: expanded,
      onPressed: _toggle,
      miuix: mintMiuixOf(context),
    );

    if (!expanded) {
      final head = widget.headerCollapsed;
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Column(
          children: [
            if (head != null) ...[head, const SizedBox(height: 2)],
            toggle,
          ],
        ),
      );
    }

    final head =
        widget.headerExpanded ??
        Row(
          children: [
            if (widget.titleIcon != null) ...[
              widget.titleIcon!,
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                ),
              ),
            ),
          ],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: [
          Expanded(child: head),
          ?widget.headerTrailing,
          toggle,
        ],
      ),
    );
  }
}

/// 折叠态图标栏里的单个按钮（40×40 圆角 + tooltip）。
///
/// 版本管理的目录、版本设置的分类都用它：收起来之后只留图标，
/// 鼠标悬停靠 tooltip 认人。
class MintPaneRailButton extends StatelessWidget {
  const MintPaneRailButton({
    super.key,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppTooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Material(
          color: selected ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(height: 40, child: Center(child: child)),
          ),
        ),
      ),
    );
  }
}

/// 折叠 / 展开按钮：三套风格各自的箭头。
class _PaneToggleButton extends StatelessWidget {
  const _PaneToggleButton({
    required this.expanded,
    required this.onPressed,
    required this.miuix,
  });

  final bool expanded;
  final VoidCallback onPressed;
  final bool miuix;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = MintIcon(
      icon: expanded
          ? Icons.keyboard_double_arrow_left
          : Icons.keyboard_double_arrow_right,
      fluentIcon: expanded
          ? fluent.FluentIcons.chevron_left
          : fluent.FluentIcons.chevron_right,
      miuixName: expanded ? 'chevronBackward' : 'chevronForward',
      size: 20,
      color: cs.onSurfaceVariant,
    );
    return IconButton(
      tooltip: expanded ? '收起侧栏' : '展开侧栏',
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      icon: icon,
    );
  }
}

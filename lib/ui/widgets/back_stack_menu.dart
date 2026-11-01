import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:mint/ui/window_chrome.dart';

/// 长按返回键 → 选择返回层级（iOS 14+ 导航栏同款行为）的 **Flutter 降级版**。
///
/// iOS 26+ 的返回键是原生平台视图（`NativeBackButton.swift`），长按直接由
/// `UIContextMenuInteraction` 弹系统 context menu，不经过这里；本函数用于：
///   - iOS 14/15：App 层没有公开 API 拉起导航栏返回菜单；
///   - 桌面 / 测试钩子：窗口标题栏与截图需要同一套层级面板。
Future<void> showMintBackStackMenu(
  BuildContext context, {
  Offset? anchor,
}) async {
  final targets = MintWindowChrome.instance.backTargets;
  if (targets.length <= 1) {
    debugPrint('back menu: 层级不足（${targets.length}）');
    return;
  }

  final navigator = Navigator.of(context);
  final media = MediaQuery.of(context);
  // 菜单是「当前层在上、更早的层在下」，和栈顺序相反。
  final ordered = targets.reversed.toList(growable: false);
  final anchorPoint = anchor ?? Offset(24, media.padding.top + 28);

  if (!context.mounted) return;
  await _showFlutterMenu(
    context: context,
    navigator: navigator,
    targets: ordered,
    anchor: anchorPoint,
  );
}

Future<void> _showFlutterMenu({
  required BuildContext context,
  required NavigatorState navigator,
  required List<MintBackTarget> targets,
  required Offset anchor,
}) {
  final theme = Theme.of(context);
  final media = MediaQuery.of(context);

  const itemHeight = 46.0;
  final panelWidth = (media.size.width - 32).clamp(0.0, 292.0);
  final panelHeight = targets.length * itemHeight + 16;

  var left = anchor.dx - 8;
  var top = anchor.dy + 18;
  left = left.clamp(8.0, media.size.width - panelWidth - 8);
  top = top.clamp(media.padding.top + 8, media.size.height - panelHeight - 8);

  void popTo(PageRoute<dynamic> route) {
    if (!route.isActive) return;
    navigator.popUntil((r) => r == route);
  }

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '返回层级',
    barrierColor: Colors.black.withValues(alpha: 0.04),
    transitionDuration: const Duration(milliseconds: 170),
    pageBuilder: (dialogContext, _, _) {
      return Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(dialogContext).pop(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: panelWidth,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 170),
                curve: Curves.easeOutCubic,
                builder: (context, t, child) => Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.88 + 0.12 * t,
                    alignment: Alignment.topLeft,
                    child: child,
                  ),
                ),
                child: _BackMenuPanel(
                  targets: targets,
                  theme: theme,
                  onSelected: (route) {
                    Navigator.of(dialogContext).pop();
                    popTo(route);
                  },
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _BackMenuPanel extends StatelessWidget {
  const _BackMenuPanel({
    required this.targets,
    required this.theme,
    required this.onSelected,
  });

  final List<MintBackTarget> targets;
  final ThemeData theme;
  final ValueChanged<PageRoute<dynamic>> onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.35),
              width: 0.6,
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final target in targets)
                _BackMenuRow(
                  target: target,
                  theme: theme,
                  onTap: target.current ? null : () => onSelected(target.route),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackMenuRow extends StatelessWidget {
  const _BackMenuRow({
    required this.target,
    required this.theme,
    required this.onTap,
  });

  final MintBackTarget target;
  final ThemeData theme;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final current = target.current;
    return Semantics(
      button: true,
      selected: current,
      enabled: !current,
      label: current ? '当前页 ${target.title}' : '返回 ${target.title}',
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 46,
          child: Row(
            children: [
              SizedBox(
                width: 38,
                child: Icon(
                  current ? Icons.check_rounded : null,
                  size: 18,
                  color: cs.primary,
                ),
              ),
              Expanded(
                child: Text(
                  target.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.2,
                    color: current
                        ? cs.onSurface
                        : cs.onSurface.withValues(alpha: 0.82),
                    fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
              if (!current)
                Icon(
                  Icons.chevron_left_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.65),
                ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/widgets/page_background.dart' show mintCardMaskColor;

/// PCL2 `MyCard` 的折叠 / 悬浮动画移植。
///
/// 原实现：
///   · 头部点击折叠，内容高度 150~200ms 收放（`AniEaseOutFluent`），
///     箭头 250ms `ExtraStrong` 回弹旋转；
///   · 鼠标进入整卡时阴影透明度 0.07 → 0.4、标题色加深，90ms 完成。
///
/// 这里保持同样的节奏；卡片本身沿用 Mint 的双风格圆角卡片（miuix squircle /
/// Material 18dp），不引入 PCL 的灰白配色。折叠完成后再把内容从树上摘掉，
/// 避免下载页几百个版本一直参与布局。
class MintCollapsibleCard extends StatefulWidget {
  const MintCollapsibleCard({
    super.key,
    required this.miuix,
    required this.title,
    required this.children,
    this.subtitle,
    this.leading,
    this.trailing,
    this.initiallyExpanded = true,
    this.headerPadding = const EdgeInsets.fromLTRB(16, 13, 12, 13),
    this.contentPadding = EdgeInsets.zero,
    this.storageKey,
  });

  final bool miuix;
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> children;
  final bool initiallyExpanded;
  final EdgeInsets headerPadding;
  final EdgeInsets contentPadding;

  /// 折叠状态持久化键（`mint.card.<key>`）。给了 key 的卡片记住上次的
  /// 展开状态，下次进页面保持；不给则回到 [initiallyExpanded]。
  final String? storageKey;

  @override
  State<MintCollapsibleCard> createState() => _MintCollapsibleCardState();
}

class _MintCollapsibleCardState extends State<MintCollapsibleCard>
    with TickerProviderStateMixin {
  late bool _expanded = widget.initiallyExpanded;
  late bool _contentMounted = widget.initiallyExpanded;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _restoreExpanded();
  }

  Future<void> _restoreExpanded() async {
    final key = widget.storageKey;
    if (key == null || key.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final expanded = prefs.getBool('mint.card.$key');
      if (expanded == null || expanded == _expanded || !mounted) return;
      setState(() => _expanded = expanded);
      _contentMounted = expanded;
      _size.value = expanded ? 1 : 0;
    } catch (_) {}
  }

  Future<void> _persistExpanded() async {
    final key = widget.storageKey;
    if (key == null || key.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('mint.card.$key', _expanded);
    } catch (_) {}
  }

  late final AnimationController _size = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: widget.initiallyExpanded ? 1 : 0,
  );
  late final Animation<double> _sizeCurve = CurvedAnimation(
    parent: _size,
    curve: Curves.easeOutCubic,
  );

  static const _easeOutFluent = Cubic(0.0, 0.0, 0.2, 1.0);

  @override
  void dispose() {
    _size.dispose();
    super.dispose();
  }

  void _toggle() {
    _persistExpanded();
    if (_expanded) {
      setState(() => _expanded = false);
      _size
          .animateBack(
            0,
            duration: const Duration(milliseconds: 200),
            curve: _easeOutFluent,
          )
          .then((_) {
            if (!mounted || _expanded) return;
            setState(() => _contentMounted = false);
          });
    } else {
      setState(() {
        _expanded = true;
        _contentMounted = true;
      });
      _size.animateTo(
        1,
        duration: const Duration(milliseconds: 240),
        curve: _easeOutFluent,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final miuixColors = mintMiuixOf(context, widget.miuix)
        ? MiuixTheme.of(context).colors
        : null;
    final surface = mintCardMaskColor(
      context,
      mintMiuixOf(context, widget.miuix)
          ? miuixColors!.surfaceContainer
          : cs.surfaceContainerLow,
    );
    final outline = mintMiuixOf(context, widget.miuix)
        ? miuixColors!.outline.withValues(alpha: 0.16)
        : cs.outlineVariant.withValues(alpha: 0.45);
    final radius = BorderRadius.circular(18);
    final shape = mintMiuixOf(context, widget.miuix)
        ? MiuixSquircleBorder(
            cornerRadius: 18,
            side: BorderSide(color: outline),
          )
        : RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: outline),
          );

    final header = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Semantics(
        button: true,
        expanded: _expanded,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: _toggle,
            // hover 反馈已有自绘（标题变色 + 阴影），InkWell 只贡献 ripple。
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            highlightColor: Colors.transparent,
            // 涟漪裁进卡片圆角：卡头贴着 18px 圆角卡的顶部，不传的话
            // 涟漪按方角画、会溢出卡片圆角外（mdui 涟漪盖满整元素后尤其
            // 明显）。
            borderRadius: radius,
            child: Padding(
              padding: widget.headerPadding,
              child: Row(
                children: [
                  if (widget.leading != null) ...[
                    widget.leading!,
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 90),
                          curve: _easeOutFluent,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                            color: _hover ? cs.primary : cs.onSurface,
                          ),
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.trailing != null) ...[
                    const SizedBox(width: 8),
                    widget.trailing!,
                  ],
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutQuart,
                    turns: _expanded ? 0.5 : 0,
                    child: Icon(
                      Icons.expand_more,
                      size: 22,
                      color: _hover ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      curve: _easeOutFluent,
      decoration: ShapeDecoration(
        shape: shape,
        color: surface,
        shadows: [
          BoxShadow(
            color: cs.shadow.withValues(
              alpha: _hover ? (dark ? 0.42 : 0.16) : (dark ? 0.22 : 0.05),
            ),
            blurRadius: _hover ? 18 : 6,
            offset: Offset(0, _hover ? 5 : 2),
          ),
        ],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(
          shape: shape,
          textDirection: Directionality.of(context),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            ClipRect(
              child: SizeTransition(
                sizeFactor: _sizeCurve,
                alignment: Alignment.topCenter,
                child: _contentMounted
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: outline.withValues(alpha: 0.6),
                          ),
                          Padding(
                            padding: widget.contentPadding,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: widget.children,
                            ),
                          ),
                        ],
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ),
          ],
        ),
      ),
    );

    // PCL2 MyCard 的阴影反馈作用于整张卡片，而不只是标题行。
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: card,
    );
  }
}

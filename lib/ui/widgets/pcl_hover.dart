import 'package:flutter/material.dart';

import 'package:mint/widgets/mdui_ripple.dart' show mintSplashColor;

/// PCL2 `MyListItem.RefreshColor` 的悬浮 / 按下动画移植。
///
/// 原实现（`MyListItem.xaml.vb`）：
///   · 鼠标进入：高亮底板从 0.75 缩放到 1.0（耗时 120×1.6ms，
///     `AniEaseOutFluent`），透明度 120ms 淡入，整行再回到 1.0（120×1.2ms）；
///   · 按下：整行缩到 0.98（120×0.9ms），底板换按下色；
///   · 离开：底板 180ms 淡出、缩到 0.996，动画结束后硬重置回 0.75，
///     整行用 180×3ms 弹回 1.0。
///
/// 这里只搬运动画，不搬 PCL 的配色；高亮色取主题 onSurface 的低透明度，
/// 选中底色由调用方通过 [baseColor] 传进来，避免覆盖列表的选中语义。
/// 多个列表快速切换时每个条目各自重定向动画，效果和 PCL 一致。
class PclHoverSurface extends StatefulWidget {
  const PclHoverSurface({
    super.key,
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTap,
    this.enabled = true,
    this.borderRadius = 12,
    this.baseColor,
    this.hoverColor,
    this.pressedColor,
    this.cursor = SystemMouseCursors.click,
    this.ripple = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onSecondaryTap;
  final bool enabled;
  final double borderRadius;

  /// 常驻底色（选中行等），不参与缩放。
  final Color? baseColor;

  /// 悬浮底板色。null = 主题 onSurface 8%。
  final Color? hoverColor;

  /// 按下底板色。null = 比悬浮色略深。
  final Color? pressedColor;

  final MouseCursor cursor;

  /// 点击时叠加 Flutter 原生 InkRipple（Material/InkWell 提供，非自绘）。
  /// PCL2 的悬浮 / 按下缩放动画保留不变；miuix 风格保持默认关闭
  /// （HyperOS 用自己的按压遮罩，不吃 ripple）。
  final bool ripple;

  @override
  State<PclHoverSurface> createState() => _PclHoverSurfaceState();
}

class _PclHoverSurfaceState extends State<PclHoverSurface>
    with TickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  );
  late final AnimationController _backScale = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 192),
    value: 0.75,
    lowerBound: 0,
    upperBound: 1,
  );
  late final AnimationController _itemScale = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 144),
    value: 1,
    lowerBound: 0.9,
    upperBound: 1,
  );

  bool _hover = false;
  bool _pressed = false;
  int _exitGeneration = 0;

  static const _easeOutFluent = Cubic(0.0, 0.0, 0.2, 1.0);

  @override
  void dispose() {
    _fade.dispose();
    _backScale.dispose();
    _itemScale.dispose();
    super.dispose();
  }

  void _enter() {
    if (!mounted || !widget.enabled) return;
    _exitGeneration++;
    _hover = true;
    _fade.animateTo(
      1,
      duration: const Duration(milliseconds: 120),
      curve: _easeOutFluent,
    );
    _backScale.animateTo(
      1,
      duration: const Duration(milliseconds: 192),
      curve: _easeOutFluent,
    );
    _itemScale.animateTo(
      _pressed ? 0.98 : 1,
      duration: const Duration(milliseconds: 144),
      curve: _easeOutFluent,
    );
    setState(() {});
  }

  void _exit() {
    if (!_hover && !_pressed) return;
    _hover = false;
    _pressed = false;
    final generation = ++_exitGeneration;
    _fade.animateTo(
      0,
      duration: const Duration(milliseconds: 180),
      curve: _easeOutFluent,
    );
    // 原版：从当前位置缩到 0.996，1ms 后硬重置到 0.75。重置必须等
    // 淡出结束，否则会在还看得见的时候突然缩小。
    _backScale
        .animateTo(
          0.996,
          duration: const Duration(milliseconds: 180),
          curve: _easeOutFluent,
        )
        .then((_) {
          if (!mounted || _hover || generation != _exitGeneration) return;
          _backScale.value = 0.75;
        });
    _itemScale.animateTo(
      1,
      duration: const Duration(milliseconds: 540),
      curve: _easeOutFluent,
    );
    setState(() {});
  }

  void _down() {
    if (!mounted || !widget.enabled) return;
    _pressed = true;
    _itemScale.animateTo(
      0.98,
      duration: const Duration(milliseconds: 108),
      curve: _easeOutFluent,
    );
    setState(() {});
  }

  void _up() {
    if (!mounted || !_pressed) return;
    _pressed = false;
    _itemScale.animateTo(
      1,
      duration: const Duration(milliseconds: 144),
      curve: _easeOutFluent,
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hoverColor =
        widget.hoverColor ?? cs.onSurface.withValues(alpha: 0.075);
    final pressedColor =
        widget.pressedColor ?? cs.onSurface.withValues(alpha: 0.11);
    final radius = BorderRadius.circular(widget.borderRadius);

    // ripple 模式：点击交给 InkWell（真·InkRipple），InkWell 的
    // hover/highlight 置透明——悬浮底板和按压态仍由 PCL 那套动画画。
    final Widget interactive =
        widget.ripple && widget.enabled && widget.onTap != null
        ? Material(
            type: MaterialType.transparency,
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              onDoubleTap: widget.onDoubleTap,
              hoverColor: Colors.transparent,
              focusColor: Colors.transparent,
              highlightColor: Colors.transparent,
              // 涟漪颜色统一走 mintSplashColor 的 M3 按压态档位（曾各自
              // 手写 onSurface 10%，跟主题色一改就容易漂移）。
              splashColor: mintSplashColor(cs.brightness),
              borderRadius: radius,
              child: widget.child,
            ),
          )
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? widget.onTap : null,
            onDoubleTap: widget.enabled ? widget.onDoubleTap : null,
            onSecondaryTap: widget.enabled ? widget.onSecondaryTap : null,
            child: widget.child,
          );

    Widget surface = MouseRegion(
      cursor: widget.onTap == null ? SystemMouseCursors.basic : widget.cursor,
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: Listener(
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedBuilder(
          animation: _itemScale,
          builder: (context, child) =>
              Transform.scale(scale: _itemScale.value, child: child),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (widget.baseColor != null)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.baseColor,
                      borderRadius: radius,
                    ),
                  ),
                ),
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_fade, _backScale]),
                  builder: (context, _) {
                    if (_fade.value <= 0) return const SizedBox.shrink();
                    return Transform.scale(
                      scale: _backScale.value,
                      child: Opacity(
                        key: const ValueKey('pcl.hover.fade'),
                        opacity: _fade.value,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _pressed ? pressedColor : hoverColor,
                            borderRadius: radius,
                            border: Border.all(
                              color: cs.onSurface.withValues(alpha: 0.045),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // 非 positioned：给 Stack 定尺寸（全部 positioned 的话 Stack
              // 在 ListView 里拿不到有界约束会直接 assert）。
              interactive,
            ],
          ),
        ),
      ),
    );

    if (widget.onTap == null) return surface;
    return Semantics(button: true, child: surface);
  }
}

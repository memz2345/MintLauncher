import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:mint/services/ios_liquid_glass.dart';

/// 悬浮底栏 —— InstallerX `FloatingBottomBar`（非玻璃 None 档）的 Flutter 移植，
/// 与 G:\192\local2api 的 `widgets/floating_bottom_bar.dart` 同源。
///
/// 结构：实色 / 毛玻璃胶囊容器（StadiumBorder）+ 悬浮阴影 +
/// 主色 15% 的胶囊指示器（宽 = 单个 tab，拖动时跟手、松手吸附）+
/// 未选中 `contentColor` / 选中 `activeContentColor` 两套内容色。
/// 图标 + 文字纵向排布（间距 1dp），tab 最小宽 76dp。
class FloatingBottomBarItem {
  const FloatingBottomBarItem({
    required this.label,
    required this.iconBuilder,
    this.semanticLabel,
    this.badge = false,
  });

  final String label;

  /// 按选中态给图标（Material 壳传 Material 字形，miuix 壳传矢量图标）。
  final Widget Function(bool selected) iconBuilder;

  final String? semanticLabel;

  /// 图标右上角的小红点（下载 tab 有进行中的任务时用）。
  final bool badge;
}

class FloatingBottomBarColors {
  const FloatingBottomBarColors({
    required this.containerColor,
    required this.indicatorColor,
    required this.contentColor,
    required this.activeContentColor,
  });

  /// 胶囊底色（InstallerX：surfaceContainer 实色）。
  final Color containerColor;

  /// 指示器（InstallerX：primary @ 15%）。
  final Color indicatorColor;

  /// 未选中内容色。
  final Color contentColor;

  /// 选中内容色（InstallerX：= indicatorColor，即 primary）。
  final Color activeContentColor;
}

class FloatingBottomBar extends StatefulWidget {
  const FloatingBottomBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.colors,
    this.height = 64,
    this.blurred = false,
    this.blurSigma = 10.8,
    this.systemGlass = false,
  });

  final List<FloatingBottomBarItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final FloatingBottomBarColors? colors;
  final double height;

  /// 毛玻璃：把身后的内容实时高斯模糊，[colors.containerColor] 需要由调用方
  /// 传**半透明**色当色调（对应 miuix 顶栏 blurred 的做法 —— blur + tint）。
  final bool blurred;

  /// 模糊 sigma。miuix 顶栏同款换算：radius 24 × 0.45 ≈ 10.8。
  final double blurSigma;

  /// iOS 26 系统液态玻璃：调用方给 `Platform.isIOS && settings.iosLiquidGlass`，
  /// 探测确认（UIGlassEffect 存在）后胶囊不再自绘底色 / 毛玻璃 / 阴影，
  /// 区域上报给原生铺 `UIGlassEffect` —— 与系统 tab 栏同款观感。探测失败
  /// 自动退回自绘。
  final bool systemGlass;

  @override
  State<FloatingBottomBar> createState() => _FloatingBottomBarState();
}

class _FloatingBottomBarState extends State<FloatingBottomBar>
    with SingleTickerProviderStateMixin {
  /// 指示器位置，单位 = tab 格（0..n-1），可含小数（拖动中）。
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.selectedIndex.toDouble(),
  );

  /// 手指拖动造成的整体橡皮筋位移（逻辑像素），松手回弹到 0。
  double _rubberBand = 0;

  /// 拖动中（指示器跟手、不吸附）。
  bool _dragging = false;

  /// 系统玻璃探测结果（仅 [FloatingBottomBar.systemGlass] 为真时探测）。
  bool _glassActive = false;

  double _tabWidth = 0;
  int get _count => widget.items.length;
  int get _index => widget.selectedIndex.clamp(0, math.max(0, _count - 1));

  @override
  void initState() {
    super.initState();
    if (widget.systemGlass) {
      IosLiquidGlass.instance.available().then((ok) {
        if (mounted) setState(() => _glassActive = ok);
      });
    }
  }

  @override
  void didUpdateWidget(FloatingBottomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部换页（PageView 滑动 / 快捷方式）→ 指示器动画过去；
    // 拖动中不跟（松手吸附会落到正确位置）。
    if (!_dragging && oldWidget.selectedIndex != widget.selectedIndex) {
      _position.animateTo(
        _index.toDouble(),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == widget.selectedIndex) return;
    widget.onSelected(index.clamp(0, _count - 1));
  }

  /// 横向拖动：指示器 1:1 跟手，越出两端用橡皮筋缓一点。
  void _onDragUpdate(DragUpdateDetails d) {
    if (_tabWidth <= 0) return;
    setState(() {
      _position.value = (_position.value + d.delta.dx / _tabWidth).clamp(
        -0.35,
        _count - 1 + 0.35,
      );
      // 越界部分的位移按 35% 折算成整体橡皮筋（对应 Compose 版 EaseOut 橡皮筋）。
      final over = _position.value < 0
          ? _position.value
          : _position.value > _count - 1
          ? _position.value - (_count - 1)
          : 0.0;
      _rubberBand = over * _tabWidth * 0.35;
    });
  }

  void _onDragEnd(DragEndDetails d) {
    final target = _position.value.round().clamp(0, _count - 1);
    setState(() {
      _dragging = false;
      _rubberBand = 0;
    });
    _position.animateTo(
      target.toDouble(),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    _select(target);
  }

  @override
  Widget build(BuildContext context) {
    final colors =
        widget.colors ??
        FloatingBottomBarColors(
          containerColor: Theme.of(context).colorScheme.surfaceContainer,
          indicatorColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.15),
          contentColor: Theme.of(context).colorScheme.onSurfaceVariant,
          activeContentColor: Theme.of(context).colorScheme.primary,
        );
    // 系统玻璃：胶囊本身完全透明（底色 / 阴影 / 毛玻璃都交给原生
    // UIGlassEffect），只画指示器与内容。
    final glass = widget.systemGlass && _glassActive;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GlassRegion(
        id: 'bottomBar',
        radius: widget.height / 2,
        enabled: glass,
        child: Material(
          color: glass ? Colors.transparent : colors.containerColor,
          // Stadium = 圆角 999 的胶囊（对应 Compose CircleShape pill）。
          shape: const StadiumBorder(),
          elevation: glass ? 0 : 6,
          shadowColor: Colors.black.withValues(alpha: 0.25),
          // 毛玻璃：裁剪到胶囊范围内做实时背景模糊 —— Material 的半透明底色
          // 在 filter 之前铺一层色调，模糊取到的就是「色调后的背景」，净效果
          // 等价 miuix 顶栏的 blur + tint。
          clipBehavior: !glass && widget.blurred ? Clip.antiAlias : Clip.none,
          child: !glass && widget.blurred
              ? BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: widget.blurSigma,
                    sigmaY: widget.blurSigma,
                  ),
                  child: _content(colors),
                )
              : _content(colors),
        ),
      ),
    );
  }

  Widget _content(FloatingBottomBarColors colors) {
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _tabWidth = (constraints.maxWidth - 8) / _count;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => setState(() => _dragging = true),
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: () => _onDragEnd(DragEndDetails()),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Stack(
                children: [
                  // 主色 15% 指示器：宽 = 单格，跟手 / 吸附动画。
                  AnimatedBuilder(
                    animation: _position,
                    builder: (context, _) {
                      final shift = _position.value * _tabWidth + _rubberBand;
                      return Positioned(
                        left: shift,
                        width: _tabWidth,
                        top: 0,
                        bottom: 0,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            shape: const StadiumBorder(),
                            color: colors.indicatorColor,
                          ),
                        ),
                      );
                    },
                  ),
                  // Tab 行：指示器之上的图标 + 文字。
                  Row(
                    children: [
                      for (var i = 0; i < _count; i++) _tab(i, colors),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _tab(int i, FloatingBottomBarColors colors) {
    final item = widget.items[i];
    final selected = i == _index;
    return Expanded(
      child: Semantics(
        label: item.semanticLabel ?? item.label,
        selected: selected,
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            // 点按：指示器动画过去再回调（跟 Compose 版 activateTab 同序）。
            _position.animateTo(
              i.toDouble(),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
            );
            _select(i);
          },
          child: IconTheme.merge(
            data: IconThemeData(
              size: 24,
              color: selected ? colors.activeContentColor : colors.contentColor,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    item.iconBuilder(selected),
                    // 红点：压在图标右上角（有进行中的下载任务时）。
                    if (item.badge)
                      Positioned(
                        top: -1,
                        right: -3,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE5484D),
                            shape: BoxShape.circle,
                            border: Border.all(
                              width: 1.2,
                              color: colors.containerColor,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    color: selected
                        ? colors.activeContentColor
                        : colors.contentColor,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

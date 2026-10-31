import 'package:flutter/material.dart';

/// 标记当前处于「浮动大标题」页面：内容从毛玻璃标题栏下滑过。
/// [MintScrollbarBehavior] 据此跳过滚动条 —— 滚动条跟着内容走，
/// 会探进标题栏区域里（老问题：滚动条进标题）。
class MintFloatingTitleScope extends InheritedWidget {
  const MintFloatingTitleScope({super.key, required super.child});

  static bool maybeOf(BuildContext? context) =>
      context?.dependOnInheritedWidgetOfExactType<MintFloatingTitleScope>() !=
      null;

  @override
  bool updateShouldNotify(MintFloatingTitleScope oldWidget) => false;
}

/// Mint 的桌面滚动条策略：浮动大标题页不画滚动条，其余照 Material
/// 桌面默认（hover 出现）。越界指示器由子类决定 —— Material / Fluent
/// 风格直接用本类（默认行为），miuix 风格用 MiuixOverscrollBehavior
/// （继承本类并替换整体位移指示器）。
class MintScrollbarBehavior extends MaterialScrollBehavior {
  const MintScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // context 来自 Scrollable 自身的 build：滚动体在浮动标题 scope 内
    // （视口盖住标题栏下方整块区域），Scrollbar 的轨道会一直延伸进
    // 标题里 —— 这些页面直接不画（滚轮 / 键盘照常）。
    if (axisDirectionToAxis(details.direction) == Axis.vertical &&
        MintFloatingTitleScope.maybeOf(context)) {
      return child;
    }
    return super.buildScrollbar(context, child, details);
  }
}

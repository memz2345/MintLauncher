import 'package:flutter/material.dart';

/// 从 NaviFlash 移植的 M3E 加载指示器 token 适配层。
///
/// 原版依赖 m3e_design 的 M3ETheme 扩展；本项目没有引入该包，
/// 直接从 Material ColorScheme 取色。
@immutable
class LoadingTokensAdapter {
  const LoadingTokensAdapter(this.context);
  final BuildContext context;

  ColorScheme get _colors => Theme.of(context).colorScheme;

  Color activeColor() => _colors.primary;

  Color containerColorDefault() => Colors.transparent;

  Color containedContainerColor() => _colors.primaryContainer;
  Color containedActiveColor() => _colors.onPrimaryContainer;

  double containerWidth() => 48;
  double containerHeight() => 48;
  double activeIndicatorSize() => 38;

  BorderRadius containerRadius() => BorderRadius.circular(999);
}

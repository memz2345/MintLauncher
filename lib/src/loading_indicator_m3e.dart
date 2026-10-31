import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import 'expressive_loading_indicator.dart';
import 'loading_tokens_adapter.dart';

/// M3E 形变加载指示器的形态（local2api 同名枚举的内联版）。
enum LoadingIndicatorM3EVariant { defaultStyle, contained }

class LoadingIndicatorM3E extends StatelessWidget {
  const LoadingIndicatorM3E({
    super.key,
    this.variant = LoadingIndicatorM3EVariant.defaultStyle,
    this.color,
    this.containerColor,
    this.polygons,
    this.constraints,
    this.padding,
    this.value,
    this.semanticLabel,
    this.semanticValue,
  });

  final LoadingIndicatorM3EVariant variant;
  final Color? color;
  final Color? containerColor;
  final List<RoundedPolygon>? polygons;
  final BoxConstraints? constraints;
  final EdgeInsetsGeometry? padding;

  /// 非空 = 定态，形变进度由调用方驱动（下拉刷新拖拽阶段用）。
  /// 对应 Compose `ContainedLoadingIndicator(progress = ...)` 那个重载。
  final double? value;
  final String? semanticLabel;
  final String? semanticValue;

  @override
  Widget build(BuildContext context) {
    final tokens = LoadingTokensAdapter(context);
    final size = Size(tokens.containerWidth(), tokens.containerHeight());

    final cons = constraints ?? BoxConstraints.tight(size);

    final activeColor = switch (variant) {
      LoadingIndicatorM3EVariant.defaultStyle => color ?? tokens.activeColor(),
      LoadingIndicatorM3EVariant.contained =>
        color ?? tokens.containedActiveColor(),
    };

    final containerBg = switch (variant) {
      LoadingIndicatorM3EVariant.defaultStyle =>
        containerColor ?? tokens.containerColorDefault(),
      LoadingIndicatorM3EVariant.contained =>
        containerColor ?? tokens.containedContainerColor(),
    };

    final indicator = ExpressiveLoadingIndicator(
      color: activeColor,
      value: value,
      polygons: polygons,
      semanticsLabel: semanticLabel,
      semanticsValue: semanticValue,
      constraints: cons,
    );

    if (variant == LoadingIndicatorM3EVariant.defaultStyle) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: containerBg,
          borderRadius: tokens.containerRadius(),
        ),
        child: Padding(
          padding: padding ?? const EdgeInsets.all(0),
          child: indicator,
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: containerBg,
        borderRadius: tokens.containerRadius(),
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(0),
        child: indicator,
      ),
    );
  }
}

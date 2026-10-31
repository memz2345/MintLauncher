import 'package:flutter/material.dart';

import 'package:mint/widgets/progressive_blur.dart';

/// 顶栏下面那条「渐进模糊带」：着色器模糊在下、压字色在上。
///
/// 两层都平铺在带高里，**中间不许插任何 `Opacity` / `ShaderMask` /
/// `ColorFiltered`** —— 那会另起一个 backdrop root，模糊就糊不到滚上来的
/// 页面内容（见 [ProgressiveBlur] 的说明）。淡入靠 [intensity] 同时调
/// sigma 与压字色 alpha。
///
/// 压字色是**自上而下淡到 0** 的渐变（不是平铺）：平铺会在带的下边缘留下
/// 一条肉眼可见的分界线 —— 带内是「模糊 + 色」，带外是「纯内容」，色没衰减
/// 干净就接不上。
class MintProgressiveBand extends StatelessWidget {
  const MintProgressiveBand({
    super.key,
    required this.height,
    required this.intensity,
    required this.tint,
    this.maxSigma = 16,
    this.tintAlphaTop = 0.30,
    this.tintAlphaBottom = 0,
  });

  /// 带高（逻辑像素）。跟顶栏折叠后的高度对齐 —— 比栏矮会让带的下边缘落在
  /// 标题行中间，把本来该清楚的标题硬生生截成两段。
  final double height;

  /// 0 = 完全清晰且透明（整层不画），1 = 满强度。
  final double intensity;

  /// 压字色的基色。
  final Color tint;

  /// 强边（顶边）处模糊 sigma。顶栏用 10~16 比较接近 HyperOS 的观感。
  final double maxSigma;

  /// 顶边的压字色不透明度。
  final double tintAlphaTop;

  /// 底边的压字色不透明度。必须留 0，否则底边出现硬切边。
  final double tintAlphaBottom;

  @override
  Widget build(BuildContext context) {
    final i = intensity.clamp(0.0, 1.0);
    // 一点没滚就整层不画：省掉一次 backdrop 采样 + 两趟着色器。
    if (i <= 0.001) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: ProgressiveBlur(
              maxSigma: maxSigma * i,
              direction: ProgressiveBlurDirection.topToBottom,
              falloff: 1.2,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    tint.withValues(alpha: tintAlphaTop * i),
                    tint.withValues(alpha: tintAlphaBottom * i),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 渐变模糊顶栏的公共参数与判定。
///
/// 「渐变模糊顶栏」= 顶栏本体全透明（只有字样与动作图标）+ 顶部一条随滚动
/// 折叠度淡入的渐进模糊带。AppMarket / HyperOS 同款观感，比整块
/// `BackdropFilter` 的硬边干净得多。
class MintGradientBar {
  const MintGradientBar._();

  /// 满强度端的模糊 sigma（逻辑像素）。AppMarket `progressiveBarBlur` 的
  /// blurRadius = 10，换 sigma 用 0.45 的系数 ≈ 4.5；实测 12~16 在手机上
  /// 更接近「内容从栏下溶解」的观感，太低会看出一层灰膜。
  static const double maxSigma = 14;

  /// 顶边压字色不透明度。AppMarket 的 `surface @ 0.3f`。
  static const double tintAlphaTop = 0.30;

  /// 顶栏折叠后的高度（flutter_miuix 的 `MiuixTopAppBarDefaults.collapsedHeight`
  /// = 52，Material 工具栏 56）。
  static const double miuixBandHeight = 52;
  static const double materialBandHeight = 56;

  /// 带高 = 状态栏 + 栏高，桌面读不到 inset 时兜底 56。
  static double bandHeightOf(BuildContext context, double barHeight) =>
      (MediaQuery.paddingOf(context).top + barHeight).clamp(56.0, 200.0);
}

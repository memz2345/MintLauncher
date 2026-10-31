import 'package:flutter/material.dart';

/// 小米 HyperOS2 + Android 15 在小窗（freeform）/ 悬浮窗模式下，会把
/// captionBar 的 bounding rect 错当成整屏，于是 `MediaQuery.padding` /
/// `viewPadding` 的 top 返回离谱值（640、737 甚至更大）—— 被 `SafeArea`
/// 一吃，整页布局被狠狠往下挤，表现为「小米小窗里界面错位 / 大片空白」。
///
/// 上游 issue：https://github.com/flutter/flutter/issues/161086 （Open，未修）
///
/// 应用侧兜底：一旦 top/bottom 的 inset 超过「窗口高度的一半」，就判定为
/// 小窗的异常值并归零（正常的刘海 / 状态栏 / 手势条 inset 远小于此，
/// 不会误伤）。没有异常时原样返回，零开销。
///
/// 与 local2api / NaviFlash 同一份实现。
MediaQueryData sanitizeXiaomiFreeformPadding(MediaQueryData data) {
  final height = data.size.height;
  if (height <= 0) return data;

  final maxInset = height * 0.5;

  double top = data.padding.top;
  double bottom = data.padding.bottom;
  double viewTop = data.viewPadding.top;
  double viewBottom = data.viewPadding.bottom;

  if (top > maxInset) top = 0.0;
  if (bottom > maxInset) bottom = 0.0;
  if (viewTop > maxInset) viewTop = 0.0;
  if (viewBottom > maxInset) viewBottom = 0.0;

  if (top == data.padding.top &&
      bottom == data.padding.bottom &&
      viewTop == data.viewPadding.top &&
      viewBottom == data.viewPadding.bottom) {
    return data;
  }

  return data.copyWith(
    padding: data.padding.copyWith(top: top, bottom: bottom),
    viewPadding: data.viewPadding.copyWith(top: viewTop, bottom: viewBottom),
  );
}

/// 独立 Widget 包装器；主应用在 `app.dart` 的 builder 里直接调
/// [sanitizeXiaomiFreeformPadding]（要和显示缩放叠在一起，顺序不能错），
/// 这个包装器留给别处单独复用。
class XiaomiFreeformMediaQuery extends StatelessWidget {
  const XiaomiFreeformMediaQuery({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: sanitizeXiaomiFreeformPadding(MediaQuery.of(context)),
      child: child,
    );
  }
}

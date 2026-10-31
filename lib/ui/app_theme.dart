import 'package:flutter/material.dart';

import '../src/system_font.dart';
import '../widgets/ios_push_transition.dart';

/// Local2API 主题：M3 + 全平台 iOS 推入转场。
///
/// 在 PageTransitionsTheme 上注册 IosPushPageTransitionsBuilder 后，
/// 所有 MaterialPageRoute（以及子类）都会使用 iOS 风格推入动画，
/// 并自带预测式返回手势联动。
class AppTheme {
  AppTheme._();

  static const Color _seed = Color(0xFF4C6FFF);

  /// 转场圆角兜底值：设置里没配过、或（自动模式）读不到设备圆角时用它。
  static const double kDefaultCornerRadius = 26.0;

  /// 全局推入转场的圆角。
  ///
  /// 由调用方（`app.dart`）经 `DeviceCornerService.resolveFor(settings)` 解析后
  /// 传进来 —— 打开「自动跟随设备」且读到了屏幕圆角就是设备值，否则是设置页
  /// 滑块的手动值。注意**只**动圆角：转场速率 / 压暗 / 曲线全走
  /// [IosPushPageTransitionsBuilder] 的默认值，别在这里额外传参。
  // 注意：map 的 for 元素不支持 const，这里用 getter 返回。
  static PageTransitionsTheme transitions({
    double cornerRadius = kDefaultCornerRadius,
  }) => PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      for (final TargetPlatform p in TargetPlatform.values)
        p: IosPushPageTransitionsBuilder(cornerRadius: cornerRadius),
    },
  );

  static ThemeData light({double cornerRadius = kDefaultCornerRadius}) =>
      _base(ColorScheme.fromSeed(seedColor: _seed), cornerRadius: cornerRadius);

  static ThemeData dark({double cornerRadius = kDefaultCornerRadius}) => _base(
    ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
    cornerRadius: cornerRadius,
  );

  static ThemeData _base(
    ColorScheme scheme, {
    double cornerRadius = kDefaultCornerRadius,
  }) {
    final bool isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      // 系统字体：Windows 默认的 Segoe UI 没有中文字形，回退字体很怪。
      fontFamily: kSystemFontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? const Color(0xFF0E0F13) : null,
      pageTransitionsTheme: transitions(cornerRadius: cornerRadius),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.72),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.035),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        // 胶囊形（M3 出厂形状）。之前这里覆盖成 14 圆角的「方」按钮 ——
        // 那是 miuix 对话框按钮（MiuixDialogButton，cornerRadius 14）的
        // 样式，Material 这边不该跟：弹窗/面板的动作按钮按 M3 习惯用胶囊。
        style: FilledButton.styleFrom(shape: const StadiumBorder()),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.3),
        space: 1,
        thickness: 1,
      ),
    );
  }
}

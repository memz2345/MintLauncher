import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// MiuixColors → Material ColorScheme 的桥。
///
/// flutter_miuix 自己不提供这个映射。双风格迁移期间总会有页面还停在
/// Material 实现上（它们读 `Theme.of(context).colorScheme`），不搭这座桥
/// 就会一边是 HyperOS 配色、一边是 Material 默认紫，同屏打架。
///
/// 映射是近似的：miuix 的色板角色与 MD3 不是一一对应（比如它没有
/// plain `tertiary`，只有 `tertiaryContainer`），这里按语义挑最近的替身。
/// 页面迁到 miuix 实现后就不再走这条路。
ColorScheme materialSchemeFromMiuix(MiuixColors c, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  // 拿 miuix 的主色当种子先造一份合法底座，再逐项覆盖成 miuix 的值：
  // ColorScheme 有一堆必填角色（inverseSurface / scrim 等），
  // 从零构造容易漏，fromSeed + copyWith 不会。
  return ColorScheme.fromSeed(
    seedColor: c.primary,
    brightness: brightness,
  ).copyWith(
    primary: c.primary,
    onPrimary: c.onPrimary,
    primaryContainer: c.primaryContainer,
    onPrimaryContainer: c.onPrimaryContainer,
    primaryFixed: c.primaryContainer,
    onPrimaryFixed: c.onPrimaryContainer,
    primaryFixedDim: c.primaryVariant,
    onPrimaryFixedVariant: c.onPrimaryVariant,
    secondary: c.secondary,
    onSecondary: c.onSecondary,
    secondaryContainer: c.secondaryContainer,
    onSecondaryContainer: c.onSecondaryContainer,
    secondaryFixed: c.secondaryContainer,
    onSecondaryFixed: c.onSecondaryContainer,
    secondaryFixedDim: c.secondaryVariant,
    onSecondaryFixedVariant: c.onSecondaryVariant,
    // miuix 没有 plain tertiary，用它的 primaryVariant 当第二强调色
    tertiary: c.primaryVariant,
    onTertiary: c.onPrimaryVariant,
    tertiaryContainer: c.tertiaryContainer,
    onTertiaryContainer: c.onTertiaryContainer,
    tertiaryFixed: c.tertiaryContainer,
    onTertiaryFixed: c.onTertiaryContainer,
    tertiaryFixedDim: c.tertiaryContainerVariant,
    error: c.error,
    onError: c.onError,
    errorContainer: c.errorContainer,
    onErrorContainer: c.onErrorContainer,
    surface: c.surface,
    onSurface: c.onSurface,
    onSurfaceVariant: c.onSurfaceSecondary,
    surfaceDim: isDark ? c.background : c.surfaceContainerHighest,
    surfaceBright: isDark ? c.surfaceContainerHigh : c.surface,
    surfaceContainerLowest: c.background,
    surfaceContainerLow: c.surfaceContainer,
    surfaceContainer: c.surfaceContainer,
    surfaceContainerHigh: c.surfaceContainerHigh,
    surfaceContainerHighest: c.surfaceContainerHighest,
    inverseSurface: c.onSurface,
    onInverseSurface: c.surface,
    inversePrimary: c.onPrimary,
    outline: c.outline,
    outlineVariant: c.dividerLine,
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );
}

/// FlexSchemeVariant → MiuixThemePaletteStyle。
///
/// Flex 有 22 个变体，miuix 只有 9 种 palette（对应 material_color_utilities
/// 里那 9 个 DynamicScheme）。能对上的直接对，对不上的按观感挑最近的 ——
/// 反正底层都是同一套 HCT 计算，差别只在 chroma 与色相旋转。
MiuixThemePaletteStyle miuixPaletteStyleOf(FlexSchemeVariant variant) =>
    switch (variant) {
      FlexSchemeVariant.tonalSpot => MiuixThemePaletteStyle.tonalSpot,
      FlexSchemeVariant.fidelity => MiuixThemePaletteStyle.fidelity,
      FlexSchemeVariant.monochrome => MiuixThemePaletteStyle.monochrome,
      FlexSchemeVariant.neutral => MiuixThemePaletteStyle.neutral,
      FlexSchemeVariant.vibrant => MiuixThemePaletteStyle.vibrant,
      FlexSchemeVariant.expressive => MiuixThemePaletteStyle.expressive,
      FlexSchemeVariant.content => MiuixThemePaletteStyle.content,
      FlexSchemeVariant.rainbow => MiuixThemePaletteStyle.rainbow,
      FlexSchemeVariant.fruitSalad => MiuixThemePaletteStyle.fruitSalad,
      // 以下都是 Flex 独有的，miuix 没有对应物，按观感归到最近的一档
      FlexSchemeVariant.material ||
      FlexSchemeVariant.material3Legacy ||
      FlexSchemeVariant.soft => MiuixThemePaletteStyle.tonalSpot,
      FlexSchemeVariant.vivid ||
      FlexSchemeVariant.vividSurfaces ||
      FlexSchemeVariant.vividBackground ||
      FlexSchemeVariant.chroma ||
      FlexSchemeVariant.highContrast ||
      FlexSchemeVariant.ultraContrast ||
      FlexSchemeVariant.jolly => MiuixThemePaletteStyle.vibrant,
      FlexSchemeVariant.oneHue => MiuixThemePaletteStyle.monochrome,
      FlexSchemeVariant.candyPop => MiuixThemePaletteStyle.fruitSalad,
    };

/// 界面风格开关下，miuix 的配色模式该走哪一档。
///
/// **一律返回 monet\***：只有 monet 模式才会走 `_resolveMonet` 去吃
/// `keyColor` 与 `paletteStyle`；静态的 system/light/dark 用的是 miuix
/// 自带那套固定 HyperOS 配色，会把用户在「显示设置」里挑的种子色与
/// palette 变体整个忽略掉。
///
/// 跟随系统动态色这件事不在这里决定 —— 它只体现在调用方给不给 `keyColor`：
/// 给了就用种子色生成，留空 miuix 才会去读 Android 壁纸。
MiuixColorSchemeMode miuixColorSchemeModeOf({required ThemeMode themeMode}) =>
    switch (themeMode) {
      ThemeMode.light => MiuixColorSchemeMode.monetLight,
      ThemeMode.dark => MiuixColorSchemeMode.monetDark,
      ThemeMode.system => MiuixColorSchemeMode.monetSystem,
    };

/// 「自定义颜色」关掉、也没开系统动态取色时，miuix 该走哪一档：**静态出厂配色**。
///
/// 对应 InstallerX `InstallerMiuixTheme` 的 Default Miuix Theme Path
/// （`useMiuixMonet = false`）：`ColorSchemeMode.System/Light/Dark` 直接用
/// flutter_miuix 自带的 `lightColorScheme()` / `darkColorScheme()` ——
/// 也就是 HyperOS 出厂蓝（浅色主色 `0xFF3482FF`、深色 `0xFF277AF7`），
/// 既不吃种子色也不吃 palette 变体。Material 分支不读这个开关，互不影响。
MiuixColorSchemeMode miuixDefaultColorSchemeModeOf({
  required ThemeMode themeMode,
}) => switch (themeMode) {
  ThemeMode.light => MiuixColorSchemeMode.light,
  ThemeMode.dark => MiuixColorSchemeMode.dark,
  ThemeMode.system => MiuixColorSchemeMode.system,
};

/// SettingsService.fontWeight（300..800）→ miuix 的字重偏移量。
///
/// miuix 的偏移以 100 为一档、相对 400 基准，所以 400 → 0、700 → 300。
int miuixFontWeightAdjustmentOf(double fontWeight) =>
    (fontWeight.round() - 400).clamp(-100, 400);

/// miuix 分支下 Material 输入框的装饰：**什么都不画**。
///
/// 为什么必须掐掉：`AppTheme` 给 Material 侧配了
/// `inputDecorationTheme(filled: true, fillColor: 半透明黑/白)`，而
/// `MiuixTextField` 内部就是一个 Material `TextField`（它自带
/// `InputDecoration(border: InputBorder.none, contentPadding: zero)`，
/// 但**没写 filled**）——`InputDecoration.applyDefaults` 会把主题里的
/// `filled` / `fillColor` / `enabledBorder` / `focusedBorder` 一并补进去。
/// 结果：miuix 输入框在自己那块 `secondaryContainer` 底色上又叠了一层灰色
/// 填充（还带主题那圈聚焦描边），看起来就像「有一圈神秘包边」。
///
/// 归零之后，输入框外观完全由 `MiuixTextField` 自己画（squircle 底 + 聚焦描边）。
/// Material 分支不受影响 —— 这份只在 `_buildMiuixApp` 里覆盖上去。
const InputDecorationThemeData kMiuixNeutralInputDecoration =
    InputDecorationThemeData(
      filled: false,
      fillColor: Colors.transparent,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
      contentPadding: EdgeInsets.zero,
      isDense: true,
    );

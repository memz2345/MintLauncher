import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/nine_patch.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/theme_package.dart';

/// 主题壁纸铺在页面上的不透明度（清晰、不模糊；可读性交给卡片遮罩）。
const double kMintThemeWallpaperOpacity = 0.88;

/// 可被单独指定背景的页面（mtz 背景预览器的「设为…」目标）。
///
/// [sheet] 不是页面：底部对话框（动作单 / 抽屉）声明的背景 —— MIUI 的
/// 底部菜单底色是透明的，透出来的就是应用声明的窗口背景图，这里照搬
/// 那个观感。落盘键就是 [id]。
enum MintPageBackgroundKey {
  home('home', '首页'),
  download('download', '下载'),
  downloads('downloads', '下载管理'),
  settings('settings', '设置'),
  theme('theme', '主题'),
  about('about', '关于'),
  sheet('sheet', '底部弹窗');

  const MintPageBackgroundKey(this.id, this.label);
  final String id;
  final String label;

  static MintPageBackgroundKey? byId(String id) {
    for (final k in values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

/// 当前页面所属的背景键。挂在页面壳（MintPageScaffold / 首页外壳）上，
/// `PageBackground` 与弹窗据此决定用哪张「按页指定」的背景图。
class MintPageBackgroundScope extends InheritedWidget {
  const MintPageBackgroundScope({
    super.key,
    required this.keyId,
    required super.child,
  });

  /// [MintPageBackgroundKey.id]。
  final String keyId;

  static String of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<MintPageBackgroundScope>()
            ?.keyId ??
        '';
  }

  @override
  bool updateShouldNotify(MintPageBackgroundScope oldWidget) =>
      keyId != oldWidget.keyId;
}

/// 页面背景（G:\192\local2api 的 `PageBackground` 同款移植）：
/// 一层纯色画布（[baseColor]）+ 可选的自定义图片层（`Image.file` +
/// `BoxFit.cover`，支持整体透明度和 0~24 的高斯模糊）。
///
/// 挂在页面壳 Stack 的最底层：没有启用图片时只画画布（或干脆不画，
/// 保持原样）；启用后图片铺满页面，内容与标题栏都浮在它上面，
/// 解决「透明层叠透明层」的难看重叠。
///
/// 背景图解析顺序：**按页指定**（mtz 背景预览器设的，当前页有
/// [MintPageBackgroundScope] 时）→ 全局自定义背景图 → 当前主题壁纸。
class PageBackground extends StatelessWidget {
  const PageBackground({super.key, this.baseColor});

  /// 画布底色。null 且图片不可用时整个组件不画任何东西。
  final Color? baseColor;

  @override
  Widget build(BuildContext context) {
    final image = _imageLayer(context);
    if (baseColor == null) return image ?? const SizedBox.shrink();
    return ColoredBox(
      color: baseColor!,
      child: image == null
          ? null
          : Stack(fit: StackFit.expand, children: [image]),
    );
  }

  Widget? _imageLayer(BuildContext context) {
    final active = mintActivePageBackgroundImage(context);
    if (active == null) return null;
    final path = resolveDisplayImage(active.path);

    // 按屏幕最长边 × DPR 限制解码尺寸，避免 4K 大图整页糊脸还吃内存。
    final mq = MediaQuery.maybeOf(context);
    final int decodeCap = mq == null
        ? 2560
        : (mq.size.longestSide * mq.devicePixelRatio).round().clamp(720, 2560);

    return Opacity(
      opacity: active.opacity,
      child: active.blur > 0.5
          ? ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: active.blur,
                sigmaY: active.blur,
              ),
              child: _image(path, decodeCap),
            )
          : _image(path, decodeCap),
    );
  }

  Widget _image(String path, int cacheWidth) {
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}

SettingsService? _settingsOf(BuildContext context) {
  try {
    return Provider.of<SettingsService>(context);
  } on ProviderNotFoundException {
    return null;
  }
}

bool _hasUsableImage(String path) => path.isNotEmpty && File(path).existsSync();

/// 当前页面是否真的铺着背景图：按页指定 / 用户指定的页面背景，或主题包壁纸。
///
/// 卡片 / 弹窗据此决定要不要改用半透明遮罩 —— 没有背景图时保持原来的
/// 实色卡面，避免「明明纯色背景，卡片却透着底色」的脏观感。
bool mintPageBackgroundActive(BuildContext context) {
  return mintActivePageBackgroundImage(context) != null;
}

/// 外壳（首页 / 下载页）已经把背景图铺到整屏（包括底栏区域）时，
/// 页面骨架不再重复画一层图，避免两层不同裁切的图片在底栏边缘接缝。
class MintShellBackgroundScope extends InheritedWidget {
  const MintShellBackgroundScope({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<MintShellBackgroundScope>()
            ?.active ??
        false;
  }

  @override
  bool updateShouldNotify(MintShellBackgroundScope oldWidget) =>
      active != oldWidget.active;
}

MintTheme? _activeThemeOf(BuildContext context) {
  final settings = _settingsOf(context);
  if (settings == null) return null;
  return MintThemeLibrary.instance.byId(settings.activeThemeId);
}

/// 当前页面实际铺着的背景图（按页指定 > 全局自定义 > 主题壁纸）及
/// 不透明度 / 模糊。
///
/// 顶栏取色用它：采样图片顶部亮度来决定黑/白文字。没启用背景图时返回
/// null，调用方按主题明暗直接取纯黑/纯白。
({String path, double opacity, double blur})? mintActivePageBackgroundImage(
  BuildContext context,
) {
  final settings = _settingsOf(context);
  if (settings == null) return null;

  ({String path, double opacity, double blur})? pick(String path) {
    if (!_hasUsableImage(path)) return null;
    return (
      path: path,
      opacity: settings.pageBackgroundOpacity.clamp(0.0, 1.0),
      blur: settings.pageBackgroundBlur.clamp(0.0, 24.0),
    );
  }

  // 1. 按页指定（预览器里「设为首页背景」这类）。
  final pageKey = MintPageBackgroundScope.of(context);
  if (pageKey.isNotEmpty) {
    final assigned = pick(settings.pageBackgroundFor(pageKey));
    if (assigned != null) return assigned;
  }

  // 2. 全局自定义背景图。
  if (settings.pageBackgroundEnabled && settings.pageBackgroundPath.isNotEmpty) {
    final custom = pick(settings.pageBackgroundPath);
    if (custom != null) return custom;
  }

  // 3. 主题壁纸。主题壁纸保持清晰（不模糊），透明度只稍微收一点；
  //    可读性交给卡片 / 弹窗的半透明主题色遮罩，而不是糊掉壁纸。
  if (!settings.themeUseWallpaper) return null;
  final theme = MintThemeLibrary.instance.byId(settings.activeThemeId);
  if (theme == null || !_hasUsableImage(theme.wallpaper)) return null;
  return (
    path: theme.wallpaper,
    opacity: kMintThemeWallpaperOpacity,
    blur: 0.0,
  );
}

/// 底部对话框（动作单 / 抽屉）该铺的背景图路径，null = 没有声明，画实色。
///
/// 取值：预览器里指定给「底部弹窗」的图 → 主题**弹窗级**的声明背景
/// （拨号盘 `dialerpad_background` —— 弹出的拨号面板本身就带一张弹窗背景，
/// 用户截图里那张浅蓝芙宁娜就是它，比整屏 window_bg 更对味）→ 退回主题
/// 声明的设置窗口背景。三套风格共用：调用方是 MintStyleDialogShell 体系的
/// 底部弹窗，Material / Fluent 也走这里。
String? mintSheetBackgroundPathOf(BuildContext context) {
  final settings = _settingsOf(context);
  if (settings == null) return null;
  final assigned = settings.pageBackgroundFor(MintPageBackgroundKey.sheet.id);
  if (_hasUsableImage(assigned)) return assigned;
  final theme = _activeThemeOf(context);
  if (theme == null) return null;
  final dark = Theme.of(context).brightness == Brightness.dark;
  final popup = theme.sheetBackgroundFor(dark)?.path;
  if (_hasUsableImage(popup ?? '')) return popup;
  final declared = theme.settingsBackgroundFor(dark);
  return _hasUsableImage(declared) ? declared : null;
}

/// 有背景图时的卡片底色：主题声明的 `card_view_background_color`
/// （一般是主色 30% 的半透明层）优先，否则用主题主色 16% 叠在原卡面上。
///
/// `fallback` 是各风格自己的卡面实色；这里把它降到 72% 再叠遮罩，
/// 既能让壁纸透出来，又不会让正文直接压在花纹上。
Color mintCardMaskColor(BuildContext context, Color fallback) {
  if (!mintPageBackgroundActive(context)) return fallback;
  final cs = Theme.of(context).colorScheme;
  final declared = _activeThemeOf(context)?.cardColor;
  final mask = declared ?? cs.primary.withValues(alpha: 0.16);
  return Color.alphaBlend(mask, fallback.withValues(alpha: 0.72));
}

/// 有背景图时的弹窗底色：比卡片更实（94%），再叠主题声明的弹窗色，
/// 保证弹窗里的正文可读，同时保留主题色调。
Color mintDialogMaskColor(BuildContext context, Color fallback) {
  if (!mintPageBackgroundActive(context)) return fallback;
  final cs = Theme.of(context).colorScheme;
  final theme = _activeThemeOf(context);
  final mask =
      theme?.dialogColor ??
      theme?.cardColor ??
      cs.primary.withValues(alpha: 0.10);
  return Color.alphaBlend(mask, fallback.withValues(alpha: 0.94));
}

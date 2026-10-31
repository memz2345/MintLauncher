import 'dart:io';

import 'package:flutter/services.dart';

import 'package:mint/services/settings_service.dart';
import 'package:mint/services/theme_package.dart';

/// 主题字体（MIUI 主题包 `fonts` 模块）的运行时加载。
///
/// Flutter 只能用 [FontLoader] 把 ttf/otf 注册成一个家族名；注册发生在
/// `runApp` 之前（main 里 load），之后 `ThemeFonts.family` 就会被 ThemeData /
/// Miuix 的 textStyles 使用。切换主题字体需要重启应用（引擎的字体注册不可逆）。
class ThemeFonts {
  ThemeFonts._();

  /// 已注册的主题字体家族名；null = 用系统字体。
  static String? family;

  static const String _loaderFamily = 'MintThemeFont';

  /// 按当前设置解析并注册字体。失败时安静回退系统字体。
  static Future<void> load(SettingsService settings) async {
    final theme = MintThemeLibrary.instance.byId(settings.activeThemeId);
    family = null;
    if (theme == null || !settings.themeUseFont || theme.fontFile.isEmpty) {
      return;
    }
    final file = File(theme.fontFile);
    if (!file.existsSync()) return;
    try {
      final bytes = await file.readAsBytes();
      final loader = FontLoader(_loaderFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      family = _loaderFamily;
    } catch (_) {
      family = null;
    }
  }
}

import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: deprecated_member_use
import 'package:material_color_utilities/material_color_utilities.dart'
    show CorePalette;

/// 动态取色：Material You 调色板（Android）或系统强调色（桌面）。
/// local2api 同名组件的精简版（去掉私有原生通道，dynamic_color 插件够用）。
class AppDynamicColorBuilder extends StatefulWidget {
  const AppDynamicColorBuilder({super.key, required this.builder});

  final Widget Function(ColorScheme? lightDynamic, ColorScheme? darkDynamic)
  builder;

  @override
  State<AppDynamicColorBuilder> createState() => _AppDynamicColorBuilderState();
}

class _AppDynamicColorBuilderState extends State<AppDynamicColorBuilder> {
  ColorScheme? _light;
  ColorScheme? _dark;

  int? _lastLightPrimary;
  int? _lastDarkPrimary;

  @override
  void initState() {
    super.initState();
    _loadPalette();
  }

  Future<void> _loadPalette() async {
    try {
      // ignore: deprecated_member_use
      final CorePalette? palette = await DynamicColorPlugin.getCorePalette();
      if (!mounted) return;
      if (palette != null) {
        _applySchemes(
          palette.toColorScheme(),
          palette.toColorScheme(brightness: Brightness.dark),
        );
        return;
      }
    } on PlatformException {
      // 低版本系统没有 Material You 调色板：忽略
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        final Color? accent = await DynamicColorPlugin.getAccentColor();
        if (!mounted || accent == null) return;
        _applySchemes(
          ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.light),
          ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
        );
      } on PlatformException {
        if (kDebugMode) debugPrint('AppDynamicColor: 获取系统强调色失败');
      }
    }
  }

  void _applySchemes(ColorScheme light, ColorScheme dark) {
    final lp = light.primary.toARGB32();
    final dp = dark.primary.toARGB32();
    if (lp == _lastLightPrimary && dp == _lastDarkPrimary) return;
    _lastLightPrimary = lp;
    _lastDarkPrimary = dp;
    setState(() {
      _light = light;
      _dark = dark;
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(_light, _dark);
}

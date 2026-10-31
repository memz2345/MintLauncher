import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mint/services/liquid_glass_bar_service.dart';

/// 原生液态玻璃底栏的显示编排（Material / miuix 两套主页壳共用）。
///
/// 原生底栏是挂在 FlutterView 之上的 ComposeView，不参与 widget 树：
/// 页面里只留一个同高的占位，显示 / 换页 / 隐藏全靠这里。
class NativeGlassBarBinding {
  NativeGlassBarBinding();

  bool _shown = false;
  bool _failed = false;
  String? _sizeKey;
  int? _index;
  Brightness? _brightness;

  bool get shown => _shown;
  bool get failed => _failed;

  Future<void> sync({
    required BuildContext context,
    required bool enabled,
    required int index,
    required List<LiquidGlassBarTab> tabs,
    Color? accent,
  }) async {
    if (!enabled || tabs.isEmpty || _failed) {
      await hide();
      return;
    }
    final media = MediaQuery.sizeOf(context);
    final sizeKey = '${media.width.round()}x${media.height.round()}';
    final brightness = Theme.of(context).brightness;
    final needShow =
        !_shown || _sizeKey != sizeKey || _brightness != brightness;
    if (!needShow && _index == index) return;
    if (needShow) {
      final ok = await LiquidGlassBarService.show(
        context: context,
        tabs: tabs,
        index: index,
        height: LiquidGlassBarService.barHeight,
        accent: accent,
      );
      if (!ok) {
        // 原生不可用（老设备 / 通道异常）：本次运行永久回退 Flutter 底栏。
        _failed = true;
        _shown = false;
        LiquidGlassBarService.enabled = false;
        return;
      }
      _shown = true;
      _sizeKey = sizeKey;
      _brightness = brightness;
      _index = index;
    } else {
      await LiquidGlassBarService.updateIndex(index);
      _index = index;
    }
  }

  Future<void> hide() async {
    if (!_shown) return;
    _shown = false;
    _index = null;
    _sizeKey = null;
    await LiquidGlassBarService.hide();
  }

  void dispose() {
    unawaited(hide());
  }
}

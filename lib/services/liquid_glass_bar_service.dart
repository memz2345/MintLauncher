import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

class LiquidGlassBarTab {
  final String id;
  final String label;
  final IconData icon;
  final IconData? selectedIcon;

  /// miuix 矢量图标的 SVG 路径串（原始 `d` 数据）。非空时原生侧优先渲染
  /// 矢量（Compose PathParser），忽略 [icon]/[selectedIcon] 的字体字形。
  final String? iconPath;

  /// [iconPath] 的视口边长（路径坐标所在坐标系）。
  final double iconViewport;

  /// miuix 生成数据带的绕中心 Y 翻转（`group(scaleY=-1, translationY=vp)`）。
  final bool iconFlipY;

  /// 图标右上角的小红点（下载 tab 有进行中的任务时）。
  final bool badge;

  const LiquidGlassBarTab({
    required this.id,
    required this.label,
    required this.icon,
    this.selectedIcon,
    this.iconPath,
    this.iconViewport = 24,
    this.iconFlipY = false,
    this.badge = false,
  });
}

final RouteObserver<ModalRoute<void>> liquidGlassBarRouteObserver =
    RouteObserver<ModalRoute<void>>();

class LiquidGlassBarService {
  LiquidGlassBarService._();

  static const MethodChannel _channel = MethodChannel(
    'dev.mint.mint/liquid_bar',
  );

  static bool enabled = true;

  static const double barHeight = 64;

  static const double bottomGap = 12;

  static double slotHeight(BuildContext context) =>
      barHeight + bottomGap + MediaQuery.paddingOf(context).bottom;

  static final List<void Function(int index)> _tabSelectedStack =
      <void Function(int index)>[];

  static void Function(int index)? get onTabSelected =>
      _tabSelectedStack.isEmpty ? null : _tabSelectedStack.last;

  static bool get hasTabSelectedOwner => _tabSelectedStack.isNotEmpty;

  static void bindTabSelected(void Function(int index) callback) {
    _tabSelectedStack.remove(callback);
    _tabSelectedStack.add(callback);
  }

  static void unbindTabSelected(void Function(int index) callback) {
    _tabSelectedStack.remove(callback);
  }

  @visibleForTesting
  static void debugReset() {
    _tabSelectedStack.clear();
    _visibleOwner = null;
    enabled = true;
    debugForceNative = false;
    stopFrameSync();
    _pendingPixels = null;
  }

  /// 底栏可见期间逐帧通知原生「这一帧有新画面」，原生在 vsync 帧头重抓背景。
  ///
  /// 不能只靠滚动通知驱动：Flutter 滚动不重建 widget，通知也只在真正滚动时才有，
  /// 而切页 / 转场 / 动画同样会改变玻璃身后的画面。这里用 post-frame 回调链做驱动，
  /// addPostFrameCallback 本身不会额外排帧，所以静止时链条自然停住，零开销。
  static int _syncGeneration = 0;
  static double? _pendingPixels;

  static void startFrameSync() {
    if (!canUseNative) return;
    _armNextFrame(++_syncGeneration);
  }

  static void stopFrameSync() => _syncGeneration++;

  /// 可见页的绝对滚动位置（逻辑像素），原生用它对滞后的旧图做平移补偿。
  static void reportScroll(double pixels) => _pendingPixels = pixels;

  static void _armNextFrame(int generation) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (generation != _syncGeneration) return;
      if (!canUseNative) return;
      final pixels = _pendingPixels;
      _pendingPixels = null;
      _channel
          .invokeMethod<void>('sync', <String, Object?>{'pixels': ?pixels})
          .catchError((_) {});
      _armNextFrame(generation);
    });
  }

  static bool _handlerInstalled = false;

  static bool get _platformSupported => debugForceNative || Platform.isAndroid;

  static bool get canUseNative => enabled && _platformSupported;

  @visibleForTesting
  static bool debugForceNative = false;

  static bool ownsVisibleBar(void Function(int index) callback) =>
      _visibleOwner == callback;

  static void Function(int index)? _visibleOwner;

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler(_handleCall);
  }

  static Future<bool> show({
    required BuildContext context,
    required List<LiquidGlassBarTab> tabs,
    required int index,
    double height = barHeight,
    Color? accent,
  }) async {
    if (!canUseNative || tabs.isEmpty) return false;
    _ensureHandler();
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    try {
      final ok = await _channel.invokeMethod<bool>('showBar', {
        'tabs': [
          for (final t in tabs)
            {
              'id': t.id,
              'label': t.label,
              'iconCodePoint': t.icon.codePoint,
              'iconFontFamily': t.icon.fontFamily,
              'selectedIconCodePoint': t.selectedIcon?.codePoint,
              'iconPath': ?t.iconPath,
              'iconViewport': t.iconViewport,
              'iconFlipY': t.iconFlipY,
              'badge': t.badge,
            },
        ],
        'index': index,
        'height': height,
        'bottomInset': bottomInset,
        'dark': Theme.of(context).brightness == Brightness.dark,
        'accent': accent?.toARGB32(),
      });

      if (ok == true) {
        _visibleOwner = onTabSelected;
        startFrameSync();
      }
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> updateIndex(int index) async {
    if (!canUseNative) return;
    try {
      await _channel.invokeMethod<void>('updateIndex', {'index': index});
    } catch (_) {}
  }

  static Future<void> hide() async {
    _visibleOwner = null;
    stopFrameSync();
    if (!_platformSupported) return;
    try {
      await _channel.invokeMethod<void>('hideBar');
    } catch (_) {}
  }

  static Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method == 'onTabSelected') {
      final args = call.arguments;
      final index = args is Map ? (args['index'] as num?)?.toInt() : null;
      if (index != null) onTabSelected?.call(index);
    }
    return null;
  }
}

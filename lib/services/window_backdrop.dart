import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'package:mint/src/enums.dart';

/// Windows 窗口背景材质（Mica / Acrylic / Tabbed / Aero）。
///
/// WinUI 里是 `SystemBackdrop`，Flutter 没有现成 API，这里走 runner 的
/// 原生方法通道（`windows/runner/window_backdrop.cpp`）：
///
///  · Windows 11 22621+ → DWM `SYSTEMBACKDROP_TYPE`（2/3/4）
///  · Windows 11 22000  → 未公开的 `MICA_EFFECT`
///  · Windows 10 1809+  → `SetWindowCompositionAttribute` 亚克力
///  · Aero 始终走 `ACCENT_ENABLE_BLURBEHIND`
///
/// 窗口透明由 `window_manager.setBackgroundColor(Colors.transparent)`
/// 打开。桌面壁纸/其它窗口透过 Flutter 视图的透明区域可见，页面再叠
/// 一层主题色保证可读性。
class WindowBackdrop extends ChangeNotifier {
  WindowBackdrop._();

  static final WindowBackdrop instance = WindowBackdrop._();

  static const MethodChannel _channel = MethodChannel('mint/backdrop');

  bool _initialized = false;
  bool _available = false;
  bool _isActive = false;
  Map<String, dynamic> _capabilities = const {};
  WindowBackdropMode _requested = WindowBackdropMode.disabled;
  WindowBackdropMode _applied = WindowBackdropMode.disabled;
  bool _fallback = false;

  bool get isActive => _isActive;
  bool get available => _available;
  WindowBackdropMode get requestedMode => _requested;
  WindowBackdropMode get appliedMode => _applied;
  bool get fellBack => _fallback;
  int get build => (_capabilities['build'] as num?)?.toInt() ?? 0;

  bool supports(WindowBackdropMode mode) {
    if (!Platform.isWindows || !_available) return false;
    return switch (mode) {
      WindowBackdropMode.disabled => true,
      WindowBackdropMode.mica => _capabilities['mica'] == true,
      WindowBackdropMode.acrylic => _capabilities['acrylic'] == true,
      WindowBackdropMode.tabbed => _capabilities['tabbed'] == true,
      WindowBackdropMode.aero => _capabilities['aero'] == true,
    };
  }

  /// 初始化能力探测（不应用效果）。失败时所有效果显示为不可用。
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isWindows) return;
    try {
      final caps = await _channel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      _capabilities = caps ?? const {};
      _available = _capabilities['supported'] == true;
    } catch (e) {
      _available = false;
      debugPrint('MintBackdrop caps failed: $e');
    }
    notifyListeners();
  }

  Future<void> _applyQueue = Future<void>.value();
  String _lastKey = '';

  /// 应用设置（带 180ms 节流合并）。重复参数直接跳过。
  void apply({
    required WindowBackdropMode mode,
    required bool dark,
    required Color surfaceColor,
  }) {
    if (!Platform.isWindows) return;
    // 模糊强度/底色透明度只影响 Flutter 侧的叠加层，不触发原生重设。
    final key = '${mode.id}|$dark|${surfaceColor.toARGB32()}';
    if (key == _lastKey) return;
    _lastKey = key;
    _requested = mode;
    _applyQueue = _applyQueue.then(
      (_) => _applyNow(mode: mode, dark: dark, surfaceColor: surfaceColor),
    );
  }

  Future<void> _applyNow({
    required WindowBackdropMode mode,
    required bool dark,
    required Color surfaceColor,
  }) async {
    try {
      if (!_initialized) await ensureInitialized();
      if (!_available) {
        _setActive(false);
        return;
      }
      if (mode == WindowBackdropMode.disabled) {
        await _channel.invokeMethod<void>('reset');
        await windowManager.setBackgroundColor(surfaceColor);
        _applied = WindowBackdropMode.disabled;
        _fallback = false;
        _setActive(false);
        return;
      }

      // 透明窗口是材质能透出来的前提；window_manager 会通过
      // SetWindowCompositionAttribute(ACCENT_ENABLE_TRANSPARENTGRADIENT)
      // 打开。原生 setBackdrop 会在这之后再覆盖 accent 策略。
      await windowManager.setBackgroundColor(Colors.transparent);
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'setBackdrop',
        {
          'mode': mode.id,
          'dark': dark,
          // 原生只取这个色的 RGB；Dart 侧再叠主题色。
          'tint': surfaceColor.toARGB32(),
        },
      );
      final appliedId = result?['applied'] as String?;
      if (appliedId == null || appliedId == 'off') {
        _applied = WindowBackdropMode.disabled;
        _fallback = true;
        _setActive(false);
        return;
      }
      _applied = WindowBackdropMode.fromId(appliedId);
      _fallback = result?['fallback'] == true;
      _setActive(true);
      _scheduleCaptionFix();
    } catch (e) {
      debugPrint('MintBackdrop apply failed: $e');
      // 允许下一帧重试（例如窗口/通道尚未就绪）。
      _lastKey = '';
      _applied = WindowBackdropMode.disabled;
      _fallback = false;
      _setActive(false);
      try {
        await windowManager.setBackgroundColor(surfaceColor);
      } catch (_) {}
    }
  }

  /// `DwmExtendFrameIntoClientArea(-1)` 带出来的原生 caption 在窗口
  /// 首帧前后可能被 DWM 重新画出来（Win11 上首次 DWMWA_CAPTION_COLOR
  /// 调用会 E_INVALIDARG）。原生侧已有一组 timer 重试，这里再从 Dart
  /// 侧补几次，确保「启动后一直不激活」也能干净。
  void _scheduleCaptionFix() {
    for (final delay in const [220, 700, 1500]) {
      Future<void>.delayed(Duration(milliseconds: delay), () {
        if (!_isActive) return;
        _channel.invokeMethod<void>('hideCaption').catchError((_) {});
      });
    }
  }

  /// 窗口获得焦点 / 最大化后由标题栏再喊一次（DWM 会重排 frame）。
  void reapplyCaption() {
    if (!Platform.isWindows || !_isActive) return;
    _channel.invokeMethod<void>('hideCaption').catchError((_) {});
  }

  void _setActive(bool value) {
    if (_isActive == value) return;
    _isActive = value;
    notifyListeners();
  }

  /// 页面玻璃底色的建议不透明度：材质越“糊”，底色调可以越薄。
  double tintFor(WindowBackdropMode mode, double userTint, bool dark) {
    // 截图/诊断钩子：完全去掉 Flutter 侧底色，验证 DWM 材质是否透出来。
    if (const bool.fromEnvironment('MINT_BACKDROP_CLEAR')) return 0.0;
    final base = switch (mode) {
      WindowBackdropMode.disabled => 1.0,
      WindowBackdropMode.mica => userTint,
      WindowBackdropMode.acrylic => userTint + 0.03,
      WindowBackdropMode.tabbed => userTint + 0.01,
      WindowBackdropMode.aero => userTint - 0.06,
    };
    return (base + (dark ? 0.04 : 0)).clamp(0.2, 0.98);
  }
}

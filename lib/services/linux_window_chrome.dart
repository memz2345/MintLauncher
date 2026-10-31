import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Linux 自绘标题栏支撑：无边框窗口 + GTK 图标主题的系统三大金刚图标。
///
/// Windows 的金刚字形来自 Segoe Fluent Icons（系统字体）；Linux 的对应物
/// 是当前图标主题的 `window-*-symbolic`（Adwaita / Breeze / Yaru 都带），
/// 由 runner（`linux/runner/window_chrome.cc`）按 Flutter 传入的前景色
/// 着色渲染成 PNG 回传 —— 换系统主题图标也跟着换，和 Windows 用系统
/// 字形是同一个思路。主题里没有这组图标时调用方回退矢量绘制。
class LinuxWindowChrome extends ChangeNotifier {
  LinuxWindowChrome._();

  static final LinuxWindowChrome instance = LinuxWindowChrome._();

  static const MethodChannel _channel = MethodChannel('mint/window_chrome');

  bool _customFrameRequested = false;
  final Map<int, Map<String, Uint8List>> _icons = {};
  final Set<int> _iconRequests = {};

  /// 摘掉 GTK 原生装饰（在窗口 show 之前调用就不会闪）。拖动 / 缩放 /
  /// 最大化等操作走 window_manager 的 Linux 实现（begin_move_drag /
  /// begin_resize_drag）。
  Future<void> ensureCustomFrame() async {
    if (!Platform.isLinux || _customFrameRequested) return;
    _customFrameRequested = true;
    try {
      await _channel.invokeMethod<void>('setCustomFrame', {'on': true});
    } catch (e) {
      debugPrint('LinuxWindowChrome setCustomFrame failed: $e');
      _customFrameRequested = false;
    }
  }

  /// 已缓存的图标（key: minimize/maximize/restore/close），没有则 null。
  Uint8List? icon(int fgArgb, String key) {
    final set_ = _icons[fgArgb];
    return set_?[key];
  }

  /// 请求按 [fgArgb] 着色的一套图标。已缓存 / 已在加载则直接返回；
  /// 通道不可用（测试 / 无 handler）时安静失败，调用方用矢量回退。
  Future<void> ensureIcons(int fgArgb) async {
    if (!Platform.isLinux) return;
    if (_iconRequests.contains(fgArgb)) return;
    _iconRequests.add(fgArgb);
    Map<String, Uint8List> loaded = const {};
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getWindowIcons',
        {'fg': fgArgb},
      );
      if (result != null) {
        loaded = result.map(
          (key, value) => MapEntry(key, value as Uint8List),
        );
      }
    } catch (e) {
      debugPrint('LinuxWindowChrome getWindowIcons failed: $e');
    }
    _icons[fgArgb] = loaded;
    notifyListeners();
  }

  /// 测试用：清空缓存与请求记录。
  void reset() {
    _icons.clear();
    _iconRequests.clear();
    notifyListeners();
  }
}

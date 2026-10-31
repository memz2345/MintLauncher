import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 自绘标题栏与原生窗口之间的补充通道。
///
/// 最大化按钮的热区必须让给顶层窗口（Win11 Snap Layouts 要求
/// `WM_NCHITTEST` 回 `HTMAXBUTTON`），Flutter 子窗口因此收不到这块的
/// 鼠标 move/enter。原生侧在 `WM_NCHITTEST` / `WM_NCMOUSEMOVE` 里判断
/// 指针是否落在最大化按钮上，通过 `mint/window_chrome` 把 hover 和点击
/// 回传给 Dart；这样最大化按钮也能和另外两个金刚一样有悬浮态与 ripple。
class WindowCaptionSignals {
  WindowCaptionSignals._();

  static final WindowCaptionSignals instance = WindowCaptionSignals._();

  static const MethodChannel _channel = MethodChannel('mint/window_chrome');

  /// 原生窗口报告的「指针在最大化按钮上」。
  final ValueNotifier<bool> maximizeHover = ValueNotifier<bool>(false);

  /// 原生处理了最大化热区的点击；每点一次 +1，用于触发 ripple。
  final ValueNotifier<int> maximizeClick = ValueNotifier<int>(0);

  /// 原生最大化热区的按下收场；每收场一次 +1。
  ///
  /// 值本身只用来计数，是否真正激活看 [maximizeReleaseActivated]。
  final ValueNotifier<int> maximizeRelease = ValueNotifier<int>(0);

  /// 最近一次最大化释放是否应该触发点击（false = 拖出 / 失焦取消）。
  bool maximizeReleaseActivated = false;

  bool _bound = false;

  void bind() {
    if (_bound) return;
    _bound = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'maximizeHover':
          final value = call.arguments;
          maximizeHover.value = value is bool ? value : false;
        case 'maximizeClick':
          maximizeClick.value = maximizeClick.value + 1;
        case 'maximizeRelease':
          maximizeReleaseActivated = call.arguments == true;
          maximizeRelease.value = maximizeRelease.value + 1;
      }
      return null;
    });
  }

  /// 让原生按「系统动画关闭时自绘缓动」的规则切换最大化 / 还原。
  /// 无原生实现（测试 / 非 Windows）时抛异常，由调用方回退到 window_manager。
  Future<void> toggleMaximize() =>
      _channel.invokeMethod<void>('toggleMaximize');

  /// Windows：在光标位置弹出**原生**系统菜单（GetSystemMenu + TrackPopupMenu）。
  Future<void> showSystemMenu() =>
      _channel.invokeMethod<void>('showSystemMenu');

  /// 测试用：清空状态，避免单例跨用例串。
  @visibleForTesting
  void reset() {
    maximizeHover.value = false;
    maximizeClick.value = 0;
    maximizeRelease.value = 0;
    maximizeReleaseActivated = false;
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一条音频流的音量状态（原生 `ACTION_VOLUME_CHANGED` 推过来的）。
class MintVolumeState {
  const MintVolumeState({
    required this.stream,
    required this.value,
    required this.max,
    required this.muted,
  });

  /// `AudioManager.STREAM_*`：3 = 媒体，2 = 铃声，4 = 闹钟，5 = 通知。
  final int stream;
  final int value;
  final int max;
  final bool muted;

  bool get isMedia => stream == 3;

  double get ratio => max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
}

/// 应用内音量条的数据源：开/关原生监听 + 把事件摊成一个 [ValueNotifier]。
///
/// 广播只在 [setListening] 为 true 时注册，所以「主题音量条」没开、或没启用
/// 主题时，应用完全不接系统回调。
class MintVolumeBar {
  MintVolumeBar._();

  static const MethodChannel _channel = MethodChannel('dev.mint.mint/volume');

  /// 当前该不该显示音量条（原生事件写入，超时自动置 null）。
  static final ValueNotifier<MintVolumeState?> current =
      ValueNotifier<MintVolumeState?>(null);

  static bool _handlerInstalled = false;
  static bool _listening = false;
  static Timer? _hideTimer;

  static Future<void> setListening(bool on) async {
    if (!Platform.isAndroid || on == _listening) return;
    _listening = on;
    if (on && !_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler(_onCall);
    }
    try {
      await _channel.invokeMethod<bool>('enable', {'on': on});
    } catch (_) {
      // 老引擎 / 通道没装好：没有主题音量条而已。
    }
    if (!on) {
      _hideTimer?.cancel();
      current.value = null;
    }
  }

  static Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'onVolumeChanged') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final state = MintVolumeState(
      stream: (args['stream'] as num?)?.toInt() ?? -1,
      value: (args['value'] as num?)?.toInt() ?? 0,
      max: (args['max'] as num?)?.toInt() ?? 0,
      muted: args['muted'] == true,
    );
    current.value = state;
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 1500), () {
      current.value = null;
    });
    return null;
  }
}

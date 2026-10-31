import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 系统 Toast（Android 原生 `Toast.makeText`）。
///
/// 设置里打开「使用系统 Toast」后，`showMintSnack` 的短提示会走这里；
/// 桌面端 / 通道不可用时调用方回退 SnackBar。
class NativeToastService {
  NativeToastService._();

  static const MethodChannel _channel = MethodChannel('dev.mint.mint/toast');

  /// 由设置页 / 启动加载时写入。
  static bool enabled = false;

  static bool get available => Platform.isAndroid;

  static void show(String message, {bool long = false}) {
    if (!available || message.isEmpty) return;
    unawaited(
      _channel
          .invokeMethod<bool>('show', {'text': message, 'long': long})
          .catchError((_) => false),
    );
  }
}

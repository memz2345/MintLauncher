import 'dart:io';

import 'package:flutter/services.dart';

/// Windows 任务栏进度（ITaskbarList3）。
///
/// 平台通道 `mint/taskbar` 在 runner C++ 侧实现；非 Windows 全部 no-op，
/// 通道未注册（老二进制）或调用失败时静默吞掉 —— 进度条坏了不该崩启动器。
enum TaskbarState {
  /// 无进度显示。
  none,

  /// 常规绿色进度（配 [TaskbarProgress.setProgress]）。
  normal,

  /// 跑马灯（不确定时长，如运行 Forge 官方安装器）。
  indeterminate,

  /// 黄色（暂停/等待用户）。
  paused,

  /// 红色（失败）。
  error,
}

abstract class TaskbarProgress {
  static const MethodChannel _channel = MethodChannel('mint/taskbar');

  static bool get _supported => Platform.isWindows;

  /// 设置确定进度 [value]（0..1），任务栏图标叠加绿色进度。
  static Future<void> setProgress(double value) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('setProgress', {
        'value': value.clamp(0.0, 1.0),
      });
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  /// 切换任务栏进度状态（[TaskbarState]）。
  static Future<void> setState(TaskbarState state) async {
    if (!_supported) return;
    final id = switch (state) {
      TaskbarState.none => 'none',
      TaskbarState.normal => 'normal',
      TaskbarState.indeterminate => 'indeterminate',
      TaskbarState.paused => 'paused',
      TaskbarState.error => 'error',
    };
    try {
      await _channel.invokeMethod<void>('setState', {'state': id});
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  /// 清除任务栏进度（图标恢复正常）。
  static Future<void> clear() => setState(TaskbarState.none);
}

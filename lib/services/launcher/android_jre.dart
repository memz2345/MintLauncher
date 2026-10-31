import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 一份 Android JRE 的安装状态（原生 `FclRuntime.status` 的 Dart 侧）。
class AndroidJreStatus {
  const AndroidJreStatus({
    required this.major,
    required this.bundled,
    required this.installed,
    required this.usable,
    required this.home,
  });

  final int major;

  /// APK 里自带（首次用到时解压）。
  final bool bundled;

  /// 已经解压 / 下载到 app_runtime/java/jreN。
  final bool installed;

  /// 这台机器上能不能真的跑（Android 16 arm64 上 JRE8 不可用）。
  final bool usable;

  final String home;

  bool get ready => bundled || installed;

  factory AndroidJreStatus.fromMap(Map<Object?, Object?> map) =>
      AndroidJreStatus(
        major: (map['major'] as num?)?.toInt() ?? 0,
        bundled: map['bundled'] == true,
        installed: map['installed'] == true,
        usable: map['usable'] != false,
        home: '${map['home'] ?? ''}',
      );
}

/// 下载 / 解压进度（原生后台线程 → `mint/jre` 的 progress 回调）。
class AndroidJreProgress {
  const AndroidJreProgress({
    required this.major,
    required this.phase,
    required this.fraction,
    required this.detail,
  });

  final int major;
  final String phase;
  final double fraction;
  final String detail;

  factory AndroidJreProgress.fromMap(Map<Object?, Object?> map) =>
      AndroidJreProgress(
        major: (map['major'] as num?)?.toInt() ?? 0,
        phase: '${map['phase'] ?? ''}',
        fraction: (map['fraction'] as num?)?.toDouble() ?? 0,
        detail: '${map['detail'] ?? ''}',
      );
}

/// Java 运行时管理：状态查询 + 按需下载（从 FCL 发布 APK 里只取需要的
/// JRE，不整包下载）。仅 Android 有实现，其它平台返回空状态。
class AndroidJre {
  AndroidJre._();

  static const MethodChannel _channel = MethodChannel('mint/jre');

  /// 当前下载任务的进度回调（同一时间只允许一个下载）。
  static void Function(AndroidJreProgress progress)? onProgress;

  static bool _handlerInstalled = false;

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        final args = call.arguments;
        if (args is Map) {
          onProgress?.call(AndroidJreProgress.fromMap(args));
        }
      }
      return null;
    });
  }

  /// 随包 + 已下载的 JRE 状态；列表固定为 8/17/21/25。
  static Future<List<AndroidJreStatus>> status() async {
    if (!Platform.isAndroid) return const [];
    _ensureHandler();
    try {
      final list = await _channel.invokeMethod<List<Object?>>('status');
      if (list == null) return const [];
      return [
        for (final item in list)
          if (item is Map) AndroidJreStatus.fromMap(item),
      ];
    } on PlatformException {
      return const [];
    }
  }

  /// 下载并安装 [major]。进度走 [onProgress]，完成后返回 javaHome。
  static Future<String> download(int major) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('只有 Android 需要下载 Java 运行时');
    }
    _ensureHandler();
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'download',
        {'major': major},
      );
      return '${map?['home'] ?? ''}';
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') throw const AndroidJreCancelled();
      throw Exception(e.message ?? '下载 Java $major 失败');
    }
  }

  static Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // 没有任务在跑时原生也会返回成功；忽略即可。
    }
  }

  /// 这个版本要求的 Java（高版本向上取整到下一个支持的档位）。
  static int? targetFor(int requiredMajor) {
    for (final major in supportedMajors) {
      if (major >= requiredMajor) return major;
    }
    return null;
  }

  /// 游戏版本 → Java 要求的展示文案（设置页 / 运行环境页共用）。
  static String gameRangeLabel(int major) => switch (major) {
    8 => '1.16.5 及更早（远古版 AWT 也走它）',
    17 => '1.17 – 1.20.4',
    21 => '1.20.5 – 1.21.x',
    25 => '26.x 及以后',
    _ => '',
  };

  static const supportedMajors = [8, 17, 21, 25];
}

class AndroidJreCancelled implements Exception {
  const AndroidJreCancelled();

  @override
  String toString() => '已取消';
}

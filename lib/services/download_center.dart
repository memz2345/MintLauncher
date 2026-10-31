import 'dart:async';

import 'package:flutter/foundation.dart';

import 'download_task.dart';

export 'download_task.dart';

/// 全局下载中心：任务队列 + 汇总进度 + 节流通知。
///
/// 单例：标题栏的下载按钮、下载管理页、控制器三处共享同一份状态。
/// 任务本身（[DownloadTask]）在 `download_task.dart`，是**纯 Dart** 的 ——
/// downloader.dart 因此能被 `dart run` 的无头工具直接编译。
class DownloadCenter extends ChangeNotifier {
  DownloadCenter._();

  static final DownloadCenter instance = DownloadCenter._();

  final List<DownloadTask> _tasks = [];
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  Timer? _throttle;
  bool _dirty = false;
  int _seq = 0;

  /// 只留最近 [maxHistory] 条已结束任务，避免长跑之后列表无限长。
  static const int maxHistory = 30;

  List<DownloadTask> get activeTasks => [
    for (final t in _tasks)
      if (t.isActive) t,
  ];

  List<DownloadTask> get finishedTasks => [
    for (final t in _tasks)
      if (!t.isActive) t,
  ];

  bool get hasActive => _tasks.any((t) => t.isActive);

  int get activeCount => activeTasks.length;

  /// 汇总进度（0..1）：**按文件数算**（PCL2 同款）——版本安装动辄几千个
  /// 小资源文件，字节数会被单个大文件（客户端 jar / OF）主导，看着卡在
  /// 99%；文件计数对用户更接近「还剩多少东西」。文件数未知时才退回
  /// 字节 / 阶段加权的平均。
  double? get overallProgress {
    final actives = activeTasks;
    if (actives.isEmpty) return null;
    var doneFiles = 0;
    var totalFiles = 0;
    var fallbackSum = 0.0;
    var fallbackKnown = 0;
    for (final t in actives) {
      if (t.totalFiles > 0) {
        doneFiles += t.doneFiles;
        totalFiles += t.totalFiles;
      }
      final p = t.progress;
      if (p != null) {
        fallbackSum += p;
        fallbackKnown++;
      }
    }
    if (totalFiles > 0) return (doneFiles / totalFiles).clamp(0.0, 1.0);
    if (fallbackKnown == 0) return null;
    return (fallbackSum / actives.length).clamp(0.0, 1.0);
  }

  /// 汇总的文件计数（PCL2 任务页「x/y 个文件」）。
  (int done, int total) get overallFiles {
    var done = 0;
    var total = 0;
    for (final t in activeTasks) {
      done += t.doneFiles;
      total += t.totalFiles;
    }
    return (done, total);
  }

  /// 汇总进度（overallProgress 的别名，controller 侧旧名）。
  double? get totalProgress => overallProgress;

  /// 汇总速度（字节/秒）。
  double get totalSpeed {
    var sum = 0.0;
    for (final t in activeTasks) {
      sum += t.bytesPerSecond;
    }
    return sum;
  }

  /// 汇总速度的旧名（controller / 旧代码）。
  double get totalBytesPerSecond => totalSpeed;

  /// 全部取消（正在跑的任务逐个 cancel）。
  void cancelAll() {
    for (final t in activeTasks) {
      t.cancel();
    }
  }

  /// 清掉全部已结束任务（清空历史）。
  void clearFinished() {
    _tasks.removeWhere((t) => !t.isActive);
    notifyListeners();
  }

  /// 从列表里移除（UI 的「删除记录」）。
  void remove(DownloadTask task) {
    if (_tasks.remove(task)) notifyListeners();
  }

  DownloadTask begin({
    required String title,
    String detail = '',
    VoidCallback? onCancel,
  }) {
    final task = DownloadTask(
      id: 'dl-${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
      title: title,
      detail: detail,
      onCancel: onCancel,
    )..onNotify = notifyTask;
    _tasks.insert(0, task);
    _trimHistory();
    notifyListeners();
    return task;
  }

  /// 任务数据变更 → 标脏 + 100ms 节流（字节进度高频，不能逐次通知）。
  void notifyTask(DownloadTask task) {
    _dirty = true;
    _throttle ??= Timer(const Duration(milliseconds: 100), () {
      _throttle = null;
      if (_dirty) {
        _dirty = false;
        notifyListeners();
      }
    });
  }

  void _trimHistory() {
    final finished = finishedTasks;
    if (finished.length <= maxHistory) return;
    final remove = finished.length - maxHistory;
    var removed = 0;
    for (final t in finished.reversed) {
      if (removed >= remove) break;
      if (_tasks.remove(t)) removed++;
    }
  }
}

/// 字节数的紧凑展示（1.2 MB / 890 KB）。
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// 速度展示（1.2 MB/s）。
String formatSpeed(double bytesPerSecond) =>
    bytesPerSecond <= 0 ? '—' : '${formatBytes(bytesPerSecond.round())}/s';

/// 剩余时间展示（1 分 20 秒）。
String formatEta(Duration d) {
  if (d.inHours > 0) return '${d.inHours} 时 ${d.inMinutes % 60} 分';
  if (d.inMinutes > 0) return '${d.inMinutes} 分 ${d.inSeconds % 60} 秒';
  return '${d.inSeconds} 秒';
}

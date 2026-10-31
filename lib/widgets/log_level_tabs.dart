import 'package:flutter/material.dart';

/// 日志级别。
enum LogLevel { all, info, warning, error }

/// 日志级别 Tab 行（带实时计数）—— local2api 最近请求页同款观感，
/// 独立日志窗口与应用内日志页共用。
class LogLevelTabs extends StatelessWidget {
  const LogLevelTabs({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.total,
    required this.info,
    required this.warning,
    required this.error,
  });

  final LogLevel selected;
  final ValueChanged<LogLevel> onSelected;

  final int total;
  final int info;
  final int warning;
  final int error;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<LogLevel>(
        segments: [
          ButtonSegment(value: LogLevel.all, label: Text('全部 ($total)')),
          ButtonSegment(value: LogLevel.info, label: Text('Info ($info)')),
          ButtonSegment(value: LogLevel.warning, label: Text('警告 ($warning)')),
          ButtonSegment(value: LogLevel.error, label: Text('错误 ($error)')),
        ],
        selected: {selected},
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
        ),
        onSelectionChanged: (s) => onSelected(s.first),
      ),
    );
  }
}

/// 行级别判定（HMCL 同思路的启发式：ERROR/FATAL/异常 → 错误，
/// WARN → 警告，其余 info）。
int logLevelOf(String line) {
  if (line.contains('ERROR') ||
      line.contains('FATAL') ||
      line.contains('❌') ||
      line.contains('Exception') ||
      line.contains(' STDERR')) {
    return 2;
  }
  if (line.contains('WARN') || line.contains('⚠') || line.contains('警告')) {
    return 1;
  }
  return 0;
}

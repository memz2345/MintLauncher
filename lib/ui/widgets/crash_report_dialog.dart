import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/services/crash_analyzer.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

/// FCL `JVMCrashActivity` 的启动器版：标题 + 人话原因 + 可复制的完整日志。
///
/// 崩溃页不自动关闭，玩家可以选择复制日志发给别人；日志框用等宽字体、
/// 只读可选中，长日志在框内滚动，不会把弹窗撑爆。
Future<void> showCrashReportDialog(
  BuildContext context, {
  required CrashReportData report,
  required bool miuix,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) =>
        _CrashReportDialog(report: report, miuix: miuix),
  );
}

class _CrashReportDialog extends StatefulWidget {
  const _CrashReportDialog({required this.report, required this.miuix});

  final CrashReportData report;
  final bool miuix;

  @override
  State<_CrashReportDialog> createState() => _CrashReportDialogState();
}

class _CrashReportDialogState extends State<_CrashReportDialog> {
  bool _copied = false;
  final ScrollController _logScroll = ScrollController();
  bool _scrolledToBottom = false;

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _scrollLogToBottomSoon() {
    if (_scrolledToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_logScroll.hasClients) return;
      _scrolledToBottom = true;
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _plainText(widget.report)));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted) setState(() => _copied = false);
  }

  String _plainText(CrashReportData r) {
    final b = StringBuffer()
      ..writeln('Mint Launcher 崩溃报告')
      ..writeln('版本：${r.version}')
      ..writeln('类型：${r.title}')
      ..writeln('exitCode：${r.exitCode}');
    if (r.cause != null) b.writeln('原因：${r.cause}');
    if (r.suggestion != null) b.writeln('建议：${r.suggestion}');
    if (r.detail != null) b.writeln(r.detail);
    if (r.logPath.isNotEmpty) b.writeln('日志文件：${r.logPath}');
    b
      ..writeln()
      ..writeln(r.log);
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final cs = Theme.of(context).colorScheme;
    final miuixColors = mintMiuixOf(context, widget.miuix)
        ? MiuixTheme.of(context).colors
        : null;
    final bg = miuixColors?.background ?? cs.surface;
    final fg = miuixColors?.onBackground ?? cs.onSurface;
    final variant = miuixColors?.onSurfaceVariantSummary ?? cs.onSurfaceVariant;
    final error = miuixColors?.error ?? cs.error;
    final errorContainer =
        miuixColors?.errorContainer ?? cs.errorContainer.withValues(alpha: 0.5);
    final primary = miuixColors?.primary ?? cs.primary;
    final onPrimary = miuixColors?.onPrimary ?? cs.onPrimary;
    final radius = mintMiuixOf(context, widget.miuix) ? 28.0 : 22.0;
    final logText = report.log.trim();
    _scrollLogToBottomSoon();

    return Dialog(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: errorContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            Icons.bug_report_outlined,
                            color: error,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                report.title,
                                style: TextStyle(
                                  fontSize: 17.5,
                                  height: 1.2,
                                  fontWeight: FontWeight.w600,
                                  color: error,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                [
                                  report.version,
                                  if (report.exitCode != 0)
                                    'exitCode ${report.exitCode}',
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: variant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if ((report.cause ?? '').isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        report.cause!,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                          color: fg,
                        ),
                      ),
                    ],
                    if ((report.suggestion ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        report.suggestion!,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: variant,
                        ),
                      ),
                    ],
                    if ((report.detail ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        report.detail!,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          color: variant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          '日志',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: fg,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${logText.length} 字符',
                          style: TextStyle(fontSize: 10.5, color: variant),
                        ),
                        if (report.logPath.isNotEmpty) ...[
                          const Spacer(),
                          Flexible(
                            child: Text(
                              report.logPath,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: TextStyle(fontSize: 10, color: variant),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 7),
                    Container(
                      height: 300,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: fg.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: fg.withValues(alpha: 0.08)),
                      ),
                      child: SelectionArea(
                        child: SingleChildScrollView(
                          controller: _logScroll,
                          physics: const ClampingScrollPhysics(),
                          child: Text(
                            logText.isEmpty ? '（没有捕获到日志）' : logText,
                            style: TextStyle(
                              fontSize: 9.8,
                              height: 1.35,
                              fontFamily: 'monospace',
                              color: fg.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _copy,
                    icon: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_rounded,
                      size: 16,
                    ),
                    label: Text(_copied ? '已复制' : '复制日志'),
                    style: TextButton.styleFrom(foregroundColor: variant),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: FilledButton.styleFrom(
                      backgroundColor: primary,
                      foregroundColor: onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

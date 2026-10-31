import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/crash_analyzer.dart';
import 'package:mint/src/expressive_loading_indicator.dart';
import 'package:mint/ui/mint_icons.dart' show mintFluentOf, mintMiuixOf;
import 'package:mint/ui/pages/common.dart'
    show loaderIconAsset, loaderIconNameForVersion, loaderLabelForVersion;
import 'package:mint/ui/widgets/crash_report_dialog.dart';

/// FCL / HMCL 风格的启动对话框。
///
/// 顶部一条总进度，下面是一条竖向步进器：每一步有 ✔ / 转圈 / 灰点，
/// 当前步骤下面跟实时细节（下载哪个文件、解压什么）。失败时当前步骤标红，
/// 对话框不自动关，错误直接留在卡里。
class LaunchProgressDialog extends StatefulWidget {
  const LaunchProgressDialog({
    super.key,
    required this.controller,
    required this.version,
    required this.miuix,
  });

  final LauncherController controller;
  final String version;
  final bool miuix;

  @override
  State<LaunchProgressDialog> createState() => _LaunchProgressDialogState();
}

class _LaunchProgressDialogState extends State<LaunchProgressDialog> {
  bool _closed = false;
  bool _sawBusy = false;
  bool _success = false;
  Timer? _closeTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _closeTimer?.cancel();
    super.dispose();
  }

  bool get _failed => widget.controller.launchError != null;

  void _onChanged() {
    if (!mounted) return;
    final controller = widget.controller;
    if (controller.state == LauncherState.running) {
      if (!_success) {
        setState(() => _success = true);
        _closeTimer?.cancel();
        // 留半秒让最后一步的 ✔ 被看见，再让位给游戏窗口。
        _closeTimer = Timer(const Duration(milliseconds: 700), _pop);
      }
      return;
    }
    if (controller.isPreparing || controller.cancelRequested) _sawBusy = true;
    if (controller.state == LauncherState.idle &&
        _sawBusy &&
        controller.cancelRequested &&
        !_closed) {
      _closeTimer?.cancel();
      _closeTimer = Timer(const Duration(milliseconds: 220), _pop);
    }
    if (mounted) setState(() {});
  }

  void _pop() {
    if (!mounted || _closed) return;
    _closed = true;
    Navigator.of(context, rootNavigator: true).pop();
  }

  void _showFailureLog() {
    final controller = widget.controller;
    showCrashReportDialog(
      context,
      report: CrashReportData(
        title: '启动失败',
        version: widget.version,
        cause: controller.launchError ?? controller.stateDetail,
        log: controller.logs.join('\n'),
      ),
      miuix: mintMiuixOf(context),
    );
  }

  void _cancel() {
    final controller = widget.controller;
    if (controller.cancelRequested) return;
    if (controller.isPreparing) {
      controller.cancelLaunch();
    } else {
      _pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cs = Theme.of(context).colorScheme;
    final miuixColors = mintMiuixOf(context, widget.miuix)
        ? MiuixTheme.of(context).colors
        : null;
    final bg = miuixColors?.background ?? cs.surface;
    final fg = miuixColors?.onBackground ?? cs.onSurface;
    final variant = miuixColors?.onSurfaceVariantSummary ?? cs.onSurfaceVariant;
    final primary = miuixColors?.primary ?? cs.primary;
    final onPrimary = miuixColors?.onPrimary ?? cs.onPrimary;
    final error = miuixColors?.error ?? cs.error;
    final onError = miuixColors?.onError ?? cs.onError;
    final line =
        miuixColors?.dividerLine ?? cs.outlineVariant.withValues(alpha: 0.35);
    final raised =
        miuixColors?.surfaceContainerHigh ?? cs.surfaceContainerHighest;
    final errorContainer =
        miuixColors?.errorContainer ??
        cs.errorContainer.withValues(alpha: 0.55);
    final onErrorContainer =
        miuixColors?.onErrorContainer ?? cs.onErrorContainer;

    final busy = controller.isPreparing;
    final failed = _failed;
    final cancelling = controller.cancelRequested;
    final stages = controller.launchStages;

    // 总进度按「步骤数」算，而不是安装任务的字节进度：安装结束那一刻
    // taskProgress 会停在 100%，但启动参数 / 启动窗口还没跑。
    var doneCount = 0;
    var runningIndex = -1;
    for (var i = 0; i < stages.length; i++) {
      if (stages[i].status == LaunchStageStatus.done) doneCount++;
      if (stages[i].status == LaunchStageStatus.running) runningIndex = i;
    }
    var runningFraction = 0.0;
    if (runningIndex >= 0) {
      final id = stages[runningIndex].id;
      final task = controller.taskProgress;
      runningFraction =
          (id == LauncherController.stageFiles ||
                  id == LauncherController.stageRuntime) &&
              task != null
          ? task.clamp(0.0, 1.0)
          : 0.35;
    }
    final overall = _success
        ? 1.0
        : stages.isEmpty
        ? (controller.taskProgress?.clamp(0.0, 1.0) ?? 0.0)
        : ((doneCount + runningFraction) / stages.length).clamp(0.0, 1.0);
    final progress = overall;
    final percent = (overall * 100).round();

    final radius = mintMiuixOf(context, widget.miuix)
        ? 28.0
        : mintFluentOf(context)
        ? 12.0
        : 24.0;

    final title = _success
        ? 'Minecraft 已启动'
        : failed
        ? '启动失败'
        : '正在启动 Minecraft';
    final subtitle =
        '${widget.version} · ${loaderLabelForVersion(widget.version)}';

    return PopScope(
      canPop: false,
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent ||
              event.logicalKey != LogicalKeyboardKey.escape) {
            return KeyEventResult.ignored;
          }
          if (failed || _success) {
            _pop();
          } else if (busy) {
            _cancel();
          }
          return KeyEventResult.handled;
        },
        child: Dialog(
          backgroundColor: bg,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 22,
            vertical: 20,
          ),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 480,
              maxHeight: MediaQuery.sizeOf(context).height * 0.9,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: failed || _success ? 1 : progress,
                  minHeight: 5,
                  color: failed ? error : primary,
                  backgroundColor: line.withValues(alpha: 0.45),
                ),
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
                              width: 46,
                              height: 46,
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                color: raised,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: loaderIconAsset(
                                loaderIconNameForVersion(widget.version),
                                size: 32,
                              ),
                            ),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: TextStyle(
                                      fontSize: 17.5,
                                      height: 1.2,
                                      fontWeight: FontWeight.w600,
                                      color: failed ? error : fg,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    subtitle,
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
                            Text(
                              failed ? '失败' : '$percent%',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: failed ? error : primary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        if (stages.isEmpty)
                          _StepTile(
                            label: '准备启动',
                            detail: controller.taskLabel.isEmpty
                                ? (controller.stateDetail.isEmpty
                                      ? '正在准备启动…'
                                      : controller.stateDetail)
                                : controller.taskLabel,
                            status: LaunchStageStatus.running,
                            primary: primary,
                            onPrimary: onPrimary,
                            error: error,
                            onError: onError,
                            text: fg,
                            variant: variant,
                            line: line,
                            last: true,
                          )
                        else
                          for (var i = 0; i < stages.length; i++)
                            _StepTile(
                              label: stages[i].label,
                              detail: stages[i].detail,
                              status: _success
                                  ? LaunchStageStatus.done
                                  : stages[i].status,
                              primary: primary,
                              onPrimary: onPrimary,
                              error: error,
                              onError: onError,
                              text: fg,
                              variant: variant,
                              line: line,
                              last: i == stages.length - 1,
                            ),
                        if (failed) ...[
                          const SizedBox(height: 2),
                          Container(
                            padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
                            decoration: BoxDecoration(
                              color: errorContainer,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.error_outline_rounded,
                                  size: 17,
                                  color: onErrorContainer,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    controller.launchError ??
                                        controller.stateDetail,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      height: 1.45,
                                      color: onErrorContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (_success)
                        _PrimaryPill(
                          miuix: mintMiuixOf(context),
                          label: '完成',
                          onPressed: _pop,
                        )
                      else if (failed) ...[
                        TextButton.icon(
                          onPressed: _showFailureLog,
                          icon: const Icon(Icons.article_outlined, size: 16),
                          label: const Text('查看日志'),
                          style: TextButton.styleFrom(foregroundColor: variant),
                        ),
                        const SizedBox(width: 6),
                        _PrimaryPill(
                          miuix: mintMiuixOf(context),
                          label: '关闭',
                          onPressed: _pop,
                        ),
                      ] else ...[
                        if (busy)
                          _SecondaryPill(
                            miuix: mintMiuixOf(context),
                            label: '后台运行',
                            onPressed: _pop,
                          ),
                        const SizedBox(width: 8),
                        _PrimaryPill(
                          miuix: mintMiuixOf(context),
                          label: cancelling ? '正在取消…' : '取消启动',
                          destructive: !cancelling,
                          onPressed: cancelling ? null : _cancel,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.label,
    required this.detail,
    required this.status,
    required this.primary,
    required this.onPrimary,
    required this.error,
    required this.onError,
    required this.text,
    required this.variant,
    required this.line,
    required this.last,
  });

  final String label;
  final String detail;
  final LaunchStageStatus status;
  final Color primary;
  final Color onPrimary;
  final Color error;
  final Color onError;
  final Color text;
  final Color variant;
  final Color line;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final running = status == LaunchStageStatus.running;
    final done = status == LaunchStageStatus.done;
    final failed = status == LaunchStageStatus.failed;
    final labelColor = failed
        ? error
        : running
        ? primary
        : done
        ? text
        : variant;
    final connector = done || running
        ? primary.withValues(alpha: running ? 0.35 : 0.55)
        : line.withValues(alpha: 0.55);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 24,
            child: Column(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    child: _mark(running, done, failed),
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Center(
                      child: Container(
                        width: 2,
                        margin: const EdgeInsets.symmetric(vertical: 2),
                        decoration: BoxDecoration(
                          color: connector,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 6 : 16, top: 1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.3,
                      fontWeight: running ? FontWeight.w600 : FontWeight.w500,
                      color: labelColor,
                    ),
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: failed ? error : variant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mark(bool running, bool done, bool failed) {
    if (done) {
      return Container(
        key: const ValueKey('done'),
        decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
        child: Icon(Icons.check_rounded, size: 15, color: onPrimary),
      );
    }
    if (failed) {
      return Container(
        key: const ValueKey('failed'),
        decoration: BoxDecoration(color: error, shape: BoxShape.circle),
        child: Icon(Icons.close_rounded, size: 15, color: onError),
      );
    }
    if (running) {
      return Container(
        key: const ValueKey('running'),
        width: 24,
        height: 24,
        alignment: Alignment.center,
        child: ExpressiveLoadingIndicator(
          color: primary,
          constraints: const BoxConstraints.tightFor(width: 18, height: 18),
        ),
      );
    }
    return Container(
      key: const ValueKey('pending'),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: line, width: 1.8),
      ),
    );
  }
}

class _PrimaryPill extends StatelessWidget {
  const _PrimaryPill({
    required this.miuix,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final bool miuix;
  final String label;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      final c = MiuixTheme.of(context).colors;
      return MiuixButton(
        onPressed: onPressed,
        minWidth: 92,
        colors: destructive
            ? MiuixButtonColors(
                color: c.error,
                disabledColor: c.disabledPrimaryButton,
                contentColor: c.onError,
                disabledContentColor: c.disabledOnPrimaryButton,
              )
            : MiuixButtonDefaults.buttonColorsPrimary(context),
        child: Text(label),
      );
    }
    final style = FilledButton.styleFrom(
      minimumSize: const Size(92, 40),
      shape: const StadiumBorder(),
    );
    if (destructive) {
      return FilledButton(
        onPressed: onPressed,
        style: style.merge(
          FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
        ),
        child: Text(label),
      );
    }
    return FilledButton(onPressed: onPressed, style: style, child: Text(label));
  }
}

class _SecondaryPill extends StatelessWidget {
  const _SecondaryPill({
    required this.miuix,
    required this.label,
    required this.onPressed,
  });

  final bool miuix;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      return MiuixButton(
        onPressed: onPressed,
        minWidth: 92,
        child: Text(label),
      );
    }
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(88, 40),
        shape: const StadiumBorder(),
      ),
      child: Text(label),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/services/download_center.dart';
import 'package:mint/ui/mint_icons.dart';
import 'package:mint/ui/widgets/mint_refresh.dart';

import 'common.dart';
import 'download_other_flow.dart';
import '../widgets/mint_page.dart';
import '../widgets/page_background.dart' show MintPageBackgroundKey;

/// 下载管理页（PCL2「下载」页的任务队列思路）：
/// 上半是正在跑的任务（总进度 + 速度 + 单任务进度条 + 取消），
/// 下半是已完成 / 失败 / 已取消的记录（可单条删除、可一键清空）。
///
/// 入口有两处：标题栏最小化左侧的下载按钮（有任务时才出现）、下载中心里
/// 的「下载管理」行。
class DownloadManagerPage extends StatefulWidget {
  const DownloadManagerPage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<DownloadManagerPage> createState() => _DownloadManagerPageState();
}

class _DownloadManagerPageState extends State<DownloadManagerPage> {
  int _lastActiveCount = -1;

  @override
  void initState() {
    super.initState();
    DownloadCenter.instance.addListener(_onCenterChanged);
    _lastActiveCount = DownloadCenter.instance.activeCount;
  }

  @override
  void dispose() {
    DownloadCenter.instance.removeListener(_onCenterChanged);
    super.dispose();
  }

  /// 最后一个任务完成时自动返回上一级（PCL2 任务页同款：队列清空即回退）。
  void _onCenterChanged() {
    final count = DownloadCenter.instance.activeCount;
    final hadActive = _lastActiveCount > 0;
    _lastActiveCount = count;
    if (hadActive && count == 0 && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).maybePop();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final miuix = mintMiuixOf(context, widget.miuix);
    return ListenableBuilder(
      listenable: DownloadCenter.instance,
      builder: (context, _) {
        final center = DownloadCenter.instance;
        final active = center.activeTasks;
        final finished = center.finishedTasks;
        return MintPageScaffold(
          miuix: miuix,
          title: '下载管理',
          showBack: true,
          pageBackgroundKey: MintPageBackgroundKey.downloads.id,
          actions: [
            if (finished.isNotEmpty)
              MintTopBarAction(
                miuix: miuix,
                icon: Icons.delete_sweep_outlined,
                tooltip: '清除已完成',
                onPressed: center.clearFinished,
              ),
          ],
          body: (padding) => Stack(
            children: [
              Positioned.fill(
                child: ListView(
                  physics: kMintPageScrollPhysics,
                  padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 110),
                  children: [
                    if (active.isEmpty && finished.isEmpty)
                      MintEmptyState(
                        miuix: miuix,
                        icon: Icons.download_done_outlined,
                        title: '没有下载任务',
                      )
                    else ...[
                      if (active.isNotEmpty) ...[
                        _SummaryCard(miuix: miuix),
                        MintSectionHeader(
                          miuix: miuix,
                          title: '正在下载',
                          trailing: Text(
                            '${active.length} 个任务',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        for (final task in active) ...[
                          _TaskCard(miuix: miuix, task: task),
                          const SizedBox(height: 8),
                        ],
                      ],
                      if (finished.isNotEmpty) ...[
                        MintSectionHeader(
                          miuix: miuix,
                          title: '已完成',
                          trailing: finished.length > 1
                              ? MintTextAction(
                                  miuix: miuix,
                                  label: '清空',
                                  onPressed: center.clearFinished,
                                )
                              : null,
                        ),
                        for (final task in finished) ...[
                          _TaskCard(miuix: miuix, task: task),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '下载是后台任务：可以离开这一页继续装游戏、切版本，'
                      '任务列表和标题栏按钮会一直跟着进度走。'
                      '点右下角 ＋ 可以直接贴链接下载文件。',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 20,
                bottom: padding.bottom + 36,
                child: miuix
                    ? MiuixFloatingActionButton(
                        onPressed: () => startOtherFileDownloadFlow(context),
                        child: Icon(
                          Icons.add,
                          size: 26,
                          color: MiuixTheme.of(context).colors.onPrimary,
                        ),
                      )
                    : FloatingActionButton(
                        heroTag: 'download-file-fab',
                        tooltip: '下载文件',
                        onPressed: () => startOtherFileDownloadFlow(context),
                        child: const Icon(Icons.add, size: 26),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 顶部汇总卡：总进度 + 总速度 + 全部取消。
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.miuix});

  final bool miuix;

  @override
  Widget build(BuildContext context) {
    final center = DownloadCenter.instance;
    final cs = Theme.of(context).colorScheme;
    final progress = center.overallProgress;
    final speed = center.totalSpeed;
    return MintCard(
      miuix: miuix,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.cloud_download_outlined,
                    size: 20,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      progress == null
                          ? '正在准备…'
                          : '总进度 ${(progress * 100).toStringAsFixed(0)}%'
                                '${() {
                                  final (done, total) = center.overallFiles;
                                  return total > 0 ? '（$done/$total 个文件）' : '';
                                }()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (speed > 1)
                    Text(
                      formatSpeed(speed),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: center.cancelAll,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: cs.error,
                    ),
                    child: const Text('全部取消'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 7,
                  backgroundColor: cs.onSurface.withValues(alpha: 0.08),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单条任务卡。
class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.miuix, required this.task});

  final bool miuix;
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = task.isActive;
    final progress = task.progress;
    final statusColor = switch (task.status) {
      DownloadStatus.running => cs.primary,
      DownloadStatus.completed => const Color(0xFF2E9E5B),
      DownloadStatus.failed => cs.error,
      DownloadStatus.cancelled => cs.onSurfaceVariant,
    };

    final subtitle = _subtitle();

    return MintCard(
      miuix: miuix,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TaskGauge(
                progress: progress,
                active: active,
                color: statusColor,
                status: task.status,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (active && task.bytesPerSecond > 1)
                          Text(
                            formatSpeed(task.bytesPerSecond),
                            style: TextStyle(
                              fontSize: 11.5,
                              color: cs.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          )
                        else
                          Text(
                            task.status.label,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: statusColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        const SizedBox(width: 8),
                      ],
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.35,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (active) ...[
                      const SizedBox(height: 9),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 5,
                                backgroundColor: cs.onSurface.withValues(
                                  alpha: 0.08,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 38,
                            child: Text(
                              progress == null
                                  ? '—'
                                  : '${(progress * 100).toStringAsFixed(0)}%',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else if (task.status == DownloadStatus.failed) ...[
                      const SizedBox(height: 4),
                      Text(
                        task.error ?? '未知错误',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: cs.error),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: active ? '取消' : '删除记录',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  active ? Icons.close : Icons.delete_outline,
                  size: 18,
                ),
                onPressed: () {
                  if (active) {
                    task.cancel();
                  } else {
                    DownloadCenter.instance.remove(task);
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _subtitle() {
    final parts = <String>[];
    if (task.detail.isNotEmpty) parts.add(task.detail);
    if (task.totalBytes > 0) {
      parts.add(
        '${formatBytes(task.doneBytes)} / ${formatBytes(task.totalBytes)}',
      );
    }
    if (task.isActive) {
      if (task.totalFiles > 0) {
        parts.add('${task.doneFiles}/${task.totalFiles} 个文件');
      }
      final eta = task.remaining;
      if (eta != null) parts.add('剩余 ${formatEta(eta)}');
    }
    return parts.join(' · ');
  }
}

/// 任务左侧的进度环 / 状态标记。
class _TaskGauge extends StatelessWidget {
  const _TaskGauge({
    required this.progress,
    required this.active,
    required this.color,
    required this.status,
  });

  final double? progress;
  final bool active;
  final Color color;
  final DownloadStatus status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!active) {
      final icon = switch (status) {
        DownloadStatus.completed => Icons.check_rounded,
        DownloadStatus.failed => Icons.error_outline_rounded,
        _ => Icons.remove_circle_outline,
      };
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 19, color: color),
      );
    }
    return SizedBox(
      width: 38,
      height: 38,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 3,
              backgroundColor: cs.onSurface.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const MintDownloadIcon(size: 16),
        ],
      ),
    );
  }
}

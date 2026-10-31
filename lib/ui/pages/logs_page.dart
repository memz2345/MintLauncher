import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/crash_analyzer.dart';
import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/log_window_service.dart';
import 'package:mint/src/system_font.dart';
import 'package:mint/widgets/log_level_tabs.dart';

import 'common.dart';
import '../widgets/mint_page.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

/// 日志页（HMCL 风格）：游戏日志（上，可按级别过滤）+ 分隔线 + 启动器日志（下），
/// 支持选中文本复制；Windows 下可投到独立窗口。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final ScrollController _gameScroll = ScrollController();
  final ScrollController _launcherScroll = ScrollController();
  LogLevel _filter = LogLevel.all;
  double _splitRatio = 0.68;
  int _lastCount = 0;

  @override
  void dispose() {
    _gameScroll.dispose();
    _launcherScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final lines = controller.logLines;
    final logWindowVisible =
        Platform.isWindows && LogWindowService.instance.isVisible;

    // 有新日志时滚到底（用户没主动滚走的话）
    if (lines.length != _lastCount) {
      _lastCount = lines.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_gameScroll.hasClients) return;
        if (_gameScroll.position.maxScrollExtent - _gameScroll.offset < 400) {
          _gameScroll.jumpTo(_gameScroll.position.maxScrollExtent);
        }
        if (_launcherScroll.hasClients) {
          _launcherScroll.jumpTo(_launcherScroll.position.maxScrollExtent);
        }
      });
    }

    final gameEntries = <(String, int)>[
      for (final e in lines)
        if (e.fromGame) (e.text, logLevelOf(e.text)),
    ];
    final launcherLines = [
      for (final e in lines)
        if (!e.fromGame) e.text,
    ];
    int countLevel(int level) =>
        gameEntries.where(((e) => e.$2 == level)).length;

    final filteredGame = [
      for (final e in gameEntries)
        if (_filter == LogLevel.all || e.$2 == _filter.index - 1) e,
    ];

    if (mintMiuixOf(context, widget.miuix)) {
      return MintPageScaffold(
        miuix: true,
        title: '运行日志',
        actions: _actions(context, controller, lines, logWindowVisible),
        body: (padding) => Padding(
          padding: padding,
          child: _body(
            context,
            gameEntries,
            filteredGame,
            launcherLines,
            countLevel,
          ),
        ),
      );
    }
    return MintPageScaffold(
      miuix: false,
      title: '运行日志',
      actions: _actions(context, controller, lines, logWindowVisible),
      body: (_) =>
          _body(context, gameEntries, filteredGame, launcherLines, countLevel),
    );
  }

  List<Widget> _actions(
    BuildContext context,
    LauncherController controller,
    List<dynamic> lines,
    bool logWindowVisible,
  ) {
    Future<void> copyAll() async {
      final text = [for (final e in controller.logLines) e.text].join('\n');
      if (text.isEmpty) return;
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('已复制全部日志')));
      }
    }

    return [
      MintTopBarAction(
        miuix: mintMiuixOf(context),
        icon: Icons.bug_report_outlined,
        tooltip: '导入日志 / 崩溃报告分析',
        onPressed: () => _importAndAnalyze(context),
      ),
      MintTopBarAction(
        miuix: mintMiuixOf(context),
        icon: Icons.copy_all_outlined,
        tooltip: '复制全部',
        onPressed: lines.isEmpty ? null : copyAll,
      ),
      if (Platform.isWindows)
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: logWindowVisible ? Icons.dock : Icons.open_in_new,
          tooltip: logWindowVisible ? '日志窗口已打开（点击隐藏）' : '在独立窗口打开',
          onPressed: logWindowVisible
              ? () => LogWindowService.instance.close()
              : () => LogWindowService.instance.open(),
        ),
      MintTopBarAction(
        miuix: mintMiuixOf(context),
        icon: Icons.delete_sweep_outlined,
        tooltip: '清空日志',
        onPressed: controller.clearLogs,
      ),
    ];
  }

  /// 选一个日志 / 崩溃报告文件跑分析器（PCL2「日志分析」同思路）。
  Future<void> _importAndAnalyze(BuildContext context) async {
    const group = XTypeGroup(
      label: '日志与崩溃报告',
      extensions: ['log', 'txt', 'json', 'hs_err'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return;
    String text;
    try {
      text = await file.readAsString();
    } catch (e) {
      if (context.mounted) {
        showMintSnack(context, '读文件失败：$e');
      }
      return;
    }
    final analysis = analyzeCrashText(text);
    if (!context.mounted) return;
    await showCrashAnalysisDialog(
      context,
      miuix: mintMiuixOf(context),
      analysis: analysis,
      fileName: file.name,
    );
  }

  Widget _body(
    BuildContext context,
    List<(String, int)> gameEntries,
    List<(String, int)> filteredGame,
    List<String> launcherLines,
    int Function(int) countLevel,
  ) {
    final cs = Theme.of(context).colorScheme;
    final controller = context.read<LauncherController>();
    if (gameEntries.isEmpty && launcherLines.isEmpty) {
      return Center(
        child: Text(
          '还没有日志。\n装个版本、点启动，这里就会有东西看了。',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
      );
    }

    return Column(
      children: [
        // 崩溃分析横幅：游戏退出后自动分析的结果，一目了然。
        if (controller.lastCrash != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: _CrashBanner(
              miuix: mintMiuixOf(context),
              crash: controller.lastCrash!,
              onDismiss: controller.dismissCrash,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: LogLevelTabs(
            selected: _filter,
            onSelected: (f) => setState(() => _filter = f),
            total: gameEntries.length,
            info: countLevel(0),
            warning: countLevel(1),
            error: countLevel(2),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final totalHeight = constraints.maxHeight;
              return Column(
                children: [
                  _paneHeader(context, '游戏日志', '${filteredGame.length} 行'),
                  Expanded(
                    flex: (_splitRatio * 100).round(),
                    child: filteredGame.isEmpty
                        ? Center(
                            child: Text(
                              '等待游戏输出…',
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          )
                        : SelectionArea(
                            child: _LogList(
                              scrollController: _gameScroll,
                              entries: filteredGame,
                              levelColor: (l) => _levelColor(cs, l),
                            ),
                          ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: (d) {
                      setState(() {
                        _splitRatio =
                            (_splitRatio + d.primaryDelta! / totalHeight).clamp(
                              0.15,
                              0.85,
                            );
                      });
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeRow,
                      child: Container(
                        height: 8,
                        color: cs.surfaceContainerHighest.withValues(
                          alpha: 0.5,
                        ),
                        child: Center(
                          child: Container(
                            width: 48,
                            height: 3,
                            decoration: BoxDecoration(
                              color: cs.outlineVariant,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _paneHeader(context, '启动器日志', '${launcherLines.length} 行'),
                  Expanded(
                    flex: ((1 - _splitRatio) * 100).round(),
                    child: launcherLines.isEmpty
                        ? Center(
                            child: Text(
                              '启动器动作会显示在这里',
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          )
                        : SelectionArea(
                            child: _LogList(
                              scrollController: _launcherScroll,
                              entries: [for (final l in launcherLines) (l, 0)],
                              levelColor: (l) => _levelColor(cs, l),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _paneHeader(BuildContext context, String title, String count) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
        child: Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              count,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );

  Color _levelColor(ColorScheme cs, int level) => switch (level) {
    2 => const Color(0xFFFF8A80),
    1 => const Color(0xFFFFD54F),
    _ => cs.onSurface.withValues(alpha: 0.92),
  };
}

/// 等宽日志列表（可选中文本）。
class _LogList extends StatelessWidget {
  const _LogList({
    required this.scrollController,
    required this.entries,
    required this.levelColor,
  });

  final ScrollController scrollController;
  final List<(String, int)> entries;
  final Color Function(int level) levelColor;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final (line, level) = entries[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 0.5),
          child: Text(
            line,
            style: TextStyle(
              fontFamily: kMonoFontFallback.first,
              fontFamilyFallback: kMonoFontFallback,
              fontSize: 12,
              height: 1.4,
              color: levelColor(level),
            ),
          ),
        );
      },
    );
  }
}

/// 崩溃分析横幅（与主页崩溃卡同一份数据，这里给日志页一个就地入口）。
class _CrashBanner extends StatelessWidget {
  const _CrashBanner({
    required this.miuix,
    required this.crash,
    required this.onDismiss,
  });

  final bool miuix;
  final CrashAnalysis crash;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.bug_report_outlined, size: 18, color: cs.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  crash.cause,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: cs.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  crash.suggestion,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: cs.onErrorContainer.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              foregroundColor: cs.onErrorContainer,
            ),
            child: const Text('忽略'),
          ),
        ],
      ),
    );
  }
}

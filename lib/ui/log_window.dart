import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:window_manager/window_manager.dart';

import 'package:mint/src/system_font.dart';
import 'package:mint/ui/window_chrome.dart';
import 'package:mint/widgets/edge_scroll_haptic.dart';
import 'package:mint/widgets/log_level_tabs.dart';
import 'package:mint/widgets/page_switcher.dart';

/// 独立日志窗口入口（子窗口引擎）。args 来自 runner 传进来的
/// `['multi_window', windowId, argument]`。
Future<void> runLogWindow(String windowId, String argument) async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    title: 'Mint 启动器 · 运行日志',
    size: Size(960, 720),
    minimumSize: Size(460, 360),
    center: true,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  final argumentMap = argument.isEmpty
      ? const <String, dynamic>{}
      : (jsonDecode(argument) as Map<String, dynamic>).cast<String, dynamic>();

  runApp(LogWindowApp(windowId: windowId, argument: argumentMap));
}

/// HMCL 风格的日志控制台窗口：
///   · 级别 Tab（全部 / Info / 警告 / 错误，实时计数，公用组件）
///   · 上下双栏：游戏日志（可过滤、可选中复制）+ 可拖拽分隔线 + 启动器日志
///   · 14px 等宽字体、自动滚动、复制 / 清空 / 关闭
class LogWindowApp extends StatelessWidget {
  const LogWindowApp({
    super.key,
    required this.windowId,
    required this.argument,
  });

  final String windowId;
  final Map<String, dynamic> argument;

  @override
  Widget build(BuildContext context) {
    return MiuixThemeController(
      isDark: true,
      keyColor: const Color(0xFF4C6FFF),
      child: MaterialApp(
        title: 'Mint 启动器 · 运行日志',
        debugShowCheckedModeBanner: false,
        builder: (context, child) => DefaultTextStyle(
          style: Theme.of(
            context,
          ).textTheme.bodyMedium!.copyWith(decoration: TextDecoration.none),
          // 自绘标题栏 / 缩放热区只在 Windows 生效：Linux 的日志子窗口
          // 保留 GTK 原生装饰（chrome 通道只注册在主窗口引擎上）。
          child: Platform.isWindows
              ? MintWindowResizeFrame(
                  child: MintCaptionMenuHost(
                    child: Column(
                      children: [
                        // 自绘窗口标题栏（系统 caption 已由 runner 去掉）。
                        const MintCaptionBar(title: '运行日志'),
                        Expanded(child: EdgeScrollHaptic(child: child!)),
                      ],
                    ),
                  ),
                )
              : MintCaptionMenuHost(
                  child: EdgeScrollHaptic(child: child!),
                ),
        ),
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          fontFamily: kSystemFontFamily,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4C6FFF),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF14161B),
        ),
        home: LogWindowPage(windowId: windowId),
      ),
    );
  }
}

class LogWindowPage extends StatefulWidget {
  const LogWindowPage({super.key, required this.windowId});

  final String windowId;

  @override
  State<LogWindowPage> createState() => _LogWindowPageState();
}

class _LogWindowPageState extends State<LogWindowPage>
    with WindowListener, PagerJumpGuard<LogWindowPage> {
  static const _kChannelToMain = 'mint/log_main';
  static const _maxLines = 8000;

  /// 每个级别 tab 一页、各自记住滚动位置；launcher 日志固定在下方。
  final List<ScrollController> _gameScrolls = List.generate(
    LogLevel.values.length,
    (_) => ScrollController(),
  );
  final ScrollController _launcherScroll = ScrollController();
  final PageController _pager = PageController();

  /// [line, level] 平行存储；level 0=info 1=warning 2=error。
  final List<String> _gameLines = [];
  final List<int> _gameLevels = [];
  final List<String> _launcherLines = [];

  LogLevel _filter = LogLevel.all;
  bool _autoScroll = true;

  /// 上下分栏比例（游戏日志占比），拖拽分隔线调整。
  double _splitRatio = 0.68;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // 关闭窗口前先把「closed」发给主窗口，再隐藏（引擎常驻，不可销毁！
    // window_manager.destroy 会把退出消息投到共享平台线程，卡死主窗口）。
    windowManager.setPreventClose(true);

    WindowMethodChannel(
      'mint/log_window',
      mode: ChannelMode.unidirectional,
    ).setMethodCallHandler(_onMainCall);

    WindowMethodChannel(
      _kChannelToMain,
      mode: ChannelMode.unidirectional,
    ).invokeMethod('init').catchError((_) => null);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _pager.dispose();
    for (final controller in _gameScrolls) {
      controller.dispose();
    }
    _launcherScroll.dispose();
    super.dispose();
  }

  Future<dynamic> _onMainCall(MethodCall call) async {
    switch (call.method) {
      case 'append':
        final args = call.arguments as Map?;
        final entries = (args?['entries'] as List?) ?? const [];
        if (!mounted) return null;
        setState(() {
          for (final e in entries) {
            if (e is! Map) continue;
            final line = '${e['line']}';
            if (e['game'] == true) {
              _gameLines.add(line);
              _gameLevels.add(logLevelOf(line));
              if (_gameLines.length > _maxLines) {
                _gameLines.removeRange(0, _gameLines.length - _maxLines);
                _gameLevels.removeRange(0, _gameLevels.length - _maxLines);
              }
            } else {
              _launcherLines.add(line);
              if (_launcherLines.length > _maxLines) {
                _launcherLines.removeRange(
                  0,
                  _launcherLines.length - _maxLines,
                );
              }
            }
          }
        });
        _scrollToBottom();
        return null;
      case 'clear':
        // 新一次游戏会话开始：主窗口刷新日志，子窗口只保留本次内容。
        if (!mounted) return null;
        setState(() {
          _gameLines.clear();
          _gameLevels.clear();
          _launcherLines.clear();
        });
        return null;
      case 'exited':
        final args = call.arguments as Map?;
        final pending = (args?['pending'] as List?) ?? const [];
        if (!mounted) return null;
        setState(() {
          for (final e in pending) {
            if (e is! Map) continue;
            final line = '${e['line']}';
            if (e['game'] == true) {
              _gameLines.add(line);
              _gameLevels.add(logLevelOf(line));
            } else {
              _launcherLines.add(line);
            }
          }
        });
        _scrollToBottom();
        return null;
    }
    return null;
  }

  int _countLevel(int level) {
    var n = 0;
    for (final l in _gameLevels) {
      if (l == level) n++;
    }
    return n;
  }

  void _scrollToBottom() {
    if (!_autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in _gameScrolls) {
        if (controller.hasClients) {
          controller.jumpTo(controller.position.maxScrollExtent);
        }
      }
      if (_launcherScroll.hasClients) {
        _launcherScroll.jumpTo(_launcherScroll.position.maxScrollExtent);
      }
    });
  }

  void _selectLevel(LogLevel level) {
    if (level == _filter) return;
    final target = level.index;
    beginPagerJump(target);
    setState(() => _filter = level);
    if (!_pager.hasClients) {
      endPagerJump();
      _scrollToBottom();
      return;
    }
    _pager
        .animateToPage(
          target,
          duration: kPageTransitionDuration,
          curve: kPageTransitionCurve,
        )
        .whenComplete(() {
          endPagerJump();
          _scrollToBottom();
        });
  }

  void _onPageChanged(int index) {
    if (ignorePagerReport(index)) return;
    final level = LogLevel.values[index];
    if (level == _filter) return;
    setState(() => _filter = level);
    _scrollToBottom();
  }

  Future<void> _sendToMain(String method, [Map<String, dynamic>? args]) async {
    try {
      await WindowMethodChannel(
        _kChannelToMain,
        mode: ChannelMode.unidirectional,
      ).invokeMethod(method, args);
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    // ⚠️ 千万不能 destroy()：会把退出消息投到共享平台线程队列并卡死
    // 主窗口。关闭 = 隐藏，引擎常驻。
    await _sendToMain('closed');
    await windowManager.hide();
  }

  Color _levelColor(ColorScheme cs, int level) => switch (level) {
    2 => const Color(0xFFFF8A80),
    1 => const Color(0xFFFFD54F),
    _ => cs.onSurface.withValues(alpha: 0.92),
  };

  List<(String, int)> _gameEntries(LogLevel level) => [
    for (var i = 0; i < _gameLines.length; i++)
      if (level == LogLevel.all || _gameLevels[i] == level.index - 1)
        (_gameLines[i], _gameLevels[i]),
  ];

  String _emptyLabel(LogLevel level) => switch (level) {
    LogLevel.all => '等待游戏输出…',
    LogLevel.info => '没有 Info 日志',
    LogLevel.warning => '没有警告日志',
    LogLevel.error => '没有错误日志',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selectedEntries = _gameEntries(_filter);

    return Scaffold(
      body: Column(
        children: [
          // ── 顶栏：本地图风格的四张级别卡 + 最右侧自动滚动 switch ──
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.24),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _LogLevelTabBar(
                    selected: _filter,
                    onSelected: _selectLevel,
                    counts: [
                      _gameLines.length,
                      _countLevel(0),
                      _countLevel(1),
                      _countLevel(2),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '自动滚动',
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 4),
                MiuixSwitch(
                  value: _autoScroll,
                  onChanged: (value) {
                    setState(() => _autoScroll = value);
                    if (value) _scrollToBottom();
                  },
                ),
              ],
            ),
          ),
          // ── 双栏：游戏日志（PageView 按级别分页） / 分隔线 / 启动器日志 ──
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final totalHeight = constraints.maxHeight;
                return Column(
                  children: [
                    _paneHeader(context, '游戏日志', '${selectedEntries.length} 行'),
                    Expanded(
                      flex: (_splitRatio * 100).round(),
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(
                          dragDevices: const {
                            PointerDeviceKind.touch,
                            PointerDeviceKind.mouse,
                            PointerDeviceKind.trackpad,
                            PointerDeviceKind.stylus,
                            PointerDeviceKind.invertedStylus,
                          },
                        ),
                        child: guardPagerGestures(
                          PageView(
                            controller: _pager,
                            onPageChanged: _onPageChanged,
                            children: [
                              for (final level in LogLevel.values)
                                KeepAlivePage(
                                  child: _buildGamePage(context, level),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 可拖拽分隔线
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (d) {
                        setState(() {
                          _splitRatio =
                              (_splitRatio + d.primaryDelta! / totalHeight)
                                  .clamp(0.15, 0.85);
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
                    _paneHeader(context, '启动器日志', '${_launcherLines.length} 行'),
                    Expanded(
                      flex: ((1 - _splitRatio) * 100).round(),
                      child: _launcherLines.isEmpty
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
                                entries: [
                                  for (final l in _launcherLines) (l, 0),
                                ],
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
      ),
    );
  }

  Widget _buildGamePage(BuildContext context, LogLevel level) {
    final cs = Theme.of(context).colorScheme;
    final entries = _gameEntries(level);
    if (entries.isEmpty) {
      return Center(
        child: Text(
          _emptyLabel(level),
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
      );
    }
    // 游戏日志页不套 SelectionArea：桌面鼠标横拖要交给 PageView 切 tab，
    // 文本选择会把水平拖拽吃掉（启动器日志栏仍可选择复制）。
    return _LogList(
      scrollController: _gameScrolls[level.index],
      entries: entries,
      levelColor: (l) => _levelColor(cs, l),
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
}

/// local2api 请求日志页同款筛选卡：四张等宽卡，选中整张染 primary。
class _LogLevelTabBar extends StatelessWidget {
  const _LogLevelTabBar({
    required this.selected,
    required this.onSelected,
    required this.counts,
  });

  final LogLevel selected;
  final ValueChanged<LogLevel> onSelected;

  /// 与 [LogLevel.values] 同序的计数。
  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final colors = theme.colors;

    String label(LogLevel level) => switch (level) {
      LogLevel.all => '全部',
      LogLevel.info => 'Info',
      LogLevel.warning => '警告',
      LogLevel.error => '错误',
    };

    return Row(
      children: [
        for (final (index, level) in LogLevel.values.indexed) ...[
          if (index > 0) const SizedBox(width: 8),
          Expanded(
            child: MiuixCard(
              cornerRadius: 12,
              onPressed: () => onSelected(level),
              colors: selected == level
                  ? MiuixCardColors(
                      color: colors.primary,
                      contentColor: colors.onPrimary,
                    )
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 3),
                child: Center(
                  child: Text(
                    '${label(level)} ${counts[index]}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: selected == level
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: selected == level
                          ? colors.onPrimary
                          : colors.onSurfaceVariantSummary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 等宽日志列表（14px，SelectionArea 内可选中复制）。
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
              fontSize: 14,
              height: 1.4,
              color: levelColor(level),
            ),
          ),
        );
      },
    );
  }
}

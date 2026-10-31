import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall;

/// 一条日志：文本 + 来源（游戏输出 / 启动器自身）。
class LogLine {
  const LogLine(this.text, {required this.fromGame});

  final String text;
  final bool fromGame;

  Map<String, dynamic> toEntry() => {'game': fromGame, 'line': text};
}

/// 独立日志窗口（主窗口侧）。
///
/// HMCL 风格：游戏启动时在 Windows 下弹出一个独立窗口实时滚动游戏日志。
/// 通信走 desktop_multi_window 的 WindowMethodChannel（unidirectional，
/// 一端注册 handler、任意引擎可调）：
///   · `mint/log_main`   —— 日志窗口 → 主窗口（init / clear）
///   · `mint/log_window` —— 主窗口 → 日志窗口（append / exited）
///
/// ⚠️ 生命周期：子窗口的 Flutter 引擎**创建后永不销毁**。「关闭」只是
/// 隐藏窗口（hide），重开是 show。原因：window_manager 的 destroy 会把
/// 退出消息投到共享平台线程队列，desktop_multi_window 的引擎销毁也在
/// 同一个线程同步进行 —— 实测关闭日志窗口会把主窗口的消息循环一起
/// 卡死或直接退出整个应用。引擎常驻的代价（几十 MB 内存）远小于崩溃。
class LogWindowService {
  LogWindowService._();

  static final LogWindowService instance = LogWindowService._();

  static const _kChannelToWindow = 'mint/log_window';
  static const _kChannelToMain = 'mint/log_main';

  WindowController? _controller;
  bool _mainHandlerRegistered = false;
  bool _visible = false;

  /// 待推送行缓冲（200ms 批量刷给子窗口，日志风暴时不打爆通道）。
  final List<Map<String, dynamic>> _pending = [];
  Timer? _flushTimer;
  bool _gameExitedSent = false;

  /// 日志窗口引擎是否已创建（隐藏也算已创建）。
  bool get isCreated => _controller != null;

  /// 日志窗口当前是否可见。
  bool get isVisible => isCreated && _visible;

  /// 日志窗口启动后会调 [onInitRequested] 拉历史日志。
  List<LogLine> Function()? onInitRequested;

  /// 主窗口收到「清空日志」请求时执行（挂到 LauncherController）。
  void Function()? onClearRequested;

  /// 打开日志窗口（首次创建引擎，之后只是重新显示）。仅 Windows。
  Future<void> open() async {
    if (!Platform.isWindows) return;
    if (!_mainHandlerRegistered) {
      await WindowMethodChannel(
        _kChannelToMain,
        mode: ChannelMode.unidirectional,
      ).setMethodCallHandler(_onWindowCall);
      _mainHandlerRegistered = true;
    }
    final existing = _controller;
    if (existing != null) {
      // 引擎常驻：清掉上一次游戏会话的旧日志再显示（不重启启动器也能
      // 看到本次会话的日志），然后重新显示。
      _visible = true;
      _gameExitedSent = false;
      _pending.clear();
      // 上一会话结束时 cancel 过的定时器引用要清掉，否则 appendLine 里的
      // `_flushTimer ??= ...` 认为定时器还在，新会话日志永远不推送。
      _flushTimer?.cancel();
      _flushTimer = null;
      unawaited(_invokeToWindow('clear', const {}));
      try {
        await existing.show();
      } catch (e) {
        debugPrint('LogWindowService re-show failed: $e');
      }
      return;
    }
    try {
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'kind': 'logs'}),
          hiddenAtLaunch: true,
        ),
      );
      _controller = controller;
      _visible = true;
      _gameExitedSent = false;
      _pending.clear();
    } catch (e) {
      debugPrint('LogWindowService.open failed: $e');
      _controller = null;
      _visible = false;
    }
  }

  /// 隐藏日志窗口（引擎保留，下次打开瞬时恢复）。
  Future<void> close() async {
    if (!isCreated) return;
    _visible = false;
    try {
      await _controller!.hide();
    } catch (e) {
      debugPrint('LogWindowService.hide failed: $e');
    }
  }

  /// 游戏退出时通知日志窗口（状态条从「运行中」变「已退出 code」）。
  void notifyGameExited(int exitCode) {
    if (!isCreated || _gameExitedSent) return;
    _gameExitedSent = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    final entries = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();
    _invokeToWindow('exited', {'exitCode': exitCode, 'pending': entries});
  }

  /// [LauncherController.log] 每写一行就调这里；批量 200ms 推一次。
  /// 窗口隐藏时也照常推（子窗口引擎还在跑，重开即见完整历史）。
  void appendLine(String line, {required bool fromGame}) {
    if (!isCreated) return;
    _pending.add({'game': fromGame, 'line': line});
    _flushTimer ??= Timer(const Duration(milliseconds: 200), _flush);
  }

  void _flush() {
    _flushTimer = null;
    if (!isCreated) {
      _pending.clear();
      return;
    }
    final entries = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();
    _invokeToWindow('append', {'entries': entries});
  }

  /// 发给日志窗口；通道不存在（理论上引擎常驻后不会发生）时忽略。
  Future<void> _invokeToWindow(String method, Map<String, dynamic> args) async {
    try {
      await WindowMethodChannel(
        _kChannelToWindow,
        mode: ChannelMode.unidirectional,
      ).invokeMethod(method, args);
    } on WindowChannelException catch (e) {
      debugPrint('log window channel: ${e.code}');
    } catch (e) {
      debugPrint('log window invoke failed: $e');
    }
  }

  Future<dynamic> _onWindowCall(MethodCall call) async {
    switch (call.method) {
      case 'init':
        // 日志窗口首次启动完成：回放历史日志。
        final history =
            onInitRequested?.call().map((e) => e.toEntry()).toList() ??
            const [];
        _invokeToWindow('append', {'entries': history});
        return true;
      case 'clear':
        onClearRequested?.call();
        return true;
      case 'closed':
        // 子窗口点了关闭按钮：它已自行隐藏，这里同步状态。
        _visible = false;
        return true;
    }
    return null;
  }
}

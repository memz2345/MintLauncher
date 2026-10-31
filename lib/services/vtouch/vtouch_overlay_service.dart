import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall;

import 'package:mint/services/settings_service.dart';
import 'package:mint/services/vtouch/vtouch_layout.dart';

/// 桌面虚拟触控悬浮层（主窗口侧）。
///
/// 与 LogWindowService 同一套子窗口架构：desktop_multi_window 开一个
/// 隐藏启动的子引擎，**引擎创建后常驻**（销毁会把主窗口消息循环一起拖死，
/// 见日志窗口的注释），show / hide 只是显隐。
///
/// 通信走 WindowMethodChannel（一端注册 handler、任意引擎可调）：
///   · `mint/vtouch_main`    —— 悬浮窗 → 主窗口（ready / save / hide）
///   · `mint/vtouch_overlay` —— 主窗口 → 悬浮窗（apply / hide）
///
/// 悬浮窗引擎**不直接读写 SharedPreferences**：两个引擎各有一份内存缓存，
/// 互写会互相覆盖。布局编辑由悬浮窗把整份数据发回来，这里落到
/// SettingsService（launcher_config blob）；设置页改动从这里实时推回悬浮窗。
class VTouchOverlayService {
  VTouchOverlayService._();

  static final VTouchOverlayService instance = VTouchOverlayService._();

  static const _kChannelToOverlay = 'mint/vtouch_overlay';
  static const _kChannelToMain = 'mint/vtouch_main';

  WindowController? _controller;
  bool _visible = false;
  bool _mainHandlerRegistered = false;

  /// 悬浮窗引擎是否已创建（隐藏也算已创建）。
  bool get isCreated => _controller != null;

  /// 悬浮窗当前是否可见。
  bool get isVisible => isCreated && _visible;

  /// 待推给悬浮窗的游戏 pid（0 = 无游戏，悬浮窗铺工作区）。
  int _pendingPid = 0;

  SettingsService? _settings;

  /// 挂上设置源：悬浮窗可见期间设置变化实时推送（设置页调滑杆立刻生效）。
  void attachSettings(SettingsService settings) {
    if (identical(_settings, settings)) return;
    _settings?.removeListener(_onSettingsChanged);
    _settings = settings;
    settings.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (!_visible) return;
    unawaited(_pushApply());
  }

  /// 打开悬浮层。[gamePid] 是游戏进程 pid：悬浮层贴它的窗口、随它移动；
  /// 传 0 / null 表示无游戏（布局编辑 / 实测），铺主屏工作区。仅 Windows。
  Future<void> show({int? gamePid}) async {
    if (!Platform.isWindows) return;
    debugPrint('vtouch: show() entered pid=$gamePid');
    _registerMainHandler();
    _pendingPid = gamePid ?? 0;
    final existing = _controller;
    if (existing != null) {
      // 引擎常驻：直接重新显示并推一份最新配置。
      _visible = true;
      await _pushApply();
      return;
    }
    try {
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'kind': 'vtouch'}),
          hiddenAtLaunch: true,
        ),
      );
      debugPrint('vtouch: sub window created id=${controller.windowId}');
      _controller = controller;
      _visible = true;
      // 配置由悬浮窗 ready 后回拉（_onOverlayCall → _pushApply），这里不抢跑：
      // 子引擎启动要几百毫秒，现在发 apply 会撞上「handler 还没注册」。
    } catch (e) {
      debugPrint('VTouchOverlayService.show failed: $e');
      _controller = null;
      _visible = false;
    }
  }

  /// 进入布局编辑（设置页「编辑按键布局」）。有游戏贴游戏窗口，没有就
  /// 铺主屏工作区；编辑模式开关在悬浮层的菜单面板里。
  Future<void> showEditor({int? gamePid}) => show(gamePid: gamePid);

  /// 收起悬浮层（游戏退出 / 用户从面板关闭都走这里）。引擎保留。
  Future<void> hide() async {
    if (!isCreated) return;
    _visible = false;
    _pendingPid = 0;
    try {
      await WindowMethodChannel(
        _kChannelToOverlay,
        mode: ChannelMode.unidirectional,
      ).invokeMethod('hide');
    } catch (e) {
      debugPrint('VTouchOverlayService.hide failed: $e');
    }
  }

  void _registerMainHandler() {
    if (_mainHandlerRegistered) return;
    _mainHandlerRegistered = true;
    WindowMethodChannel(
      _kChannelToMain,
      mode: ChannelMode.unidirectional,
    ).setMethodCallHandler(_onOverlayCall);
  }

  Future<dynamic> _onOverlayCall(MethodCall call) async {
    final settings = _settings;
    switch (call.method) {
      case 'ready':
        // 悬浮窗首帧就绪：把当前配置推过去（含游戏 pid）。
        await _pushApply();
        return true;
      case 'save':
        if (settings == null) return false;
        final args =
            (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
        final layout = args['layout'];
        if (layout is List) {
          final controls = <VTouchControl>[
            for (final item in layout)
              if (item is Map)
                VTouchControl.fromJson(item.cast<String, dynamic>()),
          ];
          if (controls.isNotEmpty) settings.vtouchLayout = controls;
        }
        if (args['alpha'] is num) {
          settings.vtouchAlpha = (args['alpha'] as num).toDouble();
        }
        if (args['scale'] is num) {
          settings.vtouchScale = (args['scale'] as num).toDouble();
        }
        if (args['ballX'] is num && args['ballY'] is num) {
          settings.setVTouchBall(
            (args['ballX'] as num).toDouble(),
            (args['ballY'] as num).toDouble(),
          );
        }
        return true;
      case 'hide':
        // 悬浮窗自己收起了（面板里的关闭按钮），同步状态。
        _visible = false;
        _pendingPid = 0;
        return true;
    }
    return null;
  }

  /// 当前配置 → 悬浮窗。pid 每次都带（游戏重启后 pid 会变）。
  ///
  /// 子窗口的 WindowMethodChannel 注册在原生窗口创建之后才完成，主引擎
  /// 第一次推 apply 可能撞上 `CHANNEL_UNREGISTERED`；这里退避重试，直到
  /// 子窗口通道就绪。
  Future<void> _pushApply() async {
    final controller = _controller;
    if (controller == null) return;
    final settings = _settings;
    try {
      await WindowMethodChannel(
        _kChannelToOverlay,
        mode: ChannelMode.unidirectional,
      ).invokeMethod('apply', {
        'pid': _pendingPid,
        'visible': _visible,
        if (settings != null) ...{
          'alpha': settings.vtouchAlpha,
          'scale': settings.vtouchScale,
          'ballX': settings.vtouchBallX,
          'ballY': settings.vtouchBallY,
          'layout': [for (final c in settings.getVTouchLayout()) c.toJson()],
        },
      });
      _pushAttempts = 0;
    } on WindowChannelException catch (e) {
      debugPrint('vtouch overlay channel: ${e.code}');
      _schedulePushRetry();
    } catch (e) {
      debugPrint('vtouch overlay invoke failed: $e');
      _schedulePushRetry();
    }
  }

  int _pushAttempts = 0;
  Timer? _pushRetry;

  void _schedulePushRetry() {
    if (_controller == null || _pushAttempts >= 20) return;
    _pushAttempts++;
    _pushRetry?.cancel();
    _pushRetry = Timer(const Duration(milliseconds: 300), () {
      unawaited(_pushApply());
    });
  }
}

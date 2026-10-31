import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/ui/nav_state.dart';

/// 桌面端全局鼠标/键盘操作（自 local2api GlobalMouseBackWrapper 移植，
/// 并按 HMCL 补齐桌面启动器的常用快捷键）。
///
///  · 鼠标侧键（后退）/ Esc / Alt+←：路由回退一次（对话框、弹层优先关闭）
///  · F11：切换全屏（HMCL 同款）
///  · Ctrl+1…3：切换一级页（只在根页面生效，子页面不抢）
///  · 启动准备阶段按 Esc：中断启动（不会误关页面）
///  · Ctrl+F：请求当前页聚焦搜索
///  · Ctrl+M：打开版本管理（多游戏目录）
///  · F5：请求刷新
///
/// 键盘监听挂在 HardwareKeyboard 兜底层：输入框/页面自己的 Shortcuts
/// 先处理，处理掉的事件不会走到这里（Esc 清空搜索之类可局部覆盖）。
class GlobalShortcutHost extends StatefulWidget {
  const GlobalShortcutHost({
    super.key,
    required this.navigatorKey,
    this.controller,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final LauncherController? controller;
  final Widget child;

  @override
  State<GlobalShortcutHost> createState() => _GlobalShortcutHostState();
}

class _GlobalShortcutHostState extends State<GlobalShortcutHost> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool get _atRoot {
    final navigator = widget.navigatorKey.currentState;
    return navigator != null && !navigator.canPop();
  }

  void _back() {
    widget.navigatorKey.currentState?.maybePop();
  }

  Future<void> _toggleFullscreen() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    try {
      final full = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!full);
    } catch (_) {
      // 窗口管理器尚未就绪（测试/启动早期）：忽略。
    }
  }

  bool _handleKey(KeyEvent event) {
    // 只认按下瞬间；长按重复不重复触发。
    if (event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      // 启动准备阶段：Esc 先中断启动，不关页面 / 弹窗。
      if (widget.controller?.isPreparing == true) {
        unawaited(widget.controller!.cancelLaunch());
        return true;
      }
      _back();
      return false;
    }

    if (key == LogicalKeyboardKey.arrowLeft && keyboard.isAltPressed) {
      _back();
      return false;
    }

    if (key == LogicalKeyboardKey.f11) {
      unawaited(_toggleFullscreen());
      return false;
    }

    // Alt+F4 关闭窗口：摘掉 WS_SYSMENU 后系统菜单加速键表没了，
    // 这里手动补回（右键菜单里的「关闭(C) Alt+F4」由它兑现）。
    if (key == LogicalKeyboardKey.f4 && keyboard.isAltPressed) {
      unawaited(windowManager.close());
      return true;
    }

    if (key == LogicalKeyboardKey.f5) {
      NavRequests.requestRefresh();
      return false;
    }

    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      if (key == LogicalKeyboardKey.keyF) {
        NavRequests.requestSearch();
        return false;
      }
      if (key == LogicalKeyboardKey.keyM && _atRoot) {
        NavRequests.requestVersionManager();
        return false;
      }
      final tab = _tabForKey(key);
      if (tab != null && _atRoot) {
        NavRequests.requestTab(tab);
        return false;
      }
    }
    return false;
  }

  int? _tabForKey(LogicalKeyboardKey key) {
    const keys = [
      (LogicalKeyboardKey.digit1, 0),
      (LogicalKeyboardKey.digit2, 1),
      (LogicalKeyboardKey.digit3, 2),
      (LogicalKeyboardKey.numpad1, 0),
      (LogicalKeyboardKey.numpad2, 1),
      (LogicalKeyboardKey.numpad3, 2),
    ];
    for (final (logical, index) in keys) {
      if (key == logical) return index;
    }
    return null;
  }

  void _handlePointer(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    // buttons & 8 = 鼠标后退侧键（kBackMouseButton）。
    if (event.buttons & 8 != 0) _back();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointer,
      child: widget.child,
    );
  }
}

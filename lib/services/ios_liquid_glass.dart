import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// iOS 26 系统液态玻璃（`ios/Runner/GlassBridge.swift`）。
///
/// 玻璃以**平台视图** `mint/liquid_glass`（UIGlassEffect +
/// UIVisualEffectView）的方式长在 Flutter 组件树里：把它垫在悬浮底栏 /
/// 返回键的 Stack 最底层，玻璃糊的是 Flutter 里它身后的页面内容，而图标
/// 由 Flutter 叠在平台视图之上（第一版把原生玻璃盖在 FlutterView 最上层，
/// 图标被一起折射掉了 —— 平台视图才是正确姿势）。
///
/// iOS < 26 或探测失败时 `available()` 返回 false，组件走自绘降级。
class IosLiquidGlass {
  IosLiquidGlass._();

  static final IosLiquidGlass instance = IosLiquidGlass._();

  static const MethodChannel _channel = MethodChannel('mint/ios_glass');

  bool _probed = false;
  bool _available = false;
  bool _backMenuNative = false;
  num _iosVersion = 0;

  /// 原生侧长按返回菜单选中了一层。
  void Function(int index)? onBackMenuSelected;

  /// 探测结果缓存（未探测时为 null）。组件同步取用；探测在应用启动时做。
  bool? get cachedAvailable => _probed ? _available : null;

  /// iOS 26+ 才有 UIGlassEffect。
  Future<bool> available() async {
    if (!Platform.isIOS) return false;
    if (_probed) return _available;
    _probed = true;
    try {
      final caps = await _channel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      _available = caps?['liquidGlass'] == true;
      _backMenuNative = caps?['backMenu'] == true;
      _iosVersion = (caps?['iosVersion'] as num?) ?? 0;
      debugPrint(
        'IosLiquidGlass available=$_available '
        'backMenu=$_backMenuNative ios=$_iosVersion',
      );
    } catch (e) {
      debugPrint('IosLiquidGlass caps failed: $e');
      _available = false;
      _backMenuNative = false;
    }
    return _available;
  }

  /// 长按返回键的层级菜单能否交给系统（iOS 16+ 的 UIEditMenuInteraction）。
  ///
  /// iOS 14/15 的系统长按菜单只有 UIKit 导航栏内部的私有路径能拉起，App 层
  /// 没有公开 API；这两代由 Flutter 自绘同款菜单兜底（行为一致，观感稍简化）。
  bool? get cachedBackMenuNative => _probed ? _backMenuNative : null;

  /// 在 [anchor]（Flutter 全局逻辑像素）处弹原生返回层级菜单。
  ///
  /// 返回 false 表示原生不可用（非 iOS / iOS 16 以下 / 无 key window），
  /// 调用方退回 Flutter 自绘菜单。
  Future<bool> showBackMenu({
    required List<String> titles,
    required int currentIndex,
    required Offset anchor,
  }) async {
    if (!Platform.isIOS || titles.isEmpty) return false;
    if (cachedBackMenuNative != true) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('showBackMenu', {
        'titles': titles,
        'currentIndex': currentIndex,
        'anchor': [anchor.dx, anchor.dy],
      });
      return ok == true;
    } catch (e) {
      debugPrint('IosLiquidGlass showBackMenu failed: $e');
      return false;
    }
  }

  bool _handlerInstalled = false;

  void ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onBackMenuSelected') {
        final args = call.arguments;
        final index = args is Map ? (args['index'] as num?)?.toInt() : null;
        if (index != null) onBackMenuSelected?.call(index);
      }
      return null;
    });
  }

  /// 测试用。
  void reset() {
    _probed = false;
    _available = false;
    _backMenuNative = false;
    _iosVersion = 0;
    onBackMenuSelected = null;
    _handlerInstalled = false;
  }
}

/// 玻璃背景层：垫在底栏 / 返回键 Stack 最底层的系统液态玻璃平台视图。
/// 圆角由外层 [ClipRRect] / [ClipOval] 裁；触摸穿透（原生侧
/// isUserInteractionEnabled = false），手势照常走 Flutter。
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, this.borderRadius});

  /// 胶囊 / 圆形圆角；null = 不裁（调用方自己裁）。
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final view = const UiKitView(viewType: 'mint/liquid_glass');
    if (borderRadius == null) return view;
    return ClipRRect(borderRadius: borderRadius!, child: view);
  }
}

/// 顶栏圆形动作（返回键 / 操作按钮）的原生玻璃底盘。
///
/// 交互全部交给上面的 Flutter 按钮（原生玻璃视图触摸穿透），所以长按 /
/// 水波 / 语义都不受影响。
class IosGlassCircle extends StatelessWidget {
  const IosGlassCircle({super.key, required this.child, this.size = 40});

  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipOval(
            child: GlassBackdrop(borderRadius: BorderRadius.circular(size / 2)),
          ),
          Center(child: child),
        ],
      ),
    );
  }
}

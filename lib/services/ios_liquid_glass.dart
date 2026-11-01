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
  bool _nativeBackButton = false;
  num _iosVersion = 0;

  /// 探测结果缓存（未探测时为 null）。组件同步取用；探测在应用启动时做。
  bool? get cachedAvailable => _probed ? _available : null;

  /// iOS 26+ 才有 UIGlassEffect / UIButton.Configuration.glass()。
  Future<bool> available() async {
    if (!Platform.isIOS) return false;
    if (_probed) return _available;
    _probed = true;
    try {
      final caps = await _channel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      _available = caps?['liquidGlass'] == true;
      _nativeBackButton = caps?['nativeBackButton'] == true;
      _iosVersion = (caps?['iosVersion'] as num?) ?? 0;
      debugPrint(
        'IosLiquidGlass available=$_available '
        'nativeBackButton=$_nativeBackButton ios=$_iosVersion',
      );
    } catch (e) {
      debugPrint('IosLiquidGlass caps failed: $e');
      _available = false;
      _nativeBackButton = false;
    }
    return _available;
  }

  /// 返回键能否整颗交给 UIKit（UIButton.Configuration.glass + SF Symbol
  /// `chevron.backward` + UIContextMenuInteraction 长按系统菜单）。
  bool? get cachedNativeBackButton => _probed ? _nativeBackButton : null;

  /// 测试用。
  void reset() {
    _probed = false;
    _available = false;
    _nativeBackButton = false;
    _iosVersion = 0;
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

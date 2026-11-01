import 'dart:io';

import 'package:flutter/foundation.dart';
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

  /// 探测结果缓存（未探测时为 null）。组件同步取用；探测在应用启动时做。
  bool? get cachedAvailable => _probed ? _available : null;

  /// 探测结果缓存（iOS 26+ 才有 UIGlassEffect）。
  Future<bool> available() async {
    if (!Platform.isIOS) return false;
    if (_probed) return _available;
    _probed = true;
    try {
      final caps = await _channel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      _available = caps?['liquidGlass'] == true;
      debugPrint('IosLiquidGlass available=$_available (UIGlassEffect 探测)');
    } catch (e) {
      debugPrint('IosLiquidGlass caps failed: $e');
      _available = false;
    }
    return _available;
  }

  /// 测试用。
  void reset() {
    _probed = false;
    _available = false;
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

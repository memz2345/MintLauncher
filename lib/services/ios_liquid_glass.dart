import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// iOS 26 系统液态玻璃桥（`ios/Runner/GlassBridge.swift`）。
///
/// 启动器的悬浮底栏 / 返回键在 iOS 26+ 上用**系统自带**的 Liquid Glass
/// （`UIGlassEffect` + `UIVisualEffectView` 铺在 Flutter 视图之上，糊身后
/// 的 Flutter 内容）替代 Flutter 自绘的毛玻璃 —— 与系统 tab 栏同款观感。
/// iOS < 26 或探测失败时 `available()` 返回 false，组件走自绘降级。
///
/// 区域用 Flutter 全局逻辑坐标（== UIKit point，FlutterView 铺满窗口），
/// 由 [GlassRegion] 组件在每帧布局后上报；`isUserInteractionEnabled =
/// false`，触摸穿透回 Flutter。
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

  final Map<String, ({bool visible, Rect? rect, double radius})> _last = {};

  /// 更新一个玻璃区域。id: 'bottomBar' / 'back'；[rect] 为 Flutter 全局
  /// 逻辑坐标，不可见时只传 [visible] = false。参数没变就不重发。
  Future<void> setGlass(
    String id, {
    required bool visible,
    Rect? rect,
    required double radius,
  }) async {
    if (!Platform.isIOS) return;
    final last = _last[id];
    if (last != null &&
        last.visible == visible &&
        last.radius == radius &&
        ((rect == null && last.rect == null) || last.rect == rect)) {
      return;
    }
    _last[id] = (visible: visible, rect: rect, radius: radius);
    try {
      await _channel.invokeMethod<void>('setGlass', {
        'id': id,
        'visible': visible,
        if (visible && rect != null) ...{
          'x': rect.left,
          'y': rect.top,
          'w': rect.width,
          'h': rect.height,
        },
        'radius': radius,
      });
    } catch (e) {
      debugPrint('IosLiquidGlass setGlass($id) failed: $e');
    }
  }

  /// 全部摘掉（应用退出到后台 / 测试重置用；组件 dispose 会各自摘自己的）。
  Future<void> clearAll() async {
    if (!Platform.isIOS) return;
    _last.clear();
    try {
      await _channel.invokeMethod<void>('clearGlass');
    } catch (e) {
      debugPrint('IosLiquidGlass clearAll failed: $e');
    }
  }

  /// 测试用。
  void reset() {
    _probed = false;
    _available = false;
    _last.clear();
  }
}

/// 报告子树全局矩形的玻璃区域：iOS 26+ 且 [enabled] 时把 rect 每帧上报给
/// 原生铺系统玻璃；其它平台 / 探测失败时是透明的空壳（原生侧没有视图）。
///
/// [IosLiquidGlass.setGlass] 自带去重，布局不变不会重复发通道消息；
/// dispose 时上报 visible=false 摘掉玻璃。
class GlassRegion extends StatefulWidget {
  const GlassRegion({
    super.key,
    required this.id,
    required this.radius,
    required this.enabled,
    required this.child,
  });

  /// 玻璃槽位（'bottomBar' / 'back'，原生侧按 id 各持一个视图）。
  final String id;

  /// 圆角（底栏传高度一半 = 胶囊；返回键传宽度一半 = 圆）。
  final double radius;

  final bool enabled;
  final Widget child;

  @override
  State<GlassRegion> createState() => _GlassRegionState();
}

class _GlassRegionState extends State<GlassRegion> {
  final GlobalKey _key = GlobalKey();
  bool _scheduled = false;

  void _scheduleReport() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      _report();
    });
  }

  void _report() {
    if (!widget.enabled) {
      IosLiquidGlass.instance.setGlass(
        widget.id,
        visible: false,
        radius: widget.radius,
      );
      return;
    }
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.isEmpty) return;
    IosLiquidGlass.instance.setGlass(
      widget.id,
      visible: true,
      rect: rect,
      radius: widget.radius,
    );
  }

  @override
  void initState() {
    super.initState();
    _scheduleReport();
  }

  @override
  void didUpdateWidget(GlassRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleReport();
  }

  @override
  void dispose() {
    IosLiquidGlass.instance.setGlass(
      widget.id,
      visible: false,
      radius: widget.radius,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleReport();
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

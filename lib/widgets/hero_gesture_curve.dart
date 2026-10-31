// lib/widgets/hero_gesture_curve.dart
//
// 预测式返回（Android）/ 侧滑返回跟手期间，Hero 飞行必须改用线性曲线。
//
// 背景：`_HeroFlightManifest.animation` 会给飞行动画套 `Hero.curve`
// （heroes.dart：`CurvedAnimation(parent: fromRoute.animation, curve: fromHero.widget.curve)`）。
// 程序化 push/pop 时路由控制器自己跑完整段动画，套 S 曲线没问题；但跟手期间
// 控制器是被手势**逐帧 seek** 的，再套 easeInOutCubic / fastOutSlowIn 就变成
// 「起手几乎不动、末端反超」——实测（整页 Hero 400×300 → 卡片 120×60）：
//
//   手势 progress   0.25    0.50    0.75
//   实测宽度        383.8   311.4   150.0
//   线性应为        330     260     190
//
// 控制器改不了（值是手势给的），只能让 Hero 自己换曲线：转场在手势期间用本
// InheritedWidget 提供 linear=true，页面里的 Hero 据此选 curve。
// Flutter 官方的 Cupertino 转场也是同一思路（`route.popGestureInProgress`
// 时所有曲线退化为线性）。
//
// 用法（只改 pop 时的 fromHero 那一端即可，飞行曲线取自 fromHero widget）：
//
//   final gestureCurve = HeroGestureCurve.curveOrNull(context);
//   Hero(curve: gestureCurve ?? myCurve, reverseCurve: gestureCurve ?? myCurve, ...)
import 'package:flutter/widgets.dart';

class HeroGestureCurve extends InheritedWidget {
  const HeroGestureCurve({
    super.key,
    required this.linear,
    required super.child,
  });

  /// true = 当前有跟手手势在进行，Hero 飞行应当线性。
  final bool linear;

  /// 手势跟手期间返回 [Curves.linear]；其余情况返回 null，
  /// 调用方回退到自己的曲线。不在任何转场里时同样返回 null。
  static Curve? curveOrNull(BuildContext context) {
    final HeroGestureCurve? scope = context
        .dependOnInheritedWidgetOfExactType<HeroGestureCurve>();
    if (scope == null || !scope.linear) return null;
    return Curves.linear;
  }

  @override
  bool updateShouldNotify(HeroGestureCurve oldWidget) =>
      oldWidget.linear != linear;
}

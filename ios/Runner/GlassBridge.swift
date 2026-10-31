import Flutter
import UIKit

/// iOS 26 Liquid Glass 桥：把系统玻璃（`UIGlassEffect` + `UIVisualEffectView`）
/// 铺在 Flutter 视图之上，让启动器的悬浮底栏 / 返回键用上**系统自带**的
/// 液态玻璃 —— 玻璃糊的是身后的 Flutter 内容，与系统 tab 栏同款观感。
///
/// Flutter 侧只报区域（逻辑坐标 == UIKit point，FlutterView 铺满窗口时
/// 一一对应）与圆角；玻璃视图 `isUserInteractionEnabled = false`，触摸
/// 全部穿透回 Flutter。
///
/// 用 `NSClassFromString("UIGlassEffect")` 反射构造：CI 的 Xcode 版本可能
/// 还没带 iOS 26 SDK，反射在旧 SDK 上也能编译、在 iOS 26 运行时上生效；
/// 类不存在（iOS < 26）时能力探测如实返回 false，Flutter 走自绘降级。
@objc class GlassBridge: NSObject {
  private static var glassViews: [String: UIVisualEffectView] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "mint/ios_glass",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
  }

  /// 场景树里的 FlutterView（flutter create 模板：rootViewController 就是
  /// FlutterViewController）。
  private static func flutterView() -> UIView? {
    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    if let root = window?.rootViewController as? FlutterViewController {
      return root.view
    }
    // 模板结构变化时兜底：在子控制器里找。
    for child in window?.rootViewController?.children ?? [] {
      if let vc = child as? FlutterViewController {
        return vc.view
      }
    }
    return nil
  }

  private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCapabilities":
      result(["liquidGlass": NSClassFromString("UIGlassEffect") != nil])
    case "setGlass":
      guard let args = call.arguments as? [String: Any],
            let id = args["id"] as? String else {
        result(FlutterError(code: "args", message: "missing id", details: nil))
        return
      }
      let visible = (args["visible"] as? Bool) ?? false
      guard visible,
            let x = args["x"] as? Double,
            let y = args["y"] as? Double,
            let w = args["w"] as? Double,
            let h = args["h"] as? Double,
            let radius = args["radius"] as? Double else {
        // 不可见：直接摘掉玻璃视图（Dart 侧 dispose / 关闭开关时调用）。
        if let view = glassViews[id] {
          view.removeFromSuperview()
          glassViews[id] = nil
        }
        result(nil)
        return
      }
      updateGlass(id: id, x: x, y: y, w: w, h: h, radius: radius)
      result(nil)
    case "clearGlass":
      for (_, view) in glassViews { view.removeFromSuperview() }
      glassViews.removeAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func updateGlass(
    id: String, x: Double, y: Double, w: Double, h: Double, radius: Double
  ) {
    guard let container = flutterView() else { return }
    guard let glassClass = NSClassFromString("UIGlassEffect") as? NSObject.Type,
          let effect = glassClass.init() as? UIVisualEffect else {
      // 运行时没有 iOS 26 的玻璃实现：什么都不铺（Dart 侧已探测过，兜底）。
      return
    }
    let view: UIVisualEffectView
    if let existing = glassViews[id] {
      view = existing
    } else {
      view = UIVisualEffectView(effect: effect)
      view.isUserInteractionEnabled = false
      container.addSubview(view)
      glassViews[id] = view
    }
    UIView.performWithoutAnimation {
      view.frame = CGRect(x: x, y: y, width: w, height: h)
      view.layer.cornerRadius = CGFloat(radius)
      view.layer.cornerCurve = .continuous
      view.layer.masksToBounds = true
      container.bringSubviewToFront(view)
    }
  }
}

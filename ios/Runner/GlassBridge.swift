import Flutter
import UIKit

/// iOS 26 Liquid Glass 桥：`UIGlassEffect` + `UIVisualEffectView` 以
/// **平台视图**（`mint/liquid_glass`）的方式长在 Flutter 组件树里 ——
/// 玻璃糊的是 Flutter 里它**身后**的内容（页面正文），而底栏图标 /
/// 返回箭头由 Flutter 叠在平台视图之上，不会被玻璃折射掉。
///
/// `UIGlassEffect` 用 `NSClassFromString` 反射构造：CI 的 Xcode 版本可能
/// 还没带 iOS 26 SDK，反射在旧 SDK 上也能编译；类不存在（iOS < 26）时
/// `getCapabilities` 如实返回 false，Flutter 走自绘降级。
@objc class GlassBridge: NSObject {
  static func register(with registrar: FlutterPluginRegistrar) {
    // 能力探测（iOS 26+ 才有 UIGlassEffect）。
    let channel = FlutterMethodChannel(
      name: "mint/ios_glass",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getCapabilities":
        result(["liquidGlass": NSClassFromString("UIGlassEffect") != nil])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // 平台视图：玻璃背景（Flutter 侧用 UiKitView 嵌进组件树）。
    registrar.register(
      GlassPlatformViewFactory(),
      withId: "mint/liquid_glass"
    )
  }
}

class GlassPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    GlassPlatformView(frame: frame)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

class GlassPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView

  init(frame: CGRect) {
    container = UIView(frame: frame)
    container.backgroundColor = .clear
    if let glassClass = NSClassFromString("UIGlassEffect") as? NSObject.Type,
       let effect = glassClass.init() as? UIVisualEffect {
      let glass = UIVisualEffectView(effect: effect)
      glass.frame = container.bounds
      glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      // 触摸穿透回 Flutter（底栏的拖动/点按都在 Flutter 侧处理）。
      glass.isUserInteractionEnabled = false
      container.addSubview(glass)
    } else {
      // 探测失败兜底：一块半透明底，好过什么都没有。
      container.backgroundColor = UIColor.systemFill
    }
    super.init()
  }

  func view() -> UIView {
    container
  }
}

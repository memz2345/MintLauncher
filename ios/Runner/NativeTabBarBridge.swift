import Flutter
import UIKit

/// 原生 iOS 26 液态玻璃底栏。
///
/// Apple 文档（WWDC25「Build a UIKit app with the new design」/ Adopting
/// Liquid Glass）：iOS 26 的浮动 Liquid Glass tab bar 由
/// `UITabBarController` 提供；**单独摆一个 `UITabBar` 不会正确采样内容**
/// （官方论坛也确认 standalone UITabBar 没有滚动内容的玻璃模糊）。
/// 所以这里把 `UITabBarController` 作为子控制器，只露出底部一条，
/// 由它管理真正的系统 tab bar（玻璃、选中高亮、按压反馈都是原生的）。
///
/// 通道名与 Android 的 `dev.mint.mint/liquid_bar` 保持一致，Dart 侧
/// `LiquidGlassBarService` / `NativeGlassBarBinding` 不需要分平台。
@objc class NativeTabBarBridge: NSObject, UITabBarControllerDelegate {
  private static var keepAlive: NativeTabBarBridge?

  private let channel: FlutterMethodChannel
  private var tabController: UITabBarController?
  private weak var host: UIViewController?
  private var stripHeight: CGFloat = 98
  private var lastFrame: CGRect = .zero

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dev.mint.mint/liquid_bar",
      binaryMessenger: registrar.messenger()
    )
    let bridge = NativeTabBarBridge(channel: channel)
    keepAlive = bridge
    channel.setMethodCallHandler { [weak bridge] call, result in
      guard let bridge else {
        result(false)
        return
      }
      bridge.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "showBar":
      guard let args = call.arguments as? [String: Any],
            let tabs = args["tabs"] as? [[String: Any]],
            let index = (args["index"] as? NSNumber)?.intValue
      else {
        result(false)
        return
      }
      let height = (args["height"] as? NSNumber)?.doubleValue ?? 64
      let bottomInset = (args["bottomInset"] as? NSNumber)?.doubleValue ?? 0
      let accent = color(from: (args["accent"] as? NSNumber)?.intValue)
      let ok = show(
        tabs: tabs,
        index: index,
        height: CGFloat(height),
        bottomInset: CGFloat(bottomInset),
        accent: accent
      )
      result(ok)
    case "updateIndex":
      let index =
        ((call.arguments as? [String: Any])?["index"] as? NSNumber)?.intValue
        ?? 0
      tabController?.selectedIndex = max(0, index)
      result(nil)
    case "hideBar":
      hide()
      result(nil)
    case "sync":
      layout()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func show(
    tabs: [[String: Any]],
    index: Int,
    height: CGFloat,
    bottomInset: CGFloat,
    accent: UIColor?
  ) -> Bool {
    hide()
    guard let host = rootViewController(), let hostView = host.view,
          !tabs.isEmpty
    else { return false }

    let controller = UITabBarController()
    controller.delegate = self
    controller.view.backgroundColor = .clear
    controller.tabBar.isTranslucent = true
    if let accent {
      controller.tabBar.tintColor = accent
    }
    controller.tabBar.unselectedItemTintColor = .secondaryLabel

    var controllers: [UIViewController] = []
    for (i, tab) in tabs.enumerated() {
      let vc = UIViewController()
      vc.view.backgroundColor = .clear
      vc.view.isHidden = true
      let item = UITabBarItem(
        title: tab["label"] as? String ?? "",
        image: UIImage(systemName: symbolName(index: i, selected: false)),
        selectedImage: UIImage(systemName: symbolName(index: i, selected: true))
      )
      // 原生红点：空字符串 badge 会渲染成一个红色小圆点。
      if (tab["badge"] as? Bool) == true {
        item.badgeValue = " "
      }
      vc.tabBarItem = item
      controllers.append(vc)
    }
    controller.setViewControllers(controllers, animated: false)
    controller.selectedIndex = max(0, min(index, controllers.count - 1))

    host.addChild(controller)
    hostView.addSubview(controller.view)
    controller.didMove(toParent: host)
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]

    self.host = host
    self.tabController = controller
    // height 是 Flutter 的 64pt 胶囊高，另留 12pt 与悬浮栏 gap 对齐。
    self.stripHeight = height + 12 + bottomInset
    layout()
    return true
  }

  private func hide() {
    guard let controller = tabController else { return }
    controller.willMove(toParent: nil)
    controller.view.removeFromSuperview()
    controller.removeFromParent()
    tabController = nil
    host = nil
  }

  private func layout() {
    guard let host, let controller = tabController else { return }
    let bounds = host.view.bounds
    let frame = CGRect(
      x: 0,
      y: bounds.height - stripHeight,
      width: bounds.width,
      height: stripHeight
    )
    if frame != lastFrame || controller.view.frame != frame {
      controller.view.frame = frame
      lastFrame = frame
    }
  }

  private func rootViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive }
      ?? scenes.first
    let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    return window?.rootViewController
  }

  private func symbolName(index: Int, selected: Bool) -> String {
    switch index {
    case 0:
      return selected ? "house.fill" : "house"
    case 1:
      return selected ? "arrow.down.circle.fill" : "arrow.down.circle"
    default:
      return "ellipsis"
    }
  }

  private func color(from argb: Int?) -> UIColor? {
    guard let argb else { return nil }
    return UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
  }

  // MARK: - UITabBarControllerDelegate

  func tabBarController(
    _ tabBarController: UITabBarController,
    didSelect viewController: UIViewController
  ) {
    channel.invokeMethod(
      "onTabSelected",
      arguments: ["index": tabBarController.selectedIndex]
    )
  }
}

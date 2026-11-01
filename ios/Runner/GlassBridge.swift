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
        result([
          "liquidGlass": NSClassFromString("UIGlassEffect") != nil,
          // iOS 16+ 才能用 UIEditMenuInteraction 在 App 层拉起系统菜单；
          // iOS 14/15 由 Flutter 自绘同款（系统只在 UINavigationBar 内部
          // 暴露长按返回菜单，没有公开 API）。
          "backMenu": GlassBackBridgeCapabilities.backMenu,
          "iosVersion": GlassBackBridgeCapabilities.iosVersion,
        ])
      case "showBackMenu":
        guard #available(iOS 16.0, *) else {
          result(false)
          return
        }
        guard let args = call.arguments as? [String: Any],
              let titles = args["titles"] as? [String], !titles.isEmpty,
              let currentIndex = args["currentIndex"] as? Int,
              let anchor = args["anchor"] as? [Double], anchor.count == 2
        else {
          result(false)
          return
        }
        let ok = BackMenuPresenter.shared.present(
          titles: titles,
          currentIndex: currentIndex,
          anchor: CGPoint(x: anchor[0], y: anchor[1]),
          channel: channel
        )
        result(ok)
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

private enum GlassBackBridgeCapabilities {
  static var backMenu: Bool {
    if #available(iOS 16.0, *) { return true }
    return false
  }

  static var iosVersion: Double {
    Double(UIDevice.current.systemVersion) ?? 0
  }
}

/// 长按返回键的层级菜单（iOS 16+）。
///
/// 用 `UIEditMenuInteraction` 在返回按钮位置拉起系统 UIMenu —— 与
/// UINavigationBar 长按返回键的菜单同源（玻璃底、系统动效、当前层打勾），
/// 选择后经 MethodChannel 回传 index，由 Dart 侧 popUntil 到对应路由。
@available(iOS 16.0, *)
final class BackMenuPresenter: NSObject, UIEditMenuInteractionDelegate {
  static let shared = BackMenuPresenter()

  private var interaction: UIEditMenuInteraction?
  private var anchorView: UIView?
  private var titles: [String] = []
  private var currentIndex = 0
  private var channel: FlutterMethodChannel?

  func present(
    titles: [String],
    currentIndex: Int,
    anchor: CGPoint,
    channel: FlutterMethodChannel
  ) -> Bool {
    dismissMenu()

    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    guard let window = scene?.windows.first(where: { $0.isKeyWindow })
        ?? scene?.windows.first,
          let root = window.rootViewController?.view
    else { return false }

    self.titles = titles
    self.currentIndex = currentIndex
    self.channel = channel

    // Flutter 逻辑像素 = iOS pt；坐标是 FlutterView 全局坐标，窗口与
    // FlutterView 全屏叠加，直接换算到 root view。
    let point = root.convert(anchor, from: window)
    // 1×1 的锚点会让 targetRect 退化成零面积，菜单定位不稳；铺一个
    // 44×44 的透明热区（返回按钮同尺寸），菜单以按钮中心为锚。
    let side: CGFloat = 44
    let view = UIView(
      frame: CGRect(
        x: point.x - side / 2,
        y: point.y - side / 2,
        width: side,
        height: side
      )
    )
    view.backgroundColor = .clear
    root.addSubview(view)

    let interaction = UIEditMenuInteraction(delegate: self)
    view.addInteraction(interaction)
    self.anchorView = view
    self.interaction = interaction

    let config = UIEditMenuConfiguration(
      identifier: nil,
      sourcePoint: CGPoint(x: side / 2, y: side / 2)
    )
    interaction.presentEditMenu(with: config)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    return true
  }

  private func dismissMenu() {
    interaction?.dismissMenu()
    cleanupViews()
  }

  private func cleanupViews() {
    if let interaction, let anchorView {
      anchorView.removeInteraction(interaction)
    }
    anchorView?.removeFromSuperview()
    interaction = nil
    anchorView = nil
  }

  private func select(_ index: Int) {
    guard index >= 0 && index < titles.count else { return }
    channel?.invokeMethod("onBackMenuSelected", arguments: ["index": index])
    dismissMenu()
  }

  // MARK: - UIEditMenuInteractionDelegate

  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction,
    menuFor configuration: UIEditMenuConfiguration,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    let actions: [UIAction] = titles.enumerated().map { index, title in
      let current = index == currentIndex
      let attributes: UIAction.Attributes = current ? [.disabled] : []
      return UIAction(
        title: title,
        image: current ? UIImage(systemName: "checkmark") : nil,
        attributes: attributes
      ) { [weak self] _ in
        self?.select(index)
      }
    }
    return UIMenu(title: "", options: .displayInline, children: actions)
  }

  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction,
    targetRectFor configuration: UIEditMenuConfiguration
  ) -> CGRect {
    anchorView?.bounds ?? .zero
  }

  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction,
    willDismissMenuFor configuration: UIEditMenuConfiguration,
    animator: UIEditMenuInteractionAnimating
  ) {
    animator.addCompletion { [weak self] in
      self?.cleanupViews()
    }
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

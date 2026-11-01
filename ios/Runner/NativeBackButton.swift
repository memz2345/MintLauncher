import Flutter
import UIKit

/// 原生返回键平台视图（`mint/native_back_button`）。
///
/// iOS 26 用 `UIButton.Configuration.glass()` —— 系统自动处理玻璃底盘、
/// 高光、按压回弹，不需要我们再拿 `UIVisualEffectView` 拼一个圆。
/// 图标用 SF Symbol `chevron.backward`（iOS 26 导航栏返回键的样式）。
/// 长按用 `UIContextMenuInteraction`，由 UIKit 弹系统 context menu（竖向、
/// 原生玻璃），不再用 `UIEditMenuInteraction` 那种文本编辑菜单。
class NativeBackButtonFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NativeBackButtonView(
      frame: frame,
      viewId: viewId,
      args: args,
      messenger: messenger
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class NativeBackButtonView: NSObject, FlutterPlatformView,
  UIContextMenuInteractionDelegate
{
  private let button = UIButton(type: .system)
  private let channel: FlutterMethodChannel
  private let titles: [String]
  private let currentIndex: Int

  init(
    frame: CGRect,
    viewId: Int64,
    args: Any?,
    messenger: FlutterBinaryMessenger
  ) {
    let dict = args as? [String: Any] ?? [:]
    titles = dict["titles"] as? [String] ?? []
    currentIndex = dict["currentIndex"] as? Int ?? 0
    let glass = dict["glass"] as? Bool ?? true
    let dark = dict["dark"] as? Bool ?? false
    channel = FlutterMethodChannel(
      name: "mint/ios_back_button_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    button.frame = CGRect(origin: .zero, size: frame.size)
    button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    button.accessibilityLabel = "返回"
    // App 可以强制深/浅色（与系统设置不同）；把 Flutter 的亮度写进
    // traitCollection，glass 按钮和 SF Symbol 才会跟着 App 走。
    button.overrideUserInterfaceStyle = dark ? .dark : .light

    let foreground: UIColor = .label
    let image = UIImage(
      systemName: "chevron.backward",
      withConfiguration: UIImage.SymbolConfiguration(
        pointSize: 17,
        weight: .semibold
      )
    )

    if #available(iOS 26.0, *), glass {
      // 文档：iOS 26 的玻璃按钮用 UIButton.Configuration.glass()，
      // 不要自己叠 UIVisualEffectView。
      var config = UIButton.Configuration.glass()
      config.image = image
      config.baseForegroundColor = foreground
      config.cornerStyle = .capsule
      config.contentInsets = NSDirectionalEdgeInsets.zero
      button.configuration = config
    } else if #available(iOS 15.0, *) {
      var config = UIButton.Configuration.plain()
      config.image = image
      config.baseForegroundColor = foreground
      config.cornerStyle = .capsule
      config.contentInsets = NSDirectionalEdgeInsets.zero
      button.configuration = config
      if glass {
        button.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        button.layer.cornerRadius = frame.height / 2
        button.clipsToBounds = true
      }
    } else {
      button.setImage(image, for: .normal)
      button.tintColor = foreground
      if glass {
        button.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        button.layer.cornerRadius = frame.height / 2
        button.clipsToBounds = true
      }
    }

    button.addTarget(self, action: #selector(onTap), for: .touchUpInside)
    let interaction = UIContextMenuInteraction(delegate: self)
    button.addInteraction(interaction)
  }

  func view() -> UIView {
    button
  }

  @objc private func onTap() {
    channel.invokeMethod("onBackPressed", arguments: nil)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    UIContextMenuConfiguration(
      identifier: nil,
      previewProvider: nil
    ) { [weak self] _ in
      guard let self else { return nil }
      let actions = self.titles.enumerated().map { index, title in
        let current = index == self.currentIndex
        let attributes: UIAction.Attributes = current ? [.disabled] : []
        return UIAction(
          title: title,
          image: current ? UIImage(systemName: "checkmark") : nil,
          attributes: attributes
        ) { _ in
          self.channel.invokeMethod(
            "onBackMenuSelected",
            arguments: ["index": index]
          )
        }
      }
      return UIMenu(title: "", children: actions)
    }
  }
}

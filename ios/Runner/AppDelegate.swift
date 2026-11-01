import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // iOS 26 Liquid Glass 桥（悬浮底栏 / 返回键的系统玻璃）。
    if let registrar = self.registrar(forPlugin: "GlassBridge") {
      GlassBridge.register(with: registrar)
    }
    // 原生 UITabBarController 底栏（iOS 26 系统 Liquid Glass tab bar）。
    if let registrar = self.registrar(forPlugin: "NativeTabBarBridge") {
      NativeTabBarBridge.register(with: registrar)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

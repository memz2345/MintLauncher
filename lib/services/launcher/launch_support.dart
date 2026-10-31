import 'dart:io';

/// 平台游戏启动能力表。
///
/// 桌面（Windows/macOS/Linux）走 `Process.start(java)`；Android 走 FCL
/// 运行时（同进程 dex）。**iOS 尚未支持**：iOS 沙盒禁 fork/exec，JVM 必须
/// 像 PojavLauncher_iOS 那样同进程 `dlopen(libjvm)` + `JNI_CreateJavaVM`
/// 启动，还要解决 JIT 特权（AltStore/TrollStore）与 GLES→Metal 渲染
/// （MetalANGLE / gl4ES / OSMesa）—— 见 README「iOS」章节的落地路线。
/// 在能力到位之前，启动入口直接给出明确说明，而不是让用户撞上
/// Process.start 的沙盒报错。
class GameLaunchSupport {
  GameLaunchSupport._();

  /// [os] 取 `Platform.operatingSystem` 的值（windows/macos/linux/android/ios）。
  static bool supportedFor(String os) => os != 'ios';

  static bool get supported => supportedFor(Platform.operatingSystem);

  static String unsupportedReason(String os) => switch (os) {
    'ios' =>
      'iOS 游戏启动尚未实现：沙盒禁止 fork/exec，需要像 PojavLauncher_iOS '
          '那样在应用内集成 OpenJDK（同进程 JNI_CreateJavaVM）、解决 JIT '
          '特权与 GLES→Metal 渲染后才可启动。当前版本可正常浏览、下载、'
          '管理版本与模组。',
    _ => '当前平台不支持启动游戏。',
  };
}

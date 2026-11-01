import 'dart:convert';

/// CI / 截图钩子。
///
/// iOS 模拟器的 `SIMCTL_CHILD_*` 环境变量在 `simctl launch --console-pty`
/// 路径下没有传到 Dart（README「iOS」章节记录过），所以 iOS 截图的页面 /
/// 深色 / 长按返回菜单改用**沙盒文件**：CI 往 `Documents/mint_test_config.json`
/// 写一份配置，应用启动时读进来（正常构建没有这个文件，什么都不生效）。
class MintTestHooks {
  MintTestHooks._();

  /// 启动后自动推入的二级页（同 `--dart-define=MINT_TEST_PAGE`）。
  static String page = '';

  /// 'dark' / 'light' / ''（跟随设置）。
  static String themeMode = '';

  /// 启动后自动弹一次返回层级菜单（截图用）。必须 const 求值：
  /// 非 const 的 `bool.fromEnvironment` 在运行期退回默认值 false。
  static bool showBackMenu = const bool.fromEnvironment('MINT_TEST_BACK_MENU');

  static void loadJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return;
    final page = decoded['page'];
    if (page is String) MintTestHooks.page = page;
    final mode = decoded['themeMode'];
    if (mode is String) MintTestHooks.themeMode = mode;
    final menu = decoded['showBackMenu'];
    if (menu is bool) MintTestHooks.showBackMenu = menu;
  }

  /// 测试用：清空。
  static void reset() {
    page = '';
    themeMode = '';
    showBackMenu = false;
  }
}

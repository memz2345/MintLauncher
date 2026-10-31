import 'package:path_provider/path_provider.dart';

/// iOS 沙盒文档目录（getApplicationDocumentsDirectory）。独立成文件并在
/// main.dart 里注入 GameDir.iosDataDirLookup —— iOS 的进程 HOME 不保证
/// 可写（CI 模拟器上没有 HOME，相对路径直接 EROFS），数据必须落在文档
/// 目录；headless 的 e2e 工具链不 import Flutter，见 game_dir.dart。
Future<String?> iosDataDirLookup() async {
  return (await getApplicationDocumentsDirectory()).path;
}

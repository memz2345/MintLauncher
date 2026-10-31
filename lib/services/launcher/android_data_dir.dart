import 'package:flutter/services.dart';

/// Android 真机/模拟器的启动器数据目录查询（`mint/fcl dataDir`，
/// getExternalFilesDir）。独立成文件并在 main.dart 里注入
/// [GameDir.androidDataDirLookup]，让 `dart run` 的 headless 工具
/// （tool/e2e_*.dart）不经过 Flutter 就能复用 game_dir / 启动链路。
Future<String?> androidDataDirLookup() async {
  return await const MethodChannel('mint/fcl').invokeMethod<String>('dataDir');
}

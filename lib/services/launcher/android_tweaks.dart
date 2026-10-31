import 'package:flutter/services.dart';

/// Android 游戏体验微调（FCL MenuSetting 对应项的 Mint 版）。
///
/// 存储在原生侧 filesDir/game_tweaks.json，与游戏内菜单（`:game` 进程的
/// Compose 菜单）共用同一份；Dart 只通过 MethodChannel 读写，原生改完
/// 会广播 ACTION_TWEAKS 让后台游戏立刻生效。
class AndroidTweaks {
  const AndroidTweaks({
    this.lookSensitivity = 1.0,
    this.enableGyroscope = false,
    this.gyroscopeSensitivity = 10,
    this.invertGyroscopeX = false,
    this.invertGyroscopeY = false,
    this.showMemory = false,
    this.requestMaxRefreshRate = true,
    this.gyroscopeAvailable = false,
  });

  /// 捕获指针后拖动转视角的灵敏度倍率（0.2–3.0，1.0 = 默认手感）。
  final double lookSensitivity;

  /// 陀螺仪转视角总开关。
  final bool enableGyroscope;

  /// 陀螺仪灵敏度（1–50，FCL 默认 10）。
  final int gyroscopeSensitivity;
  final bool invertGyroscopeX;
  final bool invertGyroscopeY;

  /// FPS 下面叠一行 JVM 堆内存用量。
  final bool showMemory;

  /// 游戏运行时把屏幕切到同分辨率最高刷新率档。
  final bool requestMaxRefreshRate;

  /// 当前设备是否有陀螺仪传感器（原生侧探测，UI 用它禁用入口）。
  final bool gyroscopeAvailable;

  static const MethodChannel _channel = MethodChannel('mint/fcl');

  /// 灵敏度取值范围（与原生 GameTweaksSettings 对齐）。
  static const double minLookSensitivity = 0.2;
  static const double maxLookSensitivity = 3.0;

  factory AndroidTweaks.fromMap(Map<Object?, Object?> map) => AndroidTweaks(
    lookSensitivity: ((map['lookSensitivity'] as num?) ?? 1.0).toDouble().clamp(
      0.2,
      3.0,
    ),
    enableGyroscope: (map['enableGyroscope'] as bool?) ?? false,
    gyroscopeSensitivity: ((map['gyroscopeSensitivity'] as num?) ?? 10)
        .toInt()
        .clamp(1, 50),
    invertGyroscopeX: (map['invertGyroscopeX'] as bool?) ?? false,
    invertGyroscopeY: (map['invertGyroscopeY'] as bool?) ?? false,
    showMemory: (map['showMemory'] as bool?) ?? false,
    requestMaxRefreshRate: (map['requestMaxRefreshRate'] as bool?) ?? true,
    gyroscopeAvailable: (map['gyroscopeAvailable'] as bool?) ?? false,
  );

  /// 读当前设置。gyroscopeAvailable 由原生在返回前探测补上。
  static Future<AndroidTweaks> load() async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'tweaks.get',
      );
      return AndroidTweaks.fromMap(map ?? const {});
    } on PlatformException {
      return const AndroidTweaks();
    }
  }

  /// 部分更新：只带要改的字段，其余保持原样（原生侧合并）。
  static Future<void> save(AndroidTweaks next) async {
    try {
      await _channel.invokeMethod<bool>('tweaks.set', {
        'lookSensitivity': next.lookSensitivity,
        'enableGyroscope': next.enableGyroscope,
        'gyroscopeSensitivity': next.gyroscopeSensitivity,
        'invertGyroscopeX': next.invertGyroscopeX,
        'invertGyroscopeY': next.invertGyroscopeY,
        'showMemory': next.showMemory,
        'requestMaxRefreshRate': next.requestMaxRefreshRate,
      });
    } on PlatformException {
      // 通道不可用（非 Android / 未接好）时静默失败，UI 不该为此崩溃。
    }
  }

  AndroidTweaks copyWith({
    double? lookSensitivity,
    bool? enableGyroscope,
    int? gyroscopeSensitivity,
    bool? invertGyroscopeX,
    bool? invertGyroscopeY,
    bool? showMemory,
    bool? requestMaxRefreshRate,
  }) => AndroidTweaks(
    lookSensitivity: lookSensitivity ?? this.lookSensitivity,
    enableGyroscope: enableGyroscope ?? this.enableGyroscope,
    gyroscopeSensitivity: gyroscopeSensitivity ?? this.gyroscopeSensitivity,
    invertGyroscopeX: invertGyroscopeX ?? this.invertGyroscopeX,
    invertGyroscopeY: invertGyroscopeY ?? this.invertGyroscopeY,
    showMemory: showMemory ?? this.showMemory,
    requestMaxRefreshRate: requestMaxRefreshRate ?? this.requestMaxRefreshRate,
    gyroscopeAvailable: gyroscopeAvailable,
  );

  String sensitivityLabel() => '${(lookSensitivity * 100).round()}%';
}

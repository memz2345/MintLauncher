import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/src/enums.dart';
import 'package:mint/services/app_locale_bridge.dart';
import 'package:mint/services/native_toast_service.dart';
import 'package:mint/services/vtouch/vtouch_layout.dart'
    show VTouchControl, migrateVTouchLabels, vtouchDefaults;
import 'launcher/account.dart' show OfflineAccount;

/// 截图/回归钩子的取值：dart-define 优先，同名环境变量兜底（CI 冒烟
/// 用同一个二进制反复拉起截不同场景，不用重编）。
String envHook(String defined, String envName) {
  if (defined.isNotEmpty) return defined;
  return Platform.environment[envName] ?? '';
}

/// 单个版本的启动设置覆盖（HMCL 的「版本特定设置」同思路）：
/// 字段为 null = 跟随全局设置。
class VersionSettings {
  VersionSettings({
    this.memoryMb,
    this.javaPath,
    this.isolation,
    this.jvmArgs,
    this.envVars,
    this.serverAddress,
    this.serverPort,
    this.width,
    this.height,
    this.verifyFiles,
    this.graphicsBackend,
    this.gpuPreference,
    this.extraGameArgs,
    this.preLaunchCommand,
    this.preLaunchWait,
    this.gcPreset,
  });

  /// 最大内存（MB）。
  int? memoryMb;

  /// 自定义 Java 可执行文件路径（空串 = 自动）。
  String? javaPath;

  /// 版本隔离（存档/配置/模组等放在 `versions/<id>` 下）。
  bool? isolation;

  /// 额外 JVM 参数（一行一个）。
  String? jvmArgs;

  /// 环境变量（一行一个 `KEY=VALUE`）。
  String? envVars;

  /// 启动后自动连接的服务器地址（空 = 不连）。
  String? serverAddress;
  int? serverPort;

  int? width;
  int? height;

  /// 关闭文件完整性校验（PCL2 `VersionAdvanceAssetsV2`）：已有文件直接信任，
  /// 只补缺失文件。
  bool? verifyFiles;

  /// 强制图形后端 id（auto / opengl / vulkan / cpu，null = 跟随全局）。
  String? graphicsBackend;

  /// 渲染显卡偏好 id（'' = 自动 / power / high / adapter:VEN&DEV&SUBSYS）。
  /// null = 跟随全局；空串 = 显式选「自动」，和「跟随」不是一回事。
  String? gpuPreference;

  /// 追加到版本 JSON 游戏参数之后（一行一个，支持空格切分）。
  String? extraGameArgs;

  /// 启动前命令（`cmd /c`，在游戏主目录执行）。
  String? preLaunchCommand;

  /// 启动前命令是否等待结束。
  bool? preLaunchWait;

  /// GC 预设 id（null = 跟随全局）。
  String? gcPreset;

  bool get isEmpty =>
      memoryMb == null &&
      (javaPath == null || javaPath!.isEmpty) &&
      isolation == null &&
      (jvmArgs == null || jvmArgs!.isEmpty) &&
      (envVars == null || envVars!.isEmpty) &&
      (serverAddress == null || serverAddress!.isEmpty) &&
      width == null &&
      height == null &&
      verifyFiles == null &&
      (graphicsBackend == null || graphicsBackend!.isEmpty) &&
      gpuPreference == null &&
      (extraGameArgs == null || extraGameArgs!.isEmpty) &&
      (preLaunchCommand == null || preLaunchCommand!.isEmpty) &&
      preLaunchWait == null &&
      (gcPreset == null || gcPreset!.isEmpty);

  Map<String, dynamic> toJson() => {
    if (memoryMb != null) 'memoryMb': memoryMb,
    if (javaPath != null) 'javaPath': javaPath,
    if (isolation != null) 'isolation': isolation,
    if (jvmArgs != null) 'jvmArgs': jvmArgs,
    if (envVars != null) 'envVars': envVars,
    if (serverAddress != null) 'serverAddress': serverAddress,
    if (serverPort != null) 'serverPort': serverPort,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (verifyFiles != null) 'verifyFiles': verifyFiles,
    if (graphicsBackend != null) 'graphicsBackend': graphicsBackend,
    if (gpuPreference != null) 'gpuPreference': gpuPreference,
    if (extraGameArgs != null) 'extraGameArgs': extraGameArgs,
    if (preLaunchCommand != null) 'preLaunchCommand': preLaunchCommand,
    if (preLaunchWait != null) 'preLaunchWait': preLaunchWait,
    if (gcPreset != null) 'gcPreset': gcPreset,
  };

  factory VersionSettings.fromJson(Map<String, dynamic> json) =>
      VersionSettings(
        memoryMb: (json['memoryMb'] as num?)?.toInt(),
        javaPath: json['javaPath'] as String?,
        isolation: json['isolation'] as bool?,
        jvmArgs: json['jvmArgs'] as String?,
        envVars: json['envVars'] as String?,
        serverAddress: json['serverAddress'] as String?,
        serverPort: (json['serverPort'] as num?)?.toInt(),
        width: (json['width'] as num?)?.toInt(),
        height: (json['height'] as num?)?.toInt(),
        verifyFiles: json['verifyFiles'] as bool?,
        graphicsBackend: json['graphicsBackend'] as String?,
        gpuPreference: json['gpuPreference'] as String?,
        extraGameArgs: json['extraGameArgs'] as String?,
        preLaunchCommand: json['preLaunchCommand'] as String?,
        preLaunchWait: json['preLaunchWait'] as bool?,
        gcPreset: json['gcPreset'] as String?,
      );

  VersionSettings copy() => VersionSettings.fromJson(toJson());
}

/// `effectiveFor` 的返回类型：全局 + 版本覆盖合并后的启动参数。
typedef EffectiveVersionSettings = ({
  int memoryMb,
  bool memoryAuto,
  String javaPath,
  bool isolation,
  String jvmArgs,
  String envVars,
  String serverAddress,
  bool verifyFiles,
  GraphicsBackend graphicsBackend,
  String gpuPreference,
  String extraGameArgs,
  String preLaunchCommand,
  bool preLaunchWait,
  GcPreset gcPreset,
  int? width,
  int? height,
});

/// 应用设置：外观（双风格共用）+ 启动器配置（游戏目录/Java/内存/下载源/账户）。
///
/// local2api SettingsService 的精简版：外观项逐键持久化；启动器配置收进一个
/// JSON blob，账户列表与每版本设置也放里面，读写一次到位。
class SettingsService extends ChangeNotifier {
  /// 转场里有自定义旧页面退场的页面全局开关（ios_push_transition 读这里）。
  static bool heroTransitionBlurEnabled = true;

  static const _prefix = 'mint.';

  static const _prefKeyPrefix = 'settings.';

  Future<SharedPreferences>? _prefsFuture;

  SettingsService() {
    _prefsFuture = SharedPreferences.getInstance();
  }

  Future<void> load() async {
    final prefs = await _prefsFuture!;
    _uiStyle = UiStyleX.fromId(prefs.getString('${_prefKeyPrefix}uiStyle'));
    // 截图/回归钩子：不改持久化值，只影响本次运行。dart-define 优先，
    // CI 冒烟可用同名环境变量（一个二进制截三种界面风格）。
    final uiOverride = envHook(
      const String.fromEnvironment('MINT_UI_STYLE'),
      'MINT_UI_STYLE',
    );
    if (uiOverride == 'miuix') _uiStyle = UiStyle.miuix;
    if (uiOverride == 'material') _uiStyle = UiStyle.materialExpressive;
    if (uiOverride == 'fluent') _uiStyle = UiStyle.fluent;
    _themeMode =
        ThemeMode.values.asNameMap()[prefs.getString(
          '${_prefKeyPrefix}themeMode',
        )] ??
        ThemeMode.system;
    // 截图/回归钩子：不改持久化值，只影响本次运行。
    final themeOverride = envHook(
      const String.fromEnvironment('MINT_THEME_MODE'),
      'MINT_THEME_MODE',
    );
    if (themeOverride == 'light') _themeMode = ThemeMode.light;
    if (themeOverride == 'dark') _themeMode = ThemeMode.dark;
    _useDynamicColor =
        prefs.getBool('${_prefKeyPrefix}useDynamicColor') ?? _useDynamicColor;
    _isPureBlackMode =
        prefs.getBool('${_prefKeyPrefix}isPureBlackMode') ?? _isPureBlackMode;
    _fontWeight = prefs.getDouble('${_prefKeyPrefix}fontWeight') ?? _fontWeight;
    _displayScale =
        prefs.getDouble('${_prefKeyPrefix}displayScale') ?? _displayScale;
    _cornerRadius =
        prefs.getDouble('${_prefKeyPrefix}cornerRadius') ?? _cornerRadius;
    final seed = prefs.getInt('${_prefKeyPrefix}themeSeedColor');
    if (seed != null) _themeSeedColor = Color(seed);
    _windowEffect = WindowBackdropMode.fromId(
      prefs.getString('${_prefKeyPrefix}windowEffect'),
    );
    _backdropTint =
        prefs.getDouble('${_prefKeyPrefix}backdropTint') ?? _backdropTint;
    _edgeScrollHaptic =
        prefs.getBool('${_prefKeyPrefix}edgeScrollHaptic') ?? _edgeScrollHaptic;
    _progressiveTopBar =
        prefs.getBool('${_prefKeyPrefix}progressiveTopBar') ??
        _progressiveTopBar;
    _iosLiquidGlass =
        prefs.getBool('${_prefKeyPrefix}iosLiquidGlass') ?? _iosLiquidGlass;
    _iosGlassBackBackground =
        prefs.getBool('${_prefKeyPrefix}iosGlassBackBackground') ??
        _iosGlassBackBackground;
    // 截图/回归钩子：--dart-define=MINT_WINDOW_EFFECT=mica|acrylic|...
    // （CI 冒烟同样接受同名环境变量）。
    final effectOverride = envHook(
      const String.fromEnvironment('MINT_WINDOW_EFFECT'),
      'MINT_WINDOW_EFFECT',
    );
    if (effectOverride.isNotEmpty) {
      _windowEffect = WindowBackdropMode.fromId(effectOverride);
    }

    // 启动器配置（JSON blob）
    final blob = prefs.getString('${_prefix}launcher_config');
    if (blob != null) {
      try {
        _applyLauncherConfig(jsonDecode(blob) as Map<String, dynamic>);
      } catch (_) {
        // 配置坏了就走默认值，别把应用挡在启动页外。
      }
    }
    _loaded = true;
    notifyListeners();
  }

  bool _loaded = false;
  bool get loaded => _loaded;

  // ───────────────────────── 外观 ─────────────────────────

  UiStyle _uiStyle = UiStyle.miuix;
  UiStyle get uiStyle => _uiStyle;
  Future<void> setUiStyle(UiStyle value) async {
    if (_uiStyle == value) return;
    _uiStyle = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setString('${_prefKeyPrefix}uiStyle', value.id);
  }

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;
  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setString('${_prefKeyPrefix}themeMode', value.name);
  }

  bool _useDynamicColor = false;
  bool get useDynamicColor => _useDynamicColor;
  Future<void> setUseDynamicColor(bool value) async {
    if (_useDynamicColor == value) return;
    _useDynamicColor = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setBool('${_prefKeyPrefix}useDynamicColor', value);
  }

  bool _isPureBlackMode = false;
  bool get isPureBlackMode => _isPureBlackMode;
  Future<void> setIsPureBlackMode(bool value) async {
    if (_isPureBlackMode == value) return;
    _isPureBlackMode = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setBool('${_prefKeyPrefix}isPureBlackMode', value);
  }

  double _fontWeight = 400;
  double get fontWeight => _fontWeight;
  Future<void> setFontWeight(double value) async {
    if (_fontWeight == value) return;
    _fontWeight = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setDouble('${_prefKeyPrefix}fontWeight', value);
  }

  double _displayScale = 1.0;
  double get displayScale => _displayScale;
  Future<void> setDisplayScale(double value) async {
    if (_displayScale == value) return;
    _displayScale = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setDouble('${_prefKeyPrefix}displayScale', value);
  }

  double _cornerRadius = 26.0;
  double get cornerRadius => _cornerRadius;
  Future<void> setCornerRadius(double value) async {
    if (_cornerRadius == value) return;
    _cornerRadius = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setDouble('${_prefKeyPrefix}cornerRadius', value);
  }

  Color _themeSeedColor = const Color(0xFF4C6FFF);
  Color get themeSeedColor => _themeSeedColor;
  Future<void> setThemeSeedColor(Color value) async {
    if (_themeSeedColor.toARGB32() == value.toARGB32()) return;
    _themeSeedColor = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setInt('${_prefKeyPrefix}themeSeedColor', value.toARGB32());
  }

  // ─────────────── 触觉反馈（到顶/底轻震，local2api EdgeScrollHaptic） ───────────────

  bool _edgeScrollHaptic = true;
  bool get edgeScrollHaptic => _edgeScrollHaptic;
  Future<void> setEdgeScrollHaptic(bool value) async {
    if (_edgeScrollHaptic == value) return;
    _edgeScrollHaptic = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setBool('${_prefKeyPrefix}edgeScrollHaptic', value);
  }

  // ─────────────── 渐变模糊顶栏（local2api / AppMarket 同款） ───────────────

  /// 顶栏透明化 + 顶部渐进模糊随内容滚入淡入。默认开（用户点名要默认启用）。
  ///
  /// 渲染路径跑不了 fragment shader 时（软件渲染 / 老 GLES）组件会自己退化成
  /// 均匀 `BackdropFilter`，所以这里不必再判平台。
  bool _progressiveTopBar = true;
  bool get progressiveTopBar => _progressiveTopBar;
  Future<void> setProgressiveTopBar(bool value) async {
    if (_progressiveTopBar == value) return;
    _progressiveTopBar = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setBool('${_prefKeyPrefix}progressiveTopBar', value);
  }

  // ─────────────── iOS 26 系统液态玻璃（底栏 / 返回键） ───────────────

  /// 悬浮底栏用系统 Liquid Glass（UIGlassEffect）替代 Flutter 自绘毛玻璃。
  /// 仅 iOS 26+ 生效（能力探测不过时组件自动走自绘降级），默认开。
  bool _iosLiquidGlass = true;
  bool get iosLiquidGlass => _iosLiquidGlass;
  Future<void> setIosLiquidGlass(bool value) async {
    if (_iosLiquidGlass == value) return;
    _iosLiquidGlass = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setBool('${_prefKeyPrefix}iosLiquidGlass', value);
  }

  /// 返回键的玻璃底是否铺（**可选**：关掉就是裸返回箭头，和系统小布局
  /// 一致）。仅在 [iosLiquidGlass] 开启时有意义。
  bool _iosGlassBackBackground = true;
  bool get iosGlassBackBackground => _iosGlassBackBackground;
  Future<void> setIosGlassBackBackground(bool value) async {
    if (_iosGlassBackBackground == value) return;
    _iosGlassBackBackground = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setBool('${_prefKeyPrefix}iosGlassBackBackground', value);
  }

  // ───────────────────── 窗口背景（Windows 10+） ─────────────────────

  WindowBackdropMode _windowEffect = WindowBackdropMode.mica;
  WindowBackdropMode get windowEffect => _windowEffect;
  Future<void> setWindowEffect(WindowBackdropMode value) async {
    if (_windowEffect == value) return;
    _windowEffect = value;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setString('${_prefKeyPrefix}windowEffect', value.id);
  }

  /// 玻璃底色的不透明度（0.2–0.95）。太低时浅色壁纸上正文会发灰。
  double _backdropTint = 0.48;
  double get backdropTint => _backdropTint;
  Future<void> setBackdropTint(double value) async {
    final v = value.clamp(0.2, 0.95);
    if ((_backdropTint - v).abs() < 0.001) return;
    _backdropTint = v;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setDouble('${_prefKeyPrefix}backdropTint', v);
  }

  // ─────────────────── 桌面虚拟触控（Windows 悬浮层） ───────────────────
  //
  // 布局模型与 Android ControlLayout JSON 字段同名，两平台格式互通。
  // 悬浮子窗口不直接读写 SharedPreferences（两个引擎各有一份内存缓存，
  // 互写会互相覆盖），布局编辑经 WindowMethodChannel 回主引擎走这里的
  // setter 落盘。

  bool _vtouchEnabled = false;
  bool get vtouchEnabled => _vtouchEnabled;
  set vtouchEnabled(bool value) {
    if (_vtouchEnabled == value) return;
    _vtouchEnabled = value;
    _persistLauncherConfig();
  }

  /// 启动游戏后自动唤起悬浮层。
  bool _vtouchAutoShow = true;
  bool get vtouchAutoShow => _vtouchAutoShow;
  set vtouchAutoShow(bool value) {
    if (_vtouchAutoShow == value) return;
    _vtouchAutoShow = value;
    _persistLauncherConfig();
  }

  /// 悬浮层整体不透明度（0.25–1；原生走 WS_EX_LAYERED 的整窗 alpha）。
  double _vtouchAlpha = 0.9;
  double get vtouchAlpha => _vtouchAlpha;
  set vtouchAlpha(double value) {
    final v = value.clamp(0.25, 1.0);
    if ((_vtouchAlpha - v).abs() < 0.001) return;
    _vtouchAlpha = v;
    _persistLauncherConfig();
  }

  /// 按键全局缩放（0.7–1.6，与 Android ControlLayout.scale 同语义）。
  double _vtouchScale = 1.0;
  double get vtouchScale => _vtouchScale;
  set vtouchScale(double value) {
    final v = value.clamp(0.7, 1.6);
    if ((_vtouchScale - v).abs() < 0.001) return;
    _vtouchScale = v;
    _persistLauncherConfig();
  }

  /// 自定义布局；null = 用内置默认（vtouchDefaults）。
  List<VTouchControl>? _vtouchLayout;
  List<VTouchControl> getVTouchLayout() => [
    for (final c in _vtouchLayout ?? vtouchDefaults()) c.copy(),
  ];
  set vtouchLayout(List<VTouchControl> value) {
    _vtouchLayout = [for (final c in value) c.copy()];
    _persistLauncherConfig();
  }

  /// 游戏内菜单球位置（归一化，可拖动）。
  double _vtouchBallX = 0.955;
  double get vtouchBallX => _vtouchBallX;
  double _vtouchBallY = 0.05;
  double get vtouchBallY => _vtouchBallY;

  void setVTouchBall(double nx, double ny) {
    final x = nx.clamp(0.05, 0.95);
    final y = ny.clamp(0.04, 0.96);
    if ((_vtouchBallX - x).abs() < 0.001 && (_vtouchBallY - y).abs() < 0.001) {
      return;
    }
    _vtouchBallX = x;
    _vtouchBallY = y;
    _persistLauncherConfig();
  }

  // ─────────────────────── 启动器配置 ───────────────────────

  /// 游戏根目录（.minecraft）。空 = 用默认：`<launcher>/minecraft`。
  String _gameDir = '';
  String get gameDir => _gameDir;
  set gameDir(String value) => setActiveGameDir(value);

  /// 已登记的游戏目录（HMCL「游戏目录」/ FCL「Profile」同思路）。
  /// 第一个不一定是默认目录；当前目录以 [gameDir] 为准。
  List<String> _gameDirs = [];
  List<String> get gameDirs => List.unmodifiable(_gameDirs);

  bool _samePath(String a, String b) =>
      p.equals(p.normalize(a), p.normalize(b));

  String _normalizeDir(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    return p.normalize(trimmed);
  }

  /// 登记一个目录（不切换）。用于启动时把解析出的默认目录补进列表。
  void registerGameDir(String value) {
    final path = _normalizeDir(value);
    if (path.isEmpty) return;
    var changed = false;
    if (!_gameDirs.any((d) => _samePath(d, path))) {
      _gameDirs.add(path);
      changed = true;
    }
    if (_gameDir.isEmpty) {
      _gameDir = path;
      _selectedVersion = _selectedVersionByDir[path] ?? _legacySelectedVersion;
      changed = true;
    }
    if (_gameDir.isNotEmpty &&
        !_selectedVersionByDir.keys.any((d) => _samePath(d, _gameDir)) &&
        _selectedVersion.isNotEmpty) {
      _selectedVersionByDir[_gameDir] = _selectedVersion;
      changed = true;
    }
    if (changed) _persistLauncherConfig();
  }

  /// 添加目录并切过去。
  void addGameDir(String value) {
    final path = _normalizeDir(value);
    if (path.isEmpty) return;
    var changed = false;
    if (!_gameDirs.any((d) => _samePath(d, path))) {
      _gameDirs.add(path);
      changed = true;
    }
    if (!_samePath(_gameDir, path)) {
      if (_gameDir.isNotEmpty) {
        _selectedVersionByDir[_gameDir] = _selectedVersion;
      }
      _gameDir = path;
      _selectedVersion = _selectedVersionByDir[path] ?? '';
      changed = true;
    }
    if (changed) _persistLauncherConfig();
  }

  /// 从列表移除目录（不删文件）。移除当前目录时切到列表里的下一个。
  void removeGameDir(String value) {
    final path = _normalizeDir(value);
    if (path.isEmpty) return;
    _gameDirs.removeWhere((d) => _samePath(d, path));
    _selectedVersionByDir.removeWhere((d, _) => _samePath(d, path));
    if (_samePath(_gameDir, path)) {
      _gameDir = _gameDirs.isEmpty ? '' : _gameDirs.first;
      _selectedVersion = _gameDir.isEmpty
          ? ''
          : (_selectedVersionByDir[_gameDir] ?? '');
    }
    _persistLauncherConfig();
  }

  /// 切换当前游戏目录；每个目录各记各的选中版本。
  void setActiveGameDir(String value) {
    final path = _normalizeDir(value);
    if (path.isEmpty || _samePath(_gameDir, path)) return;
    if (_gameDir.isNotEmpty) {
      _selectedVersionByDir[_gameDir] = _selectedVersion;
    }
    _gameDir = path;
    _selectedVersion = _selectedVersionByDir[path] ?? '';
    if (!_gameDirs.any((d) => _samePath(d, path))) _gameDirs.add(path);
    _persistLauncherConfig();
  }

  /// 目录显示名（HMCL 用最后一级目录名）。
  String gameDirName(String path) {
    final base = p.basename(p.normalize(path));
    return base.isEmpty ? path : base;
  }

  /// 自定义 Java 可执行文件路径。空 = 自动检测。
  String _javaPath = '';
  String get javaPath => _javaPath;
  set javaPath(String value) {
    if (_javaPath == value) return;
    _javaPath = value;
    _persistLauncherConfig();
  }

  /// 全局版本隔离开关（单版本可在 VersionSettings.isolation 覆盖）。
  ///
  /// PCL2 `LaunchArgumentIndieV2` 五档 + mods/saves 自动检测：版本目录下
  /// 已有 mods（含文件）或 saves（含子目录）的版本无论选哪档都隔离。
  IsolationMode _isolationMode = IsolationMode.off;
  IsolationMode get isolationMode => _isolationMode;
  set isolationMode(IsolationMode value) {
    if (_isolationMode == value) return;
    _isolationMode = value;
    _persistLauncherConfig();
  }

  /// 旧布尔开关的桥接（true = 全部隔离，false = 关闭），老代码兼容用。
  bool get versionIsolation => _isolationMode == IsolationMode.all;
  set versionIsolation(bool value) =>
      isolationMode = value ? IsolationMode.all : IsolationMode.off;

  /// 版本画像探针：由 LauncherController.init 注入（读版本目录与 json），
  /// SettingsService 自己不碰磁盘。测试里可以换成假实现。
  static VersionFacts? Function(String versionId)? versionFactsProbe;

  /// 解析某版本是否隔离：单版本覆盖 > mods/saves 自动 > 全局模式。
  bool isolationFor(String versionId, {bool? override}) {
    if (override != null) return override;
    final vs = _readVersionSettings(versionId, _gameDir);
    if (vs?.isolation != null) return vs!.isolation!;
    final facts = versionFactsProbe?.call(versionId);
    // PCL2 PathIndie：版本目录下有 mods / saves → 无条件隔离。
    if (facts != null && facts.hasOwnGameData) return true;
    return switch (_isolationMode) {
      IsolationMode.off => false,
      IsolationMode.all => true,
      IsolationMode.loaders => facts?.modable ?? false,
      IsolationMode.oldSnapshots => facts?.oldOrSnapshot ?? false,
      IsolationMode.oldAndLoaders =>
        (facts?.modable ?? false) || (facts?.oldOrSnapshot ?? false),
    };
  }

  // ---- 页面背景（PageBackground 组件读取；local2api 同款思路）----
  String _pageBackgroundPath = '';
  bool _pageBackgroundEnabled = false;
  double _pageBackgroundOpacity = 0.22;
  double _pageBackgroundBlur = 8;

  /// 背景图片路径（空 = 没选）。只在 [pageBackgroundEnabled] 时渲染。
  String get pageBackgroundPath => _pageBackgroundPath;
  set pageBackgroundPath(String value) {
    if (_pageBackgroundPath == value) return;
    _pageBackgroundPath = value;
    _persistLauncherConfig();
  }

  bool get pageBackgroundEnabled => _pageBackgroundEnabled;
  set pageBackgroundEnabled(bool value) {
    if (_pageBackgroundEnabled == value) return;
    _pageBackgroundEnabled = value;
    _persistLauncherConfig();
  }

  /// 图片层整体不透明度（0~1）。
  double get pageBackgroundOpacity => _pageBackgroundOpacity;
  set pageBackgroundOpacity(double value) {
    final v = value.clamp(0.0, 1.0);
    if (_pageBackgroundOpacity == v) return;
    _pageBackgroundOpacity = v;
    _persistLauncherConfig();
  }

  /// 图片层高斯模糊（0~24）。
  double get pageBackgroundBlur => _pageBackgroundBlur;
  set pageBackgroundBlur(double value) {
    final v = value.clamp(0.0, 24.0);
    if (_pageBackgroundBlur == v) return;
    _pageBackgroundBlur = v;
    _persistLauncherConfig();
  }

  // ---- 按页背景（mtz 背景预览器把某张图指定到某个页面 / 底部弹窗）----
  // key 是 MintPageBackgroundKey 的 id（home / download / … / sheet），
  // value 是图片绝对路径。没指定的页面回落到全局自定义背景 / 主题壁纸。
  Map<String, String> _pageBackgroundAssignments = {};

  Map<String, String> get pageBackgroundAssignments =>
      Map.unmodifiable(_pageBackgroundAssignments);

  /// 某个页面键当前指定的背景路径（空 = 没指定）。
  String pageBackgroundFor(String key) => _pageBackgroundAssignments[key] ?? '';

  void setPageBackground(String key, String path) {
    if (path.isEmpty) {
      if (!_pageBackgroundAssignments.containsKey(key)) return;
      _pageBackgroundAssignments = Map.of(_pageBackgroundAssignments)
        ..remove(key);
    } else {
      if (_pageBackgroundAssignments[key] == path) return;
      _pageBackgroundAssignments = Map.of(_pageBackgroundAssignments)
        ..[key] = path;
    }
    _persistLauncherConfig();
  }

  // ---- 「下载其他文件」的默认目录（下载器 → 下载其他文件流程记忆）----
  String _otherDownloadDir = '';

  String get otherDownloadDir => _otherDownloadDir;
  set otherDownloadDir(String value) {
    if (_otherDownloadDir == value) return;
    _otherDownloadDir = value;
    _persistLauncherConfig();
  }

  // ---- 云雾前景（MintCloudForeground 读取；Kimi K3.1 页头同风格）----
  bool _cloudForeground = true;
  double _cloudOpacity = 0.55;
  double _cloudDensity = 0.5;

  /// 主页之上的白色云雾装饰层。默认开（透明度被压得很低，属氛围层）。
  bool get cloudForeground => _cloudForeground;
  set cloudForeground(bool value) {
    if (_cloudForeground == value) return;
    _cloudForeground = value;
    _persistLauncherConfig();
  }

  /// 云雾不透明度（0~1）。深浅主题会各自打折+封顶（见
  /// widgets/mint_cloud_foreground.dart 的 cloudEffectiveOpacity）。
  double get cloudOpacity => _cloudOpacity;
  set cloudOpacity(double value) {
    final v = value.clamp(0.0, 1.0);
    if (_cloudOpacity == v) return;
    _cloudOpacity = v;
    _persistLauncherConfig();
  }

  /// 云团密度（0~1）→ blob 数量。
  double get cloudDensity => _cloudDensity;
  set cloudDensity(double value) {
    final v = value.clamp(0.0, 1.0);
    if (_cloudDensity == v) return;
    _cloudDensity = v;
    _persistLauncherConfig();
  }

  // ---- 音量条（Android：应用内画主题的音量柱，见 services/volume_bar_service.dart）----
  bool _volumeUseThemeBar = false;

  /// 调节系统音量时在应用内显示主题的音量条。没有套用主题时这个开关不可用。
  bool get volumeUseThemeBar => _volumeUseThemeBar;
  set volumeUseThemeBar(bool value) {
    if (_volumeUseThemeBar == value) return;
    _volumeUseThemeBar = value;
    _persistLauncherConfig();
  }

  // ---- 关于页「高级设置」（纹理集）：原样存 TextureSetState.toMap ----
  Map<String, Object?> _textureSettings = const {};

  Map<String, Object?> get textureSettings => _textureSettings;
  set textureSettings(Map<String, Object?> value) {
    _textureSettings = value;
    _persistLauncherConfig();
  }

  // ---- MIUI 主题包（MintThemeLibrary 导入；这里只存「应用哪个 + 用哪些部分」）----
  String _activeThemeId = '';
  bool _themeUseWallpaper = true;
  bool _themeUseAccent = true;
  bool _themeUseFont = true;
  bool _themeUseBootAnimation = true;

  /// 正在应用的 mtz 主题 id（空 = 用启动器自己的外观）。
  String get activeThemeId => _activeThemeId;

  bool get themeUseWallpaper => _themeUseWallpaper;
  set themeUseWallpaper(bool value) {
    if (_themeUseWallpaper == value) return;
    _themeUseWallpaper = value;
    _persistLauncherConfig();
  }

  bool get themeUseAccent => _themeUseAccent;
  set themeUseAccent(bool value) {
    if (_themeUseAccent == value) return;
    _themeUseAccent = value;
    _persistLauncherConfig();
  }

  bool get themeUseFont => _themeUseFont;
  set themeUseFont(bool value) {
    if (_themeUseFont == value) return;
    _themeUseFont = value;
    _persistLauncherConfig();
  }

  bool get themeUseBootAnimation => _themeUseBootAnimation;
  set themeUseBootAnimation(bool value) {
    if (_themeUseBootAnimation == value) return;
    _themeUseBootAnimation = value;
    _persistLauncherConfig();
  }

  /// 应用 / 停用一个主题包。`hasXxx` 是主题实际声明的模块：没声明的部分
  /// 自动关掉开关，避免出现「开关开着但什么都没发生」。
  Future<void> applyThemePackage(
    String id, {
    bool hasWallpaper = false,
    bool hasAccent = false,
    bool hasFont = false,
    bool hasBootAnimation = false,
  }) async {
    _activeThemeId = id;
    _themeUseWallpaper = hasWallpaper;
    _themeUseAccent = hasAccent;
    _themeUseFont = hasFont;
    _themeUseBootAnimation = hasBootAnimation;
    await _persistLauncherConfig();
  }

  /// 额外 JVM 参数（全局，每版本可覆盖；一行一个）。
  String _jvmArgs = '';
  String get jvmArgs => _jvmArgs;
  set jvmArgs(String value) {
    if (_jvmArgs == value) return;
    _jvmArgs = value;
    _persistLauncherConfig();
  }

  /// 环境变量（全局，每版本可覆盖；一行一个 `KEY=VALUE`）。
  String _envVars = '';
  String get envVars => _envVars;
  set envVars(String value) {
    if (_envVars == value) return;
    _envVars = value;
    _persistLauncherConfig();
  }

  /// 启动后自动连接的服务器（全局兜底；host 可带 :port）。
  String _serverAddress = '';
  String get serverAddress => _serverAddress;
  set serverAddress(String value) {
    if (_serverAddress == value) return;
    _serverAddress = value;
    _persistLauncherConfig();
  }

  /// 追加到版本 JSON 游戏参数之后的自定义参数（一行一个）。
  String _extraGameArgs = '';
  String get extraGameArgs => _extraGameArgs;
  set extraGameArgs(String value) {
    if (_extraGameArgs == value) return;
    _extraGameArgs = value;
    _persistLauncherConfig();
  }

  /// 启动前命令（PCL2 `LaunchAdvanceRun`，`cmd /c` 在工作目录执行）。
  String _preLaunchCommand = '';
  String get preLaunchCommand => _preLaunchCommand;
  set preLaunchCommand(String value) {
    if (_preLaunchCommand == value) return;
    _preLaunchCommand = value;
    _persistLauncherConfig();
  }

  bool _preLaunchWait = true;
  bool get preLaunchWait => _preLaunchWait;
  set preLaunchWait(bool value) {
    if (_preLaunchWait == value) return;
    _preLaunchWait = value;
    _persistLauncherConfig();
  }

  /// 启动后启动器可见性（PCL2 `LaunchArgumentVisible`）。
  LauncherVisibility _launcherVisibility = LauncherVisibility.keep;
  LauncherVisibility get launcherVisibility => _launcherVisibility;
  set launcherVisibility(LauncherVisibility value) {
    if (_launcherVisibility == value) return;
    _launcherVisibility = value;
    _persistLauncherConfig();
  }

  /// 游戏进程优先级（Windows 生效）。
  ProcessPriority _processPriority = ProcessPriority.normal;
  ProcessPriority get processPriority => _processPriority;
  set processPriority(ProcessPriority value) {
    if (_processPriority == value) return;
    _processPriority = value;
    _persistLauncherConfig();
  }

  /// 强制图形后端（HMCL 图形设置的精简版）。
  GraphicsBackend _graphicsBackend = GraphicsBackend.auto;
  GraphicsBackend get graphicsBackend => _graphicsBackend;
  set graphicsBackend(GraphicsBackend value) {
    if (_graphicsBackend == value) return;
    _graphicsBackend = value;
    _persistLauncherConfig();
  }

  /// 渲染显卡偏好（Windows 的每应用图形设置；'' = 交给系统决定）。
  String _gpuPreference = '';
  String get gpuPreference => _gpuPreference;
  set gpuPreference(String value) {
    if (_gpuPreference == value) return;
    _gpuPreference = value;
    _persistLauncherConfig();
  }

  /// Android 渲染器（FCL RendererManager 六档）。桌面端忽略。
  AndroidRenderer _androidRenderer = AndroidRenderer.gl4es;
  AndroidRenderer get androidRenderer => _androidRenderer;
  set androidRenderer(AndroidRenderer value) {
    if (_androidRenderer == value) return;
    _androidRenderer = value;
    _persistLauncherConfig();
  }

  /// Android 游戏内 FPS 叠层。
  bool _androidShowFps = true;
  bool get androidShowFps => _androidShowFps;
  set androidShowFps(bool value) {
    if (_androidShowFps == value) return;
    _androidShowFps = value;
    _persistLauncherConfig();
  }

  /// GC 预设（PCL2 `LaunchAdvanceGC`）。
  GcPreset _gcPreset = GcPreset.auto;
  GcPreset get gcPreset => _gcPreset;
  set gcPreset(GcPreset value) {
    if (_gcPreset == value) return;
    _gcPreset = value;
    _persistLauncherConfig();
  }

  /// 启动时若没有合适的 Java，自动下载对应运行时。
  bool _autoInstallJava = true;
  bool get autoInstallJava => _autoInstallJava;
  set autoInstallJava(bool value) {
    if (_autoInstallJava == value) return;
    _autoInstallJava = value;
    _persistLauncherConfig();
  }

  /// 全局文件校验开关（版本级可覆盖）。
  bool _verifyFiles = true;
  bool get verifyFiles => _verifyFiles;
  set verifyFiles(bool value) {
    if (_verifyFiles == value) return;
    _verifyFiles = value;
    _persistLauncherConfig();
  }

  /// CurseForge 官方 API Key（导入 CurseForge 整合包时查询 fileID 用）。
  String _curseForgeApiKey = '';
  String get curseForgeApiKey => _curseForgeApiKey;
  set curseForgeApiKey(String value) {
    if (_curseForgeApiKey == value) return;
    _curseForgeApiKey = value;
    _persistLauncherConfig();
  }

  /// HTTP 代理（下载用；空 = 系统默认直连）。
  bool _proxyEnabled = false;
  bool get proxyEnabled => _proxyEnabled;
  set proxyEnabled(bool value) {
    if (_proxyEnabled == value) return;
    _proxyEnabled = value;
    _persistLauncherConfig();
  }

  String _proxyHost = '';
  String get proxyHost => _proxyHost;
  set proxyHost(String value) {
    if (_proxyHost == value) return;
    _proxyHost = value;
    _persistLauncherConfig();
  }

  /// 界面语言（'' = 跟随系统；当前内置 zh-CN，其它语言走默认回退）。
  String _uiLocale = '';
  String get uiLocale => _uiLocale;
  set uiLocale(String value) {
    if (_uiLocale == value) return;
    _uiLocale = value;
    // Android 13+：写回系统「应用语言」，系统设置里也保持一致。
    unawaited(AppLocaleBridge.setSystemAppLocale(value.isEmpty ? null : value));
    _persistLauncherConfig();
  }

  /// Android 短提示用系统 Toast（local2api「原生 Toast」对应物）。
  bool _nativeToast = false;
  bool get nativeToast => _nativeToast;
  set nativeToast(bool value) {
    if (_nativeToast == value) return;
    _nativeToast = value;
    NativeToastService.enabled = value;
    _persistLauncherConfig();
  }

  /// Android 窄屏用原生液态玻璃底栏（local2api / NaviFlash 同款），
  /// 关闭后回到 Flutter 悬浮胶囊底栏。
  bool _glassBottomBar = true;
  bool get glassBottomBar => _glassBottomBar;
  set glassBottomBar(bool value) {
    if (_glassBottomBar == value) return;
    _glassBottomBar = value;
    _persistLauncherConfig();
  }

  /// 启动游戏时把 options.txt 的语言设为简体中文（zh_cn）。
  /// 默认开（PCL2「游戏语言」同款思路）。
  bool _gameLangZh = true;
  bool get gameLangZh => _gameLangZh;
  set gameLangZh(bool value) {
    if (_gameLangZh == value) return;
    _gameLangZh = value;
    _persistLauncherConfig();
  }

  /// 下载线程数（并发分片下载数，PCL2「线程数」同款）。
  int _downloadThreads = 64;
  int get downloadThreads => _downloadThreads;
  set downloadThreads(int value) {
    final v = value.clamp(1, 256);
    if (_downloadThreads == v) return;
    _downloadThreads = v;
    _persistLauncherConfig();
  }

  int _proxyPort = 7890;
  int get proxyPort => _proxyPort;
  set proxyPort(int value) {
    if (_proxyPort == value) return;
    _proxyPort = value.clamp(1, 65535);
    _persistLauncherConfig();
  }

  /// 自动分配内存（PCL2 默认 AUTO）：启动时按可用物理内存 + 模组数量计算。
  bool _memoryAuto = true;
  bool get memoryAuto => _memoryAuto;
  set memoryAuto(bool value) {
    if (_memoryAuto == value) return;
    _memoryAuto = value;
    _persistLauncherConfig();
  }

  /// JVM 最大堆（MB）。AUTO 关闭时使用；不设 32GB 这种人为上限。
  int _memoryMb = 4096;
  int get memoryMb => _memoryMb;
  set memoryMb(int value) {
    final v = value.clamp(256, 1048576);
    if (_memoryMb == v) return;
    _memoryMb = v;
    _persistLauncherConfig();
  }

  /// 游戏窗口模式（PCL2 `LaunchArgumentWindowType` 裁剪版）。
  GameWindowMode _gameWindowMode = GameWindowMode.defaultSize;
  GameWindowMode get gameWindowMode => _gameWindowMode;
  set gameWindowMode(GameWindowMode value) {
    if (_gameWindowMode == value) return;
    _gameWindowMode = value;
    _fullscreen = value == GameWindowMode.fullscreen;
    _persistLauncherConfig();
  }

  /// 游戏窗口宽/高。
  int _gameWidth = 854;
  int get gameWidth => _gameWidth;
  set gameWidth(int value) {
    if (_gameWidth == value) return;
    _gameWidth = value.clamp(320, 7680);
    _persistLauncherConfig();
  }

  int _gameHeight = 480;
  int get gameHeight => _gameHeight;
  set gameHeight(int value) {
    if (_gameHeight == value) return;
    _gameHeight = value.clamp(240, 4320);
    _persistLauncherConfig();
  }

  bool _fullscreen = false;
  bool get fullscreen => _fullscreen;
  set fullscreen(bool value) {
    if (_fullscreen == value) return;
    _fullscreen = value;
    if (value) {
      _gameWindowMode = GameWindowMode.fullscreen;
    } else if (_gameWindowMode == GameWindowMode.fullscreen) {
      _gameWindowMode = GameWindowMode.defaultSize;
    }
    _persistLauncherConfig();
  }

  DownloadSource _downloadSource = DownloadSource.auto;
  DownloadSource get downloadSource => _downloadSource;
  set downloadSource(DownloadSource value) {
    if (_downloadSource == value) return;
    _downloadSource = value;
    _persistLauncherConfig();
  }

  /// 每版本设置覆盖（`目录 + versionId` → 覆盖项；旧数据用 `*` 兜底）。
  Map<String, VersionSettings> _versionSettings = {};
  Map<String, VersionSettings> get versionSettings => _versionSettings;

  /// 不同游戏目录可以有同名版本，设置必须按目录分开。
  String _versionKey(String root, String versionId) =>
      '${(root.isEmpty ? '*' : root)}\u0000$versionId';

  VersionSettings? _readVersionSettings(String versionId, String root) =>
      _versionSettings[_versionKey(root, versionId)] ??
      _versionSettings[_versionKey('', versionId)];

  /// 读某个版本的设置（不存在返回空覆盖对象，不改 store）。
  VersionSettings settingsFor(String versionId, {String? gameDir}) =>
      _readVersionSettings(versionId, gameDir ?? _gameDir) ?? VersionSettings();

  /// 更新某个版本的设置；清空所有覆盖项时删掉该键。
  void updateVersionSettings(
    String versionId,
    VersionSettings vs, {
    String? gameDir,
  }) {
    final key = _versionKey(gameDir ?? _gameDir, versionId);
    if (vs.isEmpty) {
      _versionSettings.remove(key);
    } else {
      _versionSettings[key] = vs;
    }
    _persistLauncherConfig();
  }

  /// 离线账户列表 + 当前选中的用户名。
  /// （账户与启动器配置收进同一个 JSON blob 键持久化。）
  List<OfflineAccount> _accounts = [];
  List<OfflineAccount> get accounts => List.unmodifiable(_accounts);

  String _selectedAccountName = '';
  String get selectedAccountName => _selectedAccountName;

  OfflineAccount? get selectedAccount {
    for (final a in _accounts) {
      if (a.name == _selectedAccountName) return a;
    }
    return _accounts.isEmpty ? null : _accounts.first;
  }

  void addAccount(OfflineAccount account) {
    // 同名覆盖
    _accounts.removeWhere((a) => a.name == account.name);
    _accounts.add(account);
    _selectedAccountName = account.name;
    _persistLauncherConfig();
  }

  void removeAccount(String name) {
    _accounts.removeWhere((a) => a.name == name);
    if (_selectedAccountName == name) {
      _selectedAccountName = _accounts.isEmpty ? '' : _accounts.first.name;
    }
    _persistLauncherConfig();
  }

  void selectAccount(String name) {
    if (_selectedAccountName == name) return;
    _selectedAccountName = name;
    _persistLauncherConfig();
  }

  /// 当前选中的版本 id。
  String _selectedVersion = '';
  String get selectedVersion => _selectedVersion;
  set selectedVersion(String value) {
    if (_selectedVersion == value) return;
    _selectedVersion = value;
    if (_gameDir.isNotEmpty) {
      _selectedVersionByDir[_gameDir] = value;
    } else {
      _legacySelectedVersion = value;
    }
    _persistLauncherConfig();
  }

  /// 每个游戏目录各自记住的选中版本（目录 → 版本 id）。
  Map<String, String> _selectedVersionByDir = {};

  /// 还没解析出目录时暂存的选中版本（旧配置迁移）。
  String _legacySelectedVersion = '';

  /// 解析某个版本的实际启动参数（每版本覆盖优先，全局兜底）。
  EffectiveVersionSettings effectiveFor(String versionId, {String? gameDir}) {
    final vs = _readVersionSettings(versionId, gameDir ?? _gameDir);
    final server = vs?.serverAddress;
    final globalServer = _serverAddress.trim();
    final serverAddr = (server != null && server.trim().isNotEmpty)
        ? server.trim()
        : globalServer;
    return (
      memoryMb: vs?.memoryMb ?? _memoryMb,
      memoryAuto: _memoryAuto && vs?.memoryMb == null,
      javaPath: (vs?.javaPath != null && vs!.javaPath!.isNotEmpty)
          ? vs.javaPath!
          : _javaPath,
      isolation: isolationFor(versionId, override: vs?.isolation),
      jvmArgs: (vs?.jvmArgs != null && vs!.jvmArgs!.isNotEmpty)
          ? vs.jvmArgs!
          : _jvmArgs,
      envVars: (vs?.envVars != null && vs!.envVars!.isNotEmpty)
          ? vs.envVars!
          : _envVars,
      serverAddress: serverAddr,
      verifyFiles: vs?.verifyFiles ?? _verifyFiles,
      graphicsBackend:
          vs?.graphicsBackend != null && vs!.graphicsBackend!.isNotEmpty
          ? GraphicsBackend.fromId(vs.graphicsBackend)
          : _graphicsBackend,
      // null = 跟随全局；'' 是用户显式选的「自动」，所以要按 ?? 而不是 isEmpty。
      gpuPreference: vs?.gpuPreference ?? _gpuPreference,
      extraGameArgs:
          (vs?.extraGameArgs != null && vs!.extraGameArgs!.isNotEmpty)
          ? vs.extraGameArgs!
          : _extraGameArgs,
      preLaunchCommand:
          (vs?.preLaunchCommand != null && vs!.preLaunchCommand!.isNotEmpty)
          ? vs.preLaunchCommand!
          : _preLaunchCommand,
      preLaunchWait: vs?.preLaunchWait ?? _preLaunchWait,
      gcPreset: vs?.gcPreset != null && vs!.gcPreset!.isNotEmpty
          ? GcPreset.fromId(vs.gcPreset)
          : _gcPreset,
      width: vs?.width,
      height: vs?.height,
    );
  }

  Map<String, dynamic> _launcherConfigJson() => {
    'gameDir': _gameDir,
    'gameDirs': _gameDirs,
    'javaPath': _javaPath,
    'isolationMode': _isolationMode.id,
    'jvmArgs': _jvmArgs,
    'envVars': _envVars,
    'serverAddress': _serverAddress,
    'extraGameArgs': _extraGameArgs,
    'preLaunchCommand': _preLaunchCommand,
    'preLaunchWait': _preLaunchWait,
    'proxyEnabled': _proxyEnabled,
    'proxyHost': _proxyHost,
    'proxyPort': _proxyPort,
    'downloadThreads': _downloadThreads,
    'uiLocale': _uiLocale,
    'nativeToast': _nativeToast,
    'glassBottomBar': _glassBottomBar,
    'gameLangZh': _gameLangZh,
    'memoryMb': _memoryMb,
    'memoryAuto': _memoryAuto,
    'gameWindowMode': _gameWindowMode.id,
    'launcherVisibility': _launcherVisibility.id,
    'processPriority': _processPriority.id,
    'graphicsBackend': _graphicsBackend.id,
    'gpuPreference': _gpuPreference,
    'androidRenderer': _androidRenderer.id,
    'androidShowFps': _androidShowFps,
    'gcPreset': _gcPreset.id,
    'autoInstallJava': _autoInstallJava,
    'verifyFiles': _verifyFiles,
    'curseForgeApiKey': _curseForgeApiKey,
    'gameWidth': _gameWidth,
    'gameHeight': _gameHeight,
    'fullscreen': _fullscreen,
    'downloadSource': _downloadSource.id,
    'accounts': [for (final a in _accounts) a.toJson()],
    'selectedAccountName': _selectedAccountName,
    'selectedVersion': _selectedVersion,
    'selectedVersionByDir': _selectedVersionByDir,
    'pageBackgroundPath': _pageBackgroundPath,
    'pageBackgroundEnabled': _pageBackgroundEnabled,
    'pageBackgroundOpacity': _pageBackgroundOpacity,
    'pageBackgroundBlur': _pageBackgroundBlur,
    'pageBackgroundAssignments': _pageBackgroundAssignments,
    'otherDownloadDir': _otherDownloadDir,
    'cloudForeground': _cloudForeground,
    'cloudOpacity': _cloudOpacity,
    'cloudDensity': _cloudDensity,
    'textureSettings': _textureSettings,
    'volumeUseThemeBar': _volumeUseThemeBar,
    'activeThemeId': _activeThemeId,
    'themeUseWallpaper': _themeUseWallpaper,
    'themeUseAccent': _themeUseAccent,
    'themeUseFont': _themeUseFont,
    'themeUseBootAnimation': _themeUseBootAnimation,
    'vtouchEnabled': _vtouchEnabled,
    'vtouchAutoShow': _vtouchAutoShow,
    'vtouchAlpha': _vtouchAlpha,
    'vtouchScale': _vtouchScale,
    'vtouchLayout': [
      if (_vtouchLayout != null)
        for (final c in _vtouchLayout!) c.toJson(),
    ],
    'vtouchBallX': _vtouchBallX,
    'vtouchBallY': _vtouchBallY,
    'versionSettings': {
      for (final e in _versionSettings.entries) e.key: e.value.toJson(),
    },
  };

  void _applyLauncherConfig(Map<String, dynamic> json) {
    _gameDir = _normalizeDir((json['gameDir'] as String?) ?? '');
    _gameDirs = [
      if (json['gameDirs'] is List)
        for (final d in (json['gameDirs'] as List))
          if (d is String && d.trim().isNotEmpty) _normalizeDir(d),
    ];
    if (_gameDirs.isEmpty && _gameDir.isNotEmpty) _gameDirs = [_gameDir];
    _javaPath = (json['javaPath'] as String?) ?? '';
    // isolationMode 是新键；旧配置只有布尔 versionIsolation
    // （true → 全部隔离，false/缺省 → 关闭）。
    final isolationId = json['isolationMode'] as String?;
    if (isolationId != null && isolationId.isNotEmpty) {
      _isolationMode = IsolationMode.fromId(isolationId);
    } else {
      _isolationMode = ((json['versionIsolation'] as bool?) == true)
          ? IsolationMode.all
          : IsolationMode.off;
    }
    _jvmArgs = (json['jvmArgs'] as String?) ?? '';
    _envVars = (json['envVars'] as String?) ?? '';
    _serverAddress = (json['serverAddress'] as String?) ?? '';
    _extraGameArgs = (json['extraGameArgs'] as String?) ?? '';
    _preLaunchCommand = (json['preLaunchCommand'] as String?) ?? '';
    _preLaunchWait = (json['preLaunchWait'] as bool?) ?? _preLaunchWait;
    _proxyEnabled = (json['proxyEnabled'] as bool?) ?? false;
    _proxyHost = (json['proxyHost'] as String?) ?? '';
    _proxyPort = (json['proxyPort'] as num?)?.toInt() ?? 7890;
    _downloadThreads = (json['downloadThreads'] as num?)?.toInt() ?? 64;
    _uiLocale = (json['uiLocale'] as String?) ?? '';
    _nativeToast = (json['nativeToast'] as bool?) ?? false;
    NativeToastService.enabled = _nativeToast;
    _glassBottomBar = (json['glassBottomBar'] as bool?) ?? true;
    _gameLangZh = (json['gameLangZh'] as bool?) ?? true;
    _memoryMb = (json['memoryMb'] as num?)?.toInt() ?? _memoryMb;
    _memoryAuto = (json['memoryAuto'] as bool?) ?? _memoryAuto;
    final storedWindowMode = json['gameWindowMode'] as String?;
    _gameWindowMode = GameWindowMode.fromId(storedWindowMode);
    _launcherVisibility = LauncherVisibility.fromId(
      json['launcherVisibility'] as String?,
    );
    _processPriority = ProcessPriority.fromId(
      json['processPriority'] as String?,
    );
    _graphicsBackend = GraphicsBackend.fromId(
      json['graphicsBackend'] as String?,
    );
    _gpuPreference = (json['gpuPreference'] as String?) ?? _gpuPreference;
    _androidRenderer = AndroidRenderer.fromId(
      json['androidRenderer'] as String?,
    );
    _androidShowFps = (json['androidShowFps'] as bool?) ?? _androidShowFps;
    _gcPreset = GcPreset.fromId(json['gcPreset'] as String?);
    _autoInstallJava = (json['autoInstallJava'] as bool?) ?? _autoInstallJava;
    _verifyFiles = (json['verifyFiles'] as bool?) ?? _verifyFiles;
    _curseForgeApiKey = (json['curseForgeApiKey'] as String?) ?? '';
    _gameWidth = (json['gameWidth'] as num?)?.toInt() ?? _gameWidth;
    _gameHeight = (json['gameHeight'] as num?)?.toInt() ?? _gameHeight;
    // fullscreen 是旧版独立开关。只要存过 gameWindowMode 就以它为准，
    // 否则从全屏切到 sameAsLauncher 后，旧配置里残留的 fullscreen=true
    // 会把模式又掰回全屏；只有完全没有 mode 键的旧配置才回退读它。
    if (storedWindowMode == null || storedWindowMode.isEmpty) {
      _fullscreen = (json['fullscreen'] as bool?) ?? false;
      if (_fullscreen) {
        _gameWindowMode = GameWindowMode.fullscreen;
      }
    } else {
      _fullscreen = _gameWindowMode == GameWindowMode.fullscreen;
    }
    _downloadSource = DownloadSource.fromId(json['downloadSource'] as String?);
    _pageBackgroundPath = (json['pageBackgroundPath'] as String?) ?? '';
    _pageBackgroundEnabled = (json['pageBackgroundEnabled'] as bool?) ?? false;
    _pageBackgroundOpacity =
        (json['pageBackgroundOpacity'] as num?)?.toDouble() ??
        _pageBackgroundOpacity;
    _pageBackgroundBlur =
        (json['pageBackgroundBlur'] as num?)?.toDouble() ?? _pageBackgroundBlur;
    _pageBackgroundAssignments = {
      if (json['pageBackgroundAssignments'] is Map)
        for (final e in (json['pageBackgroundAssignments'] as Map).entries)
          if (e.value is String && (e.value as String).isNotEmpty)
            '${e.key}': e.value as String,
    };
    _otherDownloadDir = (json['otherDownloadDir'] as String?) ?? '';
    _cloudForeground = (json['cloudForeground'] as bool?) ?? _cloudForeground;
    _cloudOpacity = (json['cloudOpacity'] as num?)?.toDouble() ?? _cloudOpacity;
    _cloudDensity = (json['cloudDensity'] as num?)?.toDouble() ?? _cloudDensity;
    _textureSettings =
        (json['textureSettings'] as Map?)?.cast<String, Object?>() ??
        _textureSettings;
    _volumeUseThemeBar =
        (json['volumeUseThemeBar'] as bool?) ?? _volumeUseThemeBar;
    _activeThemeId = (json['activeThemeId'] as String?) ?? _activeThemeId;
    _themeUseWallpaper =
        (json['themeUseWallpaper'] as bool?) ?? _themeUseWallpaper;
    _themeUseAccent = (json['themeUseAccent'] as bool?) ?? _themeUseAccent;
    _themeUseFont = (json['themeUseFont'] as bool?) ?? _themeUseFont;
    _themeUseBootAnimation =
        (json['themeUseBootAnimation'] as bool?) ?? _themeUseBootAnimation;
    _vtouchEnabled = (json['vtouchEnabled'] as bool?) ?? _vtouchEnabled;
    _vtouchAutoShow = (json['vtouchAutoShow'] as bool?) ?? _vtouchAutoShow;
    _vtouchAlpha = (json['vtouchAlpha'] as num?)?.toDouble() ?? _vtouchAlpha;
    _vtouchScale = (json['vtouchScale'] as num?)?.toDouble() ?? _vtouchScale;
    if (json['vtouchLayout'] is List) {
      final list = [
        if (json['vtouchLayout'] is List)
          for (final item in (json['vtouchLayout'] as List))
            if (item is Map<String, dynamic>) VTouchControl.fromJson(item),
      ];
      // 布局文件坏了 / 空布局 → 回落默认；缺摇杆的半截布局补回摇杆
      // （与 Android ControlLayout.load 的兜底一致）。
      if (list.isEmpty) {
        _vtouchLayout = null;
      } else if (!list.any((c) => c.isJoystick)) {
        _vtouchLayout = migrateVTouchLabels([
          ...list,
          ...vtouchDefaults().where((c) => c.isJoystick),
        ]);
      } else {
        _vtouchLayout = migrateVTouchLabels(list);
      }
    }
    _vtouchBallX = (json['vtouchBallX'] as num?)?.toDouble() ?? _vtouchBallX;
    _vtouchBallY = (json['vtouchBallY'] as num?)?.toDouble() ?? _vtouchBallY;
    _accounts = [
      if (json['accounts'] is List)
        for (final a in (json['accounts'] as List))
          OfflineAccount.fromJson(a as Map<String, dynamic>),
    ];
    _selectedAccountName = (json['selectedAccountName'] as String?) ?? '';
    _selectedVersion = (json['selectedVersion'] as String?) ?? '';
    _selectedVersionByDir = {
      if (json['selectedVersionByDir'] is Map<String, dynamic>)
        for (final e
            in (json['selectedVersionByDir'] as Map<String, dynamic>).entries)
          if (e.value is String) _normalizeDir(e.key): e.value as String,
    };
    if (_gameDir.isNotEmpty && _selectedVersion.isNotEmpty) {
      _selectedVersionByDir.putIfAbsent(_gameDir, () => _selectedVersion);
    } else if (_gameDir.isEmpty && _selectedVersion.isNotEmpty) {
      _legacySelectedVersion = _selectedVersion;
    }
    if (json['versionSettings'] is Map<String, dynamic>) {
      _versionSettings = {
        for (final e
            in (json['versionSettings'] as Map<String, dynamic>).entries)
          if (e.value is Map<String, dynamic>)
            // 旧版键是裸 versionId：归到 '*'（读取时任何目录都能兜底），
            // 新键是「目录\u0000版本 id」。
            (e.key.contains('\u0000') ? e.key : _versionKey('', e.key)):
                VersionSettings.fromJson(e.value as Map<String, dynamic>),
      };
    }
  }

  Future<void> _persistLauncherConfig() async {
    if (!_loaded) return;
    notifyListeners();
    final prefs = await _prefsFuture!;
    await prefs.setString(
      '${_prefix}launcher_config',
      jsonEncode(_launcherConfigJson()),
    );
  }
}

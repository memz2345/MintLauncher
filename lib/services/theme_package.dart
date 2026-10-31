import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/nine_patch.dart';

/// 一个 MIUI 主题包（.mtz）里的单个模块声明。
///
/// mtz 的模块本身就是 zip（`icons`、`com.android.systemui` …），也可能是
/// 目录（`wallpaper/`、`preview/`）。这里只记录我们反向适配时用得到的
/// 信息：模块名、资产数量、theme_values 里声明了多少颜色 / 字符串。
class MintThemeModule {
  const MintThemeModule({
    required this.name,
    required this.kind,
    this.assetCount = 0,
    this.colorCount = 0,
    this.stringCount = 0,
    this.fontFile = '',
  });

  final String name;

  /// `wallpaper` / `icons` / `boots` / `font` / `overlay` / `preview` / `other`
  final String kind;
  final int assetCount;
  final int colorCount;
  final int stringCount;
  final String fontFile;
}

/// 主题里的一个应用图标（包名 → PNG）。
class MintThemeIcon {
  const MintThemeIcon(this.packageName, this.path);
  final String packageName;
  final String path;
}

/// 「额外素材」的版本：每加一轮要从 mtz 里补解的素材就 +1，
/// 老 theme.json 的 assetsVersion 小于它时启动会补解一次（见
/// [MintThemeLibrary._upgradeAssets]）。
/// 1 = 关于页窗口背景 / 字标；2 = + 音量条图标；3 = + 全模块背景图
/// （[MintTheme.backgrounds]，背景预览器 / 按页背景 / 弹窗背景用）。
const int kThemeAssetsVersion = 3;

/// 需要额外解出「关于页 / 音量条」素材的覆盖模块名。
const List<String> kThemeOverlayModules = [
  'com.android.settings',
  'miui.systemui.plugin',
];

/// 主题包里的一张「应用声明背景图」。
///
/// MIUI 主题按应用声明整屏背景（`window_bg`）和页面级背景
/// （拨号盘 `dialerpad_background`、短信会话 `conversation_bg`…），
/// 解包后统一收进 [MintTheme.backgrounds]：背景预览器按它铺开，
/// 用户可以把任意一张指定到启动器的某个页面（首页 / 下载 / 关于…）
/// 或底部弹窗上。
class MintThemeBackground {
  const MintThemeBackground({
    required this.module,
    required this.name,
    required this.path,
    required this.dark,
  });

  /// 来源模块（com.android.contacts / com.android.settings …）。
  final String module;

  /// 资源名（window_bg / dialerpad_background …，已去掉 light/dark 后缀）。
  final String name;

  /// 解出来的绝对路径（.9.png 的引导边在展示前会被裁掉，见
  /// `services/nine_patch.dart`）。
  final String path;

  /// 是否夜间版（nightmode/ 目录下的声明）。
  final bool dark;

  Map<String, Object?> toJson() => {
    'module': module,
    'name': name,
    'path': path,
    'dark': dark,
  };

  static MintThemeBackground fromJson(Map<String, Object?> json) =>
      MintThemeBackground(
        module: '${json['module'] ?? ''}',
        name: '${json['name'] ?? ''}',
        path: '${json['path'] ?? ''}',
        dark: (json['dark'] as bool?) ?? false,
      );
}

/// 解析完成、已经落盘的主题包。
class MintTheme {
  const MintTheme({
    required this.id,
    required this.dir,
    required this.title,
    required this.author,
    required this.designer,
    required this.version,
    required this.uiVersion,
    required this.description,
    required this.importedAt,
    required this.wallpaper,
    required this.lockWallpaper,
    required this.settingsWindowBackground,
    required this.settingsWindowBackgroundDark,
    required this.settingsIcon,
    required this.volumeIcon,
    required this.volumeIconMuted,
    required this.assetsVersion,
    required this.accent,
    required this.fontFile,
    required this.bootAnimationDir,
    required this.icons,
    required this.previews,
    required this.modules,
    required this.colors,
    required this.strings,
    required this.controls,
    required this.widgetAssets,
    required this.sourcePath,
    this.backgrounds = const [],
  });

  final String id;
  final String dir;

  /// `description.xml` 的标题 / 作者 / 设计师 / 版本 / 描述。
  final String title;
  final String author;
  final String designer;
  final String version;
  final String uiVersion;
  final String description;
  final DateTime importedAt;

  /// 桌面壁纸 / 锁屏壁纸（解出来的绝对路径，空 = 主题没声明）。
  final String wallpaper;
  final String lockWallpaper;

  /// `com.android.settings` 声明的设置/关于窗口背景（window_bg_light/dark），
  /// 以及主题的版本字标（HyperOS 的 xiaomi_os_logo / MIUI 的 miui_version_logo）。
  /// 空 = 该主题没声明。
  final String settingsWindowBackground;
  final String settingsWindowBackgroundDark;
  final String settingsIcon;

  /// `miui.systemui.plugin` 声明的音量条图标（ic_miui_volume_media[_mute]）。
  final String volumeIcon;
  final String volumeIconMuted;

  /// 已解到磁盘的「额外素材」版本（[kThemeAssetsVersion]）。比当前版本小 =
  /// 早于某轮素材解析导入的老缓存，[MintThemeLibrary.load] 会拿 [sourcePath]
  /// 补解一次（见 [extractThemeExtraAssets]）并把版本号写回，不用重新导入。
  final int assetsVersion;

  String settingsBackgroundFor(bool dark) =>
      dark && settingsWindowBackgroundDark.isNotEmpty
      ? settingsWindowBackgroundDark
      : settingsWindowBackground;

  /// 从 theme_values 里挑出来的主色（MIUI 蓝色主色优先）。
  final Color? accent;

  /// 主题字体文件（ttf/otf），空 = 没声明。
  final String fontFile;

  /// 开机动画目录（desc.txt + partN/），空 = 没声明。
  final String bootAnimationDir;

  final List<MintThemeIcon> icons;
  final List<String> previews;
  final List<MintThemeModule> modules;

  /// 所有模块 theme_values 合并后的颜色 / 字串（同名后者覆盖前者）。
  final Map<String, String> colors;
  final Map<String, String> strings;

  /// 控件颜色（switch / back / button / checkbox / radio / seekbar / scrollbar）。
  final Map<String, String> controls;

  /// 控件图片（同名角色取第一张）：switchOn / switchOff / back / backArt /
  /// button / checkbox / radio / seekbar / scrollbar / buttonPressed。
  final Map<String, String> widgetAssets;

  /// 全模块声明的背景图（window_bg / dialerpad_background …，浅色 + 夜间）。
  /// 背景预览器（主题页 →「背景图」）按这份列表铺开。
  final List<MintThemeBackground> backgrounds;

  final String sourcePath;

  /// 返回箭头颜色（主题声明 `miui_back_color` 之类时生效）。
  Color? get backColor => _parseColor(controls['back']);

  /// 滚动条颜色（主题一般给的是主色 30% 的拇指色）。
  Color? get scrollbarColor => _parseColor(controls['scrollbar']);

  /// 开关打开态颜色（`miuix_appcompat_sliding_button_bar_on_*` 等）。
  Color? get switchColor => _parseColor(controls['switch']);

  /// 主按钮背景色。
  Color? get buttonColor => _parseColor(controls['button']);

  /// 卡片底色（`card_view_background_color`，主题一般给主色 30% 的半透明遮罩）。
  Color? get cardColor => _parseColor(controls['card']);

  /// 弹窗底色（`*_dialog_bg_*`）；没声明时退回卡片色。
  Color? get dialogColor =>
      _parseColor(controls['dialog']) ?? _parseColor(controls['card']);

  /// 弹窗选中项底色（`*_dialog_default_list_item_bg_*_checked_*`）。
  Color? get dialogSelectedColor => _parseColor(controls['dialogSelected']);

  Color? get checkboxColor => _parseColor(controls['checkbox']);

  Color? get radioColor => _parseColor(controls['radio']);

  Color? get seekbarColor => _parseColor(controls['seekbar']);

  // ---- 音量条（miui.systemui.plugin 的 miui_volume_* 声明）----

  Color? get volumeAccentColor => _parseColor(controls['volumeAccent']);
  Color? get volumeTrackColor => _parseColor(controls['volumeTrack']);
  Color? get volumeDisabledColor => _parseColor(controls['volumeDisabled']);
  Color? get volumeButtonColor => _parseColor(controls['volumeButton']);
  Color? get volumeExpandColor => _parseColor(controls['volumeExpand']);

  /// 柱高：主题给的是 `165dip` 这类字串，解析不出来用系统面板的默认值。
  double get volumeColumnHeight {
    final raw = controls['volumeColumnHeight'];
    if (raw == null) return 165;
    final value =
        double.tryParse(RegExp(r'[\d.]+').firstMatch(raw)?.group(0) ?? '') ??
        165.0;
    return value.clamp(80.0, 320.0);
  }
  /// 主题是否声明了可展示的「关于」信息（description.xml 的元数据）。
  bool get hasAbout =>
      title.isNotEmpty ||
      description.isNotEmpty ||
      author.isNotEmpty ||
      designer.isNotEmpty;

  /// 底部弹窗该用的声明背景：mtz 里**弹窗级**的资源优先 —— 拨号盘
  /// `dialerpad_background`（弹出的拨号面板就是一张带圆角的弹窗背景图，
  /// 浅蓝芙宁娜那张）/ `dialer_background_pad`，按明暗取对应的声明；
  /// 只有明暗不齐时退回浅色版。null = 主题没声明弹窗背景。
  MintThemeBackground? sheetBackgroundFor(bool dark) {
    MintThemeBackground? pick(String name, bool isDark) {
      for (final b in backgrounds) {
        if (b.name == name && b.dark == isDark && File(b.path).existsSync()) {
          return b;
        }
      }
      return null;
    }

    for (final name in const ['dialerpad_background', 'dialer_background_pad']) {
      // 夜间模式优先取夜间声明，缺了退回浅色版。
      final matched = pick(name, dark) ?? pick(name, false);
      if (matched != null) return matched;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'dir': dir,
    'title': title,
    'author': author,
    'designer': designer,
    'version': version,
    'uiVersion': uiVersion,
    'description': description,
    'importedAt': importedAt.toIso8601String(),
    'wallpaper': wallpaper,
    'lockWallpaper': lockWallpaper,
    'settingsWindowBackground': settingsWindowBackground,
    'settingsWindowBackgroundDark': settingsWindowBackgroundDark,
    'settingsIcon': settingsIcon,
    'volumeIcon': volumeIcon,
    'volumeIconMuted': volumeIconMuted,
    'assetsVersion': assetsVersion,
    'accent': accent?.toARGB32(),
    'fontFile': fontFile,
    'bootAnimationDir': bootAnimationDir,
    'icons': [
      for (final i in icons) [i.packageName, i.path],
    ],
    'previews': previews,
    'modules': [
      for (final m in modules)
        [m.name, m.kind, m.assetCount, m.colorCount, m.stringCount, m.fontFile],
    ],
    'colors': colors,
    'strings': strings,
    'controls': controls,
    'widgetAssets': widgetAssets,
    'backgrounds': [for (final b in backgrounds) b.toJson()],
    'sourcePath': sourcePath,
  };

  static MintTheme fromJson(Map<String, Object?> json) {
    final accent = json['accent'] as num?;
    final colors = {
      for (final e in (json['colors'] as Map? ?? const {}).entries)
        '${e.key}': '${e.value}',
    };
    final controls = {
      for (final e in (json['controls'] as Map? ?? const {}).entries)
        '${e.key}': '${e.value}',
    };
    // 旧版 theme.json 没有 controls / 缺少新角色：从 colors 现场补齐，
    // 避免已经导入的主题必须重新导入才能用上新增的控件映射。
    for (final entry in _pickControlColors(colors).entries) {
      controls.putIfAbsent(entry.key, () => entry.value);
    }
    return MintTheme(
      id: '${json['id'] ?? ''}',
      dir: '${json['dir'] ?? ''}',
      title: '${json['title'] ?? ''}',
      author: '${json['author'] ?? ''}',
      designer: '${json['designer'] ?? ''}',
      version: '${json['version'] ?? ''}',
      uiVersion: '${json['uiVersion'] ?? ''}',
      description: '${json['description'] ?? ''}',
      importedAt:
          DateTime.tryParse('${json['importedAt'] ?? ''}') ?? DateTime.now(),
      wallpaper: '${json['wallpaper'] ?? ''}',
      lockWallpaper: '${json['lockWallpaper'] ?? ''}',
      settingsWindowBackground: '${json['settingsWindowBackground'] ?? ''}',
      settingsWindowBackgroundDark:
          '${json['settingsWindowBackgroundDark'] ?? ''}',
      settingsIcon: '${json['settingsIcon'] ?? ''}',
      volumeIcon: '${json['volumeIcon'] ?? ''}',
      volumeIconMuted: '${json['volumeIconMuted'] ?? ''}',
      assetsVersion: (json['assetsVersion'] as num?)?.toInt() ?? 0,
      accent: accent == null ? null : Color(accent.toInt()),
      fontFile: '${json['fontFile'] ?? ''}',
      bootAnimationDir: '${json['bootAnimationDir'] ?? ''}',
      icons: [
        for (final raw in (json['icons'] as List? ?? const []))
          if (raw is List && raw.length >= 2)
            MintThemeIcon('${raw[0]}', '${raw[1]}'),
      ],
      previews: [for (final e in (json['previews'] as List? ?? const [])) '$e'],
      modules: [
        for (final raw in (json['modules'] as List? ?? const []))
          if (raw is List && raw.length >= 2)
            MintThemeModule(
              name: '${raw[0]}',
              kind: '${raw[1]}',
              assetCount: raw.length > 2 ? (raw[2] as num).toInt() : 0,
              colorCount: raw.length > 3 ? (raw[3] as num).toInt() : 0,
              stringCount: raw.length > 4 ? (raw[4] as num).toInt() : 0,
              fontFile: raw.length > 5 ? '${raw[5]}' : '',
            ),
      ],
      colors: colors,
      strings: {
        for (final e in (json['strings'] as Map? ?? const {}).entries)
          '${e.key}': '${e.value}',
      },
      controls: controls,
      widgetAssets: {
        for (final e in (json['widgetAssets'] as Map? ?? const {}).entries)
          '${e.key}': '${e.value}',
      },
      backgrounds: [
        for (final raw in (json['backgrounds'] as List? ?? const []))
          if (raw is Map)
            MintThemeBackground.fromJson(raw.cast<String, Object?>()),
      ],
      sourcePath: '${json['sourcePath'] ?? ''}',
    );
  }

  /// 换掉「额外素材」那几项，其余字段原样带走（老主题补解后用）。
  MintTheme withAssets({
    required String settingsWindowBackground,
    required String settingsWindowBackgroundDark,
    required String settingsIcon,
    required String volumeIcon,
    required String volumeIconMuted,
    List<MintThemeBackground>? backgrounds,
  }) => MintTheme(
    id: id,
    dir: dir,
    title: title,
    author: author,
    designer: designer,
    version: version,
    uiVersion: uiVersion,
    description: description,
    importedAt: importedAt,
    wallpaper: wallpaper,
    lockWallpaper: lockWallpaper,
    settingsWindowBackground: settingsWindowBackground,
    settingsWindowBackgroundDark: settingsWindowBackgroundDark,
    settingsIcon: settingsIcon,
    volumeIcon: volumeIcon,
    volumeIconMuted: volumeIconMuted,
    assetsVersion: kThemeAssetsVersion,
    accent: accent,
    fontFile: fontFile,
    bootAnimationDir: bootAnimationDir,
    icons: icons,
    previews: previews,
    modules: modules,
    colors: colors,
    strings: strings,
    controls: controls,
    widgetAssets: widgetAssets,
    backgrounds: backgrounds ?? this.backgrounds,
    sourcePath: sourcePath,
  );
}

/// mtz 导入 / 管理。
///
/// 目录：`<启动器数据>/themes/<id>/`
///   - `theme.json` 解析结果缓存
///   - `wallpaper/` 壁纸
///   - `icons/` 应用图标
///   - `preview/` 预览图
///   - `bootanimation/` 开机动画（desc.txt + partN）
///   - `font.ttf` 主题字体（若有）
class MintThemeLibrary extends ChangeNotifier {
  MintThemeLibrary._();
  static final MintThemeLibrary instance = MintThemeLibrary._();

  String? _root;

  /// 测试 / 工具用：覆盖主题存放目录（null = 启动器数据目录下的 themes/）。
  String? rootOverride;

  /// 当前生效的主题（app.dart 每次 build 更新，图标/滚动条等叶子组件直接读它，
  /// 不用层层传 context）。null = 没应用主题。
  MintTheme? activeTheme;

  final List<MintTheme> _themes = [];
  bool _loaded = false;

  List<MintTheme> get themes => List.unmodifiable(_themes);
  bool get loaded => _loaded;
  String? get root => _root;

  MintTheme? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final t in _themes) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    final base = await GameDir.launcherDataDir();
    _root = rootOverride ?? p.join(base, 'themes');
    final dir = Directory(_root!);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _themes.clear();
    for (final entity in dir.listSync()) {
      if (entity is! Directory) continue;
      final manifest = File(p.join(entity.path, 'theme.json'));
      if (!manifest.existsSync()) continue;
      try {
        final json = jsonDecode(manifest.readAsStringSync());
        if (json is Map<String, Object?>) {
          _themes.add(MintTheme.fromJson(json));
        } else if (json is Map) {
          _themes.add(MintTheme.fromJson(json.cast<String, Object?>()));
        }
      } catch (_) {
        // 单个主题坏了不影响其它主题。
      }
    }
    _themes.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    _loaded = true;
    notifyListeners();
    // .9.png 背景的引导边在后台裁掉，裁完通知一次换用裁边缓存。
    unawaited(materializeImageCrops());
  }

  /// 裁掉所有主题素材里的 .9.png 引导边（见 services/nine_patch.dart）。
  /// 全部成功 / 没有可裁图时不通知。
  Future<void> materializeImageCrops() async {
    var changed = false;
    for (final t in _themes) {
      final paths = <String>[
        for (final b in t.backgrounds) b.path,
        t.settingsWindowBackground,
        t.settingsWindowBackgroundDark,
        t.wallpaper,
        t.lockWallpaper,
      ];
      final before = [for (final p in paths) resolveDisplayImage(p)];
      await materializeNinePatches(paths);
      for (var i = 0; i < paths.length; i++) {
        if (before[i] != resolveDisplayImage(paths[i])) changed = true;
      }
    }
    if (changed && _loaded) notifyListeners();
  }

  /// 素材版本落后的主题（老 theme.json 里没有当轮解析出的 settings / volume
  /// 素材）：原 .mtz 还在的话，只把 `com.android.settings` 和 `miui.systemui.plugin`
  /// 里那几张图补解出来并写回缓存，不用用户重新导入一遍几十 MB 的包。
  ///
  /// 启动时单独调用、不串在 [load] 里 —— 一次补解要一两秒，别挡首帧。
  Future<void> upgradeAssets() async {
    var changed = false;
    for (var i = 0; i < _themes.length; i++) {
      final theme = _themes[i];
      if (theme.assetsVersion >= kThemeAssetsVersion) continue;
      if (theme.sourcePath.isEmpty || !File(theme.sourcePath).existsSync()) {
        continue;
      }
      MintTheme upgraded;
      try {
        final assets = await Isolate.run(
          () => extractThemeExtraAssets(theme.sourcePath, theme.dir),
        );
        upgraded = theme.withAssets(
          settingsWindowBackground: assets.$1,
          settingsWindowBackgroundDark: assets.$2,
          settingsIcon: assets.$3,
          volumeIcon: assets.$4,
          volumeIconMuted: assets.$5,
          backgrounds: assets.$6,
        );
      } catch (_) {
        // 补不上就维持原样；下次启动再试一次。
        continue;
      }
      _themes[i] = upgraded;
      changed = true;
      try {
        File(p.join(theme.dir, 'theme.json')).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(upgraded.toJson()),
        );
      } catch (_) {}
    }
    if (changed) notifyListeners();
    // 补解出来的新素材里可能又有 .9.png，跟着裁一次。
    unawaited(materializeImageCrops());
  }

  /// 导入一个 .mtz。返回解包后的主题；失败抛异常。
  /// 导入一个 .mtz。
  ///
  /// 解包/校验/解压是 CPU + I/O 重活（78MB 的包在手机上有几秒），全部丢进
  /// [Isolate.run]：主 isolate 只负责转圈和收结果，不会「点了没反应」。
  Future<MintTheme> import(String mtzPath) async {
    await load();
    final root = _root;
    if (root == null) throw Exception('主题目录还没有初始化');
    final theme = await Isolate.run(() => extractMintTheme(mtzPath, root));
    _themes.removeWhere((t) => t.id == theme.id);
    _themes.insert(0, theme);
    notifyListeners();
    // 新导入包里的 .9.png 背景先裁好再交给预览器。
    await materializeImageCrops();
    return theme;
  }

  Future<void> remove(String id) async {
    final theme = byId(id);
    if (theme == null) return;
    final dir = Directory(theme.dir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    _themes.removeWhere((t) => t.id == id);
    notifyListeners();
  }
}

String _baseName(String path) => p.basenameWithoutExtension(path);

String _slug(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  final trimmed = cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  return trimmed.isEmpty ? 'theme' : trimmed;
}

bool _isImage(String lower) =>
    lower.endsWith('.png') ||
    lower.endsWith('.jpg') ||
    lower.endsWith('.jpeg') ||
    lower.endsWith('.webp');

bool _looksLikeZip(Uint8List bytes) =>
    bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;

String _readText(ArchiveFile entry) {
  final bytes = entry.readBytes();
  if (bytes == null) return '';
  try {
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return '';
  }
}

/// 在后台 isolate 里解包一个 .mtz（不碰 UI / 单例，只落盘并返回模型）。
Future<MintTheme> extractMintTheme(String mtzPath, String themesRoot) async {
  final file = File(mtzPath);
  if (!file.existsSync()) {
    throw Exception('主题包不存在：$mtzPath');
  }

  // 分块算 sha1：78MB 整读进内存在小内存机器上容易抖。
  final digest = await _sha1OfFile(file);
  final id = '${_slug(_baseName(mtzPath))}_${digest.substring(0, 8)}';
  final dest = Directory(p.join(themesRoot, id));
  if (dest.existsSync()) dest.deleteSync(recursive: true);
  dest.createSync(recursive: true);

  final out = _ThemeImportContext(dest.path, id, mtzPath);
  try {
    final archive = ZipDecoder().decodeStream(InputFileStream(mtzPath));

    // ── 1. 顶层：description.xml / wallpaper 目录 / preview 目录 ──
    final modules = <String, List<ArchiveFile>>{};
    for (final entry in archive) {
      final name = entry.name.replaceAll('\\', '/');
      if (entry.isFile && name == 'description.xml') {
        out.description = _readText(entry);
        continue;
      }
      final slash = name.indexOf('/');
      final module = slash < 0 ? name : name.substring(0, slash);
      if (entry.isFile) {
        modules.putIfAbsent(module, () => []).add(entry);
      }
    }

    // ── 2. description.xml ──
    if (out.description.isNotEmpty) {
      _parseDescription(out);
    }

    // ── 3. 壁纸（wallpaper/default_wallpaper.jpg 直接拷贝） ──
    final wallpaperDir = Directory(p.join(dest.path, 'wallpaper'));
    for (final entry in modules['wallpaper'] ?? const <ArchiveFile>[]) {
      final lower = entry.name.toLowerCase();
      if (!_isImage(lower)) continue;
      wallpaperDir.createSync(recursive: true);
      final target = p.join(wallpaperDir.path, p.basename(entry.name));
      File(target).writeAsBytesSync(entry.readBytes() ?? Uint8List(0));
      final name = p.basenameWithoutExtension(entry.name).toLowerCase();
      if (name.contains('lock')) {
        out.lockWallpaper = target;
      } else {
        out.wallpaper = target;
      }
    }

    // ── 4. 预览图 ──
    final previewDir = Directory(p.join(dest.path, 'preview'));
    for (final entry in modules['preview'] ?? const <ArchiveFile>[]) {
      if (!_isImage(entry.name.toLowerCase())) continue;
      previewDir.createSync(recursive: true);
      final target = p.join(previewDir.path, p.basename(entry.name));
      File(target).writeAsBytesSync(entry.readBytes() ?? Uint8List(0));
      out.previews.add(target);
    }

    // ── 5. 模块：icons / boots / framework-* / 字体 / theme_values ──
    for (final module in modules.entries) {
      final name = module.key;
      if (name == 'wallpaper' ||
          name == 'preview' ||
          name == 'description.xml') {
        continue;
      }
      final files = module.value;
      if (name == 'boots') {
        for (final entry in files) {
          if (p.basename(entry.name).toLowerCase() == 'bootanimation.zip') {
            out.extractBootAnimation(
              ZipDecoder().decodeBytes(entry.readBytes() ?? Uint8List(0)).files,
            );
          }
        }
        continue;
      }
      // 模块 zip：顶层文件本身是 zip（无扩展名、> 4 字节）
      if (files.length == 1 && files.first.name == name) {
        final bytes = files.first.readBytes() ?? Uint8List(0);
        if (!_looksLikeZip(bytes)) continue;
        final inner = ZipDecoder().decodeBytes(bytes);
        out.consumeModule(name, inner.files);
        continue;
      }
      out.consumeModule(name, files);
    }

    // wallpaper 如果是 zip 模块，从解包结果里补壁纸。
    if (out.wallpaper.isEmpty) {
      final png = File(p.join(dest.path, 'wallpaper', 'default_wallpaper.png'));
      final jpg = File(p.join(dest.path, 'wallpaper', 'default_wallpaper.jpg'));
      if (jpg.existsSync()) out.wallpaper = jpg.path;
      if (png.existsSync()) out.wallpaper = png.path;
    }

    // ── 6. 字体：fonts 模块或任意 ttf/otf ──
    final font = out.pickFont();
    if (font != null) {
      final target = File(p.join(dest.path, 'font${p.extension(font.name)}'));
      target.writeAsBytesSync(font.readBytes() ?? Uint8List(0));
      out.fontFile = target.path;
      out.modules.add(
        MintThemeModule(name: 'fonts', kind: 'font', fontFile: target.path),
      );
    }

    // ── 7. 主色 + 控件颜色（开关 / 返回 / 按钮 / 复选框 / 滑块 / 滚动条）──
    out.accent = _pickAccent(out.colors);
    out.controls.addAll(_pickControlColors(out.colors));
    // 音量条柱高是 dimen 不是颜色；跟着 controls 一起持久化，省一套字段。
    final columnHeight = out.dims['miui_volume_column_height'];
    if (columnHeight != null && columnHeight.isNotEmpty) {
      out.controls['volumeColumnHeight'] = columnHeight;
    }

    // ── 8. 全模块背景图落盘（预览器 / 按页背景 / 弹窗背景素材源）──
    out.backgrounds = out.materializeBackgrounds();

    final theme = MintTheme(
      id: id,
      dir: dest.path,
      title: out.title.isEmpty ? _baseName(mtzPath) : out.title,
      author: out.author,
      designer: out.designer,
      version: out.version,
      uiVersion: out.uiVersion,
      description: out.descriptionText,
      importedAt: DateTime.now(),
      wallpaper: out.wallpaper,
      lockWallpaper: out.lockWallpaper,
      settingsWindowBackground: out.settingsWindowBackground,
      settingsWindowBackgroundDark: out.settingsWindowBackgroundDark,
      settingsIcon: out.settingsIcon,
      volumeIcon: out.volumeIcon,
      volumeIconMuted: out.volumeIconMuted,
      assetsVersion: kThemeAssetsVersion,
      accent: out.accent,
      fontFile: out.fontFile,
      bootAnimationDir: out.bootAnimationDir,
      icons: out.icons,
      previews: out.previews,
      modules: out.modules,
      colors: out.colors,
      strings: out.strings,
      controls: out.controls,
      widgetAssets: out.widgetAssets,
      backgrounds: out.backgrounds,
      sourcePath: mtzPath,
    );
    File(p.join(dest.path, 'theme.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(theme.toJson()),
    );
    return theme;
  } catch (e) {
    try {
      dest.deleteSync(recursive: true);
    } catch (_) {}
    rethrow;
  }
}

/// 在后台 isolate 里只补「额外素材」：打开原 .mtz 的所有模块 zip，按导入时
/// 同一套优先级解出窗口背景、版本字标、音量条图标和全模块背景图。
Future<(String, String, String, String, String, List<MintThemeBackground>)>
extractThemeExtraAssets(String mtzPath, String themeDir) async {
  final out = _ThemeImportContext(themeDir, _baseName(themeDir), mtzPath);
  final archive = ZipDecoder().decodeStream(InputFileStream(mtzPath));
  for (final entry in archive) {
    if (!entry.isFile) continue;
    // 顶层无路径分隔的 zip 才是模块（boots/bootanimation.zip 这类目录内
    // 的 zip 不算）。老主题补解要扫全部模块 —— 背景图散在 contacts / mms /
    // downloads.ui 等每个应用模块里，不只 settings。
    if (entry.name.contains('/')) continue;
    final bytes = entry.readBytes() ?? Uint8List(0);
    if (!_looksLikeZip(bytes)) continue;
    final module = p.basename(entry.name);
    final isOverlay = kThemeOverlayModules.contains(module);
    for (final file in ZipDecoder().decodeBytes(bytes).files) {
      if (!file.isFile) continue;
      final path = file.name.replaceAll('\\', '/');
      final lower = p.basename(path).toLowerCase();
      if (!_isImage(lower)) continue;
      out.collectBackgroundCandidate(file, path, module);
      if (isOverlay) out._consumeOverlayAsset(file, path, lower);
    }
  }
  return (
    out.settingsWindowBackground,
    out.settingsWindowBackgroundDark,
    out.settingsIcon,
    out.volumeIcon,
    out.volumeIconMuted,
    out.materializeBackgrounds(),
  );
}

Future<String> _sha1OfFile(File file) async {
  final output = _DigestSink();
  final sink = sha1.startChunkedConversion(output);
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  return output.value.toString();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 一条背景图候选（物化前暂存 zip entry 引用与 dpi 排名）。
class _BgCandidate {
  _BgCandidate({
    required this.module,
    required this.name,
    required this.dark,
    required this.entry,
    required this.dpi,
  });

  final String module;
  final String name;
  final bool dark;
  final ArchiveFile entry;
  final int dpi;
}

/// 单个主题的导入上下文（解析细节太多，挪出主流程）。
class _ThemeImportContext {
  _ThemeImportContext(this.dir, this.id, this.sourcePath);

  final String dir;
  final String id;
  final String sourcePath;

  /// dpi 目录层级：nxhdpi > xxhdpi > xhdpi > hdpi > 其它
  /// （MIUI 主题包常用这几个桶，同名资源只留最清晰的一份）。
  static int _dpiRank(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('drawable-nxhdpi')) return 4;
    if (lower.contains('drawable-xxhdpi')) return 3;
    if (lower.contains('drawable-xhdpi')) return 2;
    if (lower.contains('drawable-hdpi')) return 1;
    return 0;
  }

  String description = '';
  String title = '';
  String author = '';
  String designer = '';
  String version = '';
  String uiVersion = '';
  String descriptionText = '';
  String wallpaper = '';
  String lockWallpaper = '';
  String settingsWindowBackground = '';
  String settingsWindowBackgroundDark = '';
  String settingsIcon = '';
  String volumeIcon = '';
  String volumeIconMuted = '';
  int _volumeIconRank = 99;
  int _volumeIconMutedRank = 99;

  /// theme_values 里的 `<dimen>`（只留音量条那几条，够 HUD 用）。
  final Map<String, String> dims = {};
  int _settingsBgLightRank = 99;
  int _settingsBgDarkRank = 99;
  int _settingsIconRank = 99;
  String fontFile = '';
  String bootAnimationDir = '';
  Color? accent;
  final List<MintThemeIcon> icons = [];
  final List<String> previews = [];
  final List<MintThemeModule> modules = [];
  final Map<String, String> colors = {};
  final Map<String, String> strings = {};
  final Map<String, String> controls = {};
  final Map<String, String> widgetAssets = {};
  final List<ArchiveFile> _fontCandidates = [];

  /// 背景图候选：key = 「明暗|模块|资源名」。同一资源会在多个 dpi 目录
  /// （nxhdpi / xxhdpi…）各放一份，只保留 dpi 最高的一份；夜间版（
  /// nightmode/）单独成条。
  final Map<String, _BgCandidate> _bgCandidates = {};

  /// 背景图（物化后的最终列表，由 [materializeBackgrounds] 填充）。
  List<MintThemeBackground> backgrounds = [];

  /// 识别一张图片是不是主题声明的背景资源，返回「资源名 + 明暗」。
  /// 认得的资源名是 MIUI 主题里真正承载整屏 / 页面背景的那几个
  /// （window_bg 家族 + 拨号盘 / 短信的页面背景）。
  static ({String name, bool dark})? parseBackgroundName(String lower) {
    if (!lower.endsWith('.png') &&
        !lower.endsWith('.jpg') &&
        !lower.endsWith('.webp')) {
      return null;
    }
    var base = lower;
    if (base.endsWith('.9.png')) {
      base = base.substring(0, base.length - '.9.png'.length);
    } else {
      base = base.substring(0, base.lastIndexOf('.'));
    }
    var dark = false;
    if (base.endsWith('_dark')) {
      dark = true;
      base = base.substring(0, base.length - '_dark'.length);
    } else if (base.endsWith('_light')) {
      base = base.substring(0, base.length - '_light'.length);
    }
    const names = {
      'window_bg',
      'miuix_appcompat_window_bg',
      'miuix_appcompat_settings_window_bg',
      'dialerpad_background',
      'dialer_background_pad',
      'conversation_bg',
    };
    if (!names.contains(base)) return null;
    return (name: base, dark: dark);
  }

  /// 记一条背景图候选（不消费 entry，模块的其他分类照常走）。
  void collectBackgroundCandidate(ArchiveFile entry, String path, String module) {
    final base = p.basename(path).toLowerCase();
    final parsed = parseBackgroundName(base);
    if (parsed == null) return;
    final isNight = path.toLowerCase().contains('nightmode/');
    final key = '${isNight ? 'n' : 'l'}|$module|${parsed.name}';
    final dpi = _dpiRank(path);
    final existing = _bgCandidates[key];
    if (existing == null || dpi > existing.dpi) {
      _bgCandidates[key] = _BgCandidate(
        module: module,
        name: parsed.name,
        dark: isNight || parsed.dark,
        entry: entry,
        dpi: dpi,
      );
    }
  }

  /// 把候选写盘成 `<dir>/backgrounds/<模块>_<资源名>[_dark].<ext>`，
  /// 返回最终背景列表（浅色在前、按资源名 / 模块排序）。
  List<MintThemeBackground> materializeBackgrounds() {
    if (_bgCandidates.isEmpty) return const [];
    final outDir = Directory(p.join(dir, 'backgrounds'))
      ..createSync(recursive: true);
    final result = <MintThemeBackground>[];
    final seen = <String>{};
    final entries = _bgCandidates.values.toList()
      ..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        if (byName != 0) return byName;
        final byModule = a.module.compareTo(b.module);
        if (byModule != 0) return byModule;
        return (a.dark ? 1 : 0) - (b.dark ? 1 : 0);
      });
    for (final c in entries) {
      final ext = p.extension(c.entry.name);
      final target = p.join(
        outDir.path,
        '${c.module}_${c.name}${c.dark ? '_dark' : ''}$ext',
      );
      if (seen.contains(target)) continue;
      seen.add(target);
      try {
        File(target).writeAsBytesSync(c.entry.readBytes() ?? Uint8List(0));
      } catch (_) {
        continue;
      }
      result.add(
        MintThemeBackground(
          module: c.module,
          name: c.name,
          path: target,
          dark: c.dark,
        ),
      );
    }
    return result;
  }

  void consumeModule(String name, Iterable<ArchiveFile> archive) {
    var assets = 0;
    var colorCount = 0;
    var stringCount = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final path = entry.name.replaceAll('\\', '/');
      final base = p.basename(path);
      final lower = base.toLowerCase();

      // 背景图候选（全模块收集；预览器 / 按页背景 / 弹窗背景的素材源）。
      if (_isImage(lower)) {
        collectBackgroundCandidate(entry, path, name);
      }

      if (lower == 'theme_values.xml') {
        final parsed = _parseThemeValues(_readText(entry));
        colors.addAll(parsed.colors);
        strings.addAll(parsed.strings);
        dims.addAll(parsed.dims);
        colorCount += parsed.colors.length;
        stringCount += parsed.strings.length;
        continue;
      }
      // 关于页（com.android.settings）与音量条（miui.systemui.plugin）素材。
      if (kThemeOverlayModules.contains(name) && _isImage(lower)) {
        if (_consumeOverlayAsset(entry, path, lower)) {
          assets++;
          continue;
        }
      }
      if (lower.endsWith('.ttf') ||
          lower.endsWith('.otf') ||
          lower.endsWith('.ttc')) {
        _fontCandidates.add(entry);
        continue;
      }
      if (name == 'icons' && _isImage(lower)) {
        final iconsDir = Directory(p.join(dir, 'icons'))
          ..createSync(recursive: true);
        final target = p.join(iconsDir.path, base);
        File(target).writeAsBytesSync(entry.readBytes() ?? Uint8List(0));
        icons.add(MintThemeIcon(p.basenameWithoutExtension(base), target));
        assets++;
        continue;
      }
      if (name == 'boots' && lower == 'bootanimation.zip') {
        extractBootAnimation(
          ZipDecoder().decodeBytes(entry.readBytes() ?? Uint8List(0)).files,
        );
        continue;
      }
      if (name == 'wallpaper' && _isImage(lower)) {
        final wallpaperDir = Directory(p.join(dir, 'wallpaper'))
          ..createSync(recursive: true);
        final target = p.join(wallpaperDir.path, base);
        File(target).writeAsBytesSync(entry.readBytes() ?? Uint8List(0));
        if (base.toLowerCase().contains('lock')) {
          lockWallpaper = target;
        } else if (wallpaper.isEmpty) {
          wallpaper = target;
        }
        continue;
      }
      if (_isImage(lower)) {
        assets++;
        final role = _widgetRoleFor(lower);
        if (role != null && !widgetAssets.containsKey(role)) {
          final widgetsDir = Directory(p.join(dir, 'widgets'))
            ..createSync(recursive: true);
          final target = p.join(widgetsDir.path, '${role}_$base');
          File(target).writeAsBytesSync(entry.readBytes() ?? Uint8List(0));
          widgetAssets[role] = target;
        }
      }
    }
    final kind = switch (name) {
      'icons' => 'icons',
      'boots' => 'boots',
      'framework-res' || 'framework-miui-res' => 'framework',
      'theme_values.xml' => 'values',
      _ => 'overlay',
    };
    modules.add(
      MintThemeModule(
        name: name,
        kind: kind,
        assetCount: assets,
        colorCount: colorCount,
        stringCount: stringCount,
      ),
    );
  }

  /// `com.android.settings` 里和「关于设备」页有关的资源：
  ///  - `window_bg_light/dark.9.png`：设置/关于窗口背景（主题作者放的那张图）
  ///  - `miui_version_logo[_dev].png` / `miui_logo_alpha.png`：主题版本图标
  /// `miui.systemui.plugin` 里的 `ic_miui_volume_*`：音量条图标。
  /// 返回 true 表示已经消费掉，不再走普通控件图片分类。
  bool _consumeOverlayAsset(ArchiveFile entry, String path, String lower) {
    final isNight = path.toLowerCase().contains('nightmode/');
    void save(String target) {
      File(
        p.join(dir, target),
      ).writeAsBytesSync(entry.readBytes() ?? Uint8List(0));
    }

    if (lower.startsWith('ic_miui_volume_')) {
      return _consumeVolumeIcon(lower, isNight, save);
    }
    if (lower == 'window_bg_light.9.png') {
      if (_settingsBgLightRank > 0) {
        save('settings_window_bg_light.png');
        settingsWindowBackground = p.join(dir, 'settings_window_bg_light.png');
        _settingsBgLightRank = 0;
      }
      return true;
    }
    if (lower == 'miuix_appcompat_settings_window_bg_light.9.png') {
      if (_settingsBgLightRank > 1) {
        save('settings_window_bg_light.png');
        settingsWindowBackground = p.join(dir, 'settings_window_bg_light.png');
        _settingsBgLightRank = 1;
      }
      return true;
    }
    if (lower == 'window_bg_dark.9.png') {
      if (_settingsBgDarkRank > 0) {
        save('settings_window_bg_dark.png');
        settingsWindowBackgroundDark = p.join(
          dir,
          'settings_window_bg_dark.png',
        );
        _settingsBgDarkRank = 0;
      }
      return true;
    }
    if (lower == 'miuix_appcompat_settings_window_bg_dark.9.png') {
      if (_settingsBgDarkRank > 1) {
        save('settings_window_bg_dark.png');
        settingsWindowBackgroundDark = p.join(
          dir,
          'settings_window_bg_dark.png',
        );
        _settingsBgDarkRank = 1;
      }
      return true;
    }
    // 「关于」页头那张字标：HyperOS 主题给 xiaomi_os_logo（宽字标，就是系统
    // 关于页顶上的 "Xiaomi HyperOS" 图），MIUI 主题给 miui_version_logo。
    // 同一主题里两张都有时按平台新旧取，夜间副本（nightmode/）不参与。
    const iconRanks = {
      'xiaomi_os_logo.png': 0,
      'xiaomi_os_logo_redmi.png': 1,
      'miui_version_logo.png': 2,
      'miui_version_logo_dev.png': 3,
      'miui_logo_alpha.png': 4,
    };
    final iconRank = iconRanks[lower];
    if (iconRank != null && !isNight && iconRank < _settingsIconRank) {
      save('settings_icon.png');
      settingsIcon = p.join(dir, 'settings_icon.png');
      _settingsIconRank = iconRank;
      return true;
    }
    return false;
  }

  /// 音量条图标 `ic_miui_volume_<流>[_mute][_collpased].png`（MIUI 的文件名把
  /// collapsed 拼成了 collpased，两种都认）。HUD 用展开态那张，media 流优先；
  /// 主题一般只声明媒体音量这一组。
  bool _consumeVolumeIcon(
    String lower,
    bool isNight,
    void Function(String target) save,
  ) {
    const prefix = 'ic_miui_volume_';
    if (!lower.endsWith('.png') ||
        isNight ||
        lower.length <= prefix.length + 4) {
      return true;
    }
    final key = lower.substring(prefix.length, lower.length - 4);
    if (key.endsWith('collpased') || key.endsWith('collapsed')) return true;
    final muted = key.endsWith('_mute');
    final stream = muted ? key.substring(0, key.length - 5) : key;
    final rank = stream == 'media' ? 0 : 1;
    final target = muted ? 'volume_icon_muted.png' : 'volume_icon.png';
    if (muted) {
      if (rank >= _volumeIconMutedRank) return true;
      save(target);
      volumeIconMuted = p.join(dir, target);
      _volumeIconMutedRank = rank;
    } else {
      if (rank >= _volumeIconRank) return true;
      save(target);
      volumeIcon = p.join(dir, target);
      _volumeIconRank = rank;
    }
    return true;
  }

  /// 解开机动画：desc.txt + partN/*.png → `<dir>/bootanimation/`。
  void extractBootAnimation(Iterable<ArchiveFile> archive) {
    final target = Directory(p.join(dir, 'bootanimation'));
    try {
      if (target.existsSync()) target.deleteSync(recursive: true);
      target.createSync(recursive: true);
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final path = entry.name.replaceAll('\\', '/');
        final dest = File(p.join(target.path, path));
        dest.parent.createSync(recursive: true);
        dest.writeAsBytesSync(entry.readBytes() ?? Uint8List(0));
      }
      final desc = File(p.join(target.path, 'desc.txt'));
      if (!desc.existsSync()) {
        target.deleteSync(recursive: true);
        return;
      }
      bootAnimationDir = target.path;
      modules.add(
        MintThemeModule(
          name: 'boots',
          kind: 'boots',
          assetCount: archive.where((f) => f.isFile).length,
        ),
      );
    } catch (_) {
      try {
        target.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  ArchiveFile? pickFont() {
    if (_fontCandidates.isEmpty) return null;
    // 优先 fonts/ 目录下的文件、其次任意位置第一个 ttf/otf。
    _fontCandidates.sort((a, b) {
      int score(ArchiveFile f) =>
          f.name.toLowerCase().contains('fonts/') ? 0 : 1;
      return score(a).compareTo(score(b));
    });
    return _fontCandidates.first;
  }
}

void _parseDescription(_ThemeImportContext ctx) {
  final xml = ctx.description;
  XmlDocument? doc;
  try {
    doc = XmlDocument.parse(xml);
  } catch (_) {
    doc = null;
  }
  String? text(String tag) {
    if (doc != null) {
      final nodes = doc.findAllElements(tag);
      if (nodes.isNotEmpty) {
        // description.xml 的结构是 <titles><title locale="zh_CN">…；
        // 先找 zh_CN，找不到再退回第一个。
        for (final node in nodes) {
          final value = node.innerText.trim();
          if (value.isNotEmpty) return value;
        }
      }
      return null;
    }
    return null;
  }

  ctx.version = text('version') ?? '';
  ctx.uiVersion = text('uiVersion') ?? '';
  ctx.title = text('title') ?? '';
  ctx.author = text('author') ?? '';
  ctx.designer = text('designer') ?? '';
  ctx.descriptionText = text('description') ?? '';
}

String _decodeXml(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'");

({
  Map<String, String> colors,
  Map<String, String> strings,
  Map<String, String> dims,
}) _parseThemeValues(String xml) {
  final colors = <String, String>{};
  final strings = <String, String>{};
  final dims = <String, String>{};
  if (xml.trim().isEmpty) {
    return (colors: colors, strings: strings, dims: dims);
  }
  void putDimen(String name, String value) {
    // HUD 只要音量条那几条尺寸，别把上千条系统 dimen 灌进缓存。
    if (name.startsWith('miui_volume')) dims[name] = value;
  }

  try {
    final doc = XmlDocument.parse(_stripInvalidXml(xml));
    for (final node in doc.descendants.whereType<XmlElement>()) {
      final name = node.getAttribute('name');
      if (name == null || name.isEmpty) continue;
      if (node.name.local == 'color') {
        final value = node.innerText.trim();
        if (value.startsWith('#') || value.startsWith('0x')) {
          colors[name] = value;
        }
      } else if (node.name.local == 'string') {
        final value = node.innerText.trim();
        if (value.isNotEmpty) strings[name] = value;
      } else if (node.name.local == 'dimen' ||
          (node.name.local == 'item' &&
              node.getAttribute('format') == 'dimension')) {
        final value = node.innerText.trim();
        if (value.isNotEmpty) putDimen(name, value);
      }
    }
  } catch (_) {
    // XML 里常混着作者写的中文注释 / 裸文本（不是合法 XML），正则兜底。
    for (final m in RegExp(
      r'<color\s+name="([^"]+)"[^>]*>([^<]+)</color>',
    ).allMatches(xml)) {
      final value = m.group(2)!.trim();
      if (value.startsWith('#')) colors[m.group(1)!] = value;
    }
    for (final m in RegExp(
      r'<string\s+name="([^"]+)"[^>]*>([^<]+)</string>',
    ).allMatches(xml)) {
      strings[m.group(1)!] = _decodeXml(m.group(2)!.trim());
    }
    for (final m in RegExp(
      r'<dimen\s+name="([^"]+)"[^>]*>([^<]+)</dimen>',
    ).allMatches(xml)) {
      putDimen(m.group(1)!, m.group(2)!.trim());
    }
  }
  return (colors: colors, strings: strings, dims: dims);
}

String _stripInvalidXml(String xml) {
  // 中文注释里的裸文本会让 XmlDocument 直接抛错，交给正则兜底即可。
  return xml;
}

/// 控件颜色：按 MIUI 的资源名把 theme_values 里散落的声明归到角色上。
///
/// 开关没有独立图片时就靠 `miuix_appcompat_sliding_button_bar_on_*` 这类
/// 颜色驱动（本主题就是这种情况，值是主色 #FF60C0FD）。
Map<String, String> _pickControlColors(Map<String, String> colors) {
  const patterns = <String, List<String>>{
    'switch': [
      r'miuix_appcompat_sliding_button_bar_on',
      r'sliding_button_bar_on',
      r'switch.*(checked|on|track)',
    ],
    'back': [r'^miui_back_color$', r'back.*color'],
    'button': [
      r'miuix_appcompat_button_bg_primary_color_normal',
      r'button_bg_primary',
      r'action_button_positive_color',
      r'button.*primary.*normal',
    ],
    'checkbox': [
      r'miuix_appcompat_checkbox_btn_on_background_color',
      r'checkbox.*(on|checked)',
    ],
    'radio': [
      r'miuix_preference_btn_radio_arrow_color',
      r'radio.*(checked|selected)',
    ],
    'seekbar': [
      r'miuix_appcompat_progress_primary_color',
      r'seekbar.*(pointer|progress|thumb|big)',
      r'slider.*(progress|thumb|on)',
    ],
    'scrollbar': [r'scrollbar.*thumb'],
    'card': [
      r'^card_view_background_color$',
      r'^device_card_background$',
      r'progress_card_view_background_color',
      r'my_device_info_item_background_color',
    ],
    'dialog': [r'daynight_dialog_bg', r'^miuix_appcompat_dialog_bg'],
    'dialogSelected': [
      r'dialog.*(list_item_bg|selected).*checked',
      r'usb_dialog_selected_bg_color',
      r'list_item_bg_dialog_color_checked',
    ],
    // 音量条（miui.systemui.plugin 的 miui_volume_*）。用精确名，不然会被
    // seekbar / card 那几条模糊式抢走。
    'volumeAccent': [r'^miui_volume_color_accent$'],
    'volumeTrack': [r'^miui_volume_bg_color$'],
    'volumeTrackCollapse': [r'^miui_volume_bg_color_collapse$'],
    'volumeButton': [r'^miui_volume_color_btn_seleted$'],
    'volumeDisabled': [r'^miui_volume_disabled_color$'],
    'volumeExpand': [r'^miui_volume_expand_background$'],
  };
  final result = <String, String>{};
  final keys = colors.keys.toList()
    ..sort((a, b) {
      // 同名资源优先浅色（本仓库的 UI 主要跟明暗两套走，浅色名更好匹配）。
      int rank(String k) =>
          k.endsWith('_light') ? 0 : (k.contains('dark') ? 2 : 1);
      return rank(a).compareTo(rank(b));
    });
  for (final entry in patterns.entries) {
    for (final pattern in entry.value) {
      final re = RegExp(pattern, caseSensitive: false);
      for (final key in keys) {
        if (!re.hasMatch(key)) continue;
        final color = _parseColor(colors[key]);
        if (color == null || color.a < 0.1) continue;
        result[entry.key] = colors[key]!;
        break;
      }
      if (result.containsKey(entry.key)) break;
    }
  }
  return result;
}

/// 图片类控件资源的角色归类（主题里没有开关图片时就不会有 switch* 角色）。
String? _widgetRoleFor(String base) {
  if (!base.endsWith('.png') && !base.endsWith('.webp')) return null;
  final n = base.toLowerCase();
  if (n.contains('switch') && !n.contains('toggle_slider')) {
    if (n.contains('thumb')) return 'switchThumb';
    if (n.contains('off')) return 'switchOff';
    if (n.contains('track')) return 'switchTrack';
    return 'switchOn';
  }
  if (n.contains('gesture_back')) return 'backArt';
  if (n.contains('back') && (n.contains('arrow') || n.contains('ic_back'))) {
    return 'back';
  }
  if (n.contains('button') && (n.contains('normal') || n.contains('main'))) {
    return 'button';
  }
  if (n.contains('checkbox')) return 'checkbox';
  if (n.contains('radio')) return 'radio';
  if (n.contains('seekbar')) return 'seekbar';
  if (n.contains('scrollbar')) return 'scrollbar';
  return null;
}

/// 主色挑选：MIUI 主题通常把主色写在这几个名字上。
Color? _pickAccent(Map<String, String> colors) {
  const preferred = [
    'miuix_color_blue_light_primary_default',
    'miuix_color_blue_dark_primary_default',
    'design_default_color_primary',
    'design_default_color_primary_variant',
    'miui_color_blue_light_primary_default',
    'miuix_appcompat_sliding_button_bar_on_light',
    'miuix_appcompat_svg_icon_color_blue_selected_light',
    'colorAccent',
    'miuix_preference_white',
  ];
  for (final key in preferred) {
    final parsed = _parseColor(colors[key]);
    if (parsed != null) return parsed;
  }
  // 没有标准名：在声明色里挑最鲜艳、不透明、不是黑白的那一个。
  Color? best;
  var bestScore = -1.0;
  for (final raw in colors.values) {
    final color = _parseColor(raw);
    if (color == null || color.a < 0.5) continue;
    final hsv = _toHsv(color);
    if (hsv.s < 0.18) continue; // 灰 / 白 / 黑
    final score = hsv.s * (0.35 + 0.65 * (hsv.v > 0.25 ? 1 : hsv.v));
    if (score > bestScore) {
      bestScore = score;
      best = color;
    }
  }
  if (best != null) return best;
  for (final raw in colors.values) {
    final color = _parseColor(raw);
    if (color != null && color.a > 0.9) return color;
  }
  return null;
}

Color? _parseColor(String? raw) {
  if (raw == null) return null;
  var text = raw.trim();
  if (text.startsWith('0x')) text = '#${text.substring(2)}';
  if (!text.startsWith('#')) return null;
  var hex = text.substring(1);
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length == 8) {
    final value = int.tryParse(hex, radix: 16);
    return value == null ? null : Color(value);
  }
  return null;
}

({double h, double s, double v}) _toHsv(Color color) {
  final r = color.r;
  final g = color.g;
  final b = color.b;
  final maxC = [r, g, b].reduce((a, b) => a > b ? a : b);
  final minC = [r, g, b].reduce((a, b) => a < b ? a : b);
  final delta = maxC - minC;
  var h = 0.0;
  if (delta > 1e-6) {
    if (maxC == r) {
      h = 60 * (((g - b) / delta) % 6);
    } else if (maxC == g) {
      h = 60 * ((b - r) / delta + 2);
    } else {
      h = 60 * ((r - g) / delta + 4);
    }
  }
  if (h < 0) h += 360;
  final s = maxC <= 1e-6 ? 0.0 : delta / maxC;
  return (h: h, s: s, v: maxC);
}

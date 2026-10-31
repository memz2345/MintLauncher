/// 全局界面风格。对应 InstallerX 的 `showMiuixUI` 开关扩展成三选一：
/// 同一个页面写两份实现，根处按这个值决定渲染哪一套叶子；
/// fluent 走 Material 叶子 + Fluent 主题桥 + fluent_ui 的侧边栏/图标。
enum UiStyle {
  /// Material 3 Expressive：iOS 推入转场、M3 组件。
  materialExpressive,

  /// 小米 HyperOS：squircle 圆角、Folme 弹簧、MiuixTopAppBar / NavigationBar。
  miuix,

  /// Windows 11 Fluent：NavigationView 侧边栏、FluentIcons、Segoe 观感。
  fluent,
}

extension UiStyleX on UiStyle {
  String get id => switch (this) {
    UiStyle.materialExpressive => 'material',
    UiStyle.miuix => 'miuix',
    UiStyle.fluent => 'fluent',
  };

  /// 没存过（全新安装）走默认的 miuix。
  static UiStyle fromId(String? id) => switch (id) {
    'material' => UiStyle.materialExpressive,
    'fluent' => UiStyle.fluent,
    _ => UiStyle.miuix,
  };

  String get label => switch (this) {
    UiStyle.materialExpressive => 'Material 3',
    UiStyle.miuix => '小米 HyperOS（miuix）',
    UiStyle.fluent => 'Windows 11 Fluent（fluent）',
  };

  bool get isMiuix => this == UiStyle.miuix;
  bool get isFluent => this == UiStyle.fluent;
}

/// 窗口背景材质（仅在 Windows 10 1809+ 生效；能力由 runner 原生侧探测）。
///
/// 对应 WinUI 的 `SystemBackdrop`：云母 / 亚克力 / 标签页 / Aero。
enum WindowBackdropMode {
  disabled,
  mica,
  acrylic,
  tabbed,
  aero;

  String get id => switch (this) {
    WindowBackdropMode.disabled => 'off',
    WindowBackdropMode.mica => 'mica',
    WindowBackdropMode.acrylic => 'acrylic',
    WindowBackdropMode.tabbed => 'tabbed',
    WindowBackdropMode.aero => 'aero',
  };

  String get label => switch (this) {
    WindowBackdropMode.disabled => '关闭',
    WindowBackdropMode.mica => '云母 Mica',
    WindowBackdropMode.acrylic => '亚克力 Acrylic',
    WindowBackdropMode.tabbed => '标签页 Tabbed',
    WindowBackdropMode.aero => 'Aero 毛玻璃',
  };

  String get description => switch (this) {
    WindowBackdropMode.disabled => '纯色窗口背景',
    WindowBackdropMode.mica => 'Windows 11 桌面壁纸染色',
    WindowBackdropMode.acrylic => '实时模糊窗口后的内容',
    WindowBackdropMode.tabbed => 'Windows 11 标签页式深模糊',
    WindowBackdropMode.aero => 'Windows 10 经典毛玻璃',
  };

  static WindowBackdropMode fromId(String? id) => switch (id) {
    'off' => WindowBackdropMode.disabled,
    'acrylic' => WindowBackdropMode.acrylic,
    'tabbed' => WindowBackdropMode.tabbed,
    'aero' => WindowBackdropMode.aero,
    _ => WindowBackdropMode.mica,
  };
}

/// 下载源：BMCLAPI 镜像（国内快）/ 官方 Mojang / 自动（默认 BMCL，失败回官方）。
enum DownloadSource {
  auto,
  bmcl,
  official;

  String get id => switch (this) {
    DownloadSource.auto => 'auto',
    DownloadSource.bmcl => 'bmcl',
    DownloadSource.official => 'official',
  };

  static DownloadSource fromId(String? id) => switch (id) {
    'bmcl' => DownloadSource.bmcl,
    'official' => DownloadSource.official,
    _ => DownloadSource.auto,
  };
}

/// 游戏窗口模式（PCL2 `LaunchArgumentWindowType` 的裁剪版）。
enum GameWindowMode {
  defaultSize('default', '默认 854 × 480'),
  sameAsLauncher('sameAsLauncher', '与启动器窗口大小相同'),
  custom('custom', '自定义尺寸'),
  fullscreen('fullscreen', '全屏');

  const GameWindowMode(this.id, this.label);
  final String id;
  final String label;

  static GameWindowMode fromId(String? id) => switch (id) {
    'sameAsLauncher' => GameWindowMode.sameAsLauncher,
    'custom' => GameWindowMode.custom,
    'fullscreen' => GameWindowMode.fullscreen,
    _ => GameWindowMode.defaultSize,
  };
}

/// 游戏启动后启动器自身的行为（PCL2 `LaunchArgumentVisible`）。
enum LauncherVisibility {
  keep('keep', '保持打开'),
  minimize('minimize', '最小化'),
  close('close', '关闭启动器');

  const LauncherVisibility(this.id, this.label);
  final String id;
  final String label;

  static LauncherVisibility fromId(String? id) => switch (id) {
    'minimize' => LauncherVisibility.minimize,
    'close' => LauncherVisibility.close,
    _ => LauncherVisibility.keep,
  };
}

/// 游戏进程优先级（PCL2 `LaunchArgumentPriority`，Windows 生效）。
enum ProcessPriority {
  high('high', '高', 'High'),
  normal('normal', '中', 'Normal'),
  low('low', '低', 'BelowNormal');

  const ProcessPriority(this.id, this.label, this.windowsName);
  final String id;
  final String label;
  final String windowsName;

  static ProcessPriority fromId(String? id) => switch (id) {
    'high' => ProcessPriority.high,
    'low' => ProcessPriority.low,
    _ => ProcessPriority.normal,
  };
}

/// GC 预设（PCL2 `LaunchAdvanceGC` 的常用档）。
enum GcPreset {
  auto('auto', '自动（不追加）'),
  tunedG1('tunedG1', '调优 G1GC'),
  g1('g1', '标准 G1GC'),
  zgc('zgc', 'ZGC'),
  generationalZgc('generationalZgc', '分代 ZGC'),
  none('none', '由版本 JSON 决定');

  const GcPreset(this.id, this.label);
  final String id;
  final String label;

  static GcPreset fromId(String? id) => switch (id) {
    'tunedG1' => GcPreset.tunedG1,
    'g1' => GcPreset.g1,
    'zgc' => GcPreset.zgc,
    'generationalZgc' => GcPreset.generationalZgc,
    'none' => GcPreset.none,
    _ => GcPreset.auto,
  };

  List<String> get args => switch (this) {
    GcPreset.tunedG1 => const [
      '-XX:+UseG1GC',
      '-XX:G1NewSizePercent=20',
      '-XX:G1ReservePercent=20',
      '-XX:MaxGCPauseMillis=50',
      '-XX:G1HeapRegionSize=16M',
    ],
    GcPreset.g1 => const ['-XX:+UseG1GC'],
    GcPreset.zgc => const ['-XX:+UseZGC'],
    GcPreset.generationalZgc => const ['-XX:+UseZGC', '-XX:+ZGenerational'],
    GcPreset.auto || GcPreset.none => const [],
  };
}

/// 强制图形后端（HMCL `graphicsBackend` / `Renderer` 的裁剪版）。
///
/// `cpu` = Windows 上加载 HMCL 同款 Mesa Loader（LLVMpipe 软件 OpenGL），
/// 其它平台退化为环境变量软件渲染。
enum GraphicsBackend {
  auto('auto', '自动（跟随游戏）'),
  openGl('opengl', '强制 OpenGL'),
  vulkan('vulkan', '强制 Vulkan'),
  cpu('cpu', 'CPU 软件渲染（Mesa LLVMpipe）');

  const GraphicsBackend(this.id, this.label);
  final String id;
  final String label;

  static GraphicsBackend fromId(String? id) => switch (id) {
    'opengl' => GraphicsBackend.openGl,
    'vulkan' => GraphicsBackend.vulkan,
    'cpu' => GraphicsBackend.cpu,
    _ => GraphicsBackend.auto,
  };
}

/// Android 渲染器（FCL `RendererManager` 的六档，全部同步在 jniLibs 里）。
///
/// 这些不是「画质选项」，而是**OpenGL 实现的替换层**：Minecraft Java 版只会
/// 调桌面 OpenGL，Android 上必须由其中一个把 GL 调用翻译成 GLES / Vulkan。
/// 换渲染器本质是在「兼容性 / 性能 / 功能」之间换取舍，所以默认给最稳的
/// Holy GL4ES，选择界面必须把取舍讲清楚。
enum AndroidRenderer {
  gl4es(
    'gl4es',
    'Holy GL4ES',
    'FCL 的经典默认档：GL4ES 把桌面 OpenGL 1.x/2.x 翻译成 GLES。兼容性最好，'
        '几乎所有版本都能进；不支持现代光影与高版本特性。',
    '兼容性最好',
    '1.21.4',
  ),
  nggl4es(
    'nggl4es',
    'Krypton Wrapper（NG GL4ES）',
    'GL4ES 的新分支，同接口重写，多数机型上帧率更高、花屏更少。'
        '遇到 Holy GL4ES 性能不理想时优先换这个。',
    '更快的 GL4ES',
    '26.2',
  ),
  virgl(
    'virgl',
    'VirGL',
    'Mesa 的 VirGL：把 GL 命令转给宿主 GPU 执行，支持到 OpenGL 3.3+，'
        '能吃部分光影。开销大，中低端机容易掉帧。',
    '支持高版本特性',
    '26.2',
  ),
  vgpu(
    'vgpu',
    'VGPU',
    '轻量虚拟 GPU 层，资源占用低，适合低端机跑老版本（≤1.16）。'
        '高版本可能直接黑屏。',
    '低端机省资源',
    '1.16.5',
  ),
  zink(
    'zink',
    'Zink',
    'OpenGL → Vulkan 转译（Mesa Zink），同时把系统 Vulkan 驱动接给游戏。'
        '26.3+ 的 RenderPearl 会直接走 Vulkan；Adreno 上已验证能进主菜单，'
        '但新渲染后端目前可能有文字/贴图花屏。',
    '26.3+ / Vulkan',
    '',
  ),
  freedreno(
    'freedreno',
    'Freedreno',
    '高通 Adreno 的开源驱动栈（Turnip/Freedreno）。仅骁龙设备有意义，'
        '其它 GPU 一定失败。',
    '仅骁龙',
    '26.2',
  ),
  mobileglues(
    'mobileglues',
    'MobileGlues',
    'FCL 1.3.4.3 新增的 GL/EGL 兼容层，自带 EGL，1.17–26.2 的现代版本'
        '可以试试；26.3 的 RenderPearl 会在着色器编译阶段失败，'
        '跑 26.3 请用 Zink。',
    '1.17–26.2',
    '26.2',
  ),
  sfpew(
    'sfpew',
    'SimpleFPEWrapper',
    'FCL 新增的轻量 FPE 包装层，给高版本但驱动挑剔的机器兜底。'
        '实测 26.3 在 Adreno 上起不来，没有特殊需求别选。',
    '实验',
    '',
  );

  const AndroidRenderer(
    this.id,
    this.label,
    this.description,
    this.badge,
    this.maxGameVersion,
  );

  final String id;
  final String label;

  /// 设置页里的详细说明（讲清取舍，不是营销文案）。
  final String description;

  /// 列表右侧的小标签。
  final String badge;

  /// 这个渲染器能启动的最高游戏版本（空 = 不限制）。
  /// 对应 FCL `Renderer.displayMaxMCver`：超过它 FCL 直接不展示该档。
  final String maxGameVersion;

  bool get unlimitedVersion => maxGameVersion.isEmpty;

  /// 版本号比较（只取数字段；`26.3` / `1.21.4` / `a1.0.15`）。
  static List<int> _parts(String version) {
    final match = RegExp(
      r'(\d+)\.(\d+)(?:\.(\d+))?',
    ).firstMatch(version.trim());
    if (match == null) return const [];
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.tryParse(match.group(3) ?? '0') ?? 0,
    ];
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      final diff = a[i] - b[i];
      if (diff != 0) return diff;
    }
    return 0;
  }

  /// 能否启动 [versionId]（非数字版本号一律放行，交给实际启动结果判断）。
  bool supportsVersion(String versionId) {
    if (unlimitedVersion) return true;
    final game = _parts(versionId);
    final limit = _parts(maxGameVersion);
    if (game.isEmpty || limit.isEmpty) return true;
    return _compare(game, limit) <= 0;
  }

  static AndroidRenderer fromId(String? id) {
    for (final r in AndroidRenderer.values) {
      if (r.id == id) return r;
    }
    return AndroidRenderer.gl4es;
  }
}

/// 版本隔离模式（PCL2 `LaunchArgumentIndieV2` 的五档）。
///
/// 不管选哪档，**版本目录下已有 mods / saves 的版本都会自动隔离**
/// （PCL2 `PathIndie` 初始化的优先级最高分支）；单版本仍可在版本设置里
/// 强制开 / 关。
enum IsolationMode {
  off('off', '关闭', '所有版本共用 .minecraft'),
  loaders('loaders', '有加载器的版本', 'Fabric / Forge 等模组化版本隔离'),
  oldSnapshots('oldSnapshots', '老版本与快照', '远古版 / 快照 / 预发布隔离'),
  oldAndLoaders('oldAndLoaders', '老版本、快照与有加载器的版本', '上面两类都隔离'),
  all('all', '全部隔离', '每个版本一个独立目录');

  const IsolationMode(this.id, this.label, this.desc);
  final String id;
  final String label;
  final String desc;

  static IsolationMode fromId(String? id) => switch (id) {
    'loaders' => IsolationMode.loaders,
    'oldSnapshots' => IsolationMode.oldSnapshots,
    'oldAndLoaders' => IsolationMode.oldAndLoaders,
    'all' => IsolationMode.all,
    _ => IsolationMode.off,
  };
}

/// 版本画像（隔离模式求值用；由 LauncherController 通过
/// `SettingsService.versionFactsProbe` 注入，SettingsService 不直接碰磁盘）。
class VersionFacts {
  const VersionFacts({
    required this.modable,
    required this.oldOrSnapshot,
    required this.hasOwnGameData,
  });

  /// 版本支持装模组（带 Fabric / Forge 等加载器）。
  final bool modable;

  /// 老版本（<1.7）或快照 / 预发布。
  final bool oldOrSnapshot;

  /// 版本目录下已有 mods / saves（PCL2 的自动隔离信号）。
  final bool hasOwnGameData;
}

/// 一次崩溃 / 启动失败的完整上下文（给日志弹窗用）。
class CrashReportData {
  const CrashReportData({
    required this.title,
    required this.version,
    required this.log,
    this.exitCode = 0,
    this.cause,
    this.suggestion,
    this.detail,
    this.logPath = '',
    this.inGameShown = false,
  });

  /// 「游戏崩溃」/「启动失败」。
  final String title;
  final String version;
  final int exitCode;
  final String? cause;
  final String? suggestion;
  final String? detail;

  /// 完整日志（启动器输出 + 游戏输出 + 崩溃报告）。
  final String log;
  final String logPath;

  /// 游戏内已经弹过崩溃页（Android），启动器回来后不必再自动弹一次。
  final bool inGameShown;
}

/// 是否像崩溃日志（与 Android GameActivity 的 CRASH_MARKERS 对齐）。
bool looksLikeCrashLog(String text) {
  const markers = [
    '---- Minecraft Crash Report ----',
    'A fatal error has been detected by the Java Runtime Environment',
    'Exception in thread',
    'Caused by:',
    'java.lang.reflect.InvocationTargetException',
    'java.lang.ExceptionInInitializerError',
    'java.lang.NoClassDefFoundError',
    'java.lang.NoSuchMethodError',
    'java.lang.UnsatisfiedLinkError',
    'java.lang.OutOfMemoryError',
    'Could not find or load main class',
    'FATAL ERROR',
    'hs_err_pid',
  ];
  final lower = text.toLowerCase();
  return markers.any((m) => lower.contains(m.toLowerCase()));
}

/// 崩溃日志自动分析（HMCL CrashReportAnalyzer / PCL2 报错字典的精简版）：
/// 对游戏输出/退出码/崩溃报告做关键词匹配，给出人话结论。
class CrashAnalysis {
  const CrashAnalysis({
    required this.cause,
    required this.suggestion,
    this.evidence,
  });

  /// 可能原因（一句话）。
  final String cause;

  /// 建议操作。
  final String suggestion;

  /// 命中的日志行（给用户对证据用；可空）。
  final String? evidence;
}

/// 分析一段日志/崩溃报告文本。找不到已知模式返回 null（别硬编原因）。
CrashAnalysis? analyzeCrashText(String text) {
  CrashAnalysis? match(String pattern, String cause, String suggestion) {
    final re = RegExp(pattern, caseSensitive: false, multiLine: true);
    if (!re.hasMatch(text)) return null;
    // 挑第一行命中的作证据，超长截断（标题栏/卡片里只展示一行）。
    for (final line in text.split('\n')) {
      if (re.hasMatch(line)) {
        final trimmed = line.trim();
        return CrashAnalysis(
          cause: cause,
          suggestion: suggestion,
          evidence: trimmed.length > 160
              ? '${trimmed.substring(0, 160)}…'
              : trimmed,
        );
      }
    }
    return CrashAnalysis(cause: cause, suggestion: suggestion);
  }

  // ── 远古版 AWT（alpha/beta/1.5.2 及以下）──
  final awt = match(
    r'X11GraphicsEnvironment|No X11 DISPLAY|java\.awt\.HeadlessException|Applet\.<init>',
    '远古版需要 AWT 桌面窗口，当前 Android 运行时没有 X11 图形环境',
    'alpha / beta / 1.5.2 及以下版本依赖 java.awt（Frame / Applet），'
        'FCL 的 Android JRE 不带 X11 显示，手机上暂时启动不了这些版本；'
        '请改用 1.6 及以上版本，或在电脑上运行该远古版',
  );
  if (awt != null) return awt;

  // ── 内存 ──
  final memory = match(
    r'java\.lang\.OutOfMemoryError: (Java heap space|Metaspace|GC overhead limit exceeded|Unable to create native thread)',
    '游戏内存不足（OutOfMemoryError）',
    '在设置里把「最大内存」调大（建议 4096MB 以上；整合包建议 6144MB+）。整合包/大模组包建议同时关掉其它占内存的程序',
  );
  if (memory != null) return memory;
  final reserve = match(
    r'Could not reserve enough space for object heap',
    '系统无法分配设定的堆内存',
    '当前内存设置可能超过物理内存，或用了 32 位 Java —— 在设置里调小内存或换 64 位 Java',
  );
  if (reserve != null) return reserve;
  final vmInit = match(
    r'Error occurred during initialization of VM|Failed to create (a )?(process|thread)',
    'JVM 启动失败（VM 初始化 / 进程线程创建）',
    '内存设置过大或系统资源紧张：调小「最大内存」，关闭其它大型程序后重试',
  );
  if (vmInit != null) return vmInit;

  // ── Java 版本 ──
  final classVersion = match(
    r'UnsupportedClassVersionError|has been compiled by a more recent version|unsupported major\.minor version|UnsupportedMajorMinorVersion',
    'Java 版本过低，跑不了这个版本/模组',
    '安装或选择更高版本的 Java（1.16.5 及以下用 Java 8/11，1.17 用 16/17，1.18+ 用 17，1.20.5+ 用 21）',
  );
  if (classVersion != null) return classVersion;
  final noJava = match(
    r'Cannot run program.*(javaw?|java\.exe)|系统找不到指定的文件.*(java|javaw)|CreateProcess error=2',
    '找不到 Java 可执行文件',
    '在设置里选择已安装的 Java，或在下载页让启动器自动装一个 JRE',
  );
  if (noJava != null) return noJava;

  // ── 模块系统 / 混合 Java ──
  final modules = match(
    r'InaccessibleObjectException|Unable to make .* accessible|module java\.base does not (open|export)',
    'Java 模块系统拦截了反射（常见于旧 Forge/插件跑在高版本 Java 上）',
    '给这个版本换用旧一些的 Java（8 或 17），或在版本设置里加对应 --add-opens JVM 参数',
  );
  if (modules != null) return modules;
  final resolution = match(
    r'ResolutionException|LayerInstantiationException',
    '模块解析失败（Forge/NeoForge 引导问题）',
    '重装该版本的 Forge/NeoForge，或检查 libraries 目录是否完整；也可能是 Java 版本不匹配',
  );
  if (resolution != null) return resolution;

  // ── 模组加载（Forge/NeoForge 与通用条目）──
  final forgeMod = match(
    r'Mod resolution|Failed to (load|create) mod|fml\.modloading|LoadingFailedException|DuplicateModsFoundException|Found (a )?duplicate mod',
    '模组加载失败',
    '看日志里第一个出错的 mod：更新/删除该模组，或补齐其前置；同名的重复 mod 也要删掉一份',
  );
  if (forgeMod != null) return forgeMod;
  final deps = match(
    r'[Mm]issing or unsupported mandatory dependencies|Missing or invalid mod dependency|Missing mods',
    '模组缺少前置依赖',
    '日志里列出了缺的 mod 名，去 Modrinth 搜对应前置装上（注意前置也要匹配游戏版本与加载器）',
  );
  if (deps != null) return deps;

  // ── 模组加载（Fabric/Quilt）──
  final fabricMod = match(
    r'net\.fabricmc\.loader\.(?:.*Exception|.*Error)|FabricLoader.*(?:Exception|Error)|quilt_loader',
    '模组加载失败（Fabric/Quilt）',
    '日志里第一个 Failed to load mod 就是元凶：更新/删除该模组；多数 Fabric 模组还需要 Fabric API',
  );
  if (fabricMod != null) return fabricMod;
  final mixin = match(
    r'MixinApplyError|Mixin apply failed|org\.spongepowered\.asm\.mixin\.(?:.*Exception|.*Error)|InjectionError|Critical injection failure',
    'Mixin 注入失败（模组与版本/其它模组不兼容）',
    '确认模组与游戏版本匹配；移除最近新加的模组，逐个排查冲突',
  );
  if (mixin != null) return mixin;

  // ── 渲染 / 显卡 ──
  final gl = match(
    r"GLFW error|Failed to create (the )?window|Cannot find OpenGL|GLX|WGL|OpenGL (is not supported|profile)|Pixel format not accelerated|Couldn'?t set pixel format",
    'OpenGL / 窗口初始化失败',
    '更新显卡驱动；核显机器确认游戏没跑在错误显卡上；远程桌面里跑游戏也常这样，请在本机控制台运行',
  );
  if (gl != null) return gl;
  final gpuCrash = match(
    r'nvlddmkm|aticfx|ig9icd|The driver (for )?(the )?GPU|gpu crashed|DEVICE_LOST|Device removed',
    '显卡驱动崩溃（GPU Device Lost）',
    '驱动崩溃多半是驱动太旧或超频不稳：更新/重装显卡驱动，光影材质先关掉试试',
  );
  if (gpuCrash != null) return gpuCrash;

  // ── 文件 / 系统 ──
  final access = match(
    r'AccessDeniedException|Access is denied|拒绝访问',
    '文件访问被拒绝',
    '游戏目录被占用或权限不足：关掉杀毒软件/其它启动器，关闭占用该目录的程序，必要时以管理员运行',
  );
  if (access != null) return access;
  final locked = match(
    r'being used by another process|The process cannot access the file|由另一进程使用',
    '文件被其它进程占用',
    '关闭其它启动器/杀毒/云同步对该目录的占用后重试；重启电脑也能释放残留句柄',
  );
  if (locked != null) return locked;
  final disk = match(
    r'There is not enough space on the disk|磁盘空间不足|No space left on device',
    '磁盘空间不足',
    '清理游戏目录所在盘的空间（至少留 2GB），再重试',
  );
  if (disk != null) return disk;
  final missing = match(
    r'NoSuchFileException.*(libraries|assets|versions)|FileNotFoundException.*(libraries|assets|versions)|error downloading.*(piston-data|bmclapi)',
    '版本文件缺失或下载失败',
    '重装该版本（下载页点对应版本），或切换下载源（自动/BMCLAPI/官方）后重试',
  );
  if (missing != null) return missing;
  final zip = match(
    r'ZipException|invalid (zip|CEN) header|zip file is empty|Not in GZIP format',
    '文件损坏（zip/jar 校验失败）',
    '通常是下载中断造成的：删除报错对应的 jar/文件让它重新下载，或直接重装该版本',
  );
  if (zip != null) return zip;

  // ── 类冲突 ──
  final classNotFound = match(
    r'java\.lang\.NoClassDefFoundError|java\.lang\.ClassNotFoundException',
    '类缺失（NoClassDefFoundError / ClassNotFoundException）',
    '大概率是混装了不同加载器的库或删了依赖：删掉版本重装，别把一个加载器的库装给另一个',
  );
  if (classNotFound != null) return classNotFound;
  final noMethod = match(
    r'java\.lang\.NoSuchMethodError|java\.lang\.NoSuchFieldError',
    '库版本冲突（NoSuchMethodError）',
    '混装了不同版本的库/模组：更新所有模组到同一游戏版本的重编译版，或删掉版本重装',
  );
  if (noMethod != null) return noMethod;

  // ── 登录 / 会话 ──
  final session = match(
    r'Invalid session|Failed to verify username|Invalid credentials|Session contains no identifier|invalid token',
    '登录会话无效（皮肤/联机被拒）',
    '离线模式进不了正版服务器属正常现象；外置登录请检查账户的服务器地址与密码是否正确',
  );
  if (session != null) return session;

  // ── 崩溃报告文件（游戏把报告写盘了）──
  final report = match(
    r'#\s*A fatal error has been detected|crash-reports[/\\]crash-|---- Minecraft Crash Report ----|Description: (Exception|Initializing|Rendering)',
    '游戏崩溃（已生成崩溃报告）',
    '日志/游戏目录 crash-reports 里有完整崩溃报告；把报告内容发给懂行的人或贴到社区能更快定位',
  );
  if (report != null) return report;

  return null;
}

/// 常见退出码 → 人话（Windows NTSTATUS / JVM 约定）。
String? exitCodeMeaning(int code) {
  return switch (code) {
    -1073741819 =>
      '访问违例（0xC0000005）：游戏进程读了不该读的内存，'
          '常见于显存/内存问题或模组冲突',
    -1073740791 => '栈缓冲区溢出（0xC0000409）：多为 JVM/驱动层面的崩溃',
    -1073741510 => '进程被 Ctrl+C / 关闭信号打断（多半是手动关闭）',
    -1073741515 =>
      '缺少依赖 DLL（0xC0000135）：系统缺运行库，'
          '装一下 VC++ Redistributable',
    -1073741571 => '栈溢出（0xC00000FD）：常由模组无限递归触发',
    1 => '通用错误退出：游戏主线程抛了未捕获异常，往上翻第一段堆栈',
    134 => 'SIGABRT：JVM 主动中止（hs_err_pid 文件里有细节）',
    _ => null,
  };
}

/// 分析游戏日志行列表 + 退出码。找不到已知模式时用退出码兜底。
CrashAnalysis? analyzeCrash(List<String> logs, int exitCode) {
  final fromText = analyzeCrashText(logs.join('\n'));
  if (fromText != null) return fromText;
  if (exitCode == 0) return null;
  final meaning = exitCodeMeaning(exitCode);
  return CrashAnalysis(
    cause: '游戏异常退出（exitCode=$exitCode）',
    suggestion: meaning ?? '日志往上翻最后一段堆栈；也可以把日志窗口内容发给懂的人看',
  );
}

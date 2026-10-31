import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'arguments.dart';
import 'game_dir.dart';
import 'version_model.dart';

/// Android 运行时（FCL JRE + LWJGL3/lwjglx + caciocavallo）暴露给 Dart 的路径。
class AndroidRuntimePaths {
  const AndroidRuntimePaths({
    required this.javaHome,
    required this.lwjglDir,
    required this.wrapperJar,
    required this.legacyBootstrapJar,
    required this.nativeLibDir,
    required this.logDir,
    required this.cacheDir,
    required this.runtimeDir,
    required this.abi,
    required this.javaMajor,
    this.cacio8Jars = const [],
    this.cacio17Jars = const [],
    this.cacioAgentJar = '',
  });

  final String javaHome;
  final String lwjglDir;
  final String wrapperJar;
  final String legacyBootstrapJar;
  final String nativeLibDir;
  final String logDir;
  final String cacheDir;
  final String runtimeDir;
  final String abi;

  /// 实际用的 JRE 大版本（8 / 17 / 21）；Android 侧按它决定 cacio 与 -XX 参数。
  final int javaMajor;

  /// AWT 模拟环境（游戏内 Swing 界面、Forge 启动图要用）；空 = 运行时没带。
  final List<String> cacio8Jars;
  final List<String> cacio17Jars;

  /// caciocavallo17 的 -javaagent（Java 9+ 走它把 AWT 后端塞进系统 ClassLoader）。
  final String cacioAgentJar;

  factory AndroidRuntimePaths.fromMap(Map<Object?, Object?> map) =>
      AndroidRuntimePaths(
        javaHome: '${map['javaHome']}',
        lwjglDir: '${map['lwjglDir']}',
        wrapperJar: '${map['wrapperJar']}',
        legacyBootstrapJar: '${map['legacyBootstrapJar']}',
        nativeLibDir: '${map['nativeLibDir']}',
        logDir: '${map['logDir']}',
        cacheDir: '${map['cacheDir']}',
        runtimeDir: '${map['runtimeDir']}',
        abi: '${map['abi']}',
        javaMajor: (map['javaMajor'] as num?)?.toInt() ?? 8,
        cacio8Jars: _jars(map['cacio8Jars']),
        cacio17Jars: _jars(map['cacio17Jars']),
        cacioAgentJar: '${map['cacioAgentJar'] ?? ''}',
      );

  static List<String> _jars(Object? value) => value is List
      ? value.map((e) => '$e').where((s) => s.isNotEmpty).toList()
      : const [];

  bool get hasJava9Plus => javaMajor >= 9;
}

/// 游戏进程退出事件（Android 原生广播 → MethodChannel）。
class AndroidGameExitInfo {
  const AndroidGameExitInfo({
    this.abnormal = false,
    this.exitCode = 0,
    this.message = '',
    this.logTail = '',
    this.logPath = '',
    this.version = '',
    this.dialogShown = false,
  });

  final bool abnormal;
  final int exitCode;
  final String message;
  final String logTail;
  final String logPath;
  final String version;

  /// 游戏内已经弹过崩溃页（Dart 侧不必再自动弹）。
  final bool dialogShown;

  factory AndroidGameExitInfo.fromMap(Map<Object?, Object?> map) =>
      AndroidGameExitInfo(
        abnormal: map['abnormal'] == true,
        exitCode: (map['exitCode'] as num?)?.toInt() ?? 0,
        message: '${map['message'] ?? ''}',
        logTail: '${map['logTail'] ?? ''}',
        logPath: '${map['logPath'] ?? ''}',
        version: '${map['version'] ?? ''}',
        dialogShown: map['dialogShown'] == true,
      );
}

/// Android JVM 宿主通道。首次调用会解压 JRE/LWJGL（十几秒到一分钟）。
class AndroidRuntime {
  AndroidRuntime._();

  static const MethodChannel _channel = MethodChannel('mint/fcl');
  static AndroidRuntimePaths? _paths;
  static AndroidRuntimePaths? _pathsLegacyAwt;
  static bool _handlerInstalled = false;

  /// 新装 / 下载了 JRE 之后调用：下一次 prepare 必须重新选版本。
  static void clearCache() {
    _paths = null;
    _pathsLegacyAwt = null;
  }

  /// 从 GameActivity 返回时回调（JVM 退出 / 用户关闭 / 崩溃）。
  static void Function(AndroidGameExitInfo info)? onGameExit;

  static Future<AndroidRuntimePaths> prepare({
    bool force = false,
    bool legacyAwt = false,
    int requiredJavaMajor = 8,
    String lwjglVersion = '3.3.3',
  }) async {
    final cached = legacyAwt ? _pathsLegacyAwt : _paths;
    if (!force &&
        cached != null &&
        cached.javaMajor == requiredJavaMajor &&
        p.basename(cached.lwjglDir) == lwjglDirName(lwjglVersion)) {
      return cached;
    }
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onGameExit') {
          final args = call.arguments;
          onGameExit?.call(
            args is Map
                ? AndroidGameExitInfo.fromMap(args)
                : const AndroidGameExitInfo(),
          );
        }
        return null;
      });
    }
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'prepare',
        {
          'legacyAwt': legacyAwt,
          // 版本 JSON 要求的 Java 大版本：原生按它从随包的 jre8/17/21 里挑
          // 「正好或更高」的那个（FCL JavaManager.findExactOrNextGreater 同款）。
          'requiredJavaMajor': requiredJavaMajor,
          'lwjglVersion': lwjglVersion,
        },
      );
      if (map == null) throw Exception('Android 运行时没有返回路径');
      final paths = AndroidRuntimePaths.fromMap(map);
      if (legacyAwt) {
        _pathsLegacyAwt = paths;
      } else {
        _paths = paths;
      }
      return paths;
    } on PlatformException catch (e) {
      throw Exception('Android 运行时准备失败：${e.message}');
    }
  }

  static Future<void> launch({
    required List<String> args,
    required String workingDir,
    required AndroidRuntimePaths paths,
    String renderer = 'gl4es',
    bool showFps = true,
    String versionName = '',

    /// 版本声明的 LWJGL 版本（`3.3.3` / `3.4.1` / `lwjglx`）：FCL 用它决定
    /// 原生库目录与 `libfcl` 的加载分支。
    String lwjglVersion = '3.3.3',

    /// 1.13+ 的结构化参数需要 GLFW 的 input stack queue（FCL 按
    /// `version.getArguments().isPresent()` 传这个）。
    bool useInputStackQueue = false,

    /// 实际用的 JRE 大版本：FCLBridge.setJava 要真实值，不能再从目录名猜。
    int javaMajor = 8,

    /// 远古版（alpha/beta/≤1.5.2）：画面走 Cacio 软件屏，输入走 AWT 事件。
    bool legacyAwt = false,

    /// MIUI 主题包的开机动画目录（desc.txt + partN/）；空 = 用默认加载层。
    String bootAnimationDir = '',

    /// 26.3+（RenderPearl / SDL3）：Surface 要先注册给 FCL 的 SdlBridge，
    /// 否则 SDL 隐藏窗口拿不到 ANativeWindow，报 Could not fetch native window。
    bool sdl3 = false,
  }) async {
    try {
      await _channel.invokeMethod<bool>('launch', {
        'args': args,
        'workingDir': workingDir,
        'logDir': paths.logDir,
        'javaHome': paths.javaHome,
        'renderer': renderer,
        'showFps': showFps,
        'versionName': versionName,
        'lwjglVersion': lwjglVersion,
        'useInputStackQueue': useInputStackQueue,
        'javaMajor': javaMajor,
        'legacyAwt': legacyAwt,
        'bootAnimationDir': bootAnimationDir,
        'sdl3': sdl3,
      });
    } on PlatformException catch (e) {
      throw Exception('Android 启动失败：${e.message}');
    }
  }

  /// FCL 只随包 3.3.3 / 3.4.1 两套 LWJGL。按 FCL `DefaultLauncher.setLwjglVersion`
  /// 的规则：声明版本 ≥ 3.4.1（例如 26.3 的 3.4.3）用 3.4.1，其它（含走
  /// lwjglx 的 2.x）归一到 3.3.3 —— 与原生 `FclRuntime.lwjglDirName` 必须一致。
  static String lwjglDirName(String version) {
    final match = RegExp(
      r'^(\d+)\.(\d+)(?:\.(\d+))?',
    ).firstMatch(version.trim());
    if (match != null) {
      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);
      final patch = int.tryParse(match.group(3) ?? '0') ?? 0;
      if (major > 3 ||
          (major == 3 && (minor > 4 || (minor == 4 && patch >= 1)))) {
        return '3.4.1';
      }
    }
    return '3.3.3';
  }

  /// 游戏进程是否还在跑（启动器切回前台时用）。
  static Future<bool> isGameRunning() async {
    try {
      return await _channel.invokeMethod<bool>('gameRunning') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 结束游戏。返回 false = 本来就没在跑。
  ///
  /// 游戏在 `:game` 独立进程里，这里杀掉它不会把启动器一起带走 ——
  /// 同进程时代只能靠 killProcess(自己)，那是没法在启动器里点「结束游戏」的。
  static Future<bool> stopGame() async {
    try {
      return await _channel.invokeMethod<bool>('stopGame') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 强制结束游戏进程：跳过「先广播再兜底」的软退出，直接 SIGKILL。
  /// 游戏卡死（画面回不来、广播收不动）时的最后手段。false = 没在跑。
  static Future<bool> forceStopGame() async {
    try {
      return await _channel.invokeMethod<bool>('game.forceStop') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 把游戏窗口调回前台。游戏 task 被盖住、不想杀掉重进时用。
  /// 返回 false = 游戏没在跑，没有可跳转的目标。
  static Future<bool> foregroundGame() async {
    try {
      return await _channel.invokeMethod<bool>('game.foreground') ?? false;
    } on PlatformException {
      return false;
    }
  }
}

/// 一次 Android 启动所需的参数。
class AndroidLaunchPlan {
  const AndroidLaunchPlan({
    required this.args,
    required this.workingDir,
    required this.paths,

    /// true = 1.13+ 的结构化参数：FCL 要按这个开 GLFW 的 input stack queue
    /// （`nativeSetUseInputStackQueue`），否则高版本的键盘输入会丢。
    this.modernArguments = false,

    /// classpath 里缺的库（maven 坐标）：非空说明依赖没下全，调用方要补。
    this.missingLibraries = const [],
  });

  final List<String> args;
  final String workingDir;
  final AndroidRuntimePaths paths;
  final bool modernArguments;
  final List<String> missingLibraries;
}

/// Android 版启动命令构建（FCL `DefaultLauncher` + `FCLauncher.rebaseArgs`
/// 的 Dart 版）。
///
/// 两种版本形态都要照顾到：
///  · **< 1.13**：版本 JSON 里是 `minecraftArguments` 字符串，JVM 参数由启动器自建；
///  · **1.13+**：JSON 换成 `arguments.jvm` / `arguments.game` 结构化列表，带
///    rules 与 `${}` 变量（1.17+ 要 Java 17、1.20.5+ 要 Java 21）。
///
/// 版本 JSON 里的 `org.lwjgl` 库全部剔除，改用运行时自带的 lwjgl.jar /
/// lwjgl-lwjglx.jar，原生 GL 由 GL4ES 翻译。`${natives_directory}` /
/// `${gl_lib_name}` / `${egl_lib_name}` 三个占位符**故意留原样**下发：它们由
/// FCL 的 `rebaseArgs` 按当前渲染器换成真实 .so 路径（LD_LIBRARY_PATH 那一大串）。
class AndroidLaunchBuilder {
  const AndroidLaunchBuilder();

  static const int width = 1280;
  static const int height = 720;

  AndroidLaunchPlan build({
    required GameVersion version,
    required GameDir gameDir,
    required String versionId,
    required String gameHome,
    required String playerName,
    required String playerUuid,
    required int memoryMb,
    required AndroidRuntimePaths paths,

    /// 额外 JVM 参数（FCL VersionSetting.javaArgs 对应物；一行一个，支持
    /// 空格切分）。追加在内置参数之后 —— JVM 对重复的 -Xmx 等取最后一个，
    /// 所以用户想覆盖内存上限时写在这里就行。
    List<String> jvmArgs = const [],

    /// 追加到版本 JSON 游戏参数之后的自定义参数（FCL minecraftArgs 对应物）。
    List<String> extraGameArgs = const [],

    /// 本次启动的 GL 渲染尺寸。默认 16:9 = 1280×720；高度受渲染精度
    /// （50%~150%）缩放，宽度按目标比例算。
    int renderWidth = width,
    int renderHeight = height,

    /// 资源目录（老版本 map_to_resources / virtual 的落盘位置）；null 走
    /// 现代版本的 assets 根。
    String? gameAssetsDir,

    /// -Dlog4j.configurationFile 指向的 xml（版本 JSON 的 logging 节点下载来的）。
    String log4jConfigPath = '',
  }) {
    final modern = version.usesModernArguments;
    final libs = _classpath(version, gameDir, paths);
    final classpath = libs.classpath;
    final clientJar = gameDir.versionJar(version.jarId);
    final lwjglNatives = p.join(paths.lwjglDir, 'natives', paths.abi);
    final variables = <String, String>{
      'auth_player_name': playerName,
      'auth_uuid': playerUuid,
      'auth_access_token': '0',
      'auth_session': 'token:0:$playerUuid',
      'auth_xuid': '',
      'clientid': playerUuid,
      'user_type': 'legacy',
      'user_properties': '{}',
      'version_name': versionId,
      'profile_name': versionId,
      'version_type': version.type,
      'game_directory': gameHome,
      'assets_root': gameDir.assets,
      'assets_index_name': version.assetsIndexId,
      'game_assets':
          gameAssetsDir ??
          p.join(gameDir.assets, 'virtual', version.assetsIndexId),
      'launcher_name': 'MintLauncher',
      'launcher_version': '0.1.0',
      'classpath': classpath,
      // 留给 FCL rebaseArgs：换成「JRE lib + lwjgl natives + jniLibs」的完整搜索路径。
      'natives_directory': r'${natives_directory}',
      'classpath_separator': ':',
      'file_separator': ':',
      'library_directory': gameDir.libraries,
      'primary_jar': clientJar,
      'primary_jar_name': p.basename(clientJar),
      'resolution_width': '$renderWidth',
      'resolution_height': '$renderHeight',
      'language': 'zh_CN',
      'path': log4jConfigPath,
    };

    // 用户/GC 预设已经显式选了收集器时不要再加默认 GC：JVM 同时看到
    // -XX:+UseSerialGC 和 -XX:+UseG1GC 会直接 "Multiple garbage collectors
    // selected" 退出（表现为启动后黑屏）。
    final explicitGc = jvmArgs.any(
      (a) => a.startsWith('-XX:+Use') && a.endsWith('GC'),
    );

    final args = <String>[
      // cacio（AWT 模拟）必须排在最前：Java 17 之后 -XX 参数解析更严格，
      // 且 FCL 也是把它放在命令行头部。
      ..._cacioArgs(paths, renderWidth, renderHeight),
      '-Xmx${memoryMb.clamp(512, 4096)}M',
      '-Xss1m',
      // Android 16 arm64 上 JRE17/21 的压缩类指针会撞 libc 的 tagged pointer
      // 截断检查（"Pointer tag ... was truncated" → JVM abort），关掉压缩
      // 指针后可以正常初始化；JRE8 不需要也不受影响。
      if (paths.hasJava9Plus) ...[
        '-XX:-UseCompressedOops',
        '-XX:-UseCompressedClassPointers',
        // 默认 G1：SerialGC 在 1G 堆、400M+ 存活对象时一次 Full GC 要
        // 600~900ms，游戏里就是每隔一会儿 FPS 掉到个位数、画面冻住。
        // G1 把停顿目标压到 50ms，并且能并发回收大堆。
        if (!explicitGc) ...[
          '-XX:+UseG1GC',
          '-XX:MaxGCPauseMillis=50',
        ],
      ],
      ..._androidProperties(
        paths: paths,
        version: version,
        gameHome: gameHome,
        clientJar: clientJar,
        lwjglNatives: lwjglNatives,
        log4jConfigPath: log4jConfigPath,
      ),
      // 用户 JVM 参数放内置参数之后、-cp 之前：JVM 对重复的 -Xmx / -Xss
      // 取最后一次出现的值，用户想覆盖内存上限时无需改这里。
      ...jvmArgs,
      if (modern) ..._modernJvmArgs(version, variables, paths),
      ..._mainClassArgs(version, paths, classpath, modern),
    ];

    // ── 游戏参数 ──
    final legacyArgs = version.minecraftArguments.trim();
    if (legacyArgs.isNotEmpty) {
      args.addAll(
        legacyArgs
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .map((s) => ArgumentExpander.substitute(s, variables)),
      );
    }
    if (modern) {
      // has_custom_resolution = true：把 JSON 里带 --width/--height 的那段
      // 规则展开出来，尺寸由我们的 resolution_* 变量决定。
      args.addAll(_expanderFor(paths).expand(version.gameArguments, variables));
    }
    final joined = args.join(' ');
    if (!joined.contains('--width')) {
      args.addAll(['--width', '$renderWidth', '--height', '$renderHeight']);
    }
    // 额外游戏参数排在最末（FCL minecraftArgs 同语义），官方参数和自定义
    // 参数同名时后者生效。
    args.addAll(extraGameArgs);

    return AndroidLaunchPlan(
      args: args,
      workingDir: gameHome,
      paths: paths,
      modernArguments: modern,
      missingLibraries: libs.missing,
    );
  }

  /// 规则求值环境：Android = Linux 内核 + `-Dos.name=Linux`，所以按 linux 展开，
  /// 否则 JSON 里所有 `os:{name:"linux"}` 的参数块都会被整段丢掉。
  static ArgumentExpander _expanderFor(AndroidRuntimePaths paths) =>
      ArgumentExpander(
        osName: 'linux',
        arch: paths.abi == 'arm64-v8a' ? 'arm64' : 'x86_64',
        features: const {'has_custom_resolution': true},
      );

  /// 1.13+ 的 `arguments.jvm`。
  ///
  /// 三个「会往 natives 目录写东西」的参数（netty / jna / lwjgl 的解包目录）
  /// 必须落到可写的 cacheDir —— FCL 就是这么处理的，否则 LWJGL 想往只读的
  /// lwjgl natives 目录里解 .so，直接启动失败。
  List<String> _modernJvmArgs(
    GameVersion version,
    Map<String, String> variables,
    AndroidRuntimePaths paths,
  ) {
    final expanded = _expanderFor(
      paths,
    ).expand(version.jvmArguments, variables);
    return [
      for (final arg in expanded)
        if (arg.contains('-Dio.netty.native.workdir') ||
            arg.contains('-Djna.tmpdir') ||
            arg.contains('-Dorg.lwjgl.system.SharedLibraryExtractPath'))
          arg.replaceAll(r'${natives_directory}', paths.cacheDir)
        else
          arg,
    ];
  }

  /// 主类之前的收尾：Java 9+ 的模块开放 + （老版本）classpath + 包装主类。
  List<String> _mainClassArgs(
    GameVersion version,
    AndroidRuntimePaths paths,
    String classpath,
    bool modern,
  ) {
    final mainClass = version.mainClass;
    if (mainClass.isEmpty) throw Exception('版本描述里没有 mainClass');
    final out = <String>[];
    if (paths.hasJava9Plus) {
      // Minecraft 1.17+ 的模块系统检查：主类所在包要对自己开放（FCL 同款）。
      final dot = mainClass.lastIndexOf('.');
      if (dot > 0) {
        final pkg = mainClass.substring(0, dot);
        out.add('--add-exports');
        out.add('$pkg/$pkg=ALL-UNNAMED');
      }
    }
    if (!modern) {
      out.addAll(['-cp', classpath]);
    }
    // 远古版（a/b/1.5）的 launchwrapper 1.5 在 Java 9+ 上会把系统
    // ClassLoader 强转成 URLClassLoader 而崩；用 LegacyBootstrap 把
    // Launch 装进自建 URLClassLoader 里再反射调用。
    out.add(
      mainClass == 'net.minecraft.launchwrapper.Launch'
          ? 'mint.LegacyBootstrap'
          : 'mio.Wrapper',
    );
    out.add(mainClass);
    return out;
  }

  /// FCL / Pojav 在 Android 上必须的 -D 集合（DefaultLauncher 的 Android 分支）。
  List<String> _androidProperties({
    required AndroidRuntimePaths paths,
    required GameVersion version,
    required String gameHome,
    required String clientJar,
    required String lwjglNatives,
    required String log4jConfigPath,
  }) => [
    // FCL 的 rebaseArgs 会把 ${natives_directory} 换成完整的 LD_LIBRARY_PATH。
    '-Djava.library.path=\${natives_directory}',
    '-Dminecraft.client.jar=$clientJar',
    '-Dminecraft.applet.TargetDirectory=$gameHome',
    '-Dminecraft.launcher.brand=MintLauncher',
    '-Dminecraft.launcher.version=0.1.0',
    '-Dorg.lwjgl.opengl.libname=\${gl_lib_name}',
    '-Dorg.lwjgl.egl.libname=\${egl_lib_name}',
    '-Dorg.lwjgl.openal.libname=${paths.nativeLibDir}/libopenal.so',
    '-Dorg.lwjgl.freetype.libname=$lwjglNatives/libfreetype.so',
    '-Dorg.lwjgl.vulkan.libname=libvulkan.so',
    '-Dorg.lwjgl.spvc.libname=spirv-cross-c-shared',
    '-Dorg.lwjgl.librarypath=$lwjglNatives',
    '-Dorg.lwjgl.system.allocator=system',
    '-Dos.name=Linux',
    '-Dos.version=Android',
    '-Duser.home=$gameHome',
    '-Duser.language=zh',
    '-Duser.country=CN',
    '-Dfile.encoding=UTF-8',
    // Java 19 起 sun.* 这两个属性不再生效，FCL 也是按版本分两套。
    if (paths.javaMajor >= 19) ...[
      '-Dstdout.encoding=UTF-8',
      '-Dstderr.encoding=UTF-8',
    ] else ...[
      '-Dsun.stdout.encoding=UTF-8',
      '-Dsun.stderr.encoding=UTF-8',
    ],
    // JVM 原生崩溃 / OOM 留现场：Android 上游戏 stderr 经常被 ROM 吞掉，
    // 没有这两个文件就只能看到「exitCode -1」。
    '-XX:ErrorFile=$gameHome/hs_err_%p.log',
    '-XX:+HeapDumpOnOutOfMemoryError',
    '-XX:HeapDumpPath=$gameHome/heapdump.hprof',
    '-Djava.io.tmpdir=${paths.cacheDir}',
    '-Dext.net.resolvPath=${paths.runtimeDir}/resolv.conf',
    // JNA 的 dispatch 库在 assets/app_runtime/jna/<版本>/natives/<abi>，
    // 由 FclRuntime 解压到 app_runtime/jna。指向 APK 的 nativeLibraryDir
    // 找不到 libjnidispatch.so —— 26.x 生成崩溃报告时 JNA/oshi 二次抛错，
    // 真正的启动异常会被吞掉。
    '-Djna.boot.library.path=${_jnaNativesDir(paths, version)}',
    '-Djna.library.path=${_jnaNativesDir(paths, version)}',
    '-Djdk.lang.Process.launchMechanism=FORK',
    '-XX:ActiveProcessorCount=${Platform.numberOfProcessors}',
    '-Dsodium.checks.issue2561=false',
    '-Dfml.ignoreInvalidMinecraftCertificates=true',
    '-Dfml.ignorePatchDiscrepancies=true',
    '-Dfml.earlyprogresswindow=false',
    '-Dglfwstub.initEgl=false',
    '-Dloader.disable_forked_guis=true',
    '-Dlog4j2.formatMsgNoLookups=true',
    if (log4jConfigPath.isNotEmpty)
      '-Dlog4j.configurationFile=$log4jConfigPath',
    // 远古版（≤1.5.2 / alpha / beta）走 AWT Frame + Canvas，FCL 运行时
    // 自带 libawt_xawt / AWTSTUB 支持；必须显式关闭 headless，否则
    // Java 认为没有 X11 DISPLAY，new Frame 直接 HeadlessException。
    '-Djava.awt.headless=false',
  ];

  /// 版本声明的 JNA（`net.java.dev.jna:jna:x.y.z`）；没有声明时取已解压的
  /// 最高版本。FCL 会按版本现场补 natives，Mint 在 prepare 时整目录复制。
  static String _jnaNativesDir(AndroidRuntimePaths paths, GameVersion version) {
    final root = Directory(p.join(paths.runtimeDir, 'jna'));
    final installed = root.existsSync()
        ? (root.listSync().whereType<Directory>().map((d) => p.basename(d.path)).toList()
            ..sort((a, b) => b.compareTo(a)))
        : <String>[];
    var declared = '';
    for (final lib in version.libraries) {
      if (!lib.name.startsWith('net.java.dev.jna:jna:')) continue;
      final parts = lib.name.split(':');
      if (parts.length >= 3) {
        declared = parts[2];
        break;
      }
    }
    final candidates = [
      if (declared.isNotEmpty) declared,
      ...installed,
    ];
    for (final ver in candidates) {
      final dir = Directory(p.join(root.path, ver, 'natives', paths.abi));
      if (dir.existsSync()) return dir.path;
    }
    // 一个都没解压出来时保持旧行为，JNA 自己会往 nativeLibraryDir 找。
    return paths.nativeLibDir;
  }

  /// caciocavallo（AWT 软件后端）参数，照 FCL `CacioJavaArgs` 搬。
  ///
  /// Minecraft 1.13+（尤其 Forge/NeoForge 与 1.17+ 的启动图）会真去取
  /// `Toolkit.getDefaultToolkit()`；Android 没有 X11，不挂 cacio 就直接
  /// `HeadlessException` / `X11GraphicsEnvironment` 崩溃。JRE8 用
  /// `caciocavallo`（-Xbootclasspath/p:），JRE17/21 用 `caciocavallo17`
  /// （-javaagent + --add-opens/--add-exports）。
  List<String> _cacioArgs(
    AndroidRuntimePaths paths,
    int renderWidth,
    int renderHeight,
  ) {
    if (paths.hasJava9Plus) {
      final jars = paths.cacio17Jars;
      if (jars.isEmpty) return const [];
      return [
        '-Dcacio.managed.screensize=${renderWidth}x$renderHeight',
        '-Dcacio.font.fontmanager=sun.awt.X11FontManager',
        '-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler',
        '-Dswing.defaultlaf=javax.swing.plaf.nimbus.NimbusLookAndFeel',
        '-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit',
        '-Djava.awt.graphicsenv='
            'com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment',
        if (paths.cacioAgentJar.isNotEmpty) '-javaagent:${paths.cacioAgentJar}',
        '--add-exports=java.desktop/java.awt=ALL-UNNAMED',
        '--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED',
        '--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED',
        '--add-exports=java.desktop/sun.java2d=ALL-UNNAMED',
        '--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED',
        '--add-exports=java.desktop/sun.awt=ALL-UNNAMED',
        '--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED',
        '--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED',
        '--add-exports=java.desktop/sun.font=ALL-UNNAMED',
        '--add-exports=java.base/sun.security.action=ALL-UNNAMED',
        '--add-opens=java.base/java.util=ALL-UNNAMED',
        '--add-opens=java.desktop/java.awt=ALL-UNNAMED',
        '--add-opens=java.desktop/sun.font=ALL-UNNAMED',
        '--add-opens=java.desktop/sun.java2d=ALL-UNNAMED',
        '--add-opens=java.base/java.lang.reflect=ALL-UNNAMED',
        '--add-opens=java.base/java.net=ALL-UNNAMED',
        '-Xbootclasspath/a:${jars.join(':')}',
      ];
    }
    final jars = paths.cacio8Jars;
    if (jars.isEmpty) return const [];
    return [
      '-Dcacio.managed.screensize=${renderWidth}x$renderHeight',
      '-Dcacio.font.fontmanager=sun.awt.X11FontManager',
      '-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler',
      '-Dswing.defaultlaf=javax.swing.plaf.nimbus.NimbusLookAndFeel',
      '-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit',
      '-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment',
      '-Xbootclasspath/p:${jars.join(':')}',
    ];
  }

  /// 1.7.10 没有 overrideWidth/overrideHeight 会按桌面默认窗口开，
  /// 在手机上字号会离谱；写入 options.txt 强制成当前渲染尺寸。
  static void ensureVideoOptions(
    String gameHome, {
    int width = AndroidLaunchBuilder.width,
    int height = AndroidLaunchBuilder.height,
  }) {
    final file = File(p.join(gameHome, 'options.txt'));
    final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
    void set(String key, String value) {
      final index = lines.indexWhere((l) => l.startsWith('$key:'));
      if (index >= 0) {
        lines[index] = '$key:$value';
      } else {
        lines.add('$key:$value');
      }
    }

    set('overrideWidth', '$width');
    set('overrideHeight', '$height');
    set('fullscreen', 'false');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${lines.join('\n')}\n');
  }

  /// classpath + 缺失库清单（`missing` 非空 = 依赖还没下全）。
  ({String classpath, List<String> missing}) _classpath(
    GameVersion version,
    GameDir gameDir,
    AndroidRuntimePaths paths,
  ) {
    final entries = <String>[];
    final missing = <String>[];
    for (final lib in version.libraries) {
      if (!lib.allowed) continue;
      final name = lib.name;
      // LWJGL2 整组换掉；jinput/twitch 的桌面原生包在 Android 上没意义。
      if (name.contains('org.lwjgl') ||
          name.contains('jinput-platform') ||
          name.contains('twitch-platform')) {
        continue;
      }
      final artifact = lib.artifact;
      final String path;
      if (artifact != null) {
        final rel = artifact.path.isEmpty ? lib.mavenPath : artifact.path;
        path = p.join(gameDir.libraries, rel);
      } else {
        path = p.join(gameDir.libraries, lib.mavenPath);
      }
      if (File(path).existsSync()) {
        entries.add(path);
      } else if (artifact != null) {
        // 依赖没下全：以前这里是静默剔除（表现为「显示已下载、进游戏却缺库」），
        // 现在记下来交给调用方补下载。
        missing.add(name);
      }
    }

    final lwjglJars = Directory(paths.lwjglDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jar'))
        .map((f) => f.path)
        .toList();
    lwjglJars.sort((a, b) {
      int rank(String path) {
        final name = p.basename(path);
        if (name == 'lwjgl.jar') return 0;
        if (name == 'lwjgl-lwjglx.jar') return 1;
        return 2;
      }

      return rank(a).compareTo(rank(b));
    });

    final clientJar = gameDir.versionJar(version.jarId);
    return (
      classpath: [
        paths.legacyBootstrapJar,
        ...lwjglJars,
        ...entries,
        paths.wrapperJar,
        // Forge/NeoForge 1.17+（BootstrapLauncher）自己找补丁 client jar，
        // 原版 jar 再进 classpath 会和 `minecraft` 模块撞包。
        if (!version.usesForgeBootstrap && File(clientJar).existsSync())
          clientJar,
      ].join(':'),
      missing: missing,
    );
  }
}

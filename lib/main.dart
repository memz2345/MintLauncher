import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'package:mint/services/download_center.dart';
import 'package:mint/services/app_locale_bridge.dart';
import 'package:mint/services/gpu_preference.dart' show GpuProbe;
import 'package:mint/services/ios_liquid_glass.dart';
import 'package:mint/services/linux_window_chrome.dart';
import 'package:mint/services/launcher/account.dart' show createOfflineAccount;
import 'package:mint/services/launcher/android_data_dir.dart'
    show androidDataDirLookup;
import 'package:mint/services/launcher/game_dir.dart' as game_dir;
import 'package:mint/services/launcher/ios_data_dir.dart'
    show iosDataDirLookup;
import 'package:mint/services/launcher/ios_game_launch_probe.dart'
    show IosGameLaunchProbe;
import 'package:mint/services/launcher/ios_jvm_probe.dart' show IosJvmProbe;
import 'package:mint/services/launcher/ios_mod_probe.dart' show IosModProbe;
import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/log_window_service.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/test_hooks.dart';
import 'package:mint/services/theme_fonts.dart';
import 'package:mint/services/theme_package.dart';
import 'package:mint/services/vtouch/vtouch_overlay_service.dart';
import 'package:mint/services/window_backdrop.dart';
import 'package:mint/src/enums.dart' show WindowBackdropMode;
import 'package:mint/ui/app.dart';
import 'package:mint/ui/log_window.dart';
import 'package:mint/ui/nav_state.dart';
import 'package:mint/ui/vtouch/vtouch_overlay.dart';
import 'package:mint/widgets/mint_cloud_foreground.dart';
import 'package:mint/widgets/progressive_blur.dart';

/// 测试钩子：--dart-define=MINT_TEST_LOG_WINDOW=true 时启动 3 秒后自动
/// 打开独立日志窗口（回归测试用，正常构建不受影响）。
const _kTestAutoLogWindow = bool.fromEnvironment('MINT_TEST_LOG_WINDOW');

/// 截图/回归用：--dart-define=MINT_TEST_TAB=2 直接落到某个一级页。
const _kTestTab = int.fromEnvironment('MINT_TEST_TAB', defaultValue: -1);

/// 截图用：塞几行不同级别的日志，方便看日志窗口 tab / 颜色。
const _kTestFakeLogs = bool.fromEnvironment('MINT_TEST_FAKE_LOGS');

/// 截图用：塞一条假的下载任务，方便看标题栏下载按钮和下载管理页
/// （正常构建不受影响）。`MINT_TEST_DOWNLOAD=2` 会额外塞一条已完成记录。
const _kTestDownload = int.fromEnvironment('MINT_TEST_DOWNLOAD');

/// 回归用：启动后自动跑一次安装（下载中心 / 后台任务的端到端冒烟）。
/// 例：`--dart-define=MINT_TEST_INSTALL=1.20.4`。
const _kTestInstall = String.fromEnvironment('MINT_TEST_INSTALL');

/// Android JVM 冒烟：启动 3 秒后直接 installAndLaunch（不经过主页点击）。
/// 例：`--dart-define=MINT_TEST_ANDROID_LAUNCH=1.7.10`。
const _kTestAndroidLaunch = String.fromEnvironment('MINT_TEST_ANDROID_LAUNCH');

/// 冒烟用附加 JVM 参数（排查 arm64 JRE8 JIT 崩溃时切 -Xint 等）。
const _kTestAndroidJvm = String.fromEnvironment('MINT_TEST_ANDROID_JVM');

/// 虚拟触控冒烟：启动 3 秒后唤起悬浮层（无游戏 pid，铺主屏工作区），
/// 用来对着记事本 / 画图实测注入。回归与截图用，正常构建不受影响。
const _kTestVTouch = bool.fromEnvironment('MINT_TEST_VTOUCH');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android 数据目录查询走 MethodChannel，iOS 走 path_provider 沙盒文档
  // 目录，都注入给 GameDir（headless 的 e2e 工具链不 import Flutter，
  // 见 game_dir.dart）。
  if (Platform.isAndroid) {
    game_dir.GameDir.androidDataDirLookup = androidDataDirLookup;
  }
  if (Platform.isIOS) {
    game_dir.GameDir.iosDataDirLookup = iosDataDirLookup;
  }

  // 部分国产 ROM / 模拟器镜像会吞掉应用进程的 logcat，Flutter 异常只剩
  // 屏幕上那一小行 —— 同步落一份到数据目录（和 mint-input.log 同套路），
  // 调试时 adb run-as 直接读文件。
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(_dumpFlutterError(details));
  };

  // 预编译「渐变模糊顶栏」的片元着色器：不预热也能用，只是第一次画顶栏时
  // 会多等一次编译（首帧闪一下）。失败自动退化成均匀 BackdropFilter。
  unawaited(ProgressiveBlur.preload());
  // 云雾前景同上：失败时主页直接不画云（纯装饰，不伤功能）。
  unawaited(MintCloudForeground.preload());

  // desktop_multi_window 子窗口引擎：runner 会用同一个 main 入口启动，
  // args[0] == 'multi_window' 时是子窗口（独立日志窗口 / 虚拟触控悬浮层）。
  if (args.firstOrNull == 'multi_window') {
    final windowId = args.length > 1 ? args[1] : '';
    final argument = args.length > 2 ? args[2] : '';
    if (windowId.isNotEmpty) {
      // 子窗口类型由创建方塞进 argument（json），缺省按日志窗口处理。
      var kind = 'logs';
      if (argument.isNotEmpty) {
        try {
          kind =
              (jsonDecode(argument) as Map<String, dynamic>)['kind']
                  as String? ??
              'logs';
        } catch (_) {}
      }
      if (kind == 'vtouch') {
        await runVTouchOverlay(windowId, argument);
      } else {
        await runLogWindow(windowId, argument);
      }
    }
    return;
  }

  // 桌面端：窗口尺寸 + 标题
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    if (Platform.isLinux) {
      // Linux 自绘标题栏：趁窗口还没 show 摘掉 GTK 原生装饰（不会闪）。
      // 三大金刚图标由 runner 从 GTK 图标主题取系统图标（LinuxWindowChrome）。
      await LinuxWindowChrome.instance.ensureCustomFrame();
    }
    const options = WindowOptions(
      title: 'Mint Launcher',
      size: Size(1180, 760),
      minimumSize: Size(480, 620),
      center: true,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      // flutter run / IDE 调试会用「最小化不抢焦点」的启动标志拉起应用，
      // SW_SHOW 不会还原最小化 —— 必须先 restore 再 focus，否则 debug
      // 模式下窗口一直在任务栏里缩着，看起来就像「没有窗口」。
      await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // iOS 26 液态玻璃能力探测（缓存给同步取用）。
  // 必须 await：顶栏按钮是在 build 里同步读 cachedAvailable 的，如果探测
  // 还在飞，首帧就没有玻璃圆片；主题包导入会把这段延迟掩盖掉，但不能靠它。
  if (Platform.isIOS) {
    await IosLiquidGlass.instance.available();
  }

  final settings = SettingsService();
  await settings.load();
  // CI 回归钩子：--dart-define=MINT_TEST_BACKDROP=acrylic|mica|… 启动即
  // 应用对应窗口材质（Linux CI 在 KWin 下用 xprop 验证模糊原子真的设置上了）。
  // 环境变量同名回退，冒烟脚本不用重编。
  final testBackdrop =
      const String.fromEnvironment('MINT_TEST_BACKDROP').isNotEmpty
      ? const String.fromEnvironment('MINT_TEST_BACKDROP')
      : (Platform.environment['MINT_TEST_BACKDROP'] ?? '');
  if (testBackdrop.isNotEmpty) {
    await settings.setWindowEffect(WindowBackdropMode.fromId(testBackdrop));
  }
  // MIUI 主题包：解析结果 + 主题字体要在 runApp 之前就绪（FontLoader 只能在
  // 引擎启动前注册；主题字体没就绪时安静地回退系统字体）。
  await MintThemeLibrary.instance.load();
  // 老缓存的素材补齐（关于页背景 / 字标 / 音量条图标）要重开一次几十 MB 的包，
  // 放后台跑，别挡首帧。
  unawaited(MintThemeLibrary.instance.upgradeAssets());
  // CI 环境变量钩子诊断：iOS 模拟器上 SIMCTL_CHILD_* 的转发情况直接打出来。
  if (Platform.isIOS || Platform.isAndroid) {
    debugPrint(
      'mint env hooks: page=${Platform.environment['MINT_TEST_PAGE']} '
      'theme=${Platform.environment['MINT_TEST_IMPORT_THEME']} '
      'mode=${Platform.environment['MINT_THEME_MODE']}',
    );
  }
  // 冒烟钩子：--dart-define=MINT_TEST_IMPORT_THEME=<mtz 路径> 启动时自动导入
  // 并应用（真机上 adb 进不了内部数据目录，用外部 files 目录喂包）。
  // iOS：CI 上 SIMCTL_CHILD_* 转发不稳定，另走文件标记 —— 沙盒
  // Documents/import_theme.mtz 存在则导入并删除。
  var testTheme = String.fromEnvironment('MINT_TEST_IMPORT_THEME');
  if (testTheme.isEmpty) {
    testTheme = Platform.environment['MINT_TEST_IMPORT_THEME'] ?? '';
  }
  String? iosDocsPath;
  if (Platform.isIOS) {
    try {
      iosDocsPath = (await getApplicationDocumentsDirectory()).path;
      final marker = File(p.join(iosDocsPath, 'import_theme.mtz'));
      if (marker.existsSync()) {
        testTheme = marker.path;
      }
      // CI 截图配置：simctl 的环境变量不进场，改用沙盒文件。
      final config = File(p.join(iosDocsPath, 'mint_test_config.json'));
      if (config.existsSync()) {
        try {
          MintTestHooks.loadJson(config.readAsStringSync());
          debugPrint(
            'mint test hooks: page=${MintTestHooks.page} '
            'themeMode=${MintTestHooks.themeMode} '
            'backMenu=${MintTestHooks.showBackMenu}',
          );
        } catch (e) {
          debugPrint('mint_test_config.json 解析失败：$e');
        }
      }
    } catch (_) {}
  }
  if (MintTestHooks.themeMode == 'dark') {
    await settings.setThemeMode(ThemeMode.dark);
  } else if (MintTestHooks.themeMode == 'light') {
    await settings.setThemeMode(ThemeMode.light);
  }
  if (testTheme.isNotEmpty && File(testTheme).existsSync()) {
    try {
      final theme = await MintThemeLibrary.instance.import(testTheme);
      await settings.applyThemePackage(
        theme.id,
        hasWallpaper: theme.wallpaper.isNotEmpty,
        hasAccent: theme.accent != null,
        hasFont: theme.fontFile.isNotEmpty,
        hasBootAnimation: theme.bootAnimationDir.isNotEmpty,
      );
      // 文件标记模式：导入成功后删掉，重launch 不会重复导入几十 MB。
      if (Platform.isIOS && iosDocsPath != null) {
        try {
          final marker = File(p.join(iosDocsPath, 'import_theme.mtz'));
          if (marker.path == testTheme) await marker.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('测试主题导入失败：$e');
    }
  }
  // 「试一下能不能启动游戏」第一性实验：模拟器进程里 dlopen libjvm 起
  // JVM（模拟器跑在 macOS 上、允许 JIT；真机仍需 Pojav 路线）。结果写
  // 沙盒 jvm_probe_result.txt，CI 直接 cat。
  if (iosDocsPath != null) {
    IosJvmProbe.maybeRun(iosDocsPath);
    // 第二轮实验：应用内构建启动命令 + posix_spawn macOS JVM 子进程
    // 起真游戏（模拟器宿主专属路线，真机必须 Pojav 同进程 dlopen）。
    IosGameLaunchProbe.maybeRun(iosDocsPath);
  }
  await ThemeFonts.load(settings);
  // 把应用内语言选择同步到 Android 13+ 的「应用语言」设置
  // （空 = 跟随系统，清掉系统里的 per-app 覆盖）。
  unawaited(
    AppLocaleBridge.setSystemAppLocale(
      settings.uiLocale.isEmpty ? null : settings.uiLocale,
    ),
  );
  // Windows 10+ 窗口材质能力探测（Mica/Acrylic/Tabbed/Aero）。
  await WindowBackdrop.instance.ensureInitialized();
  // MINT_GPU_PROBE_OUT=<路径> 时跑一遍选卡链路（Windows 注册表往返 /
  // Linux 合成环境 + 子进程读回 DRI_PRIME），结果写进那个文件。
  await GpuProbe.maybeRun();
  // 桌面虚拟触控：设置变化实时推给悬浮层（悬浮窗可见期间生效）。
  VTouchOverlayService.instance.attachSettings(settings);

  final controller = LauncherController(settings: settings);
  await controller.init();

  // CI Mod 安装探针：沙盒 Documents/mod_probe.json 存在时，在应用进程里
  // 走真实 Modrinth 下载链路，装进当前版本对应的 mods 目录。
  if (iosDocsPath != null) {
    IosModProbe.maybeRun(iosDocsPath, controller.gameDir, settings);
  }

  if (_kTestFakeLogs) {
    const gameLines = [
      '[12:00:01] [main/INFO]: Loading Minecraft 1.20.4',
      '[12:00:02] [Render thread/INFO]: Backend library: LWJGL 3.3.2',
      '[12:00:03] [Render thread/INFO]: OpenGL vendor: NVIDIA Corporation',
      '[12:00:04] [Render thread/WARN]: Pack minecraft:test has invalid pack.mcmeta',
      '[12:00:05] [Worker-Main-1/INFO]: Loading 42 mods',
      '[12:00:06] [Render thread/ERROR]: Failed to load resource pack test.zip',
      'java.util.zip.ZipException: zip END header not found',
      '    at java.util.zip.ZipFile.<init>(ZipFile.java:265)',
      '[12:00:07] [Render thread/WARN]: Missing sound event minecraft:test.sound',
      '[12:00:08] [Render thread/INFO]: Sound engine started',
      '[12:00:09] [Render thread/INFO]: Created 2048x2048 texture atlas',
      '[12:00:10] [Render thread/ERROR]: Could not resolve model test:block/unknown',
      '[12:00:11] [Render thread/INFO]: Reloading resource manager completed in 2384 ms',
      '[12:00:12] [Server thread/INFO]: Starting integrated minecraft server',
      '[12:00:13] [Server thread/INFO]: Preparing spawn area: 27%',
      '[12:00:14] [Render thread/INFO]: Loaded 42 advancements',
    ];
    for (final line in gameLines) {
      controller.gameLog(line);
    }
    controller
      ..log('测试日志：启动器初始化完成')
      ..log('测试日志：正在检测 Java…')
      ..log('测试日志：已选择 Java 17');
  }

  if (_kTestTab >= 0 && _kTestTab < 2) {
    HomeNavState.instance.index = _kTestTab;
  }

  if (_kTestDownload > 0) {
    final task = DownloadCenter.instance.begin(
      title: '安装 Fabric 0.16.9（1.20.4）',
      detail: 'fabric-loader-0.16.9-1.20.4.jar',
    );
    task.plan(files: 42, bytes: 68 * 1024 * 1024);
    // 让它慢慢爬，截图时进度环/速度都有内容。
    Timer.periodic(const Duration(milliseconds: 120), (t) {
      if (!task.isActive) return t.cancel();
      task.addBytes(420 * 1024);
      if (task.doneBytes > task.totalBytes) task.complete();
    });
    if (_kTestDownload > 1) {
      final done = DownloadCenter.instance.begin(title: '下载 Java 运行时 17');
      done.plan(files: 1, bytes: 46 * 1024 * 1024);
      done
        ..detail = 'OpenJDK17U-jre_x64_windows_hotspot.zip'
        ..addBytes(0);
      done.complete(detail: '已解压到 runtimes/java-17');
    }
  }

  if (_kTestAutoLogWindow && Platform.isWindows) {
    Timer(const Duration(seconds: 3), () {
      LogWindowService.instance.open();
    });
  }

  if (_kTestVTouch && Platform.isWindows) {
    Timer(const Duration(seconds: 3), () {
      debugPrint('vtouch: MINT_TEST_VTOUCH hook firing');
      VTouchOverlayService.instance.show();
    });
  }

  if (_kTestInstall.isNotEmpty) {
    Timer(const Duration(seconds: 2), () {
      controller.installOnly(_kTestInstall).catchError((Object e) {
        controller.log('MINT_TEST_INSTALL 失败：$e');
      });
    });
  }

  if (_kTestAndroidLaunch.isNotEmpty && Platform.isAndroid) {
    Timer(const Duration(seconds: 3), () async {
      // 全新安装没有账户：冒烟钩子先补一个离线账户再启动。
      if (settings.accounts.isEmpty) {
        settings.addAccount(createOfflineAccount('MintTest'));
      }
      if (_kTestAndroidJvm.isNotEmpty) {
        settings.jvmArgs = _kTestAndroidJvm;
        debugPrint('MINT_TEST_ANDROID_LAUNCH: jvmArgs=$_kTestAndroidJvm');
      } else {
        // 冒烟测试每次从干净参数开始（避免上一次 -Xint 留盘）。
        settings.jvmArgs = '';
      }
      debugPrint(
        'MINT_TEST_ANDROID_LAUNCH: start $_kTestAndroidLaunch '
        'gameDir=${settings.gameDir}',
      );
      try {
        await controller.installAndLaunch(_kTestAndroidLaunch);
        debugPrint('MINT_TEST_ANDROID_LAUNCH: installAndLaunch returned');
      } catch (e, st) {
        debugPrint('MINT_TEST_ANDROID_LAUNCH failed: $e\n$st');
        controller.log('MINT_TEST_ANDROID_LAUNCH 失败：$e');
      }
    });
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<LauncherController>.value(value: controller),
      ],
      child: MintApp(settings: settings, controller: controller),
    ),
  );

  // Android 品牌闪屏一直挂到 Flutter 真正画出第一帧（原生 keep-on-screen
  // 条件在 MainActivity，8 秒超时兜底）。桌面端没有这个通道，忽略。
  if (Platform.isAndroid) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        const MethodChannel(
          'mint/fcl',
        ).invokeMethod<void>('ready').catchError((Object _) {}),
      );
    });
  }
}

/// 把 Flutter 异常（含堆栈）落到数据目录的 `flutter_error.log`。
/// 失败静默 —— 诊断辅助不能反过来把应用搞挂。
Future<void> _dumpFlutterError(FlutterErrorDetails details) async {
  try {
    final dir = await game_dir.GameDir.launcherDataDir();
    final file = File('$dir/flutter_error.log');
    await file.writeAsString(
      '${DateTime.now().toIso8601String()}\n'
      '${details.toString()}\n\n'
      '── stack ──\n${details.stack ?? StackTrace.current}\n\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

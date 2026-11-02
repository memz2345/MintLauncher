import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../crash_analyzer.dart';
import '../download_center.dart';
import '../gpu_preference.dart';
import '../log_window_service.dart' show LogLine, LogWindowService;
import '../settings_service.dart';
import '../system_memory.dart';
import '../taskbar_progress.dart';
import '../vtouch/vtouch_overlay_service.dart';
import '../../src/enums.dart'
    show
        AndroidRenderer,
        DownloadSource,
        GameWindowMode,
        GraphicsBackend,
        LauncherVisibility,
        ProcessPriority;
import 'account.dart';
import 'android_display.dart';
import 'android_jre.dart';
import 'android_launch.dart';
import 'downloader.dart';
import 'game_dir.dart';
import 'java_runtime.dart';
import 'launch_builder.dart';
import 'legacy_assets.dart';
import 'package:mint/services/theme_package.dart';
import 'manifest.dart';
import 'modloader.dart';
import 'modpack_importer.dart';
import 'modrinth.dart';
import 'optifine.dart';
import 'version_installer.dart';
import 'version_model.dart';

/// 用户在安装 / 准备 Java / 起进程之前按了取消。
class LaunchCancelledException implements Exception {
  @override
  String toString() => '已取消启动';
}

/// 启动器状态机。
enum LauncherState {
  idle,
  installing,
  preparingJava,
  launching,
  running,
  failed,
}

/// 启动对话框里一步的状态（FCL / HMCL 的 launching steps）。
enum LaunchStageStatus { pending, running, done, failed }

/// 一次启动的步骤。启动对话框直接读这个列表画步进器。
class LaunchStage {
  LaunchStage(this.id, this.label);

  final String id;
  final String label;
  LaunchStageStatus status = LaunchStageStatus.pending;
  String detail = '';
}

/// 启动器编排：下载 → Java → 构建命令 → 起进程 → 收日志。
///
/// UI 直接 watch 这个 ChangeNotifier：状态 / 进度 / 日志都从这里来。
class LauncherController extends ChangeNotifier {
  LauncherController({required this.settings});

  final SettingsService settings;

  GameDir? _gameDir;
  GameDir get gameDir => _gameDir!;

  JavaService? _javaService;
  JavaService get javaService => _javaService!;

  LauncherState state = LauncherState.idle;
  String stateDetail = '';

  /// 安装/下载进度（0..1），不在安装流程时为 null。
  double? taskProgress;
  String taskLabel = '';

  /// 正在处理的 modloader 任务描述（安装 Forge 之类），空 = 普通任务。
  String activeTaskTitle = '';

  /// 本次启动的步骤（启动对话框的步进器）。空 = 当前没有启动流程。
  final List<LaunchStage> launchStages = [];

  /// 当前启动的错误（失败时留给对话框显示；下次启动清空）。
  String? launchError;

  /// 上一次游戏退出后的崩溃分析（null = 没有分析出已知模式）。
  CrashAnalysis? lastCrash;
  int lastExitCode = 0;

  /// 待展示的崩溃 / 启动失败报告（UI 消费后调 [consumeCrashReport]）。
  CrashReportData? pendingCrash;

  /// 日志缓冲（游戏输出 + 启动器动作）。
  final List<LogLine> _logs = [];

  /// 纯文本视图（应用内日志页用）。
  List<String> get logs => [for (final e in _logs) e.text];

  /// 带来源标记的日志行（日志分栏用：游戏输出 / 启动器动作）。
  List<LogLine> get logLines => List.unmodifiable(_logs);

  Process? _gameProcess;
  int? get gamePid => _gameProcess?.pid;

  /// 正在运行的版本 id（null = 没有游戏在跑）。
  String? runningVersion;

  /// Android 本次启动的工作目录（原生把 mint-runtime.log 落在这里）。
  String? _androidGameHome;

  /// 本次启动是否已请求取消（Esc / 启动窗口的取消按钮）。
  bool _cancelRequested = false;
  bool get cancelRequested => _cancelRequested;

  /// 用户主动点了「结束」：进程树被强杀时 exitCode 非 0，不应误报崩溃。
  bool _userStopped = false;

  /// 启动流程里还在跑的下载器：取消时统一置 cancelled。
  final Set<Downloader> _launchDownloaders = {};

  bool get isPreparing =>
      state == LauncherState.installing ||
      state == LauncherState.preparingJava ||
      state == LauncherState.launching;

  /// 请求中断当前启动。进程已经起来之后不再走这里（那叫结束游戏）。
  Future<void> cancelLaunch() async {
    if (!isPreparing || _cancelRequested) return;
    _cancelRequested = true;
    for (final dl in _launchDownloaders) {
      dl.cancelled = true;
    }
    taskLabel = '正在取消…';
    stateDetail = '正在取消…';
    log('正在取消启动…');
    notifyListeners();
  }

  // ─────────────────────── 启动步骤 ───────────────────────

  static const String stageFiles = 'files';
  static const String stageRuntime = 'runtime';
  static const String stageAccount = 'account';
  static const String stageArgs = 'args';
  static const String stageProcess = 'process';

  void _beginLaunchStages() {
    launchError = null;
    launchStages
      ..clear()
      ..addAll([
        LaunchStage(stageFiles, '检查版本文件'),
        LaunchStage(stageRuntime, '准备运行环境'),
        LaunchStage(stageAccount, '验证账户'),
        LaunchStage(stageArgs, '构建启动参数'),
        LaunchStage(stageProcess, '启动游戏'),
      ]);
    _setStage(stageFiles, LaunchStageStatus.running, '准备安装');
  }

  /// 启动对话框打开前先摆好步骤，避免第一帧空列表闪一下。
  void prepareLaunchStages() {
    if (launchStages.isEmpty || !isPreparing) _beginLaunchStages();
    _dialogShownAt = DateTime.now();
  }

  /// 启动对话框出现的时间。Android 用它保证对话框至少露个脸再切游戏窗口。
  DateTime? _dialogShownAt;

  LaunchStage? _stageById(String id) {
    for (final s in launchStages) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _setStage(String id, LaunchStageStatus status, [String? detail]) {
    final stage = _stageById(id);
    if (stage == null) return;
    stage.status = status;
    if (detail != null) stage.detail = detail;
    notifyListeners();
  }

  /// 失败时把当前正在跑的步骤标红；错误留给对话框，不靠 snackbar。
  void _failActiveStage(Object error) {
    for (final s in launchStages) {
      if (s.status == LaunchStageStatus.running) {
        s.status = LaunchStageStatus.failed;
        s.detail = '$error';
        break;
      }
    }
    launchError = '$error';
    notifyListeners();
  }

  void _cancelActiveStage() {
    for (final s in launchStages) {
      if (s.status == LaunchStageStatus.running) {
        s.status = LaunchStageStatus.pending;
        s.detail = '已取消';
        break;
      }
    }
    notifyListeners();
  }

  Downloader _newLaunchDownloader(DownloadTask task) {
    final dl = _downloaderFor(task);
    _launchDownloaders.add(dl);
    return dl;
  }

  void _closeLaunchDownloader(Downloader dl) {
    _launchDownloaders.remove(dl);
    dl.close();
  }

  void _throwIfCancelled() {
    if (_cancelRequested) {
      for (final dl in _launchDownloaders) {
        dl.cancelled = true;
      }
      throw LaunchCancelledException();
    }
  }

  /// 版本清单缓存（下载页用）。
  VersionManifest? manifest;

  void log(String line) => _log(line, fromGame: false);

  /// 游戏进程的输出（独立日志窗口里归到「游戏日志」栏）。
  void gameLog(String line) => _log(line, fromGame: true);

  void _log(String line, {required bool fromGame}) {
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    final stamped = '[$stamp] $line';
    _logs.add(LogLine(stamped, fromGame: fromGame));
    if (_logs.length > 4000) _logs.removeRange(0, 1000);
    // 独立日志窗口（Windows）实时跟进；带来源标记供分栏/分级统计。
    LogWindowService.instance.appendLine(stamped, fromGame: fromGame);
    notifyListeners();
  }

  Future<void> init() async {
    final dir = settings.gameDir.isNotEmpty
        ? settings.gameDir
        : await GameDir.defaultGameDir();
    // 默认目录也登记进「游戏目录」列表，版本管理页才能看到并切换它。
    settings.registerGameDir(dir);
    _gameDir = GameDir(dir);
    _javaService ??= JavaService(gameDir: _gameDir!);
    // 版本隔离求值的探针（PCL2 PathIndie 的 mods/saves 自动检测）。
    SettingsService.versionFactsProbe = _gameDir!.factsOf;

    // 独立日志窗口的数据源。
    LogWindowService.instance.onInitRequested = () => List<LogLine>.from(_logs);
    LogWindowService.instance.onClearRequested = clearLogs;
    // 选中版本失效（版本被删/首次启动）时回落到第一个已安装版本：
    // 主页的启动按钮和模组/光影下载目标都依赖它。
    final installed = _gameDir!.installedVersions();
    if (installed.isNotEmpty && !installed.contains(settings.selectedVersion)) {
      settings.selectedVersion = installed.first;
    }
    // Android：游戏可能在 `:game` 独立进程里继续跑（用户按 Home / 回启动器，
    // 或者启动器进程被系统回收后重建）。这里把状态接回来，首页才会显示
    // 「结束游戏」而不是「启动游戏」。
    if (Platform.isAndroid) await syncAndroidGameState();
    notifyListeners();
  }

  /// 同步 Android 游戏进程状态。
  ///
  /// 游戏在独立进程里，Dart 侧的 `LauncherState` 只是镜像 —— 启动器每次回到
  /// 前台都该重新对一次，否则会出现「游戏明明在跑，按钮却写着启动游戏」，
  /// 或者反过来（游戏自己退出了，按钮还停在结束游戏）。
  Future<void> syncAndroidGameState() async {
    if (!Platform.isAndroid) return;
    final bool running;
    try {
      running = await AndroidRuntime.isGameRunning();
    } catch (_) {
      return;
    }
    if (running && state != LauncherState.running) {
      runningVersion = settings.selectedVersion;
      _setState(LauncherState.running, 'Android JVM');
    } else if (!running && state == LauncherState.running) {
      // 硬崩溃（JVM abort / 原生 SIGSEGV）来不及走 onGameExit，靠
      // GameActivity 定期落盘的 mint-runtime.log 兜底弹日志。
      _inspectAndroidHardCrash();
      runningVersion = null;
      _setState(LauncherState.idle, '游戏已退出');
    }
  }

  void _inspectAndroidHardCrash() {
    if (pendingCrash != null) return;
    // GameActivity 把运行日志落在**本次启动的工作目录**（开了版本隔离就是
    // 版本主目录）；读共享根目录的 logs 会永远采不到，秒退也就永远不弹日志。
    final home = _androidGameHome ?? gameDir.root;
    final file = File(p.join(home, 'logs', 'mint-runtime.log'));
    if (!file.existsSync()) return;
    String text;
    try {
      final length = file.lengthSync();
      final raf = file.openSync();
      try {
        raf.setPositionSync(length > 200 * 1024 ? length - 200 * 1024 : 0);
        text = utf8.decode(
          raf.readSync(length > 200 * 1024 ? 200 * 1024 : length),
        );
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return;
    }
    if (!looksLikeCrashLog(text)) return;
    final codeMatch = RegExp(
      r'OpenJDK exited with code\s*:\s*(-?\d+)',
    ).firstMatch(text);
    final code = int.tryParse(codeMatch?.group(1) ?? '') ?? -1;
    lastExitCode = code;
    lastCrash =
        analyzeCrash([text], code) ??
        const CrashAnalysis(
          cause: '游戏进程崩溃',
          suggestion: '展开日志查看最后一段堆栈；也可以把日志发给懂行的人或贴到社区。',
        );
    pendingCrash = CrashReportData(
      title: '游戏崩溃',
      version: runningVersion ?? settings.selectedVersion,
      exitCode: code,
      cause: lastCrash!.cause,
      suggestion: lastCrash!.suggestion,
      log: text,
      logPath: file.path,
    );
    log('❌ 检测到游戏硬崩溃：${lastCrash!.cause}（exitCode=$code）');
  }

  /// 切游戏目录后调用。
  Future<void> reloadGameDir() async {
    _javaService = null;
    await init();
  }

  /// 切换到另一个游戏目录（版本管理页左侧目录列表）。
  /// 会同步更新 settings.gameDir 并重新加载 Java/选中版本。
  Future<void> switchGameDir(String root) async {
    if (p.equals(p.normalize(root), p.normalize(gameDir.root))) return;
    settings.setActiveGameDir(root);
    await reloadGameDir();
  }

  // ─────────────────────── 清单 ───────────────────────

  Future<VersionManifest> ensureManifest({bool force = false}) async {
    if (manifest != null && !force) return manifest!;
    final dl = _newDownloader();
    try {
      manifest = await VersionManifest.fetch(dl);
      log(
        '版本清单已获取：${manifest!.versions.length} 个版本'
        '（latest ${manifest!.latest.release}）',
      );
      notifyListeners();
      return manifest!;
    } catch (e) {
      log('❌ 版本清单获取失败：$e');
      rethrow;
    } finally {
      dl.close();
    }
  }

  Downloader _newDownloader({DownloadTask? task}) {
    final mirror = switch (settings.downloadSource) {
      DownloadSource.bmcl => Mirror.bmcl,
      DownloadSource.official => Mirror.official,
      DownloadSource.auto => Mirror.auto,
    };
    return Downloader(
      mirror: mirror,
      concurrency: settings.downloadThreads,
      proxyHost: settings.proxyEnabled ? settings.proxyHost : '',
      proxyPort: settings.proxyEnabled ? settings.proxyPort : 0,
      task: task,
    );
  }

  /// 开一条「后台下载任务」：标题栏的下载按钮与下载管理页都读这一份。
  DownloadTask _beginTask(String title, {String detail = ''}) =>
      DownloadCenter.instance.begin(title: title, detail: detail);

  /// 任务 id → 挂在它身上的下载器（取消时逐个置 cancelled）。
  final Map<String, List<Downloader>> _taskDownloaders = {};

  /// 建一个「记在这条任务上」的下载器，顺手把取消语义接上。
  Downloader _downloaderFor(DownloadTask? task) {
    final dl = _newDownloader(task: task);
    if (task != null) {
      _taskDownloaders.putIfAbsent(task.id, () => []).add(dl);
      task.onCancel = () {
        for (final d in _taskDownloaders[task.id] ?? const <Downloader>[]) {
          d.cancelled = true;
        }
        log('已取消下载：${task.title}');
      };
    }
    return dl;
  }

  /// 任务收尾：成功 / 失败都由调用方决定（[error] 非空即失败）。
  /// 下载器句柄在这里统一关掉，避免 .part 文件残留句柄。
  void _endTask(DownloadTask? task, {Object? error}) {
    if (task == null) return;
    if (error == null) {
      task.complete();
    } else if (error is LaunchCancelledException) {
      if (task.isActive) task.cancel();
    } else if (task.isActive) {
      task.fail(error);
    }
    for (final d in _taskDownloaders.remove(task.id) ?? const <Downloader>[]) {
      d.close();
    }
  }

  /// 给 UI 侧的查询任务用（modloader 版本列表、Modrinth 搜索等）。
  Downloader newDownloaderForModloader() => _newDownloader();

  /// Modrinth 服务（gameHome 由调用方按版本隔离情况给）。
  ///
  /// [task] 非空时把下载器的字节进度接到这条后台任务上。
  ModrinthService modrinthFor(
    String versionId, {
    required bool isolated,
    DownloadTask? task,
  }) => ModrinthService(
    downloader: task == null ? _newDownloader() : _downloaderFor(task),
    gameHomeDir: gameDir.gameHome(versionId, isolated: isolated),
  );

  // ─────────────────────── 安装 + 启动 ───────────────────────

  /// 安装并启动一个版本。失败抛异常（消息给 UI 弹 toast）。
  Future<void> installAndLaunch(String versionId) async {
    if (isPreparing) return;
    if (_gameProcess != null) {
      throw Exception('已有游戏在运行（PID $_gameProcess）');
    }
    final account = settings.selectedAccount;
    if (account == null) throw Exception('请先创建离线账户');
    await init();

    // ── 每版本设置（HMCL「版本特定设置」）──
    final eff = settings.effectiveFor(versionId);
    final isolated = eff.isolation;
    final gameHome = gameDir.gameHome(versionId, isolated: isolated);
    Directory(gameHome).createSync(recursive: true);
    if (isolated) log('版本隔离已开启：游戏主目录 $gameHome');

    // ── 游戏语言：默认简体中文（PCL2「游戏语言」同思路，写 options.txt）──
    if (settings.gameLangZh) {
      _forceOptionsLang(gameHome, 'zh_cn');
    }

    _cancelRequested = false;
    _userStopped = false;
    _beginLaunchStages();
    DownloadTask? activeTask;
    Downloader? activeDownloader;
    try {
      // ── 安装（已装好的版本会全部跳过下载）──
      activeTaskTitle = '安装 $versionId';
      _setState(LauncherState.installing, '准备安装 $versionId');
      activeTask = _beginTask('安装 $versionId', detail: '准备安装');
      activeDownloader = _newLaunchDownloader(activeTask);
      String? authlibJarPath;
      try {
        final installer = VersionInstaller(
          gameDir: gameDir,
          downloader: activeDownloader,
          verifyFiles: eff.verifyFiles,
          isCancelled: () => _cancelRequested,
        );
        await installer.install(
          versionId,
          onProgress: _onInstallProgress,
          onLog: log,
        );
        _throwIfCancelled();

        // ── 外置登录：确保 authlib-injector 注入器就位 ──
        if (account.isAuthlib) {
          activeTaskTitle = '准备外置登录';
          activeTask.setPhase(0.95, '准备外置登录（authlib-injector）');
          authlibJarPath = await _ensureAuthlibInjector(activeDownloader);
          _throwIfCancelled();
        }
        _endTask(activeTask);
      } catch (e) {
        _endTask(activeTask, error: e);
        rethrow;
      } finally {
        _closeLaunchDownloader(activeDownloader);
        activeDownloader = null;
      }
      _setStage(stageFiles, LaunchStageStatus.done, '版本文件已就绪');

      // ── Android：FCL JRE8 + LWJGL3/lwjglx，不上桌面 Java 探测 ──
      if (Platform.isAndroid) {
        await _installAndLaunchAndroid(
          versionId,
          account: account,
          gameHome: gameHome,
          // Android 也走同一套 AUTO 公式（可用内存 + 模组数），但上限压到
          // 2G：26.x 的 JVM 存活集已经 400~700M，固定 1G 会频繁 Full GC；
          // 再高又容易触发系统 LowMemoryKiller。
          memoryMb: eff.memoryAuto
              ? (await _autoMemoryMb(
                  versionId,
                  gameHome,
                )).clamp(512, 2048).toInt()
              : eff.memoryMb,
        );
        return;
      }

      // ── Java：已有可用版本就用，否则按 version JSON 自动安装 ──
      activeTaskTitle = '启动 $versionId';
      _setState(LauncherState.preparingJava, '检测 Java');
      _setStage(stageRuntime, LaunchStageStatus.running, '检测 Java');
      final parsed = await _loadVersion(versionId);
      _throwIfCancelled();
      final requiredMajor = parsed.javaMajor;
      final requestedComponent = parsed.javaComponent;
      final customJava = eff.javaPath.trim().isNotEmpty;
      JavaRuntime? java = await javaService.pickFor(
        requiredMajor,
        customPath: eff.javaPath,
      );
      _throwIfCancelled();

      if (customJava && java != null) {
        log('使用指定 Java：$java');
        if (!JavaService.isCompatible(java, requiredMajor)) {
          log('⚠️ 指定 Java ${java.version} 低于版本要求 $requiredMajor，仍按你的选择继续');
        }
      } else if (java != null &&
          JavaService.isCompatible(java, requiredMajor)) {
        log('使用 $java');
      } else {
        if (!settings.autoInstallJava) {
          throw Exception(
            requiredMajor > 0
                ? '没有找到 Java $requiredMajor，且设置里关闭了自动安装'
                : '没有找到可用的 Java，且设置里关闭了自动安装',
          );
        }
        final major = requiredMajor > 0 ? requiredMajor : 21;
        final reason = java == null
            ? '未检测到 Java'
            : 'Java ${java.version} 不满足 $requiredMajor';
        log('$reason，开始自动安装 Java $major…');
        _setState(LauncherState.preparingJava, '安装 Java $major');
        final jreTask = _beginTask(
          '下载 Java 运行时 $major',
          detail: requestedComponent.isEmpty ? 'Mojang' : requestedComponent,
        );
        final javaDl = _newLaunchDownloader(jreTask);
        try {
          void javaProgress(double f, String name) {
            taskProgress = f;
            taskLabel = '下载 Java $major $name';
            jreTask.setPhase(f, name);
            _setState(LauncherState.preparingJava, '下载 Java $major');
            _setStage(
              stageRuntime,
              LaunchStageStatus.running,
              '下载 Java $major · $name',
            );
            _syncTaskbar();
          }

          try {
            java = await javaService.downloadMojangRuntime(
              major: major,
              component: requestedComponent,
              downloader: javaDl,
              onLog: log,
              onProgress: javaProgress,
              isCancelled: () => _cancelRequested,
            );
          } catch (e) {
            _throwIfCancelled();
            log('⚠️ Mojang 运行时安装失败：$e，回退 Adoptium');
            jreTask.setPhase(0.05, '回退 Adoptium');
            java = await javaService.downloadJre(
              major,
              downloader: javaDl,
              onLog: log,
              onProgress: javaProgress,
            );
          }
          _endTask(jreTask);
        } catch (e) {
          _endTask(jreTask, error: e);
          rethrow;
        } finally {
          _closeLaunchDownloader(javaDl);
        }
      }

      // ── 内存：AUTO 或手工值（不再有 8GB 之类的人为上限）──
      _setStage(stageRuntime, LaunchStageStatus.done, '$java');
      _setStage(stageAccount, LaunchStageStatus.done, account.name);
      final memoryMb = eff.memoryAuto
          ? await _autoMemoryMb(versionId, gameHome)
          : eff.memoryMb;
      log('分配内存 ${memoryMb}MB${eff.memoryAuto ? '（AUTO）' : ''}');
      _throwIfCancelled();

      // ── 强制后端：CPU 软件渲染时准备 Mesa Loader（HMCL 同款）──
      String mesaJar = '';
      String mesaNatives = '';
      if (eff.graphicsBackend == GraphicsBackend.cpu) {
        if (Platform.isWindows) {
          final mesaTask = _beginTask('准备 Mesa 软件渲染器', detail: 'Mesa LLVMpipe');
          final mesaDl = _newLaunchDownloader(mesaTask);
          try {
            final mesa = await _ensureMesaLoader(mesaDl, mesaTask);
            mesaJar = mesa.$1;
            mesaNatives = mesa.$2;
            _endTask(mesaTask);
          } catch (e) {
            _endTask(mesaTask, error: e);
            rethrow;
          } finally {
            _closeLaunchDownloader(mesaDl);
          }
        } else {
          log('CPU 软件渲染通过环境变量启用（$mesaNatives）');
        }
        _throwIfCancelled();
      }

      // ── 启动前命令（PCL2 LaunchAdvanceRun）──
      final envVars = LaunchBuilder.parseEnvVars(eff.envVars);
      final preLaunch = eff.preLaunchCommand.trim();
      if (preLaunch.isNotEmpty) {
        _setState(LauncherState.launching, '运行启动前命令');
        _setStage(stageArgs, LaunchStageStatus.running, '执行启动前命令');
        log('执行启动前命令：$preLaunch');
        await _runPreLaunchCommand(
          preLaunch,
          versionId: versionId,
          gameHome: gameHome,
          javaExe: java.executablePath,
          wait: eff.preLaunchWait,
          env: envVars,
        );
        _throwIfCancelled();
      }

      // ── 构建命令 ──
      _setState(LauncherState.launching, '构建启动命令');
      _setStage(stageArgs, LaunchStageStatus.running, '构建启动命令');
      final builder = const LaunchBuilder();
      final log4jPath = _log4jConfigPath(parsed);
      final windowMode = settings.gameWindowMode;
      var width = eff.width ?? settings.gameWidth;
      var height = eff.height ?? settings.gameHeight;
      if (eff.width == null &&
          eff.height == null &&
          windowMode == GameWindowMode.defaultSize) {
        width = 854;
        height = 480;
      }
      // 「与启动器窗口大小相同」：版本没有自定义宽高时，用启动器当前
      // 窗口的逻辑像素尺寸；全屏仍然只由 GameWindowMode.fullscreen 决定。
      if (eff.width == null &&
          eff.height == null &&
          windowMode == GameWindowMode.sameAsLauncher) {
        final launcherSize = await _launcherWindowSize();
        width = launcherSize?.$1 ?? 854;
        height = launcherSize?.$2 ?? 480;
      }
      final fullscreen =
          eff.width == null &&
          eff.height == null &&
          windowMode == GameWindowMode.fullscreen;
      final useCpuBackend =
          eff.graphicsBackend == GraphicsBackend.cpu && !Platform.isWindows;
      // Linux 混合显卡（Optimus / Switchable）靠 DRI_PRIME 挑 provider；
      // Windows 用注册表里的每应用图形偏好（见 GpuService.apply）。
      final launchEnv = <String, String>{
        ...envVars,
        if (useCpuBackend) ...{
          'LIBGL_ALWAYS_SOFTWARE': '1',
          'GALLIUM_DRIVER': 'llvmpipe',
        },
        ...gpuLaunchEnv(eff.gpuPreference, cpuBackend: useCpuBackend),
      };
      final assetLayout = resolveAssetLayout(
        gameDir,
        parsed,
        gameHome: gameHome,
      );
      materializeLegacyAssets(gameDir, assetLayout, log: log);
      final command = builder.build(
        LaunchOptions(
          javaExe: java.executablePath,
          version: parsed,
          gameDir: gameDir,
          versionId: versionId,
          playerName: account.name,
          playerUuid: account.uuid.isNotEmpty
              ? account.uuid
              : offlineUuid(account.name),
          memoryMb: memoryMb,
          width: width,
          height: height,
          fullscreen: fullscreen,
          log4jConfigPath: log4jPath,
          gameHome: gameHome,
          gameAssetsDir: assetLayout.dir,
          extraJvmArgs: [
            ...LaunchBuilder.parseJvmArgs(eff.jvmArgs),
            ...eff.gcPreset.args,
          ],
          envVars: launchEnv,
          serverAddress: eff.serverAddress,
          authlibServer: account.isAuthlib ? account.authServer : '',
          authlibInjectorJar: authlibJarPath ?? '',
          extraGameArgs: LaunchBuilder.parseGameArgs(eff.extraGameArgs),
          graphicsBackend: eff.graphicsBackend,
          mesaLoaderJar: mesaJar,
          mesaNativeDir: mesaNatives,
        ),
      );
      log('\$ ${command.quote()}');
      _throwIfCancelled();
      _setStage(
        stageArgs,
        LaunchStageStatus.done,
        '启动参数 ${command.args.length} 项',
      );

      // ── 起进程 ──
      _setStage(stageProcess, LaunchStageStatus.running, '正在拉起游戏进程');
      // 绑定渲染显卡必须在**进程起来之前**：Windows 由驱动在建 GL 上下文时读
      // 每应用图形偏好，Linux 靠子进程环境变量，进程起来之后再改都只影响下次。
      if (Platform.isWindows) {
        final applied = await GpuService.instance.apply(
          executable: command.executable,
          preferenceId: eff.gpuPreference,
        );
        if (applied.isNotEmpty) log(applied);
      } else if (Platform.isLinux && eff.gpuPreference.isNotEmpty) {
        // 混合显卡笔电上「到底传没传下去」全靠这一行日志。
        final env = gpuLaunchEnv(
          eff.gpuPreference,
          cpuBackend: useCpuBackend,
        );
        final label = GpuService.instance.labelFor(eff.gpuPreference);
        log(
          env.isEmpty
              ? '渲染显卡：$label（已强制软件渲染，不设 DRI_PRIME）'
              : '渲染显卡：$label → $env',
        );
      }
      final process = await Process.start(
        command.executable,
        command.args,
        workingDirectory: gameHome,
        environment: command.environment.isEmpty ? null : command.environment,
        mode: ProcessStartMode.normal,
      );
      _gameProcess = process;
      runningVersion = versionId;
      _setStage(stageProcess, LaunchStageStatus.done, 'PID ${process.pid}');
      _setState(LauncherState.running, 'PID ${process.pid}');
      log('游戏进程已启动（PID ${process.pid}）');
      unawaited(_applyProcessPriority(process.pid, settings.processPriority));
      if (settings.launcherVisibility == LauncherVisibility.keep) {
        // HMCL 同款：Windows 下弹独立日志窗口实时显示游戏输出。
        unawaited(LogWindowService.instance.open());
      }
      // 桌面虚拟触控：启用 + 自动显示时，游戏起来就唤起悬浮层（贴游戏
      // 窗口、随它移动）；游戏退出自动收起（见下方 exitCode 回调）。
      if (Platform.isWindows &&
          settings.vtouchEnabled &&
          settings.vtouchAutoShow) {
        unawaited(VTouchOverlayService.instance.show(gamePid: process.pid));
      }
      unawaited(_applyLauncherVisibility(settings.launcherVisibility));
      unawaited(_pumpOutput(process));
      unawaited(
        process.exitCode.then((code) {
          _gameProcess = null;
          runningVersion = null;
          lastExitCode = code;
          gameLog('游戏进程退出，exitCode=$code');
          LogWindowService.instance.notifyGameExited(code);
          // 悬浮层贴着游戏窗口，游戏没了就该收起来。
          unawaited(VTouchOverlayService.instance.hide());
          // 崩溃自动分析（HMCL CrashReportAnalyzer 精简版）。
          // 用户主动结束（进程树强杀）不算崩溃。
          final stoppedByUser = _userStopped;
          _userStopped = false;
          lastCrash = (code == 0 || stoppedByUser)
              ? null
              : analyzeCrash(logs, code);
          if (lastCrash != null) {
            log('🔎 崩溃分析：${lastCrash!.cause} —— ${lastCrash!.suggestion}');
            pendingCrash = CrashReportData(
              title: '游戏崩溃',
              version: versionId,
              exitCode: code,
              cause: lastCrash!.cause,
              suggestion: lastCrash!.suggestion,
              log: logs.join('\n'),
            );
          }
          _setState(LauncherState.idle, 'exitCode=$code');
          // 游戏结束后自动收掉独立日志窗口（1 秒内给「退出」状态留个尾巴）；
          // 期间重新启动了游戏就不再关，避免误伤新会话窗口。
          Future<void>.delayed(const Duration(milliseconds: 1000), () {
            if (_gameProcess == null) {
              unawaited(LogWindowService.instance.close());
            }
          });
        }),
      );
    } catch (e, st) {
      if (e is LaunchCancelledException) {
        _cancelActiveStage();
        log('已取消启动');
        _setState(LauncherState.idle, '已取消启动');
        rethrow;
      }
      if (kDebugMode) {
        debugPrint('启动失败：$e\n$st');
      }
      _failActiveStage(e);
      log('❌ 失败：$e');
      pendingCrash = CrashReportData(
        title: '启动失败',
        version: versionId,
        cause: '$e',
        detail: kDebugMode ? '$st' : null,
        log: logs.join('\n'),
      );
      _setState(LauncherState.failed, '$e');
      rethrow;
    } finally {
      // 起进程之后这些下载器都已关闭；清掉引用避免误取消。
      for (final dl in List<Downloader>.from(_launchDownloaders)) {
        dl.close();
      }
      _launchDownloaders.clear();
      activeTaskTitle = '';
      activeTask = null;
      activeDownloader = null;
    }
  }

  /// Android 启动：FCL 运行时由原生侧准备，Dart 负责参数与版本信息。
  ///
  /// **26.3+ 才用 SDL3 建窗口**（版本 JSON 里出现 `lwjgl-sdl`）。26.2 的
  /// RenderPearl 仍然走 GLFW，只是手柄子系统可能用到 SDL；把它当 SDL 版本
  /// 会去调一套还没初始化的 SDLSurface，原生 `nativeResize` 直接
  /// UnsatisfiedLinkError，且会干扰 GLFW 的 ANativeWindow。
  static bool _needsSdl3(String versionId) {
    final match = RegExp(r'^(\d+)\.(\d+)').firstMatch(versionId.trim());
    if (match == null) return false;
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    return major > 26 || (major == 26 && minor >= 3);
  }

  /// 随包 JRE 不够用时自动补一份（高版本 26.x 要 Java 25）。
  ///
  /// 「运行环境」页与这里共用 [AndroidJre]：同一套下载 / 解压 / marker，
  /// 装完之后 [AndroidRuntime.clearCache] 让下一次 prepare 重新选版本。
  Future<void> _ensureAndroidJava(int requiredJava, DownloadTask task) async {
    if (!Platform.isAndroid) return;
    final status = await AndroidJre.status();
    if (status.isEmpty) return; // 非 Android / 通道不可用
    final ready = {
      for (final item in status)
        if (item.usable && item.ready) item.major,
    };
    if (ready.any((major) => major >= requiredJava)) return;

    final target = AndroidJre.targetFor(requiredJava);
    if (target == null) {
      throw Exception(
        '这个版本需要 Java $requiredJava，运行环境最高只支持 '
        'Java ${AndroidJre.supportedMajors.last}',
      );
    }
    if (!settings.autoInstallJava) {
      throw Exception(
        '这个版本需要 Java $requiredJava，本机未安装。'
        '到「设置 → 运行环境」下载 Java $target 后再启动',
      );
    }
    log('未找到可用的 Java $requiredJava，自动下载 JRE$target …');
    task.setPhase(0.02, '下载 Java $target');
    AndroidJre.onProgress = (progress) {
      task.setPhase(
        0.02 + progress.fraction * 0.86,
        progress.detail.isEmpty ? '下载 Java $target' : progress.detail,
      );
    };
    try {
      final home = await AndroidJre.download(target);
      log('JRE$target 已安装：$home');
      task.setPhase(0.9, 'JRE$target 已安装');
      AndroidRuntime.clearCache();
    } finally {
      AndroidJre.onProgress = null;
    }
  }

  Future<void> _installAndLaunchAndroid(
    String versionId, {
    required OfflineAccount account,
    required String gameHome,
    required int memoryMb,
  }) async {
    AndroidRuntime.onGameExit = (info) {
      if (info.abnormal) {
        lastExitCode = info.exitCode;
        final analysis = analyzeCrash([
          ...logs,
          if (info.logTail.isNotEmpty) info.logTail,
        ], info.exitCode);
        lastCrash =
            analysis ??
            CrashAnalysis(
              cause: info.message.isEmpty
                  ? '游戏异常退出（exitCode=${info.exitCode}）'
                  : info.message,
              suggestion:
                  '展开下面的日志查看最后一段堆栈；'
                  '也可以把日志发给懂行的人或贴到社区。',
            );
        pendingCrash = CrashReportData(
          title: '游戏崩溃',
          version: info.version.isEmpty ? versionId : info.version,
          exitCode: info.exitCode,
          cause: lastCrash!.cause,
          suggestion: lastCrash!.suggestion,
          log: info.logTail.isEmpty ? logs.join('\n') : info.logTail,
          logPath: info.logPath,
          inGameShown: info.dialogShown,
        );
        log(
          '❌ 游戏崩溃（exitCode=${info.exitCode}）：${lastCrash!.cause}'
          '${info.logPath.isEmpty ? '' : '，日志：${info.logPath}'}',
        );
      }
      if (state == LauncherState.running) {
        runningVersion = null;
        _setState(LauncherState.idle, info.abnormal ? '游戏崩溃' : '游戏已退出');
      } else if (info.abnormal) {
        notifyListeners();
      }
    };
    try {
      activeTaskTitle = '启动 $versionId';
      _setStage(stageAccount, LaunchStageStatus.done, account.name);
      _setState(LauncherState.preparingJava, '解压 Android 运行时');
      _setStage(stageRuntime, LaunchStageStatus.running, '解压 Android 运行时');
      _androidGameHome = gameHome;
      final parsed = await _loadVersion(versionId);
      // 远古版（launchwrapper 1.5 + AWT Frame）优先 JRE8：JRE17 的 java.desktop
      // 在 Android 上会走 X11GraphicsEnvironment，initDisplay 没有 native 实现。
      final needsLegacyAwt =
          parsed.type == 'old_alpha' ||
          parsed.type == 'old_beta' ||
          parsed.assetsIndexId == 'pre-1.6';
      // 版本要求的 Java（1.17+ → 17，1.20.5+ → 21）与它声明的 LWJGL 版本，
      // 决定原生解包用哪个 JRE、挂哪套 lwjgl 原生库。
      final requiredJava = needsLegacyAwt ? 8 : parsed.requiredJavaMajor;
      final lwjglVersion = parsed.lwjglVersion;
      log(
        '准备 Android 运行时（要求 Java $requiredJava · LWJGL $lwjglVersion · '
        '${needsLegacyAwt ? '远古版 AWT' : parsed.mainClass}）…',
      );
      // JRE/LWJGL/cacio 的解包量是 Android 上最大的一块（JRE 解压 ~200MB），
      // 以前只算一个「正在解压」的 stage，下载中心里完全看不见 —— 用户以为
      // 「已经下完了」，实际大头还没落地，所以这里挂一条真任务。
      final runtimeTask = _beginTask(
        '准备 Android 运行时',
        detail: 'JRE$requiredJava · LWJGL $lwjglVersion',
      );
      AndroidRuntimePaths paths;
      try {
        // 高版本（26.x 要 Java 25）不在随包列表里：先查状态，缺了就在
        // 「运行环境」同一套链路里自动下载，再走正常解压。
        await _ensureAndroidJava(requiredJava, runtimeTask);
        runtimeTask.setPhase(0.1, '解压 JRE / LWJGL / caciocavallo');
        paths = await AndroidRuntime.prepare(
          legacyAwt: needsLegacyAwt,
          requiredJavaMajor: requiredJava,
          lwjglVersion: lwjglVersion,
        );
        runtimeTask.setPhase(1, 'JRE${paths.javaMajor} 就绪');
        _endTask(runtimeTask);
      } catch (e) {
        _endTask(runtimeTask, error: e);
        rethrow;
      }
      if (paths.javaMajor < requiredJava) {
        throw Exception(
          '这个版本需要 Java $requiredJava，但当前 Android 运行时只有 '
          'Java ${paths.javaMajor}（${paths.abi} 没有随包更高版本）',
        );
      }
      final jreLabel = 'JRE${paths.javaMajor}';
      log('Android JRE：$jreLabel ${paths.javaHome}');
      _setStage(
        stageRuntime,
        LaunchStageStatus.done,
        '$jreLabel · LWJGL ${lwjglVersion == 'lwjglx' ? '3.3.3+lwjglx' : lwjglVersion} · ${paths.abi}',
      );

      // 远古版（map_to_resources / virtual）资源需要铺到实际读取的位置：
      // pre-1.6 用游戏主目录的 resources/，否则资源初始化会直接崩。
      final assetLayout = resolveAssetLayout(
        gameDir,
        parsed,
        gameHome: gameHome,
      );
      materializeLegacyAssets(gameDir, assetLayout, log: log);
      // 画面比例改的是渲染分辨率（高固定 720、宽度随比例），不是拉伸；
      // 每次启动重新读原生 JSON（游戏内菜单也可能改过）。
      final display = await AndroidDisplay.load(force: true);
      AndroidLaunchBuilder.ensureVideoOptions(
        gameHome,
        width: display.renderWidth,
        height: display.renderHeight,
      );
      _setState(LauncherState.launching, '构建 Android 启动参数');
      _setStage(stageArgs, LaunchStageStatus.running, '构建 Android 启动参数');
      // 每版本覆盖的 JVM / 游戏参数在 Android 上同样生效（FCL
      // javaArgs/minecraftArgs 对应物）；解析复用桌面的 LaunchBuilder。
      final eff = settings.effectiveFor(versionId);
      // 依赖没下全时以前是静默从 classpath 剔掉（进游戏才 NoClassDefFoundError）。
      // 启动前补一轮，补不上才带着缺项启动，并在日志里点名。
      await _repairAndroidLibraries(parsed, gameDir, versionId);
      final plan = const AndroidLaunchBuilder().build(
        version: parsed,
        gameDir: gameDir,
        versionId: versionId,
        gameHome: gameHome,
        playerName: account.name,
        playerUuid: account.uuid.isNotEmpty
            ? account.uuid
            : offlineUuid(account.name),
        memoryMb: memoryMb,
        paths: paths,
        jvmArgs: LaunchBuilder.parseJvmArgs(eff.jvmArgs),
        extraGameArgs: LaunchBuilder.parseGameArgs(eff.extraGameArgs),
        renderWidth: display.renderWidth,
        renderHeight: display.renderHeight,
        gameAssetsDir: assetLayout.dir,
        log4jConfigPath: _log4jConfigPath(parsed),
      );
      if (plan.missingLibraries.isNotEmpty) {
        log(
          '⚠️ 仍缺 ${plan.missingLibraries.length} 个库：'
          '${plan.missingLibraries.take(6).join('、')}'
          '${plan.missingLibraries.length > 6 ? ' …' : ''}',
        );
      }
      log('Android 启动参数 ${plan.args.length} 项，mainClass=${parsed.mainClass}');
      _setStage(
        stageArgs,
        LaunchStageStatus.done,
        '启动参数 ${plan.args.length} 项',
      );
      _setStage(stageProcess, LaunchStageStatus.running, '正在拉起游戏窗口');
      // 缓存全热时安装 + 解压可能不到一秒，GameActivity 会直接盖掉启动对话框。
      // 至少让它显示 1.2 秒，玩家才看得到「正在启动」的步骤条。
      final shownAt = _dialogShownAt;
      _dialogShownAt = null;
      if (shownAt != null) {
        final wait =
            const Duration(milliseconds: 1200) -
            DateTime.now().difference(shownAt);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _throwIfCancelled();
      // 渲染器版本上限（FCL Renderer.displayMaxMCver）：
      //  · 远古版固定 GL4ES（alpha 这批 AWT + LWJGL2 只有它不灰屏）；
      //  · 26.3 的 RenderPearl 用 SDL3 + 新渲染后端，GL4ES/Krypton 的 EGL
      //    不完整（eglGetDisplay 失败），自动切 Zink —— Zink 会以系统
      //    Vulkan 驱动初始化，游戏实际走 Vulkan 后端。其它渲染器下次可在
      //    设置里改回来。
      var renderer = settings.androidRenderer;
      if (needsLegacyAwt) {
        renderer = AndroidRenderer.gl4es;
      } else if (!renderer.supportsVersion(versionId)) {
        const fallback = AndroidRenderer.zink;
        log(
          '⚠️ ${renderer.label} 不支持 $versionId，自动改用 '
          '${fallback.label}（Vulkan；设置 → Android 渲染器 可改）',
        );
        renderer = fallback;
      }
      await AndroidRuntime.launch(
        args: plan.args,
        workingDir: plan.workingDir,
        paths: paths,
        renderer: renderer.id,
        showFps: settings.androidShowFps,
        versionName: versionId,
        lwjglVersion: lwjglVersion,
        useInputStackQueue: plan.modernArguments,
        javaMajor: paths.javaMajor,
        legacyAwt: needsLegacyAwt,
        bootAnimationDir: _activeBootAnimationDir(settings),
        sdl3: _needsSdl3(versionId),
      );
      runningVersion = versionId;
      _setStage(stageProcess, LaunchStageStatus.done, '游戏窗口已启动');
      _setState(LauncherState.running, 'Android JVM');
      log(
        'Android 游戏已启动（渲染器 ${renderer.label} · '
        'Java ${paths.javaMajor}），运行日志：$gameHome/logs/mint-runtime.log',
      );
    } catch (e, st) {
      if (e is LaunchCancelledException) {
        _cancelActiveStage();
        log('已取消启动');
        _setState(LauncherState.idle, '已取消启动');
        rethrow;
      }
      _failActiveStage(e);
      if (kDebugMode) debugPrint('Android 启动失败：$e\n$st');
      log('❌ Android 启动失败：$e');
      pendingCrash = CrashReportData(
        title: '启动失败',
        version: versionId,
        cause: '$e',
        detail: kDebugMode ? '$st' : null,
        log: logs.join('\n'),
      );
      _setState(LauncherState.failed, '$e');
      rethrow;
    } finally {
      activeTaskTitle = '';
    }
  }

  /// AUTO 内存：可用物理内存 + 版本 mods 数量（PCL2 档位公式）。
  Future<int> _autoMemoryMb(String versionId, String gameHome) async {
    var mods = 0;
    final modsDir = Directory(p.join(gameHome, 'mods'));
    if (modsDir.existsSync()) {
      try {
        for (final entry in modsDir.listSync()) {
          if (entry is! File) continue;
          final ext = p.extension(entry.path).toLowerCase();
          if (ext == '.jar' || ext == '.zip' || ext == '.litemod') mods++;
        }
      } catch (_) {}
    }
    final status = await SystemMemory.read(force: true);
    final mb = MemoryAdvisor.autoMbFor(status, modCount: mods);
    log(
      'AUTO 内存：可用 ${status.availableGb.toStringAsFixed(1)}GB / '
      '总 ${status.totalGb.toStringAsFixed(1)}GB，$mods 个模组 → $mb MB',
    );
    return mb;
  }

  /// 下载 / 复用 HMCL 的 mesa-loader-windows（LLVMpipe 软件 OpenGL）。
  Future<(String, String)> _ensureMesaLoader(
    Downloader dl,
    DownloadTask task,
  ) async {
    final isArm = Platform.version.contains('arm64');
    const version = '26.0.4';
    final classifier = isArm ? 'arm64' : 'x64';
    final sha1 = isArm
        ? '5c761a344700a07eaded51c5cf0cde36ee614706'
        : 'f8da709c59ef61f531c91434ca0e3b4f39202981';
    final size = isArm ? 43504189 : 49873846;
    final dir = p.join(gameDir.runtime, 'mesa-loader');
    final jar = p.join(dir, 'mesa-loader-windows-$version-$classifier.jar');
    final natives = p.join(dir, 'natives');
    Directory(natives).createSync(recursive: true);
    task.setPhase(0.1, 'Mesa Loader $version');
    if (!File(jar).existsSync()) {
      log(
        '下载 Mesa Loader（${isArm ? 'ARM64' : 'x64'}，约 ${size ~/ 1024 ~/ 1024}MB）…',
      );
      await dl.fetchFile(
        DownloadItem(
          url:
              'https://repo1.maven.org/maven2/org/glavo/'
              'mesa-loader-windows/$version/'
              'mesa-loader-windows-$version-$classifier.jar',
          dest: jar,
          sha1: sha1,
          size: size,
          name: 'mesa-loader-windows $version',
        ),
      );
      _throwIfCancelled();
    }
    task.setPhase(1, 'Mesa Loader 就绪');
    log('Mesa Loader 就绪：$jar');
    return (jar, natives);
  }

  /// 把 options.txt 的 lang 行改成 [lang]（没有则追加，文件不存在则新建）。
  /// 只在值真的变化时写盘，避免每次启动都碰用户配置。
  static void _forceOptionsLang(String gameHome, String lang) {
    final file = File(p.join(gameHome, 'options.txt'));
    const newline = '\n';
    List<String> lines;
    if (file.existsSync()) {
      lines = file.readAsStringSync().split(newline);
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('lang:')) {
          if (lines[i] == 'lang:$lang') return;
          lines[i] = 'lang:$lang';
          file.writeAsStringSync(lines.join(newline), flush: true);
          return;
        }
      }
      lines.add('lang:$lang');
    } else {
      lines = ['lang:$lang'];
    }
    file.writeAsStringSync(lines.join(newline), flush: true);
  }

  /// 启动前命令：支持 PCL2 的 {verpath} / {java} / {verindie} 占位符。
  Future<void> _runPreLaunchCommand(
    String command, {
    required String versionId,
    required String gameHome,
    required String javaExe,
    required bool wait,
    required Map<String, String> env,
  }) async {
    final expanded = command
        .replaceAll('{verpath}', gameDir.versionDir(versionId))
        .replaceAll('{verindie}', gameHome)
        .replaceAll('{java}', javaExe)
        .replaceAll('{version}', versionId);
    final exe = Platform.isWindows ? 'cmd' : '/bin/sh';
    final args = Platform.isWindows ? ['/c', expanded] : ['-c', expanded];
    if (wait) {
      final result = await Process.run(
        exe,
        args,
        workingDirectory: gameHome,
        environment: env.isEmpty ? null : env,
        runInShell: false,
      );
      final out = '${result.stdout}${result.stderr}'.trim();
      if (out.isNotEmpty) {
        for (final line in out.split('\n').take(8)) {
          log('  $line');
        }
      }
      if (result.exitCode != 0) {
        throw Exception('启动前命令退出码 ${result.exitCode}');
      }
    } else {
      await Process.start(
        exe,
        args,
        workingDirectory: gameHome,
        environment: env.isEmpty ? null : env,
        mode: ProcessStartMode.detached,
      );
    }
  }

  /// 设置游戏进程优先级（Windows；其它平台忽略）。
  Future<void> _applyProcessPriority(int pid, ProcessPriority priority) async {
    if (!Platform.isWindows || priority == ProcessPriority.normal) return;
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "(Get-Process -Id $pid).PriorityClass = "
            "'${priority.windowsName}'",
      ], runInShell: false);
      if (result.exitCode == 0) {
        log('游戏进程优先级：${priority.label}');
      }
    } catch (e) {
      log('⚠️ 设置进程优先级失败：$e');
    }
  }

  /// 读取启动器当前窗口的逻辑像素尺寸（`sameAsLauncher` 模式用）。
  ///
  /// window_manager 的 getSize 已按 devicePixelRatio 折算成逻辑像素；
  /// 最大化时返回的就是当前窗口尺寸，直接使用即可，不额外传 --fullscreen。
  /// 非桌面平台 / 读取失败返回 null，由调用方回退 854×480。
  Future<(int, int)?> _launcherWindowSize() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      log('当前平台无法读取启动器窗口尺寸，游戏窗口回退 854×480');
      return null;
    }
    try {
      final size = await windowManager.getSize();
      final width = size.width.round().clamp(320, 7680).toInt();
      final height = size.height.round().clamp(240, 4320).toInt();
      log('游戏窗口与启动器窗口一致：$width × $height');
      return (width, height);
    } catch (e) {
      log('读取启动器窗口尺寸失败，游戏窗口回退 854×480：$e');
      return null;
    }
  }

  /// 启动后对启动器窗口做最小化 / 关闭（PCL2 LaunchArgumentVisible）。
  Future<void> _applyLauncherVisibility(LauncherVisibility visibility) async {
    switch (visibility) {
      case LauncherVisibility.keep:
        return;
      case LauncherVisibility.minimize:
        try {
          await windowManager.minimize();
        } catch (_) {}
      case LauncherVisibility.close:
        await Future<void>.delayed(const Duration(milliseconds: 800));
        log('按设置关闭启动器（游戏继续运行）');
        exit(0);
    }
  }

  /// 下载（或复用）authlib-injector 注入器，返回本地路径。
  Future<String> _ensureAuthlibInjector(Downloader dl) async {
    final artifact = await latestAuthlibInjector(dl);
    final jarFile = File(
      p.join(gameDir.root, 'authlib-injector-${artifact.version}.jar'),
    );
    if (!jarFile.existsSync()) {
      log('下载 authlib-injector ${artifact.version}…');
      await dl.fetchFile(
        DownloadItem(
          url: artifact.url,
          dest: jarFile.path,
          name: 'authlib-injector ${artifact.version}',
        ),
      );
    }
    return jarFile.path;
  }

  /// 安装 Modrinth 资源（模组/资源包/光影/数据包）。
  ///
  /// [destDir] 非空时安装到用户手动选择的文件夹（社区内容下载 UI 会
  /// 预填该版本对应的子目录）；为空时用 `<gameHome>/<type.targetDirName>`。
  Future<void> installModrinthFile(
    ModrinthVersionFile version,
    ModrinthProjectType type, {
    required String versionId,
    required bool isolated,
    String? destDir,
  }) async {
    final task = _beginTask(
      '下载 ${version.name.isEmpty ? '资源' : version.name}',
      detail: type.label,
    );
    // 下载器挂在任务上：字节进度 / 取消都走同一条任务。
    final service = modrinthFor(versionId, isolated: isolated, task: task);
    try {
      await service.install(version, type: type, destDir: destDir, onLog: log);
      _endTask(task);
    } catch (e) {
      _endTask(task, error: e);
      rethrow;
    } finally {
      service.downloader.close();
    }
  }

  /// 安装 Modrinth 整合包（.mrpack）为新版本。
  ///
  /// 流程（PCL2 / FCL 的 Modrinth 整合包安装同思路）：
  ///  1. 下载 .mrpack 到 `versions/<packId>/`
  ///  2. 解析 modrinth.index.json，解压 `overrides/` 进版本目录
  ///     （整合包一律按「版本隔离」铺文件，mods/config 等不污染共享根）
  ///  3. 下载 index 声明的资源文件
  ///  4. 安装 MC 本体 + 依赖的加载器，最后写一个继承加载器的 pack json
  ///
  /// 返回新版本 id。
  ///
  /// [targetRoot] 非空且不是当前游戏目录时，先登记并切到该目录再装
  /// （社区内容下载 UI 允许用户挑一个目标游戏目录）。
  Future<String> installModpack(
    ModrinthVersionFile version, {
    required String title,
    String? targetRoot,
  }) async {
    if (state == LauncherState.installing ||
        state == LauncherState.preparingJava ||
        state == LauncherState.launching) {
      throw Exception('有安装任务正在进行，请等它完成');
    }
    await init();
    if (targetRoot != null &&
        targetRoot.isNotEmpty &&
        !p.equals(p.normalize(targetRoot), p.normalize(gameDir.root))) {
      settings.addGameDir(targetRoot);
      await reloadGameDir();
    }
    final packId = _uniquePackId(title);
    final instanceDir = gameDir.versionDir(packId);
    Directory(instanceDir).createSync(recursive: true);

    final task = _beginTask('安装整合包 $title', detail: '下载整合包文件');
    final dl = _downloaderFor(task);
    final service = ModrinthService(downloader: dl, gameHomeDir: gameDir.root);
    try {
      activeTaskTitle = '安装整合包 $title';
      _setState(LauncherState.installing, '下载整合包文件');

      // ── 1. .mrpack 本体 ──
      final mrpackPath = await service.downloadModpack(
        version,
        destDir: instanceDir,
        onLog: log,
      );

      // ── 2. index + overrides ──
      task.setPhase(0.05, '解压整合包覆盖文件');
      final index = service.parseModpack(mrpackPath);
      final overrideCount = service.extractModpackOverrides(
        mrpackPath,
        instanceDir,
      );
      log(
        '整合包 ${index.name}：MC ${index.gameVersion}，'
        '覆盖文件 $overrideCount 个，待下载文件 ${index.files.length} 个',
      );

      // ── 3. index 文件 ──
      _setState(LauncherState.installing, '下载整合包内容');
      await service.downloadModpackFiles(
        index,
        instanceDir,
        onLog: log,
        onProgress: (f, label) => task.setPhase(0.05 + f * 0.25, label),
      );

      // ── 4. 加载器 + MC 本体 ──
      final deps = index.dependencies;
      final (loader, loaderVersion) = _resolveModpackLoader(deps);
      task.setPhase(0.3, '安装 Minecraft ${index.gameVersion}');
      if (loader != null) {
        await _installLoaderChain(
          loader,
          index.gameVersion,
          loaderVersion,
          task,
        );
      } else {
        await _installVersion(index.gameVersion, task: task);
      }

      // ── 5. pack 版本 json（继承加载器版本）＋ 强制版本隔离 ──
      final loaderId = loader == null
          ? index.gameVersion
          : ModloaderService.versionIdFor(
              loader,
              index.gameVersion,
              loaderVersion,
            );
      final stamp = DateTime.now().toUtc().toIso8601String();
      File(gameDir.versionJson(packId)).writeAsStringSync(
        jsonEncode({
          'id': packId,
          'inheritsFrom': loaderId,
          'type': 'release',
          'releaseTime': stamp,
          'time': stamp,
        }),
      );
      // 整合包的 mods/config 都铺在 versions/<packId> 下，隔离必须开着。
      final vs = settings.settingsFor(packId);
      settings.updateVersionSettings(
        packId,
        VersionSettings(
          memoryMb: vs.memoryMb,
          javaPath: vs.javaPath,
          isolation: true,
          jvmArgs: vs.jvmArgs,
          envVars: vs.envVars,
          serverAddress: vs.serverAddress,
        ),
      );
      settings.selectedVersion = packId;

      log('✅ 整合包 $title 已安装为版本 $packId（可从主页直接启动）');
      _endTask(task);
      _setState(LauncherState.idle, '整合包安装完成');
      return packId;
    } catch (e) {
      _endTask(task, error: e);
      log('❌ 整合包安装失败：$e');
      _setState(LauncherState.failed, '$e');
      rethrow;
    } finally {
      dl.close();
      activeTaskTitle = '';
    }
  }

  /// 从本地文件导入整合包（PCL2 / HMCL「拖入 zip 安装」同款）。
  ///
  /// [ModpackImporter] 负责识别格式（Modrinth .mrpack / CurseForge /
  /// MultiMC(Prism) / HMCL / 普通 zip）与解压覆盖文件；这里编排：
  ///  1. 解压 overrides / .minecraft / 整包文件到 `versions/<packId>/`
  ///  2. 下载清单声明的文件（Modrinth index / CurseForge manifest）
  ///  3. 安装 MC 本体 + 依赖加载器，写继承 pack json 并强制版本隔离
  ///
  /// 普通 zip 识别不出 MC 版本时由 [gameVersion] 兜底（导入对话框让用户填）。
  /// 返回新版本 id。
  Future<String> installModpackFromFile(
    String path, {
    String? name,
    String? gameVersion,
  }) async {
    if (state == LauncherState.installing ||
        state == LauncherState.preparingJava ||
        state == LauncherState.launching) {
      throw Exception('有安装任务正在进行，请等它完成');
    }
    await init();

    final descriptor = ModpackImporter.inspect(path);
    final mcVersion = descriptor.gameVersion.isNotEmpty
        ? descriptor.gameVersion
        : (gameVersion ?? '').trim();
    if (mcVersion.isEmpty) {
      throw Exception('无法识别整合包的 Minecraft 版本，请在导入时手动填写');
    }
    final title = (name == null || name.trim().isEmpty)
        ? descriptor.name
        : name.trim();
    final packId = _uniquePackId(title);
    final instanceDir = gameDir.versionDir(packId);
    Directory(instanceDir).createSync(recursive: true);

    final task = _beginTask('导入整合包 $title', detail: descriptor.kind.label);
    final dl = _downloaderFor(task);
    try {
      activeTaskTitle = '导入整合包 $title';
      _setState(LauncherState.installing, '解压 ${descriptor.kind.label}');
      task.setPhase(0.02, '解压整合包文件');

      // ── 1. 覆盖文件（后面的 prefix 覆盖前面的同名文件）──
      final overrideCount = descriptor.kind == ModpackKind.plain
          ? ModpackImporter.extractPlain(path, instanceDir)
          : ModpackImporter.extractPrefixes(
              path,
              instanceDir,
              prefixes: [
                if (descriptor.kind == ModpackKind.modrinth)
                  '${descriptor.rootPrefix}overrides/',
                descriptor.overridesPrefix,
                if (descriptor.kind == ModpackKind.modrinth)
                  '${descriptor.rootPrefix}client-overrides/',
              ],
            );
      log(
        '${descriptor.kind.label}「$title」：MC $mcVersion，'
        '${descriptor.loader == null ? '原版' : descriptor.displayLoader}，'
        '覆盖文件 $overrideCount 个'
        '（${(descriptor.archiveBytes / 1024 / 1024).toStringAsFixed(1)}MB）',
      );

      // ── 2. 清单声明的文件 ──
      if (descriptor.kind == ModpackKind.modrinth) {
        _setState(LauncherState.installing, '下载整合包内容');
        await ModrinthService(
          downloader: dl,
          gameHomeDir: gameDir.root,
        ).downloadModpackFiles(
          ModrinthModpackIndex(descriptor.index),
          instanceDir,
          onLog: log,
          onProgress: (f, label) => task.setPhase(0.05 + f * 0.25, label),
        );
      } else if (descriptor.kind == ModpackKind.curseForge) {
        _setState(LauncherState.installing, '下载 CurseForge 文件');
        await _downloadCurseFiles(descriptor, instanceDir, dl, task);
      }

      // ── 3. MC 本体 + 加载器 ──
      final loader = descriptor.loader;
      final loaderVersion = loader == null
          ? ''
          : _normalizeLoaderVersion(
              loader,
              descriptor.loaderVersion,
              mcVersion,
            );
      task.setPhase(0.3, '安装 Minecraft $mcVersion');
      String loaderId;
      if (loader != null && loaderVersion.isNotEmpty) {
        await _installLoaderChain(loader, mcVersion, loaderVersion, task);
        loaderId = ModloaderService.versionIdFor(
          loader,
          mcVersion,
          loaderVersion,
        );
      } else {
        await _installVersion(mcVersion, task: task);
        loaderId = mcVersion;
      }

      // ── 4. pack 版本 json（继承加载器版本）＋ 强制版本隔离 ──
      final stamp = DateTime.now().toUtc().toIso8601String();
      File(gameDir.versionJson(packId)).writeAsStringSync(
        jsonEncode({
          'id': packId,
          'inheritsFrom': loaderId,
          'type': 'release',
          'releaseTime': stamp,
          'time': stamp,
        }),
      );
      final vs = settings.settingsFor(packId).copy();
      vs.isolation = true;
      settings.updateVersionSettings(packId, vs);
      settings.selectedVersion = packId;

      log('✅ 整合包「$title」已导入为版本 $packId（可从主页直接启动）');
      _endTask(task);
      _setState(LauncherState.idle, '整合包导入完成');
      return packId;
    } catch (e) {
      _endTask(task, error: e);
      log('❌ 整合包导入失败：$e');
      _setState(LauncherState.failed, '$e');
      rethrow;
    } finally {
      dl.close();
      activeTaskTitle = '';
    }
  }

  /// Forge 的清单版本常带 MC 前缀（`1.20.1-47.2.0`），剥掉才是纯 Forge 版本。
  String _normalizeLoaderVersion(
    ModLoader loader,
    String version,
    String mcVersion,
  ) {
    final v = version.trim();
    if (loader == ModLoader.forge && mcVersion.isNotEmpty) {
      final prefix = '$mcVersion-';
      if (v.length > prefix.length &&
          v.toLowerCase().startsWith(prefix.toLowerCase())) {
        return v.substring(prefix.length);
      }
    }
    return v;
  }

  /// CurseForge manifest 的 files → 下载地址 → 批量下载。
  ///
  /// 官方 API 需要 key（设置 → 网络）；查询不到或没配 key 时用
  /// edge.forgecdn.net 按 fileID 拼 CDN 直链兜底（公开 CDN，无需 key）。
  /// 文件相对路径来自 manifest 的 `path`；下载器挂在任务上，字节进度
  /// 直接进 DownloadCenter。
  Future<void> _downloadCurseFiles(
    ModpackDescriptor descriptor,
    String instanceDir,
    Downloader dl,
    DownloadTask task,
  ) async {
    final entries = <({int fileID, String path})>[
      for (final f in descriptor.curseFiles)
        if ((f['fileID'] as num?) != null && f['required'] != false)
          (
            fileID: (f['fileID'] as num).toInt(),
            path: _normalizeCursePath(f['path'] as String? ?? ''),
          ),
    ].where((e) => e.path.isNotEmpty).toList();
    if (entries.isEmpty) return;

    // fileID → 官方 downloadUrl（可选：没配 key 就全走 CDN 兜底）。
    final apiKey = settings.curseForgeApiKey.trim();
    final officialUrl = <int, String>{};
    if (apiKey.isNotEmpty) {
      task.setPhase(0.08, '查询 CurseForge 文件信息');
      try {
        final request = await dl.httpClient.postUrl(
          Uri.parse('https://api.curseforge.com/v1/mods/files'),
        );
        request.headers.set('x-api-key', apiKey);
        request.headers.set('User-Agent', 'MintLauncher/0.1.0');
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'fileIds': [for (final e in entries) e.fileID],
          }),
        );
        final response = await request.close();
        final body = jsonDecode(await response.transform(utf8.decoder).join());
        if (body is Map<String, dynamic> && body['data'] is List) {
          for (final d in body['data'] as List) {
            if (d is! Map<String, dynamic>) continue;
            final id = (d['id'] as num?)?.toInt();
            final url = d['downloadUrl'] as String?;
            if (id != null && url != null && url.isNotEmpty) {
              officialUrl[id] = url;
            }
          }
        }
        log('CurseForge API 解析 ${officialUrl.length}/${entries.length} 个文件');
      } catch (e) {
        log('⚠️ CurseForge 文件信息查询失败（改用 CDN 直链）：$e');
      }
    }

    final items = <DownloadItem>[];
    for (final e in entries) {
      final dest = p.joinAll([instanceDir, ...e.path.split('/')]);
      if (File(dest).existsSync()) continue;
      final fileName = p.posix.basename(e.path);
      final url =
          officialUrl[e.fileID] ??
          'https://edge.forgecdn.net/files/'
              '${e.fileID ~/ 1000}/${e.fileID % 1000}/'
              '${Uri.encodeComponent(fileName)}';
      items.add(DownloadItem(url: url, dest: dest, name: e.path));
    }
    if (items.isNotEmpty) {
      log('CurseForge 清单文件 ${items.length} 个，开始下载');
      await dl.runBatch(
        items,
        onFileError: (file, e) => log('⚠️ 文件下载失败 $file：$e'),
      );
    }
    task.setPhase(0.3, '清单文件下载完成');
  }

  /// CurseForge manifest 的 path：反斜杠归一、剥前导斜杠、拒收 `..`。
  String _normalizeCursePath(String raw) {
    var path = raw.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    path = p.posix.normalize(path);
    if (path.isEmpty || path.startsWith('../') || p.posix.isAbsolute(path)) {
      return '';
    }
    return path;
  }

  /// modrinth.index.json 的 dependencies → 加载器 + 版本号。
  /// 没有加载器依赖（纯原版整合包）时 loader 为 null。
  (ModLoader?, String) _resolveModpackLoader(Map<String, String> deps) {
    if (deps.containsKey('fabric-loader')) {
      return (ModLoader.fabric, deps['fabric-loader']!);
    }
    if (deps.containsKey('quilt-loader')) {
      return (ModLoader.quilt, deps['quilt-loader']!);
    }
    if (deps.containsKey('forge')) return (ModLoader.forge, deps['forge']!);
    if (deps.containsKey('neoforge')) {
      return (ModLoader.neoforge, deps['neoforge']!);
    }
    return (null, '');
  }

  /// versions/ 里不重名的整合包版本 id。
  String _uniquePackId(String title) {
    final safe = title
        .replaceAll('.mrpack', '')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final base = safe.isEmpty ? 'Modpack' : safe;
    var id = base;
    var n = 2;
    while (File(gameDir.versionJson(id)).existsSync()) {
      id = '$base-$n';
      n++;
    }
    return id;
  }

  /// 只安装不启动。
  Future<void> installOnly(String versionId) async {
    if (state == LauncherState.installing) return;
    try {
      await _installVersion(versionId);
      _setState(LauncherState.idle, '安装完成');
    } catch (e) {
      log('❌ 安装失败：$e');
      _setState(LauncherState.failed, '$e');
      rethrow;
    }
  }

  /// 实际安装一个版本（无重入保护，供 [installOnly] 与 modloader
  /// 编排复用；调用方负责状态守卫）。
  ///
  /// [task] 是上层编排（加载器安装）已经开好的下载任务；为空时自己开一条。
  Future<void> _installVersion(String versionId, {DownloadTask? task}) async {
    activeTaskTitle = '安装 $versionId';
    _setState(LauncherState.installing, '准备安装 $versionId');
    final own = task == null;
    final dlTask = task ?? _beginTask('安装 $versionId', detail: '准备安装');
    final dl = _downloaderFor(dlTask);
    try {
      final installer = VersionInstaller(gameDir: gameDir, downloader: dl);
      await installer.install(
        versionId,
        onProgress: _onInstallProgress,
        onLog: log,
      );
      if (own) _endTask(dlTask);
    } catch (e) {
      if (own) _endTask(dlTask, error: e);
      rethrow;
    } finally {
      if (own) dl.close();
      activeTaskTitle = '';
    }
  }

  /// 安装模组加载器（Forge / NeoForge / Fabric / Quilt）到 [targetDir]。
  ///
  /// 流程（HMCL 的对应安装任务同思路）：
  ///  1. [targetDir] 与当前目录不同 → 切换游戏目录
  ///  2. 先装好原版本体（加载器的版本 JSON 都继承原版）
  ///  3. Fabric/Quilt：meta 的 profile json 落盘 → 按继承链补库
  ///     Forge/NeoForge：官方 installer.jar 以 --installClient 无头安装
  Future<void> installModloader(
    ModLoader loader,
    String gameVersion,
    String loaderVersion,
    String targetDir,
  ) async {
    if (state == LauncherState.installing ||
        state == LauncherState.preparingJava) {
      return;
    }
    await init();
    activeTaskTitle = '安装 ${loader.label} $loaderVersion';
    final task = _beginTask(
      '安装 ${loader.label} $loaderVersion',
      detail: 'Minecraft $gameVersion',
    );
    try {
      // ── 1. 目标目录 ──
      if (targetDir.isNotEmpty && targetDir != gameDir.root) {
        log('切换游戏目录：${gameDir.root} → $targetDir');
        settings.gameDir = targetDir;
        await reloadGameDir();
      }

      // ── 2. 原版本体 + 加载器 ──
      await _installLoaderChain(loader, gameVersion, loaderVersion, task);

      log(
        '✅ ${loader.label} $loaderVersion（$gameVersion）安装完成，'
        '可在「启动」页选择新版本',
      );
      _endTask(task);
      _setState(LauncherState.idle, '安装完成');
    } catch (e) {
      _endTask(task, error: e);
      log('❌ ${loader.label} 安装失败：$e');
      _setState(LauncherState.failed, '$e');
      rethrow;
    } finally {
      activeTaskTitle = '';
    }
  }

  /// 在当前游戏目录把 [loader] 装到 [gameVersion] 之上（原版本体缺了会
  /// 先补装）。[task] 是调用方已开好的下载任务；Forge/NeoForge 需要的
  /// Java 会按需下载（装 8 跟随游戏要求）。
  Future<void> _installLoaderChain(
    ModLoader loader,
    String gameVersion,
    String loaderVersion,
    DownloadTask task,
  ) async {
    // ── 原版本体 ──
    _setState(LauncherState.installing, '安装原版 $gameVersion');
    final baseInstalled = File(gameDir.versionJson(gameVersion)).existsSync();
    if (!baseInstalled) {
      log('原版 $gameVersion 未安装，先装原版…');
      await _installVersion(gameVersion, task: task);
    } else {
      log('原版 $gameVersion 已就绪，跳过');
    }

    final dl = _downloaderFor(task);
    final service = ModloaderService(gameDir: gameDir, downloader: dl);
    try {
      switch (loader) {
        case ModLoader.fabric || ModLoader.quilt:
          // ── Fabric/Quilt：profile json → 继承链补库 ──
          final id = await service.installFabricFamily(
            loader,
            gameVersion,
            loaderVersion,
            onLog: log,
          );
          _setState(LauncherState.installing, '下载 ${loader.label} 依赖库');
          await _installVersion(id, task: task);
        case ModLoader.forge || ModLoader.neoforge:
          // ── Forge / NeoForge：官方安装器 ──
          _setState(LauncherState.preparingJava, '准备安装器运行时');
          final major = await _installerJavaMajor(loader, gameVersion);
          var java = await javaService.pickFor(
            major,
            customPath: settings.javaPath,
          );
          java ??= await javaService.downloadJre(
            major,
            onLog: log,
            onProgress: (f, name) {
              taskProgress = f;
              taskLabel = '下载运行时 $name';
              task.setPhase(f, '下载运行时 $name');
              notifyListeners();
              _syncTaskbar();
            },
          );
          _setState(LauncherState.installing, '运行 ${loader.label} 安装器');
          taskProgress = null;
          taskLabel = '运行 ${loader.label} 官方安装器…';
          task.setPhase(0.9, '运行 ${loader.label} 官方安装器');
          notifyListeners();
          _syncTaskbar();
          await service.installViaOfficialInstaller(
            loader,
            gameVersion,
            loaderVersion,
            javaExe: java.executablePath,
            onLog: log,
          );
      }
    } finally {
      dl.close();
    }
  }

  /// 官方安装器需要的 Java 大版本：跟随游戏要求（老版本装 8）。
  Future<int> _installerJavaMajor(ModLoader loader, String gameVersion) async {
    // 从已装的原版 json 读 javaVersion；读不到按 8 兜底。
    final file = File(gameDir.versionJson(gameVersion));
    if (file.existsSync()) {
      try {
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final javaVersion = json['javaVersion'];
        if (javaVersion is Map<String, dynamic>) {
          final major = (javaVersion['majorVersion'] as num?)?.toInt() ?? 0;
          if (major >= 8) return major;
        }
      } catch (_) {}
    }
    return 8;
  }

  /// 安装 OptiFine 到 [baseVersion] 之上（HMCL OptiFineInstallTask 同款
  /// 原生安装：Patcher 补丁 + LaunchWrapper 版本 json，不跑官方 GUI）。
  ///
  /// [baseVersion] 可以是原版，也可以是已装的 Forge 版本（组合安装）。
  /// 返回新版本 id。
  Future<String> installOptifine(
    OptiFineEntry entry,
    String baseVersion,
    String targetDir,
  ) async {
    if (state == LauncherState.installing ||
        state == LauncherState.preparingJava) {
      return '';
    }
    await init();
    activeTaskTitle = '安装 OptiFine ${entry.edition}';
    try {
      // ── 目标目录 ──
      if (targetDir.isNotEmpty && targetDir != gameDir.root) {
        log('切换游戏目录：${gameDir.root} → $targetDir');
        settings.gameDir = targetDir;
        await reloadGameDir();
      }

      // ── 基版本就位 ──
      final mcVersion = gameDir.mcVersionOf(baseVersion);
      final baseJson = File(gameDir.versionJson(baseVersion));
      final isPlainMc = RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(baseVersion);
      if (!baseJson.existsSync()) {
        if (!isPlainMc) {
          throw Exception(
            '基版本 $baseVersion 未安装：请先在「下载」页安装它'
            '（Forge 等模组化版本需先装好，再往上面装 OptiFine）',
          );
        }
        _setState(LauncherState.installing, '安装原版 $baseVersion');
        log('原版 $baseVersion 未安装，先装原版…');
        await _installVersion(baseVersion);
      } else {
        log('基版本 $baseVersion（MC $mcVersion）已就绪');
      }

      // ── Java（Patcher 需要 8+，跟随基版本要求）──
      _setState(LauncherState.preparingJava, '准备 OptiFine 运行时');
      final major = await _installerJavaMajor(ModLoader.forge, mcVersion);
      var java = await javaService.pickFor(
        major,
        customPath: settings.javaPath,
      );
      java ??= await javaService.downloadJre(
        major,
        onLog: log,
        onProgress: (f, name) {
          taskProgress = f;
          taskLabel = '下载运行时 $name';
          notifyListeners();
          _syncTaskbar();
        },
      );

      // ── 原生安装 ──
      _setState(LauncherState.installing, '安装 OptiFine');
      // 挂一条下载任务：OptiFine 安装器有几十 MB，之前用的是无任务下载器，
      // 下载中心里完全看不见，容易被当成「什么都没下」的幽灵进度。
      final ofTask = _beginTask(
        '安装 OptiFine $mcVersion',
        detail: entry.edition,
      );
      final dl = _downloaderFor(ofTask);
      final service = OptiFineService(gameDir: gameDir, downloader: dl);
      String versionId;
      try {
        versionId = await service.install(
          baseVersion,
          mcVersion: mcVersion,
          entry: entry,
          javaExe: java.executablePath,
          onLog: log,
        );
        _endTask(ofTask);
      } catch (e) {
        _endTask(ofTask, error: e);
        rethrow;
      } finally {
        dl.close();
      }
      log('✅ OptiFine 安装完成，可在「启动」页选择 $versionId');
      _setState(LauncherState.idle, '安装完成');
      return versionId;
    } catch (e) {
      log('❌ OptiFine 安装失败：$e');
      _setState(LauncherState.failed, '$e');
      rethrow;
    } finally {
      activeTaskTitle = '';
    }
  }

  // ─────────────────────── 模组 / 世界管理 ───────────────────────

  /// 启用/禁用模组（jar ↔ jar.disabled 重命名）。
  Future<void> toggleMod(File modFile) async {
    final path = modFile.path;
    final newPath = path.endsWith('.disabled')
        ? path.substring(0, path.length - '.disabled'.length)
        : '$path.disabled';
    try {
      await modFile.rename(newPath);
      log('模组 ${p.basename(path)} → ${p.basename(newPath)}');
    } catch (e) {
      log('❌ 模组启停失败：$e');
    }
  }

  Future<void> deleteMod(File modFile) async {
    try {
      await modFile.delete();
      log('已删除模组 ${p.basename(modFile.path)}');
    } catch (e) {
      log('❌ 删除模组失败：$e');
    }
  }

  /// 备份一个世界为 zip（存到共享根的 `backups/` 目录）。返回备份文件路径。
  Future<String> backupWorld(
    String versionId,
    String world, {
    required bool isolated,
  }) async {
    final worldPath = gameDir.worldDir(versionId, world, isolated: isolated);
    final dir = Directory(worldPath);
    if (!dir.existsSync()) throw Exception('世界不存在：$world');
    final backupDir = Directory(gameDir.backups);
    if (!backupDir.existsSync()) backupDir.createSync(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    final dest = File(p.join(backupDir.path, '$world-$stamp.zip'));
    log('备份世界 $world…');
    final encoder = ar.ZipEncoder();
    final archive = ar.Archive();
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: dir.path).replaceAll('\\', '/');
      if (rel.startsWith('session.lock')) continue;
      final bytes = await e.readAsBytes();
      archive.addFile(ar.ArchiveFile(rel, bytes.length, bytes));
    }
    await dest.writeAsBytes(encoder.encode(archive), flush: true);
    log('✅ 世界已备份到 ${dest.path}');
    return dest.path;
  }

  /// 用系统文件管理器打开目录。
  Future<void> openInFileManager(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      log('❌ 打开文件夹失败：$e');
    }
  }

  /// 结束游戏进程（强杀）。
  ///
  /// Android 走独立进程（`:game`），杀掉它启动器自己还活着；桌面端还是直接
  /// 杀子进程。
  Future<void> stopGame() async {
    if (Platform.isAndroid) {
      final stopped = await AndroidRuntime.stopGame();
      log(stopped ? '已结束 Android 游戏进程' : '游戏进程已不在运行');
      if (state == LauncherState.running) {
        runningVersion = null;
        _setState(LauncherState.idle, '游戏已结束');
      }
      return;
    }
    // 只结束本控制器亲手拉起的那个进程（_gameProcess），绝不按进程名 /
    // 全盘扫描去杀 —— 否则会把 HMCL / PCL 等别的启动器正在跑的实例一起带走。
    final p = _gameProcess;
    if (p == null) {
      if (state == LauncherState.running) {
        runningVersion = null;
        _setState(LauncherState.idle, '游戏已结束');
      }
      return;
    }
    log('终止游戏进程（PID ${p.pid}）');
    _userStopped = true;
    if (Platform.isWindows) {
      // Windows 的 javapath\java.exe 只是 Oracle 启动器的 wrapper，真正的
      // JVM（游戏窗口）是它的子进程；只 kill wrapper 会留下孤儿游戏进程
      // （「FAB 结束不了游戏」的根因）。按本控制器拿到的 PID 定向杀整棵
      // 进程树，仍不会按镜像名扫到别的启动器实例。
      try {
        final result = await Process.run('taskkill', [
          '/PID',
          '${p.pid}',
          '/T',
          '/F',
        ], runInShell: false);
        log(
          result.exitCode == 0
              ? '已结束游戏进程树（PID ${p.pid}）'
              : 'taskkill 退出码 ${result.exitCode}',
        );
      } catch (e) {
        log('⚠️ taskkill 失败：$e');
      }
    } else {
      try {
        p.kill();
      } catch (e) {
        log('⚠️ 结束进程失败：$e');
      }
    }
    try {
      final code = await p.exitCode.timeout(const Duration(seconds: 5));
      log('游戏进程已结束（exitCode=$code）');
    } on TimeoutException {
      log('⚠️ 游戏进程 5 秒内仍未退出');
      if (identical(_gameProcess, p)) {
        _gameProcess = null;
        runningVersion = null;
        _setState(LauncherState.idle, '已强制结束');
      }
    }
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  /// UI 关掉崩溃分析横幅。
  void dismissCrash() {
    if (lastCrash == null) return;
    lastCrash = null;
    notifyListeners();
  }

  /// 取走待展示的崩溃报告（弹窗消费一次后可再关闭）。
  CrashReportData? consumeCrashReport() {
    final report = pendingCrash;
    pendingCrash = null;
    return report;
  }

  /// 关闭崩溃报告弹窗（详情仍保留在 [lastCrash] 供横幅展示）。
  void dismissCrashReport() {
    if (pendingCrash == null) return;
    pendingCrash = null;
    notifyListeners();
  }

  // ─────────────────────── 内部 ───────────────────────

  void _onInstallProgress(InstallProgress p) {
    taskProgress = p.phase == InstallPhase.done ? 1.0 : p.fraction;
    taskLabel = '${p.phase.label} ${p.detail}';
    final files = _stageById(stageFiles);
    if (files != null && files.status == LaunchStageStatus.running) {
      files.detail = taskLabel;
    }
    // 后台下载任务跟着走：字节进度在解压阶段不增长，用阶段比例覆盖。
    final active = DownloadCenter.instance.activeTasks;
    if (active.isNotEmpty && taskProgress != null) {
      active.first.setPhase(taskProgress!, taskLabel);
    }
    notifyListeners();
    _syncTaskbar();
  }

  /// 当前 MIUI 主题包声明的开机动画目录（未启用 / 没声明 → 空）。
  String _activeBootAnimationDir(SettingsService settings) {
    if (!settings.themeUseBootAnimation) return '';
    final theme = MintThemeLibrary.instance.byId(settings.activeThemeId);
    return theme?.bootAnimationDir ?? '';
  }

  Future<GameVersion> _loadVersion(String versionId) async {
    final file = File(gameDir.versionJson(versionId));
    if (!file.existsSync()) throw Exception('版本描述不存在');
    return GameVersion.resolve(
      versionId,
      _decodeJson(file.readAsStringSync()),
      (id) async {
        final f = File(gameDir.versionJson(id));
        if (!f.existsSync()) return null;
        return _decodeJson(f.readAsStringSync());
      },
    );
  }

  static Map<String, dynamic> _decodeJson(String text) {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('version json is not an object');
  }

  /// 启动前补齐版本 JSON 要求、但磁盘上还没有的库（Android 专用）。
  ///
  /// 「显示已下载、进游戏却还有一大堆依赖」的根因之一：安装阶段某些文件下载
  /// 失败只写进日志，而 classpath 构建是「文件在才加」，缺库于是静默消失，
  /// 到游戏里才炸 `NoClassDefFoundError`。这里在真正拉起 JVM 前按 JSON 再核
  /// 一遍，缺的现补；补不上也照样启动，但会在日志里点名缺了什么。
  Future<void> _repairAndroidLibraries(
    GameVersion version,
    GameDir gameDir,
    String versionId,
  ) async {
    final items = <DownloadItem>[];
    for (final lib in version.libraries) {
      if (!lib.allowed) continue;
      final name = lib.name;
      if (name.contains('org.lwjgl') ||
          name.contains('jinput-platform') ||
          name.contains('twitch-platform')) {
        continue;
      }
      final artifact = lib.artifact;
      if (artifact == null || artifact.url.isEmpty) continue;
      final dest = p.join(
        gameDir.libraries,
        artifact.path.isEmpty ? lib.mavenPath : artifact.path,
      );
      if (File(dest).existsSync()) continue;
      items.add(
        DownloadItem(
          url: artifact.url,
          dest: dest,
          sha1: artifact.sha1,
          size: artifact.size,
          name: name,
        ),
      );
    }
    if (items.isEmpty) return;
    _throwIfCancelled();
    log('补齐 $versionId 缺失依赖：${items.length} 个文件');
    final task = _beginTask('补齐 $versionId 依赖', detail: '${items.length} 个文件');
    final dl = _newLaunchDownloader(task);
    final failed = <String>[];
    try {
      await dl.runBatch(
        items,
        onFileError: (file, e) {
          failed.add(file);
          log('⚠️ 依赖补齐失败 $file：$e');
        },
      );
      _endTask(
        task,
        error: failed.isEmpty ? null : Exception('${failed.length} 个依赖下载失败'),
      );
    } catch (e) {
      _endTask(task, error: e);
      rethrow;
    } finally {
      _closeLaunchDownloader(dl);
    }
  }

  String _log4jConfigPath(GameVersion version) {
    final logging = version.loggingFile;
    if (logging == null || logging.file.isEmpty) return '';
    final file = File(p.join(gameDir.root, 'log_configs', logging.file));
    return file.existsSync() ? file.path : '';
  }

  static String pJoin(String a, [String b = '', String c = '']) {
    var path = a;
    if (b.isNotEmpty) path += Platform.pathSeparator + b;
    if (c.isNotEmpty) path += Platform.pathSeparator + c;
    return path;
  }

  Future<void> _pumpOutput(Process process) async {
    // 游戏输出混有非 UTF-8 字节：宽松解码，别让 FormatException 打崩 UI
    const forgivingUtf8 = Utf8Codec(allowMalformed: true);
    process.stdout
        .transform(forgivingUtf8.decoder)
        .listen(
          (line) => gameLog(line),
          onError: (Object e) => log('stdout 读取错误：$e'),
        );
    process.stderr
        .transform(forgivingUtf8.decoder)
        .listen(
          (line) => gameLog(line),
          onError: (Object e) => log('stderr 读取错误：$e'),
        );
  }

  void _setState(LauncherState s, String detail) {
    state = s;
    stateDetail = detail;
    if (s == LauncherState.idle || s == LauncherState.failed) {
      taskProgress = null;
      taskLabel = '';
    }
    notifyListeners();
    _syncTaskbar();
  }

  /// Windows 任务栏进度同步：下载/安装走正常进度条，无进度的
  /// 官方安装器阶段走跑马灯，失败变红。
  void _syncTaskbar() {
    switch (state) {
      case LauncherState.failed:
        TaskbarProgress.setState(TaskbarState.error);
      case LauncherState.installing ||
          LauncherState.preparingJava ||
          LauncherState.launching:
        final p = taskProgress;
        if (p == null) {
          TaskbarProgress.setState(TaskbarState.indeterminate);
        } else {
          TaskbarProgress.setProgress(p);
        }
      case LauncherState.idle || LauncherState.running:
        TaskbarProgress.clear();
    }
  }

  @override
  void dispose() {
    _gameProcess?.kill();
    super.dispose();
  }
}

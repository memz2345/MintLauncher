import 'dart:io';
import 'package:path/path.dart' as p;

import '../../src/enums.dart' show GraphicsBackend;
import 'arguments.dart';
import 'game_dir.dart';
import 'version_model.dart';

/// 一次启动所需的全部输入。
class LaunchOptions {
  const LaunchOptions({
    required this.javaExe,
    required this.version,
    required this.gameDir,
    required this.versionId,
    required this.playerName,
    required this.playerUuid,
    required this.memoryMb,
    required this.width,
    required this.height,
    required this.fullscreen,
    this.log4jConfigPath = '',
    this.gameHome = '',
    this.extraJvmArgs = const [],
    this.envVars = const {},
    this.serverAddress = '',
    this.authlibServer = '',
    this.authlibInjectorJar = '',
    this.extraGameArgs = const [],
    this.graphicsBackend = GraphicsBackend.auto,
    this.mesaLoaderJar = '',
    this.mesaNativeDir = '',
    this.gameAssetsDir,
  });

  final String javaExe;
  final GameVersion version;
  final GameDir gameDir;
  final String versionId;
  final String playerName;
  final String playerUuid;
  final int memoryMb;
  final int width;
  final int height;
  final bool fullscreen;
  final String log4jConfigPath;

  /// 版本隔离后的游戏主目录（存档/配置/mods 所在层）。
  /// 空 = 用共享根。
  final String gameHome;

  /// 用户自定义 JVM 参数（-Xmx 之后、json jvm 参数之前）。
  final List<String> extraJvmArgs;

  /// 传给游戏进程的环境变量。
  final Map<String, String> envVars;

  /// 启动后自动连接的服务器（`host` 或 `host:port`；空 = 不连）。
  final String serverAddress;

  /// 外置登录验证服务器根（空 = 不注入 authlib-injector）。
  final String authlibServer;

  /// authlib-injector jar 的本地路径（[authlibServer] 非空时必须给）。
  final String authlibInjectorJar;

  /// 用户追加的游戏参数（PCL2「游戏参数」）。
  final List<String> extraGameArgs;

  /// 强制图形后端（HMCL 图形设置精简版）。
  final GraphicsBackend graphicsBackend;

  /// CPU 软件渲染用的 Mesa Loader jar / native 目录（Windows）。
  final String mesaLoaderJar;
  final String mesaNativeDir;

  /// 游戏进程的实际工作目录 = 版本主目录。
  String get effectiveGameHome => gameHome.isEmpty ? gameDir.root : gameHome;

  /// 老版本资源目录（map_to_resources / virtual）；null 走现代 assets 根。
  final String? gameAssetsDir;
}

/// 构建好的启动命令。
class LaunchCommand {
  const LaunchCommand({
    required this.executable,
    required this.args,
    this.environment = const {},
  });
  final String executable;
  final List<String> args;
  final Map<String, String> environment;

  /// 打日志用的完整命令行（参数含空格时加引号）。
  String quote() {
    String q(String a) => a.contains(' ') ? '"$a"' : a;
    return [executable, ...args].map(q).join(' ');
  }
}

/// 启动命令构建器（HMCL `LauncherHelper` 的纯 Dart 精简版）：
///   java [-Xmx..] [用户 JVM 参数] [json 里的 jvm 参数] `<mainClass>`
///        [json 里的 game 参数] [窗口参数] [自动连服]
///
/// 兼容两种参数形态：
///   · 1.13+：`arguments: {jvm: [...], game: [...]}`，带 rules 逐条求值
///   · < 1.13：`minecraftArguments` 字符串 + 自建 JVM 参数
class LaunchBuilder {
  const LaunchBuilder();

  /// [expander] 可注入规则求值环境：iOS 启动探针给 **macOS 子进程** 构建
  /// 命令时进程是 iOS，`osNameForCurrentPlatform()` 会落到 `linux`，osx 专属
  /// 参数（`-XstartOnFirstThread`、`-Djava.library.path` 的 mac 块）就全丢了
  /// —— 这里显式传 `ArgumentExpander(osName: 'osx', arch: 'arm64')`。
  LaunchCommand build(LaunchOptions o, {ArgumentExpander? expander}) {
    final gameDir = o.gameDir;
    final gameHome = o.effectiveGameHome;
    final version = o.version;
    final nativesDir = gameDir.nativesDir(o.versionId);
    final classpath = _classpath(o);

    final variables = <String, String>{
      'auth_player_name': o.playerName,
      'auth_uuid': o.playerUuid,
      'auth_access_token': '0', // 离线/外置登录：固定占位（外置由注入器接管校验）
      'auth_session': 'token:0:${o.playerUuid}',
      'auth_xuid': '',
      'clientid': o.playerUuid,
      'user_type': 'legacy', // 离线用户类型
      'user_properties': '{}',
      'version_name': o.versionId,
      'profile_name': o.versionId,
      'version_type': version.type,
      'game_directory': gameHome,
      'assets_root': gameDir.assets,
      'assets_index_name': version.assetsIndexId,
      'game_assets':
          o.gameAssetsDir ??
          p.join(gameDir.assets, 'virtual', version.assetsIndexId),
      'natives_directory': nativesDir,
      'launcher_name': 'MintLauncher',
      'launcher_version': '0.1.0',
      'classpath': classpath,
      'classpath_separator': Platform.isWindows ? ';' : ':',
      'library_directory': gameDir.libraries,
      'libraries_separator': Platform.isWindows ? ';' : ':',
      'resolution_width': '${o.width}',
      'resolution_height': '${o.height}',
      'path': o.log4jConfigPath,
    };

    final args = <String>[];

    // ── 外置登录（authlib-injector 必须排在最前）──
    if (o.authlibServer.isNotEmpty) {
      if (o.authlibInjectorJar.isEmpty) {
        throw Exception('外置登录缺少 authlib-injector 注入器');
      }
      args.add(
        '-javaagent:${_quotePath(o.authlibInjectorJar)}=${o.authlibServer}',
      );
    }

    // ── 内存 ──
    args.add('-Xmx${o.memoryMb}M');

    // ── 用户自定义 JVM 参数 ──
    args.addAll(o.extraJvmArgs);

    // ── 强制 CPU 软件渲染（HMCL mesa-loader-windows 同款）──
    if (o.graphicsBackend == GraphicsBackend.cpu &&
        o.mesaLoaderJar.isNotEmpty) {
      args.add('-javaagent:${o.mesaLoaderJar}=llvmpipe');
      args.add(
        '-Dorg.glavo.mesa.loader.nativeDir='
        '${o.mesaNativeDir.isEmpty ? p.dirname(o.mesaLoaderJar) : o.mesaNativeDir}',
      );
    }

    final useModernArgs = version.jvmArguments.isNotEmpty;

    if (useModernArgs) {
      // ── 1.13+：json 的 jvm 列表（规则求值 + ${} 替换）──
      args.addAll(_expandArgumentList(version.jvmArguments, variables, expander));
    } else {
      // ── 老版本：自建 JVM 参数 ──
      if (!Platform.isWindows) {
        args.add('-Djava.library.path=$nativesDir');
      } else {
        args.add('-Djava.library.path=${_quotePath(nativesDir)}');
      }
      args.add('-Dminecraft.applet.TargetDirectory=${_quotePath(gameHome)}');
      args.add('-cp');
      args.add(classpath);
    }

    // 主类
    final mainClass = version.mainClass;
    if (mainClass.isEmpty) {
      throw Exception('版本描述里没有 mainClass');
    }
    args.add(mainClass);

    // ── 游戏参数 ──
    if (version.gameArguments.isNotEmpty) {
      args.addAll(_expandArgumentList(version.gameArguments, variables, expander));
    }
    if (version.minecraftArguments.isNotEmpty) {
      // 1.12 及更早：整串参数模板，同样要替换 ${auth_player_name} /
      // ${version_type} / ${game_directory} 等占位符（否则主菜单会显示
      // "Minecraft 1.11.2/${version_type}"，账号名也会变成占位符）。
      args.addAll([
        for (final token in version.minecraftArguments.split(' '))
          if (token.isNotEmpty) _substitute(token, variables),
      ]);
    }

    // ── 用户追加的游戏参数（PCL2「游戏参数」）──
    args.addAll(o.extraGameArgs);

    // ── 强制图形 API（仅 26.2-snapshot-2+ 认这个参数，HMCL 同款）──
    if (_supportsGraphicsBackendArg(o.versionId)) {
      if (o.graphicsBackend == GraphicsBackend.openGl) {
        args.addAll(['--graphicsBackend', 'opengl']);
      } else if (o.graphicsBackend == GraphicsBackend.vulkan) {
        args.addAll(['--graphicsBackend', 'vulkan']);
      } else if (o.graphicsBackend == GraphicsBackend.cpu) {
        args.addAll(['--graphicsBackend', 'opengl']);
      }
    }

    // 窗口尺寸 / 全屏（特性开关没开，json 里的 --width 不会出现，这里手动补）
    if (o.fullscreen) {
      args.addAll(['--fullscreen']);
    } else if (!version.gameArguments.join(' ').contains('--width') &&
        !version.minecraftArguments.contains('--width')) {
      args.addAll(['--width', '${o.width}', '--height', '${o.height}']);
    }

    // ── 自动连接服务器（HMCL「自动连服」）──
    if (o.serverAddress.isNotEmpty) {
      final parts = o.serverAddress.split(':');
      final host = parts.first;
      final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 25565 : 25565;
      args.addAll(['--server', host, '--port', '$port']);
    }

    return LaunchCommand(
      executable: o.javaExe,
      args: args,
      environment: o.envVars,
    );
  }

  /// Minecraft 26.2-snapshot-2 起才支持 `--graphicsBackend`。
  /// 用版本 id 粗略比较（26.2 之前的版本一律 false）。
  static bool _supportsGraphicsBackendArg(String versionId) {
    final match = RegExp(r'^(\d+)\.(\d+)').firstMatch(versionId);
    if (match == null) return false;
    final major = int.tryParse(match.group(1)!) ?? 0;
    final minor = int.tryParse(match.group(2)!) ?? 0;
    return major > 26 || (major == 26 && minor >= 2);
  }

  /// classpath：所有允许的库（排除 natives classifier jar）+ 客户端 jar。
  ///
  /// 没有 downloads/url 字段的库（OptiFine 注入的 optifine:OptiFine 等，
  /// 只存在本地 libraries 目录）按 maven 坐标找本地文件兜底。
  String _classpath(LaunchOptions o) {
    final gameDir = o.gameDir;
    final entries = <String>[];
    for (final lib in o.version.libraries) {
      if (!lib.allowed) continue;
      final artifact = lib.artifact;
      if (artifact != null) {
        final rel = artifact.path.isEmpty ? lib.mavenPath : artifact.path;
        entries.add(File(p.join(gameDir.libraries, rel)).path);
      } else {
        // 本地库兜底：坐标 → libraries/<mavenPath>，存在才进 classpath。
        final local = File(p.join(gameDir.libraries, lib.mavenPath));
        if (local.existsSync()) entries.add(local.path);
      }
    }
    // 主 jar（PCL2 McLibListGet 的规则）：
    //  · Forge/NeoForge 1.17+（BootstrapLauncher）→ 用版本**自己的** jar 路径，
    //    不上溯继承链——这类版本通常没有自己的 jar（本体是 libraries 里的
    //    补丁 client jar，由 BootstrapLauncher 找），这里只是不加原版 jar，
    //    避免 `_1._20._1` 与 `minecraft` 模块重复导出包。
    //  · 其它版本 → 沿 inheritsFrom 走到根版本的原版 jar。
    final jarId = o.version.usesForgeBootstrap ? o.versionId : o.version.jarId;
    final jarPath = gameDir.versionJar(jarId);
    if (File(jarPath).existsSync()) entries.add(jarPath);
    return entries.join(Platform.isWindows ? ';' : ':');
  }

  /// 展开 1.13+ 参数列表（规则求值 + `${}` 替换，见 [ArgumentExpander]）。
  List<String> _expandArgumentList(
    List<dynamic> raw,
    Map<String, String> variables, [
    ArgumentExpander? expander,
  ]) => (expander ?? _expander).expand(raw, variables);

  static final ArgumentExpander _expander = ArgumentExpander(
    osName: ArgumentExpander.osNameForCurrentPlatform(),
    arch: ArgumentExpander.mojangArch(),
  );

  String _substitute(String template, Map<String, String> variables) =>
      ArgumentExpander.substitute(template, variables);

  /// Windows 上含空格的路径给 -D 参数时要手动加引号（进程参数不含引号语义，
  /// JVM 的 -D 解析按第一个 = 切分，值里的空格需要引号保护）。
  String _quotePath(String path) => path.contains(' ') ? '"$path"' : path;

  /// 多行 JVM 参数解析：一行一个，# 开头与空行忽略，容忍行内空白切分。
  static List<String> parseJvmArgs(String text) {
    final out = <String>[];
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      out.addAll(line.split(RegExp(r'\s+')).where((s) => s.isNotEmpty));
    }
    return out;
  }

  /// 多行游戏参数解析：一行一个，按空白切分（与 JVM 参数一致）。
  static List<String> parseGameArgs(String text) => parseJvmArgs(text);

  /// 多行环境变量解析：一行一个 `KEY=VALUE`。
  static Map<String, String> parseEnvVars(String text) {
    final out = <String, String>{};
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || !line.contains('=')) continue;
      final idx = line.indexOf('=');
      final key = line.substring(0, idx).trim();
      if (key.isEmpty) continue;
      out[key] = line.substring(idx + 1).trim();
    }
    return out;
  }
}

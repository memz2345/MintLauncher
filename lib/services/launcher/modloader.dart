import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'downloader.dart';
import 'game_dir.dart';

/// 模组加载器类型。
enum ModLoader {
  forge('forge', 'Forge'),
  neoforge('neoforge', 'NeoForge'),
  fabric('fabric', 'Fabric'),
  quilt('quilt', 'Quilt');

  const ModLoader(this.id, this.label);
  final String id;
  final String label;

  /// Fabric / Quilt 同一套「profile json + 继承链补库」安装法。
  bool get isFabricFamily =>
      this == ModLoader.fabric || this == ModLoader.quilt;
}

/// 清单里展示用的一条加载器版本。
class LoaderVersionInfo {
  const LoaderVersionInfo({
    required this.version,
    this.recommended = false,
    this.latest = false,
    this.stable = true,
  });

  final String version;
  final bool recommended;
  final bool latest;
  final bool stable;

  /// 展示名（推荐版加角标）。
  String get displayLabel {
    final badges = <String>[
      if (recommended) '推荐',
      if (latest && !recommended) '最新',
    ];
    return badges.isEmpty ? version : '$version（${badges.join('/')}）';
  }
}

/// Forge/NeoForge/Fabric 安装服务（HMCL 的三条安装任务同思路）：
///
///  · Fabric：不走安装器。从 fabric-meta 拉继承原版的版本 JSON
///    （`inheritsFrom` 指向原版），落盘后交给 [VersionInstaller] 装
///    Fabric 库 + 父版本依赖。
///  · Forge / NeoForge：下载官方 installer.jar，用 `--installClient <目录>`
///    无 GUI 运行（官方安装器自带的命令行模式，HMCL 的 Forge/
///    NeoForgeInstallTask 之外最稳的路径）。安装器自己处理
///    binpatch / 库下载 / 版本 JSON 生成。
class ModloaderService {
  ModloaderService({required this.gameDir, required this.downloader});

  final GameDir gameDir;
  final Downloader downloader;

  /// 某加载器构建对应的版本目录 id（与安装产物保持一致）。
  /// Fabric/Quilt：`<prefix>-<loader>-<game>`；Forge：`<game>-forge-<loader>`；
  /// NeoForge：`neoforge-<loader>`。安装前用来判断「其实已经装过了」，
  /// 避免用「安装前后差集」推断 id 在重装时失效。
  static String versionIdFor(
    ModLoader loader,
    String game,
    String loaderVersion,
  ) => switch (loader) {
    ModLoader.fabric => 'fabric-loader-$loaderVersion-$game',
    ModLoader.quilt => 'quilt-loader-$loaderVersion-$game',
    ModLoader.forge => '$game-forge-$loaderVersion',
    ModLoader.neoforge => 'neoforge-$loaderVersion',
  };

  // ─────────────────────── 版本清单 ───────────────────────

  /// Forge 版本列表（`<game>-<forge>` 全版本号）。
  ///
  /// 数据源 files.minecraftforge.net 的 maven-metadata.json；promotions
  /// 文件提供 recommended / latest 标记。下载走 BMCLAPI /maven 镜像。
  /// Forge 版本列表。
  ///
  /// 数据源两条（和 NeoForge 同思路）：
  ///  · BMCLAPI 专用列表接口 `GET /forge/minecraft/<mc>`（国内稳，返回
  ///    `{version: "49.1.0", build, files…}` 数组）优先；
  ///  · 官方 files.minecraftforge.net 的扁平 maven-metadata.json 兜底。
  /// recommended / latest 标记走 promotions_slim.json（BMCLAPI 已镜像）。
  Future<List<LoaderVersionInfo>> forgeVersions(String game) async {
    if (downloader.mirror != Mirror.official) {
      try {
        final list = await downloader.getJsonList(
          'https://bmclapi2.bangbang93.com/forge/minecraft/$game',
        );
        final builds = <String>{
          for (final e in list)
            if (e is Map<String, dynamic> && e['version'] is String)
              e['version'] as String,
        }.toList();
        if (builds.isNotEmpty) {
          return _markedForgeBuilds(game, builds);
        }
      } catch (_) {
        // 镜像挂了走官方兜底。
      }
    }

    final meta = await downloader.getJson(
      'https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json',
    );
    final prefix = '$game-';
    final builds = <String>[
      for (final key in meta.keys)
        if (key.startsWith(prefix)) key.substring(prefix.length),
    ];
    if (builds.isEmpty) return const [];
    return _markedForgeBuilds(game, builds);
  }

  Future<List<LoaderVersionInfo>> _markedForgeBuilds(
    String game,
    List<String> builds,
  ) async {
    var recommended = '';
    var latest = '';
    try {
      // 官方规范路径（不带 /maven 前缀）；BMCLAPI 镜像会自己补 /maven。
      final promos =
          (await downloader.getJson(
                'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json',
              ))['promos']
              as Map<String, dynamic>;
      recommended = (promos['$game-recommended'] as String?) ?? '';
      latest = (promos['$game-latest'] as String?) ?? '';
    } catch (_) {
      // promotions 拉不到就都不标。
    }

    int buildNum(String v) {
      // 兼容两种形态：官方 "49.1.0"（BMCLAPI）与 "1.20.4-49.1.0" 的尾段。
      final last = v.split('-').last;
      var n = 0;
      for (final part in last.split('.')) {
        n = n * 1000 + (int.tryParse(part) ?? 0);
      }
      return n;
    }

    builds.sort((a, b) => buildNum(b).compareTo(buildNum(a)));
    return [
      for (final b in builds)
        LoaderVersionInfo(
          version: b,
          recommended: b == recommended,
          latest: b == latest,
        ),
    ];
  }

  /// NeoForge 版本列表。1.20.2+ 走 net.neoforged:neoforge
  /// （版本号 `21.1.95` = MC 1.21.1）；1.20.1 的旧制品不在此列。
  ///
  /// 数据源两条：BMCLAPI 的专用列表接口（国内稳，官方 maven.neoforged.net
  /// 经常连不上）优先，官方 REST API 兜底。
  Future<List<LoaderVersionInfo>> neoforgeVersions(String game) async {
    final prefix = _neoForgePrefix(game);
    if (prefix == null) return const [];

    if (downloader.mirror != Mirror.official) {
      try {
        final list = await downloader.getJsonList(
          'https://bmclapi2.bangbang93.com/neoforge/list/$game',
        );
        final versions = [
          for (final e in list)
            if (e is Map<String, dynamic> && e['version'] is String)
              e['version'] as String,
        ];
        if (versions.isNotEmpty) return _sortedNeoForge(prefix, versions);
      } catch (_) {
        // 镜像挂了走官方兜底。
      }
    }

    final json = await downloader.getString(
      'https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge',
    );
    final data = jsonDecode(json) as Map<String, dynamic>;
    final versions = [
      for (final v in (data['versions'] as List? ?? const []))
        if (v is String && (v.startsWith('$prefix.') || v == prefix)) v,
    ];
    return _sortedNeoForge(prefix, versions);
  }

  List<LoaderVersionInfo> _sortedNeoForge(String prefix, List<String> all) {
    final versions = [
      for (final v in all)
        if (v.startsWith('$prefix.') || v == prefix) v,
    ];
    int num(String v) =>
        v.split('.').fold(0, (acc, s) => acc * 1000 + (int.tryParse(s) ?? 0));
    versions.sort((a, b) => num(b).compareTo(num(a)));
    return [
      for (final (i, v) in versions.indexed)
        LoaderVersionInfo(version: v, latest: i == 0),
    ];
  }

  /// MC 版本 → NeoForge 版本号前缀；不支持 NeoForge 的版本返回 null。
  /// `1.21.1` → `21.1`，`1.21` → `21`，`1.20.4` → `20.4`。
  String? _neoForgePrefix(String game) {
    final parts = game.split('.');
    if (parts.length < 2) return null;
    final major = int.tryParse(parts[1]);
    final minor = parts.length > 2 ? int.tryParse(parts[2]) : null;
    // NeoForge 起家于 1.20.2（旧 1.20.1 是 net.neoforged:forge，不兼容本流程）。
    if (major == null || major < 20) return null;
    if (major == 20 && (minor == null || minor < 2)) return null;
    return minor == null ? parts[1] : '${parts[1]}.$minor';
  }

  /// Fabric loader 版本列表（稳定版优先、版本号倒序）。
  Future<List<LoaderVersionInfo>> fabricVersions(String game) =>
      _fabricFamilyVersions(
        game,
        'https://meta.fabricmc.net/v2/versions/loader/$game',
      );

  /// Quilt loader 版本列表（meta API 与 fabric 同构，v3）。
  Future<List<LoaderVersionInfo>> quiltVersions(String game) =>
      _fabricFamilyVersions(
        game,
        'https://meta.quiltmc.org/v3/versions/loader/$game',
      );

  Future<List<LoaderVersionInfo>> _fabricFamilyVersions(
    String game,
    String listUrl,
  ) async {
    // meta API 返回 JSON 数组（getJsonList）；API 顺序即「新→旧」，
    // 不要自行按版本号重排（0.10.6+build.214 这类带 build 的号会被排错）。
    final list = await downloader.getJsonList(listUrl);
    final entries = <String>[];
    for (final e in list) {
      if (e is Map<String, dynamic> && e['loader'] is Map<String, dynamic>) {
        final v = (e['loader'] as Map<String, dynamic>)['version'] as String?;
        if (v != null && v.isNotEmpty) entries.add(v);
      }
    }
    return [for (final v in entries) LoaderVersionInfo(version: v)];
  }

  // ─────────────────────── 安装 ───────────────────────

  /// Fabric / Quilt：拉 profile json 写进 `versions/<id>/`。返回新版本 id。
  ///
  /// 库与父版本（原版本体）交给 [VersionInstaller.install] 按继承链补齐。
  Future<String> installFabricFamily(
    ModLoader loader,
    String game,
    String loaderVersion, {
    void Function(String line)? onLog,
  }) async {
    void log(String line) => onLog?.call(line);
    final metaBase = switch (loader) {
      ModLoader.fabric => 'https://meta.fabricmc.net/v2',
      ModLoader.quilt => 'https://meta.quiltmc.org/v3',
      _ => throw ArgumentError('$loader 不走 profile json 安装'),
    };
    final id = ModloaderService.versionIdFor(loader, game, loaderVersion);
    log('获取 ${loader.label} profile（$game / loader $loaderVersion）');
    final profile = await downloader.getJson(
      '$metaBase/versions/loader/$game/$loaderVersion/profile/json',
    );
    final dir = Directory(gameDir.versionDir(id));
    dir.createSync(recursive: true);
    File(gameDir.versionJson(id)).writeAsStringSync(jsonEncode(profile));
    log('✅ ${loader.label} 版本描述已写入 $id');
    return id;
  }

  /// Forge / NeoForge：下载官方 installer 并以 `--installClient` 无头安装。
  ///
  /// [javaExe] 用于跑安装器；[onLog] 输出安装器 stdout/stderr。
  /// 安装器退出码非 0 时抛异常。
  Future<void> installViaOfficialInstaller(
    ModLoader loader,
    String game,
    String loaderVersion, {
    required String javaExe,
    void Function(String line)? onLog,
  }) async {
    void log(String line) => onLog?.call(line);
    final (fullId, installerUrl) = switch (loader) {
      ModLoader.forge => (
        ModloaderService.versionIdFor(loader, game, loaderVersion),
        'https://maven.minecraftforge.net/net/minecraftforge/forge/'
            '$game-$loaderVersion/forge-$game-$loaderVersion-installer.jar',
      ),
      ModLoader.neoforge => (
        ModloaderService.versionIdFor(loader, game, loaderVersion),
        'https://maven.neoforged.net/releases/net/neoforged/neoforge/'
            '$loaderVersion/neoforge-$loaderVersion-installer.jar',
      ),
      _ => throw ArgumentError('$loader 不走官方安装器'),
    };

    final installerFile = File(
      p.join(gameDir.root, 'installer-${loader.id}-$fullId.jar'),
    );
    log('下载 ${loader.label} 安装器…');
    await downloader.fetchFile(
      DownloadItem(
        url: installerUrl,
        dest: installerFile.path,
        name: '${loader.label} installer',
      ),
    );

    // Forge 安装器要求目标目录里已有官方启动器的档案文件，全新目录会报
    // "There is no Minecraft launcher profile … run the launcher first"。
    // HMCL 同款处理：先写一个空的 launcher_profiles.json。
    final profiles = File(p.join(gameDir.root, 'launcher_profiles.json'));
    if (!profiles.existsSync()) {
      profiles.writeAsStringSync(
        jsonEncode({'profiles': {}, 'settings': {}, 'version': 3}),
      );
    }

    log('运行 ${loader.label} 官方安装器（--installClient）…');
    final result = await Process.run(
      javaExe,
      ['-jar', installerFile.path, '--installClient', gameDir.root],
      workingDirectory: gameDir.root,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    for (final line in (result.stdout as String).split('\n')) {
      if (line.trim().isNotEmpty) log('  $line');
    }
    for (final line in (result.stderr as String).split('\n')) {
      if (line.trim().isNotEmpty) log('  ⚠ $line');
    }
    try {
      installerFile.deleteSync();
    } catch (_) {}

    if (result.exitCode != 0) {
      throw Exception(
        '${loader.label} 安装器退出码 ${result.exitCode}'
        '（详见日志；常见原因：Java 版本不符 / 网络问题）',
      );
    }
    // NeoForge 的版本目录名与安装器内部实现有关，不硬编码校验；
    // 安装器成功后 versions/ 下会多出带 json 的目录。
    log('✅ ${loader.label} $loaderVersion 安装完成');
  }
}

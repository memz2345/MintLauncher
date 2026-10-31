import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:path/path.dart' as p;

import 'downloader.dart';
import 'game_dir.dart';

/// 清单里的一条 OptiFine 版本（BMCLAPI /optifine/versionList 条目）。
class OptiFineEntry {
  OptiFineEntry({required this.json});

  final Map<String, dynamic> json;

  String get mcVersion => (json['mcversion'] as String?) ?? '';
  String get type => (json['type'] as String?) ?? '';
  String get patch => (json['patch'] as String?) ?? '';
  String get filename => (json['filename'] as String?) ?? '';
  String get forgeInfo => (json['forge'] as String?) ?? '';

  /// preview_OptiFine_1.20.1_HD_U_I5_pre4.jar → 预览版。
  bool get isPreview => filename.startsWith('preview_');

  /// OptiFine_1.20.1_HD_U_I6.jar → HD_U_I6（type/patch 字段各年代含义
  /// 不一致，从文件名解析最稳）。
  String get edition {
    var name = p.basenameWithoutExtension(filename);
    if (name.startsWith('preview_')) name = name.substring('preview_'.length);
    if (name.startsWith('OptiFine_')) name = name.substring('OptiFine_'.length);
    if (name.startsWith(mcVersion)) {
      name = name.substring(mcVersion.length);
    }
    if (name.startsWith('_')) name = name.substring(1);
    return name;
  }

  /// BMCLAPI 下载地址（内部 302 到带签名的镜像 CDN）。
  String get downloadUrl =>
      'https://bmclapi2.bangbang93.com/optifine/$mcVersion/$type/$patch';

  /// 展示名（版本列表行）。
  String get displayLabel => isPreview ? '$edition（预览）' : edition;
}

/// OptiFine 安装服务（HMCL OptiFineInstallTask 的 Dart 移植）。
///
/// 官方安装器的 `optifine.Installer` main 会忽略所有参数、只认默认
/// .minecraft（Windows 下读 APPDATA），自定义目录没法直接用；且 1.13+
/// 需要 optifine.Patcher 对原版 jar 打 xdelta 补丁。因此照 HMCL 的做法
/// **原生安装、不跑安装器**：
///
///  1. 安装器 jar 若含 `optifine/Patcher.class`（1.13+）：
///     `java -cp installer.jar optifine.Patcher <vanilla.jar> <installer.jar> <lib.jar>`
///     产出 OptiFine 库 jar；否则（≤1.12）安装器 jar 本身就是库 jar。
///  2. 库 jar 删掉 `META-INF/mods.toml`（防止被 Forge 当 mod 加载）。
///  3. 安装器捆绑的 launchwrapper（`launchwrapper-2.0.jar` 或
///     `launchwrapper-of-*.jar`）装进 libraries，没有就补
///     `net.minecraft:launchwrapper:1.12`。
///  4. 生成版本 json：inheritsFrom 原版、mainClass 换成
///     `net.minecraft.launchwrapper.Launch`、game 参数追加
///     `--tweakClass optifine.OptiFineTweaker`。
class OptiFineService {
  OptiFineService({required this.gameDir, required this.downloader});

  final GameDir gameDir;
  final Downloader downloader;

  /// BMCLAPI 的 OptiFine 全量清单（HMCL BMCLAPIDownloadProvider 同源）。
  Future<List<OptiFineEntry>> versions() async {
    final list = await downloader.getJsonList(
      'https://bmclapi2.bangbang93.com/optifine/versionList',
    );
    final entries = [
      for (final e in list)
        if (e is Map<String, dynamic>) OptiFineEntry(json: e),
    ];
    // 稳定版在前，同组内按文件名倒序（文件名里含版本字母序）。
    entries.sort((a, b) {
      if (a.isPreview != b.isPreview) return a.isPreview ? 1 : -1;
      return b.filename.compareTo(a.filename);
    });
    return entries;
  }

  /// 把 OptiFine 装到 [baseVersion] 之上（原版或 Forge 等模组化版本均可）。
  ///
  /// [mcVersion] 是基版本对应的 Minecraft 版本（沿 inheritsFrom 链解析，
  /// HMCL 同样以 vanilla 客户端 jar 作为 Patcher 输入）。基版本本体
  /// （json + jar）必须已存在。返回新版本 id：
  /// `<baseVersion>-OptiFine_<edition>`。
  ///
  /// Forge 组合说明（HMCL 同款）：生成的 json 把 mainClass 统一换成
  /// `net.minecraft.launchwrapper.Launch` 并追加
  /// `--tweakClass optifine.OptiFineTweaker`，Forge 1.17+ 的
  /// BootstrapLauncher 也被覆盖 —— 现代安装器捆绑的
  /// `launchwrapper-of-2.x` 正是为引导 Forge 而存在的。
  Future<String> install(
    String baseVersion, {
    required String mcVersion,
    required OptiFineEntry entry,
    required String javaExe,
    String? localInstaller,
    void Function(String line)? onLog,
  }) async {
    void log(String line) => onLog?.call(line);
    if (entry.mcVersion != mcVersion) {
      throw Exception(
        'OptiFine ${entry.edition} 对应 Minecraft '
        '${entry.mcVersion}，与所选版本（$mcVersion）不匹配',
      );
    }
    final edition = entry.edition;
    final mavenVersion = '${mcVersion}_$edition';
    final versionId = '$baseVersion-OptiFine_$edition';

    final baseJson = File(gameDir.versionJson(baseVersion));
    if (!baseJson.existsSync()) {
      throw Exception('基版本 $baseVersion 未安装');
    }

    // ── Forge / NeoForge 基版本：走官方共存路线 ──
    // OptiFine 1.17+ 与 Forge 的官方共存方式是把 OF jar 作为 Forge mod
    // 放进 mods/（安装器里的 OptiFineForgeTweaker / Patcher 都是 1.12 时代
    // 的老路）。生成一个继承 Forge 的别名版本，OF jar 放进它的隔离 mods；
    // 版本目录里有 mods 也会触发启动器的自动版本隔离。
    if (await _isForgeBase(baseVersion)) {
      return _installOnForge(
        baseVersion,
        mcVersion: mcVersion,
        entry: entry,
        onLog: onLog,
      );
    }
    // Patcher 输入 = 基版本 jar（Forge 版本目录里的 jar 就是原版客户端）；
    // 兜底用对应 MC 版本的原版 jar。
    var patcherInput = File(gameDir.versionJar(baseVersion));
    if (!patcherInput.existsSync()) {
      patcherInput = File(gameDir.versionJar(mcVersion));
    }
    if (!patcherInput.existsSync()) {
      throw Exception('找不到客户端 jar（$baseVersion / $mcVersion 都没有）');
    }

    // ── 1. 安装器 jar ──
    final installerDir = Directory(p.join(gameDir.root, 'installers'));
    if (!installerDir.existsSync()) installerDir.createSync(recursive: true);
    final installerFile = File(p.join(installerDir.path, entry.filename));
    if (localInstaller != null) {
      await File(localInstaller).copy(installerFile.path);
    } else if (!installerFile.existsSync()) {
      log('下载 ${entry.filename}…');
      await downloader.fetchFile(
        DownloadItem(
          url: entry.downloadUrl,
          dest: installerFile.path,
          name: entry.filename,
        ),
      );
    }

    // ── 2. 解析安装器内容 ──
    final bytes = await installerFile.readAsBytes();
    final ar.Archive installer;
    try {
      installer = ar.ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw Exception('OptiFine 安装器不是有效的 jar（${entry.filename}）');
    }
    ar.ArchiveFile? find(String name) {
      for (final f in installer) {
        if (f.name == name && f.isFile) return f;
      }
      return null;
    }

    final hasPatcher = find('optifine/Patcher.class') != null;
    log(
      hasPatcher
          ? '检测到 Patcher（$mcVersion 需要 xdelta 补丁）'
          : '旧版 OptiFine：安装器 jar 直接作为库',
    );

    // ── 3. 生成 OptiFine 库 jar ──
    final libPath = p.join(
      gameDir.libraries,
      'optifine',
      'OptiFine',
      mavenVersion,
      'OptiFine-$mavenVersion.jar',
    );
    final libFile = File(libPath);
    if (!libFile.parent.existsSync())
      libFile.parent.createSync(recursive: true);
    if (hasPatcher) {
      log(
        '运行 optifine.Patcher 补丁客户端 jar（输入：${p.basename(patcherInput.path)}）…',
      );
      final result = await Process.run(
        javaExe,
        [
          '-cp',
          installerFile.path,
          'optifine.Patcher',
          patcherInput.path,
          installerFile.path,
          libFile.path,
        ],
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
      for (final line in (result.stderr as String).split('\n')) {
        if (line.trim().isNotEmpty) log('  $line');
      }
      if (result.exitCode != 0 || !libFile.existsSync()) {
        throw Exception('optifine.Patcher 失败（exitCode=${result.exitCode}）');
      }
    } else {
      await installerFile.copy(libFile.path);
    }

    // ── 4. 从库 jar 里删掉 mods.toml（别被 Forge 当成 mod）──
    await _removeModsToml(libFile);

    // ── 5. launchwrapper ──
    final libraries = <Map<String, dynamic>>[
      {'name': 'optifine:OptiFine:$mavenVersion'},
    ];
    final lw2 = find('launchwrapper-2.0.jar');
    final lwTxt = find('launchwrapper-of.txt');
    var hasLaunchWrapper = false;
    if (lw2 != null) {
      final dest = p.join(
        gameDir.libraries,
        'optifine',
        'launchwrapper',
        '2.0',
        'launchwrapper-2.0.jar',
      );
      await _writeEntry(lw2, dest);
      libraries.add({'name': 'optifine:launchwrapper:2.0'});
      hasLaunchWrapper = true;
      log('安装捆绑的 launchwrapper 2.0');
    } else if (lwTxt != null) {
      final lwVersion = utf8.decode(lwTxt.content as List<int>).trim();
      final lwJar = find('launchwrapper-of-$lwVersion.jar');
      if (lwJar != null) {
        final dest = p.join(
          gameDir.libraries,
          'optifine',
          'launchwrapper-of',
          lwVersion,
          'launchwrapper-of-$lwVersion.jar',
        );
        await _writeEntry(lwJar, dest);
        libraries.add({'name': 'optifine:launchwrapper-of:$lwVersion'});
        hasLaunchWrapper = true;
        log('安装捆绑的 launchwrapper-of $lwVersion');
      }
    }
    if (!hasLaunchWrapper) {
      // 老版本没有捆绑：从 Mojang 库仓库补 launchwrapper 1.12。
      libraries.add({
        'name': 'net.minecraft:launchwrapper:1.12',
        'url': 'https://libraries.minecraft.net/',
      });
      log('补装 launchwrapper 1.12');
    }

    // ── 6. 版本 json ──
    final now = DateTime.now().toUtc().toIso8601String();
    final versionJson = {
      'id': versionId,
      'inheritsFrom': baseVersion,
      'time': now,
      'releaseTime': now,
      'type': 'release',
      'mainClass': 'net.minecraft.launchwrapper.Launch',
      'arguments': {
        'game': ['--tweakClass', 'optifine.OptiFineTweaker'],
      },
      'libraries': libraries,
    };
    final dir = Directory(gameDir.versionDir(versionId));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File(gameDir.versionJson(versionId)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(versionJson),
    );

    log('✅ OptiFine $edition（$mcVersion @ $baseVersion）安装完成：$versionId');
    return versionId;
  }

  /// 基版本链上是否是 Forge / NeoForge 1.17+（BootstrapLauncher）。
  Future<bool> _isForgeBase(String baseVersion) async {
    var current = baseVersion;
    for (var depth = 0; depth < 8; depth++) {
      final file = File(gameDir.versionJson(current));
      if (!file.existsSync()) return false;
      Map<String, dynamic> json;
      try {
        json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {
        return false;
      }
      if (json['mainClass'] == 'cpw.mods.bootstraplauncher.BootstrapLauncher') {
        return true;
      }
      final inherits = json['inheritsFrom'] as String?;
      if (inherits == null || inherits.isEmpty) return false;
      current = inherits;
    }
    return false;
  }

  /// Forge 基版本上的安装：OF jar 作为 Forge mod 放进别名版本的隔离 mods/。
  Future<String> _installOnForge(
    String baseVersion, {
    required String mcVersion,
    required OptiFineEntry entry,
    void Function(String line)? onLog,
  }) async {
    void log(String line) => onLog?.call(line);
    final edition = entry.edition;
    final versionId = '$baseVersion-OptiFine_$edition';

    // 安装器 jar = OF mod jar 本体（Extract 按钮产物就是它自己）。
    final installerDir = Directory(p.join(gameDir.root, 'installers'));
    if (!installerDir.existsSync()) installerDir.createSync(recursive: true);
    final installerFile = File(p.join(installerDir.path, entry.filename));
    if (!installerFile.existsSync()) {
      log('下载 ${entry.filename}…');
      await downloader.fetchFile(
        DownloadItem(
          url: entry.downloadUrl,
          dest: installerFile.path,
          name: entry.filename,
        ),
      );
    }

    final dir = Directory(gameDir.versionDir(versionId));
    final modsDir = Directory(p.join(dir.path, 'mods'));
    if (!modsDir.existsSync()) modsDir.createSync(recursive: true);
    final dest = File(p.join(modsDir.path, entry.filename));
    if (!dest.existsSync()) await installerFile.copy(dest.path);

    // 纯别名 json：不带 mainClass / 库覆盖，Forge 的引导链原样继承。
    final now = DateTime.now().toUtc().toIso8601String();
    File(gameDir.versionJson(versionId)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'id': versionId,
        'inheritsFrom': baseVersion,
        'time': now,
        'releaseTime': now,
        'type': 'release',
      }),
    );
    log('✅ OptiFine $edition 已作为 Forge mod 装到 $versionId/mods');
    return versionId;
  }

  /// 重写 zip：去掉 META-INF/mods.toml。
  Future<void> _removeModsToml(File jar) async {
    final bytes = await jar.readAsBytes();
    final archive = ar.ZipDecoder().decodeBytes(bytes);
    var changed = false;
    final rebuilt = ar.Archive();
    for (final f in archive) {
      if (f.isFile && f.name == 'META-INF/mods.toml') {
        changed = true;
        continue;
      }
      rebuilt.addFile(f);
    }
    if (changed) {
      await jar.writeAsBytes(ar.ZipEncoder().encode(rebuilt), flush: true);
    }
  }

  Future<void> _writeEntry(ar.ArchiveFile entry, String dest) async {
    final file = File(dest);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    await file.writeAsBytes(entry.content as List<int>, flush: true);
  }
}

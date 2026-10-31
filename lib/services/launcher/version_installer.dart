import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:path/path.dart' as p;

import 'downloader.dart';
import 'game_dir.dart';
import 'manifest.dart';
import 'version_model.dart';

/// 安装阶段（进度展示用）。
enum InstallPhase {
  versionJson('获取版本描述'),
  libraries('下载依赖库'),
  client('下载客户端'),
  assetIndex('下载资源索引'),
  assets('下载游戏资源'),
  natives('解压原生库'),
  done('完成');

  const InstallPhase(this.label);
  final String label;
}

class InstallProgress {
  const InstallProgress({
    required this.phase,
    required this.fraction,
    this.detail = '',
  });

  final InstallPhase phase;
  final double fraction; // 0..1，当前阶段内
  final String detail;
}

/// 安装跑完了，但有文件没落地 —— 之前这种只写日志、UI 照样打勾。
class InstallIncompleteException implements Exception {
  const InstallIncompleteException(this.failures);

  final List<DownloadFailure> failures;

  String get summary =>
      '${failures.length} 个文件下载失败：'
      '${failures.take(4).map((f) => f.name).join('、')}'
      '${failures.length > 4 ? ' …' : ''}';

  @override
  String toString() => summary;
}

/// 版本安装器：版本 JSON → 库 / 客户端 / 资源 / natives 全部落盘。
///
/// 流程与 HMCL 的 DefaultGameRepository + DownloadTask 一致：
///  1. 清单里找版本 → 下载 `<id>.json`（auto 镜像优先、官方兜底）
///  2. 解析（含 inheritsFrom 合并）
///  3. 并发下载库 + 客户端 + log4j 配置
///  4. 下载资源索引 → 并发下载资源对象（sha1 校验，hash 即路径）
///  5. natives jar 解到 `<id>-natives/`
class VersionInstaller {
  VersionInstaller({
    required this.gameDir,
    required this.downloader,
    this.verifyFiles = true,
    this.isCancelled,
  });

  final GameDir gameDir;
  final Downloader downloader;

  /// false = 不校验已有文件（PCL2「关闭文件校验」）：只补缺失文件。
  final bool verifyFiles;

  /// 启动中断回调；true 时尽快抛异常退出。
  final bool Function()? isCancelled;

  bool cancelled = false;

  void _checkCancelled() {
    if (cancelled || isCancelled?.call() == true) {
      downloader.cancelled = true;
      throw Exception('已取消');
    }
  }

  /// 按版本 id 安装。[onProgress] 回调阶段进度；[onLog] 输出可读日志。
  Future<void> install(
    String versionId, {
    void Function(InstallProgress progress)? onProgress,
    void Function(String line)? onLog,
  }) async {
    void log(String line) => onLog?.call(line);
    void progress(InstallPhase phase, double fraction, [String detail = '']) =>
        onProgress?.call(
          InstallProgress(phase: phase, fraction: fraction, detail: detail),
        );

    _checkCancelled();
    if (!verifyFiles) log('已关闭文件完整性校验：已有文件直接信任');

    // ── 1. 版本 JSON ──
    progress(InstallPhase.versionJson, 0.1);
    final jsonFile = File(gameDir.versionJson(versionId));
    if (!jsonFile.existsSync()) {
      final manifest = await VersionManifest.fetch(downloader);
      final entry = manifest.find(versionId);
      if (entry == null) {
        throw Exception('清单里找不到版本 $versionId');
      }
      log('获取版本 $versionId（${entry.type}）');
      final text = await downloader.getString(entry.url);
      jsonFile.parent.createSync(recursive: true);
      jsonFile.writeAsStringSync(text);
    }

    // ── 2. 解析（含 inheritsFrom）──
    final version = await _resolveFromDisk(versionId);
    log(
      '主类 ${version.mainClass}，Java ${version.javaMajor <= 0 ? '?' : version.javaMajor}，'
      '资源索引 ${version.assetsIndexId}，${version.libraries.length} 个库',
    );

    // ── 3. 库 + 客户端 + log4j ──
    final libraryItems = <DownloadItem>[];
    final nativesJars = <DownloadItem>[];
    for (final lib in version.libraries) {
      if (!lib.allowed) continue;
      final artifact = lib.artifact;
      if (artifact != null && artifact.url.isNotEmpty) {
        final dest = p.join(
          gameDir.libraries,
          artifact.path.isEmpty ? lib.mavenPath : artifact.path,
        );
        if (verifyFiles || !File(dest).existsSync()) {
          libraryItems.add(
            DownloadItem(
              url: artifact.url,
              dest: dest,
              sha1: artifact.sha1,
              size: artifact.size,
              name: lib.name,
            ),
          );
        }
      }
      if (lib.needsNative) {
        final nd = lib.nativesDownload!;
        final classifier = lib.nativesClassifier!;
        final mavenNativePath = _nativesMavenPath(lib.name, classifier);
        final dest = p.join(
          gameDir.libraries,
          nd.path.isEmpty ? mavenNativePath : nd.path,
        );
        if (verifyFiles || !File(dest).existsSync()) {
          nativesJars.add(
            DownloadItem(
              url: nd.url,
              dest: dest,
              sha1: nd.sha1,
              size: nd.size,
              name: '${lib.name} ($classifier)',
            ),
          );
        }
      }
    }

    // 客户端 jar（jar 字段指定的另一个版本也可以）
    final jarId = version.jarId;
    final jarItem = <DownloadItem>[];
    final clientDownload = version.clientDownload;
    final jarFile = File(gameDir.versionJar(jarId));
    if (clientDownload != null && clientDownload.url.isNotEmpty) {
      // 只看「存在」会放行半截 jar（260MB 下到一半被杀进程），启动时报
      // 「invalid main client jar」；所以对得上大小才认它下好了。
      final intact =
          jarFile.existsSync() &&
          (clientDownload.size == null ||
              jarFile.lengthSync() == clientDownload.size);
      if (!intact) {
        if (jarFile.existsSync()) {
          log(
            '⚠️ 客户端 jar 大小不符（${jarFile.lengthSync()} ≠ '
            '${clientDownload.size}），重新下载',
          );
          jarFile.deleteSync();
        }
        jarItem.add(
          DownloadItem(
            url: clientDownload.url,
            dest: jarFile.path,
            sha1: clientDownload.sha1,
            size: clientDownload.size,
            name: '$jarId.jar',
          ),
        );
      }
    }

    // log4j 配置（log4shell 缓解 + 版本日志格式）
    final logging = version.loggingFile;
    final log4jItems = <DownloadItem>[];
    var log4jPath = '';
    if (logging != null && logging.url.isNotEmpty) {
      log4jPath = p.join(gameDir.root, 'log_configs', logging.file);
      if (verifyFiles || !File(log4jPath).existsSync()) {
        log4jItems.add(
          DownloadItem(url: logging.url, dest: log4jPath, name: logging.file),
        );
      }
    }

    final libFraction = 0.15;
    final clientFraction = 0.25;
    // 每一批的失败都攒起来；结尾统一报「有几个文件没下来」，
    // 不再让 ✅ 掩盖真实未完成的依赖。
    final failures = <DownloadFailure>[];
    Future<void> batch(
      List<DownloadItem> items, {
      void Function(DownloadProgress pr)? onProgress,
      required void Function(String file, Object e) onError,
    }) async {
      final result = await downloader.runBatch(
        items,
        onProgress: onProgress,
        onFileError: onError,
      );
      failures.addAll(result.failed);
    }

    progress(
      InstallPhase.libraries,
      0,
      '${libraryItems.length + nativesJars.length} 个库',
    );
    await batch(
      libraryItems,
      onProgress: (pr) => progress(
        InstallPhase.libraries,
        libFraction * pr.fraction,
        pr.currentName,
      ),
      onError: (file, e) => log('⚠️ 库下载失败 $file：$e'),
    );
    progress(InstallPhase.client, 0, jarId);
    await batch(
      jarItem,
      onProgress: (pr) => progress(
        InstallPhase.client,
        clientFraction * pr.fraction,
        pr.currentName,
      ),
      onError: (file, e) => log('⚠️ 客户端下载失败 $file：$e'),
    );
    await batch(
      log4jItems,
      onError: (file, e) => log('⚠️ log4j 配置下载失败 $file：$e'),
    );
    await batch(
      nativesJars,
      onError: (file, e) => log('⚠️ natives 下载失败 $file：$e'),
    );
    _checkCancelled();

    // ── 4. 资源索引 + 资源对象 ──
    final assetIndexInfo = version.assetIndexInfo;
    Map<String, AssetObject>? objects;
    if (assetIndexInfo != null && assetIndexInfo.url.isNotEmpty) {
      final indexFile = File(gameDir.assetIndex(assetIndexInfo.id));
      progress(InstallPhase.assetIndex, 0.1);
      // 已存在的索引也要能解析：上一轮写了一半的 json 会让「资源」这一整批
      // 静默变成 0 个文件，进度直接冲到 100%。
      var text = indexFile.existsSync() ? indexFile.readAsStringSync() : '';
      var valid =
          text.isNotEmpty &&
          (assetIndexInfo.sha1 == null ||
              sha1Hex(utf8.encode(text)) == assetIndexInfo.sha1);
      if (valid) {
        try {
          jsonDecode(text) as Map<String, dynamic>;
        } on FormatException {
          valid = false;
        }
      }
      if (!valid) {
        indexFile.parent.createSync(recursive: true);
        text = await downloader.getString(assetIndexInfo.url);
        if (assetIndexInfo.sha1 != null &&
            sha1Hex(utf8.encode(text)) != assetIndexInfo.sha1) {
          throw Exception('资源索引校验失败');
        }
        indexFile.writeAsStringSync(text);
      }
      final indexJson =
          jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
      objects = {
        for (final entry
            in (indexJson['objects'] as Map<String, dynamic>).entries)
          entry.key: AssetObject.fromJson(entry.value as Map<String, dynamic>),
      };

      progress(InstallPhase.assets, 0, '${objects.length} 个资源');
      final assetItems = <DownloadItem>[];
      final seenDests = <String>{};
      for (final obj in objects.values) {
        if (obj.hash.isEmpty) continue;
        final dest = gameDir.assetObject(obj.hash);
        // 不同虚拟路径可以指向同一 hash：按 dest 去重，不然两个 worker
        // 会同时写同一个 .download 临时文件互相打架。
        if (!seenDests.add(dest)) continue;
        if (File(dest).existsSync()) continue;
        assetItems.add(
          DownloadItem(
            url:
                'https://resources.download.minecraft.net/${obj.hash.substring(0, 2)}/${obj.hash}',
            dest: dest,
            sha1: obj.hash,
            size: obj.size,
          ),
        );
      }
      log('需要下载 ${assetItems.length} 个资源文件');
      await batch(
        assetItems,
        onProgress: (pr) =>
            progress(InstallPhase.assets, pr.fraction, pr.currentName),
        onError: (file, e) => log('⚠️ 资源下载失败 $file：$e'),
      );
      _checkCancelled();
    }

    // ── 5. natives 解压 ──
    progress(InstallPhase.natives, 0.2);
    final nativesDir = gameDir.nativesDir(versionId);
    await _extractNatives(nativesJars, nativesDir, onLog: log);
    _checkCancelled();
    if (failures.isNotEmpty) {
      // 依赖没落地就报「安装完成」，是「幽灵下载」的另一半：下次启动要么
      // 缺库崩，要么再悄悄补一轮，用户完全看不出来。
      log(
        '❌ 版本 $versionId 安装不完整：${InstallIncompleteException(failures).summary}',
      );
      throw InstallIncompleteException(failures);
    }
    progress(InstallPhase.done, 1);
    log('✅ 版本 $versionId 安装完成');
  }

  /// 从磁盘读取版本 json（含 inheritsFrom 链）。
  Future<GameVersion> _resolveFromDisk(String versionId) async {
    Future<Map<String, dynamic>?> load(String id) async {
      final f = File(gameDir.versionJson(id));
      if (!f.existsSync()) return null;
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    }

    final json = await load(versionId);
    if (json == null)
      throw Exception('版本描述不存在：${gameDir.versionJson(versionId)}');
    return GameVersion.resolve(versionId, json, load);
  }

  /// maven 坐标 + classifier → 库路径（downloads.classifiers 缺 path 时兜底）。
  String _nativesMavenPath(String name, String classifier) {
    final parts = name.split(':');
    if (parts.length < 3) return name;
    final group = parts[0].replaceAll('.', '/');
    final artifact = parts[1];
    final version = parts[2];
    return '$group/$artifact/$version/$artifact-$version-$classifier.jar';
  }

  /// 把 natives jar 里的原生库解到 [nativesDir]（跳过 META-INF / 已存在的同名文件）。
  Future<void> _extractNatives(
    List<DownloadItem> jars,
    String nativesDir, {
    void Function(String line)? onLog,
  }) async {
    void warn(String line) => onLog?.call(line);
    final dir = Directory(nativesDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    for (final jar in jars) {
      final file = File(jar.dest);
      if (!file.existsSync()) {
        // 解不出来 = 这个 jar 压根没下完。以前是静默 continue，游戏启动才
        // 发现缺 .so；现在写进日志，配合上面的失败统计一起暴露给用户。
        warn('⚠️ natives jar 缺失，跳过解压：${jar.displayName}');
        continue;
      }
      final bytes = file.readAsBytesSync();
      final ar.Archive archive;
      try {
        archive = ar.ZipDecoder().decodeBytes(bytes);
      } catch (e) {
        warn('⚠️ natives jar 解不开（坏文件？）：${jar.displayName}：$e');
        continue;
      }
      for (final entry in archive) {
        if (entry.isFile) {
          final name = entry.name;
          if (name.contains('..')) continue;
          if (name.startsWith('META-INF/')) continue;
          final outFile = File(p.join(nativesDir, p.basename(name)));
          // 同名同大小就跳过（重复安装不重写）
          if (outFile.existsSync() && outFile.lengthSync() == entry.size)
            continue;
          outFile.writeAsBytesSync(entry.content as List<int>);
        }
      }
    }
  }
}

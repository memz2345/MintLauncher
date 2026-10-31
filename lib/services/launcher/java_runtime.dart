import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:path/path.dart' as p;

import 'downloader.dart';
import 'game_dir.dart';

/// Java 运行时：系统检测 + Adoptium（Temurin JRE）下载。
///
/// HMCL 的 JavaRuntime 同思路：先找系统里已有的 Java，没有或大版本不匹配时
/// 从 Adoptium API 拉对应大版本的 JRE 解压到 `<gameDir>/runtime/`。
class JavaRuntime {
  JavaRuntime({required this.executablePath, required this.version});

  final String executablePath;
  final int version; // 主版本号（8/17/21...）

  @override
  String toString() => 'Java $version（$executablePath）';
}

class JavaService {
  JavaService({required this.gameDir});

  final GameDir gameDir;

  /// 检测到的候选（调试/设置页展示用）。
  final List<JavaRuntime> detected = [];

  /// 找出可用的 Java：自定义路径优先，其次已下载的运行时、
  /// JAVA_HOME、PATH、常见安装目录。
  Future<List<JavaRuntime>> detectAll({String? customPath}) async {
    detected.clear();
    final candidates = <String>[];

    if (customPath != null && customPath.trim().isNotEmpty) {
      candidates.add(customPath.trim());
    }

    // 启动器自己下载过的运行时
    final runtimeDir = Directory(gameDir.runtime);
    if (runtimeDir.existsSync()) {
      for (final entry in runtimeDir.listSync()) {
        if (entry is! Directory) continue;
        final exe = _javaExeOf(entry.path);
        if (exe != null) candidates.add(exe);
      }
    }

    // JAVA_HOME
    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome != null && javaHome.isNotEmpty) {
      final exe = _javaExeOf(javaHome);
      if (exe != null) candidates.add(exe);
    }

    // PATH 里的 java
    try {
      final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
        'java',
      ], runInShell: true);
      for (final line in (result.stdout as String).split('\n')) {
        final candidate = line.trim();
        if (candidate.isNotEmpty) candidates.add(candidate);
      }
    } catch (_) {
      // where/which 不存在就算了
    }

    // 常见安装目录
    if (Platform.isWindows) {
      final roots = [r'C:\Program Files', r'C:\Program Files (x86)'];
      final vendorPrefixes = [
        'Java',
        'Eclipse Adoptium',
        'Microsoft',
        'Zulu',
        'Amazon Corretto',
        'BellSoft',
        'AdoptOpenJDK',
      ];
      for (final root in roots) {
        final dir = Directory(root);
        if (!dir.existsSync()) continue;
        for (final vendor in dir.listSync()) {
          if (vendor is! Directory) continue;
          if (!vendorPrefixes.any((v) => p.basename(vendor.path).startsWith(v)))
            continue;
          for (final jdk in vendor.listSync()) {
            if (jdk is! Directory) continue;
            final exe = _javaExeOf(jdk.path);
            if (exe != null) candidates.add(exe);
          }
        }
      }
    } else if (Platform.isLinux) {
      for (final root in ['/usr/lib/jvm', '/opt/java']) {
        final dir = Directory(root);
        if (!dir.existsSync()) continue;
        for (final jdk in dir.listSync()) {
          if (jdk is! Directory) continue;
          final exe = _javaExeOf(jdk.path);
          if (exe != null) candidates.add(exe);
        }
      }
    } else if (Platform.isMacOS) {
      try {
        final result = await Process.run('/usr/libexec/java_home', [
          '-V',
        ], runInShell: false);
        final out = (result.stdout as String) + (result.stderr as String);
        for (final match in RegExp(r'"([^"]+)"').allMatches(out)) {
          final exe = _javaExeOf(match.group(1)!);
          if (exe != null) candidates.add(exe);
        }
      } catch (_) {}
    }

    // 去重 + 探测版本
    final seen = <String>{};
    for (final candidate in candidates) {
      final normalized = p.normalize(candidate);
      if (!seen.add(normalized.toLowerCase())) continue;
      final runtime = await probe(normalized);
      if (runtime != null) detected.add(runtime);
    }
    // 大版本倒序
    detected.sort((a, b) => b.version.compareTo(a.version));
    return detected;
  }

  /// 在解压目录里递归找 java（Temurin zip 外面多一层 jdk-xxx-jre/）。
  String? _findJavaExe(String root) {
    final direct = _javaExeOf(root);
    if (direct != null) return direct;
    final dir = Directory(root);
    if (!dir.existsSync()) return null;
    try {
      for (final entry in dir.listSync()) {
        if (entry is! Directory) continue;
        final nested = _findJavaExe(entry.path);
        if (nested != null) return nested;
      }
    } catch (_) {}
    return null;
  }

  /// 目录或文件路径 → java 可执行文件。
  String? _javaExeOf(String path) {
    if (Platform.isWindows) {
      final direct = File(p.join(path, 'bin', 'java.exe'));
      if (direct.existsSync()) return direct.path;
      if (path.toLowerCase().endsWith('java.exe') && File(path).existsSync())
        return path;
      return null;
    }
    final direct = File(p.join(path, 'bin', 'java'));
    if (direct.existsSync()) return direct.path;
    if (p.basename(path) == 'java' && File(path).existsSync()) return path;
    return null;
  }

  /// 跑 `java -version` 探测主版本。
  Future<JavaRuntime?> probe(String exe) async {
    try {
      final result = await Process.run(exe, ['-version'], runInShell: false);
      final output = (result.stderr as String).isNotEmpty
          ? result.stderr as String
          : result.stdout as String;
      final major = _parseMajorVersion(output);
      if (major == null) return null;
      return JavaRuntime(executablePath: exe, version: major);
    } catch (_) {
      return null;
    }
  }

  /// "1.8.0_402" → 8，"21.0.3" → 21，含 -version: 输出格式差异。
  static int? _parseMajorVersion(String output) {
    final match = RegExp(r'version "([^"]+)"').firstMatch(output);
    if (match == null) return null;
    final raw = match.group(1)!;
    if (raw.startsWith('1.')) {
      return int.tryParse(raw.split('.')[1]);
    }
    return int.tryParse(raw.split('.')[0]);
  }

  /// 为版本挑一个 Java：要求大版本一致（或可运行的最接近的）。
  Future<JavaRuntime?> pickFor(int requiredMajor, {String? customPath}) async {
    final all = await detectAll(customPath: customPath);
    if (all.isEmpty) return null;
    if (requiredMajor <= 0) return all.first;
    for (final java in all) {
      if (java.version == requiredMajor) return java;
    }
    // 找 ≥ 要求的最小版本（高版本跑老版本一般没问题；8 以下例外）
    final higher = all.where((j) => j.version >= requiredMajor).toList()
      ..sort((a, b) => a.version.compareTo(b.version));
    return higher.isEmpty ? all.last : higher.first;
  }

  /// Adoptium API 下载 Temurin JRE 到 `<runtime>/temurin-<major>`。
  ///
  /// 返回其中的 java 可执行文件。
  Future<JavaRuntime> downloadJre(
    int major, {
    Downloader? downloader,
    void Function(String line)? onLog,
    void Function(double fraction, String name)? onProgress,
  }) async {
    void log(String line) => onLog?.call(line);
    final dl =
        downloader ?? Downloader(mirror: Mirror.official, concurrency: 4);
    final arch = Platform.version.contains('arm64') ? 'aarch64' : 'x64';
    final os = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
        ? 'mac'
        : 'linux';
    final apiUrl =
        'https://api.adoptium.net/v3/assets/latest/$major/hotspot?os=$os&architecture=$arch&image_type=jre&vendor=eclipse';
    log('查询 Adoptium：JRE $major（$os/$arch）');
    final assets = await dl.getJson(apiUrl) as List<dynamic>;
    if (assets.isEmpty) throw Exception('Adoptium 没有可用的 JRE $major');
    final binary =
        (assets.first as Map<String, dynamic>)['binary']
            as Map<String, dynamic>;
    final package = binary['package'] as Map<String, dynamic>;
    final link = package['link'] as String;
    final size = (package['size'] as num?)?.toInt();
    final isZip =
        (package['name'] as String?)?.toLowerCase().endsWith('.zip') ??
        Platform.isWindows;
    log('下载 ${package['name']}（${size ?? '?'} 字节）');

    final destDir = p.join(gameDir.runtime, 'temurin-$major-$arch');
    final archiveFile = File(p.join(gameDir.runtime, p.basename(link)));
    await dl.fetchFile(
      DownloadItem(url: link, dest: archiveFile.path, size: size),
    );

    log('解压运行时…');
    if (onProgress != null) onProgress(0.9, '解压');
    final bytes = archiveFile.readAsBytesSync();
    final destDirectory = Directory(destDir);
    if (!destDirectory.existsSync()) destDirectory.createSync(recursive: true);
    if (isZip) {
      final archive = ar.ZipDecoder().decodeBytes(bytes);
      // Temurin 的 zip 里包一层 jdk-xx.x.x+jre/，解到 destDir 后自动落位
      for (final entry in archive) {
        if (!entry.isFile) continue;
        if (entry.name.contains('..')) continue;
        final outPath = p.join(destDir, entry.name);
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(entry.content as List<int>);
      }
    } else {
      // linux/mac 的 .tar.gz
      final tar = ar.GZipDecoder().decodeBytes(bytes);
      final archive = ar.TarDecoder().decodeBytes(tar);
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final outPath = p.join(destDir, entry.name);
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(entry.content as List<int>);
        if (!Platform.isWindows) {
          final mode = entry.mode;
          if (mode & 0x111 != 0) {
            await Process.run('chmod', ['+x', outPath]);
          }
        }
      }
    }
    archiveFile.deleteSync();

    final exe = _findJavaExe(destDir);
    if (exe == null) throw Exception('解压后找不到 java 可执行文件（$destDir）');
    final runtime = await probe(exe);
    if (runtime == null) throw Exception('解压后的 java 无法运行（$exe）');
    log('✅ $runtime');
    return runtime;
  }

  /// 从 Mojang 官方 java-runtime 清单安装对应大版本的运行时（HMCL 同源）。
  ///
  /// 优先使用版本 JSON 的 `javaVersion.component`；没有时按 major 选最接近的
  /// 组件。文件落到 `<gameDir>/runtime/mojang-<component>/`，逐文件 SHA-1
  /// 校验；安装失败会清掉半成品目录，由调用方决定是否回退 Adoptium。
  Future<JavaRuntime> downloadMojangRuntime({
    required int major,
    String component = '',
    Downloader? downloader,
    void Function(String line)? onLog,
    void Function(double fraction, String label)? onProgress,
    bool Function()? isCancelled,
  }) async {
    void log(String line) => onLog?.call(line);
    void check() {
      if (isCancelled?.call() == true) throw Exception('已取消');
    }

    final dl =
        downloader ?? Downloader(mirror: Mirror.official, concurrency: 8);
    const allUrl =
        'https://piston-meta.mojang.com/v1/products/java-runtime/'
        '2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json';

    check();
    log('查询 Mojang Java 运行时清单…');
    final all = await _getJsonDirect(dl, allUrl);
    final platformKey = Platform.isWindows
        ? (Platform.version.contains('arm64') ? 'windows-arm64' : 'windows-x64')
        : Platform.isMacOS
        ? (Platform.version.contains('arm64') ? 'mac-os-arm64' : 'mac-os')
        : 'linux';
    var platform = all[platformKey] as Map<String, dynamic>?;
    if (platform == null && Platform.isWindows) {
      platform = all['windows-x64'] as Map<String, dynamic>?;
    }
    if (platform == null) throw Exception('Mojang 清单没有 $platformKey 运行时');

    String? picked;
    Map<String, dynamic>? entry;
    if (component.isNotEmpty && platform[component] is List) {
      final list = platform[component] as List;
      if (list.isNotEmpty && list.first is Map<String, dynamic>) {
        picked = component;
        entry = list.first as Map<String, dynamic>;
      }
    }
    if (entry == null) {
      var bestMajor = 1 << 30;
      for (final key in platform.keys) {
        if (key == 'minecraft-java-exe') continue;
        final list = platform[key];
        if (list is! List || list.isEmpty) continue;
        final first = list.first;
        if (first is! Map<String, dynamic>) continue;
        final version = first['version'];
        final name = version is Map<String, dynamic>
            ? (version['name'] as String? ?? '')
            : '';
        final verMajor = int.tryParse(
          RegExp(r'^(\d+)').firstMatch(name)?.group(1) ?? '',
        );
        if (verMajor == null || verMajor < major) continue;
        if (verMajor < bestMajor) {
          bestMajor = verMajor;
          picked = key;
          entry = first;
        }
      }
    }
    if (entry == null || picked == null) {
      throw Exception('Mojang 没有适合 Java $major 的运行时');
    }
    final manifestInfo = entry['manifest'] as Map<String, dynamic>?;
    final manifestUrl = manifestInfo?['url'] as String?;
    if (manifestUrl == null || manifestUrl.isEmpty) {
      throw Exception('Java 运行时缺少 manifest URL');
    }
    log('选中运行时 $picked（Java $major）');

    check();
    final manifest = await _getJsonDirect(dl, manifestUrl);
    final files = manifest['files'] as Map<String, dynamic>?;
    if (files == null) throw Exception('Java 运行时清单格式异常');

    final target = p.join(gameDir.runtime, 'mojang-$picked');
    final existing = _findJavaExe(target);
    if (existing != null) {
      final probed = await probe(existing);
      if (probed != null) {
        log('✅ 已有运行时 $probed');
        return probed;
      }
    }
    final temp = p.join(
      gameDir.runtime,
      '.install-$picked-${DateTime.now().microsecondsSinceEpoch}',
    );
    final tempDir = Directory(temp);
    tempDir.createSync(recursive: true);
    final items = <DownloadItem>[];
    for (final entry in files.entries) {
      final meta = entry.value;
      if (meta is! Map<String, dynamic>) continue;
      if ((meta['type'] as String?) != 'file') continue;
      final rel = entry.key.replaceAll('\\', '/');
      if (rel.contains('..')) continue;
      final downloads = meta['downloads'] as Map<String, dynamic>?;
      final raw = downloads?['raw'] as Map<String, dynamic>?;
      if (raw == null) continue; // 只有 lzma 的条目极少，交给 Adoptium 兜底
      final url = raw['url'] as String?;
      if (url == null || url.isEmpty) continue;
      items.add(
        DownloadItem(
          url: url,
          dest: p.join(temp, rel),
          sha1: raw['sha1'] as String?,
          size: (raw['size'] as num?)?.toInt(),
          name: rel,
        ),
      );
    }
    if (items.isEmpty) throw Exception('Java 运行时没有可下载文件');
    log('下载 Java $major（$picked，${items.length} 个文件）');
    await dl.runBatch(
      items,
      onProgress: (pr) {
        onProgress?.call(
          pr.fraction == 0
              ? pr.doneFiles / (pr.totalFiles == 0 ? 1 : pr.totalFiles)
              : pr.fraction,
          pr.currentName,
        );
      },
    );
    check();
    final exeInTemp = _findJavaExe(temp);
    if (exeInTemp == null) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
      throw Exception('Java 运行时缺少 bin/java');
    }
    if (Directory(target).existsSync()) {
      Directory(target).deleteSync(recursive: true);
    }
    Directory(temp).renameSync(target);
    final exe = _findJavaExe(target);
    if (exe == null) throw Exception('Java 运行时安装不完整');
    final runtime = await probe(exe);
    if (runtime == null) throw Exception('安装后的 Java 无法运行（$exe）');
    log('✅ $runtime');
    return runtime;
  }

  /// 直连官方 URL 取 JSON（不走下载镜像：java-runtime 清单在 BMCLAPI
  /// 不一定有同路径，避免 auto 模式把请求打到 404）。
  Future<Map<String, dynamic>> _getJsonDirect(Downloader dl, String url) async {
    final request = await dl.httpClient.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw Exception('HTTP ${response.statusCode}: $url');
    }
    final text = await response.transform(utf8.decoder).join();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// 该 Java 是否满足版本要求。
  static bool isCompatible(JavaRuntime java, int requiredMajor) {
    if (requiredMajor <= 0) return true;
    if (requiredMajor <= 8) return java.version >= requiredMajor;
    return java.version >= requiredMajor;
  }
}

/// 输出转 JSON（小工具，Adoptium 返回的是数组）。
List<Map<String, dynamic>> parseJsonArray(String text) {
  final decoded = jsonDecode(text);
  if (decoded is List) return decoded.cast<Map<String, dynamic>>();
  throw const FormatException('unexpected json');
}

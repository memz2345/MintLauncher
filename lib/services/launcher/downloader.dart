import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../download_task.dart';

/// 下载源选择。参考 HMCL 的 DownloadProvider：
///   · BMCLAPI：Mojang 各域名的国内镜像（清单/客户端/资源全走镜像）
///   · 官方：原样用 Mojang 的 URL
enum Mirror { auto, bmcl, official }

/// Mojang → BMCLAPI 的域名映射（HMCL BMCLAPIDownloadProvider 同款）。
const Map<String, String> _bmclHostMap = {
  'launchermeta.mojang.com': 'bmclapi2.bangbang93.com',
  'piston-meta.mojang.com': 'bmclapi2.bangbang93.com',
  'piston-data.mojang.com': 'bmclapi2.bangbang93.com',
  'launcher.mojang.com': 'bmclapi2.bangbang93.com',
  // maven 布局的库（libraries.minecraft.net）→ 镜像的 /maven 前缀
  'libraries.minecraft.net': 'bmclapi2.bangbang93.com/maven',
  // 资源文件 → 镜像的 /assets 前缀
  'resources.download.minecraft.net': 'bmclapi2.bangbang93.com/assets',
  // Forge 清单 / promotions / 安装器（files.* 与 maven.* 同一仓库）
  'files.minecraftforge.net': 'bmclapi2.bangbang93.com/maven',
  'maven.minecraftforge.net': 'bmclapi2.bangbang93.com/maven',
  // NeoForge maven。官方带 /releases 仓库前缀，镜像摊平在 /maven 下，
  // 映射时把前缀摘掉（见 [_stripPathPrefixes]）。
  'maven.neoforged.net': 'bmclapi2.bangbang93.com/maven',
};

/// 镜像时要从路径里摘掉的仓库前缀（host → 前缀）。
const Map<String, String> _stripPathPrefixes = {
  'maven.neoforged.net': '/releases',
};

/// 把官方 URL 翻译成镜像 URL；非官方域名原样返回。
String mirrorUrl(String url, Mirror mirror) {
  if (mirror == Mirror.official) return url;
  final uri = Uri.parse(url);
  final replacement = _bmclHostMap[uri.host];
  if (replacement == null) return url;
  var path = uri.path;
  final strip = _stripPathPrefixes[uri.host];
  if (strip != null && path.startsWith(strip)) {
    path = path.substring(strip.length);
  }
  final segments = replacement.split('/');
  final newHost = segments.first;
  final extraPath = segments.length > 1 ? '/${segments.skip(1).join('/')}' : '';
  return uri
      .replace(host: newHost, scheme: 'https', path: '$extraPath$path')
      .toString();
}

/// 单个下载任务：URL → 本地路径，可选 SHA1 校验与大小提示。
class DownloadItem {
  DownloadItem({
    required this.url,
    required this.dest,
    this.sha1,
    this.size,
    this.name,
  });

  final String url;
  final String dest;
  final String? sha1;
  final int? size;

  /// 展示名（进度条 label 用），不给就取文件名。
  final String? name;

  String get displayName => name ?? p.basename(dest);
}

/// 并发下载器的进度快照。
class DownloadProgress {
  const DownloadProgress({
    required this.totalFiles,
    required this.doneFiles,
    required this.totalBytes,
    required this.doneBytes,
    this.currentName = '',
  });

  final int totalFiles;
  final int doneFiles;
  final int totalBytes;
  final int doneBytes;
  final String currentName;

  double get fraction => totalBytes > 0
      ? (doneBytes / totalBytes).clamp(0.0, 1.0)
      : (totalFiles > 0 ? doneFiles / totalFiles : 0);

  bool get finished => totalFiles > 0 && doneFiles >= totalFiles;

  @override
  String toString() =>
      '$doneFiles/$totalFiles · ${_fmtBytes(doneBytes)}/${_fmtBytes(totalBytes)}';
}

/// 一批下载的结果。
///
/// `runBatch` 不会因单个文件失败而抛（64 并发挂一个就中断整批太脆），所以
/// 结果得带出来给调用方判断：安装是否真的完整、要不要标成失败。
class BatchResult {
  const BatchResult({
    this.total = 0,
    this.downloaded = 0,
    this.failed = const [],
  });

  final int total;
  final int downloaded;
  final List<DownloadFailure> failed;

  bool get clean => failed.isEmpty;
  bool get hasWork => total > 0;

  String get failureSummary => failed.isEmpty
      ? ''
      : '${failed.length} 个文件失败：'
            '${failed.take(4).map((f) => f.name).join('、')}'
            '${failed.length > 4 ? ' …' : ''}';
}

class DownloadFailure {
  const DownloadFailure(this.name, this.error);

  final String name;
  final Object error;

  @override
  String toString() => '$name：$error';
}

String _fmtBytes(int n) {
  if (n < 1024) return '${n}B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
  if (n < 1024 * 1024 * 1024)
    return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
}

class DownloadException implements Exception {
  DownloadException(this.message);
  final String message;

  @override
  String toString() => message;
}

class _SourceStat {
  int attempts = 0;
  int failures = 0;
}

/// 并发下载器：固定并发数 + 每文件重试 + SHA1 校验 + 进度回调。
///
/// 用 dart:io HttpClient（不走 package:http），大文件流式落盘、
/// 校验 hash 时才整块读一次。
class Downloader {
  Downloader({
    this.mirror = Mirror.auto,
    this.concurrency = 64,
    this.retries = 3,
    this.timeout = const Duration(seconds: 30),
    this.userAgent = 'MintLauncher/0.1.0',
    this.proxyHost = '',
    this.proxyPort = 0,
    this.task,
  });

  final Mirror mirror;
  final int concurrency;
  final int retries;
  final Duration timeout;
  final String userAgent;

  /// HTTP 代理（host:port）；host 为空 = 直连。
  final String proxyHost;
  final int proxyPort;

  /// 下载管理页的进度出口（null = 不记账，例如清单探测这类小请求）。
  final DownloadTask? task;

  HttpClient? _client;

  /// 供 Modrinth 等走同一代理/UA 配置的调用方使用。
  HttpClient get httpClient => _httpClient;

  HttpClient get _httpClient => _client ??= HttpClient()
    ..userAgent = userAgent
    ..connectionTimeout = timeout
    // 池子和并发对齐：小文件批次全靠连接复用摊薄握手成本。
    ..maxConnectionsPerHost = concurrency
    ..idleTimeout = const Duration(seconds: 60)
    // Happy Eyeballs 的 IPv4 优先版（PCL2/.NET 同效果）：Dart 的
    // HttpClient 按 getaddrinfo 顺序拨号，有 AAAA 时先走 IPv6——
    // 国内不少 CDN 的 v6 边缘会被掐 TLS（Connection terminated during
    // handshake），表现为小文件慢。这里自己解析并 IPv4 在前。
    ..connectionFactory = _connectIpv4First
    ..findProxy = (proxyHost.isEmpty || proxyPort <= 0)
        ? (uri) => 'DIRECT'
        : (uri) => 'PROXY $proxyHost:$proxyPort';

  static Future<ConnectionTask<Socket>> _connectIpv4First(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    // 走代理时返回裸 socket，隧道和 TLS 仍由 HttpClient 自己做。
    if (proxyHost != null) {
      return Socket.startConnect(proxyHost, proxyPort ?? uri.port);
    }
    final addrs = await InternetAddress.lookup(uri.host);
    final ordered = [
      ...addrs.where((a) => a.type == InternetAddressType.IPv4),
      ...addrs.where((a) => a.type == InternetAddressType.IPv6),
    ];
    if (ordered.isEmpty) {
      throw SocketException('没有可用的地址：${uri.host}');
    }
    // startConnect 只收单个地址（传 List 会类型错误）；按序试着连，
    // 前一个握不上再换下一个。https 直连时 TLS 也是本工厂的责任。
    Object? lastError;
    for (final addr in ordered) {
      final task = await (uri.scheme == 'https'
          ? SecureSocket.startConnect(addr, uri.port)
          : Socket.startConnect(addr, uri.port));
      try {
        await task.socket;
        return task;
      } catch (e) {
        lastError = e;
      }
    }
    throw SocketException('连接失败 ${uri.host}：$lastError');
  }

  /// 取消标记：置 true 后所有未完成任务尽快放弃。
  bool cancelled = false;

  void _checkCancel() {
    if (cancelled) throw DownloadException('已取消');
  }

  // ── 下载源熔断（PCL2 SourceFail 的简化版）──
  //
  // 小文件批次最怕「坏源重试」：某个镜像的边缘节点握手一直被打断时，
  // 若每个文件都先在它上面耗 3 次再回退官方，几百个文件会把时间全花在
  // 失败握手上。这里按「主机 + 第一段路径」统计失败率：窗口内尝试
  // ≥8 次且连接层失败率 ≥60% 就短路 45 秒，后续文件直接走下一个源；
  // 成功只做衰减，不会把已经烂掉的源立刻洗白。
  static const int _sourceMinAttempts = 8;
  static const double _sourceFailureRatio = 0.6;
  static const Duration _sourceCooldown = Duration(seconds: 45);
  final Map<String, _SourceStat> _sourceStats = {};
  final Map<String, DateTime> _sourceCooldownUntil = {};

  static String _sourceKey(String url) {
    final uri = Uri.parse(url);
    // 资源文件的路径第一段是 hash 前缀（每两个字符就变），按它分组会让
    // 官方资源源的失败统计碎成上千份；这里把已知 CDN 按固定源分组。
    if (uri.host == 'resources.download.minecraft.net') {
      return '${uri.host}/assets';
    }
    if (uri.host == 'libraries.minecraft.net') {
      return '${uri.host}/maven';
    }
    final first = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    return '${uri.host}/$first';
  }

  _SourceStat _statOf(String url) =>
      _sourceStats.putIfAbsent(_sourceKey(url), _SourceStat.new);

  bool _sourceHealthy(String url) {
    final until = _sourceCooldownUntil[_sourceKey(url)];
    return until == null || DateTime.now().isAfter(until);
  }

  void _markSourceAttempt(String url) => _statOf(url).attempts++;

  void _markSourceFailure(String url) {
    final key = _sourceKey(url);
    final stat = _statOf(url);
    stat.failures++;
    if (stat.attempts >= _sourceMinAttempts &&
        stat.failures / stat.attempts >= _sourceFailureRatio) {
      _sourceCooldownUntil[key] = DateTime.now().add(_sourceCooldown);
      _sourceStats.remove(key);
    }
  }

  void _markSourceSuccess(String url) {
    final stat = _sourceStats[_sourceKey(url)];
    if (stat == null) return;
    // 衰减而不是清零：偶发成功救不回一个 80% 失败的源。
    if (stat.attempts > 0) stat.attempts--;
    if (stat.failures > 0) stat.failures--;
  }

  /// 健康源排前面，被熔断的源只作最后兜底；全被熔断时清空重来，
  /// 避免一批任务因为之前 45 秒的坏运气直接全灭。
  List<String> _orderCandidates(List<String> candidates) {
    final healthy = [
      for (final c in candidates)
        if (_sourceHealthy(c)) c,
    ];
    if (healthy.isEmpty) {
      _sourceStats.clear();
      _sourceCooldownUntil.clear();
      return candidates;
    }
    return [
      ...healthy,
      for (final c in candidates)
        if (!_sourceHealthy(c)) c,
    ];
  }

  Future<HttpClientResponse> _get(
    String url, {
    String? accept,
    List<int>? range,
  }) async {
    final request = await _httpClient.getUrl(Uri.parse(url));
    if (accept != null) request.headers.set(HttpHeaders.acceptHeader, accept);
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=${range.first}-');
    }
    final response = await request.close().timeout(timeout);
    return response;
  }

  /// 下载文本（自动镜像回退：auto 时先镜像后官方）。
  ///
  /// 与 [fetchFile] 一样带重试：清单 / 元数据这类小请求在镜像抖动时
  /// 常见一次性失败（forge 的 CDN 尤其），每个候选源重试两次。
  Future<String> getString(String url) async {
    final candidates = _orderCandidates(_urlCandidates(url));
    Object? lastError;
    for (final candidate in candidates) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          _checkCancel();
          _markSourceAttempt(candidate);
          final response = await _get(candidate, accept: 'application/json');
          if (response.statusCode != 200) {
            await response.drain<void>();
            throw DownloadException('HTTP ${response.statusCode}: $candidate');
          }
          final text = await response.transform(utf8.decoder).join();
          _markSourceSuccess(candidate);
          return text;
        } catch (e) {
          lastError = e;
          if (cancelled) break;
          if (_isConnectionError(e)) {
            // 坏源立即换下一个，别在同一个握不上手的源上反复试。
            _markSourceFailure(candidate);
            break;
          }
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
        }
      }
    }
    throw DownloadException('下载失败 $url：$lastError');
  }

  Future<Map<String, dynamic>> getJson(String url) async =>
      jsonDecode(await getString(url)) as Map<String, dynamic>;

  /// JSON 数组版（BMCLAPI 的 OptiFine 清单等）。
  Future<List<dynamic>> getJsonList(String url) async =>
      jsonDecode(await getString(url)) as List<dynamic>;

  /// auto 模式下「镜像优先、官方兜底」的候选列表。
  List<String> _urlCandidates(String url) {
    switch (mirror) {
      case Mirror.official:
        return [url];
      case Mirror.bmcl:
        return [mirrorUrl(url, Mirror.bmcl)];
      case Mirror.auto:
        final mirrored = mirrorUrl(url, Mirror.bmcl);
        return mirrored == url ? [url] : [mirrored, url];
    }
  }

  /// 校验（或补齐校验和）后的下载：存在且 hash 对就跳过。
  ///
  /// 返回 true = 实际下载了，false = 本地已就绪。
  Future<bool> fetchFile(DownloadItem item) async {
    _checkCancel();
    final file = File(item.dest);
    final dir = Directory(p.dirname(item.dest));
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // 已有文件且 hash 匹配：跳过。hash 未知时按大小判断 —— 半截文件（下载
    // 中断 / 被系统杀进程）大小对不上，必须重下，否则「显示已下载」但游戏
    // 读的是坏文件。
    if (file.existsSync()) {
      if (item.sha1 == null) {
        final size = item.size;
        if (size == null || file.lengthSync() == size) return false;
        file.deleteSync();
      } else {
        final existing = _sha1Of(file);
        if (existing == item.sha1) return false;
        file.deleteSync();
      }
    }

    final candidates = _orderCandidates(_urlCandidates(item.url));
    Object? lastError;
    for (final candidate in candidates) {
      for (var attempt = 0; attempt < retries; attempt++) {
        // 每次尝试用独立分片文件：上一个尝试的残留句柄/半截文件
        // 不会卡住下一个尝试（Windows 上同名句柄未关会导致 errno 32 级联）。
        final part = File(
          '${item.dest}.part${candidates.indexOf(candidate)}x$attempt',
        );
        // 已计入的字节数：这次尝试失败要退回去，否则 doneBytes 会超过
        // totalBytes，进度被 clamp 在 100%（镜像抖动 + 熔断切源时虚得最快）。
        final countedBefore = task?.doneBytes ?? 0;
        try {
          _checkCancel();
          _markSourceAttempt(candidate);
          await _downloadOne(candidate, part, file, item);
          if (item.sha1 != null) {
            final hash = _sha1Of(file);
            if (hash != item.sha1) {
              file.deleteSync();
              throw DownloadException('SHA1 校验失败：$candidate（$hash）');
            }
          }
          _markSourceSuccess(candidate);
          return true;
        } catch (e) {
          lastError = e;
          task?.undoBytes((task?.doneBytes ?? 0) - countedBefore);
          if (cancelled) rethrow;
          // 连接层失败（握手被掐 / 断流 / 解析失败）：坏源立即换下一个
          // 候选；对同一个源重试只会把「每个小文件都先撞坏源」的成本
          // 乘上尝试次数。服务器拒绝类才稍等，避免打死镜像。
          if (_isConnectionError(e)) {
            _markSourceFailure(candidate);
            break;
          }
          await Future<void>.delayed(
            Duration(milliseconds: 300 * (attempt + 1)),
          );
        }
      }
    }
    throw DownloadException('下载失败 ${item.displayName}：$lastError');
  }

  Future<void> _downloadOne(
    String url,
    File tmp,
    File file,
    DownloadItem item,
  ) async {
    final response = await _get(url);
    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.drain<void>();
      throw DownloadException('HTTP ${response.statusCode}: $url');
    }
    final sink = tmp.openWrite();
    try {
      // 每个数据块一个 stall 超时：服务器断流时能及时失败重试，
      // 否则一批 worker 会被一条挂死的连接拖住整批。
      await for (final chunk in response.timeout(
        timeout,
        onTimeout: (eventSink) {
          eventSink.addError(TimeoutException('下载停滞超过 $timeout'));
        },
      )) {
        _checkCancel();
        sink.add(chunk);
        task?.addBytes(chunk.length);
      }
      // 小文件不逐个 fsync（PCL2 同款）：close 已把缓冲交给操作系统，
      // 强制 flush 会让磁盘在并发下串行化。
      await sink.close();
      // Windows 上目标存在时 rename 会报错，先删再改名
      if (file.existsSync()) file.deleteSync();
      tmp.renameSync(file.path);
    } catch (e) {
      // 先把句柄关干净再清理临时文件，顺序反了在 Windows 上会 errno 32
      try {
        await sink.close().timeout(const Duration(seconds: 10));
      } catch (_) {}
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      rethrow;
    }
  }

  /// 连接层失败：重试不值得等待（握手被掐 / socket 断 / DNS / 超时）。
  static bool _isConnectionError(Object e) =>
      e is SocketException ||
      e is HandshakeException ||
      e is TimeoutException ||
      (e is HttpException && e.message.contains('Connection'));

  String _sha1Of(File file) {
    var digest = crypto.sha1;
    final bytes = file.readAsBytesSync();
    return digest.convert(bytes).toString();
  }

  /// 并发跑一批任务，进度经 [onProgress] 汇报（每完成一个文件回调一次）。
  /// 并发跑一批任务，进度经 [onProgress] 汇报（每完成一个文件回调一次）。
  ///
  /// 返回这一批的实际结果：调用方（VersionInstaller / 启动前补齐）据此决定
  /// 是报「完成」还是报「N 个文件失败」—— 失败以前只进日志，UI 照样打勾。
  Future<BatchResult> runBatch(
    List<DownloadItem> rawItems, {
    void Function(DownloadProgress)? onProgress,
    void Function(String file, Object error)? onFileError,
  }) async {
    // 同 dest 的任务只留一个：两个 worker 写同一个 .download 会互相打架
    final seenDests = <String>{};
    final items = [
      for (final item in rawItems)
        if (seenDests.add(item.dest.toLowerCase())) item,
    ];
    if (items.isEmpty) return const BatchResult();
    var doneFiles = 0;
    var doneBytes = 0;
    var downloadedFiles = 0;
    var index = 0;
    final failed = <DownloadFailure>[];
    final totalBytes = items.fold<int>(0, (sum, i) => sum + (i.size ?? 0));
    // 进度铺底：**累加**到这条任务已有的总量上（一次安装要跑 5~10 批，
    // 每批覆盖分母就会显示成「100% 了怎么又开始了」）。
    task?.addPlan(files: items.length, bytes: totalBytes);

    Future<void> worker() async {
      while (true) {
        final my = index;
        index++;
        if (my >= items.length || cancelled) return;
        final item = items[my];
        final size = item.size ?? 0;
        task?.startFile(item.displayName, size: size);
        // 文件已就绪时 fetchFile 不实际下载：不计入 doneBytes（进度别虚高）
        try {
          final downloaded = await fetchFile(item);
          doneFiles++;
          if (downloaded) {
            doneBytes += size;
            downloadedFiles++;
          }
          task?.fileDone(item.displayName);
          onProgress?.call(
            DownloadProgress(
              totalFiles: items.length,
              doneFiles: doneFiles,
              totalBytes: totalBytes,
              doneBytes: doneBytes,
              currentName: item.displayName,
            ),
          );
        } catch (e) {
          if (cancelled) return;
          failed.add(DownloadFailure(item.displayName, e));
          onFileError?.call(item.displayName, e);
          doneFiles++;
          // 失败与成功在计数上等价（不然整批卡住），但单独记一笔失败数。
          task?.fileFailed(item.displayName);
          onProgress?.call(
            DownloadProgress(
              totalFiles: items.length,
              doneFiles: doneFiles,
              totalBytes: totalBytes,
              doneBytes: doneBytes,
              currentName: item.displayName,
            ),
          );
        }
      }
    }

    final workers = List.generate(
      concurrency.clamp(1, items.length),
      (_) => worker(),
      growable: false,
    );
    await Future.wait(workers);
    return BatchResult(
      total: items.length,
      downloaded: downloadedFiles,
      failed: failed,
    );
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }
}

/// 单文件大小探测（HEAD）——清单里没有 size 时给进度条用。
Future<int?> probeContentLength(String url, Mirror mirror) async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.headUrl(Uri.parse(mirrorUrl(url, mirror)));
      final response = await request.close();
      await response.drain<void>();
      final length = response.contentLength;
      return length > 0 ? length : null;
    } finally {
      client.close(force: true);
    }
  } catch (_) {
    return null;
  }
}

/// 小工具：把 [Uint8List] 的 SHA1 算出来（16 进制小写）。
String sha1Hex(List<int> bytes) => crypto.sha1.convert(bytes).toString();

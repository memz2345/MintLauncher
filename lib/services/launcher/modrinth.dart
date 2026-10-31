import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:path/path.dart' as p;

import 'downloader.dart';
import 'game_dir.dart';

/// 版本 id → Minecraft 版本（Modrinth 的 game_versions 过滤用）。
///
/// 优先读版本 json 的 inheritsFrom（权威来源：fabric/quilt/forge/neoforge
/// 的注入 json 都带）。json 缺失时按各加载器的 id 形状用正则兜底——
/// 不能无脑取第一个数字段：`fabric-loader-0.16.14-1.21.1` 里
/// `0.16.14` 是 loader 版本，会被抢先匹配。
String? resolveMcVersion(GameDir gameDir, String versionId) {
  try {
    final f = File(gameDir.versionJson(versionId));
    if (f.existsSync()) {
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final inherits = json['inheritsFrom'] as String?;
      if (inherits != null && inherits.isNotEmpty) return inherits;
      // 原版 json 自身就是 MC 版本。
      if (RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(versionId)) return versionId;
    }
  } catch (_) {}
  return _mcVersionFromId(versionId);
}

String? _mcVersionFromId(String versionId) {
  final id = versionId.toLowerCase();
  // NeoForge：neoforge-21.1.95 → MC 1.21.1（前两位是 21.1）。
  final neo = RegExp(r'^neoforge-(\d+)\.(\d+)').firstMatch(id);
  if (neo != null) {
    final minor = neo.group(2)!;
    return minor == '0' ? '1.${neo.group(1)}' : '1.${neo.group(1)}.$minor';
  }
  // Fabric / Quilt：loader-<loader版本>-<游戏版本>，游戏版本在末尾。
  if (id.contains('fabric-loader') || id.contains('quilt-loader')) {
    final tail = RegExp(r'(\d+\.\d+(?:\.\d+)?)$').firstMatch(id);
    return tail?.group(1);
  }
  // 原版 / OptiFine / Forge：1.21.1、1.20.1-forge-47.2.0（游戏版本在开头）。
  final head = RegExp(r'^(\d+\.\d+(?:\.\d+)?)').firstMatch(id);
  return head?.group(1);
}

/// Modrinth 资源类型。
enum ModrinthProjectType {
  mod('mod', '模组'),
  modpack('modpack', '整合包'),
  resourcepack('resourcepack', '资源包'),
  shader('shader', '光影'),
  datapack('datapack', '数据包');

  const ModrinthProjectType(this.id, this.label);
  final String id;
  final String label;

  /// 普通文件类资源的安装目标子目录（相对游戏主目录）。
  /// 整合包不走这里（它安装成独立版本）。
  String get targetDirName => switch (this) {
    ModrinthProjectType.mod => 'mods',
    ModrinthProjectType.resourcepack => 'resourcepacks',
    ModrinthProjectType.shader => 'shaderpacks',
    ModrinthProjectType.datapack => 'datapacks',
    ModrinthProjectType.modpack => 'modpacks',
  };
}

/// Modrinth 分类 slug → 中文标签（覆盖常见项，未收录原样显示）。
const Map<String, String> kModrinthCategoryLabels = {
  'adventure': '冒险',
  'technology': '科技',
  'magic': '魔法',
  'utility': '实用',
  'optimization': '优化',
  'decoration': '装饰',
  'worldgen': '世界生成',
  'food': '食物',
  'equipment': '装备',
  'storage': '存储',
  'transportation': '交通',
  'mobs': '生物',
  'player': '玩家',
  'misc': '杂项',
  'library': '前置库',
  'game-mechanics': '游戏机制',
  'social': '联机',
  'education': '教育',
  'map-based': '地图',
  'mini-game': '小游戏',
  'quests': '任务',
  'multiplayer': '多人',
  'vanilla-like': '原版风',
  'challenging': '硬核',
  'combat': '战斗',
  'speedrun': '速通',
  'first-person': '第一人称',
  'realistic': '写实',
  'cartoon': '卡通',
  'fantasy': '奇幻',
  'semi-realistic': '半写实',
  'vintage': '复古',
  'potato': '低配',
  'performance': '性能',
  'fabric': 'Fabric',
  'forge': 'Forge',
  'neoforge': 'NeoForge',
  'quilt': 'Quilt',
  'datapack': '数据包',
};

String modrinthCategoryLabel(String slug) =>
    kModrinthCategoryLabels[slug] ?? slug;

/// 搜索结果条目（/v2/search 的 hit）。
/// 一页 Modrinth 搜索结果（offset 已经由调用方指定）。
class ModrinthSearchPage {
  const ModrinthSearchPage({
    required this.hits,
    required this.totalHits,
    required this.offset,
    required this.limit,
  });

  final List<ModrinthHit> hits;
  final int totalHits;
  final int offset;
  final int limit;
}

class ModrinthHit {
  ModrinthHit({required this.json});

  final Map<String, dynamic> json;

  String get id => (json['project_id'] as String?) ?? '';
  String get slug => (json['slug'] as String?) ?? '';
  String get title => (json['title'] as String?) ?? slug;
  String get description => (json['description'] as String?) ?? '';
  String get iconUrl => (json['icon_url'] as String?) ?? '';
  String get author => (json['author'] as String?) ?? '';
  int get downloads => (json['downloads'] as num?)?.toInt() ?? 0;
  int get follows => (json['follows'] as num?)?.toInt() ?? 0;
  String get dateModified => (json['date_modified'] as String?) ?? '';
  List<String> get versions => [
    if (json['versions'] is List)
      for (final v in json['versions'] as List)
        if (v is String) v,
  ];

  /// 原始分类（含 loader 名）。
  List<String> get categories => [
    if (json['categories'] is List)
      for (final c in json['categories'] as List)
        if (c is String) c,
  ];

  /// 展示用分类（Modrinth 已剔除 loader），空则退回原始分类。
  List<String> get displayCategories {
    final list = [
      if (json['display_categories'] is List)
        for (final c in json['display_categories'] as List)
          if (c is String) c,
    ];
    return list.isEmpty ? categories : list;
  }

  String get displayDownloads {
    final n = downloads;
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

/// 某个项目的具体版本文件。
class ModrinthVersionFile {
  ModrinthVersionFile({required this.json});

  final Map<String, dynamic> json;

  String get name => (json['name'] as String?) ?? '';
  String get versionNumber => (json['version_number'] as String?) ?? '';
  String get versionType => (json['version_type'] as String?) ?? 'release';
  List<String> get loaders => [
    if (json['loaders'] is List)
      for (final l in json['loaders'] as List)
        if (l is String) l,
  ];
  List<String> get gameVersions => [
    if (json['game_versions'] is List)
      for (final v in json['game_versions'] as List)
        if (v is String) v,
  ];
  String get datePublished => (json['date_published'] as String?) ?? '';

  /// 主文件（primary）下载信息。
  ({String url, String filename, int size, String? sha1})? get primaryFile {
    final files = json['files'];
    if (files is! List || files.isEmpty) return null;
    Map<String, dynamic>? chosen;
    for (final f in files) {
      if (f is Map<String, dynamic> && f['primary'] == true) {
        chosen = f;
        break;
      }
    }
    chosen ??= (files.first as Map<String, dynamic>);
    final hashes = chosen['hashes'];
    return (
      url: (chosen['url'] as String?) ?? '',
      filename: (chosen['filename'] as String?) ?? '',
      size: (chosen['size'] as num?)?.toInt() ?? 0,
      sha1: hashes is Map<String, dynamic> ? hashes['sha1'] as String? : null,
    );
  }
}

/// .mrpack 的 modrinth.index.json 单条文件。
class ModrinthModpackFile {
  ModrinthModpackFile({required this.json});

  final Map<String, dynamic> json;

  /// 相对整合包实例根目录的路径（如 `mods/sodium.jar`、`config/x.toml`）。
  String get path => (json['path'] as String?) ?? '';
  int get fileSize => (json['fileSize'] as num?)?.toInt() ?? 0;
  List<String> get downloads => [
    if (json['downloads'] is List)
      for (final d in json['downloads'] as List)
        if (d is String) d,
  ];
  String? get sha1 {
    final hashes = json['hashes'];
    return hashes is Map<String, dynamic> ? hashes['sha1'] as String? : null;
  }

  /// 客户端要求：required / optional / unsupported。unsupported 不下载。
  String get clientEnv {
    final env = json['env'];
    return env is Map<String, dynamic> ? (env['client'] as String?) ?? '' : '';
  }

  bool get requiredForClient => clientEnv != 'unsupported';
}

/// .mrpack 的 modrinth.index.json 解析结果。
class ModrinthModpackIndex {
  ModrinthModpackIndex(this.json);

  final Map<String, dynamic> json;

  String get formatVersion => '${json['formatVersion'] ?? 1}';
  String get gameVersion =>
      (json['dependencies'] is Map<String, dynamic>
              ? (json['dependencies'] as Map<String, dynamic>)['minecraft']
              : null)
          as String? ??
      '';
  String get name => (json['name'] as String?) ?? '';

  /// loader 依赖键 → 版本（fabric-loader / quilt-loader / forge / neoforge）。
  Map<String, String> get dependencies => {
    if (json['dependencies'] is Map<String, dynamic>)
      for (final e in (json['dependencies'] as Map<String, dynamic>).entries)
        if (e.key != 'minecraft' && e.value is String) e.key: e.value as String,
  };

  List<ModrinthModpackFile> get files => [
    if (json['files'] is List)
      for (final f in json['files'] as List)
        if (f is Map<String, dynamic>) ModrinthModpackFile(json: f),
  ];
}

/// 搜索排序（Modrinth index 参数）。
enum ModrinthSearchIndex {
  relevance('relevance', '相关度'),
  downloads('downloads', '下载量'),
  follows('follows', '关注'),
  newest('newest', '最新'),
  updated('updated', '更新');

  const ModrinthSearchIndex(this.id, this.label);
  final String id;
  final String label;
}

/// Modrinth 客户端：搜索 / 拉版本列表 / 下载安装。
/// Modrinth API 无需密钥；带 UA（官方礼貌性要求）。
class ModrinthService {
  ModrinthService({required this.downloader, required this.gameHomeDir});

  final Downloader downloader;

  /// 安装目标的游戏主目录（共享根或隔离后的 `versions/<id>`）。
  final String gameHomeDir;

  static const _base = 'https://api.modrinth.com/v2';

  /// 搜索资源。
  ///
  /// [gameVersion]/[loaders]/[categories] 非空时作为过滤 facet；
  /// [query] 为空时配合 [index] 就是「热门列表」（downloads = 下载最多）。
  Future<List<ModrinthHit>> search(
    String query,
    ModrinthProjectType type, {
    String? gameVersion,
    List<String>? loaders,
    List<String>? categories,
    ModrinthSearchIndex index = ModrinthSearchIndex.relevance,
    int limit = 20,
    int offset = 0,
  }) async {
    final page = await searchPage(
      query,
      type,
      gameVersion: gameVersion,
      loaders: loaders,
      categories: categories,
      index: index,
      limit: limit,
      offset: offset,
    );
    return page.hits;
  }

  /// 分页搜索：除了当前页 hits，还带 API 的 `total_hits`（翻页器要用）。
  Future<ModrinthSearchPage> searchPage(
    String query,
    ModrinthProjectType type, {
    String? gameVersion,
    List<String>? loaders,
    List<String>? categories,
    ModrinthSearchIndex index = ModrinthSearchIndex.relevance,
    int limit = 20,
    int offset = 0,
  }) async {
    final facets = <List<String>>[
      ['project_type:${type.id}'],
    ];
    if (gameVersion != null && gameVersion.isNotEmpty) {
      facets.add(['game_versions:$gameVersion']);
    }
    if (loaders != null && loaders.isNotEmpty) {
      facets.add([for (final l in loaders) 'categories:$l']);
    }
    if (categories != null && categories.isNotEmpty) {
      // 单选 tag：一组内是 OR，这里只有一个 → 精确过滤该分类。
      facets.add([for (final c in categories) 'categories:$c']);
    }
    final uri = Uri.parse('$_base/search').replace(
      queryParameters: {
        'limit': '$limit',
        'offset': '$offset',
        'index': index.id,
        'query': query,
        'facets': jsonEncode(facets),
      },
    );
    final json = await _getJson(uri.toString()) as Map<String, dynamic>;
    final hits = [
      if (json['hits'] is List)
        for (final h in json['hits'] as List)
          if (h is Map<String, dynamic>) ModrinthHit(json: h),
    ];
    return ModrinthSearchPage(
      hits: hits,
      totalHits: (json['total_hits'] as num?)?.toInt() ?? hits.length,
      offset: offset,
      limit: limit,
    );
  }

  /// 某项目的可用版本（按发布时间倒序，API 默认）。id 或 slug 均可。
  Future<List<ModrinthVersionFile>> versionsOf(
    String projectIdOrSlug, {
    String? gameVersion,
    List<String>? loaders,
  }) async {
    final params = <String, String>{};
    if (gameVersion != null && gameVersion.isNotEmpty) {
      params['game_versions'] = jsonEncode([gameVersion]);
    }
    if (loaders != null && loaders.isNotEmpty) {
      params['loaders'] = jsonEncode(loaders);
    }
    final uri = Uri.parse(
      '$_base/project/$projectIdOrSlug/version',
    ).replace(queryParameters: params.isEmpty ? null : params);
    final list = await _getJson(uri.toString()) as List<dynamic>;
    return [
      for (final v in list)
        if (v is Map<String, dynamic>) ModrinthVersionFile(json: v),
    ];
  }

  /// 下载安装一个版本文件。
  ///
  /// [destDir] 非空时覆盖默认的 `<gameHomeDir>/<type.targetDirName>`；
  /// 社区资源下载前由用户手动选文件夹（默认给这个路径）。
  Future<String> install(
    ModrinthVersionFile version, {
    required ModrinthProjectType type,
    String? destDir,
    void Function(String line)? onLog,
  }) async {
    void log(String line) => onLog?.call(line);
    final file = version.primaryFile;
    if (file == null || file.url.isEmpty) {
      throw Exception('该版本没有可下载的文件');
    }
    final dirPath = destDir ?? p.join(gameHomeDir, type.targetDirName);
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final dest = File(p.join(dir.path, file.filename));
    if (dest.existsSync()) {
      log('${file.filename} 已存在，跳过');
      return dest.path;
    }
    log(
      '下载 ${file.filename}'
      '（${file.size > 0 ? '${(file.size / 1024 / 1024).toStringAsFixed(1)}MB' : '?'}）…',
    );
    await downloader.fetchFile(
      DownloadItem(
        url: file.url,
        dest: dest.path,
        sha1: file.sha1,
        size: file.size,
      ),
    );
    log('✅ 已安装到 ${dest.path}');
    return dest.path;
  }

  /// 下载 .mrpack 到 [destDir]（不解压不安装，返回本地路径）。
  Future<String> downloadModpack(
    ModrinthVersionFile version, {
    required String destDir,
    void Function(String line)? onLog,
  }) => install(
    version,
    type: ModrinthProjectType.modpack,
    destDir: destDir,
    onLog: onLog,
  );

  /// 解析已下载的 .mrpack → modrinth.index.json。
  ModrinthModpackIndex parseModpack(String mrpackPath) {
    final bytes = File(mrpackPath).readAsBytesSync();
    final archive = ar.ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      final name = file.name.replaceAll('\\', '/').replaceFirst('./', '');
      if (name == 'modrinth.index.json') {
        final content = utf8.decode(file.content as List<int>);
        return ModrinthModpackIndex(
          jsonDecode(content) as Map<String, dynamic>,
        );
      }
    }
    throw Exception('不是有效的 Modrinth 整合包（找不到 modrinth.index.json）');
  }

  /// 解压 .mrpack 的 overrides/ + client-overrides/ 到 [instanceDir]。
  ///
  /// 先铺 overrides，再铺 client-overrides（后者覆盖前者，和 Modrinth 规范
  /// 一致）。返回覆盖的文件数。
  int extractModpackOverrides(String mrpackPath, String instanceDir) {
    final bytes = File(mrpackPath).readAsBytesSync();
    final archive = ar.ZipDecoder().decodeBytes(bytes);
    var count = 0;
    for (final prefix in ['overrides/', 'client-overrides/']) {
      for (final file in archive) {
        var name = file.name.replaceAll('\\', '/');
        while (name.startsWith('./')) {
          name = name.substring(2);
        }
        if (!name.startsWith(prefix)) continue;
        if (!file.isFile) continue;
        final rel = p.posix.normalize(name.substring(prefix.length));
        if (rel.isEmpty || rel == '..' || rel.startsWith('../')) continue;
        final dest = File(p.joinAll([instanceDir, ...rel.split('/')]));
        dest.parent.createSync(recursive: true);
        dest.writeAsBytesSync(file.content as List<int>, flush: true);
        count++;
      }
    }
    return count;
  }

  /// 下载整合包 index 声明的资源文件到 [instanceDir]。
  /// 跳过 client 环境标记为 unsupported 的文件；返回待下载文件数。
  Future<int> downloadModpackFiles(
    ModrinthModpackIndex index,
    String instanceDir, {
    void Function(String line)? onLog,
    void Function(double fraction, String label)? onProgress,
  }) async {
    final todo = [
      for (final f in index.files)
        if (f.requiredForClient && f.downloads.isNotEmpty) f,
    ];
    final items = <DownloadItem>[];
    for (final f in todo) {
      final rel = p.posix.normalize(f.path);
      if (rel.isEmpty || rel == '..' || rel.startsWith('../')) continue;
      final dest = p.joinAll([instanceDir, ...rel.split('/')]);
      if (File(dest).existsSync()) continue;
      items.add(
        DownloadItem(
          url: f.downloads.first,
          dest: dest,
          sha1: f.sha1,
          size: f.fileSize,
          name: f.path,
        ),
      );
    }
    if (items.isNotEmpty) {
      onLog?.call('整合包需要下载 ${items.length} 个文件');
      await downloader.runBatch(
        items,
        onProgress: (pr) => onProgress?.call(
          pr.fraction == 0
              ? pr.doneFiles / (pr.totalFiles == 0 ? 1 : pr.totalFiles)
              : pr.fraction,
          pr.currentName,
        ),
        onFileError: (file, e) => onLog?.call('⚠️ 整合包文件失败 $file：$e'),
      );
    }
    return items.length;
  }

  Future<dynamic> _getJson(String url) async {
    final request = await downloader.httpClient.getUrl(Uri.parse(url));
    request.headers.set(
      'User-Agent',
      'MintLauncher/0.1.0 (Minecraft launcher)',
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw Exception('Modrinth API HTTP ${response.statusCode}: $url');
    }
    return jsonDecode(await response.transform(utf8.decoder).join());
  }
}

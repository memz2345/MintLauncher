/// Minecraft 版本 JSON 的模型与 rules 求值（HMCL `Version` / `Rule` 同构）。
library;

import 'dart:io';

/// 一条库规则：os / features 条件 + allow/disallow 动作。
class LibraryRule {
  const LibraryRule({
    required this.action,
    this.osName,
    this.osArch,
    this.features,
  });

  factory LibraryRule.fromJson(Map<String, dynamic> json) => LibraryRule(
    action: (json['action'] as String?) ?? 'allow',
    osName: (json['os'] as Map<String, dynamic>?)?['name'] as String?,
    osArch: (json['os'] as Map<String, dynamic>?)?['arch'] as String?,
    features: (json['features'] as Map<String, dynamic>?)?.cast<String, bool>(),
  );

  final String action;
  final String? osName;
  final String? osArch;
  final Map<String, bool>? features;

  /// 是否适用当前环境 + 特性集。
  bool applies(Map<String, bool> features) {
    if (osName != null && osName != currentOsName) return false;
    if (osArch != null && osArch != currentOsArch) return false;
    final f = this.features;
    if (f != null && f.isNotEmpty) {
      for (final entry in f.entries) {
        if (features[entry.key] != entry.value) return false;
      }
    }
    return true;
  }

  static String get currentOsName {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'osx';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }

  /// Mojang 清单里的 arch 写法。注意规则里 "x86" 特指 **32 位**（
  /// 各库用它 `disallow` 掉 32 位环境），64 位机器绝不能返回 "x86"，
  /// 否则 LWJGL 主 jar 会被整个踢出 classpath（实测就是这么炸的）。
  static String get currentOsArch {
    final v = Platform.version;
    if (v.contains('arm64') || v.contains('aarch64')) return 'arm64';
    if (v.contains('x64') || v.contains('x86_64') || v.contains('amd64')) {
      return 'x86_64';
    }
    return 'x86';
  }
}

/// 求值一组规则（HMCL `Rule.evaluate`）：无规则 = 允许；
/// 有规则 = **最后一条**适用规则的 action 决定。
bool evaluateRules(List<LibraryRule> rules, Map<String, bool> features) {
  if (rules.isEmpty) return true;
  var allow = false;
  for (final rule in rules) {
    if (rule.applies(features)) {
      allow = rule.action == 'allow';
    }
  }
  return allow;
}

class LibraryDownload {
  const LibraryDownload({
    required this.path,
    required this.url,
    this.sha1,
    this.size,
  });

  factory LibraryDownload.fromJson(Map<String, dynamic> json) =>
      LibraryDownload(
        path: (json['path'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        sha1: json['sha1'] as String?,
        size: (json['size'] as num?)?.toInt(),
      );

  final String path;
  final String url;
  final String? sha1;
  final int? size;
}

class Library {
  Library._({
    required this.name,
    required this.rules,
    required this.artifact,
    required this.nativesClassifier,
    required this.nativesDownload,
    this.allowedOverride = true,
  });

  factory Library.fromJson(Map<String, dynamic> json) {
    final downloads = json['downloads'] as Map<String, dynamic>?;
    final artifactJson = downloads?['artifact'] as Map<String, dynamic>?;
    final nativesMap = json['natives'] as Map<String, dynamic>?;
    final classifiers = downloads?['classifiers'] as Map<String, dynamic>?;

    final osKey = LibraryRule.currentOsName;
    final classifierName = nativesMap?[osKey] as String?;
    LibraryDownload? nativesDownload;
    if (classifierName != null && classifiers is Map<String, dynamic>) {
      final entry = classifiers[classifierName] as Map<String, dynamic>?;
      if (entry != null) nativesDownload = LibraryDownload.fromJson(entry);
    }

    // 旧版格式（< 1.13 的 Mojang json、Forge/Fabric 注入的库）：没有
    // downloads 节点，只有 maven 坐标 name + 仓库基址 url。
    LibraryDownload? artifact;
    if (artifactJson != null) {
      artifact = LibraryDownload.fromJson(artifactJson);
    } else if ((json['url'] as String?) != null) {
      artifact = _legacyArtifact(json);
    }

    return Library._(
      name: (json['name'] as String?) ?? '',
      rules: [
        for (final r in (json['rules'] as List? ?? const []))
          LibraryRule.fromJson(r as Map<String, dynamic>),
      ],
      artifact: artifact,
      nativesClassifier: classifierName,
      nativesDownload: nativesDownload,
      // 旧 Forge json 用 clientreq 标记纯服务端库（客户端装了也没用）。
      allowedOverride: (json['clientreq'] as bool?) ?? true,
    );
  }

  /// 旧版库条目 → 下载描述：url = 仓库基址 + maven 路径。
  static LibraryDownload _legacyArtifact(Map<String, dynamic> json) {
    final base = (json['url'] as String?) ?? '';
    final name = (json['name'] as String?) ?? '';
    final path = _mavenPathOf(name);
    String? sha1;
    final direct = json['sha1'] as String?;
    if (direct != null && direct.isNotEmpty) {
      sha1 = direct;
    } else if (json['checksums'] is List) {
      final list = (json['checksums'] as List).whereType<String>().toList();
      if (list.isNotEmpty) sha1 = list.last;
    }
    return LibraryDownload(
      path: path,
      url: base.isEmpty ? '' : '$base$path',
      sha1: sha1,
    );
  }

  static String _mavenPathOf(String name) {
    final parts = name.split(':');
    if (parts.length < 3) return name;
    final group = parts[0].replaceAll('.', '/');
    final artifact = parts[1];
    final version = parts[2];
    final classifier = parts.length > 3 ? '-${parts[3]}' : '';
    return '$group/$artifact/$version/$artifact-$version$classifier.jar';
  }

  final String name;

  /// maven 坐标兜底路径（downloads 缺 path 时用）。
  String get mavenPath {
    final parts = name.split(':');
    if (parts.length < 3) return name;
    final group = parts[0].replaceAll('.', '/');
    final artifact = parts[1];
    final version = parts[2];
    final classifier = parts.length > 3 ? '-${parts[3]}' : '';
    return '$group/$artifact/$version/$artifact-$version$classifier.jar';
  }

  final List<LibraryRule> rules;
  final LibraryDownload? artifact;
  final String? nativesClassifier;
  final LibraryDownload? nativesDownload;

  /// 旧 Forge json 的 clientreq 标记：false = 纯服务端库，客户端跳过。
  final bool allowedOverride;

  bool get allowed => evaluateRules(rules, const {}) && allowedOverride;

  /// 要不要为当前平台解出 native 库（允许 + 声明了本平台 classifier）。
  bool get needsNative =>
      allowed && nativesClassifier != null && nativesDownload != null;
}

/// 版本号比较（Minecraft 版本 id 与 LWJGL 版本都用「点分数字 + 可选后缀」）。
class McVersion {
  McVersion._();

  /// `1.20.4`、`1.8-pre1`、`3.3.3` 这类点分版本号；后缀（-snapshot-2、-rc1）
  /// 不参与比较，同一基线视为相等。
  static List<int> parts(String version) =>
      (RegExp(r'^\d+(?:\.\d+)*').firstMatch(version)?.group(0) ?? '0')
          .split('.')
          .map((s) => int.tryParse(s) ?? 0)
          .toList();

  static int compareTo(String a, String b) {
    final x = parts(a), y = parts(b);
    final n = x.length > y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      final c = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
      if (c != 0) return c;
    }
    return 0;
  }

  static bool atLeast(String version, String baseline) =>
      compareTo(version, baseline) >= 0;

  /// 按 Minecraft 版本号推需要的 Java 大版本（JSON 没写 javaVersion 时用）。
  static int inferJavaMajor(String gameVersion) {
    if (gameVersion.isEmpty) return 8;
    if (atLeast(gameVersion, '1.20.5')) return 21;
    if (atLeast(gameVersion, '1.17')) return 17;
    return 8;
  }
}

class AssetObject {
  const AssetObject({required this.hash, required this.size});

  factory AssetObject.fromJson(Map<String, dynamic> json) => AssetObject(
    hash: (json['hash'] as String?) ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
  );

  final String hash;
  final int size;
}

/// 完整版本描述：本体 + （可选）inheritsFrom 父版本合并后的结果。
///
/// 合并策略（HMCL `Version` 的 resolve）：id/mainClass/type 等字段子覆盖父；
/// 库列表父子合并、按 maven 坐标前两段（组:artifact）去重、子版本优先；
/// 参数（arguments）**子覆盖父**（原版不继承 arguments，Forge 一类只会写自己
/// 需要的增量，HMCL 对 arguments 的合并也是「子有就用子的」）。
class GameVersion {
  GameVersion._({required this.id, required this.json, required this.parent});

  final String id;
  final Map<String, dynamic> json;
  final GameVersion? parent;

  /// 解析并递归合并 inheritsFrom。[loadJson] 按版本 id 读 json 文本。
  static Future<GameVersion> resolve(
    String id,
    Map<String, dynamic> json,
    Future<Map<String, dynamic>?> Function(String versionId) loadJson,
  ) async {
    final inherits = json['inheritsFrom'] as String?;
    if (inherits == null) {
      return GameVersion._(id: id, json: json, parent: null);
    }
    final parentJson = await loadJson(inherits);
    if (parentJson == null) {
      throw Exception('缺少父版本 $inherits（inheritsFrom）');
    }
    final parent = await resolve(inherits, parentJson, loadJson);
    return GameVersion._(id: id, json: json, parent: parent);
  }

  String get mainClass =>
      (json['mainClass'] as String?) ?? parent?.mainClass ?? '';

  /// 链上是否出现过 Forge/NeoForge 1.17+ 的 BootstrapLauncher 主类
  /// （PCL2 `ModLoaders.Forge/NeoForge && Major >= 17` 的等价判定）。
  ///
  /// 这类版本的游戏本体是 libraries 里的补丁 client jar（BootstrapLauncher
  /// 自己找），**继承链上的原版 jar 不能再进 classpath** —— 否则
  /// `_1._20._1`（原版 jar 的自动模块名）与 `minecraft` 模块撞包：
  /// `ResolutionException: Modules _1._20._1 and minecraft export package …`。
  bool get usesForgeBootstrap =>
      (json['mainClass'] as String?) ==
          'cpw.mods.bootstraplauncher.BootstrapLauncher' ||
      (parent?.usesForgeBootstrap ?? false);

  String get type => (json['type'] as String?) ?? parent?.type ?? 'release';

  String get assetsIndexId =>
      (json['assets'] as String?) ?? parent?.assetsIndexId ?? 'legacy';

  /// 客户端 jar 的版本 id：`jar` 字段优先，否则本体 id。
  String get jarId => (json['jar'] as String?) ?? parent?.jarId ?? id;

  /// 参数列表（HMCL 的合并策略：**父在前、子在后拼接**）。
  ///
  /// Forge/Fabric 注入的子版本只携带自己的增量（Fabric 的 arguments.game
  /// 甚至为空），逐项替换会丢掉原版的 --username 等参数 —— 必须拼。
  List<dynamic> _argumentList(String key) {
    final args = json['arguments'];
    final own = args is Map<String, dynamic> ? args[key] : null;
    final parentList = parent?._argumentList(key) ?? const [];
    if (own is List) return [...parentList, ...own];
    return parentList;
  }

  /// JVM 参数（1.13+ 的 arguments.jvm），老版本为空（启动器自建）。
  List<dynamic> get jvmArguments => _argumentList('jvm');

  /// 游戏参数（1.13+ 的 arguments.game）。
  List<dynamic> get gameArguments => _argumentList('game');

  /// 老版本的 minecraftArguments 字符串（< 1.13）。
  String get minecraftArguments =>
      (json['minecraftArguments'] as String?) ??
      parent?.minecraftArguments ??
      '';

  /// 版本要求的 Java 大版本（-1 = 未知）。
  int get javaMajor {
    final javaVersion = json['javaVersion'];
    if (javaVersion is Map<String, dynamic>) {
      final major = javaVersion['majorVersion'];
      if (major is num) return major.toInt();
    }
    return parent?.javaMajor ?? -1;
  }

  /// 启动这个版本实际需要的 Java 大版本。
  ///
  /// 老版本 JSON 里没有 `javaVersion` 节点（1.17 之前 Mojang 不发这个字段），
  /// 只能按 Minecraft 版本号推 —— Android 侧必须自己选 JRE，选小了直接
  /// `UnsupportedClassVersionError`，选大了 AWT/GL4ES 那套又对不上。
  /// 远古版（a/b 前缀 + old_alpha/old_beta）单独归到 Java 8。
  int get requiredJavaMajor {
    final declared = javaMajor;
    if (declared > 0) return declared;
    if (type == 'old_alpha' || type == 'old_beta' || type == 'infdev') {
      return 8;
    }
    final match = RegExp(r'(\d+)\.(\d+)').firstMatch(jarId);
    if (match == null) return 8;
    return McVersion.inferJavaMajor('${match.group(1)}.${match.group(2)}');
  }

  /// 是否用 1.13+ 的结构化参数（`arguments.jvm` / `arguments.game`）。
  bool get usesModernArguments => jvmArguments.isNotEmpty;

  /// 版本声明的 LWJGL 版本（FCL `setLwjglVersion` 的输入）。
  ///
  /// Mojang 的新老声明可能并存（lwjgl3ify 一类整合包会同时留 LWJGL2 与 3.x），
  /// 取**最高**的那个；2.x 走 lwjglx 兼容层，>= 3.4.1 走运行时里的 3.4.1，
  /// 其余（3.0 ~ 3.4.0 与未知）统一用 3.3.3。
  String get lwjglVersion {
    String? best;
    for (final lib in libraries) {
      final name = lib.name;
      if (!name.startsWith('org.lwjgl:lwjgl:') &&
          !name.startsWith('org.lwjgl.lwjgl:lwjgl:')) {
        continue;
      }
      final version = name.split(':')[2];
      if (best == null || McVersion.compareTo(version, best) > 0)
        best = version;
    }
    if (best == null) return '3.3.3';
    if (McVersion.compareTo(best, '3.0') < 0) return 'lwjglx';
    if (McVersion.compareTo(best, '3.4.1') >= 0) return '3.4.1';
    return '3.3.3';
  }

  /// Mojang 运行时组件名（`java-runtime-gamma` 等；空 = 未知）。
  ///
  /// 自动安装 Java 时优先用它，避免 21 和 25 之间选错组件。
  String get javaComponent {
    final javaVersion = json['javaVersion'];
    if (javaVersion is Map<String, dynamic>) {
      final component = javaVersion['component'];
      if (component is String && component.isNotEmpty) return component;
    }
    return parent?.javaComponent ?? '';
  }

  /// 合并后的库列表：父在前、子在后，同名（完整 maven 坐标，含 classifier）
  /// 去重取子版本。⚠️ 不能只按 group:artifact 去重 —— Mojang 把
  /// `org.lwjgl:lwjgl:3.3.2` 与它的 `:natives-windows` / `:natives-windows-x86`
  /// 等变体声明成**平级的独立条目**（各带自己的 rules），按组名去重会把主 jar
  /// 挤掉只留最后一个变体（实测 LWJGL 就这么 NoClassDefFoundError 的）。
  List<Library> get libraries {
    final merged = <String, Library>{};
    for (final lib in parent?.libraries ?? const <Library>[]) {
      merged[_libKey(lib.name)] = lib;
    }
    for (final lib in _rawLibraries(json)) {
      merged[_libKey(lib.name)] = lib;
    }
    return merged.values.toList();
  }

  static String _libKey(String name) => name;

  static List<Library> _rawLibraries(Map<String, dynamic> json) => [
    for (final lib in (json['libraries'] as List? ?? const []))
      Library.fromJson(lib as Map<String, dynamic>),
  ];

  /// 资源索引描述（assetIndex 节点，父版本兜底）。
  ({String id, String url, String? sha1})? get assetIndexInfo {
    final info =
        (json['assetIndex'] ?? parent?.json['assetIndex'])
            as Map<String, dynamic>?;
    if (info == null) return null;
    return (
      id: (info['id'] as String?) ?? assetsIndexId,
      url: (info['url'] as String?) ?? '',
      sha1: info['sha1'] as String?,
    );
  }

  /// 客户端下载描述（downloads.client，父版本兜底）。
  LibraryDownload? get clientDownload {
    final downloads = json['downloads'] as Map<String, dynamic>?;
    final client = downloads?['client'] as Map<String, dynamic>?;
    if (client is Map<String, dynamic>) return LibraryDownload.fromJson(client);
    return parent?.clientDownload;
  }

  /// logging 配置（-Dlog4j.configurationFile），可选。
  ({String file, String url})? get loggingFile {
    final logging =
        (json['logging'] ?? parent?.json['logging']) as Map<String, dynamic>?;
    final client = logging?['client'] as Map<String, dynamic>?;
    final fileMap = client?['file'] as Map<String, dynamic>?;
    if (fileMap == null) return null;
    return (
      file: (fileMap['id'] as String?) ?? '',
      url: (fileMap['url'] as String?) ?? '',
    );
  }
}

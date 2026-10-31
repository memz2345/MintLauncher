import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:path/path.dart' as p;

import 'modloader.dart';

/// 识别到的整合包格式。
enum ModpackKind {
  modrinth('Modrinth (.mrpack)'),
  curseForge('CurseForge'),
  multiMc('MultiMC / Prism'),
  hmcl('HMCL'),
  plain('普通压缩包');

  const ModpackKind(this.label);
  final String label;
}

/// 本地整合包描述（不负责安装，只负责“看懂它”）。
class ModpackDescriptor {
  const ModpackDescriptor({
    required this.path,
    required this.kind,
    required this.fileName,
    required this.name,
    required this.gameVersion,
    this.loader,
    this.loaderVersion = '',
    this.manifest = const {},
    this.index = const {},
    this.rootPrefix = '',
    this.overridesPrefix = '',
    this.fileCount = 0,
    this.archiveBytes = 0,
  });

  final String path;
  final ModpackKind kind;
  final String fileName;
  final String name;
  final String gameVersion;
  final ModLoader? loader;
  final String loaderVersion;

  /// CurseForge manifest / MultiMC mmc-pack / HMCL pack.json 等原始数据。
  final Map<String, dynamic> manifest;
  final Map<String, dynamic> index;
  final String rootPrefix;
  final String overridesPrefix;
  final int fileCount;
  final int archiveBytes;

  bool get isKnown => kind != ModpackKind.plain;

  String get displayLoader {
    if (loader == null) return '原版';
    return '${loader!.label} ${loaderVersion.isEmpty ? '' : loaderVersion}'
        .trim();
  }

  List<Map<String, dynamic>> get curseFiles => [
    if (manifest['files'] is List)
      for (final f in manifest['files'] as List)
        if (f is Map<String, dynamic>) f,
  ];

  List<Map<String, dynamic>> get multiMcComponents => [
    if (manifest['components'] is List)
      for (final c in manifest['components'] as List)
        if (c is Map<String, dynamic>) c,
  ];
}

/// 本地整合包识别 + 解压（Modrinth / CurseForge / MultiMC / HMCL / 普通 zip）。
///
/// 只做纯文件与 JSON 处理，真正“装 MC + 加载器”由 LauncherController 编排。
class ModpackImporter {
  ModpackImporter._();

  static ModpackDescriptor inspect(String zipPath) {
    final file = File(zipPath);
    if (!file.existsSync()) throw Exception('文件不存在：$zipPath');
    if (p.extension(zipPath).toLowerCase() != '.zip' &&
        p.extension(zipPath).toLowerCase() != '.mrpack') {
      throw Exception('只支持 .zip / .mrpack 整合包');
    }
    final bytes = file.readAsBytesSync();
    final archive = ar.ZipDecoder().decodeBytes(bytes);
    final entries = <String, ar.ArchiveFile>{};
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = _normalize(entry.name);
      if (name.isEmpty || name.startsWith('__MACOSX/')) continue;
      entries[name] = entry;
    }
    if (entries.isEmpty) throw Exception('压缩包是空的');

    final fileName = p.basename(zipPath);
    final fallbackName = p.basenameWithoutExtension(zipPath);

    // ── Modrinth ──
    final modrinthEntry = _find(entries, 'modrinth.index.json');
    if (modrinthEntry != null) {
      final index = _json(entries[modrinthEntry]!);
      final deps = index['dependencies'] is Map<String, dynamic>
          ? (index['dependencies'] as Map<String, dynamic>)
          : const <String, dynamic>{};
      final loader = _loaderFromModrinthDeps(deps);
      return ModpackDescriptor(
        path: zipPath,
        kind: ModpackKind.modrinth,
        fileName: fileName,
        name: _str(index['name'], fallbackName),
        gameVersion: _str(deps['minecraft'], ''),
        loader: loader.$1,
        loaderVersion: loader.$2,
        index: index,
        rootPrefix: _rootOf(modrinthEntry),
        overridesPrefix: '${_rootOf(modrinthEntry)}overrides/',
        fileCount: entries.length,
        archiveBytes: bytes.length,
      );
    }

    // ── CurseForge ──
    final curseEntry = _find(entries, 'manifest.json');
    if (curseEntry != null) {
      final manifest = _json(entries[curseEntry]!);
      if (_str(manifest['manifestType'], '') == 'minecraftModpack') {
        final mc = manifest['minecraft'] is Map<String, dynamic>
            ? manifest['minecraft'] as Map<String, dynamic>
            : const <String, dynamic>{};
        final loader = _loaderFromCurse(
          manifest['modLoaders'] is List
              ? manifest['modLoaders'] as List
              : mc['modLoaders'],
        );
        final root = _rootOf(curseEntry);
        final overrides = _str(manifest['overrides'], 'overrides');
        return ModpackDescriptor(
          path: zipPath,
          kind: ModpackKind.curseForge,
          fileName: fileName,
          name: _str(manifest['name'], fallbackName),
          gameVersion: _str(mc['version'], ''),
          loader: loader.$1,
          loaderVersion: loader.$2,
          manifest: manifest,
          rootPrefix: root,
          overridesPrefix:
              '$root${overrides.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '')}/',
          fileCount: entries.length,
          archiveBytes: bytes.length,
        );
      }
    }

    // ── MultiMC / Prism ──
    final mmcEntry = _find(entries, 'mmc-pack.json');
    if (mmcEntry != null) {
      final pack = _json(entries[mmcEntry]!);
      final root = _rootOf(mmcEntry);
      final name = _multiMcName(entries, root) ?? fallbackName;
      var gameVersion = '';
      ModLoader? loader;
      var loaderVersion = '';
      final components = pack['components'] is List
          ? pack['components'] as List
          : const [];
      for (final c in components) {
        if (c is! Map<String, dynamic>) continue;
        final uid = _str(c['uid'], '');
        final version = _str(c['version'], '');
        if (uid == 'net.minecraft') gameVersion = version;
        final mapped = _loaderFromMultiMcUid(uid);
        if (mapped != null) {
          loader = mapped;
          loaderVersion = version;
        }
      }
      return ModpackDescriptor(
        path: zipPath,
        kind: ModpackKind.multiMc,
        fileName: fileName,
        name: name,
        gameVersion: gameVersion,
        loader: loader,
        loaderVersion: loaderVersion,
        manifest: pack,
        rootPrefix: root,
        overridesPrefix: _multiMcOverridesPrefix(entries, root),
        fileCount: entries.length,
        archiveBytes: bytes.length,
      );
    }

    // ── HMCL 旧整合包 ──
    final hmclMeta = _find(entries, 'modpack.json');
    final hmclPack = _find(entries, 'minecraft/pack.json');
    if (hmclMeta != null && hmclPack != null) {
      final meta = _json(entries[hmclMeta]!);
      final pack = _json(entries[hmclPack]!);
      final loader = _loaderFromPackJson(pack);
      return ModpackDescriptor(
        path: zipPath,
        kind: ModpackKind.hmcl,
        fileName: fileName,
        name: _str(meta['name'], fallbackName),
        gameVersion: _str(meta['gameVersion'], ''),
        loader: loader.$1,
        loaderVersion: loader.$2,
        manifest: pack,
        index: meta,
        rootPrefix: _rootOf(hmclMeta),
        overridesPrefix: '${_rootOf(hmclMeta)}minecraft/',
        fileCount: entries.length,
        archiveBytes: bytes.length,
      );
    }

    // ── 普通压缩包：可能是直接把 mods/config 打包 ──
    return ModpackDescriptor(
      path: zipPath,
      kind: ModpackKind.plain,
      fileName: fileName,
      name: fallbackName,
      gameVersion: '',
      fileCount: entries.length,
      archiveBytes: bytes.length,
    );
  }

  /// 解压 [prefixes] 下的文件到 [destDir]；后面的 prefix 覆盖前面的同名文件
  /// （client-overrides 覆盖 overrides，MultiMC `.minecraft` 优先）。
  static int extractPrefixes(
    String zipPath,
    String destDir, {
    required List<String> prefixes,
    Set<String> exclude = const {},
  }) {
    final archive = ar.ZipDecoder().decodeBytes(
      File(zipPath).readAsBytesSync(),
    );
    var count = 0;
    for (final prefix in prefixes) {
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final name = _normalize(entry.name);
        if (!name.startsWith(prefix)) continue;
        final rel = name.substring(prefix.length);
        if (rel.isEmpty || exclude.contains(rel)) continue;
        final normalized = p.posix.normalize(rel);
        if (normalized == '..' ||
            normalized.startsWith('../') ||
            p.posix.isAbsolute(normalized)) {
          continue;
        }
        final dest = File(p.joinAll([destDir, ...normalized.split('/')]));
        dest.parent.createSync(recursive: true);
        dest.writeAsBytesSync(entry.content as List<int>, flush: true);
        count++;
      }
    }
    return count;
  }

  /// 普通压缩包：整包铺到 [destDir]，自动剥掉只有一层的外壳目录。
  static int extractPlain(String zipPath, String destDir) {
    final archive = ar.ZipDecoder().decodeBytes(
      File(zipPath).readAsBytesSync(),
    );
    final names = <String>[
      for (final entry in archive)
        if (entry.isFile) _normalize(entry.name),
    ];
    if (names.isEmpty) return 0;
    final firsts = names
        .map((n) => n.split('/').first)
        .where((s) => s.isNotEmpty)
        .toSet();
    final strip = firsts.length == 1 && names.every((n) => n.contains('/'))
        ? '${firsts.first}/'
        : '';
    var count = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      var name = _normalize(entry.name);
      if (strip.isNotEmpty && name.startsWith(strip)) {
        name = name.substring(strip.length);
      }
      if (name.isEmpty) continue;
      final normalized = p.posix.normalize(name);
      if (normalized == '..' ||
          normalized.startsWith('../') ||
          p.posix.isAbsolute(normalized)) {
        continue;
      }
      if (normalized == 'modpack.json' || normalized == 'minecraft/pack.json') {
        continue;
      }
      final dest = File(p.joinAll([destDir, ...normalized.split('/')]));
      dest.parent.createSync(recursive: true);
      dest.writeAsBytesSync(entry.content as List<int>, flush: true);
      count++;
    }
    return count;
  }

  static String? _multiMcName(
    Map<String, ar.ArchiveFile> entries,
    String root,
  ) {
    final entry = _find(entries, '${root}instance.cfg');
    if (entry == null) return null;
    try {
      final text = utf8.decode(
        entries[entry]!.content as List<int>,
        allowMalformed: true,
      );
      for (final line in text.split('\n')) {
        if (line.startsWith('name=')) {
          final value = line.substring(5).trim();
          if (value.isNotEmpty) return value;
        }
      }
    } catch (_) {}
    return null;
  }

  /// MultiMC 实例目录叫 `.minecraft`（老 MultiMC）或 `minecraft`
  /// （Prism 导出）；按 zip 里实际存在的前缀选，两个都没有时默认前者。
  /// 不能用 containsKey：目录条目不进 [entries]，`.minecraft/` 这个键
  /// 永远不存在，之前因此总是错选 `minecraft/`。
  static String _multiMcOverridesPrefix(
    Map<String, ar.ArchiveFile> entries,
    String root,
  ) {
    final dot = '${root}.minecraft/';
    if (entries.keys.any((k) => k.startsWith(dot))) return dot;
    final plain = '${root}minecraft/';
    if (entries.keys.any((k) => k.startsWith(plain))) return plain;
    return dot;
  }

  static (ModLoader?, String) _loaderFromModrinthDeps(
    Map<String, dynamic> deps,
  ) {
    if (deps['fabric-loader'] is String) {
      return (ModLoader.fabric, deps['fabric-loader'] as String);
    }
    if (deps['quilt-loader'] is String) {
      return (ModLoader.quilt, deps['quilt-loader'] as String);
    }
    if (deps['forge'] is String)
      return (ModLoader.forge, deps['forge'] as String);
    if (deps['neoforge'] is String) {
      return (ModLoader.neoforge, deps['neoforge'] as String);
    }
    return (null, '');
  }

  static (ModLoader?, String) _loaderFromCurse(Object? raw) {
    if (raw is! List) return (null, '');
    String? primary;
    for (final item in raw) {
      if (item is Map<String, dynamic> && item['primary'] == true) {
        primary = item['id'] as String?;
        break;
      }
      if (primary == null && item is Map<String, dynamic>) {
        primary = item['id'] as String?;
      }
    }
    if (primary == null || primary.isEmpty) return (null, '');
    final dash = primary.indexOf('-');
    if (dash <= 0) return (null, '');
    final kind = primary.substring(0, dash).toLowerCase();
    final version = primary.substring(dash + 1);
    final loader = switch (kind) {
      'forge' => ModLoader.forge,
      'neoforge' => ModLoader.neoforge,
      'fabric' || 'fabric-loader' => ModLoader.fabric,
      'quilt' || 'quilt-loader' => ModLoader.quilt,
      _ => null,
    };
    return (loader, version);
  }

  static ModLoader? _loaderFromMultiMcUid(String uid) => switch (uid) {
    'net.minecraftforge' => ModLoader.forge,
    'net.neoforged' => ModLoader.neoforge,
    'net.fabricmc.fabric-loader' => ModLoader.fabric,
    'org.quiltmc.quilt-loader' => ModLoader.quilt,
    _ => null,
  };

  static (ModLoader?, String) _loaderFromPackJson(Map<String, dynamic> pack) {
    final libs = pack['libraries'];
    if (libs is! List) return (null, '');
    for (final lib in libs) {
      if (lib is! Map<String, dynamic>) continue;
      final name = _str(lib['name'], '');
      final parts = name.split(':');
      if (parts.length < 3) continue;
      final group = parts[0];
      final artifact = parts[1];
      final version = parts[2];
      if (group == 'net.fabricmc' && artifact == 'fabric-loader') {
        return (ModLoader.fabric, version);
      }
      if (group == 'org.quiltmc' && artifact == 'quilt-loader') {
        return (ModLoader.quilt, version);
      }
      if (group == 'net.neoforged' && artifact == 'neoforge') {
        return (ModLoader.neoforge, version);
      }
      if (group == 'net.minecraftforge' && artifact == 'forge') {
        final dash = version.indexOf('-');
        return (
          ModLoader.forge,
          dash >= 0 ? version.substring(dash + 1) : version,
        );
      }
    }
    return (null, '');
  }

  static String _normalize(String raw) {
    var name = raw.replaceAll('\\', '/');
    while (name.startsWith('./')) {
      name = name.substring(2);
    }
    name = name.replaceAll(RegExp(r'^/+'), '');
    return name;
  }

  static String? _find(Map<String, ar.ArchiveFile> entries, String suffix) {
    if (entries.containsKey(suffix)) return suffix;
    for (final name in entries.keys) {
      if (name.endsWith('/$suffix')) return name;
    }
    return null;
  }

  static String _rootOf(String? entry) {
    if (entry == null) return '';
    final idx = entry.lastIndexOf('/');
    return idx < 0 ? '' : entry.substring(0, idx + 1);
  }

  static Map<String, dynamic> _json(ar.ArchiveFile entry) {
    final text = utf8.decode(entry.content as List<int>, allowMalformed: true);
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    throw Exception('${entry.name} 不是 JSON 对象');
  }

  static String _str(Object? value, String fallback) =>
      value is String && value.trim().isNotEmpty ? value.trim() : fallback;
}

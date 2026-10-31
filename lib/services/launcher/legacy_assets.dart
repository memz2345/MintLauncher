import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'game_dir.dart';
import 'version_model.dart';

/// 资源索引的落盘布局（HMCL `GameAssetsDir` 对应物）。
///
/// - `map_to_resources`（pre-1.6 / alpha / beta）：资源要铺到游戏主目录的
///   `resources/`，游戏把 `--assetsDir` 指到这里；
/// - `virtual`（1.6–1.12 的 legacy 索引）：铺到 `assets/virtual/<index>`；
/// - 其余现代索引：直接用 `assets/`。
///
/// 以前 Mint 一律用 `assets/virtual/<index>`，远古版既拿不到资源、又会在
/// 初始化资源时直接闪退。
class AssetLayout {
  const AssetLayout({
    required this.indexId,
    required this.dir,
    required this.virtual,
    required this.mapToResources,
  });

  final String indexId;
  final String dir;
  final bool virtual;
  final bool mapToResources;
}

/// 读取资源索引的 `virtual` / `map_to_resources` 标记并算出目标目录。
AssetLayout resolveAssetLayout(
  GameDir gameDir,
  GameVersion version, {
  required String gameHome,
}) {
  final info = version.assetIndexInfo;
  final indexId = info?.id ?? version.assetsIndexId;
  var virtual = false;
  var mapToResources = false;
  final file = File(gameDir.assetIndex(indexId));
  if (file.existsSync()) {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map) {
        virtual = json['virtual'] == true;
        mapToResources = json['map_to_resources'] == true;
      }
    } catch (_) {}
  }
  final dir = mapToResources
      ? p.join(gameHome, 'resources')
      : virtual
      ? p.join(gameDir.assets, 'virtual', indexId)
      : gameDir.assets;
  return AssetLayout(
    indexId: indexId,
    dir: dir,
    virtual: virtual,
    mapToResources: mapToResources,
  );
}

/// 把 legacy 索引里的对象按原虚拟路径铺到 [AssetLayout.dir]。
///
/// 用符号链接（失败退回复制）：pre-1.6 有 749 个文件、约 40MB，按版本复制
/// 太占空间；assets/objects 与目标目录在同一个数据分区，符号链接可用。
/// 返回本次新建的条目数（0 = 已经齐全或不需要铺）。
int materializeLegacyAssets(
  GameDir gameDir,
  AssetLayout layout, {
  void Function(String message)? log,
}) {
  if (!layout.virtual && !layout.mapToResources) return 0;
  final indexFile = File(gameDir.assetIndex(layout.indexId));
  if (!indexFile.existsSync()) {
    log?.call('⚠️ 资源索引缺失：${indexFile.path}');
    return 0;
  }
  Map<String, dynamic> objects;
  try {
    final json = jsonDecode(indexFile.readAsStringSync());
    final raw = (json as Map)['objects'];
    if (raw is! Map) return 0;
    objects = raw.cast<String, dynamic>();
  } catch (e) {
    log?.call('⚠️ 资源索引解析失败：$e');
    return 0;
  }

  var created = 0;
  for (final entry in objects.entries) {
    final name = entry.key;
    if (name.contains('..') || name.startsWith('/')) continue;
    final obj = entry.value;
    if (obj is! Map) continue;
    final hash = obj['hash'] as String?;
    if (hash == null || hash.length < 2) continue;
    final source = File(gameDir.assetObject(hash));
    if (!source.existsSync()) continue;
    final dest = File(p.joinAll([layout.dir, ...name.split('/')]));
    if (dest.existsSync() || Link(dest.path).existsSync()) continue;
    try {
      dest.parent.createSync(recursive: true);
      Link(dest.path).createSync(source.path);
      created++;
    } catch (_) {
      try {
        dest.parent.createSync(recursive: true);
        source.copySync(dest.path);
        created++;
      } catch (_) {}
    }
  }
  if (created > 0) {
    log?.call('已准备远古版资源 $created 项 → ${layout.dir}');
  }
  return created;
}

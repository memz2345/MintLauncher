import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:mint/src/enums.dart' show VersionFacts;

/// 游戏目录布局（.minecraft 结构，HMCL 同名约定）。
class GameDir {
  GameDir(this.root);

  /// 共享根目录（versions / libraries / assets 都在这层）。
  final String root;

  /// Android 侧注入的数据目录查询（`mint/fcl dataDir`）。由 Flutter 入口
  /// （main.dart）注入 —— 放这里是为了让 `dart run` 的 headless 工具
  /// （e2e 冒烟）不拉进 Flutter 依赖。
  static Future<String?> Function()? androidDataDirLookup;

  /// iOS 侧注入的沙盒文档目录查询（path_provider）。iOS 的进程 HOME 不
  /// 保证可写（CI 模拟器进程甚至没有 HOME，相对路径 `./x` 直接 EROFS），
  /// 必须走 getApplicationDocumentsDirectory。同样用注入避免 headless
  /// 工具链拉进 Flutter。
  static Future<String?> Function()? iosDataDirLookup;

  /// 启动器数据根目录（不是 .minecraft）。
  static Future<String> launcherDataDir() async {
    if (Platform.isIOS) {
      final lookup = iosDataDirLookup;
      if (lookup != null) {
        try {
          final dir = await lookup();
          if (dir != null && dir.isNotEmpty) {
            return p.join(dir, 'MintLauncher');
          }
        } catch (_) {}
      }
      // lookup 没注入或失败：落到沙盒 HOME 的 Documents（真机/模拟器
      // 进程一般有 HOME；模拟器 CI 上拿不到就只能暴露给上层兜底）。
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return p.join(home, 'Documents', 'MintLauncher');
      }
    }
    if (Platform.isAndroid) {
      // Android 11+ 不能随便写 /sdcard 根目录；app 专属外部目录不需要
      // 存储权限，卸载时随应用一起清理，也方便 adb 拉日志。
      // 注意：scoped storage 下父目录必须由系统创建，Dart 硬编码路径
      // 直接 mkdir /Android/data/<pkg> 会被拒绝（errno 13）——
      // 先问原生拿 getExternalFilesDir()。main() 里的 controller.init()
      // 可能早于 MethodChannel 注册，短重试几次再回退。
      final lookup = androidDataDirLookup;
      if (lookup != null) {
        for (var attempt = 0; attempt < 6; attempt++) {
          try {
            final dir = await lookup();
            if (dir != null && dir.isNotEmpty) {
              return p.join(dir, 'MintLauncher');
            }
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
      return '/storage/emulated/0/Android/data/dev.mint.mint/files/MintLauncher';
    }
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty)
        return p.join(appData, 'MintLauncher');
    } else if (Platform.isMacOS) {
      return p.join(
        Platform.environment['HOME'] ?? '.',
        'Library',
        'Application Support',
        'MintLauncher',
      );
    }
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    if (Platform.isLinux) {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'MintLauncher');
    }
    return p.join(home, '.mint_launcher');
  }

  /// 默认游戏目录：`<启动器数据>/minecraft`。
  static Future<String> defaultGameDir() async =>
      p.join(await launcherDataDir(), 'minecraft');

  String get versions => p.join(root, 'versions');
  String get libraries => p.join(root, 'libraries');
  String get assets => p.join(root, 'assets');
  String get runtime => p.join(root, 'runtime');

  String versionDir(String id) => p.join(versions, id);
  String versionJson(String id) => p.join(versionDir(id), '$id.json');
  String versionJar(String id) => p.join(versionDir(id), '$id.jar');
  String nativesDir(String id) => p.join(versionDir(id), '$id-natives');

  /// 版本画像（隔离模式求值用，PCL2 `PathIndie` / `Modable` 的对应实现）：
  ///  - [VersionFacts.hasOwnGameData]：版本目录下有 mods（含文件）或
  ///    saves（含子目录）→ PCL2 无条件自动隔离的信号；
  ///  - [VersionFacts.modable]：版本 id 带加载器（可装模组）；
  ///  - [VersionFacts.oldOrSnapshot]：快照 / 预发布 / 远古版
  ///    （版本 json 的 type 与下载页「远古版」分组同口径）。
  VersionFacts factsOf(String versionId) {
    final dir = versionDir(versionId);
    var hasGameData = false;
    final modsDir = Directory(p.join(dir, 'mods'));
    if (modsDir.existsSync()) {
      try {
        hasGameData = modsDir.listSync().any((e) => e is File);
      } catch (_) {}
    }
    if (!hasGameData) {
      final savesDir = Directory(p.join(dir, 'saves'));
      if (savesDir.existsSync()) {
        try {
          hasGameData = savesDir.listSync().any((e) => e is Directory);
        } catch (_) {}
      }
    }

    final lower = versionId.toLowerCase();
    final modable =
        lower.contains('forge') ||
        lower.contains('fabric') ||
        lower.contains('quilt') ||
        lower.contains('neoforge') ||
        lower.contains('optifine') ||
        lower.contains('liteloader') ||
        lower.contains('rift');

    var oldOrSnapshot = false;
    try {
      final json = jsonDecodeAsMap(
        File(versionJson(versionId)).readAsStringSync(),
      );
      final type = '${json['type'] ?? ''}';
      oldOrSnapshot =
          type == 'snapshot' || type == 'old_beta' || type == 'old_alpha';
      if (!oldOrSnapshot) {
        // 兜底：type 缺失或异常时按 MC 版本号判快照 / 预发布。
        final mc = mcVersionOf(versionId);
        oldOrSnapshot =
            RegExp(r'^\d{2}w\d{2}[a-z]?$').hasMatch(mc) ||
            RegExp(r'-pre\d+$|-rc\d+$').hasMatch(mc);
      }
    } catch (_) {}

    return VersionFacts(
      modable: modable,
      oldOrSnapshot: oldOrSnapshot,
      hasOwnGameData: hasGameData,
    );
  }

  String assetIndex(String indexId) =>
      p.join(assets, 'indexes', '$indexId.json');
  String assetObject(String hash) =>
      p.join(assets, 'objects', hash.substring(0, 2), hash);

  /// 版本的游戏主目录（HMCL「版本隔离」）：
  /// 开启隔离时存档/配置/模组/资源包等都放 `versions/<id>/`，
  /// 关闭时直接用共享根。库与资源永远在共享根，两个版本不重复下载。
  String gameHome(String versionId, {required bool isolated}) =>
      isolated ? versionDir(versionId) : root;

  String modsDir(String versionId, {required bool isolated}) =>
      p.join(gameHome(versionId, isolated: isolated), 'mods');

  String get saves => p.join(root, 'saves');
  String worldDir(String versionId, String world, {required bool isolated}) =>
      p.join(gameHome(versionId, isolated: isolated), 'saves', world);

  /// 世界备份目录（始终在共享根）。
  String get backups => p.join(root, 'backups');

  /// 已安装的版本 id 列表（目录下有 `<id>.json` 就算装了）。
  List<String> installedVersions() {
    final dir = Directory(versions);
    if (!dir.existsSync()) return const [];
    final result = <String>[];
    for (final entry in dir.listSync()) {
      if (entry is! Directory) continue;
      final id = p.basename(entry.path);
      if (File(versionJson(id)).existsSync()) result.add(id);
    }
    result.sort((a, b) => b.compareTo(a));
    return result;
  }

  /// 某版本 mods 目录下的模组文件（含 .disabled）。
  List<File> modsOf(String versionId, {required bool isolated}) {
    final dir = Directory(modsDir(versionId, isolated: isolated));
    if (!dir.existsSync()) return const [];
    return [
      for (final e in dir.listSync())
        if (e is File &&
            (e.path.endsWith('.jar') || e.path.endsWith('.disabled')))
          e,
    ]..sort(
      (a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()),
    );
  }

  /// 某版本存档列表（世界名）。
  List<String> worldsOf(String versionId, {required bool isolated}) {
    final dir = Directory(
      p.join(gameHome(versionId, isolated: isolated), 'saves'),
    );
    if (!dir.existsSync()) return const [];
    return [
      for (final e in dir.listSync())
        if (e is Directory && File(p.join(e.path, 'level.dat')).existsSync())
          p.basename(e.path),
    ]..sort();
  }

  /// 版本的 jar 是否已就位。
  bool hasJar(String id) => File(versionJar(id)).existsSync();

  /// 版本元信息缓存（按 versionId；目录切换 / reload 时 GameDir 会重建）。
  final Map<String, ({String loader, String type, String mcVersion})>
  _metaCache = {};

  /// 版本 id → 加载器 / 版本类型 / MC 版本。
  ///
  /// 只看 id 会把整合包自带的目录名（如 `Fabulously Optimized`）都判成原版；
  /// 这里沿 inheritsFrom 读 json 的 mainClass 与 libraries，判定加载器；
  /// type 缺失时沿用父版本（Fabric/Forge 子版本通常不写 type）。
  ({String loader, String type, String mcVersion}) metaOf(String versionId) {
    final cached = _metaCache[versionId];
    if (cached != null) return cached;

    var current = versionId;
    var mcVersion = versionId;
    var type = '';
    final seen = <String>{};
    final hay = StringBuffer(versionId.toLowerCase());
    for (var depth = 0; depth < 8; depth++) {
      if (!seen.add(current)) break;
      final file = File(versionJson(current));
      if (!file.existsSync()) break;
      try {
        final json = jsonDecodeAsMap(file.readAsStringSync());
        if (type.isEmpty) type = '${json['type'] ?? ''}';
        final mainClass = '${json['mainClass'] ?? ''}';
        if (mainClass.isNotEmpty) hay.write(' ${mainClass.toLowerCase()}');
        final libs = json['libraries'];
        if (libs is List) {
          for (final lib in libs) {
            if (lib is Map) {
              final name = lib['name'];
              if (name is String) hay.write(' ${name.toLowerCase()}');
            }
          }
        }
        final inherits = json['inheritsFrom'];
        if (inherits is! String || inherits.isEmpty) break;
        current = inherits;
        mcVersion = inherits;
      } catch (_) {
        break;
      }
    }

    final text = hay.toString();
    final loader =
        text.contains('fabric-loader') ||
            text.contains('net.fabricmc') ||
            text.contains('fabricmc')
        ? 'fabric'
        : text.contains('quilt-loader') || text.contains('org.quiltmc')
        ? 'quilt'
        : text.contains('neoforge') || text.contains('neoforged')
        ? 'neoforge'
        : text.contains('forge')
        ? 'forge'
        : text.contains('optifine')
        ? 'optifine'
        : text.contains('liteloader')
        ? 'liteloader'
        : text.contains('rift')
        ? 'rift'
        : '';

    final meta = (
      loader: loader,
      type: type.isEmpty ? 'release' : type,
      mcVersion: mcVersion,
    );
    _metaCache[versionId] = meta;
    return meta;
  }

  /// 沿 inheritsFrom 链走到根，返回基版本的 MC 版本 id。
  /// `1.20.1-forge-47.2.0` → `1.20.1`，`fabric-loader-0.16-1.21.1` → `1.21.1`。
  /// json 缺失/解析失败时返回原 id。
  String mcVersionOf(String versionId) {
    var current = versionId;
    for (var depth = 0; depth < 8; depth++) {
      final f = File(versionJson(current));
      if (!f.existsSync()) break;
      try {
        final json = jsonDecodeAsMap(f.readAsStringSync());
        final inherits = json['inheritsFrom'] as String?;
        if (inherits == null || inherits.isEmpty) break;
        current = inherits;
      } catch (_) {
        break;
      }
    }
    return current;
  }

  /// 重命名版本（目录 + json 里的 id 字段同步改）。返回新 id。
  String renameVersion(String oldId, String newId) {
    final safe = newId.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safe.isEmpty || safe == oldId) return oldId;
    final oldDir = Directory(versionDir(oldId));
    if (!oldDir.existsSync()) return oldId;
    final newDir = Directory(versionDir(safe));
    if (newDir.existsSync()) throw Exception('版本 $safe 已存在');
    oldDir.renameSync(newDir.path);
    final jsonFile = File(versionJson(safe));
    if (jsonFile.existsSync()) {
      try {
        final json = jsonDecodeAsMap(jsonFile.readAsStringSync());
        json['id'] = safe;
        jsonFile.writeAsStringSync(jsonEncode(json));
      } catch (_) {}
    }
    return safe;
  }

  /// 复制版本（目录整体拷贝，json id 改为新名）。返回新 id。
  String copyVersion(String id, String newId) {
    final safe = newId.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safe.isEmpty) throw Exception('版本名不能为空');
    final src = Directory(versionDir(id));
    if (!src.existsSync()) throw Exception('版本 $id 不存在');
    final dst = Directory(versionDir(safe));
    if (dst.existsSync()) throw Exception('版本 $safe 已存在');
    _copyDirectory(src, dst);
    final jsonFile = File(versionJson(safe));
    if (jsonFile.existsSync()) {
      try {
        final json = jsonDecodeAsMap(jsonFile.readAsStringSync());
        json['id'] = safe;
        jsonFile.writeAsStringSync(jsonEncode(json));
      } catch (_) {}
    }
    return safe;
  }

  static void _copyDirectory(Directory src, Directory dst) {
    dst.createSync(recursive: true);
    for (final e in src.listSync()) {
      final target = p.join(dst.path, p.basename(e.path));
      if (e is Directory) {
        _copyDirectory(e, Directory(target));
      } else if (e is File) {
        e.copySync(target);
      }
    }
  }
}

/// jsonDecode + Map 断言小工具。
Map<String, dynamic> jsonDecodeAsMap(String text) {
  final decoded = jsonDecode(text);
  if (decoded is Map<String, dynamic>) return decoded;
  throw const FormatException('json is not an object');
}

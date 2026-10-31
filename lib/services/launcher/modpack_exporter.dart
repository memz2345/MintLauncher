import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as ar;
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'game_dir.dart';

/// 导出格式。
///
/// PCL2 2.14 的「导出整合包」（`PageInstanceExport`）只导 Modrinth 格式
/// （zip 根放 `modrinth.index.json` + `overrides/`，扩展名 .mrpack），
/// 没有 CurseForge manifest 导出；Mint 保留 CurseForge 格式作为兼容选项。
enum ModpackExportFormat {
  modrinth('Modrinth（.mrpack）'),
  curseForge('CurseForge 兼容（.zip）');

  const ModpackExportFormat(this.label);
  final String label;
}

/// 导出结果。
class ModpackExportResult {
  const ModpackExportResult({
    required this.path,
    required this.fileCount,
    required this.hostedCount,
    required this.sizeBytes,
    this.skippedOptiFine = const [],
    this.notes = const [],
  });

  final String path;

  /// 打包进 overrides 的文件数。
  final int fileCount;

  /// 通过联网匹配确认托管在 Modrinth / CurseForge、改为写入 index 而不打包的文件数。
  final int hostedCount;
  final int sizeBytes;

  /// 因许可证限制未打包的 OptiFine 文件名。
  final List<String> skippedOptiFine;

  /// 需要在完成提示里展示的备注（如联网匹配失败回退）。
  final List<String> notes;
}

/// 一个「导出内容」选项（PCL2 `ExportOption` 同思路：Title / Description /
/// Rules / DefaultChecked / RequireModLoader / RequireOptiFine）。
///
/// Rules 是 `/` 分隔的相对路径规则，支持 `*` `?` `[...]` 通配、以 `!` 开头反选、
/// 以 `/` 结尾表示整个目录；按选项顺序拼接后**靠后的行覆盖靠前的**，
/// 文件只有在「最后一条命中的规则是包含」时才会进包（PCL2 `GetAllRules` 语义）。
class ModpackExportOption {
  const ModpackExportOption({
    required this.key,
    required this.title,
    required this.description,
    required this.rules,
    this.defaultChecked = false,
    this.requireModLoader = false,
    this.requireModLoaderOrOptiFine = false,
    this.subFolders = const [],
    this.subAcceptCompressed = false,
  });

  /// 稳定 id，UI 勾选状态按它记忆。
  final String key;
  final String title;
  final String description;
  final List<String> rules;
  final bool defaultChecked;

  /// 仅可安装模组的版本显示（PCL2 `RequireModLoader`）。
  final bool requireModLoader;

  /// 可安装模组或有 OptiFine 时显示（PCL2 `RequireModLoaderOrOptiFine`）。
  final bool requireModLoaderOrOptiFine;

  /// 需要按目录内容生成子选项的文件夹（saves / resourcepacks / shaderpacks…，
  /// PCL2 `ReloadSubOptions` 同思路）。
  final List<String> subFolders;

  /// 子选项是否包含 *.zip / *.rar 压缩包（资源包 / 光影包是，存档不是）。
  final bool subAcceptCompressed;

  bool get hasSubItems => subFolders.isNotEmpty;
}

/// 一个子选项（某个存档 / 资源包 / 光影包）。
class ModpackExportSubItem {
  const ModpackExportSubItem({required this.title, required this.rule});

  final String title;

  /// 该子项的包含规则（已做通配转义；子项反选时在前面加 `!`）。
  final String rule;
}

/// 把已安装的版本导出为整合包。
///
/// 文件收集不再用固定目录白名单，而是对齐 PCL2 2.14 `PageInstanceExport` 的
/// 规则模型：递归扫游戏主目录，每个文件按选项规则（最后一击生效）决定
/// 收不收；`assets` / `versions` / `libraries` 只在主目录根部跳过（版本隔离时
/// `versions/<id>/` 里的 `<id>.jar` / `<id>.json` 因为不命中任何包含规则自然
/// 不会进包），缓存类目录（.git、.fabric、avatar-cache 等）无条件跳过。
///
/// **OptiFine 不打包**（许可证禁止再分发，PCL2 也如此并在页面顶部提示
/// 「受 Modrinth 整合包规范限制，导出的整合包中不会包含 OptiFine」）。
///
/// Modrinth 格式支持「联网匹配」：对 mods / 资源包 / 光影包里的 jar/zip 按
/// sha1 到 Modrinth 反查（PCL2 同款 `POST /v2/version_files`），查到的文件
/// 不打包、只把下载链接写进 `modrinth.index.json`，导出物体积大幅缩小；
/// 查不到的（小众 Mod、自制包）原样进 overrides，导入方仍可用。
class ModpackExporter {
  ModpackExporter({required this.gameDir});

  final GameDir gameDir;

  // ── 选项目录（顺序即规则优先级，与 PCL2 PageInstanceExport.xaml 一致）──

  /// PCL2 整合包重要数据选项的规则原文（社区整合包常见目录，逐条对应）。
  static const _packDataRules = [
    'hotai/',
    'bansoukou/',
    'addons/',
    'multiblocked/',
    'modpack-update-checker/',
    'global_packs/',
    'global_resource_packs/',
    'global_data_packs/',
    'optional_data_packs/',
    'moonlight-global-datapacks/',
    'maps/',
    'icon.png',
    'mods-resourcepacks/',
    'matmos/',
    'resource_assorts/',
    'resource_assorts.json',
    'patchouli_books/',
    'datapacks/',
    'kubejs*/',
    '!kubejs*/probe/',
    '!kubejs*/exported/',
    '!kubejs*/jsconfig.json',
    '!kubejs*/README.txt',
    'openloader/',
    'worldshape/',
    'resources/',
    'scripts/',
    'structures/',
    'fontfiles/',
    'oresources/',
    'packmenu/',
    'craftpresence/',
    'pointblanks/',
    'template*/',
    '!template*/playerdata/',
    '!template*/stats/',
  ];

  /// PCL2 Mod 设置选项的规则原文：config 全收，但排除 JEI 世界数据
  /// （单独选项）、WorldEdit / spark 的会话数据、Essential 的账号与缓存
  /// 等个人信息，末尾排除 TaCZ 自定义（由 TaCZ 选项重新包含）。
  static const _modConfigRules = [
    'config/',
    '!config/jei/world/',
    '!config/worldedit/',
    'config/worldedit/worldedit.properties',
    '!config/spark/',
    'config/spark/config.json',
    'defaultconfigs/',
    'journeymap/config/',
    'journeymap/server/',
    'TrashSlotSaveState.json',
    'customfov.txt',
    'gg.essential.mod/',
    'essential/',
    '!essential/*/',
    '!essential/*.jar*',
    '!essential/screenshot-checksum-caches.json',
    '!essential/microsoft_accounts.json',
    'paragliderSettings.nbt',
    'local/client_config.json',
    'local/ftbl.json',
    'local/client/sidebar_buttons.json',
    'local/client/ftbutilities.cfg',
    'local/client/ftblib.cfg',
    'local/client/xencraft.cfg',
    'liteloader.properties',
    'default_reference.xml',
    'CustomSkinLoader/CustomSkinLoader.json',
    '!config/tacz/custom',
  ];

  /// 全部选项。**顺序不能乱**：规则按此顺序拼接，靠后的覆盖靠前的
  /// （例：Mod 设置排除 `config/tacz/custom`，其后的 TaCZ 选项再包含回来）。
  static const List<ModpackExportOption> options = [
    ModpackExportOption(
      key: 'basic',
      title: '游戏本体设置',
      description: '键位、音量、视频设置等',
      rules: [
        'options.txt',
        'configureddefaults/',
        'optionsof.txt',
        'optionsshaders.txt',
      ],
      defaultChecked: true,
    ),
    ModpackExportOption(
      key: 'basicPersonal',
      title: '游戏本体个人信息',
      description: '命令历史、已保存的快捷栏',
      rules: ['hotbar.nbt', 'command_history.txt'],
    ),
    ModpackExportOption(
      key: 'mods',
      title: '模组',
      description: 'mods / coremods / lib 下的已启用 Mod',
      rules: [
        'mods/',
        'coremods/',
        'lib/',
        '!mods/*.disabled',
        '!mods/*.old',
        '!mods/.connector/',
      ],
      defaultChecked: true,
      requireModLoader: true,
    ),
    // 在模组之后：把上一条排除的 .disabled / .old 重新包含。
    ModpackExportOption(
      key: 'modsDisabled',
      title: '已禁用的 Mod',
      description: '.disabled / .old 后缀的 Mod 文件',
      rules: ['mods/*.disabled', 'mods/*.old'],
      requireModLoader: true,
    ),
    ModpackExportOption(
      key: 'packData',
      title: '整合包重要数据',
      description: '脚本文件、内置资源包、数据包等',
      rules: _packDataRules,
      defaultChecked: true,
    ),
    ModpackExportOption(
      key: 'modConfig',
      title: 'Mod 设置',
      description: 'config / defaultconfigs 等（自动避开账号、世界数据等隐私内容）',
      rules: _modConfigRules,
      defaultChecked: true,
    ),
    // 在 Mod 设置之后：重新包含被其排除的 config/tacz/custom。
    ModpackExportOption(
      key: 'tacz',
      title: 'TaCZ 枪包',
      description: 'TaCZ 枪械附加包与自定义配置',
      rules: ['tacz/', 'config/tacz/custom/'],
      defaultChecked: true,
      requireModLoader: true,
    ),
    ModpackExportOption(
      key: 'immersivePaintings',
      title: '已上传的沉浸画',
      description: 'Immersive Paintings 的自定义画',
      rules: ['immersive_paintings/'],
    ),
    ModpackExportOption(
      key: 'mapData',
      title: '已绘制的地图',
      description: '地图类 Mod 为现有存档记录的地图、路标点等',
      rules: [
        'journeymap/data/',
        'xaero/',
        'XaeroWaypoints/',
        'XaeroWorldMap/',
      ],
    ),
    ModpackExportOption(
      key: 'jeiPersonal',
      title: 'JEI 个人信息',
      description: '物品收藏夹等',
      rules: ['config/jei/world/'],
    ),
    ModpackExportOption(
      key: 'emiPersonal',
      title: 'EMI 个人信息',
      description: '物品收藏夹、默认配方、合成历史记录等',
      rules: ['emi.json'],
    ),
    ModpackExportOption(
      key: 'patchouliPersonal',
      title: '帕秋莉手册个人信息',
      description: '教程书的已读记录、书签、阅读历史记录等',
      rules: ['patchouli_data.json'],
    ),
    ModpackExportOption(
      key: 'resourcepacks',
      title: '资源包',
      description: 'resourcepacks / texturepacks，可单独反选',
      rules: ['resourcepacks/', 'texturepacks/'],
      defaultChecked: true,
      subFolders: ['resourcepacks', 'texturepacks'],
      subAcceptCompressed: true,
    ),
    ModpackExportOption(
      key: 'shaderpacks',
      title: '光影包',
      description: 'shaderpacks，可单独反选',
      rules: ['shaderpacks/'],
      defaultChecked: true,
      requireModLoaderOrOptiFine: true,
      subFolders: ['shaderpacks'],
      subAcceptCompressed: true,
    ),
    ModpackExportOption(
      key: 'shaderSettings',
      title: '光影包设置',
      description: '已选光影包的自定义设置',
      rules: ['shaderpacks/*.txt'],
      defaultChecked: true,
      requireModLoaderOrOptiFine: true,
    ),
    ModpackExportOption(
      key: 'screenshots',
      title: '截图',
      description: 'screenshots 文件夹',
      rules: ['screenshots/'],
    ),
    ModpackExportOption(
      key: 'schematics',
      title: '导出的结构',
      description: 'schematics 文件夹（投影等建筑蓝图）',
      rules: ['schematics/'],
      defaultChecked: true,
    ),
    ModpackExportOption(
      key: 'replay',
      title: '录像回放',
      description: 'Replay Mod 的录像文件（体积大）',
      rules: ['replay_recordings/', 'replay_videos/'],
    ),
    ModpackExportOption(
      key: 'saves',
      title: '单人游戏存档',
      description: 'saves 下的世界，可单独反选',
      rules: ['saves/'],
      defaultChecked: true,
      subFolders: ['saves'],
    ),
    ModpackExportOption(
      key: 'licence',
      title: 'Licence 文件',
      description: '根目录的 LICENSE / LICENCE 说明',
      rules: ['LICEN*'],
      defaultChecked: true,
    ),
    ModpackExportOption(
      key: 'servers',
      title: '多人游戏服务器列表',
      description: 'servers.dat',
      rules: ['servers.dat'],
      defaultChecked: true,
    ),
  ];

  /// PCL2 `SubOptionBlackList`：这些是 PCL2 自带的皮肤包 / 附加包，
  /// 混在资源包目录里，列子选项时跳过。
  static const _subItemBlackList = [
    'Quark Programmer Art.zip',
    '+ EuphoriaPatches_',
    'PCL2 Skin.zip',
  ];

  /// 默认排除（PCL2 `GetAllRules` 末尾五条 + Mint 补充的 session.lock）。
  static const _defaultExcludeRules = [
    '!*.log',
    '!*.dat_old',
    '!*.BakaCoreInfo',
    '!hmclversion.cfg',
    '!log4j2.xml',
    // * 可跨目录段，saves/<世界>/session.lock 也能排除（Mint 补充）。
    '!*session.lock',
  ];

  /// 递归扫描时无条件跳过的目录（PCL2 `SearchFolder` 里写死的五个）。
  static const _alwaysSkipDirs = [
    'structureCacheV1',
    '.fabric',
    '.git',
    'avatar-cache',
    'cosmetic-cache',
  ];

  /// 只在主目录根部跳过的目录（共享根的公共资源；版本隔离时这些目录
  /// 也不会出现在 `versions/<id>/` 下，跳过只是兜底）。
  static const _rootSkipDirs = ['assets', 'versions', 'libraries'];

  /// 需要「联网检查是否已托管」的候选：扩展名与 PCL2 一致
  /// （.jar/.zip/.rar/.disabled/.old），路径包含 mods / packs /
  /// openloader / resource 之一——PCL2 用子串判断，资源包、光影包、
  /// 数据包目录都会顺带命中。
  static const _hostedExtensions = [
    '.jar',
    '.zip',
    '.rar',
    '.disabled',
    '.old',
  ];
  static const _hostedPathKeywords = [
    'mods',
    'packs',
    'openloader',
    'resource',
  ];

  // ── 对外查询接口（UI 用）──

  /// 按版本能力过滤后可展示的选项（PCL2 `RefreshAllOptionsUI` 的
  /// RequireOptiFine / RequireModLoader 门控）。
  static List<ModpackExportOption> optionsFor({
    required bool modable,
    required bool hasOptiFine,
  }) => [
    for (final o in options)
      if (!(o.requireModLoader && !modable))
        if (!(o.requireModLoaderOrOptiFine && !modable && !hasOptiFine)) o,
  ];

  /// 扫出某选项的子项（存档世界 / 资源包文件等）。
  /// 压缩包按文件名、目录按目录名，各按名称排序保证稳定。
  static List<ModpackExportSubItem> subItemsOf(
    ModpackExportOption option,
    String home,
  ) {
    final result = <ModpackExportSubItem>[];
    for (final folder in option.subFolders) {
      final dir = Directory(p.join(home, folder));
      if (!dir.existsSync()) continue;
      final names = <(String, bool)>[]; // (名称, 是否目录)
      try {
        for (final e in dir.listSync()) {
          final name = p.basename(e.path);
          if (_subItemBlackList.any((b) => name.contains(b))) continue;
          if (e is Directory) {
            // 空目录跳过（PCL2 同款：EnumerateFileSystemInfos().Any()）。
            if (e.listSync().isEmpty) continue;
            names.add((name, true));
          } else if (e is File && option.subAcceptCompressed) {
            final lower = name.toLowerCase();
            if (lower.endsWith('.zip') || lower.endsWith('.rar')) {
              names.add((name, false));
            }
          }
        }
      } catch (_) {
        continue;
      }
      names.sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
      result.addAll([
        for (final (name, isDir) in names)
          ModpackExportSubItem(
            title: name,
            rule: '$folder/${escapeGlob(name)}${isDir ? '/' : ''}',
          ),
      ]);
    }
    return result;
  }

  // ── 规则引擎 ──

  /// 通配转义：子项名称里可能出现 `* ? [ ]`。`[` 转成单字符字符类后，
  /// 后面出现的 `]` 不会被当成字符集结尾，无需转义；
  /// `*` `?` 各自包成只含自身的字符类。
  static String escapeGlob(String name) {
    final sb = StringBuffer();
    for (final c in name.split('')) {
      sb.write(switch (c) {
        '*' => '[*]',
        '?' => '[?]',
        '[' => '[[]',
        _ => c,
      });
    }
    return sb.toString();
  }

  /// 规则 → 正则（VB Like 子集：`*` 任意串、`?` 单字符、`[abc]` / `[a-z]` /
  /// `[!abc]` 字符集；已统一小写、`/` 分隔）。不含通配符的规则返回 null，
  /// 由调用方做精确比较。目录规则（`/` 结尾）不进正则，直接前缀匹配。
  static RegExp? _ruleToRegex(String rule) {
    if (!rule.contains('*') && !rule.contains('?') && !rule.contains('[')) {
      return null;
    }
    final sb = StringBuffer();
    var i = 0;
    while (i < rule.length) {
      final c = rule[i];
      switch (c) {
        case '*':
          sb.write('.*');
        case '?':
          sb.write('.');
        case '[':
          final close = rule.indexOf(']', i + 1);
          // 「[]]」「[[]」这类转义写法：内容为空/只有一个字符时按字面量处理。
          if (close <= i + 1) {
            sb.write(RegExp.escape('['));
          } else {
            var content = rule.substring(i + 1, close);
            var negate = false;
            if (content.startsWith('!')) {
              negate = true;
              content = content.substring(1);
            }
            final escaped = content.replaceAllMapped(
              RegExp(r'[\\\^\-\]]'),
              (m) => '\\${m[0]}',
            );
            sb
              ..write('[')
              ..write(negate ? '^' : '')
              ..write(escaped)
              ..write(']');
            // 跳过整个字符集，内容不能重复当作字面量再走一遍。
            i = close;
          }
        default:
          sb.write(RegExp.escape(c));
      }
      i++;
    }
    try {
      return RegExp('^(?:$sb)\$');
    } on FormatException {
      return null;
    }
  }

  /// 单条规则是否命中（内部统一转小写做大小写不敏感匹配，
  /// 对应 PCL2 双方 Lower 后再 Like）。
  static bool ruleMatches(String relativePath, String rule) {
    final relLower = relativePath.toLowerCase();
    final ruleLower = rule.toLowerCase().trim();
    final pattern = ruleLower.startsWith('!')
        ? ruleLower.substring(1)
        : ruleLower;
    if (pattern.isEmpty) return false;
    if (pattern.endsWith('/')) {
      // 目录规则 = 目录前缀下任意内容（PCL2 给目录规则补 * 的同款语义）。
      // 走通配翻译而不是字面 startsWith，子项名里的 [ ] * ? 转义才能生效。
      final regex = _ruleToRegex('$pattern*');
      return regex?.hasMatch(relLower) ?? relLower.startsWith(pattern);
    }
    final regex = _ruleToRegex(pattern);
    if (regex != null) return regex.hasMatch(relLower);
    return relLower == pattern;
  }

  /// 一组规则对某文件的最终裁决（null = 不收）：
  /// **靠后的行覆盖靠前的**，`!` 开头为排除（PCL2 `GetAllRules` 语义）。
  static bool? resolveRules(List<String> rules, String relativePath) {
    final relLower = relativePath.toLowerCase();
    bool? included;
    for (final raw in rules) {
      final rule = raw.trim();
      if (rule.isEmpty || rule.startsWith('#')) continue;
      if (ruleMatches(relLower, rule.toLowerCase())) {
        included = !rule.startsWith('!');
      }
    }
    return included;
  }

  // ── 主流程 ──

  /// 导出整合包。
  ///
  /// [home] 是该版本实际的游戏主目录（隔离 = `versions/<id>`，否则共享根）。
  /// [optionChecked] / [subItemChecked] 缺省时用各选项默认值；子项只在对应
  /// 选项勾选时有意义（未勾的子项生成排除规则，从父规则里抠掉）。
  /// [checkHosted] 仅 Modrinth 格式生效：联网反查资源托管信息。
  Future<ModpackExportResult> export(
    String versionId, {
    required String home,
    required String name,
    required String author,
    required String packVersion,
    required ModpackExportFormat format,
    Map<String, bool> optionChecked = const {},
    Map<String, bool> subItemChecked = const {},
    bool checkHosted = true,
    required String destFile,
    void Function(double fraction, String label)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final mc = gameDir.mcVersionOf(versionId);
    final loader = _loaderOf(versionId);

    // ── 1. 组规则（选项顺序即优先级 + 默认排除兜底）──
    final rules = <String>[];
    for (final option in options) {
      final checked = optionChecked[option.key] ?? option.defaultChecked;
      if (!checked) continue;
      rules.addAll(option.rules);
      if (option.hasSubItems) {
        for (final sub in subItemsOf(option, home)) {
          final subChecked =
              subItemChecked['${option.key}/${sub.title}'] ?? true;
          if (!subChecked) rules.add('!${sub.rule}');
        }
      }
    }
    rules.addAll(_defaultExcludeRules);

    // ── 2. 扫描游戏主目录 ──
    final candidates = <(String relPath, File file)>[];
    void walk(String dirPath, bool isRoot) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in entries) {
        final base = p.basename(e.path);
        if (e is Directory) {
          if (_alwaysSkipDirs.contains(base)) continue;
          if (isRoot && _rootSkipDirs.contains(base)) continue;
          walk(e.path, false);
        } else if (e is File) {
          final rel = p.posix.joinAll(
            p.relative(e.path, from: home).split(p.separator),
          );
          if (rel.startsWith('../') || rel == '..') continue;
          if (resolveRules(rules, rel) == true) candidates.add((rel, e));
        }
      }
    }

    onProgress?.call(0.02, '收集导出内容');
    walk(home, true);
    candidates.sort((a, b) => a.$1.compareTo(b.$1));

    // ── 3. 逐文件处理：OptiFine 跳过 / 候选联网匹配 / 其余直接打包 ──
    final skippedOptiFine = <String>[];
    final notes = <String>[];
    final packed = <(String relPath, File file)>[];
    final hostedEntries = <Map<String, dynamic>>[];
    final pendingHashes = <(String relPath, File file, String sha1)>[];
    final sha512Of = <String, String>{}; // relPath → sha512（候选文件才算）

    var done = 0;
    for (final (rel, file) in candidates) {
      if (isCancelled?.call() == true) throw Exception('已取消导出');
      done++;
      onProgress?.call(
        0.02 + 0.18 * done / candidates.length,
        '检查 ${p.basename(rel)}',
      );

      final lower = rel.toLowerCase();
      if (lower.endsWith('.jar') && lower.contains('optifine')) {
        // OptiFine 许可证禁止再分发：跳过并在说明里提示。
        skippedOptiFine.add(p.basename(rel));
        continue;
      }
      final isCandidate =
          _hostedExtensions.any(lower.endsWith) &&
          _hostedPathKeywords.any(rel.toLowerCase().contains);
      if (format == ModpackExportFormat.modrinth &&
          checkHosted &&
          isCandidate) {
        final bytes = await file.readAsBytes();
        final sha1 = crypto.sha1.convert(bytes).toString();
        final sha512 = crypto.sha512.convert(bytes).toString();
        pendingHashes.add((rel, file, sha1));
        sha512Of[rel] = sha512;
      } else {
        packed.add((rel, file));
      }
    }

    // ── 4. Modrinth 批量反查（失败不阻塞导出，文件退回直接打包）──
    Map<String, String> hostedUrls = const {};
    if (pendingHashes.isNotEmpty) {
      onProgress?.call(0.25, '联网匹配 Modrinth 资源');
      try {
        hostedUrls = await _queryModrinthFiles(
          pendingHashes.map((e) => e.$3).toList(),
        );
      } catch (e) {
        notes.add('Modrinth 联网匹配失败，资源文件已直接打包');
      }
    }
    for (final (rel, file, sha1) in pendingHashes) {
      final url = hostedUrls[sha1];
      if (url == null) {
        packed.add((rel, file));
      } else {
        hostedEntries.add({
          'path': rel,
          'hashes': {'sha1': sha1, 'sha512': sha512Of[rel]},
          'downloads': [url],
          'fileSize': file.lengthSync(),
        });
      }
    }

    // ── 5. 组 zip ──
    final archive = ar.Archive();
    var packedCount = 0;
    for (final (rel, file) in packed) {
      if (isCancelled?.call() == true) throw Exception('已取消导出');
      packedCount++;
      onProgress?.call(
        0.35 + 0.6 * packedCount / packed.length,
        '打包 ${p.basename(rel)}',
      );
      final bytes = await file.readAsBytes();
      archive.addFile(ar.ArchiveFile('overrides/$rel', bytes.length, bytes));
    }

    // 说明（也放进 overrides，导入方都能看到）。
    final readme = utf8.encode(
      _readme(name, mc, loader, format, skippedOptiFine, hostedEntries.length),
    );
    archive.addFile(
      ar.ArchiveFile('overrides/安装说明.txt', readme.length, readme),
    );

    if (format == ModpackExportFormat.modrinth) {
      final index = utf8.encode(
        jsonEncode({
          'formatVersion': 1,
          'game': 'minecraft',
          'versionId': packVersion,
          'name': name,
          'summary': 'Minecraft $mc · 由 Mint Launcher 导出',
          'files': hostedEntries,
          'dependencies': {
            'minecraft': mc,
            if (loader != null) loader.$3: loader.$4,
          },
        }),
      );
      archive.addFile(
        ar.ArchiveFile('modrinth.index.json', index.length, index),
      );
    } else {
      final manifest = utf8.encode(
        jsonEncode({
          'minecraft': {
            'version': mc,
            'additions': '',
            if (loader != null)
              'modLoaders': [
                {'id': '${loader.$2}-${loader.$4}', 'primary': true},
              ],
          },
          'manifestType': 'minecraftModpack',
          'manifestVersion': 1,
          'name': name,
          'version': packVersion,
          'author': author,
          'files': [],
          'overrides': 'overrides',
        }),
      );
      archive.addFile(
        ar.ArchiveFile('manifest.json', manifest.length, manifest),
      );
    }

    onProgress?.call(0.97, '写压缩包');
    final bytes = ar.ZipEncoder().encode(archive);
    final dest = File(destFile);
    dest.parent.createSync(recursive: true);
    await dest.writeAsBytes(bytes, flush: true);
    onProgress?.call(1, '完成');

    return ModpackExportResult(
      path: destFile,
      fileCount: packedCount,
      hostedCount: hostedEntries.length,
      sizeBytes: bytes.length,
      skippedOptiFine: skippedOptiFine,
      notes: notes,
    );
  }

  /// Modrinth `POST /v2/version_files`：sha1 列表 → 已托管文件的下载直链。
  /// PCL2 同款接口（`PageInstanceExport` 里 512 一批没有硬限制，这里按
  /// 256 一批切请求，单批失败整批重抛）。
  static Future<Map<String, String>> _queryModrinthFiles(
    List<String> sha1List,
  ) async {
    final result = <String, String>{};
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      for (var i = 0; i < sha1List.length; i += 256) {
        final batch = sha1List.sublist(
          i,
          i + 256 > sha1List.length ? sha1List.length : i + 256,
        );
        final body = jsonEncode({'hashes': batch, 'algorithm': 'sha1'});
        final req = await client.postUrl(
          Uri.parse('https://api.modrinth.com/v2/version_files'),
        );
        req.headers.contentType = ContentType.json;
        req.headers.set('User-Agent', 'MintLauncher/export');
        req.write(body);
        final res = await req.close().timeout(const Duration(seconds: 30));
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode != 200) {
          throw Exception('Modrinth API ${res.statusCode}');
        }
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) continue;
        for (final entry in decoded.entries) {
          final files = entry.value['files'];
          if (files is! List || files.isEmpty) continue;
          final first = files[0];
          if (first is! Map<String, dynamic>) continue;
          final url = first['url'];
          // 校验返回的 sha1 与请求一致（PCL2 同款防串包检查）。
          final hashes = first['hashes'];
          final returnedSha1 = hashes is Map<String, dynamic>
              ? hashes['sha1']
              : null;
          if (url is String && url.isNotEmpty && returnedSha1 == entry.key) {
            result[entry.key] = url;
          }
        }
      }
    } finally {
      client.close(force: true);
    }
    return result;
  }

  /// 版本 id → (显示名, CurseForge 前缀, Modrinth 依赖键, 版本号)。
  /// Modrinth index 依赖键为 `forge` / `fabric-loader` / `neoforge` /
  /// `quilt-loader`（quilt 是 Mint 对 PCL2 的补充，PCL2 2.14 只写前三种）；
  /// CurseForge manifest 的 modLoaders id 是 `<前缀>-<版本>`
  /// （如 `fabric-0.16.9`）。
  /// 认不出（纯原版 / 未知命名）返回 null。
  static (String, String, String, String)? _loaderOf(String versionId) {
    final base = versionId.split('-OptiFine_').first;
    var m = RegExp(r'fabric-loader-([0-9][\w.+\-]*?)-\d').firstMatch(base);
    if (m != null) return ('Fabric', 'fabric', 'fabric-loader', m.group(1)!);
    m = RegExp(r'quilt-loader-([0-9][\w.+\-]*?)-\d').firstMatch(base);
    if (m != null) return ('Quilt', 'quilt', 'quilt-loader', m.group(1)!);
    m = RegExp(r'-forge-(\d[\w.+\-]*)$').firstMatch(base);
    if (m != null) return ('Forge', 'forge', 'forge', m.group(1)!);
    m = RegExp(r'^neoforge-(\d[\w.+\-]*)$').firstMatch(base);
    if (m != null) return ('NeoForge', 'neoforge', 'neoforge', m.group(1)!);
    return null;
  }

  static String _readme(
    String name,
    String mc,
    (String, String, String, String)? loader,
    ModpackExportFormat format,
    List<String> skippedOptiFine,
    int hostedCount,
  ) => [
    '整合包「$name」',
    '由 Mint Launcher 导出'
        '${format == ModpackExportFormat.modrinth ? '（Modrinth 格式：modrinth.index.json + overrides/）' : '（CurseForge 格式：manifest.json + overrides/）'}。',
    'Minecraft $mc${loader == null ? '' : ' · ${loader.$1} ${loader.$4}'}',
    if (hostedCount > 0) '$hostedCount 个 Mod / 资源文件已匹配到 Modrinth 在线下载，导入时自动获取。',
    '',
    if (skippedOptiFine.isNotEmpty) ...[
      '注意：出于 OptiFine 许可证限制，以下文件没有打包，'
          '请安装后自行下载安装对应 OptiFine：',
      for (final f in skippedOptiFine) '  · $f',
      '',
    ],
    '导入方式：把整个文件拖进 Mint / PCL2 / HMCL 窗口，'
        '或下载页的「导入整合包」。',
  ].join('\n');
}

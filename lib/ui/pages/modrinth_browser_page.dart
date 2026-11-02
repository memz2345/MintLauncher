import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mint/services/launcher/downloader.dart';
import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/manifest.dart';
import 'package:mint/services/launcher/modrinth.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/src/loading_indicator_m3e.dart';

import 'common.dart';
import 'shared_actions.dart';
import '../widgets/mint_collapsible_card.dart';
import '../widgets/mint_page.dart';
import '../widgets/mint_refresh.dart';
import '../widgets/page_background.dart' show mintDialogMaskColor;
import '../widgets/pcl_hover.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

// ───────────────────────── 目标目录 / 装载辅助 ─────────────────────────

/// 某类型资源的默认安装目录（用户选文件夹对话框的初始位置）：
/// 当前版本的隔离主目录 + 类型对应子目录。
String defaultInstallDir(
  LauncherController controller,
  SettingsService settings,
  String versionId,
  ModrinthProjectType type,
) {
  // 没有已安装版本也能下：目标退回共享根的对应目录，选择器里还能随便改。
  if (versionId.isEmpty) {
    return p.join(controller.gameDir.root, type.targetDirName);
  }
  final isolated = settings.effectiveFor(versionId).isolation;
  final home = controller.gameDir.gameHome(versionId, isolated: isolated);
  return p.join(home, type.targetDirName);
}

/// 目标目录是否落在 Android/data（或应用私有 /data）里。
///
/// 系统「文件」选择器（SAF DocumentsUI）看不到这些目录，即使启动器自己
/// 有 MANAGE_EXTERNAL_STORAGE 也选不出来 —— 这种情况直接装到版本目录，
/// 不再弹文件夹选择器。
bool isAndroidDataPath(String path) {
  if (!Platform.isAndroid) return false;
  final normalized = p.posix
      .normalize(path.replaceAll('\\', '/'))
      .toLowerCase();
  return normalized.contains('/android/data/') ||
      normalized.contains('/android/obb/') ||
      normalized.startsWith('/data/');
}

/// 社区资源安装位置（Android/data 游戏）。
enum _InstallTargetAction { here, pick }

/// 版本 id → Modrinth 的 loader facet。
List<String> _loadersForVersion(String id) {
  final v = id.toLowerCase();
  if (v.contains('fabric')) return const ['fabric'];
  if (v.contains('quilt')) return const ['quilt'];
  if (v.contains('neoforge')) return const ['neoforge'];
  if (v.contains('forge')) return const ['forge'];
  return const [];
}

String _loaderLabel(String id) => loaderLabelForVersion(id);

ModrinthService _service(
  LauncherController controller,
  Downloader dl,
  String target,
  SettingsService settings,
) {
  final isolated = settings.effectiveFor(target).isolation;
  return ModrinthService(
    downloader: dl,
    gameHomeDir: controller.gameDir.gameHome(target, isolated: isolated),
  );
}

// ───────────────────────── 浏览器主体（可嵌入） ─────────────────────────

/// Modrinth 浏览器主体：搜索框 + tag 过滤 + 结果列表 + 翻页（带内存缓存）。
///
/// 打开即拉「热门列表」（无关键词按下载量排序）；输入关键词后按相关度。
/// [type] 固定由宿主控制 —— 下载中心双栏切类型、独立页用类型 chips。
class ModrinthBrowserView extends StatefulWidget {
  const ModrinthBrowserView({
    super.key,
    required this.miuix,
    required this.type,
    this.versionId,
    this.initialQuery = '',
    this.initialCategory,
    this.autoOpenSlug,
    this.embedded = false,
  });

  final bool miuix;
  final ModrinthProjectType type;

  /// 固定目标版本；null = 当前启动版本。
  final String? versionId;
  final String initialQuery;

  /// 初始的分类过滤（tag 点击进来）。
  final String? initialCategory;

  /// 搜索完成后自动打开的项目 slug（Fabric API 快捷入口）。
  final String? autoOpenSlug;

  /// 嵌入下载中心双栏时省掉一层标题说明。
  final bool embedded;

  @override
  State<ModrinthBrowserView> createState() => _ModrinthBrowserViewState();
}

class _ModrinthViewCache {
  _ModrinthViewCache({required this.query, this.category});

  String query;
  String? category;
  String? versionFilter;
  int page = 1;
  List<ModrinthHit>? hits;
  int totalHits = 0;
  bool loaded = false;
  bool autoOpened = false;
  double scrollOffset = 0;
}

class _ModrinthBrowserViewState extends State<ModrinthBrowserView> {
  static const int _pageSize = 20;

  /// 每个类型 + 目标版本一份内存快照（不落盘，重启即清空）。
  /// 切 tab 回来时直接渲染上次的结果 / 页码 / 滚动位置；只有没加载过
  /// 或用户手动刷新 / 改搜索条件时才请求网络。
  static final Map<String, _ModrinthViewCache> _caches = {};

  late final TextEditingController _query;
  late ModrinthProjectType _type = widget.type;
  late String? _category;

  /// 游戏版本过滤：null = 全部版本；默认初始化为当前版本对应的 MC 版本
  /// （PCL2 的「全部 (也可自行输入)」版本下拉同思路）。
  String? _versionFilter;
  bool _versionFilterReady = true;
  List<ModrinthHit>? _hits;
  int _totalHits = 0;
  int _page = 1;
  bool _loading = false;
  String? _error;
  bool _autoOpened = false;
  late final _ModrinthViewCache _cache;
  final ScrollController _scroll = ScrollController();

  /// 手动刷新（顶栏按钮 / 下拉）走 MintRefreshView 的指示器。
  final MintRefreshController _refreshCtrl = MintRefreshController();

  String get _cacheKey =>
      '${widget.embedded ? 'embedded' : 'page'}|${widget.type.id}|'
      '${widget.versionId ?? ''}';

  @override
  void initState() {
    super.initState();
    // 带 initialQuery / autoOpenSlug 的入口（Fabric API 快捷入口等）
    // 要一次全新的搜索，不能被同类型的旧快照顶掉。
    final fresh = widget.initialQuery.isNotEmpty || widget.autoOpenSlug != null;
    var cache = _caches[_cacheKey];
    if (fresh || cache == null) {
      cache = _ModrinthViewCache(
        query: widget.initialQuery,
        category: widget.initialCategory,
      );
      _caches[_cacheKey] = cache;
    }
    _cache = cache;
    _query = TextEditingController(text: cache.query);
    _category = cache.category;
    _versionFilter = cache.versionFilter;
    _hits = cache.hits;
    _totalHits = cache.totalHits;
    _page = cache.page;
    _autoOpened = cache.autoOpened;
    _scroll.addListener(_rememberScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_cache.loaded) {
        _search();
      } else if (_cache.scrollOffset > 0 && _scroll.hasClients) {
        _scroll.jumpTo(
          _cache.scrollOffset.clamp(0.0, _scroll.position.maxScrollExtent),
        );
      }
    });
  }

  void _rememberScroll() {
    if (_scroll.hasClients) _cache.scrollOffset = _scroll.offset;
  }

  @override
  void dispose() {
    _rememberScroll();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  String get _typeLabel => _type.label;

  int get _totalPages =>
      _totalHits <= 0 ? 1 : ((_totalHits + _pageSize - 1) ~/ _pageSize);
  bool get _hasPrev => _page > 1;
  bool get _hasNext => _page < _totalPages;

  void _saveCache() {
    _cache
      ..query = _query.text.trim()
      ..category = _category
      ..versionFilter = _versionFilter
      ..page = _page
      ..hits = _hits
      ..totalHits = _totalHits
      ..loaded = _hits != null
      ..autoOpened = _autoOpened;
  }

  /// 点击 tag：清空关键词，只按该分类继续搜（PCL2 的 tag 过滤同思路）。
  void _searchByCategory(String slug) {
    setState(() {
      _query.clear();
      _category = slug == _category ? null : slug;
      _hits = null;
      _page = 1;
      _error = null;
    });
    _search();
  }

  Future<ModrinthSearchPage> _doSearch({required int page}) async {
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    final target = widget.versionId ?? activeVersionId(controller, settings);
    // 没有已安装版本也能浏览：loader facet 退回不过滤（模组默认全部显示）。
    final dl = controller.newDownloaderForModloader();
    final service = target == null
        ? null
        : _service(controller, dl, target, settings);
    try {
      final query = _query.text.trim();
      return await (service ??
              ModrinthService(
                downloader: dl,
                gameHomeDir: controller.gameDir.root,
              ))
          .searchPage(
            query,
            _type,
            // null = 不过滤（全部版本）；字符串 = 精确过滤该 MC 版本。
            gameVersion: _versionFilter,
            loaders: target == null ? null : _loaders(target),
            categories: _category == null ? null : [_category!],
            // 无关键词 = 热门榜（按下载量）；有关键词 = 相关度。
            index: query.isEmpty
                ? ModrinthSearchIndex.downloads
                : ModrinthSearchIndex.relevance,
            limit: _pageSize,
            offset: (page - 1) * _pageSize,
          );
    } finally {
      dl.close();
    }
  }

  /// 版本筛选：从版本清单里选（带搜索），也支持手输任意版本
  /// （PCL2 的版本下拉同思路）。
  Future<void> _pickVersionFilter() async {
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    final target = widget.versionId ?? activeVersionId(controller, settings);
    final currentMc = target == null
        ? null
        : resolveMcVersion(controller.gameDir, target);
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _VersionPickerDialog(
        miuix: mintMiuixOf(context),
        controller: controller,
        current: _versionFilter,
        currentMcVersion: currentMc,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _versionFilter = picked.isEmpty ? null : picked;
      _hits = null;
      _page = 1;
    });
    _search();
  }

  Future<void> _search({bool resetPage = true}) async {
    if (_loading) return;
    if (resetPage) _page = 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _doSearch(page: _page);
      if (!mounted) return;
      setState(() {
        _hits = result.hits;
        _totalHits = result.totalHits;
        _loading = false;
      });
      _saveCache();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      final slug = widget.autoOpenSlug;
      if (!_autoOpened && slug != null) {
        _autoOpened = true;
        _cache.autoOpened = true;
        ModrinthHit? match;
        for (final h in result.hits) {
          if (h.slug == slug) {
            match = h;
            break;
          }
        }
        if (match != null) {
          final controller = context.read<LauncherController>();
          final settings = context.read<SettingsService>();
          final target =
              widget.versionId ?? activeVersionId(controller, settings);
          if (target != null && mounted) {
            _openProject(match, target, settings, replace: true);
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 手动刷新（下拉 / 刷新按钮）：回第一页重拉，不动搜索条件。
  Future<void> _refresh() => _search(resetPage: true);

  Future<void> _goToPage(int page) async {
    if (_loading || page < 1 || page > _totalPages || page == _page) return;
    setState(() => _page = page);
    await _search(resetPage: false);
  }

  void _openProject(
    ModrinthHit hit,
    String target,
    SettingsService settings, {
    bool replace = false,
  }) {
    final route = MaterialPageRoute<void>(
      builder: (_) => _ModrinthProjectPage(
        miuix: mintMiuixOf(context),
        hit: hit,
        type: _type,
        versionId: target,
        gameVersionFilter: _versionFilter,
      ),
    );
    if (replace) {
      // 自动打开（Fabric API 快捷入口）时替换当前搜索页，返回时直接回到上一页。
      Navigator.of(context).pushReplacement(route);
    } else {
      Navigator.of(context).push(route);
    }
  }

  IconData _typeIcon(ModrinthProjectType type) => switch (type) {
    ModrinthProjectType.mod => Icons.extension_outlined,
    ModrinthProjectType.modpack => Icons.inventory_2_outlined,
    ModrinthProjectType.datapack => Icons.data_object,
    ModrinthProjectType.resourcepack => Icons.texture_outlined,
    ModrinthProjectType.shader => Icons.auto_awesome_outlined,
  };

  List<String> _loaders(String? target) {
    if (_type != ModrinthProjectType.mod || target == null) {
      return const [];
    }
    return _loadersForVersion(target);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final settings = context.watch<SettingsService>();
    final target = widget.versionId ?? activeVersionId(controller, settings);
    final cs = Theme.of(context).colorScheme;
    final isFabric = _loaders(target).any((l) => l == 'fabric' || l == 'quilt');
    final showFabricApiHint = _type == ModrinthProjectType.mod && isFabric;

    return MintRefreshView(
      miuix: mintMiuixOf(context),
      controller: _refreshCtrl,
      topInset: 0,
      onRefresh: _refresh,
      child: ListView(
        controller: _scroll,
        physics: kMintPageScrollPhysics,
        padding: EdgeInsets.fromLTRB(16, widget.embedded ? 4 : 8, 16, 32),
        children: [
          if (!widget.embedded) ...[
            Row(
              children: [
                Icon(
                  Icons.sports_esports_outlined,
                  size: 16,
                  color: cs.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    target == null
                        ? '还没有已安装版本：下载时自选目标文件夹'
                        : '安装到当前版本 $target'
                              '${_loaderLabel(target).isEmpty ? '' : ' · ${_loaderLabel(target)}'}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: MintSearchField(
                  miuix: mintMiuixOf(context),
                  hint: '搜索$_typeLabel（留空看热门）',
                  controller: _query,
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              MintTextAction(
                miuix: mintMiuixOf(context),
                label: '搜索',
                icon: Icons.search,
                onPressed: _search,
              ),
            ],
          ),
          if (target == null) ...[
            const SizedBox(height: 16),
            MintNotice(
              miuix: mintMiuixOf(context),
              icon: Icons.info_outline,
              title: '还没有已安装版本',
              message:
                  '可以正常浏览与下载；安装时选择任意目标文件夹'
                  '（默认游戏根目录）。',
            ),
          ] else ...[
            if (_versionFilterReady) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  InputChip(
                    avatar: Icon(
                      Icons.videogame_asset_outlined,
                      size: 16,
                      color: cs.primary,
                    ),
                    label: Text(
                      _versionFilter == null ? '全部版本' : '版本 $_versionFilter',
                      style: TextStyle(fontSize: 12, color: cs.onSurface),
                    ),
                    onDeleted: _versionFilter == null
                        ? null
                        : () {
                            setState(() => _versionFilter = null);
                            _search();
                          },
                    onPressed: _pickVersionFilter,
                  ),
                  if (_category != null)
                    InputChip(
                      avatar: Icon(
                        Icons.filter_alt_outlined,
                        size: 16,
                        color: cs.primary,
                      ),
                      label: Text(
                        '分类：${modrinthCategoryLabel(_category!)}',
                        style: TextStyle(fontSize: 12, color: cs.onSurface),
                      ),
                      onDeleted: () {
                        setState(() {
                          _category = null;
                          _hits = null;
                          _page = 1;
                        });
                        _search();
                      },
                      onPressed: () {
                        setState(() {
                          _category = null;
                          _hits = null;
                          _page = 1;
                        });
                        _search();
                      },
                    ),
                ],
              ),
            ],
            if (showFabricApiHint) ...[
              const SizedBox(height: 12),
              MintNotice(
                miuix: mintMiuixOf(context),
                icon: Icons.extension_outlined,
                title: '记得装 Fabric API',
                message: '当前是 Fabric 系版本；大多数模组依赖 Fabric API，缺了会在启动时崩。',
                action: MintTextAction(
                  miuix: mintMiuixOf(context),
                  label: '获取',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ModrinthBrowserPage(
                        miuix: mintMiuixOf(context),
                        type: ModrinthProjectType.mod,
                        versionId: target,
                        initialQuery: 'Fabric API',
                        autoOpenSlug: 'fabric-api',
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 64),
                child: Center(child: LoadingIndicatorM3E()),
              )
            else if (_error != null)
              MintEmptyState(
                miuix: mintMiuixOf(context),
                icon: Icons.cloud_off,
                title: '搜索失败',
                message: _error,
                action: MintSecondaryButton(
                  miuix: mintMiuixOf(context),
                  label: '重试',
                  icon: Icons.refresh,
                  onPressed: _search,
                ),
              )
            else if (_hits == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(
                    '正在获取热门$_typeLabel…',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else if (_hits!.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(
                    _category == null
                        ? '没有匹配的$_typeLabel'
                        : '该分类下没有匹配 ${resolveMcVersion(controller.gameDir, target) ?? '当前版本'} 的$_typeLabel',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              )
            else ...[
              // 和下载游戏页一样：结果收进一张可折叠大卡，行内是资源。
              MintCollapsibleCard(
                miuix: mintMiuixOf(context),
                title: _query.text.trim().isEmpty
                    ? '热门$_typeLabel'
                    : '$_typeLabel 搜索结果',
                subtitle:
                    '共 $_totalHits 个 · 第 $_page / $_totalPages 页'
                    '${(_query.text.trim().isEmpty ? '' : ' · 关键词「${_query.text.trim()}」')}',
                leading: Icon(_typeIcon(_type), size: 26, color: cs.primary),
                initiallyExpanded: true,
                children: [
                  for (final (i, hit) in _hits!.indexed) ...[
                    _HitCard(
                      miuix: mintMiuixOf(context),
                      hit: hit,
                      type: _type,
                      grouped: true,
                      onTagTap: _searchByCategory,
                      onTap: () => _openProject(
                        hit,
                        target,
                        context.read<SettingsService>(),
                      ),
                    ),
                    if (i != _hits!.length - 1)
                      Divider(
                        height: 1,
                        indent: 14,
                        endIndent: 14,
                        color: cs.outlineVariant.withValues(alpha: 0.35),
                      ),
                  ],
                ],
              ),
              if (_hits!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      MintTextAction(
                        miuix: mintMiuixOf(context),
                        label: '上一页',
                        icon: Icons.chevron_left,
                        onPressed: _hasPrev && !_loading
                            ? () => _goToPage(_page - 1)
                            : null,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '第 $_page / $_totalPages 页',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      MintTextAction(
                        miuix: mintMiuixOf(context),
                        label: '下一页',
                        icon: Icons.chevron_right,
                        onPressed: _hasNext && !_loading
                            ? () => _goToPage(_page + 1)
                            : null,
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

// ───────────────────────── 独立页（带类型切换） ─────────────────────────

/// Modrinth 浏览器页（模组 / 整合包 / 资源包 / 光影 / 数据包）。
///
/// 顶部一行类型 chips 可切换（PCL2 下载页左侧类别的窄屏形态），
/// 切换会按新类型重新拉热门/搜索。
class ModrinthBrowserPage extends StatefulWidget {
  const ModrinthBrowserPage({
    super.key,
    required this.miuix,
    required this.type,
    this.versionId,
    this.initialQuery = '',
    this.initialCategory,
    this.autoOpenSlug,
  });

  final bool miuix;
  final ModrinthProjectType type;

  /// 固定目标版本；null = 当前启动版本。
  final String? versionId;
  final String initialQuery;

  /// 初始分类过滤（详情页 tag 点击进来：无关键词按分类搜）。
  final String? initialCategory;

  /// 搜索完成后自动打开的项目 slug（Fabric API 快捷入口）。
  final String? autoOpenSlug;

  @override
  State<ModrinthBrowserPage> createState() => _ModrinthBrowserPageState();
}

class _ModrinthBrowserPageState extends State<ModrinthBrowserPage> {
  late ModrinthProjectType _type = widget.type;

  /// initialQuery / autoOpenSlug 只给第一次进入的那个 tab 用；之后切回来
  /// 走内存缓存，不能因为父级重新传 initialQuery 又强制重搜一遍。
  bool _initialConsumed = false;

  @override
  Widget build(BuildContext context) {
    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: _type.label,
      showBack: true,
      body: (padding) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: padding.copyWith(bottom: 0),
            child: _TypeChipsRow(
              miuix: mintMiuixOf(context),
              selected: _type,
              onSelected: (t) => setState(() {
                _type = t;
                _initialConsumed = true;
              }),
            ),
          ),
          Expanded(
            child: ModrinthBrowserView(
              key: ValueKey(_type),
              miuix: mintMiuixOf(context),
              type: _type,
              versionId: widget.versionId,
              initialQuery: _type == widget.type && !_initialConsumed
                  ? widget.initialQuery
                  : '',
              initialCategory: _type == widget.type && !_initialConsumed
                  ? widget.initialCategory
                  : null,
              autoOpenSlug: _type == widget.type && !_initialConsumed
                  ? widget.autoOpenSlug
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 类型 chips 行（窄屏的类型选择）。
class _TypeChipsRow extends StatelessWidget {
  const _TypeChipsRow({
    required this.miuix,
    required this.selected,
    required this.onSelected,
  });

  final bool miuix;
  final ModrinthProjectType selected;
  final ValueChanged<ModrinthProjectType> onSelected;

  static const List<(ModrinthProjectType, IconData)> _items = [
    (ModrinthProjectType.mod, Icons.extension_outlined),
    (ModrinthProjectType.modpack, Icons.inventory_2_outlined),
    (ModrinthProjectType.datapack, Icons.data_object),
    (ModrinthProjectType.resourcepack, Icons.texture_outlined),
    (ModrinthProjectType.shader, Icons.auto_awesome_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          for (final (type, icon) in _items)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _TypeChip(
                miuix: miuix,
                icon: icon,
                label: type.label,
                selected: type == selected,
                onTap: () => onSelected(type),
              ),
            ),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.miuix,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final bool miuix;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? (miuix ? cs.primary : cs.secondaryContainer)
          : cs.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected
                    ? (miuix ? cs.onPrimary : cs.onSecondaryContainer)
                    : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected
                      ? (miuix ? cs.onPrimary : cs.onSecondaryContainer)
                      : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 搜索结果卡片 ─────────────────────────

class _HitCard extends StatelessWidget {
  const _HitCard({
    required this.miuix,
    required this.hit,
    required this.type,
    required this.onTap,
    required this.onTagTap,
    this.grouped = false,
  });

  final bool miuix;
  final ModrinthHit hit;
  final ModrinthProjectType type;
  final VoidCallback onTap;
  final ValueChanged<String> onTagTap;

  /// 放进下载游戏页同款的大分组卡时不再自己套一层卡。
  final bool grouped;

  /// 展示的 tag：displayCategories 优先；兜底 categories 时剔除 loader 名。
  List<String> get _tags {
    final list = hit.displayCategories;
    if (list.isNotEmpty) return list;
    return [
      for (final c in hit.categories)
        if (!_isLoaderName(c)) c,
    ];
  }

  static bool _isLoaderName(String slug) => const {
    'fabric',
    'forge',
    'neoforge',
    'quilt',
    'liteloader',
    'rift',
    'modloader',
  }.contains(slug);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: hit.iconUrl.isEmpty
          ? Container(
              width: 54,
              height: 54,
              color: cs.surfaceContainerHighest,
              child: const Icon(Icons.extension, size: 26),
            )
          : Image.network(
              hit.iconUrl,
              width: 54,
              height: 54,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                width: 54,
                height: 54,
                color: cs.surfaceContainerHighest,
                child: const Icon(Icons.extension, size: 26),
              ),
            ),
    );
    final tags = _tags.take(4).toList();
    // 行动画与版本管理列表同源：PCL 悬浮底板（0.75→1 缩放 + 淡入淡出）+
    // Material 风格下的水波；miuix 保持自己的按压遮罩，不吃 ripple。
    final row = PclHoverSurface(
      onTap: onTap,
      borderRadius: 16,
      ripple: !miuix,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            icon,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hit.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hit.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final tag in tags)
                        _MiniTagChip(
                          miuix: miuix,
                          label: modrinthCategoryLabel(tag),
                          onTap: () => onTagTap(tag),
                        ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.download_outlined,
                        size: 11,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        hit.displayDownloads,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.favorite_border,
                        size: 11,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        hit.follows.toString(),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            // 和下载游戏页一样：右侧是明确的下载入口（打开详情选文件），
            // 不再只是一个小箭头。
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: IconButton(
                tooltip: '下载 / 选择版本',
                onPressed: onTap,
                icon: Icon(
                  Icons.download_outlined,
                  size: 23,
                  color: cs.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (grouped) return row;
    return MintCard(miuix: miuix, children: [row]);
  }
}

/// 列表卡片上的迷你 tag（点击按该分类过滤）。
class _MiniTagChip extends StatelessWidget {
  const _MiniTagChip({
    required this.miuix,
    required this.label,
    required this.onTap,
  });

  final bool miuix;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primary.withValues(alpha: miuix ? 0.14 : 0.09),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: cs.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 项目详情页 ─────────────────────────

class _ModrinthProjectPage extends StatefulWidget {
  const _ModrinthProjectPage({
    required this.miuix,
    required this.hit,
    required this.type,
    required this.versionId,
    this.gameVersionFilter,
  });

  final bool miuix;
  final ModrinthHit hit;
  final ModrinthProjectType type;
  final String versionId;

  /// 浏览页带过来的版本筛选（null = 全部版本）。
  final String? gameVersionFilter;

  @override
  State<_ModrinthProjectPage> createState() => _ModrinthProjectPageState();
}

class _ModrinthProjectPageState extends State<_ModrinthProjectPage> {
  List<ModrinthVersionFile>? _versions;
  bool _loading = true;
  String? _error;
  String? _installing;

  /// 没有任何匹配 MC 版本号的游戏版本时的分组名。
  static const String _otherVersionKey = '其他版本';

  static final RegExp _mcVersionPattern = RegExp(r'^(\d+)\.(\d+)(?:\.(\d+))?$');

  static List<int> _versionTuple(String id) {
    final m = _mcVersionPattern.firstMatch(id);
    if (m == null) return const [];
    return [
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3) ?? '0'),
    ];
  }

  /// 一个文件归入的版本分组键：启用版本筛选时就是筛选值本身；
  /// 否则取该文件适配的**最新** MC 版本（一个文件往往同时适配多个）。
  String _groupKeyOf(ModrinthVersionFile v) {
    final filter = widget.gameVersionFilter;
    if (filter != null && filter.isNotEmpty) return filter;
    String? best;
    var bestTuple = const <int>[-1, -1, -1];
    for (final g in v.gameVersions) {
      final t = _versionTuple(g);
      if (t.isEmpty) continue;
      var greater = false;
      for (var i = 0; i < 3; i++) {
        if (t[i] != bestTuple[i]) {
          greater = t[i] > bestTuple[i];
          break;
        }
      }
      if (greater) {
        bestTuple = t;
        best = g;
      }
    }
    return best ?? _otherVersionKey;
  }

  /// 版本文件按 MC 版本分组，组间按版本号**新 → 旧**排序
  /// （PCL2 社区详情页同款：一个版本一张可折叠大卡片）。
  List<(String, List<ModrinthVersionFile>)> _groupVersions(
    List<ModrinthVersionFile> versions,
  ) {
    final map = <String, List<ModrinthVersionFile>>{};
    for (final v in versions) {
      map.putIfAbsent(_groupKeyOf(v), () => []).add(v);
    }
    final entries = map.entries.toList();
    entries.sort((a, b) {
      final ka = _versionTuple(a.key);
      final kb = _versionTuple(b.key);
      if (ka.isEmpty && kb.isEmpty) return a.key.compareTo(b.key);
      if (ka.isEmpty) return 1;
      if (kb.isEmpty) return -1;
      for (var i = 0; i < 3; i++) {
        final c = kb[i].compareTo(ka[i]);
        if (c != 0) return c;
      }
      return 0;
    });
    return [for (final e in entries) (e.key, e.value)];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// 详情页 tag 点击：推一个「无关键词 + 该分类过滤」的搜索页继续浏览。
  void _browseTag(String slug) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModrinthBrowserPage(
          miuix: mintMiuixOf(context),
          type: widget.type,
          versionId: widget.versionId,
          initialCategory: slug,
        ),
      ),
    );
  }

  /// 顶卡点击：打开 Modrinth 项目页（浏览器 / 默认浏览器）。
  Future<void> _openWeb() async {
    final slug = widget.hit.slug.isNotEmpty ? widget.hit.slug : widget.hit.id;
    if (slug.isEmpty) return;
    final uri = Uri.parse('https://modrinth.com/${widget.type.id}/$slug');
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('系统拒绝了打开请求');
    } catch (e) {
      if (!mounted) return;
      showMintSnack(context, '打开网页失败：$e\n$uri');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final settings = context.watch<SettingsService>();
    final isolated = settings.effectiveFor(widget.versionId).isolation;
    final targetDir = Directory(
      p.join(
        controller.gameDir.gameHome(widget.versionId, isolated: isolated),
        widget.type.targetDirName,
      ),
    );
    final cs = Theme.of(context).colorScheme;
    final isFabric =
        widget.type == ModrinthProjectType.mod &&
        _loadersForVersion(
          widget.versionId,
        ).any((l) => l == 'fabric' || l == 'quilt');
    final tags = widget.hit.displayCategories.isEmpty
        ? widget.hit.categories
        : widget.hit.displayCategories;

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: widget.hit.title,
      showBack: true,
      body: (padding) => ListView(
        physics: kMintPageScrollPhysics,
        padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _HitCard(
            miuix: mintMiuixOf(context),
            hit: widget.hit,
            type: widget.type,
            onTap: _openWeb,
            onTagTap: _browseTag,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              children: [
                Icon(Icons.link, size: 13, color: cs.onSurfaceVariant),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '点击卡片打开 Modrinth 网页'
                    '${widget.gameVersionFilter == null ? '' : ' · 版本筛选 ${widget.gameVersionFilter}'}',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Text(
                '标签（点击按分类继续浏览）',
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in tags)
                  ActionChip(
                    avatar: Icon(Icons.tag, size: 14, color: cs.primary),
                    label: Text(
                      modrinthCategoryLabel(tag),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () => _browseTag(tag),
                  ),
              ],
            ),
          ],
          if (widget.type == ModrinthProjectType.modpack) ...[
            const SizedBox(height: 12),
            MintNotice(
              miuix: mintMiuixOf(context),
              icon: Icons.inventory_2_outlined,
              title: '整合包安装说明',
              message:
                  '安装时会让你选一个游戏目录并输入版本名；整合包会以「版本隔离」'
                  '安装成独立版本，mods / config 等都在 versions/<版本名> 下。',
            ),
          ],
          if (isFabric && widget.hit.slug != 'fabric-api') ...[
            const SizedBox(height: 10),
            MintNotice(
              miuix: mintMiuixOf(context),
              icon: Icons.extension_outlined,
              title: 'Fabric API',
              message: '大多数 Fabric 模组需要 Fabric API，没装的话进游戏可能直接崩。',
              action: MintTextAction(
                miuix: mintMiuixOf(context),
                label: '获取',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ModrinthBrowserPage(
                      miuix: mintMiuixOf(context),
                      type: ModrinthProjectType.mod,
                      versionId: widget.versionId,
                      initialQuery: 'Fabric API',
                      autoOpenSlug: 'fabric-api',
                    ),
                  ),
                ),
              ),
            ),
          ],
          MintSectionHeader(
            miuix: mintMiuixOf(context),
            title: '版本文件',
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
            trailing: Text(
              _loading ? '获取中…' : '${_versions?.length ?? 0} 个',
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: LoadingIndicatorM3E()),
            )
          else if (_error != null)
            MintEmptyState(
              miuix: mintMiuixOf(context),
              icon: Icons.cloud_off,
              title: '获取版本失败',
              message: _error,
              action: MintSecondaryButton(
                miuix: mintMiuixOf(context),
                label: '重试',
                icon: Icons.refresh,
                onPressed: _load,
              ),
            )
          else if (_versions == null || _versions!.isEmpty)
            MintEmptyState(
              miuix: mintMiuixOf(context),
              icon: Icons.inbox_outlined,
              title: '没有匹配当前版本的文件',
              message: '该资源没有适配 ${widget.versionId} 的版本，可以换一个资源或版本。',
            )
          else
            for (final (i, (title, files)) in _groupVersions(
              _versions!,
            ).indexed) ...[
              MintCollapsibleCard(
                miuix: mintMiuixOf(context),
                title: title == _otherVersionKey ? '未标注版本' : 'Minecraft $title',
                subtitle: '${files.length} 个文件',
                // 搜索态不记状态；默认只展开最新一组（PCL2 同款）。
                storageKey: 'modrinth.$title',
                // 默认只展开最新一组，其余折叠（PCL2 同款）。
                initiallyExpanded: i == 0,
                children: [
                  for (final (j, v) in files.indexed)
                    _VersionFileRow(
                      miuix: mintMiuixOf(context),
                      version: v,
                      type: widget.type,
                      bare: true,
                      showDivider: j < files.length - 1,
                      installing: _installing == v.primaryFile?.filename,
                      installed: v.primaryFile == null
                          ? false
                          : File(
                              p.join(targetDir.path, v.primaryFile!.filename),
                            ).existsSync(),
                      onInstall: () => _install(v),
                    ),
                ],
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    final dl = controller.newDownloaderForModloader();
    final service = _service(controller, dl, widget.versionId, settings);
    try {
      final versions = await service.versionsOf(
        widget.hit.slug.isEmpty ? widget.hit.id : widget.hit.slug,
        gameVersion: widget.gameVersionFilter,
        loaders: widget.type == ModrinthProjectType.mod
            ? _loadersForVersion(widget.versionId)
            : null,
      );
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    } finally {
      dl.close();
    }
  }

  /// Android/data 游戏：询问是直接装进版本目录，还是另选一个可见文件夹。
  /// 返回 null = 用户取消整个安装。
  Future<_InstallTargetAction?> _askDataTarget({
    required String hereLabel,
    required String hereSubtitle,
  }) {
    return showMintChoiceDialog<_InstallTargetAction>(
      context,
      miuix: mintMiuixOf(context),
      title: '当前游戏在 data 目录',
      selected: _InstallTargetAction.here,
      options: [
        MintChoice(
          value: _InstallTargetAction.here,
          label: hereLabel,
          subtitle: hereSubtitle,
          icon: Icons.check_circle_outline,
        ),
        const MintChoice(
          value: _InstallTargetAction.pick,
          label: '选择其他文件夹…',
          subtitle: '系统文件应用无法进入 data 目录',
          icon: Icons.folder_open_outlined,
        ),
      ],
    );
  }

  /// 安装一个版本文件：先让用户选目标文件夹（默认该版本对应目录），
  /// 整合包则选游戏目录 + 输入版本名。之后下载全部走后台任务。
  Future<void> _install(ModrinthVersionFile version) async {
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    final filename = version.primaryFile?.filename;
    try {
      if (widget.type == ModrinthProjectType.modpack) {
        // ── 整合包：选游戏目录（默认当前目录）→ 输入版本名 ──
        final defaultRoot = controller.gameDir.root;
        String? root = defaultRoot;
        if (isAndroidDataPath(defaultRoot)) {
          final action = await _askDataTarget(
            hereLabel: '安装到当前目录',
            hereSubtitle: '整合包会作为独立版本直接装进当前游戏目录',
          );
          if (action == null || !mounted) return;
          root = action == _InstallTargetAction.pick
              ? await getDirectoryPath(confirmButtonText: '安装整合包到这里')
              : defaultRoot;
        } else {
          root = await getDirectoryPath(
            initialDirectory: defaultRoot,
            confirmButtonText: '安装整合包到这里',
          );
        }
        if (root == null || !mounted) return;
        final name = await showMintTextDialog(
          context,
          miuix: mintMiuixOf(context),
          title: '整合包版本名称',
          initial: widget.hit.title.replaceAll('.mrpack', ''),
          hint: '将创建独立版本（自动开启版本隔离）',
        );
        if (name == null || name.trim().isEmpty || !mounted) return;
        setState(() => _installing = filename ?? version.versionNumber);
        final packId = await controller.installModpack(
          version,
          title: name.trim(),
          targetRoot: root,
        );
        if (!mounted) return;
        showMintSnack(
          context,
          '整合包已安装为 $packId，可在主页选择启动',
          action: SnackBarAction(
            label: '打开文件夹',
            onPressed: () => controller.openInFileManager(
              controller.gameDir.versionDir(packId),
            ),
          ),
        );
      } else {
        // ── 普通资源：选文件夹（默认该版本对应子目录）──
        final defaultDir = defaultInstallDir(
          controller,
          settings,
          widget.versionId,
          widget.type,
        );
        String? dir = defaultDir;
        if (isAndroidDataPath(defaultDir)) {
          final hasVersion = widget.versionId.isNotEmpty;
          final action = await _askDataTarget(
            hereLabel: hasVersion ? '安装到版本 ${widget.versionId}' : '安装到游戏目录',
            hereSubtitle:
                '${widget.type.label}会直接写入${hasVersion ? '该版本' : '游戏'}目录',
          );
          if (action == null || !mounted) return;
          dir = action == _InstallTargetAction.pick
              ? await getDirectoryPath(confirmButtonText: '安装到这里')
              : defaultDir;
        } else {
          dir = await getDirectoryPath(
            initialDirectory: defaultDir,
            confirmButtonText: '安装到这里',
          );
        }
        if (dir == null || !mounted) return;
        setState(() => _installing = filename ?? version.versionNumber);
        await controller.installModrinthFile(
          version,
          widget.type,
          versionId: widget.versionId,
          isolated: settings.effectiveFor(widget.versionId).isolation,
          destDir: dir,
        );
        if (!mounted) return;
        // 装完按资源类型给个直达入口：资源管理器定位到该版本对应目录。
        showMintSnack(
          context,
          '已安装到 ${widget.type.label}目录',
          action: SnackBarAction(
            label: '打开文件夹',
            onPressed: () => controller.openInFileManager(dir!),
          ),
        );
      }
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      showMintSnack(context, '安装失败：$e');
    } finally {
      if (mounted) setState(() => _installing = null);
    }
  }
}

class _VersionFileRow extends StatelessWidget {
  const _VersionFileRow({
    required this.miuix,
    required this.version,
    required this.type,
    required this.installing,
    required this.installed,
    required this.onInstall,
    this.bare = false,
    this.showDivider = false,
  });

  final bool miuix;
  final ModrinthVersionFile version;
  final ModrinthProjectType type;
  final bool installing;
  final bool installed;
  final VoidCallback onInstall;

  /// true = 嵌在分组折叠卡里的裸行（不套自己的卡片，带分组内分隔线）。
  final bool bare;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final file = version.primaryFile;
    final size = file == null || file.size <= 0
        ? ''
        : ' · ${(file.size / 1024 / 1024).toStringAsFixed(1)} MB';
    final row = MintTile(
      miuix: miuix,
      icon: type == ModrinthProjectType.modpack
          ? Icons.inventory_2_outlined
          : Icons.description_outlined,
      title: version.versionNumber,
      subtitle:
          '${version.loaders.join('/')} · ${version.versionType}$size'
          '${file == null ? '' : ' · ${file.filename}'}',
      showDivider: bare ? showDivider : false,
      onTap: installing || file == null ? null : onInstall,
      trailing: installing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : installed
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, size: 18, color: cs.primary),
                const SizedBox(width: 4),
                Text(
                  '已安装',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ],
            )
          : MintTextAction(
              miuix: miuix,
              label: '安装',
              icon: Icons.download,
              onPressed: file == null ? null : onInstall,
            ),
    );
    if (bare) return row;
    return MintCard(miuix: miuix, children: [row]);
  }
}

// ───────────────────────── 版本选择对话框 ─────────────────────────

/// 按 Minecraft 版本筛选：拉版本清单（ newest 在前）+ 本地搜索，
/// 也支持把搜索词当自定义版本直接用（清单拉不到时唯一的路）。
class _VersionPickerDialog extends StatefulWidget {
  const _VersionPickerDialog({
    required this.miuix,
    required this.controller,
    required this.current,
    this.currentMcVersion,
  });

  final bool miuix;
  final LauncherController controller;
  final String? current;

  /// 当前启动版本对应的 MC 版本（快捷项）。
  final String? currentMcVersion;

  @override
  State<_VersionPickerDialog> createState() => _VersionPickerDialogState();
}

class _VersionPickerDialogState extends State<_VersionPickerDialog> {
  final TextEditingController _search = TextEditingController();
  List<ManifestVersion>? _versions;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final manifest = await widget.controller.ensureManifest();
        if (!mounted) return;
        setState(() => _versions = manifest.versions);
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = '$e');
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(String value) => Navigator.of(context).pop(value);

  /// release / snapshot / old_beta / old_alpha → 中文标签 + 配色。
  (String, Color) _typeBadge(String type, ColorScheme cs) => switch (type) {
    'release' => ('正式版', cs.primary),
    'snapshot' => ('快照', const Color(0xFFE08A3C)),
    'old_beta' => ('Beta', cs.onSurfaceVariant),
    'old_alpha' => ('Alpha', cs.onSurfaceVariant),
    _ => (type, cs.onSurfaceVariant),
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final query = _search.text.trim().toLowerCase();
    final versions = _versions;
    final filtered = versions == null
        ? null
        : [
            for (final v in versions)
              if (query.isEmpty || v.id.toLowerCase().contains(query)) v,
          ];

    if (mintMiuixOf(context, widget.miuix)) {
      final c = MiuixTheme.of(context).colors;
      return Dialog(
        backgroundColor: mintDialogMaskColor(context, c.background),
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: _body(context, cs, filtered, miuix: true),
      );
    }
    return AlertDialog(
      title: const Text('按 Minecraft 版本筛选'),
      content: SizedBox(
        width: 420,
        height: 480,
        child: _body(context, cs, filtered, miuix: false),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    ColorScheme cs,
    List<ManifestVersion>? filtered, {
    required bool miuix,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (miuix)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
            child: Text(
              '按 Minecraft 版本筛选',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: MintSearchField(
                  miuix: miuix,
                  hint: '搜索版本 / 输入任意版本',
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (v) {
                    final text = v.trim();
                    if (text.isNotEmpty) _pick(text);
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Row(
            children: [
              MintTextAction(
                miuix: miuix,
                label: '全部版本',
                icon: Icons.public_outlined,
                onPressed: () => _pick(''),
              ),
              if (widget.currentMcVersion != null &&
                  widget.currentMcVersion!.isNotEmpty) ...[
                const SizedBox(width: 4),
                MintTextAction(
                  miuix: miuix,
                  label: '当前版本（${widget.currentMcVersion}）',
                  icon: Icons.videogame_asset_outlined,
                  onPressed: () => _pick(widget.currentMcVersion!),
                ),
              ],
              const Spacer(),
              Text(
                _error != null
                    ? '清单拉取失败，可直接输入'
                    : '${filtered?.length ?? '…'} 个版本',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered == null
              ? Center(
                  child: _error != null
                      ? Text(
                          '版本清单获取失败：$_error\n仍可在上方输入任意版本号。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: cs.onSurfaceVariant,
                          ),
                        )
                      : const Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                )
              : ListView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    for (final v in filtered)
                      _VersionRow(
                        miuix: miuix,
                        version: v.id,
                        badge: _typeBadge(v.type, cs),
                        selected: v.id == widget.current,
                        onTap: () => _pick(v.id),
                      ),
                  ],
                ),
        ),
        if (miuix)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
            child: Align(
              alignment: Alignment.centerRight,
              child: MiuixButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ),
          ),
      ],
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.miuix,
    required this.version,
    required this.badge,
    required this.selected,
    required this.onTap,
  });

  final bool miuix;
  final String version;
  final (String, Color) badge;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color) = badge;
    if (miuix) {
      return MiuixBasicComponent(
        title: version,
        insideMargin: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        onClick: onTap,
        endActions: [
          if (selected) Icon(Icons.check, size: 18, color: cs.primary),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(label, style: TextStyle(fontSize: 10.5, color: color)),
          ),
        ],
      );
    }
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(version),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) Icon(Icons.check, size: 18, color: cs.primary),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(label, style: TextStyle(fontSize: 10.5, color: color)),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

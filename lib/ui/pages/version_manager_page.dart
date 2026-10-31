import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/ui/nav_state.dart';
import 'package:mint/ui/pages/common.dart';
import 'package:mint/ui/pages/shared_actions.dart';
import 'package:mint/ui/pages/vanilla_versions_page.dart';
import 'package:mint/ui/pages/version_navigation.dart';
import 'package:mint/ui/widgets/mint_collapsible_card.dart';
import 'package:mint/ui/widgets/mint_collapsible_pane.dart';
import 'package:mint/ui/widgets/mint_page.dart';
import 'package:mint/ui/widgets/mint_refresh.dart';
import 'package:mint/ui/widgets/pcl_hover.dart';
import 'package:mint/ui/widgets/version_card.dart' show VersionMenuAction;
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

/// 版本管理（不是下载）：HMCL「实例管理」/ FCL 版本列表布局。
///
///   左侧：游戏目录（HMCL 的 game directories / FCL 的 profile）
///   右侧：该目录下的版本号列表 + 搜索 + 加载器筛选
///
/// 点击目录切换当前游戏目录；点击版本设为启动版本；双击 / Enter 启动。
/// 键盘：↑↓ 选择、Enter 启动、F2 重命名、Delete 删除、Ctrl+F 搜索、F5 刷新。
class VersionManagerPage extends StatefulWidget {
  const VersionManagerPage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<VersionManagerPage> createState() => _VersionManagerPageState();
}

enum _DirectoryAction { activate, open, remove }

/// 推入版本管理页（主页 / 版本页的「管理」入口共用）。
void openVersionManager(BuildContext context, bool miuix) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => VersionManagerPage(miuix: miuix)),
  );
}

class _VersionManagerPageState extends State<VersionManagerPage> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _listFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// 手动刷新（顶栏按钮 / F5）走 MintRefreshView 的指示器。
  final MintRefreshController _refreshCtrl = MintRefreshController();

  int _filter = 0;
  int _focusIndex = 0;
  bool _switching = false;
  List<String> _visible = const [];

  static const _filters = ['全部', 'Fabric', 'Forge', 'NeoForge', '其他'];

  /// 已安装版本的分组（照下载游戏页的可折叠大卡）。
  /// 「可安装 Mod」= json 里识别出加载器的版本；没有加载器的按
  /// manifest type 分原版 / 快照 / 远古版。
  static const _groups = [
    (id: 'modded', label: '可安装 Mod', icon: 'grass'),
    (id: 'release', label: '原版', icon: 'grass'),
    (id: 'snapshot', label: '快照', icon: 'command_block'),
    (id: 'old', label: '远古版', icon: 'cobblestone'),
  ];

  /// 键盘上下选择时用来把当前行滚进可视区（分组卡片不是固定行高）。
  final Map<String, GlobalKey> _rowKeys = {};

  Map<String, ({String loader, String type, String mcVersion})> _metas(
    LauncherController controller,
    List<String> ids,
  ) => {for (final id in ids) id: controller.gameDir.metaOf(id)};

  String _groupOf(({String loader, String type, String mcVersion}) meta) {
    if (meta.loader.isNotEmpty) return 'modded';
    if (meta.type == 'snapshot') return 'snapshot';
    if (meta.type == 'old_alpha' || meta.type == 'old_beta') return 'old';
    return 'release';
  }

  String _mcLabel(
    String id,
    ({String loader, String type, String mcVersion}) meta,
  ) {
    if (meta.type == 'old_alpha') return '远古版 Alpha';
    if (meta.type == 'old_beta') return '远古版 Beta';
    if (meta.type == 'snapshot') return '快照';
    return 'Minecraft ${meta.mcVersion}';
  }

  /// 行副标题：MC / 类型 + 加载器 + 隔离 + 模组数。
  String _metaSubtitle(
    String id,
    ({String loader, String type, String mcVersion}) meta, {
    required bool isolated,
    required int mods,
  }) {
    final parts = <String>[_mcLabel(id, meta)];
    if (meta.loader.isNotEmpty) {
      parts.add(loaderLabelForVersion(id, loader: meta.loader));
    } else if (meta.type == 'release') {
      parts.add('原版');
    }
    if (isolated) parts.add('版本隔离');
    if (mods > 0) parts.add('$mods 个模组');
    return parts.join(' · ');
  }

  @override
  void initState() {
    super.initState();
    NavRequests.search.addListener(_onSearchRequest);
    NavRequests.refresh.addListener(_onRefreshRequest);
    _search.addListener(_onQueryChanged);
    _listFocus.addListener(_onListFocusChanged);
  }

  @override
  void dispose() {
    NavRequests.search.removeListener(_onSearchRequest);
    NavRequests.refresh.removeListener(_onRefreshRequest);
    _search.removeListener(_onQueryChanged);
    _search.dispose();
    _searchFocus.dispose();
    _listFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged() => setState(() {
    _focusIndex = 0;
  });

  void _onSearchRequest() {
    if (!mounted) return;
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  void _onRefreshRequest() => _reload();

  void _onListFocusChanged() {
    if (!_listFocus.hasFocus) return;
    final selected = activeVersionId(
      context.read<LauncherController>(),
      context.read<SettingsService>(),
    );
    final index = _visible.indexOf(selected ?? '');
    if (index >= 0 && index != _focusIndex) {
      setState(() => _focusIndex = index);
    }
  }

  Future<void> _reload() async {
    if (_switching) return;
    final controller = context.read<LauncherController>();
    setState(() => _switching = true);
    try {
      await controller.reloadGameDir();
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  List<String> _directories(
    SettingsService settings,
    LauncherController controller,
  ) {
    final dirs = [...settings.gameDirs];
    final active = controller.gameDir.root;
    if (!dirs.any((d) => p.equals(d, active))) dirs.insert(0, active);
    return dirs;
  }

  List<String> _filterVersions(
    List<String> ids,
    Map<String, ({String loader, String type, String mcVersion})> metas,
  ) {
    final query = _search.text.trim().toLowerCase();
    return [
      for (final id in ids)
        if ((query.isEmpty || id.toLowerCase().contains(query)) &&
            _matchesFilter(metas[id]?.loader ?? ''))
          id,
    ];
  }

  bool _matchesFilter(String loader) {
    final isFabric = loader == 'fabric';
    final isForge = loader == 'forge';
    final isNeoForge = loader == 'neoforge';
    return switch (_filter) {
      1 => isFabric,
      2 => isForge,
      3 => isNeoForge,
      4 => !isFabric && !isForge && !isNeoForge,
      _ => true,
    };
  }

  Future<void> _activateDir(String dir) async {
    final controller = context.read<LauncherController>();
    if (p.equals(dir, controller.gameDir.root)) return;
    setState(() => _switching = true);
    try {
      await controller.switchGameDir(dir);
      if (!mounted) return;
      _focusIndex = 0;
    } finally {
      if (mounted) setState(() => _switching = false);
    }
    if (mounted) _listFocus.requestFocus();
  }

  Future<void> _selectVersion(String id) async {
    final settings = context.read<SettingsService>();
    if (settings.selectedVersion != id) settings.selectedVersion = id;
    if (mounted) setState(() {});
  }

  Future<void> _launch(String dir, String id) async {
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    if (!p.equals(dir, controller.gameDir.root)) {
      await _activateDir(dir);
      if (!mounted) return;
    }
    await _selectVersion(id);
    if (!mounted) return;
    if (controller.runningVersion == id && controller.gamePid != null) {
      controller.stopGame();
      return;
    }
    await launchVersion(context, controller, settings, versionId: id);
  }

  List<({String id, String label, String icon, List<String> versions})>
  _groupVersions(
    List<String> filtered,
    Map<String, ({String loader, String type, String mcVersion})> metas,
  ) {
    return [
      for (final group in _groups)
        (
          id: group.id,
          label: group.label,
          icon: group.icon,
          versions: [
            for (final id in filtered)
              if (metas[id] != null && _groupOf(metas[id]!) == group.id) id,
          ],
        ),
    ].where((entry) => entry.versions.isNotEmpty).toList();
  }

  Widget _groupLeading(
    BuildContext context,
    String groupId,
    List<String> ids,
    Map<String, ({String loader, String type, String mcVersion})> metas,
  ) {
    if (groupId == 'modded') {
      final first = ids.first;
      return loaderIconAsset(
        loaderIconNameForVersion(first, loader: metas[first]?.loader),
        size: 26,
      );
    }
    if (groupId == 'release') {
      return loaderIconAsset('grass', size: 26);
    }
    if (groupId == 'snapshot') {
      return loaderIconAsset('command_block', size: 26);
    }
    return loaderIconAsset('cobblestone', size: 26);
  }

  Widget _versionGroups(
    BuildContext context,
    LauncherController controller,
    SettingsService settings,
    String activeDir,
    String? activeId,
    Map<String, ({String loader, String type, String mcVersion})> metas, {
    required bool compact,
  }) {
    final hasQuery = _search.text.trim().isNotEmpty;
    final groups = _groupVersions(_visible, metas);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in groups) ...[
          MintCollapsibleCard(
            key: ValueKey(
              'vm-${entry.id}-$hasQuery-${mintMiuixOf(context, widget.miuix)}',
            ),
            miuix: mintMiuixOf(context),
            title: entry.label,
            subtitle: '${entry.versions.length} 个版本',
            leading: _groupLeading(context, entry.id, entry.versions, metas),
            storageKey: hasQuery ? null : 'versionManager.${entry.id}',
            initiallyExpanded: true,
            children: compact
                ? [
                    for (var i = 0; i < entry.versions.length; i++)
                      _buildCompactVersionTile(
                        context,
                        controller,
                        settings,
                        entry.versions[i],
                        activeDir,
                        activeId,
                        metas[entry.versions[i]]!,
                        last: i == entry.versions.length - 1,
                      ),
                  ]
                : [
                    for (var i = 0; i < entry.versions.length; i++)
                      _buildVersionRow(
                        context,
                        controller,
                        settings,
                        entry.versions[i],
                        activeDir,
                        activeId,
                        metas[entry.versions[i]]!,
                        index: _visible.indexOf(entry.versions[i]),
                        cursor: _cursorIndex,
                        last: i == entry.versions.length - 1,
                      ),
                  ],
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  int _cursorIndex = -1;

  Future<void> _addDirectory() async {
    final path = await getDirectoryPath(confirmButtonText: '添加游戏目录');
    if (path == null || path.trim().isEmpty || !mounted) return;
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    settings.addGameDir(path);
    await controller.reloadGameDir();
    if (!mounted) return;
    final count = controller.gameDir.installedVersions().length;
    showMintSnack(
      context,
      count == 0
          ? '已添加目录，但里面还没有已安装版本'
          : '已添加目录：${settings.gameDirName(path)}（$count 个版本）',
    );
    setState(() {
      _focusIndex = 0;
      _search.clear();
    });
  }

  Future<void> _directoryMenu(String dir) async {
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    final dirs = _directories(settings, controller);
    final canRemove = dirs.length > 1;
    final isActive = p.equals(dir, controller.gameDir.root);
    final options = [
      if (!isActive)
        const MintChoice(
          value: _DirectoryAction.activate,
          label: '设为当前目录',
          subtitle: '之后启动 / 下载都使用这个目录',
          icon: Icons.check_circle_outline,
        ),
      const MintChoice(
        value: _DirectoryAction.open,
        label: '在文件管理器中打开',
        icon: Icons.folder_open,
      ),
      MintChoice(
        value: _DirectoryAction.remove,
        label: '从列表移除',
        subtitle: canRemove ? '不会删除磁盘上的文件' : '至少保留一个游戏目录',
        icon: Icons.remove_circle_outline,
        enabled: canRemove,
        destructive: true,
      ),
    ];
    final narrow = MediaQuery.sizeOf(context).width < 760;
    final action = narrow
        ? await showMintActionSheet<_DirectoryAction>(
            context,
            miuix: mintMiuixOf(context),
            title: settings.gameDirName(dir),
            options: options,
          )
        : await showMintChoiceDialog<_DirectoryAction>(
            context,
            miuix: mintMiuixOf(context),
            title: settings.gameDirName(dir),
            showCheck: false,
            options: options,
          );
    if (!mounted || action == null) return;
    switch (action) {
      case _DirectoryAction.activate:
        await _activateDir(dir);
      case _DirectoryAction.open:
        await controller.openInFileManager(dir);
      case _DirectoryAction.remove:
        final ok = await showMintConfirmDialog(
          context,
          miuix: mintMiuixOf(context),
          title: '移除目录？',
          message: '$dir\n\n只会从列表里移除，不会删除游戏文件。',
          confirmLabel: '移除',
          destructive: true,
        );
        if (!ok || !mounted) return;
        settings.removeGameDir(dir);
        await controller.reloadGameDir();
        if (mounted) setState(() => _focusIndex = 0);
    }
  }

  Future<void> _versionMenu(String dir, String id) async {
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    final action = await _chooseVersionAction(id);
    if (!mounted || action == null) return;
    if (!p.equals(dir, controller.gameDir.root)) {
      await _activateDir(dir);
      if (!mounted) return;
    }
    await _selectVersion(id);
    if (!mounted) return;
    await handleVersionMenu(
      context,
      controller,
      settings,
      id,
      action,
      miuix: mintMiuixOf(context),
    );
    if (mounted) setState(() {});
  }

  Future<VersionMenuAction?> _chooseVersionAction(String id) {
    final options = <MintChoice<VersionMenuAction>>[
      const MintChoice(
        value: VersionMenuAction.manage,
        label: '管理内容',
        subtitle: '模组 / 资源包 / 光影 / 存档',
        icon: Icons.inventory_2_outlined,
      ),
      const MintChoice(
        value: VersionMenuAction.settings,
        label: '版本设置',
        subtitle: '内存 / Java / 隔离 / 窗口',
        icon: Icons.tune,
      ),
      const MintChoice(
        value: VersionMenuAction.installLoader,
        label: '安装加载器 / OptiFine',
        subtitle: 'Fabric / Forge / NeoForge / Quilt',
        icon: Icons.extension_outlined,
      ),
      const MintChoice(
        value: VersionMenuAction.exportPack,
        label: '导出整合包',
        subtitle: 'CurseForge 格式 zip；OptiFine 因许可证不打包',
        icon: Icons.outbox_outlined,
      ),
      const MintChoice(
        value: VersionMenuAction.openFolder,
        label: '打开版本目录',
        icon: Icons.folder_open,
      ),
      const MintChoice(
        value: VersionMenuAction.rename,
        label: '重命名',
        icon: Icons.drive_file_rename_outline,
      ),
      const MintChoice(
        value: VersionMenuAction.copy,
        label: '复制版本',
        icon: Icons.copy_all_outlined,
      ),
      const MintChoice(
        value: VersionMenuAction.delete,
        label: '删除版本',
        subtitle: '删除 json / jar / natives',
        icon: Icons.delete_outline,
        destructive: true,
      ),
    ];
    final narrow = MediaQuery.sizeOf(context).width < 760;
    if (narrow) {
      return showMintActionSheet<VersionMenuAction>(
        context,
        miuix: mintMiuixOf(context),
        title: id,
        options: options,
      );
    }
    return showMintChoiceDialog<VersionMenuAction>(
      context,
      miuix: mintMiuixOf(context),
      title: id,
      showCheck: false,
      options: options,
    );
  }

  Future<void> _pickDirectory() async {
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    final dirs = _directories(settings, controller);
    final result = await showMintChoiceDialog<String>(
      context,
      miuix: mintMiuixOf(context),
      title: '游戏目录',
      showCheck: false,
      options: [
        for (final dir in dirs)
          MintChoice(
            value: dir,
            label: settings.gameDirName(dir),
            subtitle: '$dir · ${GameDir(dir).installedVersions().length} 个版本',
            icon: Icons.folder_outlined,
          ),
        const MintChoice(
          value: '__add__',
          label: '添加游戏目录…',
          icon: Icons.create_new_folder_outlined,
        ),
      ],
    );
    if (!mounted || result == null) return;
    if (result == '__add__') {
      await _addDirectory();
    } else {
      await _activateDir(result);
    }
  }

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ids = _visible;
    if (ids.isEmpty) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final next = (_focusIndex + delta).clamp(0, ids.length - 1);
      if (next != _focusIndex) {
        setState(() => _focusIndex = next);
        _selectVersion(ids[next]);
        _scrollTo(next);
      }
      return KeyEventResult.handled;
    }

    final current = ids[_focusIndex.clamp(0, ids.length - 1)];
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final controller = context.read<LauncherController>();
      _launch(controller.gameDir.root, current);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2) {
      final controller = context.read<LauncherController>();
      final settings = context.read<SettingsService>();
      renameVersionFlow(
        context,
        controller,
        settings,
        current,
        miuix: mintMiuixOf(context),
      ).then((_) {
        if (mounted) setState(() {});
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete) {
      final controller = context.read<LauncherController>();
      final settings = context.read<SettingsService>();
      deleteVersionFlow(
        context,
        controller,
        settings,
        current,
        miuix: mintMiuixOf(context),
      ).then((_) {
        if (mounted) setState(() {});
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _scrollTo(int index) {
    if (index < 0 || index >= _visible.length) return;
    final key = _rowKeys[_visible[index]];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        alignment: 0.5,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final settings = context.watch<SettingsService>();
    final dirs = _directories(settings, controller);
    final activeDir = controller.gameDir.root;
    final ids = controller.gameDir.installedVersions();
    final metas = _metas(controller, ids);
    _visible = _filterVersions(ids, metas);
    final activeId = activeVersionId(controller, settings);
    final selectedIndex = activeId == null ? -1 : _visible.indexOf(activeId);
    final cursor = _visible.isEmpty
        ? -1
        : (_listFocus.hasFocus
              ? _focusIndex.clamp(0, _visible.length - 1)
              : (selectedIndex >= 0 ? selectedIndex : 0));

    final counts = <String, int>{
      for (final dir in dirs) dir: GameDir(dir).installedVersions().length,
    };

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '版本管理',
      showBack: true,
      // 双栏 / 卡片布局不是整页滚动体，大标题折叠没有滚动体可记账；
      // 钉住小标题栏，渐变模糊带常驻，目录与版本列表都从栏下滚过。
      pinBar: true,
      actions: [
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: Icons.refresh,
          tooltip: '刷新（F5）',
          onPressed: _refreshCtrl.refresh,
        ),
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: Icons.download_outlined,
          tooltip: '下载新版本',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => VanillaVersionsPage(
                miuix: mintMiuixOf(context, widget.miuix),
              ),
            ),
          ),
        ),
      ],
      body: (padding) => Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, padding.top + 6, 16, 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 760;
                  if (!wide) {
                    return _buildCompactPage(
                      context,
                      settings,
                      controller,
                      activeDir,
                      ids,
                      activeId,
                      counts,
                      metas,
                    );
                  }
                  final versionPane = _buildVersionPane(
                    context,
                    settings,
                    controller,
                    activeDir,
                    ids,
                    activeId,
                    cursor,
                    metas,
                    wide: true,
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 左栏 = 可折叠的圆角卡片：默认展开，收起来只剩图标栏。
                      MintCollapsiblePane(
                        miuix: mintMiuixOf(context),
                        storageKey: 'versionManagerDirs',
                        title: '游戏目录',
                        titleIcon: Icon(
                          Icons.folder_outlined,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        expandedWidth: 272,
                        headerTrailing: MintTopBarAction(
                          miuix: mintMiuixOf(context),
                          icon: Icons.create_new_folder_outlined,
                          tooltip: '添加游戏目录',
                          onPressed: _addDirectory,
                        ),
                        child: _buildDirectoryList(
                          context,
                          settings,
                          controller,
                          dirs,
                          activeDir,
                          counts,
                        ),
                        collapsedChild: _buildDirectoryRail(
                          context,
                          settings,
                          controller,
                          dirs,
                          activeDir,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: versionPane),
                    ],
                  );
                },
              ),
            ),
          ),
          Positioned(
            right: 20,
            bottom: padding.bottom + 36,
            child: mintMiuixOf(context)
                ? MiuixFloatingActionButton(
                    onPressed: _addDirectory,
                    child: Icon(
                      Icons.create_new_folder_outlined,
                      size: 25,
                      color: MiuixTheme.of(context).colors.onPrimary,
                    ),
                  )
                : FloatingActionButton(
                    heroTag: 'version-add-dir-fab',
                    tooltip: '添加游戏目录',
                    onPressed: _addDirectory,
                    child: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 24,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── 左侧目录 ─────────────────────────

  /// 展开态：目录列表 + 底部「添加游戏目录」。卡面 / 标题 / 折叠按钮由
  /// [MintCollapsiblePane] 提供。
  Widget _buildDirectoryList(
    BuildContext context,
    SettingsService settings,
    LauncherController controller,
    List<String> dirs,
    String activeDir,
    Map<String, int> counts,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            children: [
              for (final dir in dirs) ...[
                _DirectoryTile(
                  miuix: mintMiuixOf(context),
                  name: settings.gameDirName(dir),
                  path: dir,
                  count: counts[dir] ?? 0,
                  selected: p.equals(dir, activeDir),
                  running:
                      controller.runningVersion != null &&
                      p.equals(dir, activeDir),
                  onTap: () => _activateDir(dir),
                  onMenu: () => _directoryMenu(dir),
                ),
                const SizedBox(height: 2),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MiuixHorizontalDivider(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 8),
              if (mintMiuixOf(context, widget.miuix))
                MiuixButton(
                  onPressed: _addDirectory,
                  cornerRadius: 14,
                  minHeight: 40,
                  insideMargin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add, size: 18),
                      SizedBox(width: 6),
                      Text('添加游戏目录', style: TextStyle(fontSize: 13.5)),
                    ],
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: _addDirectory,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加游戏目录'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 折叠态：只剩文件夹图标（选中项带底色），底部一个「+」。
  Widget _buildDirectoryRail(
    BuildContext context,
    SettingsService settings,
    LauncherController controller,
    List<String> dirs,
    String activeDir,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 2),
            children: [
              for (final dir in dirs)
                MintPaneRailButton(
                  tooltip: settings.gameDirName(dir),
                  selected: p.equals(dir, activeDir),
                  onTap: () => _activateDir(dir),
                  child: Icon(
                    p.equals(dir, activeDir)
                        ? Icons.folder_rounded
                        : Icons.folder_outlined,
                    size: 20,
                    color: p.equals(dir, activeDir)
                        ? cs.onPrimaryContainer
                        : cs.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: MintPaneRailButton(
            tooltip: '添加游戏目录',
            selected: false,
            onTap: _addDirectory,
            child: Icon(Icons.add, size: 20, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// 窄屏（手机 / 分屏）：和设置、画面比例等页面同一套页面式布局 ——
  /// 目录卡 → 区块标题 → 搜索 / 筛选 → 版本卡片，整页一起滚动。
  Widget _buildCompactPage(
    BuildContext context,
    SettingsService settings,
    LauncherController controller,
    String activeDir,
    List<String> allIds,
    String? activeId,
    Map<String, int> counts,
    Map<String, ({String loader, String type, String mcVersion})> metas,
  ) {
    final cs = Theme.of(context).colorScheme;
    final filtered = _visible;
    final dirName = settings.gameDirName(activeDir);
    final count = counts[activeDir] ?? allIds.length;

    final directoryCard = MintCard(
      miuix: mintMiuixOf(context),
      children: [
        MintTile(
          miuix: mintMiuixOf(context),
          icon: Icons.folder_outlined,
          title: dirName,
          subtitle: '$count 个版本',
          trailing: const Icon(Icons.unfold_more, size: 20),
          onTap: _pickDirectory,
        ),
        MintTile(
          miuix: mintMiuixOf(context),
          icon: Icons.create_new_folder_outlined,
          title: '添加游戏目录',
          subtitle: '选择已经装好 Minecraft 的目录',
          onTap: _addDirectory,
        ),
        MintTile(
          miuix: mintMiuixOf(context),
          icon: Icons.tune,
          title: '目录操作',
          subtitle: '在文件管理器中打开 / 从列表移除',
          showDivider: false,
          onTap: () => _directoryMenu(activeDir),
        ),
      ],
    );

    final List<Widget> versionContent;
    if (allIds.isEmpty) {
      versionContent = [
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: MintEmptyState(
            miuix: mintMiuixOf(context),
            icon: Icons.videogame_asset_off_outlined,
            title: '这个目录还没有版本',
            message: '下载一个原版或模组加载器版本，装好后会出现在这里。',
            action: MintPrimaryButton(
              miuix: mintMiuixOf(context),
              label: '下载 Minecraft',
              icon: Icons.download,
              expand: false,
              height: 46,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VanillaVersionsPage(
                    miuix: mintMiuixOf(context, widget.miuix),
                  ),
                ),
              ),
            ),
          ),
        ),
      ];
    } else if (filtered.isEmpty) {
      versionContent = [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 36),
          child: Column(
            children: [
              Icon(Icons.search_off, size: 40, color: cs.onSurfaceVariant),
              const SizedBox(height: 10),
              Text(
                '没有匹配的版本',
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              MintTextAction(
                miuix: mintMiuixOf(context),
                label: '清空搜索',
                onPressed: () => setState(() {
                  _search.clear();
                  _filter = 0;
                }),
              ),
            ],
          ),
        ),
      ];
    } else {
      versionContent = [
        _versionGroups(
          context,
          controller,
          settings,
          activeDir,
          activeId,
          metas,
          compact: true,
        ),
      ];
    }

    return MintRefreshView(
      miuix: mintMiuixOf(context),
      controller: _refreshCtrl,
      onRefresh: _reload,
      child: ListView(
        physics: kMintPageScrollPhysics,
        padding: const EdgeInsets.only(bottom: 110),
        children: [
          directoryCard,
          MintSectionHeader(
            miuix: mintMiuixOf(context),
            title: '已安装版本',
            trailing: Text(
              '$count 个',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): () {
                      if (_search.text.isNotEmpty) {
                        _search.clear();
                      } else {
                        FocusScope.of(context).unfocus();
                      }
                    },
                  },
                  child: MintSearchField(
                    miuix: mintMiuixOf(context),
                    hint: '搜索版本号',
                    controller: _search,
                    focusNode: _searchFocus,
                    onSubmitted: (_) => _searchFocus.unfocus(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (filtered.length != allIds.length)
                Text(
                  '${filtered.length} 个',
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: MintSegmentedTabs(
              miuix: mintMiuixOf(context),
              tabs: _filters,
              selected: _filter,
              onSelected: (i) => setState(() {
                _filter = i;
                _focusIndex = 0;
              }),
            ),
          ),
          if (_switching)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 3,
                  color: cs.primary,
                  backgroundColor: cs.primary.withValues(alpha: 0.12),
                ),
              ),
            ),
          const SizedBox(height: 10),
          ...versionContent,
        ],
      ),
    );
  }

  Widget _buildCompactVersionTile(
    BuildContext context,
    LauncherController controller,
    SettingsService settings,
    String id,
    String activeDir,
    String? activeId,
    ({String loader, String type, String mcVersion}) meta, {
    required bool last,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isolated = settings.effectiveFor(id).isolation;
    final mods = controller.gameDir.modsOf(id, isolated: isolated).length;
    final running =
        controller.gamePid != null && controller.runningVersion == id;
    final selected = id == activeId;
    final subtitle =
        '${_metaSubtitle(id, meta, isolated: isolated, mods: mods)}'
        '${running
            ? ' · 运行中'
            : selected
            ? ' · 当前版本'
            : ''}';

    final play = mintMiuixOf(context, widget.miuix)
        ? MiuixIconButton(
            onPressed: () => _launch(activeDir, id),
            minWidth: 38,
            minHeight: 38,
            child: Icon(
              running ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              size: 25,
              color: running ? cs.error : cs.primary,
            ),
          )
        : IconButton(
            onPressed: () => _launch(activeDir, id),
            tooltip: running ? '停止游戏' : '启动',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              running ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              size: 25,
              color: running ? cs.error : cs.primary,
            ),
          );
    final more = mintMiuixOf(context, widget.miuix)
        ? MiuixIconButton(
            onPressed: () => _versionMenu(activeDir, id),
            minWidth: 38,
            minHeight: 38,
            child: const Icon(Icons.more_vert, size: 20),
          )
        : IconButton(
            onPressed: () => _versionMenu(activeDir, id),
            tooltip: '更多',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_vert, size: 20),
          );

    return Container(
      color: selected ? cs.primary.withValues(alpha: 0.09) : null,
      child: MintTile(
        miuix: mintMiuixOf(context),
        leading: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: loaderIconAsset(
              loaderIconNameForVersion(id, loader: meta.loader),
              size: 34,
            ),
          ),
        ),
        title: id,
        subtitle: subtitle,
        showDivider: !last,
        onTap: () {
          _selectVersion(id);
          if (mounted) Navigator.of(context).maybePop();
        },
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [play, more]),
      ),
    );
  }

  // ───────────────────────── 右侧列表 ─────────────────────────

  Widget _buildVersionRow(
    BuildContext context,
    LauncherController controller,
    SettingsService settings,
    String id,
    String activeDir,
    String? activeId,
    ({String loader, String type, String mcVersion}) meta, {
    required int index,
    required int cursor,
    required bool last,
  }) {
    final isolated = settings.effectiveFor(id).isolation;
    final mods = controller.gameDir.modsOf(id, isolated: isolated).length;
    final running =
        controller.gamePid != null && controller.runningVersion == id;
    final selected = id == activeId;
    return _VersionRow(
      key: _rowKeys.putIfAbsent(id, () => GlobalKey()),
      miuix: mintMiuixOf(context),
      id: id,
      subtitle: _metaSubtitle(id, meta, isolated: isolated, mods: mods),
      iconName: loaderIconNameForVersion(id, loader: meta.loader),
      selected: selected,
      running: running,
      cursor: index == cursor && _listFocus.hasFocus,
      showDivider: !last,
      onTap: () {
        _listFocus.requestFocus();
        setState(() => _focusIndex = index);
        _selectVersion(id);
        // 选中即用（PCL 版本选择同款）：选完回主页，
        // 重命名 / 删除等管理操作走行内按钮或右键菜单。
        if (mounted) Navigator.of(context).maybePop();
      },
      onLaunch: () => _launch(activeDir, id),
      onSettings: () => openVersionSettings(context, mintMiuixOf(context), id),
      onMenu: () => _versionMenu(activeDir, id),
      onSecondary: () {
        _listFocus.requestFocus();
        setState(() => _focusIndex = index);
        _versionMenu(activeDir, id);
      },
    );
  }

  Widget _buildVersionPane(
    BuildContext context,
    SettingsService settings,
    LauncherController controller,
    String activeDir,
    List<String> allIds,
    String? activeId,
    int cursor,
    Map<String, ({String loader, String type, String mcVersion})> metas, {
    required bool wide,
  }) {
    final cs = Theme.of(context).colorScheme;
    final filtered = _visible;
    _cursorIndex = cursor;
    final filterTabs = Padding(
      padding: const EdgeInsets.only(top: 10),
      child: wide && mintMiuixOf(context, widget.miuix)
          ? Align(
              alignment: Alignment.centerLeft,
              child: MiuixTabRow(
                tabs: _filters,
                selectedTabIndex: _filter,
                onTabSelected: (i) => setState(() {
                  _filter = i;
                  _focusIndex = 0;
                }),
                contentAlignment: Alignment.centerLeft,
                colors: MiuixTabRowColors(
                  backgroundColor: MiuixTheme.of(
                    context,
                  ).colors.surfaceContainerHigh.withValues(alpha: 0.9),
                  contentColor: MiuixTheme.of(
                    context,
                  ).colors.onSurfaceVariantSummary,
                  selectedBackgroundColor: cs.primary,
                  selectedContentColor: cs.onPrimary,
                ),
              ),
            )
          : MintSegmentedTabs(
              miuix: mintMiuixOf(context),
              tabs: _filters,
              selected: _filter,
              onSelected: (i) => setState(() {
                _filter = i;
                _focusIndex = 0;
              }),
            ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): () {
                    if (_search.text.isNotEmpty) {
                      _search.clear();
                    } else {
                      FocusScope.of(context).unfocus();
                    }
                  },
                },
                child: MintSearchField(
                  miuix: mintMiuixOf(context),
                  hint: '搜索版本号',
                  controller: _search,
                  focusNode: _searchFocus,
                  onSubmitted: (_) => _applySearchFocus(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${filtered.length} 个',
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
            ),
          ],
        ),
        filterTabs,
        if (_switching)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 3,
                color: cs.primary,
                backgroundColor: cs.primary.withValues(alpha: 0.12),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6, left: 4, right: 4),
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  activeDir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: allIds.isEmpty
              ? _emptyDirectory(context)
              : filtered.isEmpty
              ? _noMatches(context)
              : MintRefreshView(
                  miuix: mintMiuixOf(context),
                  controller: _refreshCtrl,
                  onRefresh: _reload,
                  child: Focus(
                    focusNode: _listFocus,
                    onKeyEvent: _onListKey,
                    child: ListView(
                      controller: _scroll,
                      physics: kMintPageScrollPhysics,
                      padding: const EdgeInsets.only(bottom: 110),
                      children: [
                        _versionGroups(
                          context,
                          controller,
                          settings,
                          activeDir,
                          activeId,
                          metas,
                          compact: false,
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  void _applySearchFocus() {
    _searchFocus.unfocus();
    _listFocus.requestFocus();
  }

  Widget _emptyDirectory(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: MintEmptyState(
          miuix: mintMiuixOf(context),
          icon: Icons.videogame_asset_off_outlined,
          title: '这个目录还没有版本',
          message: '下载一个原版或模组加载器版本，装好后会出现在这里。',
          action: MintPrimaryButton(
            miuix: mintMiuixOf(context),
            label: '下载 Minecraft',
            icon: Icons.download,
            expand: false,
            height: 46,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => VanillaVersionsPage(
                  miuix: mintMiuixOf(context, widget.miuix),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _noMatches(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 40, color: cs.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(
              '没有匹配的版本',
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            MintTextAction(
              miuix: mintMiuixOf(context),
              label: '清空搜索',
              onPressed: () => setState(() {
                _search.clear();
                _filter = 0;
              }),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── 目录条目 ─────────────────────────

class _DirectoryTile extends StatefulWidget {
  const _DirectoryTile({
    required this.miuix,
    required this.name,
    required this.path,
    required this.count,
    required this.selected,
    required this.running,
    required this.onTap,
    required this.onMenu,
  });

  final bool miuix;
  final String name;
  final String path;
  final int count;
  final bool selected;
  final bool running;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  State<_DirectoryTile> createState() => _DirectoryTileState();
}

class _DirectoryTileState extends State<_DirectoryTile> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PclHoverSurface(
      onTap: widget.onTap,
      onSecondaryTap: widget.onMenu,
      borderRadius: 14,
      baseColor: widget.selected ? cs.primary.withValues(alpha: 0.12) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
        child: Row(
          children: [
            Icon(
              widget.selected ? Icons.folder : Icons.folder_outlined,
              size: 22,
              color: widget.selected ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: widget.selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (widget.running) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: cs.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.count} 个版本',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (mintMiuixOf(context, widget.miuix))
              MiuixIconButton(
                onPressed: widget.onMenu,
                minWidth: 34,
                minHeight: 34,
                child: const Icon(Icons.more_horiz, size: 19),
              )
            else
              IconButton(
                onPressed: widget.onMenu,
                tooltip: '目录操作',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_horiz, size: 19),
              ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── 版本条目 ─────────────────────────

class _VersionRow extends StatefulWidget {
  const _VersionRow({
    super.key,
    required this.miuix,
    required this.id,
    required this.subtitle,
    required this.iconName,
    required this.selected,
    required this.running,
    required this.cursor,
    required this.showDivider,
    required this.onTap,
    required this.onLaunch,
    required this.onSettings,
    required this.onMenu,
    required this.onSecondary,
  });

  final bool miuix;
  final String id;
  final String subtitle;
  final String iconName;
  final bool selected;
  final bool running;
  final bool cursor;
  final bool showDivider;
  final VoidCallback onTap;
  final VoidCallback onLaunch;
  final VoidCallback onSettings;
  final VoidCallback onMenu;
  final VoidCallback onSecondary;

  @override
  State<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<_VersionRow> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = loaderIconAsset(widget.iconName, size: 32);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: PclHoverSurface(
            onTap: widget.onTap,
            onDoubleTap: widget.onLaunch,
            onSecondaryTap: widget.onSecondary,
            borderRadius: 16,
            ripple: !mintMiuixOf(context),
            baseColor: widget.selected
                ? cs.primary.withValues(alpha: 0.10)
                : null,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: widget.cursor
                      ? cs.primary.withValues(alpha: 0.65)
                      : Colors.transparent,
                  width: 1.2,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 3.5,
                    height: 34,
                    margin: const EdgeInsets.only(left: 3),
                    decoration: BoxDecoration(
                      color: widget.selected ? cs.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 11),
                  SizedBox(width: 42, height: 42, child: Center(child: icon)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.id,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (widget.selected) ...[
                              const SizedBox(width: 8),
                              _Badge(
                                label: widget.running ? '运行中' : '当前',
                                color: cs.primary,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _rowAction(
                    tooltip: widget.running ? '停止游戏' : '启动',
                    icon: widget.running
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                    color: widget.running ? cs.error : cs.primary,
                    size: 25,
                    onPressed: widget.onLaunch,
                  ),
                  _rowAction(
                    tooltip: '版本设置',
                    icon: Icons.tune,
                    size: 19,
                    onPressed: widget.onSettings,
                  ),
                  _rowAction(
                    tooltip: '更多',
                    icon: Icons.more_vert,
                    size: 19,
                    onPressed: widget.onMenu,
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
        ),
        if (widget.showDivider)
          Divider(
            height: 1,
            indent: 58,
            endIndent: 12,
            color: cs.outlineVariant.withValues(alpha: 0.35),
          ),
      ],
    );
  }

  Widget _rowAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    Color? color,
    double size = 20,
  }) {
    if (mintMiuixOf(context, widget.miuix)) {
      return MiuixIconButton(
        onPressed: onPressed,
        minWidth: 36,
        minHeight: 36,
        child: Icon(icon, size: size, color: color),
      );
    }
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: size, color: color),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

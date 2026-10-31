import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/manifest.dart';
import 'package:mint/services/launcher/modloader.dart';
import 'package:mint/services/launcher/optifine.dart';
import 'package:mint/services/settings_service.dart';

import 'common.dart';
import 'loader_install_page.dart';
import 'shared_actions.dart';
import '../widgets/mint_page.dart';
import '../widgets/mint_refresh.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

/// 一键安装页（HMCL / FCL 的「安装游戏」流程）：
///
///  1. 先选 Minecraft 版本（含已安装版本，原版本体缺了会自动补装）；
///  2. 预取该版本可用的加载器（Fabric / Quilt / Forge / NeoForge），
///     规则不支持或构建列表为空的加载器不显示；
///  3. 加载器单选（× 取消），可选 OptiFine 叠加，点右下角 FAB 开始安装。
class GameInstallPage extends StatefulWidget {
  const GameInstallPage({
    super.key,
    required this.miuix,
    this.initialVersion,
    this.initialLoader,
  });

  final bool miuix;

  /// 从原版列表进来时预填的版本。
  final String? initialVersion;

  /// 从下载中心的加载器入口进来时预选的加载器。
  final ModLoader? initialLoader;

  @override
  State<GameInstallPage> createState() => _GameInstallPageState();
}

class _GameInstallPageState extends State<GameInstallPage> {
  /// 从原版列表进来时预填的版本；从下载中心进来时预选的加载器。
  String? _game;
  ModLoader? _loader;

  LoaderCatalog? _catalog;
  int _catalogToken = 0;

  LoaderVersionInfo? _build;
  bool _optifine = false;
  OptiFineEntry? _optifineEntry;

  final MintRefreshController _refreshCtrl = MintRefreshController();

  @override
  void initState() {
    super.initState();
    _game = widget.initialVersion;
    _loader = widget.initialLoader;
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  String get _gameId => _game ?? '';

  Future<void> _bootstrap() async {
    if (!mounted) return;
    final controller = context.read<LauncherController>();
    final VersionManifest manifest;
    try {
      manifest = await controller.ensureManifest();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (_game == null || manifest.find(_game!) == null) {
      final settings = context.read<SettingsService>();
      final active = activeVersionId(controller, settings);
      final mc = active == null
          ? manifest.latest.release
          : controller.gameDir.mcVersionOf(active);
      setState(() {
        _game = manifest.find(mc) != null ? mc : manifest.latest.release;
      });
    }
    await _prefetch(controller);
  }

  // ───────────────────────── 数据加载 ─────────────────────────

  Future<void> _refresh() async {
    final controller = context.read<LauncherController>();
    if (_gameId.isEmpty) {
      await controller.ensureManifest(force: true);
      return;
    }
    await _prefetch(controller, force: true);
  }

  /// 并发预取当前 MC 版本所有加载器构建 + OptiFine，并按游戏版本缓存。
  Future<void> _prefetch(
    LauncherController controller, {
    bool force = false,
  }) async {
    final game = _gameId;
    if (game.isEmpty) return;
    final existing = _catalog;
    if (!force && existing != null && existing.game == game) return;
    final type = controller.manifest?.find(game)?.type ?? 'release';
    final catalog = LoaderCatalog(
      controller: controller,
      game: game,
      mcType: type,
    );
    final token = ++_catalogToken;
    setState(() {
      _catalog = catalog;
      if (_loader != null && !catalog.supports(_loader!)) {
        _loader = null;
        _build = null;
      }
    });
    await catalog.prefetch(
      onUpdate: () {
        if (!mounted || token != _catalogToken) return;
        setState(_reconcile);
      },
    );
    if (!mounted || token != _catalogToken) return;
    setState(_reconcile);
  }

  /// 预取结果 → 修正选中项：不可用就清掉，构建列表变化时重选默认构建。
  void _reconcile() {
    final catalog = _catalog;
    if (catalog == null) return;
    final loader = _loader;
    if (loader != null) {
      if (!catalog.supports(loader)) {
        _loader = null;
        _build = null;
      } else if (catalog.errors.containsKey(loader)) {
        _build = null;
      } else if (catalog.builds.containsKey(loader)) {
        final list = catalog.builds[loader]!;
        if (list.isEmpty) {
          _loader = null;
          _build = null;
        } else if (_build == null ||
            !list.any((v) => v.version == _build!.version)) {
          _build = list.first;
        }
      }
    }
    if (_optifine) {
      if (catalog.optifineError != null) {
        _optifineEntry = null;
      } else if (catalog.optifine != null) {
        final list = catalog.optifine!;
        if (list.isEmpty) {
          _optifine = false;
          _optifineEntry = null;
        } else if (_optifineEntry == null ||
            !list.any((e) => e.filename == _optifineEntry!.filename)) {
          _optifineEntry = list.first;
        }
      }
    }
  }

  Future<void> _changeGame(LauncherController controller, String game) async {
    if (game == _gameId) return;
    setState(() {
      _game = game;
      _loader = null;
      _build = null;
      _optifine = false;
      _optifineEntry = null;
      _catalog = null;
      _catalogToken++;
    });
    await _prefetch(controller, force: true);
  }

  void _selectLoader(ModLoader? loader) {
    if (_loader == loader) return;
    final list = loader == null
        ? const <LoaderVersionInfo>[]
        : _catalog?.buildsOf(loader) ?? const <LoaderVersionInfo>[];
    setState(() {
      _loader = loader;
      _build = list.isEmpty ? null : list.first;
    });
  }

  void _selectOptifine(bool enabled) {
    if (_optifine == enabled) return;
    final list = _catalog?.optifineEntries ?? const <OptiFineEntry>[];
    setState(() {
      _optifine = enabled;
      _optifineEntry = enabled && list.isNotEmpty ? list.first : null;
    });
  }

  void _retryLoader(ModLoader loader) {
    final catalog = _catalog;
    if (catalog == null) return;
    unawaited(
      catalog.fetch(
        loader,
        onUpdate: () {
          if (!mounted || !identical(_catalog, catalog)) return;
          setState(_reconcile);
        },
      ),
    );
  }

  void _retryOptifine() {
    final catalog = _catalog;
    if (catalog == null) return;
    unawaited(
      catalog.fetchOptifine(
        onUpdate: () {
          if (!mounted || !identical(_catalog, catalog)) return;
          setState(_reconcile);
        },
      ),
    );
  }

  /// 当前选择是否可安装（纯原版没有构建要求）。
  bool get _hasInstallSelection {
    final catalog = _catalog;
    final loader = _loader;
    if (loader != null) {
      final build = _build;
      if (catalog == null || build == null) return false;
      return catalog.buildsOf(loader).any((v) => v.version == build.version);
    }
    if (_optifine) {
      final entry = _optifineEntry;
      if (catalog == null || entry == null) return false;
      return catalog.optifineEntries.any((e) => e.filename == entry.filename);
    }
    return true;
  }

  // ───────────────────────── 构建 ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final manifest = controller.manifest;
    final busy = controller.isPreparing;

    if (manifest == null || _game == null) {
      return MintPageScaffold(
        miuix: mintMiuixOf(context),
        title: '安装游戏',
        showBack: true,
        body: (padding) => Padding(
          padding: padding,
          child: const Center(
            child: SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ),
        ),
      );
    }

    final installed = controller.gameDir.installedVersions().toSet();
    final gameType = manifest.find(_gameId)?.type ?? 'release';
    final gameIcon = blockIconForManifestType(gameType);
    final catalog = _catalog;
    final availableLoaders = [
      if (catalog != null)
        for (final loader in ModLoader.values)
          if (catalog.available(loader)) loader,
    ];
    final optifineAvailable = catalog?.optifineAvailable ?? false;
    final fab = InstallFab(
      miuix: mintMiuixOf(context),
      label: _installLabel,
      onPressed: busy || !_hasInstallSelection
          ? null
          : () => _startInstall(controller),
    );

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '安装 $_gameId',
      showBack: true,
      actions: [
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: Icons.refresh,
          tooltip: '刷新版本列表',
          onPressed: _refreshCtrl.refresh,
        ),
      ],
      floatingActionButton: mintMiuixOf(context, widget.miuix) ? fab : null,
      body: (padding) {
        final content = MintRefreshView(
          miuix: mintMiuixOf(context),
          controller: _refreshCtrl,
          topInset: padding.top,
          onRefresh: _refresh,
          child: ListView(
            physics: kMintPageScrollPhysics,
            padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              // ── 目标 Minecraft 版本 ──
              MintCard(
                miuix: mintMiuixOf(context),
                children: [
                  MintTile(
                    miuix: mintMiuixOf(context),
                    leading: loaderIconAsset(gameIcon, size: 28),
                    title: _gameId,
                    subtitle: installed.contains(_gameId) ? '已安装' : '未安装',
                    showDivider: false,
                    onTap: () async {
                      final installedIds = controller.gameDir
                          .installedVersions();
                      final installedSet = installedIds.toSet();
                      final picked = await showGameVersionPickerSheet(
                        context,
                        miuix: mintMiuixOf(context),
                        ids: [
                          ...installedIds,
                          for (final v in manifest.versions)
                            if (!installedSet.contains(v.id)) v.id,
                        ],
                        installed: installedSet,
                        current: _gameId,
                        types: {
                          for (final v in manifest.versions) v.id: v.type,
                        },
                      );
                      if (picked != null && mounted) {
                        _changeGame(controller, picked);
                      }
                    },
                    trailing: Icon(
                      Icons.expand_more,
                      size: 22,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),

              // ── 模组加载器（只显示可用的）──
              MintSectionHeader(miuix: mintMiuixOf(context), title: '模组加载器'),
              if (catalog == null ||
                  (catalog.isLoading && availableLoaders.isEmpty))
                LoaderLoadingCard(miuix: mintMiuixOf(context, widget.miuix))
              else if (availableLoaders.isEmpty)
                MintEmptyState(
                  miuix: mintMiuixOf(context),
                  icon: Icons.extension_off_outlined,
                  title: '该版本没有可用的加载器',
                )
              else
                MintCard(
                  miuix: mintMiuixOf(context),
                  children: [
                    for (final (i, loader) in availableLoaders.indexed)
                      _LoaderChoiceRow(
                        miuix: mintMiuixOf(context),
                        loader: loader,
                        selected: _loader == loader,
                        showDivider: i != availableLoaders.length - 1,
                        onTap: () => _selectLoader(loader),
                        onClear: () => _selectLoader(null),
                      ),
                  ],
                ),
              if (catalog != null &&
                  catalog.isLoading &&
                  availableLoaders.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '正在获取加载器…',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_loader != null) ...[
                const SizedBox(height: 10),
                _BuildCard(
                  miuix: mintMiuixOf(context),
                  icon: loaderIconAsset(_loader!.id, size: 24),
                  title: '${_loader!.label} 构建',
                  loading: catalog?.loading.contains(_loader!) ?? true,
                  error: catalog?.errors[_loader!],
                  entries:
                      (catalog?.buildsOf(_loader!) ??
                              const <LoaderVersionInfo>[])
                          .map(
                            (v) => (label: v.displayLabel, value: v as Object),
                          )
                          .toList(),
                  selectedLabel: _build?.displayLabel,
                  onRetry: () => _retryLoader(_loader!),
                  onPick: (v) =>
                      setState(() => _build = v as LoaderVersionInfo),
                ),
              ],

              // ── OptiFine（有构建才显示，可与加载器叠加）──
              if (optifineAvailable) ...[
                MintSectionHeader(
                  miuix: mintMiuixOf(context),
                  title: 'OptiFine',
                ),
                MintCard(
                  miuix: mintMiuixOf(context),
                  children: [
                    _OptifineChoiceRow(
                      miuix: mintMiuixOf(context),
                      selected: _optifine,
                      showDivider: false,
                      onTap: () => _selectOptifine(true),
                      onClear: () => _selectOptifine(false),
                    ),
                  ],
                ),
              ],
              if (_optifine) ...[
                const SizedBox(height: 10),
                _BuildCard(
                  miuix: mintMiuixOf(context),
                  icon: loaderIconAsset('optifine', size: 24),
                  title: 'OptiFine 构建',
                  loading: catalog?.optifineLoading ?? true,
                  error: catalog?.optifineError,
                  entries: (catalog?.optifineEntries ?? const <OptiFineEntry>[])
                      .map((e) => (label: e.displayLabel, value: e as Object))
                      .toList(),
                  selectedLabel: _optifineEntry?.displayLabel,
                  onRetry: _retryOptifine,
                  onPick: (v) =>
                      setState(() => _optifineEntry = v as OptiFineEntry),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        );
        if (mintMiuixOf(context, widget.miuix)) return content;
        return Stack(
          children: [
            Positioned.fill(child: content),
            Positioned(
              right: 16,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              child: fab,
            ),
          ],
        );
      },
    );
  }

  String get _installLabel {
    final parts = <String>[
      if (_loader != null) _loader!.label,
      if (_optifine) 'OptiFine',
    ];
    if (parts.isEmpty) return '安装 $_gameId';
    return '安装 $_gameId + ${parts.join(' + ')}';
  }

  Future<void> _startInstall(LauncherController controller) async {
    final loader = _loader;
    final build = _build;
    final optifineEntry = _optifine ? _optifineEntry : null;
    if (!_hasInstallSelection) {
      if (loader != null) {
        showMintSnack(context, '$_gameId 没有可用的 ${loader.label}');
      } else if (_optifine) {
        showMintSnack(context, '$_gameId 没有可用的 OptiFine');
      } else {
        showMintSnack(context, '请选择可用的构建');
      }
      return;
    }

    final target = _gameId;
    final root = controller.gameDir.root;
    final parts = <String>[
      if (loader != null) loader.label,
      if (optifineEntry != null) 'OptiFine',
    ];

    await runInstallTask(
      context,
      title: parts.isEmpty
          ? '安装 Minecraft $target'
          : '安装 $target + ${parts.join(' + ')}',
      task: () async {
        var base = target;
        if (loader != null && build != null) {
          final before = controller.gameDir.installedVersions().toSet();
          await controller.installModloader(
            loader,
            target,
            build.version,
            root,
          );
          final expected = ModloaderService.versionIdFor(
            loader,
            target,
            build.version,
          );
          final installedNow = controller.gameDir.installedVersions();
          if (installedNow.contains(expected)) {
            base = expected;
          } else {
            final newIds = [
              for (final id in installedNow)
                if (!before.contains(id)) id,
            ];
            base = newIds.isEmpty
                ? target
                : newIds.firstWhere(
                    (id) => id.toLowerCase().contains(loader.id),
                    orElse: () => newIds.first,
                  );
          }
        } else {
          // 纯原版 / 仅 OptiFine：本体就是全部（OptiFine 部分由
          // installOptifine 处理）。
          await controller.installOnly(target);
        }
        if (optifineEntry != null) {
          final id = await controller.installOptifine(
            optifineEntry,
            base,
            root,
          );
          return id.isEmpty ? base : id;
        }
        return base;
      },
    );
  }
}

// ───────────────────────── 选择行 / 构建卡 ─────────────────────────

/// 加载器选择行：选中态带 × 取消；只展示当前版本可用的加载器。
class _LoaderChoiceRow extends StatelessWidget {
  const _LoaderChoiceRow({
    required this.miuix,
    required this.loader,
    required this.selected,
    required this.showDivider,
    required this.onTap,
    required this.onClear,
  });

  final bool miuix;
  final ModLoader loader;
  final bool selected;
  final bool showDivider;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final row = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          child: Row(
            children: [
              loaderIconAsset(loader.id, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  loader.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ),
              if (selected) ...[
                SizedBox(
                  width: 34,
                  height: 34,
                  child: IconButton(
                    tooltip: '取消选择 ${loader.label}',
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    onPressed: onClear,
                    icon: Icon(Icons.cancel, color: cs.primary),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _RadioMark(selected: selected),
            ],
          ),
        ),
      ),
    );
    if (!showDivider) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        Divider(
          height: 1,
          indent: 54,
          endIndent: 16,
          color: cs.outlineVariant.withValues(alpha: 0.4),
        ),
      ],
    );
  }
}

/// OptiFine 行：可叠在原版或已选加载器之上（Fabric 上需 OptiFabric 模组）。
class _OptifineChoiceRow extends StatelessWidget {
  const _OptifineChoiceRow({
    required this.miuix,
    required this.selected,
    required this.showDivider,
    required this.onTap,
    required this.onClear,
  });

  final bool miuix;
  final bool selected;
  final bool showDivider;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final row = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: selected ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          child: Row(
            children: [
              loaderIconAsset('optifine', size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'OptiFine',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ),
              if (selected) ...[
                SizedBox(
                  width: 34,
                  height: 34,
                  child: IconButton(
                    tooltip: '取消选择 OptiFine',
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    onPressed: onClear,
                    icon: Icon(Icons.cancel, color: cs.primary),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _RadioMark(selected: selected),
            ],
          ),
        ),
      ),
    );
    if (!showDivider) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        Divider(
          height: 1,
          indent: 54,
          endIndent: 16,
          color: cs.outlineVariant.withValues(alpha: 0.4),
        ),
      ],
    );
  }
}

class _RadioMark extends StatelessWidget {
  const _RadioMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const size = 22.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          width: selected ? 2 : 1.6,
          color: selected ? cs.primary : cs.outlineVariant,
        ),
      ),
      child: selected
          ? Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.primary,
              ),
            )
          : null,
    );
  }
}

/// 加载器 / OptiFine 的构建版本卡：loading / 失败重试 / 空列表 / 选择构建。
class _BuildCard extends StatelessWidget {
  const _BuildCard({
    required this.miuix,
    required this.icon,
    required this.title,
    required this.loading,
    required this.error,
    required this.entries,
    required this.selectedLabel,
    required this.onRetry,
    required this.onPick,
  });

  final bool miuix;
  final Widget icon;
  final String title;
  final bool loading;
  final String? error;

  /// (展示名, 值) 对；值是 LoaderVersionInfo / OptiFineEntry。
  final List<({String label, Object value})> entries;
  final String? selectedLabel;
  final VoidCallback onRetry;
  final ValueChanged<Object> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (loading) {
      return MintCard(
        miuix: miuix,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '获取 $title…',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    if (error != null) {
      return MintCard(
        miuix: miuix,
        children: [
          MintTile(
            miuix: miuix,
            icon: Icons.cloud_off,
            title: '获取$title失败',
            showDivider: false,
            trailing: MintSecondaryButton(
              miuix: miuix,
              label: '重试',
              onPressed: onRetry,
            ),
          ),
        ],
      );
    }
    if (entries.isEmpty) {
      return MintCard(
        miuix: miuix,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Text(
              '没有可用的$title',
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      );
    }
    final current = selectedLabel ?? entries.first.label;
    return MintCard(
      miuix: miuix,
      children: [
        MintTile(
          miuix: miuix,
          leading: icon,
          title: title,
          subtitle: '$current · 共 ${entries.length} 个',
          showDivider: false,
          trailing: Icon(
            Icons.expand_more,
            size: 22,
            color: cs.onSurfaceVariant,
          ),
          onTap: () async {
            final picked = await showModalBottomSheet<Object>(
              context: context,
              showDragHandle: true,
              builder: (sheetContext) => SafeArea(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 460),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      return ListTile(
                        leading: icon,
                        title: Text(e.label),
                        trailing: e.label == current
                            ? Icon(
                                Icons.check,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                        onTap: () => Navigator.pop(sheetContext, e.value),
                      );
                    },
                  ),
                ),
              ),
            );
            if (picked != null) onPick(picked);
          },
        ),
      ],
    );
  }
}

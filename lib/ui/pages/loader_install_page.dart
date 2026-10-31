import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/modloader.dart';
import 'package:mint/services/launcher/modrinth.dart' show resolveMcVersion;
import 'package:mint/services/launcher/optifine.dart';
import 'package:mint/services/settings_service.dart';

import 'common.dart';
import '../widgets/mint_page.dart';
import '../widgets/mint_refresh.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

// ───────────────────────── 加载器目录（安装页 / 补装页共用）─────────────────────────

/// 某个 Minecraft 版本可用的加载器构建目录。
///
/// 只记录「规则支持」的加载器构建；页面据此决定是否展示对应行：
/// 规则不支持或构建列表为空都不显示（不是禁用 + 原因）。
class LoaderCatalog {
  LoaderCatalog({
    required this.controller,
    required this.game,
    required this.mcType,
  });

  final LauncherController controller;
  final String game;

  /// manifest 里的版本类型（release / snapshot / old_beta / old_alpha）。
  final String mcType;

  final Map<ModLoader, List<LoaderVersionInfo>> builds = {};
  final Map<ModLoader, String> errors = {};
  final Set<ModLoader> loading = {};

  List<OptiFineEntry>? optifine;
  String? optifineError;
  bool optifineLoading = false;

  bool get isLoading => loading.isNotEmpty || optifineLoading;

  bool get optifineAvailable => optifine?.isNotEmpty ?? false;

  List<OptiFineEntry> get optifineEntries => optifine ?? const [];

  bool get hasAny => ModLoader.values.any(available) || optifineAvailable;

  bool supports(ModLoader loader) =>
      LoaderCompat.supports(loader, game, mcType);

  bool available(ModLoader loader) => builds[loader]?.isNotEmpty ?? false;

  List<LoaderVersionInfo> buildsOf(ModLoader loader) =>
      builds[loader] ?? const [];

  /// 并发预取该版本所有规则支持的加载器 + OptiFine。
  Future<void> prefetch({VoidCallback? onUpdate}) {
    final tasks = <Future<void>>[
      for (final loader in ModLoader.values)
        if (supports(loader)) fetch(loader, onUpdate: onUpdate),
    ];
    tasks.add(fetchOptifine(onUpdate: onUpdate));
    return Future.wait(tasks);
  }

  Future<void> fetch(ModLoader loader, {VoidCallback? onUpdate}) async {
    if (loading.contains(loader)) return;
    loading.add(loader);
    builds.remove(loader);
    errors.remove(loader);
    onUpdate?.call();
    final dl = controller.newDownloaderForModloader();
    try {
      final service = ModloaderService(
        gameDir: controller.gameDir,
        downloader: dl,
      );
      final list = await switch (loader) {
        ModLoader.forge => service.forgeVersions(game),
        ModLoader.neoforge => service.neoforgeVersions(game),
        ModLoader.fabric => service.fabricVersions(game),
        ModLoader.quilt => service.quiltVersions(game),
      };
      builds[loader] = list;
    } catch (e) {
      errors[loader] = '$e';
      controller.log('❌ 获取 ${loader.label} 版本列表失败：$e');
    } finally {
      loading.remove(loader);
      dl.close();
      onUpdate?.call();
    }
  }

  Future<void> fetchOptifine({VoidCallback? onUpdate}) async {
    if (optifineLoading) return;
    optifineLoading = true;
    optifine = null;
    optifineError = null;
    onUpdate?.call();
    final dl = controller.newDownloaderForModloader();
    try {
      final all = await OptiFineService(
        gameDir: controller.gameDir,
        downloader: dl,
      ).versions();
      final mc = resolveMcVersion(controller.gameDir, game) ?? game;
      optifine = [
        for (final e in all)
          if (e.mcVersion == mc) e,
      ];
    } catch (e) {
      optifineError = '$e';
      controller.log('❌ 获取 OptiFine 版本列表失败：$e');
    } finally {
      optifineLoading = false;
      dl.close();
      onUpdate?.call();
    }
  }
}

/// PCL2 同款加载器兼容规则（规则不支持时连行都不显示）。
class LoaderCompat {
  LoaderCompat._();

  static bool supports(ModLoader loader, String game, String type) {
    if (type == 'old_beta' || type == 'old_alpha') return false;
    return switch (loader) {
      // Forge 只处理标准正式版（PCL 的 IsStandardFormat）。
      ModLoader.forge => type == 'release',
      ModLoader.neoforge => _isAtLeastPatch(game, 20, 2),
      ModLoader.fabric || ModLoader.quilt => _isAtLeastMinor(game, 14),
    };
  }

  /// `1.20.4` / `24w13a` / `1.21.4-rc1` → 主次版本号比较。
  /// 周快照 `YYwWW`：18w43a 起是 1.14 纪元，粗略映射到 1.x minor，
  /// 够判「早期版本不可用」。
  static (int, int) _versionPair(String id) {
    final base = id.split(RegExp('[-+]')).first.trim();
    final weekly = RegExp(r'^(\d\d)w(\d+)').firstMatch(base);
    if (weekly != null) {
      final yy = int.tryParse(weekly.group(1)!) ?? 25;
      const era = {
        18: 14,
        19: 15,
        20: 16,
        21: 17,
        22: 19,
        23: 20,
        24: 21,
        25: 21,
        26: 22,
      };
      var minor = era[yy] ?? (yy >= 27 ? 23 : 13);
      // 18w43a 之前的快照不属于 1.14 纪元。
      final ww = int.tryParse(weekly.group(2)!) ?? 0;
      if (yy == 18 && ww < 43) minor = 13;
      return (1, minor);
    }
    final m = RegExp(r'^1\.(\d+)(?:\.(\d+))?').firstMatch(base);
    if (m == null) return (1, 99); // 认不出来就交给数据源兜底
    return (1, int.tryParse(m.group(1)!) ?? 0);
  }

  static int _minorOf(String id) => _versionPair(id).$2;

  static bool _isAtLeastMinor(String id, int minor) => _minorOf(id) >= minor;

  static bool _isAtLeastPatch(String id, int minor, int patch) {
    final base = id.split(RegExp('[-+]')).first.trim();
    if (RegExp(r'^\d\dw\d+').hasMatch(base)) return _minorOf(id) >= minor;
    final m = RegExp(r'^1\.(\d+)(?:\.(\d+))?').firstMatch(base);
    if (m == null) return true;
    final maj = int.tryParse(m.group(1)!) ?? 0;
    final p = int.tryParse(m.group(2) ?? '0') ?? 0;
    if (maj > minor) return true;
    if (maj < minor) return false;
    return p >= patch;
  }
}

// ───────────────────────── 共用小部件 ─────────────────────────

/// 右下角安装 FAB（miuix 用 Miuix 组件，Material 用 extended FAB）。
class InstallFab extends StatelessWidget {
  const InstallFab({
    super.key,
    required this.miuix,
    required this.label,
    required this.onPressed,
    this.icon = Icons.download,
  });

  final bool miuix;
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final bg = enabled ? cs.primary : cs.primary.withValues(alpha: 0.45);
    final fg = enabled ? cs.onPrimary : cs.onPrimary.withValues(alpha: 0.75);
    final text = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14.5,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
    if (miuix) {
      return MiuixFloatingActionButton(
        onPressed: onPressed,
        containerColor: bg,
        shadowElevation: enabled ? 6 : 2,
        minHeight: 52,
        shape: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: 8),
              text,
            ],
          ),
        ),
      );
    }
    return FloatingActionButton.extended(
      heroTag: null,
      onPressed: onPressed,
      backgroundColor: bg,
      foregroundColor: fg,
      elevation: enabled ? 4 : 0,
      extendedPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      icon: Icon(icon, size: 20),
      label: text,
    );
  }
}

/// 轻量加载卡：拉取可用加载器时用，不露出任何不可用行。
class LoaderLoadingCard extends StatelessWidget {
  const LoaderLoadingCard({
    super.key,
    required this.miuix,
    this.label = '正在获取可用的加载器…',
  });

  final bool miuix;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MintCard(
      miuix: miuix,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── 补装加载器页 ─────────────────────────

/// 给已安装版本补装加载器 / OptiFine（HMCL 下载加载器页同思路）：
///
///  · 进入后解析目标版本的 Minecraft 版本，只列该版本可用的加载器；
///  · 选中加载器后在同一页展示可用构建（默认推荐 / 最新）；
///  · 点 FAB 先返回上一级，再转后台安装并自动选中新版本。
class LoaderInstallPage extends StatefulWidget {
  const LoaderInstallPage({
    super.key,
    required this.miuix,
    required this.versionId,
  });

  final bool miuix;
  final String versionId;

  @override
  State<LoaderInstallPage> createState() => _LoaderInstallPageState();
}

class _LoaderInstallPageState extends State<LoaderInstallPage> {
  String? _mc;
  String? _error;
  LoaderCatalog? _catalog;
  int _catalogToken = 0;

  ModLoader? _loader;
  LoaderVersionInfo? _build;
  bool _optifine = false;
  OptiFineEntry? _optifineEntry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    final controller = context.read<LauncherController>();
    final mc = resolveMcVersion(controller.gameDir, widget.versionId);
    if (mc == null || mc.isEmpty) {
      setState(() => _error = '无法确定 Minecraft 版本');
      return;
    }
    setState(() => _mc = mc);
    // manifest 只用于 Forge 的「是否正式版」判定；不要让它把加载器列表
    // 堵在 loading（Mojang 清单偶尔很慢）。先按版本 id 形态兜底开拉，
    // manifest 到了且类型判定不同再强制刷新一次目录。
    unawaited(
      controller
          .ensureManifest()
          .then((_) {
            if (!mounted) return;
            final type = controller.manifest?.find(mc)?.type;
            final catalog = _catalog;
            if (type != null && catalog != null && type != catalog.mcType) {
              unawaited(_loadCatalog(controller, force: true));
            }
          })
          .catchError((Object _) {}),
    );
    await _loadCatalog(controller);
  }

  String _fallbackType(String mc) =>
      RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(mc) ? 'release' : 'snapshot';

  Future<void> _loadCatalog(
    LauncherController controller, {
    bool force = false,
  }) async {
    final mc = _mc;
    if (mc == null) return;
    final existing = _catalog;
    if (!force && existing != null && existing.game == mc) return;
    final type = controller.manifest?.find(mc)?.type ?? _fallbackType(mc);
    final catalog = LoaderCatalog(
      controller: controller,
      game: mc,
      mcType: type,
    );
    final token = ++_catalogToken;
    setState(() {
      _catalog = catalog;
      _reconcile();
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

  void _refresh() {
    final controller = context.read<LauncherController>();
    unawaited(_loadCatalog(controller, force: true));
  }

  LoaderVersionInfo _preferredLoaderBuild(List<LoaderVersionInfo> list) {
    for (final v in list) {
      if (v.recommended) return v;
    }
    for (final v in list) {
      if (v.latest) return v;
    }
    return list.first;
  }

  OptiFineEntry _preferredOptifine(List<OptiFineEntry> list) {
    for (final e in list) {
      if (!e.isPreview) return e;
    }
    return list.first;
  }

  /// 选中项在当前目录下的有效性修正（刷新 / 异步加载完成时调用）。
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
          _build = _preferredLoaderBuild(list);
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
          _optifineEntry = _preferredOptifine(list);
        }
      }
    }
  }

  void _selectLoader(ModLoader loader) {
    if (_loader == loader) return;
    final list = _catalog?.buildsOf(loader) ?? const <LoaderVersionInfo>[];
    setState(() {
      _loader = loader;
      _build = list.isEmpty ? null : _preferredLoaderBuild(list);
      _optifine = false;
      _optifineEntry = null;
    });
  }

  void _selectOptifine() {
    if (_optifine) return;
    final list = _catalog?.optifineEntries ?? const <OptiFineEntry>[];
    setState(() {
      _loader = null;
      _build = null;
      _optifine = true;
      _optifineEntry = list.isEmpty ? null : _preferredOptifine(list);
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

  bool get _canInstall {
    final catalog = _catalog;
    if (catalog == null) return false;
    final loader = _loader;
    if (loader != null) {
      final build = _build;
      if (build == null) return false;
      return catalog.buildsOf(loader).any((v) => v.version == build.version);
    }
    if (_optifine) {
      final entry = _optifineEntry;
      if (entry == null) return false;
      return catalog.optifineEntries.any((e) => e.filename == entry.filename);
    }
    return false;
  }

  String get _fabLabel {
    final loader = _loader;
    if (loader != null) {
      final build = _build;
      return build == null
          ? '安装 ${loader.label}'
          : '安装 ${loader.label} ${build.version}';
    }
    if (_optifine) {
      final entry = _optifineEntry;
      return entry == null ? '安装 OptiFine' : '安装 OptiFine ${entry.edition}';
    }
    return '安装加载器';
  }

  Future<void> _install() async {
    final controller = context.read<LauncherController>();
    if (controller.isPreparing) {
      showMintSnack(context, '有任务正在进行，稍后再试');
      return;
    }
    final mc = _mc;
    final loader = _loader;
    final build = _build;
    final optifine = _optifine ? _optifineEntry : null;
    if (mc == null || mc.isEmpty) return;
    if (loader == null && !_optifine) return;
    if (loader != null && build == null) return;
    if (_optifine && optifine == null) return;
    if (!_canInstall) return;

    final settings = context.read<SettingsService>();
    final navigator = Navigator.of(context);
    final notifyContext = navigator.context;
    final root = controller.gameDir.root;
    final baseVersion = widget.versionId;
    final label = loader != null
        ? '${loader.label} ${build!.version}'
        : 'OptiFine ${optifine!.edition}';

    // 先回上一级，安装转后台（与原一键安装同款：进度见标题栏）。
    if (navigator.canPop()) navigator.pop();
    if (notifyContext.mounted) {
      showMintSnackAboveRoutes(notifyContext, '已开始安装 $label，进度见标题栏');
    }

    if (loader != null) {
      final expected = ModloaderService.versionIdFor(
        loader,
        mc,
        build!.version,
      );
      unawaited(() async {
        try {
          await controller.installModloader(loader, mc, build.version, root);
          settings.selectedVersion = expected;
          if (notifyContext.mounted) {
            showMintSnackAboveRoutes(notifyContext, '✅ 安装完成：$expected');
          }
        } catch (e) {
          controller.log('❌ 安装 $label 失败：$e');
          if (notifyContext.mounted) {
            showMintSnackAboveRoutes(notifyContext, '❌ 安装失败：$e');
          }
        }
      }());
      return;
    }

    unawaited(() async {
      try {
        final id = await controller.installOptifine(
          optifine!,
          baseVersion,
          root,
        );
        if (id.isNotEmpty) {
          settings.selectedVersion = id;
          if (notifyContext.mounted) {
            showMintSnackAboveRoutes(notifyContext, '✅ 安装完成：$id');
          }
        } else if (notifyContext.mounted) {
          showMintSnackAboveRoutes(notifyContext, '安装未开始，可能有任务正在进行');
        }
      } catch (e) {
        controller.log('❌ 安装 $label 失败：$e');
        if (notifyContext.mounted) {
          showMintSnackAboveRoutes(notifyContext, '❌ 安装失败：$e');
        }
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final catalog = _catalog;
    final busy = controller.isPreparing;
    final fab = InstallFab(
      miuix: mintMiuixOf(context),
      label: _fabLabel,
      onPressed: _canInstall && !busy ? _install : null,
    );

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '安装加载器',
      showBack: true,
      actions: [
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: Icons.refresh,
          tooltip: '刷新',
          onPressed: _mc == null ? null : _refresh,
        ),
      ],
      floatingActionButton: mintMiuixOf(context, widget.miuix) ? fab : null,
      body: (padding) {
        final content = ListView(
          physics: kMintPageScrollPhysics,
          padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            _targetCard(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: MintEmptyState(
                  miuix: mintMiuixOf(context),
                  icon: Icons.videogame_asset_off_outlined,
                  title: _error!,
                ),
              )
            else if (catalog == null || (catalog.isLoading && !catalog.hasAny))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: LoaderLoadingCard(
                  miuix: mintMiuixOf(context, widget.miuix),
                ),
              )
            else if (!catalog.hasAny)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: MintEmptyState(
                  miuix: mintMiuixOf(context),
                  icon: Icons.extension_off_outlined,
                  title: '该版本没有可用的加载器',
                ),
              )
            else ...[
              MintSectionHeader(miuix: mintMiuixOf(context), title: '加载器'),
              _loaderOptions(catalog),
              if (catalog.isLoading)
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
            ],
            if (_loader != null) ...[
              const SizedBox(height: 2),
              _loaderBuildSection(),
            ],
            if (_optifine) ...[
              const SizedBox(height: 2),
              _optifineBuildSection(),
            ],
            const SizedBox(height: 16),
          ],
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

  Widget _targetCard() {
    return MintCard(
      miuix: mintMiuixOf(context),
      children: [
        MintTile(
          miuix: mintMiuixOf(context),
          leading: loaderIconAsset(
            loaderIconNameForVersion(widget.versionId),
            size: 28,
          ),
          title: widget.versionId,
          subtitle: _mc == null ? null : 'Minecraft $_mc',
          showDivider: false,
        ),
      ],
    );
  }

  Widget _loaderOptions(LoaderCatalog catalog) {
    final loaders = [
      for (final loader in ModLoader.values)
        if (catalog.available(loader)) loader,
    ];
    final total = loaders.length + (catalog.optifineAvailable ? 1 : 0);
    return MintCard(
      miuix: mintMiuixOf(context),
      children: [
        for (final (i, loader) in loaders.indexed)
          _LoaderOptionRow(
            miuix: mintMiuixOf(context),
            icon: loaderIconAsset(loader.id, size: 24),
            label: loader.label,
            selected: _loader == loader,
            showDivider: i != total - 1,
            onTap: () => _selectLoader(loader),
          ),
        if (catalog.optifineAvailable)
          _LoaderOptionRow(
            miuix: mintMiuixOf(context),
            icon: loaderIconAsset('optifine', size: 24),
            label: 'OptiFine',
            selected: _optifine,
            showDivider: false,
            onTap: _selectOptifine,
          ),
      ],
    );
  }

  /// 构建排序：推荐优先、最新其次，其余保持数据源顺序（新→旧）。
  /// 默认选中的就是第一行，FAB 文案和列表不会对不上。
  List<LoaderVersionInfo> _orderedBuilds(List<LoaderVersionInfo> list) {
    final indexed = list.indexed.toList()
      ..sort((a, b) {
        final ra = a.$2.recommended ? 0 : 1;
        final rb = b.$2.recommended ? 0 : 1;
        if (ra != rb) return ra - rb;
        final la = a.$2.latest ? 0 : 1;
        final lb = b.$2.latest ? 0 : 1;
        if (la != lb) return la - lb;
        return a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }

  Widget _loaderBuildSection() {
    final loader = _loader!;
    final catalog = _catalog;
    final list = _orderedBuilds(
      catalog?.buildsOf(loader) ?? const <LoaderVersionInfo>[],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MintSectionHeader(
          miuix: mintMiuixOf(context),
          title: '${loader.label} 构建',
          trailing: list.isEmpty
              ? null
              : Text(
                  '${list.length} 个',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
        _BuildListCard(
          miuix: mintMiuixOf(context),
          title: '${loader.label} 构建',
          loading: catalog?.loading.contains(loader) ?? true,
          error: catalog?.errors[loader],
          entries: [
            for (final v in list)
              (label: v.displayLabel, key: v.version, value: v as Object),
          ],
          selectedKey: _build?.version,
          onRetry: () => _retryLoader(loader),
          onPick: (v) => setState(() => _build = v as LoaderVersionInfo),
        ),
      ],
    );
  }

  Widget _optifineBuildSection() {
    final catalog = _catalog;
    final list = catalog?.optifineEntries ?? const <OptiFineEntry>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MintSectionHeader(
          miuix: mintMiuixOf(context),
          title: 'OptiFine 构建',
          trailing: list.isEmpty
              ? null
              : Text(
                  '${list.length} 个',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
        _BuildListCard(
          miuix: mintMiuixOf(context),
          title: 'OptiFine 构建',
          loading: catalog?.optifineLoading ?? true,
          error: catalog?.optifineError,
          entries: [
            for (final e in list)
              (label: e.displayLabel, key: e.filename, value: e as Object),
          ],
          selectedKey: _optifineEntry?.filename,
          onRetry: _retryOptifine,
          onPick: (v) => setState(() => _optifineEntry = v as OptiFineEntry),
        ),
      ],
    );
  }
}

// ───────────────────────── 行 / 构建列表 ─────────────────────────

class _LoaderOptionRow extends StatelessWidget {
  const _LoaderOptionRow({
    required this.miuix,
    required this.icon,
    required this.label,
    required this.selected,
    required this.showDivider,
    required this.onTap,
  });

  final bool miuix;
  final Widget icon;
  final String label;
  final bool selected;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final row = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            children: [
              icon,
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ),
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
    return Container(
      width: 22,
      height: 22,
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

/// 构建列表卡：固定高度内滚动，默认选中推荐 / 最新构建。
class _BuildListCard extends StatelessWidget {
  const _BuildListCard({
    required this.miuix,
    required this.title,
    required this.loading,
    required this.error,
    required this.entries,
    required this.selectedKey,
    required this.onRetry,
    required this.onPick,
  });

  final bool miuix;
  final String title;
  final bool loading;
  final String? error;

  /// (展示名, 唯一键, 值) 列表。
  final List<({String label, String key, Object value})> entries;
  final String? selectedKey;
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
            padding: const EdgeInsets.symmetric(vertical: 22),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  '正在获取构建…',
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                ),
              ],
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
              '没有可用的构建',
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      );
    }
    final height = entries.length > 6 ? 336.0 : entries.length * 57.0;
    return MintCard(
      miuix: miuix,
      children: [
        SizedBox(
          height: height,
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemExtent: 57,
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              final selected = e.key == selectedKey;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: () => onPick(e.value),
                      child: SizedBox(
                        height: 56,
                        child: Row(
                          children: [
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                e.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: selected ? cs.primary : cs.onSurface,
                                ),
                              ),
                            ),
                            if (selected)
                              Icon(Icons.check, size: 20, color: cs.primary),
                            const SizedBox(width: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (i != entries.length - 1)
                    Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: cs.outlineVariant.withValues(alpha: 0.4),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/modrinth.dart';
import 'package:mint/services/launcher/optifine.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/src/loading_indicator_m3e.dart';

import 'common.dart';
import 'shared_actions.dart';
import '../widgets/mint_collapsible_card.dart';
import '../widgets/mint_page.dart';
import '../widgets/mint_refresh.dart';
import '../widgets/pcl_hover.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

/// OptiFine 下载页（独立页面）。基版本默认当前启动版本，可换。
class OptiFinePage extends StatefulWidget {
  const OptiFinePage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<OptiFinePage> createState() => _OptiFinePageState();
}

class _OptiFinePageState extends State<OptiFinePage> {
  String? _game;
  List<OptiFineEntry>? _all;
  bool _loading = false;
  String? _error;

  /// 手动刷新（顶栏按钮）走 MintRefreshView 的指示器。
  final MintRefreshController _refreshCtrl = MintRefreshController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = context.read<LauncherController>();
      final settings = context.read<SettingsService>();
      final active = activeVersionId(controller, settings);
      controller.ensureManifest().then(
        (m) {
          if (!mounted) return;
          setState(() {
            _game = active ?? m.latest.release;
          });
          _load(controller);
        },
        onError: (Object _) {
          if (!mounted) return;
          setState(() => _game = active);
          _load(controller);
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final settings = context.watch<SettingsService>();
    final manifest = controller.manifest;
    final installed = controller.gameDir.installedVersions();
    final installedSet = installed.toSet();
    final game = _game ?? activeVersionId(controller, settings);
    final mcVersion = game == null
        ? null
        : resolveMcVersion(controller.gameDir, game);
    final versions = _all
        ?.where((e) => e.mcVersion == mcVersion)
        .toList(growable: false);
    final busy =
        controller.state == LauncherState.installing ||
        controller.state == LauncherState.preparingJava;

    final games = <String>[
      ...installed,
      if (manifest != null)
        for (final v in manifest.versions)
          if (!installedSet.contains(v.id)) v.id,
    ];
    final types = {
      if (manifest != null)
        for (final v in manifest.versions) v.id: v.type,
    };

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: 'OptiFine',
      showBack: true,
      actions: [
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: Icons.refresh,
          tooltip: '刷新清单',
          onPressed: _loading ? null : _refreshCtrl.refresh,
        ),
      ],
      body: (padding) => MintRefreshView(
        miuix: mintMiuixOf(context),
        controller: _refreshCtrl,
        topInset: padding.top,
        onRefresh: () => _load(controller, force: true),
        child: ListView(
          physics: kMintPageScrollPhysics,
          padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            MintCard(
              miuix: mintMiuixOf(context),
              children: [
                MintTile(
                  miuix: mintMiuixOf(context),
                  leading: loaderIconAsset('optifine', size: 28),
                  title: '安装到哪个版本',
                  subtitle: game == null
                      ? '还没有安装版本'
                      : '$game · Minecraft ${mcVersion ?? '?'}'
                            '${installedSet.contains(game) ? '（已安装）' : ''}',
                  showDivider: false,
                  onTap: game == null
                      ? null
                      : () async {
                          final picked = await showGameVersionPickerSheet(
                            context,
                            miuix: mintMiuixOf(context),
                            ids: games,
                            installed: installedSet,
                            current: game,
                            types: types,
                          );
                          if (picked != null) setState(() => _game = picked);
                        },
                  trailing: Icon(
                    Icons.expand_more,
                    size: 22,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            MintNotice(
              miuix: mintMiuixOf(context),
              icon: Icons.info_outline,
              title: '可以叠在 Forge 上',
              message: 'OptiFine 会作为新的版本安装；若基版本是 Forge，会自动补丁并保留 Forge 的加载链。',
            ),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: LoadingIndicatorM3E()),
              )
            else if (_error != null && (_all == null || _all!.isEmpty))
              MintEmptyState(
                miuix: mintMiuixOf(context),
                icon: Icons.cloud_off,
                title: '获取 OptiFine 清单失败',
                message: _error,
                action: MintSecondaryButton(
                  miuix: mintMiuixOf(context),
                  label: '重试',
                  icon: Icons.refresh,
                  onPressed: () => _load(controller, force: true),
                ),
              )
            else if (versions == null || versions.isEmpty)
              MintEmptyState(
                miuix: mintMiuixOf(context),
                icon: Icons.hd_outlined,
                title: '这个版本没有 OptiFine',
                message: mcVersion == null
                    ? '先选择一个游戏版本。'
                    : 'Minecraft $mcVersion 没有可用的 OptiFine 构建。',
              )
            else
              MintCollapsibleCard(
                miuix: mintMiuixOf(context),
                title: 'OptiFine 构建',
                subtitle:
                    'Minecraft ${mcVersion ?? '?'} · ${versions.length} 个',
                leading: loaderIconAsset('optifine', size: 26),
                storageKey: 'optifine.builds',
                initiallyExpanded: true,
                children: [
                  for (final (i, v) in versions.indexed)
                    _OptiFineRow(
                      miuix: mintMiuixOf(context),
                      entry: v,
                      busy: busy,
                      showDivider: i < versions.length - 1,
                      onInstall: () => _install(controller, game!, v),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _load(
    LauncherController controller, {
    bool force = false,
  }) async {
    if (_loading) return;
    if (!force && _all != null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final dl = controller.newDownloaderForModloader();
    final service = OptiFineService(
      gameDir: controller.gameDir,
      downloader: dl,
    );
    try {
      final list = await service.versions();
      if (!mounted) return;
      setState(() {
        _all = list;
        _loading = false;
      });
    } catch (e) {
      controller.log('❌ 获取 OptiFine 版本列表失败：$e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    } finally {
      dl.close();
    }
  }

  Future<void> _install(
    LauncherController controller,
    String game,
    OptiFineEntry entry,
  ) async {
    await runInstallTask(
      context,
      title: '安装 OptiFine ${entry.displayLabel}',
      task: () =>
          controller.installOptifine(entry, game, controller.gameDir.root),
    );
  }
}

class _OptiFineRow extends StatelessWidget {
  const _OptiFineRow({
    required this.miuix,
    required this.entry,
    required this.busy,
    required this.showDivider,
    required this.onInstall,
  });

  final bool miuix;
  final OptiFineEntry entry;
  final bool busy;
  final bool showDivider;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = [
      if (entry.forgeInfo.isNotEmpty && entry.forgeInfo != 'Forge N/A')
        '适配 ${entry.forgeInfo}',
      if (entry.isPreview) '预览版',
    ].join(' · ');
    final row = PclHoverSurface(
      enabled: !busy,
      onTap: onInstall,
      borderRadius: 12,
      ripple: !miuix,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            loaderIconAsset('optifine', size: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (info.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      info,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            MintTextAction(
              miuix: miuix,
              label: '安装',
              icon: Icons.download,
              onPressed: busy ? null : onInstall,
            ),
          ],
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
          indent: 14,
          endIndent: 14,
          color: cs.outlineVariant.withValues(alpha: 0.35),
        ),
      ],
    );
  }
}

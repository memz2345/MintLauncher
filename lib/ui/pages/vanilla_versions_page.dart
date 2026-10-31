import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/manifest.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/src/enums.dart';
import 'package:mint/src/loading_indicator_m3e.dart';

import 'common.dart';
import 'game_install_page.dart';
import '../widgets/mint_collapsible_card.dart';
import '../widgets/mint_page.dart';
import '../widgets/mint_refresh.dart';
import '../widgets/pcl_hover.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

/// 原版版本列表（独立页面）。
///
/// 正式版 / 快照 / 远古版各是一张可折叠大卡片（PCL2 下载页同布局），
/// 分组图标用方块：草方块 / 命令方块 / 原石（HMCL 同款）；
/// 行说明只写发布日期和时间，不再重复类型。
class VanillaVersionsPage extends StatefulWidget {
  const VanillaVersionsPage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<VanillaVersionsPage> createState() => _VanillaVersionsPageState();
}

class _VersionGroup {
  const _VersionGroup(this.type, this.label, this.icon);
  final String type;
  final String label;
  final String icon;

  bool matches(ManifestVersion v) => switch (type) {
    'release' => v.isRelease,
    'snapshot' => v.isSnapshot,
    _ => v.isOld,
  };
}

const _kGroups = [
  _VersionGroup('release', '正式版', 'grass'),
  _VersionGroup('snapshot', '快照', 'command_block'),
  _VersionGroup('old', '远古版', 'cobblestone'),
];

class _VanillaVersionsPageState extends State<VanillaVersionsPage> {
  String _query = '';
  bool _refreshing = false;

  /// 手动刷新（顶栏按钮）走 MintRefreshView 的指示器：
  /// Material 浮出 M3E 指示器，miuix 把页面元素整体下推。
  final MintRefreshController _refreshCtrl = MintRefreshController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = context.read<LauncherController>();
      controller.ensureManifest().then((_) {}, onError: (Object _) {});
    });
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final controller = context.read<LauncherController>();
    try {
      await controller.ensureManifest(force: true);
    } catch (e) {
      if (mounted) showMintSnack(context, '刷新版本清单失败：$e');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final manifest = controller.manifest;

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: 'Minecraft 版本',
      showBack: true,
      actions: [
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: Icons.refresh,
          tooltip: '刷新清单',
          onPressed: _refreshing ? null : _refreshCtrl.refresh,
        ),
      ],
      body: (padding) {
        if (manifest == null) {
          return const Center(child: LoadingIndicatorM3E());
        }
        final settings = context.watch<SettingsService>();
        final installed = controller.gameDir.installedVersions().toSet();
        final query = _query.trim().toLowerCase();
        final groups = [
          for (final group in _kGroups)
            (
              group: group,
              versions: [
                for (final v in manifest.versions)
                  if (group.matches(v) &&
                      (query.isEmpty || v.id.toLowerCase().contains(query)))
                    v,
              ],
            ),
        ];
        final visibleCount = groups.fold<int>(
          0,
          (sum, group) => sum + group.versions.length,
        );

        return MintRefreshView(
          miuix: mintMiuixOf(context),
          controller: _refreshCtrl,
          topInset: padding.top,
          onRefresh: _refresh,
          child: ListView(
            physics: kMintPageScrollPhysics,
            padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              MintSearchField(
                miuix: mintMiuixOf(context),
                hint: '搜索版本，例如 1.21.9',
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 10),
              Text(
                '$visibleCount 个版本 · 下载源：${_sourceLabel(settings.downloadSource)}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              for (final entry in groups)
                if (entry.versions.isNotEmpty) ...[
                  MintCollapsibleCard(
                    // 搜索时所有分组都展开；清空搜索后恢复「正式版默认展开」。
                    key: ValueKey(
                      '${entry.group.type}-${query.isNotEmpty}-${mintMiuixOf(context, widget.miuix)}',
                    ),
                    miuix: mintMiuixOf(context),
                    title: entry.group.label,
                    subtitle: '${entry.versions.length} 个版本',
                    leading: loaderIconAsset(entry.group.icon, size: 26),
                    storageKey: 'vanilla.${entry.group.type}',
                    initiallyExpanded:
                        query.isNotEmpty || entry.group.type == 'release',
                    children: [
                      for (final (i, v) in entry.versions.indexed)
                        _VanillaRow(
                          miuix: mintMiuixOf(context),
                          version: v,
                          icon: entry.group.icon,
                          installed: installed.contains(v.id),
                          showDivider: i < entry.versions.length - 1,
                          onTap: installed.contains(v.id)
                              ? () {
                                  settings.selectedVersion = v.id;
                                  showMintSnack(context, '已切换到 ${v.id}');
                                  Navigator.of(context).maybePop();
                                }
                              : () => _openInstaller(v.id),
                          onDownload: () => _openInstaller(v.id),
                          onAddLoader: installed.contains(v.id)
                              ? () => _openInstaller(v.id)
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              if (visibleCount == 0)
                MintEmptyState(
                  miuix: mintMiuixOf(context),
                  icon: Icons.search_off,
                  title: '没有匹配的版本',
                ),
            ],
          ),
        );
      },
    );
  }

  void _openInstaller(String version) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GameInstallPage(
          miuix: mintMiuixOf(context),
          initialVersion: version,
        ),
      ),
    );
  }
}

class _VanillaRow extends StatelessWidget {
  const _VanillaRow({
    required this.miuix,
    required this.version,
    required this.icon,
    required this.installed,
    required this.showDivider,
    required this.onTap,
    required this.onDownload,
    this.onAddLoader,
  });

  final bool miuix;
  final ManifestVersion version;

  /// 行首方块图标（草方块 / 命令方块 / 原石）。
  final String icon;
  final bool installed;
  final bool showDivider;
  final VoidCallback onTap;
  final VoidCallback onDownload;
  final VoidCallback? onAddLoader;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final row = PclHoverSurface(
      onTap: onTap,
      borderRadius: 12,
      // Material 风格的点击动画用 Flutter 原生 InkRipple（非自绘）；
      // miuix 保持 PCL 悬浮 + 按压缩放，不吃 ripple。
      ripple: !miuix,
      baseColor: installed ? cs.primary.withValues(alpha: 0.06) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            loaderIconAsset(icon, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    version.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: installed ? FontWeight.w700 : FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatReleaseTime(version.releaseTime),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (installed)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '已安装',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ),
            // 下载图标对已安装版本也要有：点它 = 重新下载 / 重装。
            IconButton(
              tooltip: installed ? '重新下载 / 重装' : '下载',
              onPressed: onDownload,
              icon: Icon(
                Icons.download_outlined,
                size: 21,
                color: installed
                    ? cs.primary.withValues(alpha: 0.75)
                    : cs.onSurfaceVariant,
              ),
            ),
            if (onAddLoader != null)
              IconButton(
                tooltip: '添加加载器 / 重装',
                onPressed: onAddLoader,
                icon: const Icon(Icons.add_circle_outline, size: 20),
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

String _sourceLabel(DownloadSource s) => switch (s) {
  DownloadSource.auto => '自动（镜像优先）',
  DownloadSource.bmcl => 'BMCLAPI',
  DownloadSource.official => 'Mojang 官方',
};

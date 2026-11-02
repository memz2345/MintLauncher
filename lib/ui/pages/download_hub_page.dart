import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/download_center.dart';
import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/modrinth.dart';

import 'common.dart';
import 'download_manager_page.dart';
import 'modpack_import_flow.dart';
import 'modrinth_browser_page.dart';
import 'vanilla_versions_page.dart';
import '../widgets/mint_page.dart';
import '../widgets/page_background.dart' show MintPageBackgroundKey;
import '../widgets/pcl_hover.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/widgets/mint_refresh.dart';

/// 下载中心（PCL2 PageDownload 同款结构）：
///  · 宽屏 —— 左侧分类列表（游戏版本 / 社区资源），右侧直接内嵌社区资源
///    浏览器（Modrinth 热门列表）；原版这类多步安装流程点条目进独立页面。
///  · 窄屏 —— 卡片列表，社区资源五类各自进浏览器页。
///
/// 所有下载都走 DownloadCenter 后台任务队列（标题栏下载按钮 + 下载管理页）。
class DownloadHubPage extends StatefulWidget {
  const DownloadHubPage({
    super.key,
    required this.miuix,
    this.embedded = false,
  });

  final bool miuix;

  /// 作为一级分页嵌在首页壳里（竖屏底栏「下载」）：不画返回键，
  /// 用可折叠大标题，内容从标题栏下滚过（local2api 的页面布局）。
  final bool embedded;

  @override
  State<DownloadHubPage> createState() => _DownloadHubPageState();
}

/// 左侧分类的唯一键（窄屏也用同一组数据铺卡片）。
enum _Category {
  vanilla('Minecraft 原版', Icons.videogame_asset_outlined),
  mod('模组', Icons.extension_outlined),
  modpack('整合包', Icons.inventory_2_outlined),
  datapack('数据包', Icons.data_object),
  resourcepack('资源包', Icons.texture_outlined),
  shader('光影', Icons.auto_awesome_outlined);

  const _Category(this.label, this.icon);
  final String label;
  final IconData icon;

  bool get isCommunity => index >= mod.index;
  ModrinthProjectType get communityType => switch (this) {
    mod => ModrinthProjectType.mod,
    modpack => ModrinthProjectType.modpack,
    datapack => ModrinthProjectType.datapack,
    resourcepack => ModrinthProjectType.resourcepack,
    shader => ModrinthProjectType.shader,
    _ => ModrinthProjectType.mod,
  };
}

class _DownloadHubPageState extends State<DownloadHubPage> {
  _Category _selected = _Category.mod;

  void _open(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  void _openCategory(_Category c) {
    if (c.isCommunity) {
      setState(() => _selected = c);
      return;
    }
    _open(VanillaVersionsPage(miuix: mintMiuixOf(context, widget.miuix)));
  }

  /// 窄屏卡片：社区分类直接进独立浏览器页（宽屏左栏才是切换右侧内嵌页）。
  void _openCategoryPage(_Category c) {
    if (c.isCommunity) {
      _open(
        ModrinthBrowserPage(miuix: mintMiuixOf(context), type: c.communityType),
      );
      return;
    }
    _open(VanillaVersionsPage(miuix: mintMiuixOf(context, widget.miuix)));
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '下载',
      largeTitle: widget.embedded ? '下载' : null,
      showBack: !widget.embedded,
      pageBackgroundKey: MintPageBackgroundKey.download.id,
      actions: [
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: Icons.folder_outlined,
          tooltip: '打开游戏目录',
          onPressed: () =>
              controller.openInFileManager(controller.gameDir.root),
        ),
      ],
      body: (padding) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 840;
          final content = wide
              ? Padding(
                  padding: padding,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 208,
                        child: _LeftPane(
                          miuix: mintMiuixOf(context),
                          selected: _selected,
                          onSelected: _openCategory,
                        ),
                      ),
                      VerticalDivider(
                        width: 17,
                        thickness: 1,
                        indent: 12,
                        endIndent: 24,
                        color: Theme.of(
                          context,
                        ).colorScheme.outlineVariant.withValues(alpha: 0.4),
                      ),
                      Expanded(
                        child: _RightPane(
                          miuix: mintMiuixOf(context),
                          category: _selected,
                        ),
                      ),
                    ],
                  ),
                )
              : _NarrowBody(
                  miuix: mintMiuixOf(context),
                  padding: padding,
                  onOpen: _openCategoryPage,
                );
          // 右下角 FAB = 安装整合包；直接下载链接文件挪到「下载管理」页。
          // miuix 风格用 Miuix 的 FAB（HyperOS 同款圆钮）。
          return Stack(
            children: [
              Positioned.fill(child: content),
              Positioned(
                right: 20,
                bottom: padding.bottom + 36,
                child: mintMiuixOf(context)
                    ? MiuixFloatingActionButton(
                        onPressed: () => startModpackImportFlow(context),
                        child: Icon(
                          Icons.add,
                          size: 26,
                          color: MiuixTheme.of(context).colors.onPrimary,
                        ),
                      )
                    : FloatingActionButton(
                        heroTag: 'download-import-fab',
                        tooltip: '安装整合包',
                        onPressed: () => startModpackImportFlow(context),
                        child: const Icon(Icons.add, size: 26),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ───────────────────────── 左侧分类列表（PCL2 PageDownloadLeft） ─────────────────────────

class _LeftPane extends StatelessWidget {
  const _LeftPane({
    required this.miuix,
    required this.selected,
    required this.onSelected,
  });

  final bool miuix;
  final _Category selected;
  final ValueChanged<_Category> onSelected;

  static const _sections = <(String, List<_Category>)>[
    ('游戏', [_Category.vanilla]),
    (
      '社区资源',
      [
        _Category.mod,
        _Category.modpack,
        _Category.datapack,
        _Category.resourcepack,
        _Category.shader,
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: DownloadCenter.instance,
      builder: (context, _) {
        final activeCount = DownloadCenter.instance.activeCount;
        return ListView(
          physics: kMintPageScrollPhysics,
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
              child: Text(
                '任务',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ),
            _CategoryTile(
              miuix: miuix,
              icon: Icons.manage_history_outlined,
              label: '下载管理',
              selected: false,
              badge: activeCount > 0,
              badgeLabel: '$activeCount',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DownloadManagerPage(miuix: miuix),
                ),
              ),
            ),
            _CategoryTile(
              miuix: miuix,
              icon: Icons.inventory_2_outlined,
              label: '导入整合包',
              selected: false,
              onTap: () => startModpackImportFlow(context),
            ),
            for (final (section, items) in _sections) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Text(
                  section,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.85),
                  ),
                ),
              ),
              for (final c in items)
                _CategoryTile(
                  miuix: miuix,
                  icon: c.icon,
                  label: c.label,
                  selected: c == selected,
                  onTap: () => onSelected(c),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.miuix,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = false,
    this.badgeLabel,
  });

  final bool miuix;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 图标右上角的小红点（下载管理入口：有进行中任务时）。
  final bool badge;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = selected
        ? (miuix ? cs.primary.withValues(alpha: 0.14) : cs.secondaryContainer)
        : Colors.transparent;
    final fg = selected
        ? (miuix ? cs.primary : cs.onSecondaryContainer)
        : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: PclHoverSurface(
        onTap: onTap,
        borderRadius: 12,
        // 选中底色走 baseColor（常驻、不参与缩放），悬浮底板 + 按压缩放和
        // 版本管理列表同一套动画。
        ripple: !miuix,
        baseColor: selected ? bg : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, size: 18, color: selected ? fg : cs.primary),
                  if (badge)
                    Positioned(
                      top: -2,
                      right: -3,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5484D),
                          shape: BoxShape.circle,
                          border: Border.all(
                            width: 1.2,
                            color: bg == Colors.transparent
                                ? Theme.of(context).colorScheme.surface
                                : bg,
                          ),
                        ),
                        child: Text(
                          badgeLabel ?? '',
                          style: const TextStyle(
                            fontSize: 8.5,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 右侧内容 ─────────────────────────

class _RightPane extends StatelessWidget {
  const _RightPane({required this.miuix, required this.category});

  final bool miuix;
  final _Category category;

  @override
  Widget build(BuildContext context) {
    if (!category.isCommunity) return const SizedBox.shrink();
    return ModrinthBrowserView(
      key: ValueKey(category),
      miuix: miuix,
      type: category.communityType,
      embedded: true,
    );
  }
}

// ───────────────────────── 窄屏卡片布局 ─────────────────────────

class _NarrowBody extends StatelessWidget {
  const _NarrowBody({
    required this.miuix,
    required this.padding,
    required this.onOpen,
  });

  final bool miuix;
  final EdgeInsets padding;
  final ValueChanged<_Category> onOpen;

  static const _communityItems = <_Category>[
    _Category.mod,
    _Category.modpack,
    _Category.datapack,
    _Category.resourcepack,
    _Category.shader,
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: DownloadCenter.instance,
      builder: (context, _) {
        final count = DownloadCenter.instance.activeCount;
        return ListView(
          physics: kMintPageScrollPhysics,
          padding: padding + const EdgeInsets.fromLTRB(16, 4, 16, 36),
          children: [
            MintSectionHeader(
              miuix: miuix,
              title: '任务',
              trailing: count > 0
                  ? Text(
                      '$count 个进行中',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
            MintCard(
              miuix: miuix,
              children: [
                MintTile(
                  miuix: miuix,
                  icon: Icons.manage_history_outlined,
                  title: '下载管理',
                  subtitle: count > 0
                      ? '正在下载 $count 个任务 · 安装整合包点右下角 ＋'
                      : '任务队列 · 安装整合包点右下角 ＋',
                  trailing: _DownloadDot(active: count > 0),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DownloadManagerPage(miuix: miuix),
                    ),
                  ),
                ),
                MintTile(
                  miuix: miuix,
                  icon: Icons.inventory_2_outlined,
                  title: '导入整合包',
                  subtitle: '本地 .zip / .mrpack，也可直接拖进窗口',
                  showDivider: false,
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  onTap: () => startModpackImportFlow(context),
                ),
              ],
            ),
            MintSectionHeader(miuix: miuix, title: '游戏'),
            MintCard(
              miuix: miuix,
              children: [
                MintTile(
                  miuix: miuix,
                  leading: loaderIconAsset('grass', size: 26),
                  title: _Category.vanilla.label,
                  showDivider: false,
                  trailing: Icon(
                    Icons.download_outlined,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  onTap: () => onOpen(_Category.vanilla),
                ),
              ],
            ),
            MintSectionHeader(miuix: miuix, title: '社区资源'),
            MintCard(
              miuix: miuix,
              children: [
                for (final (i, c) in _communityItems.indexed)
                  MintTile(
                    miuix: miuix,
                    icon: c.icon,
                    title: c.label,
                    showDivider: i < _communityItems.length - 1,
                    trailing: Icon(
                      Icons.download_outlined,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                    onTap: () => onOpen(c),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 小红点（窄屏「下载管理」行）。
class _DownloadDot extends StatelessWidget {
  const _DownloadDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    if (!active) {
      return Icon(
        Icons.chevron_right,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
    }
    return Container(
      width: 9,
      height: 9,
      decoration: const BoxDecoration(
        color: Color(0xFFE5484D),
        shape: BoxShape.circle,
      ),
    );
  }
}

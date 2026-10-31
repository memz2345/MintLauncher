import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/ui/pages/common.dart';
import 'package:mint/ui/widgets/page_background.dart' show mintCardMaskColor;

/// 版本卡上的更多操作。
enum VersionMenuAction {
  manage,
  settings,
  installLoader,
  exportPack,
  openFolder,
  rename,
  copy,
  delete,
}

/// 版本卡片：加载器图标 + 版本名 + MC/加载器/隔离信息 + 快捷操作。
///
/// 主页与「版本」页共用，保证两处观感与行为一致。点击卡片 = 选中该版本。
class VersionTileCard extends StatelessWidget {
  const VersionTileCard({
    super.key,
    required this.miuix,
    required this.id,
    required this.mcVersion,
    required this.loader,
    required this.selected,
    required this.isolated,
    required this.onTap,
    required this.onLaunch,
    required this.onSettings,
    required this.onMenu,
    this.running = false,
  });

  final bool miuix;
  final String id;
  final String mcVersion;
  final String loader;
  final bool selected;
  final bool isolated;
  final bool running;
  final VoidCallback onTap;
  final VoidCallback onLaunch;
  final VoidCallback onSettings;
  final ValueChanged<VersionMenuAction> onMenu;

  @override
  Widget build(BuildContext context) {
    if (miuix) return _buildMiuix(context);
    final cs = Theme.of(context).colorScheme;
    final icon = loaderIconAsset(loaderIconNameForVersion(id), size: 38);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          SizedBox(width: 48, height: 48, child: Center(child: icon)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          running ? '运行中' : '当前',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  'Minecraft $mcVersion · $loader'
                  '${isolated ? ' · 版本隔离' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '启动',
            onPressed: onLaunch,
            icon: Icon(
              running ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              size: 26,
              color: running ? cs.error : cs.primary,
            ),
          ),
          IconButton(
            tooltip: '版本设置',
            onPressed: onSettings,
            icon: const Icon(Icons.tune, size: 21),
          ),
          PopupMenuButton<VersionMenuAction>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert, size: 21),
            onSelected: onMenu,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: VersionMenuAction.manage,
                child: _MenuRow(icon: Icons.folder_open, label: '管理内容'),
              ),
              PopupMenuItem(
                value: VersionMenuAction.settings,
                child: _MenuRow(icon: Icons.tune, label: '版本设置'),
              ),
              PopupMenuItem(
                value: VersionMenuAction.installLoader,
                child: _MenuRow(
                  icon: Icons.extension_outlined,
                  label: '安装加载器 / OptiFine',
                ),
              ),
              PopupMenuItem(
                value: VersionMenuAction.exportPack,
                child: _MenuRow(icon: Icons.outbox_outlined, label: '导出整合包'),
              ),
              PopupMenuItem(
                value: VersionMenuAction.openFolder,
                child: _MenuRow(icon: Icons.folder_outlined, label: '打开版本目录'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: VersionMenuAction.rename,
                child: _MenuRow(
                  icon: Icons.drive_file_rename_outline,
                  label: '重命名',
                ),
              ),
              PopupMenuItem(
                value: VersionMenuAction.copy,
                child: _MenuRow(icon: Icons.copy_all_outlined, label: '复制'),
              ),
              PopupMenuItem(
                value: VersionMenuAction.delete,
                child: _MenuRow(icon: Icons.delete_outline, label: '删除'),
              ),
            ],
          ),
          const SizedBox(width: 2),
        ],
      ),
    );

    final decorated = Material(
      color: mintCardMaskColor(
        context,
        miuix
            ? MiuixTheme.of(context).colors.surfaceContainer
            : cs.surfaceContainerLow,
      ),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected
              ? cs.primary.withValues(alpha: 0.7)
              : cs.outlineVariant.withValues(alpha: 0.4),
          width: selected ? 1.4 : 1,
        ),
      ),
      child: InkWell(onTap: onTap, child: content),
    );
    return decorated;
  }

  /// miuix 分支：MiuixCard + MiuixIconButton + HyperOS 动作弹层，
  /// 不在 HyperOS 页面里混 Material 的 IconButton / PopupMenuButton。
  Widget _buildMiuix(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final miuix = MiuixTheme.of(context);
    final icon = loaderIconAsset(loaderIconNameForVersion(id), size: 38);
    final base = mintCardMaskColor(context, miuix.colors.surfaceContainer);
    return MiuixCard(
      cornerRadius: 18,
      onPressed: onTap,
      colors: MiuixCardColors(
        color: selected
            ? Color.alphaBlend(cs.primary.withValues(alpha: 0.10), base)
            : base,
        contentColor: miuix.colors.onSurfaceContainer,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            SizedBox(width: 48, height: 48, child: Center(child: icon)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            running ? '运行中' : '当前',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Minecraft $mcVersion · $loader'
                    '${isolated ? ' · 版本隔离' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            MiuixIconButton(
              onPressed: onLaunch,
              child: Icon(
                running
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
                size: 25,
                color: running ? cs.error : cs.primary,
              ),
            ),
            MiuixIconButton(
              onPressed: onSettings,
              minWidth: 38,
              minHeight: 38,
              child: const Icon(Icons.tune, size: 20),
            ),
            MiuixIconButton(
              onPressed: () => _showMiuixMenu(context),
              minWidth: 38,
              minHeight: 38,
              child: const Icon(Icons.more_vert, size: 20),
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }

  Future<void> _showMiuixMenu(BuildContext context) async {
    final action = await showMintChoiceDialog<VersionMenuAction>(
      context,
      miuix: true,
      title: id,
      showCheck: false,
      options: const [
        MintChoice(
          value: VersionMenuAction.manage,
          label: '管理内容',
          icon: Icons.folder_open,
        ),
        MintChoice(
          value: VersionMenuAction.settings,
          label: '版本设置',
          icon: Icons.tune,
        ),
        MintChoice(
          value: VersionMenuAction.installLoader,
          label: '安装加载器 / OptiFine',
          icon: Icons.extension_outlined,
        ),
        MintChoice(
          value: VersionMenuAction.exportPack,
          label: '导出整合包',
          subtitle: 'CurseForge 格式 zip（OptiFine 不打包）',
          icon: Icons.outbox_outlined,
        ),
        MintChoice(
          value: VersionMenuAction.openFolder,
          label: '打开版本目录',
          icon: Icons.folder_outlined,
        ),
        MintChoice(
          value: VersionMenuAction.rename,
          label: '重命名',
          icon: Icons.drive_file_rename_outline,
        ),
        MintChoice(
          value: VersionMenuAction.copy,
          label: '复制',
          icon: Icons.copy_all_outlined,
        ),
        MintChoice(
          value: VersionMenuAction.delete,
          label: '删除',
          icon: Icons.delete_outline,
          destructive: true,
        ),
      ],
    );
    if (action != null) onMenu(action);
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 19), const SizedBox(width: 10), Text(label)],
    );
  }
}

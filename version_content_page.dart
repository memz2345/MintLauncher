import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/modrinth.dart';
import 'package:mint/services/settings_service.dart';

import 'common.dart';
import 'modrinth_browser_page.dart';
import 'shared_actions.dart';
import 'version_settings_page.dart';
import '../widgets/mint_page.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/widgets/mint_refresh.dart';

/// 单个版本的内容管理：模组 / 资源包 / 光影 / 数据包 / 存档。
///
/// 下载入口都跳到独立页面（浏览器内可切类型）；安装时会让用户手动选
/// 文件夹，默认定位到该版本对应的子目录（mods / resourcepacks / …）。
class VersionContentPage extends StatefulWidget {
  const VersionContentPage({
    super.key,
    required this.miuix,
    required this.versionId,
  });

  final bool miuix;
  final String versionId;

  @override
  State<VersionContentPage> createState() => _VersionContentPageState();
}

class _VersionContentPageState extends State<VersionContentPage> {
  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final settings = context.watch<SettingsService>();
    final isolated = settings.effectiveFor(widget.versionId).isolation;
    final summary = versionSummary(controller, widget.versionId);
    final mods = controller.gameDir.modsOf(
      widget.versionId,
      isolated: isolated,
    );
    final worlds = controller.gameDir.worldsOf(
      widget.versionId,
      isolated: isolated,
    );

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '内容管理',
      showBack: true,
      actions: [
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: Icons.tune,
          tooltip: '版本设置',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => VersionSettingsPage(
                miuix: mintMiuixOf(context),
                versionId: widget.versionId,
              ),
            ),
          ),
        ),
      ],
      body: (padding) => ListView(
        physics: kMintPageScrollPhysics,
        padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 36),
        children: [
          MintCard(
            miuix: mintMiuixOf(context),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Row(
                  children: [
                    loaderIconAsset(
                      loaderIconNameForVersion(widget.versionId),
                      size: 36,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.versionId,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Minecraft ${summary.mcVersion} · ${summary.loader}'
                            '${isolated ? ' · 版本隔离' : ''}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    MintTextAction(
                      miuix: mintMiuixOf(context),
                      label: '打开目录',
                      icon: Icons.folder_outlined,
                      onPressed: () => controller.openInFileManager(
                        controller.gameDir.gameHome(
                          widget.versionId,
                          isolated: isolated,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          MintSectionHeader(miuix: mintMiuixOf(context), title: '模组'),
          MintCard(
            miuix: mintMiuixOf(context),
            children: [
              MintTile(
                miuix: mintMiuixOf(context),
                icon: Icons.travel_explore,
                title: '浏览模组',
                subtitle:
                    'Modrinth · 按 ${summary.mcVersion} 与 ${summary.loader} 过滤',
                onTap: () => _openModrinth(ModrinthProjectType.mod),
              ),
              MintTile(
                miuix: mintMiuixOf(context),
                icon: Icons.folder_open,
                title: '打开 mods 目录',
                showDivider: mods.isNotEmpty,
                onTap: () => controller.openInFileManager(
                  controller.gameDir.modsDir(
                    widget.versionId,
                    isolated: isolated,
                  ),
                ),
              ),
              if (mods.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.extension_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '还没有模组',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (final (i, mod) in mods.indexed)
                  MintTile(
                    miuix: mintMiuixOf(context),
                    icon: Icons.extension_outlined,
                    title: _displayName(p.basename(mod.path)),
                    subtitle: p.basename(mod.path),
                    showDivider: i < mods.length - 1,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        mintMiuixOf(context, widget.miuix)
                            ? MiuixSwitch(
                                value: !mod.path.endsWith('.disabled'),
                                onChanged: (_) => controller.toggleMod(mod),
                                colors: mintSwitchColorsOf(context),
                              )
                            : Switch(
                                value: !mod.path.endsWith('.disabled'),
                                onChanged: (_) => controller.toggleMod(mod),
                              ),
                        IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _deleteMod(controller, mod),
                        ),
                      ],
                    ),
                  ),
            ],
          ),

          MintSectionHeader(
            miuix: mintMiuixOf(context),
            title: '资源包 / 光影 / 数据包',
          ),
          MintCard(
            miuix: mintMiuixOf(context),
            children: [
              MintTile(
                miuix: mintMiuixOf(context),
                icon: Icons.texture_outlined,
                title: '浏览资源包',
                subtitle: '安装到 resourcepacks',
                onTap: () => _openModrinth(ModrinthProjectType.resourcepack),
              ),
              MintTile(
                miuix: mintMiuixOf(context),
                icon: Icons.auto_awesome_outlined,
                title: '浏览光影',
                subtitle: '安装到 shaderpacks（需 Iris / OptiFine）',
                onTap: () => _openModrinth(ModrinthProjectType.shader),
              ),
              MintTile(
                miuix: mintMiuixOf(context),
                icon: Icons.data_object,
                title: '浏览数据包',
                subtitle: '安装到 datapacks（放进世界也能用）',
                showDivider: false,
                onTap: () => _openModrinth(ModrinthProjectType.datapack),
              ),
            ],
          ),

          MintSectionHeader(miuix: mintMiuixOf(context), title: '存档'),
          MintCard(
            miuix: mintMiuixOf(context),
            children: [
              if (worlds.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.public_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '还没有存档',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (final (i, world) in worlds.indexed)
                  MintTile(
                    miuix: mintMiuixOf(context),
                    icon: Icons.public_outlined,
                    title: world,
                    showDivider: i < worlds.length - 1,
                    trailing: IconButton(
                      tooltip: '备份为 zip',
                      icon: const Icon(Icons.backup_outlined, size: 20),
                      onPressed: () => _backupWorld(controller, world),
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openModrinth(ModrinthProjectType type) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ModrinthBrowserPage(
          miuix: mintMiuixOf(context),
          type: type,
          versionId: widget.versionId,
        ),
      ),
    );
  }

  Future<void> _deleteMod(LauncherController controller, File mod) async {
    final ok = await showMintConfirmDialog(
      context,
      miuix: mintMiuixOf(context),
      title: '删除 ${p.basename(mod.path)}？',
      message: '文件会从 mods 目录删除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (ok) await controller.deleteMod(mod);
  }

  Future<void> _backupWorld(LauncherController controller, String world) async {
    final isolated = context
        .read<SettingsService>()
        .effectiveFor(widget.versionId)
        .isolation;
    try {
      final path = await controller.backupWorld(
        widget.versionId,
        world,
        isolated: isolated,
      );
      if (!mounted) return;
      showMintSnack(context, '已备份到 $path');
    } catch (e) {
      if (!mounted) return;
      showMintSnack(context, '备份失败：$e');
    }
  }

  static String _displayName(String filename) {
    var name = filename;
    if (name.toLowerCase().endsWith('.disabled')) {
      name = name.substring(0, name.length - '.disabled'.length);
    }
    if (name.toLowerCase().endsWith('.jar')) {
      name = name.substring(0, name.length - 4);
    }
    return name;
  }
}

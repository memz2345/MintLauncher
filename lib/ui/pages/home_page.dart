import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/account.dart' show OfflineAccount;
import 'package:mint/services/settings_service.dart';
import 'package:mint/ui/nav_state.dart';
import 'package:mint/widgets/mint_cloud_foreground.dart';

import 'accounts_page.dart';
import 'common.dart';
import 'shared_actions.dart';
import 'version_manager_page.dart';
import '../widgets/mint_page.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

/// 首页（2026-10-25 改版）：
///
/// 只保留右侧一列信息 —— 用户名列表 / 版本管理 / 启动游戏 FAB。
/// 不再区分横竖屏，中间留给背景；顶部不显示「启动」「Mint Launcher」。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 截图/回归钩子：--dart-define=MINT_TEST_CLOUD=1|0 强制开/关云雾前景
/// （只影响本次运行，不写设置；排查「白雾 vs 别的白层」这类问题用）。
const _kTestCloud = String.fromEnvironment('MINT_TEST_CLOUD');

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = context.read<LauncherController>();
      final settings = context.read<SettingsService>();
      final installed = controller.gameDir.installedVersions();
      if (installed.isNotEmpty &&
          !installed.contains(settings.selectedVersion)) {
        settings.selectedVersion = installed.first;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final settings = context.watch<SettingsService>();
    final active = activeVersionId(controller, settings);

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '',
      bare: true,
      body: (padding) => LayoutBuilder(
        builder: (context, constraints) {
          final panelWidth = (constraints.maxWidth * 0.32).clamp(276.0, 344.0);
          return Stack(
            children: [
              // 中间留空：首页只露页面背景 / 窗口材质。
              Positioned(
                top: padding.top + 18,
                right: 20,
                bottom: padding.bottom + 18,
                width: panelWidth,
                child: ListView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 132),
                  children: [
                    _AccountsCard(
                      miuix: mintMiuixOf(context),
                      settings: settings,
                      controller: controller,
                    ),
                    const SizedBox(height: 12),
                    _VersionCard(
                      miuix: mintMiuixOf(context),
                      controller: controller,
                      active: active,
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 20,
                bottom: padding.bottom + 36,
                child: _LaunchFab(
                  miuix: mintMiuixOf(context),
                  controller: controller,
                  settings: settings,
                  active: active,
                ),
              ),
              // 云雾前景（Kimi K3.1 页头同风格）：盖在控件「上」的液态白雾，
              // IgnorePointer 不挡交互，透明度按深浅主题打折+封顶（见
              // MintCloudForeground），上半屏为主 —— 氛围，不抢内容。
              // shader 未就绪时组件自己退化为空（不要在这里判 ready：
              // preload 完成后本页不一定会重建）。
              if (_kTestCloud == '1' ||
                  (_kTestCloud.isEmpty &&
                      settings.cloudForeground &&
                      settings.cloudOpacity > 0))
                Positioned.fill(
                  child: IgnorePointer(
                    child: MintCloudForeground(
                      opacity: settings.cloudOpacity,
                      density: settings.cloudDensity,
                      topBias: 0.72,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 用户名列表：直接显示所有离线账户，点名字切换；底部进入账户管理。
class _AccountsCard extends StatelessWidget {
  const _AccountsCard({
    required this.miuix,
    required this.settings,
    required this.controller,
  });

  final bool miuix;
  final SettingsService settings;
  final LauncherController controller;

  @override
  Widget build(BuildContext context) {
    final accounts = settings.accounts;
    final selected = settings.selectedAccount;
    return MintCard(
      miuix: miuix,
      children: [
        if (accounts.isEmpty)
          MintTile(
            miuix: miuix,
            icon: Icons.person_add_alt_1,
            title: '添加账户',
            subtitle: '还没有离线账户，启动前先建一个',
            showDivider: false,
            onTap: () => _openAccounts(context),
          )
        else ...[
          for (final account in accounts)
            _AccountRow(
              miuix: miuix,
              account: account,
              selected: selected?.name == account.name,
              onTap: () => settings.selectAccount(account.name),
              showDivider: account != accounts.last,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${accounts.length} 个离线账户',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _openAccounts(context),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: const Icon(Icons.manage_accounts_outlined, size: 16),
                  label: const Text('管理'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _openAccounts(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AccountsPage(
          miuix: miuix,
          settings: settings,
          controller: controller,
        ),
      ),
    );
  }
}

class _AccountRow extends StatefulWidget {
  const _AccountRow({
    required this.miuix,
    required this.account,
    required this.selected,
    required this.onTap,
    required this.showDivider,
  });

  final bool miuix;
  final OfflineAccount account;
  final bool selected;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  State<_AccountRow> createState() => _AccountRowState();
}

class _AccountRowState extends State<_AccountRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final initial = widget.account.name.trim().isEmpty
        ? '?'
        : widget.account.name.trim()[0].toUpperCase();
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? cs.primaryContainer.withValues(alpha: 0.7)
                : _hover
                ? cs.onSurface.withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.selected
                      ? cs.primary
                      : cs.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: widget.selected ? cs.onPrimary : cs.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: widget.selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      widget.account.isAuthlib ? '外置登录' : '离线账户',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.selected)
                Icon(Icons.check_circle, size: 19, color: cs.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 版本管理入口（唯一一条），副标题显示当前启动版本。
class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.miuix,
    required this.controller,
    required this.active,
  });

  final bool miuix;
  final LauncherController controller;
  final String? active;

  @override
  Widget build(BuildContext context) {
    return MintCard(
      miuix: miuix,
      children: [
        MintTile(
          miuix: miuix,
          icon: Icons.layers_outlined,
          title: '版本管理',
          subtitle: active == null ? '还没有安装版本' : '当前版本：$active',
          showDivider: false,
          onTap: () => openVersionManager(context, miuix),
          trailing: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

/// 启动游戏 FAB：准备中可取消，运行中可结束游戏。
class _LaunchFab extends StatelessWidget {
  const _LaunchFab({
    required this.miuix,
    required this.controller,
    required this.settings,
    required this.active,
  });

  final bool miuix;
  final LauncherController controller;
  final SettingsService settings;
  final String? active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final busy = controller.isPreparing;
    final running = controller.state == LauncherState.running;
    final cancelling = controller.cancelRequested;
    final hasAccount = settings.accounts.isNotEmpty;
    final label = running
        ? '结束'
        : busy
        ? (cancelling ? '正在取消…' : '取消启动')
        : !hasAccount
        ? '添加账户'
        : active == null
        ? '下载游戏'
        : '启动游戏';
    final icon = running
        ? Icons.stop_rounded
        : busy
        ? Icons.close_rounded
        : !hasAccount
        ? Icons.person_add_alt_1
        : active == null
        ? Icons.download_rounded
        : Icons.play_arrow_rounded;
    final bg = running ? cs.error : cs.primary;
    final fg = running ? cs.onError : cs.onPrimary;

    Future<void> onPressed() async {
      if (running) {
        await controller.stopGame();
        return;
      }
      if (busy) {
        await controller.cancelLaunch();
        return;
      }
      if (!hasAccount) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AccountsPage(
              miuix: miuix,
              settings: settings,
              controller: controller,
            ),
          ),
        );
        return;
      }
      if (active == null) {
        NavRequests.requestTab(1);
        return;
      }
      await launchVersion(context, controller, settings, versionId: active);
    }

    final Widget iconWidget = busy && !cancelling
        ? (miuix
              ? MiuixCircularProgressIndicator(
                  size: 20,
                  strokeWidth: 2.2,
                  progress: controller.taskProgress,
                  colors: MiuixProgressIndicatorColors(
                    foregroundColor: fg,
                    disabledForegroundColor: fg,
                    backgroundColor: fg.withValues(alpha: 0.25),
                  ),
                )
              : SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    value: controller.taskProgress,
                    color: fg,
                    backgroundColor: fg.withValues(alpha: 0.25),
                  ),
                ))
        : Icon(icon, size: 22, color: fg);
    final labelWidget = Text(
      label,
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg),
    );

    if (miuix) {
      return MiuixFloatingActionButton(
        onPressed: cancelling ? null : onPressed,
        containerColor: cancelling ? bg.withValues(alpha: 0.6) : bg,
        shadowElevation: 6,
        minHeight: 56,
        shape: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [iconWidget, const SizedBox(width: 10), labelWidget],
          ),
        ),
      );
    }

    return FloatingActionButton.extended(
      heroTag: 'home-launch-fab',
      onPressed: cancelling ? null : onPressed,
      backgroundColor: cancelling ? bg.withValues(alpha: 0.6) : bg,
      foregroundColor: fg,
      elevation: 4,
      extendedPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      icon: iconWidget,
      label: labelWidget,
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mint/services/launcher/android_launch.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/nav_state.dart';
import 'package:mint/ui/pages/runtime_env_page.dart';
import 'package:mint/ui/pages/settings_page.dart' show openSettings;
import 'package:mint/ui/pages/theme_package_page.dart';
import 'package:mint/ui/widgets/mint_page.dart';
import 'package:mint/ui/widgets/mint_refresh.dart' show kMintPageScrollPhysics;

import 'common.dart';

/// 「更多」一级页：与首页 / 下载同级的三项列表 —— 设置 / 主题设置（MIUI）/
/// 下载器。底栏第三项就是这页（PageView 常驻 tab，不再 push）。
///
/// 下载器**不是新页面**：点了切到一级分页里的下载页（和底栏「下载」
/// 同一个 tab）。
class MintMorePage extends StatelessWidget {
  const MintMorePage({super.key, required this.miuix, this.embedded = false});

  final bool miuix;

  /// 作为一级分页嵌在首页壳里（底栏「更多」）：不画返回键，用大标题。
  final bool embedded;

  /// 切到下载一级分页。嵌在壳里时直接发 tab 请求；独立推入（测试钩子）
  /// 时先 pop 再切。
  void _goDownloader(BuildContext context) {
    if (!embedded) Navigator.of(context).pop();
    NavRequests.requestTab(1);
  }

  @override
  Widget build(BuildContext context) {
    final miuix = mintMiuixOf(context, this.miuix);
    return MintPageScaffold(
      miuix: miuix,
      title: '更多',
      largeTitle: embedded ? '更多' : null,
      showBack: !embedded,
      body: (padding) => ListView(
        physics: kMintPageScrollPhysics,
        padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 36),
        children: [
          MintCard(
            miuix: miuix,
            children: [
              MintTile(
                miuix: miuix,
                icon: Icons.settings_outlined,
                title: '设置',
                subtitle: '启动 · 网络 · 外观 · 快捷键',
                onTap: () => openSettings(context, miuix),
                trailing: const Icon(Icons.chevron_right),
              ),
              MintTile(
                miuix: miuix,
                icon: Icons.palette_outlined,
                title: '主题设置',
                subtitle: 'MIUI 主题包 · 背景图 · 弹窗背景',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MintThemePage(miuix: miuix),
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
              ),
              if (Platform.isAndroid)
                MintTile(
                  miuix: miuix,
                  icon: Icons.coffee_outlined,
                  title: '运行环境',
                  subtitle: 'Java 8 / 17 / 21 / 25 · 高版本游戏缺运行时来这里',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RuntimeEnvPage(miuix: miuix),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                ),
              MintTile(
                miuix: miuix,
                icon: Icons.download_outlined,
                title: '下载器',
                subtitle: '游戏 · 社区资源 · 任务管理',
                showDivider: false,
                onTap: () => _goDownloader(context),
                trailing: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 16),
            _GameProcessCard(miuix: miuix),
          ],
        ],
      ),
    );
  }
}

/// 游戏进程管理（Android）：状态 / 跳转游戏窗口 / 强制结束。
///
/// 解决两类「卡在游戏里」：游戏 task 被盖住回不去（跳转），或画面 / 输入
/// 彻底挂死退不出（强制结束）。游戏跑在 `:game` 独立进程，杀它不影响启动器；
/// 状态用 pid 文件 + /proc 复核（[AndroidRuntime.isGameRunning]）。
class _GameProcessCard extends StatefulWidget {
  const _GameProcessCard({required this.miuix});

  final bool miuix;

  @override
  State<_GameProcessCard> createState() => _GameProcessCardState();
}

class _GameProcessCardState extends State<_GameProcessCard> {
  /// null = 查询中；之后 true/false = 游戏在跑 / 没跑。
  bool? _running;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final running = await AndroidRuntime.isGameRunning();
    if (mounted) setState(() => _running = running);
  }

  Future<void> _foreground() async {
    final ok = await AndroidRuntime.foregroundGame();
    if (!mounted) return;
    showMintSnack(
      context,
      ok ? '已切回游戏画面' : '游戏没有在运行',
    );
    await _refresh();
  }

  Future<void> _forceStop() async {
    final confirmed = await showMintConfirmDialog(
      context,
      miuix: widget.miuix,
      title: '强制结束游戏进程？',
      message: '游戏会被立刻杀掉，未保存的世界进度会丢失。'
          '只在游戏彻底卡死、正常方式退不出去时使用。',
      confirmLabel: '强制结束',
      destructive: true,
    );
    if (!confirmed) return;
    final stopped = await AndroidRuntime.forceStopGame();
    if (!mounted) return;
    showMintSnack(
      context,
      stopped ? '游戏进程已结束' : '游戏没有在运行',
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final running = _running;
    final status = running == null
        ? '检查中…'
        : running
        ? '运行中'
        : '未运行';
    return MintCard(
      miuix: widget.miuix,
      children: [
        MintTile(
          miuix: widget.miuix,
          icon: Icons.videogame_asset_outlined,
          title: '游戏进程',
          subtitle: status,
        ),
        MintTile(
          miuix: widget.miuix,
          icon: Icons.open_in_new_outlined,
          title: '跳转到游戏画面',
          subtitle: '游戏被启动器或其他应用盖住时，把它切回前台',
          enabled: running == true,
          onTap: _foreground,
        ),
        MintTile(
          miuix: widget.miuix,
          icon: Icons.dangerous_outlined,
          title: '强制结束游戏进程',
          subtitle: '游戏彻底卡死、退不出去时的最后手段',
          enabled: running == true,
          onTap: _forceStop,
          showDivider: false,
        ),
      ],
    );
  }
}

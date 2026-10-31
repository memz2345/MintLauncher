import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/src/enums.dart';

import 'common.dart';
import 'shared_actions.dart';
import 'version_navigation.dart';
import '../widgets/mint_collapsible_pane.dart';
import '../widgets/mint_page.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/widgets/mint_refresh.dart';

/// 版本设置（独立页面）—— 布局照 PCL2 `PageInstance`：
/// 左侧一列分类（概览 / 启动 / 高级），右侧是当前分类的内容。
///
/// 空 = 跟随全局；「清空全部覆盖」把该版本恢复成完全跟随全局。
class VersionSettingsPage extends StatefulWidget {
  const VersionSettingsPage({
    super.key,
    required this.miuix,
    required this.versionId,
  });

  final bool miuix;
  final String versionId;

  @override
  State<VersionSettingsPage> createState() => _VersionSettingsPageState();
}

enum _SettingsSection {
  overview('概览', Icons.space_dashboard_outlined, Icons.space_dashboard),
  launch('启动', Icons.rocket_launch_outlined, Icons.rocket_launch),
  advanced('高级', Icons.tune, Icons.tune);

  const _SettingsSection(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _VersionSettingsPageState extends State<VersionSettingsPage> {
  late final VersionSettings _initial;
  late final TextEditingController _memory;
  late final TextEditingController _java;
  late final TextEditingController _jvm;
  late final TextEditingController _env;
  late final TextEditingController _server;
  late final TextEditingController _gameArgs;
  late final TextEditingController _preLaunch;
  late final TextEditingController _width;
  late final TextEditingController _height;
  bool? _isolationOverride;
  bool? _verifyFilesOverride;
  bool? _preLaunchWaitOverride;
  String? _graphicsOverride;
  String? _gcOverride;
  _SettingsSection _section = _SettingsSection.overview;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    _initial = settings.settingsFor(widget.versionId);
    _memory = TextEditingController(text: _initial.memoryMb?.toString() ?? '');
    _java = TextEditingController(text: _initial.javaPath ?? '');
    _jvm = TextEditingController(text: _initial.jvmArgs ?? '');
    _env = TextEditingController(text: _initial.envVars ?? '');
    _server = TextEditingController(text: _initial.serverAddress ?? '');
    _gameArgs = TextEditingController(text: _initial.extraGameArgs ?? '');
    _preLaunch = TextEditingController(text: _initial.preLaunchCommand ?? '');
    _width = TextEditingController(text: _initial.width?.toString() ?? '');
    _height = TextEditingController(text: _initial.height?.toString() ?? '');
    _isolationOverride = _initial.isolation;
    _verifyFilesOverride = _initial.verifyFiles;
    _preLaunchWaitOverride = _initial.preLaunchWait;
    _graphicsOverride = _initial.graphicsBackend;
    _gcOverride = _initial.gcPreset;
  }

  @override
  void dispose() {
    _memory.dispose();
    _java.dispose();
    _jvm.dispose();
    _env.dispose();
    _server.dispose();
    _gameArgs.dispose();
    _preLaunch.dispose();
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final controller = context.watch<LauncherController>();

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '版本设置',
      showBack: true,
      actions: [
        MintTopBarAction(
          miuix: mintMiuixOf(context),
          icon: Icons.restore,
          tooltip: '清空全部覆盖',
          onPressed: () => _clearOverrides(settings),
        ),
      ],
      body: (padding) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 780;
          if (!wide) {
            return Padding(
              padding: EdgeInsets.only(top: padding.top + 8),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: MintSegmentedTabs(
                      miuix: mintMiuixOf(context),
                      tabs: [for (final s in _SettingsSection.values) s.label],
                      selected: _section.index,
                      onSelected: (i) =>
                          setState(() => _section = _SettingsSection.values[i]),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _buildContent(
                      context,
                      settings,
                      controller,
                      horizontal: 16,
                    ),
                  ),
                ],
              ),
            );
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(16, padding.top + 10, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 左栏 = 可折叠的圆角卡片（默认展开）：头部是版本信息，
                // 下面是分类 + 快捷动作；收起来只剩图标。
                MintCollapsiblePane(
                  miuix: mintMiuixOf(context),
                  storageKey: 'versionSettingsSections',
                  title: '版本设置',
                  expandedWidth: 228,
                  headerExpanded: _buildVersionHead(context),
                  headerCollapsed: Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: loaderIconAsset(
                      loaderIconNameForVersion(widget.versionId),
                      size: 34,
                    ),
                  ),
                  child: _buildSidebarBody(context, settings, controller),
                  collapsedChild: _buildSidebarRail(
                    context,
                    settings,
                    controller,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildContent(
                    context,
                    settings,
                    controller,
                    horizontal: 0,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ───────────────────────── 左侧分类栏 ─────────────────────────

  /// 头部：loader 图标 + 版本 id + MC/加载器说明（展开态）。
  Widget _buildVersionHead(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final summary = versionSummary(
      context.read<LauncherController>(),
      widget.versionId,
    );
    return Row(
      children: [
        loaderIconAsset(loaderIconNameForVersion(widget.versionId), size: 32),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.versionId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'MC ${summary.mcVersion} · ${summary.loader}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 展开态：分类列表 + 快捷动作 + 保存状态说明。
  Widget _buildSidebarBody(
    BuildContext context,
    SettingsService settings,
    LauncherController controller,
  ) {
    final cs = Theme.of(context).colorScheme;
    final saved = settings.settingsFor(widget.versionId);
    return ListView(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      children: [
        for (final section in _SettingsSection.values) ...[
          _SettingsNavItem(
            miuix: mintMiuixOf(context),
            icon: section.icon,
            selectedIcon: section.selectedIcon,
            label: section.label,
            selected: _section == section,
            onTap: () => setState(() => _section = section),
          ),
          const SizedBox(height: 2),
        ],
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Divider(
            height: 1,
            color: cs.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        const SizedBox(height: 6),
        _SideAction(
          label: '管理内容',
          icon: Icons.inventory_2_outlined,
          onTap: () => openVersionContent(
            context,
            mintMiuixOf(context),
            widget.versionId,
          ),
        ),
        _SideAction(
          label: '打开版本目录',
          icon: Icons.folder_open,
          onTap: () => controller.openInFileManager(
            controller.gameDir.gameHome(
              widget.versionId,
              isolated: settings.effectiveFor(widget.versionId).isolation,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
          child: Text(
            saved.isEmpty ? '目前完全跟随全局设置' : '已保存该版本的专属设置',
            style: TextStyle(
              fontSize: 11,
              height: 1.45,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 折叠态：分类 / 动作都收成图标（tooltip 认人）。
  Widget _buildSidebarRail(
    BuildContext context,
    SettingsService settings,
    LauncherController controller,
  ) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      children: [
        for (final section in _SettingsSection.values)
          MintPaneRailButton(
            tooltip: section.label,
            selected: _section == section,
            onTap: () => setState(() => _section = section),
            child: Icon(
              _section == section ? section.selectedIcon : section.icon,
              size: 20,
              color: _section == section
                  ? cs.onPrimaryContainer
                  : cs.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: 8),
        MintPaneRailButton(
          tooltip: '管理内容',
          selected: false,
          onTap: () => openVersionContent(
            context,
            mintMiuixOf(context),
            widget.versionId,
          ),
          child: Icon(
            Icons.inventory_2_outlined,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
        ),
        MintPaneRailButton(
          tooltip: '打开版本目录',
          selected: false,
          onTap: () => controller.openInFileManager(
            controller.gameDir.gameHome(
              widget.versionId,
              isolated: settings.effectiveFor(widget.versionId).isolation,
            ),
          ),
          child: Icon(Icons.folder_open, size: 20, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  // ───────────────────────── 右侧内容 ─────────────────────────

  Widget _buildContent(
    BuildContext context,
    SettingsService settings,
    LauncherController controller, {
    required double horizontal,
  }) {
    final summary = versionSummary(controller, widget.versionId);
    final global = settings.effectiveFor(widget.versionId);
    final isolation = _isolationOverride ?? global.isolation;

    final children = switch (_section) {
      _SettingsSection.overview => _overviewChildren(
        context,
        settings,
        controller,
        summary,
        global,
      ),
      _SettingsSection.launch => _launchChildren(context, settings, isolation),
      _SettingsSection.advanced => _advancedChildren(context, settings),
    };

    return ListView(
      key: PageStorageKey('version-settings-${_section.name}'),
      physics: kMintPageScrollPhysics,
      padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 28),
      children: [
        ...children,
        if (_section != _SettingsSection.overview) ...[
          const SizedBox(height: 18),
          _buildSaveRow(context, settings),
        ],
      ],
    );
  }

  List<Widget> _overviewChildren(
    BuildContext context,
    SettingsService settings,
    LauncherController controller,
    ({String id, String mcVersion, String loader}) summary,
    EffectiveVersionSettings effective,
  ) {
    final cs = Theme.of(context).colorScheme;
    final saved = settings.settingsFor(widget.versionId);
    final isolated = effective.isolation;
    final mods = controller.gameDir
        .modsOf(widget.versionId, isolated: isolated)
        .length;
    final home = controller.gameDir.gameHome(
      widget.versionId,
      isolated: isolated,
    );
    return [
      MintSectionHeader(
        miuix: mintMiuixOf(context),
        title: '版本信息',
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      ),
      MintCard(
        miuix: mintMiuixOf(context),
        children: [
          MintTile(
            miuix: mintMiuixOf(context),
            icon: Icons.videogame_asset_outlined,
            title: 'Minecraft ${summary.mcVersion}',
            subtitle:
                '${summary.loader} · ${saved.isEmpty ? '跟随全局设置' : '独立设置'}',
            trailing: _StateBadge(
              label: isolated ? '版本隔离' : '共享目录',
              color: isolated ? cs.primary : cs.onSurfaceVariant,
            ),
          ),
          MintTile(
            miuix: mintMiuixOf(context),
            icon: Icons.memory,
            title: '最大内存',
            subtitle: effective.memoryAuto
                ? 'AUTO（跟随全局）'
                : '${effective.memoryMb} MB',
          ),
          MintTile(
            miuix: mintMiuixOf(context),
            icon: Icons.terminal,
            title: 'Java',
            subtitle: effective.javaPath.isEmpty
                ? '自动检测 / 下载 JRE'
                : effective.javaPath,
          ),
          MintTile(
            miuix: mintMiuixOf(context),
            icon: Icons.folder_outlined,
            title: '游戏目录',
            subtitle: home,
            showDivider: (saved.serverAddress ?? '').isNotEmpty,
          ),
          if ((saved.serverAddress ?? '').isNotEmpty)
            MintTile(
              miuix: mintMiuixOf(context),
              icon: Icons.dns_outlined,
              title: '自动连接',
              subtitle: saved.serverAddress!,
            ),
        ],
      ),
      MintSectionHeader(miuix: mintMiuixOf(context), title: '内容'),
      MintCard(
        miuix: mintMiuixOf(context),
        children: [
          MintTile(
            miuix: mintMiuixOf(context),
            icon: Icons.extension_outlined,
            title: '模组',
            subtitle: mods == 0 ? '还没有模组' : '$mods 个已启用 / 已安装',
            onTap: () => openVersionContent(
              context,
              mintMiuixOf(context),
              widget.versionId,
            ),
            trailing: const Icon(Icons.chevron_right),
          ),
          MintTile(
            miuix: mintMiuixOf(context),
            icon: Icons.tune,
            title: '修改启动选项',
            subtitle: '内存 / Java / 窗口 / JVM / 后端 / 校验',
            showDivider: false,
            onTap: () => setState(() => _section = _SettingsSection.launch),
            trailing: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Text(
        saved.isEmpty
            ? '当前版本全部跟随全局设置。切换到「启动」或「高级」可单独覆盖。'
            : '本页保存的设置只对该版本生效，不影响其他版本。',
        style: TextStyle(
          fontSize: 11.5,
          height: 1.5,
          color: cs.onSurfaceVariant,
        ),
      ),
    ];
  }

  List<Widget> _launchChildren(
    BuildContext context,
    SettingsService settings,
    bool isolation,
  ) {
    return [
      MintSectionHeader(
        miuix: mintMiuixOf(context),
        title: '启动',
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      ),
      MintCard(
        miuix: mintMiuixOf(context),
        children: [
          _FieldRow(
            miuix: mintMiuixOf(context),
            icon: Icons.memory,
            title: '最大内存',
            subtitle: '留空 = 跟随全局（${settings.memoryMb} MB）',
            child: _NumberField(
              miuix: mintMiuixOf(context),
              controller: _memory,
              hint: '${settings.memoryMb}',
              suffix: 'MB',
            ),
          ),
          _FieldRow(
            miuix: mintMiuixOf(context),
            icon: Icons.terminal,
            title: 'Java 路径',
            subtitle:
                '留空 = 自动检测 / 下载 JRE（全局：'
                '${settings.javaPath.isEmpty ? '自动' : settings.javaPath}）',
            child: _TextField(
              miuix: mintMiuixOf(context),
              controller: _java,
              hint: r'C:\Program Files\Java\jdk-21\bin\java.exe',
            ),
          ),
          _IsolationRow(
            miuix: mintMiuixOf(context),
            value: isolation,
            overridden: _isolationOverride != null,
            global: settings.effectiveFor(widget.versionId).isolation,
            onChanged: (v) => setState(() => _isolationOverride = v),
            onFollowGlobal: () => setState(() => _isolationOverride = null),
          ),
          _FieldRow(
            miuix: mintMiuixOf(context),
            icon: Icons.aspect_ratio_outlined,
            title: '窗口尺寸',
            subtitle: '留空 = 跟随全局（${settings.gameWindowMode.label}）',
            child: Row(
              children: [
                Expanded(
                  child: _NumberField(
                    miuix: mintMiuixOf(context),
                    controller: _width,
                    hint: '宽（留空跟随全局）',
                    suffix: 'px',
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('×'),
                ),
                Expanded(
                  child: _NumberField(
                    miuix: mintMiuixOf(context),
                    controller: _height,
                    hint: '高（留空跟随全局）',
                    suffix: 'px',
                  ),
                ),
              ],
            ),
          ),
          _FieldRow(
            miuix: mintMiuixOf(context),
            icon: Icons.dns_outlined,
            title: '自动连接服务器',
            subtitle: '启动后自动进入该服务器，留空 = 不连',
            showDivider: false,
            child: _TextField(
              miuix: mintMiuixOf(context),
              controller: _server,
              hint: 'mc.example.com 或 host:port',
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _advancedChildren(
    BuildContext context,
    SettingsService settings,
  ) {
    final cs = Theme.of(context).colorScheme;
    final verify = _verifyFilesOverride ?? settings.verifyFiles;
    final graphics = _graphicsOverride == null
        ? settings.graphicsBackend
        : GraphicsBackend.fromId(_graphicsOverride);
    final gc = _gcOverride == null
        ? settings.gcPreset
        : GcPreset.fromId(_gcOverride);
    final preLaunchWait = _preLaunchWaitOverride ?? settings.preLaunchWait;
    return [
      MintSectionHeader(
        miuix: mintMiuixOf(context),
        title: '高级',
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      ),
      MintCard(
        miuix: mintMiuixOf(context),
        children: [
          _FieldRow(
            miuix: mintMiuixOf(context),
            icon: Icons.code,
            title: 'JVM 参数',
            subtitle: '一行一个，留空 = 跟随全局',
            child: _TextField(
              miuix: mintMiuixOf(context),
              controller: _jvm,
              hint: '-XX:+UseG1GC\n-Dfile.encoding=UTF-8',
              maxLines: 4,
            ),
          ),
          _FieldRow(
            miuix: mintMiuixOf(context),
            icon: Icons.sports_esports_outlined,
            title: '游戏参数',
            subtitle: '追加在版本 JSON 游戏参数之后，留空 = 跟随全局',
            child: _TextField(
              miuix: mintMiuixOf(context),
              controller: _gameArgs,
              hint: '--demo\n--width 1280',
              maxLines: 3,
            ),
          ),
          _FieldRow(
            miuix: mintMiuixOf(context),
            icon: Icons.data_object,
            title: '环境变量',
            subtitle: '一行一个 KEY=VALUE，留空 = 跟随全局',
            child: _TextField(
              miuix: mintMiuixOf(context),
              controller: _env,
              hint: 'JAVA_HOME=C:\\jdk-21',
              maxLines: 3,
            ),
          ),
          _FieldRow(
            miuix: mintMiuixOf(context),
            icon: Icons.play_circle_outline,
            title: '启动前命令',
            subtitle: 'cmd /c 在游戏主目录执行，留空 = 跟随全局',
            child: _TextField(
              miuix: mintMiuixOf(context),
              controller: _preLaunch,
              hint: r'echo 准备启动 {version}',
              maxLines: 3,
            ),
          ),
          if (_preLaunch.text.trim().isNotEmpty ||
              settings.preLaunchCommand.isNotEmpty)
            MintSwitchTile(
              miuix: mintMiuixOf(context),
              icon: Icons.hourglass_bottom,
              title: '等待命令结束',
              subtitle: '关闭 = 拉起命令后立刻继续启动游戏',
              value: preLaunchWait,
              onChanged: (v) => setState(() => _preLaunchWaitOverride = v),
            ),
          _ChoiceRow(
            miuix: mintMiuixOf(context),
            icon: Icons.auto_awesome_outlined,
            title: '垃圾回收器',
            subtitle: _gcOverride == null
                ? '跟随全局：${settings.gcPreset.label}'
                : '本版本：${gc.label}',
            onTap: () => _pickGc(context, settings),
          ),
          _ChoiceRow(
            miuix: mintMiuixOf(context),
            icon: Icons.imagesearch_roller_outlined,
            title: '强制图形后端',
            subtitle: _graphicsOverride == null
                ? '跟随全局：${settings.graphicsBackend.label}'
                : '本版本：${graphics.label}',
            onTap: () => _pickGraphics(context, settings),
          ),
          _VerifyRow(
            miuix: mintMiuixOf(context),
            value: verify,
            overridden: _verifyFilesOverride != null,
            global: settings.verifyFiles,
            onChanged: (v) => setState(() => _verifyFilesOverride = v),
            onFollowGlobal: () => setState(() => _verifyFilesOverride = null),
          ),
        ],
      ),
      const SizedBox(height: 12),
      MintCard(
        miuix: mintMiuixOf(context),
        children: [
          MintTile(
            miuix: mintMiuixOf(context),
            icon: Icons.restore,
            title: '清空全部覆盖',
            subtitle: '恢复为完全跟随全局设置',
            showDivider: false,
            onTap: () => _clearOverrides(settings),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          verify
              ? '启动时会校验库 / 资源与 SHA-1；缺失的文件自动补齐。'
              : '已关闭文件校验：已有文件直接信任，只补缺失文件。',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.5,
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
    ];
  }

  Future<void> _pickGc(BuildContext context, SettingsService settings) async {
    final result = await showMintChoiceDialog<String>(
      context,
      miuix: mintMiuixOf(context),
      title: '垃圾回收器',
      selected: _gcOverride ?? '',
      options: [
        const MintChoice(value: '', label: '跟随全局', subtitle: '使用启动器设置'),
        for (final preset in GcPreset.values)
          MintChoice(value: preset.id, label: preset.label),
      ],
    );
    if (result == null) return;
    setState(() => _gcOverride = result.isEmpty ? null : result);
  }

  Future<void> _pickGraphics(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await showMintChoiceDialog<String>(
      context,
      miuix: mintMiuixOf(context),
      title: '强制图形后端',
      selected: _graphicsOverride ?? '',
      options: [
        const MintChoice(value: '', label: '跟随全局', subtitle: '使用启动器设置'),
        for (final backend in GraphicsBackend.values)
          if (backend != GraphicsBackend.auto)
            MintChoice(value: backend.id, label: backend.label),
      ],
    );
    if (result == null) return;
    setState(() => _graphicsOverride = result.isEmpty ? null : result);
  }

  Widget _buildSaveRow(BuildContext context, SettingsService settings) {
    final cs = Theme.of(context).colorScheme;
    final saved = settings.settingsFor(widget.versionId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MintPrimaryButton(
          miuix: mintMiuixOf(context),
          label: '保存设置',
          icon: Icons.check,
          height: 50,
          onPressed: () => _save(settings),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            saved.isEmpty ? '当前版本全部跟随全局设置' : '已保存该版本的专属设置',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  void _save(SettingsService settings) {
    final memoryText = _memory.text.trim();
    final memory = memoryText.isEmpty ? null : int.tryParse(memoryText);
    if (memoryText.isNotEmpty && (memory == null || memory < 256)) {
      showMintSnack(context, '内存请填 256 以上的整数（MB）');
      return;
    }
    final width = int.tryParse(_width.text.trim());
    final height = int.tryParse(_height.text.trim());
    final hasCommand = _preLaunch.text.trim().isNotEmpty;
    settings.updateVersionSettings(
      widget.versionId,
      VersionSettings(
        memoryMb: memory,
        javaPath: _java.text.trim(),
        isolation: _isolationOverride,
        jvmArgs: _jvm.text.trim(),
        envVars: _env.text.trim(),
        serverAddress: _server.text.trim(),
        width: width != null && width > 0 ? width : null,
        height: height != null && height > 0 ? height : null,
        verifyFiles: _verifyFilesOverride,
        graphicsBackend: _graphicsOverride,
        extraGameArgs: _gameArgs.text.trim(),
        preLaunchCommand: _preLaunch.text.trim(),
        preLaunchWait: hasCommand ? _preLaunchWaitOverride : null,
        gcPreset: _gcOverride,
      ),
    );
    showMintSnack(context, '已保存 ${widget.versionId} 的设置');
    setState(() {});
  }

  Future<void> _clearOverrides(SettingsService settings) async {
    final ok = await showMintConfirmDialog(
      context,
      miuix: mintMiuixOf(context),
      title: '清空版本覆盖？',
      message: '${widget.versionId} 将完全跟随全局设置。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!ok || !mounted) return;
    settings.updateVersionSettings(widget.versionId, VersionSettings());
    if (!mounted) return;
    showMintSnack(context, '已恢复为跟随全局');
    Navigator.of(context).maybePop();
  }
}

class _SettingsNavItem extends StatefulWidget {
  const _SettingsNavItem({
    required this.miuix,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final bool miuix;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SettingsNavItem> createState() => _SettingsNavItemState();
}

class _SettingsNavItemState extends State<_SettingsNavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selected = widget.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected
                ? cs.primaryContainer
                : _hover
                ? cs.onSurface.withValues(alpha: 0.055)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
                child: Row(
                  children: [
                    Icon(
                      selected ? widget.selectedIcon : widget.icon,
                      size: 21,
                      color: selected
                          ? cs.onPrimaryContainer
                          : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: selected
                              ? cs.onPrimaryContainer
                              : cs.onSurface,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SideAction extends StatelessWidget {
  const _SideAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 13.5, color: cs.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.miuix,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool miuix;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MintTile(
      miuix: miuix,
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _VerifyRow extends StatelessWidget {
  const _VerifyRow({
    required this.miuix,
    required this.value,
    required this.overridden,
    required this.global,
    required this.onChanged,
    required this.onFollowGlobal,
  });

  final bool miuix;
  final bool value;
  final bool overridden;
  final bool global;
  final ValueChanged<bool> onChanged;
  final VoidCallback onFollowGlobal;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MintTile(
          miuix: miuix,
          icon: Icons.fact_check_outlined,
          title: '校验文件完整性',
          subtitle: overridden
              ? '本版本：${value ? '校验' : '不校验'}（全局 ${global ? '校验' : '不校验'}）'
              : '跟随全局：${global ? '校验' : '不校验'}',
          trailing: miuix
              ? MiuixSwitch(
                  value: value,
                  onChanged: onChanged,
                  colors: mintSwitchColorsOf(context),
                )
              : Switch(value: value, onChanged: onChanged),
        ),
        if (overridden)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const SizedBox(width: 36),
                Text(
                  value ? '启动前会校对已有文件的哈希' : '已有文件直接信任，只补缺失文件',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onFollowGlobal,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('跟随全局'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _IsolationRow extends StatelessWidget {
  const _IsolationRow({
    required this.miuix,
    required this.value,
    required this.overridden,
    required this.global,
    required this.onChanged,
    required this.onFollowGlobal,
  });

  final bool miuix;
  final bool value;
  final bool overridden;
  final bool global;
  final ValueChanged<bool> onChanged;
  final VoidCallback onFollowGlobal;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MintTile(
          miuix: miuix,
          icon: Icons.folder_copy_outlined,
          title: '版本隔离',
          subtitle: overridden
              ? '本版本单独设置：${value ? '开' : '关'}（默认 ${global ? '开' : '关'}）'
              : '跟随全局（默认 ${global ? '开' : '关'}；'
                    '版本目录有 mods/saves 时自动开）',
          trailing: miuix
              ? MiuixSwitch(
                  value: value,
                  onChanged: onChanged,
                  colors: mintSwitchColorsOf(context),
                )
              : Switch(value: value, onChanged: onChanged),
        ),
        if (overridden)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const SizedBox(width: 36),
                Text(
                  '存档 / 模组 / 配置会放进 versions/${'<版本>'} 目录',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onFollowGlobal,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('跟随全局'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.miuix,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.showDivider = true,
  });

  final bool miuix;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 21, color: cs.primary),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 33),
            child: Text(
              subtitle,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(padding: const EdgeInsets.only(left: 33), child: child),
        ],
      ),
    );
    if (!showDivider) return body;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        body,
        Divider(
          height: 1,
          indent: 16,
          endIndent: 16,
          color: cs.outlineVariant.withValues(alpha: 0.4),
        ),
      ],
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.miuix,
    required this.controller,
    required this.hint,
    this.maxLines = 1,
  });

  final bool miuix;
  final TextEditingController controller;
  final String hint;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      return MiuixTextField(
        controller: controller,
        label: hint,
        useLabelAsPlaceholder: true,
        singleLine: maxLines == 1,
        maxLines: maxLines,
        insideMargin: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      );
    }
    return TextField(
      controller: controller,
      maxLines: maxLines,
      decoration: InputDecoration(hintText: hint),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.miuix,
    required this.controller,
    required this.hint,
    required this.suffix,
  });

  final bool miuix;
  final TextEditingController controller;
  final String hint;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      return MiuixTextField(
        controller: controller,
        label: '内存（MB），留空跟随全局',
        useLabelAsPlaceholder: true,
        singleLine: true,
        insideMargin: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      );
    }
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(hintText: hint, suffixText: suffix),
    );
  }
}

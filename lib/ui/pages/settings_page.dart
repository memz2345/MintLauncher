import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/launcher/java_runtime.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/system_memory.dart';
import 'package:mint/services/theme_package.dart';
import 'package:mint/services/vtouch/vtouch_overlay_service.dart';
import 'package:mint/services/window_backdrop.dart';
import 'package:mint/src/enums.dart';

import 'common.dart';
import 'about_page.dart';
import 'android_display_page.dart';
import 'runtime_env_page.dart';
import 'logs_page.dart';
import 'mint_choice_page.dart';
import 'theme_package_page.dart';
import 'shared_actions.dart' show activeVersionId;
import '../widgets/mint_page.dart';
import '../widgets/page_background.dart' show MintPageBackgroundKey;
import '../../services/launcher/android_tweaks.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/widgets/mint_refresh.dart';

/// 设置页的分类（HMCL「设置」左侧大类）。
enum _SettingsCategory {
  launch('启动', Icons.play_circle_outline),
  network('网络', Icons.wifi_outlined),
  appearance('外观', Icons.palette_outlined),
  shortcuts('快捷键', Icons.keyboard_outlined),
  about('关于', Icons.info_outline);

  const _SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 推入设置页（一级导航的「设置」不再是一个 tab，而是单独页面）。
Future<void> openSettings(BuildContext context, bool miuix) async {
  // 已经压着别的二级页（设置 / 版本管理 / 下载详情）时不再叠一层。
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return;
  await Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(miuix: miuix)));
}

/// 设置页：启动器配置（目录/Java/内存/下载源）+ 外观（双风格）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<JavaRuntime>? _javas;

  /// 分类用 ValueNotifier 而不是 setState：切分类时只重建右侧内容和
  /// 左侧的背景色，卡片行（InkWell / MiuixPressable）本身不重建，mdui
  /// 1400ms 的涟漪才能继续扩散完，不会一切换就消失。
  final ValueNotifier<_SettingsCategory> _category = ValueNotifier(
    _SettingsCategory.launch,
  );

  /// Android 体验微调（灵敏度 / 陀螺仪 / 高刷）。非 Android 为 null。
  AndroidTweaks? _androidTweaks;

  @override
  void initState() {
    super.initState();
    _detectJavas();
    if (Platform.isAndroid) {
      AndroidTweaks.load().then((t) {
        if (mounted) setState(() => _androidTweaks = t);
      });
    }
  }

  Future<void> _detectJavas() async {
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    final list = await controller.javaService.detectAll(
      customPath: settings.javaPath,
    );
    if (mounted) setState(() => _javas = list);
  }

  @override
  void dispose() {
    _category.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '设置',
      showBack: true,
      pageBackgroundKey: MintPageBackgroundKey.settings.id,
      body: (padding) => Padding(
        padding: padding + const EdgeInsets.fromLTRB(16, 6, 16, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            if (!wide) {
              // 竖屏 / 窄屏：取消分类选择（旧版是横向胶囊 tab），所有设置
              // 在一个页面里按分区铺开。整页就是一个 ListView —— miuix 的
              // 大标题折叠与顶栏渐变模糊带都能吃到同一份滚动。
              return _body(context, EdgeInsets.zero, _SettingsCategory.values);
            }
            final content = ValueListenableBuilder<_SettingsCategory>(
              valueListenable: _category,
              builder: (context, category, _) =>
                  _body(context, EdgeInsets.zero, [category]),
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 232, child: _buildCategoryPane(context)),
                const SizedBox(width: 12),
                Expanded(child: content),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 宽屏左栏：HMCL 设置左侧的大类列表。
  Widget _buildCategoryPane(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: MintCard(
        miuix: mintMiuixOf(context),
        children: [
          for (final (i, cat) in _SettingsCategory.values.indexed)
            Stack(
              children: [
                // 只有这层背景色跟着选中态重建；MintTile 本体不重建，
                // 点击产生的 ripple / 按压遮罩可以继续跑完。
                Positioned.fill(
                  child: ValueListenableBuilder<_SettingsCategory>(
                    valueListenable: _category,
                    builder: (context, selected, _) => ColoredBox(
                      color: selected == cat
                          ? cs.primary.withValues(alpha: 0.10)
                          : Colors.transparent,
                    ),
                  ),
                ),
                MintTile(
                  miuix: mintMiuixOf(context),
                  icon: cat.icon,
                  title: cat.label,
                  showDivider: i != _SettingsCategory.values.length - 1,
                  onTap: () => _category.value = cat,
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    EdgeInsets padding,
    List<_SettingsCategory> categories,
  ) {
    final settings = context.watch<SettingsService>();
    final controller = context.watch<LauncherController>();
    final miuix = mintMiuixOf(context, widget.miuix);

    return ListView(
      physics: kMintPageScrollPhysics,
      padding: padding + const EdgeInsets.fromLTRB(0, 4, 0, 28),
      children: [
        for (final category in categories) ...[
        if (category == _SettingsCategory.launch) ...[
          _sectionTitle(context, '启动'),
          GroupCard(
            miuix: miuix,
            children: [
              TileRow(
                miuix: miuix,
                icon: Icons.folder_outlined,
                title: '游戏目录',
                subtitle: controller.gameDir.root,
                onTap: () => _editGameDir(context, settings, controller),
                trailing: const Icon(Icons.chevron_right),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.memory,
                title: 'Java 运行时',
                subtitle: _javaSummary(settings),
                // Android 的 JRE 由随包/FCL 运行时管理，系统里装的 Java 用不上；
                // 桌面才走「选择自定义 java.exe」那条路。
                onTap: Platform.isAndroid
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RuntimeEnvPage(miuix: miuix),
                        ),
                      )
                    : () => _pickJava(context, settings, controller),
                trailing: const Icon(Icons.chevron_right),
              ),
              SwitchRow(
                miuix: miuix,
                icon: Icons.system_update_alt,
                title: '自动安装 Java',
                subtitle: Platform.isAndroid
                    ? '启动时缺少对应版本，自动下载到「运行环境」'
                    : '启动时缺少对应版本，就从 Mojang 下载官方运行时',
                value: settings.autoInstallJava,
                onChanged: (v) => settings.autoInstallJava = v,
              ),
              _MemoryTile(miuix: miuix),
              SwitchRow(
                miuix: miuix,
                icon: Icons.translate,
                title: '启动游戏时使用简体中文',
                subtitle: '启动前把游戏内语言写为简体中文（options.txt）',
                value: settings.gameLangZh,
                onChanged: (v) => settings.gameLangZh = v,
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.fullscreen,
                title: '游戏窗口',
                subtitle: settings.gameWindowMode.label,
                onTap: () => _pickWindowMode(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              if (settings.gameWindowMode == GameWindowMode.custom)
                TileRow(
                  miuix: miuix,
                  icon: Icons.aspect_ratio_outlined,
                  title: '窗口尺寸',
                  subtitle: '${settings.gameWidth} × ${settings.gameHeight}',
                  onTap: () => _editResolution(context, settings),
                  trailing: const Icon(Icons.chevron_right),
                ),
              TileRow(
                miuix: miuix,
                icon: Icons.visibility_outlined,
                title: '启动后启动器',
                subtitle: settings.launcherVisibility.label,
                onTap: () => _pickLauncherVisibility(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.speed,
                title: '游戏进程优先级',
                subtitle: settings.processPriority == ProcessPriority.normal
                    ? '中（默认）'
                    : '${settings.processPriority.label}（Windows 生效）',
                onTap: () => _pickProcessPriority(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.cloud_download_outlined,
                title: '下载源',
                subtitle: switch (settings.downloadSource) {
                  DownloadSource.auto => '自动（BMCLAPI 优先，失败回官方）',
                  DownloadSource.bmcl => 'BMCLAPI（国内镜像）',
                  DownloadSource.official => 'Mojang 官方',
                },
                showDivider: false,
                onTap: () => _pickDownloadSource(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _sectionTitle(context, '启动高级'),
          GroupCard(
            miuix: miuix,
            children: [
              TileRow(
                miuix: miuix,
                icon: Icons.inventory_2_outlined,
                title: '版本隔离',
                subtitle:
                    '${settings.isolationMode.label} · '
                    '${settings.isolationMode.desc}；版本目录有 mods/saves 自动隔离',
                onTap: () => _pickIsolationMode(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.terminal,
                title: 'JVM 参数',
                subtitle: settings.jvmArgs.isEmpty
                    ? '未设置（一行一个）'
                    : settings.jvmArgs.split('\n').first,
                onTap: () => _editMultiline(
                  context,
                  title: 'JVM 参数（一行一个）',
                  hint: '-XX:+UseG1GC\n-Dfoo=bar',
                  initial: settings.jvmArgs,
                ),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.sports_esports_outlined,
                title: '游戏参数',
                subtitle: settings.extraGameArgs.isEmpty
                    ? '追加到版本参数之后（一行一个）'
                    : settings.extraGameArgs.split('\n').first,
                onTap: () => _editMultiline(
                  context,
                  title: '游戏参数（一行一个）',
                  hint: '--demo\n--width 1280',
                  initial: settings.extraGameArgs,
                  onSaved: (v) => settings.extraGameArgs = v,
                ),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.data_object,
                title: '环境变量',
                subtitle: settings.envVars.isEmpty
                    ? '未设置（一行一个 KEY=VALUE）'
                    : settings.envVars.split('\n').first,
                onTap: () => _editMultiline(
                  context,
                  title: '环境变量（一行一个 KEY=VALUE）',
                  hint: 'JAVA_HOME=C:\\jdk',
                  initial: settings.envVars,
                ),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.play_circle_outline,
                title: '启动前命令',
                subtitle: settings.preLaunchCommand.isEmpty
                    ? '未设置（cmd /c，在游戏主目录执行）'
                    : settings.preLaunchCommand.split('\n').first,
                onTap: () => _editMultiline(
                  context,
                  title: '启动前命令',
                  hint: r'echo 准备启动 %INST_NAME%',
                  initial: settings.preLaunchCommand,
                  onSaved: (v) => settings.preLaunchCommand = v,
                ),
              ),
              if (settings.preLaunchCommand.isNotEmpty)
                SwitchRow(
                  miuix: miuix,
                  icon: Icons.hourglass_bottom,
                  title: '等待命令结束',
                  subtitle: '关闭 = 拉起命令后立刻继续启动游戏',
                  value: settings.preLaunchWait,
                  onChanged: (v) => settings.preLaunchWait = v,
                ),
              TileRow(
                miuix: miuix,
                icon: Icons.dns_outlined,
                title: '自动连接服务器',
                subtitle: settings.serverAddress.isEmpty
                    ? '未设置（启动后自动进服）'
                    : settings.serverAddress,
                onTap: () => _editText(
                  context,
                  title: '自动连接服务器',
                  hint: 'host 或 host:port（留空关闭）',
                  initial: settings.serverAddress,
                ),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.auto_awesome_outlined,
                title: '垃圾回收器',
                subtitle: settings.gcPreset.label,
                onTap: () => _pickGcPreset(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.imagesearch_roller_outlined,
                title: '强制图形后端',
                subtitle: settings.graphicsBackend.label,
                onTap: () => _pickGraphicsBackend(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              // Android 专属：渲染器是「GL 翻译层」，不是画质档位 —— 换错了
              // 会直接进不去游戏，所以说明要写清取舍。
              if (Platform.isAndroid) ...[
                TileRow(
                  miuix: miuix,
                  icon: Icons.coffee_outlined,
                  title: '运行环境（Java）',
                  subtitle: 'Java 8 / 17 / 21 / 25 · 26.x 需要 25，缺了在这里下载',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RuntimeEnvPage(miuix: miuix),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                ),
                TileRow(
                  miuix: miuix,
                  icon: Icons.videogame_asset_outlined,
                  title: 'Android 渲染器',
                  subtitle:
                      '${settings.androidRenderer.label} · ${settings.androidRenderer.badge}',
                  onTap: () => _pickAndroidRenderer(context, settings),
                  trailing: const Icon(Icons.chevron_right),
                ),
                TileRow(
                  miuix: miuix,
                  icon: Icons.aspect_ratio_outlined,
                  title: '游戏窗口 / 渲染分辨率',
                  subtitle: '拖角标改画面大小（即时），渲染分辨率按横向比例设定',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AndroidDisplayPage(miuix: miuix),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                ),
                SwitchRow(
                  miuix: miuix,
                  icon: Icons.monitor_heart_outlined,
                  title: '游戏内显示 FPS',
                  subtitle: '左上角叠一行实时帧率（FCL 渲染计数器）',
                  value: settings.androidShowFps,
                  onChanged: (v) => settings.androidShowFps = v,
                ),
                // 体验微调（FCL MenuSetting 对应项）：存原生 game_tweaks.json，
                // 游戏内菜单改的是同一份，游戏在后台也会被广播立刻刷新。
                if (_androidTweaks != null) ...[
                  _SliderTile(
                    miuix: miuix,
                    icon: Icons.speed_outlined,
                    title: '转视角灵敏度',
                    value: _androidTweaks!.lookSensitivity,
                    min: AndroidTweaks.minLookSensitivity,
                    max: AndroidTweaks.maxLookSensitivity,
                    divisions: 14,
                    label: _androidTweaks!.sensitivityLabel(),
                    onChanged: (v) {
                      final next = _androidTweaks!.copyWith(lookSensitivity: v);
                      setState(() => _androidTweaks = next);
                      AndroidTweaks.save(next);
                    },
                  ),
                  SwitchRow(
                    miuix: miuix,
                    icon: Icons.screen_rotation_alt_outlined,
                    title: '陀螺仪转视角',
                    subtitle: _androidTweaks!.gyroscopeAvailable
                        ? '倾斜设备转动视角，进世界后生效（游戏内也可开）'
                        : '此设备没有陀螺仪传感器',
                    value:
                        _androidTweaks!.enableGyroscope &&
                        _androidTweaks!.gyroscopeAvailable,
                    onChanged: _androidTweaks!.gyroscopeAvailable
                        ? (v) {
                            final next = _androidTweaks!.copyWith(
                              enableGyroscope: v,
                            );
                            setState(() => _androidTweaks = next);
                            AndroidTweaks.save(next);
                          }
                        : null,
                  ),
                  SwitchRow(
                    miuix: miuix,
                    icon: Icons.auto_mode_outlined,
                    title: '最高屏幕刷新率',
                    subtitle: '游戏运行时切到同分辨率下的最高刷新率档位',
                    value: _androidTweaks!.requestMaxRefreshRate,
                    onChanged: (v) {
                      final next = _androidTweaks!.copyWith(
                        requestMaxRefreshRate: v,
                      );
                      setState(() => _androidTweaks = next);
                      AndroidTweaks.save(next);
                    },
                  ),
                ],
              ],
              SwitchRow(
                miuix: miuix,
                icon: Icons.fact_check_outlined,
                title: '校验文件完整性',
                subtitle: '关闭后已有文件直接信任，只补缺失文件（版本可覆盖）',
                value: settings.verifyFiles,
                onChanged: (v) => settings.verifyFiles = v,
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.article_outlined,
                title: '启动器日志',
                subtitle: '查看本次运行输出 / 打开独立日志窗口',
                showDivider: false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LogsPage(miuix: miuix),
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (category == _SettingsCategory.appearance) ...[
          // 虚拟触控（桌面）：Android 的虚拟按键在游戏内菜单里配置（原生
          // 实现，见 ControlLayout.kt），这个分组只管 Windows 的悬浮层；
          // 其它桌面平台显示但禁用，注明未实现。
          if (!Platform.isAndroid) ...[
            _sectionTitle(context, '虚拟触控'),
            GroupCard(
              miuix: miuix,
              children: [
                SwitchRow(
                  miuix: miuix,
                  icon: Icons.sports_esports_outlined,
                  title: '启用虚拟触控',
                  subtitle: Platform.isWindows
                      ? '游戏窗口上浮一层可自定义的摇杆 / 按键，触屏或懒得够键盘时用'
                      : '仅 Windows 实现，其它桌面平台暂不可用',
                  value: settings.vtouchEnabled && Platform.isWindows,
                  onChanged: Platform.isWindows
                      ? (v) => settings.vtouchEnabled = v
                      : null,
                ),
                SwitchRow(
                  miuix: miuix,
                  icon: Icons.rocket_launch_outlined,
                  title: '启动游戏时自动显示',
                  subtitle: '贴着游戏窗口显示 / 移动，游戏退出或最小化时自动收起',
                  value: settings.vtouchAutoShow && Platform.isWindows,
                  onChanged: Platform.isWindows && settings.vtouchEnabled
                      ? (v) => settings.vtouchAutoShow = v
                      : null,
                ),
                _SliderTile(
                  miuix: miuix,
                  icon: Icons.opacity_outlined,
                  title: '悬浮层不透明度',
                  value: settings.vtouchAlpha,
                  min: 0.25,
                  max: 1.0,
                  divisions: 15,
                  label: '${(settings.vtouchAlpha * 100).round()}%',
                  onChanged: Platform.isWindows
                      ? (v) => settings.vtouchAlpha = v
                      : (v) {},
                ),
                _SliderTile(
                  miuix: miuix,
                  icon: Icons.open_in_full_outlined,
                  title: '按键大小',
                  value: settings.vtouchScale,
                  min: 0.7,
                  max: 1.6,
                  divisions: 18,
                  label: '${(settings.vtouchScale * 100).round()}%',
                  onChanged: Platform.isWindows
                      ? (v) => settings.vtouchScale = v
                      : (v) {},
                ),
                TileRow(
                  miuix: miuix,
                  icon: Icons.tune,
                  title: '编辑按键布局',
                  subtitle: '打开悬浮层：拖动定位、改键位标签与绑定、增删按键',
                  enabled: Platform.isWindows,
                  showDivider: false,
                  onTap: Platform.isWindows
                      ? () {
                          // 游戏在跑就贴游戏窗口编辑，否则铺主屏（对着桌面
                          // 也能摆布局，或拿记事本实测注入）。
                          final pid = controller.gamePid;
                          VTouchOverlayService.instance.showEditor(
                            gamePid: pid,
                          );
                        }
                      : null,
                  trailing: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ],
        if (category == _SettingsCategory.network) ...[
          _sectionTitle(context, '网络'),
          GroupCard(
            miuix: miuix,
            children: [
              TileRow(
                miuix: miuix,
                icon: Icons.speed_outlined,
                title: '下载线程数',
                subtitle: '并发分片下载的线程数（${settings.downloadThreads} 线程）',
                onTap: () => _pickDownloadThreads(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              SwitchRow(
                miuix: miuix,
                icon: Icons.vpn_key_outlined,
                title: 'HTTP 代理',
                value: settings.proxyEnabled,
                onChanged: (v) => settings.proxyEnabled = v,
                subtitle: '版本下载 / Modrinth / 清单请求走代理',
              ),
              if (settings.proxyEnabled)
                TileRow(
                  miuix: miuix,
                  icon: Icons.settings_ethernet,
                  title: '代理地址',
                  subtitle: '${settings.proxyHost}:${settings.proxyPort}',
                  onTap: () => _editProxy(context, settings),
                  trailing: const Icon(Icons.chevron_right),
                ),
              TileRow(
                miuix: miuix,
                icon: Icons.key_outlined,
                title: 'CurseForge API Key',
                subtitle: settings.curseForgeApiKey.isEmpty
                    ? '可选：导入 CurseForge 整合包时查询文件用'
                    : '已设置（••••${settings.curseForgeApiKey.length > 4 ? settings.curseForgeApiKey.substring(settings.curseForgeApiKey.length - 4) : ''}）',
                showDivider: false,
                onTap: () => _editText(
                  context,
                  title: 'CurseForge API Key',
                  hint: '留空 = 不使用 CurseForge 文件查询',
                  initial: settings.curseForgeApiKey,
                  onSaved: (v) => settings.curseForgeApiKey = v,
                ),
                trailing: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (category == _SettingsCategory.appearance) ...[
          _sectionTitle(context, '外观'),
          GroupCard(
            miuix: miuix,
            children: [
              TileRow(
                miuix: miuix,
                icon: Icons.palette_outlined,
                title: '界面风格',
                subtitle: settings.uiStyle.label,
                onTap: () => _pickUiStyle(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.palette,
                title: 'MIUI 主题包',
                subtitle: _themeSubtitle(settings),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MintThemePage(miuix: miuix),
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.language,
                title: '界面语言',
                subtitle: settings.uiLocale.isEmpty
                    ? '跟随系统（当前内置：简体中文）'
                    : '简体中文',
                onTap: () => _pickUiLocale(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              if (Platform.isAndroid)
                SwitchRow(
                  miuix: miuix,
                  icon: Icons.notifications_active_outlined,
                  title: '使用系统 Toast',
                  subtitle: '短提示改用 Android 原生 Toast，不占页面布局',
                  value: settings.nativeToast,
                  onChanged: (v) => settings.nativeToast = v,
                ),
              if (Platform.isAndroid)
                SwitchRow(
                  miuix: miuix,
                  icon: Icons.layers_outlined,
                  title: '液态玻璃底栏',
                  subtitle: '原生实时折射 / 高光的玻璃底栏（local2api 同款），关闭回到悬浮胶囊',
                  value: settings.glassBottomBar,
                  onChanged: (v) => settings.glassBottomBar = v,
                ),
              if (Platform.isAndroid)
                SwitchRow(
                  miuix: miuix,
                  icon: Icons.volume_up_outlined,
                  title: '主题音量条',
                  subtitle: '按音量键时在应用内显示主题的音量柱',
                  value: settings.volumeUseThemeBar,
                  // 没启用主题就没有可套的样式：开关置灰。
                  onChanged: settings.activeThemeId.isEmpty
                      ? null
                      : (v) => settings.volumeUseThemeBar = v,
                ),
              SwitchRow(
                miuix: miuix,
                icon: Icons.gradient,
                title: '渐变模糊顶栏',
                subtitle: '顶栏透明化，内容滚入时顶部渐进模糊淡入（AppMarket 同款）',
                value: settings.progressiveTopBar,
                onChanged: (v) => settings.setProgressiveTopBar(v),
                showDivider: settings.cloudForeground,
              ),
              SwitchRow(
                miuix: miuix,
                icon: Icons.cloud_outlined,
                title: '云雾前景',
                value: settings.cloudForeground,
                onChanged: (v) => settings.cloudForeground = v,
                subtitle: '主页之上飘动的液态白雾，不挡交互',
                showDivider: settings.cloudForeground,
              ),
              if (settings.cloudForeground) ...[
                _SliderTile(
                  miuix: miuix,
                  icon: Icons.opacity,
                  title: '云雾不透明度',
                  value: settings.cloudOpacity,
                  min: 0.05,
                  max: 1,
                  divisions: 19,
                  label: '${(settings.cloudOpacity * 100).round()}%',
                  onChanged: (v) => settings.cloudOpacity = v,
                ),
                _SliderTile(
                  miuix: miuix,
                  icon: Icons.filter_drama_outlined,
                  title: '云团密度',
                  value: settings.cloudDensity,
                  min: 0.1,
                  max: 1,
                  divisions: 9,
                  label: '${(settings.cloudDensity * 100).round()}%',
                  onChanged: (v) => settings.cloudDensity = v,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(52, 0, 16, 12),
                  child: Text(
                    '主页飘动的白色云雾（Kimi K3.1 博客页头同风格，程序化生成）；'
                    '实际透明度深色主题会再压低，嫌挡内容就调低不透明度。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          GroupCard(
            miuix: miuix,
            children: [
              TileRow(
                miuix: miuix,
                icon: Icons.blur_on,
                title: '窗口背景材质',
                subtitle: _backdropSummary(settings),
                onTap: () => _pickBackdrop(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              if (WindowBackdrop.instance.isActive)
                _SliderTile(
                  miuix: miuix,
                  icon: Icons.opacity,
                  title: '玻璃不透明度',
                  value: settings.backdropTint,
                  min: 0.2,
                  max: 0.95,
                  divisions: 15,
                  label: '${(settings.backdropTint * 100).round()}%',
                  onChanged: (v) => settings.setBackdropTint(v),
                ),
              if (!WindowBackdrop.instance.isActive)
                Padding(
                  padding: const EdgeInsets.fromLTRB(52, 0, 16, 12),
                  child: Text(
                    Platform.isWindows
                        ? 'Mica / Tabbed 需要 Windows 11；Windows 10 会自动降级为 Acrylic。'
                        : '窗口材质只在 Windows 10 及以上可用。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          GroupCard(
            miuix: miuix,
            children: [
              SwitchRow(
                miuix: miuix,
                icon: Icons.wallpaper_outlined,
                title: '页面背景图',
                value:
                    settings.pageBackgroundEnabled &&
                    settings.pageBackgroundPath.isNotEmpty,
                subtitle: settings.pageBackgroundPath.isEmpty
                    ? '选一张图片铺在所有页面底下'
                    : p.basename(settings.pageBackgroundPath),
                onChanged: (v) async {
                  if (v) {
                    final path = await _pickBackgroundImage();
                    if (path == null) return;
                    settings.pageBackgroundPath = path;
                  }
                  settings.pageBackgroundEnabled = v;
                },
              ),
              if (settings.pageBackgroundEnabled &&
                  settings.pageBackgroundPath.isNotEmpty) ...[
                TileRow(
                  miuix: miuix,
                  icon: Icons.image_outlined,
                  title: '更换图片',
                  subtitle: p.basename(settings.pageBackgroundPath),
                  onTap: () async {
                    final path = await _pickBackgroundImage();
                    if (path != null) settings.pageBackgroundPath = path;
                  },
                ),
                _SliderTile(
                  miuix: miuix,
                  icon: Icons.opacity,
                  title: '背景不透明度',
                  value: settings.pageBackgroundOpacity,
                  min: 0.05,
                  max: 1,
                  divisions: 19,
                  label: '${(settings.pageBackgroundOpacity * 100).round()}%',
                  onChanged: (v) => settings.pageBackgroundOpacity = v,
                ),
                _SliderTile(
                  miuix: miuix,
                  icon: Icons.blur_on,
                  title: '背景模糊',
                  value: settings.pageBackgroundBlur,
                  min: 0,
                  max: 24,
                  divisions: 24,
                  label: settings.pageBackgroundBlur.round().toString(),
                  onChanged: (v) => settings.pageBackgroundBlur = v,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(52, 0, 16, 12),
                  child: Text(
                    '背景图铺在所有页面内容与标题栏底下（local2api 的 '
                    'PageBackground 同款）；嫌正文读不清就调低不透明度、拉高模糊。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          GroupCard(
            miuix: miuix,
            children: [
              TileRow(
                miuix: miuix,
                icon: Icons.dark_mode_outlined,
                title: '深色模式',
                subtitle: switch (settings.themeMode) {
                  ThemeMode.system => '跟随系统',
                  ThemeMode.light => '浅色',
                  ThemeMode.dark => '深色',
                },
                onTap: () => _pickThemeMode(context, settings),
                trailing: const Icon(Icons.chevron_right),
              ),
              SwitchRow(
                miuix: miuix,
                icon: Icons.colorize,
                title: '跟随系统取色',
                value: settings.useDynamicColor,
                onChanged: (v) => settings.setUseDynamicColor(v),
                subtitle: '桌面读系统强调色，Android 读 Material You',
              ),
              SwitchRow(
                miuix: miuix,
                icon: Icons.vibration,
                title: '到顶 / 底轻震',
                value: settings.edgeScrollHaptic,
                onChanged: (v) => settings.setEdgeScrollHaptic(v),
                subtitle: '快速滑动撞到列表边界时触发（移动端触觉反馈）',
              ),
              SwitchRow(
                miuix: miuix,
                icon: Icons.contrast,
                title: '纯黑模式',
                value: settings.isPureBlackMode,
                onChanged: (v) => settings.setIsPureBlackMode(v),
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.color_lens_outlined,
                title: '主题种子色',
                showDivider: false,
                onTap: () async {
                  final color = await showColorPickerDialog(
                    context,
                    settings.themeSeedColor,
                  );
                  if (color != null) settings.setThemeSeedColor(color);
                },
                trailing: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: settings.themeSeedColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              _SliderTile(
                miuix: miuix,
                icon: Icons.rounded_corner,
                title: '转场圆角',
                value: settings.cornerRadius,
                min: 0,
                max: 40,
                label: '${settings.cornerRadius.round()}',
                onChanged: (v) => settings.setCornerRadius(v),
              ),
              _SliderTile(
                miuix: miuix,
                icon: Icons.format_bold,
                title: '全局字重',
                value: settings.fontWeight,
                min: 300,
                max: 800,
                divisions: 5,
                label: '${settings.fontWeight.round()}',
                onChanged: (v) => settings.setFontWeight(v),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (category == _SettingsCategory.shortcuts) ...[
          _sectionTitle(context, '快捷键'),
          GroupCard(
            miuix: miuix,
            children: [
              TileRow(
                miuix: miuix,
                icon: Icons.arrow_back,
                title: '返回 / 关闭弹窗',
                subtitle: 'Esc · 鼠标侧键 · Alt + ←',
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.tab,
                title: '切换一级页',
                subtitle: 'Ctrl + 1 … 3',
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.fullscreen,
                title: '全屏',
                subtitle: 'F11',
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.search,
                title: '搜索 / 刷新',
                subtitle: 'Ctrl + F · F5',
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.folder_copy_outlined,
                title: '版本管理（多游戏目录）',
                subtitle: 'Ctrl + M',
              ),
              TileRow(
                miuix: miuix,
                icon: Icons.cancel_schedule_send,
                title: '中断启动',
                subtitle: '启动准备阶段按 Esc，或点启动窗口的「取消」',
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (category == _SettingsCategory.about) ...[
          _sectionTitle(context, '关于'),
          GroupCard(
            miuix: miuix,
            children: [
              TileRow(
                miuix: miuix,
                icon: Icons.info_outline,
                title: '关于',
                subtitle: _aboutSubtitle(settings),
                onTap: () => openAbout(context, miuix),
                trailing: const Icon(Icons.chevron_right),
                showDivider: false,
              ),
            ],
          ),
        ],
        ],
      ],
    );
  }

  String _themeSubtitle(SettingsService settings) {
    if (settings.activeThemeId.isEmpty) {
      return '导入 .mtz，套用壁纸 / 主色 / 字体 / 开机动画';
    }
    final theme = MintThemeLibrary.instance.byId(settings.activeThemeId);
    return theme == null ? '导入 .mtz 主题包' : '使用中：${theme.title}';
  }

  String _aboutSubtitle(SettingsService settings) {
    final theme = MintThemeLibrary.instance.byId(settings.activeThemeId);
    if (theme != null && theme.hasAbout) return '主题：${theme.title}';
    return '版本与致谢';
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Future<void> _editText(
    BuildContext context, {
    required String title,
    required String hint,
    required String initial,
    void Function(String value)? onSaved,
  }) async {
    final result = await showMintInputDialog(
      context,
      miuix: mintMiuixOf(context),
      title: title,
      hint: hint,
      initial: initial,
    );
    if (result == null) return;
    if (onSaved != null) {
      onSaved(result);
    } else {
      _applyText(title, result);
    }
  }

  Future<void> _editMultiline(
    BuildContext context, {
    required String title,
    required String hint,
    required String initial,
    void Function(String value)? onSaved,
  }) async {
    final result = await showMintInputDialog(
      context,
      miuix: mintMiuixOf(context),
      title: title,
      hint: hint,
      initial: initial,
      multiline: true,
    );
    if (result == null) return;
    if (onSaved != null) {
      onSaved(result.trim());
    } else {
      _applyText(title, result.trim());
    }
  }

  void _applyText(String title, String result) {
    final settings = context.read<SettingsService>();
    if (title.startsWith('JVM')) {
      settings.jvmArgs = result;
    } else if (title.startsWith('环境变量')) {
      settings.envVars = result;
    } else {
      settings.serverAddress = result;
    }
  }

  Future<void> _editProxy(
    BuildContext context,
    SettingsService settings,
  ) async {
    final hostController = TextEditingController(text: settings.proxyHost);
    final portController = TextEditingController(text: '${settings.proxyPort}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => MintStyleDialogShell(
        miuix: mintMiuixOf(context),
        title: 'HTTP 代理',
        actions: mintDialogActions(
          dialogContext,
          miuix: mintMiuixOf(context),
          onCancel: () => Navigator.pop(dialogContext, false),
          onConfirm: () => Navigator.pop(dialogContext, true),
        ),
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: MintStyleTextField(
                  controller: hostController,
                  hint: '主机',
                  autofocus: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MintStyleTextField(
                  controller: portController,
                  hint: '端口',
                  numeric: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (ok != true) return;
    settings.proxyHost = hostController.text.trim();
    settings.proxyPort = int.tryParse(portController.text.trim()) ?? 7890;
  }

  String _javaSummary(SettingsService settings) {
    if (Platform.isAndroid) {
      return 'Java 8 / 17 / 21 / 25 · 由「运行环境」管理';
    }
    if (_javas == null) return '检测中…';
    if (settings.javaPath.isNotEmpty) return '自定义：${settings.javaPath}';
    if (_javas!.isEmpty) return '未检测到 Java（启动时会自动下载）';
    return '检测到 ${_javas!.length} 个：${_javas!.take(2).join('，')}';
  }

  Future<void> _editGameDir(
    BuildContext context,
    SettingsService settings,
    LauncherController controller,
  ) async {
    final textController = TextEditingController(text: settings.gameDir);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => MintStyleDialogShell(
        miuix: mintMiuixOf(context),
        title: '游戏目录（.minecraft）',
        actions: mintDialogActions(
          dialogContext,
          miuix: mintMiuixOf(context),
          onCancel: () => Navigator.pop(dialogContext),
          onConfirm: () =>
              Navigator.pop(dialogContext, textController.text.trim()),
        ),
        children: [
          MintStyleTextField(
            controller: textController,
            hint: '留空 = 启动器目录下的 minecraft',
            autofocus: true,
            suffix: IconButton(
              tooltip: '浏览文件夹',
              icon: const Icon(Icons.folder_open),
              onPressed: () async {
                final path = await getDirectoryPath(
                  confirmButtonText: '选择游戏目录',
                );
                if (path != null && path.isNotEmpty) {
                  textController.text = path;
                }
              },
            ),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (result.isEmpty) {
      settings.addGameDir(await GameDir.defaultGameDir());
    } else {
      settings.addGameDir(result);
    }
    await controller.reloadGameDir();
    _detectJavas();
  }

  Future<void> _pickJava(
    BuildContext context,
    SettingsService settings,
    LauncherController controller,
  ) async {
    if (_javas == null) return;
    final result = await pushMintChoicePage<String>(
      context,
      miuix: mintMiuixOf(context),
      title: '选择 Java',
      selected: settings.javaPath.isEmpty ? '' : settings.javaPath,
      options: [
        for (final java in _javas!)
          MintChoice(
            value: java.executablePath,
            label: 'Java ${java.version}',
            subtitle: java.executablePath,
            icon: Icons.terminal,
          ),
        const MintChoice(
          value: '',
          label: '自动（检测 / 启动时下载 JRE）',
          icon: Icons.auto_fix_high,
        ),
      ],
    );
    if (result == null) return;
    settings.javaPath = result;
    await _detectJavas();
  }

  Future<void> _pickWindowMode(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<GameWindowMode>(
      context,
      miuix: mintMiuixOf(context),
      title: '游戏窗口',
      selected: settings.gameWindowMode,
      options: [
        for (final mode in GameWindowMode.values)
          MintChoice(value: mode, label: mode.label),
      ],
    );
    if (result != null) settings.gameWindowMode = result;
  }

  Future<void> _pickLauncherVisibility(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<LauncherVisibility>(
      context,
      miuix: mintMiuixOf(context),
      title: '启动后启动器',
      selected: settings.launcherVisibility,
      options: const [
        MintChoice(
          value: LauncherVisibility.keep,
          label: '保持打开',
          subtitle: '启动器与日志窗口继续显示',
        ),
        MintChoice(
          value: LauncherVisibility.minimize,
          label: '最小化',
          subtitle: '游戏启动后把启动器收到任务栏',
        ),
        MintChoice(
          value: LauncherVisibility.close,
          label: '关闭启动器',
          subtitle: '游戏继续运行；崩溃检测 / 日志窗口会停止',
        ),
      ],
    );
    if (result != null) settings.launcherVisibility = result;
  }

  Future<void> _pickProcessPriority(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<ProcessPriority>(
      context,
      miuix: mintMiuixOf(context),
      title: '游戏进程优先级',
      selected: settings.processPriority,
      options: [
        for (final priority in ProcessPriority.values)
          MintChoice(
            value: priority,
            label: priority.label,
            subtitle: priority == ProcessPriority.normal
                ? '系统默认'
                : 'Windows 任务管理器里的「${priority.windowsName}」',
          ),
      ],
    );
    if (result != null) settings.processPriority = result;
  }

  Future<void> _pickIsolationMode(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<IsolationMode>(
      context,
      miuix: mintMiuixOf(context),
      title: '版本隔离',
      selected: settings.isolationMode,
      options: [
        for (final mode in IsolationMode.values)
          MintChoice(
            value: mode,
            label: mode.label,
            subtitle: mode == IsolationMode.off
                ? mode.desc
                : '${mode.desc}；单版本可在版本设置里强制开 / 关',
          ),
      ],
    );
    if (result != null) settings.isolationMode = result;
  }

  Future<void> _pickUiLocale(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<String>(
      context,
      miuix: mintMiuixOf(context),
      title: '界面语言',
      selected: settings.uiLocale,
      options: const [
        MintChoice(
          value: '',
          label: '跟随系统',
          subtitle: '系统不是中文时回退简体中文（当前唯一内置语言）',
        ),
        MintChoice(value: 'zh-CN', label: '简体中文'),
      ],
    );
    if (result != null) settings.uiLocale = result;
  }

  Future<void> _pickDownloadThreads(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await showMintInputDialog(
      context,
      miuix: mintMiuixOf(context),
      title: '下载线程数（1-256）',
      hint: '例如 32；越大越快也越容易触发限流',
      initial: '${settings.downloadThreads}',
    );
    if (result == null) return;
    final value = int.tryParse(result.trim());
    if (value == null || value < 1) {
      if (context.mounted) showMintSnack(context, '请输入 1 以上的整数');
      return;
    }
    settings.downloadThreads = value;
  }

  Future<void> _pickGcPreset(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<GcPreset>(
      context,
      miuix: mintMiuixOf(context),
      title: '垃圾回收器',
      selected: settings.gcPreset,
      options: [
        for (final preset in GcPreset.values)
          MintChoice(value: preset, label: preset.label),
      ],
    );
    if (result != null) settings.gcPreset = result;
  }

  Future<void> _pickGraphicsBackend(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<GraphicsBackend>(
      context,
      miuix: mintMiuixOf(context),
      title: '强制图形后端',
      selected: settings.graphicsBackend,
      options: const [
        MintChoice(
          value: GraphicsBackend.auto,
          label: '自动',
          subtitle: '按游戏和系统默认选择',
        ),
        MintChoice(
          value: GraphicsBackend.openGl,
          label: '强制 OpenGL',
          subtitle: '26.2+ 追加 --graphicsBackend opengl',
        ),
        MintChoice(
          value: GraphicsBackend.vulkan,
          label: '强制 Vulkan',
          subtitle: '仅 26.2+ 生效；旧版本仍走 OpenGL',
        ),
        MintChoice(
          value: GraphicsBackend.cpu,
          label: 'CPU 软件渲染',
          subtitle: 'Windows 下载 Mesa LLVMpipe（约 48MB，首次较慢）',
        ),
      ],
    );
    if (result != null) settings.graphicsBackend = result;
  }

  /// Android 渲染器选择。
  ///
  /// 六档都是 FCL `RendererManager` 里的真实条目（对应的 .so 已经全部打进
  /// jniLibs），不是摆设。每项带一句「什么时候该选它」，比只写名字有用。
  Future<void> _pickAndroidRenderer(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<AndroidRenderer>(
      context,
      miuix: mintMiuixOf(context),
      title: 'Android 渲染器',
      selected: settings.androidRenderer,
      options: [
        for (final r in AndroidRenderer.values)
          MintChoice(
            value: r,
            label: '${r.label} · ${r.badge}',
            subtitle: r.description,
          ),
      ],
    );
    if (result != null) settings.androidRenderer = result;
  }

  Future<void> _editResolution(
    BuildContext context,
    SettingsService settings,
  ) async {
    final w = TextEditingController(text: '${settings.gameWidth}');
    final h = TextEditingController(text: '${settings.gameHeight}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => MintStyleDialogShell(
        miuix: mintMiuixOf(context),
        title: '游戏窗口尺寸',
        actions: mintDialogActions(
          dialogContext,
          miuix: mintMiuixOf(context),
          onCancel: () => Navigator.pop(dialogContext, false),
          onConfirm: () => Navigator.pop(dialogContext, true),
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: MintStyleTextField(
                  controller: w,
                  hint: '宽',
                  numeric: true,
                  autofocus: true,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('×'),
              ),
              Expanded(
                child: MintStyleTextField(
                  controller: h,
                  hint: '高',
                  numeric: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (ok != true) return;
    settings.gameWidth = int.tryParse(w.text) ?? settings.gameWidth;
    settings.gameHeight = int.tryParse(h.text) ?? settings.gameHeight;
  }

  Future<void> _pickDownloadSource(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<DownloadSource>(
      context,
      miuix: mintMiuixOf(context),
      title: '下载源',
      selected: settings.downloadSource,
      options: const [
        MintChoice(
          value: DownloadSource.auto,
          label: '自动',
          subtitle: 'BMCLAPI 优先，失败回官方',
        ),
        MintChoice(
          value: DownloadSource.bmcl,
          label: 'BMCLAPI（国内镜像）',
          subtitle: '国内下载速度快',
        ),
        MintChoice(
          value: DownloadSource.official,
          label: 'Mojang 官方',
          subtitle: '不经过镜像',
        ),
      ],
    );
    if (result != null) settings.downloadSource = result;
  }

  Future<void> _pickUiStyle(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<UiStyle>(
      context,
      miuix: mintMiuixOf(context),
      title: '界面风格',
      selected: settings.uiStyle,
      options: const [
        MintChoice(
          value: UiStyle.miuix,
          label: '小米 HyperOS（miuix）',
          subtitle: 'squircle、大标题、Folme 弹簧',
        ),
        MintChoice(
          value: UiStyle.materialExpressive,
          label: 'Material 3',
          subtitle: 'M3 组件 + 同一套推入转场',
        ),
        MintChoice(
          value: UiStyle.fluent,
          label: 'Windows 11 Fluent',
          subtitle: 'fluent_ui 侧边栏 + Fluent 图标，Win11 原生观感',
        ),
      ],
    );
    if (result != null) settings.setUiStyle(result);
  }

  String _backdropSummary(SettingsService settings) {
    if (!Platform.isWindows) return '仅 Windows 10+ 可用';
    final backdrop = WindowBackdrop.instance;
    if (!backdrop.available) return '当前 Windows 版本不可用';
    final mode = settings.windowEffect;
    if (mode == WindowBackdropMode.disabled) return '关闭（纯色窗口）';
    final applied = backdrop.appliedMode;
    if (backdrop.isActive && applied != mode) {
      return '${mode.label} → 已降级为 ${applied.label}';
    }
    if (!backdrop.supports(mode)) {
      return '${mode.label}（当前系统不支持，将降级）';
    }
    final build = backdrop.build;
    return build >= 22621 ? '${mode.label} · Windows 11' : mode.label;
  }

  Future<String?> _pickBackgroundImage() async {
    const group = XTypeGroup(
      label: '图片',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    return file?.path;
  }

  Future<void> _pickBackdrop(
    BuildContext context,
    SettingsService settings,
  ) async {
    final backdrop = WindowBackdrop.instance;
    final result = await pushMintChoicePage<WindowBackdropMode>(
      context,
      miuix: mintMiuixOf(context),
      title: '窗口背景材质',
      selected: settings.windowEffect,
      options: [
        for (final mode in WindowBackdropMode.values)
          MintChoice(
            value: mode,
            label: mode.label,
            subtitle: Platform.isWindows
                ? (mode == WindowBackdropMode.disabled ||
                          backdrop.supports(mode)
                      ? mode.description
                      : '${mode.description} · 需要 Windows 11')
                : '仅 Windows 10+ 可用',
            icon: switch (mode) {
              WindowBackdropMode.disabled => Icons.crop_square,
              WindowBackdropMode.mica => Icons.wallpaper,
              WindowBackdropMode.acrylic => Icons.blur_on,
              WindowBackdropMode.tabbed => Icons.tab,
              WindowBackdropMode.aero => Icons.gradient,
            },
            enabled:
                mode == WindowBackdropMode.disabled ||
                (Platform.isWindows && backdrop.supports(mode)),
          ),
      ],
    );
    if (result != null) await settings.setWindowEffect(result);
  }

  Future<void> _pickThemeMode(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await pushMintChoicePage<ThemeMode>(
      context,
      miuix: mintMiuixOf(context),
      title: '深色模式',
      selected: settings.themeMode,
      options: const [
        MintChoice(value: ThemeMode.system, label: '跟随系统'),
        MintChoice(value: ThemeMode.light, label: '浅色'),
        MintChoice(value: ThemeMode.dark, label: '深色'),
      ],
    );
    if (result != null) settings.setThemeMode(result);
  }
}

/// 内存分配：AUTO / 手工滑块 + 系统物理内存实时占用。
///
/// PCL2 的 AUTO 是按可用内存算的；这里把「总内存 / 已用 / 可用」直接画在
/// 滑块上方，每 2 秒刷新，拖动时也不再是黑盒。
class _MemoryTile extends StatefulWidget {
  const _MemoryTile({required this.miuix});

  final bool miuix;

  @override
  State<_MemoryTile> createState() => _MemoryTileState();
}

class _MemoryTileState extends State<_MemoryTile> {
  MemoryStatus? _status;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final status = await SystemMemory.read(force: true);
    if (mounted) setState(() => _status = status);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final controller = context.watch<LauncherController>();
    final cs = Theme.of(context).colorScheme;
    final status = _status;
    final active = activeVersionId(controller, settings);
    final isolated = active == null
        ? false
        : settings.effectiveFor(active).isolation;
    final mods = active == null
        ? 0
        : controller.gameDir.modsOf(active, isolated: isolated).length;
    final autoMb = status == null
        ? null
        : MemoryAdvisor.autoMbFor(status, modCount: mods);
    final shownMb = settings.memoryAuto ? (autoMb ?? 0) : settings.memoryMb;
    final totalMb = ((status?.totalGb ?? 32) * 1024).round();
    final maxMb = totalMb < 32768 ? 32768 : totalMb;
    final used = status?.usedFraction ?? 0;
    final value = shownMb.clamp(256, maxMb).toDouble();
    final slider = mintMiuixOf(context, widget.miuix)
        ? MiuixSlider(
            value: value,
            min: 256,
            max: maxMb.toDouble(),
            onValueChanged: (v) {
              if (settings.memoryAuto) settings.memoryAuto = false;
              settings.memoryMb = (v ~/ 128) * 128;
            },
            height: 34,
          )
        : Slider(
            value: value,
            min: 256,
            max: maxMb.toDouble(),
            label: '${(shownMb / 1024).toStringAsFixed(1)} GB',
            onChanged: (v) {
              if (settings.memoryAuto) settings.memoryAuto = false;
              settings.memoryMb = (v ~/ 128) * 128;
            },
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.developer_board, size: 22, color: cs.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '最大内存',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      status == null
                          ? '读取物理内存…'
                          : '物理内存 ${status.totalGb.toStringAsFixed(1)} GB · '
                                '已用 ${status.usedGb.toStringAsFixed(1)} GB · '
                                '可用 ${status.availableGb.toStringAsFixed(1)} GB',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.35,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    settings.memoryAuto
                        ? 'AUTO'
                        : '${(settings.memoryMb / 1024).toStringAsFixed(1)} GB',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
                  if (settings.memoryAuto && autoMb != null)
                    Text(
                      '建议 ${(autoMb / 1024).toStringAsFixed(1)} GB',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 6),
              if (mintMiuixOf(context, widget.miuix))
                MiuixSwitch(
                  value: settings.memoryAuto,
                  onChanged: (v) => settings.memoryAuto = v,
                  colors: mintSwitchColorsOf(context),
                )
              else
                Switch(
                  value: settings.memoryAuto,
                  onChanged: (v) => settings.memoryAuto = v,
                ),
            ],
          ),
          const SizedBox(height: 10),
          // 实时占用条：滑块上方一条细轨道，已用部分随系统刷新。
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: used,
              minHeight: 5,
              backgroundColor: cs.surfaceContainerHighest,
              color: used > 0.9 ? cs.error : cs.tertiary,
            ),
          ),
          const SizedBox(height: 2),
          slider,
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4),
            child: Row(
              children: [
                Text(
                  '256 MB',
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
                const Spacer(),
                Text(
                  '上限 ${(maxMb / 1024).toStringAsFixed(0)} GB',
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                settings.memoryAuto
                    ? 'AUTO：按可用内存 + ${mods} 个模组分配'
                    : '手工分配；拖动滑块或输入精确值',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _editExact(context, settings),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('输入'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _editExact(
    BuildContext context,
    SettingsService settings,
  ) async {
    final result = await showMintTextDialog(
      context,
      miuix: mintMiuixOf(context),
      title: '最大内存（MB）',
      initial: '${settings.memoryMb}',
      hint: '例如 6144',
      confirmLabel: '保存',
    );
    if (result == null) return;
    final value = int.tryParse(result.trim());
    if (value == null || value < 256) {
      if (context.mounted) showMintSnack(context, '请输入 256 以上的整数');
      return;
    }
    settings.memoryAuto = false;
    settings.memoryMb = value;
  }
}

/// 通用滑块行。
class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.miuix,
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.label,
    required this.onChanged,
  });

  final bool miuix;
  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

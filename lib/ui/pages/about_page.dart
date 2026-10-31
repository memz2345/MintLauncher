import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/nine_patch.dart' show resolveDisplayImage;
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/texture_set_state.dart';
import 'package:mint/services/theme_package.dart';
import 'package:mint/ui/mint_icons.dart' show MintBackIcon, mintMiuixOf;
import 'package:mint/ui/pages/common.dart';
import 'package:mint/ui/widgets/mint_page.dart' show MintTopBarAction;
import 'package:mint/ui/widgets/mint_progressive_band.dart'
    show MintGradientBar, MintProgressiveBand;
import 'package:mint/ui/widgets/page_background.dart';
import 'package:mint/ui/widgets/top_bar_tone.dart'
    show MintTopBarTone, mintTopBarScrimFor;
import 'package:mint/widgets/bg_effect_background.dart';

/// 推入关于页（local2api 的 AboutPage 同款入口：设置里单独一页）。
Future<void> openAbout(BuildContext context, bool miuix) async {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return;
  await Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => MintAboutPage(miuix: miuix)));
}

/// 「我的设备」滚动动画的几何参数 —— 从 MIUI 设置（设置_15.apk）反编译的
/// `MyDeviceAnimationController` 里逐项搬过来的比例：
///
///  - `my_device_os_logo_area_height`（actionBarPadding）→ 标题块的收起行程；
///  - `my_device_logo_bottom - btnPadding - 30dp`（logoPadding）→ logo 开始
///    收缩的滚动位置；
///  - `my_device_logo_height`（logoHeight）→ logo 自身收缩的行程。
///
/// 动画本体（[MintMyDeviceAnimation.startAnimation] 的注释）也是逐行对照
/// 反编译源码移植的：两段式 —— 先是标题块按 stage1 缩到 0.9 并淡出，
/// 滚过 [logoPadding] 后 logo 再按 stage2 缩到 0.9 并淡出，收起态小标题
/// 在 stage2 打满时出现在顶栏。
class MintMyDeviceAnimation {
  MintMyDeviceAnimation({
    this.actionBarPadding = 88,
    this.logoPadding = 128,
    this.logoHeight = 104,
  });

  /// `my_device_os_logo_area_height`：标题块（版本布局）收起的滚动行程。
  final double actionBarPadding;

  /// `my_device_logo_bottom - btnPadding - 30dp`：logo 开始收缩的滚动位置。
  final double logoPadding;

  /// `my_device_logo_height`：logo 收缩的滚动行程。
  final double logoHeight;

  /// 标题块 / logo 的最大收缩量（反编译：`1.0f - fMin * 0.1f`）。
  static const double maxShrink = 0.1;

  /// stage1：标题块收起进度（0..1）。
  double stage1(double scrollY) =>
      (scrollY.abs() / actionBarPadding).clamp(0.0, 1.0);

  /// stage2：logo 收起进度（滚过 [logoPadding] 后才走，0..1）。
  double stage2(double scrollY) => scrollY >= logoPadding
      ? ((scrollY - logoPadding).abs() / logoHeight).clamp(0.0, 1.0)
      : 0.0;

  /// 标题块的缩放（`1 - 0.1 * stage1`）。
  double titleScale(double scrollY) => 1.0 - maxShrink * stage1(scrollY);

  /// 标题块的透明度（`1 - (actionBarPadding / logoPadding) * stage1`）。
  double titleAlpha(double scrollY) =>
      1.0 - (actionBarPadding / logoPadding) * stage1(scrollY);

  /// logo 的缩放（`1 - 0.1 * stage2`）。
  double logoScale(double scrollY) => 1.0 - maxShrink * stage2(scrollY);

  /// logo 的透明度（`1 - stage2`）。
  double logoAlpha(double scrollY) => 1.0 - stage2(scrollY);

  /// 收起态小标题：反编译里是二值的 —— `fMin2 == 1.0f` 才显示。
  bool collapsedTitleVisible(double scrollY) => stage2(scrollY) >= 0.999;
}

/// 关于页（local2api / InstallerX 同款：浮动返回 + 居中 Logo 头 + 信息卡）。
///
/// 2026-10 重排（反编译 MIUI 设置「我的设备」页对齐）：
///  - 头部照 `MyDeviceAnimationController` 做两段式缩放 —— 滚动时标题块
///    先缩（1→0.9）淡出，logo 在第二段缩放淡出，收起态小标题钉进顶栏；
///  - 主题信息（描述 / 作者 / 版本 / 模块 / 高级设置 / 来源）合并成
///    **一整块大卡**，和系统「我的设备」页下面的信息大卡同构。
///
/// 应用信息没有写死（名字 / 版本 / 链接留空）；当前套用了 mtz 主题时，
/// 显示主题 `description.xml` 声明的标题 / 作者 / 设计师 / 版本 / 描述 /
/// 模块统计 —— 这就是「mtz 的关于页」；没有主题或主题没声明时，回落到
/// 原来设置里的 Mint Launcher 关于内容。
class MintAboutPage extends StatefulWidget {
  const MintAboutPage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<MintAboutPage> createState() => _MintAboutPageState();
}

class _MintAboutPageState extends State<MintAboutPage> {
  final ScrollController _scroll = ScrollController();
  final MiuixLayerBackdrop _backdrop = MiuixLayerBackdrop();
  final MintMyDeviceAnimation _anim = MintMyDeviceAnimation();
  late final SettingsService _settings;
  late final TextureSetState _texture;
  double _scrollY = 0;

  /// 「效果背景」这一层此刻有没有真的在画（有主题或有背景图时按用户取向不画动效）。
  /// build 里更新，高级设置弹层据此决定动效相关控件是否可用。
  bool _effectVisible = true;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsService>();
    // 「高级设置」跨页面 / 重启保留（local2api 那份是每次进页面重建的）。
    _texture = TextureSetState.fromMap(
      _settings.textureSettings,
      defaultBlur: true,
    )..addListener(_onTextureChanged);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    // dispose 时整棵路由树正在拆，同步 notifyListeners 会让还挂着的弹层
    // ListenableBuilder 在已 deactivate 的元素上重建；快照推到微任务里写。
    final snapshot = _texture.toMap();
    scheduleMicrotask(() => _settings.textureSettings = snapshot);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _texture.removeListener(_onTextureChanged);
    _texture.dispose();
    _backdrop.dispose();
    super.dispose();
  }

  Timer? _persistTimer;

  /// 滑条每帧都在动；整条 launcher_config 落盘 + notifyListeners 不能跟帧跑，
  /// 所以只在停下 400ms 后写一次（关页面时再补一次）。
  void _onTextureChanged() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), _flushTextureSettings);
    if (mounted) setState(() {});
  }

  void _flushTextureSettings() {
    _settings.textureSettings = _texture.toMap();
  }

  void _onScroll() {
    final y = _scroll.hasClients ? _scroll.offset : 0.0;
    if ((y - _scrollY).abs() < 0.5 && y != 0 && _scrollY != 0) return;
    if (mounted) setState(() => _scrollY = y);
  }

  @override
  Widget build(BuildContext context) {
    final miuix = mintMiuixOf(context, widget.miuix);
    final settings = context.watch<SettingsService>();
    final theme = MintThemeLibrary.instance.byId(settings.activeThemeId);
    final hasTheme = settings.activeThemeId.isNotEmpty && theme != null;
    final hasThemeAbout = hasTheme && theme.hasAbout;
    final base = miuix
        ? MiuixTheme.of(context).colors.surface
        : Theme.of(context).colorScheme.surface;

    // 背景图解析：预览器指定给「关于」的图 > 主题声明的设置窗口背景 >
    // 全局自定义 / 主题壁纸。动效只在没主题且没有背景图时出现。
    final assignedAbout = settings.pageBackgroundFor(
      MintPageBackgroundKey.about.id,
    );
    final settingsBg = _usableOr(assignedAbout)
        ? assignedAbout
        : hasTheme
        ? (theme.settingsWindowBackground.isNotEmpty
              ? theme.settingsWindowBackground
              : theme.settingsWindowBackgroundDark)
        : '';
    final hasSettingsBg = _usableOr(settingsBg);
    final activeBg = mintActivePageBackgroundImage(context);
    final showEffect = !hasTheme && activeBg == null;
    _effectVisible = showEffect;
    final toneBg = hasSettingsBg
        ? (path: settingsBg, opacity: 1.0, blur: 0.0)
        : activeBg;

    final background = Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: ColoredBox(color: base)),
        if (hasSettingsBg)
          Positioned.fill(child: _AboutBackgroundImage(path: settingsBg))
        else
          Positioned.fill(child: PageBackground(baseColor: base)),
        if (showEffect)
          Positioned.fill(
            child: BgEffectBackground(
              variant: _texture.variant,
              dynamic: _texture.dynamicBg,
              enabled: _texture.effectBg,
              alpha: (1 - _anim.stage1(_scrollY)).clamp(0.0, 1.0),
              saturateOffset: _texture.noise,
            ),
          ),
      ],
    );
    // 卡片模糊要采样的就是这一层背景（效果动效 / 主题窗口背景 / 壁纸）。
    final captured = miuix
        ? MiuixLayerBackdropCapture(backdrop: _backdrop, child: background)
        : background;

    final content = Stack(
      children: [
        Positioned.fill(child: captured),
        if (hasSettingsBg || activeBg != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: base.withValues(
                  alpha: (_anim.stage1(_scrollY) * 0.88).clamp(0, 1),
                ),
              ),
            ),
          ),
        SafeArea(
          child: ListView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            // 底部留白 = 半个视口：关于页内容不满一屏，不加这段行程
            // 就滚不出「我的设备」的两段式收起（stage1+stage2 要 232px），
            // 收起态小标题永远出不来。MIUI 关于页底部也有大段留白。
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              MediaQuery.sizeOf(context).height * 0.5,
            ),
            children: [
              const SizedBox(height: 72),
              MintTopBarTone(
                baseColor: base,
                backgroundImage: toneBg,
                // 主题标题 / 版本在背景约 23%~35% 的位置，按标题所在的
                // 中间区域单独取色，否则会被两侧深色边距带偏成白字。
                sampleStart: 0.23,
                sampleEnd: 0.35,
                sampleLeft: 0.2,
                sampleRight: 0.8,
                // 背景若被压暗，实际标题底色比原图暗，阈值调低一点才会选黑字。
                threshold: 0.35,
                builder: (context, foreground) => _DeviceHeader(
                  miuix: miuix,
                  anim: _anim,
                  scrollY: _scrollY,
                  theme: hasThemeAbout ? theme : null,
                  themeActive: hasTheme,
                  foreground: foreground,
                  onLogoTap: _showTextureSetSheet,
                ),
              ),
              const SizedBox(height: 32),
              // 「我的设备」式的一整块大卡：全部信息收进同一张卡。
              _bigCard(context, miuix, theme, hasThemeAbout),
            ],
          ),
        ),
        // 顶栏：返回键与其他二级页同款（同组件同几何，对齐）；渐变模糊带
        // 随滚动渐入（stage1 打满时全强度），完全折叠后在栏中央显示「关于」
        // —— MIUI 关于页收起时 actionBar 渐入的同款行为。
        _AboutTopBar(
          miuix: miuix,
          base: base,
          toneBg: toneBg,
          collapse: _anim.stage1(_scrollY).clamp(0.0, 1.0),
          showTitle: _anim.collapsedTitleVisible(_scrollY),
        ),
      ],
    );

    if (miuix) {
      return Material(
        type: MaterialType.transparency,
        child: MiuixScaffold(
          containerColor: Colors.transparent,
          content: (_) => content,
        ),
      );
    }
    return Scaffold(backgroundColor: Colors.transparent, body: content);
  }

  static bool _usableOr(String path) =>
      path.isNotEmpty && File(path).existsSync();

  /// 「我的设备」大卡：一整块卡收下全部信息。
  Widget _bigCard(
    BuildContext context,
    bool miuix,
    MintTheme? theme,
    bool hasThemeAbout,
  ) {
    final children = <Widget>[];
    void divider() {
      if (children.isEmpty) return;
      final prev = children.removeLast();
      children
        ..add(prev)
        ..add(
          miuix
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: MiuixHorizontalDivider(
                    color: MiuixTheme.of(
                      context,
                    ).colors.dividerLine.withValues(alpha: 0.6),
                  ),
                )
              : Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
        );
    }

    void addRow(Widget row) {
      divider();
      children.add(row);
    }

    void addInfo(
      String title,
      String value, {
      IconData? icon,
    }) {
      if (value.trim().isEmpty) return;
      addRow(
        MintTile(
          miuix: miuix,
          icon: icon,
          title: title,
          subtitle: value,
          showDivider: false,
        ),
      );
    }

    if (hasThemeAbout && theme != null) {
      // 主题描述作为大卡的第一段（系统「我的设备」卡顶部也是一段说明文字）。
      if (theme.description.isNotEmpty) {
        addRow(
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Text(
              theme.description,
              style: const TextStyle(fontSize: 13.5, height: 1.55),
            ),
          ),
        );
      }
      addInfo('主题', theme.title, icon: Icons.palette_outlined);
      addInfo('作者', theme.author, icon: Icons.person_outline);
      addInfo('设计师', theme.designer, icon: Icons.brush_outlined);
      addInfo(
        '版本',
        [
          if (theme.version.isNotEmpty) theme.version,
          if (theme.uiVersion.isNotEmpty) 'UI ${theme.uiVersion}',
        ].join(' · '),
        icon: Icons.tag,
      );
      addInfo(
        '资源',
        '${theme.modules.length} 个模块 · ${theme.colors.length} 条颜色 · '
            '${theme.icons.length} 个图标',
        icon: Icons.widgets_outlined,
      );
      addInfo(
        '壁纸 / 开机动画',
        [
          if (theme.wallpaper.isNotEmpty) '壁纸已声明',
          if (theme.bootAnimationDir.isNotEmpty) '开机动画已声明',
        ].join(' · '),
        icon: Icons.photo_library_outlined,
      );
      final source = theme.sourcePath.isNotEmpty ? theme.sourcePath : theme.dir;
      if (source.isNotEmpty) {
        addInfo('主题包', source, icon: Icons.folder_zip_outlined);
      }
    } else {
      addInfo(
        'Mint Launcher',
        '0.1.0 · 实验性 Minecraft 启动器\n'
            '主页布局参考 FCL；下载与安装流程参考 HMCL\n'
            '标题栏与双风格来自 local2api',
        icon: Icons.rocket_launch_outlined,
      );
    }
    // 高级设置行也收进大卡（「我的设备」卡的最后一行是可点项）。
    addRow(
      MintTile(
        miuix: miuix,
        icon: Icons.auto_awesome_outlined,
        title: '高级设置',
        subtitle: '背景动效 / 卡片模糊 / 混合模式',
        showDivider: false,
        onTap: _showTextureSetSheet,
      ),
    );

    return _aboutCard(context, miuix, children);
  }

  Widget _aboutCard(BuildContext context, bool miuix, List<Widget> children) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (!miuix || !_texture.blurEnable) {
      return MintCard(miuix: miuix, children: children);
    }
    final colors = MiuixTheme.of(context).colors;
    return MiuixContentColor(
      color: colors.onSurfaceContainer,
      child: MiuixTextureBlur(
        backdrop: _backdrop,
        shape: const MiuixSquircleBorder(cornerRadius: 18),
        blurRadius: _texture.blurRadius,
        colors: _texture.blurColors(dark),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  void _showTextureSetSheet() {
    // 有背景图（主题声明的关于页窗口背景 / 设备壁纸）时，动效那一层不画，
    // 相关开关就一并置灰 —— 不然拨了没反应，看着像坏了。
    final effectEnabled = _effectVisible;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        maxChildSize: 0.94,
        minChildSize: 0.42,
        builder: (context, scrollController) => ListenableBuilder(
          listenable: _texture,
          builder: (context, _) => Container(
            decoration: BoxDecoration(
              color: MiuixTheme.of(context).colors.background,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: MiuixTheme.of(
                          context,
                        ).colors.outline.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  MiuixText(
                    '高级设置',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Opacity(
                    opacity: effectEnabled ? 1 : 0.4,
                    child: IgnorePointer(
                      ignoring: !effectEnabled,
                      child: MintSegmentedTabs(
                        miuix: true,
                        tabs: const ['OS3', 'OS2'],
                        selected: _texture.variant == BgEffectVariant.os3
                            ? 0
                            : 1,
                        onSelected: (i) => _texture.setVariant(
                          i == 0 ? BgEffectVariant.os3 : BgEffectVariant.os2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  MintCard(
                    miuix: true,
                    children: [
                      MiuixSwitchPreference(
                        title: '效果背景',
                        value: _texture.effectBg,
                        enabled: effectEnabled,
                        onChanged: (v) => _texture.set((s) => s.effectBg = v),
                      ),
                      const MiuixHorizontalDivider(),
                      MiuixSwitchPreference(
                        title: '动态背景',
                        value: _texture.dynamicBg,
                        enabled: effectEnabled,
                        onChanged: (v) => _texture.set((s) => s.dynamicBg = v),
                      ),
                      const MiuixHorizontalDivider(),
                      MiuixSwitchPreference(
                        title: '卡片模糊',
                        value: _texture.blurEnable,
                        onChanged: (v) => _texture.set((s) => s.blurEnable = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  MintCard(
                    miuix: true,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _textureSlider(
                              context,
                              '模糊半径',
                              _texture.blurRadius,
                              0,
                              200,
                              (v) => _texture.set((s) => s.blurRadius = v),
                              format: (v) => v.round().toString(),
                            ),
                            _textureSlider(
                              context,
                              '噪点',
                              _texture.noise,
                              0,
                              0.5,
                              (v) => _texture.set((s) => s.noise = v),
                              format: (v) => v.toStringAsFixed(3),
                              enabled: effectEnabled,
                            ),
                            _textureSlider(
                              context,
                              '亮度',
                              _texture.brightness,
                              -1,
                              1,
                              (v) => _texture.set((s) => s.brightness = v),
                              format: (v) => v.toStringAsFixed(2),
                            ),
                            _textureSlider(
                              context,
                              '对比度',
                              _texture.contrast,
                              0,
                              3,
                              (v) => _texture.set((s) => s.contrast = v),
                              format: (v) => v.toStringAsFixed(2),
                            ),
                            _textureSlider(
                              context,
                              '饱和度',
                              _texture.saturation,
                              0,
                              3,
                              (v) => _texture.set((s) => s.saturation = v),
                              format: (v) => v.toStringAsFixed(2),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  MintCard(
                    miuix: true,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                        child: Row(
                          children: [
                            const Expanded(
                              child: MiuixText('混合模式', fontSize: 14),
                            ),
                            MiuixIconButton(
                              onPressed: () => _texture.set(
                                (s) => s.blendIndex =
                                    (s.blendIndex -
                                        1 +
                                        blendModePresets.length) %
                                    blendModePresets.length,
                              ),
                              child: const Icon(Icons.chevron_left),
                            ),
                            SizedBox(
                              width: 92,
                              child: MiuixText(
                                _texture.blendPreset.label,
                                fontSize: 13,
                                textAlign: TextAlign.center,
                                color: MiuixTheme.of(context).colors.primary,
                                fontWeight: FontWeight.w600,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            MiuixIconButton(
                              onPressed: () => _texture.set(
                                (s) => s.blendIndex =
                                    (s.blendIndex + 1) %
                                    blendModePresets.length,
                              ),
                              child: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  MiuixButton(
                    onPressed: () => _texture.reset(true),
                    child: const Text('恢复默认'),
                  ),
                  const SizedBox(height: 8),
                  MiuixButton(
                    onPressed: () => Navigator.of(sheetContext).maybePop(),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹层里的一行滑条。[context] 必须是弹层自己的 context：页面 State 的
/// context 在弹层还挂着时可能已经 deactivate，取 MiuixTheme 会炸。
Widget _textureSlider(
  BuildContext context,
  String label,
  double value,
  double min,
  double max,
  ValueChanged<double> onChanged, {
  required String Function(double) format,
  bool enabled = true,
}) {
  final colors = MiuixTheme.of(context).colors;
  final row = Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: MiuixText(label, fontSize: 14)),
          MiuixText(
            format(value),
            fontSize: 13,
            color: colors.onSurfaceVariantSummary,
          ),
        ],
      ),
      MiuixSlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onValueChanged: onChanged,
      ),
    ],
  );
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: enabled
        ? row
        : Opacity(opacity: 0.4, child: IgnorePointer(ignoring: true, child: row)),
  );
}

/// 主题声明的设置/关于窗口背景（window_bg_light/dark）。
class _AboutBackgroundImage extends StatelessWidget {
  const _AboutBackgroundImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Image.file(
      File(resolveDisplayImage(path)),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}

/// 关于页顶栏：返回键与其他二级页**同组件同几何**（miuix 用
/// `MiuixSmallTopAppBar`、Material 用同规格的小栏，和 MintPageScaffold
/// 的二级页完全对位），展开态只有返回键浮在页头上。
///
/// 滚动时叠一条渐进模糊带（[MintProgressiveBand]，强度 = stage1），
/// 完全折叠（stage2 打满）后栏中央渐显「关于」—— MIUI 关于页收起时
/// actionBar 带着模糊渐入的同款行为。
class _AboutTopBar extends StatelessWidget {
  const _AboutTopBar({
    required this.miuix,
    required this.base,
    required this.toneBg,
    required this.collapse,
    required this.showTitle,
  });

  final bool miuix;
  final Color base;
  final ({String path, double opacity, double blur})? toneBg;

  /// 渐进模糊带强度（0..1，跟 stage1 走）。
  final double collapse;

  /// 是否显示折叠态标题「关于」（stage2 打满）。
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      return MintTopBarTone(
        baseColor: base,
        backgroundImage: toneBg,
        builder: (context, foreground) {
          final scrim = mintTopBarScrimFor(foreground);
          return Stack(
            children: [
              if (collapse > 0.01)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: IgnorePointer(
                    child: MintProgressiveBand(
                      height:
                          MediaQuery.paddingOf(context).top +
                          MiuixTopAppBarDefaults.smallTopAppBarCenterHeight,
                      intensity: collapse,
                      tint: scrim,
                      maxSigma: MintGradientBar.maxSigma,
                      tintAlphaTop: MintGradientBar.tintAlphaTop,
                    ),
                  ),
                ),
              MiuixSmallTopAppBar(
                title: showTitle ? '关于' : '',
                color: Colors.transparent,
                titleColor: foreground,
                navigationIcon: MintTopBarAction(
                  miuix: true,
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const MintBackIcon(size: 22),
                ),
              ),
            ],
          );
        },
      );
    }
    // Material：与 MintPageScaffold 的 `_MaterialSmallBar` 同规格
    // （净高 56 + back 左置 + 标题），折叠态标题按 collapse 渐显。
    return MintTopBarTone(
      baseColor: base,
      backgroundImage: toneBg,
      builder: (context, foreground) {
        final barHeight =
            MediaQuery.paddingOf(context).top + _kMaterialToolbarHeight;
        return SizedBox(
          height: barHeight,
          child: Stack(
            children: [
              if (collapse > 0.01)
                Positioned.fill(
                  child: IgnorePointer(
                    child: MintProgressiveBand(
                      height: barHeight,
                      intensity: collapse,
                      tint: mintTopBarScrimFor(foreground),
                      maxSigma: 12,
                      tintAlphaTop: 0.75,
                    ),
                  ),
                ),
              SafeArea(
                bottom: false,
                child: SizedBox(
                  height: _kMaterialToolbarHeight,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      MintTopBarAction(
                        miuix: false,
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const MintBackIcon(size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Opacity(
                          opacity: showTitle ? 1.0 : 0.0,
                          child: Text(
                            '关于',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: foreground,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Material 小栏净高（MintPageScaffold._toolbarHeight 同款）。
const double _kMaterialToolbarHeight = 56;

/// 「我的设备」页头：OS 字标（主题字标 / Mint 徽标）+ 标题块。
///
/// 滚动动画照反编译的 `MyDeviceAnimationController.startAnimation`：
/// 标题块（版本布局）在 stage1 缩放淡出，logo（图标）在 stage2 缩放淡出，
/// pivot 都取自身中心 —— 与 Android View 的默认 pivot 一致。
class _DeviceHeader extends StatelessWidget {
  const _DeviceHeader({
    required this.miuix,
    required this.anim,
    required this.scrollY,
    required this.theme,
    required this.themeActive,
    required this.foreground,
    this.onLogoTap,
  });

  final bool miuix;
  final MintMyDeviceAnimation anim;
  final double scrollY;
  final MintTheme? theme;

  /// 有没有套用 mtz 主题（和 [theme] 不同：主题可能没声明任何可展示的「关于」
  /// 信息，这时 theme 为 null，但页头也不该再画启动器自己的 M 徽标）。
  final bool themeActive;
  final Color foreground;
  final VoidCallback? onLogoTap;

  @override
  Widget build(BuildContext context) {
    final accent =
        theme?.accent ??
        (miuix
            ? MiuixTheme.of(context).colors.primary
            : Theme.of(context).colorScheme.primary);
    final title = theme?.title ?? '';
    final subtitle = theme == null
        ? ''
        : [
            if (theme!.author.isNotEmpty) theme!.author,
            if (theme!.version.isNotEmpty) theme!.version,
            if (theme!.uiVersion.isNotEmpty) 'UI ${theme!.uiVersion}',
          ].join(' · ');
    final iconPath = theme?.settingsIcon ?? '';
    final hasIcon = iconPath.isNotEmpty && File(iconPath).existsSync();
    // 主题没声明字标 → 页头不画图标（用户取向：只显示主题声明的东西）。
    final logo = hasIcon
        ? ConstrainedBox(
            // xiaomi_os_logo 是 1080×153 的宽字标，给到 300 宽才看得清；
            // miui_version_logo 是方形头像，被 maxHeight 收回 96×96。
            constraints: const BoxConstraints(maxWidth: 300, maxHeight: 96),
            child: Image.file(
              File(resolveDisplayImage(iconPath)),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          )
        : themeActive
        ? const SizedBox.shrink()
        : Container(
            width: 96,
            height: 96,
            alignment: Alignment.center,
            decoration: ShapeDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(accent, Colors.white, 0.18)!,
                  accent,
                ],
              ),
              shape: miuix
                  ? const MiuixSquircleBorder(cornerRadius: 28)
                  : RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
              shadows: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.32),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: const Text(
              'M',
              style: TextStyle(
                color: Colors.white,
                fontSize: 44,
                fontWeight: FontWeight.w900,
              ),
            ),
          );

    // ── MyDeviceAnimationController.startAnimation 的 Flutter 化 ──
    final logoScale = anim.logoScale(scrollY);
    final logoAlpha = anim.logoAlpha(scrollY);
    final titleScale = anim.titleScale(scrollY);
    final titleAlpha = anim.titleAlpha(scrollY);

    return Column(
      children: [
        // logo（mIconImageView）：stage2 缩放 + 淡出，pivot 中心。
        if (!themeActive || hasIcon)
          Transform.scale(
            scale: logoScale,
            child: Opacity(opacity: logoAlpha, child: GestureDetector(
              onTap: onLogoTap,
              child: logo,
            )),
          ),
        // 标题块（versionLayout）：stage1 缩放 + 淡出，pivot 中心。
        if (title.isNotEmpty) ...[
          const SizedBox(height: 22),
          Transform.scale(
            scale: titleScale,
            child: Opacity(
              opacity: titleAlpha.clamp(0.0, 1.0),
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: foreground,
                  shadows: [
                    Shadow(
                      color: foreground.computeLuminance() > 0.5
                          ? Colors.black.withValues(alpha: 0.38)
                          : Colors.white.withValues(alpha: 0.55),
                      blurRadius: 10,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 6),
          Transform.scale(
            scale: titleScale,
            child: Opacity(
              opacity: titleAlpha.clamp(0.0, 1.0),
              child: Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: foreground.withValues(alpha: 0.82),
                  shadows: [
                    Shadow(
                      color: foreground.computeLuminance() > 0.5
                          ? Colors.black.withValues(alpha: 0.32)
                          : Colors.white.withValues(alpha: 0.45),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

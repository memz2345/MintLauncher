import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/settings_service.dart';
import 'package:mint/services/theme_package.dart';
import 'package:mint/ui/pages/common.dart';
import 'package:mint/ui/widgets/mint_page.dart';
import 'package:mint/ui/widgets/page_background.dart'
    show MintPageBackgroundKey;
import 'theme_background_preview_page.dart';
import 'package:mint/ui/mint_icons.dart';

/// MIUI 主题包（.mtz）管理页。
///
/// 「完整还原」：导入后可以逐项开关 —— 壁纸（页面背景）、主题主色
/// （miuix 配色 + Material 种子）、主题字体（全局）、开机动画（启动游戏时
/// 播 boots/bootanimation.zip）。图标、AOD、时钟等模块在详情里预览；
/// 系统级模块（SystemUI / 设置 / 联系人…）只做声明展示，不改系统。
class MintThemePage extends StatefulWidget {
  const MintThemePage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<MintThemePage> createState() => _MintThemePageState();
}

class _MintThemePageState extends State<MintThemePage> {
  final MintThemeLibrary _library = MintThemeLibrary.instance;
  String? _selectedId;
  bool _importing = false;
  String _importStep = '';

  bool get miuix => mintMiuixOf(context, widget.miuix);

  @override
  void initState() {
    super.initState();
    _library.addListener(_onLibraryChanged);
    if (!_library.loaded) {
      _library.load();
    }
  }

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
    super.dispose();
  }

  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  MintTheme? get _selected =>
      _library.byId(_selectedId) ??
      (context.read<SettingsService>().activeThemeId.isNotEmpty
          ? _library.byId(context.read<SettingsService>().activeThemeId)
          : null) ??
      (_library.themes.isEmpty ? null : _library.themes.first);

  Future<void> _import() async {
    // Android 的 DocumentsUI 会按 MIME 过滤并把不认识的扩展名（.mtz）置灰。
    // file_selector 对未知扩展名映射不到 MIME，所以在 Android 上放开成
    // `*/*`，选完自己校验扩展名；桌面端继续按扩展名过滤。
    final group = Platform.isAndroid
        ? const XTypeGroup(label: 'MIUI 主题包', mimeTypes: <String>['*/*'])
        : const XTypeGroup(
            label: 'MIUI 主题包',
            extensions: <String>['mtz', 'zip'],
          );
    final picked = await openFile(acceptedTypeGroups: [group]);
    if (picked == null || !mounted) return;
    // Android 的 XFile 可能是 content:// URI：先落到临时文件再解包
    // （file_selector 的 saveTo 对 content URI 走流式拷贝）。
    File? temp;
    try {
      setState(() {
        _importing = true;
        _importStep = '读取主题包…';
      });
      // 导入在后台 isolate 里跑，这里先把进度卡画出来。
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final suffix = picked.name.toLowerCase().endsWith('.zip') ? 'zip' : 'mtz';
      temp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'mint_theme_import_${DateTime.now().millisecondsSinceEpoch}.$suffix',
      );
      await picked.saveTo(temp.path);
      if (!mounted) return;
      setState(() => _importStep = '解析模块 / 壁纸 / 图标 / 开机动画…');
      final theme = await _library.import(temp.path);
      if (!mounted) return;
      setState(() => _selectedId = theme.id);
      showMintSnack(context, '已导入「${theme.title}」');
    } catch (e) {
      if (mounted) showMintSnack(context, '导入失败：$e');
    } finally {
      runCatchingDelete(temp);
      if (mounted) {
        setState(() {
          _importing = false;
          _importStep = '';
        });
      }
    }
  }

  void _toast(String message) {
    if (mounted) showMintSnack(context, message);
  }

  void runCatchingDelete(File? file) {
    if (file == null) return;
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  Future<void> _apply(MintTheme theme, SettingsService settings) async {
    await settings.applyThemePackage(
      theme.id,
      hasWallpaper: theme.wallpaper.isNotEmpty,
      hasAccent: theme.accent != null,
      hasFont: theme.fontFile.isNotEmpty,
      hasBootAnimation: theme.bootAnimationDir.isNotEmpty,
    );
    if (mounted) _toast('已应用「${theme.title}」');
  }

  /// 关闭主题：取消套用，回到启动器自己的外观；已导入的包还在，随时再开。
  Future<void> _close(SettingsService settings) async {
    await settings.applyThemePackage('');
    if (mounted) _toast('已关闭主题');
  }

  Future<void> _remove(MintTheme theme, SettingsService settings) async {
    final ok = await showMintConfirmDialog(
      context,
      miuix: miuix,
      title: '删除主题包？',
      message: '只删除导入到 Mint 的副本（${theme.title}），不会动原始 .mtz。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok) return;
    if (settings.activeThemeId == theme.id) {
      await settings.applyThemePackage('');
    }
    await _library.remove(theme.id);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final themes = _library.themes;
    final selected = _selected;

    return MintPageScaffold(
      miuix: widget.miuix,
      title: 'MIUI 主题包',
      showBack: true,
      pageBackgroundKey: MintPageBackgroundKey.theme.id,
      actions: [
        MintTopBarAction(
          miuix: miuix,
          icon: Icons.add,
          tooltip: '导入 .mtz',
          onPressed: _importing ? null : _import,
        ),
      ],
      body: (padding) => ListView(
        padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 32),
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        children: [
          if (_importing) ...[
            GroupCard(
              miuix: miuix,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '正在导入主题包',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _importStep,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(minHeight: 3),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (themes.isEmpty && !_importing)
            _EmptyCard(miuix: miuix, onImport: _import)
          else ...[
            if (selected != null) ...[
              _ThemeHero(
                miuix: miuix,
                theme: selected,
                applied: settings.activeThemeId == selected.id,
                onApply: () => _apply(selected, settings),
                onClose: () => _close(settings),
                onRemove: () => _remove(selected, settings),
              ),
              const SizedBox(height: 12),
              if (settings.activeThemeId.isNotEmpty)
                _AppliedSwitches(miuix: miuix, settings: settings),
              if (settings.activeThemeId.isNotEmpty) const SizedBox(height: 12),
              // 背景图预览器：主题声明的整屏背景左右滑动预览，
              // 可指定到首页 / 下载 / 关于 / 底部弹窗等专属背景。
              _BackgroundsEntry(miuix: miuix, theme: selected),
              const SizedBox(height: 12),
            ],
            if (themes.length > 1) ...[
              MintSectionHeader(miuix: miuix, title: '已导入（${themes.length}）'),
              GroupCard(
                miuix: miuix,
                children: [
                  for (final (i, theme) in themes.indexed)
                    MintTile(
                      miuix: miuix,
                      title: theme.title,
                      subtitle:
                          '${theme.author.isEmpty ? '未知作者' : theme.author} · ${theme.version}'
                          '${settings.activeThemeId == theme.id ? ' · 使用中' : ''}',
                      leading: _WallpaperThumb(
                        path: theme.wallpaper,
                        size: 40,
                        fallback: theme.accent,
                      ),
                      showDivider: i != themes.length - 1,
                      trailing: settings.activeThemeId == theme.id
                          ? Icon(
                              Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary,
                              size: 20,
                            )
                          : null,
                      onTap: () => setState(() => _selectedId = theme.id),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (selected != null) ...[
              MintSectionHeader(miuix: miuix, title: '主题详情'),
              GroupCard(
                miuix: miuix,
                children: [
                  MintTile(
                    miuix: miuix,
                    icon: Icons.info_outline,
                    title: '声明的模块',
                    subtitle:
                        '${selected.modules.length} 个模块 · '
                        '${selected.colors.length} 条颜色 · '
                        '${selected.strings.length} 条字符串',
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final module in selected.modules)
                          _ModuleChip(miuix: miuix, module: module),
                      ],
                    ),
                  ),
                  if (selected.modules.every((m) => m.colorCount == 0) &&
                      selected.strings.isEmpty)
                    const SizedBox.shrink(),
                  if (selected.colors.isNotEmpty)
                    _ColorSection(miuix: miuix, theme: selected),
                  if (selected.fontFile.isNotEmpty)
                    MintTile(
                      miuix: miuix,
                      icon: Icons.text_fields,
                      title: '主题字体',
                      subtitle: selected.fontFile
                          .split(Platform.pathSeparator)
                          .last,
                    ),
                  if (selected.bootAnimationDir.isNotEmpty)
                    MintTile(
                      miuix: miuix,
                      icon: Icons.movie_outlined,
                      title: '开机动画',
                      subtitle: 'boots/bootanimation.zip（启动游戏时播放）',
                    ),
                ],
              ),
              const SizedBox(height: 12),
              MintSectionHeader(miuix: miuix, title: '控件样式（主题声明）'),
              _ControlsCard(miuix: miuix, theme: selected),
              if (selected.icons.isNotEmpty) ...[
                const SizedBox(height: 12),
                GroupCard(
                  miuix: miuix,
                  children: [
                    MintTile(
                      miuix: miuix,
                      icon: Icons.apps,
                      title: '主题图标',
                      subtitle: '${selected.icons.length} 个应用图标（按包名展示）',
                      showDivider: true,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                      child: _IconGrid(icons: selected.icons),
                    ),
                  ],
                ),
              ],
              if (selected.previews.isNotEmpty) ...[
                const SizedBox(height: 12),
                GroupCard(
                  miuix: miuix,
                  children: [
                    MintTile(
                      miuix: miuix,
                      icon: Icons.photo_library_outlined,
                      title: '主题预览',
                      subtitle: '${selected.previews.length} 张',
                    ),
                    SizedBox(
                      height: 180,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                        itemCount: selected.previews.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (context, index) => ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.file(
                            File(selected.previews[index]),
                            height: 160,
                            fit: BoxFit.cover,
                            cacheHeight: 480,
                            errorBuilder: (_, _, _) =>
                                const SizedBox(width: 90, height: 160),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }
}

/// 「背景图」入口行：主题声明了多少张整屏背景 + 已把几张指定到页面。
/// 点进左右滑动的预览器，任意一张都能设为首页 / 下载 / 关于 / 底部弹窗等
/// 的专属背景。
class _BackgroundsEntry extends StatelessWidget {
  const _BackgroundsEntry({required this.miuix, required this.theme});

  final bool miuix;
  final MintTheme theme;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final count = 1 + // 桌面壁纸
        (theme.lockWallpaper.isNotEmpty ? 1 : 0) +
        theme.backgrounds
            .where((b) => File(b.path).existsSync())
            .length;
    if (count <= 1 && theme.backgrounds.isEmpty) return const SizedBox.shrink();
    final assigned = settings.pageBackgroundAssignments;
    final assignedCount = [
      for (final path in assigned.values)
        if (path.startsWith(theme.dir)) path,
    ].length;
    return GroupCard(
      miuix: miuix,
      children: [
        MintTile(
          miuix: miuix,
          icon: Icons.wallpaper_outlined,
          title: '背景图',
          subtitle: assignedCount > 0
              ? '$count 张 · 已指定 $assignedCount 处'
              : '$count 张 · 可设为首页 / 下载 / 弹窗等专属背景',
          showDivider: false,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ThemeBackgroundPreviewPage(
                miuix: miuix,
                themeId: theme.id,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.miuix, required this.onImport});

  final bool miuix;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GroupCard(
      miuix: miuix,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 26),
          child: Column(
            children: [
              Icon(
                Icons.palette_outlined,
                size: 44,
                color: colors.primary.withValues(alpha: 0.85),
              ),
              const SizedBox(height: 14),
              Text(
                '还没有导入主题包',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '选一个 .mtz（HyperOS / MIUI 主题包），壁纸、主色、字体、'
                '图标与开机动画都会解析进来。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('导入 .mtz'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ThemeHero extends StatelessWidget {
  const _ThemeHero({
    required this.miuix,
    required this.theme,
    required this.applied,
    required this.onApply,
    required this.onClose,
    required this.onRemove,
  });

  final bool miuix;
  final MintTheme theme;
  final bool applied;
  final VoidCallback onApply;
  final VoidCallback onClose;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(miuix ? 22 : 18),
      child: Stack(
        children: [
          Positioned.fill(
            child: theme.wallpaper.isEmpty
                ? ColoredBox(color: colors.surfaceContainerHigh)
                : Image.file(
                    File(theme.wallpaper),
                    fit: BoxFit.cover,
                    cacheHeight: 720,
                    errorBuilder: (_, _, _) =>
                        ColoredBox(color: colors.surfaceContainerHigh),
                  ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.08),
                    Colors.black.withValues(alpha: 0.72),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 70, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        theme.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                    if (applied)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          '使用中',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (theme.author.isNotEmpty) theme.author,
                    theme.version,
                    'UI ${theme.uiVersion}',
                  ].where((e) => e.isNotEmpty).join(' · '),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 12,
                  ),
                ),
                if (theme.description.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    theme.description.split('\n').take(4).join('\n').trim(),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.68),
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    FilledButton(
                      onPressed: applied ? onClose : onApply,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        disabledBackgroundColor: Colors.white.withValues(
                          alpha: 0.35,
                        ),
                        disabledForegroundColor: Colors.black45,
                      ),
                      child: Text(applied ? '关闭主题' : '应用主题'),
                    ),
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: onRemove,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('删除'),
                    ),
                    const Spacer(),
                    if (theme.accent != null)
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: theme.accent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.7),
                            width: 1.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AppliedSwitches extends StatelessWidget {
  const _AppliedSwitches({required this.miuix, required this.settings});

  final bool miuix;
  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    final theme = MintThemeLibrary.instance.byId(settings.activeThemeId);
    if (theme == null) return const SizedBox.shrink();
    return GroupCard(
      miuix: miuix,
      children: [
        MintTile(
          miuix: miuix,
          icon: Icons.tune,
          title: '应用到启动器',
          subtitle: '按主题声明的模块逐项生效',
        ),
        if (theme.wallpaper.isNotEmpty)
          MintSwitchTile(
            miuix: miuix,
            icon: Icons.wallpaper_outlined,
            title: '壁纸',
            subtitle: '铺在所有页面底下（页面背景图优先）',
            value: settings.themeUseWallpaper,
            onChanged: (v) => settings.themeUseWallpaper = v,
            showDivider: true,
          ),
        if (theme.accent != null)
          MintSwitchTile(
            miuix: miuix,
            icon: Icons.color_lens_outlined,
            title: '主题主色',
            subtitle: '驱动 miuix 配色与 Material 种子色',
            value: settings.themeUseAccent,
            onChanged: (v) => settings.themeUseAccent = v,
            showDivider: true,
          ),
        if (theme.fontFile.isNotEmpty)
          MintSwitchTile(
            miuix: miuix,
            icon: Icons.text_fields,
            title: '主题字体',
            subtitle: '重新启动应用后完整生效',
            value: settings.themeUseFont,
            onChanged: (v) => settings.themeUseFont = v,
            showDivider: true,
          ),
        if (theme.bootAnimationDir.isNotEmpty)
          MintSwitchTile(
            miuix: miuix,
            icon: Icons.movie_outlined,
            title: '开机动画',
            subtitle: 'Android 启动游戏时播放 boots 动画',
            value: settings.themeUseBootAnimation,
            onChanged: (v) => settings.themeUseBootAnimation = v,
          ),
      ],
    );
  }
}

/// 主题声明的控件样式：颜色按 MIUI 资源名归类；图片类素材只解析预览，
/// 系统级手势返回装饰图不套到启动器控件上。
class _ControlsCard extends StatelessWidget {
  const _ControlsCard({required this.miuix, required this.theme});

  final bool miuix;
  final MintTheme theme;

  static const _labels = <String, String>{
    'switch': '开关（打开态轨道）',
    'back': '返回箭头',
    'button': '主按钮背景',
    'checkbox': '复选框',
    'radio': '单选框',
    'seekbar': '滑块 / 进度',
    'scrollbar': '滚动条',
    'card': '卡片半透明底色',
    'dialog': '弹窗底色',
    'dialogSelected': '弹窗选中项',
  };

  static const _applied = <String>{
    'switch',
    'back',
    'button',
    'checkbox',
    'radio',
    'seekbar',
    'scrollbar',
    'card',
    'dialog',
    'dialogSelected',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final entries = _labels.entries
        .where((e) => theme.controls.containsKey(e.key))
        .toList();
    final assets = theme.widgetAssets.entries.toList();
    return GroupCard(
      miuix: miuix,
      children: [
        for (final (i, entry) in entries.indexed)
          MintTile(
            miuix: miuix,
            leading: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color:
                    _colorOf(theme.controls[entry.value]) ??
                    colors.surfaceContainerHigh,
                shape: BoxShape.circle,
                border: Border.all(
                  color: colors.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
            ),
            title: entry.value,
            subtitle:
                '${theme.controls[entry.value]} · '
                '${_applied.contains(entry.key) ? '已应用到启动器' : '启动器没有对应控件'}',
            showDivider: i != entries.length - 1 || assets.isNotEmpty,
          ),
        if (assets.isNotEmpty) ...[
          MintTile(
            miuix: miuix,
            icon: Icons.widgets_outlined,
            title: '控件图片素材',
            subtitle: '${assets.length} 个（系统级图片只解析预览）',
            showDivider: true,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final asset in assets)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 44,
                          height: 44,
                          color: colors.surfaceContainerHigh,
                          child: Image.file(
                            File(asset.value),
                            fit: BoxFit.contain,
                            cacheWidth: 132,
                            errorBuilder: (_, _, _) => const SizedBox(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _assetLabel(asset.key),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
        if (entries.isEmpty && assets.isEmpty)
          MintTile(
            miuix: miuix,
            icon: Icons.tune,
            title: '主题没有声明控件样式',
            subtitle: '开关 / 返回 / 按钮等继续用 miuix 默认样式',
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
          child: Text(
            '没有开关图片时用 theme_values 里的开关颜色；手势返回装饰图属于'
            '系统级素材，不套到应用栏按钮上。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: colors.onSurfaceVariant.withValues(alpha: 0.85),
            ),
          ),
        ),
      ],
    );
  }

  String _assetLabel(String role) => switch (role) {
    'switchOn' => '开关·开',
    'switchOff' => '开关·关',
    'switchTrack' => '开关轨道',
    'switchThumb' => '开关拇指',
    'back' => '返回',
    'backArt' => '手势返回',
    'button' => '按钮',
    'checkbox' => '复选框',
    'radio' => '单选框',
    'seekbar' => '滑块',
    'scrollbar' => '滚动条',
    _ => role,
  };

  Color? _colorOf(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.startsWith('0x')) text = '#${text.substring(2)}';
    if (!text.startsWith('#')) return null;
    var hex = text.substring(1);
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length == 3) {
      hex = 'FF${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
    }
    final value = int.tryParse(hex, radix: 16);
    return value == null ? null : Color(value);
  }
}

class _ModuleChip extends StatelessWidget {
  const _ModuleChip({required this.miuix, required this.module});

  final bool miuix;
  final MintThemeModule module;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = switch (module.kind) {
      'icons' => '图标',
      'boots' => '开机动画',
      'font' => '字体',
      'wallpaper' => '壁纸',
      'framework' => '框架资源',
      'values' => '颜色值',
      _ => '系统覆盖',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '${module.name} · $label'
        '${module.assetCount > 0 ? ' · ${module.assetCount}' : ''}',
        style: TextStyle(
          fontSize: 11.5,
          color: colors.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _ColorSection extends StatelessWidget {
  const _ColorSection({required this.miuix, required this.theme});

  final bool miuix;
  final MintTheme theme;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final entries = theme.colors.entries.take(10).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '声明的颜色（示例）',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: _colorOf(entry.value) ?? Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: colors.outlineVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    entry.value,
                    style: TextStyle(
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Color? _colorOf(String raw) {
    var text = raw.trim();
    if (text.startsWith('0x')) text = '#${text.substring(2)}';
    if (!text.startsWith('#')) return null;
    var hex = text.substring(1);
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length == 3) {
      hex = 'FF${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
    }
    final value = int.tryParse(hex, radix: 16);
    return value == null ? null : Color(value);
  }
}

class _IconGrid extends StatelessWidget {
  const _IconGrid({required this.icons});

  final List<MintThemeIcon> icons;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: icons.length,
      itemBuilder: (context, index) {
        final icon = icons[index];
        return Tooltip(
          message: icon.packageName,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(icon.path),
              fit: BoxFit.contain,
              cacheWidth: 144,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: Colors.transparent),
            ),
          ),
        );
      },
    );
  }
}

class _WallpaperThumb extends StatelessWidget {
  const _WallpaperThumb({
    required this.path,
    required this.size,
    this.fallback,
  });

  final String path;
  final double size;
  final Color? fallback;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fallback ?? Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
    );
    if (path.isEmpty || !File(path).existsSync()) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 3).round(),
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

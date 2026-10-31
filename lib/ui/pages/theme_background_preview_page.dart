import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/nine_patch.dart' show resolveDisplayImage;
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/theme_package.dart';
import 'package:mint/ui/mint_icons.dart' show MintBackIcon;
import 'package:mint/ui/widgets/page_background.dart'
    show MintPageBackgroundKey;

/// mtz 背景图预览器：主题包里所有「应用声明背景」按左右滑动铺开预览，
/// 任何一张都可以指定给启动器的某个页面（首页 / 下载 / 设置 / 关于 /
/// 底部弹窗）当专属背景 —— MIUI 主题本来就是按应用声明整屏背景的，
/// 这里把同一套素材接到启动器自己的页面上。
///
/// 入口：主题页的「背景图」行（也接受 [themeId] 直接落到某个主题）。
class ThemeBackgroundPreviewPage extends StatefulWidget {
  const ThemeBackgroundPreviewPage({
    super.key,
    required this.miuix,
    required this.themeId,
    this.initialIndex = 0,
  });

  final bool miuix;
  final String themeId;
  final int initialIndex;

  @override
  State<ThemeBackgroundPreviewPage> createState() =>
      _ThemeBackgroundPreviewPageState();
}

class _ThemeBackgroundPreviewPageState
    extends State<ThemeBackgroundPreviewPage> {
  late final PageController _pager;
  late List<_BgItem> _items;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pager = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _collectItems();
  }

  void _collectItems() {
    context.watch<SettingsService>();
    final theme = MintThemeLibrary.instance.byId(widget.themeId);
    final items = <_BgItem>[];
    if (theme != null) {
      // 壁纸在最前（它是主题的「全局默认」），然后按模块铺开声明的背景。
      if (theme.wallpaper.isNotEmpty) {
        items.add(
          _BgItem(
            path: theme.wallpaper,
            title: '桌面壁纸',
            subtitle: theme.title,
            module: 'wallpaper',
          ),
        );
      }
      if (theme.lockWallpaper.isNotEmpty) {
        items.add(
          _BgItem(
            path: theme.lockWallpaper,
            title: '锁屏壁纸',
            subtitle: theme.title,
            module: 'wallpaper',
          ),
        );
      }
      for (final b in theme.backgrounds) {
        if (!File(b.path).existsSync()) continue;
        items.add(
          _BgItem(
            path: b.path,
            title: bgResourceLabel(b.name),
            subtitle: bgModuleLabel(b.module),
            module: b.module,
            dark: b.dark,
            name: b.name,
          ),
        );
      }
    }
    _items = items;
    if (_index >= items.length) _index = items.isEmpty ? 0 : items.length - 1;
  }

  void _assign(BuildContext context, MintPageBackgroundKey key, String path) {
    final settings = context.read<SettingsService>();
    final current = settings.pageBackgroundFor(key.id);
    // 已经指定成这张图 → 再点一次取消。
    settings.setPageBackground(key.id, current == path ? '' : path);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final assignments = context
        .watch<SettingsService>()
        .pageBackgroundAssignments;
    final current = _items.isEmpty ? null : _items[_index.clamp(0, _items.length - 1)];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF101014),
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (_items.isEmpty)
              const Center(
                child: Text(
                  '这个主题没有声明背景图',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              )
            else ...[
              // 左右滑动的整屏预览。
              NotificationListener<ScrollNotification>(
                onNotification: (_) => false,
                child: PageView.builder(
                  controller: _pager,
                  itemCount: _items.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) {
                    final item = _items[i];
                    return InteractiveViewer(
                      maxScale: 4,
                      child: Center(
                        child: Image.file(
                          File(resolveDisplayImage(item.path)),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // 底部信息 + 指定按钮。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _BottomPanel(
                  item: current,
                  index: _index,
                  total: _items.length,
                  assignments: assignments,
                  items: _items,
                  pager: _pager,
                  onIndexChanged: (i) => setState(() => _index = i),
                  onAssign: (key) =>
                      _assign(context, key, current?.path ?? ''),
                ),
              ),
            ],
            // 顶部：返回 + 页码。
            SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 0, 0),
                  child: IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: MintBackIcon(size: 24, color: Colors.white),
                  ),
                ),
              ),
            ),
            if (_items.isNotEmpty)
              SafeArea(
                bottom: false,
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 12, 16, 0),
                    child: Text(
                      '${_index + 1} / ${_items.length}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 资源名 → 中文标签。
String bgResourceLabel(String name) => switch (name) {
  'window_bg' => '窗口背景',
  'miuix_appcompat_window_bg' => '应用窗口背景',
  'miuix_appcompat_settings_window_bg' => '设置 / 关于背景',
  'dialerpad_background' => '拨号盘背景',
  'dialer_background_pad' => '拨号背景',
  'conversation_bg' => '短信会话背景',
  _ => name,
};

/// 模块名 → 中文标签。
String bgModuleLabel(String module) => switch (module) {
  'com.android.contacts' => '电话与联系人',
  'com.android.settings' => '系统设置',
  'com.android.mms' => '短信',
  'com.android.providers.downloads.ui' => '下载管理',
  'com.android.systemui' => '系统界面',
  'com.miui.home' => '桌面',
  'com.miui.securitycenter' => '安全中心',
  'com.android.updater' => '系统更新',
  'framework-res' => '系统框架',
  'framework-miui-res' => 'MIUI 框架',
  'miui.systemui.plugin' => 'SystemUI 插件',
  'wallpaper' => '壁纸',
  _ => module,
};

class _BgItem {
  const _BgItem({
    required this.path,
    required this.title,
    required this.subtitle,
    required this.module,
    this.dark = false,
    this.name = '',
  });

  final String path;
  final String title;
  final String subtitle;
  final String module;
  final bool dark;
  final String name;
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.item,
    required this.index,
    required this.total,
    required this.assignments,
    required this.items,
    required this.pager,
    required this.onIndexChanged,
    required this.onAssign,
  });

  final _BgItem? item;
  final int index;
  final int total;
  final Map<String, String> assignments;
  final List<_BgItem> items;
  final PageController pager;
  final ValueChanged<int> onIndexChanged;
  final ValueChanged<MintPageBackgroundKey> onAssign;

  /// 当前这张图正被指定到哪些页面。
  List<MintPageBackgroundKey> _keysFor(String path) => [
    for (final k in MintPageBackgroundKey.values)
      if (assignments[k.id] == path) k,
  ];

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    if (item == null) return const SizedBox.shrink();
    final assigned = _keysFor(item.path);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00101014), Color(0xF0101014)],
          stops: [0, 0.35],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (item.dark) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                '夜间',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.62),
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (assigned.isNotEmpty)
                  Text(
                    '已用于 ${assigned.map((k) => k.label).join(' / ')}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Colors.lightBlueAccent.withValues(alpha: 0.95),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // 「设为 …」chip 行：已指定的实心，再点一次取消。
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final key in MintPageBackgroundKey.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _AssignChip(
                        label: key == MintPageBackgroundKey.sheet
                            ? '底部弹窗'
                            : '设为${key.label}背景',
                        selected: assigned.contains(key),
                        onTap: () => onAssign(key),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 缩略图条：点击直接跳页。
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: items.length,
                      itemExtent: 44,
                      itemBuilder: (context, i) {
                        final it = items[i];
                        final selected = i == index;
                        final usedByKeys = _keysFor(it.path);
                        return GestureDetector(
                          onTap: () {
                            onIndexChanged(i);
                            pager.animateToPage(
                              i,
                              duration: const Duration(milliseconds: 280),
                              curve: Curves.easeOutCubic,
                            );
                          },
                          child: Container(
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                width: selected ? 2 : 1,
                                color: selected
                                    ? Colors.white
                                    : Colors.white24,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.file(
                                    File(resolveDisplayImage(it.path)),
                                    fit: BoxFit.cover,
                                    filterQuality: FilterQuality.low,
                                    gaplessPlayback: true,
                                    errorBuilder: (_, _, _) =>
                                        const ColoredBox(
                                          color: Color(0xFF2A2A30),
                                        ),
                                  ),
                                  if (usedByKeys.isNotEmpty)
                                    Positioned(
                                      top: 2,
                                      right: 2,
                                      child: Container(
                                        width: 6,
                                        height: 6,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF7FC3FF),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 指定 chip：实心 = 已指定（再点取消）。
class _AssignChip extends StatelessWidget {
  const _AssignChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF7FC3FF)
              : Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            width: 1,
            color: selected
                ? const Color(0xFF7FC3FF)
                : Colors.white.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? const Color(0xFF0D1B2A) : Colors.white.withValues(alpha: 0.9),
          ),
        ),
      ),
    );
  }
}

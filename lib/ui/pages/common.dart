import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/services/crash_analyzer.dart' show CrashAnalysis;
import 'package:mint/services/native_toast_service.dart';
import 'package:mint/services/nine_patch.dart' show resolveDisplayImage;
import 'package:mint/services/theme_package.dart';
import 'package:mint/ui/mint_icons.dart' show mintFluentOf, mintMiuixOf;
import 'package:mint/ui/widgets/page_background.dart'
    show mintCardMaskColor, mintDialogMaskColor, mintSheetBackgroundPathOf;
import 'package:mint/widgets/ios_push_transition.dart' show MiuixNavSettleCurve;

// ───────────────────────── 加载器图标 ─────────────────────────

/// HMCL（GPL-3.0）的加载器图标。
///
/// Forge 的图标是深灰铁砧 + 透明底，深色主题下几乎看不见 —— 给它垫一块
/// 浅色圆角小板；其它图标本身够亮，保持透明。
Widget loaderIconAsset(String name, {double size = 20}) =>
    _LoaderIcon(name: name, size: size);

class _LoaderIcon extends StatelessWidget {
  const _LoaderIcon({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      'assets/icons/$name.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.high,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (name == 'forge' && dark) {
      return Container(
        width: size + 8,
        height: size + 8,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFFE8E8EC),
          borderRadius: BorderRadius.circular(size * 0.28),
        ),
        child: image,
      );
    }
    return image;
  }
}

const Set<String> _kLoaderIconNames = {
  'forge',
  'neoforge',
  'fabric',
  'quilt',
  'optifine',
  'grass',
  'command_block',
  'cobblestone',
};

/// version_manifest 的 type → 方块图标（HMCL 下载页同款）：
/// 正式版草方块 / 快照命令方块 / 远古版原石。
String blockIconForManifestType(String type) => switch (type) {
  'release' => 'grass',
  'snapshot' => 'command_block',
  _ => 'cobblestone', // old_beta / old_alpha / 未知
};

/// 版本 id → 加载器图标资源名（unknown = grass 原版）。
///
/// [loader] 是 GameDir.metaOf 从版本 json 里识别出的加载器；整合包版本
/// 的目录名经常不含 fabric / forge，仅靠 id 会全部落成原版。
String loaderIconNameForVersion(String id, {String? loader}) {
  if (loader != null && loader.isNotEmpty) {
    return switch (loader) {
      'fabric' => 'fabric',
      'quilt' => 'quilt',
      'forge' => 'forge',
      'neoforge' => 'neoforge',
      'optifine' => 'optifine',
      _ => 'grass',
    };
  }
  final v = id.toLowerCase();
  final direct = _kLoaderIconNames.firstWhere(
    (name) => name != 'grass' && v.contains(name),
    orElse: () => '',
  );
  if (direct == 'forge' && v.contains('neoforge')) return 'neoforge';
  return direct.isEmpty ? 'grass' : direct;
}

/// 版本 id → 加载器展示名（「原版」兜底）。
String loaderLabelForVersion(String id, {String? loader}) {
  if (loader != null && loader.isNotEmpty) {
    return switch (loader) {
      'fabric' => 'Fabric',
      'quilt' => 'Quilt',
      'forge' => 'Forge',
      'neoforge' => 'NeoForge',
      'optifine' => 'OptiFine',
      'liteloader' => 'LiteLoader',
      'rift' => 'Rift',
      _ => '原版',
    };
  }
  final icon = loaderIconNameForVersion(id);
  return switch (icon) {
    'fabric' => 'Fabric',
    'quilt' => 'Quilt',
    'forge' => 'Forge',
    'neoforge' => 'NeoForge',
    'optifine' => 'OptiFine',
    _ => '原版',
  };
}

/// version_manifest 的 ISO 时间 → 本地 `yyyy-MM-dd HH:mm`。
///
/// 下载页列表统一只显示发布日期和时间（类型已经由分组卡片标题表达），
/// 解析失败就退回原串，避免把整行搞崩。
String formatReleaseTime(String raw) {
  if (raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw;
  final local = parsed.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// 游戏版本下拉的条目文案（标出快照/远古版）。
String gameDropdownLabel(String id, String type, bool installed) {
  final suffix = switch (type) {
    'snapshot' => '（快照）',
    'old_beta' => '（Beta）',
    'old_alpha' => '（Alpha）',
    _ => '',
  };
  return installed ? '$id（已安装）$suffix' : '$id$suffix';
}

// ───────────────────────── 卡片 / 行 ─────────────────────────

/// 一组行收进圆角卡片。
class MintCard extends StatelessWidget {
  const MintCard({super.key, required this.miuix, required this.children});

  final bool miuix;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      final colors = MiuixCardDefaults.defaultColors(context);
      final shape = MiuixSquircleBorder(cornerRadius: 18);
      // 不能直接用 MiuixCard：它只画 squircle 背景、不裁子节点，而
      // MiuixBasicComponent 的按压/悬停遮罩是一个铺满整行的矩形。
      // 点在「游戏目录」这类分组卡片里时，遮罩会把卡片的圆角盖成直角
      // （点击态伸到卡片外面）。这里按同一个 squircle 先把内容裁一刀，
      // 遮罩就只留在卡面轮廓内。
      return MiuixContentColor(
        color: colors.contentColor,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            // 有背景图时改用主题声明的半透明卡面色，壁纸从卡下透出来。
            color: mintCardMaskColor(context, colors.color),
            shape: shape,
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(
              shape: shape,
              textDirection: Directionality.of(context),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: mintCardMaskColor(context, cs.surfaceContainerLow),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// 通用行：leading 图标 + 标题 + 副标题 + 尾部控件。
class MintTile extends StatelessWidget {
  const MintTile({
    super.key,
    required this.miuix,
    this.icon,
    this.iconColor,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.showDivider = true,
    this.enabled = true,
  });

  final bool miuix;
  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final start =
        leading ??
        (icon == null
            ? null
            : Icon(
                icon,
                size: 22,
                color: enabled
                    ? (iconColor ?? cs.primary)
                    : cs.onSurface.withValues(alpha: 0.35),
              ));

    Widget row;
    if (miuix) {
      row = MiuixBasicComponent(
        title: title,
        summary: subtitle,
        startAction: start,
        endActions: trailing == null ? null : [trailing!],
        insideMargin: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        onClick: enabled ? onTap : null,
        role: onTap == null ? null : MiuixBasicComponentRole.button,
        enabled: enabled,
      );
    } else {
      row = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                if (start != null) ...[start, const SizedBox(width: 14)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: enabled
                              ? cs.onSurface
                              : cs.onSurface.withValues(alpha: 0.35),
                        ),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              ],
            ),
          ),
        ),
      );
    }

    if (!showDivider) return row;
    if (miuix) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: MiuixHorizontalDivider(
              color: MiuixTheme.of(
                context,
              ).colors.dividerLine.withValues(alpha: 0.6),
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
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

/// 主题声明的 miuix 开关配色（打开态轨道）。没声明返回 null，走默认。
MiuixSwitchColors? mintSwitchColorsOf(BuildContext context) {
  final color = MintThemeLibrary.instance.activeTheme?.switchColor;
  if (color == null) return null;
  final c = MiuixTheme.of(context).colors;
  return MiuixSwitchColors(
    checkedThumbColor: c.onPrimary,
    uncheckedThumbColor: c.onSecondary,
    disabledCheckedThumbColor: c.disabledOnPrimary,
    disabledUncheckedThumbColor: c.disabledOnSecondary,
    checkedTrackColor: color,
    uncheckedTrackColor: c.secondary,
    disabledCheckedTrackColor: c.disabledPrimary,
    disabledUncheckedTrackColor: c.disabledSecondary,
  );
}

/// 开关行。
class MintSwitchTile extends StatelessWidget {
  const MintSwitchTile({
    super.key,
    required this.miuix,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.showDivider = false,
  });

  final bool miuix;
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? subtitle;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final switchColor = MintThemeLibrary.instance.activeTheme?.switchColor;
    return MintTile(
      miuix: miuix,
      icon: icon,
      title: title,
      subtitle: subtitle,
      showDivider: showDivider,
      trailing: miuix
          ? MiuixSwitch(
              value: value,
              onChanged: onChanged,
              // 主题声明了开关色（miuix_appcompat_sliding_button_bar_on_*）时
              // 打开态轨道跟着走；拇指保持 onPrimary（白）。
              colors: mintSwitchColorsOf(context),
            )
          : Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: switchColor,
            ),
    );
  }
}

/// 分区小标题（两套风格统一留白，不再一页里出现三种标题字号）。
class MintSectionHeader extends StatelessWidget {
  const MintSectionHeader({
    super.key,
    required this.miuix,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(4, 18, 4, 8),
  });

  final bool miuix;
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: miuix
                ? MiuixSmallTitle(
                    title,
                    insideMargin: EdgeInsets.zero,
                    textColor: cs.onSurfaceVariant,
                  )
                : Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 空状态卡片：图标 + 主标题 + 说明 + 可选动作按钮。
class MintEmptyState extends StatelessWidget {
  const MintEmptyState({
    super.key,
    required this.miuix,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final bool miuix;
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MintCard(
      miuix: miuix,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
          child: Column(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 26, color: cs.primary),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (message != null && message!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 18), action!],
            ],
          ),
        ),
      ],
    );
  }
}

/// 提示条（Fabric API、目标版本等）：低饱和底色 + 图标 + 动作。
class MintNotice extends StatelessWidget {
  const MintNotice({
    super.key,
    required this.miuix,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final bool miuix;
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
    final decorated = Material(
      color: cs.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
    return decorated;
  }
}

// ───────────────────────── 按钮 ─────────────────────────

/// 主按钮：miuix 用 MiuixButton 主色，Material 用 FilledButton（胶囊以外
/// 采用 18 圆角，与卡片一致）。
class MintPrimaryButton extends StatelessWidget {
  const MintPrimaryButton({
    super.key,
    required this.miuix,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 50,
    this.expand = true,
  });

  final bool miuix;
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      final child = Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 20,
              color: MiuixTheme.of(context).colors.onPrimary,
            ),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ],
      );
      return MiuixButton(
        onPressed: onPressed,
        colors: MiuixButtonDefaults.buttonColorsPrimary(context),
        cornerRadius: 18,
        minHeight: height,
        minWidth: 64,
        insideMargin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: child,
      );
    }
    final style = FilledButton.styleFrom(
      minimumSize: Size(expand ? double.infinity : 0, height),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    );
    return icon == null
        ? FilledButton(onPressed: onPressed, style: style, child: Text(label))
        : FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon, size: 20),
            label: Text(label),
          );
  }
}

/// 次级按钮（描边/浅底）。
class MintSecondaryButton extends StatelessWidget {
  const MintSecondaryButton({
    super.key,
    required this.miuix,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 40,
  });

  final bool miuix;
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      return MiuixButton(
        onPressed: onPressed,
        cornerRadius: 14,
        minHeight: height,
        insideMargin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18),
              const SizedBox(width: 6),
            ],
            Text(label, style: const TextStyle(fontSize: 14)),
          ],
        ),
      );
    }
    final style = OutlinedButton.styleFrom(
      minimumSize: Size(0, height),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    );
    return icon == null
        ? OutlinedButton(onPressed: onPressed, style: style, child: Text(label))
        : OutlinedButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon, size: 18),
            label: Text(label),
          );
  }
}

/// 搜索框：miuix 用 MiuixTextField，Material 用 TextField。
class MintSearchField extends StatelessWidget {
  const MintSearchField({
    super.key,
    required this.miuix,
    required this.hint,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  final bool miuix;
  final String hint;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      return MiuixTextField(
        controller: controller,
        focusNode: focusNode,
        label: hint,
        useLabelAsPlaceholder: true,
        singleLine: true,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        leadingIcon: const Icon(Icons.search, size: 20),
        insideMargin: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      );
    }
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      autofocus: autofocus,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
      ),
    );
  }
}

/// 分段选择（离线/外置登录、正式版/快照等）：自绘 pill，
/// 两套风格共用，避免 MiuixTabRow 在深色主题下选中态和轨道糊在一起。
class MintSegmentedTabs extends StatelessWidget {
  const MintSegmentedTabs({
    super.key,
    required this.miuix,
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  final bool miuix;
  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final track = dark
        ? cs.surfaceContainerHighest.withValues(alpha: 0.65)
        : cs.surfaceContainerHighest.withValues(alpha: 0.7);
    final pill = miuix ? cs.primary : cs.secondaryContainer;
    final pillText = miuix ? cs.onPrimary : cs.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: track,
        borderRadius: BorderRadius.circular(miuix ? 14 : 12),
      ),
      child: Row(
        children: [
          for (final (i, label) in tabs.indexed)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelected(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: i == selected ? pill : Colors.transparent,
                    borderRadius: BorderRadius.circular(miuix ? 11 : 9),
                    boxShadow: i == selected && !dark
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 6,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: i == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: i == selected ? pillText : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 小号文字按钮（卡片内动作）。
class MintTextAction extends StatelessWidget {
  const MintTextAction({
    super.key,
    required this.miuix,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final bool miuix;
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (miuix) {
      return MiuixButton(
        onPressed: onPressed,
        cornerRadius: 12,
        minHeight: 32,
        insideMargin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16),
              const SizedBox(width: 4),
            ],
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );
    }
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: cs.primary,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 4)],
          Text(label),
        ],
      ),
    );
  }
}

/// 全局 miuix Snackbar 宿主：页面 State 里的方法（context 在
/// MintPageScaffold 之上）找不到页面作用域时兜底用这个。挂载在 MaterialApp
/// 的 builder 上，盖在所有路由之上。
class MintGlobalSnack {
  MintGlobalSnack._();

  static final MiuixSnackbarHostState host = MiuixSnackbarHostState();
  static bool miuix = false;
}

/// miuix 页面的 Snackbar 宿主作用域。
///
/// MiuixScaffold 底下没有 Material Scaffold，app 级 ScaffoldMessenger 的
/// SnackBar 会落到首页的 Scaffold 上（当前页根本看不到）。每个
/// [MintPageScaffold] 在 miuix 模式下创建自己的 [MiuixSnackbarHostState]，
/// 这里把宿主挂到 InheritedWidget 上，[showMintSnack] 优先走它。
class MintSnackScope extends InheritedWidget {
  const MintSnackScope({super.key, required this.host, required super.child});

  final MiuixSnackbarHostState host;

  static MiuixSnackbarHostState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MintSnackScope>()?.host;

  @override
  bool updateShouldNotify(MintSnackScope oldWidget) => host != oldWidget.host;
}

/// 统一 SnackBar：miuix 走 MiuixSnackbarHost，Material 走 ScaffoldMessenger。
void showMintSnack(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) {
  // 「使用系统 Toast」：短提示走 Android 原生 Toast（带按钮的提示仍需
  // SnackBar / miuix snackbar 承载动作）。
  if (action == null && NativeToastService.enabled) {
    NativeToastService.show(message);
    if (NativeToastService.available) return;
  }
  final host =
      MintSnackScope.maybeOf(context) ??
      (MintGlobalSnack.miuix ? MintGlobalSnack.host : null);
  if (host != null) {
    host
        .showSnackbar(
          message,
          actionLabel: action?.label,
          duration: action == null
              ? MiuixSnackbarDuration.short
              : MiuixSnackbarDuration.custom(5000),
        )
        .then((result) {
          if (result == MiuixSnackbarResult.actionPerformed) {
            action?.onPressed();
          }
        });
    return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  // 防御：当前没有任何已注册的 Material Scaffold 时（风格切换的瞬间、
  // 或某个没有 Scaffold 宿主的上下文），showSnackBar 在 debug 会命中
  // 「no descendant Scaffolds」断言。release 下本来就是静默跳过，
  // 这里让 debug 行为一致（打印到控制台），不再打断调试。
  try {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          action: action,
        ),
      );
  } catch (e) {
    debugPrint('showMintSnack 无法呈现（没有 Material Scaffold 宿主）：$message ($e)');
  }
}

/// 跨页面 SnackBar：页面会被立刻关掉（安装转后台）时用这个。
///
/// 页面作用域的 [MintSnackScope] 会随路由销毁，所以固定走 app 级
/// miuix host / 根 ScaffoldMessenger；Material 下 SnackBar 挂在
/// MaterialApp 的 messenger 上，路由切换不会把它带走。
void showMintSnackAboveRoutes(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) {
  if (MintGlobalSnack.miuix) {
    MintGlobalSnack.host
        .showSnackbar(
          message,
          actionLabel: action?.label,
          duration: action == null
              ? MiuixSnackbarDuration.short
              : MiuixSnackbarDuration.custom(5000),
        )
        .then((result) {
          if (result == MiuixSnackbarResult.actionPerformed) {
            action?.onPressed();
          }
        });
    return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  try {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          action: action,
        ),
      );
  } catch (e) {
    debugPrint('showMintSnackAboveRoutes 无法呈现：$message ($e)');
  }
}

/// 确认对话框：miuix 用 HyperOS 居中圆角卡（左取消 / 右确定），
/// fluent 用 Win11 ContentDialog 观感（8px 圆角 + FluentTheme 资源色），
/// Material 用 AlertDialog。
enum _MintDialogStyle { miuix, fluent, material }

_MintDialogStyle _mintDialogStyle(BuildContext context, bool miuix) => miuix
    ? _MintDialogStyle.miuix
    : mintFluentOf(context)
    ? _MintDialogStyle.fluent
    : _MintDialogStyle.material;

/// 三风格对话框外壳：标题 + 内容列 + 右下动作区。
/// miuix → 28px 圆角 HyperOS 卡；fluent → Win11 ContentDialog；
/// Material → AlertDialog。
class MintStyleDialogShell extends StatelessWidget {
  const MintStyleDialogShell({
    super.key,
    required this.miuix,
    required this.title,
    required this.children,
    this.actions = const [],
    this.maxWidth = 460,
  });

  final bool miuix;
  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    switch (_mintDialogStyle(context, miuix)) {
      case _MintDialogStyle.fluent:
        final theme = fluent.FluentTheme.of(context);
        return Dialog(
          backgroundColor: theme.resources.solidBackgroundFillColorBase,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: theme.typography.subtitle?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ...children,
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: actions,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      case _MintDialogStyle.miuix:
        final c = MiuixTheme.of(context).colors;
        return Dialog(
          backgroundColor: mintDialogMaskColor(context, c.background),
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ...children,
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: actions,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      case _MintDialogStyle.material:
        return AlertDialog(
          title: Text(title),
          content: children.isEmpty
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
          actions: actions,
        );
    }
  }
}

/// 三风格对话框动作按钮组（取消在左、确认在右）。
List<Widget> mintDialogActions(
  BuildContext context, {
  required bool miuix,
  required VoidCallback onCancel,
  required VoidCallback onConfirm,
  String cancelLabel = '取消',
  String confirmLabel = '确定',
  bool destructive = false,
}) {
  switch (_mintDialogStyle(context, miuix)) {
    case _MintDialogStyle.fluent:
      return [
        fluent.Button(
          onPressed: onCancel,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(cancelLabel),
          ),
        ),
        const SizedBox(width: 8),
        fluent.FilledButton(
          onPressed: onConfirm,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(confirmLabel),
          ),
        ),
      ];
    case _MintDialogStyle.miuix:
      final c = MiuixTheme.of(context).colors;
      return [
        MiuixButton(onPressed: onCancel, child: Text(cancelLabel)),
        const SizedBox(width: 8),
        MiuixButton(
          onPressed: onConfirm,
          colors: destructive
              ? MiuixButtonColors(
                  color: c.error,
                  disabledColor: c.disabledPrimaryButton,
                  contentColor: c.onError,
                  disabledContentColor: c.disabledOnPrimaryButton,
                )
              : MiuixButtonDefaults.buttonColorsPrimary(context),
          child: Text(confirmLabel),
        ),
      ];
    case _MintDialogStyle.material:
      return [
        TextButton(onPressed: onCancel, child: Text(cancelLabel)),
        FilledButton(
          onPressed: onConfirm,
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ];
  }
}

/// 三风格文本框：miuix → MiuixTextField，fluent → TextBox，
/// Material → TextField。
class MintStyleTextField extends StatelessWidget {
  const MintStyleTextField({
    super.key,
    this.controller,
    this.hint = '',
    this.multiline = false,
    this.suffix,
    this.autofocus = false,
    this.numeric = false,
  });

  final TextEditingController? controller;
  final String hint;
  final bool multiline;
  final Widget? suffix;
  final bool autofocus;
  final bool numeric;

  @override
  Widget build(BuildContext context) {
    switch (_mintDialogStyle(context, mintMiuixOf(context))) {
      case _MintDialogStyle.fluent:
        return fluent.TextBox(
          controller: controller,
          placeholder: hint,
          maxLines: multiline ? 5 : 1,
          autofocus: autofocus,
          suffix: suffix == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: suffix,
                ),
        );
      case _MintDialogStyle.miuix:
        return MiuixTextField(
          controller: controller,
          label: hint,
          useLabelAsPlaceholder: true,
          singleLine: !multiline,
          autofocus: autofocus,
          insideMargin: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
        );
      case _MintDialogStyle.material:
        return TextField(
          controller: controller,
          autofocus: autofocus,
          maxLines: multiline ? 5 : 1,
          keyboardType: numeric ? TextInputType.number : null,
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: suffix,
            isDense: true,
          ),
        );
    }
  }
}

/// 通用输入对话框（三风格）：单行 / 多行，返回原始输入（调用方自行 trim）。
///
/// controller 由对话框的 State 持有 —— `showDialog` 返回时退场动画还在播，
/// 外面立刻 `controller.dispose()` 会在动画 tick 重建仍在树里的 TextField 时
/// 撞上已 dispose 的 controller（debug 红屏 / 99k 像素溢出）。
Future<String?> showMintInputDialog(
  BuildContext context, {
  required bool miuix,
  required String title,
  String initial = '',
  String hint = '',
  bool multiline = false,
  String confirmLabel = '保存',
  Widget? suffix,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _MintInputDialog(
      miuix: miuix,
      title: title,
      initial: initial,
      hint: hint,
      multiline: multiline,
      confirmLabel: confirmLabel,
      suffix: suffix,
    ),
  );
}

class _MintInputDialog extends StatefulWidget {
  const _MintInputDialog({
    required this.miuix,
    required this.title,
    required this.initial,
    required this.hint,
    required this.multiline,
    required this.confirmLabel,
    required this.suffix,
  });

  final bool miuix;
  final String title;
  final String initial;
  final String hint;
  final bool multiline;
  final String confirmLabel;
  final Widget? suffix;

  @override
  State<_MintInputDialog> createState() => _MintInputDialogState();
}

class _MintInputDialogState extends State<_MintInputDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return MintStyleDialogShell(
      miuix: widget.miuix,
      title: widget.title,
      actions: mintDialogActions(
        context,
        miuix: widget.miuix,
        onCancel: () => Navigator.pop(context),
        onConfirm: _submit,
        confirmLabel: widget.confirmLabel,
      ),
      children: [
        MintStyleTextField(
          controller: _controller,
          hint: widget.hint,
          multiline: widget.multiline,
          suffix: widget.suffix,
          autofocus: true,
        ),
      ],
    );
  }
}

/// 确认对话框：miuix 用 HyperOS 居中圆角卡（左取消 / 右确定），
/// Material 用 AlertDialog。
Future<bool> showMintConfirmDialog(
  BuildContext context, {
  required bool miuix,
  required String title,
  String? message,
  String cancelLabel = '取消',
  String confirmLabel = '确定',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      if (miuix) {
        final c = MiuixTheme.of(dialogContext).colors;
        return Dialog(
          backgroundColor: mintDialogMaskColor(dialogContext, c.background),
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (message != null && message.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: c.onSurfaceVariantSummary,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    MiuixButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(cancelLabel),
                    ),
                    const SizedBox(width: 8),
                    MiuixButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      colors: destructive
                          ? MiuixButtonColors(
                              color: c.error,
                              disabledColor: c.disabledPrimaryButton,
                              contentColor: c.onError,
                              disabledContentColor: c.disabledOnPrimaryButton,
                            )
                          : MiuixButtonDefaults.buttonColorsPrimary(
                              dialogContext,
                            ),
                      child: Text(confirmLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
      if (!miuix && mintFluentOf(context)) {
        final theme = fluent.FluentTheme.of(dialogContext);
        return MintStyleDialogShell(
          miuix: false,
          title: title,
          actions: mintDialogActions(
            dialogContext,
            miuix: false,
            onCancel: () => Navigator.pop(dialogContext, false),
            onConfirm: () => Navigator.pop(dialogContext, true),
            cancelLabel: cancelLabel,
            confirmLabel: confirmLabel,
            destructive: destructive,
          ),
          children: [
            if (message != null && message.isNotEmpty)
              Text(
                message,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: theme.resources.textFillColorSecondary,
                ),
              ),
          ],
        );
      }
      return AlertDialog(
        title: Text(title),
        content: message == null || message.isEmpty ? null : Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(dialogContext).colorScheme.error,
                    foregroundColor: Theme.of(
                      dialogContext,
                    ).colorScheme.onError,
                  )
                : null,
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// 单选对话框条目。
class MintChoice<T> {
  const MintChoice({
    required this.value,
    required this.label,
    this.subtitle,
    this.icon,
    this.enabled = true,
    this.destructive = false,
  });

  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  final bool enabled;
  final bool destructive;
}

/// fluent 风格的单选行（fluent.ListTile + RadioButton）。
class _FluentChoiceRow<T> extends StatelessWidget {
  const _FluentChoiceRow({
    required this.option,
    required this.checked,
    required this.isCurrent,
    required this.onTap,
  });

  final MintChoice<T> option;
  final bool checked;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    final fg = option.destructive
        ? theme.resources.systemFillColorCritical
        : option.enabled
        ? theme.resources.textFillColorPrimary
        : theme.resources.textFillColorTertiary;
    return fluent.ListTile(
      onPressed: option.enabled ? onTap : null,
      leading: option.icon == null
          ? null
          : Icon(
              option.icon,
              size: 20,
              color: option.destructive
                  ? theme.resources.systemFillColorCritical
                  : theme.accentColor.defaultBrushFor(theme.brightness),
            ),
      title: Text(option.label, style: TextStyle(fontSize: 13.5, color: fg)),
      subtitle: option.subtitle == null
          ? null
          : Text(
              option.subtitle!,
              style: TextStyle(
                fontSize: 11.5,
                color: theme.resources.textFillColorSecondary,
              ),
            ),
      trailing: checked
          ? Icon(
              fluent.FluentIcons.check_mark,
              size: 16,
              color: theme.accentColor.defaultBrushFor(theme.brightness),
            )
          : null,
    );
  }
}

/// 单选对话框：miuix 走 HyperOS 圆角列表（MiuixBasicComponent），
/// Material 走 SimpleDialog。不支持/不可选的条目显示灰字。
Future<T?> showMintChoiceDialog<T>(
  BuildContext context, {
  required bool miuix,
  required String title,
  required List<MintChoice<T>> options,
  String cancelLabel = '取消',
  bool showCheck = true,
  T? selected,
}) {
  return showDialog<T>(
    context: context,
    builder: (dialogContext) {
      if (miuix) {
        final c = MiuixTheme.of(dialogContext).colors;
        final selectedMask =
            MintThemeLibrary.instance.activeTheme?.dialogSelectedColor ??
            c.primary.withValues(alpha: 0.10);
        return Dialog(
          backgroundColor: mintDialogMaskColor(dialogContext, c.background),
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final (i, option) in options.indexed) ...[
                  if (i > 0)
                    MiuixHorizontalDivider(
                      color: c.dividerLine.withValues(alpha: 0.55),
                    ),
                  ColoredBox(
                    color: selected != null && option.value == selected
                        ? selectedMask
                        : Colors.transparent,
                    child: MiuixBasicComponent(
                      title: option.label,
                      summary: option.subtitle,
                      startAction: option.icon == null
                          ? null
                          : Icon(
                              option.icon,
                              size: 22,
                              color: option.destructive ? c.error : c.primary,
                            ),
                      endActions:
                          showCheck &&
                              option.enabled &&
                              (selected == null || option.value == selected)
                          ? [Icon(Icons.check, size: 20, color: c.primary)]
                          : null,
                      enabled: option.enabled,
                      insideMargin: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      onClick: option.enabled
                          ? () => Navigator.pop(dialogContext, option.value)
                          : null,
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: MiuixButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(cancelLabel),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      if (!miuix && mintFluentOf(context)) {
        return MintStyleDialogShell(
          miuix: false,
          title: title,
          children: [
            for (final option in options)
              _FluentChoiceRow(
                option: option,
                checked:
                    showCheck &&
                    option.enabled &&
                    (selected == null || option.value == selected),
                isCurrent: option.value == selected,
                onTap: () => Navigator.pop(dialogContext, option.value),
              ),
          ],
          maxWidth: 440,
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(dialogContext),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(cancelLabel),
              ),
            ),
          ],
        );
      }
      return SimpleDialog(
        title: Text(title),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: option.enabled
                  ? () => Navigator.pop(dialogContext, option.value)
                  : null,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: option.enabled,
                leading: option.icon == null ? null : Icon(option.icon),
                iconColor: option.destructive
                    ? Theme.of(dialogContext).colorScheme.error
                    : null,
                title: Text(option.label),
                subtitle: option.subtitle == null
                    ? null
                    : Text(option.subtitle!),
                trailing: showCheck && option.value == selected
                    ? const Icon(Icons.check)
                    : null,
              ),
            ),
        ],
      );
    },
  );
}

/// 手机端底部动作单（FCL / M3E 的「操作菜单」形态）。
///
/// 和居中单选对话框的区别只在壳：内容仍是一组 [MintChoice]，从底部整块
/// 滑上来，带一点点弹簧回弹。动效不是系统 BottomSheet 的 easeOutCubic ——
/// 用 [MiuixNavSettleCurve] 把一条欠阻尼弹簧烘焙成缓动，起速快、尾巴缓，
/// 视觉上就是 Compose expressive 那种「非线性」的手感。
Future<T?> showMintActionSheet<T>(
  BuildContext context, {
  required bool miuix,
  required String title,
  required List<MintChoice<T>> options,
  String cancelLabel = '取消',
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.38),
    transitionDuration: const Duration(milliseconds: 380),
    pageBuilder: (dialogContext, _, __) => _MintActionSheet<T>(
      miuix: miuix,
      title: title,
      options: options,
      cancelLabel: cancelLabel,
    ),
    transitionBuilder: (dialogContext, animation, secondary, child) {
      // 面板本体用弹簧停靠曲线滑上来；缩放层再叠一条更欠阻尼的弹簧，
      // 让卡片顶端先「弹」一下再落位 —— 但不让位移过冲，避免底边露缝。
      final slide = CurvedAnimation(
        parent: animation,
        curve: MiuixNavSettleCurve(response: 0.72, damping: 0.95),
        reverseCurve: Curves.easeInCubic,
      );
      final pop = CurvedAnimation(
        parent: animation,
        curve: MiuixNavSettleCurve(response: 0.58, damping: 0.78),
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(slide),
        child: FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            alignment: Alignment.bottomCenter,
            scale: Tween<double>(begin: 0.94, end: 1.0).animate(pop),
            child: child,
          ),
        ),
      );
    },
  );
}

class _MintActionSheet<T> extends StatelessWidget {
  const _MintActionSheet({
    required this.miuix,
    required this.title,
    required this.options,
    required this.cancelLabel,
  });

  final bool miuix;
  final String title;
  final List<MintChoice<T>> options;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final miuixColors = miuix ? MiuixTheme.of(context).colors : null;
    final bg = miuixColors?.background ?? cs.surfaceContainerLow;
    final line =
        miuixColors?.dividerLine ?? cs.outlineVariant.withValues(alpha: 0.4);
    final dragColor =
        miuixColors?.onSurfaceVariantSummary ?? cs.onSurfaceVariant;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.72;

    // 弹窗声明的背景（MIUI 主题的底部菜单底色是透明的，透出来的就是应用
    // 声明的窗口背景 —— 预览器也可以把任意一张图指定给「底部弹窗」）。
    // 三套风格共用这张图；没有声明时保持原来的实色底。
    final sheetBg = mintSheetBackgroundPathOf(context);
    final content = sheetBg == null
        ? _sheetBody(context, bg, line, dragColor, maxHeight)
        : ClipRRect(
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(28),
              bottom: Radius.circular(wide ? 28 : 0),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 背景图整张铺（BoxFit.cover，角色立绘通常在底部，贴底对齐）。
                ColoredBox(color: bg),
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.92,
                    child: Image.file(
                      File(resolveDisplayImage(sheetBg)),
                      fit: BoxFit.cover,
                      alignment: Alignment.bottomCenter,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                // 顶部一道同色渐变，把手柄 / 标题压出可读性；底部保持原图。
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0, 0.34, 1],
                          colors: [
                            bg.withValues(alpha: 0.88),
                            bg.withValues(alpha: 0.45),
                            bg.withValues(alpha: 0.08),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                _sheetBody(
                  context,
                  Colors.transparent,
                  line,
                  dragColor,
                  maxHeight,
                ),
              ],
            ),
          );

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          wide ? 24 : 0,
          0,
          wide ? 24 : 0,
          wide ? 18 : 0,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
          child: Material(
            color: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(28),
                bottom: Radius.circular(wide ? 28 : 0),
              ),
            ),
            child: SafeArea(top: false, child: content),
          ),
        ),
      ),
    );
  }

  Widget _sheetBody(
    BuildContext context,
    Color bg,
    Color line,
    Color dragColor,
    double maxHeight,
  ) {
    final cs = Theme.of(context).colorScheme;
    final miuixColors = miuix ? MiuixTheme.of(context).colors : null;
    return Container(
      color: bg,
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: Center(
              child: Container(
                width: 34,
                height: 4,
                decoration: BoxDecoration(
                  color: dragColor.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: miuixColors?.onBackground ?? cs.onSurface,
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, option) in options.indexed) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        indent: 22,
                        endIndent: 22,
                        color: line.withValues(alpha: 0.45),
                      ),
                    _MintActionSheetRow<T>(
                      miuix: miuix,
                      option: option,
                      onTap: () => Navigator.of(context).pop(option.value),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Divider(height: 1, color: line.withValues(alpha: 0.45)),
          InkWell(
            onTap: () => Navigator.of(context).pop(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                cancelLabel,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: miuixColors?.primary ?? cs.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MintActionSheetRow<T> extends StatelessWidget {
  const _MintActionSheetRow({
    required this.miuix,
    required this.option,
    required this.onTap,
  });

  final bool miuix;
  final MintChoice<T> option;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final miuixColors = miuix ? MiuixTheme.of(context).colors : null;
    final fg = !option.enabled
        ? (miuixColors?.onSurfaceVariantSummary ?? cs.onSurfaceVariant)
              .withValues(alpha: 0.55)
        : option.destructive
        ? (miuixColors?.error ?? cs.error)
        : (miuixColors?.onBackground ?? cs.onSurface);
    final iconColor = option.destructive
        ? (miuixColors?.error ?? cs.error)
        : !option.enabled
        ? fg
        : (miuixColors?.primary ?? cs.primary);

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(22, 13, 22, 13),
      child: Row(
        children: [
          if (option.icon != null) ...[
            Icon(option.icon, size: 21, color: iconColor),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  option.label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
                if (option.subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    option.subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      color:
                          miuixColors?.onSurfaceVariantSummary ??
                          cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    if (!option.enabled) return Opacity(opacity: 0.7, child: content);
    if (miuix) {
      return MiuixBasicComponent(
        insideMargin: EdgeInsets.zero,
        onClick: onTap,
        content: [content],
      );
    }
    return InkWell(onTap: onTap, child: content);
  }
}

/// 单行输入对话框（重命名/复制版本等）。controller 由对话框自身持有并释放。
Future<String?> showMintTextDialog(
  BuildContext context, {
  required bool miuix,
  required String title,
  required String initial,
  String hint = '',
  String cancelLabel = '取消',
  String confirmLabel = '确定',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _MintTextDialog(
      miuix: miuix,
      title: title,
      initial: initial,
      hint: hint,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
    ),
  );
}

class _MintTextDialog extends StatefulWidget {
  const _MintTextDialog({
    required this.miuix,
    required this.title,
    required this.initial,
    required this.hint,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  final bool miuix;
  final String title;
  final String initial;
  final String hint;
  final String cancelLabel;
  final String confirmLabel;

  @override
  State<_MintTextDialog> createState() => _MintTextDialogState();
}

class _MintTextDialogState extends State<_MintTextDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    if (mintMiuixOf(context, widget.miuix)) {
      final c = MiuixTheme.of(context).colors;
      return Dialog(
        backgroundColor: mintDialogMaskColor(context, c.background),
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              MiuixTextField(
                controller: _controller,
                label: widget.hint.isEmpty ? widget.title : widget.hint,
                useLabelAsPlaceholder: true,
                singleLine: true,
                autofocus: true,
                insideMargin: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MiuixButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(widget.cancelLabel),
                  ),
                  const SizedBox(width: 8),
                  MiuixButton(
                    onPressed: _submit,
                    colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                    child: Text(widget.confirmLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (!mintMiuixOf(context, widget.miuix) && mintFluentOf(context)) {
      return MintStyleDialogShell(
        miuix: false,
        title: widget.title,
        actions: mintDialogActions(
          context,
          miuix: false,
          onCancel: () => Navigator.pop(context),
          onConfirm: _submit,
          confirmLabel: widget.confirmLabel,
        ),
        children: [
          fluent.TextBox(
            controller: _controller,
            placeholder: widget.hint,
            autofocus: true,
            onSubmitted: (_) => _submit(),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// 崩溃 / 错误分析结果对话框（PCL2 日志分析同思路）。
/// [analysis] 为 null 表示没有匹配到已知模式 —— 照实说，不硬编。
Future<void> showCrashAnalysisDialog(
  BuildContext context, {
  required bool miuix,
  required CrashAnalysis? analysis,
  String? fileName,
}) {
  final body = analysis == null
      ? '没有匹配到已知的错误模式。\n'
            '把日志完整复制下来发给懂行的人，或到社区求助会更快。'
      : '${analysis.cause}\n\n${analysis.suggestion}'
            '${(analysis.evidence?.isNotEmpty ?? false) ? '\n\n命中：${analysis.evidence}' : ''}';
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      if (miuix) {
        final c = MiuixTheme.of(dialogContext).colors;
        return Dialog(
          backgroundColor: mintDialogMaskColor(dialogContext, c.background),
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  analysis == null ? '分析结果' : '分析结果：可能的原因',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (fileName != null && fileName.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    fileName,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: c.onSurfaceVariantSummary,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: c.onSurface,
                  ),
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: MiuixButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    colors: MiuixButtonDefaults.buttonColorsPrimary(
                      dialogContext,
                    ),
                    child: const Text('知道了'),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return AlertDialog(
        title: Text(analysis == null ? '分析结果' : '分析结果：可能的原因'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (fileName != null && fileName.isNotEmpty)
                Text(
                  fileName,
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              const SizedBox(height: 8),
              Text(body),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}

/// 预设色板选色对话框（experiment 不引 flutter_colorpicker，色板就够用）。
Future<Color?> showColorPickerDialog(BuildContext context, Color current) {
  const presets = [
    Color(0xFF4C6FFF), // Mint 默认蓝
    Color(0xFF3482FF), // HyperOS 蓝
    Color(0xFF6750A4), // M3 紫
    Color(0xFF00A884), // 翡翠绿
    Color(0xFFE25822), // 熔岩橙
    Color(0xFFD04343), // 绯红
    Color(0xFF7C4DFF), // 深紫
    Color(0xFF00BCD4), // 青
    Color(0xFFFFB300), // 琥珀
    Color(0xFF5D4037), // 咖啡
    Color(0xFF607D8B), // 蓝灰
    Color(0xFF3F51B5), // 靛蓝
  ];
  return showDialog<Color>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('主题种子色'),
      content: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final color in presets)
            InkWell(
              onTap: () => Navigator.of(context).pop(color),
              borderRadius: BorderRadius.circular(24),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: current.toARGB32() == color.toARGB32()
                      ? Border.all(
                          width: 3,
                          color: Theme.of(context).colorScheme.onSurface,
                        )
                      : null,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

/// 旧名字兼容（设置页等仍在用）。后续页面统一走 [MintCard]/[MintTile]。
typedef GroupCard = MintCard;
typedef TileRow = MintTile;
typedef SwitchRow = MintSwitchTile;

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mint/services/theme_package.dart';
import 'package:mint/services/volume_bar_service.dart';

/// 应用内音量条：HyperOS 的竖柱样式（42dp 宽、圆角胶囊、下方一个图标圆钮），
/// 配色与图标取主题在 `miui.systemui.plugin` 里声明的 `miui_volume_*` /
/// `ic_miui_volume_*`；主题没声明的项回落到当前风格的 primary。
///
/// 只在设置里开了「主题音量条」且套用了主题时挂出来（见 app.dart），
/// 事件源是 [MintVolumeBar.current]，原生广播到点后 1.5s 自动收起。
class ThemeVolumeBar extends StatefulWidget {
  const ThemeVolumeBar({super.key, this.margin = const EdgeInsets.only(left: 16)});

  final EdgeInsets margin;

  @override
  State<ThemeVolumeBar> createState() => _ThemeVolumeBarState();
}

class _ThemeVolumeBarState extends State<ThemeVolumeBar> {
  MintVolumeState? _last;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    MintVolumeBar.current.addListener(_sync);
  }

  @override
  void dispose() {
    MintVolumeBar.current.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final state = MintVolumeBar.current.value;
    if (!mounted) return;
    setState(() {
      if (state != null) _last = state;
      _shown = state != null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = _last;
    if (state == null || state.max <= 0) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final theme = MintThemeLibrary.instance.activeTheme;
    final track =
        theme?.volumeTrackColor ??
        scheme.onSurface.withValues(alpha: dark ? 0.24 : 0.12);
    final accent = theme?.volumeAccentColor ?? scheme.primary;
    final buttonBg = theme?.volumeExpandColor ?? track;
    final buttonFg = theme?.volumeButtonColor ??
        (dark ? Colors.white : scheme.onSurface);
    final iconPath = state.muted ? theme?.volumeIconMuted : theme?.volumeIcon;
    final hasIcon =
        iconPath != null && iconPath.isNotEmpty && File(iconPath).existsSync();
    final height = theme?.volumeColumnHeight ?? 165.0;

    return IgnorePointer(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: widget.margin,
          child: AnimatedOpacity(
            opacity: _shown ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: AnimatedScale(
              scale: _shown ? 1 : 0.92,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 42,
                    height: height,
                    decoration: BoxDecoration(
                      color: track,
                      borderRadius: BorderRadius.circular(21),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.16),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: state.ratio,
                              child: ColoredBox(color: accent),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: buttonBg,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: hasIcon
                        ? Image.file(
                            File(iconPath),
                            width: 24,
                            height: 24,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => _fallbackIcon(
                              state,
                              buttonFg,
                            ),
                          )
                        : _fallbackIcon(state, buttonFg),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallbackIcon(MintVolumeState state, Color color) => Icon(
    state.muted
        ? Icons.volume_off
        : (state.isMedia ? Icons.volume_up : Icons.ring_volume),
    size: 22,
    color: color,
  );
}

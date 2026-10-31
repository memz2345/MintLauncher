import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/services/launcher/android_display.dart';

import 'common.dart';
import '../widgets/mint_page.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/widgets/mint_refresh.dart';

/// Android 专属：游戏窗口 + 渲染分辨率（FCL「窗口缩放 / 强制分辨率」的现代版）。
///
/// 上半张卡是**可以拖的**：拖画面右下角的角标就像拖窗口一样改大小，拉小之后
/// 周围是黑边（正常现象，画面永远等比缩放不变形）。窗口大小即时生效；
/// 渲染分辨率改的是 GL 缓冲实际像素，运行中通过 FCL 的 framebuffer-size
/// 事件下发，下一次启动由 `--width/--height` 保持同一尺寸。
class AndroidDisplayPage extends StatefulWidget {
  const AndroidDisplayPage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<AndroidDisplayPage> createState() => _AndroidDisplayPageState();
}

class _AndroidDisplayPageState extends State<AndroidDisplayPage> {
  AndroidDisplaySettings? _settings;

  @override
  void initState() {
    super.initState();
    AndroidDisplay.load(force: true).then((value) {
      if (mounted) setState(() => _settings = value);
    });
  }

  /// 拖动中的预览：只改内存里的值，落盘等松手。
  void _preview(AndroidDisplaySettings next) {
    setState(() => _settings = next);
  }

  Future<void> _commit(AndroidDisplaySettings next) async {
    setState(() => _settings = next);
    await AndroidDisplay.save(next);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final cs = Theme.of(context).colorScheme;
    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '游戏窗口',
      showBack: true,
      body: (padding) {
        if (settings == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          physics: kMintPageScrollPhysics,
          padding: padding + const EdgeInsets.fromLTRB(16, 4, 16, 36),
          children: [
            _WindowPreviewCard(settings: settings, onChanged: _commit),
            MintSectionHeader(miuix: mintMiuixOf(context), title: '窗口大小'),
            MintCard(
              miuix: mintMiuixOf(context),
              children: [
                _SliderTile(
                  miuix: mintMiuixOf(context),
                  label: '横向大小',
                  valueText: '${(settings.windowWidth * 100).round()}%',
                  value: settings.windowWidth,
                  onChanged: (v) => _preview(
                    AndroidDisplaySettings.fromWindow(
                      windowWidth: v,
                      windowHeight: settings.windowHeight,
                      screenAspect: settings.screenAspect,
                      screenWidth: settings.screenWidth,
                      screenHeight: settings.screenHeight,
                      resolutionScale: settings.resolutionScale,
                    ),
                  ),
                  onCommitted: (v) => _commit(
                    AndroidDisplaySettings.fromWindow(
                      windowWidth: v,
                      windowHeight: settings.windowHeight,
                      screenAspect: settings.screenAspect,
                      screenWidth: settings.screenWidth,
                      screenHeight: settings.screenHeight,
                      resolutionScale: settings.resolutionScale,
                    ),
                  ),
                ),
                _SliderTile(
                  miuix: mintMiuixOf(context),
                  label: '纵向大小',
                  valueText: '${(settings.windowHeight * 100).round()}%',
                  value: settings.windowHeight,
                  onChanged: (v) => _preview(
                    AndroidDisplaySettings.fromWindow(
                      windowWidth: settings.windowWidth,
                      windowHeight: v,
                      screenAspect: settings.screenAspect,
                      screenWidth: settings.screenWidth,
                      screenHeight: settings.screenHeight,
                      resolutionScale: settings.resolutionScale,
                    ),
                  ),
                  onCommitted: (v) => _commit(
                    AndroidDisplaySettings.fromWindow(
                      windowWidth: settings.windowWidth,
                      windowHeight: v,
                      screenAspect: settings.screenAspect,
                      screenWidth: settings.screenWidth,
                      screenHeight: settings.screenHeight,
                      resolutionScale: settings.resolutionScale,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in AndroidDisplaySettings.windowPresets)
                  _PresetPill(
                    miuix: mintMiuixOf(context),
                    label: preset.label,
                    selected:
                        (settings.windowWidth - preset.value).abs() < 0.01 &&
                        (settings.windowHeight - preset.value).abs() < 0.01,
                    onTap: () => _commit(
                      AndroidDisplaySettings.fromWindow(
                        windowWidth: preset.value,
                        windowHeight: preset.value,
                        screenAspect: settings.screenAspect,
                        screenWidth: settings.screenWidth,
                        screenHeight: settings.screenHeight,
                        resolutionScale: settings.resolutionScale,
                      ),
                    ),
                  ),
              ],
            ),
            MintSectionHeader(miuix: mintMiuixOf(context), title: '渲染精度'),
            MintCard(
              miuix: mintMiuixOf(context),
              children: [
                MintTile(
                  miuix: mintMiuixOf(context),
                  icon: Icons.memory_outlined,
                  title: '${settings.scaleLabel} · ${settings.resolutionLabel}',
                  subtitle:
                      '100% = 屏幕原生 ${settings.nativeResolutionLabel}；'
                      '掉帧时先降到 75% 或 50%，画面比例不变，只是变糊一点',
                  showDivider: false,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in AndroidDisplaySettings.scalePresets)
                  _PresetPill(
                    miuix: mintMiuixOf(context),
                    label: preset.label,
                    selected:
                        (settings.resolutionScale - preset.value).abs() < 0.01,
                    onTap: () => _commit(
                      settings.copyWith(resolutionScale: preset.value),
                    ),
                  ),
              ],
            ),
            MintSectionHeader(miuix: mintMiuixOf(context), title: '显示方式'),
            MintSegmentedTabs(
              miuix: mintMiuixOf(context),
              tabs: [for (final mode in AndroidAspectMode.values) mode.label],
              selected: settings.mode.index,
              onSelected: (index) {
                final mode = AndroidAspectMode.values[index];
                _commit(settings.copyWith(mode: mode));
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(
                settings.mode.description,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.45,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            if (settings.mode == AndroidAspectMode.custom) ...[
              MintSectionHeader(miuix: mintMiuixOf(context), title: '横向比例'),
              MintCard(
                miuix: mintMiuixOf(context),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '画面宽度 : 高度',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            Text(
                              AndroidDisplaySettings.ratioLabel(settings.ratio),
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: cs.primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        if (mintMiuixOf(context, widget.miuix))
                          MiuixSlider(
                            value: settings.ratio,
                            min: AndroidDisplaySettings.minRatio,
                            max: AndroidDisplaySettings.maxRatio,
                            height: 34,
                            onValueChanged: (v) =>
                                _preview(settings.copyWith(ratio: v)),
                            onValueChangeFinished: () =>
                                _commit(_settings ?? settings),
                          )
                        else
                          Slider(
                            value: settings.ratio.clamp(
                              AndroidDisplaySettings.minRatio,
                              AndroidDisplaySettings.maxRatio,
                            ),
                            min: AndroidDisplaySettings.minRatio,
                            max: AndroidDisplaySettings.maxRatio,
                            label: AndroidDisplaySettings.ratioLabel(
                              settings.ratio,
                            ),
                            onChanged: (v) =>
                                _preview(settings.copyWith(ratio: v)),
                            onChangeEnd: (v) =>
                                _commit(settings.copyWith(ratio: v)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in AndroidDisplaySettings.presets)
                    _PresetPill(
                      miuix: mintMiuixOf(context),
                      label: preset.label,
                      selected: (settings.ratio - preset.ratio).abs() < 0.015,
                      onTap: () => _commit(
                        settings.copyWith(
                          mode: AndroidAspectMode.custom,
                          ratio: preset.ratio,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            MintSectionHeader(miuix: mintMiuixOf(context), title: '渲染分辨率'),
            MintCard(
              miuix: mintMiuixOf(context),
              children: [
                MintTile(
                  miuix: mintMiuixOf(context),
                  icon: Icons.photo_size_select_large_outlined,
                  title: settings.resolutionLabel,
                  subtitle:
                      '高度 = 屏幕原生 ${settings.screenHeight} × ${settings.scaleLabel}，'
                      '宽度按目标比例变化 —— 游戏画面等比缩放，不拉伸；运行中改即时生效',
                  showDivider: false,
                ),
              ],
            ),
            MintSectionHeader(miuix: mintMiuixOf(context), title: '说明'),
            MintCard(
              miuix: mintMiuixOf(context),
              children: [
                MintTile(
                  miuix: mintMiuixOf(context),
                  icon: Icons.sports_esports_outlined,
                  title: '窗口大小即时生效',
                  subtitle: '拉小后画面四周是黑边（正常），按键层跟着一起缩',
                ),
                MintTile(
                  miuix: mintMiuixOf(context),
                  icon: Icons.restart_alt,
                  title: '游戏内也能调',
                  subtitle: '悬浮球 → 功能 → 游戏窗口，拖角标改的是同一份设置',
                ),
                MintTile(
                  miuix: mintMiuixOf(context),
                  icon: Icons.speed_outlined,
                  title: '掉帧先查这两项',
                  subtitle:
                      '渲染器换 NG GL4ES（多数机型更快）；精度降到 75%。'
                      '原生 100% 就是屏幕全像素，发热和掉帧会明显一些',
                  showDivider: false,
                  onTap: null,
                ),
              ],
            ),
            const SizedBox(height: 12),
            MintCard(
              miuix: mintMiuixOf(context),
              children: [
                MintTile(
                  miuix: mintMiuixOf(context),
                  icon: Icons.fit_screen_outlined,
                  title: '恢复默认',
                  subtitle: '全屏 16:9 · 屏幕原生 100%，两侧留黑边',
                  showDivider: false,
                  onTap: () => _commit(
                    const AndroidDisplaySettings(
                      mode: AndroidAspectMode.fit,
                      ratio: 16 / 9,
                    ).copyWith(
                      screenAspect: settings.screenAspect,
                      screenWidth: settings.screenWidth,
                      screenHeight: settings.screenHeight,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _PresetPill extends StatelessWidget {
  const _PresetPill({
    required this.miuix,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final bool miuix;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      return MiuixButton(
        onPressed: onTap,
        minHeight: 36,
        insideMargin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        colors: selected
            ? MiuixButtonDefaults.buttonColorsPrimary(context)
            : null,
        child: Text(label),
      );
    }
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

/// 一条带标签的滑杆行（横向 / 纵向大小共用）。
class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.miuix,
    required this.label,
    required this.valueText,
    required this.value,
    required this.onChanged,
    required this.onCommitted,
  });

  final bool miuix;
  final String label;
  final String valueText;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommitted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                valueText,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          if (miuix)
            MiuixSlider(
              value: value,
              min: AndroidDisplaySettings.minWindow,
              max: AndroidDisplaySettings.maxWindow,
              height: 34,
              onValueChanged: onChanged,
              onValueChangeFinished: () => onCommitted(value),
            )
          else
            Slider(
              value: value.clamp(
                AndroidDisplaySettings.minWindow,
                AndroidDisplaySettings.maxWindow,
              ),
              min: AndroidDisplaySettings.minWindow,
              max: AndroidDisplaySettings.maxWindow,
              label: valueText,
              onChanged: onChanged,
              onChangeEnd: onCommitted,
            ),
        ],
      ),
    );
  }
}

/// 屏幕里嵌一块可按拖拽的「游戏画面」：拖右下角角标 = 改窗口大小。
class _WindowPreviewCard extends StatelessWidget {
  const _WindowPreviewCard({required this.settings, required this.onChanged});

  final AndroidDisplaySettings settings;
  final ValueChanged<AndroidDisplaySettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 236,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '拖右下角改窗口大小',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '${settings.windowLabel} · ${settings.resolutionLabel}',
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 屏幕框按真机横屏比例画（原生回传的 screenAspect）。
                final screenAspect =
                    settings.screenAspect.isFinite && settings.screenAspect > 0
                    ? settings.screenAspect
                    : 2.0;
                var screenW = constraints.maxWidth;
                var screenH = screenW / screenAspect;
                if (screenH > constraints.maxHeight) {
                  screenH = constraints.maxHeight;
                  screenW = screenH * screenAspect;
                }
                final gameW = math.max(24.0, screenW * settings.windowWidth);
                final gameH = math.max(24.0, screenH * settings.windowHeight);
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: screenW,
                    height: screenH,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.16),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: gameW,
                          height: gameH,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0xFF2C5E36),
                                        Color(0xFF15331D),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.4,
                                      ),
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      'Minecraft',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white.withValues(
                                          alpha: 0.82,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // 角标：拖动即改窗口比例。
                              Positioned(
                                right: -6,
                                bottom: -6,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanUpdate: (drag) {
                                    final dw = drag.delta.dx / screenW;
                                    final dh = drag.delta.dy / screenH;
                                    onChanged(
                                      AndroidDisplaySettings.fromWindow(
                                        windowWidth: settings.windowWidth + dw,
                                        windowHeight:
                                            settings.windowHeight + dh,
                                        screenAspect: screenAspect,
                                        screenWidth: settings.screenWidth,
                                        screenHeight: settings.screenHeight,
                                        resolutionScale:
                                            settings.resolutionScale,
                                      ),
                                    );
                                  },
                                  child: Container(
                                    width: 26,
                                    height: 26,
                                    decoration: BoxDecoration(
                                      color: cs.primary,
                                      borderRadius: BorderRadius.circular(9),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.7,
                                        ),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.drag_handle,
                                      size: 15,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

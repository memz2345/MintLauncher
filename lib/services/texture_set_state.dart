import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/widgets/bg_effect_background.dart';

/// 一个混合模式预设：名字 + 一组叠在模糊背景上的颜色层。
/// 对应 local2api / InstallerX 的 ColorBlendToken。
class BlendModePreset {
  const BlendModePreset(this.label, this.entries);

  final String label;
  final List<BlendColorEntry> Function(bool dark) entries;
}

final List<BlendModePreset> blendModePresets = [
  BlendModePreset(
    '默认',
    (dark) => dark
        ? const [BlendColorEntry(Color(0x99000000), BlurBlendMode.srcOver)]
        : const [BlendColorEntry(Color(0x8CFFFFFF), BlurBlendMode.srcOver)],
  ),
  BlendModePreset(
    '叠加',
    (dark) => [
      BlendColorEntry(
        dark ? const Color(0x33FFFFFF) : const Color(0x26FFFFFF),
        BlurBlendMode.overlay,
      ),
    ],
  ),
  BlendModePreset(
    '滤色',
    (_) => const [BlendColorEntry(Color(0x2E808080), BlurBlendMode.screen)],
  ),
  BlendModePreset(
    '正片叠底',
    (dark) => [
      BlendColorEntry(
        dark ? const Color(0x40404080) : const Color(0x26C0C0C0),
        BlurBlendMode.multiply,
      ),
    ],
  ),
  BlendModePreset(
    '线性减淡',
    (_) => const [BlendColorEntry(Color(0x1FFFFFFF), BlurBlendMode.plus)],
  ),
  BlendModePreset(
    '线性加深',
    (_) => const [BlendColorEntry(Color(0x66000000), BlurBlendMode.darken)],
  ),
  BlendModePreset(
    '柔光',
    (_) => const [BlendColorEntry(Color(0x29FFFFFF), BlurBlendMode.softLight)],
  ),
  BlendModePreset(
    '差值',
    (_) => const [BlendColorEntry(Color(0x33FFFFFF), BlurBlendMode.difference)],
  ),
];

/// 关于页「高级设置 / 纹理集」的全部参数。
class TextureSetState extends ChangeNotifier {
  TextureSetState({required bool defaultBlur}) : blurEnable = defaultBlur;

  /// 从 [SettingsService.textureSettings] 还原（缺键用默认值；`blurEnable`
  /// 缺省时跟随显示设置里的「模糊」总开关）。
  factory TextureSetState.fromMap(
    Map<String, Object?> map, {
    required bool defaultBlur,
  }) {
    final state = TextureSetState(defaultBlur: defaultBlur);
    Object? raw(String key) => map[key];
    bool flag(String key, bool fallback) => raw(key) as bool? ?? fallback;
    double decimal(String key, double fallback) =>
        (raw(key) as num?)?.toDouble() ?? fallback;
    state.variant = raw('variant') == 'os2'
        ? BgEffectVariant.os2
        : BgEffectVariant.os3;
    state.effectBg = flag('effectBg', true);
    state.dynamicBg = flag('dynamicBg', true);
    state.blurEnable = flag('blurEnable', defaultBlur);
    state.blurRadius = decimal('blurRadius', 60);
    state.noise = decimal('noise', kOs3PhoneLight.saturateOffset);
    state.brightness = decimal('brightness', 0);
    state.contrast = decimal('contrast', 1);
    state.saturation = decimal('saturation', 1);
    state.blendIndex = (raw('blendIndex') as num?)?.toInt() ?? 0;
    return state;
  }

  /// 存进 launcher_config（字段名与 [TextureSetState.fromMap] 一一对应）。
  Map<String, Object?> toMap() => {
    'variant': variant == BgEffectVariant.os2 ? 'os2' : 'os3',
    'effectBg': effectBg,
    'dynamicBg': dynamicBg,
    'blurEnable': blurEnable,
    'blurRadius': blurRadius,
    'noise': noise,
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'blendIndex': blendIndex,
  };

  BgEffectVariant variant = BgEffectVariant.os3;
  bool effectBg = true;
  bool dynamicBg = true;
  bool blurEnable;

  double blurRadius = 60;

  /// 噪点：驱动背景着色器的噪声去饱和强度（默认取 OS3 浅色预设）。
  double noise = kOs3PhoneLight.saturateOffset;
  double brightness = 0;
  double contrast = 1;
  double saturation = 1;
  int blendIndex = 0;

  BgEffectPreset get preset => switch (variant) {
    BgEffectVariant.os2 => kOs2PhoneLight,
    BgEffectVariant.os3 => kOs3PhoneLight,
  };

  BlendModePreset get blendPreset =>
      blendModePresets[blendIndex % blendModePresets.length];

  BlurColors blurColors(bool dark) => BlurColors(
    blendColors: blendPreset.entries(dark),
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
  );

  void setVariant(BgEffectVariant v) {
    variant = v;
    noise = preset.saturateOffset;
    notifyListeners();
  }

  void set(void Function(TextureSetState) mutate) {
    mutate(this);
    notifyListeners();
  }

  void reset(bool defaultBlur) {
    variant = BgEffectVariant.os3;
    effectBg = true;
    dynamicBg = true;
    blurEnable = defaultBlur;
    blurRadius = 60;
    noise = kOs3PhoneLight.saturateOffset;
    brightness = 0;
    contrast = 1;
    saturation = 1;
    blendIndex = 0;
    notifyListeners();
  }
}

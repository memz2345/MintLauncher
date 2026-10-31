import 'dart:io';

import 'package:flutter/services.dart';

/// Android 13+ per-app language 桥。
///
/// - `getAppLocales`：读系统为本应用设置的语言列表（用户在
///   系统设置 → 应用 → Mint → 语言 里选的）
/// - `setAppLocale`：把 App 内选择写回系统（LocaleManager，
///   Android 13+），低版本走 Flutter 内部覆盖即可。
class AppLocaleBridge {
  static const MethodChannel _channel = MethodChannel('dev.mint.mint/locale');

  /// 返回系统 per-app locale 的首个 BCP-47 语言标签原文（如 'zh-CN'，有的
  /// OEM / 规范化路径会给 'zh-Hans-CN'）；无则 null。**别直接拿来跟应用内
  /// 规范码比对** —— 先过 [AppSettings.normalizeLocaleCode] 归一化。
  static Future<String?> getSystemAppLocale() async {
    if (!Platform.isAndroid) return null;
    try {
      final list = await _channel.invokeMethod<List<dynamic>>('getAppLocales');
      if (list == null || list.isEmpty) return null;
      return list.first as String?;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 把 App 内选择写回系统（Android 13+），tag 为空表示恢复跟随系统。
  ///
  /// 传入的是**应用内规范码**（'zh-CN' / 'zh-TW' / 'en-US'），写回系统前映射
  /// 成规范的 BCP-47 tag —— 中文要带 script（zh-Hans-CN / zh-Hant-TW），跟
  /// locales_config.xml 里声明的 canonical 形式一致：有的 OEM 会拿写入的
  /// tag 与声明清单做字符串比对，对不上就静默丢弃（症状是只有 English
  /// 能生效 —— en 没有 likely script，规范化后形式不变）。
  static Future<void> setSystemAppLocale(String? tag) async {
    if (!Platform.isAndroid) return;
    // 应用内「跟随系统」（null）→ 写空 tag，原生侧会清掉系统里的 per-app
    // 覆盖（恢复跟随系统）；其余映射成规范 BCP-47 tag 再写。
    try {
      await _channel.invokeMethod('setAppLocale', {'tag': _systemTagFor(tag)});
    } on PlatformException {
      // API < 33 或通道异常：忽略，仅 App 内生效
    } on MissingPluginException {
      // 同上
    }
  }

  /// 应用内规范码 → 写回系统用的 BCP-47 tag。null 表示「跟随系统」，
  /// 原生侧拿到空 tag 会清掉 per-app 覆盖。
  static String? _systemTagFor(String? code) => switch (code) {
    null || '' => null,
    'zh-CN' => 'zh-Hans-CN',
    'zh-TW' => 'zh-Hant-TW',
    _ => code,
  };
}

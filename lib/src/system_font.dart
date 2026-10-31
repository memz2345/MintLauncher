import 'dart:io';

/// 各平台的系统 CJK/UI 字体。Flutter Windows 默认 Segoe UI 没有中文字形，
/// 引擎回退会落到很怪的字体（字距/基线都不对），必须显式指定系统字体。
final String kSystemFontFamily = Platform.isWindows
    ? 'Microsoft YaHei UI'
    : Platform.isMacOS
    ? 'PingFang SC'
    : 'Noto Sans CJK SC';

/// 等宽字体（日志用），中文回退到系统字体。
final List<String> kMonoFontFallback = [
  'Consolas',
  'Menlo',
  'monospace',
  kSystemFontFamily,
];

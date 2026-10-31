/// Mojang 版本 JSON 的结构化参数（1.13+ 的 `arguments.jvm` / `arguments.game`）
/// 展开器：规则求值 + `${}` 变量替换，桌面与 Android 共用同一套判定。
library;

import 'dart:io';

/// 规则求值所在的环境。
///
/// [osName] 用 Mojang 清单里的写法（`windows` / `osx` / `linux`）—— Android 跑
/// 的是 Linux 内核，而且启动时会给游戏 `-Dos.name=Linux`，所以 Android 也按
/// `linux` 求值，否则所有 `os:{name:"linux"}` 的参数块都会被整段丢掉。
class ArgumentExpander {
  const ArgumentExpander({
    required this.osName,
    required this.arch,
    this.features = const {},
  });

  final String osName;
  final String arch;

  /// 特性开关（`has_custom_resolution` 等）：规则要求某个特性为 true 时，
  /// 只有这里给了 true 才展开那段参数。
  final Map<String, bool> features;

  /// 当前平台对应的 Mojang os name。
  static String osNameForCurrentPlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'osx';
    return 'linux';
  }

  /// Mojang 清单里的 arch 写法。注意规则里 "x86" 特指 **32 位**（各库用它
  /// `disallow` 掉 32 位环境），64 位机器绝不能返回 "x86"。
  static String mojangArch([String? platformVersion]) {
    final v = platformVersion ?? Platform.version;
    if (v.contains('arm64') || v.contains('aarch64')) return 'arm64';
    if (v.contains('x64') || v.contains('x86_64') || v.contains('amd64')) {
      return 'x86_64';
    }
    return 'x86';
  }

  /// 展开 1.13+ 参数列表：字符串 / `{rules, value}`，value 可为字符串或数组。
  List<String> expand(List<dynamic> raw, Map<String, String> variables) {
    final out = <String>[];
    for (final entry in raw) {
      if (entry is String) {
        out.add(substitute(entry, variables));
        continue;
      }
      if (entry is Map) {
        final rules = entry['rules'];
        if (rules is List && !rulesAllow(rules)) continue;
        final value = entry['value'];
        if (value is String) {
          out.add(substitute(value, variables));
        } else if (value is List) {
          out.addAll([
            for (final v in value)
              if (v is String) substitute(v, variables),
          ]);
        }
      }
    }
    return out;
  }

  bool rulesAllow(List<dynamic> rules) {
    var allow = false;
    for (final rule in rules) {
      if (rule is! Map) continue;
      final os = rule['os'];
      if (os is Map) {
        final name = os['name'] as String?;
        if (name != null && name != osName) continue;
        final arch = os['arch'] as String?;
        if (arch != null && arch != this.arch) continue;
        // os.version（如 ">=10"）只影响 Windows 专属块，这里不细分。
      }
      final ruleFeatures = rule['features'];
      if (ruleFeatures is Map && ruleFeatures.isNotEmpty) {
        // 每条特性都要和当前特性集一致才适用（has_custom_resolution 一类）。
        var matches = true;
        for (final entry in ruleFeatures.entries) {
          if ((features[entry.key] ?? false) != (entry.value == true)) {
            matches = false;
            break;
          }
        }
        if (!matches) continue;
      }
      allow = (rule['action'] as String?) != 'disallow';
    }
    return allow;
  }

  static String substitute(String template, Map<String, String> variables) =>
      template.replaceAllMapped(RegExp(r'\$\{([^}]+)\}'), (m) {
        final key = m.group(1)!;
        return variables[key] ?? m.group(0)!;
      });
}

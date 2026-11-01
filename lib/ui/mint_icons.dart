import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/src/enums.dart';
import 'package:mint/ui/widgets/top_bar_tone.dart' show MintTopBarToneScope;

/// 全局「当前界面风格」。
///
/// 叶子页面拿不到壳的配置（`miuix` 只是个 bool，三套风格塞不进去），
/// 而返回箭头 / 下载图标这类细节必须跟风格走。MintApp 在每次 build 时
/// 写一次，任何 widget 直接读 —— 换风格会整树重建，读到的一定是新的。
class MintUiStyle {
  const MintUiStyle._();

  static UiStyle current = UiStyle.miuix;

  static bool get isFluent => current == UiStyle.fluent;
  static bool get isMiuix => current == UiStyle.miuix;
}

/// 当前风格的**可监听**版本。
///
/// [MintUiStyle.current] 是静态变量：读它的 widget 不会向框架登记依赖，
/// 所以换风格时只有「恰好会重建」的那部分变了，已经入栈的页面还挂着
/// 推入时求值好的 `miuix` 参数 —— 就是用户看到的「改了一版」（一半新一半旧）。
/// 这个 InheritedWidget 挂在 `MaterialApp.builder` 上（Navigator 之上），
/// 页面在 build 里调 [mintStyleOf] / [mintMiuixOf] 既拿到当前值、又登记依赖，
/// 风格一变全部重绘，且不清路由栈。
class MintStyleScope extends InheritedWidget {
  const MintStyleScope({super.key, required this.style, required super.child});

  final UiStyle style;

  @override
  bool updateShouldNotify(MintStyleScope oldWidget) => oldWidget.style != style;
}

/// build 期读当前界面风格（同时登记依赖）。
UiStyle mintStyleOf(BuildContext context) {
  final scope = context.dependOnInheritedWidgetOfExactType<MintStyleScope>();
  return scope?.style ?? MintUiStyle.current;
}

/// build 期读「是不是 miuix 风格」。
///
/// [fallback] 传页面自己的 `widget.miuix`：正常在应用里永远以 InheritedWidget
/// 为准（换风格立刻重绘），只有在**没有 scope** 的场合（widget 单测直接 pump
/// 一个页面、或挂在 MaterialApp 之外的浮层）才退回构造参数。
bool mintMiuixOf(BuildContext context, [bool? fallback]) {
  final scope = context.dependOnInheritedWidgetOfExactType<MintStyleScope>();
  if (scope != null) return scope.style.isMiuix;
  return fallback ?? MintUiStyle.current.isMiuix;
}

bool mintFluentOf(BuildContext context) => mintStyleOf(context).isFluent;

/// 三套风格各自的图标：Material 字形 / FluentIcons / miuix 矢量图标。
///
/// miuix 没有「线性箭头」这类 Material 字形，改用 `MiuixIcons.extended`
/// 里对应的矢量图标（找不到时回退 Material，保证不会画空白）。
class MintIcon extends StatelessWidget {
  const MintIcon({
    super.key,
    required this.icon,
    this.fluentIcon,
    this.miuixName,
    this.size = 22,
    this.fluentSize,
    this.color,
  });

  /// Material 字形（也是找不到 miuix 图标时的回退）。
  final IconData icon;

  /// Fluent 字形；不给就用 [icon]。
  final IconData? fluentIcon;

  /// miuix 扩展图标名（小驼峰，如 `back` / `download`）。
  final String? miuixName;

  final double size;

  /// Fluent 字形的尺寸。Segoe Fluent 的箭头/符号字形留白比 Material 少，
  /// 同一个 size 看起来会大一圈，所以允许单独给一个更小的值。
  final double? fluentSize;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? IconTheme.of(context).color;
    switch (mintStyleOf(context)) {
      case UiStyle.fluent:
        return fluent.Icon(
          fluentIcon ?? icon,
          size: fluentSize ?? size,
          color: tint,
        );
      case UiStyle.miuix:
        final name = miuixName;
        final vector = name == null ? null : MiuixIcons.extended.byName(name);
        if (vector != null) {
          return MiuixIcon(vector: vector, size: size, tint: tint);
        }
        return Icon(icon, size: size, color: tint);
      case UiStyle.materialExpressive:
        return Icon(icon, size: size, color: tint);
    }
  }
}

/// 返回箭头：fluent 用 `chrome_back`（Win11 标题栏同款细箭头），
/// miuix 用扩展图标里的 `back`，Material 用 `arrow_back`。
class MintBackIcon extends StatelessWidget {
  const MintBackIcon({super.key, this.size = 22, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      // iOS 26 导航栏的返回键是 chevron.backward（没有横杠）；iOS 14/15
      // 的原生返回键同样是纯 chevron。原生按钮走 SF Symbol，这里兜住
      // Flutter 降级路径（旧系统 / 截图测试）。
      final tint =
          color ??
          MintTopBarToneScope.maybeOf(context) ??
          IconTheme.of(context).color ??
          Theme.of(context).colorScheme.onSurface;
      return Icon(CupertinoIcons.back, size: size, color: tint);
    }
    return MintIcon(
      icon: Icons.arrow_back,
      fluentIcon: fluent.FluentIcons.chrome_back,
      miuixName: 'back',
      size: size,
      // Win11 标题栏的返回箭头本身是 16px 的字形，给 22 会显得比标题还壮。
      fluentSize: size * 0.70,
      // 顶栏里统一用自适应黑/白（和标题、动作图标同色）；不在页面顶栏时
      // 跟随当前 IconTheme（Windows 自绘标题栏会给它自己的前景色）。
      color:
          color ??
          MintTopBarToneScope.maybeOf(context) ??
          IconTheme.of(context).color ??
          Theme.of(context).colorScheme.onSurface,
    );
  }
}

/// 下载 / 下载管理：三套风格各自的下载图标。
class MintDownloadIcon extends StatelessWidget {
  const MintDownloadIcon({super.key, this.size = 22, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return MintIcon(
      icon: Icons.download_rounded,
      fluentIcon: fluent.FluentIcons.download,
      miuixName: 'download',
      size: size,
      color: color,
    );
  }
}

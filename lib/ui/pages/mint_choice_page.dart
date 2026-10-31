import 'package:flutter/material.dart';

import 'package:mint/ui/pages/common.dart';
import 'package:mint/ui/widgets/mint_page.dart';
import 'package:mint/ui/widgets/mint_refresh.dart';

/// 设置项的单选页（共用母页）。
///
/// 设置页里原来用 `showMintChoiceDialog` 弹出的「带选项」弹窗，统一改成
/// 推入这个页面：同一套 `MintPageScaffold` + 卡片列表，只是标题与选项不同。
/// 选中一条就 pop 回值，调用方仍然 `final result = await ...`，业务代码
/// 不用改。左右两栏 / HMCL 式设置页共用同一个视觉。
Future<T?> pushMintChoicePage<T>(
  BuildContext context, {
  required bool miuix,
  required String title,
  required List<MintChoice<T>> options,
  T? selected,
  String? subtitle,
}) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      builder: (_) => MintChoicePage<T>(
        miuix: miuix,
        title: title,
        options: options,
        selected: selected,
        subtitle: subtitle,
      ),
    ),
  );
}

class MintChoicePage<T> extends StatelessWidget {
  const MintChoicePage({
    super.key,
    required this.miuix,
    required this.title,
    required this.options,
    this.selected,
    this.subtitle,
  });

  final bool miuix;
  final String title;
  final List<MintChoice<T>> options;
  final T? selected;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MintPageScaffold(
      miuix: miuix,
      title: title,
      showBack: true,
      body: (padding) => ListView(
        physics: kMintPageScrollPhysics,
        padding: padding + const EdgeInsets.fromLTRB(16, 10, 16, 32),
        children: [
          if (subtitle != null && subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          MintCard(
            miuix: miuix,
            children: [
              for (final (i, option) in options.indexed)
                MintTile(
                  miuix: miuix,
                  icon: option.icon,
                  title: option.label,
                  subtitle: option.subtitle,
                  enabled: option.enabled,
                  showDivider: i != options.length - 1,
                  trailing: option.enabled && option.value == selected
                      ? Icon(Icons.check_rounded, size: 20, color: cs.primary)
                      : null,
                  onTap: option.enabled
                      ? () => Navigator.of(context).pop(option.value)
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/account.dart';
import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/settings_service.dart';

import 'common.dart';
import '../widgets/mint_page.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/widgets/mint_refresh.dart';

/// 账户页（FCL 右侧账户入口点进来）：当前账户、账户列表、添加离线/外置账户。
class AccountsPage extends StatefulWidget {
  const AccountsPage({
    super.key,
    required this.miuix,
    required this.settings,
    required this.controller,
  });

  final bool miuix;
  final SettingsService settings;
  final LauncherController controller;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  bool _authlibMode = false;
  bool _busy = false;
  final _name = TextEditingController();
  final _server = TextEditingController(
    text: 'https://littleskin.cn/api/yggdrasil',
  );

  @override
  void dispose() {
    _name.dispose();
    _server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final selected = settings.selectedAccount;

    return MintPageScaffold(
      miuix: mintMiuixOf(context),
      title: '账户',
      showBack: true,
      body: (padding) => ListView(
        physics: kMintPageScrollPhysics,
        padding: padding + const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          MintSectionHeader(miuix: mintMiuixOf(context), title: '当前账户'),
          MintCard(
            miuix: mintMiuixOf(context),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Row(
                  children: [
                    _Avatar(name: selected?.name ?? '?', size: 56),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selected?.name ?? '未登录',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            selected == null
                                ? '添加一个账户后即可启动游戏'
                                : selected.isAuthlib
                                ? '外置登录 · ${selected.authServer}'
                                : '离线账户',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          if (settings.accounts.isNotEmpty) ...[
            MintSectionHeader(miuix: mintMiuixOf(context), title: '全部账户'),
            MintCard(
              miuix: mintMiuixOf(context),
              children: [
                for (final (i, a) in settings.accounts.indexed)
                  MintTile(
                    miuix: mintMiuixOf(context),
                    leading: _Avatar(name: a.name, size: 34),
                    title: a.name,
                    subtitle: a.isAuthlib
                        ? '外置登录 · ${a.authServer}'
                        : '离线 · ${a.uuid}',
                    showDivider: i < settings.accounts.length - 1,
                    onTap: () => settings.selectAccount(a.name),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (selected?.name == a.name)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.check_circle,
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        IconButton(
                          tooltip: '删除账户',
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _removeAccount(a),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],

          MintSectionHeader(
            miuix: mintMiuixOf(context),
            title: '添加账户',
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
          ),
          MintCard(
            miuix: mintMiuixOf(context),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ModeTabs(
                      miuix: mintMiuixOf(context),
                      authlib: _authlibMode,
                      onChanged: (v) => setState(() => _authlibMode = v),
                    ),
                    const SizedBox(height: 16),
                    _Field(
                      miuix: mintMiuixOf(context),
                      controller: _name,
                      label: '用户名',
                      hint: '3–16 个字符，字母、数字、下划线',
                    ),
                    if (_authlibMode) ...[
                      const SizedBox(height: 12),
                      _Field(
                        miuix: mintMiuixOf(context),
                        controller: _server,
                        label: '验证服务器（Yggdrasil API）',
                        hint: 'https://littleskin.cn/api/yggdrasil',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '外置登录会在启动时注入 authlib-injector；服务器需支持该验证方式。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    MintPrimaryButton(
                      miuix: mintMiuixOf(context),
                      label: _busy
                          ? '正在验证…'
                          : (_authlibMode ? '添加外置账户' : '添加离线账户'),
                      icon: Icons.person_add_alt_1,
                      height: 46,
                      onPressed: _busy ? null : _addAccount,
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),
          Text(
            '离线账户使用 HMCL 同款 UUID 算法（md5("OfflinePlayer:<名字>")），'
            '仅能进入开启离线验证的服务器。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addAccount() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showMintSnack(context, '请输入用户名');
      return;
    }
    final settings = widget.settings;
    if (!_authlibMode) {
      settings.addAccount(createOfflineAccount(name));
      _name.clear();
      showMintSnack(context, '已添加并切换到 $name');
      return;
    }

    final server = _server.text.trim();
    if (server.isEmpty) {
      showMintSnack(context, '请输入验证服务器地址');
      return;
    }
    setState(() => _busy = true);
    final dl = widget.controller.newDownloaderForModloader();
    try {
      final account = await createAuthlibAccount(name, server, dl);
      if (!mounted) return;
      settings.addAccount(account);
      _name.clear();
      showMintSnack(context, '已添加外置账户 $name');
    } catch (e) {
      if (mounted) showMintSnack(context, '验证服务器连接失败：$e');
    } finally {
      dl.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeAccount(OfflineAccount account) async {
    final ok = await showMintConfirmDialog(
      context,
      miuix: mintMiuixOf(context),
      title: '删除账户 ${account.name}？',
      message: '只会删除启动器里保存的登录信息。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (ok) widget.settings.removeAccount(account.name);
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
      child: Text(
        initial,
        style: TextStyle(
          color: cs.onPrimary,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ModeTabs extends StatelessWidget {
  const _ModeTabs({
    required this.miuix,
    required this.authlib,
    required this.onChanged,
  });

  final bool miuix;
  final bool authlib;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MintSegmentedTabs(
      miuix: miuix,
      tabs: const ['离线账户', '外置登录'],
      selected: authlib ? 1 : 0,
      onSelected: (i) => onChanged(i == 1),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.miuix,
    required this.controller,
    required this.label,
    required this.hint,
  });

  final bool miuix;
  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    if (miuix) {
      return MiuixTextField(
        controller: controller,
        label: label,
        useLabelAsPlaceholder: true,
        singleLine: true,
        insideMargin: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      );
    }
    return TextField(
      controller: controller,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }
}

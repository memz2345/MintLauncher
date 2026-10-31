import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/src/system_font.dart';

import 'common.dart';
import '../widgets/mint_page.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/widgets/mint_refresh.dart';

/// 安装进度页：点「安装」直接跳到这一页开始跑，不再在设置表单里原地转圈。
///
/// [task] 返回安装完成的版本 id（失败抛异常）；完成后会自动切到该版本。
/// 成功页可带一条提示（例如 Fabric 需要 Fabric API）。
class InstallProgressPage extends StatefulWidget {
  const InstallProgressPage({
    super.key,
    required this.miuix,
    required this.title,
    required this.task,
    this.successHint,
    this.hintActionLabel,
    this.onHintAction,
  });

  final bool miuix;
  final String title;
  final Future<String?> Function() task;

  /// 成功后的提示文案（如「还需要安装 Fabric API」）。
  final String? successHint;
  final String? hintActionLabel;
  final VoidCallback? onHintAction;

  @override
  State<InstallProgressPage> createState() => _InstallProgressPageState();
}

class _InstallProgressPageState extends State<InstallProgressPage> {
  bool _started = false;
  bool _running = true;
  bool _success = false;
  String? _installedId;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (_started) return;
    _started = true;
    final controller = context.read<LauncherController>();
    final settings = context.read<SettingsService>();
    try {
      final id = await widget.task();
      // 先落设置（页面可能已经被关掉 —— 后台下载允许提前离开）。
      if (id != null && id.isNotEmpty) settings.selectedVersion = id;
      if (!mounted) return;
      setState(() {
        _running = false;
        _success = true;
        _installedId = id;
      });
    } catch (e) {
      controller.log('❌ ${widget.title} 失败：$e');
      if (!mounted) return;
      setState(() {
        _running = false;
        _success = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<LauncherController>();
    final cs = Theme.of(context).colorScheme;
    final progress = controller.taskProgress;
    final busy = _running;

    return PopScope(
      // 后台下载：安装/下载跑在 LauncherController 里，和这一页的生命周期
      // 无关 —— 允许直接返回，进度会挂到标题栏的下载按钮上继续走。
      canPop: true,
      child: MintPageScaffold(
        miuix: mintMiuixOf(context),
        title: busy ? '正在安装' : '安装',
        showBack: true,
        body: (padding) => LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: kMintPageScrollPhysics,
            padding: padding + const EdgeInsets.fromLTRB(20, 24, 20, 36),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - padding.vertical - 60)
                    .clamp(0.0, double.infinity),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Column(
                          children: [
                            _StatusMark(
                              miuix: mintMiuixOf(context),
                              success: _success,
                              failed: !busy && !_success,
                              running: busy,
                            ),
                            const SizedBox(height: 18),
                            Text(
                              _success
                                  ? '安装完成'
                                  : busy
                                  ? widget.title
                                  : '安装没有完成',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _success
                                  ? (_installedId == null ||
                                            _installedId!.isEmpty
                                        ? '已写入游戏目录'
                                        : '已安装 ${_installedId!}，并切换为当前启动版本')
                                  : busy
                                  ? '请保持网络连接，安装器正在写入文件…'
                                  : '可以查看日志了解具体原因，然后重试',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.45,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      if (busy || _success) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: _success ? 1 : progress?.clamp(0.0, 1.0),
                            minHeight: 8,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _success
                              ? '已完成'
                              : controller.taskLabel.isEmpty
                              ? controller.stateDetail
                              : (progress != null
                                    ? '${controller.taskLabel}  '
                                          '${(progress * 100).toStringAsFixed(0)}%'
                                    : controller.taskLabel),
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],

                      if (!busy && !_success && _error != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: cs.errorContainer.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.45,
                              color: cs.onErrorContainer,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Builder(
                          builder: (context) {
                            final lines = controller.logLines
                                .where(
                                  (l) =>
                                      l.text.contains('❌') ||
                                      l.text.contains('失败'),
                                )
                                .toList();
                            if (lines.isEmpty) return const SizedBox.shrink();
                            return Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest.withValues(
                                  alpha: 0.4,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                [for (final l in lines.reversed.take(4)) l.text]
                                    .join('\n'),
                                style: TextStyle(
                                  fontFamily: kMonoFontFallback.first,
                                  fontFamilyFallback: kMonoFontFallback,
                                  fontSize: 11,
                                  height: 1.4,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            );
                          },
                        ),
                      ],

                      if (_success && widget.successHint != null) ...[
                        const SizedBox(height: 20),
                        MintNotice(
                          miuix: mintMiuixOf(context),
                          icon: Icons.tips_and_updates_outlined,
                          title: '还要一步',
                          message: widget.successHint!,
                          action: widget.hintActionLabel == null
                              ? null
                              : MintTextAction(
                                  miuix: mintMiuixOf(context),
                                  label: widget.hintActionLabel!,
                                  onPressed: widget.onHintAction ?? () {},
                                ),
                        ),
                      ],

                      const SizedBox(height: 28),
                      if (!busy)
                        MintPrimaryButton(
                          miuix: mintMiuixOf(context),
                          label: _success ? '完成' : '返回',
                          icon: _success ? Icons.check : Icons.arrow_back,
                          height: 48,
                          onPressed: () =>
                              Navigator.of(context).pop(_installedId),
                        )
                      else ...[
                        MintSecondaryButton(
                          miuix: mintMiuixOf(context),
                          label: '后台继续',
                          icon: Icons.download_done_outlined,
                          height: 46,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '可以离开这一页：下载在后台继续，标题栏最小化左侧的'
                          '下载按钮能看到进度，点进去就是下载管理。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.45,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusMark extends StatelessWidget {
  const _StatusMark({
    required this.miuix,
    required this.success,
    required this.failed,
    required this.running,
  });

  final bool miuix;
  final bool success;
  final bool failed;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = failed ? cs.error : cs.primary;
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: running
            ? SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3, color: color),
              )
            : Icon(
                success ? Icons.check_rounded : Icons.error_outline,
                size: 40,
                color: color,
              ),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:mint/services/download_center.dart';
import 'package:mint/services/launcher/android_jre.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;
import 'package:mint/ui/pages/common.dart';
import 'package:mint/ui/pages/vanilla_versions_page.dart';
import 'package:mint/ui/widgets/mint_page.dart';
import 'package:mint/ui/widgets/mint_refresh.dart' show kMintPageScrollPhysics;

/// Android 运行环境：Java 运行时 + 对应游戏版本。
///
/// 随包只带 Java 8 / 17 / 21；26.x 的版本 JSON 要求 Java 25，所以这里提供
/// 「按需下载」——从 FCL 发布 APK 里用 Range 只取该 JRE 的三个文件，不整包
/// 下载（见原生 JreDownloader）。下载完与随包 JRE 走同一套解压 / marker，
/// 启动时 [FclRuntime.prepare] 直接认。
class RuntimeEnvPage extends StatefulWidget {
  const RuntimeEnvPage({super.key, required this.miuix});

  final bool miuix;

  @override
  State<RuntimeEnvPage> createState() => _RuntimeEnvPageState();
}

class _RuntimeEnvPageState extends State<RuntimeEnvPage> {
  List<AndroidJreStatus>? _status;
  int? _busyMajor;
  double _progress = 0;
  String _detail = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final status = await AndroidJre.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _download(int major) async {
    if (_busyMajor != null) return;
    setState(() {
      _busyMajor = major;
      _progress = 0;
      _detail = '准备下载';
    });
    final task = DownloadCenter.instance.begin(
      title: '下载 Java $major',
      detail: 'FCL 运行时 · JRE$major',
    );
    AndroidJre.onProgress = (progress) {
      task.setPhase(
        progress.fraction,
        progress.detail.isEmpty ? '下载 Java $major' : progress.detail,
      );
      if (!mounted) return;
      setState(() {
        _progress = progress.fraction;
        _detail = progress.detail;
      });
    };
    try {
      final home = await AndroidJre.download(major);
      task.complete(detail: '已安装到 $home');
      if (mounted) {
        showMintSnack(context, 'Java $major 已安装');
      }
      await _refresh();
    } on AndroidJreCancelled {
      task.cancel();
      if (mounted) showMintSnack(context, '已取消下载');
    } catch (e) {
      task.fail(e);
      if (mounted) showMintSnack(context, 'Java $major 下载失败：$e');
    } finally {
      AndroidJre.onProgress = null;
      if (mounted) {
        setState(() {
          _busyMajor = null;
          _detail = '';
        });
      }
    }
  }

  Future<void> _cancel() async {
    await AndroidJre.cancel();
  }

  void _openVanilla() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VanillaVersionsPage(miuix: widget.miuix),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final miuix = mintMiuixOf(context, widget.miuix);
    final cs = Theme.of(context).colorScheme;
    final status = _status;
    return MintPageScaffold(
      miuix: miuix,
      title: '运行环境',
      showBack: true,
      body: (padding) {
        if (!Platform.isAndroid) {
          return ListView(
            physics: kMintPageScrollPhysics,
            padding: padding + const EdgeInsets.fromLTRB(16, 12, 16, 36),
            children: [
              MintCard(
                miuix: miuix,
                children: [
                  MintTile(
                    miuix: miuix,
                    icon: Icons.desktop_windows_outlined,
                    title: '桌面端不需要这里',
                    subtitle: 'Windows / macOS / Linux 用系统 Java 或启动器自动下载',
                    showDivider: false,
                  ),
                ],
              ),
            ],
          );
        }
        return ListView(
          physics: kMintPageScrollPhysics,
          padding: padding + const EdgeInsets.fromLTRB(16, 4, 16, 36),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                'Minecraft 1.17 起必须用新版 Java；26.x 已经要求 Java 25。'
                '随包只有 8 / 17 / 21，缺的在这里下载即可，启动时自动选中。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            MintSectionHeader(miuix: miuix, title: 'Java 运行时'),
            if (status == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              MintCard(
                miuix: miuix,
                children: [
                  for (final item in status)
                    _JreRow(
                      miuix: miuix,
                      status: item,
                      busy: _busyMajor == item.major,
                      busyDetail: _detail,
                      progress: _progress,
                      onDownload: () => _download(item.major),
                      onCancel: _cancel,
                      isLast: item == status.last,
                    ),
                ],
              ),
            MintSectionHeader(miuix: miuix, title: '版本 → Java 对照'),
            MintCard(
              miuix: miuix,
              children: [
                for (final (i, entry) in _javaTargets.indexed)
                  MintTile(
                    miuix: miuix,
                    icon: entry.$1,
                    title: entry.$2,
                    subtitle: entry.$3,
                    showDivider: i != _javaTargets.length - 1,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            MintCard(
              miuix: miuix,
              children: [
                MintTile(
                  miuix: miuix,
                  icon: Icons.download_outlined,
                  title: '下载对应的游戏版本',
                  subtitle: '原版 26.3 需要 Java 25；装完版本再回来检查运行时',
                  onTap: _openVanilla,
                  trailing: const Icon(Icons.chevron_right),
                ),
                MintTile(
                  miuix: miuix,
                  icon: Icons.info_outline,
                  title: '运行时来源',
                  subtitle: 'FCL 1.3.4.3（GPL-3.0），只下载需要的 JRE 文件',
                  showDivider: false,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static const _javaTargets = <(IconData, String, String)>[
    (Icons.history_edu, 'Java 8', '1.16.5 及更早；Android 16 arm64 上会被跳过'),
    (Icons.looks_one_outlined, 'Java 17', '1.17 – 1.20.4'),
    (Icons.looks_two_outlined, 'Java 21', '1.20.5 – 1.21.x'),
    (Icons.looks_3_outlined, 'Java 25', '26.x 及以后（需要下载）'),
  ];
}

class _JreRow extends StatelessWidget {
  const _JreRow({
    required this.miuix,
    required this.status,
    required this.busy,
    required this.busyDetail,
    required this.progress,
    required this.onDownload,
    required this.onCancel,
    required this.isLast,
  });

  final bool miuix;
  final AndroidJreStatus status;
  final bool busy;
  final String busyDetail;
  final double progress;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canDownload = status.usable && !status.ready;
    final state = !status.usable
        ? '不可用'
        : status.installed
        ? '已安装'
        : status.bundled
        ? '随包'
        : '需下载';
    final subtitle =
        '${AndroidJre.gameRangeLabel(status.major)} · $state';
    return Column(
      children: [
        MintTile(
          miuix: miuix,
          icon: Icons.coffee_outlined,
          iconColor: status.usable ? null : cs.onSurfaceVariant,
          title: 'Java ${status.major}',
          subtitle: subtitle,
          enabled: status.usable,
          showDivider: false,
          onTap: canDownload ? onDownload : null,
          trailing: busy
              ? TextButton(
                  onPressed: onCancel,
                  child: const Text('取消'),
                )
              : canDownload
              ? (miuix
                    ? MiuixButton(
                        onPressed: onDownload,
                        minHeight: 32,
                        insideMargin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text('下载'),
                      )
                    : FilledButton.tonal(
                        onPressed: onDownload,
                        child: const Text('下载'),
                      ))
              : null,
        ),
        if (busy)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                    minHeight: 5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${(progress * 100).round()}% · '
                  '${busyDetail.isEmpty ? '下载中' : busyDetail}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        if (!isLast)
          Divider(
            height: 1,
            indent: 56,
            endIndent: 16,
            color: cs.outlineVariant.withValues(alpha: 0.35),
          ),
      ],
    );
  }
}

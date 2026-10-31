import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:mint/services/download_center.dart';
import 'package:mint/services/launcher/downloader.dart';
import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

import 'common.dart';

/// 「下载其他文件」：任意 URL 下载到选定的目录。
///
/// 目录解析：
///  - **Android**：直接用公共下载目录 `/sdcard/Download/Mint`（应用声明了
///    MANAGE_EXTERNAL_STORAGE，FCL 同款），不再弹 SAF —— 模拟器 / 真机的
///    DocumentsUI 对主存储限制很多，体验很差；目录建不出来时回落到应用
///    数据目录下的 `Download/Mint`。
///  - **桌面端**：系统目录选择器，默认定位上次用的目录（`otherDownloadDir`
///    落盘记忆，首次回落游戏目录）。
///
/// 选完目录 → 输入 URL（可选改文件名）→ DownloadCenter 后台任务，进度在
/// 标题栏下载按钮 / 下载管理页 / 下载中心的「下载管理」里都看得到。
Future<void> startOtherFileDownloadFlow(BuildContext context) async {
  final settings = context.read<SettingsService>();
  final miuix = mintMiuixOf(context);

  // 1. 解析目录。
  late final String dir;
  if (Platform.isAndroid) {
    final primary = '/storage/emulated/0/Download/Mint';
    try {
      Directory(primary).createSync(recursive: true);
      dir = primary;
    } catch (_) {
      final fallback = p.join(await GameDir.launcherDataDir(), 'Download', 'Mint');
      Directory(fallback).createSync(recursive: true);
      dir = fallback;
    }
  } else {
    var initial = settings.otherDownloadDir;
    if (initial.isEmpty || !Directory(initial).existsSync()) {
      initial = settings.gameDir;
    }
    String? picked;
    try {
      picked = await getDirectoryPath(
        confirmButtonText: '保存到这里',
        initialDirectory: initial.isNotEmpty && Directory(initial).existsSync()
            ? initial
            : null,
      );
    } catch (_) {
      picked = null;
    }
    if (picked == null || picked.isEmpty || !context.mounted) return;
    dir = picked;
    // 记住这次的选择，下次直接定位。
    settings.otherDownloadDir = dir;
  }

  if (!context.mounted) return;

  // 2. 输入 URL + 可选文件名。controller 由对话框 State 持有（dispose 在
  // 退场动画结束后才跑）—— 在这里 await 完立刻 dispose 会在 pop 动画
  // 期间把还在树里的 TextField 炸掉（对已 dispose 的 controller
  // addListener → build 期红屏）。
  final submitted = await showDialog<(String, String)>(
    context: context,
    builder: (_) => _OtherFileUrlDialog(miuix: miuix, dir: dir),
  );
  if (submitted == null || !context.mounted) return;
  final url = submitted.$1;
  final customName = submitted.$2;
  if (url.isEmpty) return;

  // 3. 解析文件名：自定义名 → URL basename（去掉 query）→ 兜底带时间戳。
  final uri = Uri.tryParse(url);
  final rawName = (uri?.pathSegments.isNotEmpty ?? false)
      ? uri!.pathSegments.last
      : '';
  final cleanName = Uri.decodeComponent(rawName).trim();
  final name = customName.isNotEmpty
      ? customName
      : (cleanName.isNotEmpty
            ? cleanName
            : 'download_${DateTime.now().millisecondsSinceEpoch}');

  // 4. 后台任务。先探 Content-Length 当分母，探不到就按文件数兜底
  // （下载管理页会显示已下字节 + 速度，不显示百分比）。
  final task = DownloadCenter.instance.begin(
    title: name,
    detail: '其他文件 · $dir',
  );
  final downloader = Downloader(mirror: Mirror.auto, task: task);
  task.onCancel = () => downloader.cancelled = true;
  var size = 0;
  try {
    size = await probeContentLength(url, Mirror.auto) ?? 0;
  } catch (_) {}
  task.plan(files: 1, bytes: size);

  try {
    final item = DownloadItem(url: url, dest: p.join(dir, name), name: name);
    await downloader.fetchFile(item);
    task.fileDone(name);
    task.complete(detail: dir);
    if (context.mounted) {
      showMintSnackAboveRoutes(context, '已下载：$name');
    }
  } catch (e) {
    if (task.isActive) task.fail(e);
    if (context.mounted) {
      showMintSnackAboveRoutes(context, '下载失败：$e');
    }
  }
}

/// 「下载其他文件」的 URL 输入对话框。controller 由 State 持有：
/// showDialog 返回时退场动画还在播，外面立刻 dispose 会在动画 tick
/// 重建仍在树里的 TextField 时撞上已 dispose 的 controller（debug 红屏）。
class _OtherFileUrlDialog extends StatefulWidget {
  const _OtherFileUrlDialog({required this.miuix, required this.dir});

  final bool miuix;
  final String dir;

  @override
  State<_OtherFileUrlDialog> createState() => _OtherFileUrlDialogState();
}

class _OtherFileUrlDialogState extends State<_OtherFileUrlDialog> {
  late final TextEditingController _url = TextEditingController();
  late final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    Navigator.pop(context, (url, _name.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return MintStyleDialogShell(
      miuix: widget.miuix,
      title: '下载其他文件',
      actions: mintDialogActions(
        context,
        miuix: widget.miuix,
        onCancel: () => Navigator.pop(context, null),
        onConfirm: _submit,
        confirmLabel: '开始下载',
      ),
      children: [
        Text(
          '保存到 ${widget.dir}',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        MintStyleTextField(
          controller: _url,
          hint: '下载链接（https://…）',
          autofocus: true,
        ),
        const SizedBox(height: 10),
        MintStyleTextField(controller: _name, hint: '文件名（可选）'),
      ],
    );
  }
}

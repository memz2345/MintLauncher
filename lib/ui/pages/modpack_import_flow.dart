import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/modpack_importer.dart';
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

import 'common.dart';

/// 整合包导入流程（PCL2 / HMCL「拖入安装」同款）：
/// [path] 为空时先弹文件选择器 → 识别 → 确认对话框 → 后台导入。
///
/// 支持拖拽（app.dart 的全窗口 DropTarget）与下载页的「导入整合包」按钮
/// 两个入口；进度走 DownloadCenter 后台任务（标题栏下载按钮可查）。
Future<void> startModpackImportFlow(
  BuildContext context, {
  String? path,
}) async {
  final file = path ?? await _pickModpackFile();
  if (file == null || file.isEmpty) return;

  final ModpackDescriptor descriptor;
  try {
    descriptor = ModpackImporter.inspect(file);
  } catch (e) {
    if (context.mounted) showMintSnack(context, '不是有效的整合包：$e');
    return;
  }
  if (!context.mounted) return;

  final result = await _confirmImport(context, descriptor);
  if (result == null || !context.mounted) return;

  final controller = context.read<LauncherController>();
  showMintSnack(context, '开始导入「${result.$1}」，进度见标题栏下载按钮');
  try {
    final packId = await controller.installModpackFromFile(
      file,
      name: result.$1,
      gameVersion: result.$2,
    );
    if (context.mounted) {
      showMintSnack(
        context,
        '整合包已导入为 $packId，可在主页选择启动',
        action: SnackBarAction(
          label: '打开文件夹',
          onPressed: () => controller.openInFileManager(
            controller.gameDir.versionDir(packId),
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) showMintSnack(context, '整合包导入失败：$e');
  }
}

Future<String?> _pickModpackFile() async {
  const group = XTypeGroup(label: '整合包', extensions: ['zip', 'mrpack']);
  final file = await openFile(acceptedTypeGroups: const [group]);
  return file?.path;
}

/// 导入确认：展示识别结果，让用户改版本名；普通压缩包额外手填 MC 版本。
/// 返回 (版本名, MC 版本兜底)。
Future<(String, String)?> _confirmImport(
  BuildContext context,
  ModpackDescriptor descriptor,
) {
  final nameController = TextEditingController(
    text: descriptor.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim(),
  );
  final versionController = TextEditingController(text: descriptor.gameVersion);
  return showDialog<(String, String)>(
    context: context,
    builder: (dialogContext) => MintStyleDialogShell(
      miuix: mintMiuixOf(context),
      title: '导入整合包',
      actions: mintDialogActions(
        dialogContext,
        miuix: mintMiuixOf(context),
        onCancel: () => Navigator.pop(dialogContext),
        onConfirm: () {
          final name = nameController.text.trim();
          if (name.isEmpty) return;
          Navigator.pop(dialogContext, (name, versionController.text.trim()));
        },
        confirmLabel: '开始导入',
      ),
      children: [
        _InfoRow(
          '格式',
          '${descriptor.kind.label} · ${(descriptor.archiveBytes / 1024 / 1024).toStringAsFixed(1)}MB · ${descriptor.fileCount} 个条目',
        ),
        _InfoRow('加载器', descriptor.displayLoader),
        _InfoRow(
          'Minecraft',
          descriptor.gameVersion.isEmpty ? '未识别' : descriptor.gameVersion,
        ),
        const SizedBox(height: 14),
        MintStyleTextField(
          controller: nameController,
          hint: '版本名称（自动开启版本隔离）',
          autofocus: true,
        ),
        if (descriptor.gameVersion.isEmpty) ...[
          const SizedBox(height: 12),
          MintStyleTextField(
            controller: versionController,
            hint: 'Minecraft 版本（未识别，请填写，例如 1.20.1）',
          ),
        ],
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// 拖入的文件是不是整合包（拖拽入口过滤用）。
bool isModpackFileName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') || lower.endsWith('.mrpack');
}

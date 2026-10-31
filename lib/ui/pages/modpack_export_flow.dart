import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:mint/services/download_center.dart';
import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/launcher/modpack_exporter.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/src/enums.dart' show UiStyleX;
import 'package:mint/ui/mint_icons.dart' show mintMiuixOf;

import 'common.dart';
import 'shared_actions.dart' show versionSummary;

/// 导出整合包流程（PCL2 2.14「导出整合包」页面同思路）：
/// 填名称 / 作者 / 版本号 → 选格式（Modrinth .mrpack / CurseForge .zip）→
/// 勾选导出内容（模组、设置、存档、资源包、光影包…，存档等可按子项反选）→
/// 选保存位置 → 后台任务打包（进度走 DownloadCenter：标题栏圆圈 + 下载管理页）。
///
/// 文件收集规则、内容选项与 PCL2 `PageInstanceExport` 对齐（见
/// ModpackExporter 顶部注释）；OptiFine 因许可证不打包。
Future<void> exportModpackFlow(
  BuildContext context,
  LauncherController controller,
  SettingsService settings,
  String versionId, {
  required bool miuix,
}) async {
  final summary = versionSummary(controller, versionId);
  final author = settings.selectedAccount?.name ?? 'MintPlayer';
  final isolated = settings.effectiveFor(versionId).isolation;
  final home = controller.gameDir.gameHome(versionId, isolated: isolated);
  final modable = controller.gameDir.factsOf(versionId).modable;
  final hasOptiFine = versionId.toLowerCase().contains('optifine');

  final result = await showDialog<_ExportInputs>(
    context: context,
    builder: (_) => _ExportDialog(
      miuix: miuix,
      defaultName: versionId.split('-OptiFine_').first,
      defaultAuthor: author,
      home: home,
      modable: modable,
      hasOptiFine: hasOptiFine,
    ),
  );
  if (result == null || !context.mounted) return;

  final safeName = result.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final ext = result.format == ModpackExportFormat.modrinth
      ? '.mrpack'
      : '.zip';
  final location = await getSaveLocation(
    suggestedName: '$safeName-${result.packVersion}$ext',
    confirmButtonText: '导出',
  );
  if (location == null || location.path.isEmpty || !context.mounted) return;

  final task = DownloadCenter.instance.begin(
    title: '导出整合包 $safeName',
    detail: 'MC ${summary.mcVersion}',
  );
  final exporter = ModpackExporter(gameDir: controller.gameDir);
  try {
    final export = await exporter.export(
      versionId,
      home: home,
      name: result.name,
      author: result.author,
      packVersion: result.packVersion,
      format: result.format,
      optionChecked: result.optionChecked,
      subItemChecked: result.subItemChecked,
      checkHosted: result.checkHosted,
      destFile: location.path,
      onProgress: (f, label) => task.setPhase(f, label),
    );
    task.complete(
      detail:
          '${export.fileCount + export.hostedCount} 个文件 · '
          '${(export.sizeBytes / 1024 / 1024).toStringAsFixed(1)}MB',
    );
    if (!context.mounted) return;
    final extras = <String>[
      if (export.hostedCount > 0) '${export.hostedCount} 个文件已匹配 Modrinth 在线下载',
      if (export.skippedOptiFine.isNotEmpty) 'OptiFine 未打包，见包内说明',
      ...export.notes,
    ];
    showMintSnack(
      context,
      '整合包已导出（${export.fileCount} 个文件打包'
      '${extras.isEmpty ? '' : '；${extras.join('；')}'}）',
      action: SnackBarAction(
        label: '打开文件夹',
        onPressed: () => controller.openInFileManager(p.dirname(location.path)),
      ),
    );
  } catch (e) {
    task.fail(e);
    if (context.mounted) showMintSnack(context, '导出失败：$e');
  }
}

class _ExportInputs {
  const _ExportInputs(
    this.name,
    this.author,
    this.packVersion,
    this.format,
    this.checkHosted,
    this.optionChecked,
    this.subItemChecked,
  );

  final String name;
  final String author;
  final String packVersion;
  final ModpackExportFormat format;
  final bool checkHosted;
  final Map<String, bool> optionChecked;
  final Map<String, bool> subItemChecked;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({
    required this.miuix,
    required this.defaultName,
    required this.defaultAuthor,
    required this.home,
    required this.modable,
    required this.hasOptiFine,
  });

  final bool miuix;
  final String defaultName;
  final String defaultAuthor;

  /// 版本游戏主目录：用于扫出存档 / 资源包 / 光影包子项。
  final String home;
  final bool modable;
  final bool hasOptiFine;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.defaultName,
  );
  late final TextEditingController _author = TextEditingController(
    text: widget.defaultAuthor,
  );
  late final TextEditingController _version = TextEditingController(
    text: '1.0',
  );
  late ModpackExportFormat _format = ModpackExportFormat.modrinth;
  bool _checkHosted = true;

  late final List<ModpackExportOption> _options = ModpackExporter.optionsFor(
    modable: widget.modable,
    hasOptiFine: widget.hasOptiFine,
  );

  late final Map<String, bool> _optionChecked = {
    for (final o in _options) o.key: o.defaultChecked,
  };

  /// key = `<optionKey>/<子项标题>`，默认全选；反选即从父规则里排除。
  late final Map<String, bool> _subItemChecked = {
    for (final entry in _subItems.entries)
      for (final sub in entry.value) '${entry.key}/${sub.title}': true,
  };

  /// 预扫各选项的子项（存档世界 / 资源包 / 光影包）。
  late final Map<String, List<ModpackExportSubItem>> _subItems = {
    for (final o in _options)
      if (o.hasSubItems) o.key: ModpackExporter.subItemsOf(o, widget.home),
  };

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    _version.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final styleMiuix = mintMiuixOf(context, widget.miuix);
    final cs = Theme.of(context).colorScheme;
    return MintStyleDialogShell(
      miuix: styleMiuix,
      title: '导出整合包',
      actions: mintDialogActions(
        context,
        miuix: styleMiuix,
        onCancel: () => Navigator.pop(context),
        onConfirm: () => Navigator.pop(
          context,
          _ExportInputs(
            _name.text.trim().isEmpty ? widget.defaultName : _name.text.trim(),
            _author.text.trim(),
            _version.text.trim().isEmpty ? '1.0' : _version.text.trim(),
            _format,
            _format == ModpackExportFormat.modrinth && _checkHosted,
            Map.of(_optionChecked),
            Map.of(_subItemChecked),
          ),
        ),
        confirmLabel: '下一步',
      ),
      children: [
        MintStyleTextField(controller: _name, hint: '整合包名称', autofocus: true),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: MintStyleTextField(controller: _author, hint: '作者'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MintStyleTextField(controller: _version, hint: '版本号'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _format == ModpackExportFormat.modrinth,
          onChanged: (v) => setState(
            () => _format = v
                ? ModpackExportFormat.modrinth
                : ModpackExportFormat.curseForge,
          ),
          title: const Text(
            'Modrinth 格式（.mrpack）',
            style: TextStyle(fontSize: 13.5),
          ),
          subtitle: Text(
            'PCL2 2.14+ 导出同款；关闭则导出 CurseForge 兼容 .zip',
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _checkHosted,
          // CurseForge 格式没有对应清单结构，联网匹配只在 Modrinth 下可用。
          onChanged: _format == ModpackExportFormat.modrinth
              ? (v) => setState(() => _checkHosted = v)
              : null,
          title: const Text(
            '联网匹配 Modrinth 资源',
            style: TextStyle(fontSize: 13.5),
          ),
          subtitle: Text(
            '匹配到的 Mod / 资源包不打包，导入时在线下载；失败自动回退为直接打包',
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '导出内容',
          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final option in _options) ...[
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _optionChecked[option.key] ?? option.defaultChecked,
                    onChanged: (v) =>
                        setState(() => _optionChecked[option.key] = v ?? false),
                    title: Text(
                      option.title,
                      style: const TextStyle(fontSize: 13.5),
                    ),
                    subtitle: Text(
                      option.description,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if ((_optionChecked[option.key] ?? option.defaultChecked) &&
                      option.hasSubItems)
                    for (final sub
                        in _subItems[option.key] ??
                            const <ModpackExportSubItem>[])
                      Padding(
                        padding: const EdgeInsets.only(left: 28),
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          controlAffinity: ListTileControlAffinity.leading,
                          value:
                              _subItemChecked['${option.key}/${sub.title}'] ??
                              true,
                          onChanged: (v) => setState(
                            () =>
                                _subItemChecked['${option.key}/${sub.title}'] =
                                    v ?? false,
                          ),
                          title: Text(
                            sub.title,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '出于 OptiFine 许可证限制，导出的整合包不会包含 OptiFine。',
          style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

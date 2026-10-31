import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mint/services/launcher/launch_support.dart';
import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/src/enums.dart' show UiStyleX;

import 'common.dart';
import '../widgets/launch_progress_dialog.dart';

/// 当前用于启动/下载的版本：设置里选中的版本优先，失效时退回第一个已安装。
String? activeVersionId(
  LauncherController controller,
  SettingsService settings,
) {
  final installed = controller.gameDir.installedVersions();
  if (installed.isEmpty) return null;
  if (installed.contains(settings.selectedVersion)) {
    return settings.selectedVersion;
  }
  return installed.first;
}

/// 版本对应的游戏主目录信息（下载/安装目标）。
({String id, bool isolated, String gameHome})? activeVersionTarget(
  LauncherController controller,
  SettingsService settings,
) {
  final id = activeVersionId(controller, settings);
  if (id == null) return null;
  final isolated = settings.effectiveFor(id).isolation;
  return (
    id: id,
    isolated: isolated,
    gameHome: controller.gameDir.gameHome(id, isolated: isolated),
  );
}

/// 版本 id → 便捷的展示信息。
({String id, String mcVersion, String loader}) versionSummary(
  LauncherController controller,
  String id,
) {
  String mc;
  var loader = '';
  try {
    final meta = controller.gameDir.metaOf(id);
    mc = meta.mcVersion;
    loader = meta.loader;
  } catch (_) {
    mc = id;
  }
  return (
    id: id,
    mcVersion: mc,
    loader: loaderLabelForVersion(id, loader: loader),
  );
}

/// 启动游戏（带进度弹窗）。[versionId] 为 null 时使用当前选中版本。
Future<void> launchVersion(
  BuildContext context,
  LauncherController controller,
  SettingsService settings, {
  String? versionId,
}) async {
  final version = versionId ?? activeVersionId(controller, settings);
  if (version == null || version.isEmpty) {
    showMintSnack(context, '还没有安装版本，先去「下载」页安装一个吧');
    return;
  }
  // iOS：沙盒禁 fork/exec，JVM 集成（Pojav 路线）未落地前直接给说明。
  if (!GameLaunchSupport.supported) {
    final miuix = settings.uiStyle.isMiuix;
    await showMintConfirmDialog(
      context,
      miuix: miuix,
      title: 'iOS 暂不支持启动游戏',
      message: GameLaunchSupport.unsupportedReason('ios'),
      cancelLabel: '',
      confirmLabel: '知道了',
    );
    return;
  }
  if (controller.state == LauncherState.running) {
    showMintSnack(context, '游戏正在运行中');
    return;
  }
  if (controller.state == LauncherState.installing ||
      controller.state == LauncherState.preparingJava ||
      controller.state == LauncherState.launching) {
    showMintSnack(context, '正在安装 / 准备中，请稍候再启动');
    return;
  }
  if (settings.selectedVersion != version) {
    settings.selectedVersion = version;
  }

  // 启动对话框全平台统一：Android 上它会被独立的 GameActivity 盖住，
  // state 变 running 时自己关掉，回启动器时不会残留。
  controller.prepareLaunchStages();
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LaunchProgressDialog(
      controller: controller,
      version: version,
      miuix: settings.uiStyle.isMiuix,
    ),
  );
  try {
    await controller.installAndLaunch(version);
  } on LaunchCancelledException {
    if (context.mounted) showMintSnack(context, '已取消启动');
  } catch (e) {
    if (context.mounted) showMintSnack(context, '启动失败：$e');
  }
}

/// 启动安装任务：直接转后台，不停在安装进度页。
///
/// 进度挂在标题栏下载按钮 + 下载管理页（[DownloadCenter]）；
/// 这里立刻关掉配置页，成功后自动选中新版本。
Future<void> runInstallTask(
  BuildContext context, {
  required String title,
  required Future<String?> Function() task,
  String? successHint,
}) async {
  final controller = context.read<LauncherController>();
  final settings = context.read<SettingsService>();
  final navigator = Navigator.of(context);
  final notifyContext = navigator.context;

  final future = task();
  if (navigator.canPop()) navigator.pop();
  showMintSnackAboveRoutes(notifyContext, '已开始$title，进度见标题栏');

  unawaited(() async {
    try {
      final id = await future;
      if (id != null && id.isNotEmpty) settings.selectedVersion = id;
      if (successHint != null && successHint.isNotEmpty) {
        controller.log(successHint);
      }
      if (notifyContext.mounted) {
        showMintSnackAboveRoutes(
          notifyContext,
          id == null || id.isEmpty ? '✅ $title 完成' : '✅ 安装完成：$id',
        );
      }
    } catch (e) {
      controller.log('❌ $title 失败：$e');
      if (notifyContext.mounted) {
        showMintSnackAboveRoutes(notifyContext, '❌ $title 失败：$e');
      }
    }
  }());
}

/// 重命名 / 复制 / 删除版本的公共操作。
Future<void> renameVersionFlow(
  BuildContext context,
  LauncherController controller,
  SettingsService settings,
  String version, {
  required bool miuix,
}) async {
  final name = await promptVersionName(
    context,
    miuix: miuix,
    title: '重命名版本',
    initial: version,
    confirm: '重命名',
  );
  if (name == null || name == version) return;
  try {
    final id = controller.gameDir.renameVersion(version, name);
    if (settings.selectedVersion == version) settings.selectedVersion = id;
    controller.log('版本 $version 已重命名为 $id');
    if (context.mounted) showMintSnack(context, '已重命名为 $id');
  } catch (e) {
    controller.log('❌ 重命名失败：$e');
    if (context.mounted) showMintSnack(context, '重命名失败：$e');
  }
}

Future<void> copyVersionFlow(
  BuildContext context,
  LauncherController controller,
  String version, {
  required bool miuix,
}) async {
  final name = await promptVersionName(
    context,
    miuix: miuix,
    title: '复制版本',
    initial: '$version-copy',
    confirm: '复制',
  );
  if (name == null) return;
  try {
    final id = controller.gameDir.copyVersion(version, name);
    controller.log('已复制为版本 $id');
    if (context.mounted) showMintSnack(context, '已复制为 $id');
  } catch (e) {
    controller.log('❌ 复制失败：$e');
    if (context.mounted) showMintSnack(context, '复制失败：$e');
  }
}

Future<bool> deleteVersionFlow(
  BuildContext context,
  LauncherController controller,
  SettingsService settings,
  String version, {
  required bool miuix,
}) async {
  final ok = await showMintConfirmDialog(
    context,
    miuix: miuix,
    title: '删除 $version？',
    message: '会删除整个版本目录（json / jar / natives），共享的库与资源保留。',
    confirmLabel: '删除',
    destructive: true,
  );
  if (!ok) return false;
  final dir = controller.gameDir.versionDir(version);
  if (dir.contains('..')) return false;
  try {
    await Directory(dir).delete(recursive: true);
    if (settings.selectedVersion == version) {
      final rest = controller.gameDir.installedVersions();
      settings.selectedVersion = rest.isEmpty ? '' : rest.first;
    }
    controller.log('已删除版本 $version');
    if (context.mounted) showMintSnack(context, '已删除版本 $version');
    return true;
  } catch (e) {
    controller.log('❌ 删除版本失败：$e');
    if (context.mounted) showMintSnack(context, '删除版本失败：$e');
    return false;
  }
}

Future<String?> promptVersionName(
  BuildContext context, {
  required bool miuix,
  required String title,
  required String initial,
  required String confirm,
}) {
  return showMintTextDialog(
    context,
    miuix: miuix,
    title: title,
    initial: initial,
    hint: '版本名称',
    confirmLabel: confirm,
  );
}

/// 目标 Minecraft 版本选择弹层（加载器 / OptiFine / 安装页共用）。
Future<String?> showGameVersionPickerSheet(
  BuildContext context, {
  required bool miuix,
  required List<String> ids,
  required Set<String> installed,
  required String? current,
  Map<String, String> types = const {},
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      var query = '';
      return StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final filtered = [
            for (final id in ids)
              if (query.isEmpty ||
                  id.toLowerCase().contains(query.toLowerCase()))
                id,
          ];
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * 0.68,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '选择 Minecraft 版本',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (current != null)
                          Text(
                            '当前 $current',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                sheetContext,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: MintSearchField(
                      miuix: miuix,
                      hint: '搜索版本',
                      onChanged: (v) => setSheetState(() => query = v),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final id = filtered[i];
                        final type = types[id] ?? 'release';
                        return ListTile(
                          leading: Icon(
                            installed.contains(id)
                                ? Icons.check_circle_outline
                                : Icons.videogame_asset_outlined,
                            size: 22,
                          ),
                          title: Text(id),
                          subtitle: Text(
                            gameDropdownLabel(id, type, installed.contains(id)),
                          ),
                          trailing: id == current
                              ? Icon(
                                  Icons.check,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                          onTap: () => Navigator.pop(sheetContext, id),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

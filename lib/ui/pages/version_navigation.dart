import 'package:flutter/material.dart';

import 'package:mint/services/launcher/launcher_controller.dart';
import 'package:mint/services/settings_service.dart';

import 'common.dart';
import 'loader_install_page.dart';
import 'modpack_export_flow.dart';
import 'shared_actions.dart';
import 'version_content_page.dart';
import 'version_settings_page.dart';
import '../widgets/version_card.dart';

/// 版本相关的页面跳转与更多菜单行为（主页 / 版本页共用）。
void openVersionSettings(BuildContext context, bool miuix, String id) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VersionSettingsPage(miuix: miuix, versionId: id),
    ),
  );
}

void openVersionContent(BuildContext context, bool miuix, String id) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VersionContentPage(miuix: miuix, versionId: id),
    ),
  );
}

/// 给已安装的版本补装加载器 / OptiFine（HMCL 同款：装在已有版本之上，
/// 生成一个继承原版本的新版本，不动原版本）。
///
/// 进入独立的「安装加载器」页选择加载器与构建；页面里开始安装后先返回
/// 上一级，安装转后台，完成后自动选中新版本。
Future<void> installLoaderFlow(
  BuildContext context,
  LauncherController controller,
  SettingsService settings,
  String versionId, {
  required bool miuix,
}) async {
  if (controller.isPreparing) {
    showMintSnack(context, '有任务正在进行，稍后再试');
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LoaderInstallPage(miuix: miuix, versionId: versionId),
    ),
  );
}

Future<void> handleVersionMenu(
  BuildContext context,
  LauncherController controller,
  SettingsService settings,
  String id,
  VersionMenuAction action, {
  required bool miuix,
}) async {
  switch (action) {
    case VersionMenuAction.manage:
      openVersionContent(context, miuix, id);
    case VersionMenuAction.settings:
      openVersionSettings(context, miuix, id);
    case VersionMenuAction.installLoader:
      await installLoaderFlow(context, controller, settings, id, miuix: miuix);
    case VersionMenuAction.exportPack:
      await exportModpackFlow(context, controller, settings, id, miuix: miuix);
    case VersionMenuAction.openFolder:
      final isolated = settings.effectiveFor(id).isolation;
      await controller.openInFileManager(
        controller.gameDir.gameHome(id, isolated: isolated),
      );
    case VersionMenuAction.rename:
      await renameVersionFlow(context, controller, settings, id, miuix: miuix);
    case VersionMenuAction.copy:
      await copyVersionFlow(context, controller, id, miuix: miuix);
    case VersionMenuAction.delete:
      await deleteVersionFlow(context, controller, settings, id, miuix: miuix);
  }
}

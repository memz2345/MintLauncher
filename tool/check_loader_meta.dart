// ignore_for_file: avoid_print

// 冒烟：Forge / NeoForge 版本清单拉取（走 Downloader 的镜像/重试链路）。
import 'dart:io';

import 'package:mint/services/launcher/downloader.dart';
import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/launcher/modloader.dart';

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('mint_meta_check_');
  final dl = Downloader(mirror: Mirror.auto);
  final svc = ModloaderService(gameDir: GameDir(tmp.path), downloader: dl);
  try {
    final forge = await svc.forgeVersions('1.20.4');
    print('forge 1.20.4: ${forge.length} 个，最新=${forge.take(3).map((v) => v.version).join(', ')}');
    final nf = await svc.neoforgeVersions('1.21.1');
    print('neoforge 1.21.1: ${nf.length} 个，最新=${nf.take(3).map((v) => v.version).join(', ')}');
    final fabric = await svc.fabricVersions('1.20.4');
    print('fabric 1.20.4: ${fabric.length} 个，最新=${fabric.take(2).map((v) => v.version).join(', ')}');
  } finally {
    dl.close();
    await tmp.delete(recursive: true);
  }
}

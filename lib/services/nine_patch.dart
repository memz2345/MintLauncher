/// MIUI 主题包里的 `.9.png` 处理。
///
/// mtz 里的 9-patch 是**源图**（没被 aapt 编译过）：最外圈保留着 1px 的
/// 黑色 stretch / padding 引导线，四个角像素透明。Flutter 把它当普通 PNG
/// 解码，引导线会被原样画出来（整张背景图四周一圈黑边、角上有针眼）。
///
/// 处理方式：展示前把外圈 1px 裁掉，缓存在原图旁边的 `<名字>_9crop.png`
/// （同目录，跟主题素材一起生灭）。裁图要用 dart:ui 的编解码器，只能在
/// 主 isolate 跑 —— 主题导入 / 补解完成后由 [materializeNinePatches]
/// 统一补一次；没来得及裁的图先按原图展示，裁完 notify 一声即换。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 是不是带引导边的 9-patch 源图。
bool isNinePatchSource(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.9.png');
}

/// 同一目录、同名的裁边缓存文件路径。
String ninePatchSidecarPath(String path) {
  final dir = File(path).parent.path;
  final base = path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
  // foo.9.png → foo.9_9crop.png（保留 .9 片段避免和真正的 foo.png 撞名）。
  return '$dir${Platform.pathSeparator}${base.substring(0, base.length - 4)}_9crop.png';
}

/// 渲染用的同步解析：有裁边缓存就用缓存，否则退回原图
/// （缓存还没生成时先画原图，裁完由 notify 触发重建）。
String resolveDisplayImage(String path) {
  if (!isNinePatchSource(path)) return path;
  final sidecar = ninePatchSidecarPath(path);
  return File(sidecar).existsSync() ? sidecar : path;
}

final Set<String> _inFlight = <String>{};

/// 把一批图里的 .9.png 全部裁边落盘（串行，失败静默 —— 大不了画原图）。
Future<void> materializeNinePatches(Iterable<String> paths) async {
  for (final raw in paths) {
    if (!isNinePatchSource(raw)) continue;
    final sidecar = ninePatchSidecarPath(raw);
    if (File(sidecar).existsSync()) continue;
    if (!_inFlight.add(raw)) continue;
    try {
      await _cropOne(raw, sidecar);
    } catch (e) {
      debugPrint('nine_patch: 裁边失败 $raw: $e');
    } finally {
      _inFlight.remove(raw);
    }
  }
}

Future<void> _cropOne(String source, String sidecar) async {
  final file = File(source);
  if (!file.existsSync()) return;
  final bytes = file.readAsBytesSync();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    if (image.width <= 2 || image.height <= 2) return;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(1, 1, image.width - 2.0, image.height - 2.0),
      ui.Rect.fromLTWH(0, 0, image.width - 2.0, image.height - 2.0),
      paint,
    );
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(image.width - 2, image.height - 2);
    picture.dispose();
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    if (data == null) return;
    await File(sidecar).writeAsBytes(data.buffer.asUint8List(), flush: true);
  } finally {
    image.dispose();
  }
}

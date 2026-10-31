import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/ui/widgets/top_bar_tone.dart';

Future<void> _writeSolidPng(File file, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = color);
  final image = await recorder.endRecording().toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  file.writeAsBytesSync(data!.buffer.asUint8List());
  image.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('顶栏取色：亮背景黑字，暗背景白字', () async {
    final temp = await Directory.systemTemp.createTemp('mint_tone_test_');
    addTearDown(() async {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final bright = File('${temp.path}/bright.png');
    final dark = File('${temp.path}/dark.png');
    await _writeSolidPng(bright, Colors.white);
    await _writeSolidPng(dark, Colors.black);

    final brightFg = await MintTopBarToneResolver.resolve(
      path: bright.path,
      opacity: 1,
      base: Colors.white,
      fallback: Colors.black,
    );
    final darkFg = await MintTopBarToneResolver.resolve(
      path: dark.path,
      opacity: 1,
      base: Colors.white,
      fallback: Colors.black,
    );
    // 暗图低不透明度铺在白底上，整体仍偏亮，应选黑字。
    final fadedDarkFg = await MintTopBarToneResolver.resolve(
      path: dark.path,
      opacity: 0.1,
      base: Colors.white,
      fallback: Colors.white,
    );

    expect(brightFg, Colors.black);
    expect(darkFg, Colors.white);
    expect(fadedDarkFg, Colors.black);
  });

  test('顶栏压字色：黑字配白栏、白字配黑栏', () {
    expect(mintTopBarScrimFor(Colors.black), Colors.white);
    expect(mintTopBarScrimFor(Colors.white), Colors.black);
  });
}

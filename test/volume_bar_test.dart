import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/theme_package.dart';
import 'package:mint/services/volume_bar_service.dart';
import 'package:mint/ui/widgets/theme_volume_bar.dart';

MintTheme _theme(Map<String, String> controls) =>
    MintTheme.fromJson({'id': 'vol', 'dir': '', 'controls': controls});

void main() {
  setUp(() => MintVolumeBar.current.value = null);
  tearDown(() {
    MintVolumeBar.current.value = null;
    MintThemeLibrary.instance.activeTheme = null;
  });

  test('音量状态换算比例，max 为 0 不炸', () {
    const media = MintVolumeState(stream: 3, value: 6, max: 15, muted: false);
    expect(media.ratio, 0.4);
    expect(media.isMedia, isTrue);
    const muted = MintVolumeState(stream: 2, value: 0, max: 7, muted: true);
    expect(muted.ratio, 0);
    expect(muted.isMedia, isFalse);
    expect(
      const MintVolumeState(stream: 3, value: 1, max: 0, muted: false).ratio,
      0,
    );
  });

  test('音量条柱高取主题的 miui_volume_column_height，异常值有边界', () {
    expect(_theme({'volumeColumnHeight': '200dip'}).volumeColumnHeight, 200);
    expect(_theme({}).volumeColumnHeight, 165);
    expect(_theme({'volumeColumnHeight': '12dip'}).volumeColumnHeight, 80);
    expect(_theme({'volumeColumnHeight': 'abc'}).volumeColumnHeight, 165);
  });

  testWidgets('音量条按主题声明的配色画轨道与进度', (tester) async {
    MintThemeLibrary.instance.activeTheme = _theme({
      'volumeAccent': '#FFADDCFF',
      'volumeTrack': '#4E60C0FD',
      'volumeExpand': '#FF60C0FD',
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ThemeVolumeBar())),
    );
    await tester.pump();
    expect(find.byType(ThemeVolumeBar), findsOneWidget);
    // 还没有音量事件 → 什么都不画。
    expect(find.byType(FractionallySizedBox), findsNothing);

    MintVolumeBar.current.value = const MintVolumeState(
      stream: 3,
      value: 8,
      max: 10,
      muted: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 轨道 / 圆钮是 Container(decoration)，进度是 ColoredBox，两边都收上来查色。
    final painted = <Color>{
      ...tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .map((w) => w.color),
      ...tester
          .widgetList<Container>(find.byType(Container))
          .map((w) => (w.decoration as BoxDecoration?)?.color)
          .whereType<Color>(),
    };
    expect(
      painted,
      containsAll([const Color(0xFFADDCFF), const Color(0x4E60C0FD)]),
    );
    expect(
      tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .heightFactor,
      0.8,
    );

    // 事件撤掉后淡出（不再占视觉，但节点还在，动画跑完就看不见）。
    MintVolumeBar.current.value = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    expect(tester.takeException(), isNull);
  });
}

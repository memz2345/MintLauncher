import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/ui/pages/common.dart' show MintGlobalSnack, showMintSnack;
import 'package:mint/ui/widgets/mint_page.dart';
import 'package:mint/ui/widgets/mint_progressive_band.dart';

Widget _scroller(EdgeInsets padding) => ListView.builder(
  physics: const ClampingScrollPhysics(),
  padding: padding,
  itemCount: 60,
  itemBuilder: (context, i) => SizedBox(height: 100, child: Text('item $i')),
);

void main() {
  testWidgets('Material 大标题在滚动后收成小标题并保持可见', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MintPageScaffold(
            miuix: false,
            title: '下载',
            largeTitle: '下载',
            body: _scroller,
          ),
        ),
      ),
    );

    Opacity opacityOf(String key) =>
        tester.widget<Opacity>(find.byKey(ValueKey(key)));

    expect(opacityOf('mint.material.largeTitle').opacity, 1);
    expect(opacityOf('mint.material.smallTitle').opacity, 0);

    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();

    expect(opacityOf('mint.material.largeTitle').opacity, lessThan(0.2));
    expect(opacityOf('mint.material.smallTitle').opacity, 1);
    expect(find.byType(BackdropFilter), findsWidgets);
  });

  testWidgets('miuix 大标题滚动后折叠量拉满（滚轮/拖动都能收起）', (tester) async {
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          home: MintPageScaffold(
            miuix: true,
            title: '下载',
            largeTitle: '下载',
            body: _scroller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final topBar = tester.widget<MiuixTopAppBar>(find.byType(MiuixTopAppBar));
    final behavior = topBar.scrollBehavior!;
    expect(behavior.state.collapsedFraction, lessThan(0.05));

    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();

    expect(behavior.state.collapsedFraction, greaterThan(0.9));
    // 折叠后小标题仍在树里（大标题不会连整条栏一起消失）。
    expect(find.text('下载'), findsWidgets);
  });

  testWidgets('miuix 短页面：内容顶进标题栏就折叠（不满一屏也收）', (tester) async {
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          home: MintPageScaffold(
            miuix: true,
            title: '实验室',
            largeTitle: '实验室',
            // 只有两行，可滚行程 0 —— 包版在这里记不到账，标题不折叠。
            // AlwaysScrollable 是项目约定（否则 min==max 时物理层直接拒绝拖动，
            // 连越界通知都没有）。
            body: (padding) => ListView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              padding: padding,
              children: const [SizedBox(height: 80), SizedBox(height: 80)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final behavior = tester
        .widget<MiuixTopAppBar>(find.byType(MiuixTopAppBar))
        .scrollBehavior!;
    expect(behavior.state.collapsedFraction, lessThan(0.05));

    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();

    expect(behavior.state.collapsedFraction, greaterThan(0.9));
    expect(find.text('实验室'), findsWidgets);

    // 反向拉回顶部 → 重新展开（折叠量跟着越界量回去）。
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(behavior.state.collapsedFraction, lessThan(0.05));
  });

  testWidgets('miuix 二级页升级为扩展大标题并可折叠', (tester) async {
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          home: MintPageScaffold(
            miuix: true,
            title: '设置',
            showBack: true,
            body: _scroller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final bar = tester.widget<MiuixTopAppBar>(find.byType(MiuixTopAppBar));
    final behavior = bar.scrollBehavior!;
    expect(bar.color, Colors.transparent);
    expect(behavior.state.collapsedFraction, lessThan(0.05));

    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();

    expect(behavior.state.collapsedFraction, greaterThan(0.9));
    // 折叠后才画渐变模糊带（展开态内容是清楚的，不糊）。
    expect(find.byType(MintProgressiveBand), findsOneWidget);
    expect(find.text('设置'), findsWidgets);
  });

  testWidgets('Material 二级页底部操作栏占布局空间且不溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MintPageScaffold(
          miuix: false,
          title: '安装',
          showBack: true,
          bottomBar: const MintBottomBar(
            child: SizedBox(height: 48, child: Text('开始安装')),
          ),
          body: _scroller,
        ),
      ),
    );
    expect(find.text('开始安装'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('miuix 二级页底部操作栏占布局空间且不溢出', (tester) async {
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          home: MintPageScaffold(
            miuix: true,
            title: '安装',
            showBack: true,
            bottomBar: const MintBottomBar(
              child: SizedBox(height: 48, child: Text('开始安装')),
            ),
            body: _scroller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('开始安装'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('miuix 页面内 showMintSnack 走页面自己的 SnackbarHost', (tester) async {
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          home: MintPageScaffold(
            miuix: true,
            title: '测试',
            showBack: true,
            body: (padding) => Padding(
              padding: padding,
              child: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showMintSnack(context, '已安装 Fabric'),
                    child: const Text('触发提示'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('触发提示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已安装 Fabric'), findsOneWidget);
  });

  testWidgets('全局 miuix Snackbar 兜底可用且不挡点击', (tester) async {
    MintGlobalSnack.miuix = true;
    addTearDown(() => MintGlobalSnack.miuix = false);
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: true,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Stack(
              children: [
                Center(
                  child: TextButton(
                    onPressed: () => showMintSnack(context, '全局提示'),
                    child: const Text('触发全局提示'),
                  ),
                ),
                Positioned.fill(
                  child: MiuixSnackbarHost(state: MintGlobalSnack.host),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('触发全局提示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('全局提示'), findsOneWidget);
  });
}

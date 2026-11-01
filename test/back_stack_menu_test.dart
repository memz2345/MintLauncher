import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/test_hooks.dart';
import 'package:mint/ui/widgets/back_stack_menu.dart';
import 'package:mint/ui/widgets/mint_page.dart';
import 'package:mint/ui/window_chrome.dart';

void main() {
  setUp(() {
    MintWindowChrome.instance.reset();
    MintWindowChrome.instance.enabled = false;
    MintTestHooks.reset();
  });

  tearDown(() {
    MintWindowChrome.instance.reset();
    MintWindowChrome.instance.enabled = false;
  });

  testWidgets('返回栈记录标题，菜单可以回到指定层级', (tester) async {
    await tester.pumpWidget(
      MiuixThemeController(
        isDark: false,
        child: MaterialApp(
          navigatorObservers: [MintWindowChrome.instance.observer],
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MintPageScaffold(
                        miuix: true,
                        title: '设置',
                        showBack: true,
                        body: (_) => Center(
                          child: Builder(
                            builder: (inner) => TextButton(
                              onPressed: () => showMintBackStackMenu(inner),
                              child: const Text('open menu'),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('push'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();

    final targets = MintWindowChrome.instance.backTargets;
    expect(targets.map((t) => t.title), ['首页', '设置']);
    expect(targets.first.current, isFalse);
    expect(targets.last.current, isTrue);

    await tester.tap(find.text('open menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 菜单是「当前层在上、更早的层在下」，当前层不可点，首页那一行可点。
    expect(find.text('首页'), findsOneWidget);
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();

    expect(find.text('push'), findsOneWidget);
    expect(find.text('设置'), findsNothing);
  });
}

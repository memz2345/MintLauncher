import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/ui/nav_state.dart';
import 'package:mint/widgets/global_shortcuts.dart';

void main() {
  testWidgets('Esc / 鼠标侧键返回上一页', (tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        builder: (context, child) =>
            GlobalShortcutHost(navigatorKey: key, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('second')),
                  ),
                ),
                child: const Text('push'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      const PointerDownEvent(
        position: Offset(20, 20),
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
  });

  testWidgets('Ctrl+2 在根页面切换一级页', (tester) async {
    final key = GlobalKey<NavigatorState>();
    NavRequests.tab.value = -1;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        builder: (context, child) =>
            GlobalShortcutHost(navigatorKey: key, child: child!),
        home: const Scaffold(body: Text('root')),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(NavRequests.tab.value, 1);
    NavRequests.tab.value = -1;
  });

  testWidgets('Ctrl+F / F5 发出页面请求', (tester) async {
    final key = GlobalKey<NavigatorState>();
    var searches = 0;
    var refreshes = 0;
    var manages = 0;
    void onSearch() => searches++;
    void onRefresh() => refreshes++;
    void onManage() => manages++;
    NavRequests.search.addListener(onSearch);
    NavRequests.refresh.addListener(onRefresh);
    NavRequests.manage.addListener(onManage);
    addTearDown(() {
      NavRequests.search.removeListener(onSearch);
      NavRequests.refresh.removeListener(onRefresh);
      NavRequests.manage.removeListener(onManage);
    });

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        builder: (context, child) =>
            GlobalShortcutHost(navigatorKey: key, child: child!),
        home: const Scaffold(body: Text('root')),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(searches, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();
    expect(refreshes, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(manages, 1);
  });
}

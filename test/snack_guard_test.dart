// showMintSnack 的防御回归：上下文没有 Material Scaffold 宿主时
// （fluent 壳、风格切换瞬间），Material 分支不能抛 debug 断言。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/ui/pages/common.dart';

void main() {
  testWidgets('showMintSnack 没有 Scaffold 宿主时不抛断言', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMintSnack(context, '你好'),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    // 修复前：debug 断言 "no descendant Scaffolds to present to"。
    expect(tester.takeException(), isNull);
  });

  testWidgets('有 Scaffold 宿主时正常弹出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMintSnack(context, '你好'),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text('你好'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

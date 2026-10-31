import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/launcher/launch_support.dart';

void main() {
  test('桌面与 Android 支持启动游戏，iOS 未支持（沙盒禁 fork/exec）', () {
    expect(GameLaunchSupport.supportedFor('windows'), isTrue);
    expect(GameLaunchSupport.supportedFor('macos'), isTrue);
    expect(GameLaunchSupport.supportedFor('linux'), isTrue);
    expect(GameLaunchSupport.supportedFor('android'), isTrue);
    expect(GameLaunchSupport.supportedFor('ios'), isFalse);
  });

  test('iOS 未支持时给出对齐 PojavLauncher_iOS 的原因说明', () {
    final reason = GameLaunchSupport.unsupportedReason('ios');
    expect(reason, contains('OpenJDK'));
    expect(reason, contains('JNI_CreateJavaVM'));
    // 其它平台（支持启动）不产生未支持说明。
    expect(GameLaunchSupport.unsupportedReason('android'), isNot(contains('尚未实现')));
  });
}

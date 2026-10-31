import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/crash_analyzer.dart';
import 'package:mint/services/launcher/account.dart';
import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/launcher/launch_builder.dart';
import 'package:mint/services/launcher/optifine.dart';
import 'package:mint/services/settings_service.dart';
import 'package:mint/services/launcher/modrinth.dart';

void main() {
  test('离线 UUID 与 Java nameUUIDFromBytes 算法一致', () {
    // md5("OfflinePlayer:Notch") + version3/variant 位修补，
    // 已用 Python hashlib 独立实现交叉验证。
    expect(offlineUuid('Notch'), 'b50ad385-829d-3141-a216-7e7d7539ba7f');
  });

  test('authlib 账户序列化保留类型与服务器', () {
    final json = const OfflineAccount(
      name: 'Notch',
      uuid: 'x',
      type: AccountType.authlib,
      authServer: 'https://littleskin.cn/api/yggdrasil',
    ).toJson();
    final back = OfflineAccount.fromJson(json);
    expect(back.isAuthlib, isTrue);
    expect(back.authServer, 'https://littleskin.cn/api/yggdrasil');

    // 旧数据（无 type 字段）= 离线账户，不炸。
    final legacy = OfflineAccount.fromJson({'name': 'a', 'uuid': 'b'});
    expect(legacy.isAuthlib, isFalse);
  });

  test('LaunchBuilder.parseJvmArgs 多行解析', () {
    final args = LaunchBuilder.parseJvmArgs('''
# 注释行
-XX:+UseG1GC
  -Dfoo=bar   -Dbaz=qux

''');
    expect(args, ['-XX:+UseG1GC', '-Dfoo=bar', '-Dbaz=qux']);
  });

  test('LaunchBuilder.parseEnvVars 解析 KEY=VALUE', () {
    final env = LaunchBuilder.parseEnvVars('''
# 注释
A=1
 B =  hello world
没有等号的行
''');
    expect(env, {'A': '1', 'B': 'hello world'});
  });

  test('VersionSettings 每版本覆盖解析与空判定', () {
    final vs = VersionSettings.fromJson({'memoryMb': 4096, 'isolation': true});
    expect(vs.memoryMb, 4096);
    expect(vs.isolation, isTrue);
    expect(vs.isEmpty, isFalse);
    expect(VersionSettings().isEmpty, isTrue);
    // 落盘往返
    final back = VersionSettings.fromJson(vs.toJson());
    expect(back.memoryMb, 4096);
    expect(back.isolation, isTrue);
  });

  test('版本重命名/复制清洗非法字符', () {
    final cleaned = 'a/b:c*?"<>|'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    expect(cleaned, 'a_b_c______');
  });

  test('崩溃分析：内存不足 / Java 版本 / 模组冲突', () {
    final oom = analyzeCrash([
      'java.lang.OutOfMemoryError: Java heap space',
    ], 1);
    expect(oom, isNotNull);
    expect(oom!.cause, contains('内存不足'));

    final java = analyzeCrash([
      'java.lang.UnsupportedClassVersionError: Foo',
    ], 1);
    expect(java, isNotNull);
    expect(java!.cause, contains('Java'));

    final mixin = analyzeCrash(['MixinApplyError: blah'], 1);
    expect(mixin, isNotNull);

    // 干净日志 + 正常退出 = 没有结论
    expect(analyzeCrash(['all good'], 0), isNull);
  });

  test('OptiFineEntry 从文件名解析 edition / 预览标记 / 下载地址', () {
    final stable = OptiFineEntry(
      json: {
        'mcversion': '1.20.1',
        'type': 'HD_U',
        'patch': 'I6',
        'filename': 'OptiFine_1.20.1_HD_U_I6.jar',
      },
    );
    expect(stable.edition, 'HD_U_I6');
    expect(stable.isPreview, isFalse);
    expect(
      stable.downloadUrl,
      'https://bmclapi2.bangbang93.com/optifine/1.20.1/HD_U/I6',
    );

    final preview = OptiFineEntry(
      json: {
        'mcversion': '1.20.1',
        'type': 'HD_U_I5',
        'patch': 'pre4',
        'filename': 'preview_OptiFine_1.20.1_HD_U_I5_pre4.jar',
      },
    );
    expect(preview.edition, 'HD_U_I5_pre4');
    expect(preview.isPreview, isTrue);
  });

  test('版本 id → MC 版本推断（Modrinth 过滤用，正则兜底路径）', () {
    // 用一个不存在的游戏目录强制走正则兜底（json 不存在）。
    final gd = GameDir('__no_such_dir_for_test__');
    expect(resolveMcVersion(gd, 'fabric-loader-0.16.14-1.21.1'), '1.21.1');
    expect(resolveMcVersion(gd, '1.20.1-forge-47.2.0'), '1.20.1');
    expect(resolveMcVersion(gd, 'neoforge-21.1.95'), '1.21.1');
    expect(resolveMcVersion(gd, 'neoforge-21.0.42'), '1.21');
    expect(resolveMcVersion(gd, '1.8.9'), '1.8.9');
    expect(
      resolveMcVersion(gd, 'quilt-loader-0.26.0+build.1-1.21.1'),
      '1.21.1',
    );
  });
}

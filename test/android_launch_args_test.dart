import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mint/services/launcher/android_launch.dart';
import 'package:mint/services/launcher/game_dir.dart';
import 'package:mint/services/launcher/launch_builder.dart';
import 'package:mint/services/launcher/version_model.dart';

/// Android 启动参数构建的纯逻辑测试：重点验证新增的「额外 JVM 参数 /
/// 额外游戏参数」拼装语义（FCL javaArgs/minecraftArgs 对应物）。
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mint_android_args');
    // _classpath 会列 lwjgl 目录里的 jar，建个空目录免得抛异常。
    Directory(p.join(temp.path, 'lwjgl')).createSync(recursive: true);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<GameVersion> version() => GameVersion.resolve('1.7.10', {
    'id': '1.7.10',
    'type': 'release',
    'mainClass': 'net.minecraft.client.main.Main',
    'minecraftArguments':
        '--username \${auth_player_name} --version \${version_name}',
    'libraries': <dynamic>[],
  }, (_) async => null);

  AndroidRuntimePaths paths({
    int javaMajor = 8,
    List<String> cacio17 = const [],
  }) => AndroidRuntimePaths(
    javaHome: p.join(temp.path, 'jre'),
    lwjglDir: p.join(temp.path, 'lwjgl'),
    wrapperJar: p.join(temp.path, 'wrapper.jar'),
    legacyBootstrapJar: p.join(temp.path, 'legacy-bootstrap.jar'),
    nativeLibDir: p.join(temp.path, 'native'),
    logDir: p.join(temp.path, 'logs'),
    cacheDir: p.join(temp.path, 'cache'),
    runtimeDir: p.join(temp.path, 'runtime'),
    abi: 'x86_64',
    javaMajor: javaMajor,
    cacio17Jars: cacio17,
    cacioAgentJar: cacio17.isEmpty
        ? ''
        : p.join(temp.path, 'cacio17', 'cacio-agent.jar'),
  );

  Future<List<String>> buildArgs({
    List<String> jvmArgs = const [],
    List<String> extraGameArgs = const [],
    int renderWidth = 1280,
    int renderHeight = 720,
    AndroidRuntimePaths? pathsOverride,
  }) async {
    final plan = const AndroidLaunchBuilder().build(
      version: await version(),
      gameDir: GameDir(temp.path),
      versionId: '1.7.10',
      gameHome: temp.path,
      playerName: 'Steve',
      playerUuid: 'test-uuid',
      memoryMb: 1024,
      paths: pathsOverride ?? paths(),
      jvmArgs: jvmArgs,
      extraGameArgs: extraGameArgs,
      renderWidth: renderWidth,
      renderHeight: renderHeight,
    );
    return plan.args;
  }

  test('额外 JVM 参数插在 -cp 之前、内置参数之后', () async {
    final args = await buildArgs(jvmArgs: ['-XX:+UseG1GC']);
    final cp = args.indexOf('-cp');
    final userArg = args.indexOf('-XX:+UseG1GC');
    final defaultXmx = args.indexOf('-Xmx1024M');
    expect(userArg, greaterThan(defaultXmx));
    expect(userArg, lessThan(cp));
  });

  test('JVM 对重复 -Xmx 取最后一个：用户参数必须能覆盖默认内存', () async {
    final args = await buildArgs(jvmArgs: ['-Xmx2048M']);
    final lastXmx = args.lastWhere((a) => a.startsWith('-Xmx'));
    expect(lastXmx, '-Xmx2048M');
  });

  test('多行 JVM 参数先由 parseJvmArgs 切分再进构建器', () async {
    // 切分发生在 LaunchBuilder.parseJvmArgs（launcher_controller 传参前调用），
    // build() 只接受切分好的列表 —— 这里把两层都验一遍。
    final parsed = LaunchBuilder.parseJvmArgs(
      '-XX:+UseG1GC  -XX:G1HeapRegionSize=16M\n# 注释行\n',
    );
    expect(parsed, ['-XX:+UseG1GC', '-XX:G1HeapRegionSize=16M']);
    final args = await buildArgs(jvmArgs: parsed);
    expect(args, contains('-XX:G1HeapRegionSize=16M'));
  });

  test('额外游戏参数追加在整个命令末尾（--width/--height 之后）', () async {
    final args = await buildArgs(extraGameArgs: ['--demo']);
    expect(args.last, '--demo');
    final width = args.indexOf('--width');
    expect(width, greaterThan(0));
    expect(args.indexOf('--demo'), greaterThan(width));
  });

  test('不传自定义参数时行为与旧版一致（无多余空项）', () async {
    final args = await buildArgs();
    expect(args.where((a) => a.isEmpty), isEmpty);
    expect(args, contains('-Xmx1024M'));
  });

  test('画面比例改成横向渲染分辨率：--width/--height 跟随目标尺寸', () async {
    final args = await buildArgs(renderWidth: 1600, renderHeight: 720);
    final width = args.indexOf('--width');
    expect(args[width + 1], '1600');
    expect(args[width + 3], '720');
  });

  test('ensureVideoOptions 把当前渲染尺寸写进 options.txt', () async {
    final options = File(p.join(temp.path, 'options.txt'))
      ..writeAsStringSync('overrideWidth:1280\noverrideHeight:720\n');
    AndroidLaunchBuilder.ensureVideoOptions(temp.path, width: 960, height: 720);
    final lines = options.readAsLinesSync();
    expect(lines, contains('overrideWidth:960'));
    expect(lines, contains('overrideHeight:720'));
  });

  test('远古版 launchwrapper：走 LegacyBootstrap + resources 资源目录', () async {
    final legacy = await GameVersion.resolve('a1.0.15', {
      'id': 'a1.0.15',
      'type': 'old_alpha',
      'mainClass': 'net.minecraft.launchwrapper.Launch',
      'minecraftArguments':
          '\${auth_player_name} \${auth_session} --gameDir \${game_directory} '
          '--assetsDir \${game_assets}',
      'libraries': <dynamic>[],
    }, (_) async => null);
    final resources = p.join(temp.path, 'resources');
    final plan = const AndroidLaunchBuilder().build(
      version: legacy,
      gameDir: GameDir(temp.path),
      versionId: 'a1.0.15',
      gameHome: temp.path,
      playerName: 'Steve',
      playerUuid: 'test-uuid',
      memoryMb: 1024,
      paths: paths(),
      gameAssetsDir: resources,
    );
    expect(plan.args, contains('mint.LegacyBootstrap'));
    expect(plan.args, contains('net.minecraft.launchwrapper.Launch'));
    final assets = plan.args.indexOf('--assetsDir');
    expect(plan.args[assets + 1], resources);
    expect(plan.args, isNot(contains('-Djava.awt.headless=true')));
  });

  group('1.13+ 结构化参数（arguments.jvm / arguments.game）', () {
    Future<GameVersion> modern({
      int javaMajor = 17,
    }) => GameVersion.resolve('1.20.4', {
      'id': '1.20.4',
      'type': 'release',
      'mainClass': 'net.minecraft.client.main.Main',
      'javaVersion': {'majorVersion': javaMajor},
      'libraries': [
        {'name': 'org.lwjgl:lwjgl:3.3.2'},
        {
          'name': 'org.lwjgl:lwjgl:3.3.2:natives-linux',
          'rules': [
            {
              'action': 'allow',
              'os': {'name': 'linux'},
            },
          ],
        },
        {
          'name': 'com.example.only-linux:1.0',
          'downloads': {
            'artifact': {
              'path': 'com/example/only-linux/1.0/only-linux-1.0.jar',
              'url': 'https://example.com/only-linux-1.0.jar',
              'size': 10,
            },
          },
          'rules': [
            {
              'action': 'allow',
              'os': {'name': 'linux'},
            },
          ],
        },
        {
          'name': 'com.example.plain:1.0',
          'downloads': {
            'artifact': {
              'path': 'com/example/plain/1.0/plain-1.0.jar',
              'url': 'https://example.com/plain-1.0.jar',
              'size': 10,
            },
          },
        },
      ],
      'arguments': {
        'jvm': [
          '-Djava.library.path=\${natives_directory}',
          '-Dminecraft.launcher.brand=\${launcher_name}',
          {
            'rules': [
              {
                'action': 'allow',
                'os': {'name': 'osx'},
              },
            ],
            'value': ['-XstartOnFirstThread'],
          },
          {
            'rules': [
              {
                'action': 'allow',
                'os': {'name': 'linux'},
              },
            ],
            'value': [
              '-Dorg.lwjgl.system.SharedLibraryExtractPath=\${natives_directory}',
              '-Dio.netty.native.workdir=\${natives_directory}',
            ],
          },
          '-cp',
          '\${classpath}',
        ],
        'game': [
          '--username',
          '\${auth_player_name}',
          '--version',
          '\${version_name}',
          '--gameDir',
          '\${game_directory}',
          '--assetsDir',
          '\${assets_root}',
          '--assetIndex',
          '\${assets_index_name}',
          '--uuid',
          '\${auth_uuid}',
          '--accessToken',
          '\${auth_access_token}',
          '--userType',
          '\${user_type}',
          '--userProperties',
          '\${user_properties}',
          {
            'rules': [
              {
                'action': 'allow',
                'features': {'has_custom_resolution': true},
              },
            ],
            'value': [
              '--width',
              '\${resolution_width}',
              '--height',
              '\${resolution_height}',
            ],
          },
        ],
      },
    }, (_) async => null);

    test('不再因为缺 minecraftArguments 直接抛异常', () async {
      final plan = const AndroidLaunchBuilder().build(
        version: await modern(),
        gameDir: GameDir(temp.path),
        versionId: '1.20.4',
        gameHome: temp.path,
        playerName: 'Steve',
        playerUuid: 'test-uuid',
        memoryMb: 1024,
        paths: paths(javaMajor: 17),
      );
      expect(plan.modernArguments, isTrue);
      expect(plan.args, contains('net.minecraft.client.main.Main'));
    });

    test('JSON 的 jvm 参数被展开，macOS 专属块被规则挡掉', () async {
      final args = const AndroidLaunchBuilder()
          .build(
            version: await modern(),
            gameDir: GameDir(temp.path),
            versionId: '1.20.4',
            gameHome: temp.path,
            playerName: 'Steve',
            playerUuid: 'test-uuid',
            memoryMb: 1024,
            paths: paths(javaMajor: 17),
          )
          .args;
      expect(args, contains('-cp'));
      expect(args, isNot(contains('-XstartOnFirstThread')));
      expect(
        args.where((a) => a.startsWith('-Dminecraft.launcher.brand=')),
        isNotEmpty,
      );
    });

    test('解包类参数落到可写的 cacheDir，不指到只读 natives 目录', () async {
      final args = const AndroidLaunchBuilder()
          .build(
            version: await modern(),
            gameDir: GameDir(temp.path),
            versionId: '1.20.4',
            gameHome: temp.path,
            playerName: 'Steve',
            playerUuid: 'test-uuid',
            memoryMb: 1024,
            paths: paths(javaMajor: 17),
          )
          .args;
      final cache = paths().cacheDir;
      for (final arg in args) {
        if (arg.startsWith('-Dorg.lwjgl.system.SharedLibraryExtractPath=') ||
            arg.startsWith('-Dio.netty.native.workdir=')) {
          expect(arg, endsWith(cache));
        }
      }
      // -Djava.library.path 留给 FCL rebaseArgs 换成完整搜索路径。
      expect(args, contains('-Djava.library.path=\${natives_directory}'));
    });

    test('游戏参数全部展开成真实值，命令行不留未替换的 \${}', () async {
      final args = const AndroidLaunchBuilder()
          .build(
            version: await modern(),
            gameDir: GameDir(temp.path),
            versionId: '1.20.4',
            gameHome: temp.path,
            playerName: 'Steve',
            playerUuid: 'test-uuid',
            memoryMb: 1024,
            paths: paths(javaMajor: 17),
            renderWidth: 1600,
            renderHeight: 720,
          )
          .args;
      expect(args, contains('--username'));
      expect(args[args.indexOf('--username') + 1], 'Steve');
      final width = args.indexOf('--width');
      expect(args[width + 1], '1600');
      // 只剩这三个占位符是故意留给 FCL 的 rebaseArgs 按当前渲染器换的。
      const deferred = [
        r'${natives_directory}',
        r'${gl_lib_name}',
        r'${egl_lib_name}',
      ];
      for (final arg in args) {
        final left = RegExp(r'\$\{[^}]+\}')
            .allMatches(arg)
            .map((m) => m.group(0)!)
            .where((v) => !deferred.contains(v));
        expect(left, isEmpty, reason: '未替换的占位符：$arg');
      }
    });

    test('Java 17：指针 tag 参数 + 主类包 --add-exports + cacio17', () async {
      final args = const AndroidLaunchBuilder()
          .build(
            version: await modern(),
            gameDir: GameDir(temp.path),
            versionId: '1.20.4',
            gameHome: temp.path,
            playerName: 'Steve',
            playerUuid: 'test-uuid',
            memoryMb: 1024,
            paths: paths(javaMajor: 17, cacio17: ['/x/cacio-shared.jar']),
          )
          .args;
      expect(args, contains('-XX:-UseCompressedOops'));
      expect(args, contains('--add-exports'));
      expect(
        args,
        contains(
          'net.minecraft.client.main/net.minecraft.client.main=ALL-UNNAMED',
        ),
      );
      expect(
        args,
        contains(
          '-Djava.awt.graphicsenv='
          'com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment',
        ),
      );
      expect(args, contains('-Xbootclasspath/a:/x/cacio-shared.jar'));
    });

    test('Java 8（1.12 一类）：不写 Java 9+ 专属参数', () async {
      final args = await buildArgs(pathsOverride: paths(javaMajor: 8));
      expect(args, isNot(contains('-XX:-UseCompressedOops')));
      expect(args.any((a) => a.startsWith('--add-exports')), isFalse);
    });

    test('requiredJavaMajor：1.20.4 → 21、1.20.4 → JSON 声明优先', () async {
      expect((await modern()).requiredJavaMajor, 17);
      final noDecl = await GameVersion.resolve('1.21.1', {
        'id': '1.21.1',
        'type': 'release',
        'mainClass': 'x',
        'libraries': <dynamic>[],
      }, (_) async => null);
      expect(noDecl.requiredJavaMajor, 21);
      final old = await GameVersion.resolve('1.12.2', {
        'id': '1.12.2',
        'type': 'release',
        'mainClass': 'x',
        'libraries': <dynamic>[],
      }, (_) async => null);
      expect(old.requiredJavaMajor, 8);
    });

    test('lwjglVersion：取最高声明，>=3.4.1 归到 3.4.1，2.x 归到 lwjglx', () async {
      Future<String> lwjgl(List<dynamic> libs) async {
        final v = await GameVersion.resolve('1.20.4', {
          'id': '1.20.4',
          'type': 'release',
          'mainClass': 'x',
          'libraries': libs,
        }, (_) async => null);
        return v.lwjglVersion;
      }

      expect(
        await lwjgl([
          {'name': 'org.lwjgl:lwjgl:3.3.2'},
        ]),
        '3.3.3',
      );
      expect(
        await lwjgl([
          {'name': 'org.lwjgl:lwjgl:3.4.1'},
        ]),
        '3.4.1',
      );
      expect(
        await lwjgl([
          {'name': 'org.lwjgl:lwjgl:3.5.0'},
        ]),
        '3.4.1',
      );
      expect(
        await lwjgl([
          {'name': 'org.lwjgl.lwjgl:lwjgl:2.9.4-nightly-20150209'},
          {'name': 'org.lwjgl:lwjgl:3.3.3'},
        ]),
        '3.3.3',
      );
      expect(
        await lwjgl([
          {'name': 'org.lwjgl.lwjgl:lwjgl:2.9.1'},
        ]),
        'lwjglx',
      );
      expect(await lwjgl(<dynamic>[]), '3.3.3');
    });

    test('Android 按 linux 展开参数（否则 os:linux 的参数块整段丢失）', () async {
      final args = const AndroidLaunchBuilder()
          .build(
            version: await modern(),
            gameDir: GameDir(temp.path),
            versionId: '1.20.4',
            gameHome: temp.path,
            playerName: 'Steve',
            playerUuid: 'u',
            memoryMb: 1024,
            paths: paths(javaMajor: 17),
          )
          .args;
      expect(
        args.any(
          (a) => a.startsWith('-Dorg.lwjgl.system.SharedLibraryExtractPath='),
        ),
        isTrue,
      );
      expect(
        args.any((a) => a.startsWith('-Dio.netty.native.workdir=')),
        isTrue,
      );
    });

    test('缺库不再静默剔除：报给调用方补下载', () async {
      final plan = const AndroidLaunchBuilder().build(
        version: await modern(),
        gameDir: GameDir(temp.path),
        versionId: '1.20.4',
        gameHome: temp.path,
        playerName: 'Steve',
        playerUuid: 'u',
        memoryMb: 1024,
        paths: paths(javaMajor: 17),
      );
      expect(plan.missingLibraries, contains('com.example.plain:1.0'));
    });
  });
}

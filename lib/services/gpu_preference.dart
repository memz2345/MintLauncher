import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一块物理显卡（原生 DXGI `EnumAdapters1` 枚举出来的）。
@immutable
class GpuAdapter {
  const GpuAdapter({
    required this.name,
    required this.specific,
    required this.vendor,
    required this.preferred,
    required this.dedicatedMemoryMb,
    this.luid = '',
  });

  factory GpuAdapter.fromMap(Map<Object?, Object?> map) => GpuAdapter(
    name: (map['name'] as String?) ?? '未知显卡',
    specific: (map['specific'] as String?) ?? '',
    vendor: (map['vendor'] as String?) ?? 'other',
    preferred: (map['preferred'] as bool?) ?? false,
    dedicatedMemoryMb: (map['dedicatedMemoryMb'] as int?) ?? 0,
    luid: (map['luid'] as String?) ?? '',
  );

  final String name;

  /// `VEN&DEV&SUBSYS`（如 `1002&73FF&24201458`），注册表
  /// `SpecificAdapter=` 后面要的就是这一串。
  final String specific;
  final String vendor;

  /// DXGI 枚举顺序里的第一块硬件卡 = 系统默认用的那张。
  final bool preferred;
  final int dedicatedMemoryMb;

  /// 显卡 LUID（`高-低` 十六进制），只用于探针 / 日志里对账。
  final String luid;

  /// 设置项里存的那个 id。
  String get id => adapterIdFor(specific);

  String get memoryLabel => dedicatedMemoryMb >= 1024
      ? '${(dedicatedMemoryMb / 1024).toStringAsFixed(1)} GB'
      : dedicatedMemoryMb > 0
      ? '$dedicatedMemoryMb MB'
      : '共享显存';
}

/// 显卡偏好 id 的取值：`''` = 自动，`power` / `high` = 系统档位，
/// `adapter:<VEN&DEV&SUBSYS>` = 指定到某一块卡。
const String kGpuAuto = '';
const String kGpuPowerSaving = 'power';
const String kGpuHighPerformance = 'high';

String adapterIdFor(String specific) => 'adapter:$specific';

bool isAdapterId(String id) => id.startsWith('adapter:');

/// Windows 注册表里那个值的数据串；null = 不写。
///
/// 档位串（`GpuPreference=0/1/2`）就是「显示 → 图形」里那三个选项，而
/// `SpecificAdapter=<卡>;GpuPreference=1073741824` 是系统里「指定某块卡」
/// 的写法（1073741824 = 0x40000000，配合 SpecificAdapter 使用的哨兵值）。
String? gpuRegistryValueFor(String id) {
  switch (id) {
    case kGpuAuto:
      return null;
    case kGpuPowerSaving:
      return 'GpuPreference=1;';
    case kGpuHighPerformance:
      return 'GpuPreference=2;';
    default:
      if (!isAdapterId(id)) return null;
      final specific = id.substring('adapter:'.length);
      if (specific.isEmpty) return null;
      return 'SpecificAdapter=$specific;GpuPreference=1073741824;';
  }
}

/// Mint 自己写过的值（用于切回「自动」时只清理自己那份，不动用户在
/// Windows 设置里手动配置的条目）。
bool isMintWrittenGpuValue(String value) =>
    value == 'GpuPreference=1;' ||
    value == 'GpuPreference=2;' ||
    (value.startsWith('SpecificAdapter=') &&
        value.endsWith(';GpuPreference=1073741824;'));

/// 非 Windows 平台的选卡方式：Mesa / NVIDIA PRIME 的混合显卡靠环境变量。
///
/// `adapter:…`（按卡名指定）在 Linux 没有对应机制 —— 只有 DXGI + 注册表那条路，
/// 所以退化成不干预。[cpuBackend] = 已经强制软件渲染时不要再设显卡。
Map<String, String> gpuLaunchEnv(String preferenceId, {bool cpuBackend = false}) {
  if (cpuBackend) return const {};
  switch (preferenceId) {
    case kGpuHighPerformance:
      return const {'DRI_PRIME': '1'};
    case kGpuPowerSaving:
      return const {'DRI_PRIME': '0'};
    default:
      return const {};
  }
}

/// 每应用渲染显卡偏好。
///
/// 机制：Windows 的「显示 → 图形」设置落在
/// `HKCU\Software\Microsoft\DirectX\UserGpuPreferences`，值名 = 被启动 exe 的
/// 绝对路径。混合显卡驱动（含 OpenGL/LWJGL 应用）在建上下文前会读它，所以
/// 这是外部 `javaw.exe` 唯一可行的选卡通道 —— HMCL 的「高性能显卡」、PCL 的
/// `SetGpuPreference` 走的都是同一条路。没有可用的公开 Win32 API。
///
/// 生效范围是**下一次启动**（进程起来才绑定），改完不用重启启动器。
class GpuService {
  GpuService._();

  static final GpuService instance = GpuService._();

  static const MethodChannel _channel = MethodChannel('mint/gpu');

  List<GpuAdapter> _adapters = const [];
  bool _loaded = false;

  /// 只有 Windows 能按卡名指定；Linux 走 `DRI_PRIME`，Android 走渲染器档位。
  bool get supported => Platform.isWindows;

  List<GpuAdapter> get adapters => _adapters;

  bool get loaded => _loaded;

  /// 枚举显卡（失败 / 非 Windows 返回空表，不抛）。结果缓存在单例里。
  Future<List<GpuAdapter>> loadAdapters() async {
    if (_loaded) return _adapters;
    if (supported) {
      try {
        final raw = await _channel.invokeMethod<Object?>('listAdapters');
        if (raw is List) {
          _adapters = [
            // 没有 specific（VEN&DEV&SUBSYS）就没法按卡名绑定，留着只会写出
            // 无效条目，直接丢掉。
            for (final item in raw)
              if (item is Map)
                GpuAdapter.fromMap(item.cast<Object?, Object?>()),
          ].where((a) => a.specific.isNotEmpty).toList();
        }
      } on PlatformException catch (e) {
        debugPrint('mint/gpu listAdapters 失败: ${e.message}');
      } on MissingPluginException {
        // 非 Windows / 测试环境：没有原生实现。
      }
    }
    _loaded = true;
    return _adapters;
  }

  /// 当前 exe 在注册表里的值（读不到 = null）。
  Future<String?> currentRegistryValue(String executable) async {
    if (!supported) return null;
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'getPreference',
        <String, Object?>{'exe': executable},
      );
      return raw is String && raw.isNotEmpty ? raw : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  String labelFor(String id, {List<GpuAdapter>? adapters}) {
    switch (id) {
      case kGpuAuto:
        return '自动（跟随系统）';
      case kGpuPowerSaving:
        return supported ? '节能显卡' : '集成显卡（DRI_PRIME=0）';
      case kGpuHighPerformance:
        return supported ? '高性能显卡' : '独立显卡（DRI_PRIME=1）';
      default:
        final list = adapters ?? _adapters;
        final hit = list.where((a) => a.id == id).toList();
        // 卡没枚举到（换了显卡 / 原生通道不可用）：留着 id 至少看得出选了谁。
        return hit.isEmpty ? '指定显卡（$id）' : hit.first.name;
    }
  }

  /// 启动前把偏好写到 [executable] 上，返回一行启动日志。
  ///
  /// `自动` 只在条目确实是 Mint 写的时候才删除；用户在 Windows 设置里手工
  /// 配过的一律不碰（HMCL 同款尊重）。
  Future<String> apply({
    required String executable,
    required String preferenceId,
  }) async {
    if (!supported) return '';
    final target = gpuRegistryValueFor(preferenceId);
    try {
      final current = await currentRegistryValue(executable);
      if (target == null) {
        if (current == null) {
          return '渲染显卡：自动（Windows 每应用图形设置里没有该 Java 的条目）';
        }
        if (!isMintWrittenGpuValue(current)) {
          return '渲染显卡：自动（保留你在 Windows 设置里配置的「$current」）';
        }
        await _channel.invokeMethod<Object?>('setPreference', <String, Object?>{
          'exe': executable,
          'data': '',
        });
        return '渲染显卡：自动（已清除条目「$current」）';
      }
      if (current == target) {
        return '渲染显卡：${labelFor(preferenceId)}（条目已是「$target」）';
      }
      await _channel.invokeMethod<Object?>('setPreference', <String, Object?>{
        'exe': executable,
        'data': target,
      });
      final previous = current == null ? '' : '，原「$current」';
      return '渲染显卡：${labelFor(preferenceId)} → $executable$previous';
    } on PlatformException catch (e) {
      return '渲染显卡偏好写入失败：${e.message}';
    } on MissingPluginException {
      return '';
    }
  }
}

/// 本机 / CI 探针：`MINT_GPU_PROBE_OUT=<文件路径>` 启动时把「选卡链路」跑一遍，
/// 结果写进那个文件（Windows GUI 子系统没有控制台，print 看不见）。
///
/// Windows：DXGI 枚举 + 注册表偏好「写 → 读回 → 清理」往返，用的是假的 exe 路径，
/// 不会碰真 Java 的条目。其他平台（Linux CI 没有 GPU，只能验到传递层）：合成启动
/// 环境后**真起一个子进程**把 `DRI_PRIME` 读回来，证明变量确实到了子进程环境里。
class GpuProbe {
  GpuProbe._();

  static const _fakeExe = r'C:\mint-gpu-probe\probe-not-a-real-java.exe';

  static Future<void> maybeRun() async {
    final out = Platform.environment['MINT_GPU_PROBE_OUT'] ?? '';
    if (out.isEmpty) return;
    final buffer = StringBuffer('mint GPU 探针 · ${Platform.operatingSystem}\n');
    try {
      if (GpuService.instance.supported) {
        await _registryRoundTrip(buffer);
      } else {
        await _envRoundTrip(buffer);
      }
    } catch (error, stack) {
      buffer.writeln('探针异常：$error\n$stack');
    }
    try {
      File(out).writeAsStringSync(buffer.toString());
    } catch (error) {
      debugPrint('GPU 探针写文件失败：$error');
    }
  }

  static Future<void> _registryRoundTrip(StringBuffer buffer) async {
    final service = GpuService.instance;
    final adapters = await service.loadAdapters();
    buffer.writeln('DXGI 枚举到 ${adapters.length} 块硬件显卡：');
    for (final adapter in adapters) {
      buffer.writeln(
        '  ${adapter.preferred ? '[默认]' : '      '} ${adapter.name}'
        '  ${adapter.memoryLabel}  specific=${adapter.specific}'
        '  LUID=${adapter.luid}  vendor=${adapter.vendor}',
      );
    }
    if (adapters.isEmpty) {
      buffer.writeln('  （空：mint/gpu 通道没接上，或全被过滤掉）');
    }
    buffer.writeln('探针 exe：$_fakeExe');
    buffer.writeln('初始值：${await _read(service)}');
    for (final id in [
      kGpuHighPerformance,
      kGpuPowerSaving,
      if (adapters.isNotEmpty) adapters.last.id,
    ]) {
      buffer.writeln('→ ${service.labelFor(id)}');
      buffer.writeln(
        '  ${await service.apply(executable: _fakeExe, preferenceId: id)}',
      );
      buffer.writeln('  读回：${await _read(service)}');
    }
    buffer.writeln('→ 清回自动');
    buffer.writeln(
      '  ${await service.apply(executable: _fakeExe, preferenceId: kGpuAuto)}',
    );
    buffer.writeln('  读回：${await _read(service)}');
  }

  /// Linux：三档偏好 + 按卡名 + CPU 软件渲染，各自合成启动环境，再让子进程把
  /// `DRI_PRIME` 读回来（空值打成 `<>`）。
  static Future<void> _envRoundTrip(StringBuffer buffer) async {
    final service = GpuService.instance;
    buffer.writeln('注册表通道可用：${service.supported}（非 Windows 不写偏好）');
    for (final id in const [
      kGpuAuto,
      kGpuHighPerformance,
      kGpuPowerSaving,
    ]) {
      final env = gpuLaunchEnv(id);
      buffer.writeln('→ ${service.labelFor(id)}  合成环境 $env');
      buffer.writeln('  子进程读到 ${await _echoDriPrime(env)}');
    }
    // 按卡名指定在 Linux 没有对应机制，必须退化成「不干预」而不是写个错值。
    const adapterId = 'adapter:1002&13C0&88771043';
    final adapterEnv = gpuLaunchEnv(adapterId);
    buffer.writeln('→ ${service.labelFor(adapterId)}  合成环境 $adapterEnv');
    buffer.writeln('  子进程读到 ${await _echoDriPrime(adapterEnv)}');
    final cpuEnv = gpuLaunchEnv(kGpuHighPerformance, cpuBackend: true);
    buffer.writeln('→ 高性能 + CPU 软件渲染  合成环境 $cpuEnv');
    buffer.writeln('  子进程读到 ${await _echoDriPrime(cpuEnv)}');
  }

  static Future<String> _echoDriPrime(Map<String, String> env) async {
    if (!Platform.isLinux) return '(仅 Linux 验子进程环境)';
    try {
      final result = await Process.run(
        '/bin/sh',
        <String>['-c', r'printf "<%s>" "$DRI_PRIME"'],
        environment: env,
      );
      return '${result.stdout}'.trim();
    } catch (error) {
      return '起子进程失败：$error';
    }
  }

  static Future<String> _read(GpuService service) async =>
      await service.currentRegistryValue(_fakeExe) ?? '(无条目)';
}

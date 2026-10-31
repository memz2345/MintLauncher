import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 物理内存快照（字节）。
class MemoryStatus {
  const MemoryStatus({required this.totalBytes, required this.availableBytes});

  final int totalBytes;
  final int availableBytes;

  int get usedBytes => (totalBytes - availableBytes).clamp(0, totalBytes);

  double get usedFraction =>
      totalBytes <= 0 ? 0 : (usedBytes / totalBytes).clamp(0.0, 1.0);

  double get totalGb => totalBytes / (1024 * 1024 * 1024);
  double get availableGb => availableBytes / (1024 * 1024 * 1024);
  double get usedGb => usedBytes / (1024 * 1024 * 1024);
}

/// 系统物理内存读取。
///
/// Windows 走 `GlobalMemoryStatusEx`（毫秒级、无子进程），Linux/Android 读
/// `/proc/meminfo`，macOS 用 `sysctl` + `vm_stat`。结果缓存 800ms —— 设置页
/// 的内存条每 2 秒刷新一次，多个组件同时读也不会把 FFI 打成热点。
class SystemMemory {
  SystemMemory._();

  static MemoryStatus? _cache;
  static DateTime _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<MemoryStatus> read({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _cache != null &&
        now.difference(_cacheAt) < const Duration(milliseconds: 800)) {
      return _cache!;
    }
    MemoryStatus status;
    try {
      if (Platform.isWindows) {
        status = _readWindows();
      } else if (Platform.isLinux || Platform.isAndroid) {
        status = await _readProcMeminfo();
      } else if (Platform.isMacOS) {
        status = await _readMacOs();
      } else {
        status = _fallback;
      }
    } catch (_) {
      status = _fallback;
    }
    _cache = status;
    _cacheAt = now;
    return status;
  }

  static const _fallback = MemoryStatus(
    totalBytes: 8 * 1024 * 1024 * 1024,
    availableBytes: 4 * 1024 * 1024 * 1024,
  );

  static MemoryStatus _readWindows() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final globalMemoryStatusEx = kernel32
        .lookupFunction<
          Int32 Function(Pointer<MEMORYSTATUSEX>),
          int Function(Pointer<MEMORYSTATUSEX>)
        >('GlobalMemoryStatusEx');
    final ptr = calloc<MEMORYSTATUSEX>();
    try {
      ptr.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
      final ok = globalMemoryStatusEx(ptr);
      if (ok == 0) return _fallback;
      return MemoryStatus(
        totalBytes: ptr.ref.ullTotalPhys,
        availableBytes: ptr.ref.ullAvailPhys,
      );
    } finally {
      calloc.free(ptr);
    }
  }

  static Future<MemoryStatus> _readProcMeminfo() async {
    final file = File('/proc/meminfo');
    if (!file.existsSync()) return _fallback;
    final text = await file.readAsString();
    int? totalKb;
    int? availableKb;
    for (final line in text.split('\n')) {
      final match = RegExp(
        r'^(MemTotal|MemAvailable):\s+(\d+)\s+kB',
      ).firstMatch(line);
      if (match == null) continue;
      final kb = int.tryParse(match.group(2)!);
      if (kb == null) continue;
      if (match.group(1) == 'MemTotal') totalKb = kb;
      if (match.group(1) == 'MemAvailable') availableKb = kb;
    }
    if (totalKb == null || availableKb == null) return _fallback;
    return MemoryStatus(
      totalBytes: totalKb * 1024,
      availableBytes: availableKb * 1024,
    );
  }

  static Future<MemoryStatus> _readMacOs() async {
    final total = await Process.run('sysctl', ['-n', 'hw.memsize']);
    final totalBytes = int.tryParse((total.stdout as String).trim());
    final vm = await Process.run('vm_stat', []);
    final text = vm.stdout as String;
    final pageSizeMatch = RegExp(r'page size of (\d+) bytes').firstMatch(text);
    final pageSize = int.tryParse(pageSizeMatch?.group(1) ?? '') ?? 4096;
    int pagesOf(String label) {
      final m = RegExp('$label:\\s+(\\d+)').firstMatch(text);
      return int.tryParse(m?.group(1) ?? '') ?? 0;
    }

    final freePages =
        pagesOf('Pages free') +
        pagesOf('Pages inactive') +
        pagesOf('Pages speculative');
    if (totalBytes == null) return _fallback;
    return MemoryStatus(
      totalBytes: totalBytes,
      availableBytes: (freePages * pageSize).clamp(0, totalBytes),
    );
  }
}

/// 内存 AUTO 建议值（PCL2 `PageSetupLaunch` 的档位公式精简版）。
///
/// 按「可用物理内存」而不是总内存计算：系统已经很紧张时不要硬塞满。
/// 有模组时档位更高（0.5/1.5/2.7/4.5GB + 按模组数上浮）。
class MemoryAdvisor {
  MemoryAdvisor._();

  static int autoMbFor(MemoryStatus status, {int modCount = 0}) {
    final avail = status.availableGb.clamp(0.0, 1024.0);
    final hasMods = modCount > 0;
    final t1 = (hasMods ? 1.5 : 1.5) + modCount / (hasMods ? 90 : 90);
    final t2 = (hasMods ? 2.7 : 2.5) + modCount / (hasMods ? 50 : 50);
    final t3 = (hasMods ? 4.5 : 4.0) + modCount / (hasMods ? 25 : 25);
    final floor = hasMods ? 0.5 : 0.5;

    var remaining = avail;
    var result = remaining < 0.1 ? 0.0 : (remaining < t1 ? remaining : t1);
    remaining -= t1;
    for (final (ratio, cap) in [(0.7, t2 - t1), (0.4, t3 - t2), (0.15, t3)]) {
      if (remaining < 0.1) continue;
      result += (remaining * ratio).clamp(0.0, cap);
      remaining -= cap / ratio;
    }
    result = result.clamp(floor, status.totalGb - 0.5);
    final mb = (result * 1024 / 128).round() * 128;
    return mb.clamp(512, 1048576);
  }
}

/// `GlobalMemoryStatusEx` 结构（Windows）。
final class MEMORYSTATUSEX extends Struct {
  @Uint32()
  external int dwLength;

  @Uint32()
  external int dwMemoryLoad;

  @Uint64()
  external int ullTotalPhys;

  @Uint64()
  external int ullAvailPhys;

  @Uint64()
  external int ullTotalPageFile;

  @Uint64()
  external int ullAvailPageFile;

  @Uint64()
  external int ullTotalVirtual;

  @Uint64()
  external int ullAvailVirtual;

  @Uint64()
  external int ullAvailExtendedVirtual;
}

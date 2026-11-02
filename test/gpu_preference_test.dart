import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mint/services/gpu_preference.dart';
import 'package:mint/services/settings_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Linux 选卡（DRI_PRIME）', () {
    test('三档合成出的环境变量', () {
      expect(gpuLaunchEnv(kGpuAuto), isEmpty);
      expect(gpuLaunchEnv(kGpuPowerSaving), const {'DRI_PRIME': '0'});
      expect(gpuLaunchEnv(kGpuHighPerformance), const {'DRI_PRIME': '1'});
      // 按卡名指定只有 Windows 的注册表机制，Linux 必须退化成「不干预」。
      expect(gpuLaunchEnv(adapterIdFor('1002&13C0&88771043')), isEmpty);
      // 已经强制 CPU 软件渲染时不要再设显卡。
      expect(
        gpuLaunchEnv(kGpuHighPerformance, cpuBackend: true),
        isEmpty,
        reason: 'LIBGL_ALWAYS_SOFTWARE 和 DRI_PRIME 互相矛盾，软件渲染优先',
      );
    });

    test(
      '合成出的环境真的进到子进程（Linux CI 跑这一段）',
      () async {
        final result = await Process.run(
          '/bin/sh',
          <String>['-c', r'printf "<%s>" "$DRI_PRIME"'],
          environment: gpuLaunchEnv(kGpuHighPerformance),
        );
        expect(result.stdout, '<1>');
      },
      skip: Platform.isLinux ? false : '只有 Linux 上 DRI_PRIME 有意义',
    );
  });

  group('显卡偏好 id → 注册表值', () {
    test('三档 + 指定卡，格式与 Windows「显示 → 图形」一致', () {
      expect(gpuRegistryValueFor(kGpuAuto), isNull);
      expect(gpuRegistryValueFor(kGpuPowerSaving), 'GpuPreference=1;');
      expect(gpuRegistryValueFor(kGpuHighPerformance), 'GpuPreference=2;');
      expect(
        gpuRegistryValueFor(adapterIdFor('1002&73FF&24201458')),
        'SpecificAdapter=1002&73FF&24201458;GpuPreference=1073741824;',
      );
      // 认不出的 id 一律不写（别让启动器把垃圾塞进系统设置）。
      expect(gpuRegistryValueFor('adapter:'), isNull);
      expect(gpuRegistryValueFor('whatever'), isNull);
    });

    test('只清理 Mint 自己写过的条目', () {
      expect(isMintWrittenGpuValue('GpuPreference=1;'), isTrue);
      expect(isMintWrittenGpuValue('GpuPreference=2;'), isTrue);
      expect(
        isMintWrittenGpuValue(
          'SpecificAdapter=1002&13C0&88771043;GpuPreference=1073741824;',
        ),
        isTrue,
      );
      // 「让 Windows 管理」和用户在别处配过的其它键都不能被我们删掉。
      expect(isMintWrittenGpuValue('GpuPreference=0;'), isFalse);
      expect(isMintWrittenGpuValue('AppStatus=0;'), isFalse);
    });
  });

  group('DXGI 适配器', () {
    test('fromMap → id 往返，显存文案', () {
      final adapter = GpuAdapter.fromMap(<Object?, Object?>{
        'name': 'AMD Radeon RX 6750 GRE 10GB',
        'specific': '1002&73FF&24201458',
        'vendor': 'amd',
        'preferred': false,
        'dedicatedMemoryMb': 10240,
      });
      expect(adapter.id, 'adapter:1002&73FF&24201458');
      expect(adapter.memoryLabel, '10.0 GB');
      expect(gpuRegistryValueFor(adapter.id), contains(adapter.specific));
    });

    test('核显这类 0 独显内存显示成共享显存', () {
      final adapter = GpuAdapter.fromMap(<Object?, Object?>{
        'name': 'AMD Radeon(TM) Graphics',
        'specific': '1002&13C0&88771043',
        'dedicatedMemoryMb': 0,
      });
      expect(adapter.memoryLabel, '共享显存');
      expect(adapter.preferred, isFalse);
    });
  });

  test('没枚举到卡时 labelFor 仍看得出选的是哪张', () {
    expect(
      GpuService.instance.labelFor(kGpuAuto),
      '自动（跟随系统）',
      reason: '自动档的文案与平台无关',
    );
    expect(
      GpuService.instance.labelFor(
        adapterIdFor('10DE&2487&145810DE'),
        adapters: const [],
      ),
      '指定显卡（adapter:10DE&2487&145810DE）',
    );
  });

  test('全局与版本覆盖：null 跟随，空串是显式自动', () async {
    final settings = SettingsService();
    await settings.load();
    expect(settings.gpuPreference, kGpuAuto);
    expect(settings.effectiveFor('a').gpuPreference, kGpuAuto);

    settings.gpuPreference = kGpuHighPerformance;
    expect(settings.effectiveFor('a').gpuPreference, kGpuHighPerformance);

    // 版本显式选「自动」= 空串，必须盖过全局，不能被当成「跟随」。
    settings.updateVersionSettings(
      'a',
      VersionSettings(gpuPreference: kGpuAuto),
    );
    expect(settings.effectiveFor('a').gpuPreference, kGpuAuto);

    // 版本没这一键（null）才回落到全局。
    settings.updateVersionSettings(
      'b',
      VersionSettings(gpuPreference: adapterIdFor('1002&73FF&24201458')),
    );
    expect(
      settings.effectiveFor('b').gpuPreference,
      adapterIdFor('1002&73FF&24201458'),
    );
    settings.updateVersionSettings('c', VersionSettings(memoryMb: 2048));
    expect(settings.effectiveFor('c').gpuPreference, kGpuHighPerformance);

    // 落盘 + 重新载入：空串这种「有值但为空」的覆盖也要活得下来。
    final reloaded = SettingsService();
    await reloaded.load();
    expect(reloaded.gpuPreference, kGpuHighPerformance);
    expect(reloaded.settingsFor('a').gpuPreference, kGpuAuto);
    expect(reloaded.effectiveFor('a').gpuPreference, kGpuAuto);
    expect(reloaded.effectiveFor('c').gpuPreference, kGpuHighPerformance);
  });

  test('单独一个显卡覆盖：其余项仍是「未覆盖」', () async {
    final settings = SettingsService();
    await settings.load();
    settings.updateVersionSettings('a', VersionSettings(gpuPreference: 'high'));
    final stored = settings.settingsFor('a');
    expect(stored.isEmpty, isFalse);
    expect(stored.memoryMb, isNull);
    expect(stored.graphicsBackend, isNull);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/download_task.dart';

/// 下载记账的纯逻辑测试。
///
/// 「幽灵下载」的三个可回归点：分母被后一批覆盖、失败文件按成功计数、阶段
/// 进度把条子往回拉。都在这里钉住。
void main() {
  DownloadTask task() => DownloadTask(id: 't', title: '安装 1.20.4');

  group('分批累加', () {
    test('addPlan 累加总量，不清零已完成量', () {
      final t = task()
        ..plan(files: 30, bytes: 1000)
        ..addBytes(1000);
      for (var i = 0; i < 30; i++) {
        t.fileDone('lib$i');
      }
      expect(t.progress, 1.0);

      // 解析完资源索引才发现还要下 1.5 万个文件。
      t.addPlan(files: 15000, bytes: 400000);
      expect(t.totalFiles, 15030);
      expect(t.totalBytes, 401000);
      expect(t.doneFiles, 30);
      // 进度必须掉下来：这才说明「远没下完」。
      expect(t.progress! < 0.01, isTrue, reason: '幽灵完成的假象又回来了');
    });

    test('空批次不改动分母（客户端 jar 已就绪时不刷新）', () {
      final t = task()..plan(files: 10, bytes: 500);
      t.addPlan(files: 0, bytes: 0);
      expect(t.totalFiles, 10);
      expect(t.totalBytes, 500);
    });

    test('addPlan 会清掉阶段进度，让字节数说话', () {
      final t = task()..setPhase(0.9, '解压原生库');
      t.addPlan(files: 100, bytes: 1000);
      expect(t.phaseProgress, isNull);
      expect(t.progress, 0.0);
    });
  });

  group('失败不能冒充完成', () {
    test('fileFailed 与 fileDone 分开计数', () {
      final t = task()..plan(files: 3, bytes: 30);
      t.fileDone('a');
      t.fileFailed('b');
      t.fileDone('c');
      expect(t.doneFiles, 3);
      expect(t.failedFiles, 1);
    });

    test('有失败项时 complete 落成 failed，不给绿勾', () {
      final t = task()..plan(files: 2, bytes: 20);
      t.fileDone('a');
      t.fileFailed('assets/x');
      t.complete();
      expect(t.status, DownloadStatus.failed);
      expect(t.error, contains('1 个文件下载失败'));
    });

    test('全部成功才置 completed', () {
      final t = task()..plan(files: 2, bytes: 20);
      t.fileDone('a');
      t.fileDone('b');
      t.complete();
      expect(t.status, DownloadStatus.completed);
      expect(t.progress, 1.0);
    });
  });

  group('进度只前进', () {
    test('setPhase 不会把条子往回拉', () {
      final t = task();
      t.setPhase(0.6, '下载资源');
      t.setPhase(0.1, '下载资源索引');
      expect(t.phaseProgress, 0.6);
    });

    test('失败尝试的字节数回滚，不虚高', () {
      final t = task()..plan(files: 1, bytes: 100);
      t.addBytes(80);
      expect(t.doneBytes, 80);
      t.undoBytes(80);
      expect(t.doneBytes, 0);
      t.addBytes(100);
      expect(t.progress, 1.0);
      t.undoBytes(500);
      expect(t.doneBytes, 0);
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import 'package:mint/services/download_task.dart';
import 'package:mint/services/launcher/downloader.dart';

/// 半截文件与失败计数的真实回归测试（本地 HTTP，不依赖外网）。
///
/// 「幽灵下载」的两个具体形态都在这里钉住：
///  1. 文件存在但只有半截 —— 以前 `sha1 == null` 直接放行，现在按大小重下；
///  2. 一批里失败的文件 —— 以前和成功一样只 +1，UI 打绿勾，现在单独计数
///     并让任务落成失败。
void main() {
  late HttpServer server;
  late Directory dir;
  late String base;
  final payload = List<int>.generate(4096, (i) => (i * 7) & 0xFF);

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final path = req.uri.path;
      if (path == '/good.bin') {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = payload.length;
        await req.response.addStream(Stream.value(payload));
        await req.response.close();
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    });
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mint_dl');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  DownloadItem item(String name, {String? sha1, int? size}) => DownloadItem(
    url: '$base/$name',
    dest: '${dir.path}/${name.replaceAll('/', '_')}',
    sha1: sha1,
    size: size,
  );

  final sha1OfPayload = crypto.sha1.convert(payload).toString();

  group('半截文件必须重下', () {
    test('sha1 未知时按大小判定：半截 → 重新下载并补全', () async {
      final dl = Downloader(
        mirror: Mirror.official,
        concurrency: 2,
        retries: 1,
      );
      final it = item('good.bin', size: payload.length);
      File(it.dest)
        ..createSync(recursive: true)
        ..writeAsBytesSync(payload.take(1000).toList());
      expect(await dl.fetchFile(it), isTrue, reason: '大小不符应重下');
      expect(File(it.dest).lengthSync(), payload.length);
      dl.close();
    });

    test('sha1 未知且大小对得上：跳过（不重复下载）', () async {
      final dl = Downloader(
        mirror: Mirror.official,
        concurrency: 2,
        retries: 1,
      );
      final it = item('good.bin', size: payload.length);
      File(it.dest)
        ..createSync(recursive: true)
        ..writeAsBytesSync(payload);
      expect(await dl.fetchFile(it), isFalse);
      dl.close();
    });

    test('sha1 已知时半截文件按 hash 不符重下', () async {
      final dl = Downloader(
        mirror: Mirror.official,
        concurrency: 2,
        retries: 1,
      );
      final it = item('good.bin', sha1: sha1OfPayload, size: payload.length);
      File(it.dest)
        ..createSync(recursive: true)
        ..writeAsBytesSync(utf8.encode('truncated'));
      expect(await dl.fetchFile(it), isTrue);
      expect(
        crypto.sha1.convert(File(it.dest).readAsBytesSync()).toString(),
        sha1OfPayload,
      );
      dl.close();
    });
  });

  group('失败要报出来', () {
    test('runBatch 返回失败清单，并把任务标成失败', () async {
      final task = DownloadTask(id: 't', title: '安装');
      final dl = Downloader(
        mirror: Mirror.official,
        concurrency: 2,
        retries: 1,
        task: task,
      );
      final errors = <String>[];
      final result = await dl.runBatch([
        item('good.bin', sha1: sha1OfPayload),
        item('missing.bin'),
      ], onFileError: (file, e) => errors.add(file));
      expect(result.total, 2);
      expect(result.clean, isFalse);
      expect(result.failed.map((f) => f.name), hasLength(1));
      expect(errors, hasLength(1));
      // 进度分母是 2（两批合并后累加），但失败那一项不能算成功。
      expect(task.totalFiles, 2);
      expect(task.doneFiles, 2);
      expect(task.failedFiles, 1);
      task.complete();
      expect(task.status, DownloadStatus.failed);
      dl.close();
    });

    test('全部成功时任务 completed，且字节量不虚高', () async {
      final task = DownloadTask(id: 't2', title: '安装');
      final dl = Downloader(
        mirror: Mirror.official,
        concurrency: 2,
        retries: 1,
        task: task,
      );
      final result = await dl.runBatch([
        item('good.bin', sha1: sha1OfPayload, size: payload.length),
      ]);
      expect(result.clean, isTrue);
      expect(result.downloaded, 1);
      expect(task.failedFiles, 0);
      expect(task.doneBytes, payload.length);
      expect(task.totalBytes, payload.length);
      task.complete();
      expect(task.status, DownloadStatus.completed);
      dl.close();
    });

    test('两批之间的分母累加（第二批才发现要下很多）', () async {
      final task = DownloadTask(id: 't3', title: '安装');
      final dl = Downloader(
        mirror: Mirror.official,
        concurrency: 2,
        retries: 1,
        task: task,
      );
      await dl.runBatch([item('good.bin', sha1: sha1OfPayload)]);
      expect(task.totalFiles, 1);
      await dl.runBatch([item('good2.bin', size: payload.length)]);
      expect(task.totalFiles, 2, reason: 'runBatch 不能覆盖上一批的总量');
      expect(task.doneFiles, 2);
      dl.close();
    });
  });
}

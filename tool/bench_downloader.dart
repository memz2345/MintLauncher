// 小文件下载基准：从已装版本的资源索引取 N 个小文件实测吞吐。
//
//   dart run tool/bench_downloader.dart [count] [concurrency]
//
// 用于对比 PCL2（多线程 + 不逐文件 fsync）的行为，验证 downloader 的
// 小文件优化（flush 移除 / 默认并发提升）。
import 'dart:io';

import 'package:mint/services/launcher/downloader.dart';

Future<void> main(List<String> args) async {
  final count = args.isNotEmpty ? int.tryParse(args[0]) ?? 200 : 200;
  final concurrency = args.length > 1 ? int.tryParse(args[1]) ?? 12 : 12;

  final indexFile = File(r'H:\mctest\assets\indexes\5.json');
  if (!indexFile.existsSync()) {
    stderr.writeln('!! 找不到资源索引 ${indexFile.path}（先装一个 1.20.1）');
    exitCode = 2;
    return;
  }
  final index = indexFile.readAsStringSync();
  final hashRe = RegExp(r'"hash"\s*:\s*"([0-9a-f]{40})"');
  final hashes = hashRe
      .allMatches(index)
      .map((m) => m.group(1)!)
      .take(count)
      .toList();

  final temp = Directory.systemTemp.createTempSync('mint_bench_');
  final items = [
    for (final h in hashes)
      DownloadItem(
        url: 'https://resources.download.minecraft.net/${h.substring(0, 2)}/$h',
        dest: '${temp.path}${Platform.pathSeparator}${h.substring(0, 2)}${Platform.pathSeparator}$h',
        sha1: h,
        name: h.substring(0, 8),
      ),
  ];

  final dl = Downloader(mirror: Mirror.auto, concurrency: concurrency);
  final sw = Stopwatch()..start();
  var failed = 0;
  try {
    await dl.runBatch(items, onFileError: (f, e) { failed++; if (failed <= 3) stdout.writeln('   err: ' + e.toString()); });
  } finally {
    dl.close();
  }
  sw.stop();
  final secs = sw.elapsedMilliseconds / 1000;
  stdout.writeln(
    '== $count 个小文件 · concurrency=$concurrency · ${secs.toStringAsFixed(1)}s'
    ' · ${(count / secs).toStringAsFixed(1)} files/s · 失败 $failed',
  );
  temp.deleteSync(recursive: true);
  exit(0);
}

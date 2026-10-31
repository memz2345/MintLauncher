// 裸 HttpClient 顺序拉 10 个小资源，测每请求延迟（隔离 Downloader 逻辑）。
import 'dart:io';

Future<void> main() async {
  // bmclapi 对根路径无内容，资源走 /assets；失败重试一次看是否偶发。

  final index = File(r'H:\mctest\assets\indexes\5.json').readAsStringSync();
  final hashes = RegExp(r'"hash"\s*:\s*"([0-9a-f]{40})"')
      .allMatches(index)
      .map((m) => m.group(1)!)
      .take(10)
      .toList();
  final client = HttpClient()
    ..userAgent = 'MintLauncher/0.1.0'
    ..connectionTimeout = const Duration(seconds: 30);
  for (final (i, h) in hashes.indexed) {
    final sw = Stopwatch()..start();
    final url = 'https://bmclapi2.bangbang93.com/assets/${h.substring(0, 2)}/$h';
    HttpClientResponse res;
    try {
      final req = await client.getUrl(Uri.parse(url));
      res = await req.close();
    } on Exception catch (e) {
      stdout.writeln('#$i handshake err: $e');
      continue;
    }
    var bytes = 0;
    await for (final c in res) {
      bytes += c.length;
    }
    stdout.writeln(
      '#$i ${res.statusCode} ${bytes}B ${sw.elapsedMilliseconds}ms '
      'keep=${res.persistentConnection}',
    );
  }
  client.close(force: true);
  exit(0);
}

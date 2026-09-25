import 'dart:io';
import '../lib/guard.dart';

Future<void> main() async {
  final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  target.listen((r) {
    if (r.uri.path == '/robots.txt') {
      r.response.statusCode = 404;
    } else {
      r.response.write('OK-FINAL-PAGE');
    }
    r.response.close();
  });
  final hop = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  hop.listen((r) {
    if (r.uri.path == '/robots.txt') {
      r.response.statusCode = 404;
    } else {
      r.response
        ..statusCode = 302
        ..headers.set('Location', 'http://127.0.0.1:${target.port}/final');
    }
    r.response.close();
  });
  // 白名单**包含**两个 host → 正常跳转必须仍然成功
  final wl = DomainWhitelist(['127.0.0.1']);
  final f = Fetcher(
      whitelist: wl,
      robots: RobotsGuard(),
      limiter: RateLimiter(minInterval: Duration.zero));
  final body = await f.getBytes(Uri.parse('http://127.0.0.1:${hop.port}/a'));
  print('白名单内跳转结果: "${String.fromCharCodes(body)}" （期望 OK-FINAL-PAGE）');
  await hop.close(force: true);
  await target.close(force: true);
}

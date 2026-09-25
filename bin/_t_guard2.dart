import 'dart:io';
import '../lib/guard.dart';

Future<void> main() async {
  // ── 限速器并发 ──
  final rl = RateLimiter(minInterval: const Duration(milliseconds: 300));
  final sw = Stopwatch()..start();
  await Future.wait([rl.wait(), rl.wait(), rl.wait()]);
  sw.stop();
  print('限速器 3 并发 wait() = ${sw.elapsedMilliseconds}ms （期望 ≥600ms）');

  // ── 重定向绕白名单 ──
  final evil = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  evil.listen((r) {
    r.response.write('SECRET-FROM-NOT-WHITELISTED-HOST');
    r.response.close();
  });
  final good = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  good.listen((r) {
    r.response
      ..statusCode = 302
      ..headers.set('Location', 'http://127.0.0.1:${evil.port}/x');
    r.response.close();
  });
  // 白名单只有 localhost（不含 127.0.0.1）
  final wl = DomainWhitelist(['localhost']);
  final f = Fetcher(whitelist: wl, robots: RobotsGuard());
  try {
    final body = await f.getBytes(
        Uri.parse('http://localhost:${good.port}/a'));
    print('★ 重定向未被拦：拿到 "${String.fromCharCodes(body)}"');
  } on RankPolicyException catch (e) {
    print('重定向已拦：[${e.code}] ${e.reason}');
  } catch (e) {
    print('其它异常（也算拦住）：$e');
  }
  await evil.close(force: true);
  await good.close(force: true);
}

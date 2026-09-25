import 'dart:io';
import '../lib/guard.dart';

Future<void> main() async {
  // 假站：明确 Disallow: /，且跑在**非默认端口**上（旧代码丢端口必挂）
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  s.listen((r) {
    if (r.uri.path == '/robots.txt') {
      r.response
        ..statusCode = 200
        ..write('User-agent: *\nDisallow: /\n');
    } else {
      r.response.write('PAGE');
    }
    r.response.close();
  });

  final g = RobotsGuard();
  // ★ 关键：带端口访问，旧代码拼 robots URL 会丢掉 :port → 连接失败 → 误判为允许
  final u = Uri.parse('http://127.0.0.1:$port/rank/x');
  final allowed = await g.isAllowed(u);
  print('端口保留后 robots 判定: allowed=$allowed  （期望 false）');
  print('verdict: ${await g.verdict(u)}');

  // 404 = 真的没有 → 允许，且文本如实说 404
  final s2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s2.listen((r) {
    r.response.statusCode = 404;
    r.response.close();
  });
  final g2 = RobotsGuard();
  final u2 = Uri.parse('http://127.0.0.1:${s2.port}/a');
  print('404 时: allowed=${await g2.isAllowed(u2)} verdict=${await g2.verdict(u2)}');

  // 403 = 拿不到 → 不再谎报"无 robots.txt"
  final s3 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s3.listen((r) {
    r.response.statusCode = 403;
    r.response.close();
  });
  final g3 = RobotsGuard();
  final u3 = Uri.parse('http://127.0.0.1:${s3.port}/a');
  print('403 时: verdict=${await g3.verdict(u3)}');

  await s.close(force: true);
  await s2.close(force: true);
  await s3.close(force: true);
}

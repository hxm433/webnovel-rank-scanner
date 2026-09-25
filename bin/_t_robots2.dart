import 'dart:io';
import '../lib/guard.dart';

Future<void> main() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  s.listen((r) {
    if (r.uri.path == '/robots.txt') {
      r.response.write(
        'User-agent: *\nAllow: /\n\n'
        'User-agent: rankscan-demo\nDisallow: /\n');
    } else {
      r.response.write('PAGE');
    }
    r.response.close();
  });
  final g = RobotsGuard();
  final u = Uri.parse('http://127.0.0.1:$port/other');
  print('专供 rankscan-demo 的 Disallow:/ → allowed=${await g.isAllowed(u)} （期望 false）');
  print('verdict: ${await g.verdict(u)}');
  // 对照：换个 agentToken 应走 * 组 → 允许
  final g2 = RobotsGuard(agentToken: 'someone-else');
  print('换 agentToken → allowed=${await g2.isAllowed(u)} （期望 true）');
  await s.close(force: true);
}

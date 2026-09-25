import 'dart:convert';
import 'dart:io';

const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';

String esc(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    sb.write(r < 128 ? String.fromCharCode(r) : '?');
  }
  return sb.toString().replaceAll(RegExp(r'\s+'), ' ');
}

Future<void> probe(String label, Uri url,
    {Map<String, String>? headers, bool follow = true}) async {
  final client = HttpClient();
  final req = await client.getUrl(url);
  req.maxRedirects = follow ? 5 : 0;
  (headers ?? const <String, String>{}).forEach((k, v) => req.headers.set(k, v));
  final resp = await req.close().timeout(const Duration(seconds: 25));
  final bytes = <int>[];
  await for (final c in resp) {
    bytes.addAll(c);
  }
  final body = utf8.decode(bytes, allowMalformed: true);
  stdout.writeln('$label status=${resp.statusCode} bytes=${bytes.length} '
      'loc=${resp.headers.value('location')} '
      'ctype=${resp.headers.value('content-type')} '
      'enc=${resp.headers.value('content-encoding')}');
  stdout.writeln('   head=${esc(body.substring(0, body.length < 300 ? body.length : 300))}');
  client.close(force: true);
}

Future<void> main() async {
  final u = Uri.parse('https://m.qidian.com/rank/yuepiao/catid21/');
  await probe('A ua-only          ', u, headers: {'user-agent': ua});
  await probe('B +accept          ', u,
      headers: {'user-agent': ua, 'accept': 'text/html,application/json'});
  await probe('C +accept-language ', u, headers: {
    'user-agent': ua,
    'accept': 'text/html,application/json',
    'accept-language': 'zh-CN,zh;q=0.9',
  });
  await probe('D +referer         ', u, headers: {
    'user-agent': ua,
    'accept': 'text/html,application/json',
    'accept-language': 'zh-CN,zh;q=0.9',
    'referer': 'https://m.qidian.com/rank/',
  });
  await probe('E nofollow         ', u, headers: {'user-agent': ua}, follow: false);
  await probe('F plain /rank/     ', Uri.parse('https://m.qidian.com/rank/'),
      headers: {'user-agent': ua});
}

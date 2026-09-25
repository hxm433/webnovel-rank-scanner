/// 起点 www 站**真实端到端**测试（会真的启动浏览器、真的打网络）。
///
/// 与 `_t_qidian_parse.dart`（离线喂夹具）互补：这个验证
/// 「渲染抓取器 + 多页循环 + 字体解码 + limit 截断」整条链路。
///
/// 运行：dart run bin/_t_qidian_e2e.dart [页数]
library;

import 'dart:io';

import '../lib/guard.dart';
import '../lib/models.dart';
import '../lib/sources.dart';
import '../lib/webview_fetcher.dart';

void main(List<String> args) {
  final limit = int.tryParse(args.isNotEmpty ? args[0] : '') ?? 45;
  stdout.writeln('== 起点真实端到端（目标 $limit 条，约 ${(limit / 20).ceil()} 页）==');

  final wl = DomainWhitelist(const ['www.qidian.com', 'qidian.com', 'm.qidian.com']);
  final renderer = WebViewFetcher(
      whitelist: wl,
      robots: RobotsGuard(),
      limiter: RateLimiter(minInterval: const Duration(milliseconds: 300)));
  stdout.writeln('浏览器内核：${renderer.exePath ?? '（未找到）'}');
  stdout.writeln('WebView2 Runtime：${renderer.webView2Version() ?? '（未装）'}');
  if (!renderer.available) {
    stdout.writeln('❌ 没有可用浏览器内核，无法测 www 站路径');
    exit(1);
  }

  final src = QidianSource(
    Fetcher(whitelist: wl, robots: RobotsGuard()),
    renderer: renderer,
  );

  final sw = Stopwatch()..start();
  src.fetch(RankQuery(source: 'qidian', board: '月票榜', limit: limit)).then((out) {
    sw.stop();
    stdout.writeln('\n耗时 ${sw.elapsed.inSeconds}s');
    stdout.writeln('质量：${out.quality.summary}');
    if (out.quality.problems.isNotEmpty) {
      stdout.writeln('问题：${out.quality.problems.join(' / ')}');
    }
    stdout.writeln('URL：${out.url}');
    stdout.writeln('\n抓到 ${out.entries.length} 条：');
    for (final e in out.entries.take(8)) {
      stdout.writeln('  #${e.rank} ${e.title} / ${e.author} / ${e.category}'
          ' / 月票=${e.metrics['monthticket'] ?? '-'}');
    }
    if (out.entries.length > 8) {
      stdout.writeln('  …（中略）');
      for (final e in out.entries.skip(out.entries.length - 3)) {
        stdout.writeln('  #${e.rank} ${e.title} / 月票=${e.metrics['monthticket'] ?? '-'}');
      }
    }
    // 断言
    var ok = true;
    if (out.entries.length != limit) {
      stdout.writeln('\n⚠️ 条数 ${out.entries.length} != 目标 $limit');
      ok = false;
    }
    final ranks = [for (final e in out.entries) e.rank];
    if (ranks.first != 1 || ranks.last != out.entries.length) {
      stdout.writeln('⚠️ 排名不连续：${ranks.first}..${ranks.last}');
      ok = false;
    }
    final withMetric = out.entries.where((e) => e.metrics.containsKey('monthticket')).length;
    stdout.writeln('\n带月票指标的：$withMetric / ${out.entries.length}');
    if (withMetric != out.entries.length) {
      stdout.writeln('⚠️ 有条目缺指标（字体未解出）');
      ok = false;
    }
    // 排名跨页也应有值
    stdout.writeln(ok ? '\n✅ 真实端到端通过' : '\n❌ 真实端到端有问题');
    exit(ok ? 0 : 1);
  }).catchError((Object e) {
    stdout.writeln('❌ 异常：$e');
    exit(1);
  });
}

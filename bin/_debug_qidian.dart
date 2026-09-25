import 'dart:convert';
import 'dart:io';

import '../lib/guard.dart';
import '../lib/sources.dart';
import '../lib/models.dart';

Future<void> main() async {
  final url = Uri.parse('https://m.qidian.com/rank/yuepiao/catid21/');
  final f = Fetcher(
    whitelist: DomainWhitelist(const ['m.qidian.com', 'qidian.com']),
    robots: RobotsGuard(),
  );
  final html = await f.getString(url);
  stdout.writeln('bytes=${html.length} hasMarker=${html.contains('pageContext')} '
      'hasRecords=${html.contains('"records"')}');

  final raw = EmbeddedJson.byIdContaining(html, 'pageContext');
  stdout.writeln('byIdContaining -> ${raw == null ? 'NULL' : 'len=${raw.length}'}');
  if (raw != null) {
    try {
      final d = jsonDecode(raw);
      final pd = (((d as Map)['pageContext'] as Map)['pageProps'] as Map)['pageData'];
      stdout.writeln('pageData type=${pd.runtimeType}');
      if (pd is Map) {
        final recs = pd['records'];
        stdout.writeln('records=${recs.runtimeType} n=${recs is List ? recs.length : -1} '
            'total=${pd['total']}');
      }
    } on Object catch (e) {
      stdout.writeln('decode fail: $e');
    }
  }

  final q = RankQuery(source: 'qidian', board: '月票榜', categoryName: '玄幻', limit: 20);
  final src = QidianSource(f);
  final out = await src.fetch(q);
  stdout.writeln('source.fetch entries=${out.entries.length} '
      'quality=${out.quality.validCount}/${out.quality.totalCount}');
  stdout.writeln('summary=${jsonEncode(out.quality.summary)}');
  stdout.writeln('problems=${jsonEncode(out.quality.problems)}');
  for (final e in out.entries.take(3)) {
    stdout.writeln('  #${e.rank} ${jsonEncode(e.title)} ${jsonEncode(e.metrics)}');
  }
}

/// 番茄字体反爬解码探针（一次性验证用，保留备查）。
///
/// 读 `out/扫榜/fanqie/*.json` 里那些**还是混淆态**的历史快照，
/// 用 [decodeFanqiePua] 现解一遍并写出 UTF-8 报告 —— 这样就能拿
/// 书名去和 `fanqienovel.com/page/<bookId>` 的明文逐字核。
///
/// 注意：快照文件本身不会被改写（只读），产物写 `out/reports/fanqie_decode.txt`。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/fanqie_font.dart';
import '../lib/models.dart';

void main(List<String> args) {
  final dir = Directory('out/扫榜/fanqie');
  if (!dir.existsSync()) {
    stderr.writeln('no snapshot dir: ${dir.path}');
    exit(2);
  }
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final out = StringBuffer();
  var total = 0, obfBefore = 0, obfAfter = 0, unknownCps = <int>{};
  for (final f in files) {
    final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    final res = (j['result'] as Map).cast<String, Object?>();
    final entries = RankResult.fromJson(res).entries;
    out.writeln('## ${f.uri.pathSegments.last}');
    for (final e in entries) {
      total++;
      final rawTitle = e.title;
      // 快照里存的可能已经是解码后的，也可能不是：两种情况都过一遍同函数。
      final title = decodeFanqiePua(rawTitle);
      final author = decodeFanqiePua(e.author);
      if (privateUseCount(rawTitle) > 0) obfBefore++;
      if (privateUseCount(title) > 0) {
        obfAfter++;
        for (final r in title.runes) {
          if (r >= 0xE000 && r <= 0xF8FF) unknownCps.add(r);
        }
      }
      out.writeln('${e.rank}\t$title\t$author\t${e.bookId}\t'
          '${privateUseCount(title) > 0 ? 'STILL-OBF' : 'ok'}');
    }
    out.writeln();
  }
  final report = File('out/reports/fanqie_decode.txt')..createSync(recursive: true);
  report.writeAsStringSync(out.toString(), flush: true);
  stdout.writeln('entries=$total  rawObf=$obfBefore  stillObf=$obfAfter  '
      'unknownCps=${unknownCps.map((c) => c.toRadixString(16)).toList()}  '
      'wrote=${report.path}');
}

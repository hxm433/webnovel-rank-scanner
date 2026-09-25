/// 一次性核对：七猫/番茄的书籍页里，抠出来的封面是不是**这本书**的。
library;
import 'dart:io';
import '../lib/cover_store.dart';

Future<void> main() async {
  final store = CoverStore(root: 'build/_covprobe');
  for (final (src, id) in [('qimao', '1879266'), ('fanqie', '7667802587961248793')]) {
    final url = coverPageUrl[src]!.replaceAll('{id}', id);
    stdout.writeln('[$src] 书页 $url');
    final r = await store.fetchPageForTest(url);
    if (r.isEmpty) { stdout.writeln('  页面取不到'); continue; }
    final html = String.fromCharCodes(r);
    final noId = extractCoverFromPage(src, html);
    final withId = extractCoverFromPage(src, html, bookId: id);
    stdout.writeln('  页面 ${r.length} 字节');
    stdout.writeln('  不传 bookId → ${noId ?? "null"}');
    stdout.writeln('  传 bookId   → ${withId ?? "null"}');
    stdout.writeln('  ★ 含本书 id? ${withId != null && withId.contains(id)}');
  }
}

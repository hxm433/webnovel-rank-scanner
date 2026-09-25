import 'dart:io';
import '../lib/store.dart';
import '../lib/models.dart';

void main() {
  final s = RankStore(root: r'C:/tmp/_t_store');
  final d = DateTime(2026, 9, 24);
  String p(RankQuery q) => s.pathFor(q, d).split(Platform.pathSeparator).last;

  // ① 同一天不同题材不再互相覆盖
  final a = p(RankQuery(source: 'qidian', board: '畅销榜', categoryId: '21', categoryName: '玄幻'));
  final b = p(RankQuery(source: 'qidian', board: '畅销榜', categoryId: '4', categoryName: '都市'));
  print('畅销榜·玄幻 → $a');
  print('畅销榜·都市 → $b');
  print('  区分开？ ${a != b}');

  // ② 全站 与 null 归一成同一个文件
  final c = p(RankQuery(source: 'qidian', board: '月票榜', categoryName: '全站'));
  final e = p(RankQuery(source: 'qidian', board: '月票榜', categoryName: null));
  print('月票榜·全站 → $c');
  print('月票榜(null) → $e');
  print('  归一？ ${c == e}');

  // ③ 穿越与保留名
  final f = p(RankQuery(source: '..', board: 'CON', categoryName: 'aux.'));
  print('穿越/保留名 → $f');
  print('  不含 ..？ ${!f.contains('..')}  非CON开头？ ${!f.toUpperCase().startsWith('CON')}');
}

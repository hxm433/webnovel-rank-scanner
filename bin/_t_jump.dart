import '../lib/analysis.dart';
import '../lib/models.dart';

/// books: (书名, 名次, 指标)。书名是跨快照的主键，必须保持稳定。
RankResult mk(List<(String, int, num?)> rows) => RankResult(
      query: const RankQuery(source: 'qidian', board: 'x'),
      fetchedAt: DateTime(2026, 9, 24),
      entries: [
        for (final r in rows)
          RankEntry(
              rank: r.$2,
              title: r.$1,
              author: 'A',
              metrics: {if (r.$3 != null) 'monthticket': r.$3!})
      ],
    );

void main() {
  // 甲 跌 1 名，乙 跌 3 名 → "下降最快"应把乙排在甲前面，且两者都是负分
  final prev = mk([('甲', 1, 100), ('乙', 5, 100)]);
  final curr = mk([('甲', 2, 100), ('乙', 8, 100)]);
  final a = const RankAnalyzer().analyze(curr, previous: prev);
  for (final t in a.trends) {
    print('${t.title}: chg=${t.rankChange} jump=${t.jumpScore.toStringAsFixed(1)}');
  }
  final falling = a.trends
      .where((t) => !t.isNew && (t.rankChange ?? 0) < 0)
      .toList()
    ..sort((x, y) => x.jumpScore.compareTo(y.jumpScore));
  print('下降最快排序: ${falling.map((t) => '${t.title}(${t.rankChange})').join('、')}');
  print('  期望 乙(-3) 在 甲(-1) 之前 → ${falling.first.title == '乙'}');
  print('  下降为负分 → ${falling.first.jumpScore < 0}');

  // 上升仍得正分、排序正确
  final prev2 = mk([('丙', 5, 100), ('丁', 6, 100)]);
  final curr2 = mk([('丙', 1, 100), ('丁', 3, 100)]);
  final a2 = const RankAnalyzer().analyze(curr2, previous: prev2);
  final rising = a2.trends
      .where((t) => (t.rankChange ?? 0) > 0)
      .toList()
    ..sort((x, y) => y.jumpScore.compareTo(x.jumpScore));
  print('上升最快: ${rising.map((t) => '${t.title}(+${t.rankChange})'
      ' jump=${t.jumpScore.toStringAsFixed(0)}').join('、')}');
  print('  期望 丙(+4) 排第一 → ${rising.first.title == '丙'}');
  print('  上升得正分 → ${rising.first.jumpScore > 0}');

  // ★ 反向验证：旧公式（clamp 到 0）会让所有下降书都是 0.0，
  //   排序退化成"原顺序"。这里用两个跌幅不同的书证明现在能区分。
  final a3 = const RankAnalyzer().analyze(curr, previous: prev);
  final scores = {for (final t in a3.trends) t.title: t.jumpScore};
  print('跌幅不同 → 分数不同？ ${scores['甲'] != scores['乙']} '
      '（旧实现两者都是 0.0）');
}

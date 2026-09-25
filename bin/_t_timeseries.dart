/// 时间序列回归（第 8 轮 P2）：跨期对比 / 轨迹补全 / 变化分组 / 边界。
///
/// 运行：dart run bin/_t_timeseries.dart
library;

import 'dart:io';

import '../lib/models.dart';
import '../lib/snapshot_index_file.dart';
import '../lib/timeseries.dart';

int _pass = 0;
int _fail = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✅ $name');
  } else {
    _fail++;
    stdout.writeln('  ❌ $name${detail == null ? '' : ' — $detail'}');
  }
}

/// 造一份快照：`[书名, 名次, 字数, 指标]`。
RankResult _mk(
  String source,
  String board,
  DateTime at,
  List<(String id, String title, int rank, int words, num metric)> rows, {
  String? catName,
  String? catId,
}) {
  return RankResult(
    query: RankQuery(
        source: source,
        board: board,
        limit: rows.length,
        categoryName: catName,
        categoryId: catId),
    entries: [
      for (final r in rows)
        RankEntry(
          rank: r.$3,
          title: r.$2,
          author: '作者',
          bookId: r.$1,
          metrics: {'words': r.$4, 'monthticket': r.$5},
        )
    ],
    fetchedAt: at,
  );
}

IndexEntry _ie(String source, String board, DateTime at, int count,
        {String? catName, String? catId}) =>
    IndexEntry(
      id: '${source}|$board|${catName ?? '-'}|'
          '${at.year}${at.month.toString().padLeft(2, '0')}${at.day.toString().padLeft(2, '0')}',
      source: source,
      board: board,
      category: catName,
      categoryId: catId,
      dateKey: '${at.year}${at.month.toString().padLeft(2, '0')}'
          '${at.day.toString().padLeft(2, '0')}',
      fetchedAt: at,
      count: count,
      ok: true,
      relFile: '扫榜/$source/$board.json',
    );

void main() {
  stdout.writeln('== 时间序列回归：跨期对比 / 轨迹 / 变化分组 ==');

  // ── ① 基本装配：三期，A 一路上升 ──
  stdout.writeln('\n── ① 基本装配（三期）──');
  final d1 = DateTime(2026, 9, 22);
  final d2 = DateTime(2026, 9, 23);
  final d3 = DateTime(2026, 9, 24);
  final r1 = _mk('qidian', '月票榜', d1, [
    ('a', '甲', 5, 100000, 100),
    ('b', '乙', 3, 200000, 200),
    ('c', '丙', 8, 50000, 50),
  ]);
  final r2 = _mk('qidian', '月票榜', d2, [
    ('a', '甲', 3, 120000, 150),
    ('b', '乙', 6, 210000, 180),
    ('c', '丙', 9, 60000, 55),
  ]);
  final r3 = _mk('qidian', '月票榜', d3, [
    ('a', '甲', 1, 150000, 300),
    ('b', '乙', 7, 220000, 170),
    ('c', '丙', 10, 70000, 60),
  ]);
  final entries = [
    _ie('qidian', '月票榜', d1, 3),
    _ie('qidian', '月票榜', d2, 3),
    _ie('qidian', '月票榜', d3, 3),
  ];
  final results = {
    entries[0].id: r1,
    entries[1].id: r2,
    entries[2].id: r3,
  };
  final ts = buildTimeSeries(entries, results);
  _check('期数 = 3', ts.periodCount == 3, 'got ${ts.periodCount}');
  _check('区间标签正确', ts.rangeLabel == '2026-09-22 → 2026-09-24', ts.rangeLabel);
  _check('识别到 3 本书轨迹', ts.tracks.length == 3, 'got ${ts.tracks.length}');
  _check('系列键 = qidian|月票榜|-', ts.seriesKey == 'qidian|月票榜|-', ts.seriesKey);

  final a = ts.tracks.firstWhere((t) => t.title == '甲');
  _check('甲 轨迹 = 5→3→1', a.points.map((p) => p.rank).join(',') == '5,3,1',
      a.points.map((p) => p.rank).join(','));
  _check('甲 最新名次 = 1', a.lastRank == 1, 'got ${a.lastRank}');
  _check('甲 相对上期上升 +2', a.latestRankChange == 2, 'got ${a.latestRankChange}');
  _check('甲 相对首次上升 +4', a.sinceFirstRankChange == 4, 'got ${a.sinceFirstRankChange}');
  _check('甲 连续上升 2 期', a.streakUp == 2, 'got ${a.streakUp}');
  _check('甲 无连续下降', a.streakDown == 0, 'got ${a.streakDown}');
  _check('甲 相对上期字数 +30000', a.latestWordsChange == 30000,
      'got ${a.latestWordsChange}');
  _check('甲 相对上期指标 +150', a.latestMetricChange == 150,
      'got ${a.latestMetricChange}');
  _check('甲 全期在榜', a.listedPeriods == 3, 'got ${a.listedPeriods}');

  final b = ts.tracks.firstWhere((t) => t.title == '乙');
  _check('乙 连续下降 2 期', b.streakDown == 2, 'got ${b.streakDown}');
  _check('乙 相对上期下降 -1', b.latestRankChange == -1, 'got ${b.latestRankChange}');

  // ── ② 变化分组（最新一期 vs 上一期）──
  stdout.writeln('\n── ② 变化分组 ──');
  _check('上升组含甲', ts.movers.up.any((m) => m.track.title == '甲'));
  _check('下降组含乙、丙', ts.movers.down.length == 2, 'got ${ts.movers.down.length}');
  _check('上升最快 = 甲（+2）',
      ts.movers.up.isNotEmpty && ts.movers.up.first.change == 2,
      ts.movers.up.isEmpty ? '(空)' : '${ts.movers.up.first.change}');
  _check('下降最快 = 丙（-1）',
      ts.movers.down.isNotEmpty && ts.movers.down.first.change == -1,
      ts.movers.down.isEmpty ? '(空)' : '${ts.movers.down.first.change}');
  _check('无新上榜', ts.movers.freshCount == 0, 'got ${ts.movers.freshCount}');
  _check('无掉榜', ts.movers.goneCount == 0, 'got ${ts.movers.goneCount}');

  // ── ③ 新上榜 / 掉榜 / 中途掉榜（轨迹补全）──
  stdout.writeln('\n── ③ 新上 / 掉榜 / 中途掉榜 ──');
  final e1 = _ie('qidian', '畅销榜', d1, 3);
  final e2 = _ie('qidian', '畅销榜', d2, 3);
  final e3 = _ie('qidian', '畅销榜', d3, 2);
  final s1 = _mk('qidian', '畅销榜', d1, [
    ('p', 'P', 1, 100, 10),
    ('q', 'Q', 2, 100, 10),
    ('r', 'R', 3, 100, 10),
  ]);
  // P 掉出榜，R 掉出榜，Z 新进榜
  final s2 = _mk('qidian', '畅销榜', d2, [
    ('p', 'P', 5, 100, 10),
    ('q', 'Q', 4, 100, 10),
    ('z', 'Z', 2, 100, 10),
  ]);
  // P 又掉，Q 在榜，Z 在榜
  final s3 = _mk('qidian', '畅销榜', d3, [
    ('q', 'Q', 1, 100, 10),
    ('z', 'Z', 3, 100, 10),
  ]);
  final ts2 = buildTimeSeries([e1, e2, e3], {e1.id: s1, e2.id: s2, e3.id: s3});

  final p = ts2.tracks.firstWhere((t) => t.title == 'P');
  _check('P 轨迹 = 1→5→—（中途掉榜补 0）',
      p.points.map((x) => x.rank).join(',') == '1,5,0',
      p.points.map((x) => x.rank).join(','));
  _check('P 最新一期未上榜', !p.listedNow);
  _check('P 掉榜后 latestRankChange = null（不算出伪变化）',
      p.latestRankChange == null, 'got ${p.latestRankChange}');
  _check('P 连续下降 2 期（跌完接着掉榜，掉榜算下降的延续）', p.streakDown == 2,
      'got ${p.streakDown}');

  final z = ts2.tracks.firstWhere((t) => t.title == 'Z');
  _check('Z 轨迹 = —→2→3（首期未上榜补 0）',
      z.points.map((x) => x.rank).join(',') == '0,2,3',
      z.points.map((x) => x.rank).join(','));
  _check('Z 最新一期在榜', z.listedNow);
  _check('Z 只在最后一期下降 → 连续下降 1 期（新上榜算上升、把前面断掉）',
      z.streakDown == 1, 'got ${z.streakDown}');
  _check('Z 相对首次上榜是跌的（2→3）', z.sinceFirstRankChange == -1,
      'got ${z.sinceFirstRankChange}');

  _check('掉榜组含 P', ts2.movers.gone.any((m) => m.track.title == 'P'));
  _check('掉榜组不含 R（首期后就没上过）',
      !ts2.movers.gone.any((m) => m.track.title == 'R'));
  _check('掉榜组数量 = 1', ts2.movers.goneCount == 1, 'got ${ts2.movers.goneCount}');
  _check('新上榜组：最新期在榜且此前全未上榜 → 不含 Z（Z 第 2 期就在了）',
      ts2.movers.freshCount == 0, 'got ${ts2.movers.freshCount}');

  // 真正的"最新期才上榜"
  final e4 = _ie('qidian', '新书榜', d1, 1);
  final e5 = _ie('qidian', '新书榜', d2, 2);
  final t1 = _mk('qidian', '新书榜', d1, [('m', 'M', 1, 100, 10)]);
  final t2 = _mk('qidian', '新书榜', d2, [
    ('m', 'M', 2, 100, 10),
    ('n', 'N', 1, 100, 10),
  ]);
  final ts3 = buildTimeSeries([e4, e5], {e4.id: t1, e5.id: t2});
  _check('新上榜组含 N', ts3.movers.fresh.any((m) => m.track.title == 'N'));
  _check('新上榜组数量 = 1', ts3.movers.freshCount == 1, 'got ${ts3.movers.freshCount}');
  _check('N 即新上榜（listedPeriods=1）',
      ts3.tracks.firstWhere((t) => t.title == 'N').listedPeriods == 1);

  // ── ④ 全期在榜 / 首发即掉 / 单期 ──
  stdout.writeln('\n── ④ 常驻 / 边界 ──');
  _check('甲为常驻（3/3 期）', ts.evergreens.any((t) => t.title == '甲'));
  _check('常驻数量 = 3（甲乙丙）', ts.evergreens.length == 3,
      'got ${ts.evergreens.length}');

  // 只有一期的序列：不能崩、不能算出变化、且提示"无可比"
  final one = buildTimeSeries([entries[2]], {entries[2].id: r3});
  _check('单期：hasComparison = false', !one.hasComparison);
  _check('单期：periodCount = 1', one.periodCount == 1, 'got ${one.periodCount}');
  _check('单期：区间标签为单日', one.rangeLabel == '2026-09-24', one.rangeLabel);
  _check('单期：变化分组全空',
      one.movers.upCount == 0 &&
          one.movers.downCount == 0 &&
          one.movers.freshCount == 0 &&
          one.movers.goneCount == 0);
  final oneA = one.tracks.firstWhere((t) => t.title == '甲');
  _check('单期：latestRankChange = null', oneA.latestRankChange == null);
  _check('单期：streakUp = 0', oneA.streakUp == 0);

  // 空序列
  final empty = buildTimeSeries(const [], const {});
  _check('空序列：periodCount = 0', empty.periodCount == 0);
  _check('空序列：rangeLabel = —', empty.rangeLabel == '—', empty.rangeLabel);
  _check('空序列：latestCount = 0', empty.latestCount == 0);

  // ── ⑤ 缺数据要记录，不静默少一期 ──
  stdout.writeln('\n── ⑤ 缺数据如实报告 ──');
  final errs = <String>[];
  final partial = buildTimeSeries(entries, {
    entries[0].id: r1,
    // entries[1].id 故意不给
    entries[2].id: r3,
  }, errors: errs);
  _check('缺数据的期被跳过（2 期）', partial.periodCount == 2,
      'got ${partial.periodCount}');
  _check('跳过有记录（非静默）', errs.any((e) => e.contains('数据缺失')), 'errs=$errs');

  // ── ⑥ 排序：按在榜期数 + 最新名次 ──
  stdout.writeln('\n── ⑥ 轨迹排序 ──');
  _check('首条是在榜期数最多的', ts.tracks.first.listedPeriods == 3);
  _check('同全期在榜时，最新名次靠前的在前',
      ts.tracks.map((t) => t.lastRank).toList().join(',') == '1,7,10',
      ts.tracks.map((t) => t.lastRank).toList().join(','));

  // ── ⑦ 汇总数字 ──
  stdout.writeln('\n── ⑦ 汇总数字 ──');
  _check('首期上榜数 = 3', ts.firstCount == 3, 'got ${ts.firstCount}');
  _check('最新期上榜数 = 3', ts.latestCount == 3, 'got ${ts.latestCount}');
  _check('首期总字数 = 350000', ts.firstTotalWords == 350000,
      'got ${ts.firstTotalWords}');
  _check('最新期总字数 = 440000', ts.latestTotalWords == 440000,
      'got ${ts.latestTotalWords}');
  _check('各期上榜数序列', ts.countSeries.join(',') == '3,3,3',
      ts.countSeries.join(','));

  // ── ⑧ 指标键识别 + 文本工具 ──
  stdout.writeln('\n── ⑧ 指标键 / 文本工具 ──');
  _check('dominantMetricKey = monthticket', dominantMetricKey(ts) == 'monthticket',
      '${dominantMetricKey(ts)}');
  _check('metricLabel(monthticket) = 月票', metricLabel('monthticket') == '月票');
  _check('metricLabel(null) = 指标', metricLabel(null) == '指标');
  _check('signedInt(3) = +3', signedInt(3) == '+3');
  _check('signedInt(-5) = -5', signedInt(-5) == '-5');
  _check('groupedInt(1234567)', groupedInt(1234567) == '1,234,567',
      groupedInt(1234567));
  _check('groupedInt(999)', groupedInt(999) == '999', groupedInt(999));
  _check('wanText(150000) = 15.0万', wanText(150000) == '15.0万', wanText(150000));
  _check('rankTrail 甲 = #5 → #3 → #1',
      rankTrail(a) == '#5 → #3 → #1', rankTrail(a));
  _check('rankTrail 限 2 期 = #3 → #1', rankTrail(a, maxPeriods: 2) == '#3 → #1',
      rankTrail(a, maxPeriods: 2));
  _check('rankTrail P 含掉榜破折号',
      rankTrail(p) == '#1 → #5 → —', rankTrail(p));

  // ── ⑨ 稳定排序与同分处理 ──
  stdout.writeln('\n── ⑨ 稳定性 ──');
  final stable1 = buildTimeSeries(entries, results);
  final stable2 = buildTimeSeries(entries.reversed.toList(), results);
  _check('输入顺序不影响输出（按期排序）',
      stable1.points.map((p) => p.dateKey).join(',') ==
          stable2.points.map((p) => p.dateKey).join(','),
      '${stable2.points.map((p) => p.dateKey).join(',')}');
  _check('时序为旧→新',
      stable1.points.first.dateKey == '20260922' &&
          stable1.points.last.dateKey == '20260924',
      '${stable1.points.map((p) => p.dateKey).join(',')}');

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

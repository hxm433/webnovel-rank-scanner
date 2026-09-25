/// 全链路编译冒烟 + 时间序列端到端（离线，不开窗）。
library;

import 'dart:io';

import '../lib/models.dart';
import '../lib/snapshot_index.dart';
import '../lib/snapshot_index_file.dart';
import '../lib/timeseries.dart';
import '../lib/ui/chart.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/view_model.dart';

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

void main() {
  stdout.writeln('== P2 端到端：meta→entry 桥接 / 区间档位 / 时间线装配 ==');

  // ── ① SnapshotMeta → IndexEntry 桥接 ──
  stdout.writeln('\n── ① 桥接 ──');
  RankResult mk(String board, DateTime at, int n, {String? cat, String? cid}) {
    return RankResult(
      query: RankQuery(
          source: 'qidian', board: board, limit: n, categoryName: cat, categoryId: cid),
      entries: [
        for (var i = 1; i <= n; i++)
          RankEntry(
              rank: i,
              title: '书$i',
              author: 'a',
              bookId: 'b$i',
              metrics: const {'words': 100, 'monthticket': 1}),
      ],
      fetchedAt: at,
    );
  }

  final tmp = Directory.systemTemp.createTempSync('p2_e2e_').path;
  final f = File('$tmp/x.json')..createSync(recursive: true);
  f.writeAsStringSync('{}');

  final meta = SnapshotMeta(
    id: 1,
    file: f,
    result: mk('月票榜', DateTime(2026, 9, 24), 5),
  );
  final e = metaToEntry(meta);
  _check('id 含日期', e.id.endsWith('20260924'), e.id);
  _check('id 口径 = source|board|cat|date',
      e.id == 'qidian|月票榜|-|20260924', e.id);
  _check('dateKey = 20260924', e.dateKey == '20260924', e.dateKey);
  _check('count 与 result 一致', e.count == 5, 'got ${e.count}');

  // 全站要归一到 null
  final meta2 = SnapshotMeta(
    id: 2,
    file: f,
    result: mk('月票榜', DateTime(2026, 9, 24), 5, cat: '全站', cid: '-1'),
  );
  _check('"全站"归一到 null', metaToEntry(meta2).category == null);
  _check('catId "-1" 归一到 null', metaToEntry(meta2).categoryId == null);
  _check('全站与空 id 相同', metaToEntry(meta2).id == e.id, metaToEntry(meta2).id);

  // 去重
  final metas = <SnapshotMeta>[meta, meta2];
  final dedup = metasToEntries(metas);
  _check('同 id 去重（2→1）', dedup.length == 1, 'got ${dedup.length}');

  // ── ② 区间档位 ──
  stdout.writeln('\n── ② 区间档位 ──');
  final many = <IndexEntry>[
    for (var d = 1; d <= 40; d++)
      IndexEntry(
        id: 'qidian|月票榜|-|202609${d.toString().padLeft(2, '0')}',
        source: 'qidian',
        board: '月票榜',
        dateKey: '202609${d.toString().padLeft(2, '0')}',
        fetchedAt: DateTime(2026, 9, d),
        count: 5,
        ok: true,
        relFile: 'x',
      )
  ];
  _check('近 7 期 → 取尾部 7 条', TimeRange.last7.apply(many).length == 7,
      'got ${TimeRange.last7.apply(many).length}');
  _check('近 7 期是**最新的** 7 条',
      TimeRange.last7.apply(many).last.dateKey == '20260940',
      TimeRange.last7.apply(many).last.dateKey);
  _check('近 7 期第一条 = 34', TimeRange.last7.apply(many).first.dateKey == '20260934',
      TimeRange.last7.apply(many).first.dateKey);
  _check('近 30 期 → 30 条', TimeRange.last30.apply(many).length == 30);
  _check('全部 → 40 条', TimeRange.all.apply(many).length == 40);
  _check('不足 7 期时原样返回',
      TimeRange.last7.apply(many.take(3).toList()).length == 3);

  // ── ③ 时间线端到端（用桥接后的条目装配）──
  stdout.writeln('\n── ③ 时间线端到端 ──');
  RankResult r1 = mk('月票榜', DateTime(2026, 9, 1), 3);
  final r2 = RankResult(
    query: const RankQuery(source: 'qidian', board: '月票榜', limit: 3),
    entries: [
      RankEntry(rank: 3, title: '书1', author: 'a', bookId: 'b1',
          metrics: const {'words': 100, 'monthticket': 1}),
      RankEntry(rank: 1, title: '书2', author: 'a', bookId: 'b2',
          metrics: const {'words': 100, 'monthticket': 1}),
      RankEntry(rank: 2, title: '书3', author: 'a', bookId: 'b3',
          metrics: const {'words': 100, 'monthticket': 1}),
    ],
    fetchedAt: DateTime(2026, 9, 2),
  );
  final two = <IndexEntry>[
    IndexEntry(
        id: 'qidian|月票榜|-|20260901', source: 'qidian', board: '月票榜',
        dateKey: '20260901', fetchedAt: DateTime(2026, 9, 1), count: 3, ok: true,
        relFile: 'x'),
    IndexEntry(
        id: 'qidian|月票榜|-|20260902', source: 'qidian', board: '月票榜',
        dateKey: '20260902', fetchedAt: DateTime(2026, 9, 2), count: 3, ok: true,
        relFile: 'x'),
  ];
  final sv = buildSeriesView(
    allSeriesEntries: two,
    results: {two[0].id: r1, two[1].id: r2},
    range: TimeRange.all,
  );
  _check('SeriesView 期数 = 2', sv.periodCount == 2, 'got ${sv.periodCount}');
  _check('totalPeriods 记录未截断总数', sv.totalPeriods == 2);
  final s = SeriesSummary.of(sv.analysis);
  // 数据：r1 书1=#1 书2=#2 书3=#3；r2 书1=#3 书2=#1 书3=#2
  // → 书2 升(#2→#1)、书3 升(#3→#2) 共 2 条上升；书1 降(#1→#3) 1 条下降。
  _check('书2、书3 上升（共 2）', s.upCount == 2, 'got ${s.upCount}');
  _check('书1 下降（#1→#3）', s.downCount == 1, 'got ${s.downCount}');
  _check('无新上榜', s.freshCount == 0, 'got ${s.freshCount}');

  // 截断档位
  final sv7 = buildSeriesView(
    allSeriesEntries: many,
    results: {for (final x in many) x.id: r1},
    range: TimeRange.last7,
  );
  _check('近 7 期装配出 7 期', sv7.periodCount == 7, 'got ${sv7.periodCount}');
  _check('totalPeriods 仍为 40（提示被截断）', sv7.totalPeriods == 40,
      'got ${sv7.totalPeriods}');

  // ── ④ 图表选线在真实装配上可用 ──
  stdout.writeln('\n── ④ 图表选线 ──');
  final picked = pickChartSeries(sv.analysis, top: 6);
  _check('两期序列能选出线', picked.isNotEmpty, 'got ${picked.length}');
  _check('每条线期数 = 2', picked.every((c) => c.ranks.length == 2));

  // ── ⑤ MainWindow 常量与符号可达 ──
  stdout.writeln('\n── ⑤ 主窗口符号 ──');
  _check('idSeriesTable 已定义', MainWindow.idSeriesTable == 203);
  _check('idRangeAll 已定义', MainWindow.idRangeAll == 412);
  _check('signedWords 格式正确', signedWords(15000) == '+1.5万', signedWords(15000));
  _check('signedWords 负数', signedWords(-3000) == '-3000', signedWords(-3000));
  _check('signedWords 零', signedWords(0) == '0');

  try {
    Directory(tmp).deleteSync(recursive: true);
  } on Object {}

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

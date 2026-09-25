/// 趋势解读回归 —— 事实 / 候选原因 / 边界纪律。
///
/// 这一层最危险的失败不是"算错"，而是**把猜测说得像结论**。
/// 所以断言分两类：
///   ① 数字类：中位数、前 3 名变动次数、连续同向期数是否算对；
///   ② 纪律类：期数不足不许给原因、候选原因不超过 3 条、
///      事实里不许复述概览卡已有的数字（那是在浪费最稀缺的显示行数）。
///
/// 运行：dart run bin/_t_insight.dart
library;

import 'dart:io';

import '../lib/models.dart';
import '../lib/snapshot_index_file.dart';
import '../lib/timeseries.dart';
import '../lib/trend_insight.dart';

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

RankResult _mk(String source, String board, DateTime at,
    List<(String id, String title, int rank, int words)> rows) {
  return RankResult(
    query: RankQuery(source: source, board: board, limit: rows.length),
    entries: [
      for (final r in rows)
        RankEntry(
          rank: r.$3,
          title: r.$2,
          author: '作者',
          bookId: r.$1,
          metrics: {'words': r.$4, 'monthticket': r.$4 ~/ 10},
        )
    ],
    fetchedAt: at,
  );
}

IndexEntry _ie(String source, String board, DateTime at, int count) => IndexEntry(
      id: '$source|$board|-|'
          '${at.year}${at.month.toString().padLeft(2, '0')}${at.day.toString().padLeft(2, '0')}',
      source: source,
      board: board,
      dateKey: '${at.year}${at.month.toString().padLeft(2, '0')}'
          '${at.day.toString().padLeft(2, '0')}',
      fetchedAt: at,
      count: count,
      ok: true,
      relFile: '扫榜/$source/$board.json',
    );

/// 把若干期的 (日期, 结果) 装配成时间线。
TimeSeriesAnalysis _ts(List<(DateTime, RankResult)> periods) {
  final entries = <IndexEntry>[];
  final results = <String, RankResult>{};
  for (final (at, r) in periods) {
    final e = _ie(r.query.source, r.query.board, at, r.entries.length);
    entries.add(e);
    results[e.id] = r;
  }
  return buildTimeSeries(entries, results);
}

void main() {
  stdout.writeln('== 趋势解读回归：事实 / 候选原因 / 边界纪律 ==');

  // ── ① 期数不足：不许猜原因 ──
  stdout.writeln('\n── ① 只有 2 期 → 不给原因 ──');
  final d1 = DateTime(2026, 9, 20);
  final d2 = DateTime(2026, 9, 21);
  final two = _ts([
    (d1, _mk('qidian', '月票榜', d1, [
      ('b1', '甲', 1, 10000),
      ('b2', '乙', 2, 10000),
      ('b3', '丙', 3, 10000),
    ])),
    (d2, _mk('qidian', '月票榜', d2, [
      ('b1', '甲', 1, 30000),
      ('b2', '乙', 2, 30000),
      ('b3', '丙', 3, 30000),
    ])),
  ]);
  final i2 = buildTrendInsight(two);
  _check('2 期 → 没有候选原因', i2.hypotheses.isEmpty,
      '${i2.hypotheses.length} 条');
  _check('2 期 → enough=false', !i2.enough);
  _check('2 期 → caveat 说明"谈不上趋势"',
      i2.caveat.contains('谈不上趋势'), i2.caveat);
  _check('2 期 → 事实仍然给（可复算的东西不用等）', i2.facts.isNotEmpty);

  // ── ② 3 期以上：事实齐全 ──
  stdout.writeln('\n── ② 3 期以上 → 事实齐全 ──');
  final d3 = DateTime(2026, 9, 22);
  final d4 = DateTime(2026, 9, 23);
  // 甲：一路上升 + 字数一路涨；乙：一路下降 + 字数不动；丙：稳居第 3
  final four = _ts([
    (d1, _mk('qidian', '月票榜', d1, [
      ('b1', '甲', 8, 10000),
      ('b2', '乙', 2, 50000),
      ('b3', '丙', 3, 30000),
    ])),
    (d2, _mk('qidian', '月票榜', d2, [
      ('b1', '甲', 6, 20000),
      ('b2', '乙', 4, 50000),
      ('b3', '丙', 3, 30000),
    ])),
    (d3, _mk('qidian', '月票榜', d3, [
      ('b1', '甲', 4, 40000),
      ('b2', '乙', 6, 50000),
      ('b3', '丙', 3, 30000),
    ])),
    (d4, _mk('qidian', '月票榜', d4, [
      ('b1', '甲', 2, 80000),
      ('b2', '乙', 8, 50000),
      ('b3', '丙', 3, 30000),
    ])),
  ]);
  final i4 = buildTrendInsight(four);
  _check('4 期 → enough=true', i4.enough);
  _check('4 期 → 有事实行', i4.facts.isNotEmpty, '${i4.facts.length} 条');
  final allFacts = i4.facts.join(' | ');
  _check('事实含"名次中位数"', allFacts.contains('名次中位数'), allFacts);
  _check('事实含在榜数变化', allFacts.contains('在榜'), allFacts);
  _check('事实含连续同向（甲连涨 3 期）', allFacts.contains('最长连涨 3 期'),
      allFacts);
  _check('事实含前 3 名变动', allFacts.contains('前 3 名共变动'), allFacts);
  // 名次中位数：8/2/3 → 3；2/8/3 → 3 → 持平
  _check('名次中位数算对（3 → 3 持平）', allFacts.contains('名次中位数 3 → 3'),
      allFacts);

  // ── ③ 纪律：事实不复述概览卡已有的数字 ──
  stdout.writeln('\n── ③ 事实不复述概览卡 ──');
  _check('事实里没有"全期在榜"（概览卡已有）', !allFacts.contains('全期在榜'),
      allFacts);
  _check('事实里没有裸的"上榜数 x → y"（概览卡已有）',
      !allFacts.contains('上榜数 '), allFacts);

  // ── ④ 候选原因：触发与上限 ──
  stdout.writeln('\n── ④ 候选原因 ──');
  _check('候选原因 ≤ 3 条', i4.hypotheses.length <= 3,
      '${i4.hypotheses.length} 条');
  for (var i = 1; i < i4.hypotheses.length; i++) {
    _check('候选原因按置信度降序（第 ${i + 1} 条）',
        i4.hypotheses[i - 1].confidence >= i4.hypotheses[i].confidence);
  }
  _check('每条候选原因都带证据', i4.hypotheses.every((h) => h.evidence.isNotEmpty));
  _check('每条候选原因都带边界说明',
      i4.hypotheses.every((h) => h.caveat.isNotEmpty));
  _check('置信度标签只有三档',
      i4.hypotheses.every((h) => const {'较强', '中等', '较弱'}
          .contains(h.confidenceLabel)),
      i4.hypotheses.map((h) => h.confidenceLabel).join(','));
  _check('连涨 3 期 → 触发"真趋势"那条',
      i4.hypotheses.any((h) => h.claim.contains('真趋势')),
      i4.hypotheses.map((h) => h.claim).join(' | '));

  // ── ⑤ 名次上升 + 字数同涨 → "更新量带动" ──
  stdout.writeln('\n── ⑤ 更新量假设 ──');
  // 甲/乙/丙 三本都上升，且字数都在涨（4 本样本）
  final up = _ts([
    (d1, _mk('qidian', '月票榜', d1, [
      ('b1', '甲', 9, 10000),
      ('b2', '乙', 8, 10000),
      ('b3', '丙', 7, 10000),
      ('b4', '丁', 6, 10000),
    ])),
    (d2, _mk('qidian', '月票榜', d2, [
      ('b1', '甲', 7, 20000),
      ('b2', '乙', 6, 20000),
      ('b3', '丙', 5, 20000),
      ('b4', '丁', 4, 20000),
    ])),
    (d3, _mk('qidian', '月票榜', d3, [
      ('b1', '甲', 5, 40000),
      ('b2', '乙', 4, 40000),
      ('b3', '丙', 3, 40000),
      ('b4', '丁', 2, 40000),
    ])),
  ]);
  final iUp = buildTrendInsight(up);
  final h1 = iUp.hypotheses.where((h) => h.claim.contains('更新量'));
  _check('上升 + 字数同涨 → 触发"更新量带动曝光"', h1.isNotEmpty,
      iUp.hypotheses.map((h) => h.claim).join(' | '));
  if (h1.isNotEmpty) {
    _check('该条证据含"字数同涨"', h1.first.evidence.contains('字数同涨'),
        h1.first.evidence);
    _check('该条置信度在 0..1', h1.first.confidence > 0 && h1.first.confidence <= 1,
        '${h1.first.confidence}');
  }

  // ── ⑥ 掉榜 + 字数零变化 → "更像口径/节奏变了" ──
  stdout.writeln('\n── ⑥ 掉榜但数据面没动 ──');
  final gone = _ts([
    (d1, _mk('qidian', '月票榜', d1, [
      ('b1', '甲', 1, 10000),
      ('b2', '乙', 2, 20000),
      ('b3', '丙', 3, 30000),
      ('b4', '丁', 4, 40000),
    ])),
    (d2, _mk('qidian', '月票榜', d2, [
      ('b1', '甲', 1, 10000),
      ('b2', '乙', 2, 20000),
      ('b3', '丙', 3, 30000),
      ('b4', '丁', 4, 40000),
    ])),
    // 第 3 期只留甲，乙丙丁掉榜且字数没动
    (d3, _mk('qidian', '月票榜', d3, [
      ('b1', '甲', 1, 10000),
    ])),
  ]);
  final iGone = buildTrendInsight(gone);
  _check('掉榜 + 字数零变化 → 触发"口径/节奏"那条',
      iGone.hypotheses.any((h) => h.claim.contains('口径')),
      iGone.hypotheses.map((h) => h.claim).join(' | '));
  _check('掉榜事实里有"换血"', iGone.facts.any((f) => f.contains('换血')),
      iGone.facts.join(' | '));

  // ── ⑦ 前 3 名"换人"才算变动（1↔2 互换不算）──
  stdout.writeln('\n── ⑦ 前 3 名变动按集合算 ──');
  final swap = _ts([
    (d1, _mk('qidian', '月票榜', d1, [
      ('b1', '甲', 1, 10000),
      ('b2', '乙', 2, 10000),
      ('b3', '丙', 3, 10000),
      ('b4', '丁', 4, 10000),
    ])),
    (d2, _mk('qidian', '月票榜', d2, [
      ('b1', '甲', 2, 10000),
      ('b2', '乙', 1, 10000),
      ('b3', '丙', 3, 10000),
      ('b4', '丁', 4, 10000),
    ])),
  ]);
  final iSwap = buildTrendInsight(swap);
  _check('1↔2 互换 → 前 3 名变动 0 次',
      iSwap.facts.any((f) => f.contains('前 3 名共变动 0 次')),
      iSwap.facts.join(' | '));

  // ── ⑧ lines 的可区分性 ──
  stdout.writeln('\n── ⑧ 事实与候选原因必须可区分 ──');
  final lines = iUp.lines;
  _check('lines 非空', lines.isNotEmpty);
  _check('lines 里既有事实也有候选原因',
      lines.any((l) => l.isFact) && lines.any((l) => !l.isFact));
  _check('事实行没有置信度标签', lines.where((l) => l.isFact).every((l) => l.tag == null));
  _check('候选原因行都有置信度标签',
      lines.where((l) => !l.isFact).every((l) => l.tag != null));
  _check('事实行排在前（读者先看数，再看推断）',
      lines.indexWhere((l) => !l.isFact) >= lines.where((l) => l.isFact).length - 1);

  // ── ⑨ 空时间线不许崩 ──
  stdout.writeln('\n── ⑨ 边界 ──');
  final empty = buildTimeSeries(const [], const {});
  final iEmpty = buildTrendInsight(empty);
  _check('空时间线 → 不抛异常且无内容',
      iEmpty.facts.isEmpty && iEmpty.hypotheses.isEmpty);
  _check('空时间线 → periods=0', iEmpty.periods == 0);

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

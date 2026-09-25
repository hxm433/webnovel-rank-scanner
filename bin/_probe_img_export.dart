/// 把榜单长图与趋势图渲染到 `build/shots/`，供肉眼复验。
///
/// 运行：dart run bin/_probe_img_export.dart
library;

import 'dart:io';

import '../lib/models.dart';
import '../lib/snapshot_index.dart';
import '../lib/snapshot_index_file.dart';
import '../lib/timeseries.dart';
import '../lib/ui/image_export.dart';

RankResult _mk(
  String source,
  String board,
  DateTime at,
  List<(String, String, String, int, int, num)> rows, {
  String? catName,
  String? catId,
}) =>
    RankResult(
      query: RankQuery(
        source: source,
        board: board,
        limit: rows.length,
        categoryName: catName,
        categoryId: catId,
      ),
      entries: [
        for (final r in rows)
          RankEntry(
            rank: r.$4,
            title: r.$2,
            author: r.$3,
            bookId: r.$1,
            category: catName,
            tags: const ['玄幻', '签约'],
            metrics: {'words': r.$5, 'monthticket': r.$6},
          )
      ],
      fetchedAt: at,
    );

SnapshotMeta _meta(String source, String board, DateTime at, RankResult r) =>
    SnapshotMeta(id: 0, file: File('x.json'), result: r);

IndexEntry _ie(String source, String board, DateTime at, int count) =>
    IndexEntry(
      id: '$source|$board|-|${at.year}${at.month.toString().padLeft(2, '0')}'
          '${at.day.toString().padLeft(2, '0')}',
      source: source,
      board: board,
      dateKey: '${at.year}${at.month.toString().padLeft(2, '0')}'
          '${at.day.toString().padLeft(2, '0')}',
      fetchedAt: at,
      count: count,
      ok: true,
      relFile: '扫榜/$source/$board.json',
    );

void main() {
  final outDir = '${Directory.current.path}${Platform.pathSeparator}build'
      '${Platform.pathSeparator}shots';
  Directory(outDir).createSync(recursive: true);

  // 榜单长图
  final rows = <(String, String, String, int, int, num)>[
    ('b1', '宿命之环', '爱潜水的乌贼', 1, 3200000, 98000),
    ('b2', '光阴之外', '耳根', 2, 2800000, 76000),
    ('b3', '这游戏也太真实了', '晨星LL', 3, 2600000, 61000),
    ('b4', '深海余烬', '远瞳', 4, 2400000, 55000),
    ('b5', '长夜君主', '那一只蚊子', 5, 2200000, 48000),
    ('b6', '从红月开始', '黑山老鬼', 6, 2100000, 42000),
    ('b7', '黎明之剑', '远瞳', 7, 2000000, 39000),
    ('b8', '不科学御兽', '轻泉流响', 8, 1900000, 35000),
    ('b9', '大魏读书人', '七月新番', 9, 1800000, 32000),
    ('b10', '明克街13号', '纯洁滴小龙', 10, 1700000, 30000),
  ];
  final r = _mk('qidian', '月票榜', DateTime(2026, 9, 24), rows,
      catName: '玄幻', catId: '21');
  final board = renderBoardImage(_meta('qidian', '月票榜', DateTime(2026, 9, 24, 18, 30), r));
  if (board != null) {
    final p = saveImage(outDir, '榜单_qidian_月票榜_玄幻_20260924', board);
    stdout.writeln('榜单图 → $p  (${board.width}x${board.height}, ${board.pngBytes} 字节)');
  }
  // 打印表头布局，确认"粗体+平台后缀"这一口径真的生效
  final hl = boardHeaderLayout(_meta('qidian', '月票榜', DateTime(2026, 9, 24), r),
      width: 980);
  stdout.writeln('表头布局（标签 / 列宽 / 文字宽 / 左内边距）：');
  for (var i = 0; i < hl.labels.length; i++) {
    final f = hl.textWidths[i] + hl.padLefts[i] <= hl.widths[i] ? 'OK' : 'OVERFLOW';
    stdout.writeln('  [$i] "${hl.labels[i]}"  列宽=${hl.widths[i]}  '
        '文字=${hl.textWidths[i]} 内边距=${hl.padLefts[i]}  → $f');
  }
  stdout.writeln('  allFit=${hl.allFit}');

  // 趋势图
  final results = <String, RankResult>{};
  final entries = <IndexEntry>[];
  for (var i = 0; i < 8; i++) {
    final at = DateTime(2026, 9, 17).add(Duration(days: i));
    final rs = <(String, String, String, int, int, num)>[
      ('b1', '宿命之环', '爱潜水的乌贼', (5 - i).clamp(1, 9), 3000000 + i * 40000, 90000 + i * 2000),
      ('b2', '光阴之外', '耳根', 3 + i, 2700000 + i * 20000, 70000 + i * 1000),
      ('b3', '这游戏也太真实了', '晨星LL', 6, 2500000 + i * 15000, 60000 + i * 800),
      ('b4', '深海余烬', '远瞳', (10 - i).clamp(2, 14), 2300000 + i * 12000, 50000 + i * 600),
      ('b5', '长夜君主', '那一只蚊子', 4 + (i % 4), 2200000 + i * 10000, 46000 + i * 500),
    ];
    final rr = _mk('qidian', '月票榜', at, rs, catName: '玄幻', catId: '21');
    final ie = _ie('qidian', '月票榜', at, rs.length);
    entries.add(ie);
    results[ie.id] = rr;
  }
  final ts = buildTimeSeries(entries, results);
  final trend = renderTrendImage(ts, width: 980, height: 520, rangeLabel: '近 8 期');
  if (trend != null) {
    final p = saveImage(outDir, '趋势_qidian_月票榜_玄幻', trend);
    stdout.writeln('趋势图 → $p  (${trend.width}x${trend.height}, ${trend.pngBytes} 字节)');
  }
}

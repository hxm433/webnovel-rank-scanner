/// 造一份**多期历史**夹具，供离屏渲染与人工验收用。
///
/// 目的：验证"历史对比"页在有 8 期数据时的真实样子 ——
/// 排名有升有降、有中途掉榜、有最新才上榜、字数在涨。
/// 数据是**确定性**生成的（不用随机），每次跑出来一样，便于比对。
///
/// 运行：dart run bin/_fixture_history.dart <outRoot>
library;

import 'dart:io';

import '../lib/models.dart';
import '../lib/store.dart';

/// 书单：id、书名、初始名次、初始字数。
const _books = <(String, String, int, int)>[
  ('1001', '剑来异仙', 8, 2100000),
  ('1002', '深海余烬', 3, 1800000),
  ('1003', '宿命之环', 2, 3200000),
  ('1004', '光阴之外', 12, 900000),
  ('1005', '万相之王', 5, 4100000),
  ('1006', '不科学御兽', 1, 2900000),
  ('1007', '赤心巡天', 15, 5600000),
  ('1008', '这游戏也太真实了', 7, 3400000),
  ('1009', '我的师门有点强', 22, 700000),
  ('1010', '天启预报', 18, 1100000),
  ('1011', '长夜君主', 30, 450000),
  ('1012', '凡人修仙传', 9, 7700000),
];

/// 每期（期号）的名次表 —— 手工编排，让趋势"有故事"：
///  · 不科学御兽：1→1→2→4→6→9→14（连续下滑，最后掉榜）
///  · 宿命之环  ：2→2→1→1→2→3→2（在榜首区间胶着）
///  · 剑来异仙  ：8→6→5→4→3→2→2（稳步上升）
///  · 我的师门有点强：22→18→15→11→8→5（逆袭）
///  · 长夜君主  ：30→28→—→—→19→12（中途掉榜后回归）
///  · 新书 暗域行者：只有最后两期在榜（新上榜）
List<List<(String, int)>> _schedule() {
  // 每期：bookId → rank。0/缺失 = 未上榜。
  return [
    // 期0
    [('1006', 1), ('1003', 2), ('1002', 3), ('1005', 5), ('1008', 7),
     ('1001', 8), ('1012', 9), ('1004', 12), ('1007', 15), ('1010', 18),
     ('1009', 22), ('1011', 30)],
    // 期1
    [('1006', 1), ('1003', 2), ('1002', 3), ('1005', 6), ('1008', 7),
     ('1001', 6), ('1012', 10), ('1004', 13), ('1007', 16), ('1010', 19),
     ('1009', 18), ('1011', 28)],
    // 期2（长夜君主掉榜）
    [('1003', 1), ('1006', 2), ('1002', 4), ('1005', 7), ('1001', 5),
     ('1008', 8), ('1012', 11), ('1004', 14), ('1007', 15), ('1010', 21),
     ('1009', 15)],
    // 期3
    [('1003', 1), ('1006', 4), ('1002', 5), ('1001', 4), ('1005', 8),
     ('1008', 9), ('1012', 12), ('1007', 14), ('1004', 13), ('1009', 11),
     ('1010', 24)],
    // 期4（长夜君主回归）
    [('1003', 2), ('1001', 3), ('1002', 6), ('1006', 6), ('1005', 9),
     ('1009', 8), ('1008', 11), ('1012', 13), ('1007', 12), ('1004', 10),
     ('1011', 19)],
    // 期5（新书 2001 出现）
    [('1003', 3), ('1001', 2), ('1002', 6), ('1006', 9), ('1009', 5),
     ('1005', 10), ('1004', 8), ('1008', 12), ('1007', 11), ('1012', 14),
     ('1011', 12), ('2001', 7)],
    // 期6（不科学御兽掉榜）
    [('1001', 2), ('1003', 4), ('1009', 2), ('1002', 7), ('1004', 5),
     ('1005', 11), ('1007', 9), ('2001', 6), ('1008', 13), ('1011', 8),
     ('1012', 15)],
    // 期7（最新）
    [('1001', 2), ('1003', 4), ('1009', 1), ('2001', 3), ('1004', 5),
     ('1007', 7), ('1002', 8), ('1011', 6), ('1005', 12), ('1008', 14),
     ('1012', 16)],
  ];
}

RankResult _mk(
  String source,
  String board,
  DateTime at,
  List<(String, int)> rows,
) {
  final byId = {for (final b in _books) b.$1: b};
  // 新书 2001 单独登记
  final titleOf = <String, String>{
    for (final b in _books) b.$1: b.$2,
    '2001': '暗域行者',
  };
  final baseWords = <String, int>{
    for (final b in _books) b.$1: b.$4,
    '2001': 300000,
  };
  final periodIdx = at.difference(DateTime(2026, 9, 15)).inDays;
  final sorted = [...rows]..sort((a, b) => a.$2.compareTo(b.$2));
  return RankResult(
    query: RankQuery(source: source, board: board, limit: sorted.length),
    entries: [
      for (final r in sorted)
        RankEntry(
          rank: r.$2,
          title: titleOf[r.$1] ?? '未知',
          author: '作者${r.$1.substring(1)}',
          bookId: r.$1,
          category: _catOf(r.$1),
          tags: const ['东方玄幻'],
          // 字数随期数增长（每期 +5% 左右，确定性的）
          metrics: {
            'words': ((baseWords[r.$1] ?? 100000) *
                    (1 + 0.05 * (periodIdx < 0 ? 0 : periodIdx))) ~/ 1,
            'monthticket':
                ((3000 / r.$2) * 100).round() + periodIdx * 37,
          },
          extra: {
            'rankCntRaw': '${((3000 / r.$2) * 100).round()}月票',
          },
        ),
    ],
    fetchedAt: at,
    truncated: false,
    quality: RankQuality(
      ok: true,
      validCount: sorted.length,
      totalCount: sorted.length,
      summary: '夹具数据（${sorted.length} 条）',
    ),
    sourceUrl: 'https://example.com/$board',
  );
}

String? _catOf(String id) {
  const map = {
    '1001': '仙侠', '1002': '奇幻', '1003': '玄幻', '1004': '仙侠',
    '1005': '玄幻', '1006': '都市', '1007': '玄幻', '1008': '游戏',
    '1009': '玄幻', '1010': '悬疑', '1011': '奇幻', '1012': '仙侠',
    '2001': '科幻',
  };
  return map[id];
}

Future<void> main(List<String> args) async {
  final outRoot = args.isNotEmpty ? args[0] : 'build/fixture_out';
  final store = RankStore(root: outRoot);
  final schedule = _schedule();

  // 8 期：2026-09-15 起，每天一期。
  var n = 0;
  for (var i = 0; i < schedule.length; i++) {
    final at = DateTime(2026, 9, 15 + i);
    await store.save(_mk('qidian', '月票榜', at, schedule[i]));
    n++;
  }
  // 再加一张榜（跨榜分析页要有数据）
  for (var i = 0; i < schedule.length; i++) {
    final at = DateTime(2026, 9, 15 + i);
    await store.save(_mk('qidian', '畅销榜', at, schedule[i]));
    n++;
  }
  // 番茄一张（平台分组）
  for (var i = 0; i < 4; i++) {
    final at = DateTime(2026, 9, 15 + i);
    await store.save(_mk('fanqie', '人气榜', at, schedule[i]));
    n++;
  }

  print('夹具已生成：$n 份快照 → $outRoot');
  print('  起点·月票榜 8 期 / 起点·畅销榜 8 期 / 番茄·人气榜 4 期');
}

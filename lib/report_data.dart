/// 页面数据构建器 —— **唯一一份口径实现**。
///
/// 原来 `bin/serve.dart` 里也有一套分析装配，那会造出"服务端算的"和"页面算的"
/// 两种结果分叉的风险。现在生成静态网页与（可选）本地预览都走这里。
library;

import 'models.dart';
import 'analysis.dart';
import 'snapshot_index.dart';

/// 指标口径声明：不同平台的同名数值不是一回事，页面上必须写清楚。
///
/// ★ 不带平台后缀的是**通用标签**（同名指标跨平台含义一致时用）。
///   带平台后缀的（如 `heat_qimao`）只在该平台出现。
///   以前只有一张写死平台名的表 —— `'heat': '热度（七猫）'` ——
///   于是**任何**平台只要有 `heat` 键就被标成"七猫"，
///   实测番茄的快照表头出现过"热度（七猫）"。
const Map<String, String> metricLabels = {
  'monthticket': '月票（起点）',
  'recommend': '推荐（起点）',
  'reading': '在读（番茄）',
  'heat': '热度',
  'collect': '收藏',
  'score': '积分（晋江）',
  'words': '字数（体量，不是热度）',
  'updatewords': '更新字数（起点）',
  'fans': '新增粉丝（起点）',
};

/// 按**平台**取指标标签。平台能认出来时补上平台名，认不出就用通用标签。
///
/// 这样"热度（七猫）"只会出现在七猫的快照上；番茄的 `heat`（若真有）
/// 会显示成"热度（番茄）"，而不是张冠李戴。
String metricLabelFor(String key, {String? source}) {
  final base = metricLabels[key] ?? key;
  if (source == null) return base;
  final name = sourceNames[source];
  if (name == null) return base;
  // 已经是"带平台名"的标签（月票（起点））就不再补第二次。
  if (base.contains('（')) return base;
  return '$base（$name）';
}

const Map<String, String> sourceNames = {
  'qidian': '起点', 'fanqie': '番茄', 'qimao': '七猫', 'jjwxc': '晋江',
};

/// 跨平台口径警告 —— **报告、网页、GUI、导出共用这一份文案**。
/// 四处各写一句的话会慢慢漂移成四种说法，用户就不知道该信哪个。
const String metricsWarning =
    '各平台指标口径不同（起点=月票/推荐、番茄=在读、七猫=热度、晋江=积分），'
    '禁止跨平台比大小；各平台题材命名也是各自体系。';

/// 一份快照的完整展示数据。
Map<String, Object?> snapshotBlock(SnapshotMeta m, {required bool withTrends}) {
  const analyzer = RankAnalyzer();
  final a = analyzer.analyze(m.result);
  final seen = <String>{};
  for (final e in m.result.entries) {
    seen.addAll(e.metrics.keys);
  }
  return {
    'meta': m.toJson(),
    'source_name': sourceNames[m.source] ?? m.source,
    'legend': {
      'keys': seen.toList(),
      'labels': {for (final k in seen) k: metricLabels[k] ?? k},
    },
    'analysis': {
      'sample_size': a.sampleSize,
      'obfuscated': a.obfuscatedCount,
      'skipped_for_keywords': a.skippedForKeywords,
      'word_range': a.wordRange == null ? null : [a.wordRange!.$1, a.wordRange!.$2],
      'new_categories': a.newCategories,
      'categories': [
        for (final c in a.categories)
          {'category': c.category, 'count': c.count, 'ratio': c.ratio, 'best_rank': c.bestRank}
      ],
      'title_keywords': [for (final k in a.titleKeywords) {'w': k.key, 'n': k.value}],
      'tag_keywords': [for (final k in a.tagKeywords) {'w': k.key, 'n': k.value}],
    },
    'entries': [for (final e in m.result.entries) e.toJson()],
    if (withTrends) 'trends': const <Object?>[],
  };
}

/// 同平台内两两对比的差分。
///
/// ★ 只提供**同平台**的基准：跨平台指标口径不同，差出来的是无意义的数。
/// 每项标 `same_series`，页面据此决定说"趋势"还是说"两榜差异"。
Map<String, Object?> comparisonsByPair(SnapshotIndex index) {
  const analyzer = RankAnalyzer();
  final out = <String, Object?>{};
  for (final curr in index.items) {
    for (final prev in index.items) {
      if (prev.source != curr.source || prev.id == curr.id) continue;
      final a = analyzer.analyze(curr.result, previous: prev.result);
      final rows = a.trends
          .where((t) => t.isNew || t.dropped || (t.rankChange ?? 0) != 0)
          .map((t) => {
                'title': t.title,
                'obf': privateUseCount(t.title) > 0,
                'prev': t.prevRank,
                'curr': t.currRank,
                'chg': t.rankChange,
                'new': t.isNew,
                'gone': t.dropped,
                'jump': double.parse(t.jumpScore.toStringAsFixed(1)),
              })
          .toList();
      if (rows.isEmpty) continue;
      out['${curr.id}|${prev.id}'] = {
        'rows': rows,
        'same_series': curr.seriesKey == prev.seriesKey,
        'base_label': '${prev.board}${prev.category == null ? '' : ' · ${prev.category}'} · ${prev.dateKey}',
      };
    }
  }
  return out;
}

/// 概览：按平台分列的题材统计 + 跨榜出现的书。
Map<String, Object?> overview(SnapshotIndex index) {
  final perSource = <String, Map<String, List<RankEntry>>>{};
  for (final m in index.items) {
    final bag = perSource.putIfAbsent(m.source, () => <String, List<RankEntry>>{});
    for (final e in m.result.entries) {
      final c = (e.category ?? '').trim();
      if (c.isEmpty) continue;
      (bag[c] ??= []).add(e);
    }
  }
  final bookBoards = <String, List<String>>{};
  final bookObf = <String, bool>{};
  for (final m in index.items) {
    final label = '${sourceNames[m.source] ?? m.source}:${m.board}'
        '${m.category == null ? '' : '·${m.category}'}';
    for (final e in m.result.entries) {
      final key = e.title.trim();
      if (key.isEmpty) continue;
      bookBoards.putIfAbsent(key, () => []).add(label);
      bookObf[key] = (bookObf[key] ?? false) || e.titleObfuscated;
    }
  }
  final multi = bookBoards.entries.where((e) => e.value.toSet().length > 1).toList()
    ..sort((a, b) => b.value.toSet().length.compareTo(a.value.toSet().length));

  return {
    'per_source': {
      for (final s in perSource.entries)
        s.key: [
          for (final c in s.value.entries)
            {
              'category': c.key,
              'count': c.value.length,
              'best_rank': c.value.map((x) => x.rank).reduce((a, b) => a < b ? a : b),
              'avg_words': _avgWords(c.value),
            }
        ].toList()..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int))
    },
    'cross_board_books': [
      for (final e in multi.take(30))
        {'title': e.key, 'boards': e.value.toSet().toList(), 'obf': bookObf[e.key] == true}
    ],
  };
}

int? _avgWords(List<RankEntry> list) {
  // ★ 只统计**有限**的数：JSON 里的 `1e999` 会被解析成 Infinity，
  //   `Infinity.round()` 抛 `Unsupported operation: Infinity or NaN toInt`。
  //   以前这个异常会从 `overview()` 冒到 `reload()`，被窗口过程静默吞掉，
  //   结果是"一份坏快照毒死全部快照"——界面永久显示"没有可显示的数据"且不报错。
  final w = list
      .map((x) => x.metrics['words'])
      .whereType<num>()
      .where((n) => n.isFinite)
      .toList();
  if (w.isEmpty) return null;
  final sum = w.fold<double>(0, (a, b) => a + b.toDouble());
  final avg = sum / w.length;
  if (!avg.isFinite) return null;
  return avg.round();
}

/// 整个页面的数据载荷。
Map<String, Object?> buildPayload(SnapshotIndex index, List<String> badFiles) {
  return {
    'generated_at': DateTime.now().toIso8601String(),
    'count': index.items.length,
    'bad_files': badFiles,
    'metrics_warning': metricsWarning,
    'sources': [
      for (final s in _sourceSummary(index)) s,
    ],
    'snapshots': [
      for (final m in index.items) snapshotBlock(m, withTrends: false),
    ],
    'comparisons': comparisonsByPair(index),
    'overview': overview(index),
  };
}

List<Map<String, Object?>> _sourceSummary(SnapshotIndex index) {
  final bySource = <String, List<SnapshotMeta>>{};
  for (final m in index.items) {
    (bySource[m.source] ??= []).add(m);
  }
  return [
    for (final e in bySource.entries)
      {
        'source': e.key,
        'name': sourceNames[e.key] ?? e.key,
        'snapshots': e.value.length,
        'books': e.value.fold<int>(0, (a, m) => a + m.count),
        'ok': e.value.where((m) => m.ok).length,
      }
  ];
}

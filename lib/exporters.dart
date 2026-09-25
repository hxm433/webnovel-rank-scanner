/// 导出：把快照与分析结果写成 CSV / JSON / Markdown 文件。
///
/// ★ 三个口径必须与报告和网页保持一致，否则用户会拿到互相矛盾的两份东西：
///   ① 指标名用 [metricLabels] 的中文口径说明（"在读（番茄）"而不是 "reading"）；
///   ② 跨平台不做大小比较 —— 导出里也带上 [metricsWarning]；
///   ③ 被字体混淆的书名照原样导出（带 U+E000 私用区字符），**不猜**，
///      让下游能自己判断这条数据能不能用。
library;

import 'dart:convert';
import 'dart:io';

import 'analysis.dart';
import 'models.dart';
import 'report_data.dart';
import 'snapshot_index.dart';

/// 把一份表格写成 CSV。
///
/// [withBom] 默认 true：Excel 打开无 BOM 的 UTF-8 CSV 会把中文显示成乱码，
/// 这是中文用户最容易踩的坑（在 Windows 上尤其常见）。
String rowsToCsv(
  List<String> headers,
  List<List<String>> rows, {
  bool withBom = true,
}) {
  final sb = StringBuffer();
  if (withBom) sb.write('\uFEFF');
  sb.writeln(headers.map(_csvCell).join(','));
  for (final r in rows) {
    sb.writeln(r.map(_csvCell).join(','));
  }
  return sb.toString();
}

/// CSV 单元格转义。
///
/// ① 含逗号/引号/换行的字段必须用双引号包起来，内部的双引号翻倍；
/// ② ★ 防公式注入：以 `= + - @` 或 TAB/CR 开头的字段，Excel/WPS 会当成
///    公式执行（`=cmd|' /C calc'!A0` 这类 payload 能直接拉起进程）。
///    本工具导出的是**抓来的站外文本**（书名/作者/标签），必须当不可信数据处理。
///    业界通行做法是在前面加一个单引号 `'`（Excel 视为文本），
///    这里同时给它套上引号，保证下游用非 Excel 解析器读到的仍是原值加一个前导 `'`。
String _csvCell(String s) {
  if (s.isEmpty) return s;
  final c0 = s.codeUnitAt(0);
  final formulaLike = c0 == 0x3D /* = */ ||
      c0 == 0x2B /* + */ ||
      c0 == 0x2D /* - */ ||
      c0 == 0x40 /* @ */ ||
      c0 == 0x09 /* TAB */ ||
      c0 == 0x0D /* CR */;
  var v = s;
  if (formulaLike) v = "'$v";
  final needsQuote = formulaLike ||
      v.contains(',') ||
      v.contains('"') ||
      v.contains('\n') ||
      v.contains('\r');
  if (!needsQuote) return v;
  return '"${v.replaceAll('"', '""')}"';
}

/// 一份快照的明细导出（CSV）。
String snapshotToCsv(SnapshotMeta m) {
  final headers = <String>[
    '名次', '书名', '作者', '题材', '标签', '书名是否被混淆', '链接',
  ];
  // 指标列取并集，保持稳定顺序
  final metricKeys = <String>{};
  for (final e in m.result.entries) {
    metricKeys.addAll(e.metrics.keys);
  }
  // words 放最后（它是体量不是热度）
  final ordered = metricKeys.toList()
    ..sort((a, b) {
      if (a == 'words') return 1;
      if (b == 'words') return -1;
      return a.compareTo(b);
    });
  for (final k in ordered) {
    // ★ 按平台补后缀（番茄的 heat 不会显示成"热度（七猫）"）。
    headers.add(metricLabelFor(k, source: m.source));
  }
  headers.add('原始计数');

  final rows = <List<String>>[];
  for (final e in m.result.entries) {
    rows.add([
      '${e.rank}',
      _plain(e.title),
      _plain(e.author),
      _plain(e.category ?? ''),
      e.tags.join('/'),
      e.titleObfuscated ? '是' : '否',
      e.url ?? '',
      for (final k in ordered)
        e.metrics[k] == null ? '' : '${e.metrics[k]}',
      e.extra['rankCntRaw'] ?? e.extra['heatRaw'] ?? e.extra['wordsRaw'] ?? '',
    ]);
  }
  return rowsToCsv(headers, rows);
}

/// 书名/作者可能含私用区字符（字体混淆未解码）；导出成文件时**保留原样**，
/// 但用一个可见标记提示"这条没解码"，避免下游误当正常文字。
///
/// ★ 注意：标记加在**末尾**，不破坏开头的字符 —— 否则会顺带改变
///   `_csvCell` 的公式注入判定（本来 `=xxx` 的 payload 最前面会被插进标记而失效）。
String _plain(String s) {
  if (s.codeUnits.any((c) => c >= 0xE000 && c <= 0xF8FF)) {
    return '$s⚠未解码';
  }
  return s;
}

/// 一份快照的完整 JSON（含分析结果）。
String snapshotToJson(SnapshotMeta m,
    {bool withAnalysis = true, String? compareToLabel}) {
  final payload = <String, Object?>{
    'source': m.source,
    'board': m.board,
    'category': m.category,
    'date': m.dateKey,
    'fetched_at': m.fetchedAt.toIso8601String(),
    'count': m.count,
    'ok': m.ok,
    'robots': m.result.robotsVerdict,
    'source_url': m.result.sourceUrl,
    'metrics_warning': metricsWarning,
    'entries': [for (final e in m.result.entries) e.toJson()],
  };
  if (withAnalysis) {
    payload['analysis'] = analyzeToJson(m.result);
  }
  if (compareToLabel != null) payload['compared_to'] = compareToLabel;
  return const JsonEncoder.withIndent('  ').convert(payload);
}

/// 一批快照的汇总导出。
String bundleToJson(
    List<SnapshotMeta> items, Map<String, Object?> overview,
    Map<String, Object?> comparisons) {
  return const JsonEncoder.withIndent('  ').convert({
    'generated_at': DateTime.now().toIso8601String(),
    'metrics_warning': metricsWarning,
    'count': items.length,
    'snapshots': [for (final m in items) m.toJson()],
    'overview': overview,
    'comparisons': comparisons,
  });
}

/// 导出到文件，返回实际写入的路径。重名自动加序号（不覆盖用户已有文件）。
String exportTo(
  String dir,
  String baseName,
  String extension,
  String content,
) {
  final d = Directory(dir);
  if (!d.existsSync()) d.createSync(recursive: true);
  var path = '$dir${Platform.pathSeparator}$baseName.$extension';
  var n = 1;
  while (File(path).existsSync()) {
    path = '$dir${Platform.pathSeparator}$baseName($n).$extension';
    n++;
  }
  File(path).writeAsStringSync(content, flush: true);
  return path;
}

/// 文件名里不能出现的字符（Windows 限制最严）。
String safeFileName(String s) => s
    .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
    .replaceAll(RegExp(r'\s+'), '_')
    .trim();

/// 把分析结果转成给 GUI/JSON 用的 map（复用指标口径声明）。
///
/// ★ 直接调 [RankAnalyzer]，**不另写一套统计**：网页、报告、导出必须是同一份
///   计算口径，否则同一份数据三处显示三个数，比不显示更糟。
Map<String, Object?> analyzeToJson(RankResult result) {
  const analyzer = RankAnalyzer();
  final a = analyzer.analyze(result);
  final keys = <String>{};
  for (final e in result.entries) {
    keys.addAll(e.metrics.keys);
  }
  return {
    'sample_size': a.sampleSize,
    'obfuscated': a.obfuscatedCount,
    'skipped_for_keywords': a.skippedForKeywords,
    'word_range': a.wordRange == null ? null : [a.wordRange!.$1, a.wordRange!.$2],
    'new_categories': a.newCategories,
    'categories': [
      for (final c in a.categories)
        {
          'category': c.category,
          'count': c.count,
          'ratio': double.parse(c.ratio.toStringAsFixed(4)),
          'best_rank': c.bestRank,
        }
    ],
    'title_keywords': [
      for (final k in a.titleKeywords) {'w': k.key, 'n': k.value}
    ],
    'tag_keywords': [
      for (final k in a.tagKeywords) {'w': k.key, 'n': k.value}
    ],
    'metric_keys': keys.toList(),
    'metric_labels': {for (final k in keys) k: metricLabels[k] ?? k},
  };
}

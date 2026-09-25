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
      // ★ 原样输出快照里的地址（用户要求“直接把链接放入”，不做改写）
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

/// 一次导出落盘的结果。
///
/// ★ [movedWhy] 非空 = **没写进你要的那个目录**，退回 [fallbackDir] 了，
///   原因在里面。UI 必须把这件事说出来 —— 悄悄换个地方存，
///   用户会以为"导出又失败了"（这正是他报的那个现象）。
typedef SaveResult = ({String path, String dir, String? movedWhy});

/// 挑一个**还没被占用**的文件名（重名自动加序号，不覆盖用户已有文件）。
String _freePath(String dir, String baseName, String extension) {
  final sep = Platform.pathSeparator;
  var path = '$dir$sep$baseName.$extension';
  var n = 1;
  while (File(path).existsSync()) {
    path = '$dir$sep$baseName($n).$extension';
    n++;
  }
  return path;
}

/// 真正把字节写到 [path]：**先写临时名，再改名替换**。
///
/// ★★ 为什么不直接 `writeAsBytesSync(path)`：目标文件经常被**读句柄**占着
///   （看图软件、杀毒扫描、索引器、网盘同步），Windows 会以
///   `errno = 32`（另一个程序正在使用）或 `errno = 5`（拒绝访问）
///   拒绝"以写方式打开"。而**改名替换不受影响** —— 读句柄只阻止写入，
///   不阻止 `MoveFileEx` 替换目录项。
///   这条在写 exe 时已经踩过一次（见 README「打包」那节的坑③）。
void _writeBytesReplacing(String path, List<int> bytes) {
  try {
    File(path).writeAsBytesSync(bytes, flush: true);
    return;
  } on Object {
  }
  final tmp = File('$path.tmp${DateTime.now().microsecondsSinceEpoch}');
  try {
    tmp.writeAsBytesSync(bytes, flush: true);
  } on Object {
    try {
      tmp.deleteSync();
    } on Object {
    }
    rethrow;
  }
  try {
    tmp.renameSync(path);
  } on Object {
    try {
      tmp.deleteSync();
    } on Object {
    }
    rethrow;
  }
}

/// 落盘一个文件，**保证成功**：
///   ① 先按 [dir] 写；失败 → **原地重试一次**（偶发占用往往一瞬就过去了）；
///   ② 还失败 → 退到 [fallbackDir] 再写一次；
///   ③ 两边都写不进去才抛。
///
/// 返回 [SaveResult]，`movedWhy` 非空时 UI 必须如实告诉用户"换地方了"。
SaveResult saveBytes(
  String dir,
  String fallbackDir,
  String baseName,
  String extension,
  List<int> bytes,
) {
  Object? firstError;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      final path = _freePath(dir, baseName, extension);
      _writeBytesReplacing(path, bytes);
      return (path: path, dir: dir, movedWhy: null);
    } on Object catch (e) {
      firstError ??= e;
      // 偶发占用（杀软/索引器）往往几十毫秒就放开了 —— 等一下再来一次
      if (attempt == 0) sleep(const Duration(milliseconds: 120));
    }
  }

  // 退回默认目录：至少让这次导出**有结果**
  if (fallbackDir != dir) {
    try {
      final d = Directory(fallbackDir);
      if (!d.existsSync()) d.createSync(recursive: true);
      final path = _freePath(fallbackDir, baseName, extension);
      _writeBytesReplacing(path, bytes);
      return (
        path: path,
        dir: fallbackDir,
        movedWhy: '写不进「$dir」（$firstError），已改存到「$fallbackDir」',
      );
    } on Object catch (e2) {
      throw StateError('两个目录都写不进去：\n  $dir → $firstError\n'
          '  $fallbackDir → $e2');
    }
  }
  throw StateError('写不进「$dir」：$firstError');
}

/// 导出到文件，返回实际写入的路径。重名自动加序号（不覆盖用户已有文件）。
///
/// ★ 落盘走 [saveBytes]：带"改名替换 + 重试 + 退回 [fallbackDir]"，
///   所以这一步**不会因为偶发占用而失败**。
String exportTo(
  String dir,
  String baseName,
  String extension,
  String content, {
  String? fallbackDir,
}) {
  final r = saveBytes(dir, fallbackDir ?? dir, baseName, extension,
      utf8.encode(content));
  return r.path;
}

/// 同 [exportTo]，但把"有没有换地方"一起返回（导出流程用它写提示）。
SaveResult exportToDetailed(
  String dir,
  String fallbackDir,
  String baseName,
  String extension,
  String content,
) =>
    saveBytes(dir, fallbackDir, baseName, extension, utf8.encode(content));

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

/// 视图模型 —— 把快照数据装配成 GUI 直接可渲染的结构。
///
/// ★ 只做**装配**，不做统计。题材分布/热词/差分全部复用
///   `analysis.dart`，跨榜汇总复用 `report_data.dart` 的 [overview]，
///   保证 GUI 与网页/报告的数字是同一份计算的结果。
library;

import '../analysis.dart';
import '../models.dart';
import '../report_data.dart';
import '../snapshot_index.dart';
import '../snapshot_index_file.dart';
import '../timeseries.dart';

/// 平台 id → 中文名。
String sourceName(String id) => sourceNames[id] ?? id;

/// 侧栏里的一条快照条目。
class SnapshotItem {
  SnapshotItem(this.meta);
  final SnapshotMeta meta;

  String get label =>
      '${meta.board}${meta.category == null ? '' : ' · ${meta.category}'}';
  String get dateLabel => meta.dateKey;
  int get count => meta.count;
  bool get ok => meta.ok;
}

/// 侧栏里按平台分组。
class SourceGroup {
  SourceGroup(this.sourceId, this.items, {this.hiddenCount = 0});
  final String sourceId;
  final List<SnapshotItem> items;

  /// 这一组里被用户**隐藏**了多少项。
  ///
  /// ★ 为什么要留着这个数：隐藏是"只是不显示"，那界面就有义务说清
  ///   "这里还有 N 项被你藏起来了" —— 否则用户会以为数据没了
  ///   （"我明明扫了 20 个榜，怎么只剩 3 个"）。
  final int hiddenCount;

  String get title => sourceName(sourceId);
}

/// 一份快照的渲染数据。
class SnapshotView {
  SnapshotView(this.meta, this.analysis);

  final SnapshotMeta meta;
  final RankAnalysis analysis;

  String get title => sourceName(meta.source);

  String get subtitle {
    final parts = <String>[meta.board];
    if (meta.category != null && meta.category!.isNotEmpty) {
      parts.add(meta.category!);
    }
    parts.add(meta.dateKey);
    return parts.join(' · ');
  }

  /// 状态胶囊：数据到手 / 有数据但有问题 / 空或被拦。
  (String, int) get statusBadge {
    if (meta.count == 0) return ('无数据', 2);
    if (!meta.ok) return ('有问题', 1);
    return ('数据到手', 0);
  }

  String? get qualitySummary => meta.result.quality?.summary;
  List<String> get problems => meta.result.quality?.problems ?? const [];
  String? get robots => meta.result.robotsVerdict;
  String? get sourceUrl => meta.result.sourceUrl;
}

/// 跨榜分析里的一个题材。
class CategoryStat {
  CategoryStat(this.category, this.count, this.bestRank, this.avgWords);
  final String category;
  final int count;
  final int bestRank;
  final int? avgWords;
}

/// 一个平台的**题材画像** —— 「跨榜分析」用来做跨平台对比。
///
/// ★ 为什么要有这个类型：各平台的分类体系**根本不同**（起点 玄幻/仙侠/都市，
///   番茄 都市高武/架空历史，晋江整站只有"言情"），名字对不齐。
///   所以跨平台能比的只有两样：**题材数**与**集中度**（头部题材占多少）。
///   把这两个口径固化成类型 + getter，就不会有人在别处各算一遍（算岔了也看不出来）。
class PlatformCategoryProfile {
  PlatformCategoryProfile(this.source, List<CategoryStat> stats)
      : sorted = ([...stats]..sort((a, b) => b.count.compareTo(a.count))),
        total = stats.fold<int>(0, (a, b) => a + b.count);

  final String source;

  /// 按条数降序。
  final List<CategoryStat> sorted;
  final int total;

  int get categoryCount => sorted.length;

  /// 头部单题材占比（0~1）。
  double get top1Share => total == 0 ? 0 : sorted.first.count / total;

  /// 头部三题材占比（0~1）—— **跨平台唯一可直接比长短的数**。
  double get top3Share =>
      total == 0 ? 0 : sorted.take(3).fold<int>(0, (a, b) => a + b.count) / total;

  /// 该平台是否**没有细分题材**（只有一个题材，或数据缺失）。
  ///
  /// ★ 这种平台的集中度必然是 100%，但那是"没细分"而不是"极度集中" ——
  ///   界面上必须标出来，否则结论会被读反。
  bool get coarse => sorted.length <= 1;

  /// 「玄幻 34% · 都市 20% · 仙侠 17%」这种一句话摘要。
  String topSummary([int n = 3]) => sorted
      .take(n)
      .map((c) => '${c.category} ${(c.count / total * 100).toStringAsFixed(0)}%')
      .join(' · ');
}

/// 把 `ViewModel.bySource` 转成可对比的平台画像列表（跳过没有题材数据的平台）。
List<PlatformCategoryProfile> buildPlatformProfiles(
    Map<String, List<CategoryStat>> bySource) {
  final out = <PlatformCategoryProfile>[];
  for (final e in bySource.entries) {
    if (e.value.isEmpty) continue;
    final p = PlatformCategoryProfile(e.key, e.value);
    if (p.total == 0) continue;
    out.add(p);
  }
  return out;
}

/// 一本书出现在哪些榜。
class CrossBoardBook {
  CrossBoardBook(this.title, this.boards, this.obfuscated);
  final String title;
  final List<String> boards;
  final bool obfuscated;
}

/// 全部视图数据。
class ViewModel {
  ViewModel({
    required this.groups,
    required this.bySource,
    required this.all,
    Set<String>? hidden,
  }) : hidden = hidden ?? const <String>{};

  /// 侧栏分组（**已剔除隐藏项**；每组带 `hiddenCount` 供界面如实提示）。
  final List<SourceGroup> groups;

  /// 平台 → 题材统计（按平台各自统计，不混合；**只统计可见项**）。
  final Map<String, List<CategoryStat>> bySource;

  /// **全部**快照（新→旧，含隐藏项）。
  ///
  /// ★ 保留全部是有意的：按 id 查一份快照（明细页、导出、附件）必须能找到
  ///   被隐藏的那些 —— "隐藏"只是侧栏不显示，不是数据不存在。
  final List<SnapshotMeta> all;

  /// 被用户隐藏的系列键（`SnapshotMeta.seriesKey`）。
  final Set<String> hidden;

  bool isHidden(SnapshotMeta m) => hidden.contains(m.seriesKey);

  /// 可见快照（新→旧）。
  List<SnapshotMeta> get visible =>
      [for (final m in all) if (!isHidden(m)) m];

  /// 可见份数（侧栏与状态栏都该用这个，否则"隐藏了还显示 20 份"）。
  int get snapshotCount => visible.length;

  int get recordCount => visible.fold<int>(0, (a, m) => a + m.count);

  /// 被隐藏的份数。
  int get hiddenCount => all.length - visible.length;

  /// 跨榜同时出现的书（只算可见项）。
  List<CrossBoardBook> crossBoardBooks() {
    final index = SnapshotIndex.fromItems(visible);
    final ov = overview(index);
    final list = (ov['cross_board_books'] as List?) ?? const [];
    return [
      for (final e in list)
        if (e is Map)
          CrossBoardBook(
            '${e['title']}',
            ((e['boards'] as List?) ?? const []).map((x) => '$x').toList(),
            e['obf'] == true,
          )
    ];
  }

  /// 从磁盘加载。
  ///
  /// [hidden] 是用户隐藏的系列键 —— 传进来后所有"聚合视图"（侧栏分组、
  /// 题材分布、跨榜信号）都会把它当作不存在，与"不显示"的直觉一致。
  static ViewModel load(String outRoot,
      {List<String>? errors, Set<String>? hidden}) {
    final index = SnapshotIndex.load(outRoot, errors: errors);
    return fromIndex(index, hidden: hidden);
  }

  static ViewModel fromIndex(SnapshotIndex index, {Set<String>? hidden}) {
    final hid = hidden ?? const <String>{};
    bool vis(SnapshotMeta m) => !hid.contains(m.seriesKey);

    final groups = <SourceGroup>[];
    void addGroup(String s) {
      final allOfSource = index.items.where((m) => m.source == s).toList();
      final shown = [for (final m in allOfSource) if (vis(m)) SnapshotItem(m)];
      if (shown.isEmpty && allOfSource.isEmpty) return;
      groups.add(SourceGroup(s, shown,
          hiddenCount: allOfSource.length - shown.length));
    }

    for (final s in sourceNames.keys) {
      addGroup(s);
    }
    // 兜底：sourceNames 里有没覆盖到的平台
    final known = sourceNames.keys.toSet();
    final extra = index.items.map((m) => m.source).toSet().difference(known);
    for (final s in extra) {
      addGroup(s);
    }

    // 平台内题材统计（复用 report_data 的 overview 口径，只喂可见项）
    final ov = overview(SnapshotIndex.fromItems(
        [for (final m in index.items) if (vis(m)) m]));
    final perSource = (ov['per_source'] as Map?) ?? const {};
    final bySource = <String, List<CategoryStat>>{};
    for (final e in perSource.entries) {
      final rows = (e.value as List?) ?? const [];
      bySource['${e.key}'] = [
        for (final r in rows)
          if (r is Map)
            CategoryStat(
              '${r['category']}',
              (r['count'] as num?)?.toInt() ?? 0,
              (r['best_rank'] as num?)?.toInt() ?? 0,
              (r['avg_words'] as num?)?.toInt(),
            )
      ];
    }

    return ViewModel(
        groups: groups, bySource: bySource, all: index.items, hidden: hid);
  }
}

// ─────────────────── 时间序列（跨时间段自身对比）───────────────────

/// 时间区间过滤档位。
///
/// ★ 语义是"要**最近**多少期"，而不是"从哪天起"——
///   因为快照不是每天都有（用户可能隔几天扫一次），
///   按"期数"取比按"天数"取更贴合实际数据密度。
enum TimeRange {
  last7('近 7 期', 7),
  last30('近 30 期', 30),
  all('全部', 0);

  const TimeRange(this.label, this.maxPeriods);
  final String label;

  /// 0 = 不限。
  final int maxPeriods;

  /// 按档位截取序列的**尾部**（保留最近的 N 期，顺序不变）。
  List<IndexEntry> apply(List<IndexEntry> entries) {
    if (maxPeriods <= 0 || entries.length <= maxPeriods) return entries;
    return entries.sublist(entries.length - maxPeriods);
  }
}

/// 时间序列视图：把一个系列的快照按时间排开，作为"与自身历史对比"的输入。
///
/// ★ 与旧的 [DiffView] 的根本区别：
///   旧的是"用户手挑两份文件 → 一张差异表"，用户得自己判断哪两份可比；
///   新的是"这一张榜的所有历史 → 一条时间线"，对比基准就是它自己。
class SeriesView {
  SeriesView({
    required this.entries,
    required this.analysis,
    required this.range,
    required this.errors,
  });

  /// 参与时间线的条目（旧→新，已按期数截断）。
  final List<IndexEntry> entries;

  /// 装配好的时间序列分析。
  final TimeSeriesAnalysis analysis;

  /// 当前区间档位。
  final TimeRange range;

  /// 装配期间的问题（缺数据、坏文件），如实上报。
  final List<String> errors;

  int get periodCount => analysis.periodCount;
  bool get hasComparison => analysis.hasComparison;

  /// 这个系列在**未截断**时的总期数（用于提示"共 N 期，当前显示近 7 期"）。
  int totalPeriods = 0;

  /// 截断前的完整输入（用于"全部"档位切换时不再重读磁盘）。
  List<IndexEntry> allEntries = const [];
}

/// 装配一个系列的时间序列视图。
///
/// [allSeriesEntries] 是该系列**全部**条目（旧→新或任意顺序都行，内部会排）。
/// [results] 是 `id → RankResult`，由调用方按需加载（只加载参与区间的那几期，
/// 避免"保留 100 期"时每帧都读 100 个文件）。
SeriesView buildSeriesView({
  required List<IndexEntry> allSeriesEntries,
  required Map<String, RankResult> results,
  required TimeRange range,
}) {
  final sorted = [...allSeriesEntries]
    ..sort((a, b) {
      final c = a.fetchedAt.compareTo(b.fetchedAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  final selected = range.apply(sorted);
  final errors = <String>[];
  final analysis = buildTimeSeries(selected, results, errors: errors);
  return SeriesView(
    entries: selected,
    analysis: analysis,
    range: range,
    errors: errors,
  )
    ..totalPeriods = sorted.length
    ..allEntries = sorted;
}

/// 按系列键把全部快照分组。
///
/// 供"侧栏选中一份快照 → 自动定位到它所属的系列"用；也供跨榜分析复用。
Map<String, List<IndexEntry>> groupBySeries(List<IndexEntry> entries) {
  final out = <String, List<IndexEntry>>{};
  for (final e in entries) {
    (out[e.seriesKey] ??= []).add(e);
  }
  return out;
}

/// 把旧索引的 [SnapshotMeta] 桥接成新索引的 [IndexEntry]。
///
/// ★ 为什么需要这座桥：侧栏/明细页消费的是 [SnapshotMeta]（`snapshot_index.dart`），
///   而时间线、保留策略、图片附件这一整套新能力建立在 [IndexEntry]
///   （`snapshot_index_file.dart`，带稳定 id + 相对路径 + 附件列表）之上。
///   两套结构短期并存（前者被导出/报告广泛引用，不能一刀切删），
///   所以这里做一次无损转换，让时间线能直接吃侧栏选中的那份快照。
IndexEntry metaToEntry(SnapshotMeta m) {
  final e = m.result;
  final catName = e.query.categoryName?.trim();
  final normCat = (catName == null || catName.isEmpty ||
          catName == '全站' || catName == '全部' || catName == '所有')
      ? null
      : catName;
  final rawId = e.query.categoryId?.trim();
  final normId = (rawId == null || rawId.isEmpty || rawId == '-1' || rawId == '0')
      ? null
      : rawId;
  final y = e.fetchedAt.year.toString().padLeft(4, '0');
  final mo = e.fetchedAt.month.toString().padLeft(2, '0');
  final d = e.fetchedAt.day.toString().padLeft(2, '0');
  final dateKey = '$y$mo$d';
  final catPart = normCat == null ? (normId ?? '-') : '$normCat#${normId ?? '-'}';
  return IndexEntry(
    id: '${e.query.source}|${e.query.board}|$catPart|$dateKey',
    source: e.query.source,
    board: e.query.board,
    category: normCat,
    categoryId: normId,
    dateKey: dateKey,
    fetchedAt: e.fetchedAt,
    count: e.entries.length,
    ok: e.quality?.ok ?? e.entries.isNotEmpty,
    relFile: _relOf(m),
  );
}

/// 从 [SnapshotMeta.file] 反推相对 `out/` 的路径（新索引要求 relFile）。
///
/// 找不到 `扫榜` 这一层就退回文件名 —— 时间线只需要"能定位到这个 id 的数据"，
/// 而我们本来就有 meta 在手，路径不完美的场合调用方会直接用 meta。
String _relOf(SnapshotMeta m) {
  final p = m.file.path.replaceAll('\\', '/');
  final i = p.indexOf('/扫榜/');
  if (i >= 0) return p.substring(i + 1);
  final segs = p.split('/');
  return segs.isEmpty ? p : '扫榜/${segs.last}';
}

/// 批量转换并去重（同一 id 只留一份，避免同日重复文件把期数算多）。
List<IndexEntry> metasToEntries(Iterable<SnapshotMeta> metas) {
  final byId = <String, IndexEntry>{};
  for (final m in metas) {
    final e = metaToEntry(m);
    byId[e.id] = e;
  }
  return byId.values.toList();
}

/// 时间线的摘要数字（概览卡用，纯统计）。
class SeriesSummary {
  const SeriesSummary({
    required this.periodCount,
    required this.countFirst,
    required this.countLatest,
    required this.totalWordsFirst,
    required this.totalWordsLatest,
    required this.upCount,
    required this.downCount,
    required this.freshCount,
    required this.goneCount,
    required this.evergreenCount,
  });

  final int periodCount;
  final int countFirst;
  final int countLatest;
  final int? totalWordsFirst;
  final int? totalWordsLatest;
  final int upCount;
  final int downCount;
  final int freshCount;
  final int goneCount;
  final int evergreenCount;

  static SeriesSummary of(TimeSeriesAnalysis a) => SeriesSummary(
        periodCount: a.periodCount,
        countFirst: a.firstCount,
        countLatest: a.latestCount,
        totalWordsFirst: a.firstTotalWords,
        totalWordsLatest: a.latestTotalWords,
        upCount: a.movers.upCount,
        downCount: a.movers.downCount,
        freshCount: a.movers.freshCount,
        goneCount: a.movers.goneCount,
        evergreenCount: a.evergreens.length,
      );
}

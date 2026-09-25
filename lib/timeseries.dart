/// 时间序列分析 —— 「同一张榜，跨时间段与自身对比」。
///
/// ★ 这一层取代了旧版"手选两份快照看差分"的语义：
///   对比的基准不该是用户挑的另一份文件，而应当是**这张榜自己的历史**。
///   于是同一系列（同平台+同榜+同题材）的每一份快照按时序排开，
///   看的是"这本书的名次/数据在这段时间里怎么变的"。
///
/// ★ 严格遵守"只出数字，不做原因推断"：
///   这里只产出**可验证的统计事实**（变化了多少名、升了几期、跌了几期、
///   连续同向多少期），一个字的原因解读都不写 —— 原因交给用户/模型去判断，
///   避免把"看起来合理的因果"当成结论输出。
///
/// ★ 逐期变化的定义（防止把"掉榜"渲染成"暴涨"）：
///   排名变化 = 上一期名次 − 本期名次（正 = 上升）。
///   任一期名次 ≤ 0（未上榜）时该期变化为 null，绝不参与汇总，
///   否则 `0 − 5 = −5` 这类伪变化会污染"上升最快"。
library;

import 'analysis.dart';
import 'models.dart';
import 'snapshot_index_file.dart';

/// 序列里的一个时点（一期快照，携带已经解析好的原始数据）。
class SeriesPoint {
  const SeriesPoint({
    required this.entry,
    required this.result,
  });

  final IndexEntry entry;
  final RankResult result;

  String get dateKey => entry.dateKey;

  /// `20260924` → `09-24`（表头短标签）。
  String get shortDate {
    final d = dateKey;
    if (d.length != 8) return d;
    return '${d.substring(4, 6)}-${d.substring(6, 8)}';
  }

  /// 展示用日期（`2026-09-24`）。
  String get isoDate {
    final d = dateKey;
    if (d.length != 8) return d;
    return '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)}';
  }
}

/// 一本书在整条时间线上的轨迹。
class BookTrack {
  BookTrack({required this.key, required this.title, required this.author});

  /// 主键：bookId 优先（书名会重名/会被字体混淆），缺失才退到书名。
  final String key;
  final String title;
  final String author;

  /// 按期（旧→新）排列的 (期号, 名次, 指标值, 字数)。名次 0 = 该期未上榜。
  final List<TrackPoint> points = [];

  String get label => title.isEmpty ? key : title;

  bool get obfuscated =>
      title.isNotEmpty && title.codeUnits.any((c) => c >= 0xE000 && c <= 0xF8FF);

  /// 有排名的期数。
  int get listedPeriods => points.where((p) => p.rank > 0).length;

  /// 最新一期是否在榜。
  bool get listedNow => points.isNotEmpty && points.last.rank > 0;

  /// 最新一期名次（未上榜 = 0）。
  int get lastRank => points.isEmpty ? 0 : points.last.rank;

  /// 首期名次（未上榜 = 0）。
  int get firstRank => points.isEmpty ? 0 : points.first.rank;

  /// 最新一期与上一期的排名变化（正 = 上升）；任一期未上榜 → null。
  int? get latestRankChange {
    if (points.length < 2) return null;
    final prev = points[points.length - 2];
    final curr = points.last;
    if (prev.rank <= 0 || curr.rank <= 0) return null;
    return prev.rank - curr.rank;
  }

  /// 最新一期与首次上榜那一期的排名变化（正 = 比首次更好）。
  int? get sinceFirstRankChange {
    final firstListed = points.where((p) => p.rank > 0).toList();
    if (firstListed.length < 2) return null;
    final a = firstListed.first.rank;
    final b = firstListed.last.rank;
    if (a <= 0 || b <= 0) return null;
    return a - b;
  }

  /// 相对上一期的字数变化。
  int? get latestWordsChange {
    if (points.length < 2) return null;
    final p = points[points.length - 2].words;
    final c = points.last.words;
    if (p == null || c == null) return null;
    return c - p;
  }

  /// 相对上一期的指标变化（跳过 words 这类体量指标）。
  num? get latestMetricChange {
    if (points.length < 2) return null;
    final p = points[points.length - 2].metric;
    final c = points.last.metric;
    if (p == null || c == null) return null;
    return c - p;
  }

  /// 连续上升期数（数到最新一期为止，一路向上）。
  ///
  /// ★ "掉榜"与"新上榜"要算进方向，否则会撒谎：
  ///   - 书从 #1 → #5 → **掉榜**，这是连续 2 期在跌。若把掉榜当成"中途断档"
  ///     直接 break，就会报 `streakDown = 0`，读起来像"最近没跌"——
  ///     而它其实刚跌出榜单。所以**掉榜视作下降的延续**。
  ///   - 反过来 `— → #2 → #1` 是连续 2 期在涨，新上榜视作上升的延续。
  int get streakUp => _streak(1);
  int get streakDown => _streak(-1);

  int _streak(int dir) {
    var n = 0;
    for (var i = points.length - 1; i > 0; i--) {
      final a = points[i - 1].rank; // 上一期
      final b = points[i].rank; // 本期
      // 方向同上/下：>0 涨，<0 跌，0 平。
      int d;
      if (b <= 0 && a > 0) {
        d = -1; // 本期掉榜 = 一次下降
      } else if (a <= 0 && b > 0) {
        d = 1; // 本期新上榜 = 一次上升
      } else if (a <= 0 && b <= 0) {
        break; // 两期都不在榜：这条轨迹在这里就断了
      } else {
        d = (a - b).sign;
      }
      if (d == 0) break;
      if ((d > 0) != (dir > 0)) break;
      n++;
    }
    return n;
  }

  /// 轨迹数组（按期，旧→新），名次 0 用 null 表示"未上榜"（画折线要断点）。
  List<int?> get rankSeries => [for (final p in points) p.rank > 0 ? p.rank : null];

  /// 指标轨迹（按期，旧→新）。**未上榜的期返回 null**（折线在那里断开）。
  ///
  /// ★ 为什么未上榜也要断：那本书那一期不在榜上，就没有"它的指标值"这个观测 ——
  ///   补 0 会在图上画出一条"掉到底"的假线，补上期的值会画出一条"没变化"的假线。
  ///   两个都是在编数据。
  ///
  /// ★ 为什么单独一个 getter：用户要"每本书**各自数据变化**的折线图"，
  ///   而 [rankSeries] 只有名次。指标（月票 / 热度 / 积分）才是"数据"。
  List<double?> get metricSeries => [
        for (final p in points)
          p.rank > 0 && p.metric != null ? p.metric!.toDouble() : null,
      ];

  /// 字数轨迹（按期，旧→新）。缺失同样返回 null。
  List<double?> get wordsSeries => [
        for (final p in points)
          p.rank > 0 && p.words != null ? p.words!.toDouble() : null,
      ];

  /// 指标序列里"有效观测"的期数（≥2 才画得出趋势）。
  int get metricPeriods => metricSeries.where((v) => v != null).length;

  /// 字数序列里"有效观测"的期数。
  int get wordsPeriods => wordsSeries.where((v) => v != null).length;
}

/// 一本书在某一期的观测。
class TrackPoint {
  const TrackPoint({
    required this.periodIndex,
    required this.rank,
    this.metric,
    this.words,
  });

  /// 期号（0 起，0 = 最早）。
  final int periodIndex;
  final int rank;
  final num? metric;
  final int? words;
}

/// 一次变化最大的书（用于"上升最快/下降最快"）。
class Mover {
  const Mover(this.track, this.change, this.fromRank, this.toRank);
  final BookTrack track;

  /// 名次变化（正 = 上升）。
  final int change;
  final int fromRank;
  final int toRank;

  String get label {
    final t = track.title;
    return track.obfuscated ? '$t〔名待补〕' : (t.isEmpty ? track.key : t);
  }
}

/// 整条时间线的分析结果（纯数字，无原因推断）。
class TimeSeriesAnalysis {
  TimeSeriesAnalysis({
    required this.seriesKey,
    required this.board,
    required this.category,
    required this.points,
    required this.tracks,
    required this.movers,
  });

  /// 系列标识（`{source}|{board}|{category}`）。
  final String seriesKey;
  final String board;
  final String? category;

  /// 按期（旧→新）。
  final List<SeriesPoint> points;

  /// 每本书的轨迹（按期数从多到少、再按最新名次排）。
  final List<BookTrack> tracks;

  /// 最新一期相对上一期的变化榜（已在内部按涨/跌/新/掉分好）。
  final MoverGroups movers;

  int get periodCount => points.length;

  bool get hasComparison => points.length >= 2;

  /// 首期 → 末期。
  String get rangeLabel {
    if (points.isEmpty) return '—';
    if (points.length == 1) return points.first.isoDate;
    return '${points.first.isoDate} → ${points.last.isoDate}';
  }

  /// 最新一期的上榜数。
  int get latestCount => points.isEmpty ? 0 : points.last.result.entries.length;

  /// 首期的上榜数。
  int get firstCount => points.isEmpty ? 0 : points.first.result.entries.length;

  /// 最新一期总字数（所有在榜书的 words 之和）。
  int? get latestTotalWords => _totalWords(points.isEmpty ? null : points.last);

  /// 首期总字数。
  int? get firstTotalWords => _totalWords(points.isEmpty ? null : points.first);

  static int? _totalWords(SeriesPoint? p) {
    if (p == null) return null;
    var sum = 0;
    var any = false;
    for (final e in p.result.entries) {
      final w = e.metrics['words'];
      if (w is num && w.isFinite) {
        sum += w.toInt();
        any = true;
      }
    }
    return any ? sum : null;
  }

  /// 全期都在榜的书。
  List<BookTrack> get evergreens =>
      tracks.where((t) => t.listedPeriods == periodCount && periodCount > 0).toList();

  /// 最新一期才出现的书（新上榜）。
  List<BookTrack> get freshNow => tracks.where((t) {
        if (!t.listedNow) return false;
        if (t.points.isEmpty) return false;
        // 之前所有期都未上榜，最新一期在榜。
        return t.points
            .sublist(0, t.points.length - 1)
            .every((p) => p.rank <= 0);
      }).toList();

  /// 最新一期未上榜、但之前在榜过的书（掉榜）。
  List<BookTrack> get goneNow => tracks.where((t) {
        if (t.listedNow) return false;
        if (t.points.isEmpty) return false;
        return t.points.any((p) => p.rank > 0);
      }).toList();

  /// 各期上榜数序列（旧→新）。
  List<int> get countSeries =>
      [for (final p in points) p.result.entries.length];
}

/// 变化分组（新上/上升/下降/掉榜）。
class MoverGroups {
  MoverGroups({
    required this.fresh,
    required this.up,
    required this.down,
    required this.gone,
  });

  final List<Mover> fresh;
  final List<Mover> up;
  final List<Mover> down;
  final List<Mover> gone;

  int get freshCount => fresh.length;
  int get upCount => up.length;
  int get downCount => down.length;
  int get goneCount => gone.length;
}

/// 把一串 [IndexEntry]（同一系列）装配成时间线分析。
///
/// [results] 由调用方提供：`id → RankResult`。缺数据的条目会被**跳过并记录**，
/// 而不是安安静静少一期（否则用户看到的"连续 N 期"是假的）。
TimeSeriesAnalysis buildTimeSeries(
  List<IndexEntry> seriesEntries,
  Map<String, RankResult> results, {
  List<String>? errors,
}) {
  // ① 按期排序（旧→新）。同一 id 只会出现一次（索引本身保证）。
  final sorted = [...seriesEntries]
    ..sort((a, b) {
      final c = a.fetchedAt.compareTo(b.fetchedAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });

  final points = <SeriesPoint>[];
  for (final e in sorted) {
    final r = results[e.id];
    if (r == null) {
      errors?.add('快照 ${e.id} 数据缺失，已从时间线中跳过');
      continue;
    }
    points.add(SeriesPoint(entry: e, result: r));
  }

  final board = sorted.isEmpty ? '' : sorted.first.board;
  final category = sorted.isEmpty ? null : sorted.first.category;
  final seriesKey = sorted.isEmpty ? '' : sorted.first.seriesKey;

  // ② 组装每本书的轨迹。
  String keyOf(RankEntry e) =>
      (e.bookId == null || e.bookId!.isEmpty) ? 'title:${e.title}' : 'id:${e.bookId}';

  final tracks = <String, BookTrack>{};
  for (var pi = 0; pi < points.length; pi++) {
    for (final e in points[pi].result.entries) {
      // ★★ 书名被字体混淆、又拿不到 bookId 的条目**不能参与身份匹配**：
      //   它的"名字"每次抓取都是一串不同的私用区乱码 → 同一本书会被拆成
      //   好几条 track，`freshNow`/`goneNow`/中位数变动全部虚高
      //   （表现成"某天突然上了 20 本新书"，其实一本书都没变）。
      //   宁可少一条轨迹，也不能造出假的新书。
      if (e.titleObfuscated && (e.bookId == null || e.bookId!.isEmpty)) {
        continue;
      }
      final k = keyOf(e);
      final t = tracks.putIfAbsent(
          k, () => BookTrack(key: k, title: e.title, author: e.author));
      t.points.add(TrackPoint(
        periodIndex: pi,
        rank: e.rank,
        metric: _pickMetric(e),
        words: _words(e),
      ));
    }
  }
  // ★ 轨迹补全：某期不在榜时也要有一个 rank=0 的点，否则折线图和"连续 N 期"
  //   都会把"中间掉过榜"错算成"一直上升"。
  for (final t in tracks.values) {
    t.points.sort((a, b) => a.periodIndex.compareTo(b.periodIndex));
    final full = <TrackPoint>[];
    var idx = 0;
    for (var pi = 0; pi < points.length; pi++) {
      if (idx < t.points.length && t.points[idx].periodIndex == pi) {
        full.add(t.points[idx]);
        idx++;
      } else {
        full.add(TrackPoint(periodIndex: pi, rank: 0));
      }
    }
    t.points
      ..clear()
      ..addAll(full);
  }

  final trackList = tracks.values.toList()
    ..sort((a, b) {
      // 在榜期数多的在前 → 最新名次靠前的在前 → 名字兜底稳定排序。
      final c = b.listedPeriods.compareTo(a.listedPeriods);
      if (c != 0) return c;
      final ar = a.lastRank <= 0 ? 9999 : a.lastRank;
      final br = b.lastRank <= 0 ? 9999 : b.lastRank;
      final d = ar.compareTo(br);
      if (d != 0) return d;
      return a.title.compareTo(b.title);
    });

  return TimeSeriesAnalysis(
    seriesKey: seriesKey,
    board: board,
    category: category,
    points: points,
    tracks: trackList,
    movers: _movers(trackList),
  );
}

/// 最新一期相对上一期的变化分组。
MoverGroups _movers(List<BookTrack> tracks) {
  final fresh = <Mover>[];
  final up = <Mover>[];
  final down = <Mover>[];
  final gone = <Mover>[];

  for (final t in tracks) {
    if (t.points.length < 2) continue;
    final prev = t.points[t.points.length - 2];
    final curr = t.points.last;
    if (curr.rank <= 0) {
      if (prev.rank > 0) {
        gone.add(Mover(t, 0, prev.rank, 0));
      }
      continue;
    }
    if (prev.rank <= 0) {
      fresh.add(Mover(t, 0, 0, curr.rank));
      continue;
    }
    final chg = prev.rank - curr.rank;
    if (chg > 0) {
      up.add(Mover(t, chg, prev.rank, curr.rank));
    } else if (chg < 0) {
      down.add(Mover(t, chg, prev.rank, curr.rank));
    }
  }
  up.sort((a, b) => b.change.compareTo(a.change));
  down.sort((a, b) => a.change.compareTo(b.change));
  fresh.sort((a, b) => a.toRank.compareTo(b.toRank));
  gone.sort((a, b) => a.fromRank.compareTo(b.fromRank));

  return MoverGroups(fresh: fresh, up: up, down: down, gone: gone);
}

/// 热度指标键的**固定优先级**（越靠前越优先）。
///
/// ★★ 不能用"插入顺序里第一个非 words 的键"：那等于让 **JSON 字段顺序**
///   决定结论。同一本书两次快照若键序变了（换个接口版本就会），
///   `latestMetricChange` 就会拿"月票"去减"在读"，算出一个**看起来正常的假数字**
///   —— 比缺数据危险得多。固定成优先级表之后，同一张榜每次挑的都是同一个键。
const List<String> _heatKeyPriority = [
  'yuepiao', // 起点：月票
  'reading', // 番茄：在读
  'heat', // 七猫：热度
  'recommend', // 起点：推荐票
  'collect', // 收藏
  'click', // 点击
];

num? _pickMetric(RankEntry e) {
  for (final k in _heatKeyPriority) {
    final v = e.metrics[k];
    if (v is num && v.isFinite) return v;
  }
  // 优先级表里都没有 → 退到"按字母序第一个非 words 键"（仍然确定，不随字段序变）
  final rest = e.metrics.keys.where((k) => k != 'words').toList()..sort();
  for (final k in rest) {
    final v = e.metrics[k];
    if (v is num && v.isFinite) return v;
  }
  return null;
}

int? _words(RankEntry e) {
  final w = e.metrics['words'];
  if (w is num && w.isFinite) return w.toInt();
  return null;
}

/// 指标键 → 中文标签（表头用）。
String metricLabel(String? key) {
  switch (key) {
    case 'monthticket':
      return '月票';
    case 'recommend':
      return '推荐';
    case 'reading':
      return '在读';
    case 'collect':
      return '收藏';
    case 'heat':
      return '热度';
    case 'score':
      return '积分';
    case 'fans':
      return '粉丝';
    case 'updatewords':
      return '更新字数';
    default:
      return key == null || key.isEmpty ? '指标' : key;
  }
}

/// 找出整条序列里"第一个非 words 指标"的键名（表头/明细列名统一口径）。
///
/// 不同期的指标键可能不完全一致（源站点改字段），以**最新一期**为准，
/// 再往前找；全都没有则返回 null（表头显示"指标"）。
String? dominantMetricKey(TimeSeriesAnalysis ts) {
  for (final p in ts.points.reversed) {
    for (final e in p.result.entries) {
      for (final k in e.metrics.keys) {
        if (k != 'words') return k;
      }
    }
  }
  return null;
}

/// 把一条轨迹渲染成"期次序列"文本，如 `#3 → #5 → #2`（未上榜显示 `—`）。
String rankTrail(BookTrack t, {int? maxPeriods}) {
  final pts = t.points;
  final start = maxPeriods == null || pts.length <= maxPeriods
      ? 0
      : pts.length - maxPeriods;
  final parts = <String>[];
  for (var i = start; i < pts.length; i++) {
    final r = pts[i].rank;
    parts.add(r > 0 ? '#$r' : '—');
  }
  return parts.join(' → ');
}

/// 数字变化的中文格式（带符号）。
String signedInt(int n) => n > 0 ? '+$n' : '$n';

/// 大字数的可读格式（对齐 analysis.dart 的口径）。
String wanText(int n) =>
    n >= 10000 ? '${(n / 10000).toStringAsFixed(1)}万' : '$n';

/// 千分位（指标展示用，避免读者数不清位数）。
String groupedInt(num n) {
  final s = n.abs().round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '${n < 0 ? '-' : ''}$buf';
}

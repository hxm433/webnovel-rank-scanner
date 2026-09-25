/// 数据契约 —— 与 `D:\OpenWrite-replica\lib\rank\rank_scan.dart` 保持同形。
///
/// 这里刻意**不重新发明**：字段名、截断归属、质量结构化这三条是他踩出来的，
/// demo 换语言/换工程也要一模一样，否则验证完还得返工。
library;

/// 一本书在某个榜上的一条记录。
class RankEntry {
  RankEntry({
    required this.rank,
    required this.title,
    required this.author,
    this.bookId,
    this.category,
    this.tags = const [],
    this.url,
    this.coverUrl,
    this.metrics = const {},
    this.extra = const {},
    this.titleObfuscated = false,
  });

  final int rank;
  final String title;
  final String author;

  /// ★ 跨快照主键。他原版用 title 做差分（书名会重名、会被字体混淆），
  /// demo 里把 bookId 提成一等字段。
  final String? bookId;

  final String? category;
  final List<String> tags;
  final String? url;

  /// 书封面图的 URL（第三方 CDN）。
  ///
  /// ★ 与 [url]（书详情页）分开存：一个是"给人看的页面"，一个是"给机器取的图"，
  ///   两者域名不同、可获取性也不同（封面 CDN 常常不需要 referer）。
  ///   取不到就是 null —— 界面画**占位卡**，绝不拿别的书的封面顶上。
  final String? coverUrl;

  /// 数值化指标。键名统一小写；**不同平台口径不同，禁止跨平台比大小**。
  final Map<String, num> metrics;

  /// 原文字符串（"6.09万月票"这种），派生值给人算，原值给人事后核。
  final Map<String, String> extra;

  /// 书名含私用区字符（字体反爬）→ 明文不可读，但仍可参与趋势统计。
  final bool titleObfuscated;

  Map<String, Object?> toJson() => {
        'rank': rank,
        'title': title,
        'author': author,
        if (bookId != null) 'book_id': bookId,
        if (category != null) 'category': category,
        if (tags.isNotEmpty) 'tags': tags,
        if (url != null) 'url': url,
        if (coverUrl != null) 'cover_url': coverUrl,
        if (metrics.isNotEmpty) 'metrics': metrics,
        if (extra.isNotEmpty) 'extra': extra,
        if (titleObfuscated) 'title_obfuscated': true,
      };

  static RankEntry fromJson(Map<String, Object?> j) => RankEntry(
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        title: (j['title'] as String?) ?? '',
        author: (j['author'] as String?) ?? '',
        bookId: j['book_id'] as String?,
        category: j['category'] as String?,
        tags: (j['tags'] as List?)?.whereType<String>().toList() ?? const [],
        url: j['url'] as String?,
        coverUrl: j['cover_url'] as String?,
        // ★ 指标必须**只保留能安全转成有限数的值**：
        //   ① `num.tryParse('abc') ?? 0` 会把"解析失败"洗成合法的 0，
        //      界面上 0 是正常值，用户会读到"这本书在读 0"；
        //   ② JSON 里的 `1e999` 解析成 Infinity，后面 `.toInt()`/`.round()` 直接抛。
        //   两条都是"脏数据被洗成看起来很干净的数"，所以这里直接丢弃异常值。
        metrics: _sanitizeMetrics((j['metrics'] as Map?) ?? const {}),
        extra: ((j['extra'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), '$v')),
        titleObfuscated: j['title_obfuscated'] == true,
      );

  /// 只保留 **有限** 的数值指标；非数且不可解析、或为 Infinity/NaN 的键直接丢掉。
  static Map<String, num> _sanitizeMetrics(Map<Object?, Object?> raw) {
    final out = <String, num>{};
    for (final e in raw.entries) {
      final v = e.value;
      num? n;
      if (v is num) {
        n = v;
      } else if (v is String) {
        n = num.tryParse(v.trim());
      }
      if (n == null || !n.isFinite) continue;
      out[e.key.toString()] = n;
    }
    return out;
  }
}

/// 一次采集的数据质量。
///
/// ★ 必须**结构化跟着数据走**：只印进 Markdown 的话，
/// 下游分析层会拿"只有书名没有指标"的数据去算热度排名。
class RankQuality {
  const RankQuality({
    required this.ok,
    required this.validCount,
    required this.totalCount,
    this.summary,
    this.problems = const [],
  });

  final bool ok;
  final int validCount;
  final int totalCount;
  final String? summary;
  final List<String> problems;

  /// 样本量低于此值即视为稀疏（主流平台 15）。
  bool get sparse => validCount < 15;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'valid_count': validCount,
        'total_count': totalCount,
        if (summary != null) 'summary': summary,
        if (problems.isNotEmpty) 'problems': problems,
      };

  static RankQuality fromJson(Map<String, Object?> j) => RankQuality(
        ok: j['ok'] == true,
        validCount: (j['valid_count'] as num?)?.toInt() ?? 0,
        totalCount: (j['total_count'] as num?)?.toInt() ?? 0,
        summary: j['summary'] as String?,
        problems: (j['problems'] as List?)?.whereType<String>().toList() ?? const [],
      );
}

class RankQuery {
  const RankQuery({
    required this.source,
    required this.board,
    this.limit = 50,
    this.categoryId,
    this.categoryName,
  });

  final String source;
  final String board;
  final int limit;
  final String? categoryId;
  final String? categoryName;

  Map<String, Object?> toJson() => {
        'source': source,
        'board': board,
        'limit': limit,
        if (categoryId != null) 'category_id': categoryId,
        if (categoryName != null) 'category_name': categoryName,
      };
}

class RankResult {
  RankResult({
    required this.query,
    required this.entries,
    required this.fetchedAt,
    this.truncated = false,
    this.quality,
    this.sourceUrl,
    this.robotsVerdict,
  });

  final RankQuery query;
  final List<RankEntry> entries;
  final DateTime fetchedAt;
  final bool truncated;
  final RankQuality? quality;
  final String? sourceUrl;

  /// ★ demo 新增：robots.txt 的实测判定结果，随报告一起出去。
  final String? robotsVerdict;

  Map<String, Object?> toJson() => {
        'query': query.toJson(),
        'fetched_at': fetchedAt.toIso8601String(),
        'truncated': truncated,
        if (sourceUrl != null) 'source_url': sourceUrl,
        if (robotsVerdict != null) 'robots': robotsVerdict,
        if (quality != null) 'quality': quality!.toJson(),
        'entries': [for (final e in entries) e.toJson()],
      };

  static RankResult fromJson(Map<String, Object?> j) {
    final q = (j['query'] as Map?) ?? const {};
    return RankResult(
      query: RankQuery(
        source: (q['source'] as String?) ?? '',
        board: (q['board'] as String?) ?? '',
        limit: (q['limit'] as num?)?.toInt() ?? 50,
        categoryId: q['category_id'] as String?,
        categoryName: q['category_name'] as String?,
      ),
      entries: [
        for (final e in ((j['entries'] as List?) ?? const []))
          if (e is Map) RankEntry.fromJson(e.cast<String, Object?>())
      ],
      fetchedAt: DateTime.tryParse('${j['fetched_at']}') ?? DateTime.now(),
      truncated: j['truncated'] == true,
      quality: j['quality'] is Map
          ? RankQuality.fromJson((j['quality'] as Map).cast<String, Object?>())
          : null,
      sourceUrl: j['source_url'] as String?,
      robotsVerdict: j['robots'] as String?,
    );
  }
}

/// 数据源适配器契约。**约定同原版**：
/// ① 网络失败返回空列表，不抛异常（由服务层包成 quality）；
/// ② 返回**未按 limit 截断**的候选集 —— 截断只归服务层，
///    否则 `truncated` 永远为 false，用户看不到"结果被截断"。
abstract class RankSourceAdapter {
  String get sourceId;
  String get displayName;
  List<String> get supportedBoards;

  /// 返回 (结果条目, 质量标注, 实际请求的 URL)。
  Future<FetchOutcome> fetch(RankQuery query);
}

class FetchOutcome {
  final List<RankEntry> entries;
  final RankQuality quality;
  final String? url;
  const FetchOutcome(this.entries, this.quality, {this.url});
}

/// 中文计数解析："4.41万月票"→44100、"910.07万字"→9100700。
///
/// ★ 必须支持**混合单位**。旧实现只看"含不含亿/万"、只取**第一个**数字、
///   乘一个因子，于是 `3亿5000万` 被算成 `3 * 1e8 * 1e4 = 3.5e12`
///   （正确值 3.5e8，错了 4 个数量级）。错误只在大数上出现，最难被注意。
///   现在改成按位权逐段累加：遇到"亿"就把已累计部分乘 1e8，
///   遇到"万"就乘 1e4，末尾没带单位的数按 1 计。
num? parseCnNumber(String raw) {
  final s = raw.trim().replaceAll(',', '');
  if (s.isEmpty) return null;
  final re = RegExp(r'([-+]?\d+(?:\.\d+)?)\s*([亿万]?)');
  var total = 0.0;
  var matched = false;
  for (final m in re.allMatches(s)) {
    final v = double.tryParse(m.group(1)!);
    if (v == null) continue;
    matched = true;
    final unit = m.group(2);
    final factor = switch (unit) {
      '亿' => 1e8,
      '万' => 1e4,
      _ => 1.0,
    };
    total += v * factor;
  }
  if (!matched) return null;
  if (!total.isFinite) return null;
  return total.round();
}

/// 从 rankCnt 之类的字符串反推指标口径（比按榜单名硬编码可靠）。
///
/// 认不出来就返回 null —— 调用方据此**保留原文**（放进 `extra.rankCntRaw`），
/// 而不是把指标整段丢掉。丢掉的话会出现"畅销榜一个热度数值都没有、
/// quality 却报 ok"这种看着正常、实则数据缺一半的情况。
String? metricKeyFromUnit(String raw) {
  if (raw.contains('月票')) return 'monthticket';
  if (raw.contains('推荐')) return 'recommend';
  if (raw.contains('在读')) return 'reading';
  if (raw.contains('收藏')) return 'collect';
  if (raw.contains('热度')) return 'heat';
  if (raw.contains('积分')) return 'score';
  if (raw.contains('粉丝')) return 'fans';
  if (raw.contains('更字') || raw.contains('更新')) return 'updatewords';
  return null;
}

/// 码点安全的简介截断（不切坏代理对）。
String truncateIntro(String s, {int max = 100}) {
  final t = s.trim();
  if (t.charactersLength <= max) return t;
  var cut = t.safeSubstring(max);
  final last = cut.lastIndexOf(RegExp(r'[。！？!?…;；]'));
  if (last > 20) cut = cut.safeSubstring(last + 1);
  return '$cut...';
}

/// 私用区字符数（字体反爬特征）。
int privateUseCount(String s) =>
    s.codeUnits.where((c) => c >= 0xE000 && c <= 0xF8FF).length;

extension on String {
  int get charactersLength => length; // demo 简化：仍按 code unit，但配合下面的安全切分

  String safeSubstring(int max) {
    if (max <= 0) return '';
    if (length <= max) return this;
    var end = max;
    final at = codeUnitAt(end);
    if (at >= 0xDC00 && at <= 0xDFFF) end -= 1;
    return substring(0, end);
  }
}

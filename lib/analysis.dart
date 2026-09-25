/// 确定性分析：**代码算数，模型解读**。
///
/// 结论要可复现、数字不能算错，所以题材分布/字数区间/热词/差分全部在代码里，
/// 模型只负责在"已经算好的数字"之上做解读。
library;

import 'models.dart';

class CategoryShare {
  const CategoryShare({
    required this.category,
    required this.count,
    required this.ratio,
    required this.bestRank,
    this.trend = 0,
  });
  final String category;
  final int count;
  final double ratio;
  final int bestRank;
  final int trend;
}

class RankTrend {
  const RankTrend({
    required this.key,
    required this.title,
    required this.prevRank,
    required this.currRank,
    this.prevMetric,
    this.currMetric,
  });
  final String key;
  final String title;
  final int prevRank;
  final int currRank;
  final num? prevMetric;
  final num? currMetric;

  /// 排名变化（正 = 上升）。
  ///
  /// ★ 掉榜时也必须返回 null：`prevRank - currRank` 在 currRank=0 时
  ///   会得到一个很大的正数，把"已经掉出榜"的书渲染成"上升最快"。
  ///   （原版 `rank_analysis.dart` 只在 `isNew` 上做了防护，没防 `dropped`，
  ///   这个 demo 用真实数据跑差分时踩到了。）
  int? get rankChange => (prevRank <= 0 || currRank <= 0) ? null : prevRank - currRank;
  bool get isNew => prevRank <= 0;
  bool get dropped => currRank <= 0;
  num? get metricChange {
    if (prevMetric == null || currMetric == null) return null;
    return currMetric! - prevMetric!;
  }

  /// 跃升打分（照抄两个 Tracker 的公式）：排名进步 60% + 指标增长 40%。
  ///
  /// ★ 下降必须保留**负号**，不能 clamp 到 0。
  ///   以前两个分量都被 `.clamp(0, ·)` 截掉负数，于是**所有掉名的书 jumpScore
  ///   恒等于 0.0**，而 `toMarkdown` 里"下降最快"正是按它升序取前 5 ——
  ///   结果跌得最狠的排在最后，"下降最快"这个结论直接是错的。
  ///   实测：A 跌 1 名、B 跌 2 名，两者都算 0.0，输出顺序是 A(-1)、B(-2)。
  ///
  ///   现在改成按**绝对值**封顶（保留方向）：|排名变化| > 20 视为满分，
  ///   |指标变化| > 100% 视为满分。上升得正分、下降得负分，排序才有意义。
  double get jumpScore {
    final rcRaw = rankChange ?? 0;
    final rc = rcRaw.abs().clamp(0, 20) / 20.0 * (rcRaw < 0 ? -1 : 1);
    double hgp = 0;
    if (prevMetric != null && prevMetric! > 0 && currMetric != null) {
      final pct = (currMetric! - prevMetric!) / prevMetric! * 100;
      if (pct.isFinite) {
        hgp = pct.abs().clamp(0, 100).toDouble() * (pct < 0 ? -1 : 1);
      }
    }
    return 0.6 * rc * 100 + 0.4 * hgp;
  }
}

class RankAnalysis {
  RankAnalysis({
    required this.categories,
    required this.wordRange,
    required this.titleKeywords,
    required this.tagKeywords,
    required this.trends,
    required this.newCategories,
    required this.sampleSize,
    required this.obfuscatedCount,
    this.skippedForKeywords = 0,
  });

  final List<CategoryShare> categories;
  final (int, int)? wordRange;
  final List<MapEntry<String, int>> titleKeywords;
  final List<MapEntry<String, int>> tagKeywords;
  final List<RankTrend> trends;
  final List<String> newCategories;
  final int sampleSize;
  final int obfuscatedCount;

  /// 因字体混淆而未参与书名热词统计的条数（如实说明，不假装算过了）。
  final int skippedForKeywords;

  String toMarkdown({required String sourceName, required String board, String? note}) {
    final sb = StringBuffer();
    sb.writeln('## $sourceName · $board');
    sb.writeln();
    sb.writeln('- 样本量：$sampleSize 条');
    if (obfuscatedCount > 0) {
      sb.writeln('- 书名字体混淆：$obfuscatedCount/$sampleSize 条（指标仍可用）');
    }
    if (wordRange != null) {
      sb.writeln('- 字数区间：${_wan(wordRange!.$1)} ~ ${_wan(wordRange!.$2)}');
    }
    if (note != null) sb.writeln('- 说明：$note');
    sb.writeln();
    sb.writeln('| 题材 | 榜上数量 | 占比 | 最好名次 | 较上期 |');
    sb.writeln('|---|---|---|---|---|');
    for (final c in categories.take(15)) {
      final t = c.trend == 0 ? '→' : (c.trend > 0 ? '↑ +${c.trend}' : '↓ ${c.trend}');
      sb.writeln('| ${c.category} | ${c.count} | ${(c.ratio * 100).toStringAsFixed(1)}% '
          '| ${c.bestRank} | $t |');
    }
    sb.writeln();
    if (tagKeywords.isNotEmpty) {
      sb.writeln('子分类热词：${tagKeywords.take(12).map((e) => '${e.key}(${e.value})').join('、')}');
      sb.writeln();
    }
    if (titleKeywords.isNotEmpty) {
      sb.writeln('书名高频片段：${titleKeywords.take(12).map((e) => '${e.key}(${e.value})').join('、')}');
      sb.writeln();
    } else if (skippedForKeywords > 0) {
      sb.writeln('书名高频片段：**未统计** —— $skippedForKeywords/$sampleSize 条书名被字体混淆，'
          '拿乱码算词频会得到不存在的规律');
      sb.writeln();
    }
    if (newCategories.isNotEmpty) {
      sb.writeln('本期新出现题材：${newCategories.join('、')}');
      sb.writeln();
    }
    if (trends.isNotEmpty) {
      final fresh = trends.where((t) => t.isNew).toList();
      final rising = trends.where((t) => !t.isNew && (t.rankChange ?? 0) > 0).toList()
        ..sort((a, b) => b.jumpScore.compareTo(a.jumpScore));
      final falling = trends.where((t) => !t.isNew && (t.rankChange ?? 0) < 0).toList()
        ..sort((a, b) => a.jumpScore.compareTo(b.jumpScore));
      final gone = trends.where((t) => t.dropped).toList();
      if (fresh.isNotEmpty) {
        sb.writeln('新上榜(${fresh.length})：${fresh.take(8).map((t) => _show(t.title)).join('、')}');
      }
      if (rising.isNotEmpty) {
        sb.writeln('上升最快：${rising.take(5).map((t) => '${_show(t.title)}(+${t.rankChange})').join('、')}');
      }
      if (falling.isNotEmpty) {
        sb.writeln('下降最快：${falling.take(5).map((t) => '${_show(t.title)}(${t.rankChange})').join('、')}');
      }
      if (gone.isNotEmpty) {
        sb.writeln('已掉榜(${gone.length})：${gone.take(8).map((t) => _show(t.title)).join('、')}');
      }
      sb.writeln();
    }
    return sb.toString();
  }

  static String _show(String t) {
    final obf = t.runes.where((c) => c >= 0xE000 && c <= 0xF8FF).isNotEmpty;
    return obf ? '$t〔名待补〕' : t;
  }

  static String _wan(int n) =>
      n >= 10000 ? '${(n / 10000).toStringAsFixed(1)}万字' : '$n字';
}

class RankAnalyzer {
  const RankAnalyzer();

  RankAnalysis analyze(RankResult current, {RankResult? previous, int topKeywords = 30}) {
    final entries = current.entries;

    final byCat = <String, List<RankEntry>>{};
    for (final e in entries) {
      final c = (e.category ?? '').trim();
      if (c.isEmpty) continue;
      (byCat[c] ??= []).add(e);
    }
    final prevByCat = <String, int>{};
    if (previous != null) {
      for (final e in previous.entries) {
        final c = (e.category ?? '').trim();
        if (c.isEmpty) continue;
        prevByCat[c] = (prevByCat[c] ?? 0) + 1;
      }
    }
    final categories = <CategoryShare>[];
    for (final e in byCat.entries) {
      final prev = previous == null ? e.value.length : (prevByCat[e.key] ?? 0);
      categories.add(CategoryShare(
        category: e.key,
        count: e.value.length,
        ratio: entries.isEmpty ? 0 : e.value.length / entries.length,
        bestRank: e.value.map((x) => x.rank).reduce((a, b) => a < b ? a : b),
        trend: e.value.length - prev,
      ));
    }
    categories.sort((a, b) => b.count.compareTo(a.count));

    // ★ 只取有限数：`1e999` 会解析成 Infinity，`Infinity.toInt()` 直接抛。
    //   一条坏记录不该让整次分析失败（更不该让整个界面永久空白）。
    final words = entries
        .map((e) => e.metrics['words'])
        .whereType<num>()
        .where((n) => n.isFinite)
        .map((n) => n.toInt())
        .toList();
    (int, int)? range;
    if (words.isNotEmpty) {
      range = (words.reduce((a, b) => a < b ? a : b), words.reduce((a, b) => a > b ? a : b));
    }

    // ★ 书名热词只用**未被字体混淆**的条目算：拿私用区乱码算 bigram，
    //   产出的"高频片段"是纯噪声，比不给更糟（它会误导模型去总结不存在的规律）。
    final readableTitles = entries.where((e) => !e.titleObfuscated).map((e) => e.title);
    final skippedForKeywords = entries.length - readableTitles.length;

    return RankAnalysis(
      categories: categories,
      wordRange: range,
      titleKeywords: _bigram(readableTitles, topKeywords),
      tagKeywords: _bigram(entries.expand((e) => e.tags), topKeywords),
      trends: previous == null ? const [] : _trends(previous, current),
      newCategories: previous == null
          ? const []
          : byCat.keys.where((c) => !prevByCat.containsKey(c)).toList(),
      sampleSize: entries.length,
      obfuscatedCount: entries.where((e) => e.titleObfuscated).length,
      skippedForKeywords: skippedForKeywords,
    );
  }

  /// ★ 跨快照主键用 bookId（书名会重名、会被混淆），缺失时才退到书名。
  List<RankTrend> _trends(RankResult prev, RankResult curr) {
    String keyOf(RankEntry e) => (e.bookId == null || e.bookId!.isEmpty) ? e.title : 'id:${e.bookId}';
    final prevBy = {for (final e in prev.entries) keyOf(e): e};
    final currBy = {for (final e in curr.entries) keyOf(e): e};
    num? pickMetric(RankEntry? e) {
      if (e == null) return null;
      for (final en in e.metrics.entries) {
        if (en.key == 'words') continue; // words 是体量不是热度
        return en.value;
      }
      return null;
    }

    final out = <RankTrend>[];
    for (final k in {...prevBy.keys, ...currBy.keys}) {
      final p = prevBy[k];
      final c = currBy[k];
      if (p == null && c == null) continue;
      out.add(RankTrend(
        key: k,
        title: (c ?? p)!.title,
        prevRank: p?.rank ?? 0,
        currRank: c?.rank ?? 0,
        prevMetric: pickMetric(p),
        currMetric: pickMetric(c),
      ));
    }
    out.sort((a, b) {
      if (a.isNew != b.isNew) return a.isNew ? -1 : 1;
      return a.currRank.compareTo(b.currRank);
    });
    return out;
  }

  /// 中文无空格，用二元组近似分词：单字噪声大、三元组太碎，
  /// 且只保留出现 ≥2 次的片段。
  List<MapEntry<String, int>> _bigram(Iterable<String> texts, int top) {
    const stop = {
      '的了', '我的', '我是', '开始', '小说', '全书', '最新', '章节', '在线',
      '免费', '阅读', '完整', '提供',
    };
    final freq = <String, int>{};
    for (final t in texts) {
      final s = t.trim();
      if (s.length < 2) continue;
      for (var i = 0; i + 2 <= s.length; i++) {
        final g = s.substring(i, i + 2);
        if (stop.contains(g)) continue;
        if (RegExp(r'^[\d\s\p{P}]+$', unicode: true).hasMatch(g)) continue;
        freq[g] = (freq[g] ?? 0) + 1;
      }
    }
    final list = freq.entries.where((e) => e.value >= 2).toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return list.take(top).toList();
  }
}

/// 趋势解读 —— 把「同一张榜跨时间的自身对比」翻译成人能读的**事实**与**候选原因**。
///
/// ★ 为什么要有这一层（以及它跟 [TimeSeriesAnalysis] 的分工）：
///   [TimeSeriesAnalysis] 只出数字（变化了多少名、涨了几期），**一个字的原因都不写**。
///   但用户真正想知道的恰恰是"为什么变了"。
///   直接让模型自由发挥因果，很容易把"看起来合理的解释"当成结论卖出去；
///   所以这里走**规则**：每条原因都由一组可复算的数字触发，并带上
///   ① 证据（用了哪几个数）② 置信度 ③ 边界（本工具看不到什么）。
///
/// ★ 两类输出必须**视觉上分开**，不能混成一段话：
///   - [InsightKind.fact]：纯统计事实，可复算、无歧义。
///   - [InsightKind.hypothesis]：候选原因，一律标注"待核实"。
///   混在一起读者会分不清哪句是数、哪句是猜。
///
/// ★ 期数不足时**不猜**：少于 3 期就说"这只是两期之差，谈不上趋势"，
///   而不是硬凑一条因果。这条纪律与 `analysis.dart` 里
///   "样本太少就报 sparse，不给结论"是同一个原则。
library;

import 'timeseries.dart';

/// 一条解读行的性质。
enum InsightKind {
  /// 纯统计事实（可复算）。
  fact,

  /// 候选原因（由规则触发，需人工核实）。
  hypothesis,
}

/// 解读里的一行。
class InsightLine {
  const InsightLine(this.kind, this.text, {this.tag});

  final InsightKind kind;
  final String text;

  /// 短标签（例：`较强` / `中等` / `较弱`）。事实行没有标签。
  final String? tag;

  bool get isFact => kind == InsightKind.fact;
}

/// 一次趋势解读的结果。
class TrendInsight {
  const TrendInsight({
    required this.facts,
    required this.hypotheses,
    required this.periods,
    required this.caveat,
  });

  final List<String> facts;
  final List<Hypothesis> hypotheses;

  /// 参与解读的期数。
  final int periods;

  /// 推断的边界说明（界面上必须显示，不能藏）。
  final String caveat;

  /// 期数是否够谈"趋势"（>= 3 期）。
  bool get enough => periods >= 3;

  /// 渲染顺序：先事实、后候选原因。
  List<InsightLine> get lines => [
        for (final f in facts) InsightLine(InsightKind.fact, f),
        for (final h in hypotheses)
          InsightLine(InsightKind.hypothesis, '${h.claim}　${h.evidence}',
              tag: h.confidenceLabel),
      ];

  bool get isEmpty => facts.isEmpty && hypotheses.isEmpty;
}

/// 一条候选原因。
class Hypothesis {
  const Hypothesis({
    required this.claim,
    required this.evidence,
    required this.confidence,
    required this.caveat,
  });

  /// 一句可能的原因（例："名次上升更像更新量带动的"）。
  final String claim;

  /// 支撑它的可复算数字（例："上升 4 本，其中 3 本同期字数增长"）。
  final String evidence;

  /// 0..1 的粗糙置信度（规则给的，不是概率）。
  final double confidence;

  /// 这条推断的边界。
  final String caveat;

  String get confidenceLabel =>
      confidence >= 0.7 ? '较强' : (confidence >= 0.45 ? '中等' : '较弱');
}

/// 推断的边界说明（所有解读共用一条）。
const String kInsightCaveat = '以上"原因"是由榜单自身的公开数字推出的**候选解释**，不是定论。'
    '本工具看得到名次 / 字数 / 热度，看不到推荐位、运营活动、流量来源与付费数据 —— '
    '要确认原因得回到作者后台或运营侧核对。';

/// 期数不足时的说明。
const String kInsightTooFewPeriods =
    '只有 2 期数据，下面只是"两期之差"，还谈不上趋势；再攒几期再看原因。';

/// 主入口：从时间线装配趋势解读。
TrendInsight buildTrendInsight(TimeSeriesAnalysis ts) {
  final facts = <String>[];
  final hyps = <Hypothesis>[];

  if (ts.periodCount == 0) {
    return const TrendInsight(
        facts: [], hypotheses: [], periods: 0, caveat: kInsightCaveat);
  }

  // ★ 事实只留**上面四张概览卡没说过**的那几条。
  //   卡上已经有"本期上榜（首期 N）/ 本期总字数 / 全期在榜 / 期数"，
  //   解读栏再复述一遍纯属浪费行数 —— 而这里的行数正是最稀缺的资源
  //   （卡片高度有限，多一行就少一行"原因"）。
  final c0 = ts.firstCount;
  final c1 = ts.latestCount;
  final w0 = ts.firstTotalWords;
  final w1 = ts.latestTotalWords;

  // ── 事实 ①：名次中位数（比"平均名次"抗极端值）+ 总字数变化率 ──
  final m0 = _medianRank(ts, 0);
  final m1 = _medianRank(ts, ts.periodCount - 1);
  final buf = StringBuffer();
  if (m0 != null && m1 != null) {
    final d = m1 - m0;
    buf.write('名次中位数 $m0 → $m1'
        '${d == 0 ? '（持平）' : '（${d < 0 ? '变好' : '变差'} ${d.abs()} 位）'}');
  }
  if (w0 != null && w1 != null && w0 > 0) {
    final pct = (w1 - w0) / w0 * 100;
    if (buf.isNotEmpty) buf.write('；');
    buf.write('在榜总字数 ${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%');
  }
  if (buf.isNotEmpty) facts.add(buf.toString());

  // ── 事实 ②：换血（在榜数 + 新上/掉榜，一次说完）──
  final dc = c1 - c0;
  final churn = StringBuffer('在榜 $c0 → $c1'
      '${dc == 0 ? '（持平）' : '（${dc > 0 ? '+' : ''}$dc）'}');
  if (ts.freshNow.isNotEmpty || ts.goneNow.isNotEmpty) {
    churn.write('；换血：新上 ${ts.freshNow.length} / 掉榜 ${ts.goneNow.length}');
  }
  facts.add(churn.toString());

  // ── 事实 ③：连续同向期数（最长的两条）──
  var upStreak = 0;
  var upWho = '';
  var downStreak = 0;
  var downWho = '';
  for (final t in ts.tracks) {
    if (t.streakUp > upStreak) {
      upStreak = t.streakUp;
      upWho = t.label;
    }
    if (t.streakDown > downStreak) {
      downStreak = t.streakDown;
      downWho = t.label;
    }
  }
  final streakParts = <String>[];
  if (upStreak >= 2) streakParts.add('最长连涨 $upStreak 期（$upWho）');
  if (downStreak >= 2) streakParts.add('最长连跌 $downStreak 期（$downWho）');
  if (streakParts.isNotEmpty) facts.add(streakParts.join('；'));

  // ── 事实 ④：头部换手 ──
  final top3Changes = _topKChanges(ts, 3);
  if (ts.periodCount >= 2) {
    facts.add('前 3 名共变动 $top3Changes 次'
        '（${ts.periodCount - 1} 次相邻期比较）');
  }

  // ── 候选原因（少于 3 期不猜）──
  if (ts.periodCount < 3) {
    return TrendInsight(
      facts: facts,
      hypotheses: const [],
      periods: ts.periodCount,
      caveat: kInsightTooFewPeriods,
    );
  }

  // H1：名次上升 ↔ 字数增长（"更新量带动曝光"）
  final upMovers = ts.movers.up;
  if (upMovers.length >= 3) {
    var withWords = 0;
    var measured = 0;
    for (final mv in upMovers) {
      final dw = mv.track.latestWordsChange;
      if (dw == null) continue;
      measured++;
      if (dw > 0) withWords++;
    }
    if (measured >= 3 && withWords / measured >= 0.6) {
      final ratio = withWords / measured;
      hyps.add(Hypothesis(
        claim: '名次上升更像"更新量带动的曝光"。',
        evidence: '上升 ${upMovers.length} 本中 $withWords/$measured 本字数同涨'
            '（${(ratio * 100).toStringAsFixed(0)}%）。',
        confidence: 0.4 + 0.35 * ratio,
        caveat: '也可能只是同一天上新/改榜单导致的同步变化，本工具看不到推荐位。',
      ));
    }
  }

  // H2：掉榜但字数没动（"更像口径/节奏变化，而不是被追上"）
  final goneMovers = ts.movers.gone;
  if (goneMovers.length >= 3) {
    var frozen = 0;
    var measured = 0;
    for (final mv in goneMovers) {
      final dw = mv.track.latestWordsChange;
      // ★★ `dw == null` = **这一期根本没采到字数**（掉榜的书最后一期常常是
      //   没有字数的），它**不是**"字数零变化"的证据。
      //   原来这里 `measured++` 是无条件的，于是"我没采到"被翻译成
      //   "我证明了它没变"：`frozen == measured` 恒成立 → 置信度 0.75、
      //   证据写成"N/N 本字数零变化" —— 而这条假设会直接影响选题判断
      //   （"掉榜是口径变了，不是被挤下去"）。缺数据不能冒充证据。
      if (dw == null) continue;
      measured++;
      if (dw == 0) frozen++;
    }
    if (measured >= 3 && frozen / measured >= 0.6) {
      final ratio = frozen / measured;
      hyps.add(Hypothesis(
        claim: '掉榜的书数据面基本没动，更像榜单口径或更新节奏变了，'
            '而不是"被新书挤下去"。',
        evidence: '掉榜 ${goneMovers.length} 本中，'
            '能比字数变化的 $measured 本里有 $frozen 本字数零变化'
            '（其余 ${goneMovers.length - measured} 本本期没采到字数，未计入）。',
        confidence: 0.35 + 0.4 * ratio,
        caveat: '字数不变也可能只是作者当天没更；要区分得看更新章节数（本工具采不到）。',
      ));
    }
  }

  // H3：存在连续多期单向移动 → 更像真趋势而不是单日噪声
  if (upStreak >= 3 || downStreak >= 3) {
    final n = upStreak >= downStreak ? upStreak : downStreak;
    final dir = upStreak >= downStreak ? '上升' : '下降';
    hyps.add(Hypothesis(
      claim: '有书连续 $n 期单向$dir，更像真趋势而非单日噪声。',
      evidence: '$dir最久者连 $n 期同向（共 ${ts.periodCount} 期）。',
      confidence: 0.55,
      caveat: '连续同向也可能是采样间隔太密（同一次推广的尾巴）。',
    ));
  }

  // H4：名次几乎不动但数据在变 → 采样时点 / 口径差异
  if (m0 != null && m1 != null && (m1 - m0).abs() <= 1 &&
      w0 != null && w1 != null && w0 > 0) {
    final pct = (w1 - w0) / w0 * 100;
    if (pct.abs() >= 8) {
      hyps.add(Hypothesis(
        claim: '名次几乎没动但字数明显在变，说明"名次"和"数据"不是同一口径，'
            '别把字数的涨跌直接读成名次趋势。',
        evidence: '名次中位数 $m0 → $m1 几乎持平，总字数'
            '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%。',
        confidence: 0.6,
        caveat: '名次榜通常按天/按周结算，字数却是实时的 —— 两者天然有滞后。',
      ));
    }
  }

  // H5：头部频繁换手 → 竞争真实且激烈
  if (top3Changes >= 3) {
    hyps.add(Hypothesis(
      claim: '前 3 名频繁换手，头部位置不是"锁定"状态。',
      evidence: '${ts.periodCount - 1} 次相邻期比较中变动 $top3Changes 次。',
      confidence: 0.5,
      caveat: '换手也可能来自榜单刷新时间不一致，不必然代表竞争加剧。',
    ));
  }

  // ★ 只留置信度最高的 3 条：候选原因超过 3 条就不是"解读"而是"穷举"了，
  //   而且解读栏的行数有限 —— 与其把 5 条挤到看不清，不如给最站得住的 3 条。
  hyps.sort((a, b) => b.confidence.compareTo(a.confidence));
  final top = hyps.length > 3 ? hyps.sublist(0, 3) : hyps;

  return TrendInsight(
    facts: facts,
    hypotheses: top,
    periods: ts.periodCount,
    caveat: kInsightCaveat,
  );
}

/// 某一期在榜名次的中位数（未上榜的不参与）；该期无数据返回 null。
int? _medianRank(TimeSeriesAnalysis ts, int periodIndex) {
  if (periodIndex < 0 || periodIndex >= ts.points.length) return null;
  final ranks = <int>[
    for (final e in ts.points[periodIndex].result.entries)
      if (e.rank > 0) e.rank
  ];
  if (ranks.isEmpty) return null;
  ranks.sort();
  final mid = ranks.length ~/ 2;
  return ranks.length.isOdd ? ranks[mid] : ((ranks[mid - 1] + ranks[mid]) ~/ 2);
}

/// 相邻两期之间，前 [k] 名的**集合**变动了几次（按 bookId/书名主键算）。
///
/// ★ 用集合而不是逐位比较：名次在 1↔2 之间互换时"前 3 名"其实没换人，
///   逐位比会把它算成 2 次变动，夸大"头部洗牌"。
int _topKChanges(TimeSeriesAnalysis ts, int k) {
  if (ts.points.length < 2) return 0;
  Set<String> topOf(int pi) {
    final list = [...ts.points[pi].result.entries]
      ..sort((a, b) => a.rank.compareTo(b.rank));
    return {
      for (final e in list.take(k))
        (e.bookId == null || e.bookId!.isEmpty) ? 't:${e.title}' : 'i:${e.bookId}'
    };
  }

  var changes = 0;
  var prev = topOf(0);
  for (var i = 1; i < ts.points.length; i++) {
    final cur = topOf(i);
    changes += prev.difference(cur).length;
    prev = cur;
  }
  return changes;
}

/// 折线图几何回归（第 8 轮 P2）：y 轴反向 / 断点断开 / 刻度档位 / 选线规则。
///
/// ★ 为什么不用"看截图"来验证：折线图最容易错的不是"好不好看"，
///   而是**名次轴方向**（第 1 名必须在顶部）和**掉榜断点**（不能连到轴上）。
///   这两条都能用像素探测精确断言，比人眼看图可靠得多。
///
/// 运行：dart run bin/_t_chart.dart
library;

import 'dart:io';

import '../lib/models.dart';
import '../lib/snapshot_index_file.dart';
import '../lib/timeseries.dart';
import '../lib/ui/chart.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/win32.dart';

int _pass = 0;
int _fail = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✅ $name');
  } else {
    _fail++;
    stdout.writeln('  ❌ $name${detail == null ? '' : ' — $detail'}');
  }
}

/// 在离屏缓冲上渲染一块区域，返回像素读取器。
class Shot {
  Shot(this.w, this.h) {
    buf = BackBuffer(w, h);
    buf.gdi.fill(Rc(0, 0, w, h), rgb(0, 0, 0));
  }
  final int w;
  final int h;
  late final BackBuffer buf;

  /// (x,y) 处是否"非纯黑"（= 被画过东西）。
  bool ink(int x, int y) {
    final b = buf.readBgra();
    if (x < 0 || y < 0 || x >= w || y >= h) return false;
    final i = (y * w + x) * 4;
    return b[i] + b[i + 1] + b[i + 2] > 24;
  }

  /// (x,y) 处像素是否为指定 BGR 色（容差 [tol]）。
  ///
  /// ★ 必须按**颜色**判定，不能只看"有没有墨"：图上还有网格线、坐标轴文字、
  ///   刻度，它们都是"墨"。用"最靠上的墨点"去找数据点会找到顶部那条网格线。
  bool isColor(int x, int y, int bgr, {int tol = 60}) {
    if (x < 0 || y < 0 || x >= w || y >= h) return false;
    final b = buf.readBgra();
    final i = (y * w + x) * 4;
    int ch(int v) => (v < 0 ? 0 : (v > 255 ? 255 : v));
    final db = (b[i] - (bgr & 0xFF)).abs();
    final dg = (b[i + 1] - ((bgr >> 8) & 0xFF)).abs();
    final dr = (b[i + 2] - ((bgr >> 16) & 0xFF)).abs();
    // 容差按通道给：抗锯齿会把边缘像素往背景混。
    return db <= tol && dg <= tol && dr <= tol;
  }

  /// 某一列里，指定颜色最靠上的 y（找不到 -1）。
  int topColorInColumn(int x, int y0, int y1, int bgr) {
    for (var y = y0; y <= y1; y++) {
      if (isColor(x, y, bgr)) return y;
    }
    return -1;
  }

  /// 一列里最靠上的墨点 y（找不到返回 -1）。
  int topInkInColumn(int x, int y0, int y1) {
    for (var y = y0; y <= y1; y++) {
      if (ink(x, y)) return y;
    }
    return -1;
  }

  void dispose() => buf.dispose();
}

void main() {
  stdout.writeln('== 折线图几何回归：y 轴反向 / 断点 / 刻度 / 选线 ==');
  Metrics.factor = 1.0;

  // ── ① y 轴必须反向：名次 1 在顶部，名次大在底部 ──
  stdout.writeln('\n── ① y 轴反向（第 1 名在顶）──');
  final shot = Shot(420, 220);
  final area = Rc(0, 0, 420, 220);
  // 三期，名次 1 → 10 → 1；颜色用纯青色便于探测。
  const testColor = 0x00FF00FF; // rgb(255,0,255) 洋红（BGR: b=255,g=0,r=255）
  final series = [
    ChartSeries(label: '测试', ranks: const [1, 10, 1], color: testColor),
  ];
  final hit = drawRankTrendChart(
    shot.buf.gdi,
    area,
    dates: const ['09-22', '09-23', '09-24'],
    series: series,
    mouseX: -100,
    mouseY: -100,
  );

  // 找最左（第 1 期，名次 1）与中间（第 2 期，名次 10）的墨点高度。
  // 绘图区左侧留白 44，所以第 1 期 x 约 44；第 3 期 x 约 420-14=406。
  // 名次 1 应该靠近顶部，名次 10 应该更靠下。
  // ★ 用**颜色**定位数据点，不要用"最靠上的墨"——
  //   图上还有网格线和刻度文字，它们也是墨，会污染判断（第一次就是这么错的）。
  var firstTop = -1;
  for (var x = 46; x <= 56; x++) {
    final t = shot.topColorInColumn(x, 0, 219, testColor);
    if (t >= 0 && (firstTop < 0 || t < firstTop)) firstTop = t;
  }
  var lastTop = -1;
  for (var x = 396; x <= 406; x++) {
    final t = shot.topColorInColumn(x, 0, 219, testColor);
    if (t >= 0 && (lastTop < 0 || t < lastTop)) lastTop = t;
  }
  // 中间期（名次 10）的 x 由 3 等分算出：44 + (406-44)*1/2 = 225
  var midTop2 = -1;
  for (var x = 220; x <= 230; x++) {
    final t = shot.topColorInColumn(x, 0, 219, testColor);
    if (t >= 0 && (midTop2 < 0 || t < midTop2)) midTop2 = t;
  }

  _check('第 1 期（名次 1）画在靠上位置', firstTop >= 0 && firstTop < 60,
      'y=$firstTop');
  _check('第 3 期（名次 1）画在靠上位置', lastTop >= 0 && lastTop < 60,
      'y=$lastTop');
  _check('第 2 期（名次 10）画得比名次 1 更靠下',
      midTop2 > firstTop + 20, 'mid=$midTop2 first=$firstTop');
  _check('第 1 期与第 3 期（都是名次 1）高度接近',
      (firstTop - lastTop).abs() <= 6, 'first=$firstTop last=$lastTop');
  _check('未悬停时无命中', !hit.valid);
  shot.dispose();

  // ── ② 掉榜断点：中间期为 0 时折线不连通 ──
  stdout.writeln('\n── ② 掉榜断点不连通 ──');
  final shot2 = Shot(420, 220);
  // 名次 1 → 掉榜 → 1：两段独立的线，中间那条竖线上不该出现墨点。
  final series2 = [
    ChartSeries(label: '断点', ranks: const [1, 0, 1], color: testColor),
  ];
  drawRankTrendChart(
    shot2.buf.gdi,
    Rc(0, 0, 420, 220),
    dates: const ['09-22', '09-23', '09-24'],
    series: series2,
    mouseX: -100,
    mouseY: -100,
  );
  // 在中间期 x 附近、名次 1 的 y 高度（约 12~20）之外的区域应无**该系列颜色**。
  // 只看系列色，不看"有没有墨"——网格线/刻度文字永远有墨。
  var gapInk = 0;
  for (var x = 200; x <= 250; x++) {
    for (var y = 30; y <= 180; y++) {
      if (shot2.isColor(x, y, testColor)) gapInk++;
    }
  }
  _check('掉榜期不再连线（中间区域无系列色的连线）', gapInk == 0, 'ink=$gapInk');
  // 对照组：首末两期都是**孤立点**（两侧都断），所以只画圆点、不画连线。
  // 这不是缺陷 —— 孤立期画成点才是诚实的（连出去就编造了不存在的轨迹）。
  //
  // ★ 注意 y 范围要扫全高：本例里只有名次 1，y 轴量程就是 0..1，
  //   于是名次 1 落在绘图区**底部**（它同时是"最好的"也是"最差的"）。
  //   这正是"反向轴"的正确表现 —— 不要假设名次 1 一定在顶部，
  //   那要看量程里还有没有别的名次。
  var dotFirst = 0;
  for (var x = 38; x <= 52; x++) {
    for (var y = 0; y < 220; y++) {
      if (shot2.isColor(x, y, testColor)) dotFirst++;
    }
  }
  var dotLast = 0;
  for (var x = 400; x <= 412; x++) {
    for (var y = 0; y < 220; y++) {
      if (shot2.isColor(x, y, testColor)) dotLast++;
    }
  }
  _check('首期孤立点已画出（对照）', dotFirst > 0, 'px=$dotFirst');
  _check('末期孤立点已画出（对照）', dotLast > 0, 'px=$dotLast');
  // ★ 记录一条反直觉但正确的行为：量程里只有名次 1 时，名次 1 落在**底部**。
  //   这正是"y 轴反向"的正确表现（0 在上、值大在下）。若哪天有人把轴"改回来"，
  //   这条断言会立刻失败，提示他 y 轴方向被改错了。
  var lowestY = 0;
  for (var x = 0; x < 420; x++) {
    for (var y = 0; y < 220; y++) {
      if (shot2.isColor(x, y, testColor) && y > lowestY) lowestY = y;
    }
  }
  _check('量程仅含名次 1 时，点落在绘图区下部（反向轴）', lowestY > 150,
      'y=$lowestY');
  shot2.dispose();

  // 对照组的补充：连续三期时，点与点之间必须真的连成线
  // （避免"只画点不画线"也被上面两条断言放过）。
  final shot2b = Shot(420, 220);
  drawRankTrendChart(
    shot2b.buf.gdi,
    Rc(0, 0, 420, 220),
    dates: const ['09-22', '09-23', '09-24'],
    series: [
      ChartSeries(label: '连', ranks: const [1, 10, 1], color: testColor),
    ],
    mouseX: -100,
    mouseY: -100,
  );
  // 取首期与中间期之间的中点 x≈135，该列应能找到系列色（连线经过）。
  var lineHit = 0;
  for (var x = 120; x <= 150; x++) {
    for (var y = 10; y <= 200; y++) {
      if (shot2b.isColor(x, y, testColor)) lineHit++;
    }
  }
  _check('相邻有效期之间连成了线', lineHit >= 3, 'px=$lineHit');
  shot2b.dispose();

  // ── ③ 刻度步长选择 ──
  stdout.writeln('\n── ③ 刻度档位 ──');
  // 通过渲染 高/低 两组数据，检查 y 轴刻度是否"可读"（不重叠、整数）。
  final shot3 = Shot(420, 220);
  drawRankTrendChart(
    shot3.buf.gdi,
    Rc(0, 0, 420, 220),
    dates: const ['a', 'b'],
    series: [
      ChartSeries(label: '大', ranks: const [3, 47], color: testColor),
    ],
    mouseX: -100,
    mouseY: -100,
  );
  // y 轴区域（x < 44）应有刻度文字
  var axisInk = 0;
  for (var x = 0; x < 44; x++) {
    for (var y = 0; y < 220; y++) {
      if (shot3.ink(x, y)) axisInk++;
    }
  }
  _check('y 轴有刻度文字', axisInk > 20, 'ink=$axisInk');
  shot3.dispose();

  // ── ④ 极窄 / 极矮区域不崩 ──
  stdout.writeln('\n── ④ 边界尺寸不崩 ──');
  final shot4 = Shot(120, 60);
  drawRankTrendChart(
    shot4.buf.gdi,
    Rc(0, 0, 120, 60),
    dates: const ['a'],
    series: [ChartSeries(label: 'x', ranks: const [1], color: testColor)],
    mouseX: 10,
    mouseY: 10,
  );
  _check('极小区域绘制不抛异常', true);
  shot4.dispose();

  final shot5 = Shot(200, 120);
  final empty = drawRankTrendChart(
    shot5.buf.gdi,
    Rc(0, 0, 200, 120),
    dates: const [],
    series: const [],
    mouseX: -1,
    mouseY: -1,
  );
  _check('空日期序列不崩且无命中', !empty.valid);
  shot5.dispose();

  // ── ⑤ 选线规则（pickChartSeries）──
  stdout.writeln('\n── ⑤ 选线规则 ──');
  final d1 = DateTime(2026, 9, 22);
  final d2 = DateTime(2026, 9, 23);
  final d3 = DateTime(2026, 9, 24);
  RankResult mk(DateTime at, List<(String, String, int)> rows) => RankResult(
        query: const RankQuery(source: 'qidian', board: '月票榜', limit: 9),
        entries: [
          for (final r in rows)
            RankEntry(
                rank: r.$3,
                title: r.$2,
                author: 'a',
                bookId: r.$1,
                metrics: const {'monthticket': 1}),
        ],
        fetchedAt: at,
      );
  IndexEntry ie(DateTime at) => IndexEntry(
        id: 'qidian|月票榜|-|${at.day}',
        source: 'qidian',
        board: '月票榜',
        dateKey: '202609${at.day}',
        fetchedAt: at,
        count: 3,
        ok: true,
        relFile: 'x',
      );
  final es = [ie(d1), ie(d2), ie(d3)];
  final ts = buildTimeSeries(es, {
    es[0].id: mk(d1, [('a', '榜首', 1), ('b', '稳定王', 40), ('c', '一期客', 5)]),
    es[1].id: mk(d2, [('a', '榜首', 3), ('b', '稳定王', 41)]),
    es[2].id: mk(d3, [('a', '榜首', 1), ('b', '稳定王', 40)]),
  });
  _check('时序里 3 条轨迹', ts.tracks.length == 3, 'got ${ts.tracks.length}');
  final picked = pickChartSeries(ts, top: 6);
  _check('只保留 >=2 期在榜的线（一期客被排除）',
      !picked.any((s) => s.label == '一期客'), picked.map((s) => s.label).join(','));
  _check('榜首的线被选中', picked.any((s) => s.label == '榜首'),
      picked.map((s) => s.label).join(','));
  _check('每条线的期数都对齐（=3）',
      picked.every((s) => s.ranks.length == 3),
      picked.map((s) => '${s.label}:${s.ranks.length}').join(','));
  _check('名次 40 的稳定王也在（虽波动小，但满 3 期）',
      picked.any((s) => s.label == '稳定王'));
  _check('线与线颜色不重复', picked.map((s) => s.color).toSet().length == picked.length,
      picked.map((s) => '${s.color}').join(','));

  // 波动大的排在前面（榜首名次好 → 应该排第一）
  _check('榜首排在第一（名次最优）', picked.first.label == '榜首', picked.first.label);

  // ── ⑥ 指标轴：**正向**（值越大越靠上），且 null 断点 ──
  //
  // ★ 这是本轮（用户要"每本书各自**数据**变化的折线图"）新增的口径。
  //   名次轴反向、指标轴正向 —— 画反了会把"涨得最多"画到图底，
  //   而且这种错**看图很容易看不出来**（两条线交叉位置变了而已），
  //   所以必须用像素坐标断言。
  stdout.writeln('\n── ⑥ 指标轴（正向）与断点 ──');
  final mshot = Shot(420, 220);
  // ★ 颜色要挑 **R==B** 的：`Palette`/GDI 用的是 COLORREF(0x00BBGGRR)，
  //   而像素读出来是 BGRA —— 只有 r==b 时两种读法才一致，不会量错。
  const mColor = 0x00FF00FF; // 洋红（r=b=FF）
  final mSeries = [
    ChartSeries.metric(label: '涨', values: const [100, 200, 300], color: mColor),
  ];
  drawTrendChart(
    mshot.buf.gdi,
    area,
    dates: const ['09-22', '09-23', '09-24'],
    series: mSeries,
    mouseX: -100,
    mouseY: -100,
    axis: ChartAxis.value,
  );
  // ★ 指标轴的左留白是 62（要放得下 "250亿" 这种刻度），名次轴才是 44 ——
  //   探测坐标必须跟着改，否则量到的是空白（这个坑踩过一次）。
  final yFirst = mshot.topColorInColumn(64, 0, 220, mColor);
  final yLast = mshot.topColorInColumn(404, 0, 220, mColor);
  _check('指标轴上：值大的一期**更靠上**（y 更小）',
      yFirst > 0 && yLast > 0 && yLast < yFirst,
      '100 → y=$yFirst，300 → y=$yLast');
  _check('指标轴的第一个数据点不在图顶（0 在底，100 不该贴顶）',
      yFirst > 20, 'y=$yFirst');
  mshot.dispose();

  // null 断点：中间一期没有观测 → 不得连线
  final nshot = Shot(420, 220);
  const nColor = 0x00AA00AA; // 深洋红（r=b=AA），与上面区分开
  drawTrendChart(
    nshot.buf.gdi,
    area,
    dates: const ['09-22', '09-23', '09-24'],
    series: [
      ChartSeries.metric(
          label: '断', values: const [100, null, 300], color: nColor),
    ],
    mouseX: -100,
    mouseY: -100,
    axis: ChartAxis.value,
  );
  // 中间区域的竖直带里不该有该系列色（连线会横穿这里）
  var midInk = 0;
  for (var y = 0; y < 220; y++) {
    for (var x = 200; x <= 240; x++) {
      if (nshot.isColor(x, y, nColor)) midInk++;
    }
  }
  _check('null 那一期断开（中间区域没有该系列色的连线）', midInk == 0,
      'ink=$midInk');
  nshot.dispose();

  // ── ⑦ 选线规则：指标模式按**变化幅度**挑 ──
  stdout.writeln('\n── ⑦ 选线：按指标/字数变化幅度 ──');
  final mts = _buildMetricSeries();
  final byValue = pickChartSeries(mts, top: 6, by: ChartMetric.value);
  _check('指标模式选出了线', byValue.isNotEmpty,
      byValue.map((s) => s.label).join(','));
  _check('指标模式的线都是"数值线"（正向轴）',
      byValue.every((s) => !s.isRank));
  _check('指标模式选出的是**变化最大**的那本（暴涨）',
      byValue.first.label == '暴涨',
      byValue.map((s) => s.label).join(','));
  _check('只有一期有指标的书被排除',
      !byValue.any((s) => s.label == '一期客'),
      byValue.map((s) => s.label).join(','));

  final byWords = pickChartSeries(mts, top: 6, by: ChartMetric.words);
  _check('字数模式也能选线', byWords.isNotEmpty,
      byWords.map((s) => s.label).join(','));
  _check('字数模式选出的是**字数涨最多**的那本',
      byWords.first.label == '暴涨',
      byWords.map((s) => s.label).join(','));
  final byRank = pickChartSeries(mts, top: 6);
  _check('名次模式选出来的都是**名次线**（反向轴）',
      byRank.every((s) => s.isRank));
  _check('名次模式里两本都进了（都满 3 期在榜）',
      byRank.map((s) => s.label).toSet().containsAll(['暴涨', '平稳']),
      byRank.map((s) => s.label).join(','));

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

/// 造一份"指标差异明显"的时间线，用来验指标模式的选线规则。
///
/// a=暴涨（100 → 600 → 1000）、b=平稳（500 → 505 → 510）、
/// c=一期客（只在首期有指标，应当被排除）。
TimeSeriesAnalysis _buildMetricSeries() {
  final d1 = DateTime(2026, 9, 22);
  final d2 = DateTime(2026, 9, 23);
  final d3 = DateTime(2026, 9, 24);
  IndexEntry ie(DateTime at) => IndexEntry(
        id: 'qidian|月票榜|-|${at.day}',
        source: 'qidian',
        board: '月票榜',
        dateKey: '202609${at.day}',
        fetchedAt: at,
        count: 3,
        ok: true,
        relFile: 'x',
      );
  RankResult mk(DateTime at, List<(String, String, int, num)> rows) =>
      RankResult(
        query: const RankQuery(source: 'qidian', board: '月票榜', limit: 9),
        entries: [
          for (final r in rows)
            RankEntry(
                rank: r.$3,
                title: r.$2,
                author: 'a',
                bookId: r.$1,
                // ★ 字数要放进 metrics['words'] —— TrackPoint.words 是从这里取的
                metrics: {'monthticket': r.$4, 'words': r.$4 * 10}),
        ],
        fetchedAt: at,
      );
  final es = [ie(d1), ie(d2), ie(d3)];
  return buildTimeSeries(es, {
    es[0].id: mk(d1, [
      ('a', '暴涨', 3, 100),
      ('b', '平稳', 1, 500),
      ('c', '一期客', 5, 50),
    ]),
    es[1].id: mk(d2, [
      ('a', '暴涨', 2, 600),
      ('b', '平稳', 1, 505),
    ]),
    es[2].id: mk(d3, [
      ('a', '暴涨', 1, 1000),
      ('b', '平稳', 2, 510),
    ]),
  });
}

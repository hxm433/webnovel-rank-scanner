/// 趋势折线图 —— 纯 GDI 自绘（零依赖）。
///
/// ★ 为什么自己画而不是找图表库：
///   项目约束是"单 exe、零第三方依赖"，任何图表库都会带来 node/canvas/skia
///   这类重资产。真正需要的只是"把一串名次画成折线 + 坐标轴 + 悬停提示"，
///   这点工作量的自绘代码比集成依赖更容易维护，也更容易做**主题一致**。
///
/// ★ 折线图的坐标系：名次越小越好 → **y 轴要反向**。
///   这是最容易画错的地方：如果按普通坐标系画，第 1 名会落在图表底部，
///   读者会以为"排在最后"。所以 y = top + (rank-1)/maxRank * height。
///
/// ★ 断点必须真的断开：某期掉榜（rank=0）时不能连到轴上，
///   否则读者会看到"从 #3 直线掉到 0 名"这种不存在的轨迹。
library;

import 'dart:math' as math;

import '../timeseries.dart';
import 'gdi.dart';
import 'theme.dart';
import 'widgets.dart';
import 'win32.dart';

/// y 轴的两种口径。
///
/// ★ 为什么必须区分：**名次越小越靠上，指标越大越靠上** ——
///   方向正好相反。混用会把"第 1 名"画到图底、把"月票最高"画到图底。
enum ChartAxis {
  /// 名次：上小下大（y 轴反向）。
  rank,

  /// 指标 / 字数这类数值：上大下小（y 轴正向，0 在底）。
  value,
}

/// 一条要画的线的样式 + 数据。
class ChartSeries {
  /// 名次线（等价于 `values` + [ChartAxis.rank]）。
  ///
  /// ★ `0` 与 `null` 都表示"该期未上榜"，一律归一成 `null`（折线在那里断开）。
  ///   数据层里未上榜就是 `rank = 0`，漏了这一步会把它当成"第 0 名"画到图顶 ——
  ///   图上会凭空多出一条"从 #3 冲到榜首"的假线。
  ChartSeries({
    required this.label,
    required List<int?> ranks,
    required this.color,
    this.thickness = 0,
  })  : values = [for (final r in ranks) (r == null || r <= 0) ? null : r.toDouble()],
        isRank = true;

  /// 数值线（指标 / 字数；`null` = 该期未上榜或无该指标，折线在此断开）。
  ChartSeries.metric({
    required this.label,
    required this.values,
    required this.color,
    this.thickness = 0,
  }) : isRank = false;

  final String label;

  /// 每期的值；null 表示该期没有观测（折线在此断开）。
  final List<double?> values;

  /// 这条线是名次还是数值（决定 y 轴方向与刻度格式）。
  final bool isRank;

  final int color;
  final int thickness;

  /// 名次序列（老调用点与自检在用；非名次线会四舍五入）。
  List<int?> get ranks => [for (final v in values) v?.round()];

  /// 第 [i] 期的值是不是有效观测。
  bool validAt(int i) => i >= 0 && i < values.length && values[i] != null;
}

/// 折线图绘制结果（悬停命中的期次，供 tooltip 用）。
class ChartHit {
  const ChartHit(this.periodIndex, this.plotX, this.plotY);
  final int periodIndex;
  final int plotX;
  final int plotY;

  static const none = ChartHit(-1, 0, 0);
  bool get valid => periodIndex >= 0;
}

/// 画一张趋势折线图（名次 **或** 指标），返回悬停命中的期次。
///
/// [dates] 是每期的短日期标签（旧→新）。
/// [axis] 决定 y 轴口径：名次反向（越小越靠上）/ 数值正向（越大越靠上）。
/// [maxRank] 只在名次模式下有意义（y 轴下界，便于跨榜对齐）。
ChartHit drawTrendChart(
  Gdi g,
  Rc area, {
  required List<String> dates,
  required List<ChartSeries> series,
  required int mouseX,
  required int mouseY,
  ChartAxis axis = ChartAxis.rank,
  int? maxRank,
  int periodHighlight = -1,
}) {
  final u = Metrics.factor;
  final n = dates.length;

  // 绘图区：左侧留给 y 轴刻度，底部留给 x 轴标签。
  // ★ 数值轴的刻度标签要放得下 "250亿" 这种四五个字，所以左留白更宽。
  final padL = ((axis == ChartAxis.rank ? 44 : 62) * u).round();
  final padR = (14 * u).round();
  final padT = (12 * u).round();
  final padB = (26 * u).round();
  final plot = Rc(area.left + padL, area.top + padT, area.right - padR,
      area.bottom - padB);
  if (plot.width < 40 || plot.height < 40 || n == 0) {
    g.text('期数不足，暂不能画趋势', area, Palette.fgDim,
        size: Metrics.fontSizeSmall, align: dtCenter);
    return ChartHit.none;
  }

  // ── y 轴上界 + 刻度 ──
  //
  // ★ 两种口径共用一段"算刻度"的代码，但**取整方式不同**：
  //   名次是整数（1/2/5/10/20/50…），指标是浮点数（1/2/2.5/5 × 10^k）。
  //   混用会让指标轴出现 "0 33 66 99" 这种读不出来的刻度。
  //
  // ★★ 刻度**条数**还要跟着绘图区高度走：概览卡被挤扁时绘图区只有五六十像素，
  //    6 条刻度（每条 16px 字）会叠在一起糊成一团（实测"250亿/200亿/150亿"
  //    三行叠着）。所以先按高度算出最多画几条，再挑步长。
  final maxTicks = (plot.height / (20 * u).round()).floor().clamp(2, 6);
  late final double yMax;
  late final List<(double, String)> ticks; // (值, 标签)
  if (axis == ChartAxis.rank) {
    var hi = maxRank ?? 0;
    if (maxRank == null) {
      for (final s in series) {
        for (final v in s.values) {
          if (v != null && v > hi) hi = v.round();
        }
      }
    }
    if (hi <= 0) hi = 10;
    var step = _niceStep(hi);
    // 档位太密就往上翻一档（10 → 20 → 50 …）
    while (hi ~/ step + 1 > maxTicks) {
      final next = _niceStep(step * 2);
      if (next <= step) break;
      step = next;
    }
    final top = ((hi + step - 1) ~/ step) * step;
    yMax = top.toDouble();
    ticks = [for (var v = 0; v <= top; v += step) (v.toDouble(), '$v')];
  } else {
    var hi = 0.0;
    for (final s in series) {
      for (final v in s.values) {
        if (v != null && v > hi) hi = v;
      }
    }
    if (hi <= 0) hi = 1;
    var step = _niceValueStep(hi);
    while ((hi / step).ceil() + 1 > maxTicks && step < hi) {
      step *= 2;
    }
    yMax = (hi / step).ceil() * step;
    final list = <(double, String)>[];
    for (var v = 0.0; v <= yMax + step / 2; v += step) {
      list.add((v, _fmtValue(v)));
    }
    ticks = list;
  }

  // ── 网格 + y 轴刻度 ──
  for (var i = 0; i < ticks.length; i++) {
    final (v, label) = ticks[i];
    final t = yMax == 0 ? 0.0 : v / yMax;
    // 名次：0 在顶（越小越好）→ 反向；数值：0 在底。
    final yy = axis == ChartAxis.rank
        ? plot.top + (plot.height * t).round()
        : plot.bottom - (plot.height * t).round();
    g.line(plot.left, yy, plot.right, yy,
        i == 0 || i == ticks.length - 1 ? Palette.line : Palette.lineFaint);
    g.text(label,
        Rc.xywh(area.left, yy - (8 * u).round(), padL - (6 * u).round(),
            (16 * u).round()),
        Palette.fgFaint,
        size: Metrics.fontSizeTiny, align: dtRight, vcenter: true);
  }

  // ── x 轴标签（太多就抽稀）──
  final xOf = <int>[];
  for (var i = 0; i < n; i++) {
    final x = n == 1
        ? plot.left + plot.width ~/ 2
        : plot.left + (plot.width * i / (n - 1)).round();
    xOf.add(x);
  }
  final labelEvery = n <= 8 ? 1 : (n / 6).ceil();
  for (var i = 0; i < n; i++) {
    if (i % labelEvery != 0 && i != n - 1) continue;
    g.text(dates[i],
        Rc.xywh(xOf[i] - (26 * u).round(), plot.bottom + (4 * u).round(),
            (52 * u).round(), (18 * u).round()),
        i == n - 1 ? Palette.fgSub : Palette.fgFaint,
        size: Metrics.fontSizeTiny, align: dtCenter, vcenter: true);
  }

  // ── 悬停竖线（画在线下面，避免盖住数据点）──
  var hit = ChartHit.none;
  if (mouseX >= plot.left - (6 * u).round() &&
      mouseX <= plot.right + (6 * u).round() &&
      mouseY >= plot.top - (6 * u).round() &&
      mouseY <= plot.bottom + (6 * u).round()) {
    var best = 0;
    var bestD = 1 << 30;
    for (var i = 0; i < n; i++) {
      final d = (xOf[i] - mouseX).abs();
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    hit = ChartHit(best, xOf[best], plot.top);
    g.line(xOf[best], plot.top, xOf[best], plot.bottom, Palette.lineStrong);
  } else if (periodHighlight >= 0 && periodHighlight < n) {
    g.line(xOf[periodHighlight], plot.top, xOf[periodHighlight], plot.bottom,
        Palette.lineStrong);
  }

  // ── 画线（含断点处理）──
  int yOf(double v) {
    var t = yMax == 0 ? 0.0 : v / yMax;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    return axis == ChartAxis.rank
        ? plot.top + (plot.height * t).round()
        : plot.bottom - (plot.height * t).round();
  }

  for (final s in series) {
    final w = s.thickness > 0 ? s.thickness : (2 * u).round();
    // 一段一段画：遇到 null 就断开重新起笔。
    var runStart = -1;
    for (var i = 0; i < n; i++) {
      if (!s.validAt(i)) {
        if (runStart >= 0) {
          _strokeRun(g, xOf, s.values, runStart, i - 1, yOf, s.color, w);
          runStart = -1;
        }
        continue;
      }
      if (runStart < 0) runStart = i;
    }
    if (runStart >= 0) {
      _strokeRun(g, xOf, s.values, runStart, n - 1, yOf, s.color, w);
    }

    // 数据点：只在期数不多时画，否则糊成一团。
    if (n <= 30) {
      for (var i = 0; i < n; i++) {
        final v = s.values[i];
        if (v == null) continue;
        final x = xOf[i], y = yOf(v);
        final rad = (3 * u).round().clamp(2, 5);
        g.roundFill(Rc.xywh(x - rad, y - rad, rad * 2, rad * 2), s.color,
            s.color,
            radius: rad);
      }
    }
  }

  // 悬停期的高亮点
  if (hit.valid) {
    for (final s in series) {
      final v = s.values[hit.periodIndex];
      if (v == null) continue;
      final x = xOf[hit.periodIndex], y = yOf(v);
      final rad = (5 * u).round().clamp(3, 8);
      g.roundFill(Rc.xywh(x - rad, y - rad, rad * 2, rad * 2), s.color,
          Palette.fg,
          radius: rad);
    }
  }

  return hit;
}

/// 名次趋势折线图（[drawTrendChart] 的名次档，保留旧名字给老调用点）。
ChartHit drawRankTrendChart(
  Gdi g,
  Rc area, {
  required List<String> dates,
  required List<ChartSeries> series,
  required int mouseX,
  required int mouseY,
  int? maxRank,
  int periodHighlight = -1,
}) =>
    drawTrendChart(g, area,
        dates: dates,
        series: series,
        mouseX: mouseX,
        mouseY: mouseY,
        axis: ChartAxis.rank,
        maxRank: maxRank,
        periodHighlight: periodHighlight);

void _strokeRun(Gdi g, List<int> xs, List<double?> vals, int from, int to,
    int Function(double) yOf, int color, int width) {
  if (to <= from) return;
  var px = xs[from];
  var py = yOf(vals[from]!);
  for (var i = from + 1; i <= to; i++) {
    final v = vals[i];
    if (v == null) continue;
    final x = xs[i];
    final y = yOf(v);
    g.line(px, py, x, y, color, width: width);
    px = x;
    py = y;
  }
}

/// 数值轴的"好看步长"（1 / 2 / 2.5 / 5 × 10^k），目标是 4~6 格。
double _niceValueStep(double hi) {
  if (hi <= 0) return 1;
  final raw = hi / 5;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in const [1.0, 2.0, 2.5, 5.0]) {
    if (mag * m >= raw) return mag * m;
  }
  return mag * 10;
}

/// 数值轴刻度标签：万 / 亿（与界面其它地方的口径一致）。
String _fmtValue(double v) {
  final a = v.abs();
  if (a >= 1e8) {
    final x = v / 1e8;
    return '${_trim(x)}亿';
  }
  if (a >= 1e4) {
    final x = v / 1e4;
    return '${_trim(x)}万';
  }
  return _trim(v);
}

String _trim(double v) {
  if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
  if (v.abs() >= 100) return v.toStringAsFixed(0);
  if (v.abs() >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// 选一个"好看的刻度步长"（1/2/5/10/20/50/100…）。
int _niceStep(int hi) {
  if (hi <= 5) return 1;
  if (hi <= 10) return 2;
  if (hi <= 20) return 5;
  if (hi <= 50) return 10;
  if (hi <= 100) return 20;
  if (hi <= 200) return 50;
  if (hi <= 500) return 100;
  if (hi <= 1000) return 200;
  final mag = math.pow(10, (math.log(hi) / math.ln10).floor()).toInt();
  return mag;
}

/// 从时间序列里挑出"值得画"的 top N 条线。
///
/// ★ 选择规则（可解释，不是拍脑袋）：
///   ① 至少在两期在榜（只上一期的画不出趋势）；
///   ② 优先"名次最好过"的书 —— 榜首争夺才是读者关心的；
///   ③ 其次看"波动大"的 —— 名次一直在 #40 的书画出来是条直线，没信息量。
/// 折线图画的是哪一种量。
enum ChartMetric {
  /// 名次（越小越好，y 轴反向）。
  rank,

  /// 榜单指标（月票 / 热度 / 积分…越大越好）。
  value,

  /// 字数（越大越好）。
  words,
}

/// 从时间序列里挑出"值得画"的 top N 条线。
///
/// ★ 选择规则（可解释，不是拍脑袋）：
///   - [ChartMetric.rank]：① 至少两期在榜；② 优先"名次最好过"的书（榜首争夺）；
///     ③ 其次看波动 —— 一直挂在 #40 的书画出来是条直线，没信息量。
///   - [ChartMetric.value] / [ChartMetric.words]：① 至少两期有该指标；
///     ② 按**变化幅度**排（涨得最猛 / 跌得最狠的才是要看的那几条）。
List<ChartSeries> pickChartSeries(
  TimeSeriesAnalysis ts, {
  int top = 6,
  ChartMetric by = ChartMetric.rank,
  List<int> palette = const [],
}) {
  final colors = palette.isNotEmpty ? palette : defaultChartPalette;

  if (by == ChartMetric.rank) {
    final cands = ts.tracks.where((t) => t.listedPeriods >= 2).toList();
    if (cands.isEmpty) return const [];
    double score(BookTrack t) {
      final listed =
          t.points.where((p) => p.rank > 0).map((p) => p.rank).toList();
      if (listed.isEmpty) return -1;
      final best = listed.reduce((a, b) => a < b ? a : b);
      final worst = listed.reduce((a, b) => a > b ? a : b);
      return (1000.0 / (best + 5)) + (worst - best) * 2;
    }

    cands.sort((a, b) {
      final c = score(b).compareTo(score(a));
      if (c != 0) return c;
      return a.title.compareTo(b.title);
    });

    final out = <ChartSeries>[];
    for (var i = 0; i < cands.length && out.length < top; i++) {
      final t = cands[i];
      out.add(ChartSeries(
        label: t.obfuscated ? '${t.title}〔名待补〕' : t.label,
        ranks: t.rankSeries,
        color: colors[out.length % colors.length],
      ));
    }
    return out;
  }

  // ── 指标 / 字数：按"变化幅度"挑 ──
  List<double?> seriesOf(BookTrack t) =>
      by == ChartMetric.value ? t.metricSeries : t.wordsSeries;
  int periodsOf(BookTrack t) =>
      by == ChartMetric.value ? t.metricPeriods : t.wordsPeriods;

  final cands = ts.tracks.where((t) => periodsOf(t) >= 2).toList();
  if (cands.isEmpty) return const [];

  /// 首末两个有效观测之间的变化幅度（绝对）。
  double swing(BookTrack t) {
    final vals = seriesOf(t).whereType<double>().toList();
    if (vals.length < 2) return -1;
    return (vals.last - vals.first).abs();
  }

  cands.sort((a, b) {
    final c = swing(b).compareTo(swing(a));
    if (c != 0) return c;
    final va = seriesOf(a).whereType<double>().toList();
    final vb = seriesOf(b).whereType<double>().toList();
    final last = (vb.isEmpty ? 0.0 : vb.last).compareTo(va.isEmpty ? 0.0 : va.last);
    if (last != 0) return last;
    return a.title.compareTo(b.title);
  });

  final out = <ChartSeries>[];
  for (var i = 0; i < cands.length && out.length < top; i++) {
    final t = cands[i];
    out.add(ChartSeries.metric(
      label: t.obfuscated ? '${t.title}〔名待补〕' : t.label,
      values: seriesOf(t),
      color: colors[out.length % colors.length],
    ));
  }
  return out;
}

/// 折线默认配色 —— 12 色循环（画 12 条以上时会重复，界面上会说明）。
List<int> get defaultChartPalette => [
      Palette.accent,
      Palette.ok,
      Palette.warn,
      Palette.bad,
      rgb(180, 140, 255),
      rgb(255, 140, 200),
      rgb(120, 220, 220),
      rgb(255, 200, 120),
      rgb(160, 200, 120),
      rgb(230, 130, 160),
      rgb(140, 170, 255),
      rgb(210, 210, 210),
    ];

/// 把各期"上榜总数"画成柱状（体量变化一眼可见）。
void drawCountBars(
  Gdi g,
  Rc area, {
  required List<String> dates,
  required List<int> counts,
  required int mouseX,
  required int mouseY,
}) {
  final u = Metrics.factor;
  final n = counts.length;
  if (n == 0) return;
  final padL = (34 * u).round();
  final padB = (22 * u).round();
  final plot = Rc(area.left + padL, area.top + (8 * u).round(), area.right,
      area.bottom - padB);
  if (plot.width < 30 || plot.height < 30) return;

  var hi = 0;
  for (final c in counts) {
    if (c > hi) hi = c;
  }
  if (hi <= 0) hi = 1;
  final step = _niceStep(hi);
  final yMax = ((hi + step - 1) ~/ step) * step;

  for (var i = 0; i <= yMax ~/ step; i++) {
    final v = i * step;
    final yy = plot.top + (plot.height * (1 - v / yMax)).round();
    g.line(plot.left, yy, plot.right, yy,
        i == 0 ? Palette.line : Palette.lineFaint);
    g.text('$v',
        Rc.xywh(area.left, yy - (8 * u).round(), padL - (6 * u).round(),
            (16 * u).round()),
        Palette.fgFaint,
        size: Metrics.fontSizeTiny, align: dtRight, vcenter: true);
  }

  final slotW = plot.width / n;
  final barW = (slotW * 0.52).round().clamp(3, (40 * u).round());
  final labelEvery = n <= 8 ? 1 : (n / 6).ceil();
  for (var i = 0; i < n; i++) {
    final cx = plot.left + (slotW * (i + 0.5)).round();
    final bh = (plot.height * (counts[i] / yMax)).round();
    final bar = Rc.xywh(cx - barW ~/ 2, plot.bottom - bh, barW, bh);
    final hot = mouseX >= cx - slotW / 2 &&
        mouseX <= cx + slotW / 2 &&
        mouseY >= plot.top &&
        mouseY <= plot.bottom;
    g.roundFill(bar, hot ? Palette.accentHover : Palette.accentGlow,
        hot ? Palette.accent : Palette.accentGlow,
        radius: (2 * u).round().clamp(0, 4));
    if (i % labelEvery == 0 || i == n - 1) {
      g.text(dates[i],
          Rc.xywh(cx - (26 * u).round(), plot.bottom + (3 * u).round(),
              (52 * u).round(), (16 * u).round()),
          i == n - 1 ? Palette.fgSub : Palette.fgFaint,
          size: Metrics.fontSizeTiny, align: dtCenter, vcenter: true);
    }
  }
}

/// 图表图例（画在图表下方或右上角）。
void drawLegend(
  Gdi g,
  Rc area,
  List<ChartSeries> series, {
  int maxItems = 8,
}) {
  final u = Metrics.factor;
  var x = area.left;
  final y = area.top;
  final fs = Metrics.fontSizeTiny;
  for (var i = 0; i < series.length && i < maxItems; i++) {
    final s = series[i];
    final label = ellipsize(g, s.label, (110 * u).round(), size: fs);
    final tw = g.measure(label, size: fs);
    final dot = (8 * u).round();
    final itemW = dot + (5 * u).round() + tw + (14 * u).round();
    if (x + itemW > area.right) break;
    g.roundFill(
        Rc.xywh(x, y + (area.height - dot) ~/ 2, dot, dot), s.color, s.color,
        radius: dot ~/ 2);
    g.text(label,
        Rc.xywh(x + dot + (5 * u).round(), y, tw + (4 * u).round(),
            area.height),
        Palette.fgSub,
        size: fs, vcenter: true);
    x += itemW;
  }
}

/// 趋势折线的 **y 轴量程**（名次上限）。
///
/// ★★ 为什么必须只有一份：屏幕上和导出的图原来各有一份实现，而且**算法不同**
///   （导出那份先算 p90、又用全 track 的最大值覆盖，p90 等于白算；
///   屏幕那份是 p90 与"最新一期最大名次"取大）。结果是历史里出现一次
///   离群名次时，两张图的 y 轴就不一样 —— 而 `image_export.dart` 的注释
///   正写着"同一绘制代码 → 图必然一致"。
///
/// 规则：取 **p90 与"最新一期最大名次"的较大者**。
///   · 用分位数而不是全局最大：一条掉到 #300 的线会把 y 轴拉到 300，
///     其余书全挤在顶部一条线上，趋势就看不见了；
///   · 又要至少覆盖最新一期：否则最新一期会被裁掉。
int niceRankCap(TimeSeriesAnalysis ts) {
  final all = <int>[];
  for (final t in ts.tracks) {
    for (final p in t.points) {
      if (p.rank > 0) all.add(p.rank);
    }
  }
  if (all.isEmpty) return 10;
  all.sort();
  final p90 = all[((all.length - 1) * 0.9).round()];
  var latestMax = 0;
  if (ts.points.isNotEmpty) {
    for (final e in ts.points.last.result.entries) {
      if (e.rank > latestMax) latestMax = e.rank;
    }
  }
  return p90 > latestMax ? p90 : latestMax;
}

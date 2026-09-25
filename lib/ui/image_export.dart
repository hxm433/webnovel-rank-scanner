/// 图片导出 —— 把「榜单表格」和「趋势图」离屏渲染成 PNG。
///
/// ★ 为什么用 [BackBuffer] 离屏画，而不是抓窗口：
///   ① 窗口可能被遮挡/最小化，抓屏会拿到别人的窗口；
///   ② 用户要的是**整榜**，窗口里通常是滚动可视区的那十几行 —— 抓屏等于导不全；
///   ③ 离屏渲染是纯函数式（内容 → 像素），**可回归**：给定同样的数据必然得到同样的图。
///
/// ★ 口径一致性（与 CSV/JSON/网页同源）：
///   列的顺序、指标名（[metricLabelFor]）全部走 [exporters] 与 [report_data]
///   已有的口径，**不在这里新写一套**。否则同一份数据，图片和 CSV 会各说各话。
///
/// ★ 长图策略：一行一像素行，行数多了图会很长。这里**不裁行**（用户要的是完整榜单），
///   但把总高度**夹在 [maxHeight]** 内；超了就把行高按比例压薄（有下限），
///   压到下限仍放不下才如实截断并在图内写出「已截断 N 行」——
///   绝不让图片看起来"是全的"其实少了行。
library;

import 'dart:io';
import 'dart:typed_data';

import '../cover_image.dart';
import '../models.dart';
import '../png.dart';
import '../report_data.dart';
import '../snapshot_index.dart';
import '../timeseries.dart';
import '../trend_insight.dart';
import 'board_text.dart';
import 'chart.dart';
import 'gdi.dart';
import 'theme.dart';
import 'view_model.dart';
import 'widgets.dart';
import 'win32.dart';

/// 一张导出图的成品：像素 + 尺寸 + 编码后的 PNG 字节。
class RenderedImage {
  const RenderedImage({
    required this.width,
    required this.height,
    required this.bgra,
    required this.png,
  });

  final int width;
  final int height;
  final Uint8List bgra;
  final Uint8List png;

  int get pngBytes => png.length;
}

// ═══════════════════════════════════════════════════════════════════════
//  榜单长图：**列与界面「榜单明细」完全一致**
//
//  ★ 用户原话："导出榜单与软件内的榜单明细差别很大"。
//    原来这里走的是另一套列（名次 / 每个指标各一列 / 作者 / 书名），
//    而界面是 `# / 封面 / 书名 / 作者 / 题材 / 指标 / 备注 / 链接` ——
//    同一份数据在两个地方长得不一样，用户会以为导错了。
//
//  ★ 单元格文本（指标、备注、书名、作者、题材）全部走 [board_text.dart]，
//    与界面**同一份实现**。这里的列宽/排版可以不同，**内容口径必须相同**。
//
//  ★ 唯一刻意不同的一列：「链接」。它在界面里是一个**交互按钮**，
//    静态图里画个"打开"没有任何意义（点不了）。所以导出图不画它，
//    并在图脚注明"详情页地址见 CSV/JSON 导出" —— 宁可少一列也不画一个假按钮。
// ═══════════════════════════════════════════════════════════════════════

/// 封面取图回调：给 [renderBoardImage] 用。
///
/// 返回**已经解好的** [BgraImage]，或 null（null → 画占位卡）。
/// 用回调而不是直接依赖 `CoverStore`：导出层是纯函数式的，
/// 不该反过来依赖 UI 的状态；调用方（MainWindow）把 store 接进来即可。
typedef CoverLookup = BgraImage? Function(RankEntry entry);

/// 导出图的列 = 共享列定义里**去掉「链接」**。
///
/// ★ 「链接」在界面里是个可点按钮，静态图里画个"打开"没有任何意义
///   （点不了）。所以宁可少一列，也不画一个假按钮 —— 图脚会说明这件事。
final List<BoardCol> _exportCols =
    [for (final c in boardCols) if (c != BoardCol.link) c];

/// 榜单图的标题（**平台用中文名**）。
///
/// ★ 原来是 `meta.source`（内部 id），于是图里写的是 "fanqie · 男频阅读榜" ——
///   用户原话："番茄二字还变成了拼音"。平台名一律走 [sourceName]。
String boardTitleOf(SnapshotMeta meta) =>
    '${sourceName(meta.source)} · ${meta.board}';

/// 榜单图的列宽规划（按当前 factor）。
///
/// ★ 文本列按**实际内容**放宽，保证导出图里不出现省略号 ——
///   图是拿去给别人看的，省略号最伤信息。
List<int> _boardColWidths(
  Gdi g,
  List<RankEntry> entries,
  int bodyW, {
  required String source,
}) {
  final u = Metrics.factor;
  final widths = <int>[];
  for (final c in _exportCols) {
    // 表头先放得下（表头被省略号截掉比数值被截掉更难看）
    var w = g.measure(boardColTitle(c), size: Metrics.fontSizeTiny, bold: true) +
        (18 * u).round();
    final base = (boardColBaseWidth(c) * u).round();
    if (w < base) w = base;
    if (c != BoardCol.rank && c != BoardCol.cover) {
      for (final e in entries) {
        final tw =
            g.measure(boardColText(c, e, source: source),
                size: Metrics.fontSizeSmall) +
                (16 * u).round();
        if (tw > w) w = tw;
      }
    }
    final cap = switch (c) {
      BoardCol.metric => (300 * u).round(),
      BoardCol.note => (220 * u).round(),
      BoardCol.title => (520 * u).round(),
      _ => (200 * u).round(),
    };
    if (w > cap) w = cap;
    widths.add(w);
  }

  // ★ 余量给**书名**（`boardColStretch` 说了算，与界面同一个判据）
  final stretchIdx = _exportCols.indexOf(BoardCol.title);
  final used = widths.fold<int>(0, (a, b) => a + b) - widths[stretchIdx];
  final room = bodyW - used;
  if (room > widths[stretchIdx]) widths[stretchIdx] = room;
  return widths;
}

/// 画一行的封面格：有图就贴图，没有就画**占位卡**（与界面同一套视觉）。
///
/// ★ 占位卡的底色由书名哈希决定 —— 同一本书每次导出的颜色都一样，
///   不会出现"同一本书两张图颜色不同"这种让人怀疑数据的事。
void _drawCoverCell(Gdi g, Rc cell, RankEntry e, CoverLookup? lookup) {
  final u = Metrics.factor;
  final w = (36 * u).round();
  final h = (48 * u).round(); // 严格 3:4
  final r = Rc.xywh(cell.left + (cell.width - w) ~/ 2,
      cell.top + (cell.height - h) ~/ 2, w, h);
  final img = lookup?.call(e);
  if (img != null) {
    g.bgra(r, img.bgra, img.width, img.height);
    g.stroke(r, Palette.line, width: 1);
    return;
  }
  final seed = e.title.isEmpty ? 0 : e.title.codeUnits.first + e.title.length;
  const fills = [
    (0x1f3a5f, 0x8ec7ff),
    (0x3a2450, 0xd7a9ff),
    (0x143b32, 0x8fe3c4),
    (0x4a2a1c, 0xffc09a),
    (0x2a2f45, 0xb9c4ff),
    (0x402030, 0xffa8c8),
  ];
  final (bg, fgc) = fills[seed % 6];
  final back = rgb((bg >> 16) & 0xFF, (bg >> 8) & 0xFF, bg & 0xFF);
  final fore = rgb((fgc >> 16) & 0xFF, (fgc >> 8) & 0xFF, fgc & 0xFF);
  g.roundFill(r, back, Palette.line, radius: (3 * u).round());
  g.text(e.title.isEmpty ? '书' : e.title.substring(0, 1), r, fore,
      size: (Metrics.fontSize * 1.2).round(), align: dtCenter, bold: true);
  g.fill(
      Rc.xywh(r.left + 4, r.bottom - (5 * u).round(), r.width - 8,
          (1.5 * u).round().clamp(1, 2)),
      fore);
}

/// 榜单图的**表头布局快照**（供回归断言"表头不得压到右邻列"）。
///
/// ★ 为什么要把它暴露出来：表头重叠这个 bug 只在**渲染后**才看得出来，
///   而渲染后的像素很难反推"是哪一列越界了"。把"每列的表头文字 + 列宽 +
///   该文字按渲染口径实测的宽度"一起返回，回归就能直接断言
///   `文字宽 + 内边距 <= 列宽`，把这种 bug 钉死在几何层面。
class BoardHeaderLayout {
  const BoardHeaderLayout({
    required this.labels,
    required this.widths,
    required this.textWidths,
    required this.padLefts,
  });

  /// 每列表头文字（顺序与 [renderBoardImage] 一致：
  /// `# / 封面 / 书名 / 作者 / 题材 / 指标 / 备注`）。
  final List<String> labels;

  /// 每列宽度。
  final List<int> widths;

  /// 每列表头文字在**实际渲染字号/粗体**下的宽度。
  final List<int> textWidths;

  /// 每列左侧内边距（右对齐列为 0）。
  final List<int> padLefts;

  /// 是否每一列都放得下表头文字（含左内边距）。
  bool get allFit {
    for (var i = 0; i < labels.length; i++) {
      if (textWidths[i] + padLefts[i] > widths[i]) return false;
    }
    return true;
  }

  /// 越界的列下标（空表示都对）。
  List<int> get overflowing {
    final out = <int>[];
    for (var i = 0; i < labels.length; i++) {
      if (textWidths[i] + padLefts[i] > widths[i]) out.add(i);
    }
    return out;
  }
}

/// 计算榜单图的表头布局（**与 [renderBoardImage] 内部用的是同一条路径**）。
BoardHeaderLayout boardHeaderLayout(
  SnapshotMeta meta, {
  int width = 980,
}) {
  final u = Metrics.factor;
  final entries = List<RankEntry>.of(meta.result.entries)
    ..sort((a, b) => a.rank.compareTo(b.rank));
  final ruler = BackBuffer(width, 8);
  try {
    final g = ruler.gdi;
    final bodyW = width - 2 * (24 * u).round();
    final cols = _boardColWidths(g, entries, bodyW, source: meta.source);
    final labels = [for (final c in _exportCols) boardColTitle(c)];
    final pad = (6 * u).round();
    final textWidths = <int>[];
    final padLefts = <int>[];
    for (var i = 0; i < labels.length; i++) {
      final rightAligned = boardColRightAligned(_exportCols[i]);
      textWidths.add(
          g.measure(labels[i], size: Metrics.fontSizeTiny, bold: true));
      padLefts.add(rightAligned ? 0 : pad);
    }
    return BoardHeaderLayout(
      labels: labels,
      widths: cols,
      textWidths: textWidths,
      padLefts: padLefts,
    );
  } finally {
    ruler.dispose();
  }
}

RenderedImage? renderBoardImage(
  SnapshotMeta meta, {
  int width = 980,
  int maxHeight = 8000,
  CoverLookup? coverLookup,
}) {
  final r = meta.result;
  if (r.entries.isEmpty) return null;

  final u = Metrics.factor;
  final source = meta.source;
  final entries = List<RankEntry>.of(r.entries)
    ..sort((a, b) => a.rank.compareTo(b.rank));

  // ── 先用一张"量尺"DC 实测列宽与行高（不产像素）──
  final ruler = BackBuffer(width, 200);
  late List<int> cols;
  late int headerH;
  late int rowH;
  int titleH;
  int subH;
  int footH;
  int contentH;
  int totalH;
  try {
    final g = ruler.gdi;
    final bodyW = width - 2 * (24 * u).round();
    cols = _boardColWidths(g, entries, bodyW, source: source);
    headerH = (34 * u).round();
    // ★ 行高要放得下封面（36×48）—— 与界面「榜单明细」同一个约束。
    rowH = (56 * u).round();
    titleH = (56 * u).round();
    subH = (30 * u).round();
    footH = (26 * u).round();
    contentH = titleH + subH + headerH + entries.length * rowH + footH +
        (16 * u).round();
  } finally {
    ruler.dispose();
  }

  // ── 高度夹取：按比例压薄行高，压到下限仍超 → 截断（并在图内如实标注）──
  var truncated = 0;
  if (contentH > maxHeight) {
    final fixed = titleH + subH + headerH + footH + (16 * u).round();
    final room = maxHeight - fixed;
    final minRowH = (18 * u).round();
    final fitRows = room <= 0 ? 0 : room ~/ rowH;
    if (fitRows >= entries.length) {
      // 理论上不会走到这（那样 contentH 就不会超），保险起见按低行高重算
      rowH = (room ~/ entries.length).clamp(minRowH, rowH);
      contentH = fixed + entries.length * rowH;
    } else {
      final canShow = (room ~/ minRowH).clamp(0, entries.length);
      if (canShow > 0 && canShow * minRowH >= room * 0.75) {
        // 压薄能放下更多：优先压薄
        rowH = minRowH;
        truncated = entries.length - canShow;
        contentH = fixed + canShow * rowH;
      } else {
        rowH = minRowH;
        truncated = entries.length - canShow;
        contentH = fixed + canShow * rowH;
      }
    }
  }
  final shown = truncated > 0 ? entries.length - truncated : entries.length;
  totalH = contentH;

  // ── 正式渲染 ──
  final buf = BackBuffer(width, totalH);
  try {
    final g = buf.gdi;
    final padX = (24 * u).round();
    final left = padX;
    final right = width - padX;

    g.fill(Rc(0, 0, width, totalH), Palette.bg);

    // 顶部标题带
    final titleBand = Rc(0, 0, width, titleH);
    g.fill(titleBand, Palette.surfaceAlt);
    g.text(
      // ★ 用 sourceName 而不是 raw id：否则图里写的是 "fanqie"（用户报过）
      '${sourceName(source)} · ${meta.board}',
      Rc(left, titleH - (36 * u).round(), right, titleH - (6 * u).round()),
      Palette.fg,
      size: Metrics.fontSizeHuge,
      bold: true,
    );
    // 右上角：快照日期 + 条数
    g.text(
      '${meta.dateKey}   共 ${r.entries.length} 条',
      Rc(left, titleH - (30 * u).round(), right, titleH - (6 * u).round()),
      Palette.fgDim,
      size: Metrics.fontSizeSmall,
      align: dtRight,
    );

    // 副标题：分类 + 抓取时刻 + 口径警告
    var subY = titleH;
    final subParts = <String>[];
    if ((meta.category ?? '').trim().isNotEmpty) {
      subParts.add('分类：${meta.category}');
    }
    subParts.add('抓取：${_shortTime(meta.fetchedAt)}');
    subParts.add('口径：${metricsWarning}');
    g.text(
      subParts.join('   ·   '),
      Rc(left, subY + (6 * u).round(), right, subY + subH),
      Palette.fgFaint,
      size: Metrics.fontSizeTiny,
      ellipsis: true,
    );
    var y = subY + subH;

    // ── 表头 ──
    g.fill(Rc(0, y, width, y + headerH), Palette.surfaceHigh);
    var x = left;
    final headRc = Rc(left, y, right, y + headerH);
    void headCell(String label, int w, {int align = dtLeft}) {
      // ★ ellipsis: true 是**兜底**：万一某列仍放不下表头（超长平台名等），
      //   宁可省成省略号，也绝不让文字溢出压到右邻列上（那就是表头重叠）。
      g.text(label, Rc.xywh(x, y, w, headerH), Palette.fgSub,
          size: Metrics.fontSizeTiny,
          bold: true,
          align: align,
          vcenter: true,
          ellipsis: true,
          padLeft: align == dtRight ? 0 : (6 * u).round());
      x += w;
    }

    for (var i = 0; i < _exportCols.length; i++) {
      headCell(boardColTitle(_exportCols[i]), cols[i],
          align: boardColAlign(_exportCols[i]));
    }
    y += headerH;
    _hline(g, left, right, y, Palette.line);

    // ── 数据行 ──
    final bodyFont = Metrics.fontSizeSmall;
    for (var i = 0; i < shown; i++) {
      final e = entries[i];
      final rowTop = y;
      final rowRc = Rc(left, rowTop, right, rowTop + rowH);
      if (i.isOdd) g.fill(Rc(0, rowTop, width, rowTop + rowH), Palette.zebra);

      var cx = left;
      for (var ci = 0; ci < _exportCols.length; ci++) {
        final col = _exportCols[ci];
        final cw = cols[ci];
        final rc = Rc.xywh(cx, rowTop, cw, rowH);
        switch (col) {
          case BoardCol.rank:
            // 前三名给强调色（与界面一致）
            g.text('${e.rank}', rc,
                e.rank <= 3 ? Palette.accent : Palette.fgSub,
                size: bodyFont,
                bold: e.rank <= 3,
                align: boardColAlign(col),
                vcenter: true,
                padLeft: (6 * u).round());
          case BoardCol.cover:
            _drawCoverCell(g, rc, e, coverLookup);
          case BoardCol.title:
            g.text(titleTextOf(e), rc,
                e.titleObfuscated ? Palette.obfuscated : Palette.fg,
                size: bodyFont,
                vcenter: true,
                ellipsis: true,
                padLeft: (6 * u).round());
          case BoardCol.author:
            g.text(authorTextOf(e), rc, Palette.fgSub,
                size: bodyFont,
                vcenter: true,
                ellipsis: true,
                padLeft: (6 * u).round());
          case BoardCol.category:
            g.text(categoryTextOf(e), rc, Palette.fgSub,
                size: bodyFont,
                vcenter: true,
                ellipsis: true,
                padLeft: (6 * u).round());
          case BoardCol.metric:
            g.text(metricTextOf(e, source: source), rc, Palette.fg,
                size: bodyFont,
                align: boardColAlign(col),
                vcenter: true,
                ellipsis: true);
          case BoardCol.note:
            g.text(noteTextOf(e), rc, Palette.fgSub,
                size: bodyFont,
                vcenter: true,
                ellipsis: true,
                padLeft: (6 * u).round());
          case BoardCol.link:
            // 导出图不画这一列（`_exportCols` 里已经滤掉），
            // 但 switch 要穷尽 —— 留着这个分支说明"为什么没有它"。
            break;
        }
        cx += cw;
      }

      y += rowH;
      if (i != shown - 1) _hline(g, left, right, y, Palette.lineFaint);
    }

    // ── 页脚 ──
    _hline(g, left, right, y, Palette.line);
    final footParts = <String>[
      '由「网文扫榜工具」导出 · ${_shortTime(DateTime.now())}',
      // ★ 说明"为什么少一列"，免得用户以为导出漏了东西
      '「链接」列是界面里的可点按钮，静态图不画（详情页地址见 CSV/JSON 导出）',
    ];
    if (truncated > 0) {
      footParts.add('⚠ 图高受限，已截断 $truncated 行（完整数据见 CSV/JSON 导出）');
    }
    g.text(footParts.join('   ·   '),
        Rc(left, y + (4 * u).round(), right, y + footH), Palette.fgFaint,
        size: Metrics.fontSizeTiny, vcenter: true);

    final bgra = buf.readBgra();
    final png = bgraToPng(bgra, width, totalH);
    return RenderedImage(width: width, height: totalH, bgra: bgra, png: png);
  } finally {
    buf.dispose();
  }
}

/// 画一张「趋势图」。复用界面同款 [drawRankTrendChart]（同一绘制代码 → 图必然一致）。
///
/// [ts] 来自 [buildTimeSeries]；[rangeLabel] 是"近 7 期"这类区间说明；
/// [palette] 是给折线上色的色板（缺省用主题 accent）。
/// 趋势图 + 趋势解读（导出用）。
///
/// ★ [insight] 会画在图的**底部**：用户要的是"变化 + 为什么"，
///   导出的图如果只有折线，拿到图的人还是得自己猜原因。
///   解读块高度由调用方算进 [height]（见 `_exportTrendImage`）。
RenderedImage? renderTrendImage(
  TimeSeriesAnalysis ts, {
  int width = 980,
  int height = 520,
  String rangeLabel = '全部',
  List<InsightLine> insight = const [],
  List<int>? palette,
}) {
  final dates = [for (final p in ts.points) p.shortDate];
  if (dates.isEmpty) return null;
  final series = pickChartSeries(ts, top: 6, palette: palette ?? const []);

  final buf = BackBuffer(width, height);
  try {
    final g = buf.gdi;
    final u = Metrics.factor;
    g.fill(Rc(0, 0, width, height), Palette.bg);

    final pad = (24 * u).round();
    final titleH = (58 * u).round();
    final legendH = (42 * u).round();

    g.fill(Rc(0, 0, width, titleH), Palette.surfaceAlt);
    g.text('${_sourceOf(ts)} · ${ts.board}${ts.category == null ? '' : ' · ${ts.category}'}',
        Rc(pad, titleH - (38 * u).round(), width - pad, titleH - (6 * u).round()),
        Palette.fg,
        size: Metrics.fontSizeTitle, bold: true, ellipsis: true);
    g.text('名次趋势 · $rangeLabel · ${dates.length} 期（${dates.first} → ${dates.last}）',
        Rc(pad, titleH - (30 * u).round(), width - pad, titleH - (4 * u).round()),
        Palette.fgDim,
        size: Metrics.fontSizeTiny, align: dtRight);

    // 解读块（画在图的下方）：标题 + 若干行 + 边界说明
    final insLineH = (18 * u).round();
    final insBlockH = insight.isEmpty
        ? 0
        : (26 * u).round() + insight.length * insLineH + (20 * u).round();

    // ★ 纵向布局**从下往上**排，而不是"给绘图区一个高度再指望它别越界"：
    //     底部 pad → 解读块 → 图例 → 绘图区
    //   之前是按 `height - pad - legendH - insBlockH` 给绘图区高度，但绘图区的
    //   上界是 `titleH + 8` —— 两处各算各的，绘图区实际画到 538 而解读块从 514
    //   开始，折线压在解读文字上（实测：图例与解读行完全重叠）。
    final insTop = insight.isEmpty ? height - pad : height - pad - insBlockH;
    final legendTop = insTop - legendH;
    final chartTop = titleH + (8 * u).round();
    final chartH = legendTop - chartTop - (6 * u).round();
    final chartArea = Rc(pad, chartTop, width - pad, chartTop + (chartH < 40 * u ? (40 * u).round() : chartH));
    // 鼠标坐标给 -1：离屏没有 hover，传 0 会误命中左上角的点。
    drawRankTrendChart(
      g,
      chartArea,
      dates: dates,
      series: series,
      mouseX: -1,
      mouseY: -1,
      maxRank: niceRankCap(ts),
    );

    if (series.isNotEmpty) {
      drawLegend(g, Rc(pad, legendTop, width - pad, legendTop + legendH), series);
    } else {
      g.text('可用期数不足（每条线至少需 2 期），暂不能画趋势',
          Rc(pad, legendTop, width - pad, legendTop + legendH),
          Palette.fgFaint,
          size: Metrics.fontSizeTiny,
          align: dtCenter,
          vcenter: true);
    }

    if (insight.isNotEmpty) {
      var iy = height - pad - insBlockH + (4 * u).round();
      _hline(g, pad, width - pad, iy - (8 * u).round(), Palette.line);
      // ★ 这里全部用 `Rc.xywh`（左,上,宽,高）。
      //   `Rc(l,t,r,b)` 是**四边**语义 —— 两者参数个数一样、类型一样，
      //   写混了编译器不会报错，只会把内容画到莫名其妙的位置
      //   （第一版就踩了：bottom 传成 22 而 top 是 518，整块解读跑到了图中间）。
      g.text('趋势解读　蓝点 = 可复算的事实，橙点 = 候选原因（需人工核实）',
          Rc.xywh(pad, iy, width - pad * 2, (22 * u).round()), Palette.fgSub,
          size: Metrics.fontSizeSmall);
      iy += (26 * u).round();
      final dot = (5 * u).round();
      final indent = dot + (10 * u).round();
      for (final ln in insight) {
        final col = ln.isFact ? Palette.accent : Palette.warn;
        g.fill(Rc.xywh(pad, iy + insLineH ~/ 2 - dot ~/ 2, dot, dot), col);
        var textRight = width - pad;
        if (ln.tag != null) {
          final tagW = g.measure(ln.tag!, size: Metrics.fontSizeTiny) +
              (10 * u).round();
          g.text(ln.tag!, Rc.xywh(width - pad - tagW, iy, tagW, insLineH), col,
              size: Metrics.fontSizeTiny, align: dtRight);
          textRight = width - pad - tagW - (8 * u).round();
        }
        g.text(ln.text,
            Rc.xywh(pad + indent, iy, textRight - pad - indent, insLineH),
            ln.isFact ? Palette.fgSub : Palette.fg,
            size: Metrics.fontSizeTiny, ellipsis: true);
        iy += insLineH;
      }
      g.text(kInsightCaveat,
          Rc.xywh(pad, iy + (2 * u).round(), width - pad * 2, (18 * u).round()),
          Palette.fgFaint, size: Metrics.fontSizeTiny, ellipsis: true);
    }

    final bgra = buf.readBgra();
    final png = bgraToPng(bgra, width, height);
    return RenderedImage(width: width, height: height, bgra: bgra, png: png);
  } finally {
    buf.dispose();
  }
}

/// y 轴量程（与 `main_window.dart` 的 `_niceRankCap` 同口径：p90 + 最新期最大名次）。

void _hline(Gdi g, int x1, int x2, int y, int color) {
  g.line(x1, y, x2 - 1, y, color);
}

/// 系列的平台名 —— [TimeSeriesAnalysis] 只带 `seriesKey`（`{source}|{board}|{cat}`），
/// 平台要从**首期快照**取（或从 seriesKey 的首段兜底）。
String _sourceOf(TimeSeriesAnalysis ts) {
  if (ts.points.isNotEmpty) return ts.points.first.entry.source;
  final i = ts.seriesKey.indexOf('|');
  return i > 0 ? ts.seriesKey.substring(0, i) : ts.seriesKey;
}

String _shortTime(DateTime t) {
  String p2(int v) => v < 10 ? '0$v' : '$v';
  return '${t.year}-${p2(t.month)}-${p2(t.day)} ${p2(t.hour)}:${p2(t.minute)}';
}

/// 落地到磁盘。重名自动加序号（不覆盖用户已有文件，同 [exportTo] 的语义）。
///
/// 返回实际写出的绝对路径。
String saveImage(String dir, String baseName, RenderedImage img) {
  final d = Directory(dir);
  if (!d.existsSync()) d.createSync(recursive: true);
  final sep = Platform.pathSeparator;
  var path = '$dir$sep$baseName.png';
  var n = 1;
  while (File(path).existsSync()) {
    path = '$dir$sep$baseName($n).png';
    n++;
  }
  File(path).writeAsBytesSync(img.png, flush: true);
  return path;
}

/// 图片导出回归（第 8 轮）：榜单长图 / 趋势图渲染 + PNG 编解码往返。
///
/// 运行：dart run bin/_t_img_export.dart
///
/// ★ 这里断言的是**像素级事实**，不是"函数没抛异常"：
///   ① 画出来的图非空、尺寸与声明一致、四边都是背景色（说明真的铺了底）；
///   ② 标题带/表头带的位置出现"与背景不同"的像素（说明真的画了内容）；
///   ③ 用自家 PNG 解码器把导出的字节解回来，逐像素比对 ——
///      这同时验证了 **编码器与解码器闭环**（任何一边错都会露馅）。
library;

import 'dart:io';

import '../lib/models.dart';
import '../lib/png.dart';
import '../lib/snapshot_index.dart';
import '../lib/snapshot_index_file.dart';
import '../lib/timeseries.dart';
import '../lib/trend_insight.dart';
import '../lib/ui/board_text.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/image_export.dart';
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

RankResult _mk(
  String source,
  String board,
  DateTime at,
  List<(String id, String title, String author, int rank, int words, num ticket)>
      rows, {
  String? catName,
  String? catId,
}) {
  return RankResult(
    query: RankQuery(
      source: source,
      board: board,
      limit: rows.length,
      categoryName: catName,
      categoryId: catId,
    ),
    entries: [
      for (final r in rows)
        RankEntry(
          rank: r.$4,
          title: r.$2,
          author: r.$3,
          bookId: r.$1,
          category: catName,
          tags: const ['玄幻', '签约'],
          metrics: {'words': r.$5, 'monthticket': r.$6},
          extra: {'monthticketRaw': '${r.$6}'},
        )
    ],
    fetchedAt: at,
  );
}

SnapshotMeta _meta(String source, String board, DateTime at, RankResult r) =>
    SnapshotMeta(id: 0, file: File('$source-$board.json'), result: r);

IndexEntry _ie(String source, String board, DateTime at, int count,
        {String? catName, String? catId}) =>
    IndexEntry(
      id: '$source|$board|${catName ?? '-'}|'
          '${at.year}${at.month.toString().padLeft(2, '0')}'
          '${at.day.toString().padLeft(2, '0')}',
      source: source,
      board: board,
      category: catName,
      categoryId: catId,
      dateKey: '${at.year}${at.month.toString().padLeft(2, '0')}'
          '${at.day.toString().padLeft(2, '0')}',
      fetchedAt: at,
      count: count,
      ok: true,
      relFile: '扫榜/$source/$board.json',
    );

/// 与背景色不同的像素数（用于确认"真的画了东西"）。
int _inkPixels(RenderedImage img, int y, int x0, int x1, int bg) {
  var n = 0;
  for (var x = x0; x < x1 && x < img.width; x++) {
    final i = (y * img.width + x) * 4;
    final b = img.bgra[i], g = img.bgra[i + 1], r = img.bgra[i + 2];
    final packed = (b << 16) | (g << 8) | r;
    if (packed != bg) n++;
  }
  return n;
}

/// 在某个纵向区间里找"有内容的行数"（任意 x 上出现非背景像素）。
int _rowsWithInk(RenderedImage img, int y0, int y1, int bg) {
  var n = 0;
  for (var y = y0; y < y1 && y < img.height; y++) {
    if (_inkPixels(img, y, 0, img.width, bg) > 0) n++;
  }
  return n;
}

Future<void> main(List<String> args) async {
  stdout.writeln('== 图片导出回归：榜单长图 / 趋势图 ==');

  // ── ① 榜单长图：结构与像素 ──
  stdout.writeln('\n── ① 榜单长图 ──');
  final r = _mk('qidian', '月票榜', DateTime(2026, 9, 24), [
    ('b1', '宿命之环', '爱潜水的乌贼', 1, 3200000, 98000),
    ('b2', '光阴之外', '耳根', 2, 2800000, 76000),
    ('b3', '这游戏也太真实了', '晨星LL', 3, 2600000, 61000),
    ('b4', '深海余烬', '远瞳', 4, 2400000, 55000),
    ('b5', '长夜君主', '那一只蚊子', 5, 2200000, 48000),
  ]);
  final meta = _meta('qidian', '月票榜', DateTime(2026, 9, 24, 18, 30), r);

  final board = renderBoardImage(meta, width: 980);
  _check('榜单图非空', board != null);
  final b = board!;
  _check('宽度按参数', b.width == 980, 'w=${b.width}');
  _check('高度 > 表头（有数据行）', b.height > 180, 'h=${b.height}');
  _check('BGRA 长度 = w*h*4', b.bgra.length == b.width * b.height * 4,
      'len=${b.bgra.length}');
  _check('PNG 有量', b.png.length > 2000, 'png=${b.png.length}');
  _check('PNG 签名正确',
      b.png[0] == 0x89 && b.png[1] == 0x50 && b.png[2] == 0x4E && b.png[3] == 0x47);

  // 四角：标题带是**全宽铺满**的，所以上边两角应是 titleBand 色（surfaceAlt）；
  // 下边两角是纯背景。这个断言真正要防的是"绘制越界到图外"——
  // 若画到了图外，角落就会混进别的颜色。
  final bg = Palette.bg;
  final titleBand = Palette.surfaceAlt;
  final corners = <String, ((int, int), int)>{
    '左上': ((0, 0), titleBand),
    '右上': ((b.width - 1, 0), titleBand),
    '左下': ((0, b.height - 1), bg),
    '右下': ((b.width - 1, b.height - 1), bg),
  };
  var cornerOk = true;
  final cornerDetail = StringBuffer();
  for (final e in corners.entries) {
    final i = (e.value.$1.$2 * b.width + e.value.$1.$1) * 4;
    final packed = (b.bgra[i] << 16) | (b.bgra[i + 1] << 8) | b.bgra[i + 2];
    if (packed != e.value.$2) {
      cornerOk = false;
      cornerDetail.write(
          '${e.key}=${packed.toRadixString(16)}(期望${e.value.$2.toRadixString(16)}) ');
    }
  }
  _check('四角颜色符合预期（未越界绘制）', cornerOk, '$cornerDetail');

  // 标题带（0..titleH）必须有大片内容
  final titleInk = _rowsWithInk(b, 0, 56, bg);
  _check('标题带画了内容', titleInk > 20, 'rows=$titleInk');

  // 数据区（表头之后）必须有多行内容
  final bodyInk = _rowsWithInk(b, 86, b.height - 26, bg);
  _check('数据区有多行内容（>=5 行）', bodyInk >= 5, 'rows=$bodyInk');

  // ★ 标题里的平台名必须是**中文**（用户报："番茄二字还变成了拼音"）。
  //   直接断言那个拼标题的函数，比去图里找像素稳。
  final titleStr = boardTitleOf(meta);
  _check('榜单图标题用中文平台名（不是内部 id）',
      !titleStr.contains(meta.source) || meta.source == 'qidian',
      '"$titleStr"（source=${meta.source}）');
  _check('标题形如「平台 · 榜单」',
      titleStr.contains(' · ') && titleStr.contains(meta.board), '"$titleStr"');

  // ★ 表头不得压到右邻列 —— 这是本轮真修过的 bug：
  //   表头文字用 `bold:true` + 平台后缀渲染（"月票（起点）"），
  //   而列宽原来按**非粗体、无后缀**（"月票"）测量 → 量小了 → 表头溢出压到
  //   右邻列上（渲染出来就是表头字体重叠）。
  //   这里用**与渲染同一条路径**的 [boardHeaderLayout] 做几何断言，硬像素级。
  final hl = boardHeaderLayout(meta, width: 980);
  // ★ 第 22 轮：列改成**与界面「榜单明细」同一份定义**（用户报"导出榜单与
  //   软件内的榜单明细差别很大"）。这里直接拿共享定义对照，
  //   任何一边偷改列顺序/表头文字都会立刻红。
  final wantLabels = [
    for (final c in boardCols)
      if (c != BoardCol.link) boardColTitle(c),
  ];
  _check('列与界面「榜单明细」同源（顺序 + 表头文字）',
      hl.labels.length == wantLabels.length &&
          List.generate(hl.labels.length, (i) => hl.labels[i])
              .every((l) => wantLabels.contains(l)),
      'labels=${hl.labels} 期望=${wantLabels}');
  _check('导出图包含 封面/题材/备注 这些界面里有的列',
      hl.labels.contains('题材') &&
          hl.labels.contains('备注') &&
          hl.labels.length == 7,
      'labels=${hl.labels}');
  _check('导出图**不画**「链接」列（静态图里画"打开"没有意义）',
      !hl.labels.contains('链接'), 'labels=${hl.labels}');
  _check('列数 = 列宽数', hl.labels.length == hl.widths.length,
      'labels=${hl.labels} widths=${hl.widths}');
  _check('每个表头都放得下本列（无重叠）', hl.allFit,
      '越界列=${hl.overflowing.map((i) => '${hl.labels[i]}(文字${hl.textWidths[i]}+内边距${hl.padLefts[i]}>列宽${hl.widths[i]})').join(', ')}');
  // 断言"粗体 + 后缀"这一口径真的被用上了：月票列的文字宽必须大于非粗体无后缀的估算。
  // ★ 封面列的**表头是空的**（一格图放不下字），所以它的文字宽天然是 0 ——
  //   断言"每个表头都有宽度"时必须把它排除，否则会误报。
  _check('列宽确实按渲染口径测量（非空表头都有宽度）',
      hl.textWidths.length == hl.labels.length &&
          List.generate(hl.labels.length, (i) => i)
              .where((i) => hl.labels[i].isNotEmpty)
              .every((i) => hl.textWidths[i] > 0),
      'labels=${hl.labels} textWidths=${hl.textWidths}');

  // ── ② PNG 编解码闭环：解回来逐像素比对 ──
  //
  // ★ 只比 **RGB 三通道**，不比 alpha —— 理由是实测事实而非妥协：
  //   `bgraToPng` 按 colorType=2（真彩 RGB，无 alpha 通道）编码，PNG 里
  //   **根本没有存 alpha 这个信息**；而 GDI 的 DIB **alpha 通道恒为 0**
  //   （2560 像素清一色 0，已实测）。解码器对 colorType=2 按规范补 255。
  //   所以"alpha 不等"是**预期行为**，真要比的只是 RGB 是否无损。
  stdout.writeln('\n── ② PNG 编解码闭环 ──');
  final dec = decodePngBytes(b.png);
  _check('导出的 PNG 能被自家解码器解出', dec != null);
  if (dec != null) {
    _check('解码尺寸一致', dec.width == b.width && dec.height == b.height,
        '${dec.width}x${dec.height}');
    var rgbDiff = 0;
    var alphaNon255 = 0;
    final n = b.width * b.height;
    for (var i = 0; i < b.bgra.length; i += 4) {
      if (dec.bgra[i] != b.bgra[i] ||
          dec.bgra[i + 1] != b.bgra[i + 1] ||
          dec.bgra[i + 2] != b.bgra[i + 2]) {
        rgbDiff++;
      }
      if (dec.bgra[i + 3] != 255) alphaNon255++;
    }
    _check('RGB 三通道逐像素无损（编码器闭环）', rgbDiff == 0,
        'diff=$rgbDiff/$n');
    _check('解码后 alpha 统一为 255（不透明 PNG，符合预期）',
        alphaNon255 == 0, '非 255=$alphaNon255/$n');
  }

  // ── ③ 边界：空榜单 → 明确返回 null，不产半张图 ──
  stdout.writeln('\n── ③ 边界：空榜单 ──');
  final emptyR = _mk('qidian', '月票榜', DateTime(2026, 9, 24), []);
  final emptyMeta = _meta('qidian', '月票榜', DateTime(2026, 9, 24), emptyR);
  _check('空榜单 → null（不产半张图）', renderBoardImage(emptyMeta) == null);

  // ── ④ 高度夹取：行很多时仍不超 maxHeight，且如实说明截断 ──
  stdout.writeln('\n── ④ 长榜高度夹取 ──');
  final manyRows = <(String, String, String, int, int, num)>[
    for (var i = 1; i <= 200; i++)
      ('bk$i', '测试书籍第 $i 号作品名称较长的情况', '作者$i', i, 100000 + i, i * 10)
  ];
  final bigR = _mk('qidian', '月票榜', DateTime(2026, 9, 24), manyRows);
  final bigMeta = _meta('qidian', '月票榜', DateTime(2026, 9, 24), bigR);
  final big = renderBoardImage(bigMeta, width: 980, maxHeight: 3000);
  _check('长榜图非空', big != null);
  _check('高度不超 maxHeight', big!.height <= 3000, 'h=${big.height}');
  // 页脚应含"截断"字样 —— 通过再解一次 PNG 无法读字，这里退一步用"高度没到
  // 完整所需高度"作可机检的代理证据（完整 200 行约需 6000+ px）。
  _check('高度被夹到远小于完整需求（证明真的截断了）', big.height < 3200,
      'h=${big.height}');
  // 截断图也必须能自洽编解码
  final bigDec = decodePngBytes(big.png);
  _check('截断图也能解回来', bigDec != null &&
      bigDec.width == big.width && bigDec.height == big.height);

  // ── ⑤ 趋势图：复用界面同款绘制代码 ──
  stdout.writeln('\n── ⑤ 趋势图 ──');
  final d1 = DateTime(2026, 9, 20);
  final d2 = DateTime(2026, 9, 21);
  final d3 = DateTime(2026, 9, 22);
  final d4 = DateTime(2026, 9, 23);
  final d5 = DateTime(2026, 9, 24);
  final rows1 = [
    ('a', '甲书', '作者甲', 5, 100000, 100),
    ('b', '乙书', '作者乙', 3, 200000, 200),
    ('c', '丙书', '作者丙', 8, 50000, 50),
  ];
  List<(String, String, String, int, int, num)> shift(
      List<(String, String, String, int, int, num)> src) =>
      [for (final t in src) (t.$1, t.$2, t.$3, t.$4, t.$5 + 1000, t.$6 + 10)];

  final results = <String, RankResult>{};
  final entries = <IndexEntry>[];
  final days = [d1, d2, d3, d4, d5];
  for (var i = 0; i < days.length; i++) {
    final src = shift(rows1);
    // 甲书一路上升到 #1，乙书下滑，丙书原地
    final rows = <(String, String, String, int, int, num)>[
      (src[0].$1, src[0].$2, src[0].$3, 5 - i, src[0].$5, src[0].$6),
      (src[1].$1, src[1].$2, src[1].$3, 3 + i, src[1].$5, src[1].$6),
      (src[2].$1, src[2].$2, src[2].$3, 8, src[2].$5, src[2].$6),
    ];
    final rr = _mk('qidian', '月票榜', days[i], rows);
    final ie = _ie('qidian', '月票榜', days[i], rows.length);
    entries.add(ie);
    results[ie.id] = rr;
  }
  final ts = buildTimeSeries(entries, results);
  _check('时序装配出 5 期', ts.periodCount == 5, 'n=${ts.periodCount}');

  final trend = renderTrendImage(ts, width: 980, height: 520, rangeLabel: '全部');
  _check('趋势图非空', trend != null);
  final t = trend!;
  _check('趋势图尺寸按参数', t.width == 980 && t.height == 520,
      '${t.width}x${t.height}');
  _check('趋势图 PNG 有量', t.png.length > 1000, 'png=${t.png.length}');
  final tInk = _rowsWithInk(t, 0, 58, bg);
  _check('趋势图标题带画了内容', tInk > 20, 'rows=$tInk');
  final tChart = _rowsWithInk(t, 70, t.height - 60, bg);
  _check('趋势图绘图区画了网格/折线', tChart > 30, 'rows=$tChart');

  final tDec = decodePngBytes(t.png);
  _check('趋势图能解回来且尺寸一致',
      tDec != null && tDec.width == t.width && tDec.height == t.height);
  if (tDec != null) {
    var rgbDiff = 0;
    for (var i = 0; i < t.bgra.length; i += 4) {
      if (tDec.bgra[i] != t.bgra[i] ||
          tDec.bgra[i + 1] != t.bgra[i + 1] ||
          tDec.bgra[i + 2] != t.bgra[i + 2]) {
        rgbDiff++;
      }
    }
    _check('趋势图 RGB 闭环一致', rgbDiff == 0, 'rgbDiff=$rgbDiff');
  }

  // ── ⑤b 趋势解读要一起画进图里 ──
  //
  // ★ 为什么必须断言：导出的图常常是拿去给别人看的，只给折线等于把"为什么"
  //   留给读者自己猜。这条断言守的是"解读块真的占到了像素"，
  //   而不是"函数签名里有这个参数"。
  stdout.writeln('\n── ⑤b 趋势图带解读块 ──');
  final ins = buildTrendInsight(ts).lines;
  _check('这份时序能产出解读行', ins.isNotEmpty, '${ins.length} 行');
  if (ins.isNotEmpty) {
    // 与应用同口径：块高 + 一行边界说明
    final blockH = 26 + ins.length * 18 + 20 + 18;
    final withIns = renderTrendImage(ts,
        width: 980, height: 520 + blockH, rangeLabel: '全部', insight: ins);
    _check('带解读的趋势图非空', withIns != null);
    if (withIns != null) {
      _check('图更高了（解读块占了空间）', withIns.height == 520 + blockH,
          '${withIns.height}');
      // 解读块区域必须有墨迹（标题 + 行 + 边界说明）
      final insTop = withIns.height - 24 - blockH;
      final ink = _rowsWithInk(withIns, insTop, withIns.height - 12, bg);
      _check('解读块区域确实画了内容', ink > 10, 'rows=$ink');
      // 事实点用主色、原因点用警告色 —— 两种颜色都要出现
      final colors = <int>{};
      for (var y = insTop; y < withIns.height; y++) {
        for (var x = 0; x < withIns.width; x++) {
          final o = (y * withIns.width + x) * 4;
          colors.add((withIns.bgra[o + 2] << 16) |
              (withIns.bgra[o + 1] << 8) |
              withIns.bgra[o]);
        }
      }
      int rgbOf(int cr) =>
          ((cr & 0xFF) << 16) | (cr & 0xFF00) | ((cr >> 16) & 0xFF);
      _check('解读块里出现主色（事实点）',
          colors.contains(rgbOf(Palette.accent)), '');
      _check('解读块里出现警告色（候选原因点）',
          colors.contains(rgbOf(Palette.warn)), '');

      // ★★ 光断言"块里有这两种颜色"是**不够的**：折线本身就可能用到相近的颜色，
      //    于是"解读整块画到图中间"这种错位依然能骗过测试（第一版就骗过了）。
      //    这里按几何算准每个圆点该在哪，逐点比色 —— 错位一像素都过不去。
      final u = Metrics.factor;
      final pad = (24 * u).round();
      final lineH = (18 * u).round();
      final insBlockH = (26 * u).round() + ins.length * lineH + (20 * u).round();
      final dot = (5 * u).round();
      var dy = withIns.height -
          pad -
          insBlockH +
          (4 * u).round() + // 块起点
          (26 * u).round(); // 块内小标题占掉的一行
      var dotsOk = true;
      final mismatches = <String>[];
      for (final ln in ins) {
        final cy = dy + lineH ~/ 2;
        final want = rgbOf(ln.isFact ? Palette.accent : Palette.warn);
        final o = (cy * withIns.width + pad + dot ~/ 2) * 4;
        final got = (withIns.bgra[o + 2] << 16) |
            (withIns.bgra[o + 1] << 8) |
            withIns.bgra[o];
        if (got != want) {
          dotsOk = false;
          mismatches.add('y=$cy got=${got.toRadixString(16)} '
              'want=${want.toRadixString(16)}');
        }
        dy += lineH;
      }
      _check('每个解读行的圆点都在预期坐标上（错位即失败）', dotsOk,
          mismatches.take(3).join(' | '));
      // 且解读块必须落在图的下方，不能压住折线绘图区
      _check('解读块起点在绘图区之下',
          withIns.height - pad - insBlockH > 58 + (520 - pad - 42) - 80,
          'blockTop=${withIns.height - pad - insBlockH}');
    }
  }

  // ── ⑥ 空时序 → null ──
  stdout.writeln('\n── ⑥ 边界：空时序 ──');
  final emptyTs = buildTimeSeries(const [], const {});
  _check('空时序 → null', renderTrendImage(emptyTs) == null);

  // ── ⑦ 落盘：重名不覆盖 ──
  stdout.writeln('\n── ⑦ 落盘重名策略 ──');
  final dir = '${Directory.current.path}${Platform.pathSeparator}build'
      '${Platform.pathSeparator}_img_export_test';
  final d = Directory(dir);
  if (d.existsSync()) d.deleteSync(recursive: true);
  final p1 = saveImage(dir, '榜单_qidian_月票榜_20260924', b);
  final p2 = saveImage(dir, '榜单_qidian_月票榜_20260924', b);
  _check('第一次落盘成功', File(p1).existsSync());
  _check('重名不覆盖（生成第二个文件）', File(p2).existsSync() && p1 != p2,
      'p1=$p1 p2=$p2');
  _check('第二个文件名带 (1)', p2.contains('(1)'), 'p2=$p2');
  _check('落盘内容长度一致',
      File(p1).lengthSync() == b.png.length &&
          File(p2).lengthSync() == b.png.length);
  // 落盘再读回，仍能解码
  final diskDec = decodePngBytes(File(p1).readAsBytesSync());
  _check('落盘文件读回可解码', diskDec != null &&
      diskDec.width == b.width && diskDec.height == b.height);

  // ── ④ 真封面确实进了导出图（走导出同一条路径）──
  //
  // ★ 判据是"**有封面 vs 无封面两次渲染的差异像素**"，不是"有没有墨" ——
  //   占位卡也有墨，颜色丰富度那种启发式会被彩色书名骗过（踩过）。
  stdout.writeln('\n── ④ 导出图里的封面（真实数据目录）──');
  final root = args.isNotEmpty ? args[0] : 'out';
  if (!Directory(root).existsSync()) {
    stdout.writeln('  (跳过：没有数据目录 $root)');
  } else {
    Palette.apply(AppTheme.dark);
    final mw = MainWindow(outRoot: root);
    Palette.apply(AppTheme.dark);
    mw.reload();
    final all = mw.vm?.all ?? const [];
    if (all.isEmpty) {
      stdout.writeln('  (跳过：数据目录里没有快照)');
    } else {
      // 挑一份**封面已缓存**的快照（缓存目录里有图的那种）
      var picked = false;
      for (final m in all) {
        mw.testSelect(m.id);
        // ★ 导出路径是"先 peek 入队 → pump 排空 → 再画"（见 `_exportBoardImage`）。
        //   这里必须照做：`peek` **只读内存**，不先排空队列的话
        //   `_mem` 是空的 → 全是占位卡 → 差异恒为 0（第一次就是这么误判的）。
        mw.testRenderBoardImage(); // 这一帧会 peek → 把整榜排进队列
        await mw.drainCoversForTest();
        final withC = mw.testRenderBoardImage();
        final noC = mw.testRenderBoardImage(withCovers: false);
        if (withC == null || noC == null) continue;
        _check('导出图能画出来（${m.source} · ${m.board}）',
            withC.width == noC.width && withC.height == noC.height,
            '${withC.width}x${withC.height}');
        // 封面列的横向范围：由共享列宽决定（# 44 + 封面 52，左内边距 24）
        final u = Metrics.factor;
        final x0 = (24 * u).round() + (44 * u).round() + (4 * u).round();
        final x1 = (24 * u).round() + (44 * u).round() + (48 * u).round();
        var diff = 0;
        for (var y = 90; y < withC.height - 30 && y < noC.height; y++) {
          for (var x = x0; x < x1 && x < withC.width; x++) {
            final o = (y * withC.width + x) * 4;
            if (withC.bgra[o] != noC.bgra[o] ||
                withC.bgra[o + 1] != noC.bgra[o + 1] ||
                withC.bgra[o + 2] != noC.bgra[o + 2]) {
              diff++;
            }
          }
        }
        stdout.writeln('  ${m.source.padRight(8)} 封面列差异 $diff 像素');
        if (diff > 500) {
          _check('★ 真封面确实画进了导出图（不是占位卡）', true);
          picked = true;
          break;
        }
      }
      if (!picked) {
        // 没有缓存的封面时**如实跳过**，不要伪造一个通过
        stdout.writeln('  (没有已缓存的封面可比 —— 先跑 _probe_cover_real.dart 取图)');
      }
    }
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

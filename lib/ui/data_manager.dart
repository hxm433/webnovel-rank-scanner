/// 数据管理窗 —— 「不同时期榜单数据」的集中管理台。
///
/// ★ 解决什么问题：快照会一直攒（每扫一轮、每个榜、每天一份），
///   而在此之前用户能做的只有"在设置窗里改一个保留份数，然后跑一次扫榜"——
///   想删掉某一天那份、想看看磁盘被占了多少、想恢复被隐藏的榜，都没有入口。
///
/// ★ 三块职责，各自独立：
///   ① **按期**：某个系列下每一份快照（日期 / 条数 / 附件 / 占用），可单份删除；
///   ② **按系列**：整段历史一起删，或对整段历史应用"只留最近 N 份"；
///   ③ **隐藏管理**：恢复被隐藏的榜（隐藏 = 侧栏不显示，数据不动）。
///
/// ★ 一切破坏性动作都要**先报数再执行**：确认框里写清"将删除 N 份、释放 X MB"，
///   而不是笼统问一句"确定吗"。删完还要在底栏把真实结果写出来。
library;

import 'dart:io';

import '../snapshot_index_file.dart';
import 'app.dart';
import 'dialogs.dart';
import 'gdi.dart';
import 'main_window.dart' show MainWindow;
import 'view_model.dart' show sourceName;
import 'theme.dart';
import 'widgets.dart';
import 'win32.dart';

/// 一个"系列"（同平台 + 同榜 + 同题材）的全部历史快照。
class SeriesBucket {
  SeriesBucket(this.key, this.source, this.board, this.category, this.entries);

  final String key;
  final String source;
  final String board;
  final String? category;

  /// 该系列的快照（**新→旧**）。
  final List<IndexEntry> entries;

  int get count => entries.length;

  String get label =>
      '$board${category == null ? '' : ' · $category'}';

  /// 系列覆盖的日期范围（旧 → 新，完整年月日）。
  String get rangeLabel {
    if (entries.isEmpty) return '—';
    final oldest = entries.last.dateKey;
    final newest = entries.first.dateKey;
    return oldest == newest ? _dash(newest) : '${_dash(oldest)} → ${_dash(newest)}';
  }

  /// 紧凑的日期范围（`09-15→09-22`），侧栏一行放得下。
  String get shortRangeLabel {
    if (entries.isEmpty) return '—';
    final oldest = _short(entries.last.dateKey);
    final newest = _short(entries.first.dateKey);
    return oldest == newest ? newest : '$oldest→$newest';
  }

  static String _dash(String ymd) => ymd.length == 8
      ? '${ymd.substring(0, 4)}-${ymd.substring(4, 6)}-${ymd.substring(6, 8)}'
      : ymd;

  static String _short(String ymd) => ymd.length == 8
      ? '${ymd.substring(4, 6)}-${ymd.substring(6, 8)}'
      : ymd;
}

/// 数据管理窗。
class DataManagerWindow extends AppWindow {
  DataManagerWindow({required this.owner});

  final MainWindow owner;

  @override
  String get title => '数据管理';

  /// 子窗口固定尺寸（不缩放）：管理台是"看清单 + 点删除"，
  /// 布局按 1000x640 设计得下，能拖大反而让两栏比例失衡。
  @override
  bool get resizable => false;

  @override
  int get captionHeight => Metrics.headerHeight;

  /// 顶栏可拖动；上面的按钮要排除掉。
  @override
  int? onHitTest(int x, int y) {
    final h = Metrics.headerHeight;
    if (y < 0 || y >= h) return null;
    for (final id in const [
      idWinMinimize,
      idWinClose,
      idRefresh,
      idRestoreAll,
      idDeleteSeries,
      idApplyRetention,
      idKeepMinus,
      idKeepPlus,
    ]) {
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) return htClient;
    }
    return htCaption;
  }

  // ── 控件 id ──
  static const int idRefresh = 910;
  static const int idRestoreAll = 911;
  static const int idDeleteSeries = 912;
  static const int idApplyRetention = 913;
  static const int idKeepMinus = 914;
  static const int idKeepPlus = 915;
  static const int idSeriesBase = 1400; // 左栏系列行
  static const int idSnapBase = 1500; // 右栏快照行（选中）
  static const int idDelBase = 1600; // 右栏每行的删除按钮
  static const int idToggleHideBase = 1700; // 左栏每行的隐藏/显示按钮

  final Map<int, Rc> hitRects = {};
  final Map<int, String> seriesKeyById = {};
  final Map<int, String> snapshotIdById = {};
  final Map<int, String> deleteIdById = {};
  final Map<int, String> toggleKeyById = {};

  /// 当前数据（每次 reload 重建）。
  SnapshotIndexFile? index;
  List<SeriesBucket> buckets = [];
  final List<String> errors = [];

  /// 左栏选中的系列键。
  String? selectedSeries;

  /// 右栏选中的快照 id。
  String? selectedSnapshot;

  int seriesScroll = 0;
  int snapshotScroll = 0;
  int seriesContentH = 0;
  int snapshotContentH = 0;

  /// 右栏表格每行的几何（绘制时写入，点击时读用）。
  List<Rc> snapshotRowRects = [];

  /// 「每榜保留份数」（初值取主窗的当前设置）。
  int keepCount = 10;

  static const int keepMin = 0;
  static const int keepMax = 60;

  String statusNote = '';

  bool _built = false;

  @override
  void onResize(int w, int h) {
    if (!_built) {
      _built = true;
      keepCount = owner.retentionPerSeries.clamp(keepMin, keepMax);
      reload();
    }
    invalidate();
  }

  // ── 数据 ──

  void reload() {
    errors.clear();
    final idx = SnapshotIndexFile.load(owner.outRoot, errors: errors);
    index = idx;
    buckets = buildBuckets(idx.entries);
    // 选中项兜底
    if (selectedSeries == null ||
        !buckets.any((b) => b.key == selectedSeries)) {
      selectedSeries = buckets.isEmpty ? null : buckets.first.key;
      selectedSnapshot = null;
    }
    final cur = currentBucket;
    if (cur != null &&
        (selectedSnapshot == null ||
            !cur.entries.any((e) => e.id == selectedSnapshot))) {
      selectedSnapshot = cur.entries.isEmpty ? null : cur.entries.first.id;
    }
    invalidate();
  }

  /// 把索引条目按系列分组（**新→旧**），系列之间按"最新的在前"排。
  ///
  /// ★ 排序口径要跟侧栏一致：先按平台（用 `sourceNames` 的固定顺序），
  ///   再按最新一期时间倒序 —— 否则用户在两处看到两种顺序会以为数据不同。
  static List<SeriesBucket> buildBuckets(List<IndexEntry> entries) {
    final byKey = <String, List<IndexEntry>>{};
    for (final e in entries) {
      (byKey[e.seriesKey] ??= []).add(e);
    }
    final out = <SeriesBucket>[];
    for (final e in byKey.entries) {
      final list = [...e.value]
        ..sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
      final f = list.first;
      out.add(SeriesBucket(e.key, f.source, f.board, f.category, list));
    }
    out.sort((a, b) {
      final sa = sourceOrder(a.source);
      final sb = sourceOrder(b.source);
      if (sa != sb) return sa.compareTo(sb);
      final c = b.entries.first.fetchedAt.compareTo(a.entries.first.fetchedAt);
      if (c != 0) return c;
      return a.label.compareTo(b.label);
    });
    return out;
  }

  /// 平台的固定显示顺序（与侧栏同源）。
  static int sourceOrder(String id) {
    const order = ['qidian', 'fanqie', 'qimao', 'jjwxc'];
    final i = order.indexOf(id);
    return i < 0 ? 99 : i;
  }

  SeriesBucket? get currentBucket {
    for (final b in buckets) {
      if (b.key == selectedSeries) return b;
    }
    return null;
  }

  bool isHidden(SeriesBucket b) => owner.settings.isHidden(b.key);

  /// 一份快照占用的字节（数据文件 + 附件）。
  int sizeOf(IndexEntry e) {
    var n = 0;
    try {
      final f = File('${owner.outRoot}${Platform.pathSeparator}${e.relFile}');
      if (f.existsSync()) n += f.lengthSync();
    } on Object {
      // 读不到就当 0（文件可能刚被别的进程删掉）
    }
    final idx = index;
    if (idx != null) {
      for (final a in idx.listAttachments(e)) {
        n += a.bytes;
      }
    }
    return n;
  }

  int get totalBytes {
    var n = 0;
    for (final b in buckets) {
      for (final e in b.entries) {
        n += sizeOf(e);
      }
    }
    return n;
  }

  int get hiddenCount => buckets.where(isHidden).length;

  // ── 绘制 ──

  @override
  void onPaint(Gdi g) {
    hitRects.clear();
    seriesKeyById.clear();
    snapshotIdById.clear();
    deleteIdById.clear();
    toggleKeyById.clear();
    final u = Metrics.factor;
    g.fill(Rc.xywh(0, 0, width, height), Palette.bg);

    _paintHeader(g);
    _paintBody(g);
    _paintFooter(g);
  }

  void _paintHeader(Gdi g) {
    final u = Metrics.factor;
    final headH = Metrics.headerHeight;
    g.fill(Rc.xywh(0, 0, width, headH), Palette.headerBg);
    g.line(0, headH - 1, width, headH - 1, Palette.line);

    final padx = (18 * u).round();
    final logo = (24 * u).round();
    final ly = (headH - logo) ~/ 2;
    g.roundFill(Rc.xywh(padx, ly, logo, logo), Palette.accent, Palette.accent,
        radius: (6 * u).round());
    g.text('管', Rc.xywh(padx, ly, logo, logo), Palette.bg,
        size: Metrics.fontSizeTiny, align: dtCenter, bold: true);

    final tx = padx + logo + (10 * u).round();
    var bx = width - Metrics.winBtnInset - Metrics.winBtnW * 2 - (10 * u).round();
    final btnH = Metrics.buttonH;
    void hbtn(int id, String label, BtnKind kind, int baseW, {bool enabled = true}) {
      final w = (baseW * u).round();
      bx -= w;
      final r = Rc.xywh(bx, (headH - btnH) ~/ 2, w, btnH);
      hitRects[id] = r;
      drawButton(g, r,
          label: label,
          kind: kind,
          st: CtlState(hot: r.contains(mouseX, mouseY), enabled: enabled));
      bx -= (8 * u).round();
    }

    // 自绘窗口按钮（最小化 + 关闭）—— 管理台不需要最大化
    var wx = width - Metrics.winBtnInset - Metrics.winBtnW * 2;
    for (final entry in const [
      (idWinMinimize, WinBtnKind.minimize),
      (idWinClose, WinBtnKind.close),
    ]) {
      final (id, kind) = entry;
      final r = Rc.xywh(wx, 0, Metrics.winBtnW, Metrics.winBtnH);
      hitRects[id] = r;
      drawWinButton(g, wx, 0,
          kind: kind,
          hot: r.contains(mouseX, mouseY),
          pressed: false,
          windowActive: hasFocus);
      wx += Metrics.winBtnW;
    }

    hbtn(idRestoreAll, '恢复全部隐藏', BtnKind.ghost, 116,
        enabled: hiddenCount > 0);
    hbtn(idRefresh, '刷新', BtnKind.ghost, 64);

    // 标题（最后画，夹在按钮左侧）
    final title = '数据管理';
    final titleW = g.measure(title, size: Metrics.fontSizeTitle, bold: true);
    final sub = '按期 / 按系列管理本地快照';
    final subW = g.measure(sub, size: Metrics.fontSizeTiny);
    final subGap = (14 * u).round();
    final headRight = bx - (16 * u).round();
    final avail = headRight - tx;
    if (avail >= titleW + subGap + subW) {
      g.text(title, Rc.xywh(tx, 0, titleW, headH), Palette.fg,
          size: Metrics.fontSizeTitle, bold: true);
      g.text(sub, Rc.xywh(tx + titleW + subGap, 0, subW, headH), Palette.fgFaint,
          size: Metrics.fontSizeTiny);
    } else if (avail >= titleW) {
      g.text(title, Rc.xywh(tx, 0, titleW, headH), Palette.fg,
          size: Metrics.fontSizeTitle, bold: true);
    }
  }

  void _paintBody(Gdi g) {
    final u = Metrics.factor;
    final pad = (14 * u).round();
    final headH = Metrics.headerHeight;
    final footH = (34 * u).round();
    final top = headH + (12 * u).round();
    final bodyH = height - top - footH - (6 * u).round();
    final leftW = (300 * u).round();

    // ── 左栏：系列清单 ──
    final left = Rc.xywh(pad, top, leftW, bodyH);
    g.roundFill(left, Palette.surface, Palette.line, radius: Metrics.radius);
    final lInner = Rc.xywh(left.left + 1, left.top + 1, left.width - 2,
        left.height - 2);
    final lTitleH = (30 * u).round();
    g.fill(Rc.xywh(lInner.left, lInner.top, lInner.width, lTitleH),
        Palette.surfaceAlt);
    g.line(lInner.left, lInner.top + lTitleH, lInner.right, lInner.top + lTitleH,
        Palette.line);
    g.text('系列（${buckets.length}）', Rc.xywh(lInner.left + (12 * u).round(),
            lInner.top, lInner.width - 24, lTitleH),
        Palette.fg, size: Metrics.fontSizeSmall, bold: true);

    final lView = Rc.xywh(lInner.left, lInner.top + lTitleH, lInner.width,
        lInner.height - lTitleH);
    // 与新的表格行高（Metrics.rowHeight = 42）对齐，两栏看着才像一套
    final rowH = (48 * u).round();
    seriesContentH = buckets.length * rowH;
    final lMax = (seriesContentH - lView.height);
    seriesScroll = seriesScroll.clamp(0, lMax < 0 ? 0 : lMax);

    final endL = g.clipTo(lView);
    var y = lView.top - seriesScroll;
    try {
      for (var i = 0; i < buckets.length; i++) {
        if (y + rowH > lView.top && y < lView.bottom) {
          final b = buckets[i];
          final r = Rc.xywh(lView.left, y, lView.width, rowH);
          final on = b.key == selectedSeries;
          final hot = r.contains(mouseX, mouseY);
          if (on) {
            g.fill(r, Palette.selected);
            g.fill(Rc.xywh(r.left, r.top, (3 * u).round().clamp(2, 5), rowH),
                Palette.accent);
          } else if (hot) {
            g.fill(r, Palette.hover);
          }
          final hid = isHidden(b);
          final dim = hid && !on;
          final tx = r.left + (12 * u).round();
          final toggleW = (26 * u).round();
          // 文本区的右界 = 隐藏按钮左边再留 8px。
          // ★ 两行**右对齐到同一条线**：第一行放份数、第二行放日期区间。
          //   早先把"份数 · 日期区间"挤在一行右对齐，300px 的栏里必然被省略成
          //   "8 份 · 2026-09-15 →" —— 用户看不到区间的后半段，
          //   而"这段历史有多长"恰恰是他判断要不要删的依据。
          final textRight = r.right - toggleW - (10 * u).round();
          final lineH2 = (18 * u).round();
          final countW = (54 * u).round();
          final rangeW = (78 * u).round();
          g.text(sourceName(b.source),
              Rc.xywh(tx, r.top + (3 * u).round(),
                  (textRight - countW - tx).clamp(0, r.width), lineH2),
              dim ? Palette.fgFaint : Palette.fgDim,
              size: Metrics.fontSizeTiny, ellipsis: true);
          g.text('${b.count} 份',
              Rc.xywh(textRight - countW, r.top + (3 * u).round(), countW, lineH2),
              dim ? Palette.fgFaint : Palette.fgSub,
              size: Metrics.fontSizeTiny, align: dtRight);
          g.text(b.label,
              Rc.xywh(tx, r.top + (21 * u).round(),
                  (textRight - rangeW - tx).clamp(0, r.width), lineH2),
              dim ? Palette.fgFaint : Palette.fg,
              size: Metrics.fontSizeSmall, bold: on, ellipsis: true);
          g.text(b.shortRangeLabel,
              Rc.xywh(textRight - rangeW, r.top + (21 * u).round(), rangeW, lineH2),
              Palette.fgFaint,
              size: Metrics.fontSizeTiny, align: dtRight, ellipsis: true);

          // 隐藏/显示小按钮
          final tr = Rc.xywh(r.right - toggleW - (4 * u).round(),
              r.top + (rowH - (20 * u).round()) ~/ 2, (20 * u).round(),
              (20 * u).round());
          hitRects[idToggleHideBase + i] = tr;
          toggleKeyById[idToggleHideBase + i] = b.key;
          drawBadge(g, tr.left, tr.top, tr.height, hid ? '显' : '隐',
              fg: hid ? Palette.warn : Palette.fgFaint,
              fontSize: Metrics.fontSizeTiny);

          hitRects[idSeriesBase + i] = r;
          seriesKeyById[idSeriesBase + i] = b.key;
        }
        y += rowH;
      }
    } finally {
      endL();
    }
    if (seriesContentH > lView.height) {
      drawScrollbar(g, lView,
          contentHeight: seriesContentH,
          viewHeight: lView.height,
          scrollY: seriesScroll,
          hot: lView.contains(mouseX, mouseY));
    }

    // ── 右栏：选中系列的快照表 ──
    final right = Rc.xywh(left.right + pad, top, width - left.right - pad * 2,
        bodyH);
    g.roundFill(right, Palette.surface, Palette.line, radius: Metrics.radius);
    final rInner = Rc.xywh(right.left + 1, right.top + 1, right.width - 2,
        right.height - 2);
    final barH = (46 * u).round();
    g.fill(Rc.xywh(rInner.left, rInner.top, rInner.width, barH),
        Palette.surfaceAlt);
    g.line(rInner.left, rInner.top + barH, rInner.right, rInner.top + barH,
        Palette.line);

    final cur = currentBucket;
    if (cur == null) {
      g.text('左侧还没有系列 —— 先扫一轮榜', rInner, Palette.fgDim,
          size: Metrics.fontSize, align: dtCenter, vcenter: true);
      return;
    }

    // 顶部条：系列名 + 保留步进器 + 应用 + 删除整段
    var bx2 = rInner.right - (12 * u).round();
    void rbtn(int id, String label, BtnKind kind, int baseW) {
      final w = (baseW * u).round();
      bx2 -= w;
      final r = Rc.xywh(bx2, rInner.top + (barH - Metrics.buttonH) ~/ 2, w,
          Metrics.buttonH);
      hitRects[id] = r;
      drawButton(g, r,
          label: label,
          kind: kind,
          st: CtlState(hot: r.contains(mouseX, mouseY)));
      bx2 -= (8 * u).round();
    }

    rbtn(idDeleteSeries, '删除整个系列', BtnKind.danger, 116);
    rbtn(idApplyRetention, '应用保留策略', BtnKind.ghost, 116);
    {
      final sw = stepperWidth;
      final sx = bx2 - sw;
      final sy = rInner.top + (barH - stepperHeight) ~/ 2;
      final mr = Rc.xywh(sx, sy, stepperHeight, stepperHeight);
      final pr = Rc.xywh(sx + sw - stepperHeight, sy, stepperHeight,
          stepperHeight);
      hitRects[idKeepMinus] = mr;
      hitRects[idKeepPlus] = pr;
      final (mr2, _v, pr2) = drawStepper(g, sx, sy,
          value: keepCount,
          enabled: true,
          hotMinus: mr.contains(mouseX, mouseY),
          hotPlus: pr.contains(mouseX, mouseY),
          cap: keepMax,
          // 量词走参数（原来是"先画'本'再拿底色盖掉"的补丁）
          unit: keepCount == 0 ? '不限' : '份');
      hitRects[idKeepMinus] = mr2;
      hitRects[idKeepPlus] = pr2;
      bx2 = sx - (10 * u).round();
      const kl = '每系列保留';
      final klw = g.measure(kl, size: Metrics.fontSizeTiny);
      if (bx2 - rInner.left > klw) {
        g.text(kl, Rc.xywh(bx2 - klw, rInner.top, klw, barH), Palette.fgSub,
            size: Metrics.fontSizeTiny, vcenter: true);
        bx2 -= klw + (10 * u).round();
      }
    }
    // 系列名 + 摘要（吃剩余宽度）
    final nameW = (bx2 - rInner.left - (12 * u).round()).clamp(0, rInner.width);
    if (nameW > 40) {
      g.text('${sourceName(cur.source)} · ${cur.label}',
          Rc.xywh(rInner.left + (12 * u).round(), rInner.top, nameW, barH),
          Palette.fg, size: Metrics.fontSize, bold: true, ellipsis: true);
    }

    // 快照表
    final tableTop = rInner.top + barH;
    final tableArea = Rc.xywh(rInner.left, tableTop, rInner.width,
        rInner.bottom - tableTop);
    final cols = <Column>[
      const Column(key: 'date', title: '日期', width: 120),
      const Column(key: 'count', title: '条数', width: 70, align: dtRight),
      const Column(key: 'att', title: '附件', width: 70, align: dtRight),
      const Column(key: 'size', title: '占用', width: 90, align: dtRight),
      const Column(key: 'note', title: '说明', width: 200, stretch: true),
      const Column(key: 'act', title: '操作', width: 64, align: dtCenter),
    ];
    final rows = <List<String>>[];
    final colors = <int>[];
    for (final e in cur.entries) {
      final idx = index;
      final att = idx == null ? 0 : idx.listAttachments(e).length;
      rows.add([
        SeriesBucket._dash(e.dateKey),
        '${e.count}',
        att == 0 ? '-' : '$att',
        _bytes(sizeOf(e)),
        e.ok ? (e.count == 0 ? '空数据' : '') : '抓取有问题',
        '删除',
      ]);
      colors.add(e.ok ? Palette.fg : Palette.warn);
    }

    final rowH2 = Metrics.rowHeight;
    snapshotContentH = tableContentHeight(rows.length);
    final viewH = tableArea.height - Metrics.headerRowHeight;
    final maxS = snapshotContentH - viewH;
    snapshotScroll = snapshotScroll.clamp(0, maxS < 0 ? 0 : maxS);

    // ★ 自己算一遍每行的矩形（要往行里塞"删除"按钮，drawTable 不给行矩形）。
    //   口径必须与 drawTable 完全一致：bodyTop + i*rowH - scrollY，
    //   且横向要减去滚动条宽度（needScroll 时才减）。
    final needScroll = snapshotContentH > viewH;
    final scrollW = needScroll ? (11 * u).round() : 0;
    final actW = (64 * u).round();
    final actLeft = tableArea.right - scrollW - actW;
    snapshotRowRects = [];
    final bodyTop = tableArea.top + Metrics.headerRowHeight;

    drawTable(g, tableArea, cols, rows,
        scrollY: snapshotScroll,
        mouseX: mouseX,
        mouseY: mouseY,
        rowColors: colors,
        selectedRow: cur.entries.indexWhere((e) => e.id == selectedSnapshot));

    for (var i = 0; i < cur.entries.length; i++) {
      final ry = bodyTop + i * rowH2 - snapshotScroll;
      final rr = Rc.xywh(tableArea.left, ry, tableArea.width, rowH2);
      snapshotRowRects.add(rr);
      if (ry + rowH2 < bodyTop || ry > tableArea.bottom) continue;
      hitRects[idSnapBase + i] = rr;
      snapshotIdById[idSnapBase + i] = cur.entries[i].id;

      // 每行的"删除"小按钮（画在"操作"列里）
      final dr = Rc.xywh(actLeft + (actW - (44 * u).round()) ~/ 2,
          ry + (rowH2 - (22 * u).round()) ~/ 2, (44 * u).round(),
          (22 * u).round());
      hitRects[idDelBase + i] = dr;
      deleteIdById[idDelBase + i] = cur.entries[i].id;
      final dhot = dr.contains(mouseX, mouseY);
      g.roundFill(dr, dhot ? Palette.bad : Palette.surfaceAlt,
          dhot ? Palette.bad : Palette.line, radius: Metrics.radiusSmall);
      g.text('删除', dr, dhot ? Palette.bg : Palette.bad,
          size: Metrics.fontSizeTiny, align: dtCenter, bold: dhot);
    }

    if (needScroll) {
      drawScrollbar(g, tableArea,
          contentHeight: snapshotContentH,
          viewHeight: viewH,
          scrollY: snapshotScroll,
          hot: tableArea.contains(mouseX, mouseY));
    }
  }

  void _paintFooter(Gdi g) {
    final u = Metrics.factor;
    final footH = (34 * u).round();
    final foot = Rc.xywh((14 * u).round(), height - footH,
        width - (28 * u).round(), footH);

    // 右侧：状态提示（破坏性动作的真实结果）
    if (statusNote.isNotEmpty) {
      final nw = g.measure(statusNote, size: Metrics.fontSizeTiny);
      g.text(statusNote,
          Rc.xywh(foot.right - nw - (8 * u).round(), foot.top, nw, footH),
          Palette.warn, size: Metrics.fontSizeTiny, align: dtRight,
          vcenter: true);
    }
    final total = '${buckets.length} 个系列 · '
        '${buckets.fold<int>(0, (a, b) => a + b.count)} 份快照 · '
        '占用 ${_bytes(totalBytes)}'
        '${hiddenCount > 0 ? ' · 已隐藏 $hiddenCount 个系列' : ''}';
    g.text(total, foot, Palette.fgSub, size: Metrics.fontSizeTiny,
        vcenter: true);
  }

  // ── 交互 ──

  @override
  bool onClick(int x, int y) {
    for (final id in const [idWinMinimize, idWinMaximize, idWinClose]) {
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) {
        if (id == idWinMinimize) {
          minimizeWindow();
        } else {
          requestClose();
        }
        return true;
      }
    }

    // ★ 顺序：**每行的删除按钮 → 行本身**。子控件嵌在父控件内部，
    //   先判父就永远点不到子（这条纪律在第 6 轮已经付过一次学费）。
    for (var i = 0; i < snapshotRowRects.length; i++) {
      if (_hit(idDelBase + i, x, y)) {
        final id = deleteIdById[idDelBase + i];
        if (id != null) deleteSnapshot(id);
        return true;
      }
    }
    for (var i = 0; i < buckets.length; i++) {
      if (_hit(idToggleHideBase + i, x, y)) {
        final key = toggleKeyById[idToggleHideBase + i];
        if (key != null) toggleHidden(key);
        return true;
      }
    }
    for (final entry in seriesKeyById.entries) {
      if (_hit(entry.key, x, y)) {
        if (selectedSeries != entry.value) {
          selectedSeries = entry.value;
          selectedSnapshot = _firstId(currentBucket);
          snapshotScroll = 0;
          invalidate();
        }
        return true;
      }
    }
    for (final entry in snapshotIdById.entries) {
      if (_hit(entry.key, x, y)) {
        if (selectedSnapshot != entry.value) {
          selectedSnapshot = entry.value;
          invalidate();
        }
        return true;
      }
    }

    if (_hit(idRefresh, x, y)) {
      reload();
      statusNote = '已重新读取索引与磁盘';
      invalidate();
      return true;
    }
    if (_hit(idRestoreAll, x, y)) {
      restoreAllHidden();
      return true;
    }
    if (_hit(idApplyRetention, x, y)) {
      applyRetention();
      return true;
    }
    if (_hit(idDeleteSeries, x, y)) {
      deleteCurrentSeries();
      return true;
    }
    if (_hit(idKeepMinus, x, y)) {
      if (keepCount > keepMin) keepCount--;
      invalidate();
      return true;
    }
    if (_hit(idKeepPlus, x, y)) {
      if (keepCount < keepMax) {
        // 0 是"不限"，是合法档位 —— 从 0 往上必须先到 1（不能跳到 2）
        keepCount = keepCount == 0 ? 1 : keepCount + 1;
      }
      invalidate();
      return true;
    }
    return false;
  }

  @override
  void onWheel(int x, int y, int delta) {
    final u = Metrics.factor;
    final pad = (14 * u).round();
    final leftW = (300 * u).round();
    final top = Metrics.headerHeight + (12 * u).round();
    final bodyH = height - top - (34 * u).round() - (6 * u).round();
    final lView = Rc.xywh(pad, top, leftW, bodyH);
    final rView = Rc.xywh(leftW + pad * 2, top, width - leftW - pad * 3, bodyH);

    if (lView.contains(x, y) && seriesContentH > lView.height) {
      final step = (48 * u).round();
      final max = seriesContentH - lView.height;
      final next = (seriesScroll - delta * step).clamp(0, max);
      if (next != seriesScroll) {
        seriesScroll = next;
        invalidate();
      }
      return;
    }
    if (rView.contains(x, y)) {
      final viewH = rView.height - (46 * u).round() - Metrics.headerRowHeight;
      if (snapshotContentH > viewH) {
        final step = (48 * u).round();
        final max = snapshotContentH - viewH;
        final next = (snapshotScroll - delta * step).clamp(0, max);
        if (next != snapshotScroll) {
          snapshotScroll = next;
          invalidate();
        }
      }
    }
  }

  @override
  void onMove(int x, int y) {
    // 与主窗同一套省电策略：只有"命中项变了"才重绘。
    final newHot = _hitTestHot(x, y);
    if (newHot == hotId) return;
    hotId = newHot;
    invalidate();
  }

  int _hitTestHot(int x, int y) {
    for (final e in hitRects.entries) {
      if (e.value.contains(x, y)) return e.key;
    }
    return -1;
  }

  bool _hit(int id, int x, int y) {
    final r = hitRects[id];
    return r != null && r.contains(x, y);
  }

  // ── 动作 ──

  /// 删除某一期快照（数据文件 + 附件 + 索引条目）。
  ///
  /// ★ 先报数再动手：确认框里写清是哪一天、多少条、占多少 ——
  ///   只问"确定吗"等于让用户盲签。
  void deleteSnapshot(String id) {
    final cur = currentBucket;
    IndexEntry? e;
    for (final x in cur?.entries ?? const <IndexEntry>[]) {
      if (x.id == id) e = x;
    }
    if (e == null) return;
    final size = _bytes(sizeOf(e));
    final ok = confirmDialog(
      hwnd,
      '删除这一期快照',
      '${SeriesBucket._dash(e.dateKey)} · ${e.count} 条 · 占用 $size\n'
      '附件目录会一起删掉，此操作不可撤销。',
      danger: true,
    );
    if (!ok) {
      statusNote = '已取消';
      invalidate();
      return;
    }
    final idx = index;
    if (idx == null) return;
    final res = idx.deleteEntry(id);
    res.index.save();
    final removed = res.deletedFiles;
    reload();
    selectedSnapshot = _firstId(currentBucket);
    statusNote = removed > 0
        ? '已删除 1 期（$size 已释放）'
        : '索引已移除该期，但磁盘文件未删掉（可能被占用）';
    owner.reload();
    invalidate();
  }

  /// 删除整个系列（该榜的全部历史）。
  void deleteCurrentSeries() {
    final cur = currentBucket;
    final idx = index;
    if (cur == null || idx == null) return;
    var bytes = 0;
    for (final e in cur.entries) {
      bytes += sizeOf(e);
    }
    final ok = confirmDialog(
      hwnd,
      '删除整个系列',
      '「${cur.label}」的全部 ${cur.count} 期快照将被删除'
      '（${cur.rangeLabel}），共 ${_bytes(bytes)}，附件一并删除。\n'
      '此操作不可撤销。',
      danger: true,
    );
    if (!ok) {
      statusNote = '已取消';
      invalidate();
      return;
    }
    var files = 0;
    var next = idx;
    for (final e in cur.entries) {
      final res = next.deleteEntry(e.id);
      next = res.index;
      files += res.deletedFiles;
    }
    next.save();
    reload();
    statusNote = '已删除「${cur.label}」共 ${cur.count} 期 / $files 个文件'
        '（${_bytes(bytes)}）';
    owner.reload();
    invalidate();
  }

  /// 对**全部系列**应用"每系列保留 N 份"。
  void applyRetention() {
    final idx = index;
    if (idx == null) return;
    if (keepCount == 0) {
      statusNote = '保留份数为「不限」，没有需要清理的';
      invalidate();
      return;
    }
    // 先**干跑一次**算出会删多少 —— 破坏性动作必须先报数。
    var wouldDelete = 0;
    var bytes = 0;
    for (final b in buckets) {
      if (b.count <= keepCount) continue;
      for (final e in b.entries.skip(keepCount)) {
        wouldDelete++;
        bytes += sizeOf(e);
      }
    }
    if (wouldDelete == 0) {
      statusNote = '每个系列都在 $keepCount 份以内，无需清理';
      invalidate();
      return;
    }
    final ok = confirmDialog(
      hwnd,
      '应用保留策略',
      '每个系列只保留最近 $keepCount 份，'
      '将删除 $wouldDelete 份旧快照（约 ${_bytes(bytes)}），附件一并删除。\n'
      '此操作不可撤销。',
      danger: true,
    );
    if (!ok) {
      statusNote = '已取消';
      invalidate();
      return;
    }
    final res = idx.pruneSeries(keepPerSeries: keepCount);
    res.index.save();
    // 主窗的设置也跟着走（两处口径必须一致，否则下次扫榜又按旧值裁）
    owner.retentionPerSeries = keepCount;
    owner.persistRetention();
    reload();
    statusNote = '已按保留策略清理 ${res.deletedEntries} 份 / '
        '${res.deletedFiles} 个文件（${_bytes(bytes)}）';
    owner.reload();
    invalidate();
  }

  /// 隐藏 / 显示一个系列（数据不动，只影响侧栏显示）。
  void toggleHidden(String seriesKey) {
    final b = buckets.firstWhere((x) => x.key == seriesKey,
        orElse: () => buckets.first);
    if (isHidden(b)) {
      owner.unhideSeries(seriesKey);
      statusNote = '已恢复显示「${b.label}」';
    } else {
      owner.settings.hideSeries(seriesKey);
      owner.saveSettings();
      owner.reload();
      statusNote = '已隐藏「${b.label}」（数据仍在磁盘上）';
    }
    invalidate();
  }

  void restoreAllHidden() {
    final n = owner.settings.hiddenSeries.length;
    if (n == 0) {
      statusNote = '当前没有被隐藏的系列';
      invalidate();
      return;
    }
    owner.settings.clearHidden();
    owner.saveSettings();
    owner.reload();
    statusNote = '已恢复显示 $n 个系列';
    invalidate();
  }

  @override
  bool onClosing() => true;

  @override
  void onDestroyed() {
    owner.dataManager = null;
    owner.invalidate();
  }

  // ── 工具 ──

  /// 系列里最新一期的 id（空系列 → null）。
  static String? _firstId(SeriesBucket? b) =>
      (b == null || b.entries.isEmpty) ? null : b.entries.first.id;

  // ── 自检钩子（本机跑不了 dart analyze，所以"能不能编译"只能靠真跑一遍）──

  /// 不经窗口就设定客户区尺寸（等价于收到 WM_SIZE）。
  void testSetSize(int w, int h) => setSizeForTest(this, w, h);

  /// 系列数 / 当前系列份数 / 选中项，供自检断言。
  int get testSeriesCount => buckets.length;

  int get testCurrentCount => currentBucket?.count ?? 0;

  String? get testSelectedSeries => selectedSeries;

  /// 选中第 i 个系列（等价于点左栏第 i 行）。
  bool testSelectSeries(int i) {
    if (i < 0 || i >= buckets.length) return false;
    selectedSeries = buckets[i].key;
    selectedSnapshot = _firstId(currentBucket);
    return true;
  }

  /// 直接调"删除某一期"的**数据部分**（不弹确认框），供自检用。
  ///
  /// ★ 为什么不复用 [deleteSnapshot]：那个会弹 MessageBox ——
  ///   自检脚本没法点它，测试会永远挂在那里等用户点"确定"。
  ///   所以把"执行"与"确认"分开：这里只执行。
  bool testDeleteSnapshot(String id) {
    final idx = index;
    if (idx == null) return false;
    final res = idx.deleteEntry(id);
    if (res.deletedEntries == 0) return false;
    res.index.save();
    reload();
    return true;
  }

  static String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) return '${(n / 1048576).toStringAsFixed(1)} MB';
    return '${(n / 1073741824).toStringAsFixed(2)} GB';
  }
}

/// 回归：书封面 / 每本书链接 / 导出菜单分两块（第 17 轮新增）。
///
/// 运行：dart run bin/_t_cover_link.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/cover_store.dart';
import '../lib/guard.dart';
import '../lib/models.dart';
import '../lib/qidian_font.dart';
import '../lib/sources.dart';
import '../lib/webview_fetcher.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/widgets.dart';
import '_render_shots.dart' show renderBgra;

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

/// COLORREF（`0x00BBGGRR`）→ 渲染像素的 `0xRRGGBB`。
///
/// ★ 两个字节序不一样：`Palette.xxx` 是 COLORREF，DIB 里读出来的是 RGB。
///   直接拿 Palette 的值比像素**永远不相等**（踩过）。
int _refToRgb(int c) => ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF);

/// 在 [y] 这一行上数"等于 [rgb] 的像素"个数。
int _countInRow(List<int> bgra, int width, int y, int x0, int x1, int rgb) {
  var n = 0;
  for (var x = x0; x < x1; x++) {
    final o = (y * width + x) * 4;
    final c = (bgra[o + 2] << 16) | (bgra[o + 1] << 8) | bgra[o];
    if (c == rgb) n++;
  }
  return n;
}

/// 造一份带 `cover_url` 的快照（不联网也能验布局）。
String _makeRoot() {
  final root = Directory.systemTemp.createTempSync('rankscan_cover_').path;
  final snapDir = Directory('$root${Platform.pathSeparator}扫榜'
      '${Platform.pathSeparator}qidian')
    ..createSync(recursive: true);
  final entries = <Map<String, Object?>>[];
  for (var i = 1; i <= 6; i++) {
    entries.add({
      'rank': i,
      'title': '样例书名$i',
      'author': '作者$i',
      'book_id': '90000000$i',
      'url': 'https://book.qidian.com/info/90000000$i/',
      if (i <= 3) 'cover_url': 'https://bookcover.yuewen.com/qdbimg/x/$i/150',
      'metrics': {'yuepiao': 1000 - i},
      // ★ 带 `intro` 是**故意的**：备注列曾经把这段几百字的简介塞进去，
      //   结果整列被截成 "任…"。这里放一段标记串，断言它**不该出现**在备注里。
      'extra': {
        'indexChange': '-1',
        'creationStatus': '1',
        'intro': '简介占位：这是一段很长的多行简介，'
            '用来验证它不会被塞进备注列。\n第二行。\n第三行。',
      },
    });
  }
  File('${snapDir.path}${Platform.pathSeparator}月票榜_20260925.json')
      .writeAsStringSync(jsonEncode({
    'result': {
      'query': {'source': 'qidian', 'board': '月票榜', 'limit': 6},
      'entries': entries,
      'fetched_at': DateTime(2026, 9, 25).toIso8601String(),
    }
  }));
  return root;
}

Future<void> main() async {
  stdout.writeln('== 封面 / 链接 / 导出菜单 ==');

  // ── ① 封面尺寸是严格 3:4 ──
  stdout.writeln('\n── ① 封面比例 ──');
  // ★ 明细缩放是**自适应**的（宽窗口 1.5×、窄窗口等比缩到刚好放得下），
  //   所以这里断言的是"**任意缩放下都成立的性质**"，而不是某个具体像素值。
  var ratioOk = true;
  var fitOk = true;
  var minOk = true;
  for (final sc in const [1.0, 1.1, 1.25, 1.4, 1.5]) {
    final cw = Metrics.coverWidthAt(sc);
    final chh = Metrics.coverHeightAt(sc);
    if ((cw * 4 - chh * 3).abs() > 3) ratioOk = false;
    if (Metrics.detailRowHeightAt(sc) < chh + 8) fitOk = false;
    if (cw < 24) minOk = false;
  }
  final cw = Metrics.coverWidthAt(Metrics.detailScale);
  final chh = Metrics.coverHeightAt(Metrics.detailScale);
  _check('封面宽高比恒为 3:4（缩放 1.0 ~ 1.5 全档）', ratioOk,
      '上限档 ${cw}x$chh → ${(cw / chh).toStringAsFixed(3)}（3:4 = 0.750）');
  _check('明细行高恒放得下封面（行高 ≥ 封面高 + 8，全档）', fitOk);
  _check('封面不会太窄（最小档宽 ≥ 24px）', minOk,
      '最小档 ${Metrics.coverWidthAt(1.0)}x${Metrics.coverHeightAt(1.0)}');
  _check('封面不会太宽（高 ≤ 行高）', chh <= Metrics.detailRowHeight, '$chh');
  _check('缩放上限就是用户要的 1.5', Metrics.detailScale == 1.5);
  _check('缩放下限是 1.0（再窄宁可横向滚动，不缩成蚂蚁字）',
      Metrics.detailMinScale == 1.0);

  // ── ② 起点：从榜单行 HTML 提封面（离线夹具）──
  //
  // ★ 用 testParseRow 而不是打网络：这一段要证明的是"封面 URL 提得对、
  //   .webp 去掉了"，网络那一段由 _probe_cover_net.dart 单独验。
  stdout.writeln('\n── ② 起点封面提取 ──');
  final fixture = File('test/fixtures/qidian_yuepiao_page1.html');
  if (fixture.existsSync()) {
    final src = QidianSource(
      Fetcher(
          whitelist: DomainWhitelist(const ['qidian.com']),
          robots: RobotsGuard()),
    );
    final html = fixture.readAsStringSync();
    final rows = RegExp(r'<li data-rid="\d+">(.*?)</li>', dotAll: true)
        .allMatches(html)
        .map((m) => m.group(1)!)
        .toList();
    _check('夹具里切出了榜单行', rows.length >= 5, '${rows.length} 行');
    final font = parseQidianFont(Uint8List(0)); // 空字体表：书名解不出不影响封面
    final parsed = <RankEntry>[];
    for (var i = 0; i < rows.length; i++) {
      final e = src.testParseRow(rows[i], i + 1, font);
      if (e != null) parsed.add(e);
    }
    _check('解析出条目', parsed.isNotEmpty, '${parsed.length} 条');
    final withCover = parsed.where((e) => (e.coverUrl ?? '').isNotEmpty).toList();
    _check('★ 每条都带封面（起点把封面写在榜单行里，不用额外请求）',
        withCover.length == parsed.length, '${withCover.length}/${parsed.length}');
    if (withCover.isNotEmpty) {
      final u = withCover.first.coverUrl!;
      _check('封面 URL 是 https 且指向封面 CDN',
          u.startsWith('https://bookcover.yuewen.com/'), u);
      _check('★ 去掉了 .webp（改成 JPEG 那一版，兼容面更广）',
          !u.endsWith('.webp'), u);
      _check('封面 URL 里的 bookId 与该条一致',
          u.contains(withCover.first.bookId ?? '@@'),
          '${withCover.first.bookId} vs $u');
    }
    _check('每条都有书详情页链接',
        parsed.every((e) => (e.url ?? '').contains('book.qidian.com')),
        parsed.first.url);
  } else {
    stdout.writeln('  (跳过：夹具不存在)');
  }

  // ── ③ 封面白名单 ──
  stdout.writeln('\n── ③ 封面域名白名单 ──');
  _check('放行起点封面 CDN',
      isAllowedCoverHost(Uri.parse('https://bookcover.yuewen.com/a.jpg')));
  _check('放行番茄封面 CDN',
      isAllowedCoverHost(
          Uri.parse('https://p3-reading-sign.fqnovelpic.com/x.image')));
  _check('**拒绝**不在表里的域名',
      !isAllowedCoverHost(Uri.parse('https://evil.example.com/a.jpg')));
  _check('拒绝非 http(s) 协议',
      !isAllowedCoverHost(Uri.parse('file:///c:/a.jpg')));

  // ── ③b 封面地址的**兜底推导**（旧快照没有 cover_url 时的唯一出路）──
  //
  // ★ 这一节直接对应"为什么一个封面都没有"那个报告：18 份旧快照里
  //   没有 cover_url 字段，如果不推导，界面永远是占位卡。
  stdout.writeln('\n── ③b 封面地址推导 ──');
  final qd = deriveCoverUrl('qidian', '1040765595');
  _check('起点：能从 bookId 推导出封面 URL',
      qd == 'https://bookcover.yuewen.com/qdbimg/349573/1040765595/150', '$qd');
  _check('推导出来的 URL 在白名单内',
      qd != null && isAllowedCoverHost(Uri.parse(qd)));
  _check('bookId 为空 → 不推导', deriveCoverUrl('qidian', '') == null);
  _check('bookId 为 null → 不推导', deriveCoverUrl('qidian', null) == null);
  _check('番茄不能推导（地址带签名）', deriveCoverUrl('fanqie', '123') == null);
  _check('七猫不能推导', deriveCoverUrl('qimao', '123') == null);
  _check('晋江不能推导', deriveCoverUrl('jjwxc', '123') == null);

  _check('有采集到的地址时优先用它',
      coverUrlFor('qidian', '1', 'https://bookcover.yuewen.com/x.jpg') ==
          'https://bookcover.yuewen.com/x.jpg');
  _check('没采集到就退回推导',
      coverUrlFor('qidian', '1040765595', null) == qd);
  _check('两边都没有 → null（界面画占位卡）',
      coverUrlFor('fanqie', '123', null) == null);

  // ── ③c 书籍页扒封面（番茄 / 七猫）──
  //
  // ★ 用**合成的页面片段**而不是真页面：既避免把第三方页面塞进仓库，
  //   又正好卡住"URL 形态 + 转义 + 广告图干扰"这三件事。
  stdout.writeln('\n── ③c 书籍页扒封面 ──');
  _check('放行番茄书籍页域名',
      isAllowedPageHost(Uri.parse('https://fanqienovel.com/page/1')));
  _check('放行七猫书籍页域名',
      isAllowedPageHost(Uri.parse('https://www.qimao.com/shuku/1/')));
  _check('**拒绝**别的域名当书籍页',
      !isAllowedPageHost(Uri.parse('https://evil.example.com/page/1')));
  _check('书籍页域名不等于封面 CDN（两张表分开）',
      !isAllowedCoverHost(Uri.parse('https://fanqienovel.com/page/1')));

  // ★ 页面里同时有"作者头像"（reading-sign + avatarUri）和"书封面"（novel-pic）
  const fqHtml = '<img class="author-img" src="'
      'https://p3-reading-sign.fqnovelpic.com/tos-cn-i-x/avatar~tplv-a.jpeg">'
      '<script>"avatarUri":"https://u002F//u002Fp3-reading-sign.fqnovelpic.com'
      '\u002Ftos-cn-i-x\u002Favatar.jpeg"</script>'
      '<img src="https://p9-novel-sign.byteimg.com/novel-pic/p2oabc'
      '~tplv-resize:225:300.image?lk3s=1&amp;x-signature=AbC%3D">'
      '<img src="https://p1-tt.byteimg.com/origin/novel-static/logo.png">';
  final fqCover = extractCoverFromPage('fanqie', fqHtml);
  _check('番茄：从页面里抠出封面 URL（novel-pic 那条）',
      fqCover != null && fqCover.contains('novel-pic'), '$fqCover');
  _check('★ 番茄：作者头像（reading-sign）不会被当封面',
      fqCover != null && !fqCover.contains('reading-sign'), '$fqCover');
  _check('★ `&amp;` 被还原成 `&`（否则签名参数是坏的）',
      fqCover != null && fqCover.contains('&x-signature=') &&
          !fqCover.contains('&amp;'),
      '$fqCover');
  _check('页面里的 logo（别的域名）不会被当封面',
      fqCover != null && !fqCover.contains('byteimg.com/origin'));

  // ★ 故意把**别的书的推荐位封面**放在最前面：必须只认"本书封面"那条路径
  //   （推荐位走 `cdn.wtzw.com/.../public/images/cover/`，本书封面走 `readerCover/`）
  const qmHtml = '<img src='
      '"https://cdn.wtzw.com/bookimg/public/images/cover/35f4/OTHERBOOK_360x480.jpg"'
      ' width="90px" height="120px">'
      '<div class="cover"><img src='
      '"https://cdn.qimao.com/bookimg/zww/upload/readerCover/625/1873260_360x480.jpg"'
      ' width="195px" height="260px"></div>'
      '<img src="https://cdn-front.qimao.com/qimao/pc/img/header/logo.png">';
  final qmCover = extractCoverFromPage('qimao', qmHtml, bookId: '1879266');
  _check('七猫：从页面里抠出封面 URL（readerCover 那条）',
      qmCover != null && qmCover.contains('readerCover'), '$qmCover');
  _check('七猫：不会把 cdn-front 的 logo 当封面',
      qmCover != null && !qmCover.contains('cdn-front'));
  _check('七猫：推荐位（public/images/cover）不会被当成封面',
      qmCover != null && !qmCover.contains('public/images/cover'));
  _check('★ 七猫：认出本书那一张，而不是推荐位的别人的封面',
      qmCover != null && qmCover.contains('readerCover') &&
          !qmCover.contains('OTHERBOOK'),
      '$qmCover');
  _check('七猫封面 CDN（cdn.wtzw.com）在白名单里',
      qmCover != null && isAllowedCoverHost(Uri.parse(qmCover)));
  _check('晋江：没有可扒的规则 → null',
      extractCoverFromPage('jjwxc', '<img src="https://x.com/a.jpg">') == null);
  _check('页面里没有封面 → null',
      extractCoverFromPage('fanqie', '<html>空页面</html>') == null);

  // ── ④ 渲染：封面格 / 链接命中区 ──
  stdout.writeln('\n── ④ 明细表的封面格与链接 ──');
  final root = _makeRoot();
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();
  const w = 1240, h = 800;
  mw.testSetSize(w, h);
  renderBgra(mw.onPaint, w, h); // 先画一帧，把命中区登记出来

  _check('快照载入成功', mw.vm?.all.length == 1, '${mw.vm?.all.length}');
  _check('链接命中区数量与条目一致',
      mw.detailLinkCount == 6, '${mw.detailLinkCount}');

  // ★★ 第 20 轮：明细缩放**自适应**之后，基准窗（1240×800）下 8 列
  //   全部放得下 —— 用户那句"小窗口时，右边无法看见"就是被这里治好的。
  final needX = mw.testDetailNaturalWidth - (mw.detailTableArea?.width ?? 0);
  _check('★ 基准窗下 8 列放得下（不需要横向滚动）', needX <= 0,
      'natural=${mw.testDetailNaturalWidth} '
      'view=${mw.detailTableArea?.width} 缩放=${mw.testDetailScale.toStringAsFixed(3)}');
  _check('基准窗下不出现横向滚动条', mw.testDetailHScrollRect == null,
      '${mw.testDetailHScrollRect}');
  // ★ 行高 60（自适应缩到 ~1.0），一屏放得下的行数随窗口变 —— 断言
  //   "**每一行画出来的**都有链接"才对。
  _check('每一行画出来的都有链接命中区',
      mw.detailLinks.length >= 5 && mw.detailLinks.length <= 6,
      '${mw.detailLinks.length}（一屏画得下几行就登记几行）');

  // 封面格与书名格的矩形（从表格回传的 cellRects 里取）
  final detail = mw.hitRects[MainWindow.idDetailTable];
  _check('明细表命中区已登记', detail != null);
  // 链接按钮：行 0 的「打开」格必须落在明细表内部
  final link0 = mw.hitRects[MainWindow.idBookLinkBase + 0];
  final title0 = mw.hitRects[MainWindow.idBookTitleLinkBase + 0];
  _check('★ 基准窗下第 1 行「打开」按钮就登记了命中区（不用先滚动）',
      link0 != null, '$link0');
  _check('第 1 行书名格也是链接命中区', title0 != null, '$title0');
  if (link0 != null && detail != null) {
    _check('「打开」按钮落在表格区域内', detail.contains(link0.left + 1, link0.top + 1),
        'btn=$link0 table=$detail');
  }
  if (title0 != null && detail != null) {
    // ★ 第 19 轮起命中区会**裁到可见区域**，所以书名格可能只剩一窄条
    //   （横向滚到最右时书名被挤出屏幕，只剩右边缘露着）。
    //   这里断言的是"它在可见区内"，而不是"它比按钮宽" ——
    //   后者是旧设计（书名是唯一大目标）的残留，现在整行才是大目标。
    _check('书名格命中区落在表格可见区内',
        detail.contains(title0.left, title0.top), 'title=$title0');
  }

  // ★★ 第 19 轮补：**整行都能点**（用户报"链接点击无效"）。
  //   原来只有 97×50 的按钮和书名格能点，用户点偏一点就毫无反应，
  //   分不清是"没点准"还是"坏了"。明细表这一行的唯一动作就是打开这本书。
  final row0 = mw.testBookRowRect(0);
  _check('第 1 行有**整行**链接命中区', row0 != null, '$row0');
  if (row0 != null) {
    _check('整行命中区比「打开」按钮大得多',
        row0.width > (link0?.width ?? 0) * 3,
        '${row0.width} vs ${link0?.width}');
    _check('整行命中区被裁进可见区域（不越界）',
        mw.testDetailArea != null &&
            row0.left >= mw.testDetailArea!.left &&
            row0.right <= mw.testDetailArea!.right,
        'row=$row0 area=${mw.testDetailArea}');
    // 点行的最左边（# 列上）也必须能打开
    final before = mw.statusText;
    final hit = mw.onClick(row0.left + 4, row0.top + row0.height ~/ 2);
    _check('点整行最左边也能打开（不用点中那个小按钮）',
        hit && mw.statusText != before && mw.statusText.startsWith('已打开详情页'),
        'hit=$hit status="${mw.statusText}"');
  }
  // ── ④b 窄到连 1.0 倍都放不下时：横向滚动 + **不留幻影点击区** ──
  //
  // ★ 这是自适应的兜底分支：缩放已经到下限 1.0 还放不下（比如 700px 宽的窗），
  //   此时才允许横向滚动；而"看不见的单元格不许登记命中区"必须仍然成立。
  stdout.writeln('\n── ④b 极窄窗的兜底：横向滚动 ──');
  const nw = 700, nh = 600;
  mw.testSetSize(nw, nh);
  mw.testScrollDetailX(0);
  renderBgra(mw.onPaint, nw, nh);
  _check('极窄窗下缩放到下限 1.0', mw.testDetailScale == Metrics.detailMinScale,
      '${mw.testDetailScale}');
  _check('极窄窗下确实放不下（出现横向滚动条）',
      mw.testDetailHScrollRect != null &&
          mw.testDetailNaturalWidth > (mw.testDetailArea?.width ?? 0),
      'natural=${mw.testDetailNaturalWidth} '
      'view=${mw.testDetailArea?.width}');
  _check('★ 横向没滚到链接列时，「打开」不登记命中区（不留幻影点击区）',
      mw.testBookButtonRect(0) == null, '${mw.testBookButtonRect(0)}');
  _check('★ 但整行命中区照样在（点行仍能打开）', mw.testBookRowRect(0) != null);
  mw.testScrollDetailX(1 << 20);
  renderBgra(mw.onPaint, nw, nh);
  _check('滚到最右后「打开」才登记命中区，且在可见区内',
      mw.testBookButtonRect(0) != null &&
          mw.testBookButtonRect(0)!.right <= (mw.testDetailArea?.right ?? 0),
      '${mw.testBookButtonRect(0)}');
  mw.testSetSize(w, h);
  renderBgra(mw.onPaint, w, h);

  // 没有封面 URL 的那几行（夹具里是第 4~6 行）也必须能打开 —— 链接与封面是两件事
  final noCoverRow = [3, 4, 5]
      .where((i) => mw.testBookRowRect(i) != null)
      .toList();
  _check('没有封面的行同样有链接命中区（画出来的那些）',
      noCoverRow.isNotEmpty, '命中区行: $noCoverRow');

  // ── ⑤ 封面仓库：白名单 + 无地址时的占位 ──
  stdout.writeln('\n── ⑤ 封面仓库行为 ──');
  final store = CoverStore(root: '$root${Platform.pathSeparator}_covers');
  _check('没有 cover_url 时 peek 返回 null 且不入队',
      store.peek('qidian', 'no-cover', null) == null && !store.hasWork);
  _check('非法域名的 cover_url 不入队（直接当失败）',
      store.peek('qidian', 'bad', 'https://evil.example.com/a.jpg') == null &&
          !store.hasWork);
  _check('bookId 为空时直接返回 null', store.peek('qidian', null, 'https://x') == null);

  // ── ⑥ 导出菜单分两块 ──
  stdout.writeln('\n── ⑥ 导出菜单分两块 ──');
  final secs = mw.testMenuSections('export');
  _check('导出菜单有 2 个分组', secs.length == 2, '${secs.length}');
  _check('第一组标题 = 榜单', secs[0].title.contains('榜单'), secs[0].title);
  _check('第二组标题提到趋势/对比',
      secs[1].title.contains('趋势') && secs[1].title.contains('对比'),
      secs[1].title);
  final boardItems = secs[0].items.join('|');
  final trendItems = secs[1].items.join('|');
  _check('「榜单」组里有 CSV / JSON / 榜单图 / 附件',
      boardItems.contains('CSV') &&
          boardItems.contains('JSON') &&
          boardItems.contains('榜单图片') &&
          boardItems.contains('附件'),
      boardItems);
  _check('「趋势」组里有趋势图与汇总对比',
      trendItems.contains('趋势图') && trendItems.contains('汇总'), trendItems);
  _check('两组没有重叠项', !secs[0].items.any(secs[1].items.contains));
  _check('每个分组项都能映射到唯一控件 id',
      {for (var si = 0; si < secs.length; si++)
        for (var ii = 0; ii < secs[si].items.length; ii++)
          mw.testMenuIdAt('export', si, ii)}.length ==
          secs[0].items.length + secs[1].items.length);
  final imp = mw.testMenuSections('import');
  _check('导入菜单只有一组（不画多余的标题）',
      imp.length == 1 && imp[0].title.isEmpty, '${imp.length}');

  // ── ⑦ 分组菜单的排版：项不重叠、都在框内 ──
  stdout.writeln('\n── ⑦ 分组菜单排版 ──');
  final l = layoutSectionedMenu(
      const Rc(0, 0, 80, 30), mw.testMenuSections('export'));
  final rs = l.items.map((e) => e.$3).toList();
  var overlap = false;
  for (var i = 1; i < rs.length; i++) {
    if (rs[i].top < rs[i - 1].bottom) overlap = true;
  }
  _check('菜单项自上而下不重叠', !overlap);
  _check('菜单项都在浮层内',
      rs.every((r) => r.left >= l.box.left && r.right <= l.box.right &&
          r.top >= l.box.top && r.bottom <= l.box.bottom),
      'box=${l.box}');
  _check('两组标题各占一行', l.headers.length == 2, '${l.headers.length}');

  // ── ⑧ 明细表 1.5 倍放大：尺寸、滚动上限、横向滚动 ──
  //
  // ★ 这一节的判据全部是**可复算的数**，不是"看着差不多"：
  //   1.5 倍是用户点名的要求，就得能拿尺子量出来。
  stdout.writeln('\n── ⑧ 明细表 1.5 倍放大 ──');
  final ds = mw.testDetailScale; // 自适应缩放
  _check('实际缩放落在 [1.0, 1.5] 区间',
      ds >= Metrics.detailMinScale && ds <= Metrics.detailScale + 1e-9,
      ds.toStringAsFixed(3));
  _check('行高 = 基准 60 × 实际缩放',
      mw.testDetailRowHeight == (60 * ds).round(), '${mw.testDetailRowHeight}');
  _check('表头高 = 基准 46 × 实际缩放',
      mw.testDetailHeaderHeight == (46 * ds).round(),
      '${mw.testDetailHeaderHeight}');
  _check('字号 = 基准 14 × 实际缩放',
      mw.testDetailFontSize == (14 * ds).round(), '${mw.testDetailFontSize}');
  _check('封面 = 基准 36×48 × 实际缩放 且仍是 3:4',
      mw.testCoverWidth == (36 * ds).round() &&
          mw.testCoverHeight == (48 * ds).round() &&
          (mw.testCoverWidth * 4 - mw.testCoverHeight * 3).abs() <= 3,
      '${mw.testCoverWidth}x${mw.testCoverHeight}');
  _check('封面解码尺寸 ≥ 显示尺寸（放大后仍清晰）',
      Metrics.coverDecodeW >= mw.testCoverWidth &&
          Metrics.coverDecodeH >= mw.testCoverHeight,
      '${Metrics.coverDecodeW}x${Metrics.coverDecodeH}');

  // 自然总宽 = Σ(列基准宽) × factor × 1.5。列基准宽写死在 _paintDetail 里，
  // 这里按同一张表复算 —— 对不上说明有人偷偷改了列宽。
  const colBase = [44, 52, 220, 104, 88, 220, 110, 62]; // rank/cover/title/author/cat/metric/note/link
  final expectW =
      (colBase.fold<int>(0, (a, b) => a + b) * Metrics.factor * ds).round();
  _check('自然总宽 = Σ列基准宽 × factor × 实际缩放',
      mw.testDetailNaturalWidth == expectW,
      '实测 ${mw.testDetailNaturalWidth} / 期望 $expectW');

  // ★ 常量写对了**不等于画出来就是那个数**（布局里可能用了别的行高）。
  //   这里**量像素**：每一行的底边有一条 `Palette.lineFaint` 分隔线横贯整行，
  //   相邻两条线的距离就是渲染出来的真实行高。判据是坐标，不是"看着差不多"。
  mw.testScrollDetailX(0);
  mw.testScrollDetailY(0);
  final area0 = mw.testDetailArea;
  if (area0 != null) {
    final px = renderBgra(mw.onPaint, w, h);
    final lineRgb = _refToRgb(Palette.lineFaint);
    final x0 = area0.left + 4;
    final x1 = area0.left + area0.width - 60; // 让开右侧纵向滚动条
    final span = x1 - x0;
    final seps = <int>[];
    for (var y = area0.top + 2; y < area0.bottom - 2; y++) {
      if (_countInRow(px, w, y, x0, x1, lineRgb) > span * 0.9) seps.add(y);
    }
    _check('量到行分隔线（判据本身有效）', seps.length >= 2, '$seps');
    if (seps.length >= 2) {
      final pitches = <int>[];
      for (var i = 1; i < seps.length; i++) {
        pitches.add(seps[i] - seps[i - 1]);
      }
      _check('★ 渲染出来的行高 = 实际缩放算出来的行高（量像素，不是看代码）',
          pitches.every((p) => p == mw.testDetailRowHeight),
          '间距 $pitches / 期望 ${mw.testDetailRowHeight}');
    }
  }

  // 纵向滚动上限：滚轮"能滚到哪"必须与绘制"画到哪"是同一个数，
  // 否则最后一行永远滚不全（放大表头后差 2×(69−46)=46px，正好半行）。
  final area = mw.testDetailArea;
  _check('明细表可见区已登记', area != null, '$area');
  if (area != null) {
    final expectMaxV = mw.testDetailHeaderHeight +
        6 * mw.testDetailRowHeight -
        (area.height - mw.testDetailHeaderHeight);
    _check('★ 纵向滚动上限与绘制侧同源（放大表头后不再差半行）',
        mw.testDetailMaxScroll == (expectMaxV < 0 ? 0 : expectMaxV),
        '实测 ${mw.testDetailMaxScroll} / 期望 ${expectMaxV < 0 ? 0 : expectMaxV}');
    _check('纵向滚动上限 > 0（6 行放不下）', mw.testDetailMaxScroll > 0);

    // 滚到底 → 最后一行（第 6 行）必须真的被画出来
    mw.testScrollDetailY(1 << 20);
    _check('滚到底时偏移正好等于上限',
        mw.testDetailScrollY == mw.testDetailMaxScroll,
        '${mw.testDetailScrollY} vs ${mw.testDetailMaxScroll}');
    renderBgra(mw.onPaint, w, h);
    _check('★ 滚到底后最后一行被画出来（不再差半行）',
        mw.detailLinks.containsKey(5), '画出的行: ${mw.detailLinks.keys.toList()}');
    mw.testScrollDetailY(0);

    // ★ 基准窗下自适应缩放已经让它放得下 → **不该**出现横向滚动条。
    //   横向滚动条只在"缩到下限 1.0 还放不下"的极窄窗里才该出现（见 ④b）。
    _check('基准窗下不出现横向滚动条（自适应缩放放得下）',
        mw.testDetailHScrollRect == null, '${mw.testDetailHScrollRect}');
  }

  // 横向滚轮：正 = 往右，且被夹在 [0, maxX]。
  // ★ 得先把窗口缩到"放不下"，否则 maxX=0、滚不动（自适应之后基准窗放得下）。
  mw.testSetSize(700, 600);
  renderBgra(mw.onPaint, 700, 600);
  final area2 = mw.testDetailArea;
  final hsb = mw.testDetailHScrollRect;
  _check('极窄窗下出现横向滚动条', hsb != null, '$hsb');
  if (hsb != null && area2 != null) {
    final barW = (11 * Metrics.factor).round();
    _check('横向滚动条贴表格底边', hsb.bottom == area2.bottom, '$hsb');
    // ★ 右下角两条滚动条不能互相压住：横向的右边要让出纵向那条的宽度
    _check('★ 横向滚动条给纵向那条让开一格（右下角不互压）',
        hsb.right <= area2.right - barW,
        'h.right=${hsb.right} 上限=${area2.right - barW}');
  }
  final cx = (area2?.left ?? 300) + 40, cy = (area2?.top ?? 200) + 40;
  final maxX = mw.testDetailNaturalWidth - (area2?.width ?? 0);
  mw.testScrollDetailX(0);
  mw.testHWheel(cx, cy, 120);
  _check('横向滚轮（往右）能推进偏移', mw.testDetailScrollX > 0,
      '${mw.testDetailScrollX}');
  mw.testHWheel(cx, cy, 1 << 20);
  _check('往右滚到底被夹在 maxX', mw.testDetailScrollX == maxX,
      '${mw.testDetailScrollX} vs $maxX');
  mw.testHWheel(cx, cy, -(1 << 20));
  _check('往左滚到底被夹在 0', mw.testDetailScrollX == 0,
      '${mw.testDetailScrollX}');
  // 指针不在表上时不该动
  mw.testScrollDetailX(50);
  mw.testHWheel(2, 2, 500);
  _check('指针不在明细表上时横向滚轮不生效', mw.testDetailScrollX == 50,
      '${mw.testDetailScrollX}');

  // ── ⑨ 备注列不再塞小说简介 ──
  //
  // ★ 用户原话："删除备注里的有关小说的简介"。简介是多行几百字，
  //   塞进一格的结果是整列被截成 "任…"，真正有用的短字段也看不清。
  stdout.writeln('\n── ⑨ 备注列的内容 ──');
  final note0 = mw.testNoteTextOf(0);
  _check('备注有内容（不是空的）', note0.isNotEmpty, '"$note0"');
  _check('★ 备注里没有小说简介（夹具第 1 行 extra 带 intro）',
      !note0.contains('简介占位'), '"$note0"');
  _check('备注是单行短文本（不含换行）', !note0.contains('\n'), '"$note0"');
  _check('备注长度克制（≤ 40 字）', note0.length <= 40, '${note0.length} 字');

  // ── ⑩ 宽屏下表格**撑满可用区**（右侧不留空缺）──
  //
  // ★ 用户原话："把右边的空缺补上"。根因是绘制宽度恒等于"自然总宽"，
  //   宽屏下自然总宽 < 可用宽 → 表格画完就收笔，右边空一大块。
  stdout.writeln('\n── ⑩ 宽屏撑满（右侧不留空缺）──');
  mw.testSetSize(2400, 1400);
  renderBgra(mw.onPaint, 2400, 1400);
  final wideArea = mw.testDetailArea;
  final wideNatural = mw.testDetailNaturalWidth;
  _check('宽屏下自然总宽 < 可用宽（复现"放得下"的情形）',
      wideArea != null && wideNatural < wideArea.width,
      'natural=$wideNatural view=${wideArea?.width}');
  _check('★ 放得下时实画宽 = 可用宽（右侧无空缺）',
      wideArea != null && mw.testDetailDrawnWidth == wideArea.width,
      'drawn=${mw.testDetailDrawnWidth} view=${wideArea?.width}');
  _check('★ 放得下时不出现横向滚动条', mw.testDetailHScrollRect == null,
      '${mw.testDetailHScrollRect}');
  // 内容右缘要贴到可见区右缘（只让开纵向滚动条那一格）
  final vBar = (11 * Metrics.factor).round();
  final contentRight = (wideArea?.left ?? 0) +
      mw.testDetailDrawnWidth -
      (mw.testDetailMaxScroll > 0 ? vBar : 0);
  _check('★ 内容右缘贴齐可见区右缘',
      wideArea != null &&
          contentRight == wideArea.right - (mw.testDetailMaxScroll > 0 ? vBar : 0),
      '$contentRight vs ${wideArea?.right}');
  mw.testSetSize(w, h); // 还原，免得影响后面的断言

  // 清场
  try {
    Directory(root).deleteSync(recursive: true);
  } on Object {}

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

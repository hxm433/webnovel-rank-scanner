/// 四个平台的适配器。传输/解析分离，解析部分可喂夹具离线测。
///
/// 与原版 `lib/rank/rank_source_*.dart` 的**实质差异**：
/// ① 起点走 www 站多页榜单（25 页 × 20 = 500 本），并就地破解其**运行时
///    字体反爬**（见 `qidian_font.dart`）；无可用浏览器内核时降级到移动站 20 条。
/// ② 番茄走补齐参数后的 `category/list`（原版直接放弃番茄）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'fanqie_font.dart';
import 'gbk.dart';
import 'guard.dart';
import 'models.dart';
import 'qidian_font.dart';
import 'webview_fetcher.dart';

/// 榜名不在枚举内：**不静默改用默认榜**，而是空结果 + 指回枚举
/// （对应原版"缺 board → 让你先 list_boards"的约定）。
FetchOutcome _badBoard(Iterable<String> valid, String got) => FetchOutcome(
      const [],
      RankQuality(
        ok: false,
        validCount: 0,
        totalCount: 0,
        summary: '榜名「$got」不存在',
        problems: ['可用榜单：${valid.join('、')}（先用 boards 子命令查）'],
      ),
    );

/// 起点书籍详情页 URL —— **必须用移动站域名**。
///
/// ★ 实测（2026-09-27，带正常浏览器 UA 的 HTTP 抓取）：
///   · `https://book.qidian.com/info/{id}/` → 302 → `www.qidian.com/book/{id}/`
///     → **202**，正体是一段 209 字节的 JS 反爬挑战页（`<body></body>` 空壳）。
///     原实现用的就是这个，用户点「打开」后浏览器停在该挑战页上 ——
///     表现就是"链接打不开、跳不到详情页"。
///   · `https://www.qidian.com/book/{id}/` → 同样 **202**（www 主站有 WAF）。
///   · `https://m.qidian.com/book/{id}/` → **200**，标题
///     「{书名}({作者}) 小说在线阅读-首发起点中文网手机端」，真·详情页。
///   所以统一走 m 站：绕开主站 WAF，点开即达详情页（m 站也有"转电脑版"入口）。
String qidianBookUrl(String bookId) => 'https://m.qidian.com/book/$bookId/';

// ───────────────────────────── 起点 ─────────────────────────────

class QidianSource implements RankSourceAdapter {
  /// ★ www 站的 chanId 优先（那是主路径）；移动站的 catId 作为兜底。
  ///   两个 id 空间不同，但**只用来做文件名区分**，同义即可 ——
  ///   关键是"同一个分类名每次得到同一个值"。
  @override
  String? categoryIdOf(String? name) {
    if (name == null || name.isEmpty) return null;
    return categories[name] ?? _mobileCategories[name];
  }

  QidianSource(this.fetcher, {WebViewFetcher? renderer})
      // ★ 把**同一个** robots 与 limiter 传下去：
      //   ① 渲染通道原来完全没判 robots；② 原来各有一个限速器 → 实际 2× 速率。
      : renderer = renderer ??
            WebViewFetcher(
              whitelist: fetcher.whitelist,
              robots: fetcher.robots,
              limiter: fetcher.limiter,
            );
  final Fetcher fetcher;

  /// 渲染抓取器（用系统 Edge 过 WAF）。不可用时降级到移动站。
  final WebViewFetcher renderer;

  /// 最近一次 www 站抓取失败的原因（降级时如实带给用户看）。
  String? _lastWebError;

  static const String id = 'qidian';

  /// www 站榜单 slug（实测自 `www.qidian.com/rank/*` 的导航链接）。
  ///
  /// ★ 与移动站 `m.qidian.com` 的 slug **完全不同**：
  ///   移动站那套（newbook/newauthor/sign/rec/update）在 www 站是 404。
  ///   以 www 站为准（只有它有 25 页 × 20 = 500 本）。
  static const Map<String, String> boards = {
    '畅销榜': 'hotsales',
    '月票榜': 'yuepiao',
    '阅读指数榜': 'readindex',
    '推荐榜': 'recom',
    '收藏榜': 'collect',
    '更新榜': 'vipup',
    '追读榜': 'followReading',
    '留存榜': 'retention',
    '书友榜': 'newfans',
    '潜力榜': 'potential',
    '未签约新书榜': 'pubnewbook',
    '签约新书榜': 'signNewBkAll',
    'VIP收藏榜': 'vipcollect',
    '女生精选榜': 'mm',
  };

  /// 题材（www 站 `data-chanid`；`-1` = 全站）。
  /// ★ www 站走 `/rank/<slug>/chn<id>/`（channelId），不是移动站的 `catid`。
  static const Map<String, String> categories = {
    '全站': '-1', '玄幻': '21', '奇幻': '1', '武侠': '2', '仙侠': '22', '都市': '4',
    '现实': '15', '军事': '6', '历史': '5', '游戏': '7', '体育': '8', '科幻': '9',
    '悬疑灵异': '10', '轻小说': '12',
  };

  /// 移动站降级用榜单。
  static const Map<String, String> _mobileBoards = {
    '畅销榜': 'hotsales', '月票榜': 'yuepiao', '阅读指数榜': 'readindex',
    '推荐榜': 'rec', '更新榜': 'update',
  };

  /// 移动站题材 catId。
  static const Map<String, String> _mobileCategories = {
    '全站': '-1', '玄幻': '21', '奇幻': '1', '武侠': '2', '仙侠': '22', '都市': '4',
    '现实': '15', '军事': '6', '历史': '5', '游戏': '7', '体育': '8', '科幻': '9',
    '悬疑灵异': '10', '诸天无限': '20109', '轻小说': '12',
  };

  // ── 解析用正则：类级 static final 只编译一次 ──
  //   www 站每页几十行、每行都要跑这一组；现场 `RegExp(...)` 等于每行
  //   重新编译十几条正则，是抓 500 本时最没必要的开销。
  //   模式与拆分前的字面量逐字一致（含 dotAll / 字符类 / 转义）。
  static final RegExp _reRows =
      RegExp(r'<li data-rid="\d+">(.*?)</li>', dotAll: true);
  static final RegExp _reTitle = RegExp(r'<h2><a[^>]*>([^<]+)</a>');
  static final RegExp _reBid = RegExp(r'data-bid="(\d+)"');
  static final RegExp _reRank = RegExp(r'rank-tag[^"]*">(\d+)<cite>');
  static final RegExp _reAuthor =
      RegExp(r'<a class="name"[^>]*>([^<]*)</a>');
  static final RegExp _reCat =
      RegExp(r'<a href="//www\.qidian\.com/([a-z0-9]+)"[^>]*>([^<]+)</a>');
  static final RegExp _reSub =
      RegExp(r'<a class="go-sub-type"[^>]*>([^<]+)</a>');
  static final RegExp _reStatus =
      RegExp(r'</a><em>\|</em><span>([^<]+)</span>');
  static final RegExp _reIntro =
      RegExp(r'<p class="intro">(.*?)</p>', dotAll: true);
  static final RegExp _reUpd = RegExp(r'最新更新([^<]*)</a>');
  static final RegExp _reDate =
      RegExp(r'</a><em>·</em><span>([^<]+)</span>');
  static final RegExp _reMetric = RegExp(
      r'<span class="[A-Za-z0-9]+">([^<]+)</span></span>'
      r'([月票推荐指数阅读收藏粉丝更字热度积分]+)');
  static final RegExp _reWs = RegExp(r'\s+');
  static final RegExp _reCover =
      RegExp(r'src="(//bookcover\.yuewen\.com/[^"]+?)"');
  static final RegExp _reFontUrl =
      RegExp(r'qd_anti_spider/([A-Za-z0-9]+)\.(?:woff|ttf)');
  static final RegExp _rePageMax = RegExp(r'data-pagemax="(\d+)"');

  @override
  String get sourceId => id;
  @override
  String get displayName => '起点中文网（www 站多页榜单）';
  @override
  List<String> get supportedBoards => boards.keys.toList(growable: false);

  /// www 站榜单 URL。`page` 从 1 起；`chanId` = -1 表示全站（不带路径段）。
  Uri webUrlFor(String board, int page, String chanId) {
    final slug = boards[board] ?? 'hotsales';
    final seg = chanId == '-1' ? '' : 'chn$chanId/';
    return Uri.parse(
        'https://www.qidian.com/rank/$slug/$seg${page <= 1 ? '' : 'page$page/'}');
  }

  /// 移动站 URL（降级路径）。
  Uri mobileUrlFor(String board, String catId) => Uri.parse(
      'https://m.qidian.com/rank/${_mobileBoards[board] ?? 'hotsales'}/catid$catId/');

  @override
  Future<FetchOutcome> fetch(RankQuery q) async {
    // ★ 采集入口先清空上一次的 www 失败原因：否则这次走降级路径时，
    //   会把**上一榜**的失败原因当成本次原因写进 quality（张冠李戴）。
    _lastWebError = null;
    if (!boards.containsKey(q.board)) {
      return _badBoard(boards.keys, q.board);
    }
    // ★ 优先"渲染抓取"（能用上 25 页 × 20 = 500 本）。
    if (renderer.available) {
      final r = await _fetchWeb(q);
      if (r != null) return r;
    }
    // ★ 降级只走移动站真实支持的榜：`_mobileBoards` 只有 5 个，
    //   其余榜以前会 `?? 'hotsales'` 静默换成畅销榜再按原榜名落盘 ——
    //   错误数据比没有数据更糟（会进趋势/导出）。
    if (!_mobileBoards.containsKey(q.board)) {
      return FetchOutcome(
        const [],
        RankQuality(
          ok: false,
          validCount: 0,
          totalCount: 0,
          summary: '「${q.board}」移动站无对应榜单，且渲染通道不可用',
          problems: [
            '该榜只有 www 站提供（需要 WebView2/Edge 渲染通道）。'
                '当前可降级的移动站榜单：${_mobileBoards.keys.join('、')}',
          ],
        ),
      );
    }
    // 降级：移动站，每榜固定 20 条。
    return _fetchMobile(q);
  }

  /// www 站多页抓取。任何一步失败返回 null（由调用方降级），
  /// **不抛异常**（与适配器契约一致）。
  Future<FetchOutcome?> _fetchWeb(RankQuery q) async {
    final chanId = q.categoryId ?? categories[q.categoryName] ?? '-1';
    final want = q.limit.clamp(1, 600);
    final out = <RankEntry>[];
    final notes = <String>[];
    // ★★ 分类名查不到时必须**说出来**。原来 `?? '-1'` 静默退成"全站"：
    //   用户点的是"玄幻"，抓回来的却是全站榜，还按"玄幻"落盘 —— 零感知。
    //   （实测 www 表缺 `诸天无限` 而移动站表有，真实分类会走到这条路上。）
    //   这里不改成报错（那会让整个榜抓不成），而是把降级写进 quality，
    //   与文件头"不静默改用默认榜"的承诺对齐。
    final asked = q.categoryName;
    final askedIsAll = asked == null || asked.isEmpty || asked == '全站';
    if (chanId == '-1' && !askedIsAll && !categories.containsKey(asked)) {
      notes.add('分类「$asked」在本站分类表里查不到，已按全站抓取'
          '（数据仍按该分类名落盘，请自行核对）');
    }
    String? firstUrl;
    var pageMax = 25;
    var fontDecoded = 0;
    var fontFailed = 0;
    String? firstPageError;

    for (var page = 1; page <= pageMax && out.length < want; page++) {
      final url = webUrlFor(q.board, page, chanId);
      firstUrl ??= '$url';
      final rp = await renderer.render(url);
      if (!rp.ok) {
        if (page == 1) {
          // 第一页就失败 → 降级，但**把原因带出去**（别静默降级，
          // 否则用户看到"只有 20 条"却不知道是浏览器没起来）。
          firstPageError = rp.error;
          break;
        }
        notes.add('第 $page 页未取到（${rp.error}）');
        break;
      }
      // ★★ 把**渲染那条 URL 的 robots 判定**回写给 fetcher：
      //   `ScanService.lastVerdict` 读的是 `_fetcher.lastVerdict`（HTTP 通道），
      //   而起点 www 站每页都走渲染 —— 不回写的话，快照里那句 verdict
      //   描述的是**另一个请求**（甚至可能一次 HTTP 都没发过）。
      if (renderer.lastVerdict != null) {
        fetcher.lastVerdict = renderer.lastVerdict;
      }
      if (page == 1) {
        final pm = _rePageMax.firstMatch(rp.html);
        if (pm != null) pageMax = (int.tryParse(pm.group(1)!) ?? 25).clamp(1, 50);
      }
      // ★ 字体表每页重新解析：实测字体名/码点基址/映射每页都变，
      //   复用上一页的表必然解出乱码（比解不出更危险）。
      final font = await _loadFont(rp.html);
      final rows = _webRows(rp.html);
      if (rows.isEmpty) {
        if (page == 1) return null;
        break;
      }
      for (final row in rows) {
        final r = _webRowToEntry(row, out.length + 1, font);
        if (r == null) continue;
        if (r.sawObfuscated) {
          if (r.decoded) {
            fontDecoded++;
          } else {
            fontFailed++;
          }
        }
        out.add(r.entry);
      }
    }

    if (out.isEmpty) {
      // 一页都没解析出来：把第一页的失败原因留给降级路径显示。
      _lastWebError = firstPageError ?? '首屏未解析到榜单行（页面结构可能改版）';
      return null;
    }
    final entries = out.take(want).toList();
    final totalObf = fontDecoded + fontFailed;
    // ★ "没看到混淆" ≠ "指标都解析出来了"：页面结构一变（或本来就是明文），
    //   metrics 会是空的。旧文案无条件说"明文数字"，等于谎报数据完整。
    final withMetric = entries
        .where((e) => e.metrics.keys.any((k) => k != 'words'))
        .length;
    final obfNote = totalObf == 0
        ? (withMetric == entries.length
            ? '该榜无字体反爬（明文数字）'
            : '该榜未解出全部指标：$withMetric/${entries.length} 条带有指标'
                '（原文可能是明文数字，或页面结构已变化）')
        : '字体反爬：$fontDecoded/$totalObf 条已解码'
            '${fontFailed == 0 ? '' : '，$fontFailed 条未解码（不采信其指标）'}';
    return FetchOutcome(
      entries,
      RankQuality(
        ok: true,
        validCount: entries.length,
        totalCount: entries.length,
        summary: 'www 站多页抓取：${entries.length} 条'
            '（共 $pageMax 页 × 20 上限）；$obfNote'
            '${notes.isEmpty ? '' : '；${notes.join('；')}'}',
        problems: [
          if (fontFailed > 0)
            '有 $fontFailed 条指标字体未能解码，其数值已丢弃（宁可缺，不可错）',
          if (totalObf == 0 && withMetric < entries.length)
            '有 ${entries.length - withMetric} 条未解析到指标（可能不是混淆数字，或页面结构已变）',
        ],
      ),
      url: firstUrl,
    );
  }

  /// 取该页的指标字体并解析成解码表。页面无字体（明文榜）→ 空表。
  Future<QidianFontTable> _loadFont(String html) async {
    final m = _reFontUrl.firstMatch(html);
    if (m == null) return QidianFontTable(const {});
    final uri = Uri.parse(
        'https://qdfepccdn.qidian.com/gtimg/qd_anti_spider/${m.group(1)}.ttf');
    // ★ 字体走的是同一个 fetcher，会覆盖 lastVerdict；而报告要的是榜单页
    //   那一跳的判定。先存后恢复，避免 robots 描述张冠李戴。
    final savedVerdict = fetcher.lastVerdict;
    try {
      final bytes = await fetcher.getBytes(uri, accept: 'font/ttf,*/*');
      return parseQidianFont(Uint8List.fromList(bytes));
    } on Object {
      return QidianFontTable(const {});
    } finally {
      fetcher.lastVerdict = savedVerdict;
    }
  }

  /// 从 www 站页面切出每本书的行 HTML（<li data-rid="N">…</li>）。
  List<String> _webRows(String html) {
    final out = <String>[];
    for (final m in _reRows.allMatches(html)) {
      out.add(m.group(1)!);
    }
    return out;
  }

  /// 把一行 HTML 变成 [RankEntry]（含字体解码）。
  ///
  /// [testParseRow] 是本方法的自检入口（离线喂夹具，不打网络）。
  _WebRow? _webRowToEntry(String row, int fallbackRank, QidianFontTable font) {
    final titleM = _reTitle.firstMatch(row);
    final title = titleM?.group(1)?.trim() ?? '';
    if (title.isEmpty) return null;
    final bid = _reBid.firstMatch(row)?.group(1);
    final coverUrl = _qidianCoverFromRow(row);
    final rankM = _reRank.firstMatch(row);
    final authorM = _reAuthor.firstMatch(row);
    // ★ 题材 slug 可能含数字（如轻小说 = `/2cy`），所以字符类要带 0-9。
    final catM = _reCat.firstMatch(row);
    final subM = _reSub.firstMatch(row);
    final statusM = _reStatus.firstMatch(row);
    final introM = _reIntro.firstMatch(row);
    final updM = _reUpd.firstMatch(row);
    final dateM = _reDate.firstMatch(row);
    // 指标：数字被包在 <span class="<随机字体类>">…</span></span><单位>
    final metricM = _reMetric.firstMatch(row);

    final metrics = <String, num>{};
    final extra = <String, String>{};
    var sawObf = false;
    var decoded = false;
    if (metricM != null) {
      final rawDigits = metricM.group(1)!;
      final unit = metricM.group(2)!;
      sawObf = true;
      extra['metricRaw'] = rawDigits;
      extra['metricUnit'] = unit;
      decoded = font.canDecodeFully(rawDigits);
      if (decoded) {
        final v = num.tryParse(font.decode(rawDigits));
        final key = metricKeyFromUnit(unit);
        if (v != null && v.isFinite && key != null) metrics[key] = v;
      }
      // ★ 解不出就不写 metrics（宁可缺，不可错）；原值留在 extra 里可核。
    }
    if (bid != null) extra['bookId'] = bid;
    _putExtra(extra, 'status', statusM?.group(1));
    _putExtra(extra, 'updatedAt', dateM?.group(1));
    _putExtra(extra, 'latestChapter', updM?.group(1));
    final intro = introM?.group(1)?.replaceAll(_reWs, ' ').trim();
    if (intro != null && intro.isNotEmpty) extra['intro'] = truncateIntro(intro);

    return _WebRow(
      RankEntry(
        rank: int.tryParse(rankM?.group(1) ?? '') ?? fallbackRank,
        title: title,
        author: authorM?.group(1)?.trim() ?? '',
        bookId: bid,
        category: catM?.group(2)?.trim(),
        tags: [if (subM != null) subM.group(1)!.trim()],
        url: bid == null ? null : qidianBookUrl(bid),
        coverUrl: coverUrl,
        metrics: metrics,
        extra: extra,
        titleObfuscated: false,
      ),
      sawObfuscated: sawObf,
      decoded: decoded,
    );
  }

  /// 从一行 HTML 里取书封面 URL。
  ///
  /// ★ 起点把封面直接写在榜单行里（`<img src="//bookcover.yuewen.com/qdbimg/
  ///   349573/{bookId}/150.webp">`），所以**不需要额外请求** —— 这是四个平台里
  ///   唯一一个"抓榜单顺带就有封面"的。
  ///
  /// ★ 为什么要把 `.webp` 去掉：实测同一张图 `/150.webp` 返回 `image/webp`、
  ///   `/150` 返回 `image/jpeg`。虽然 WIC 两种都能解，但 JPEG 兼容面更广
  ///   （万一系统没装 WebP 解码器），所以统一取 JPEG 那一版。
  static String? _qidianCoverFromRow(String row) {
    final m = _reCover.firstMatch(row);
    if (m == null) return null;
    var u = m.group(1)!;
    if (u.endsWith('.webp')) u = u.substring(0, u.length - 5);
    return 'https:$u';
  }

  /// 降级路径：移动站 SSR（每榜固定 20 条，无翻页）。
  Future<FetchOutcome> _fetchMobile(RankQuery q) async {
    final catId = q.categoryId ?? _mobileCategories[q.categoryName] ?? '-1';
    final askedM = q.categoryName;
    final catFallback = catId == '-1' && askedM != null && askedM.isNotEmpty;
    final url = mobileUrlFor(q.board, catId);
    // ★ 不带 Referer：实测带 Referer 时起点 WAF 会返回验证脚本。
    final html = await fetcher.getString(url);
    final entries = _parseMobile(html, q);
    final pd = _mobilePageData(html);
    final total = pd?['total'];
    return FetchOutcome(
      entries,
      RankQuality(
        ok: entries.isNotEmpty,
        validCount: entries.length,
        totalCount: entries.length,
        summary: entries.isEmpty
            ? '未解析到 records'
            : '【降级】移动站单榜 ${entries.length} 条'
                '（未检测到可用浏览器内核，无法走 www 站多页；pageData.total=$total）'
                '${catFallback ? '；分类「$askedM」查不到，已按全站抓取' : ''}'
                '；★ 移动站 records 不含连载/完结字段，本榜「备注」列会显示 `-`',
        problems: entries.isEmpty
            ? const ['未找到 pageContext.pageData.records，页面可能改版']
            : [
                '降级路径每榜上限 20 条；装 Edge/WebView2 可抓到 500 条',
                '移动站榜单不含「连载/完结」状态，备注列为 `-`'
                    '（装 Edge/WebView2 走 www 站即可显示）',
                if (_lastWebError != null) 'www 站抓取失败原因：$_lastWebError',
              ],
      ),
      url: '$url',
    );
  }

  /// 纯解析（移动站）：喂录制夹具即可离线测，不打网络。
  List<RankEntry> _parseMobile(String html, RankQuery query) {
    final out = <RankEntry>[];
    for (final r in _mobileRecords(html)) {
      final name = r['bName'];
      if (name is! String || name.trim().isEmpty) continue;
      final rankCnt = r['rankCnt'];
      final cnt = r['cnt'];
      final metrics = <String, num>{};
      if (rankCnt is String) {
        final v = parseCnNumber(rankCnt);
        final key = metricKeyFromUnit(rankCnt);
        if (v != null && key != null) metrics[key] = v;
      }
      if (cnt is String) {
        final w = parseCnNumber(cnt);
        if (w != null) metrics['words'] = w;
      }
      final bid = r['bid'];
      final extra = <String, String>{};
      if (bid != null) extra['bookId'] = '$bid';
      if (rankCnt is String) extra['rankCntRaw'] = rankCnt;
      if (cnt is String) extra['wordsRaw'] = cnt;
      final desc = r['desc'];
      if (desc is String && desc.trim().isNotEmpty) {
        extra['intro'] = truncateIntro(desc);
      }
      // ★ rankNum 只认 num：远端偶尔给字符串/缺字段，强转会 TypeError
      //   把整个移动站降级路径打挂；退回"出现顺序"这一既有兜底。
      final rankNum = r['rankNum'];
      out.add(RankEntry(
        rank: rankNum is num ? rankNum.toInt() : (out.length + 1),
        title: name.trim(),
        author: (r['bAuth'] is String) ? r['bAuth'] as String : '',
        bookId: bid == null ? null : '$bid',
        category: (r['cat'] is String) ? r['cat'] as String : null,
        tags: (r['subCat'] is String) ? [r['subCat'] as String] : const [],
        url: bid == null ? null : qidianBookUrl('$bid'),
        metrics: metrics,
        extra: extra,
        titleObfuscated: privateUseCount(name) > 0,
      ));
    }
    return out;
  }

  List<Map> _mobileRecords(String html) {
    final pd = _mobilePageData(html);
    final recs = pd?['records'];
    return recs is List ? recs.whereType<Map>().toList() : const [];
  }

  Map? _mobilePageData(String html) {
    final raw = EmbeddedJson.byIdContaining(html, 'pageContext');
    if (raw == null) return null;
    Object? d;
    try {
      d = jsonDecode(raw);
    } on Object {
      return null;
    }
    // ★ 逐级 is 判断：远端 JSON 结构一变（顶层不是对象/字段换类型）时不再抛
    //   TypeError 打挂整条降级路径，而是返回 null，由上层按"未解析到 records"处理。
    if (d is! Map) return null;
    final pc = d['pageContext'];
    if (pc is! Map) return null;
    final pp = pc['pageProps'];
    if (pp is! Map) return null;
    final pd = pp['pageData'];
    return pd is Map ? pd : null;
  }

  /// 自检钩子：离线解析一行 www 站 HTML（不打网络）。
  RankEntry? testParseRow(String row, int fallbackRank, QidianFontTable font) =>
      _webRowToEntry(row, fallbackRank, font)?.entry;

  /// 自检钩子：离线切行。
  List<String> testWebRows(String html) => _webRows(html);
}

/// www 站解析中间结果（带“是否见过混淆 / 解出没解出”标记，供质量统计）。
class _WebRow {
  const _WebRow(this.entry, {required this.sawObfuscated, required this.decoded});
  final RankEntry entry;
  final bool sawObfuscated;
  final bool decoded;
}

/// 去空白后写入 extra（空串不写）。
void _putExtra(Map<String, String> extra, String key, String? v) {
  final t = v?.trim();
  if (t != null && t.isNotEmpty) extra[key] = t;
}

// ───────────────────────────── 番茄 ─────────────────────────────

class FanqieSource implements RankSourceAdapter {
  /// 这个平台不靠 id 区分分类（番茄的榜单接口按 gender/category 传参，分类不用 id 区分）——
  /// 显式声明一次：Dart 的 `implements` 要求实现接口的**全部**成员。
  @override
  String? categoryIdOf(String? name) => null;

  FanqieSource(this.fetcher);
  final Fetcher fetcher;

  static const String id = 'fanqie';

  static const Map<String, (String gender, String mold)> boards = {
    '男频阅读榜': ('1', '2'),
    '男频新书榜': ('1', '1'),
    '女频阅读榜': ('0', '2'),
    '女频新书榜': ('0', '1'),
  };

  Object? _meta;

  /// 元数据最近一次成功抓取的时间（为空 = 还没成功过）。
  DateTime? _metaFetchedAt;
  String _rankVersion = '';

  /// `/rank` 页 `@font-face` 里的字体哈希；'' = 没取到。
  String _fontHash = '';

  /// 字体哈希与内置表一致才允许解码 —— 见 `fanqie_font.dart` 顶部的取舍说明。
  bool _decodable = false;

  Map<String, List<Map<String, Object?>>> _categoryLists = {};

  @override
  String get sourceId => id;
  @override
  String get displayName => '番茄小说（category/list 接口）';
  @override
  List<String> get supportedBoards => boards.keys.toList(growable: false);

  /// 分类表、rank_version、字体哈希都来自 /rank 页的 __INITIAL_STATE__ / @font-face，
  /// 抓一次缓存。
  ///
  /// ★ 字体反爬的解码表绑定字体哈希：同一份 /rank 页同时给出「数据用的字体」，
  ///   所以这里顺手把哈希取回来，哈希一致才开解码（见 fanqie_font.dart）。
  Future<void> _ensureMeta() async {
    // ★ 元数据带 TTL：字体若在进程存活期间轮换，永久缓存会让旧表继续解
    //   新字体 → 静默错字。30 分钟刷新一次，成本可接受（一个页面）。
    final fresh = _metaFetchedAt != null &&
        DateTime.now().difference(_metaFetchedAt!) < const Duration(minutes: 30);
    if (_meta != null && fresh) return;
    final html = await fetcher.getString(Uri.parse('https://fanqienovel.com/rank'));
    _fontHash = fanqieFontHashOf(html);
    _decodable = _fontHash.isNotEmpty && _fontHash == fanqieFontHash;
    final state = EmbeddedJson.initialState(html);
    // ★ is 判断代替 `as Map?`：__INITIAL_STATE__ 结构变一点就整源失败，代价太大。
    final stateMap = state is Map ? state['rank'] : null;
    final rank = stateMap is Map ? stateMap : const <dynamic, dynamic>{};
    // ★ 空 rank 是"这次没拿到"，不是"这就是答案"：不能缓存成永久值，
    //   否则整源会一直报"接口未返回 book_list"直到重启。
    if (rank.isEmpty) return;
    _meta = rank;
    _metaFetchedAt = DateTime.now();
    _rankVersion = '${rank['rankVersion'] ?? ''}';
    final cats = rank['rankCategoryTypeList'];
    if (cats is Map) {
      _categoryLists = {
        for (final e in cats.entries)
          e.key.toString():
              (e.value is List ? e.value as List : const <dynamic>[])
                  .whereType<Map>()
                  .map((m) => m.cast<String, Object?>())
                  .toList()
      };
    }
  }

  /// 分类名 → category_id（供 CLI 用中文名指定）
  Future<List<Map<String, Object?>>> categoriesOf(String gender) async {
    await _ensureMeta();
    return _categoryLists[gender == '1' ? 'male' : 'female'] ?? const [];
  }

  /// 指定分类在运行时分类表里不存在：明确失败，不静默取第一个分类。
  FetchOutcome _badCategory(RankQuery q, List<Map<String, Object?>> cs) {
    final opts = cs
        .map((c) => '${c['name']}')
        .where((s) => s.isNotEmpty)
        .join('、');
    return FetchOutcome(
      const [],
      RankQuality(
        ok: false,
        validCount: 0,
        totalCount: 0,
        summary: '分类「${q.categoryName}」不存在（可能页面改版/分类表过期）',
        problems: ['可选分类：${opts.isEmpty ? '（未取到分类表）' : opts}'],
      ),
    );
  }

  @override
  Future<FetchOutcome> fetch(RankQuery q) async {
    if (!boards.containsKey(q.board)) return _badBoard(boards.keys, q.board);
    await _ensureMeta();
    final gb = boards[q.board]!;
    final gender = gb.$1;
    final mold = gb.$2;
    var catId = q.categoryId ?? '';
    if (catId.isEmpty) {
      final cs = await categoriesOf(gender);
      final want = q.categoryName?.trim() ?? '';
      final hit = cs.isEmpty
          ? null
          : cs.firstWhere((c) => '${c['name']}' == want,
              orElse: () => <String, Object?>{});
      if (want.isEmpty) {
        catId = cs.isEmpty ? '' : '${cs.first['id'] ?? ''}';
      } else if (hit == null || hit.isEmpty) {
        return _badCategory(q, cs);
      } else {
        catId = '${hit['id'] ?? ''}';
      }
    }
    final names = <String, String>{
      for (final c in await categoriesOf(gender)) '${c['id']}': '${c['name']}'
    };

    final out = <RankEntry>[];
    var offset = 0;
    final want = q.limit.clamp(1, 100);
    String? firstUrl;
    while (out.length < want) {
      final page = (want - out.length).clamp(10, 50);
      final url = Uri.parse('https://fanqienovel.com/api/rank/category/list'
          '?app_id=2503&rank_list_type=3&offset=$offset&limit=$page'
          '&category_id=${Uri.encodeComponent(catId)}'
          '&rank_version=${Uri.encodeComponent(_rankVersion)}'
          '&gender=$gender&rankMold=$mold');
      firstUrl ??= '$url';
      final text = await fetcher.getString(url,
          referer: 'https://fanqienovel.com/rank',
          accept: 'application/json, text/plain, */*');
      Object? d;
      try {
        d = jsonDecode(text);
      } on Object {
        break;
      }
      // ★ is 判断代替强转：data 不是对象时按"没有 book_list"处理，不炸整源。
      final data = d is Map ? d['data'] : null;
      final bl = data is Map ? (data['book_list'] ?? data['list']) : null;
      if (bl is! List || bl.isEmpty) break;
      for (final b in bl.whereType<Map>()) {
        out.add(_toEntry(b, out.length + 1, catId, names[catId]));
      }
      // ★ 不能用"返回条数 < 请求 limit"判结束：服务端可能把 limit 截到更小，
      //   那样第二页就不翻了。空列表才是明确结束 —— 而这一点**上面
      //   `if (bl is! List || bl.isEmpty) break;` 已经判过了**，
      //   原来这里还有一句重复的 `if (bl.isEmpty) break;`，永不可达（审查报告 #2）。
      offset += bl.length;
    }

    final entries = out.take(want).toList();
    final obf = entries.where((e) => e.titleObfuscated).length;
    return FetchOutcome(
      entries,
      RankQuality(
        ok: entries.isNotEmpty,
        validCount: entries.length,
        totalCount: entries.length,
        summary: '题材=${names[catId] ?? catId} rank_version=$_rankVersion；'
            '${_textNote(entries.length, obf)}',
        problems: entries.isEmpty
            ? ['接口未返回 book_list（rank_version 可能已轮换，或该分类无此榜）']
            : const [],
      ),
      url: firstUrl,
    );
  }

  /// 一句话说清"这一轮到底解没解字体反爬" —— 不解就明说，
  /// 别让下游把私用区乱码当成真书名。
  String _textNote(int total, int obf) {
    final font = _fontHash.isEmpty ? '未在 /rank 页取到 @font-face 哈希' : '字体 $_fontHash';
    if (_decodable) {
      return '书名/作者/简介用内置字体表还原（$font 命中），仍混淆 $obf/$total 条；';
    }
    return '书名被字体混淆 $obf/$total 条（$font 与内置表不符 → 未解码，'
        '标〔名待补〕而不是猜）；';
  }

  /// 文本字段统一过一遍字体反爬还原。
  ///
  /// 只在字体哈希与内置表一致时才动 —— 表不对应时原样返回，
  /// 让 [RankEntry.titleObfuscated] 如实为 true，页面标〔名待补〕。
  String _text(Object? v) {
    final s = '${v ?? ''}';
    return _decodable ? decodeFanqiePua(s) : s;
  }

  RankEntry _toEntry(Map b, int fallback, String catId, String? catName) {
    final name = _text(b['bookName'] ?? b['book_name']);
    // ★ 原来第二行是 `?? parseCnNumber(readCount)`，但第一行已经
    //   `read_count ?? readCount` 兜过了 —— 只有"read_count 非空但解析不出、
    //   且 readCount 能解析"这种实际不存在的组合才会走到它（审查报告 #11）。
    //   保留两次尝试的**本意**（字段名可能两种），但别再重复解析同一个值。
    final reads = parseCnNumber('${b['read_count'] ?? ''}') ??
        parseCnNumber('${b['readCount'] ?? ''}');
    final words = parseCnNumber('${b['wordNumber'] ?? ''}');
    // ★ currentPos 只认 num：远端换成字符串时不整源崩，退回调用方给的顺序号。
    final posRaw = b['currentPos'];
    return RankEntry(
      rank: posRaw is num ? posRaw.toInt() : fallback,
      title: name.trim(),
      author: _text(b['author'] ?? b['authorName']).trim(),
      bookId: b['bookId'] == null ? null : '${b['bookId']}',
      category: catName,
      tags: (b['categoryV2'] is String && (b['categoryV2'] as String).isNotEmpty)
          ? [b['categoryV2'] as String]
          : const [],
      url: b['bookId'] == null ? null : 'https://fanqienovel.com/page/${b['bookId']}',
      coverUrl: coverUrlFromMap(b),
      metrics: {
        if (reads != null && reads > 0) 'reading': reads,
        if (words != null) 'words': words,
      },
      extra: {
        if (b['bookId'] != null) 'bookId': '${b['bookId']}',
        if (b['rankPosDiff'] != null) 'rankPosDiff': '${b['rankPosDiff']}',
        if (b['creationStatus'] != null) 'creationStatus': '${b['creationStatus']}',
        if (b['lastChapterTitle'] is String)
          'lastChapterTitle': _text(b['lastChapterTitle']),
        if (b['abstract'] is String && (b['abstract'] as String).trim().isNotEmpty)
          'intro': truncateIntro(_text(b['abstract'])),
      },
      titleObfuscated: privateUseCount(name) > 0,
    );
  }
}

// ───────────────────────────── 七猫 ─────────────────────────────

class QimaoSource implements RankSourceAdapter {
  /// 这个平台不靠 id 区分分类（七猫的分类走 category 参数，不用 id 区分）——
  /// 显式声明一次：Dart 的 `implements` 要求实现接口的**全部**成员。
  @override
  String? categoryIdOf(String? name) => null;

  QimaoSource(this.fetcher);
  final Fetcher fetcher;

  static const String id = 'qimao';

  static const Map<String, String> boards = {
    '男频大热榜': 'boy/hot/date',
    '男频大热月榜': 'boy/hot/month',
    '男频新书榜': 'boy/new/date',
    '男频完结榜': 'boy/over/date',
    '男频收藏榜': 'boy/collect/date',
    '男频更新榜': 'boy/update/date',
    '女频大热榜': 'girl/hot/date',
    '女频大热月榜': 'girl/hot/month',
    '女频新书榜': 'girl/new/date',
    '女频完结榜': 'girl/over/date',
    '女频收藏榜': 'girl/collect/date',
    '女频更新榜': 'girl/update/date',
  };

  @override
  String get sourceId => id;
  @override
  String get displayName => '七猫小说（Nuxt 内嵌载荷）';
  @override
  List<String> get supportedBoards => boards.keys.toList(growable: false);

  @override
  Future<FetchOutcome> fetch(RankQuery q) async {
    if (!boards.containsKey(q.board)) return _badBoard(boards.keys, q.board);
    final path = boards[q.board]!;
    final url = Uri.parse('https://www.qimao.com/paihang/$path/');
    final html = await fetcher.getString(url, referer: 'https://www.qimao.com/');
    final entries = parse(html, q);
    return FetchOutcome(
      entries,
      RankQuality(
        ok: entries.isNotEmpty,
        validCount: entries.length,
        totalCount: entries.length,
        summary: entries.isEmpty ? '未解析到 listData' : '榜单页自带 index_change（排名变化），可不依赖历史快照',
        problems: entries.isEmpty ? ['__NUXT__ 结构可能改版'] : const [],
      ),
      url: '$url',
    );
  }

  List<RankEntry> parse(String html, RankQuery query) {
    final data = EmbeddedJson.nuxtData(html);
    final list = findList(data, 'listData');
    if (list == null) return const [];
    final out = <RankEntry>[];
    for (final item in list.whereType<Map>()) {
      final title = item['title'];
      if (title is! String || title.trim().isEmpty) continue;
      final metrics = <String, num>{};
      final words = parseCnNumber('${item['words_num'] ?? ''}');
      if (words != null) metrics['words'] = words;
      final numRaw = item['number'];
      if (numRaw != null) {
        final n = num.tryParse('$numRaw');
        if (n != null) {
          final unit = '${item['unit'] ?? ''}'.trim();
          final factor = unit == '亿' ? 100000000 : (unit == '万' ? 10000 : 1);
          metrics['heat'] = (n * factor).round();
        }
      }
      final bid = item['book_id'];
      out.add(RankEntry(
        rank: out.length + 1,
        title: title.trim(),
        author: '${item['author'] ?? ''}'.trim(),
        bookId: bid == null ? null : '$bid',
        category: (item['category2_name'] is String)
            ? item['category2_name'] as String
            : ((item['category1_name'] is String) ? item['category1_name'] as String : null),
        url: item['book_url'] is String ? item['book_url'] as String : null,
        coverUrl: coverUrlFromMap(item),
        metrics: metrics,
        extra: {
          if (bid != null) 'bookId': '$bid',
          if (item['words_num'] != null) 'wordsRaw': '${item['words_num']}',
          if (item['number'] != null) 'heatRaw': '${item['number']}${item['unit'] ?? ''}',
          if (item['index_change'] is String && '${item['index_change']}'.trim().isNotEmpty)
            'indexChange': '${item['index_change']}',
          if (item['is_over'] != null) 'isOver': '${item['is_over']}',
          if (item['intro'] is String && (item['intro'] as String).trim().isNotEmpty)
            'intro': truncateIntro(item['intro'] as String),
        },
        titleObfuscated: privateUseCount(title) > 0,
      ));
    }
    return out;
  }
}

// ───────────────────────────── 晋江 ─────────────────────────────

class JinjiangSource implements RankSourceAdapter {
  /// 这个平台不靠 id 区分分类（晋江的榜单不带分类维度）——
  /// 显式声明一次：Dart 的 `implements` 要求实现接口的**全部**成员。
  @override
  String? categoryIdOf(String? name) => null;

  JinjiangSource(this.fetcher);
  final Fetcher fetcher;

  static const String id = 'jjwxc';

  /// orderstr 逐个对过页面 title（16 的 title 实际是【完结金榜】，与二手文档不符）
  static const Map<String, String> boards = {
    '新晋作者榜': '3',
    '季度排行榜': '4',
    '月度排行榜': '5',
    '半年排行榜': '6',
    '总分排行榜': '7',
    '字数排行榜': '8',
    '完结金榜': '16',
  };

  @override
  String get sourceId => id;
  @override
  String get displayName => '晋江文学城（topten 表格 + gb18030）';
  @override
  List<String> get supportedBoards => boards.keys.toList(growable: false);

  @override
  Future<FetchOutcome> fetch(RankQuery q) async {
    if (!boards.containsKey(q.board)) return _badBoard(boards.keys, q.board);
    final order = boards[q.board]!;
    final url = Uri.parse('https://www.jjwxc.net/topten.php?orderstr=$order');
    final bytes = await fetcher.getBytes(url, referer: 'https://www.jjwxc.net/');
    final html = const GbkDecoder().decode(bytes);
    final entries = parse(html, q);
    return FetchOutcome(
      entries,
      RankQuality(
        ok: entries.isNotEmpty,
        validCount: entries.length,
        totalCount: entries.length,
        summary: 'gb18030 解码 ${bytes.length} 字节 → ${entries.length} 行'
            '（注：新晋榜一次给 3000 条 / 约 7MB，其余榜每页 200 条）',
        problems: entries.isEmpty ? ['未匹配到 onebook.php?novelid= 数据行'] : const [],
      ),
      url: '$url',
    );
  }

  List<RankEntry> parse(String html, RankQuery query) {
    final out = <RankEntry>[];
    for (final row in _rowRe.allMatches(html)) {
      final r = row.group(1) ?? '';
      if (!r.contains('onebook.php?novelid=')) continue;
      final e = _parseRow(r, out.length);
      if (e != null) out.add(e);
    }
    return out;
  }

  static final _rankRe = RegExp(r'<td[^>]*>\s*(\d{1,4})\s*</td>');
  static final _authorRe = RegExp(r'oneauthor\.php\?authorid=(\d+)[^>]*>\s*([^<]+?)\s*</a>');
  static final _titleAttr = RegExp(
      r'title="([^"]{1,80})"[^>]*?href="onebook\.php\?novelid=(\d+)"',
      dotAll: true);
  static final _titleText = RegExp(
      r'href="onebook\.php\?novelid=(\d+)"[^>]*>\s*([^<]+?)\s*</a>',
      dotAll: true);
  static final _numRe = RegExp(r'(\d[\d,]{0,20})&nbsp;');
  static final _typeRe = RegExp(r'((?:原创|同人)-[^<>\r\n]{2,60})');
  static final _statusRe =
      RegExp(r'>\s*(?:<font[^>]*>)?\s*(完结|连载中|连载|暂停)\s*(?:</font>)?\s*</td>');
  static final _dateRe = RegExp(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})');

  /// 整行切分：每次 `parse()` 都要用，提到类级只编译一次。
  static final _rowRe = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true);

  RankEntry? _parseRow(String row, int fallback) {
    final attr = _titleAttr.firstMatch(row);
    final text = _titleText.firstMatch(row);
    final m = attr ?? text;
    if (m == null) return null;
    // title 属性优先：单元格文本里混着订阅提示（含 █ 与 <br>）
    final title = attr != null ? attr.group(1)! : (m.group(2) ?? '');
    final novelId = attr != null ? attr.group(2)! : (m.group(1) ?? '');
    if (title.trim().isEmpty || novelId.isEmpty) return null;

    final numbers = _numRe.allMatches(row).map((e) => e.group(1)!).toList();
    final metrics = <String, num>{};
    if (numbers.isNotEmpty) {
      final w = parseCnNumber(numbers[0]);
      if (w != null) metrics['words'] = w;
    }
    if (numbers.length > 1) {
      final s = parseCnNumber(numbers[1]);
      if (s != null) metrics['score'] = s;
    }
    var category = _typeRe.firstMatch(row)?.group(1);
    final tags = <String>[];
    var site = '';
    if (category != null) {
      final parts = category.split('-').map((s) => s.trim()).toList();
      if (parts.isNotEmpty) site = parts.first;
      if (parts.length > 1) category = parts[1];
      tags.addAll(parts.skip(2));
    }
    final authorM = _authorRe.firstMatch(row);
    final rankM = _rankRe.firstMatch(row);

    return RankEntry(
      rank: int.tryParse(rankM?.group(1) ?? '') ?? (fallback + 1),
      title: title.trim(),
      author: (authorM?.group(2) ?? '').trim(),
      bookId: novelId,
      category: (category == null || category.trim().isEmpty) ? null : category.trim(),
      tags: tags,
      url: 'https://www.jjwxc.net/onebook.php?novelid=$novelId',
      metrics: metrics,
      extra: {
        'bookId': novelId,
        if (authorM != null) 'authorId': authorM.group(1)!,
        if (site.isNotEmpty) 'site': site,
        if (_statusRe.firstMatch(row) != null)
          'status': _statusRe.firstMatch(row)!.group(1)!,
        if (_dateRe.firstMatch(row) != null)
          'publishedAt': _dateRe.firstMatch(row)!.group(1)!,
        if (numbers.isNotEmpty) 'wordsRaw': numbers[0],
      },
    );
  }
}

/// 从 JSON 对象里找封面 URL —— 按常见字段名依次试。
///
/// ★ 为什么用"别名探测"而不是写死一个字段名：各平台的字段名在不同版本/接口里
///   改过（`cover` / `thumb_url` / `image_url` …），而我们无法对每个平台都做
///   逐版本验证。**取不到就返回 null**（界面画占位卡），绝不猜一个 URL 出来。
///
/// ★ 只认 `http(s)://` 开头的字符串：有的接口把封面放在嵌套对象里、
///   或者给个相对路径，那两种都当"没有"处理 —— 猜错了会去请求一个
///   完全不相关的地址。
String? coverUrlFromMap(Map m) {
  for (final k in const [
    'cover', 'cover_url', 'coverUrl', 'coverURL',
    'thumb_url', 'thumbUrl', 'thumb', 'image_url', 'imageUrl', 'image',
    'book_cover', 'bookCover', 'book_cover_url', 'pic', 'img', 'img_url',
  ]) {
    final v = m[k];
    if (v is String && v.startsWith('http')) return v;
  }
  return null;
}

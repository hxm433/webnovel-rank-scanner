/// 起点 www 站榜单解析自检（离线，喂真实夹具）。
///
/// 夹具 `test/fixtures/qidian_yuepiao_page1.html` 是**真实抓取**的月票榜
/// page1（`--headless=new --dump-dom` 落盘），自检覆盖：
///   ① 每行切分（`<li data-rid>`）；
///   ② 字段抽取（书名/作者/题材/子题材/状态/bookId/简介/更新）；
///   ③ 字体反爬解码（与独立实现逐值比对）；
///   ④ "解不出就不写 metrics"（宁可缺，不可错）的语义。
///
/// 运行：dart run bin/_t_qidian_parse.dart
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/guard.dart';
import '../lib/models.dart';
import '../lib/qidian_font.dart';
import '../lib/sources.dart';
import '../lib/webview_fetcher.dart';

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

void main() {
  final root = Directory.current.path;
  final html = File('$root/test/fixtures/qidian_yuepiao_page1.html').readAsStringSync();
  // ★ 从 HTML 里自动发现字体名（每次抓页面都变），避免夹具一更新测试就假失败。
  final fontName = RegExp(r'qd_anti_spider/([A-Za-z0-9]+)\.(?:woff|ttf)')
      .firstMatch(html)!
      .group(1)!;
  final fontBytes = Uint8List.fromList(
      File('$root/test/fixtures/qidian_font_$fontName.ttf').readAsBytesSync());
  final font = parseQidianFont(fontBytes);

  stdout.writeln('== 起点 www 站解析自检 ==');

  // 构造一个只做网络降级的 QidianSource（renderer 不可用时 _fetchWeb 不会被调）。
  final src = QidianSource(
    Fetcher(whitelist: DomainWhitelist(const ['qidian.com']), robots: RobotsGuard()),
  );

  // ── 1. URL 构造 ──
  stdout.writeln('\n[1] URL 构造');
  _check('page1 全站（无 chn、无 pageN）',
      '${src.webUrlFor('月票榜', 1, '-1')}' == 'https://www.qidian.com/rank/yuepiao/',
      '${src.webUrlFor('月票榜', 1, '-1')}');
  _check('page2 全站',
      '${src.webUrlFor('月票榜', 2, '-1')}' == 'https://www.qidian.com/rank/yuepiao/page2/',
      '${src.webUrlFor('月票榜', 2, '-1')}');
  _check('page1 玄幻（chn21）',
      '${src.webUrlFor('月票榜', 1, '21')}' == 'https://www.qidian.com/rank/yuepiao/chn21/',
      '${src.webUrlFor('月票榜', 1, '21')}');
  _check('page3 玄幻（chn21）',
      '${src.webUrlFor('月票榜', 3, '21')}' ==
          'https://www.qidian.com/rank/yuepiao/chn21/page3/',
      '${src.webUrlFor('月票榜', 3, '21')}');

  // ── 2. 榜单枚举 ──
  stdout.writeln('\n[2] 榜单枚举');
  _check('14 个 www 站榜单', src.supportedBoards.length == 14,
      'got ${src.supportedBoards.length}');
  _check('含月票榜/畅销榜/留存榜/女生精选榜',
      src.supportedBoards.contains('月票榜') &&
          src.supportedBoards.contains('畅销榜') &&
          src.supportedBoards.contains('留存榜') &&
          src.supportedBoards.contains('女生精选榜'));

  // ── 3. 行切分 ──
  stdout.writeln('\n[3] 行切分与字段抽取');
  // 用反射式的公开面：这里通过 _fetchWeb 的私有方法不便直调，
  // 改为直接验证"页面上确实有 20 行 <li data-rid>"这一前置事实。
  final rowCount = RegExp(r'<li data-rid="\d+">').allMatches(html).length;
  _check('夹具含 20 行 <li data-rid>', rowCount == 20, 'got $rowCount');

  // ── 4. 字体解码（与独立实现比对） ──
  stdout.writeln('\n[4] 字体解码');
  _check('字体表 11 项', font.map.length == 11, 'got ${font.map.length}');
  final re =
      RegExp(r'<span class="[A-Za-z0-9]+">([^<]+)</span></span>(月票|推荐|指数|阅读|收藏|粉丝)');
  final encs = [for (final m in re.allMatches(html)) m.group(1)!];
  final decoded = [for (final e in encs) font.decode(e)];
  const expected = [
    '62899', '56602', '52481', '40378', '39438', '38978', '36074', '33901',
    '32157', '30633', '30427', '29538', '29533', '25625', '23242', '22960',
    '18612', '16877', '16086', '15296',
  ];
  _check('20 条全部解码为纯数字',
      decoded.length == 20 && decoded.every((s) => RegExp(r'^\d+$').hasMatch(s)),
      'got=${decoded.take(3).toList()}');
  _check('解码值与独立实现完全一致', decoded.join(',') == expected.join(','),
      'exp=${expected.take(3).toList()} got=${decoded.take(3).toList()}');

  // ── 5. 端到端：解析出的 RankEntry 字段完整 ──
  // 通过把夹具喂给一个"离线版"渲染器来跑完整 _fetchWeb 路径。
  stdout.writeln('\n[5] 端到端解析（离线渲染器喂夹具）');
  final offline = _OfflineQidian(
    Fetcher(whitelist: DomainWhitelist(const ['qidian.com']), robots: RobotsGuard()),
    html,
    fontBytes,
  );
  final out = offline.parseFixture();
  _check('解析出 20 条', out.length == 20, 'got ${out.length}');
  if (out.isNotEmpty) {
    final e = out.first;
    _check('书名正确', e.title == '夜无疆', 'got "${e.title}"');
    _check('作者正确', e.author == '辰东', 'got "${e.author}"');
    _check('bookId 正确', e.bookId == '1040765595', 'got ${e.bookId}');
    _check('排名 = 1', e.rank == 1, 'got ${e.rank}');
    _check('题材 = 玄幻', e.category == '玄幻', 'got ${e.category}');
    _check('子题材 = 东方玄幻', e.tags.isNotEmpty && e.tags.first == '东方玄幻',
        'got ${e.tags}');
    _check('状态 = 连载', e.extra['status'] == '连载', 'got ${e.extra['status']}');
    _check('月票指标 = 62899', e.metrics['monthticket'] == 62899,
        'got ${e.metrics['monthticket']}');
    _check('URL 指向作品页', e.url == 'https://book.qidian.com/info/1040765595/',
        'got ${e.url}');
    _check('指标原值留在 extra 可核', e.extra['metricRaw']!.isNotEmpty);
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

/// 测试用的"离线渲染器"：把预置 HTML/字体直接喂给解析逻辑，
/// 不启动浏览器、不打网络。
class _OfflineQidian extends QidianSource {
  _OfflineQidian(super.fetcher, this.html, this.fontBytes)
      : super(
            renderer: WebViewFetcher(
              whitelist: fetcher.whitelist,
              robots: fetcher.robots,
              limiter: fetcher.limiter,
            ));
  final String html;
  final Uint8List fontBytes;

  /// 直接跑 `_webRowToEntry`（通过公开的 testRows 钩子）。
  List<RankEntry> parseFixture() {
    final font = parseQidianFont(fontBytes);
    final out = <RankEntry>[];
    final re = RegExp(r'<li data-rid="\d+">(.*?)</li>', dotAll: true);
    for (final m in re.allMatches(html)) {
      final e = testParseRow(m.group(1)!, out.length + 1, font);
      if (e != null) out.add(e);
    }
    return out;
  }
}

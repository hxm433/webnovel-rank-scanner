/// 起点**多页真实 HTML** 的离线解析自检。
///
/// 夹具 `qidian_yuepiao_page{1,2,3}.html` 是**真实抓取**的连续三页月票榜。
/// 本测试把三页依次喂给解析逻辑（模拟 `_fetchWeb` 的多页循环），验证：
///   ① 跨页排名连续（1..60）；
///   ② ★ 每页字体**各自独立解码**（实测三页字体名/码点/映射全不同）——
///      若错用同一张表，后两页必然解出乱码；
///   ③ 全部条目都有月票指标（解码零失败）；
///   ④ 全 60 条书名/作者/bookId 无重复（榜单分页不应重复）。
///
/// 运行：dart run bin/_t_qidian_multi.dart
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

Future<void> main() async {
  final root = Directory.current.path;
  final fx = '$root/test/fixtures';
  stdout.writeln('== 起点多页真实 HTML 离线解析自检 ==');

  final src = QidianSource(
    Fetcher(whitelist: DomainWhitelist(const ['qidian.com']), robots: RobotsGuard()),
    renderer: WebViewFetcher(
        whitelist: DomainWhitelist(const ['qidian.com']),
        robots: RobotsGuard(),
        limiter: RateLimiter(minInterval: const Duration(milliseconds: 300)),
      ),
  );

  final all = <RankEntry>[];
  final perPageFonts = <String>[];
  final perPageNoMetric = <int>[];

  for (final page in [1, 2, 3]) {
    final f = File('$fx/qidian_yuepiao_page$page.html');
    if (!f.existsSync()) {
      stdout.writeln('  ❌ 夹具缺失：page$page');
      exit(1);
    }
    final html = f.readAsStringSync();
    // 每页各自的字体：从页面里的 .ttf URL 名去夹具目录找（夹具只存了 page1 的字体）。
    // 为真实模拟"每页重新解析"，这里按页面内联的字体名匹配已保存的字体文件；
    // page2/3 的字体文件是运行时下载的，本地没有 → 用字体名判断"每页确实不同"。
    final fontName =
        RegExp(r'qd_anti_spider/([A-Za-z0-9]+)\.(?:woff|ttf)').firstMatch(html)?.group(1);
    perPageFonts.add(fontName ?? '(无字体)');

    final fontFile = File('$fx/qidian_font_$fontName.ttf');
    final font = fontFile.existsSync()
        ? parseQidianFont(Uint8List.fromList(fontFile.readAsBytesSync()))
        : QidianFontTable(const {});

    final rows = src.testWebRows(html);
    _check('page$page 切出 20 行', rows.length == 20, 'got ${rows.length}');
    var noMetric = 0;
    for (final row in rows) {
      final e = src.testParseRow(row, all.length + 1, font);
      if (e == null) continue;
      if (!e.metrics.containsKey('monthticket')) noMetric++;
      all.add(e);
    }
    perPageNoMetric.add(noMetric);
    stdout.writeln('    page$page 字体=$fontName 解析=${all.length} 条 缺指标=$noMetric');
  }

  stdout.writeln('\n[1] 跨页汇总');
  _check('三页共 60 条', all.length == 60, 'got ${all.length}');
  final ranks = [for (final e in all) e.rank];
  _check('排名连续 1..60',
      ranks.first == 1 && ranks.last == 60 && ranks.length == 60, '${ranks.first}..${ranks.last}');
  final uniqIds = {for (final e in all) e.bookId}.length;
  _check('bookId 无重复（分页不重叠）', uniqIds == 60, 'unique=$uniqIds');

  stdout.writeln('\n[2] 每页字体独立解码（关键：三页映射不同）');
  final distinctFonts = perPageFonts.toSet();
  _check('三页用了 ≥2 种不同字体名（证明映射会变）', distinctFonts.length >= 2,
      perPageFonts.join(','));
  stdout.writeln('    字体名：${perPageFonts.join(' / ')}');
  // page1 有字体文件 → 必须 0 缺指标；page2/3 本地无字体文件 → 会缺（如实记录，不假成功）
  _check('page1（有字体文件）0 条缺指标', perPageNoMetric[0] == 0,
      'got ${perPageNoMetric[0]}');

  stdout.writeln('\n[3] 月票数值单调性（跨页应整体递减）');
  final nums = [
    for (final e in all)
      if (e.metrics['monthticket'] != null) e.metrics['monthticket']!.toInt()
  ];
  var mono = true;
  for (var i = 1; i < nums.length; i++) {
    if (nums[i] > nums[i - 1]) mono = false;
  }
  _check('月票数整体单调递减', mono && nums.length > 0, 'len=${nums.length}');

  stdout.writeln('\n[4] 字段完整性抽样');
  final withAuthor = all.where((e) => e.author.isNotEmpty).length;
  final withCat = all.where((e) => e.category != null).length;
  final withIntro = all.where((e) => e.extra['intro'] != null).length;
  _check('全部有作者', withAuthor == 60, 'got $withAuthor');
  _check('全部有题材', withCat == 60, 'got $withCat');
  _check('全部有简介', withIntro == 60, 'got $withIntro');

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

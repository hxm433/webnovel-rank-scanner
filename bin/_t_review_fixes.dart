/// 第四轮审查报告里**已核验属实**的那些条目的回归。
///
/// 这个文件按"报告条目号"组织，方便下次有人再提同一条时一眼看到
/// "这条改过了、而且有断言守着"。
///
/// 运行：dart run bin/_t_review_fixes.dart
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/analysis.dart';
import '../lib/guard.dart';
import '../lib/models.dart';
import '../lib/png.dart';
import '../lib/qidian_font.dart';
import '../lib/report_data.dart';
import '../lib/scan_service.dart';
import '../lib/snapshot_index.dart';
import '../lib/sources.dart';
import '../lib/ui/win32.dart';
import '../lib/store.dart';

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

RankEntry _e(String title, {String? id, Map<String, num>? m, int rank = 1}) =>
    RankEntry(
        rank: rank,
        title: title,
        author: '作者',
        bookId: id,
        metrics: m ?? const {});

void main() {
  // ══ #3 跨快照主键统一成一份 ══
  stdout.writeln('\n── #3 跨快照主键（bookKeyOf）──');
  _check('有 bookId → id:<id>', bookKeyOf(_e('x', id: '123')) == 'id:123');
  _check('无 bookId → title:<书名>', bookKeyOf(_e('书名')) == 'title:书名');
  _check('bookId 为空串也退到书名', bookKeyOf(_e('书名', id: '')) == 'title:书名');
  _check('两种形态前缀不同，不会互相撞',
      bookKeyOf(_e('123')) != bookKeyOf(_e('x', id: '123')));

  // ══ #8 _bigram 不从代理对中间切开 ══
  stdout.writeln('\n── #8 书名热词不产生"半截代理对"──');
  bool isLone(String g) {
    if (g.length < 2) return false;
    final a = g.codeUnitAt(0), b = g.codeUnitAt(1);
    bool hi(int c) => c >= 0xD800 && c <= 0xDBFF;
    bool lo(int c) => c >= 0xDC00 && c <= 0xDFFF;
    if (hi(a) && !lo(b)) return true;
    if (lo(a)) return true;
    return false;
  }

  // 造一批带 emoji（补充平面，占 2 个 code unit）的书名
  final emojiTitles = ['📖📖📖', '📚书📚书', '好书📕推荐', '📕📕📕📕'];
  final res = const RankAnalyzer().analyze(RankResult(
    query: const RankQuery(source: 'fanqie', board: 'b'),
    fetchedAt: DateTime(2026, 10, 2),
    entries: [
      for (var i = 0; i < emojiTitles.length; i++)
        RankEntry(rank: i + 1, title: emojiTitles[i], author: '作者'),
    ],
  ));
  final bad = res.titleKeywords.where((k) => isLone(k.key)).toList();
  _check('热词里没有"半截代理对"', bad.isEmpty,
      bad.map((e) => e.key.codeUnits.map((c) => c.toRadixString(16)).join(',')).join(' | '));

  // ══ #9/#10/#24 文件名清洗器统一成一份 ══
  stdout.writeln('\n── #9/#10/#24 safeFileSegment ──');
  _check('目录穿越被挡住', safeFileSegment('..') != '..');
  _check('`a/../b` 的分隔符被换掉',
      !safeFileSegment('a/../b').contains('/') &&
          !safeFileSegment(r'a\..\b').contains(r'\'));
  _check('Windows 保留名 con 被加前缀',
      safeFileSegment('con').startsWith('_'), safeFileSegment('con'));
  _check('保留名 aux.json 也算（带扩展名照样保留）',
      safeFileSegment('aux.json').startsWith('_'), safeFileSegment('aux.json'));
  _check('结尾的点被换掉（Windows 会静默吞掉）',
      !safeFileSegment('name.').endsWith('.'), safeFileSegment('name.'));
  _check('结尾的空格被换掉',
      !safeFileSegment('name ').endsWith(' '), safeFileSegment('name '));
  _check('超长截断到 120', safeFileSegment('x' * 300).length == 120);
  _check('正常名字原样保留', safeFileSegment('月票榜') == '月票榜');

  // 三处调用现在必须**同源**：store 与 snapshot_index_file 对同一输入给同一结果
  _check('store 与公共实现一致（同源）',
      RankStore(root: 'out').testSafe('con') == safeFileSegment('con'));

  // ══ #1 采集路径必须带上 categoryId ══
  stdout.writeln('\n── #1 采集路径的 categoryId ──');
  final qd = QidianSource(Fetcher(
    whitelist: DomainWhitelist(const ['qidian.com']),
    robots: RobotsGuard(),
  ));
  _check('起点能按分类名解析出 id',
      qd.categoryIdOf('玄幻') != null, '${qd.categoryIdOf('玄幻')}');
  _check('认不出的分类返回 null', qd.categoryIdOf('不存在的分类') == null);
  _check('空/null 返回 null',
      qd.categoryIdOf(null) == null && qd.categoryIdOf('') == null);
  _check('"全站"解析成 -1（store 会把它当归一空值）',
      qd.categoryIdOf('全站') == '-1', '${qd.categoryIdOf('全站')}');

  // pathFor 拿到 id 才会写 `_c<id>` 后缀 —— 这正是"两个分类落到同一个文件"的防护
  final st = RankStore(root: 'out');
  final pWith = st.pathFor(
      const RankQuery(source: 'qidian', board: '畅销榜', categoryName: '玄幻', categoryId: '21'),
      DateTime(2026, 10, 2));
  final pWithout = st.pathFor(
      const RankQuery(source: 'qidian', board: '畅销榜', categoryName: '玄幻'),
      DateTime(2026, 10, 2));
  _check('带 id → 文件名有 _c21 后缀', pWith.contains('_c21'), pWith);
  _check('不带 id → 没有后缀（这就是原来采集路径的情形）',
      !pWithout.contains('_c21'), pWithout);
  _check('★ 两个不同分类不会落到同一个文件',
      pWith !=
          st.pathFor(
              const RankQuery(
                  source: 'qidian', board: '畅销榜', categoryName: '都市', categoryId: '4'),
              DateTime(2026, 10, 2)));

  // ══ #4 劣质数据不许覆盖优质数据 ══
  stdout.writeln('\n── #4 _isDegraded 不只看条数 ──');
  RankResult mk(int n, int withMetrics) => RankResult(
        query: const RankQuery(source: 'qidian', board: 'b'),
        fetchedAt: DateTime(2026, 10, 2),
        entries: [
          for (var i = 0; i < n; i++)
            RankEntry(
              rank: i + 1,
              title: '书$i',
              author: '作者',
              metrics: i < withMetrics ? {'monthticket': 100} : const {},
            ),
        ],
      );
  _check('条数变少 → 判为劣化',
      ScanService.testIsDegraded(mk(20, 20), mk(10, 10)));
  _check('条数变多 → 不判劣化',
      !ScanService.testIsDegraded(mk(10, 10), mk(20, 20)));
  _check('★ 条数相同但指标全空 → 判为劣化（原来会放行）',
      ScanService.testIsDegraded(mk(20, 20), mk(20, 0)));
  _check('条数相同、指标也一样多 → 不判劣化',
      !ScanService.testIsDegraded(mk(20, 20), mk(20, 20)));
  _check('条数相同、指标更多 → 不判劣化',
      !ScanService.testIsDegraded(mk(20, 10), mk(20, 20)));

  // ══ #22 WOFF 解压 hook 必须有默认实现 ══
  stdout.writeln('\n── #22 WOFF inflate hook ──');
  _check('★ woffInflateHook 默认非 null（原来声明了从没被赋值）',
      woffInflateHook != null);
  // 真跑一次：拿 PNG 编码产出的 zlib 流（那是**我们自己那份手写 deflate** 压的），
  // 再用 hook 解回来。
  // ★ 不比对内容 —— PNG 的 IDAT 里是"每行前面带 filter 字节的扫描行"，
  //   不是原始像素；这里要证明的是"hook 能把 zlib 解出来"，不是"解出来的内容等于输入"。
  final z = zlibCompressForTest();
  final back = woffInflateHook!(z, 1 << 22);
  _check('★ 默认 hook 能真的把 zlib 流解回来（非空、长度合理）',
      back != null && back.isNotEmpty && back.length > 100,
      back == null ? '解出 null' : '${back.length} 字节');
  _check('喂垃圾数据返回 null（不抛）',
      woffInflateHook!(Uint8List.fromList([1, 2, 3, 4, 5]), 100) == null);

  // ══ #35 comparisons 的行必须带跨快照主键 ══
  stdout.writeln('\n── #35 comparisons 的行带 key ──');
  SnapshotMeta meta(int id, DateTime when, List<RankEntry> es) => SnapshotMeta(
        id: id,
        file: File('x.json'),
        result: RankResult(
          query: const RankQuery(source: 'fanqie', board: 'b'),
          fetchedAt: when,
          entries: es,
        ),
      );
  // 同一本书，两次快照的**书名不同**（模拟字体混淆：同一本书 PUA 码点不一样）
  final older = meta(1, DateTime(2026, 10, 1),
      [_e('\uE000\uE001混淆书名', id: '999', m: {'heat': 1})]);
  // ★ 名次必须真的变了 —— `comparisonsByPair` 只保留
  //   `isNew || dropped || rankChange != 0` 的行，名次不变会被过滤掉。
  final newer = meta(2, DateTime(2026, 10, 2),
      [_e('\uE002\uE003混淆书名', id: '999', m: {'heat': 2}, rank: 3)]);
  final cmp = comparisonsByPair(SnapshotIndex.fromItems([older, newer]));
  final rows = (cmp.values.isEmpty ? null : cmp.values.first) as Map?;
  final rowList = (rows?['rows'] as List?) ?? const [];
  _check('产生了对比行', rowList.isNotEmpty, '${cmp.length} 组');
  if (rowList.isNotEmpty) {
    final r = rowList.first as Map;
    _check('★ 行里带 key（网页面板靠它匹配，书名混淆时 title 匹配不上）',
        r['key'] != null, '$r');
    _check('key 用的是 bookId（同一本书两次混淆码点不同也能对上）',
        r['key'] == 'id:999', '${r['key']}');
    _check('行里仍有 title（给人看的）', r['title'] != null);
  }

  // ══ 「打开浏览器」的判据（第 31 轮，两个假阳性都是真踩过的）══
  //
  // ★ 判据是"**页面真的加载了**"，不是"浏览器窗口出现了"：
  //   ① `(标题为空)` —— 挑到了 Edge 的辅助窗口；
  //   ② `还原页面`   —— Edge 的"恢复上次页面"提示窗口（也是 msedge、也有标题）。
  //   两个都被当成过"已打开"。
  stdout.writeln('\n── 浏览器窗口标题判据 ──');
  _check('空标题算"没加载"', isBlankBrowserTitle(''));
  _check('纯空白算"没加载"', isBlankBrowserTitle('   '));
  _check('"新建标签页 - 个人 - Microsoft Edge" 算没加载',
      isBlankBrowserTitle('新建标签页 - 个人 - Microsoft Edge'));
  _check('"无标题 - 用户配置 1 - Microsoft Edge" 算没加载（页面还没加载完）',
      isBlankBrowserTitle('无标题 - 用户配置 1 - Microsoft Edge'));
  _check('"New Tab" 算没加载', isBlankBrowserTitle('New Tab'));
  _check('真页面标题**不算**没加载',
      !isBlankBrowserTitle('《偏偏宠爱》藤萝为枝_晋江文学城_【原创小说|言情小说】'));
  // 默认浏览器 exe 能从注册表解出来（本机装了 Edge，必然有）
  final exe = defaultBrowserExe();
  _check('defaultBrowserExe() 解得出一个存在的 exe',
      exe != null && File(exe).existsSync(), '$exe');
  _check('解出来的确实是浏览器 exe',
      exe != null && RegExp(r'(msedge|chrome|firefox|brave|vivaldi)',
              caseSensitive: false)
          .hasMatch(exe),
      '$exe');

  // ══ 界面文本不许出现 Markdown 的 `**`（本项目所有提示都是纯文本）══
  //
  // ★ 用户截图里真的出现过 `浏览器**起来了，但停在了新建标签页**` ——
  //   提示条 / 系统 MessageBox / 画布文字**一个都不解析 Markdown**，
  //   写 `**` 就等于在屏幕上画两个星号。
  stdout.writeln('\n── 界面文本不带 Markdown 星号 ──');
  final offenders = <String>[];
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    var i = 0;
    for (final ln in f.readAsLinesSync()) {
      i++;
      if (ln.trimLeft().startsWith('//')) continue; // 注释随便写
      if (ln.contains(r'\*\*') || ln.contains('RegExp')) continue; // 正则里真要匹配星号
      if (RegExp(r"'[^']*\*\*[^']*'").hasMatch(ln)) {
        offenders.add('${f.path}:$i');
      }
    }
  }
  _check('lib 下没有"会把 ** 画到界面上"的字符串', offenders.isEmpty,
      offenders.take(5).join(' | '));

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

/// 造一段**由本项目自己的 deflate 产出**的 zlib 流：画一张小图，取它的 IDAT。
Uint8List zlibCompressForTest() {
  const w = 64, h = 64;
  final bgra = Uint8List(w * h * 4);
  for (var i = 0; i < bgra.length; i++) {
    bgra[i] = (i * 7) & 0xFF;
  }
  final png = bgraToPng(bgra, w, h);
  var p = 8;
  while (p + 8 <= png.length) {
    final len = (png[p] << 24) | (png[p + 1] << 16) | (png[p + 2] << 8) | png[p + 3];
    final type = String.fromCharCodes(png.sublist(p + 4, p + 8));
    if (type == 'IDAT') {
      return Uint8List.fromList(png.sublist(p + 8, p + 8 + len));
    }
    p += 12 + len;
  }
  throw StateError('没找到 IDAT');
}

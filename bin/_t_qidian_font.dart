/// 起点字体反爬解码器自检。
///
/// 夹具 `test/fixtures/qidian_font_DGTIwkHU.ttf` 是**从起点 CDN 真实下载**的
/// 反爬字体（对应 2026-09-25 抓到的月票榜 page1）；期望值是**用另一套独立
/// 实现（Python 手写 TTF 解析）算出来的**，两边必须逐字节一致 —— 这是
/// "解码器真的对"的唯一证据，不是自己证明自己。
///
/// 运行：
///   dart run bin/_t_qidian_font.dart
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/qidian_font.dart';

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
  final htmlPath = '$root/test/fixtures/qidian_yuepiao_page1.html';

  stdout.writeln('== 起点字体反爬解码器自检 ==');

  // ── 0. 从 HTML 里**自动发现**它引用的字体，而不是写死一个文件名 ──
  //   ★ 这一步是防"夹具过期"的：页面和字体是同一时刻抓的，一旦重新抓页面，
  //     字体名就变了（每次请求都随机）。写死字体名会让测试拿旧字体解新页面，
  //     表现为"表解析对了、解码全错"，非常难查（本轮真踩过）。
  final html = File(htmlPath).readAsStringSync();
  final fontRef = RegExp(r'qd_anti_spider/([A-Za-z0-9]+)\.(?:woff|ttf)')
      .firstMatch(html);
  if (fontRef == null) {
    stdout.writeln('  ❌ 页面里找不到反爬字体引用');
    exit(1);
  }
  final fontName = fontRef.group(1)!;
  final fontPath = '$root/test/fixtures/qidian_font_$fontName.ttf';
  final f = File(fontPath);
  if (!f.existsSync()) {
    stdout.writeln('  ❌ 夹具缺失：$fontPath（页面里引用的字体是 $fontName）');
    exit(1);
  }
  stdout.writeln('  页面引用的字体：$fontName（自动发现）');

  // ── 1. 字体解析 ──
  final bytes = Uint8List.fromList(f.readAsBytesSync());
  final table = parseQidianFont(bytes);

  stdout.writeln('\n[1] 解析真实反爬字体（${bytes.length} 字节）');
  _check('解析出非空映射表', !table.isEmpty, 'map size=${table.map.length}');
  _check('映射表恰好 11 项（0-9 + 小数点）', table.map.length == 11,
      'got ${table.map.length}');

  // ★ 期望值由**独立 Python 实现**算出：tool/xcheck_qidian_font.py
  //   （纯 struct 手写 TTF 解析，与 Dart 是两条独立路径）。
  //   重跑该脚本可重新生成下表。
  final expected = _expectedMapFor(fontName);

  final actual = <int, String>{
    for (final e in table.map.entries) e.key: e.value,
  };
  final mapOk = expected.length == actual.length &&
      expected.entries.every((e) => actual[e.key] == e.value);
  _check('映射表与独立实现逐码点一致', mapOk,
      mapOk ? null : 'exp=$expected got=$actual');

  // ★ 关键回归点：cmap format 12 的连续段必须**展开**。
  //   这一段（U+18720/U+18721 相邻两个码点）用来钉死"只取组起点会漏码点"。
  final segKeys = expected.keys.where((k) => expected[k] == '5').toList();
  if (segKeys.isNotEmpty) {
    final k = segKeys.first;
    _check('fmt12 连续段展开正确（相邻码点都能解）',
        table.map[k] == '5' && table.map[k + 1] == '6',
        '$k=${table.map[k]} ${k + 1}=${table.map[k + 1]}');
  } else {
    _check('fmt12 连续段展开正确（相邻码点都能解）', false, '期望表里找不到 5');
  }

  // ── 2. 用真实页面验证解码结果 ──
  stdout.writeln('\n[2] 解码真实页面里的月票数');
  final re = RegExp(r'<span class="[A-Za-z0-9]+">([^<]+)</span></span>(月票|推荐|指数|阅读|收藏|粉丝)');
  final encs = [for (final m in re.allMatches(html)) m.group(1)!];
  _check('页面上找到 20 条混淆数字', encs.length == 20, 'got ${encs.length}');

  final decoded = [for (final e in encs) table.decode(e)];
  final allDigits = decoded.every((s) => RegExp(r'^\d+$').hasMatch(s));
  _check('全部解码为纯数字（无残留未知字符）', allDigits,
      decoded.where((s) => !RegExp(r'^\d+$').hasMatch(s)).take(3).join(','));

  // ★ 期望值：独立 Python 实现解出的 20 个月票数（tool/xcheck_qidian_font.py）。
  const expectedYp = [
    '62899', '56602', '52481', '40378', '39438', '38978', '36074', '33901',
    '32157', '30633', '30427', '29538', '29533', '25625', '23242', '22960',
    '18612', '16877', '16086', '15296',
  ];
  final ypOk = decoded.length == expectedYp.length &&
      List.generate(decoded.length, (i) => decoded[i] == expectedYp[i])
          .every((x) => x);
  _check('20 个月票数与独立实现完全一致', ypOk,
      ypOk ? null : 'exp=${expectedYp.take(3).toList()} got=${decoded.take(3).toList()}');

  // ★ 反向验证：数字必须严格递减（榜单本身是按热度排的）。
  //   如果解码错位（比如 0 和 6 换了），递减性会被破坏 —— 这是个不依赖
  //   期望值的自洽检查。
  final nums = [for (final s in decoded) int.parse(s)];
  var mono = true;
  for (var i = 1; i < nums.length; i++) {
    if (nums[i] > nums[i - 1]) mono = false;
  }
  _check('解码后数值严格递减（榜单单调性自洽）', mono,
      mono ? null : '序列非单调：$nums');

  // ── 3. 失败路径：坏数据必须返回空表而不是乱猜 ──
  stdout.writeln('\n[3] 失败路径');
  _check('空字节 → 空表', parseQidianFont(Uint8List(0)).isEmpty);
  _check('随机垃圾 → 空表',
      parseQidianFont(Uint8List.fromList(List.generate(64, (i) => i * 7))).isEmpty);
  final truncated = Uint8List.fromList(bytes.sublist(0, 40));
  _check('截断字体 → 空表或安全返回', parseQidianFont(truncated).map.length <= 11);

  // ── 4. canDecodeFully 的语义 ──
  stdout.writeln('\n[4] 完整性判定');
  _check('全部可解 → true', table.canDecodeFully(encs[0]));
  _check('含未知码点 → false', !table.canDecodeFully('${encs[0]}\u{18870}'));
  _check('空串 → false（不谎报可解）', !table.canDecodeFully(''));

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

/// 各字体名的**独立实现**期望映射（由 tool/xcheck_qidian_font.py 生成）。
///
/// 字体每次抓页面都换名字，所以这里按名字登记；找不到就返回空表，
/// 测试会直接报"映射表与独立实现不一致"并把实际值打出来 —— 这时应当
/// 重跑 Python 脚本、把新表粘进来，而不是改断言放水。
Map<int, String> _expectedMapFor(String fontName) {
  switch (fontName) {
    case 'wpLihXPQ': // 2026-09-25 13:52 抓的月票榜 page1
      return const {
        0x1871E: '4', 0x18720: '5', 0x18721: '6', 0x18722: '8',
        0x18723: '.', 0x18724: '2', 0x18725: '3', 0x18726: '0',
        0x18727: '9', 0x18728: '7', 0x18729: '1',
      };
    case 'DGTIwkHU': // 更早一版（保留，便于历史夹具回归）
      return const {
        0x1885F: '0', 0x18861: '.', 0x18862: '1', 0x18863: '9',
        0x18864: '3', 0x18865: '4', 0x18866: '7', 0x18867: '6',
        0x18868: '5', 0x18869: '2', 0x1886A: '8',
      };
    default:
      return const {};
  }
}

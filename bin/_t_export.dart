import 'dart:io';
import '../lib/exporters.dart';
import '../lib/models.dart';
import '../lib/snapshot_index.dart';

int pass = 0, fail = 0;
void ok(String name, bool cond, [String? detail]) {
  if (cond) {
    pass++;
    print('  PASS  $name');
  } else {
    fail++;
    print('  FAIL  $name${detail == null ? '' : '  -> $detail'}');
  }
}

SnapshotMeta mk(String source, List<RankEntry> entries) => SnapshotMeta(
      id: 1,
      file: File(r'C:/tmp/x.json'),
      result: RankResult(
        query: RankQuery(source: source, board: '畅销榜'),
        entries: entries,
        fetchedAt: DateTime(2026, 9, 25),
      ),
    );

void main() {
  print('== CSV 公式注入防护 ==');
  String cell(String v) {
    final csv = rowsToCsv(<String>['h'], <List<String>>[
      [v]
    ], withBom: false);
    final lines = csv.split('\n');
    return lines.length > 1 ? lines[1] : '';
  }

  ok('普通中文不被动', cell('玄幻小说') == '玄幻小说');
  ok('=cmd payload 被前缀单引号',
      cell("=cmd|' /C calc'!A0").startsWith('"\'='), cell("=cmd|' /C calc'!A0"));
  ok('+ 开头被处理', cell('+1+1').startsWith('"\'+'));
  ok('- 开头被处理', cell('-2+3').startsWith('"\'-'));
  ok('@ 开头被处理', cell('@SUM(A1)').startsWith('"\'@'));
  ok('引号翻倍仍生效', cell('a"b') == '"a""b"');
  ok('逗号仍加引号', cell('a,b') == '"a,b"');
  final inj = cell('=HYPERLINK("http://x","y")');
  ok('注入+引号同时', inj.startsWith('"\'=') && inj.contains('""'), inj);
  ok('空串保持空', cell('') == '');

  print('\n== 表头按平台补后缀 ==');
  final mf = mk('fanqie', [
    RankEntry(
      rank: 1,
      title: '测试书',
      author: '甲',
      url: 'https://x/1',
      metrics: {'heat': 100, 'words': 2000},
    ),
  ]);
  final csvF = snapshotToCsv(mf);
  ok('番茄 heat -> 热度（番茄）', csvF.contains('热度（番茄）'), csvF.split('\n').first);
  ok('番茄表头不含七猫', !csvF.contains('七猫'));
  ok('words 表头在', csvF.contains('字数'));

  final mq = mk('qimao', [
    RankEntry(rank: 1, title: '书', author: '乙', metrics: {'heat': 1}),
  ]);
  final csvQ = snapshotToCsv(mq);
  ok('七猫 heat -> 热度（七猫）', csvQ.contains('热度（七猫）'), csvQ.split('\n').first);

  print('\n== 混淆书名带可见标记 ==');
  final mo = mk('fanqie', [
    RankEntry(
      rank: 1,
      title: '\uE123\uE456',
      author: '乙',
      metrics: {'heat': 1},
    ),
  ]);
  final csv2 = snapshotToCsv(mo);
  ok('混淆书名保留原字符', csv2.contains('\uE123\uE456'));
  ok('混淆书名带"未解码"标记', csv2.contains('未解码'));
  ok('正常作者不带标记', !csv2.contains('乙⚠') && !csv2.contains('乙未解码'));

  print('\n== 注入字段经 _plain 后仍被防护 ==');
  final mi = mk('fanqie', [
    RankEntry(
      rank: 1,
      title: "=cmd|' /C calc'!A0\uE123",
      author: '丙',
      metrics: {'heat': 1},
    ),
  ]);
  final csvI = snapshotToCsv(mi);
  // 标记加在末尾，开头仍是 '='，防护应生效
  ok('混淆+注入 仍以带引号的单引号开头', csvI.contains('"\'=cmd'), csvI.split('\n')[1]);

  print('\n== 汇总：$pass 通过 / $fail 失败 ==');
  if (fail > 0) exitCode = 1;
}

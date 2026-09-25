/// 端到端落盘验证：把带 `=cmd` 注入 payload 的快照真的导出成 CSV 文件，
/// 再从磁盘读回检查 —— 证明防护在**文件层面**生效（攻击者拿到的就是落盘文件）。
library;

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

void main() {
  final dir = Directory('build/_export_attack');
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final m = SnapshotMeta(
    id: 1,
    file: File('build/_export_attack/src.json'),
    result: RankResult(
      query: const RankQuery(source: 'fanqie', board: '畅销榜'),
      fetchedAt: DateTime(2026, 9, 25),
      entries: [
        RankEntry(
          rank: 1,
          title: "=cmd|' /C calc'!A0",
          author: '@SUM(1+1)*cmd',
          metrics: {'heat': 999, 'words': 1000},
        ),
        RankEntry(
          rank: 2,
          title: '\uE111\uE222\uE333',
          author: '+danger',
          metrics: {'heat': 1},
        ),
        RankEntry(rank: 3, title: '正常书名', author: '正常作者', metrics: {'heat': 2}),
      ],
    ),
  );

  final csv = snapshotToCsv(m);
  final path = exportTo(dir.path, 'attack', 'csv', csv);
  print('  已写 $path');
  final back = File(path).readAsStringSync();

  print('\n== 落盘内容逐行检查 ==');
  for (final line in back.split('\n')) {
    if (line.trim().isEmpty) continue;
    print('  | $line');
  }

  print('');
  // 表头：番茄 heat → 热度（番茄）
  ok('表头含 热度（番茄）', back.contains('热度（番茄）'));
  ok('表头不含 七猫', !back.contains('七猫'));

  // 公式注入：裸 =cmd 不能再出现在任何字段开头
  ok('无裸 =cmd payload', !back.contains(',=cmd') && !back.contains('"=cmd'));
  ok('无裸 @SUM payload', !back.contains(',@SUM') && !back.contains('"@SUM'));
  ok('无裸 +danger payload', !back.contains(',+danger') && !back.contains('"+danger'));
  // 防护后应出现前导单引号
  ok('=cmd 已被前缀单引号', back.contains("'=cmd"));
  ok('@SUM 已被前缀单引号', back.contains("'@SUM"));
  ok('+danger 已被前缀单引号', back.contains("'+danger"));

  // 混淆书名
  ok('混淆书名带未解码标记', back.contains('未解码'));
  ok('混淆书名保留原码点', back.contains('\uE111\uE222\uE333'));
  ok('正常行不带标记',
      back.split('\n').where((l) => l.contains('正常书名')).every((l) => !l.contains('未解码')));

  File('build/_export_attack/RESULT.txt').writeAsStringSync(
      back.replaceAll('\uFEFF', '[BOM]'),
      flush: true);

  print('\n== 汇总：$pass 通过 / $fail 失败 ==');
  if (fail > 0) exitCode = 1;
}

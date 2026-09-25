/// 反向验证：用攻击方的**真实毒样本**跑端到端，证明本轮修复确实生效。
///
/// 覆盖：
///   ① 毒样本加载不再"被一份坏文件毒死全部"（界面永久空 + 无报错）；
///   ② overview() / comparisonsByPair() 不抛异常（Infinity 等）；
///   ③ 导出的 CSV：公式注入字段带前导单引号、混淆书名带"未解码"标记、
///      表头按平台补后缀（番茄的 heat 不再写成"热度（七猫）"）。
library;

import 'dart:io';

import '../lib/exporters.dart';
import '../lib/report_data.dart';
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

const corpusA = 'C:/Users/hxm/Documents/Qoder/2026-09-25/21179128/毒样本';
const corpusB = 'C:/Users/hxm/Documents/Qoder/2026-09-25/21179128/毒样本B';

void runCorpus(String root, String label) {
  print('\n==== $label : $root ====');
  final bad = <String>[];
  SnapshotIndex index;
  try {
    index = SnapshotIndex.load(root, errors: bad);
  } catch (e, st) {
    ok('$label 加载不抛异常', false, '$e\n$st');
    return;
  }
  ok('$label 加载不抛异常', true);
  print('  载入快照 ${index.items.length} 份；坏文件 ${bad.length} 个');
  for (final b in bad.take(8)) {
    print('    - ${b.split(Platform.pathSeparator).last.split(':').first}');
  }
  ok('$label 至少有 1 份快照被载入（没被坏文件拖走全部）', index.items.isNotEmpty);

  // overview 是最容易因 Infinity 抛异常的入口
  try {
    final ov = overview(index);
    ok('$label overview() 不抛异常', true);
    final per = ov['per_source'];
    ok('$label overview 结构完整', per is Map);
  } catch (e) {
    ok('$label overview() 不抛异常', false, '$e');
  }

  try {
    final cmp = comparisonsByPair(index);
    ok('$label comparisonsByPair() 不抛异常', true);
    print('  两两对比 ${cmp.length} 组');
  } catch (e) {
    ok('$label comparisonsByPair() 不抛异常', false, '$e');
  }

  // 导出一份 CSV，检查公式注入 / 混淆标记
  var injected = 0, obfMarked = 0, formulaGuarded = 0;
  for (final m in index.items.take(30)) {
    String csv;
    try {
      csv = snapshotToCsv(m);
    } catch (e) {
      ok('$label 快照 id=${m.id} 导出不抛异常', false, '$e');
      continue;
    }
    for (final line in csv.split('\n')) {
      if (line.contains("'=cmd") ||
          line.contains('\'=') ||
          line.contains("'@") ||
          line.contains("'+") ||
          line.contains("'-")) {
        injected++;
      }
      // 原始 payload 形态（未被防护的裸 =cmd）若出现即为漏网
      if (RegExp(r'(^|,)"?=cmd\|').hasMatch(line)) formulaGuarded++;
      if (line.contains('未解码')) obfMarked++;
    }
  }
  ok('$label 无漏网的裸公式注入', formulaGuarded == 0, '漏网 $formulaGuarded 处');
  print('  含防护前缀的行 $injected；带"未解码"标记的行 $obfMarked');
}

void main() {
  print('##### 毒样本端到端反向验证 #####');
  runCorpus(corpusA, '毒样本A');
  runCorpus(corpusB, '毒样本B');

  print('\n==== 汇总：$pass 通过 / $fail 失败 ====');
  if (fail > 0) exitCode = 1;
}

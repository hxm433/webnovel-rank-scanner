/// 扫榜设置窗自检（本机跑不了 dart analyze，只能靠真跑一遍）。
///
/// 覆盖本数能力（入口已收敛为**唯一**的顶栏批量步进器）：
///   ① 步进档位与上限夹取（起点 500 / 其它 50）；
///   ② 上限于各源分别生效；
///   ③ 本数入口只剩顶栏那一对（没有多余入口）；
///   ④ 点批量 + 改所有已选榜的本数，且**不改勾选状态**；
///   ⑤ `_targets()` 带上每榜真实本数；
///   ⑥ 底栏汇总的合计本数正确。
///
/// 运行：dart run bin/_t_scan_dialog.dart
library;

import 'dart:io';

import '../lib/scan_service.dart';
import '../lib/ui/dialogs.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';

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
  stdout.writeln('== 扫榜设置窗自检（每榜本数）==');
  final dlg = ScanDialogWindow(owner: MainWindow(outRoot: 'out'));
  dlg.testSetSize(760, 680);
  // 触发一次真实绘制（_build 在 onPaint 里被调；用离屏 BackBuffer 拿真实布局）。
  void paint() {
    final buf = BackBuffer(dlg.width, dlg.height);
    try {
      dlg.onPaint(buf.gdi);
    } finally {
      buf.dispose();
    }
  }
  paint();

  // ── 1. 步进档距**随值放大**（不是固定档位表）──
  //
  // ★ 这一节是第 10 轮改的：原来步进只在 [10,20,30,50,100,200,300,500] 里走，
  //   七猫上限 50 → 那张表裁完只剩 4 档，用户点 + 只能得到四个值。
  //   现在步距随值放大（1/5/10/50/100），任何整数都走得到；
  //   再加上值区**可以直接打字输入任意数字**（见第 8 节）。
  stdout.writeln('\n[1] 步进档距随值放大');
  const qk = 'qidian|月票榜|';
  dlg.limits.remove(qk);
  _check('起点默认 20 本', dlg.limitOf('qidian', qk) == 20,
      'got ${dlg.limitOf('qidian', qk)}');
  dlg.stepLimit('qidian', qk, 1);
  _check('20 加一步 → 25（步距 5）', dlg.limitOf('qidian', qk) == 25,
      'got ${dlg.limitOf('qidian', qk)}');
  dlg.stepLimit('qidian', qk, -1);
  _check('25 减一步 → 20', dlg.limitOf('qidian', qk) == 20,
      'got ${dlg.limitOf('qidian', qk)}');
  dlg.limits[qk] = 95;
  dlg.stepLimit('qidian', qk, 1);
  _check('95 加一步 → 105（步距 10）', dlg.limitOf('qidian', qk) == 105,
      'got ${dlg.limitOf('qidian', qk)}');
  dlg.limits[qk] = 480;
  dlg.stepLimit('qidian', qk, 1);
  _check('480 加一步夹到 500（起点上限）', dlg.limitOf('qidian', qk) == 500,
      'got ${dlg.limitOf('qidian', qk)}');
  dlg.limits[qk] = 5;
  dlg.stepLimit('qidian', qk, -1);
  _check('5 减一步 → 4（步距 1）', dlg.limitOf('qidian', qk) == 4,
      'got ${dlg.limitOf('qidian', qk)}');
  dlg.limits[qk] = 1;
  dlg.stepLimit('qidian', qk, -1);
  _check('1 再减仍是 1（下限）', dlg.limitOf('qidian', qk) == 1,
      'got ${dlg.limitOf('qidian', qk)}');
  _check('stepFor 的档距单调不降',
      ScanDialogWindow.stepFor(1) <= ScanDialogWindow.stepFor(50) &&
          ScanDialogWindow.stepFor(50) <= ScanDialogWindow.stepFor(500));

  // ── 2. 非起点源上限更低 ──
  stdout.writeln('\n[2] 各源上限');
  _check('起点上限 500', dlg.capOf('qidian') == 500, 'got ${dlg.capOf('qidian')}');
  _check('七猫上限 50', dlg.capOf('qimao') == 50, 'got ${dlg.capOf('qimao')}');
  const mk = 'qimao|男频大热榜|';
  dlg.limits.remove(mk);
  for (var i = 0; i < 10; i++) {
    dlg.stepLimit('qimao', mk, 1);
  }
  _check('七猫夹到 50（不出现 100/200）', dlg.limitOf('qimao', mk) == 50,
      'got ${dlg.limitOf('qimao', mk)}');

  // ── 3. 本数入口收敛：只剩顶栏那一对 ──
  stdout.writeln('\n[3] 本数入口唯一');
  dlg.checked.clear();
  dlg.limits.clear();
  paint();
  // ★ 收敛断言：无论勾没勾，命中区恒为 2（只有顶栏的减/加），
  //   且每一个都落在顶栏里（y 在 headerHeight 以上）。
  _check('步进器命中区恰为 2 个（顶栏减/加）', dlg.testStepperHitCount == 2,
      'got ${dlg.testStepperHitCount}');
  final bsp0 = dlg.testBatchStepperProbe();
  _check('顶栏批量步进器已登记', bsp0 != null, 'probe=$bsp0');
  if (bsp0 != null) {
    final (_, py, _) = bsp0;
    _check('步进器在顶栏内（不在内容区行上）',
        py < Metrics.headerHeight + 2,
        'py=$py headerHeight=${Metrics.headerHeight}');
  }
  final probe = dlg.testBatchStepperProbe();
  _check('未勾选时批量步进器不可用（enabled=false）',
      probe != null && probe.$3 == false, 'probe=$probe');

  // ── 4. 勾上后批量步进器可用，且点 + 不改勾选 ──
  stdout.writeln('\n[4] 勾上后可批量调，且不影响勾选');
  dlg.checked
    ..clear()
    ..addAll(['qidian|月票榜|全站', 'qimao|男频大热榜|']);
  dlg.limits.clear();
  paint();
  final sp = dlg.testBatchStepperProbe();
  _check('已勾选时批量步进器可用', sp != null && sp.$3 == true, 'probe=$sp');
  if (sp != null) {
    final (px, py, _) = sp;
    final beforeLimit = dlg.limitOf('qidian', 'qidian|月票榜|');
    dlg.onClick(px, py); // 点 "+"
    final afterLimit = dlg.limitOf('qidian', 'qidian|月票榜|');
    _check('点 + 本数增加', afterLimit > beforeLimit,
        '$beforeLimit -> $afterLimit');
    _check('点 + 后两榜仍勾选（没被取消）',
        dlg.checked.contains('qidian|月票榜|全站') &&
            dlg.checked.contains('qimao|男频大热榜|'),
        '${dlg.checked}');
    _check('批量 + 对另一个源也生效（七猫本数同步提高）',
        dlg.limitOf('qimao', 'qimao|男频大热榜|') > 20,
        'got ${dlg.limitOf('qimao', 'qimao|男频大热榜|')}');
  }

  // ── 5. _targets() 带真实本数 ──
  stdout.writeln('\n[5] _targets 带本数');
  dlg.checked
    ..clear()
    ..addAll(['qidian|月票榜|全站', 'qidian|月票榜|玄幻', 'qimao|男频大热榜|']);
  dlg.limits.clear();
  dlg.limits['qidian|月票榜|'] = 100;
  dlg.limits['qimao|男频大热榜|'] = 30;
  final ts = dlg.testTargets();
  _check('3 个目标', ts.length == 3, 'got ${ts.length}');
  final qd = ts.where((t) => t.source == 'qidian').toList();
  final qm = ts.where((t) => t.source == 'qimao').toList();
  _check('起点的两个题材共用 100 本（按榜设定）',
      qd.length == 2 && qd.every((t) => t.limit == 100),
      'got ${qd.map((t) => t.limit).toList()}');
  _check('七猫 30 本', qm.length == 1 && qm.first.limit == 30,
      'got ${qm.map((t) => t.limit).toList()}');
  _check('题材字段保留', qd.any((t) => t.category == '玄幻'));

  // ── 6. 统一设置 ──
  stdout.writeln('\n[6] 统一设置所有已选榜');
  dlg.limits.clear();
  dlg.setAllLimits(1);
  final all = dlg.testTargets();
  _check('统一 + 后全为 25（默认 20 加一步）',
      all.every((t) => t.limit == 25), 'got ${all.map((t) => t.limit).toList()}');

  // ── 7. 汇总文本 ──
  stdout.writeln('\n[7] 底栏汇总');
  final sum = dlg.testSummary();
  _check('汇总含"合计"', sum.contains('合计'), sum);
  _check('汇总含本数（3 榜 × 25 = 75）', sum.contains('75'), sum);
  _check('汇总含"约"耗时提示', sum.contains('约'), sum);

  // ── 8. 任意值：点值区直接输入 ──
  //
  // ★ 这一节是用户要求的核心："扫榜本数要可以任意修改，不是只有几个选择"。
  //   加减按钮再快也走不到 37 这种值 —— 必须能打字。
  stdout.writeln('\n[8] 本数可以直接输入任意值');
  dlg.checked
    ..clear()
    ..add('qidian|月票榜|全站');
  dlg.limits.clear();
  paint();
  final rs = dlg.testRowStepper('qidian', '月票榜');
  _check('月票榜行内有自己的步进器', rs != null);
  if (rs != null) {
    final (minus, value, plus) = rs;
    _check('行内步进器三段不重叠（减 / 值 / 加）',
        minus.right <= value.left && value.right <= plus.left,
        'm=$minus v=$value p=$plus');
    // 点 + → 20 → 25
    dlg.onClick(plus.left + plus.width ~/ 2, plus.top + plus.height ~/ 2);
    _check('点行内 + → 25', dlg.limitOf('qidian', 'qidian|月票榜|') == 25,
        'got ${dlg.limitOf('qidian', 'qidian|月票榜|')}');
    // 点值区 → 进入编辑
    dlg.onClick(value.left + value.width ~/ 2, value.top + value.height ~/ 2);
    _check('点值区进入编辑态', dlg.testEditId >= 0, 'editId=${dlg.testEditId}');
    _check('编辑缓冲初值是当前值', dlg.testEditBuf == '25', dlg.testEditBuf);
    // 敲 37：第一个数字**替换**原值（聚焦即全选），第二个才追加
    dlg.testType('3');
    _check('聚焦即全选：敲 3 后是 "3" 不是 "253"', dlg.testEditBuf == '3',
        dlg.testEditBuf);
    dlg.testType('7');
    _check('再敲一个数字 → "37"（是追加不是替换）', dlg.testEditBuf == '37',
        dlg.testEditBuf);
    // 回车提交
    dlg.onKey(0x0D);
    _check('回车提交 → 本数 37（**任意值**）',
        dlg.limitOf('qidian', 'qidian|月票榜|') == 37,
        'got ${dlg.limitOf('qidian', 'qidian|月票榜|')}');
    _check('提交后退出编辑态', dlg.testEditId < 0);

    // 非数字一律不收
    dlg.onClick(value.left + value.width ~/ 2, value.top + value.height ~/ 2);
    dlg.testType('4a');
    _check('输入框只收数字（字母被忽略）', dlg.testEditBuf == '4',
        dlg.testEditBuf);
    dlg.onKey(0x1B); // Esc 取消
    _check('Esc 取消不改值', dlg.limitOf('qidian', 'qidian|月票榜|') == 37,
        'got ${dlg.limitOf('qidian', 'qidian|月票榜|')}');

    // 超出上限要被夹住
    dlg.onClick(value.left + value.width ~/ 2, value.top + value.height ~/ 2);
    dlg.testType('9999');
    dlg.onKey(0x0D);
    _check('输入 9999 → 夹到起点上限 500',
        dlg.limitOf('qidian', 'qidian|月票榜|') == 500,
        'got ${dlg.limitOf('qidian', 'qidian|月票榜|')}');
  }

  // ── 9. 每个榜单独设置 ──
  stdout.writeln('\n[9] 每榜独立');
  dlg.limits.clear();
  dlg.checked
    ..clear()
    ..addAll(['qidian|月票榜|全站', 'qidian|畅销榜|全站']);
  paint();
  final a = dlg.testRowStepper('qidian', '月票榜');
  final b = dlg.testRowStepper('qidian', '畅销榜');
  _check('两个榜各有各的步进器', a != null && b != null);
  if (a != null && b != null) {
    _check('两行的步进器不在同一个位置（各自独立）',
        a.$2.left != b.$2.left || a.$2.top != b.$2.top);
    dlg.onClick(a.$3.left + a.$3.width ~/ 2, a.$3.top + a.$3.height ~/ 2);
    dlg.onClick(b.$3.left + b.$3.width ~/ 2, b.$3.top + b.$3.height ~/ 2);
    final la = dlg.limitOf('qidian', 'qidian|月票榜|');
    final lb = dlg.limitOf('qidian', 'qidian|畅销榜|');
    _check('分别 +1 步后两个值互不影响（25 / 25）', la == 25 && lb == 25,
        '$la / $lb');
    dlg.onClick(a.$3.left + a.$3.width ~/ 2, a.$3.top + a.$3.height ~/ 2);
    _check('再给月票榜 +1 → 30，畅销榜仍是 25',
        dlg.limitOf('qidian', 'qidian|月票榜|') == 30 &&
            dlg.limitOf('qidian', 'qidian|畅销榜|') == 25,
        '${dlg.limitOf('qidian', 'qidian|月票榜|')} / '
        '${dlg.limitOf('qidian', 'qidian|畅销榜|')}');
    // 两个榜的本数不同 → 顶栏批量框显示"多值"（不会硬编一个数字骗人）
    final vals = {
      for (final k in ScanDialogWindow.boardKeysOf(dlg.checked))
        dlg.limitOf(k.split('|').first, k)
    };
    _check('两个榜本数不同时"多值"成立', vals.length == 2, '$vals');
  }
  // ★ 行内步进器嵌在行矩形内部：点它**不能**把榜取消勾选
  _check('点行内步进器没有把榜取消勾选',
      dlg.checked.contains('qidian|月票榜|全站'), '${dlg.checked}');

  // ── 10. 折叠符号只在"真的有东西可折叠"时才出现 ──
  //
  // ★ 用户原话："这种没有折叠任何内容的，把折叠符号去掉"。
  //   番茄 / 七猫的榜下面没有题材维度，画一个箭头出来点它什么也不会发生。
  stdout.writeln('\n[10] 折叠符号的存在性');
  dlg.checked.clear();

  // 用搜索把两类榜分别顶到列表最前面，这样它们都在视口内（行矩形才会被登记）
  dlg.search = '番茄';
  paint();
  final fanqieRows =
      dlg.treeRows.where((r) => r.kind == 1 && r.source == 'fanqie').toList();
  _check('番茄有 4 个榜', fanqieRows.length == 4, '${fanqieRows.length}');
  _check('番茄的榜 cats 全为空',
      fanqieRows.every((r) => r.cats.isEmpty));
  _check('番茄的榜**一个折叠箭头都没有**',
      fanqieRows.every((r) => dlg.testChevronRect(r) == null));
  final fRect = dlg.testRowRect(fanqieRows.first.id);

  dlg.search = '月票';
  paint();
  final qdRow = dlg.treeRows
      .firstWhere((r) => r.kind == 1 && r.source == 'qidian' && r.board == '月票榜');
  _check('起点的榜有题材 → 有折叠箭头', dlg.testChevronRect(qdRow) != null);
  _check('起点的榜 cats 非空', qdRow.cats.isNotEmpty);
  final qRect = dlg.testRowRect(qdRow.id);

  final srcRow = dlg.treeRows.firstWhere((r) => r.kind == 0);
  _check('平台行有榜 → 有折叠箭头', dlg.testChevronRect(srcRow) != null);

  // 没有箭头的行**仍然占住箭头那段宽度**（否则同级榜会一个靠左一个靠右，
  // 看起来像两级缩进 —— 比多一个没用的箭头更糟）
  _check('两类榜的行框左缘一致（缩进不受箭头有无影响）',
      fRect != null && qRect != null && fRect.left == qRect.left,
      '${fRect?.left} vs ${qRect?.left}');
  dlg.search = '';
  paint();

  // ── 11. 顶栏批量步进器也能直接输入 ──
  stdout.writeln('\n[11] 批量步进器同样支持任意值');
  dlg.checked
    ..clear()
    ..addAll(['qidian|月票榜|全站', 'qimao|男频大热榜|']);
  dlg.limits.clear();
  paint();
  final bs = dlg.testBatchStepperRects();
  _check('顶栏批量步进器三段已登记', bs != null);
  if (bs != null) {
    dlg.onClick(bs.$2.left + bs.$2.width ~/ 2, bs.$2.top + bs.$2.height ~/ 2);
    _check('点批量值区进入编辑', dlg.testEditId >= 0);
    dlg.testType('17');
    dlg.onKey(0x0D);
    _check('批量输入 17 → 两个榜都变成 17',
        dlg.limitOf('qidian', 'qidian|月票榜|') == 17 &&
            dlg.limitOf('qimao', 'qimao|男频大热榜|') == 17,
        '${dlg.limitOf('qidian', 'qidian|月票榜|')} / '
        '${dlg.limitOf('qimao', 'qimao|男频大热榜|')}');
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

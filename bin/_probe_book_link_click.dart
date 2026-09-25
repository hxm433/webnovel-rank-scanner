/// 诊断：「打开」按钮点了没反应，到底断在哪一段。
///
/// 三段链路，逐段验：
///   ① 命中区有没有登记（绘制侧）
///   ② onClick 有没有走到 openBookLink（事件侧）
///   ③ ShellExecuteW 本身能不能用（系统调用侧）
///
/// 运行：dart run bin/_probe_book_link_click.dart [数据目录]
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/win32.dart';
import '_render_shots.dart' show renderBgra;

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'out';
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();

  // 选一份番茄的快照（用户截图里那个平台）
  final all = mw.vm?.all ?? const [];
  final fq = all.where((m) => m.source == 'fanqie').toList();
  if (fq.isEmpty) {
    stdout.writeln('没有番茄快照，随便挑一份');
    if (all.isEmpty) {
      stdout.writeln('数据目录为空');
      exitCode = 2;
      return;
    }
    mw.testSelect(all.first.id);
  } else {
    mw.testSelect(fq.first.id);
  }
  const w = 1240, h = 800;
  mw.testSetSize(w, h);
  renderBgra(mw.onPaint, w, h);

  final m = mw.currentMeta()!;
  stdout.writeln('快照：${m.source} / ${m.board} / ${m.count} 条');
  stdout.writeln('');

  // ── ① 命中区 ──
  //
  // ★ 第 19 轮之后命中区**一律裁到可见区域**：横向滚动时"看不见的列"
  //   不再登记命中区（否则视口外会有一片看不见却能点的区域）。
  //   所以这里分两次看：scrollX=0 看**整行**（它一定在可见区里），
  //   滚到最右再看「打开」按钮。
  stdout.writeln('── ① 绘制侧：命中区登记 ──');
  stdout.writeln('detailLinkCount = ${mw.detailLinkCount}');
  stdout.writeln('detailLinks 条数 = ${mw.detailLinks.length}');
  stdout.writeln('detailLinks[0] = ${mw.detailLinks[0]}');
  var rows = 0;
  for (var i = 0; i < m.result.entries.length; i++) {
    if (mw.testBookRowRect(i) != null) rows++;
  }
  stdout.writeln('scrollX=0 时登记了**整行**命中区 = $rows 行');
  final row0 = mw.testBookRowRect(0);
  final btn0 = mw.testBookButtonRect(0);
  stdout.writeln('第 0 行整行命中区 = $row0');
  stdout.writeln('第 0 行「打开」命中区 = $btn0');
  stdout.writeln('（自适应缩放之后基准窗下 8 列放得下，「打开」本来就在屏幕里）');
  stdout.writeln('');

  // ── ② 事件侧：点**整行最左边**（# 列上），应当也能打开 ──
  stdout.writeln('── ② 事件侧：点整行最左边 ──');
  if (row0 == null) {
    stdout.writeln('❌ 没有整行命中区 —— 问题在绘制侧');
  } else {
    final cx = row0.left + 6;
    final cy = row0.top + row0.height ~/ 2;
    final before = mw.statusText;
    final handled = mw.onClick(cx, cy);
    stdout.writeln('点 ($cx,$cy)  onClick 返回 $handled');
    stdout.writeln('statusText: "$before"  ->  "${mw.statusText}"');
    stdout.writeln(mw.statusText.startsWith('已打开详情页')
        ? '✅ 点行的任意位置都能打开（不用非要点中那个小按钮）'
        : '❌ 点行没反应');
  }
  stdout.writeln('');

  // 滚到最右，看「打开」按钮的命中区
  mw.testScrollDetailX(1 << 20);
  renderBgra(mw.onPaint, w, h);
  final btn = mw.testBookButtonRect(0);
  final area = mw.testDetailArea;
  stdout.writeln('滚到最右后「打开」命中区 = $btn');
  stdout.writeln(btn != null && area != null &&
          btn.right <= area.right && btn.left >= area.left
      ? '✅ 「打开」按钮在可视区内且登记了命中区'
      : '⚠️ 按钮命中区异常');
  stdout.writeln('');

  // ── ③ 系统调用侧：ShellExecuteW ──
  //
  // ★ 用一个**不存在的路径**探，不拿真 URL 试 —— 免得诊断脚本自己弹出浏览器。
  //   返回值 <=32 就是错误码（SE_ERR_FNF = 2 表示"文件找不到"）：
  //   能拿到 2 就说明这个 API 调得通、绑定没错。
  stdout.writeln('── ③ 系统侧：ShellExecuteW 绑定 ──');
  final op = 'open'.toNativeUtf16();
  final bogus = 'C:\\__no_such_file_rankscan_probe__.txt'.toNativeUtf16();
  final r1 = shellExecuteW(0, op, bogus, nullptr, nullptr, swShowNormal);
  stdout.writeln('对不存在的文件 → 返回 $r1'
      '（期望 2 = SE_ERR_FNF，说明绑定没问题）');
  calloc.free(bogus);

  // 再拿一个真实存在的文件试。`nShowCmd` 用 0（SW_HIDE）——
  // ShellExecuteW 照样会去查文件关联并返回 HINSTANCE，
  // 但不会弹出窗口来打扰用户；判据（返回值 >32）不受影响。
  final tmp = File('${Directory.systemTemp.path}\\rankscan_shell_probe.txt')
    ..writeAsStringSync('rankscan probe\n');
  final real = tmp.path.toNativeUtf16();
  final r2 = shellExecuteW(0, op, real, nullptr, nullptr, 0);
  stdout.writeln('对真实存在的文件 → 返回 $r2（>32 才算成功）');
  calloc.free(real);
  calloc.free(op);
  stdout.writeln(r2 > 32
      ? '✅ ShellExecuteW 可用'
      : '❌ ShellExecuteW 返回错误码 $r2');
  try {
    tmp.deleteSync();
  } on Object {}

  exitCode = (r2 > 32 && row0 != null) ? 0 : 1;
}

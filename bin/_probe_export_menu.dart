/// 导出菜单体检：把三组菜单项原样打出来（含"先问文件夹"开关的当前状态）。
///
/// 运行：dart run bin/_probe_export_menu.dart [数据目录]
library;

import 'dart:io';

import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '_render_shots.dart' show renderBgra;

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'out';
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();
  mw.testSetSize(1240, 800);
  mw.testOpenMenu('export');
  // ★ 命中区是**绘制时**登记的 —— 不画一帧就查，必然全是 null（我第一版就漏了这步）
  renderBgra(mw.onPaint, 1240, 800);

  var total = 0, missing = 0;
  for (final s in mw.testMenuSections('export')) {
    stdout.writeln('【${s.title}】');
    for (var i = 0; i < s.items.length; i++) {
      total++;
      stdout.writeln('   · ${s.items[i]}');
    }
  }
  // 每项都要有命中区（点得到）
  for (var si = 0; si < 3; si++) {
    final secs = mw.testMenuSections('export');
    if (si >= secs.length) break;
    for (var ii = 0; ii < secs[si].items.length; ii++) {
      final id = mw.testMenuIdAt('export', si, ii);
      if (mw.testHitRect(id) == null) {
        missing++;
        stdout.writeln('   ❌ 第 ${si + 1} 组第 ${ii + 1} 项没有命中区：${secs[si].items[ii]}');
      }
    }
  }
  stdout.writeln('共 $total 项，命中区缺失 $missing 项');
  exitCode = missing == 0 ? 0 : 1;
}

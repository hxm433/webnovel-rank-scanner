/// 把「历史对比」的三种看图口径各渲染一张，用来肉眼核对版面。
///
/// 运行：dart run bin/_probe_metric_chart.dart [数据目录] [输出目录]
library;

import 'dart:io';

import '../lib/png.dart';
import '../lib/ui/chart.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '_render_shots.dart' show renderBgra;

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'out';
  final outDir = args.length > 1 ? args[1] : 'build/shots';
  Directory(outDir).createSync(recursive: true);

  const w = 1240, h = 800;
  for (final (m, name) in const [
    (ChartMetric.rank, '排名'),
    (ChartMetric.value, '指标'),
    (ChartMetric.words, '字数'),
  ]) {
    Palette.apply(AppTheme.dark);
    final mw = MainWindow(outRoot: root);
    Palette.apply(AppTheme.dark);
    mw.reload();
    mw.testSetSize(w, h);
    mw.testSetTab(1); // 历史对比
    // 选一份期数最多的快照（期数越多折线越有看头）
    final all = mw.vm?.all ?? const [];
    if (all.isEmpty) {
      stdout.writeln('数据目录里没有快照');
      exitCode = 2;
      return;
    }
    final bySeries = <String, int>{};
    for (final x in all) {
      bySeries[x.seriesKey] = (bySeries[x.seriesKey] ?? 0) + 1;
    }
    final best = bySeries.entries.reduce((a, b) => a.value >= b.value ? a : b);
    for (final x in all) {
      if (x.seriesKey == best.key) {
        mw.testSelect(x.id);
        break;
      }
    }
    mw.seriesBy = m;
    mw.seriesTop = 6;
    final bgra = renderBgra(mw.onPaint, w, h);
    final png = bgraToPng(bgra, w, h);
    final path = '$outDir/20_历史对比_$name.png';
    File(path).writeAsBytesSync(png);
    stdout.writeln('$path  ${(png.length / 1024).toStringAsFixed(0)} KB  '
        '系列=${best.key} 期数=${best.value}');
  }
}

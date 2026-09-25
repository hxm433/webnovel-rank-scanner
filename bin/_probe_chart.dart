library;

import 'dart:io';

import '../lib/ui/chart.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/win32.dart';

void main() {
  Metrics.factor = 1.0;
  const testColor = 0x00FF00FF;
  final w = 420, h = 220;
  final buf = BackBuffer(w, h);
  buf.gdi.fill(Rc(0, 0, w, h), rgb(0, 0, 0));
  drawRankTrendChart(
    buf.gdi,
    Rc(0, 0, w, h),
    dates: const ['a', 'b', 'c'],
    series: [ChartSeries(label: 'x', ranks: const [1, 0, 1], color: testColor)],
    mouseX: -1,
    mouseY: -1,
  );
  final b = buf.readBgra();
  bool isC(int x, int y) {
    final i = (y * w + x) * 4;
    return (b[i] - 255).abs() <= 60 &&
        (b[i + 1] - 0).abs() <= 60 &&
        (b[i + 2] - 255).abs() <= 60;
  }

  // 统计每列的颜色像素数
  final cols = <int, int>{};
  for (var x = 0; x < w; x++) {
    var n = 0;
    for (var y = 0; y < h; y++) {
      if (isC(x, y)) n++;
    }
    if (n > 0) cols[x] = n;
  }
  print('有颜色的列: ${cols.keys.toList()}');
  // 打印首尾列的 y 位置
  for (final x in cols.keys) {
    final ys = <int>[];
    for (var y = 0; y < h; y++) {
      if (isC(x, y)) ys.add(y);
    }
    print('  x=$x  ys=${ys.first}..${ys.last} n=${ys.length}');
  }
  buf.dispose();
  exit(0);
}

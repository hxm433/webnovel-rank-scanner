/// 编译冒烟：确认新增模块的 import / 类型都成立。
library;

import '../lib/timeseries.dart';
import '../lib/ui/chart.dart';
import '../lib/ui/view_model.dart';

void main() {
  print('TimeRange.all = ${TimeRange.all.label}');
  print('SeriesSummary ok');
  print('ChartSeries ok: ${ChartSeries(label: 'x', ranks: const [1], color: 0).label}');
}

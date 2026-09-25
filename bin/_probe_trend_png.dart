/// 一次性探针：把「趋势图 + 趋势解读」导出成 PNG，供肉眼复核。
///
/// 为什么单独跑：界面里的解读栏受卡片高度限制（最多几行），
/// 导出的图没有这个限制 —— 必须亲眼看一次"图里到底写了什么"。
///
/// 运行：dart run bin/_probe_trend_png.dart [outRoot] [seriesSubstr]
library;

import 'dart:io';

import '../lib/models.dart';
import '../lib/snapshot_index_file.dart';
import '../lib/timeseries.dart';
import '../lib/trend_insight.dart';
import '../lib/ui/image_export.dart';
import '../lib/ui/view_model.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'build/fixture_out';
  final want = args.length > 1 ? args[1] : '月票榜';

  final vm = ViewModel.load(root);
  final metas = vm.all;
  if (metas.isEmpty) {
    stderr.writeln('$root 里没有快照');
    exit(1);
  }
  final seed = metas.firstWhere((m) => m.seriesKey.contains(want),
      orElse: () => metas.first);

  final same = metas.where((m) => m.seriesKey == seed.seriesKey).toList();
  final entries = metasToEntries(same);
  final results = <String, RankResult>{
    for (final m in same) metaToEntry(m).id: m.result
  };
  final ts = buildTimeSeries(entries, results);
  final insight = buildTrendInsight(ts).lines;
  final blockH = insight.isEmpty ? 0 : 26 + insight.length * 18 + 20 + 18;

  final img = renderTrendImage(ts,
      width: 980, height: 520 + blockH, rangeLabel: '全部', insight: insight);
  if (img == null) {
    stderr.writeln('画不出趋势图（期数不足）');
    exit(1);
  }
  final dir = Directory('build/shots')..createSync(recursive: true);
  final path = saveImage(dir.path, '趋势图_${seed.source}_${seed.board}', img);
  stdout.writeln('已导出：$path  ${img.width}x${img.height}  '
      '${(img.png.length / 1024).round()} KB  解读 ${insight.length} 行');
  for (final l in insight) {
    stdout.writeln('  ${l.isFact ? '[事实]' : '[原因·${l.tag}]'} ${l.text}');
  }
}

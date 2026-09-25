/// 量一下榜单图的列宽（用户报"导出的图里书名只剩一个字"）。
///
/// ★ 必须**按用户那个缩放档位**量：`Metrics.factor` 在 150% 缩放的屏上是 1.5，
///   而导出的图是**固定画布宽**（980）—— 两者不一致时列会溢出，
///   溢出由"硬约束"压缩，首当其冲的是**书名列**（它是 stretch 列）。
///
/// 运行：dart run bin/_probe_colwidth.dart [数据目录]
library;

import 'dart:io';

import '../lib/snapshot_index.dart';
import '../lib/ui/board_text.dart';
import '../lib/ui/image_export.dart';
import '../lib/ui/theme.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'out';
  Palette.apply(AppTheme.dark);
  final idx = SnapshotIndex.load(root);
  var meta = idx.items.first;
  for (final m in idx.items) {
    if (m.source == 'qimao') meta = m;
  }
  stdout.writeln('快照：${meta.source} / ${meta.board} / ${meta.count} 条');

  for (final f in <double>[1.0, 1.5]) {
    Metrics.factor = f;
    stdout.writeln('── Metrics.factor = $f ──');
    for (final w in <int?>[null, 980]) {   // null = 用新的默认（980 × factor）
      final cols = testBoardColWidths(meta, width: w);
      var x = 0;
      final parts = <String>[];
      for (var i = 0; i < boardCols.length - 1; i++) {
        final t = boardColTitle(boardCols[i]);
        parts.add('${t.isEmpty ? "封面" : t}=${cols[i]}');
        x += cols[i];
      }
      stdout.writeln('   画布宽 ${w ?? "默认(980×f)"} → 列宽合计 $x');
      stdout.writeln('      ${parts.join("  ")}');
    }
  }
}

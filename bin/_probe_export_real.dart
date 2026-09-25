/// 用**真实数据**导出一张榜单图，肉眼核对（导出图与界面是否一致）。
///
/// 运行：dart run bin/_probe_export_real.dart [数据目录] [平台]
library;

import 'dart:io';

import '../lib/ui/image_export.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : 'out';
  final want = args.length > 1 ? args[1] : 'qidian';
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();

  final all = mw.vm?.all ?? const [];
  final list = all.where((m) => m.source == want).toList();
  if (list.isEmpty) {
    stdout.writeln('没有 $want 的快照');
    exitCode = 2;
    return;
  }
  list.sort((a, b) => b.count.compareTo(a.count));
  mw.testSelect(list.first.id);

  // 与 `_exportBoardImage` 同一条路径：先 peek 入队 → 排空 → 再画
  mw.testRenderBoardImage();
  final n = await mw.drainCoversForTest();
  final img = mw.testRenderBoardImage();
  if (img == null) {
    stdout.writeln('画不出来');
    exitCode = 1;
    return;
  }
  final dir = Directory('build/shots')..createSync(recursive: true);
  final f = File('${dir.path}/30_导出榜单图_$want.png')
    ..writeAsBytesSync(img.png);
  stdout.writeln('已写 ${f.path}  ${img.width}x${img.height}  '
      '${(img.pngBytes / 1024).round()} KB  （排空封面队列 $n 次）');
}

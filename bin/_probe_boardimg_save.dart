/// 复现"导出榜单图到桌面 → errno = 5"：把**真实那份快照**画成图再落盘。
///
/// 运行：dart run bin/_probe_boardimg_save.dart [数据目录] [目标目录]
library;

import 'dart:io';

import '../lib/exporters.dart';
import '../lib/snapshot_index.dart';
import '../lib/ui/view_model.dart';
import '../lib/ui/image_export.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'out';
  final dir = args.length > 1 ? args[1] : 'C:\\Users\\hxm\\Desktop';
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();

  final all = mw.vm?.all ?? const <SnapshotMeta>[];
  if (all.isEmpty) {
    stdout.writeln('没有快照');
    exitCode = 2;
    return;
  }
  // 优先挑"起点 / 条数多"的那份（用户报错的就是 起点·新人作者新书榜·全站）
  var target = all.first;
  for (final m in all) {
    if (m.source == 'qidian' && m.board.contains('新人作者')) target = m;
  }
  stdout.writeln('快照：${target.source} / ${target.board} / ${target.category} '
      '/ ${target.count} 条');

  final img = renderBoardImage(target, width: 980);
  if (img == null) {
    stdout.writeln('画不出图');
    exitCode = 1;
    return;
  }
  stdout.writeln('图尺寸 ${img.width}x${img.height}，PNG ${img.pngBytes} 字节 '
      '（${(img.pngBytes / 1024 / 1024).toStringAsFixed(2)} MB）');

  final base = safeFileName('${sourceName(target.source)}_${target.board}'
      '${target.category == null ? '' : '_${target.category}'}'
      '_${target.dateKey}');

  // ① 先写到**数据目录**（应当一定成功）
  try {
    final p1 = saveImage(root, '榜单_$base', img);
    stdout.writeln('✅ 写到数据目录成功：$p1（${File(p1).lengthSync()} 字节）');
    File(p1).deleteSync();
  } on Object catch (e) {
    stdout.writeln('❌ 写到数据目录也失败：$e');
  }

  // ② 再写到你给的目录（桌面）
  stdout.writeln('\n目标目录 = $dir（存在=${Directory(dir).existsSync()}）');
  try {
    final p2 = saveImage(dir, '榜单_$base', img);
    stdout.writeln('✅ 写到目标目录成功：$p2（${File(p2).lengthSync()} 字节）');
  } on Object catch (e) {
    stdout.writeln('❌ 写到目标目录失败：$e');
    exitCode = 1;
  }
}

/// 导出链路体检：把"选目录"以外的每一步都真跑一遍，看哪一步断。
///
/// 运行：dart run bin/_probe_export_health.dart [数据目录]
library;

import 'dart:io';

import '../lib/exporters.dart';
import '../lib/models.dart';
import '../lib/report_data.dart';
import '../lib/snapshot_index.dart';
import '../lib/ui/image_export.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'out';
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();

  final all = mw.vm?.all ?? const [];
  stdout.writeln('快照 ${all.length} 份');
  if (all.isEmpty) {
    stdout.writeln('没有数据，退出');
    exitCode = 2;
    return;
  }
  mw.testSelect(all.first.id);
  final m = all.first;
  stdout.writeln('选中 ${m.source} / ${m.board} / ${m.count} 条');

  final dir = Directory.systemTemp.createTempSync('export_health_');
  stdout.writeln('目标目录 $dir');

  // ── ① CSV / JSON（走 testExportOneTo，与界面同一条写盘路径）──
  for (final ext in ['csv', 'json']) {
    final p = mw.testExportOneTo(dir.path, ext);
    if (p == null) {
      stdout.writeln('❌ $ext 导出返回 null：${mw.statusText}');
      continue;
    }
    final f = File(p);
    stdout.writeln('${f.existsSync() ? "✅" : "❌"} $ext → $p'
        '（${f.existsSync() ? "${f.lengthSync()} 字节" : "文件不存在！"}）');
  }

  // ── ② 全量汇总 ──
  try {
    final idx = SnapshotIndex.fromItems(all);
    final j = bundleToJson(all, overview(idx), comparisonsByPair(idx));
    stdout.writeln('✅ 汇总 JSON 生成成功（${j.length} 字符）');
  } on Object catch (e) {
    stdout.writeln('❌ 汇总 JSON 生成失败：$e');
  }

  // ── ③ 榜单长图（需要先备齐封面）──
  mw.testRenderBoardImage();
  stdout.writeln('榜单图（无封面）: ${mw.testRenderBoardImage(withCovers: false)?.width} 宽');

  // ── ④ 直接调 exportTo 看写盘本身有没有问题 ──
  try {
    final p = exportTo(dir.path, '直写测试', 'txt', 'hello');
    final f = File(p);
    stdout.writeln('${f.existsSync() ? "✅" : "❌"} exportTo 直写 → $p');
  } on Object catch (e) {
    stdout.writeln('❌ exportTo 直写失败：$e');
  }

  stdout.writeln('\n目录内容：');
  for (final f in dir.listSync()) {
    stdout.writeln('  ${f.path.split(Platform.pathSeparator).last}');
  }
  dir.deleteSync(recursive: true);
}

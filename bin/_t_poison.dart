/// 毒样本加载回归：把一批"故意写坏"的快照喂给加载路径，看会不会炸。
///
/// ★ 数据目录改成**参数传入**（默认 `out` 下的毒样本目录）。
///   原来这里写死了仓库外的绝对路径 —— 换台机器就红，
///   而 README 说"每个自检脚本都是独立可跑的"，那是假的。
///
/// 运行：dart run bin/_t_poison.dart [毒样本目录]
library;

import 'dart:io';

import '../lib/report_data.dart';
import '../lib/snapshot_index.dart';
import '../lib/ui/view_model.dart';

void main(List<String> args) {
  final dir = args.isNotEmpty
      ? args.first
      : 'build${Platform.pathSeparator}毒样本';
  if (!Directory(dir).existsSync()) {
    stdout.writeln('找不到毒样本目录：$dir');
    stdout.writeln('把一批写坏的快照放进去，或用参数指定：');
    stdout.writeln('  dart run bin/_t_poison.dart <目录>');
    exitCode = 2; // 2 = 跳过（不是失败，也别假装通过）
    return;
  }
  final errs = <String>[];
  try {
    final vm = ViewModel.load(dir, errors: errs);
    print('VM 载入 OK: 快照 ${vm.snapshotCount} 份 / 记录 ${vm.recordCount} 条');
    print('分组 ${vm.groups.length} 个');
    final ov = vm.crossBoardBooks();
    print('跨榜书 ${ov.length} 条');
    print('解析失败文件 ${errs.length} 个: ${errs.take(5).toList()}');
  } catch (e, st) {
    print('★ 仍然炸: $e');
    print(st.toString().split('\n').take(4).join('\n'));
  }
}

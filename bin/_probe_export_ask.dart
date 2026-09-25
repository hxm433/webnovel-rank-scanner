/// 验「每次导出前先问文件夹」这个开关**真的会弹框**。
///
/// ★ 思路：目录框是**模态**的，会阻塞调用线程 —— 所以"它到底弹没弹"
///   可以直接用"**卡住多久**"来判定：
///     · 开关关 → 导出立刻返回（几百毫秒）；
///     · 开关开 → 导出**卡在模态框上**，几秒都不返回。
///   为了不把自己卡死，导出的那次调用放到**另一个 isolate** 里跑：
///   主 isolate 只负责等消息，超时就说明"卡住了" = 框弹出来了。
///
/// ★ 上一版想用 `WM_CLOSE` 把框关掉再断言返回值，结果自己把自己卡住
///   （关闭器还没起、框先弹了；而且那个框的窗口类也不是我以为的 `#32770`）。
///   换成"用卡住本身当证据"就稳了。
///
/// 运行：dart run bin/_probe_export_ask.dart [数据目录]
library;

import 'dart:io';
import 'dart:isolate';

import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';

int _pass = 0, _fail = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✅ $name');
  } else {
    _fail++;
    stdout.writeln('  ❌ $name${detail == null ? '' : ' — $detail'}');
  }
}

/// 在独立 isolate 里做一次"走菜单路径"的导出；做完把结果发回去。
///
/// 开了"先问文件夹"时它会**永远卡在模态框上**（本进程退出才结束），
/// 这正是我们要观测的现象。
void _exportOnce(List<Object?> args) {
  final port = args[0] as SendPort;
  final root = args[1] as String;
  final dir = args[2] as String;
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();
  final all = mw.vm?.all ?? const [];
  if (all.isEmpty) {
    port.send('NO_DATA');
    return;
  }
  mw.testSelect(all.first.id);
  mw.testSetExportDir(dir);
  final p = mw.testExportViaMenuPath('csv');
  port.send(p == null ? 'NULL' : 'OK:$p');
}

Future<String> _runExport(String root, String dir, Duration wait) async {
  final rp = ReceivePort();
  await Isolate.spawn(_exportOnce, [rp.sendPort, root, dir]);
  try {
    final v = await rp.first.timeout(wait);
    return '$v';
  } on Object {
    return 'BLOCKED';
  } finally {
    rp.close();
  }
}

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : 'out';
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();
  final all = mw.vm?.all ?? const [];
  if (all.isEmpty) {
    stdout.writeln('没有快照');
    exitCode = 2;
    return;
  }
  final dir = Directory.systemTemp.createTempSync('ask_export_');

  stdout.writeln('── 开关关闭：应当**不弹框**，很快出文件 ──');
  mw.testSetAskExportDir(false);
  final sw1 = Stopwatch()..start();
  final r1 = await _runExport(root, dir.path, const Duration(seconds: 6));
  sw1.stop();
  _check('关：导出正常完成（没卡住）', r1.startsWith('OK:'), r1);
  _check('关：耗时很短', sw1.elapsedMilliseconds < 5000,
      '${sw1.elapsedMilliseconds}ms');

  stdout.writeln('\n── 开关打开：应当**卡在文件夹框上** ──');
  mw.testSetAskExportDir(true);
  _check('开关值已生效（写进 settings）', mw.settings.askExportDir);
  final sw2 = Stopwatch()..start();
  final r2 = await _runExport(root, dir.path, const Duration(seconds: 6));
  sw2.stop();
  stdout.writeln('     结果 = $r2（等了 ${sw2.elapsedMilliseconds}ms）');
  _check('★ 开：导出**卡住了** —— 说明文件夹框真的弹出来了', r2 == 'BLOCKED', r2);

  // 关掉开关，恢复默认（别把用户设置留在"每次都问"上）
  mw.testSetAskExportDir(false);
  _check('已把开关恢复成"关"', !mw.settings.askExportDir);

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  dir.deleteSync(recursive: true);
  exit(_fail == 0 ? 0 : 1);
}

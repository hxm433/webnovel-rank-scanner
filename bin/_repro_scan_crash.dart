/// 复现「点开始扫榜就退出」。
///
/// 走完整链路：主窗口 → 点「扫榜设置」→ 设置窗 → 点「开始扫榜」→ startScan。
/// 全程不联网（用一个假的 ScanService 子类拦截）。
library;

import 'dart:async';
import 'dart:io';

import '../lib/models.dart';
import '../lib/scan_service.dart';
import '../lib/ui/dialogs.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';

/// 假的采集服务：不联网，只记录被调用的目标。
class FakeService extends ScanService {
  FakeService({required super.outRoot});
  final List<String> calls = [];
  @override
  List<BoardInfo> enumerateBoards() => super.enumerateBoards();
  @override
  Future<ScanOutcome> scanOne({
    required String source,
    required String board,
    String? category,
    int limit = 20,
  }) async {
    calls.add('$source|$board|${category ?? ''}');
    return ScanOutcome(
      result: RankResult(
        query: RankQuery(source: source, board: board, limit: limit),
        entries: const [],
        fetchedAt: DateTime.now(),
      ),
      elapsed: Duration.zero,
      error: 'fake（自检不联网）',
    );
  }
}

void main() async {
  final outRoot = 'out';
  print('=== 复现「点开始扫榜就退出」 ===\n');

  final mw = MainWindow(outRoot: outRoot);
  mw.service = FakeService(outRoot: outRoot);
  mw.reload();
  mw.testSetSize(1240, 800);

  // 1. 主窗口绘制（建立 hitRects）
  final mbuf = BackBuffer(1240, 800);
  mw.onPaint(mbuf.gdi);
  mbuf.dispose();
  print('[1] 主窗口已绘制');

  // 2. 打开设置窗（点主窗口的「扫榜设置」按钮）
  print('[2] 打开扫榜设置窗…');
  final dlg = ScanDialogWindow(owner: mw);
  dlg.testSetSize(720, 620);
  final dbuf = BackBuffer(720, 620);
  dlg.onPaint(dbuf.gdi);
  dbuf.dispose();
  print('    设置窗已绘制，默认勾选 ${dlg.checked.length} 项，'
      '命中矩形 ${dlg.hitRects.length} 个');

  // 3. 点「开始扫榜」—— 就是这一步会挂
  print('[3] 点「开始扫榜」…');
  final r = dlg.hitRects[ScanDialogWindow.idRun];
  print('    idRun 矩形: ${r ?? "【null —— 按钮没记录到矩形！】"}');
  if (r == null) {
    print('\n>>> 根因：idRun 命中矩形是 null，按钮永远点不到。');
    print('    但用户说"点扫榜自动退出"，说明是点到别处触发的退出路径。');
  }

  // 不管有没有矩形，直接调 onClick 模拟点击
  if (r != null) {
    print('    点击中心 (${r.left + r.width ~/ 2}, ${r.top + r.height ~/ 2})');
    dlg.onClick(r.left + r.width ~/ 2, r.top + r.height ~/ 2);
  } else {
    // 直接找按钮文字所在的大致位置
    print('    尝试点右上角 (660, 23)');
    dlg.onClick(660, 23);
  }

  print('    设置窗 checked=${dlg.checked.length}，phase=${mw.phase}');

  // 4. 等异步扫榜跑完
  print('[4] 等 startScan 完成…');
  var waited = 0;
  while (mw.phase == ScanPhase.running && waited < 60) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    waited++;
  }
  print('    phase=${mw.phase}  scanDone=${mw.scanDone}/${mw.scanTotal}');

  // 5. 再画一次主窗口（扫榜后重绘，最容易在这里崩）
  print('[5] 扫榜后重绘主窗口…');
  final mbuf2 = BackBuffer(1240, 800);
  mw.onPaint(mbuf2.gdi);
  mbuf2.dispose();
  print('    重绘 OK');

  print('\n=== 结论：如果上面没抛异常，说明"退出"不在 Dart 逻辑层 ===');
  exit(0);
}

/// GUI 全链路自检 —— 不开真窗口，但把「窗口类」真的实例化一遍，
/// 并把绘制跑到真实的 GDI 内存 DC 上。
///
/// 为什么不用 `dart analyze` / `dart compile kernel`：
///   本机沙箱的管道句柄耗尽，这两个命令一律报 CreateFile failed 231。
///   所以改成"跑一遍"来当编译验证 —— 顺便连布局里的除零、越界也一起兜住。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../lib/scan_service.dart';
import '../lib/ui/dialogs.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/view_model.dart' show TimeRange;
import '../lib/ui/win32.dart';

int _pass = 0, _fail = 0;

void _check(String what, bool ok, [String extra = '']) {
  if (ok) {
    _pass++;
    print('  [OK]   $what${extra.isEmpty ? '' : ' — $extra'}');
  } else {
    _fail++;
    print('  [FAIL] $what${extra.isEmpty ? '' : ' — $extra'}');
  }
}

void main() {
  print('=== GUI 全链路自检 ===\n');
  final outRoot = Platform.environment['RANKSCAN_OUT'] ?? 'out';
  print('数据目录: $outRoot\n');

  // ── 1. 主窗口：构造 + 离屏绘制（多种尺寸，覆盖布局边界）──
  print('[1] MainWindow 构造与离屏绘制');
  final mw = MainWindow(outRoot: outRoot);
  mw.reload();

  final results = <String>[];
  for (final size in const [
    [1240, 800],
    [900, 600],
    [640, 480], // 小窗口：侧栏/表头都可能挤没，最容易除零
  ]) {
    final (w, h) = (size[0], size[1]);
    final buf = BackBuffer(w, h);
    try {
      mw.testSetSize(w, h);
      mw.onPaint(buf.gdi);
      // 三个标签页都画一遍（明细/对比/跨榜各有自己的布局代码）
      for (final tab in [0, 1, 2]) {
        mw.testSetTab(tab);
        mw.onPaint(buf.gdi);
      }
      _pass++;
      print('  [OK]   ${w}x$h 三个标签页均绘制成功');
    } on Object catch (e, st) {
      _fail++;
      print('  [FAIL] ${w}x$h 绘制抛异常: $e');
      print('         ${st.toString().split('\n').first}');
    } finally {
      buf.dispose();
    }
  }

  // ── 2. 数据是否真的载入 ──
  print('\n[2] 数据载入');
  final vm = mw.vm;
  _check('ViewModel 非空', vm != null);
  if (vm != null) {
    print('       快照 ${vm.snapshotCount} 份 / 记录 ${vm.recordCount} 条 '
        '/ 平台 ${vm.bySource.keys.length} 个');
    _check('至少载入 1 份快照', vm.snapshotCount > 0,
        '${vm.snapshotCount} 份');
    _check('解析零错误', mw.loadErrors.isEmpty,
        mw.loadErrors.isEmpty ? '' : mw.loadErrors.take(2).join(' | '));

    // 选中态
    _check('默认选中了快照', mw.selectedId != 0);
  }

  // ── 2b. 「历史对比」页装配的是**这张榜自己的时间线** ──
  //
  // ★ 旧版这里断言的是 `mw.baseId != 0`（"自动挑出了一份对比基准"）。
  //   第 8 轮把对比语义从"用户手挑另一份快照"改成"与自己过去各期对比"后，
  //   基准不再是一份文件，而是**同系列的全部历史快照**，`baseId` 这个字段
  //   已经不存在了。断言跟着改成检查时间线本身，否则这条自检会假红。
  print('\n[2b] 历史对比页 = 自身时间线');
  if (vm != null && vm.snapshotCount > 0) {
    final buf2 = BackBuffer(1240, 800);
    try {
      mw.testSetSize(1240, 800);
      mw.testSetTab(1); // 历史对比
      mw.onPaint(buf2.gdi); // 绘制会触发 _ensureSeries
    } finally {
      buf2.dispose();
    }
    final sv = mw.series;
    _check('历史对比页装配出了时间线', sv != null);
    if (sv != null) {
      final cur = vm.all.firstWhere((m) => m.id == mw.selectedId,
          orElse: () => vm.all.first);
      _check('时间线期数 ≥ 1', sv.periodCount >= 1, '${sv.periodCount} 期');
      _check('时间线是**该榜自身**的历史（系列键一致）',
          sv.analysis.seriesKey == cur.seriesKey,
          '${sv.analysis.seriesKey} vs ${cur.seriesKey}');
      _check('区间档位可切（近 7 期 / 近 30 期 / 全部）',
          TimeRange.values.length == 3);
    }
  }

  // ── 3. 扫榜设置窗口：构造 + 绘制 + 目标解析 ──
  print('\n[3] ScanDialogWindow 构造、绘制与目标解析');
  final dlg = ScanDialogWindow(owner: mw);
  final dbuf = BackBuffer(720, 620);
  try {
    dlg.testSetSize(720, 620);
    dlg.onPaint(dbuf.gdi);
    _pass++;
    print('  [OK]   设置窗绘制成功');

    final grpCount = dlg.groups.length;
    final boardCount = dlg.groups.fold<int>(0, (a, g) => a + g.boards.length);
    _check('枚举出平台分组', grpCount > 0, '$grpCount 个平台');
    _check('枚举出榜单条目', boardCount > 0, '$boardCount 个榜');
    _check('默认勾选了组合', dlg.checked.isNotEmpty,
        '${dlg.checked.length} 项');

    // 逐行矩形是否真被记录（这是"点击判定"的命脉）
    final rowRectCount = dlg.testRowRectCount;
    _check('勾选行矩形已记录', rowRectCount > 0, '$rowRectCount 行');

    // 目标解析：勾选项 → ScanTarget
    final targets = dlg.testTargets();
    _check('勾选项能解析成 ScanTarget', targets.isNotEmpty,
        '${targets.length} 个目标');
    final badSource =
        targets.where((t) => !const {'qidian', 'fanqie', 'qimao', 'jjwxc'}
            .contains(t.source)).toList();
    _check('目标 platform 均在白名单', badSource.isEmpty,
        badSource.isEmpty ? '' : badSource.map((t) => t.source).join(','));
    final badLimit = targets.where((t) => t.limit <= 0).toList();
    _check('目标 limit 全部 > 0', badLimit.isEmpty);

    // 命中测试：拿一个已记录的行矩形中心点去点，必须能翻转勾选状态
    final probe = dlg.testProbeRowCenter();
    if (probe != null) {
      final (px, py, before) = probe;
      dlg.onClick(px, py);
      final after = dlg.checked.contains(dlg.testKeyOfPoint(px, py));
      _check('点击勾选行能翻转状态', before != after,
          before ? '已选→已取消' : '未选→已选');
    } else {
      _fail++;
      print('  [FAIL] 找不到可探测的勾选行');
    }

    // 快捷按钮：全不选 / 默认组合
    dlg.checked.clear();
    dlg.testClickButton(ScanDialogWindow.idQuickSweep);
    _check('「默认组合」按钮生效', dlg.checked.length >= 8,
        '${dlg.checked.length} 项');
    dlg.testClickButton(ScanDialogWindow.idClearAll);
    _check('「全不选」按钮生效', dlg.checked.isEmpty);
  } on Object catch (e, st) {
    _fail++;
    print('  [FAIL] 设置窗抛异常: $e');
    print('         ${st.toString().split('\n').first}');
  } finally {
    dbuf.dispose();
  }

  // ── 4. 服务层枚举一致性（GUI 与 CLI 必须同源）──
  print('\n[4] ScanService 枚举（GUI/CLI 同源）');
  final svc = ScanService(outRoot: outRoot);
  final boards = svc.enumerateBoards();
  _check('枚举到平台', boards.isNotEmpty, '${boards.length} 个');
  for (final b in boards) {
    print('       ${b.sourceId.padRight(8)} ${b.displayName}  '
        '榜 ${b.boards.length} 个  题材 ${b.categories.length} 个');
  }

  print('\n=== 结果: $_pass 通过 / $_fail 失败 ===');
  exit(_fail == 0 ? 0 : 1);
}

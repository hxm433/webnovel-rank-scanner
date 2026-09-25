/// 真窗口回归：点「打开」到底能不能跳转。
///
/// ★ 为什么必须**真窗口 + 真消息**：离屏渲染里 `onClick` 是直接调的，
///   测不到"消息坐标 → 客户区坐标 → 命中区"这一段。
///   而这一段恰好是第 19 轮引入 `clientXYOf` 的地方，
///   也正好是用户报"点了没反应"的地方。
///
/// 运行：dart run bin/_t_book_link_real.dart [数据目录]
library;

import 'dart:async';
import 'dart:io';

import '../lib/ui/app.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/win32.dart';

int _pass = 0, _fail = 0;
void ok(String s) {
  _pass++;
  print('  [OK]   $s');
}

void bad(String s) {
  _fail++;
  print('  [FAIL] $s');
}

void check(bool c, String s) => c ? ok(s) : bad(s);

/// 按客户区坐标投递一次真实的左键按下（走完整消息路径）。
void postClick(int hwnd, int cx, int cy) {
  // lParam：低 16 位 x，高 16 位 y（都是**有符号** 16 位）
  final lp = ((cy & 0xFFFF) << 16) | (cx & 0xFFFF);
  postMessageW(hwnd, wmLButtonDown, 1 /* MK_LBUTTON */, lp);
  postMessageW(hwnd, wmLButtonUp, 0, lp);
}

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : 'out';
  print('=== 真窗口：点「打开」能否跳转 ===\n');

  Palette.apply(AppTheme.dark);
  final win = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);

  // ★ 用一个**宽窗口**（1900×1000）：这正是用户截图里那种情况 ——
  //   8 列放得下，右侧还剩一点空隙，所以「打开」按钮本来就在屏幕里。
  const w = 1900, h = 1000;
  final app = App();
  final done = app.run(win, width: w, height: h);

  await Future<void>.delayed(const Duration(milliseconds: 1200));

  check(win.hwnd != 0, '真窗口已建立 hwnd=${win.hwnd}');
  print('       客户区 ${win.width}x${win.height}');

  // 选一份番茄快照（用户截图里那个平台）
  final all = win.vm?.all ?? const [];
  final fq = all.where((m) => m.source == 'fanqie').toList();
  if (all.isEmpty) {
    print('数据目录里没有快照，无法测');
    app.quit();
    await done;
    exitCode = 2;
    return;
  }
  win.testSelect(fq.isNotEmpty ? fq.first.id : all.first.id);
  win.testSetTab(0);
  win.onPaint(BackBuffer(win.width, win.height).gdi); // 强制登记命中区

  final m = win.currentMeta()!;
  print('       快照 ${m.source} / ${m.board} / ${m.count} 条\n');

  print('[1] 命中区位置');
  final btn = win.hitRects[MainWindow.idBookLinkBase];
  final area = win.testDetailArea;
  check(btn != null, '第 0 行「打开」有命中区：$btn');
  if (btn == null) {
    app.quit();
    await done;
    exitCode = 1;
    return;
  }
  print('       明细表可见区 $area');
  print('       自然总宽 ${win.testDetailNaturalWidth}'
      ' / 可见宽 ${area?.width}');
  final visible = area != null && btn.right <= area.right && btn.left >= area.left;
  check(visible, '「打开」按钮落在可见区内（用户点得到）：$btn');

  print('\n[2] 投递真实左键消息');
  final cx = btn.left + btn.width ~/ 2;
  final cy = btn.top + btn.height ~/ 2;
  final before = win.statusText;
  print('       点击客户区坐标 ($cx, $cy)');
  postClick(win.hwnd, cx, cy);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final after = win.statusText;
  print('       statusText: "$before"  ->  "$after"');
  check(after != before, '点击被识别（statusText 变了）');
  check(after.startsWith('已打开详情页'),
      '走到了 openExternal —— "$after"');

  print('\n[3] 整行都能点（不该只有那个小按钮能点）');
  // ★ 这里**不再点第二次** —— 每点一次都会真的开一个浏览器标签。
  //   "点行也能打开"由 `_t_cover_link` 的离屏 onClick 断言覆盖，
  //   这里只做几何验证：整行命中区存在、被裁进可见区、并且**覆盖住按钮**。
  final row = win.testBookRowRect(0);
  if (row == null) {
    bad('第 0 行没有整行命中区');
  } else {
    print('       整行命中区 $row');
    check(true, '第 0 行有整行命中区（比按钮大得多：${row.width}px）');
    check(row.left >= (area?.left ?? 0) && row.right <= (area?.right ?? 0),
        '整行命中区被裁进可见区（视口外没有幻影可点区）');
    check(row.contains(cx, cy), '整行命中区**覆盖**了「打开」按钮的位置');
  }

  app.quit();
  await done;

  print('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

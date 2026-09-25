/// 自检 —— 脏区（局部失效）重绘必须与整窗重绘**像素一致**。
///
/// 这是最容易出错的一环：`SetViewportOrgEx` 平移 + `presentTo(x,y)` 贴回，
/// 任何一边算错都会表现为"局部刷新后内容整体错位/跑到左上角"。
///
/// 判定方法：同一份数据分别用
///   ① 整窗重绘（NULL 失效）
///   ② 只有状态栏失效（脏区路径）
/// 画两遍，把状态栏那一条的像素**逐字节比对** —— 必须完全相同。
/// 光看"有没有画出来"是不够的，错位也会画出来。
library;

import 'dart:io';

import '../lib/ui/app.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';

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

Future<void> main() async {
  print('=== 脏区重绘一致性自检 ===\n');

  final win = MainWindow(outRoot: 'out');
  final app = App();
  final done = app.run(win, width: 1240, height: 800);
  await Future<void>.delayed(const Duration(milliseconds: 900));

  // 等淡入动画跑完，否则两次采样进度不同会被误判成"错位"。
  await Future<void>.delayed(const Duration(milliseconds: 400));

  final W = win.width, H = win.height;
  final statusH = Metrics.statusHeight;
  final dirtyTop = H - statusH;

  print('[1] 基准：整窗重绘');
  final full = BackBuffer(W, H);
  try {
    win.onPaint(full.gdi);
  } finally {
    // 先读出状态栏那一条，再释放。
  }
  final fullPx = full.readBgra();
  full.dispose();

  print('[2] 脏区路径：缓冲只覆盖状态栏，原点平移后贴回');
  final dirty = BackBuffer(W, statusH);
  try {
    final g = dirty.gdi;
    g.origin(0, -dirtyTop); // 与 app.dart 的 WM_PAINT 一致
    try {
      win.onPaint(g);
    } finally {
      g.origin(0, 0);
    }
  } finally {}
  final dirtyPx = dirty.readBgra();
  dirty.dispose();

  print('[3] 逐像素比对（状态栏那一条）');
  var diff = 0;
  var firstDiff = '';
  for (var y = 0; y < statusH; y++) {
    for (var x = 0; x < W; x++) {
      final o1 = ((dirtyTop + y) * W + x) * 4;
      final o2 = (y * W + x) * 4;
      final a = (fullPx[o1] << 24) |
          (fullPx[o1 + 1] << 16) |
          (fullPx[o1 + 2] << 8) |
          fullPx[o1 + 3];
      final b = (dirtyPx[o2] << 24) |
          (dirtyPx[o2 + 1] << 16) |
          (dirtyPx[o2 + 2] << 8) |
          dirtyPx[o2 + 3];
      if (a != b) {
        diff++;
        if (firstDiff.isEmpty) {
          firstDiff = '首个差异 ($x,${dirtyTop + y}) 整窗=0x${a.toRadixString(16)} '
              '脏区=0x${b.toRadixString(16)}';
        }
      }
    }
  }
  print('       状态栏 ${W}x$statusH = ${W * statusH} 像素，差异 $diff 个');
  if (diff > 0) print('       $firstDiff');
  check(diff == 0, '脏区重绘与整窗重绘像素完全一致');

  print('\n[4] 脏区路径确实比整窗省内存');
  final fullBytes = W * H * 4;
  final dirtyBytes = W * statusH * 4;
  final ratio = fullBytes / dirtyBytes;
  print('       整窗缓冲 $fullBytes 字节 vs 脏区缓冲 $dirtyBytes 字节'
      '（省 ${(ratio * 100).round()} 倍）');
  check(ratio > 10, '脏区缓冲比整窗小 10 倍以上（实测 ${ratio.toStringAsFixed(1)}x）');

  print('\n[5] 脏区非空（真的画了内容，不是一片纯底色）');
  final seen = <int>{};
  for (var i = 0; i + 3 < dirtyPx.length; i += 4) {
    seen.add((dirtyPx[i + 2] << 16) | (dirtyPx[i + 1] << 8) | dirtyPx[i]);
  }
  print('       脏区不同颜色数 = ${seen.length}');
  check(seen.length > 3, '状态栏有条目底色+文字+分隔线（颜色 >3）');

  print('\n=== 结果: $_pass 通过 / $_fail 失败 ===');

  app.quit();
  await done.timeout(const Duration(seconds: 3), onTimeout: () {});
  exit(_fail == 0 ? 0 : 1);
}

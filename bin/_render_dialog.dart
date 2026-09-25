/// 把**扫榜设置窗**离屏渲染成 PNG —— 用来肉眼确认新版的"每榜本数"步进器
/// 真的画出来了、没被挤压/重叠。
///
/// 走的是 `ScanDialogWindow.onPaint` 本体（不是在测试里另画一份），
/// 所以这张图就是发布版设置窗的样子。
///
/// 运行：
///   dart run bin/_render_dialog.dart
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../lib/png.dart';
import '../lib/ui/dialogs.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/win32.dart';

/// 把 `paint` 画进 32 位 DIB，返回 BGRA。
Uint8List _renderBgra(void Function(Gdi) paint, int width, int height) {
  final screenDc = getDC(0);
  final memDc = createCompatibleDC(screenDc);
  final bi = calloc<BitmapInfoHeader>();
  bi.ref
    ..size = 40
    ..width = width
    ..height = -height
    ..planes = 1
    ..bitCount = 32
    ..compression = 0;
  final ppv = calloc<Pointer<Void>>();
  final hbmp = createDIBSection(memDc, bi, 0, ppv, 0, 0);
  final old = selectObject(memDc, hbmp);
  paint(Gdi(memDc));
  final n = width * height * 4;
  final out = Uint8List(n);
  final ptr = ppv.value.cast<Uint8>();
  for (var i = 0; i < n; i++) {
    out[i] = ptr[i];
  }
  selectObject(memDc, old);
  deleteObject(hbmp);
  deleteDC(memDc);
  releaseDC(0, screenDc);
  calloc.free(bi);
  calloc.free(ppv);
  return out;
}

void main() {
  final dir = Directory('build/shots')..createSync(recursive: true);
  final owner = MainWindow(outRoot: 'out');

  // ── 场景 A：默认（4 个榜已勾选，步进器应是"亮"的）──
  {
    final dlg = ScanDialogWindow(owner: owner);
    dlg.testSetSize(1020, 760);
    final bgra = _renderBgra(dlg.onPaint, dlg.width, dlg.height);
    final png = bgraToPng(bgra, dlg.width, dlg.height);
    File('${dir.path}/设置窗_默认.png').writeAsBytesSync(png);
    stdout.writeln('设置窗_默认.png  ${dlg.width}x${dlg.height}  '
        '步进器命中区=${dlg.testStepperHitCount}  '
        '汇总=${dlg.testSummary()}');
  }

  // ── 场景 B：改几个本数（10 / 50 / 200），看数字真的变了 ──
  {
    final dlg = ScanDialogWindow(owner: owner);
    dlg.testSetSize(1020, 760);
    // 先画一次让布局建立（_build 在 onPaint 里被调）
    dlg.onPaint(Gdi(0));
    dlg.checked.clear();
    dlg.checked.addAll([
      'qidian|月票榜|全站',
      'qidian|畅销榜|玄幻',
      'qimao|男频大热榜|',
      'jjwxc|总分排行榜|',
    ]);
    dlg.limits['qidian|月票榜|'] = 200;
    dlg.limits['qidian|畅销榜|'] = 50;
    dlg.limits['qimao|男频大热榜|'] = 10;
    final bgra = _renderBgra(dlg.onPaint, dlg.width, dlg.height);
    final png = bgraToPng(bgra, dlg.width, dlg.height);
    File('${dir.path}/设置窗_自定义本数.png').writeAsBytesSync(png);
    stdout.writeln('设置窗_自定义本数.png  '
        '步进器命中区=${dlg.testStepperHitCount}  '
        '汇总=${dlg.testSummary()}');
    final ts = dlg.testTargets();
    stdout.writeln('目标本数：${[for (final t in ts) '${t.source}/${t.board}=${t.limit}']}');
  }

  stdout.writeln('\n已写到 build/shots/');
}

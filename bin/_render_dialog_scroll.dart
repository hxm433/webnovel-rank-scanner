/// 离屏渲染**扫榜设置窗**的两个关键状态，验证问题 B（莫名空白）/ C（字体重叠）已修。
///
/// B：内容区滚动后，滚上去的行不能画到卡片外（原来是"莫名空白"）。
/// C：最后一行不能画进底栏（原来是底栏汇总文字压在勾选框上）。
///
/// 用 1040x720（与 showScanDialog 一致），并强制 scrollY 到不同值各渲染一张。
///
/// 运行：dart run bin/_render_dialog_scroll.dart
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

  // 与 showScanDialog 一致的逻辑尺寸。
  const w = 1040, h = 720;

  // ── 顶部（scrollY=0）：检查卡片顶部有无"莫名空白" ──
  {
    final dlg = ScanDialogWindow(owner: owner);
    dlg.testSetSize(w, h);
    dlg.onPaint(Gdi(0)); // 建立布局
    dlg.testSetScroll(0);
    final bgra = _renderBgra(dlg.onPaint, w, h);
    File('${dir.path}/设置窗_scroll0.png').writeAsBytesSync(bgraToPng(bgra, w, h));
    stdout.writeln('设置窗_scroll0.png  scrollY=0');
  }

  // ── 中段（scrollY=mid）：滚上去的内容不能溢出卡片 ──
  {
    final dlg = ScanDialogWindow(owner: owner);
    dlg.testSetSize(w, h);
    dlg.onPaint(Gdi(0));
    dlg.testSetScroll(180);
    final bgra = _renderBgra(dlg.onPaint, w, h);
    File('${dir.path}/设置窗_scroll180.png').writeAsBytesSync(bgraToPng(bgra, w, h));
    stdout.writeln('设置窗_scroll180.png  scrollY=180');
  }

  // ── 底部（scrollY=max）：最后一行不能压到底栏 ──
  {
    final dlg = ScanDialogWindow(owner: owner);
    dlg.testSetSize(w, h);
    dlg.onPaint(Gdi(0));
    final maxY = dlg.testMaxScroll();
    dlg.testSetScroll(maxY);
    final bgra = _renderBgra(dlg.onPaint, w, h);
    File('${dir.path}/设置窗_scrollmax.png').writeAsBytesSync(bgraToPng(bgra, w, h));
    stdout.writeln('设置窗_scrollmax.png  scrollY=$maxY');
    stdout.writeln('  汇总=${dlg.testSummary()}');
  }

  stdout.writeln('\n已写到 build/shots/');
}

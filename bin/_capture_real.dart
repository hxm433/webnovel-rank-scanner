/// 真窗口截屏 —— 起**真窗 + 真消息循环**，等它绘制完，再把窗口客户区
/// 用 GDI `BitBlt` 抓到 PNG。
///
/// 为什么必须做这一步：`_render_shots.dart` 是**离屏渲染**，画的是"我以为的
/// 界面"；真实窗口还叠着**标题栏主题 / DPI 缩放 / 系统合成**这些环境因素。
/// 用户看到的那条刺眼白标题栏，只有真窗口才复现得出来。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../lib/ui/app.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/win32.dart';
import '_render_shots.dart' show bgraToPng;

Future<void> main() async {
  final log = StringBuffer();
  final win = MainWindow(outRoot: 'out');
  final app = App();
  final done = app.run(win, width: 1240, height: 800);

  // 等首绘 + 数据载入
  await Future<void>.delayed(const Duration(milliseconds: 1200));

  log.writeln('hwnd=0x${win.hwnd.toRadixString(16)}');
  log.writeln('client=${win.width}x${win.height}');
  log.writeln('snapshots=${win.vm?.snapshotCount} records=${win.vm?.recordCount} '
      'errors=${win.loadErrors}');

  final w = win.width, h = win.height;

  // 直接 BitBlt 真窗口的客户区 DC 到 32 位 DIB
  final winDc = getDC(win.hwnd);
  final memDc = createCompatibleDC(winDc);
  final bi = calloc<BitmapInfoHeader>();
  bi.ref
    ..size = 40
    ..width = w
    ..height = -h
    ..planes = 1
    ..bitCount = 32
    ..compression = 0;
  final ppv = calloc<Pointer<Void>>();
  final hbmp = createDIBSection(memDc, bi, 0, ppv, 0, 0);
  final old = selectObject(memDc, hbmp);
  bitBlt(memDc, 0, 0, w, h, winDc, 0, 0, srccopy);
  releaseDC(win.hwnd, winDc);

  final n = w * h * 4;
  final bytes = Uint8List(n);
  final p = ppv.value.cast<Uint8>();
  for (var i = 0; i < n; i++) {
    bytes[i] = p[i];
  }
  selectObject(memDc, old);
  deleteObject(hbmp);
  deleteDC(memDc);
  calloc.free(bi);
  calloc.free(ppv);

  final png = bgraToPng(bytes, w, h);
  File('build/shots/real_window.png').writeAsBytesSync(png);
  log.writeln('wrote build/shots/real_window.png (${png.length} bytes)');
  stdout.write(log.toString());

  app.quit();
  await done.timeout(const Duration(seconds: 3), onTimeout: () {});
  exit(0);
}

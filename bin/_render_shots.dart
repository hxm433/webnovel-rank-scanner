/// 把界面**离屏渲染成 PNG** —— 不弹窗口、不依赖截屏权限。
///
/// 原理：完全复用正式绘制代码（`MainWindow.onPaint`），
/// 只是把目标从"屏幕 DC"换成"32 位 DIB 内存 DC"（能直接读像素），
/// 再把 BGRA 缓冲拼成 PNG（手写，不引第三方 image 库）。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../lib/png.dart';
import '../lib/ui/data_manager.dart';
import '../lib/ui/dialogs.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/win32.dart';

// PNG 编码已抽到 ../lib/png.dart（发布版 exe 的自检截图也要用同一份）。

/// 把界面画进 32 位 DIB，返回 BGRA 像素。
Uint8List renderBgra(void Function(Gdi) paint, int width, int height) {
  final screenDc = getDC(0);
  final memDc = createCompatibleDC(screenDc);

  final bi = calloc<BitmapInfoHeader>();
  bi.ref
    ..size = 40
    ..width = width
    ..height = -height // 负 = 自上而下，省得再翻转
    ..planes = 1
    ..bitCount = 32
    ..compression = 0; // BI_RGB

  final ppv = calloc<Pointer<Void>>();
  final hbmp = createDIBSection(memDc, bi, 0, ppv, 0, 0);
  if (hbmp == 0) {
    calloc.free(bi);
    calloc.free(ppv);
    deleteDC(memDc);
    releaseDC(0, screenDc);
    throw StateError('CreateDIBSection 失败');
  }
  final old = selectObject(memDc, hbmp);

  paint(Gdi(memDc));

  final bytes = width * height * 4;
  final out = Uint8List(bytes);
  final ptr = ppv.value.cast<Uint8>();
  for (var i = 0; i < bytes; i++) {
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

void main(List<String> args) {
  final outRoot = args.isNotEmpty ? args[0] : 'out';
  const shots = <(String, int, int, int)>[
    ('1_榜单明细', 0, 1240, 800),
    ('2_历史对比', 1, 1240, 800),
    ('3_跨榜分析', 2, 1240, 800),
    ('4_小窗适应', 0, 860, 560),
    // ★ 窄窗下的「历史对比」走的是另一条布局分支（图与解读叠放 / 只放解读），
    //   必须单独出一张图，否则那条分支永远没人看过。
    ('5_历史对比_窄窗', 1, 900, 620),
  ];

  final dir = Directory('build/shots')..createSync(recursive: true);
  var n = 0;

  // ★ 深色 / 浅色**各出一套**：主题是两套色板，只验一套等于没验另一套。
  //   浅色主题最容易出的问题是"某个控件还在用深色底/浅色字"，
  //   而那种问题只有把图画出来才看得见。
  for (final theme in AppTheme.values) {
    final suffix = theme == AppTheme.dark ? '' : '_浅色';
    for (final (name, tab, w, h) in shots) {
      Palette.apply(theme);
      final mw = MainWindow(outRoot: outRoot);
      // MainWindow 构造会把主题设回"设置里那一档"，所以这里再压一次。
      Palette.apply(theme);
      mw.reload();
      mw.testSetSize(w, h);
      mw.testSetTab(tab);
      final bgra = renderBgra(mw.onPaint, w, h);
      final png = bgraToPng(bgra, w, h);
      File('${dir.path}/$name$suffix.png').writeAsBytesSync(png);
      print('$name$suffix.png  ${w}x$h  '
          '${(png.length / 1024).toStringAsFixed(0)} KB');
      n++;
    }

    // 侧栏「隐藏 + 平台折叠」态：看"已隐藏 N 项 · 管理"入口与折叠箭头。
    //
    // ★ 这一步会往 outRoot 写 ui.json（隐藏状态要持久化）——
    //   画完立刻删掉，否则会污染同一轮里后面那几张图
    //   （它们会莫名其妙地少几行侧栏）。
    {
      Palette.apply(theme);
      final mw = MainWindow(outRoot: outRoot);
      Palette.apply(theme);
      mw.reload();
      mw.testSetSize(1240, 800);
      final warm = BackBuffer(1240, 800);
      try {
        mw.onPaint(warm.gdi); // 先画一帧，把 sideRows 填出来
      } finally {
        warm.dispose();
      }
      mw.hideSidebarMeta(mw.sideRows.first.id);
      if (mw.sideGroupCount > 1) mw.toggleSidebarGroup(1);
      final bgra = renderBgra(mw.onPaint, 1240, 800);
      final png = bgraToPng(bgra, 1240, 800);
      File('${dir.path}/8_侧栏隐藏态$suffix.png').writeAsBytesSync(png);
      print('8_侧栏隐藏态$suffix.png  1240x800  '
          '${(png.length / 1024).toStringAsFixed(0)} KB');
      n++;
      final ui = File('$outRoot/ui.json');
      if (ui.existsSync()) ui.deleteSync();
    }

    // 扫榜设置窗（折叠树 + 搜索框，两套主题各一张）
    {
      Palette.apply(theme);
      final mw = MainWindow(outRoot: outRoot);
      Palette.apply(theme);
      mw.reload();
      final dlg = ScanDialogWindow(owner: mw);
      const sw = 1040, sh = 720;
      dlg.testSetSize(sw, sh);
      final bgra = renderBgra(dlg.onPaint, sw, sh);
      final png = bgraToPng(bgra, sw, sh);
      File('${dir.path}/7_扫榜设置$suffix.png').writeAsBytesSync(png);
      print('7_扫榜设置$suffix.png  ${sw}x$sh  '
          '${(png.length / 1024).toStringAsFixed(0)} KB');
      n++;
    }

    // 数据管理窗（两套主题各一张）
    {
      Palette.apply(theme);
      final mw = MainWindow(outRoot: outRoot);
      Palette.apply(theme);
      mw.reload();
      final dm = DataManagerWindow(owner: mw);
      const dw = 1000, dh = 640;
      dm.testSetSize(dw, dh);
      final bgra = renderBgra(dm.onPaint, dw, dh);
      final png = bgraToPng(bgra, dw, dh);
      File('${dir.path}/6_数据管理$suffix.png').writeAsBytesSync(png);
      print('6_数据管理$suffix.png  ${dw}x$dh  '
          '${(png.length / 1024).toStringAsFixed(0)} KB');
      n++;
    }
  }

  print('\n共 $n 张渲染完成 -> build/shots/');
}

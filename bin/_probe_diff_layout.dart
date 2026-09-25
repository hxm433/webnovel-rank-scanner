/// 一次性探针：把「历史对比」页的卡片纵向边界从**渲染结果像素**里量出来。
///
/// 为什么不用看图猜：解读栏能显示几行完全由"卡片净高"决定，
/// 而净高是几步 clamp 的结果 —— 只有量出来才知道该压哪一处。
///
/// 运行：dart run bin/_probe_diff_layout.dart [outRoot]
library;

import 'dart:io';

import '../lib/png.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'build/fixture_out';
  const w = 1240;
  const h = 800;

  final mw = MainWindow(outRoot: root);
  mw.reload();
  mw.testSetSize(w, h);
  mw.testSetTab(1);
  final buf = BackBuffer(w, h);
  mw.onPaint(buf.gdi);
  final png = bgraToPng(buf.readBgra(), w, h);
  buf.dispose();

  final img = decodePngBytes(png);
  if (img == null) {
    stderr.writeln('解码失败');
    exit(1);
  }

  int rgbAt(int x, int y) {
    final o = (y * img.width + x) * 4;
    // DecodedImage 的像素顺序是 BGRA
    return (img.bgra[o + 2] << 16) |
        (img.bgra[o + 1] << 8) |
        img.bgra[o];
  }

  // 卡片背景是 Palette.surface，页背景是 Palette.bg；按这个界别找边界。
  // COLORREF 是 0x00BBGGRR，渲染出来的像素是 0xRRGGBB —— 必须换序再比。
  int rgbOf(int colorref) =>
      ((colorref & 0xFF) << 16) | (colorref & 0xFF00) | ((colorref >> 16) & 0xFF);
  final surface = rgbOf(Palette.surface);
  final bg = rgbOf(Palette.bg);
  stdout.writeln('factor=${Metrics.factor}  surface=#${surface.toRadixString(16)} '
      'bg=#${bg.toRadixString(16)}');
  stdout.writeln('窗口 ${w}x$h，取 x=$w-260 这一列扫描纵向结构：');

  final x = w - 260;
  var prev = '';
  for (var y = 0; y < h; y++) {
    final c = rgbAt(x, y);
    final kind = c == surface ? 'S' : (c == bg ? '.' : '?');
    if (kind != prev) {
      stdout.writeln('  y=$y  ${kind == 'S' ? '卡片面' : (kind == '.' ? '页背景' : '其它')}  '
          '#${c.toRadixString(16).padLeft(6, '0')}');
      prev = kind;
    }
  }
}

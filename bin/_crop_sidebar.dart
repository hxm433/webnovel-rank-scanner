/// 离屏渲染**侧栏选中项**的放大裁剪图 —— 专验"未对齐"（问题 A）。
///
/// 复刻用户截图 145910 的取景：选中行（高亮框 + 左侧 accent 竖条）的左缘。
/// 渲染 scale 1.0 的 1240x800 主窗，裁出侧栏区域并最近邻放大 4x。
///
/// 运行：dart run bin/_crop_sidebar.dart
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/png.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '_render_shots.dart' show renderBgra;

/// 从 BGRA 缓冲裁一块并放大 [k] 倍（最近邻），返回 BGRA。
Uint8List _cropZoom(
    Uint8List src, int sw, int sh, int x0, int y0, int cw, int ch, int k) {
  final out = Uint8List(cw * k * ch * k * 4);
  for (var y = 0; y < ch * k; y++) {
    for (var x = 0; x < cw * k; x++) {
      final sx = x0 + x ~/ k;
      final sy = y0 + y ~/ k;
      final so = (sy * sw + sx) * 4;
      final dofs = (y * cw * k + x) * 4;
      out[dofs] = src[so];
      out[dofs + 1] = src[so + 1];
      out[dofs + 2] = src[so + 2];
      out[dofs + 3] = 255;
    }
  }
  return out;
}

void main() {
  const w = 1240, h = 800;
  final mw = MainWindow(outRoot: 'out');
  mw.reload();
  mw.testSetSize(w, h);
  final bgra = renderBgra(mw.onPaint, w, h);

  final dir = Directory('build/shots')..createSync(recursive: true);
  File('${dir.path}/sidebar_full.png').writeAsBytesSync(bgraToPng(bgra, w, h));

  // 定位**选中填充色** Palette.selected = rgb(26,47,62)（BGR 62,47,26）。
  var selY = -1;
  for (var y = 60; y < 780; y++) {
    final o = (y * w + 30) * 4; // x=30：选中框内部（远离 accent 条）
    final b = bgra[o], g = bgra[o + 1], r = bgra[o + 2];
    if ((r - 26).abs() < 4 && (g - 47).abs() < 4 && (b - 62).abs() < 4) {
      selY = y;
      break;
    }
  }
  stdout.writeln('选中填充行 y=$selY');
  if (selY > 0) {
    final sb = StringBuffer('左缘 x=0..24: ');
    for (var x = 0; x < 24; x++) {
      final o = (selY * w + x) * 4;
      sb.write('$x:(${bgra[o + 2]},${bgra[o + 1]},${bgra[o]}) ');
    }
    stdout.writeln(sb.toString());
  }

  // 选中项附近裁剪 + 放大 6 倍，肉眼确认左缘/accent 条。
  const cw = 130;
  const ch = 56;
  const k = 6;
  final y0 = selY > 0 ? selY - 8 : 490;
  final crop = _cropZoom(bgra, w, h, 0, y0, cw, ch, k);
  File('${dir.path}/sidebar_sel_zoom.png')
      .writeAsBytesSync(bgraToPng(crop, cw * k, ch * k));
  stdout.writeln('放大图(选中项) -> build/shots/sidebar_sel_zoom.png  y0=$y0');
}

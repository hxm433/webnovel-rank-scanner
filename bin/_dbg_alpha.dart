library;

import 'dart:io';

import '../lib/png.dart';
import '../lib/ui/gdi.dart';

void main() {
  final buf = BackBuffer(64, 40);
  final g = buf.gdi;
  g.fill(Rc(0, 0, 64, 40), 0xFFFFFF);
  g.fill(Rc(10, 10, 40, 30), 0x0000FF); // 红
  final bgra = buf.readBgra();
  buf.dispose();

  var a255 = 0, a0 = 0, aOther = 0;
  for (var i = 3; i < bgra.length; i += 4) {
    final a = bgra[i];
    if (a == 255) {
      a255++;
    } else if (a == 0) {
      a0++;
    } else {
      aOther++;
    }
  }
  stdout.writeln('alpha 统计：255=$a255  0=$a0  其它=$aOther  总像素=${64 * 40}');

  final png = bgraToPng(bgra, 64, 40);
  final dec = decodePngBytes(png)!;
  var rgbDiff = 0, alphaDiff = 0;
  for (var i = 0; i < bgra.length; i += 4) {
    if (dec.bgra[i] != bgra[i] ||
        dec.bgra[i + 1] != bgra[i + 1] ||
        dec.bgra[i + 2] != bgra[i + 2]) {
      rgbDiff++;
    }
    if (dec.bgra[i + 3] != bgra[i + 3]) alphaDiff++;
  }
  stdout.writeln('闭环：RGB 差异像素=$rgbDiff  alpha 差异像素=$alphaDiff');
  stdout.writeln('解码 alpha 取值集合（前 4 个不同值）：');
  final set = <int>{};
  for (var i = 3; i < dec.bgra.length; i += 4) {
    set.add(dec.bgra[i]);
  }
  stdout.writeln('  $set');
}

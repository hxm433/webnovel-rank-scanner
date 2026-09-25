/// 裁剪 PNG 的某个区域并放大，供人工细看（纯手写，不引第三方库）。
///
/// 运行：dart run bin/_crop.dart <src.png> <x> <y> <w> <h> <scale> <dst.png>
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/png.dart';

/// 极简 PNG 解码：只支持我们自己 `bgraToPng` 产出的格式
/// （8 位 RGBA、无隔行、filter 0/1/2/3/4、stored zlib 块）。
/// 生产代码不需要解码器，这个工具只是给人工验收用的。
Uint8List decodePng(Uint8List png, List<int> sizeOut) {
  var p = 8;
  var w = 0, h = 0;
  final idat = <int>[];
  while (p < png.length) {
    final len = (png[p] << 24) | (png[p + 1] << 16) | (png[p + 2] << 8) | png[p + 3];
    final type = String.fromCharCodes(png.sublist(p + 4, p + 8));
    final data = png.sublist(p + 8, p + 8 + len);
    if (type == 'IHDR') {
      w = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
      h = (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7];
    } else if (type == 'IDAT') {
      idat.addAll(data);
    } else if (type == 'IEND') {
      break;
    }
    p += 12 + len;
  }
  sizeOut..clear()..add(w)..add(h);

  // zlib：2 字节头 + stored 块（我们自己的编码器就是这么写的）
  final raw = _inflateStored(Uint8List.fromList(idat));
  final bpp = 4;
  final stride = w * bpp;
  final out = Uint8List(h * stride);
  var rp = 0;
  for (var y = 0; y < h; y++) {
    final filter = raw[rp++];
    final line = raw.sublist(rp, rp + stride);
    rp += stride;
    final prev = y == 0 ? null : out.sublist((y - 1) * stride, y * stride);
    for (var i = 0; i < stride; i++) {
      final a = i >= bpp ? out[y * stride + i - bpp] : 0;
      final b = prev == null ? 0 : prev[i];
      final c = (prev == null || i < bpp) ? 0 : prev[i - bpp];
      var v = line[i];
      switch (filter) {
        case 0:
          break;
        case 1:
          v = (v + a) & 0xFF;
        case 2:
          v = (v + b) & 0xFF;
        case 3:
          v = (v + ((a + b) >> 1)) & 0xFF;
        case 4:
          v = (v + _paeth(a, b, c)) & 0xFF;
      }
      out[y * stride + i] = v;
    }
  }
  return out;
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

Uint8List _inflateStored(Uint8List z) {
  var p = 0;
  // zlib 头
  final cmf = z[p], flg = z[p + 1];
  if ((cmf * 256 + flg) % 31 != 0) throw StateError('zlib 头校验失败');
  p += 2;
  final out = <int>[];
  while (p < z.length) {
    final hdr = z[p++];
    final bfinal = hdr & 1;
    final btype = (hdr >> 1) & 3;
    if (btype != 0) throw StateError('只支持 stored 块，遇到 btype=$btype');
    final len = z[p] | (z[p + 1] << 8);
    p += 4; // len + nlen
    out.addAll(z.sublist(p, p + len));
    p += len;
    if (bfinal == 1) break;
  }
  return Uint8List.fromList(out);
}

void main(List<String> args) {
  if (args.length < 7) {
    stderr.writeln('用法: _crop.dart <src> <x> <y> <w> <h> <scale> <dst>');
    exit(2);
  }
  final src = File(args[0]).readAsBytesSync();
  final x = int.parse(args[1]);
  final y = int.parse(args[2]);
  final cw = int.parse(args[3]);
  final ch = int.parse(args[4]);
  final scale = int.parse(args[5]);
  final dst = args[6];

  final size = <int>[];
  final pix = decodePng(src, size);
  final w = size[0], h = size[1];
  final ow = cw * scale, oh = ch * scale;
  final out = Uint8List(ow * oh * 4);
  for (var oy = 0; oy < oh; oy++) {
    final sy = y + oy ~/ scale;
    for (var ox = 0; ox < ow; ox++) {
      final sx = x + ox ~/ scale;
      final si = (sy.clamp(0, h - 1) * w + sx.clamp(0, w - 1)) * 4;
      final di = (oy * ow + ox) * 4;
      out[di] = pix[si];
      out[di + 1] = pix[si + 1];
      out[di + 2] = pix[si + 2];
      out[di + 3] = 255;
    }
  }
  File(dst).writeAsBytesSync(bgraToPng(out, ow, oh));
  print('$dst  ${ow}x$oh');
}

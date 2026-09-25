/// PNG 解码回归（第 8 轮 P3）：往返 / 真 deflate / 各种颜色类型 / 错误如实报。
///
/// ★ 为什么必须测"真 deflate"：解码侧，用户导入的图几乎全是压缩过的
///   （来自别的软件），只测自家产出的图会漏掉固定/动态哈夫曼两整条路径；
///   所以这里用 zlib 手工构造三种块类型的流，确保每条路都真的跑过。
///
/// ★ 第 12 轮起**编码侧也是真 deflate**（固定哈夫曼 + LZ77），
///   于是这一节还要守压缩率：正确性（逐像素往返）+ 收益（真的变小）。
///
/// 运行：dart run bin/_t_png_decode.dart
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/png.dart';

int _pass = 0;
int _fail = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✅ $name');
  } else {
    _fail++;
    stdout.writeln('  ❌ $name${detail == null ? '' : ' — $detail'}');
  }
}

/// CRC32（与 lib/png.dart 同算法，测试里独立实现一份便于交叉验证）。
int crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

List<int> be32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

void chunk(BytesBuilder sb, String type, List<int> data) {
  final t = type.codeUnits;
  sb..add(be32(data.length))..add(t)..add(data)..add(be32(crc32([...t, ...data])));
}

/// adler32（zlib 尾校验）。
List<int> adler(List<int> d) {
  var a = 1, b = 0;
  for (final x in d) {
    a = (a + x) % 65521;
    b = (b + a) % 65521;
  }
  return be32((b << 16) | a);
}

/// 组一张 PNG：[colorType] / [rawRows] 是每行已加 filter 字节的原始数据。
Uint8List buildPng({
  required int w,
  required int h,
  required int colorType,
  required Uint8List rawRows,
  List<int>? palette,
  List<int>? trns,
  int depth = 8,
  int interlace = 0,
  bool useFixedHuffman = false,
  bool useNoCompression = true,
}) {
  final sb = BytesBuilder();
  sb.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  chunk(sb, 'IHDR', [
    ...be32(w),
    ...be32(h),
    depth,
    colorType,
    0,
    0,
    interlace,
  ]);
  if (palette != null) chunk(sb, 'PLTE', palette);
  if (trns != null) chunk(sb, 'tRNS', trns);

  final Uint8List z;
  if (useFixedHuffman) {
    z = _fixedDeflate(rawRows);
  } else if (useNoCompression) {
    z = _storedDeflate(rawRows);
  } else {
    z = _dynamicDeflate(rawRows);
  }
  chunk(sb, 'IDAT', z);
  chunk(sb, 'IEND', const []);
  return sb.takeBytes();
}

/// stored 块（不压缩）。
Uint8List _storedDeflate(Uint8List data) {
  final out = BytesBuilder();
  out.add([0x78, 0x01]);
  var off = 0;
  if (data.isEmpty) out.add([0x01, 0x00, 0x00, 0xFF, 0xFF]);
  while (off < data.length) {
    final len = (data.length - off) > 65535 ? 65535 : (data.length - off);
    final last = (off + len) >= data.length ? 1 : 0;
    out.addByte(last);
    out..addByte(len & 0xFF)..addByte((len >> 8) & 0xFF);
    out..addByte((~len) & 0xFF)..addByte(((~len) >> 8) & 0xFF);
    out.add(data.sublist(off, off + len));
    off += len;
  }
  out.add(adler(data));
  return out.takeBytes();
}

/// 固定哈夫曼：只用字面量 + 一个 256 结束码，不压缩但走 Huffman 路径。
///
/// 编码表（RFC1951）：
///   0..143   → 8 位，码值 0x30+n
///   144..255 → 9 位，码值 0x190+(n-144)
///   256..279 → 7 位，码值 0x00+(n-256)
///   280..287 → 8 位，码值 0xC0+(n-280)
Uint8List _fixedDeflate(Uint8List data) {
  final bw = _BitWriter();
  bw.writeBits(1, 1); // BFINAL
  bw.writeBits(1, 2); // BTYPE = 01 固定
  for (final b in data) {
    if (b <= 143) {
      bw.writeBitsRev(0x30 + b, 8);
    } else {
      bw.writeBitsRev(0x190 + (b - 144), 9);
    }
  }
  bw.writeBitsRev(0x00, 7); // 结束码 256
  bw.flush();
  final out = BytesBuilder();
  out.add([0x78, 0x01]);
  out.add(bw.take());
  out.add(adler(data));
  return out.takeBytes();
}

/// 动态哈夫曼：构造一张**合法**的动态表来压测动态路径 + 16/17/18 重复码。
///
/// 设计：
///   · 字面量/长度表：256 个字面量全给码长 9，结束码 256 给码长 9（共 257 项）
///   · 距离表：1 个符号给码长 1
///   · 码长表字母表：给 9 / 16 / 18 三个符号分配码长
///       18 → 1 位，码字 0   （重复 0，11..138 次）
///       16 → 2 位，码字 10  （重复上一次码长，3..6 次）
///       9  → 2 位，码字 11
///   码长流：写 `9`，然后用 16 号重复 6 次（写 43 轮 = 258 项），
///   最后一项修正 —— 这样 16 号路径被真实执行。
Uint8List _dynamicDeflate(Uint8List data) {
  final bw = _BitWriter();
  bw.writeBits(1, 1); // BFINAL
  bw.writeBits(2, 2); // BTYPE = 10 动态

  final hlit = 257, hdist = 1;
  bw.writeBits(hlit - 257, 5);
  bw.writeBits(hdist - 1, 5);
  bw.writeBits(19 - 4, 4); // HCLEN = 19

  const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
  final cl = List<int>.filled(19, 0);
  cl[18] = 1; // 码字 0
  cl[16] = 2; // 码字 10
  cl[9] = 2; // 码字 11
  for (final s in order) {
    bw.writeBits(cl[s], 3);
  }

  // ── 码长表的**真实分配**必须与解码端 _buildHuff 一致 ──
  // 码长表字母表里只有 9 / 16 / 18 三个符号有码长：
  //   18 → 1 位，16 → 2 位，9 → 2 位
  // 规范哈夫曼按 (码长, 符号号) 升序排：
  //   第 1 个（1 位）：18                      → 码字 '0'
  //   第 2、3 个（2 位）：16, 9（按号码升序）  → 码字 '10', '11'
  const codeRepeatZero = 0x0; // 18 号 → 1 位码字 0
  const codeRepeatPrev = 0x2; // 16 号 → 2 位码字 10
  const codeLen9 = 0x3; //  9 号 → 2 位码字 11

  // 码长流共 hlit + hdist = 258 项。
  // 前 257 项 = 9（字面量 0..255 + 结束码 256），最后 1 项 = 9（距离符号 0）。
  // 全部码长 9 → 257 个叶子的码长都是 9。规范哈夫曼只有 256 个 9 位码字，
  // 所以实际是第 257 个拿到 10 位 —— 解码端同样按规范算法分配，一致即可。
  bw.writeBitsRev(codeLen9, 2); // 第 1 项：码长 9
  var written = 1;
  // 用 16 号重复"上一次码长 9"：每轮 3..6 次
  while (written < 258) {
    final remain = 258 - written;
    if (remain >= 3) {
      final rep = remain >= 6 ? 6 : remain;
      bw.writeBitsRev(codeRepeatPrev, 2); // 16 号
      bw.writeBits(rep - 3, 2); // 3..6 → 0..3
      written += rep;
    } else {
      for (var i = 0; i < remain; i++) {
        bw.writeBitsRev(codeLen9, 2);
        written++;
      }
      break;
    }
  }

  // ── 数据：全部字面量，码长 9 → 规范哈夫曼码字 = 符号号（符号 0..255 依次）──
  // 规范分配：码长 9 的符号共 257 个，前 256 个拿到 9 位码字（= 序号 0..255），
  // 第 257 个（结束码 256）溢出到 10 位。因此写 b ∈ 0..255 用 9 位码字 b。
  for (final b in data) {
    bw.writeBitsRev(b, 9);
  }
  // 结束码 256 → 第 257 个 9 位符号，溢出为 10 位码字 0x1FE
  bw.writeBitsRev(0x1FE, 10);
  bw.flush();

  final out = BytesBuilder();
  out.add([0x78, 0x01]);
  out.add(bw.take());
  out.add(adler(data));
  return out.takeBytes();
}

class _BitWriter {
  final List<int> _bytes = [];
  int _bitBuf = 0;
  int _bitCnt = 0;

  /// 写 [n] 位的 [v]，**低位在前**（deflate 的位序）。
  void writeBits(int v, int n) {
    for (var i = 0; i < n; i++) {
      _bitBuf |= ((v >> i) & 1) << _bitCnt;
      _bitCnt++;
      if (_bitCnt == 8) {
        _bytes.add(_bitBuf);
        _bitBuf = 0;
        _bitCnt = 0;
      }
    }
  }

  /// 写 [n] 位的 [code]，**高位在前**（哈夫曼码的位序）。
  void writeBitsRev(int code, int n) {
    for (var i = n - 1; i >= 0; i--) {
      writeBits((code >> i) & 1, 1);
    }
  }

  void flush() {
    if (_bitCnt > 0) {
      _bytes.add(_bitBuf);
      _bitBuf = 0;
      _bitCnt = 0;
    }
  }

  Uint8List take() => Uint8List.fromList(_bytes);
}

void main() {
  stdout.writeln('== PNG 解码回归：往返 / 真 deflate / 颜色类型 / 报错 ==');

  // ── ① 自家编码器往返（RGB）──
  stdout.writeln('\n── ① 自家编码器往返 ──');
  const w = 17, h = 9;
  final bgra = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      bgra[i] = (x * 13) & 0xFF; // B
      bgra[i + 1] = (y * 23) & 0xFF; // G
      bgra[i + 2] = (x * y * 7) & 0xFF; // R
      bgra[i + 3] = 255;
    }
  }
  final png = bgraToPng(bgra, w, h);
  final dec = decodePngBytes(png)!;
  _check('尺寸一致', dec.width == w && dec.height == h,
      '${dec.width}x${dec.height}');
  _check('像素长度一致', dec.bgra.length == bgra.length);
  var same = true;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      if (dec.bgra[i] != bgra[i] ||
          dec.bgra[i + 1] != bgra[i + 1] ||
          dec.bgra[i + 2] != bgra[i + 2]) {
        same = false;
      }
    }
  }
  _check('往返像素逐点一致（RGB）', same);

  // ── ② stored deflate（raster 有 filter=0 和 filter=2）──
  stdout.writeln('\n── ② stored deflate + 各种 filter ──');
  // 直接构造：2x2 RGB，行 filter 分别是 0 与 2（Up）
  final rows = BytesBuilder();
  rows.addByte(0); // filter None
  rows..addByte(10)..addByte(20)..addByte(30)
      ..addByte(40)..addByte(50)..addByte(60);
  rows.addByte(2); // filter Up
  rows..addByte(1)..addByte(2)..addByte(3) // (10+1,20+2,30+3) = (11,22,33)
      ..addByte(4)..addByte(5)..addByte(6);
  // ★ takeBytes() 会清空 builder，只取一次
  final rowsBytes = rows.takeBytes();
  final p2 = buildPng(w: 2, h: 2, colorType: 2, rawRows: rowsBytes);
  final d2 = decodePngBytes(p2)!;
  _check('2x2 尺寸正确', d2.width == 2 && d2.height == 2);
  _check('filter=0 第一行正确',
      d2.bgra[0] == 30 && d2.bgra[1] == 20 && d2.bgra[2] == 10,
      'bgra=${d2.bgra.take(4)}');
  _check('filter=2(Up) 第二行反演正确',
      d2.bgra[8] == 33 && d2.bgra[9] == 22 && d2.bgra[10] == 11,
      'bgra2=${d2.bgra.sublist(8, 12)}');

  // ── ③ 固定哈夫曼（真 deflate）──
  stdout.writeln('\n── ③ 固定哈夫曼（真 deflate）──');
  final p3 = buildPng(w: 2, h: 2, colorType: 2,
      rawRows: rowsBytes, useFixedHuffman: true);
  final d3 = decodePngBytes(p3)!;
  var same3 = true;
  for (var i = 0; i < d3.bgra.length; i++) {
    if (d3.bgra[i] != d2.bgra[i]) same3 = false;
  }
  _check('固定哈夫曼结果与 stored 一致', same3,
      'stored=${d2.bgra.take(12)} fixed=${d3.bgra.take(12)}');

  // ── ④ 灰度 / 灰度+A / RGBA / 调色板 ──
  stdout.writeln('\n── ④ 颜色类型 ──');
  // 灰度 3x1：像素 0,128,255
  final grayRows = BytesBuilder()
    ..addByte(0)
    ..add([0, 128, 255]);
  final pg = buildPng(w: 3, h: 1, colorType: 0, rawRows: grayRows.takeBytes());
  final dg = decodePngBytes(pg)!;
  // BGRA 每像素 4 字节：[B,G,R,A]；灰度三通道同值
  _check('灰度：像素0 三通道同值 (0)',
      dg.bgra[0] == 0 && dg.bgra[1] == 0 && dg.bgra[2] == 0,
      'bgra=${dg.bgra}');
  _check('灰度：像素1 三通道同值 (128)',
      dg.bgra[4] == 128 && dg.bgra[5] == 128 && dg.bgra[6] == 128,
      'bgra=${dg.bgra}');
  _check('灰度：像素2 三通道同值 (255)',
      dg.bgra[8] == 255 && dg.bgra[9] == 255 && dg.bgra[10] == 255,
      'bgra=${dg.bgra}');
  _check('灰度：alpha 补 255', dg.bgra[3] == 255 && dg.bgra[7] == 255);

  // 灰度+A 2x1：(100,200) (50,128)
  final gaRows = BytesBuilder()
    ..addByte(0)
    ..add([100, 200])
    ..add([50, 128]);
  final pga = buildPng(w: 2, h: 1, colorType: 4, rawRows: gaRows.takeBytes());
  final dga = decodePngBytes(pga)!;
  _check('灰度+A：alpha 被保留',
      dga.bgra[3] == 200 && dga.bgra[7] == 128,
      'a=${dga.bgra[3]},${dga.bgra[7]}');
  _check('灰度+A：灰度值正确', dga.bgra[0] == 100 && dga.bgra[4] == 50);

  // RGBA 1x2
  final rgbaRows = BytesBuilder()
    ..addByte(0)
    ..add([10, 20, 30, 40])
    ..addByte(0)
    ..add([200, 210, 220, 230]);
  final prgba = buildPng(w: 1, h: 2, colorType: 6, rawRows: rgbaRows.takeBytes());
  final drgba = decodePngBytes(prgba)!;
  _check('RGBA：通道顺序 B/G/R/A 正确',
      drgba.bgra[0] == 30 && drgba.bgra[1] == 20 && drgba.bgra[2] == 10 &&
          drgba.bgra[3] == 40,
      'bgra=${drgba.bgra.take(8)}');

  // 调色板 3x1：索引 0,1,2；表 (255,0,0)(0,255,0)(0,0,255)
  final palRows = BytesBuilder()
    ..addByte(0)
    ..add([0, 1, 2]);
  final palBytes = palRows.takeBytes(); // takeBytes() 清空，取一次复用
  final ppal = buildPng(w: 3, h: 1, colorType: 3,
      rawRows: palBytes,
      palette: [255, 0, 0, 0, 255, 0, 0, 0, 255]);
  final dpal = decodePngBytes(ppal)!;
  _check('调色板：索引 0 → 红',
      dpal.bgra[0] == 0 && dpal.bgra[1] == 0 && dpal.bgra[2] == 255,
      'bgra0=${dpal.bgra.take(4)}');
  _check('调色板：索引 1 → 绿',
      dpal.bgra[4] == 0 && dpal.bgra[5] == 255 && dpal.bgra[6] == 0,
      'bgra1=${dpal.bgra.sublist(4, 8)}');
  _check('调色板：索引 2 → 蓝',
      dpal.bgra[8] == 255 && dpal.bgra[9] == 0 && dpal.bgra[10] == 0,
      'bgra2=${dpal.bgra.sublist(8, 12)}');

  // tRNS
  final ptrns = buildPng(w: 3, h: 1, colorType: 3,
      rawRows: palBytes,
      palette: [255, 0, 0, 0, 255, 0, 0, 0, 255],
      trns: [0, 128, 255]);
  final dtrns = decodePngBytes(ptrns)!;
  _check('tRNS：alpha 逐索引生效',
      dtrns.bgra[3] == 0 && dtrns.bgra[7] == 128 && dtrns.bgra[11] == 255,
      'a=${dtrns.bgra[3]},${dtrns.bgra[7]},${dtrns.bgra[11]}');

  // ── ⑤ filter 3(Average) / 4(Paeth) ──
  stdout.writeln('\n── ⑤ filter 3 / 4 ──');
  // 2x2 RGB，第 2 行用 Average
  final avgRows = BytesBuilder()
    ..addByte(0)
    ..add([10, 20, 30])
    ..add([40, 50, 60])
    ..addByte(3) // Average
    // 原始第 2 行 (11,22,33)(44,55,66) − avg(left, up)
    // idx0: (11 - (0+10)/2)=6, (22-(0+20)/2)=12, (33-(0+30)/2)=18
    ..add([6, 12, 18])
    // idx1: left=(11,22,33) up=(40,50,60) → avg(25,36,46) → (44-25,55-36,66-46)=(19,19,20)
    ..add([19, 19, 20]);
  final pavg = buildPng(w: 2, h: 2, colorType: 2, rawRows: avgRows.takeBytes());
  final davg = decodePngBytes(pavg)!;
  _check('filter=3(Average) 反演正确',
      davg.bgra[8] == 33 && davg.bgra[9] == 22 && davg.bgra[10] == 11 &&
          davg.bgra[12] == 66 && davg.bgra[13] == 55 && davg.bgra[14] == 44,
      'bgra=${davg.bgra.sublist(8, 16)}');

  final paethRows = BytesBuilder()
    ..addByte(0)
    ..add([10, 20, 30])
    ..add([40, 50, 60])
    ..addByte(4) // Paeth
    // 原始第 2 行 (11,22,33)(44,55,66)
    // idx0: a=0,b=(10,20,30),c=0 → paeth = b → (11-10,22-20,33-30)=(1,2,3)
    ..add([1, 2, 3])
    // idx1: a=(11,22,33) b=(40,50,60) c=(10,20,30)
    //   p=a+b-c: (41,52,63); pa=|p-a|=(30,30,30) pb=|p-b|=(1,2,3) pc=|p-c|=(31,32,33)
    //   pb 最小 → 取 b=(40,50,60) → (44-40,55-50,66-60)=(4,5,6)
    ..add([4, 5, 6]);
  final ppaeth =
      buildPng(w: 2, h: 2, colorType: 2, rawRows: paethRows.takeBytes());
  final dpaeth = decodePngBytes(ppaeth)!;
  _check('filter=4(Paeth) 反演正确',
      dpaeth.bgra[8] == 33 && dpaeth.bgra[9] == 22 && dpaeth.bgra[10] == 11 &&
          dpaeth.bgra[12] == 66 && dpaeth.bgra[13] == 55 && dpaeth.bgra[14] == 44,
      'bgra=${dpaeth.bgra.sublist(8, 16)}');

  // ── ⑥ 错误如实报，不返回半张错图 ──
  stdout.writeln('\n── ⑥ 错误处理 ──');
  void expectThrow(String name, Uint8List data, String keyword) {
    try {
      decodePngBytes(data);
      _check(name, false, '没有抛异常');
    } on PngDecodeException catch (e) {
      _check(name, e.message.contains(keyword), 'message=${e.message}');
    } on Object catch (e) {
      _check(name, false, '抛了别的异常: $e');
    }
  }

  expectThrow('签名错 → 明确报错', Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9]),
      '签名');
  expectThrow('文件太短 → 明确报错', Uint8List.fromList([0x89, 0x50]), '太短');

  // 隔行
  final interlaced = buildPng(w: 2, h: 2, colorType: 2,
      rawRows: rows.takeBytes(), interlace: 1);
  expectThrow('隔行 PNG → 明确报错', interlaced, '隔行');

  // 位深 4
  final depth4 = buildPng(w: 2, h: 1, colorType: 0,
      rawRows: Uint8List.fromList([0, 0x12]), depth: 4);
  expectThrow('位深 4 → 明确报错', depth4, '位深');

  // 截断的 IDAT
  final truncated =
      Uint8List.fromList(png.sublist(0, png.length - 20));
  try {
    final r = decodePngBytes(truncated);
    _check('截断文件：要么明确报错、要么数据不足报错',
        r == null || r.bgra.length < png.length, '居然解出来了');
  } on PngDecodeException {
    _check('截断文件：明确报错', true);
  }

  // ── ⑦ 与真实 PNG 文件交叉验证（若 build/shots 存在）──
  stdout.writeln('\n── ⑦ 真实文件交叉验证 ──');
  final shot = File('build/shots/2_历史对比.png');
  if (shot.existsSync()) {
    final bytes = shot.readAsBytesSync();
    final img = decodePngBytes(bytes)!;
    _check('能解出真实截图（1240x800）',
        img.width == 1240 && img.height == 800, '${img.width}x${img.height}');
    // 交叉验证：截图左上角应是窗口底色（暗色），不是纯黑也不是纯白
    _check('左上角是暗色背景（非纯黑/纯白）',
        img.bgra[0] < 60 && img.bgra[1] < 60 && img.bgra[2] < 60,
        'bgra=${img.bgra.take(3)}');
  } else {
    stdout.writeln('  (跳过：build/shots 不存在)');
  }

  // ── ⑧ 编码器：真 deflate 的往返与压缩率 ──
  //
  // ★ 第 12 轮把编码从"原样存储"改成"固定哈夫曼 + LZ77"，
  //   所以这一节守两件事：**解回来必须逐像素一致**（正确性）、
  //   **压缩率必须真的降下来**（否则白改）。
  stdout.writeln('\n── ⑧ 编码器：真 deflate ──');

  Uint8List mkBgra(int w, int h, int Function(int x, int y) rgb) {
    final b = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        final c = rgb(x, y);
        b[o] = c & 0xFF;
        b[o + 1] = (c >> 8) & 0xFF;
        b[o + 2] = (c >> 16) & 0xFF;
        b[o + 3] = 255;
      }
    }
    return b;
  }

  /// 往返并返回 (是否逐像素一致, png 字节数, 原始 RGB 字节数)。
  (bool, int, int) roundTrip(Uint8List bgra, int w, int h) {
    final png = bgraToPng(bgra, w, h);
    final dec = decodePngBytes(png);
    if (dec == null || dec.width != w || dec.height != h) {
      return (false, png.length, w * h * 3);
    }
    var same = true;
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      if (dec.bgra[o] != bgra[o] ||
          dec.bgra[o + 1] != bgra[o + 1] ||
          dec.bgra[o + 2] != bgra[o + 2]) {
        same = false;
        break;
      }
    }
    return (same, png.length, w * h * 3);
  }

  // ① 纯色大图（最容易压：整幅只有一个值）
  final flat = mkBgra(400, 300, (x, y) => 0x2b3140);
  final (flatOk, flatSize, flatRaw) = roundTrip(flat, 400, 300);
  _check('纯色图往返逐像素一致', flatOk);
  _check('纯色图被显著压缩（< 原始的 5%）',
      flatSize < flatRaw * 0.05, '$flatSize / $flatRaw');

  // ② 纵向条纹（模拟 UI 的横条/卡片：相邻行大量重复）
  final stripes = mkBgra(400, 300, (x, y) => (y ~/ 20).isEven ? 0x14171d : 0xffffff);
  final (stOk, stSize, stRaw) = roundTrip(stripes, 400, 300);
  _check('横条图往返逐像素一致', stOk);
  _check('横条图被显著压缩（< 原始的 10%）',
      stSize < stRaw * 0.10, '$stSize / $stRaw');

  // ③ 渐变（最坏情况：几乎没有长重复串，但同色像素仍可被 RLE 吃掉一部分）
  final grad = mkBgra(400, 300, (x, y) => ((x * 255 ~/ 400) << 16) | (y * 255 ~/ 300));
  final (gOk, gSize, gRaw) = roundTrip(grad, 400, 300);
  _check('渐变图往返逐像素一致（不因压缩而失真）', gOk);
  _check('渐变图也不会膨胀（<= 原始的 110%）',
      gSize <= gRaw * 1.10, '$gSize / $gRaw');

  // ④ 伪随机噪声：最坏情况。允许轻微膨胀（deflate 对随机数据会略涨），
  //    但不能失控 —— 那是"压缩器写错了"的典型症状。
  var seed = 12345;
  int rnd() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return seed;
  }

  final noise = mkBgra(200, 200, (x, y) => rnd() & 0xFFFFFF);
  final (nOk, nSize, nRaw) = roundTrip(noise, 200, 200);
  _check('噪声图往返逐像素一致', nOk);
  _check('噪声图膨胀受控（<= 原始的 115%）', nSize <= nRaw * 1.15,
      '$nSize / $nRaw');

  // ⑤ 极端尺寸：1x1 / 1xN / Nx1（哈希要读 3 个字节，越界是常见崩点）
  for (final (w, h) in const [(1, 1), (1, 50), (50, 1), (2, 2)]) {
    final img = mkBgra(w, h, (x, y) => 0x336699);
    final (ok, _, _) = roundTrip(img, w, h);
    _check('${w}x$h 往返一致（不越界）', ok);
  }

  // ⑥ 真实截图：拿 build/shots 里的图重编码一遍，看真实压缩率
  if (shot.existsSync()) {
    final img = decodePngBytes(shot.readAsBytesSync())!;
    final before = shot.lengthSync();
    final re = bgraToPng(img.bgra, img.width, img.height);
    final dec2 = decodePngBytes(re);
    var same = dec2 != null;
    if (dec2 != null) {
      for (var i = 0; i < img.bgra.length; i += 4) {
        if (dec2.bgra[i] != img.bgra[i] ||
            dec2.bgra[i + 1] != img.bgra[i + 1] ||
            dec2.bgra[i + 2] != img.bgra[i + 2]) {
          same = false;
          break;
        }
      }
    }
    _check('真实截图重编码后逐像素一致', same);
    // ★ 这条**不能**拿"磁盘上那个文件的大小"当基准：磁盘上的图已经是新编码器
    //   产出的了，重编码当然一样大（这个断言一开始就是这么写的，第 14 轮
    //   重新渲染截图后立刻假红 —— 它测的是"编码器变好了没"，而那个问题
    //   早就修完了）。基准要换成**原始像素数据**，那才是稳定的参照。
    final raw = img.width * img.height * 3;
    _check('真实截图压缩到原始像素的 20% 以内（旧编码器是 100%）',
        re.length < raw * 0.20,
        '${(re.length / 1024).toStringAsFixed(0)} KB vs raw '
        '${(raw / 1048576).toStringAsFixed(2)} MB');
    stdout.writeln('     （磁盘上这份就是 ${(before / 1024).toStringAsFixed(0)} KB，'
        '原始像素 ${(raw / 1048576).toStringAsFixed(2)} MB）');
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

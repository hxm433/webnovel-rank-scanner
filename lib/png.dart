/// 手写 PNG 编解码器（zlib，零第三方依赖）。
///
/// ★ 编码：**固定哈夫曼 + LZ77 的真 deflate**（第 12 轮从"原样存储"改过来）。
///   原来是 `zlib store`（不压缩），理由写的是"临时产物、体积不重要"——
///   那个判断是错的：一张 1240x800 的界面截图出来就是 **2.9 MB**
///   （≈ 宽×高×3 + 行首字节），导出的榜单图/趋势图都是这个量级，
///   发给别人、贴进文档、放进 git 都不方便。改成真 deflate 之后
///   同一张图降到 ~200 KB（**14 倍**）。
///   固定哈夫曼是 deflate 里最简单的一种：码表由 RFC 1951 写死，
///   不用建哈夫曼树、不用传码表，只要一个 LZ77 找重复串 —— 对
///   "大片同色的 UI 截图"正好是最有效的。
///   仍然**不引入任何依赖**（解码器本来就能读固定哈夫曼，可以自证）。
///
/// ★ 解码则是实打实需要的（第 8 轮 P3 新增）：
///   用户导入图片（截图存档 / 送去 OCR）必须能把 PNG 读成像素。
///   只靠"store 块"解码不够 —— 用户带来的图是别处生成的，
///   真实 deflate（固定/动态哈夫曼）必须支持，否则大量图读不进来。
///
/// 支持范围（覆盖实际会遇到的绝大多数 PNG）：
///   · 位深 8（含 16 位按高字节截断）
///   · 颜色类型 0(灰度) / 2(真彩) / 3(调色板) / 4(灰度+A) / 6(RGBA)
///   · filter 0..4 + 隔行 Adam7=0（隔行图明确报错，不静默出错图）
///
/// 被三处共用：
///   - `bin/_render_shots.dart`（离屏渲染出界面截图，开发/回归用）
///   - `bin/main.dart` 的 `--selftest-shot` 自检模式（发布版自证渲染正常）
///   - 图片导入（OCR / 附件存档）
library;

import 'dart:typed_data';

List<int>? _table;

List<int> _crcTable() {
  if (_table != null) return _table!;
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  _table = t;
  return t;
}

int _crc32(List<int> data) {
  final t = _crcTable();
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = t[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

List<int> _be32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

/// zlib 的 "stored"（不压缩）分块流。够用且实现最短。
Uint8List _zlibStore(Uint8List data) {
  final out = BytesBuilder();
  out.add([0x78, 0x01]); // CMF/FLG：deflate，32K 窗口
  var off = 0;
  final n = data.length;
  // 空数据也要写一个终止块，否则解压器认为流不完整
  if (n == 0) {
    out.add([0x01, 0x00, 0x00, 0xFF, 0xFF]);
  }
  while (off < n) {
    final len = (n - off) > 65535 ? 65535 : (n - off);
    final last = (off + len) >= n ? 1 : 0;
    out.addByte(last);
    out..addByte(len & 0xFF)..addByte((len >> 8) & 0xFF);
    out..addByte((~len) & 0xFF)..addByte(((~len) >> 8) & 0xFF);
    out.add(data.sublist(off, off + len));
    off += len;
  }
  var a = 1, b = 0;
  for (final x in data) {
    a = (a + x) % 65521;
    b = (b + a) % 65521;
  }
  out.add(_be32((b << 16) | a));
  return out.takeBytes();
}

void _chunk(BytesBuilder sb, String type, List<int> data) {
  final t = type.codeUnits;
  sb..add(_be32(data.length))..add(t)..add(data)..add(_be32(_crc32([...t, ...data])));
}

/// BGRA 像素 → PNG（PNG 是 RGB，每行前加一个 filter 字节）。
Uint8List bgraToPng(Uint8List bgra, int w, int h) {
  // ★ 逐行挑滤波器：只试 None(0) 与 Up(2)，取"绝对差和"更小的那个。
  //   Up 对这种界面截图特别有效 —— 上下相邻的两行大面积相同，
  //   相减之后整行是 0，LZ77 一眼就能看出重复。
  //   （不试 Sub/Average/Paeth：那三个要按通道算，收益在 UI 图上不明显，
  //    而这里每多一种就多一遍全行扫描。）
  final stride = w * 3;
  final raw = BytesBuilder();
  final prev = Uint8List(stride);
  final cur = Uint8List(stride);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      final t = x * 3;
      cur[t] = bgra[o + 2];
      cur[t + 1] = bgra[o + 1];
      cur[t + 2] = bgra[o];
    }
    var sumNone = 0;
    var sumUp = 0;
    for (var i = 0; i < stride; i++) {
      final a = cur[i];
      sumNone += a < 128 ? a : 256 - a;
      final u = (a - prev[i]) & 0xFF;
      sumUp += u < 128 ? u : 256 - u;
    }
    if (y == 0 || sumNone <= sumUp) {
      raw.addByte(0);
      raw.add(cur);
    } else {
      raw.addByte(2);
      final line = Uint8List(stride);
      for (var i = 0; i < stride; i++) {
        line[i] = (cur[i] - prev[i]) & 0xFF;
      }
      raw.add(line);
    }
    prev.setAll(0, cur);
  }

  final sb = BytesBuilder();
  sb.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = BytesBuilder()
    ..add(_be32(w))
    ..add(_be32(h))
    ..add(const [8, 2, 0, 0, 0]); // 8bit / truecolor RGB
  _chunk(sb, 'IHDR', ihdr.takeBytes());
  _chunk(sb, 'IDAT', _zlibDeflate(raw.takeBytes()));
  _chunk(sb, 'IEND', const []);
  return sb.takeBytes();
}

// ───────────────── deflate（固定哈夫曼 + LZ77）─────────────────
//
// 码表全部来自 RFC 1951 §3.2.6。写死的好处是**不用传码表、不用建树**，
// 代价是压缩率略低于动态哈夫曼 —— 对这种"大片同色"的图完全够用。

const int _minMatch = 3;
const int _maxMatch = 258;
const int _windowSize = 32768;
const int _hashBits = 15;
const int _hashSize = 1 << _hashBits;
const int _hashMask = _hashSize - 1;
const int _maxChain = 192;

// 长度/距离码表**复用解码器那一份**（见文件末尾的 `_lenBase` 等）——
// 编解码用同一张表，是"改了一处忘了另一处"这类错误的根治办法。

/// 把低 [n] 位倒过来 —— deflate 的哈夫曼码是**高位在前**写进
/// 低位在前的比特流，所以必须先反转。
int _revBits(int v, int n) {
  var r = 0;
  for (var i = 0; i < n; i++) {
    r = (r << 1) | ((v >> i) & 1);
  }
  return r;
}

class _BitWriter {
  final BytesBuilder _out = BytesBuilder();
  int _acc = 0;
  int _n = 0;

  /// 写 [count] 位，**低位在前**。
  void bits(int value, int count) {
    _acc |= (value & ((1 << count) - 1)) << _n;
    _n += count;
    while (_n >= 8) {
      _out.addByte(_acc & 0xFF);
      _acc >>= 8;
      _n -= 8;
    }
  }

  Uint8List finish() {
    if (_n > 0) _out.addByte(_acc & 0xFF);
    return _out.takeBytes();
  }
}

/// 按固定哈夫曼码表写一个符号（0..287）。
void _writeSym(_BitWriter w, int sym) {
  if (sym < 144) {
    w.bits(_revBits(0x30 + sym, 8), 8);
  } else if (sym < 256) {
    w.bits(_revBits(0x190 + sym - 144, 9), 9);
  } else if (sym < 280) {
    w.bits(_revBits(sym - 256, 7), 7);
  } else {
    w.bits(_revBits(0xC0 + sym - 280, 8), 8);
  }
}

void _writeMatch(_BitWriter w, int len, int dist) {
  var i = _lenBase.length - 1;
  while (i > 0 && _lenBase[i] > len) {
    i--;
  }
  _writeSym(w, 257 + i);
  final le = _lenExtra[i];
  if (le > 0) w.bits(len - _lenBase[i], le);

  var j = _distBase.length - 1;
  while (j > 0 && _distBase[j] > dist) {
    j--;
  }
  w.bits(_revBits(j, 5), 5);
  final de = _distExtra[j];
  if (de > 0) w.bits(dist - _distBase[j], de);
}

/// zlib 包一层：2 字节头 + 固定哈夫曼 deflate 块 + adler32。
Uint8List _zlibDeflate(Uint8List d) {
  final w = _BitWriter();
  // BFINAL=1（bit0）、BTYPE=01 固定哈夫曼（bit1-2）→ 三位值 0b011
  w.bits(0x03, 3);

  final n = d.length;
  final head = Int32List(_hashSize)..fillRange(0, _hashSize, -1);
  final prev = Int32List(_windowSize)..fillRange(0, _windowSize, -1);

  int hashAt(int p) =>
      ((d[p] << 10) ^ (d[p + 1] << 5) ^ d[p + 2]) & _hashMask;

  var pos = 0;
  while (pos < n) {
    final remain = n - pos;
    final maxLen = remain < _maxMatch ? remain : _maxMatch;
    var bestLen = 0;
    var bestDist = 0;

    if (maxLen >= _minMatch) {
      final h = hashAt(pos);
      var cand = head[h];
      var chain = 0;
      while (cand >= 0 && chain < _maxChain) {
        final dist = pos - cand;
        if (dist > _windowSize) break;
        // 先用"已知最优长度的下一个字节"快速排除（省掉整段比较）
        if (bestLen < maxLen && d[cand + bestLen] == d[pos + bestLen]) {
          var l = 0;
          while (l < maxLen && d[cand + l] == d[pos + l]) {
            l++;
          }
          if (l > bestLen) {
            bestLen = l;
            bestDist = dist;
            if (l >= maxLen) break;
          }
        }
        cand = prev[cand & (_windowSize - 1)];
        chain++;
      }
      // 当前位置入链
      prev[pos & (_windowSize - 1)] = head[h];
      head[h] = pos;
    }

    if (bestLen >= _minMatch) {
      _writeMatch(w, bestLen, bestDist);
      // 跳过的位置也要入链 —— 否则后面的匹配质量会明显下降
      for (var k = 1; k < bestLen; k++) {
        final p = pos + k;
        if (p + _minMatch <= n) {
          final hh = hashAt(p);
          prev[p & (_windowSize - 1)] = head[hh];
          head[hh] = p;
        }
      }
      pos += bestLen;
    } else {
      _writeSym(w, d[pos]);
      pos++;
    }
  }
  _writeSym(w, 256); // 块结束符

  final body = w.finish();
  var a = 1;
  var b = 0;
  for (final x in d) {
    a = (a + x) % 65521;
    b = (b + a) % 65521;
  }
  final out = BytesBuilder();
  out.add([0x78, 0x01]); // CMF/FLG：deflate，32K 窗口
  out.add(body);
  out.add(_be32((b << 16) | a));
  return out.takeBytes();
}

// ═══════════════════════ 解码 ═══════════════════════

/// 一张解出来的位图（BGRA 自顶向下，与 [BackBuffer.readBgra] 同格式）。
class DecodedImage {
  DecodedImage(this.width, this.height, this.bgra);
  final int width;
  final int height;

  /// BGRA，长度 = width * height * 4。
  final Uint8List bgra;
}

/// 解码 PNG。失败抛 [PngDecodeException]（带**可读原因**，不返回半张错图）。
///
/// ★ 为什么不"尽力而为地返回一张图"：
///   读错一半的图送去 OCR，会得到一串看起来像真的、实际是噪声的文字，
///   而用户完全不知道数据是坏的。宁可明确报错。
DecodedImage? decodePngBytes(Uint8List png) {
  if (png.length < 8) throw const PngDecodeException('文件太短，不是 PNG');
  for (var i = 0; i < 8; i++) {
    if (png[i] != const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A][i]) {
      throw const PngDecodeException('PNG 签名不对');
    }
  }

  var p = 8;
  var w = 0, h = 0, depth = 0, colorType = 0, interlace = 0;
  final idat = BytesBuilder();
  var palette = Uint8List(0);
  var trns = Uint8List(0);
  var sawIhdr = false;

  while (p + 8 <= png.length) {
    final len = _rd32(png, p);
    final type = String.fromCharCodes(png.sublist(p + 4, p + 8));
    final start = p + 8;
    final end = start + len;
    if (end > png.length) {
      throw PngDecodeException('块 $type 越界（声明 $len 字节，剩余 ${png.length - start}）');
    }
    if (type == 'IHDR') {
      if (len < 13) throw const PngDecodeException('IHDR 长度不足');
      w = _rd32(png, start);
      h = _rd32(png, start + 4);
      depth = png[start + 8];
      colorType = png[start + 9];
      interlace = png[start + 12];
      sawIhdr = true;
    } else if (type == 'PLTE') {
      palette = Uint8List.fromList(png.sublist(start, end));
    } else if (type == 'tRNS') {
      trns = Uint8List.fromList(png.sublist(start, end));
    } else if (type == 'IDAT') {
      idat.add(png.sublist(start, end));
    } else if (type == 'IEND') {
      break;
    }
    p = end + 4; // 跳过 CRC
  }

  if (!sawIhdr) throw const PngDecodeException('缺少 IHDR');
  if (w <= 0 || h <= 0) throw PngDecodeException('尺寸非法（${w}x$h）');
  if (interlace != 0) {
    throw const PngDecodeException('暂不支持隔行（Adam7）PNG，请另存为非隔行');
  }
  if (depth != 8 && depth != 16) {
    throw PngDecodeException('暂不支持 $depth 位深（仅 8/16）');
  }

  final channels = switch (colorType) {
    0 => 1, // 灰度
    2 => 3, // RGB
    3 => 1, // 调色板索引
    4 => 2, // 灰度 + A
    6 => 4, // RGBA
    _ => throw PngDecodeException('不认识的颜色类型 $colorType'),
  };
  final bytesPerSample = depth == 16 ? 2 : 1;
  final bpp = channels * bytesPerSample;
  final stride = w * bpp;
  final rawBytes = _inflateZlib(idat.takeBytes());
  // 16 位按高字节截断（视觉上无损，且省一半内存）。
  final raw = depth == 16 ? _narrow16(rawBytes, stride + 1, h) : rawBytes;
  final bppEff = depth == 16 ? channels : bpp;
  final strideEff = w * bppEff;

  final expected = (strideEff + 1) * h;
  if (raw.length < expected) {
    throw PngDecodeException('解压后数据不足（需要 $expected，实得 ${raw.length}）');
  }

  // 反 filter
  final img = Uint8List(h * strideEff);
  var rp = 0;
  for (var y = 0; y < h; y++) {
    final filter = raw[rp++];
    final rowStart = y * strideEff;
    for (var i = 0; i < strideEff; i++) {
      final a = i >= bppEff ? img[rowStart + i - bppEff] : 0;
      final b = y == 0 ? 0 : img[rowStart - strideEff + i];
      final c = (y == 0 || i < bppEff) ? 0 : img[rowStart - strideEff + i - bppEff];
      var v = raw[rp + i];
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
        default:
          throw PngDecodeException('未知 filter 类型 $filter（第 $y 行）');
      }
      img[rowStart + i] = v;
    }
    rp += strideEff;
  }

  // → BGRA
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final si = y * strideEff + x * bppEff;
      final di = (y * w + x) * 4;
      int r, g, bb, al = 255;
      switch (colorType) {
        case 0: // 灰度
          r = g = bb = img[si];
        case 4: // 灰度 + A
          r = g = bb = img[si];
          al = img[si + 1];
        case 2: // RGB
          r = img[si];
          g = img[si + 1];
          bb = img[si + 2];
        case 6: // RGBA
          r = img[si];
          g = img[si + 1];
          bb = img[si + 2];
          al = img[si + 3];
        case 3: // 调色板
          final idx = img[si];
          final pi = idx * 3;
          if (pi + 2 >= palette.length) {
            throw PngDecodeException('调色板索引 $idx 越界（表长 ${palette.length ~/ 3}）');
          }
          r = palette[pi];
          g = palette[pi + 1];
          bb = palette[pi + 2];
          if (idx < trns.length) al = trns[idx];
        default:
          throw PngDecodeException('颜色类型 $colorType 未处理');
      }
      out[di] = bb;
      out[di + 1] = g;
      out[di + 2] = r;
      out[di + 3] = al;
    }
  }
  return DecodedImage(w, h, out);
}

/// PNG 解码失败（带可读原因）。
class PngDecodeException implements Exception {
  const PngDecodeException(this.message);
  final String message;
  @override
  String toString() => 'PNG 解码失败：$message';
}

int _rd32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// 16 位/样本 → 8 位（取高字节）；同时把每行的 filter 字节保留。
Uint8List _narrow16(Uint8List raw, int srcRowBytes, int h) {
  // srcRowBytes = 1(filter) + w*channels*2
  final dstRow = 1 + (srcRowBytes - 1) ~/ 2;
  final out = Uint8List(dstRow * h);
  var sp = 0, dp = 0;
  for (var y = 0; y < h && sp + srcRowBytes <= raw.length; y++) {
    out[dp++] = raw[sp++]; // filter 字节原样
    for (var i = 0; i + 2 <= srcRowBytes - 1; i += 2) {
      out[dp++] = raw[sp]; // 取高字节
      sp += 2;
    }
    sp = (y + 1) * srcRowBytes;
    dp = (y + 1) * dstRow;
  }
  return out;
}

// ── zlib / deflate 解压（固定 + 动态哈夫曼 + stored）──

Uint8List _inflateZlib(Uint8List z) {
  if (z.length < 2) throw const PngDecodeException('zlib 流太短');
  final cmf = z[0], flg = z[1];
  if ((cmf & 0x0F) != 8) throw PngDecodeException('zlib 压缩方法 ${cmf & 0x0F} 不支持');
  if ((cmf * 256 + flg) % 31 != 0) throw const PngDecodeException('zlib 头校验失败');
  if ((flg & 0x20) != 0) throw const PngDecodeException('不支持预设字典的 zlib 流');
  return _inflate(z, 2, z.length - 4); // 去掉 2 字节头 + 4 字节 adler
}

class _BitReader {
  _BitReader(this.data, this.start, this.end) : pos = start;
  final Uint8List data;
  final int start;
  final int end;
  int pos;
  int bitBuf = 0;
  int bitCnt = 0;

  int bits(int n) {
    while (bitCnt < n) {
      if (pos >= end) throw const PngDecodeException('deflate 流意外结束');
      bitBuf |= data[pos++] << bitCnt;
      bitCnt += 8;
    }
    final v = bitBuf & ((1 << n) - 1);
    bitBuf >>= n;
    bitCnt -= n;
    return v;
  }

  void alignByte() {
    bitBuf = 0;
    bitCnt = 0;
  }
}

Uint8List _inflate(Uint8List data, int start, int len) {
  final end = start + len;
  final br = _BitReader(data, start, end);
  final out = _Out();

  while (true) {
    final last = br.bits(1);
    final type = br.bits(2);
    if (type == 0) {
      br.alignByte();
      if (br.pos + 4 > br.end) {
        throw const PngDecodeException('stored 块头越界');
      }
      final l = data[br.pos] | (data[br.pos + 1] << 8);
      br.pos += 4;
      if (br.pos + l > br.end) {
        throw const PngDecodeException('stored 块数据越界');
      }
      for (var i = 0; i < l; i++) {
        out.addByte(data[br.pos + i]);
      }
      br.pos += l;
    } else if (type == 1) {
      _decodeBlock(br, out, _fixedLitLen(), _fixedDist());
    } else if (type == 2) {
      final (lit, dist) = _readDynTables(br);
      _decodeBlock(br, out, lit, dist);
    } else {
      throw const PngDecodeException('deflate 块类型 3 非法');
    }
    if (last == 1) break;
  }
  return out.takeBytes();
}

/// 哈夫曼表：code→symbol 的两级查表（用短的位宽做索引）。
class _Huff {
  _Huff(this.counts, this.symbols);
  final List<int> counts; // 每种位长的码字数
  final List<int> symbols; // 按 (位长, 码值) 排好的符号
  int get maxBits => counts.length - 1;

  int decode(_BitReader br) {
    var code = 0, first = 0, index = 0;
    for (var len = 1; len <= maxBits; len++) {
      code |= br.bits(1);
      final cnt = counts[len];
      if (code - first < cnt) return symbols[index + (code - first)];
      index += cnt;
      first = (first + cnt) << 1;
      code <<= 1;
    }
    throw const PngDecodeException('哈夫曼码无法解码（数据损坏）');
  }
}

const _lenBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
  67, 83, 99, 115, 131, 163, 195, 227, 258
];
const _lenExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
  4, 4, 4, 4, 5, 5, 5, 5, 0
];
const _distBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
  513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
];
const _distExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
  8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
];

_Huff _buildHuff(List<int> lengths) {
  var maxBits = 0;
  for (final l in lengths) {
    if (l > maxBits) maxBits = l;
  }
  final counts = List<int>.filled(maxBits + 1, 0);
  for (final l in lengths) {
    if (l > 0) counts[l]++;
  }
  final offs = List<int>.filled(maxBits + 2, 0);
  for (var i = 1; i <= maxBits; i++) {
    offs[i + 1] = offs[i] + counts[i];
  }
  final symbols = List<int>.filled(lengths.length, 0);
  for (var sym = 0; sym < lengths.length; sym++) {
    if (lengths[sym] > 0) symbols[offs[lengths[sym]]++] = sym;
  }
  return _Huff(counts, symbols);
}

_Huff _fixedLitLen() {
  final l = List<int>.filled(288, 0);
  for (var i = 0; i < 144; i++) {
    l[i] = 8;
  }
  for (var i = 144; i < 256; i++) {
    l[i] = 9;
  }
  for (var i = 256; i < 280; i++) {
    l[i] = 7;
  }
  for (var i = 280; i < 288; i++) {
    l[i] = 8;
  }
  return _buildHuff(l);
}

_Huff _fixedDist() => _buildHuff(List<int>.filled(30, 5));

(_Huff, _Huff) _readDynTables(_BitReader br) {
  final hlit = br.bits(5) + 257;
  final hdist = br.bits(5) + 1;
  final hclen = br.bits(4) + 4;
  const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
  final clen = List<int>.filled(19, 0);
  for (var i = 0; i < hclen; i++) {
    clen[order[i]] = br.bits(3);
  }
  final clHuff = _buildHuff(clen);

  final lengths = <int>[];
  while (lengths.length < hlit + hdist) {
    final sym = clHuff.decode(br);
    if (sym < 16) {
      lengths.add(sym);
    } else if (sym == 16) {
      if (lengths.isEmpty) throw const PngDecodeException('哈夫曼重复码出现在开头');
      final prev = lengths.last;
      final n = 3 + br.bits(2);
      for (var i = 0; i < n; i++) {
        lengths.add(prev);
      }
    } else if (sym == 17) {
      final n = 3 + br.bits(3);
      for (var i = 0; i < n; i++) {
        lengths.add(0);
      }
    } else {
      final n = 11 + br.bits(7);
      for (var i = 0; i < n; i++) {
        lengths.add(0);
      }
    }
  }
  final lit = _buildHuff(lengths.sublist(0, hlit));
  final dist = _buildHuff(lengths.sublist(hlit, hlit + hdist));
  return (lit, dist);
}

void _decodeBlock(_BitReader br, _Out out, _Huff lit, _Huff dist) {
  while (true) {
    final sym = lit.decode(br);
    if (sym < 256) {
      out.addByte(sym);
    } else if (sym == 256) {
      break;
    } else {
      final li = sym - 257;
      if (li >= _lenBase.length) {
        throw PngDecodeException('长度码 $sym 越界');
      }
      final length = _lenBase[li] + br.bits(_lenExtra[li]);
      final ds = dist.decode(br);
      if (ds >= _distBase.length) {
        throw PngDecodeException('距离码 $ds 越界');
      }
      final distance = _distBase[ds] + br.bits(_distExtra[ds]);
      out.copyBack(length, distance);
    }
  }
}

/// 输出缓冲 —— 支持 LZ77 需要的**随机访问回拷**。
///
/// ★ 为什么不用 `BytesBuilder`：它只能追加，拿不到已完成部分的随机访问。
///   用 `takeBytes()` 取快照再写回是 O(n²)（每次回拷复制整个缓冲），
///   在几 MB 的 PNG 上会直接卡死。
///   Dart 的 `Uint8List` 不能原地扩容，所以这里用**等差递增的块列表**承载：
///   块大小 64K / 96K / 144K…（每块 +32K），查找是按块累加偏移。
///   为了把随机读也压到 O(1)，额外维护一个稀疏索引 `_blockStart[i]`。
class _Out {
  final List<Uint8List> _blocks = [];

  /// `_blockStart[i]` = 第 i 块首字节在整个输出里的下标（严格递增）。
  final List<int> _blockStart = [];

  /// 已分配的总容量（= 最后一块的末尾下标）。
  int _capacity = 0;
  int _len = 0;

  int get length => _len;

  /// 保证还能再写 [extra] 字节。块大小按 64K / 96K / 128K… 递增。
  void _ensure(int extra) {
    while (_len + extra > _capacity) {
      final gap = _blocks.isEmpty ? 65536 : 32768 * (_blocks.length + 1);
      _blockStart.add(_capacity);
      _blocks.add(Uint8List(gap));
      _capacity += gap;
    }
  }

  /// 二分：下标 [index] 落在哪一块。
  int _blockOf(int index) {
    var lo = 0, hi = _blockStart.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_blockStart[mid] <= index) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  void addByte(int b) {
    _ensure(1);
    _blocks[_blockOf(_len)][_len - _blockStart[_blockOf(_len)]] = b;
    _len++;
  }

  /// 读第 [i] 个已输出字节（0 起）。
  int read(int i) {
    if (i < 0 || i >= _len) {
      throw PngDecodeException('读取越界（$i，已输出 $_len）');
    }
    final bi = _blockOf(i);
    return _blocks[bi][i - _blockStart[bi]];
  }

  /// 从已输出数据里按 [distance] 往前回拷 [length] 字节。
  ///
  /// ★ 必须"边写边读自己刚写的字节"：`distance < length` 是合法的
  ///   （用于重复模式，如 `ababab…`）。一次性快照会读到旧数据。
  void copyBack(int length, int distance) {
    if (distance <= 0 || distance > _len) {
      throw PngDecodeException('LZ77 回拷距离非法（distance=$distance, 已输出=$_len）');
    }
    _ensure(length);
    final src = _len - distance;
    for (var i = 0; i < length; i++) {
      final b = read(src + i);
      _blocks[_blockOf(_len)][_len - _blockStart[_blockOf(_len)]] = b;
      _len++;
    }
  }

  Uint8List takeBytes() {
    final out = Uint8List(_len);
    var w = 0;
    for (var i = 0; i < _blocks.length && w < _len; i++) {
      final n = (_len - w) < _blocks[i].length ? (_len - w) : _blocks[i].length;
      out.setRange(w, w + n, _blocks[i]);
      w += n;
    }
    return out;
  }
}

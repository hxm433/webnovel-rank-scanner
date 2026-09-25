/// 起点「字体反爬」运行时解码器。
///
/// **问题**：起点 `www.qidian.com` 榜单页把指标数字（月票/推荐票/…）
/// 换成自定义字体的符号：
/// ```html
/// <span class="DGTIwkHU">𘡧𘡩𘡪𘡨𘡩</span></span>月票
/// ```
/// 这些字符的码点落在 **U+187FB..U+1886A** 一带，是**每次请求都变**的：
///   - 字体名随机（DGTIwkHU / vrgrgdgt / XfOVGKNB …）
///   - 码点基准点变（U+1885F / U+187FB / U+18843 …）
///   - 码点→数字的映射也变
/// 实测三页三套完全不同的映射，**所以不能像番茄那样用预生成静态表**，
/// 必须每次抓完页面就地把内联的字体下载下来、即时解析。
///
/// ★ 好消息：这份字体是**明文可读**的（不是番茄那种轮廓匹配难题）：
///   ① `post` 表 version 2.0，glyph 名字就是 `zero`/`one`/…/`nine`/`period`；
///   ② cmap 走 format 12（pid=3/eid=10），码点直接指向这些具名 glyph。
///   于是"解码"退化成"读名字"，无需字形栅格化。
///
/// ★ 两条必须做对的细节（都实测踩过）：
///   ① **必须遍历 format 12 的全部 groups 并展开连续段**：
///      例如 `U+18864..U+18865 -> g5`，两个码点共享同一 glyph。
///      只取组起点会让 U+18865 解不出来（表现为页面上出现 `?`，静默丢数）；
///   ② `post` 的 glyph 名索引 < 258 是**标准 Mac 序**（这里只有 idx0=notdef），
///      ≥ 258 才是表尾 Pascal 字符串，偏移从 `34 + 2*numGlyphs` 开始。
///
/// 解不出来时的态度与番茄一致：**宁可缺，不可错** —— 未识别码点保留原样，
/// 由调用方通过 [decodeOk] 判断"这一页是不是解干净了"，不干净就不落指标。
library;

import 'dart:typed_data';

/// 一次字体解码的结果。
class QidianFontTable {
  QidianFontTable(this.map);

  /// 码点 → 字符（'0'..'9'、'.'）。
  final Map<int, String> map;

  bool get isEmpty => map.isEmpty;

  /// 把一段被混淆的文本还原成明文。表里没有的码点**原样保留**。
  String decode(String raw) {
    if (map.isEmpty || raw.isEmpty) return raw;
    final sb = StringBuffer();
    for (final r in raw.runes) {
      sb.write(map[r] ?? String.fromCharCode(r));
    }
    return sb.toString();
  }

  /// 这段文本是否**全部**字符都能解（解不干净就不该信这个数）。
  bool canDecodeFully(String raw) {
    if (raw.isEmpty) return false;
    for (final r in raw.runes) {
      if (!map.containsKey(r)) return false;
    }
    return true;
  }
}

const _digitNames = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
];

/// 解析起点反爬字体（TTF / 已解成字节的 WOFF 也可先解压再喂）。
///
/// 失败一律返回**空表**（不是抛异常）：调用方据此降级，绝不半猜。
QidianFontTable parseQidianFont(Uint8List data) {
  try {
    return _parse(data);
  } on Object {
    return QidianFontTable(const {});
  }
}

QidianFontTable _parse(Uint8List d) {
  if (d.length < 12) return QidianFontTable(const {});
  // sfnt 版本：0x00010000 = TrueType；'wOFF' = WOFF（需另解压，这里不处理）；'OTTO' = CFF
  final tag = _u32(d, 0);

  // ── WOFF 兼容：起点 CDN 同时提供 .ttf 与 .woff。若拿到 WOFF，先解出 sfnt。 ──
  Uint8List sfnt = d;
  var sfntOff = 0;
  if (tag == 0x774F4646) {
    // 'wOFF'
    final out = _unwrapWoff(d);
    if (out == null) return QidianFontTable(const {});
    sfnt = out;
    sfntOff = 0;
  } else if (tag != 0x00010000 && tag != 0x4F54544F) {
    return QidianFontTable(const {});
  }

  final numTables = _u16(sfnt, sfntOff + 4);
  final tables = <String, int>{};
  for (var i = 0; i < numTables; i++) {
    final o = sfntOff + 12 + 16 * i;
    if (o + 16 > sfnt.length) break;
    final name = String.fromCharCodes(sfnt.sublist(o, o + 4));
    tables[name] = _u32(sfnt, o + 8);
  }

  final postOff = tables['post'];
  final cmapOff = tables['cmap'];
  if (postOff == null || cmapOff == null) return QidianFontTable(const {});

  // ── ① post 表取 glyph 名 ──
  final names = _glyphNames(sfnt, postOff);

  // ── ② cmap 找 format 12，展开全部 groups ──
  final map = <int, String>{};
  final nSub = _u16(sfnt, cmapOff + 2);
  for (var i = 0; i < nSub; i++) {
    final rec = cmapOff + 4 + 8 * i;
    if (rec + 8 > sfnt.length) break;
    final subOff = cmapOff + _u32(sfnt, rec + 4);
    if (subOff + 16 > sfnt.length) continue;
    final fmt = _u16(sfnt, subOff);
    if (fmt == 12) {
      _readFmt12(sfnt, subOff, names, map);
    } else if (fmt == 4 && map.isEmpty) {
      // 兜底：个别字体可能只给 BMP 的 fmt4。
      _readFmt4(sfnt, subOff, names, map);
    }
  }
  return QidianFontTable(map);
}

/// 读 post 表（version 2.0）的 glyph 名。version 1.0/3.0 无名字 → 返回空表。
List<String?> _glyphNames(Uint8List d, int postOff) {
  final ver = _u32(d, postOff);
  if (ver != 0x00020000) return const [];
  final numGlyphs = _u16(d, postOff + 32);
  final idxBase = postOff + 34;
  final idxs = <int>[];
  for (var i = 0; i < numGlyphs; i++) {
    final p = idxBase + 2 * i;
    if (p + 2 > d.length) return const [];
    idxs.add(_u16(d, p));
  }
  // Pascal 字符串紧跟在索引数组之后。
  var pos = idxBase + 2 * numGlyphs;
  final names = <String?>[];
  for (final idx in idxs) {
    if (idx < 258) {
      // ★ <258 = 标准 Mac glyph 序：这里只有 0(notdef)，一律当"无名"。
      names.add(null);
    } else {
      if (pos >= d.length) {
        names.add(null);
        continue;
      }
      final len = d[pos];
      final end = pos + 1 + len;
      if (end > d.length) {
        names.add(null);
        pos = end;
        continue;
      }
      names.add(String.fromCharCodes(d.sublist(pos + 1, end)));
      pos = end;
    }
  }
  return names;
}

void _readFmt12(Uint8List d, int off, List<String?> names, Map<int, String> out) {
  final nGroups = _u32(d, off + 12);
  for (var i = 0; i < nGroups; i++) {
    final p = off + 16 + 12 * i;
    if (p + 12 > d.length) break;
    final sc = _u32(d, p);
    final ec = _u32(d, p + 4);
    final gid = _u32(d, p + 8);
    // ★ 展开连续段：只取组起点会漏码点（见文件头注释）。
    final span = ec - sc;
    if (span < 0 || span > 0x10000) continue; // 防御异常大段
    for (var c = sc; c <= ec; c++) {
      final g = gid + (c - sc);
      final ch = _nameToChar(g < names.length ? names[g] : null);
      if (ch != null) out[c] = ch;
    }
  }
}

void _readFmt4(Uint8List d, int off, List<String?> names, Map<int, String> out) {
  final segX2 = _u16(d, off + 6);
  final seg = segX2 ~/ 2;
  if (seg == 0) return;
  final endBase = off + 14;
  final startBase = endBase + segX2 + 2;
  final deltaBase = startBase + segX2;
  final rangeBase = deltaBase + segX2;
  for (var s = 0; s < seg; s++) {
    final ec = _u16(d, endBase + 2 * s);
    final sc = _u16(d, startBase + 2 * s);
    if (sc == 0xffff) continue;
    final delta = _s16(d, deltaBase + 2 * s);
    final ro = _u16(d, rangeBase + 2 * s);
    for (var c = sc; c <= ec; c++) {
      int g;
      if (ro == 0) {
        g = (c + delta) & 0xffff;
      } else {
        final gi = rangeBase + 2 * s + ro + 2 * (c - sc);
        if (gi + 2 > d.length) continue;
        g = _u16(d, gi);
        if (g != 0) g = (g + delta) & 0xffff;
      }
      final ch = _nameToChar(g < names.length ? names[g] : null);
      if (ch != null) out[c] = ch;
    }
  }
}

/// glyph 名 → 明文。`zero..nine` 给数字，`period` 给小数点，其余返回 null。
String? _nameToChar(String? name) {
  if (name == null) return null;
  if (name == 'period' || name == 'dot' || name == 'uni002E') return '.';
  final i = _digitNames.indexOf(name);
  if (i >= 0) return '$i';
  // 兜底：uni0030..uni0039（个别字体用 unicode 名）
  if (name.startsWith('uni') && name.length == 7) {
    final v = int.tryParse(name.substring(3), radix: 16);
    if (v != null && v >= 0x30 && v <= 0x39) return '${v - 0x30}';
  }
  return null;
}

/// WOFF 解包 → sfnt（TrueType）。解不开返回 null。
///
/// WOFF 头 44 字节，之后是逐表目录；每个表可 zlib 压缩。
/// 这里只做"复制表体 + 重建 sfnt 索引"的最小实现。
Uint8List? _unwrapWoff(Uint8List d) {
  if (d.length < 44) return null;
  final numTables = _u16(d, 12);
  final entries = <_WoffEntry>[];
  for (var i = 0; i < numTables; i++) {
    final o = 44 + 20 * i;
    if (o + 20 > d.length) return null;
    final tag = String.fromCharCodes(d.sublist(o, o + 4));
    final off = _u32(d, o + 4);
    final compLen = _u32(d, o + 8);
    final origLen = _u32(d, o + 12);
    entries.add(_WoffEntry(tag, off, compLen, origLen));
  }
  // 重建 sfnt：12 字节头 + 16*numTables 目录 + 各表（4 字节对齐）
  final headerLen = 12 + 16 * numTables;
  var total = headerLen;
  final bodies = <Uint8List>[];
  for (final e in entries) {
    final body = e.origLen == e.compLen
        ? d.sublist(e.off, e.off + e.compLen)
        : _inflate(d.sublist(e.off, e.off + e.compLen), e.origLen);
    if (body == null) return null;
    bodies.add(body);
    total += (body.length + 3) & ~3;
  }
  final out = Uint8List(total);
  final bd = ByteData.view(out.buffer);
  bd.setUint32(0, 0x00010000); // sfnt version
  bd.setUint16(4, numTables);
  // searchRange/entrySelector/rangeShift 不是必需（多数解析器忽略），填 0
  var cursor = headerLen;
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    final body = bodies[i];
    final o = 12 + 16 * i;
    out.setRange(o, o + 4, e.tag.codeUnits);
    bd.setUint32(o + 4, _checksum(body));
    bd.setUint32(o + 8, cursor);
    bd.setUint32(o + 12, body.length);
    out.setRange(cursor, cursor + body.length, body);
    cursor += (body.length + 3) & ~3;
  }
  return out;
}

typedef _WoffEntry = _WoffTable;
/// WOFF 目录项。
class _WoffTable {
  const _WoffTable(this.tag, this.off, this.compLen, this.origLen);
  final String tag;
  final int off;
  final int compLen;
  final int origLen;
}

/// 需要 zlib 解压：dart:io 的 ZLibDecoder 在 `dart:io` 里。
/// 为保持本文件不依赖 dart:io（便于纯函数测试），这里声明成可注入点。
Uint8List? Function(Uint8List, int)? woffInflateHook;

Uint8List? _inflate(Uint8List data, int origLen) {
  final h = woffInflateHook;
  if (h == null) return null;
  return h(data, origLen);
}

int _checksum(Uint8List b) {
  var sum = 0;
  final n = b.length;
  for (var i = 0; i + 3 < n; i += 4) {
    sum = (sum + ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3])) & 0xFFFFFFFF;
  }
  return sum;
}

int _u16(Uint8List d, int o) => (d[o] << 8) | d[o + 1];
int _s16(Uint8List d, int o) {
  final v = (d[o] << 8) | d[o + 1];
  return v >= 0x8000 ? v - 0x10000 : v;
}

int _u32(Uint8List d, int o) =>
    ((d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3]) & 0xFFFFFFFF;

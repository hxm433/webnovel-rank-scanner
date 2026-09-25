/// 极简 **xlsx**（Excel 2007+）写出器 —— **零依赖**：ZIP 容器与 OOXML 都手写。
///
/// ★ 为什么要有它（2026-10-02 审查报告的功能缺口）：
///   CSV 虽然能被 Excel 打开，但它**不是 Excel 的原生格式** ——
///   没有真正的"表格"概念（列宽、类型、多 sheet 都表达不了），
///   而且每个单元格都要靠"前置单引号"这种**内容层面的补丁**去挡公式注入。
///   xlsx 里字符串是 `<c t="inlineStr">`，**结构上就不可能是公式** ——
///   同样的数据用原生格式表达，比在 CSV 里打补丁干净。
///
/// ★ 为什么手写而不是引包：本项目从第一天起就是"只用 package:ffi"。
///   ZIP 需要的 CRC32 与 deflate 在 `png.dart` 里**已经有了**（手写的
///   LZ77 + 固定哈夫曼），这里只把 zlib 那层包装剥掉复用，不复制第二份实现。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'png.dart' show crc32, deflateRaw;

/// 一张工作表。
class XlsxSheet {
  /// 表名（会自动清洗成 Excel 允许的形态：去 `: \ / ? * [ ]`、截断 31 字符）。
  final String name;

  /// 行 → 单元格。第一行通常当表头。
  ///
  /// 值可以是 `String` / `num` / `null`；其余类型走 `toString()`。
  final List<List<Object?>> rows;

  const XlsxSheet(this.name, this.rows);
}

/// 把若干张表打成一份 `.xlsx` 的字节。
Uint8List buildXlsx(List<XlsxSheet> sheets, {DateTime? now}) {
  assert(sheets.isNotEmpty, '至少要有一张表');
  final t = now ?? DateTime.now();
  final names = _sheetNames(sheets.map((s) => s.name).toList());

  final files = <String, Uint8List>{
    '[Content_Types].xml': _utf8(_contentTypes(sheets.length)),
    '_rels/.rels': _utf8(_rootRels()),
    'xl/workbook.xml': _utf8(_workbook(names)),
    'xl/_rels/workbook.xml.rels': _utf8(_workbookRels(sheets.length)),
    'xl/styles.xml': _utf8(_styles()),
  };
  for (var i = 0; i < sheets.length; i++) {
    files['xl/worksheets/sheet${i + 1}.xml'] =
        _utf8(_sheetXml(sheets[i].rows));
  }
  return _zip(files, t);
}

// ─────────────────────────────────────────────────────────────────────────
//  OOXML 各部分
// ─────────────────────────────────────────────────────────────────────────

String _contentTypes(int sheetCount) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<Types xmlns="http://schemas.openxmlformats.org/package/2006/'
        'content-types">')
    ..write('<Default Extension="rels" ContentType="application/vnd.'
        'openxmlformats-package.relationships+xml"/>')
    ..write('<Default Extension="xml" ContentType="application/xml"/>')
    ..write('<Override PartName="/xl/workbook.xml" ContentType="application/'
        'vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
    ..write('<Override PartName="/xl/styles.xml" ContentType="application/'
        'vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>');
  for (var i = 1; i <= sheetCount; i++) {
    b.write('<Override PartName="/xl/worksheets/sheet$i.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.'
        'spreadsheetml.worksheet+xml"/>');
  }
  b.write('</Types>');
  return b.toString();
}

String _rootRels() => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/'
    'relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
    'officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    '</Relationships>';

String _workbook(List<String> names) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/'
        '2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/'
        '2006/relationships"><sheets>');
  for (var i = 0; i < names.length; i++) {
    b.write('<sheet name="${_xmlAttr(names[i])}" sheetId="${i + 1}" '
        'r:id="rId${i + 1}"/>');
  }
  b.write('</sheets></workbook>');
  return b.toString();
}

String _workbookRels(int sheetCount) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<Relationships xmlns="http://schemas.openxmlformats.org/package/'
        '2006/relationships">');
  for (var i = 1; i <= sheetCount; i++) {
    b.write('<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/'
        'officeDocument/2006/relationships/worksheet" '
        'Target="worksheets/sheet$i.xml"/>');
  }
  b.write('<Relationship Id="rId${sheetCount + 1}" Type="http://schemas.'
      'openxmlformats.org/officeDocument/2006/relationships/styles" '
      'Target="styles.xml"/></Relationships>');
  return b.toString();
}

/// 最小样式表：只声明一个默认字体与两种单元格格式（文本 / 两位小数）。
///
/// ★ 不少读取器（含 Excel 的某些路径）会假定 `styles.xml` 存在，
///   缺了它虽然符合规范，但打开时可能报"文件已损坏"。留着更稳。
String _styles() => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/'
    '2006/main">'
    '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
    '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
    '<borders count="1"><border/></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" '
    'borderId="0"/></cellStyleXfs>'
    '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" '
    'xfId="0"/></cellXfs>'
    '</styleSheet>';

/// 一张表的 XML。
///
/// ★ 字符串一律走 `t="inlineStr"` —— 这是**结构层面**的公式注入免疫：
///   单元格内容是 `<is><t>` 里的文本，Excel 不会把它当公式求值。
///   （CSV 做不到这一点，只能靠前置单引号这种内容层面的补丁。）
String _sheetXml(List<List<Object?>> rows) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/'
        'spreadsheetml/2006/main"><sheetData>');
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    if (row.isEmpty) continue;
    b.write('<row r="${r + 1}">');
    for (var c = 0; c < row.length; c++) {
      final ref = '${_colName(c)}${r + 1}';
      final v = row[c];
      if (v == null) continue;
      if (v is num) {
        if (v.isNaN || v.isInfinite) {
          // 非法数值不能写进 `<v>`（Excel 会判文件损坏）→ 退化成文本
          b.write('<c r="$ref" t="inlineStr"><is><t>${_xmlText('$v')}</t></is></c>');
        } else {
          b.write('<c r="$ref"><v>$v</v></c>');
        }
      } else {
        final s = '$v';
        if (s.isEmpty) continue;
        b.write('<c r="$ref" t="inlineStr"><is>'
            '<t xml:space="preserve">${_xmlText(s)}</t></is></c>');
      }
    }
    b.write('</row>');
  }
  b.write('</sheetData></worksheet>');
  return b.toString();
}

/// 列号 → 字母（0 → A、25 → Z、26 → AA）。
String _colName(int i) {
  var n = i;
  final b = StringBuffer();
  while (true) {
    b.writeCharCode(0x41 + (n % 26));
    n = n ~/ 26 - 1;
    if (n < 0) break;
  }
  return String.fromCharCodes(b.toString().codeUnits.reversed);
}

/// 表名清洗：Excel 不允许 `: \ / ? * [ ]`，且上限 31 字符；重名要区分开。
List<String> _sheetNames(List<String> raw) {
  final out = <String>[];
  final used = <String>{};
  for (var i = 0; i < raw.length; i++) {
    var name = raw[i].replaceAll(RegExp(r'[:\\/?*\[\]]'), '_').trim();
    if (name.isEmpty) name = 'Sheet${i + 1}';
    if (name.length > 31) name = name.substring(0, 31);
    var candidate = name;
    var k = 2;
    while (used.contains(candidate)) {
      final suffix = '_$k';
      candidate = name.length + suffix.length > 31
          ? '${name.substring(0, 31 - suffix.length)}$suffix'
          : '$name$suffix';
      k++;
    }
    used.add(candidate);
    out.add(candidate);
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────
//  ZIP 容器
// ─────────────────────────────────────────────────────────────────────────

/// 写一个 ZIP（deflate 压缩；压缩后反而变大时退回"存储"）。
Uint8List _zip(Map<String, Uint8List> files, DateTime t) {
  final dosTime = _dosTime(t);
  final dosDate = _dosDate(t);
  final local = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;

  for (final entry in files.entries) {
    final nameBytes = utf8.encode(entry.key);
    final raw = entry.value;
    final deflated = deflateRaw(raw);
    // ★ 小文件压缩后常常更大 —— 那时用"存储"（method 0）更小也更省事
    final useDeflate = deflated.length < raw.length;
    final body = useDeflate ? deflated : raw;
    final method = useDeflate ? 8 : 0;
    final crc = crc32(raw);

    local
      ..add(_le32(0x04034b50)) // 本地文件头签名
      ..add(_le16(20)) // 解压所需版本
      ..add(_le16(0x0800)) // 通用标志位：bit11 = 文件名是 UTF-8
      ..add(_le16(method))
      ..add(_le16(dosTime))
      ..add(_le16(dosDate))
      ..add(_le32(crc))
      ..add(_le32(body.length)) // 压缩后
      ..add(_le32(raw.length)) // 原始
      ..add(_le16(nameBytes.length))
      ..add(_le16(0)) // 扩展区长度
      ..add(nameBytes)
      ..add(body);

    central
      ..add(_le32(0x02014b50)) // 中央目录签名
      ..add(_le16(20)) // 制作版本
      ..add(_le16(20)) // 解压所需版本
      ..add(_le16(0x0800))
      ..add(_le16(method))
      ..add(_le16(dosTime))
      ..add(_le16(dosDate))
      ..add(_le32(crc))
      ..add(_le32(body.length))
      ..add(_le32(raw.length))
      ..add(_le16(nameBytes.length))
      ..add(_le16(0)) // 扩展区
      ..add(_le16(0)) // 注释
      ..add(_le16(0)) // 起始磁盘号
      ..add(_le16(0)) // 内部属性
      ..add(_le32(0)) // 外部属性
      ..add(_le32(offset)) // 本地头偏移
      ..add(nameBytes);

    offset += 30 + nameBytes.length + body.length;
  }

  final centralBytes = central.toBytes();
  final out = BytesBuilder()
    ..add(local.toBytes())
    ..add(centralBytes)
    ..add(_le32(0x06054b50)) // 中央目录结束记录
    ..add(_le16(0)) // 本磁盘号
    ..add(_le16(0)) // 中央目录起始磁盘
    ..add(_le16(files.length))
    ..add(_le16(files.length))
    ..add(_le32(centralBytes.length))
    ..add(_le32(offset))
    ..add(_le16(0)); // 注释长度
  return out.toBytes();
}

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

int _dosTime(DateTime t) =>
    (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);

int _dosDate(DateTime t) =>
    ((t.year - 1980) << 9) | (t.month << 5) | t.day;

// ─────────────────────────────────────────────────────────────────────────
//  XML 转义
// ─────────────────────────────────────────────────────────────────────────

/// 文本节点转义。
///
/// ★ 顺手剔掉 XML 1.0 **不允许**的控制字符（`\x00-\x08` 等）——
///   抓来的书名里偶尔带这些，直接写进去 Excel 会判"文件已损坏"。
String _xmlText(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x09 || r == 0x0A || r == 0x0D ||
        (r >= 0x20 && r <= 0xD7FF) ||
        (r >= 0xE000 && r <= 0xFFFD) ||
        (r >= 0x10000 && r <= 0x10FFFF)) {
      switch (r) {
        case 0x26:
          b.write('&amp;');
        case 0x3C:
          b.write('&lt;');
        case 0x3E:
          b.write('&gt;');
        default:
          b.writeCharCode(r);
      }
    }
  }
  return b.toString();
}

/// 属性值转义（比文本多两个引号）。
String _xmlAttr(String s) =>
    _xmlText(s).replaceAll('"', '&quot;').replaceAll("'", '&apos;');

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// xlsx 写出器回归（**结构自检**部分）。
///
/// ★ 为什么外部校验不在这里：本机沙箱里 `dart run` 起的**子进程一律失败**
///   （`CreateFile failed 231` + `process_win.cc:744`，连 `cmd /c echo hi` 都起不来），
///   所以这里不 spawn Python。真正"别的程序能不能打开"的验证交给
///   `tool/check_xlsx.py`（Python 标准库 zipfile + ElementTree 独立解一遍），
///   由 `tool/run_all_tests.sh` 在跑完 Dart 脚本后**单独调一次**。
///
/// 运行：dart run bin/_t_xlsx.dart [输出目录]
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/xlsx.dart';

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

/// 把测试用的 xlsx 写到固定位置（供外部校验脚本读取）。
String writeFixture(String dir) {
  Directory(dir).createSync(recursive: true);
  final out = '$dir${Platform.pathSeparator}测试.xlsx';
  File(out).writeAsBytesSync(buildXlsx(_sheets, now: DateTime(2026, 10, 2, 21, 30)));
  return out;
}

const String _pua = '\uE000\uE001混淆书名';

final List<XlsxSheet> _sheets = <XlsxSheet>[
  XlsxSheet('榜单明细', [
    ['#', '书名', '作者', '指标', '备注'],
    [1, _pua, '作者甲', 12345, '连载'],
    // ★ 公式注入 payload：xlsx 里走 inlineStr，结构上就不可能是公式
    [2, "=cmd|'/c calc'!A1", '+1+1', -5, '@SUM(A1)'],
    [3, '含 & < > " \' 的标题', '控制\x01字符', 0, null],
    [4, '超长列名', 'x' * 200, 3.14159, ''],
  ]),
  XlsxSheet('趋势·对比', [
    ['书名', '期数', '名次变化'],
    ['测试书', 12, -3],
  ]),
  // 表名里有 Excel 非法字符 + 超长 + 与前面重名 → 都要被清洗
  XlsxSheet('非法:名/字?*[]', [
    ['a'],
  ]),
  XlsxSheet('非法:名/字?*[]', [
    ['b'],
  ]),
];

/// 一个**独立写的** ZIP 目录扫描器（不与写出器共用代码）——
/// 自己解自己没说服力，但至少能查出偏移/条目数这类低级错误。
class _ZipScan {
  final Uint8List b;
  _ZipScan(this.b);

  int _le16(int o) => b[o] | (b[o + 1] << 8);
  int _le32(int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  /// 从尾部找 EOCD（PK\x05\x06），返回 (条目数, 中央目录大小, 中央目录偏移)。
  (int, int, int)? eocd() {
    for (var i = b.length - 22; i >= 0 && i > b.length - 22 - 65536; i--) {
      if (b[i] == 0x50 && b[i + 1] == 0x4B && b[i + 2] == 5 && b[i + 3] == 6) {
        return (_le16(i + 10), _le32(i + 12), _le32(i + 16));
      }
    }
    return null;
  }

  /// 逐个走中央目录，返回 (文件名, CRC, 压缩后长度, 原始长度, 本地头偏移)。
  List<(String, int, int, int, int)> entries() {
    final e = eocd();
    if (e == null) return const [];
    var o = e.$3;
    final out = <(String, int, int, int, int)>[];
    for (var k = 0; k < e.$1; k++) {
      if (!(b[o] == 0x50 && b[o + 1] == 0x4B && b[o + 2] == 1 && b[o + 3] == 2)) {
        break;
      }
      final crc = _le32(o + 16);
      final csize = _le32(o + 20);
      final usize = _le32(o + 24);
      final nlen = _le16(o + 28);
      final elen = _le16(o + 30);
      final clen = _le16(o + 32);
      final lho = _le32(o + 42);
      final name = String.fromCharCodes(b.sublist(o + 46, o + 46 + nlen));
      out.add((name, crc, csize, usize, lho));
      o += 46 + nlen + elen + clen;
    }
    return out;
  }

  /// 本地头里的文件名是否与中央目录一致、偏移是否指向真签名。
  bool localHeaderOk(int offset, String name) {
    if (offset + 30 > b.length) return false;
    if (!(b[offset] == 0x50 && b[offset + 1] == 0x4B &&
        b[offset + 2] == 3 && b[offset + 3] == 4)) {
      return false;
    }
    final nlen = _le16(offset + 26);
    final got = String.fromCharCodes(b.sublist(offset + 30, offset + 30 + nlen));
    return got == name;
  }
}

void main(List<String> args) {
  final dir = args.isNotEmpty ? args[0] : 'build/_xlsx_test';
  final out = writeFixture(dir);
  final bytes = File(out).readAsBytesSync();
  stdout.writeln('写出 $out（${bytes.length} 字节）');

  stdout.writeln('\n── ZIP 结构 ──');
  final z = _ZipScan(bytes);
  final eocd = z.eocd();
  _check('找得到中央目录结束记录（PK\\x05\\x06）', eocd != null);
  if (eocd == null) {
    stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
    exitCode = 1;
    return;
  }
  final ents = z.entries();
  _check('EOCD 声明的条目数 == 实际能走出来的条目数',
      eocd.$1 == ents.length, '${eocd.$1} vs ${ents.length}');
  _check('条目数 = 5 个固定部件 + 4 张表 = 9',
      ents.length == 9, '${ents.length}');
  _check('每个条目的本地头偏移都指向真签名、文件名一致',
      ents.every((e) => z.localHeaderOk(e.$5, e.$1)));
  _check('每个条目的 CRC 非 0', ents.every((e) => e.$2 != 0));
  _check('所有条目都真的带数据（原始长度 > 0）',
      ents.every((e) => e.$4 > 0));

  stdout.writeln('\n── 内容（在 Dart 侧能查的部分）──');
  final hasWorkbook = ents.any((e) => e.$1 == 'xl/workbook.xml');
  _check('包含 xl/workbook.xml', hasWorkbook);
  _check('包含 [Content_Types].xml',
      ents.any((e) => e.$1 == '[Content_Types].xml'));
  _check('包含 xl/styles.xml（缺了部分读取器会报"文件已损坏"）',
      ents.any((e) => e.$1 == 'xl/styles.xml'));
  _check('四张表都在', ents.where((e) => e.$1.startsWith('xl/worksheets/')).length == 4,
      '${ents.where((e) => e.$1.startsWith('xl/worksheets/')).length}');
  // ★ 压缩后的字节里当然有 NUL —— 我第一版拿"字节流里没有 NUL"当断言，是错的。
  //   这里改成查"有没有真的压缩"：只要有一条的压缩后长度 ≠ 原始长度，就说明走了 deflate。
  _check('至少有一条走了 deflate（不是全存储态）',
      ents.any((e) => e.$3 != e.$4), '全部都是存储态');

  stdout.writeln('\n  （XML 良构 / 单元格内容 / 表名清洗 → 交给 tool/check_xlsx.py 独立验）');
  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

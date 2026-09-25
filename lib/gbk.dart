/// GBK / gb18030 双字节区解码 —— 晋江等 GBK 站点的数据源前提。
///
/// ─────────────────────────────────────────────────────────────
/// 为什么需要它（B8 的前置条件）
/// ─────────────────────────────────────────────────────────────
/// Dart 内置只有 utf8 / latin1 / ascii，`Encoding.getByName('gb18030')`
/// 返回 null。而晋江的页面是 **GBK 编码**（响应头 charset=gb18030），
/// 没有 GBK 解码就没有晋江数据源 —— 这是扫榜统一方案把 B8 单列的
/// 原因：需要自实现码表。
///
/// 码表来自 `tool/gen_gbk_table.py`（Python 内置 'gbk' = cp936 编解码器
/// 逐格生成，**独立权威**），只覆盖**双字节区**：
/// - lead 0x81–0xFE，trail 0x40–0xFE（排除 0x7F）
/// - 单字节 < 0x80 直接按 ASCII 输出
/// - 其余字节序列（0x80、0xFF、截断的双字节、未指派格）→ U+FFFD
///
/// gb18030 的**双字节区与 GBK 完全一致**（gb18030 是超集，多出的部分
/// 在四字节区）。晋江页面只用双字节区，所以这个解码器标 gb18030 兼容
/// 是就"双字节区"而言 —— 四字节区（生僻字）不覆盖，命中即 U+FFFD。
///
/// 为什么不做编码器：本项目的唯一用途是**读取** GBK 页面；发出去的
/// 请求（URL、UA）全是 ASCII。没有用途的代码不写。
library;

import 'gbk_table.dart';

/// GBK 解码器（解码方向，见文件头说明）。
class GbkDecoder {
  const GbkDecoder();

  static const int _leadMin = 0x81;
  static const int _leadMax = 0xFE;
  static const int _rowWidth = 190;
  static const int _replacementChar = 0xFFFD;

  /// 解码 [bytes]。[allowMalformed] 为 false 时遇到非法序列抛
  /// FormatException（与 `utf8.decode(allowMalformed: false)` 语义对齐）；
  /// 默认 true，坏字节替换为 U+FFFD —— 抓取场景宁可显示占位符
  /// 也不要让一个脏字节毁掉整页解析。
  String decode(List<int> bytes, {bool allowMalformed = true}) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b < 0x80) {
        sb.writeCharCode(b);
        continue;
      }
      if (b >= _leadMin && b <= _leadMax && i + 1 < bytes.length) {
        final t = bytes[i + 1];
        if (t >= 0x40 && t <= 0xFE && t != 0x7F) {
          final ch = kGbkDoubleByteTable.codeUnitAt(_cell(b, t));
          if (ch != 0x0000) {
            sb.writeCharCode(ch);
            i++; // 双字节消费两个
            continue;
          }
        }
      }
      // 非法序列：lead 越界 / trail 越界 / 截断 / 未指派格
      if (!allowMalformed) {
        throw FormatException('GBK 解码失败：偏移 $i 处的字节 0x'
            '${b.toRadixString(16).padLeft(2, '0')}');
      }
      sb.writeCharCode(_replacementChar);
    }
    return sb.toString();
  }

  /// (lead, trail) → 表内索引。
  ///
  /// trail 索引跳过 0x7F：0x40..0x7E → 0..62；0x80..0xFE → 63..189。
  /// 这个偏移必须在生成器与解码器**两侧完全一致** —— 错一格整表全歪，
  /// 抽样比对测试就是为钉死它。
  static int _cell(int lead, int trail) =>
      (lead - _leadMin) * _rowWidth +
      (trail < 0x7F ? trail - 0x40 : trail - 0x41);
}

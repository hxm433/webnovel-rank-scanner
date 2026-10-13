import 'dart:convert';

/// Shared stable helpers used across snapshot metadata, storage, and exports.
int stablePathId(String path) {
  final bytes = utf8.encode(path);
  var h = 0x811C9DC5;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h == 0 ? 1 : h;
}

String ymdKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}';

String safeFileSegment(String s, {int maxLen = 120}) {
  var out = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
  out = out.replaceAll(RegExp(r'[. ]+$'), '_');
  if (out == '.' || out == '..' || out.trim().isEmpty) out = '_';
  final stem = out.split('.').first.toLowerCase();
  final windowsReservedNames = <String>{
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
  };
  if (windowsReservedNames.contains(stem)) out = '_$out';
  if (out.length > maxLen) out = out.substring(0, maxLen);
  return out;
}

String bookKeyOf(dynamic e) {
  if (e is Map) {
    final id = e['bookId'] ?? e['book_id'];
    if (id != null && id.toString().trim().isNotEmpty) return 'id:${id.toString()}';
    final title = e['title'];
    return 'title:${title ?? ''}';
  }
  return 'title:${e.toString()}';
}

num? parseCnNumber(String raw) {
  final s = raw.trim().replaceAll(',', '');
  if (s.isEmpty) return null;
  final re = RegExp(r'([-+]?\d+(?:\.\d+)?)\s*([亿万]?)');
  var total = 0.0;
  var matched = false;
  for (final m in re.allMatches(s)) {
    final v = double.tryParse(m.group(1)!);
    if (v == null) continue;
    matched = true;
    final unit = m.group(2);
    final factor = switch (unit) {
      '亿' => 1e8,
      '万' => 1e4,
      _ => 1.0,
    };
    total += v * factor;
  }
  if (!matched) return null;
  if (!total.isFinite) return null;
  return total.round();
}

int? finiteToInt(Object? v) => (v is num && v.isFinite) ? v.toInt() : null;

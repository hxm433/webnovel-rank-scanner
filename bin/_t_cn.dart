import '../lib/models.dart';

void main() {
  final cases = <String, num?>{
    '3亿5000万': 350000000,
    '4.41万月票': 44100,
    '910.07万字': 9100700,
    '6.14万月票': 61400,
    '1.5亿': 150000000,
    '1亿2万': 100020000,
    '5000': 5000,
    '没数字': null,
  };
  var ok = 0, bad = 0;
  for (final e in cases.entries) {
    final got = parseCnNumber(e.key);
    final pass = got == e.value;
    if (pass) { ok++; } else { bad++; }
    print('${pass ? "PASS" : "FAIL"}  ${e.key} → $got （期望 ${e.value}）');
  }
  print('');
  print('通过 $ok / 失败 $bad');
}

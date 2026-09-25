import '../lib/ui/widgets.dart';

void main() {
  final cases = <num?, String>{
    9223372036854775807: '9.2e+18',
    null: '-',
    44100: '4.4万',
    9100700: '910.1万',
    350000000: '3.50亿',
    12345: '1.2万',
    42: '42',
    double.infinity: '非有限数',
    double.nan: '非有限数',
  };
  var ok = 0, bad = 0;
  for (final e in cases.entries) {
    final got = wan(e.key);
    final pass = got == e.value;
    if (pass) { ok++; } else { bad++; }
    print('${pass ? "PASS" : "FAIL"}  ${e.key} → "$got" （期望 "${e.value}"）');
  }
  print('');
  print('通过 $ok / 失败 $bad');
}

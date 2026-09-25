/// 探针：WIC 能不能在本进程里解码封面（JPEG / WebP）。
///
/// ★ 为什么要单独探一次：本项目已验证 WinRT 在裸 exe 里会**崩**
///   （见 `lib/ocr.dart`），所以"借系统解码器"这条路必须先证明可行，
///   不能等界面里用到时才发现。
///
/// 运行：dart run bin/_probe_wic.dart [图片路径]
library;

import 'dart:io';

import '../lib/cover_image.dart';
import '../lib/png.dart';

/// 结果也写一份到文件。
///
/// ★ 为什么必须写文件：打包成单 exe 之后 Subsystem 是 **GUI**，
///   stdout 没有窗口可显示 —— 只看打印的话，"探针在真 exe 里到底成不成"
///   永远拿不到答案（这是本项目第二次踩这个坑，OCR 那次也是）。
final _log = StringBuffer();
void _say(String s) {
  stdout.writeln(s); // ← 这一行必须走 stdout，写成 _say 就成了无限递归
  _log.writeln(s);
}

void main(List<String> args) {
  final f = args.isNotEmpty ? args[0] : 'build/_covtest/qd.jpg';
  final file = File(f);
  _say('文件: $f  '
      '(${file.existsSync() ? '${file.lengthSync()} 字节' : '不存在'})');
  if (!file.existsSync()) {
    _say('  先下几张封面样本再跑：见 README「封面」一节');
    exitCode = 2;
    return;
  }

  final ok = WicSupport.probe();
  _say('WIC 可用 = $ok   ${WicSupport.note}');
  if (!ok) {
    exitCode = 1;
    return;
  }

  final img = decodeCoverFile(f, 36, 48);
  if (img == null) {
    _say('解码失败 → null');
    exitCode = 1;
    return;
  }
  _say('解码成功: ${img.width}x${img.height}  ${img.bgra.length} 字节');

  // 取中心像素 + 统计非黑像素，确认不是一片黑（"解出个空图"是这类
  // 手工 vtable 调用最典型的失败形态）
  final cx = (img.height ~/ 2) * img.width * 4 + (img.width ~/ 2) * 4;
  _say('  中心像素 BGRA = ${img.bgra[cx]},${img.bgra[cx + 1]},'
      '${img.bgra[cx + 2]},${img.bgra[cx + 3]}');
  var nonZero = 0;
  for (var i = 0; i < img.bgra.length; i += 4) {
    if (img.bgra[i] != 0 || img.bgra[i + 1] != 0 || img.bgra[i + 2] != 0) {
      nonZero++;
    }
  }
  final total = img.width * img.height;
  _say('  非黑像素 = $nonZero / $total'
      '（${(nonZero * 100 / total).toStringAsFixed(0)}%）');

  final png = bgraToPng(img.bgra, img.width, img.height);
  File('build/_covtest/decoded.png').writeAsBytesSync(png);
  _say('  已写出 build/_covtest/decoded.png（${png.length} 字节）');
  _say(nonZero > total ~/ 10
      ? '\n[OK]   解码结果像一张真图'
      : '\n[FAIL] 解出来几乎全黑 —— 槽位或格式很可能不对');
  _say(nonZero > total ~/ 10
      ? '[OK]   解码结果像一张真图'
      : '[FAIL] 解出来几乎全黑 —— 槽位或格式很可能不对');
  try {
    File('build/_covtest/wic_probe.txt').writeAsStringSync(_log.toString());
  } on Object {}
  exitCode = nonZero > total ~/ 10 ? 0 : 1;
}

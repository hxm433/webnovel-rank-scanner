/// 验证"认出对话框 + 点掉它的「是」"这套机制**真的有效**。
///
/// ★ 为什么必须验：真机上那个 Edge 提权框现在复现不出来了（Edge 已经是普通权限），
///   但代码里那段"找 #32770 框 → GetDlgItem(IDYES) → BM_CLICK"**必须证明能用** ——
///   否则下次它出现时还是点不掉，又会来回一轮。
///   办法：自己弹一个**标准 Yes/No MessageBox**（和那个框同类、同 id 约定），
///   让被测代码去点它，看返回值是不是 IDYES(6)。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import '../lib/ui/win32.dart';
import 'package:ffi/ffi.dart';

/// 在独立 isolate 里弹一个模态 Yes/No 框（模态会阻塞调用线程，所以必须分线程）。
void _showBox(List<Object?> args) {
  final port = args[0] as SendPort;
  final r = messageBoxW(0, '测试：请点「是」'.toNativeUtf16(),
      'Microsoft Edge'.toNativeUtf16(), 0x00000004 /*MB_YESNO*/);
  port.send(r);
}

Future<void> main() async {
  final rp = ReceivePort();
  await Isolate.spawn(_showBox, [rp.sendPort]);

  // 等框出来
  int dlg = 0;
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    dlg = findBrowserElevationDialog();
    if (dlg != 0) break;
  }
  stdout.writeln('找到对话框：$dlg  ${dlg != 0 ? "✅" : "❌ 没找到（判据失效）"}');
  if (dlg == 0) {
    exitCode = 1;
    exit(1);
  }

  final ok = clickElevationDialogYes(dlg);
  stdout.writeln('发出点击：$ok');

  // 等它关闭并把返回值送回来
  String result;
  try {
    final v = await rp.first.timeout(const Duration(seconds: 5));
    result = '$v';
  } on Object {
    result = 'TIMEOUT';
  }
  stdout.writeln('MessageBox 返回值 = $result（6 = IDYES = 点到了「是」）');
  stdout.writeln(result == '6' ? '✅ 机制有效' : '❌ 机制无效');
  exitCode = result == '6' ? 0 : 1;
  exit(exitCode);
}

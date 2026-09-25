/// 决定性实验：**现在**用完全相同的调用方式打开用户点的那个地址，
/// 看 Edge 到底会不会导航过去。
///
/// ★ 之前的对比：程序自检（`--selftest-click-link`）**能成功**，
///   用户手点**不成功** —— 所以必须把两者的差异找出来，而不是继续加机制。
library;

import 'dart:io';

import '../lib/ui/app.dart';
import '../lib/ui/win32.dart';

String _title() {
  final h = findBrowserWindow();
  if (h == 0) return '(没有浏览器窗口)';
  final (cls, t) = windowClassAndTitle(h);
  return '$cls | $t';
}

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'https://www.qimao.com/book/195958/';
  stdout.writeln('打开前：${_title()}');

  var rc = 0;
  // ① 与程序里**一模一样**的调用：带 owner（这里没有窗口，用 0 代替）
  final ok = openExternal(url, owner: 0, detail: (r) => rc = r);
  stdout.writeln('openExternal(owner=0) → ok=$ok rc=$rc');

  for (var i = 1; i <= 8; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    stdout.writeln('  ${i}s：${_title()}');
  }
}

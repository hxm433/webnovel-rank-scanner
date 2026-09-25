/// **关键对照实验**：`openExternal` 带 owner 与不带 owner 有没有差别？
///
/// ★ 已有的两条事实：
///   · 程序自检（`--selftest-click-link`，**带 owner=程序窗口**）→ 成功；
///   · 用户手点（同一条代码路径）→ 用户说打不开。
///   而我的独立探针（**owner=0**）→ 成功。
///   所以"owner 这个参数"是唯一还没排除的差异 —— 直接拿**正在运行的那个程序窗口**
///   当 owner 试一次，就能把它排除或坐实。
library;

import 'dart:ffi';
import 'dart:io';

import '../lib/ui/app.dart';
import '../lib/ui/win32.dart';

/// 找本工具自己的窗口（类名 `RankScanApp`）。
int _findAppWindow() {
  var found = 0;
  final proc = Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_cb, 1);
  _sink = (h) {
    found = h;
  };
  enumWindows(proc, 0);
  _sink = null;
  return found;
}

void Function(int)? _sink;

int _cb(int hwnd, int lparam) {
  if (_sink == null) return 1;
  final (cls, _) = windowClassAndTitle(hwnd);
  if (cls == 'RankScanApp' && isWindowVisible(hwnd) != 0) {
    _sink!(hwnd);
    return 0;
  }
  return 1;
}

String _edgeTitle() {
  final h = findBrowserWindow();
  if (h == 0) return '(没有浏览器窗口)';
  final (_, t) = windowClassAndTitle(h);
  return t;
}

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'https://www.qimao.com/shuku/1655407/';
  final owner = _findAppWindow();
  stdout.writeln('本工具的窗口 hwnd = $owner ${owner != 0 ? "✅" : "（没找到，可能没在跑）"}');
  stdout.writeln('打开前 Edge 标题：${_edgeTitle()}');

  var rc = 0;
  final ok = openExternal(url, owner: owner, detail: (r) => rc = r);
  stdout.writeln('openExternal(owner=$owner) → ok=$ok rc=$rc');
  for (var i = 1; i <= 6; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    stdout.writeln('  ${i}s：${_edgeTitle()}');
  }
}

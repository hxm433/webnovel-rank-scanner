/// 读令牌判断"谁提权了" —— 拿已知答案校准 + 看 Edge 的真实状态。
library;

import 'dart:ffi';
import 'dart:io';

import '../lib/ui/win32.dart';

Map<String, int> _pidsByName() {
  final out = <String, int>{};
  final proc = Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_cb, 1);
  _sink = out;
  enumWindows(proc, 0);
  _sink = null;
  return out;
}

Map<String, int>? _sink;

int _cb(int hwnd, int lparam) {
  final s = _sink;
  if (s == null) return 1;
  final pid = processIdOfWindow(hwnd);
  final nm = processNameOfWindow(hwnd);
  if (pid != 0 && nm.isNotEmpty) s.putIfAbsent(nm, () => pid);
  return 1;
}

void main() {
  stdout.writeln('本进程提权？ ${selfIsElevated()}  （dart run 一般是普通权限）');
  stdout.writeln('');
  stdout.writeln('── 校准（已知答案）──');
  final byName = _pidsByName();
  for (final nm in ['explorer', 'svchost', 'SearchApp', 'ShellExperienceHost']) {
    final pid = byName[nm];
    if (pid == null) {
      stdout.writeln('  $nm：没窗口，跳过');
      continue;
    }
    stdout.writeln('  $nm (pid $pid) 提权？ ${isProcessElevated(pid)}');
  }
  stdout.writeln('');
  stdout.writeln('── 浏览器（有窗口的）──');
  for (final pid in browserProcessIds()) {
    stdout.writeln('  pid $pid 提权？ ${isProcessElevated(pid)}');
  }
}

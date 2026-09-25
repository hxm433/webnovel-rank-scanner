/// 问窗口："这个坐标算不算客户区？"（`WM_NCHITTEST`）
///
/// 运行：dart run bin/_probe_hittest.dart <hwnd十进制> <屏幕x> <屏幕y>
///
/// ★ 为什么这条最关键：**真实鼠标点击的路径**是
///   系统 → `WM_NCHITTEST` → 若返回 `HTCAPTION` 就变成"拖动窗口"，
///   **`WM_LBUTTONDOWN` 根本不会发到应用** → 表现就是"点了没反应"。
///   而 `PostMessage(WM_LBUTTONDOWN)` 是**直接投递**，跳过命中测试 ——
///   所以之前那套自检全绿也说明不了真实点击能work（踩过）。
///
/// 返回值对照：HTCLIENT=1（客户区，点击会到应用）、HTCAPTION=2（标题栏/拖动）、
/// HTNOWHERE=0、HTTRANSPARENT=-1、HTBORDER=18 等。
library;

import 'dart:io';

import '../lib/ui/win32.dart';

const Map<int, String> _htNames = {
  0: 'HTNOWHERE',
  1: 'HTCLIENT ✅（点击会到应用）',
  2: 'HTCAPTION ⚠️（会变成拖动窗口，应用收不到点击）',
  3: 'HTSYSMENU',
  4: 'HTGROWBOX',
  10: 'HTNOWHERE?',
  17: 'HTCLOSE',
  18: 'HTBORDER',
  20: 'HTMINBUTTON',
  21: 'HTMAXBUTTON',
  -1: 'HTTRANSPARENT',
  -2: 'HTNOWHERE',
};

/// 沿一条水平线扫描，找"从 HTCLIENT 变成别的"的分界。
void _scan(int hwnd, int x0, int x1, int y, int step) {
  stdout.writeln('扫描 y=$y，x 从 $x0 到 $x1（步长 $step）');
  int? prev;
  for (var x = x0; x <= x1; x += step) {
    final lp = ((y & 0xFFFF) << 16) | (x & 0xFFFF);
    final r = sendMessageW(hwnd, wmNcHitTest, 0, lp);
    final v = r >= 0x8000 ? r - 0x10000 : r;
    if (prev == null || v != prev) {
      stdout.writeln('  x=$x → $v  ${_htNames[v] ?? ""}');
      prev = v;
    }
  }
}

/// 沿竖直方向扫描。
void _scanY(int hwnd, int y0, int y1, int x, int step) {
  stdout.writeln('扫描 x=$x，y 从 $y0 到 $y1（步长 $step）');
  int? prev;
  for (var y = y0; y <= y1; y += step) {
    final lp = ((y & 0xFFFF) << 16) | (x & 0xFFFF);
    final r = sendMessageW(hwnd, wmNcHitTest, 0, lp);
    final v = r >= 0x8000 ? r - 0x10000 : r;
    if (prev == null || v != prev) {
      stdout.writeln('  y=$y → $v  ${_htNames[v] ?? ""}');
      prev = v;
    }
  }
}

void main(List<String> args) {
  if (args.isNotEmpty && args[0] == '--scan-y') {
    final hwnd = int.tryParse(args[1]) ?? 0;
    final y0 = int.tryParse(args[2]) ?? 0;
    final y1 = int.tryParse(args[3]) ?? 0;
    final x = int.tryParse(args[4]) ?? 0;
    final step = args.length > 5 ? (int.tryParse(args[5]) ?? 10) : 10;
    _scanY(hwnd, y0, y1, x, step);
    return;
  }
  if (args.isNotEmpty && args[0] == '--scan') {
    final hwnd = int.tryParse(args[1]) ?? 0;
    final x0 = int.tryParse(args[2]) ?? 0;
    final x1 = int.tryParse(args[3]) ?? 0;
    final y = int.tryParse(args[4]) ?? 0;
    final step = args.length > 5 ? (int.tryParse(args[5]) ?? 10) : 10;
    _scan(hwnd, x0, x1, y, step);
    return;
  }
  if (args.length < 3) {
    stderr.writeln('用法：dart run bin/_probe_hittest.dart <hwnd> <屏幕x> <屏幕y>');
    exitCode = 2;
    return;
  }
  final hwnd = int.tryParse(args[0]) ?? 0;
  final x = int.tryParse(args[1]) ?? 0;
  final y = int.tryParse(args[2]) ?? 0;
  if (hwnd == 0) {
    stderr.writeln('hwnd 无效');
    exitCode = 2;
    return;
  }
  // lParam：低 16 位 x、高 16 位 y（**屏幕坐标**、有符号 16 位）
  final lp = ((y & 0xFFFF) << 16) | (x & 0xFFFF);
  final r = sendMessageW(hwnd, wmNcHitTest, 0, lp);
  // 返回值按有符号处理（HTTRANSPARENT = -1）
  final v = r >= 0x8000 ? r - 0x10000 : r;
  stdout.writeln('WM_NCHITTEST (屏幕 $x,$y) → $v  ${_htNames[v] ?? ""}');
  stdout.writeln(v == htClient
      ? '[OK] 这个坐标算客户区 —— 真实点击会送到应用'
      : '[FAIL] 这个坐标不是客户区 —— 真实点击不会送到应用（这就是"点了没反应"）');
  exitCode = v == htClient ? 0 : 1;
}

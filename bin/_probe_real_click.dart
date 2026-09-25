/// 用 **真实鼠标输入**（`SetCursorPos` + `mouse_event`）点一下屏幕上的某个位置。
///
/// 运行：dart run bin/_probe_real_click.dart <屏幕x> <屏幕y>
///
/// ★ 为什么不能只用 `PostMessage`：`PostMessage(WM_LBUTTONDOWN)` 是**直接投递
///   一条消息**，绕过了鼠标输入队列。真实点击会先经过窗口激活
///   （`WM_MOUSEACTIVATE`）、命中测试（`WM_NCHITTEST`）、
///   `WM_MOUSEMOVE` 等一串消息 —— "点了没反应"这类问题只可能在真实输入下复现。
///
/// ★ 它会**移动真实光标**（几秒后不还原）—— 只在自检时用。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../lib/ui/win32.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法：dart run bin/_probe_real_click.dart <屏幕x> <屏幕y>');
    exitCode = 2;
    return;
  }
  final x = int.tryParse(args[0]);
  final y = int.tryParse(args[1]);
  if (x == null || y == null) {
    stderr.writeln('坐标必须是整数');
    exitCode = 2;
    return;
  }
  // ★★ 先声明 DPI 感知（-4 = PER_MONITOR_AWARE_V2）。
  //
  //   本机屏幕是 150% 缩放，`dart run` 起的进程默认**不感知 DPI** →
  //   它看到的是"虚拟坐标"，`SetCursorPos` 收到的坐标会被系统 ×1.5 换算成
  //   物理坐标，很可能超出屏幕被**夹到边缘** —— 于是"点了"的位置根本不是
  //   目标位置（实测：光标停在屏幕最右，点了个空，还看不出为什么）。
  //   应用本身是 DPI 感知的（`app.dart` 启动时声明过），两边坐标系必须一致。
  final dpiOk = setProcessDpiAwarenessContext(-4);
  stdout.writeln('DPI 感知声明=$dpiOk  屏幕='
      '${getSystemMetrics(0)}x${getSystemMetrics(1)}');
  stdout.writeln('真实点击屏幕 ($x, $y)');
  final p0 = calloc<Point>();
  getCursorPos(p0);
  stdout.writeln('点击前光标=(${p0.ref.x},${p0.ref.y})');
  final okSet = setCursorPos(x, y);
  getCursorPos(p0);
  // ★ 这一行是关键：`SetCursorPos` 返回非 0 不代表光标真的动了 ——
  //   沙箱/权限可能把合成输入静默丢掉。光标没动 = 这次"点击"根本没发生。
  stdout.writeln('SetCursorPos 返回 $okSet，点击后光标=(${p0.ref.x},${p0.ref.y})');
  calloc.free(p0);
  if (okSet == 0) {
    stdout.writeln('[FAIL] SetCursorPos 失败');
    exitCode = 1;
    return;
  }
  if (p0.ref.x != x || p0.ref.y != y) {
    stdout.writeln('[WARN] 光标没有移动到目标位置 —— 合成输入可能被环境丢弃');
  }
  // 给系统一点时间把光标移动 / hover 消息处理完
  await Future<void>.delayed(const Duration(milliseconds: 300));
  mouseEvent(mouseEventLeftDown, 0, 0, 0, 0);
  await Future<void>.delayed(const Duration(milliseconds: 60));
  mouseEvent(mouseEventLeftUp, 0, 0, 0, 0);
  stdout.writeln('已发出真实左键按下 / 抬起');
}

/// 环境探针 —— 真实建一个窗口，把它的**窗口矩形/客户区矩形/DPI/工作区**全打出来。
///
/// 目的：截图里界面"塌成一条"，先确认到底是
///   ① CreateWindowExW 传的宽高被 DPI 缩放吃了（客户区 ≠ 请求值）；
///   ② 还是屏幕工作区比请求的还小、窗口被裁到只剩一条；
///   ③ 还是绘制层自己的问题。
/// 不实测就只能猜。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../lib/ui/app.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/win32.dart';

void main() {
  final out = StringBuffer();

  // ── 1. DPI / 屏幕度量 ──
  final hdcScreen = getDC(0);
  final dpi = getDeviceCaps(hdcScreen, 88); // LOGPIXELSX
  releaseDC(0, hdcScreen);
  out.writeln('[DPI] LOGPIXELSX = $dpi  (96=100%, 120=125%, 144=150%)');

  final sw = getSystemMetrics(0); // SM_CXSCREEN
  final sh = getSystemMetrics(1); // SM_CYSCREEN
  out.writeln('[Screen] ${sw}x$sh');

  // 工作区（去掉任务栏）
  final work = calloc<Rect>();
  systemParametersInfoW(48, 0, work.cast(), 0); // SPI_GETWORKAREA
  out.writeln('[WorkArea] ${work.ref.width}x${work.ref.height} '
      'at (${work.ref.left},${work.ref.top})');
  calloc.free(work);

  // ── 2. 真的建一个主窗，看请求尺寸与实际尺寸的差 ──
  final win = MainWindow(outRoot: 'out');
  final app = App();
  // 只跑到"建窗 + 首次绘制"为止，不跑长驻消息循环
  app.runProbe(win, width: 1240, height: 800);

  out.writeln('[Window] hwnd=0x${win.hwnd.toRadixString(16)}');

  final wr = calloc<Rect>();
  getWindowRect(win.hwnd, wr);
  out.writeln('[WindowRect] ${wr.ref.width}x${wr.ref.height} '
      '(请求 1240x800 的外框应比客户区大 ~16x39)');
  calloc.free(wr);

  final cr = calloc<Rect>();
  getClientRect(win.hwnd, cr);
  out.writeln('[ClientRect] ${cr.ref.width}x${cr.ref.height}');
  calloc.free(cr);

  out.writeln('[Dashboard] AppWindow.width=${win.width} height=${win.height}');

  // 可见性
  out.writeln('[Visible] isWindowVisible=${isWindowVisible(win.hwnd)}');

  app.probeQuit();

  File('build/probe_geometry.txt').writeAsStringSync(out.toString());
  stdout.write(out.toString());
}

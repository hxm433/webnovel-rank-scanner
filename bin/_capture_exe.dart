/// 抓**已打包 exe** 的真窗口 —— 验证发布产物本身就渲染新版界面，
/// 而不是只有 `dart run` 那条路径好看。
///
/// 做法：枚举顶层窗口找到进程名匹配的那个，BitBlt 它的客户区到 PNG。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../lib/ui/gdi.dart';
import '../lib/ui/win32.dart';
import '_render_shots.dart' show bgraToPng;

// ── 只在本文件用到的枚举绑定 ──
typedef _WndEnumProcNative = IntPtr Function(IntPtr, IntPtr);
typedef _WndEnumProcDart = int Function(int, int);
typedef _EnumWindowsNative = Int32 Function(
    Pointer<NativeFunction<_WndEnumProcNative>>, IntPtr);
typedef _EnumWindowsDart = int Function(
    Pointer<NativeFunction<_WndEnumProcNative>>, int);

typedef _GetWindowThreadProcessIdNative = Uint32 Function(
    Pointer<Void>, Pointer<Uint32>);
typedef _GetWindowThreadProcessIdDart = int Function(
    Pointer<Void>, Pointer<Uint32>);

typedef _IsWindowVisibleNative = Int32 Function(Pointer<Void>);
typedef _IsWindowVisibleDart = int Function(Pointer<Void>);

typedef _GetClassNameWNative = Int32 Function(
    Pointer<Void>, Pointer<Utf16>, Int32);
typedef _GetClassNameWDart = int Function(Pointer<Void>, Pointer<Utf16>, int);

const _target = '网文扫榜工具.exe';

void main(List<String> args) {
  // ★ 不能在这里 spawn `tasklist`：本机沙箱里 dart 起子进程会耗尽管道句柄
  //   （CreateFile failed 231 / process_win.cc:744）。所以 pid 由外部传入。
  final pids = <int>{};
  for (final a in args) {
    final pid = int.tryParse(a.trim());
    if (pid != null) pids.add(pid);
  }
  if (pids.isEmpty) {
    stderr.writeln('用法: dart run bin/_capture_exe.dart <pid> [pid...]');
    exit(2);
  }
  stdout.writeln('目标 pid: ${pids.join(", ")}');

  final u32 = DynamicLibrary.open('user32.dll');
  final enumWindows = u32.lookupFunction<_EnumWindowsNative, _EnumWindowsDart>(
      'EnumWindows');
  final getPid = u32
      .lookupFunction<_GetWindowThreadProcessIdNative,
          _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');
  final isVisible = u32.lookupFunction<_IsWindowVisibleNative,
      _IsWindowVisibleDart>('IsWindowVisible');
  final getClass = u32.lookupFunction<_GetClassNameWNative, _GetClassNameWDart>(
      'GetClassNameW');

  final hits = <({int hwnd, int pid, String cls})>[];
  final cb = NativeCallable<_WndEnumProcNative>.isolateLocal(
    (rawHwnd, _) {
      // IntPtr 参数在 Dart 侧是 int，要转回 Pointer 才能喂给别的绑定。
      final hwnd = Pointer<Void>.fromAddress(rawHwnd);
      var pid = 0;
      try {
        final pp = calloc<Uint32>();
        getPid(hwnd, pp);
        pid = pp.value;
        calloc.free(pp);
        final buf = calloc<Uint16>(256).cast<Utf16>();
        getClass(hwnd, buf, 256);
        final vis = isVisible(hwnd) != 0;
        hits.add((
          hwnd: rawHwnd,
          pid: pid,
          cls: '${buf.toDartString()}|vis=${vis ? 1 : 0}'
        ));
        calloc.free(buf);
      } catch (e) {
        stdout.writeln('  [callback error] $e');
      }
      return 1;
    },
    exceptionalReturn: 0,
  );
  final ok = enumWindows(cb.nativeFunction, 0);
  stdout.writeln('EnumWindows 返回 $ok，命中 ${hits.length} 个窗口');
  cb.close();

  for (final h in hits) {
    stdout.writeln('  窗口 hwnd=0x${h.hwnd.toRadixString(16)} '
        'pid=${h.pid} class=${h.cls}');
  }
  final visible = hits
      .where((h) => h.cls.endsWith('|vis=1'))
      .map((h) => (hwnd: h.hwnd, pid: h.pid, cls: h.cls.split('|').first))
      .toList();
  // ★ 顶层窗口里混着大量 IME / 托盘 / 提示窗（可能撞到同一个 pid），
  //   必须按「客户区有实际面积」筛选，否则会截到一张 0x0 的空窗。
  ({int hwnd, int pid, String cls}) main = (hwnd: 0, pid: 0, cls: '');
  for (final h in visible) {
    if (h.pid != pids.first) continue;
    final r = calloc<Rect>();
    if (getClientRect(h.hwnd, r) != 0) {
      final cw = r.ref.right - r.ref.left;
      final ch = r.ref.bottom - r.ref.top;
      if (cw > 200 && ch > 200) {
        main = h;
        calloc.free(r);
        break;
      }
    }
    calloc.free(r);
  }
  if (main.hwnd == 0) {
    final ours = visible.where((h) => h.pid == pids.first).toList();
    stderr.writeln('pid=${pids.first} 没有可截图的窗口'
        '（该 pid 可见窗口 ${ours.length} / 全部命中 ${hits.length}）');
    exit(3);
  }

  // 量客户区（绑定层 hwnd 参数就是 int）
  final hwndPtr = main.hwnd;
  final rect = calloc<Rect>();
  if (getClientRect(hwndPtr, rect) == 0) {
    stderr.writeln('GetClientRect 失败');
    exit(4);
  }
  final w = rect.ref.right - rect.ref.left;
  final h = rect.ref.bottom - rect.ref.top;
  calloc.free(rect);
  stdout.writeln('客户区 ${w}x$h');

  final winDc = getDC(hwndPtr);
  final memDc = createCompatibleDC(winDc);
  final bi = calloc<BitmapInfoHeader>();
  bi.ref
    ..size = 40
    ..width = w
    ..height = -h
    ..planes = 1
    ..bitCount = 32
    ..compression = 0;
  final ppv = calloc<Pointer<Void>>();
  final hbmp = createDIBSection(memDc, bi, 0, ppv, 0, 0);
  final old = selectObject(memDc, hbmp);
  bitBlt(memDc, 0, 0, w, h, winDc, 0, 0, srccopy);
  releaseDC(hwndPtr, winDc);

  final n = w * h * 4;
  final bytes = Uint8List(n);
  final p = ppv.value.cast<Uint8>();
  final colors = <int>{};
  for (var i = 0; i < n; i++) {
    bytes[i] = p[i];
    if (i % 4 == 0) {
      colors.add((bytes[i]) | (bytes[i + 1] << 8) | (bytes[i + 2] << 16));
    }
  }
  stdout.writeln('不同颜色数 = ${colors.length}');

  selectObject(memDc, old);
  deleteObject(hbmp);
  deleteDC(memDc);
  calloc.free(bi);
  calloc.free(ppv);

  final png = bgraToPng(bytes, w, h);
  const out = 'build/shots/exe_window.png';
  File(out).writeAsBytesSync(png);
  stdout.writeln('已写 $out (${png.length} bytes)');

  if (colors.length <= 12) {
    stderr.writeln('[FAIL] 颜色过少，疑似单色位图退化');
    exit(5);
  }
  stdout.writeln('[OK] 发布版 exe 真窗口渲染正常');
}

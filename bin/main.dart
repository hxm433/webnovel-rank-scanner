/// GUI 入口 —— 双击 exe 直接弹原生窗口。
///
/// 数据目录（`out/`）**外置**：与 exe 同级，而不是打进 exe。
/// 理由：快照是会持续增长的运行数据，每次重打包 exe 都覆盖用户数据
/// 是最糟的设计。exe 只是壳，数据在磁盘上。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../lib/png.dart';
import '../lib/ui/app.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/win32.dart';

void main(List<String> args) {
  if (!platformSupportsGui) {
    stderr.writeln('本工具的原生窗口版只支持 Windows。');
    stderr.writeln('在其它平台上请用命令行版：dart run bin/scan.dart --help');
    exit(2);
  }

  // ★ 自检模式：`--selftest-shot=<png路径> [--selftest-after=2500]`
  //   打包后的 exe 没法被外部脚本稳定截图（本机沙箱会把脱离父进程的
  //   子进程回收，抓窗口的窗口期极短）。让 **exe 自己**画完自己截自己，
  //   既绕开回收问题，又真的证明了"发布产物本身渲染正常"。
  String? shotPath;
  var afterMs = 2500;
  // ★ 自检模式：`--selftest-click-link=<日志路径>`
  //   在**发布版 exe 里**往「打开」按钮真投递一次左键消息，把结果写进日志。
  //   离屏自检证明不了这一段 —— 它绕过窗口消息循环，直接调 onClick。
  String? clickLogPath;
  // 自检窗口尺寸（客户区）。默认 1240x800（基准窗口）；
  // 给大尺寸是为了复现"宽屏下明细表放得下、右侧有留白"那种版面。
  var selfW = 1240, selfH = 800;
  final rest = <String>[];
  for (final a in args) {
    if (a.startsWith('--selftest-shot=')) {
      shotPath = a.substring('--selftest-shot='.length);
    } else if (a.startsWith('--selftest-click-link=')) {
      clickLogPath = a.substring('--selftest-click-link='.length);
    } else if (a.startsWith('--selftest-size=')) {
      final parts = a.substring('--selftest-size='.length).split('x');
      if (parts.length == 2) {
        selfW = int.tryParse(parts[0]) ?? selfW;
        selfH = int.tryParse(parts[1]) ?? selfH;
      }
    } else if (a.startsWith('--selftest-after=')) {
      afterMs = int.tryParse(a.substring('--selftest-after='.length)) ?? afterMs;
    } else {
      rest.add(a);
    }
  }

  // 数据目录：优先命令行传入，否则用 exe 同级的 out/
  final outRoot = rest.isNotEmpty && rest.first.isNotEmpty
      ? rest.first
      : _defaultOutRoot();

  // 客户区目标尺寸。窗口自绘 UI 按逻辑像素设计，所以这里给的是**客户区**；
  // 剩下的非客户区（标题栏/边框）由 App 用 AdjustWindowRectEx 补上，
  // 高分屏也不会出现"布局按 1240 算、实际只有 992"的横向溢出。
  final win = MainWindow(outRoot: outRoot);
  final done = App().run(win, width: selfW, height: selfH);

  if (shotPath != null) {
    unawaited(_selfShot(win, shotPath, afterMs).then((_) {
      exit(0);
    }));
    return;
  }
  if (clickLogPath != null) {
    unawaited(_selfClickLink(win, clickLogPath, afterMs).then((_) {
      exit(0);
    }));
    return;
  }
  done.then((_) => exit(0));
}

/// 在真窗口里往「打开」按钮**投递一条真实左键消息**，验证发布版能跳转。
///
/// 为什么要单独一条：`onClick` 被离屏脚本直接调过无数次，全通过；
/// 但"窗口消息 → 客户区坐标 → 命中区 → openExternal"这一整条只有真窗才跑得到。
Future<void> _selfClickLink(MainWindow win, String logPath, int afterMs) async {
  await Future<void>.delayed(Duration(milliseconds: afterMs));
  final sb = StringBuffer();
  try {
    sb.writeln('hwnd=0x${win.hwnd.toRadixString(16)} client=${win.width}x${win.height}');
    sb.writeln('factor=${Metrics.factor}');
    final all = win.vm?.all ?? const [];
    sb.writeln('snapshots=${all.length}');
    // 找一份**有 url 的**快照
    var picked = false;
    for (final m in all) {
      if (m.result.entries.any((e) => (e.url ?? '').isNotEmpty)) {
        win.testSelect(m.id);
        win.testSetTab(0);
        picked = true;
        sb.writeln('选中 ${m.source}/${m.board} ${m.count} 条');
        break;
      }
    }
    if (!picked) {
      sb.writeln('[FAIL] 没有带 url 的快照，无法测');
      File(logPath).writeAsStringSync(sb.toString());
      return;
    }
    // 强制画一帧把命中区登记出来
    BackBuffer warm = BackBuffer(win.width, win.height);
    try {
      win.onPaint(warm.gdi);
    } finally {
      warm.dispose();
    }

    var btn = win.hitRects[MainWindow.idBookLinkBase];
    var area = win.testDetailArea;
    sb.writeln('明细表可见区 = $area');
    sb.writeln('自然总宽 = ${win.testDetailNaturalWidth}');
    sb.writeln('「打开」命中区 = $btn');
    if (btn == null) {
      sb.writeln('[FAIL] 第 0 行没有「打开」命中区');
      File(logPath).writeAsStringSync(sb.toString());
      return;
    }
    // ★ 必须先保证按钮**真的在屏幕里** —— 否则这个自检就是在点一个
    //   用户根本够不到的坐标（PostMessage 不校验坐标，会假通过）。
    if (area != null && btn.right > area.right) {
      win.testScrollDetailX(1 << 20); // 滚到最右
      final warm2 = BackBuffer(win.width, win.height);
      try {
        win.onPaint(warm2.gdi);
      } finally {
        warm2.dispose();
      }
      btn = win.hitRects[MainWindow.idBookLinkBase];
      area = win.testDetailArea;
      sb.writeln('（按钮原本在可视区外 → 已横向滚到最右）');
      sb.writeln('「打开」命中区 = $btn');
    }
    if (btn == null || area == null ||
        btn.left < area.left || btn.right > area.right) {
      sb.writeln('[FAIL] 按钮不在可视区内，用户点不到：$btn vs $area');
      File(logPath).writeAsStringSync(sb.toString());
      return;
    }
    sb.writeln('[OK] 「打开」按钮在可视区内（用户点得到）');
    final cx = btn.left + btn.width ~/ 2;
    final cy = btn.top + btn.height ~/ 2;
    final before = win.statusText;
    // lParam：低 16 位 x，高 16 位 y（有符号 16 位）
    final lp = ((cy & 0xFFFF) << 16) | (cx & 0xFFFF);
    postMessageW(win.hwnd, wmLButtonDown, 1 /* MK_LBUTTON */, lp);
    postMessageW(win.hwnd, wmLButtonUp, 0, lp);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    sb.writeln('点击客户区坐标 ($cx, $cy)');
    sb.writeln('statusText: "$before"');
    sb.writeln('      ->   "${win.statusText}"');
    sb.writeln(win.statusText.startsWith('已打开详情页')
        ? '[OK] 发布版 exe 点「打开」确实走到了 openExternal'
        : '[FAIL] 点击没被识别成书链接');
  } on Object catch (e, st) {
    sb.writeln('[FAIL] 自检异常: $e\n$st');
  }
  try {
    File(logPath).writeAsStringSync(sb.toString());
  } on Object {
    // 日志写不进去也不能卡住退出
  }
}

/// 等首绘 + 数据载入后，把自己的客户区 BitBlt 成 PNG，再退出。
Future<void> _selfShot(MainWindow win, String outPath, int afterMs) async {
  await Future<void>.delayed(Duration(milliseconds: afterMs));
  final log = File('$outPath.log');
  final sb = StringBuffer();
  try {
    if (win.hwnd == 0) {
      sb.writeln('[FAIL] hwnd=0，窗口没建起来');
      log.writeAsStringSync(sb.toString());
      return;
    }
    final w = win.width, h = win.height;
    sb.writeln('hwnd=0x${win.hwnd.toRadixString(16)} client=${w}x$h');
    sb.writeln('snapshots=${win.vm?.snapshotCount} records=${win.vm?.recordCount} '
        'errors=${win.loadErrors}');

    final winDc = getDC(win.hwnd);
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
    releaseDC(win.hwnd, winDc);

    final n = w * h * 4;
    final bytes = Uint8List(n);
    final p = ppv.value.cast<Uint8>();
    final colors = <int>{};
    for (var i = 0; i < n; i++) {
      bytes[i] = p[i];
      if (i % 4 == 0) {
        colors.add(bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16));
      }
    }
    sb.writeln('不同颜色数 = ${colors.length}');

    selectObject(memDc, old);
    deleteObject(hbmp);
    deleteDC(memDc);
    calloc.free(bi);
    calloc.free(ppv);

    final png = bgraToPng(bytes, w, h);
    File(outPath).writeAsBytesSync(png);
    sb.writeln('已写 $outPath (${png.length} bytes)');
    sb.writeln(colors.length > 12
        ? '[OK] 发布版 exe 真窗口渲染正常（颜色丰富，非单色退化）'
        : '[FAIL] 颜色过少，疑似单色位图退化');
  } on Object catch (e, st) {
    sb.writeln('[FAIL] 自检截图异常: $e\n$st');
  }
  try {
    log.writeAsStringSync(sb.toString());
  } on Object {
    // 日志写不进去也不能卡住退出
  }
}

/// exe 同级目录下的 out/。
///
/// ★ 用 `Platform.resolvedExecutable` 而不是 `Directory.current`：
///   双击 exe 时工作目录是"快捷方式起始位置"（常常是 C:\Windows\System32），
///   用 cwd 会把数据写到莫名其妙的地方。
String _defaultOutRoot() {
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    // dart run 时 resolvedExecutable 是 dart.exe，这种情况下退到项目根
    if (exeDir.contains('dart-sdk')) {
      return 'out';
    }
    return '$exeDir${Platform.pathSeparator}out';
  } on Object {
    return 'out';
  }
}

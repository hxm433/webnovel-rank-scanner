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
  // ★ 自检模式：`--selftest-open-scan=<日志路径> [--selftest-after=3500]`
  //
  //   开一次「扫榜设置」，然后把**当时所有顶层窗口**的（类名 / 标题 / 是否可见）
  //   写进日志。用于诊断"屏幕上多出来一个窗口"：类名是最硬的证据 ——
  //     `#32770`            系统对话框
  //     `ConsoleWindowClass` 控制台（关掉它进程会一起死）
  //     `Chrome_WidgetWin_1` Edge / Chrome 窗口
  //     本项目注册的类名    自绘窗口
  String? openScanLog;

  // ★ 自检模式：`--selftest-wait-click=<日志路径> [--selftest-wait-ms=8000]`
  //   把「打开」按钮的**屏幕坐标**写进日志，然后等一次**真实鼠标点击**
  //   （由 bin/_probe_real_click.dart 用 mouse_event 合成）。
  //
  //   为什么非要真实输入：`PostMessage(WM_LBUTTONDOWN)` 绕过鼠标输入队列，
  //   测不出"窗口没焦点时第一下点击会不会被吃掉"这类只在真实输入下才有的行为。
  String? waitClickLog;
  var waitClickMs = 8000;
  // 自检窗口尺寸（客户区）。默认 1240x800（基准窗口）；
  // 给大尺寸是为了复现"宽屏下明细表放得下、右侧有留白"那种版面。
  var selfW = 1240, selfH = 800;
  final rest = <String>[];
  for (final a in args) {
    if (a.startsWith('--selftest-shot=')) {
      // 空串按"没给"处理（`--selftest-shot=` 不应当触发截图模式）。
      final v = a.substring('--selftest-shot='.length);
      if (v.isNotEmpty) shotPath = v;
    } else if (a.startsWith('--selftest-click-link=')) {
      clickLogPath = a.substring('--selftest-click-link='.length);
    } else if (a.startsWith('--debug-hittest=')) {
      hitTestDebugPath = a.substring('--debug-hittest='.length);
    } else if (a.startsWith('--selftest-open-scan=')) {
      openScanLog = a.substring('--selftest-open-scan='.length);
    } else if (a.startsWith('--selftest-wait-click=')) {
      waitClickLog = a.substring('--selftest-wait-click='.length);
    } else if (a.startsWith('--selftest-wait-ms=')) {
      waitClickMs = int.tryParse(a.substring('--selftest-wait-ms='.length)) ??
          waitClickMs;
    } else if (a.startsWith('--selftest-size=')) {
      final parts = a.substring('--selftest-size='.length).split('x');
      final w = parts.length == 2 ? int.tryParse(parts[0]) : null;
      final h = parts.length == 2 ? int.tryParse(parts[1]) : null;
      // 尺寸直接进真实窗口创建：解析失败 / 非正 / 过小一律算用法错误，
      // 免得自检脚本"以为改了尺寸"其实还是默认值。
      if (w == null || h == null || w < 200 || h < 200) {
        stderr.writeln('非法参数：--selftest-size 需要 <宽>x<高> 且宽高均 >= 200，实际「' +
            a.substring('--selftest-size='.length) +
            '」');
        _usageExit();
      }
      selfW = w;
      selfH = h;
    } else if (a.startsWith('--selftest-after=')) {
      afterMs = int.tryParse(a.substring('--selftest-after='.length)) ?? afterMs;
    } else {
      rest.add(a);
    }
  }

  // ★★ 先脱离父控制台（用户反馈："多了一个无用窗口，关掉它软件也一起关"）。
  //
  //   从 cmd / .cmd 启动一个 GUI 程序时，Windows 会把它附着到父控制台：
  //     · 那个黑底、带滚动条、标题就是本程序完整路径的窗口，看起来就是
  //       "多出来的一个无用窗口"；
  //     · 而关掉它会向所有附着进程发 CTRL_CLOSE —— **整个程序被杀**。
  //   GUI 程序不需要控制台，直接脱离。控制台窗口本身是 cmd 的，我们管不着，
  //   但"关它不再杀掉我们"这件事由这一行保证。
  try {
    if (getConsoleWindow() != 0) {
      final ok = freeConsole();
      // 写进启动日志，方便下次确认到底有没有控制台（这类问题看不到现场）
      try {
        final f = File('${_defaultOutRoot()}/扫榜/_startup.txt');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(
            '${DateTime.now().toIso8601String()}\t'
            'GetConsoleWindow()!=0 → FreeConsole() 返回 $ok\n',
            mode: FileMode.append,
            flush: true);
      } on Object {
        // 日志写不进去不影响启动
      }
    }
  } on Object {
    // 脱离失败也不能拦着启动
  }

  // 数据目录：优先命令行传入，否则用 exe 同级的 out/
  final outRoot = rest.isNotEmpty && rest.first.isNotEmpty
      ? rest.first
      : _defaultOutRoot();

  // 客户区目标尺寸。窗口自绘 UI 按逻辑像素设计，所以这里给的是**客户区**；
  // 剩下的非客户区（标题栏/边框）由 App 用 AdjustWindowRectEx 补上，
  // 高分屏也不会出现"布局按 1240 算、实际只有 992"的横向溢出。
  // ★ 把"起不来"变成"看得见的原因"。
  //   GUI 子系统没有控制台，未捕获异常只会让进程以 255 静默退出 ——
  //   用户双击后"什么都没发生"，无从下手。常见诱因有：
  //     · 无交互桌面会话（服务/远程会话/受限沙箱）→ RegisterClassW 失败；
  //     · 会话被策略限制创建窗口 → CreateWindowExW 失败。
  //   这里捕获后：① 写 out/扫榜/_start_error.txt；② 弹一个系统 MessageBox。
  //   ★ App().run 是 async：异常**不会**同步抛出，必须挂到返回的 Future 上
  //     （catchError），否则错误逃到顶层，照样静默 255。
  late final MainWindow win;
  try {
    win = MainWindow(outRoot: outRoot);
  } on Object catch (e, st) {
    _reportStartFailure(outRoot, 'MainWindow 构造失败：$e\n$st');
    exit(255);
  }

  late final Future<void> done;
  try {
    done = App()
        .run(win, width: selfW, height: selfH)
        .catchError((Object e, StackTrace st) {
      _reportStartFailure(outRoot, '$e\n$st');
      exit(255);
    });
  } on Object catch (e, st) {
    // App().run 本身若同步抛出（调用前就坏了），也走同一条路。
    _reportStartFailure(outRoot, '$e\n$st');
    exit(255);
  }

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
  if (openScanLog != null) {
    unawaited(_selfOpenScan(win, openScanLog, afterMs).then((_) {
      exit(0);
    }));
    return;
  }
  if (waitClickLog != null) {
    unawaited(_selfWaitRealClick(win, waitClickLog, afterMs, waitClickMs)
        .then((_) => exit(0)));
    return;
  }
  done.then((_) => exit(0));
}

/// 命令行用法错误：打印用法后退码 2（与"启动失败 255"区分开）。
Never _usageExit() {
  stderr.writeln('用法：扫榜工具 [输出目录] [选项]');
  stderr.writeln('  --selftest-open-scan=<路径>   自检：开扫榜设置并 dump 顶层窗口清单');
  stderr.writeln('  --selftest-shot=<png路径>     自检截图输出路径（空串=未给）');
  stderr.writeln('  --selftest-size=<宽>x<高>      自检客户区尺寸（宽高均须 >= 200）');
  stderr.writeln('  --selftest-after=<毫秒>       截图前等待时长');
  stderr.writeln('  --selftest-click-link=<日志>  投递点击自检日志路径');
  stderr.writeln('  --selftest-wait-click=<日志>  等真实鼠标点击的日志路径');
  stderr.writeln('  --selftest-wait-ms=<毫秒>     等真实点击的超时');
  stderr.writeln('  --debug-hittest=<日志>        命中区调试日志路径');
  exit(2);
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

    // ★★ 「返回码说成功」不等于「浏览器真的开了」。
    //   这里隔 1.5s / 4s 各 dump 一次顶层窗口清单 —— 浏览器窗口的类名是
    //   `Chrome_WidgetWin_1`（Edge/Chrome），控制台是 `ConsoleWindowClass`。
    //   用户报"软件端打不开 Edge"时，这份清单就是唯一的证据。
    for (final ms in [1500, 4000]) {
      await Future<void>.delayed(Duration(milliseconds: ms));
      sb.writeln('--- 点击后 ${ms}ms 的可见顶层窗口 ---');
      sb.writeln(_dumpWindows(win.hwnd));
    }
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

    // ── DPI / 缩放自检 ──
    //
    // ★ 为什么把这段放进**发布版自检**：DPI 缩放是"只有真机才验得到"的东西 ——
    //   125% / 150% / 200% 的机器上表现完全不同，而开发机往往只有一档。
    //   把"客户区尺寸 == 设计尺寸 × factor"这条**恒等式**写成断言，
    //   用户在任何缩放档位跑一次 `--selftest-shot` 就能验出来对不对。
    //
    //   恒等式怎么来的：设计尺寸（逻辑）→ 乘 factor（= 布局因子 × DPI 因子）
    //   → 就是 CreateWindowExW 该给的物理客户区。少了 DPI 那一乘，
    //   150% 下客户区会小 1/3，界面看起来"整个缩了一圈"。
    final design = win.testDesignSize;
    sb.writeln('dpi=${Metrics.dpiScale} factor=${Metrics.factor}');
    if (design.$1 > 0 && design.$2 > 0) {
      final wantW = (design.$1 * Metrics.factor).round();
      final wantH = (design.$2 * Metrics.factor).round();
      // 容差 2px：窗口创建时会经过 WM_NCCALCSIZE / SetWindowPos 微调。
      final ok = (w - wantW).abs() <= 2 && (h - wantH).abs() <= 2;
      sb.writeln('设计尺寸 ${design.$1}x${design.$2} × factor '
          '= ${wantW}x$wantH（实测 ${w}x$h）');
      sb.writeln(ok
          ? '[OK] DPI/缩放换算正确（客户区 = 设计尺寸 × factor）'
          : '[FAIL] DPI/缩放换算不对：客户区 $w x $h 与期望 $wantW x $wantH 不符');
    } else {
      sb.writeln('[warn] 拿不到设计尺寸，跳过 DPI 换算断言');
    }

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

/// 等一次**真实鼠标点击**，把「打开」按钮的屏幕坐标先写进日志。
///
/// 与 `_selfClickLink` 的区别：那个用 `PostMessage` 自己投递消息，
/// **绕过了鼠标输入队列**；这个什么都不做，只报坐标，由外部脚本用
/// `mouse_event` 合成真实点击 —— 能测到"窗口没焦点 / 第一下点击被吃掉"这类问题。
Future<void> _selfWaitRealClick(
    MainWindow win, String logPath, int afterMs, int waitMs) async {
  await Future<void>.delayed(Duration(milliseconds: afterMs));
  final sb = StringBuffer();
  try {
    sb.writeln('hwnd=0x${win.hwnd.toRadixString(16)} client=${win.width}x${win.height}');
    final all = win.vm?.all ?? const [];
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
      sb.writeln('[FAIL] 没有带 url 的快照');
      File(logPath).writeAsStringSync(sb.toString());
      return;
    }
    final warm = BackBuffer(win.width, win.height);
    try {
      win.onPaint(warm.gdi);
    } finally {
      warm.dispose();
    }
    final btn = win.hitRects[MainWindow.idBookLinkBase];
    if (btn == null) {
      sb.writeln('[FAIL] 没有「打开」命中区');
      File(logPath).writeAsStringSync(sb.toString());
      return;
    }
    // 客户区坐标 → 屏幕坐标
    final pt = calloc<Point>()
      ..ref.x = btn.left + btn.width ~/ 2
      ..ref.y = btn.top + btn.height ~/ 2;
    clientToScreen(win.hwnd, pt);
    final sx = pt.ref.x, sy = pt.ref.y;
    calloc.free(pt);
    // 窗口在屏幕上的位置（判断点击坐标是否落在窗口里）
    final wr = calloc<Rect>();
    getWindowRect(win.hwnd, wr);
    sb.writeln('窗口屏幕矩形=(${wr.ref.left},${wr.ref.top})..'
        '(${wr.ref.right},${wr.ref.bottom})');
    calloc.free(wr);
    final sm = getSystemMetrics(0);
    final smy = getSystemMetrics(1);
    sb.writeln('屏幕=${sm}x$smy');
    sb.writeln('按钮客户区=$btn  屏幕=($sx,$sy)');
    sb.writeln('READY $sx $sy');
    File(logPath).writeAsStringSync(sb.toString());

    final before = win.statusText;
    final sw = Stopwatch()..start();
    var moves = 0;
    var lastX = win.mouseX, lastY = win.mouseY;
    while (sw.elapsedMilliseconds < waitMs) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (win.mouseX != lastX || win.mouseY != lastY) {
        moves++;
        lastX = win.mouseX;
        lastY = win.mouseY;
      }
      if (win.statusText != before) break;
    }
    // ★ 这两行是"点击到底有没有到应用"的判据：
    //   收到过 WM_MOUSEMOVE（moves > 0）说明坐标是对的、消息进得来，
    //   那问题就在点击判定；moves == 0 说明消息压根没进来（坐标/焦点/输入被挡）。
    sb.writeln('收到鼠标移动 $moves 次，最后一次客户区=($lastX,$lastY)');
    sb.writeln('等待 ${sw.elapsedMilliseconds} ms');
    sb.writeln('statusText: "$before"  ->  "${win.statusText}"');
    sb.writeln(win.statusText.startsWith('已打开详情页')
        ? '[OK] 真实鼠标点击走到了 openExternal'
        : (win.statusText == before
            ? '[FAIL] 真实鼠标点击**没有任何反应**（点击没被识别）'
            : '[WARN] 点击被识别但没走到 openExternal：${win.statusText}'));
  } on Object catch (e, st) {
    sb.writeln('[FAIL] 自检异常: $e\n$st');
  }
  try {
    File(logPath).writeAsStringSync(sb.toString());
  } on Object {
    // 写不进去也不能卡住退出
  }
}

/// 启动失败（建类/建窗失败）时的落盘 + 提示。
///
/// ★ 为什么必须这么做：GUI 子系统程序**没有控制台**，`stderr` 写到哪里都
///   没人看得见；异常逃到顶层就是进程静默退出（码 255）。用户看到的只是
///   "双击了，什么都没发生"。所以：
///   ① 写 `out/扫榜/_start_error.txt`（含完整栈）——给排查留证据；
///   ② 弹 `MessageBoxW`——不依赖任何自绘，窗口都建不起来时它仍然能显示。
void _reportStartFailure(String outRoot, String detail) {
  final sep = Platform.pathSeparator;
  try {
    final f = File('$outRoot${sep}扫榜${sep}_start_error.txt');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
        '${DateTime.now().toIso8601String()}\n$detail\n', flush: true);
  } on Object {
    // 落盘失败也要继续弹框
  }
  try {
    final cap = '网文扫榜工具：窗口创建失败'.toNativeUtf16();
    final msg = ('程序无法创建窗口，已退出。\n\n'
            '常见原因：当前不在可交互的桌面会话中'
            '（远程/服务/受限环境），或会话策略禁止创建窗口。\n\n'
            '详细信息已写入：\n'
            '$outRoot$sep扫榜${sep}_start_error.txt\n\n'
            '技术细节：\n$detail')
        .toNativeUtf16();
    messageBoxW(0, msg, cap, 0x00000010 /* MB_ICONERROR */);
    calloc.free(msg);
    calloc.free(cap);
  } on Object {
    // 弹框失败就只能靠日志了
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

/// 自检：打开「扫榜设置」，然后把所有顶层窗口的（类名 / 标题 / 可见）写进日志。
///
/// ★ 为什么要**程序自己**枚举：用户报"多了一个无用窗口，关掉它软件也一起关"，
///   而我按常规路径跑看不到它 —— 那说明它只在某条操作路径上出现。
///   与其猜，不如让程序把当时的窗口清单打出来；类名是最硬的证据。
Future<void> _selfOpenScan(MainWindow win, String logPath, int afterMs) async {
  final f = File(logPath);
  void log(String s) {
    f.writeAsStringSync('$s\n', mode: FileMode.append, flush: true);
  }

  f.writeAsStringSync('', flush: true);
  await Future<void>.delayed(const Duration(milliseconds: 900));
  log('主窗口 hwnd = ${win.hwnd}');
  log('--- 开扫榜设置前 ---');
  log(_dumpWindows(win.hwnd));
  win.openScanDialog();
  await Future<void>.delayed(const Duration(milliseconds: 900));
  log('--- 开扫榜设置后 ---');
  log(_dumpWindows(win.hwnd));
  await Future<void>.delayed(Duration(milliseconds: afterMs));
  log('--- ${afterMs}ms 后 ---');
  log(_dumpWindows(win.hwnd));
}

/// 枚举所有**可见**顶层窗口。`mark` 是本进程的主窗口 hwnd，用来标出"这是我们的"。
String _dumpWindows(int mark) {
  final sb = StringBuffer();
  final proc = Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_enumCb, 1);
  _enumSink = sb;
  _enumMark = mark;
  enumWindows(proc, 0);
  _enumSink = null;
  return sb.toString().trimRight();
}

StringBuffer? _enumSink;
int _enumMark = 0;

int _enumCb(int hwnd, int lparam) {
  final sink = _enumSink;
  if (sink == null) return 1;
  if (isWindowVisible(hwnd) == 0) return 1;
  final (cls, title) = windowClassAndTitle(hwnd);
  if (cls.isEmpty && title.isEmpty) return 1;
  final mine = hwnd == _enumMark ? '  ← 本进程主窗口' : '';
  sink.writeln('  [$hwnd] $cls | $title$mine');
  return 1;
}

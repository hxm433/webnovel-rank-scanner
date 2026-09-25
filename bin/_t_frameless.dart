/// 自检 —— 无边框窗口改造（自绘标题栏 / 命中测试 / 几何）。
///
/// 这些断言**只有真窗口才测得出**：
///   - 客户区是否真的铺满整窗（WM_NCCALCSIZE 返回 0 生效）
///   - 命中测试是否把标题栏判成可拖、把按钮判成客户区
///   - 窗口按钮的命中区是否落在窗口内、且互不重叠
///
/// 沙箱里 `dart analyze` 不可用（CreateFile failed 231），
/// 所以"语法对不对、符号存不存在"也靠这个脚本真跑一遍来验证 ——
/// 只要有一个未定义符号，编译期就会炸在这里。
library;

import 'dart:io';

import '../lib/ui/app.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/widgets.dart';
import '../lib/ui/win32.dart';

int _pass = 0, _fail = 0;
void ok(String s) {
  _pass++;
  print('  [OK]   $s');
}

void bad(String s) {
  _fail++;
  print('  [FAIL] $s');
}

void check(bool c, String s) => c ? ok(s) : bad(s);

Future<void> main() async {
  print('=== 无边框窗口自检 ===\n');

  final win = MainWindow(outRoot: 'out');
  final app = App();
  final done = app.run(win, width: 1240, height: 800);
  await Future<void>.delayed(const Duration(milliseconds: 900));

  print('[1] 客户区必须铺满整窗（WM_NCCALCSIZE=0 生效）');
  // 无边框 + NCCALCSIZE 返回 0 之后，外框 == 客户区。
  // 若这一层没生效，客户区会比请求值小一圈（差值 = 标题栏高度 + 边框）。
  final wr = win.width, hr = win.height;
  print('       客户区 = ${wr}x$hr（请求 1240x800）');
  check(wr >= 1230, '宽度没被系统标题栏吃掉（$wr ≥ 1230）');
  check(hr >= 790, '高度没被系统标题栏吃掉（$hr ≥ 790）');

  print('\n[2] 自绘标题栏的窗口按钮命中区');
  // 先画一帧，把 hitRects 填上。
  final buf = BackBuffer(win.width, win.height);
  try {
    win.onPaint(buf.gdi);
  } finally {
    buf.dispose();
  }

  final rMin = win.hitRects[idWinMinimize];
  final rMax = win.hitRects[idWinMaximize];
  final rClose = win.hitRects[idWinClose];
  check(rMin != null, '最小化按钮已登记');
  check(rMax != null, '最大化按钮已登记');
  check(rClose != null, '关闭按钮已登记');

  if (rClose != null && rMin != null && rMax != null) {
    check(rClose.right <= win.width + 1,
        '关闭按钮未越出右边界（right=${rClose.right} ≤ ${win.width}）');
    check(rMin.left >= 0, '最小化按钮未越出左边界（left=${rMin.left}）');
    check(rMin.right <= rMax.left, '最小化在最大化左侧，不重叠');
    check(rMax.right <= rClose.left, '最大化在关闭左侧，不重叠');
    // 三个按钮必须都在顶栏条带内（y < headerHeight）。
    final cap = win.captionHeight;
    check(rMin.bottom <= cap + 1 && rClose.bottom <= cap + 1,
        '窗口按钮都在标题栏条带内（bottom ≤ $cap）');
  }

  print('\n[3] 命中测试：标题栏可拖、按钮不可拖');
  final cap = win.captionHeight;
  // 品牌区（左上角靠右一点，避开 logo 左侧的留白）→ 必须被判为 HTCAPTION。
  final hBrand = win.onHitTest(150, cap ~/ 2);
  check(hBrand == htCaption, '品牌区 → HTCAPTION（实际 $hBrand）');
  // 窗口按钮中心 → 必须是 HTCLIENT（否则点不动）。
  if (rClose != null) {
    final cx = rClose.left + rClose.width ~/ 2;
    final cy = rClose.top + rClose.height ~/ 2;
    final h = win.onHitTest(cx, cy);
    check(h == htClient, '关闭按钮中心 → HTCLIENT（实际 $h）');
  }
  if (rMin != null) {
    final cx = rMin.left + rMin.width ~/ 2;
    final cy = rMin.top + rMin.height ~/ 2;
    final h = win.onHitTest(cx, cy);
    check(h == htClient, '最小化按钮中心 → HTCLIENT（实际 $h）');
  }
  // 顶栏的操作按钮也要排除在拖拽之外。
  final rScan = win.hitRects[MainWindow.idScanButton];
  if (rScan != null) {
    final h = win.onHitTest(
        rScan.left + rScan.width ~/ 2, rScan.top + rScan.height ~/ 2);
    check(h == htClient, '「扫榜设置」按钮 → HTCLIENT（实际 $h）');
  }
  // 内容区（顶栏以下）不归 onHitTest 管 → 返回 null，交给系统默认。
  final hBody = win.onHitTest(600, cap + 100);
  check(hBody == null, '内容区 → null（交还系统，实际 $hBody）');

  print('\n[4] 无边框样式位常量正确');
  check(wsFramelessWindow & wsCaption == 0, 'WS_CAPTION 已剔除（无系统标题栏）');
  check(wsFramelessWindow & wsThickFrame != 0, '保留 WS_THICKFRAME（可缩放）');
  check(wsFramelessWindow & wsPopup != 0, 'WS_POPUP 已设置');
  check(wsFramelessWindow & wsMinimizeBox != 0, 'WS_MINIMIZEBOX 已设置');
  check(wsFramelessWindow & wsMaximizeBox != 0, 'WS_MAXIMIZEBOX 已设置');
  check(wsFramelessDialog & wsThickFrame == 0, '对话框不带 WS_THICKFRAME（不可缩放）');

  print('\n[5] 窗口按钮矢量图标真的画出了东西');
  // 直接画到一个离屏缓冲上，检查按钮区域有"亮像素"（图标线条）。
  final b2 = BackBuffer(400, 80);
  try {
    // 铺深底，再画三个按钮，然后数亮像素。
    b2.gdi.fill(Rc.xywh(0, 0, 400, 80), Palette.headerBg);
    drawWinButton(b2.gdi, 10, 10,
        kind: WinBtnKind.minimize, hot: false, pressed: false, windowActive: true);
    drawWinButton(b2.gdi, 60, 10,
        kind: WinBtnKind.maximize, hot: false, pressed: false, windowActive: true);
    drawWinButton(b2.gdi, 110, 10,
        kind: WinBtnKind.restore, hot: false, pressed: false, windowActive: true);
    drawWinButton(b2.gdi, 160, 10,
        kind: WinBtnKind.close, hot: false, pressed: false, windowActive: true);
    final px = b2.readBgra();
    int bright = 0;
    for (var i = 0; i + 3 < px.length; i += 4) {
      final r = px[i + 2], g = px[i + 1], b = px[i];
      if (r + g + b > 330) bright++;
    }
    print('       图标亮像素 = $bright');
    check(bright > 40, '四个窗口按钮的矢量图标都画上了（亮像素 >40）');
  } finally {
    b2.dispose();
  }

  print('\n[6] 关闭按钮 hover 用 Windows 标准红');
  check(Palette.closeHover == rgb(232, 17, 35), 'closeHover = #E81123');

  print('\n=== 结果: $_pass 通过 / $_fail 失败 ===');

  app.quit();
  await done.timeout(const Duration(seconds: 3), onTimeout: () {});
  exit(_fail == 0 ? 0 : 1);
}

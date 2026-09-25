/// 窗口基座 —— 创建窗口、分片消息循环、重绘调度。
///
/// ★ 核心设计：**消息循环必须分片跑，不能阻塞**。
///   Win32 的经典写法是 `while (GetMessage(...))`，那会把整个线程钉死，
///   Dart 的异步任务（网络请求、定时器）就永远得不到执行 —— 而对扫榜软件，
///   网络恰恰是它唯一在做的事。
///   所以这里改用 `Timer.periodic` + `PeekMessageW(PM_REMOVE)`：
///   每次 tick 排空最多 N 条消息后立刻让出，让 Dart 事件循环转起来。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'gdi.dart';
import 'theme.dart';
import 'win32.dart';

/// 应用窗口。继承它实现 [onPaint] / [onClick] 等。
abstract class AppWindow {
  int hwnd = 0;

  /// 客户区尺寸。窗口过程（同库）负责写入。
  int _width = 0;
  int _height = 0;
  bool _disposed = false;

  /// 重绘请求是否已挂起（合并同一帧内的多次 invalidate）。
  bool _paintPending = false;

  /// 挂起的重绘**级别**：0 = 无、1 = 只失效了某块区域、2 = 整窗。
  ///
  /// ★ 为什么需要它：`invalidate()` 与 [invalidateRectClient] 原来共用
  ///   同一个布尔闸门。状态栏的 60ms 转圈定时器先挂起一次"只重画状态栏"，
  ///   紧接着任何一次 `invalidate()`（列表刷新、点击反馈）都会被
  ///   这个闸门**静默丢弃** —— 主内容停在旧帧，看起来像"点了没反应"。
  ///   现在记住级别：局部挂起时再来整窗请求就**升级**为整窗。
  int _pendingLevel = 0;
  bool _hasFocus = true;

  /// 是否已销毁。
  bool get isDisposed => _disposed;

  /// 光标位置（用于 hover 效果）。
  int mouseX = -1;
  int mouseY = -1;
  int hotId = -1;

  /// 拖拽中的控件 id（-1 = 没有）。
  int dragId = -1;

  /// 内容滚动偏移（按控件 id 分别记）。
  final Map<int, int> scroll = {};

  int get width => _width;
  int get height => _height;
  bool get hasFocus => _hasFocus;

  String get title;

  /// 绘制整个界面（坐标系是客户区，左上角为 0,0）。
  void onPaint(Gdi g);

  /// 鼠标左键按下。返回 true 表示已处理（阻止后续默认处理）。
  bool onClick(int x, int y) => false;

  /// 左键抬起。
  void onRelease(int x, int y) {}

  /// 鼠标移动（含未按键的 hover）。
  void onMove(int x, int y) {}

  /// 滚轮。[delta] 正 = 向上滚。
  void onWheel(int x, int y, int delta) {}

  /// 横向滚轮（触摸板双指横扫 / 倾斜滚轮）。
  ///
  /// ★ 为什么单独一条而不是塞进 [onWheel]：Windows 把横向滚轮当成**另一个消息**
  ///   （`WM_MOUSEHWHEEL`），语义也不一样 —— 这里的 [delta] 已经统一成
  ///   "正 = 往右滚"（原始消息是反的），窗口侧不用再记方向。
  void onHWheel(int x, int y, int delta) {}

  /// 按键。
  void onKey(int vk) {}

  /// 收到了一个**字符**（WM_CHAR，已过输入法）。
  ///
  /// 默认什么都不做 —— 只有真正有文本输入框的窗口才需要覆盖它。
  void onChar(int ch) {}

  /// 窗口尺寸变化。
  void onResize(int w, int h) {}

  /// 窗口关闭前（返回 false 可阻止关闭）。
  bool onClosing() => true;

  /// 窗口**已经销毁**（WM_DESTROY 之后）。用来释放这个窗口独占的资源。
  void onDestroyed() {}

  // ── 无边框窗口钩子 ──

  /// 窗口是否无边框（自绘标题栏）。
  ///
  /// 为 false 时走系统标题栏，[_paintHeader] 里的窗口按钮区不会被命中。
  /// 子窗口要系统边框就覆写成 false。
  bool get frameless => true;

  /// 窗口是否可缩放（拖动边缘改尺寸）。
  ///
  /// 主窗开着（表格需要空间），设置类子窗关掉 —— 一个"能拖大但布局
  /// 不会跟着重排"的窗口比不能拖更让人困惑。
  bool get resizable => true;

  /// 自绘标题栏高度（客户区坐标，0 = 不可拖动）。
  ///
  /// 由 [onHitTest] 用：落在这条带里且没被按钮吃掉 → 返回 `HTCAPTION`，
  /// 系统自动完成拖动 / 双击最大化。
  int get captionHeight => 0;

  /// 命中测试。返回 `HT*` 常量；返回 null 表示"交还给默认逻辑"。
  ///
  /// ★ 这是无边框窗口的**唯一**交互入口：拖动、8 向缩放全靠它。
  ///   好处是完全不用自己写拖拽循环（自己写必然踩"拖快了掉帧、
  ///   松开后窗口还跟着鼠标"这类坑），系统原生的拖动还自带
  ///   Aero Snap（拖到屏幕边缘自动半屏/最大化）。
  ///
  /// [x]/[y] 是**客户区**坐标。
  int? onHitTest(int x, int y) => null;

  /// 窗口尺寸/状态变化后的回调（最大化、还原）。
  void onWindowStateChanged() {}

  /// 窗口是否已最大化。
  bool get isMaximized => hwnd != 0 && isZoomed(hwnd) != 0;

  /// 切换最大化 / 还原。
  void toggleMaximize() {
    if (hwnd == 0) return;
    showWindow(hwnd, isMaximized ? swRestore : swMaximize);
  }

  /// 最小化。
  void minimizeWindow() {
    if (hwnd == 0) return;
    showWindow(hwnd, 6); // SW_MINIMIZE
  }

  /// 走正常关闭流程发 `WM_CLOSE` —— 而不是直接 DestroyWindow，
  /// 这样 [onClosing] 里的"正在扫榜，确定退出？"确认框才有机会弹出来。
  void requestClose() {
    if (hwnd == 0) return;
    postMessageW(hwnd, wmClose, 0, 0);
  }

  /// 逻辑 DPI 缩放。UI 按 1.0 设计，缩放在这里统一处理。
  double dpiScale = 1.0;

  void invalidate() {
    if (_disposed || hwnd == 0) return;
    // 已经挂了"整窗"就不用再挂一次；只挂了"局部"则**升级**为整窗。
    if (_pendingLevel == 2) return;
    _pendingLevel = 2;
    _paintPending = true;
    // ★ 用 NULL 矩形 = 整窗失效。频繁调用会被合并成一次 WM_PAINT。
    invalidateRect(hwnd, nullptr, 0);
  }

  /// 只让某块区域失效（脏区重绘）。
  ///
  /// ★ 这是"轻量化"的关键：`invalidate()` 会让整个客户区重绘，
  ///   而重绘一次要把整个表格重建一遍（几十行 × 十几列 DrawTextW）。
  ///   扫榜时状态栏的转圈动画每 60ms 就要动一次 —— 用整窗重绘的话，
  ///   一次扫描期间会白烧掉上万次表格重建。
  ///   把失效区收窄到状态栏那一条，开销降到 1/50 以下。
  ///
  /// [r] 是客户区坐标。越界的部分会被系统裁剪，不必自己 clamp。
  void invalidateRectClient(Rc r) {
    // 已经挂了"整窗"就什么都不用做（整窗覆盖这一块）；
    // 挂了"局部"则保持局部（局部请求不该升级，否则省不下来）。
    if (_pendingLevel > 0 || _disposed || hwnd == 0) return;
    _pendingLevel = 1;
    _paintPending = true;
    final pr = calloc<Rect>()
      ..ref.left = r.left
      ..ref.top = r.top
      ..ref.right = r.right
      ..ref.bottom = r.bottom;
    invalidateRect(hwnd, pr, 0);
    calloc.free(pr);
  }

  void setTitle(String t) {
    if (hwnd == 0) return;
    final p = t.toNativeUtf16();
    setWindowTextW(hwnd, p);
    calloc.free(p);
  }

  /// 是否正在拖拽（用于拖动时跳过 hover 计算）。
  bool get dragging => dragId != -1;

  /// 离屏自检用：直接设定客户区尺寸（正常路径由 WM_SIZE 写）。
  void setSizeForTest(int width, int height) {
    _width = width;
    _height = height;
    onResize(width, height);
  }
}

/// 窗口过程的状态 —— ffi 只允许顶层函数，所以必须放全局。
class WindowHost {
  static final Map<int, AppWindow> byHwnd = {};
}

/// 自定义消息：唤醒消息循环立刻跑一轮（窗口增删时用）。
/// 取值要避开系统消息，0x8000 以上是 WM_APP 区间，安全。
const int wmAppWake = 0x8000 + 1;

/// 标题栏要染成的颜色，格式是 **0x00BBGGRR**（DWM 要 COLORREF 序，不是 RGB）。
///
/// ★ 从 [Palette] **现取**而不是写死常量：主题可切换之后，写死的值会在
///   浅色主题下把标题栏染成深色（一条黑标题栏压在浅色客户区上）。
///   `Palette` 里本来就是 COLORREF 序，直接用即可。
int get captionBgBgr => Palette.headerBg;

/// 无边框窗口的 1px 描边色，同样是 **0x00BBGGRR**（COLORREF 序）。
/// 有它窗口边缘才不会和桌面糊在一起。
int get paletteLineBgr => Palette.line;

/// 从鼠标消息的 `lParam` 取出**客户区**坐标。
///
/// ★ 为什么不能继续用 `win.mouseX/mouseY`：那两个值只在 `WM_MOUSEMOVE`
///   里更新。于是"窗口在光标底下弹出来后的第一次点击"、"指针已经移出本窗
///   之后收到的滚轮"都会拿**上一次移动的陈旧坐标**做命中 —— 表现就是
///   **点到了旁边那一行**。消息自己带着坐标，用它才准。
///
/// lParam 里 x 在低 16 位、y 在高 16 位，都是**有符号**的（多显示器下可为负）。
(int, int) clientXYOf(int lp) {
  final rawX = lp & 0xFFFF;
  final rawY = (lp >> 16) & 0xFFFF;
  return (
    rawX >= 0x8000 ? rawX - 0x10000 : rawX,
    rawY >= 0x8000 ? rawY - 0x10000 : rawY,
  );
}

/// 主线程 id（供 `PostThreadMessageW` 用）。窗口过程里无法可靠拿到，
/// 所以在建第一个窗口前记一次。
int _threadId = 0;

/// 窗口过程。
///
/// ★ 签名必须与 [WndProcNative] 逐字对应：`IntPtr Function(Pointer<Void>,
///   Uint32, UintPtr, IntPtr)`。写成 `int Function(Pointer<Void>, int, int, int)`
///   会报 "Expected type ... to be ... which is the Dart type corresponding to"。
///   （Dart 会把相邻的整数类型擦除成 int，但指针类型不能擦。）
/// 最近一次在窗口过程里被捕获的异常（诊断用）。
///
/// ★ 为什么需要：`Pointer.fromFunction(_wndProc, 0)` 的第二个参数是
///   "异常兜底返回值"，传 0 等于**不兜底** —— Dart 回调里逃出的异常到了
///   原生栈上就是致命错误，表现是"进程直接没了"或（更坏）"界面卡死但进程还在"。
///   而这类异常以前没有任何出口：日志 0 字节、没有对话框。
///   现在统一记在这里，并同步写一行到 stderr，方便排查。
String? lastWindowError;

/// 窗口过程里捕获的异常计数（自检用）。
int windowErrorCount = 0;

int _wndProc(Pointer<Void> hwnd, int msg, int wp, int lp) {
  // ★ 异常屏障：**所有**窗口消息处理都走这里。
  //   Win32 的窗口过程不允许异常逃到原生栈上，逃出去就是未定义行为。
  //   不加这一层的话，一次解析/布局异常的症状是"永久空界面且不报错"。
  try {
    return _wndProcImpl(hwnd, msg, wp, lp);
  } catch (e, st) {
    windowErrorCount++;
    lastWindowError = '$e';
    // 只打印一次详情，避免鼠标一动就刷屏；但计数会一直累加。
    if (windowErrorCount == 1) {
      stderr.writeln('[wndProc] 捕获异常（msg=0x${msg.toRadixString(16)}）: $e\n$st');
    }
    // ★ 关键：把重绘挂起标记复位。否则 `_paintPending` 永远为 true，
    //   之后所有 invalidate() 都被短路，窗口再也不重绘 —— 表现为界面卡死。
    final win = WindowHost.byHwnd[hwnd.address];
    if (win != null) {
      win._paintPending = false;
      win._pendingLevel = 0;
    }
  }
  return defWindowProcW(hwnd.address, msg, wp, lp);
}

int _wndProcImpl(Pointer<Void> hwnd, int msg, int wp, int lp) {
  final h = hwnd.address;
  final win = WindowHost.byHwnd[h];

  switch (msg) {
    // ── 无边框窗口的两个核心消息 ──
    //
    // ★ WM_NCCALCSIZE 返回 0 = "非客户区 0 像素"。
    //   窗口样式里已经去掉了 WS_CAPTION，剩下的可缩放边框也被这一手收进
    //   客户区，于是整窗都归我们画。
    //   wParam==0 时是"窗口尺寸没变、只是重算"，一律交回默认处理。
    case wmNcCalcSize:
      if (win != null && win.frameless && wp != 0) {
        // 返回 0 而不写 NCCALCSIZE_PARAMS → 完全吃掉非客户区。
        return 0;
      }
      break;

    // ★ WM_NCHITTEST 决定"这个位置是标题栏 / 客户区 / 哪条缩放边"。
    //   把它算对，拖动和 8 向缩放就全部由系统接管。
    case wmNcHitTest:
      if (win != null && win.frameless) {
        // lParam 是**屏幕坐标**且是有符号 16 位。
        final rawX = lp & 0xFFFF;
        final rawY = (lp >> 16) & 0xFFFF;
        final sx = (rawX & 0x8000) != 0 ? rawX - 0x10000 : rawX;
        final sy = (rawY & 0x8000) != 0 ? rawY - 0x10000 : rawY;
        // 换算到客户区：GetWindowRect 拿外框，再减掉。
        // ★ 用 GetWindowRect 而不是自己减 dx/dy：最大化时外框会外扩
        //   8px（那是系统的"最大化边框补偿"），自己减会整体偏移。
        final wr = calloc<Rect>();
        getWindowRect(h, wr);
        final cx = sx - wr.ref.left;
        final cy = sy - wr.ref.top;
        final isMax = isZoomed(h) != 0;
        final cw = wr.ref.width;
        final ch = wr.ref.height;
        calloc.free(wr);

        // 最大化时不留缩放边（否则拖上边缘会莫名还原窗口）；
        // 声明不可缩放的窗口（设置类子窗）同样不留。
        const grip = 6;
        if (!isMax && win.resizable) {
          final left = cx < grip;
          final right = cx >= cw - grip;
          final top = cy < grip;
          final bottom = cy >= ch - grip;
          if (top && left) return htTopLeft;
          if (top && right) return htTopRight;
          if (bottom && left) return htBottomLeft;
          if (bottom && right) return htBottomRight;
          if (left) return htLeft;
          if (right) return htRight;
          if (top) return htTop;
          if (bottom) return htBottom;
        }

        // 先问业务：自绘的窗口按钮（最小化/最大化/关闭）必须算客户区，
        // 否则点它们会变成"拖动窗口"。
        final hit = win.onHitTest(cx, cy);
        if (hit != null) return hit;

        // 落在标题栏条带里 → HTCAPTION：系统接管拖动 + 双击最大化 + Aero Snap。
        final cap = win.captionHeight;
        if (cap > 0 && cy >= 0 && cy < cap) return htCaption;
        return htClient;
      }
      break;

    // 无边框窗口里系统不再画非客户区，必须显式吃掉这两个消息，
    // 否则会闪出瞬间的白色边框。
    case wmNcPaint:
      if (win != null && win.frameless) return 0;
      break;

    // ★ WM_NCACTIVATE 要配合"自绘激活态"：
    //   返回 0 表示"我处理了，别你重画" —— 但必须在窗口失焦时让客户区
    //   自己重绘（标题栏变灰），不然失去焦点毫无视觉反馈。
    case wmNcActivate:
      if (win != null && win.frameless) {
        win._hasFocus = wp != 0;
        win.invalidate();
        return 1;
      }
      break;

    case wmPaint:
      final ps = calloc<PaintStruct>();
      final hdc = beginPaint(h, ps);
      try {
        if (win != null && win.width > 0 && win.height > 0) {
          // ★ 双缓冲：先画到内存 DC，再一次性贴到屏幕（否则拖动会闪）
          //
          // ★ 脏区优化（轻量化的重点）：
          //   `rcPaint` 是系统告诉我们的"这次到底哪块需要重画"。
          //   只失效状态栏时它是状态栏那条矩形，不是整窗。
          //   把 BackBuffer 收窄到它，就不必重建上方几百行的表格。
          //   ── 但 UI 绘制是"整幅画"的语义（表格/卡片不会画到一半），
          //   所以这里用**平移**而不是裁剪：把整个界面画到偏移后的缓冲里，
          //   只有目标区域会落到位图上。代价是文字定位要整体位移，
          //   而 GDI 的 SetViewportOrgEx 正好干这个 —— 不需要改任何
          //   绘制代码。
          //
          //   若系统给的是整窗（rcPaint = 客户区），就退化成原来的一整张。
          var pw = win.width;
          var ph = win.height;
          var offX = 0;
          var offY = 0;
          final rp = ps.ref.rcPaint;
          final dirtyW = rp.width;
          final dirtyH = rp.height;
          // 只有"脏区明显小于整窗"时才值得走收窄路径。
          // 阈值取 60%：脏区太大时收窄省不下多少，反而多一次 Blt。
          if (dirtyW > 0 &&
              dirtyH > 0 &&
              (dirtyW * dirtyH) < (win.width * win.height * 0.6)) {
            pw = dirtyW;
            ph = dirtyH;
            offX = rp.left;
            offY = rp.top;
          }

          final buf = BackBuffer(pw, ph);
          try {
            final g = buf.gdi;
            // SetViewportOrgEx(-offX, -offY)：把"客户区坐标 (x,y)"
            // 映射到缓冲区的 (x-offX, y-offY) —— 于是整幅界面照常画，
            // 只有脏区那部分真的落在位图上。
            g.origin(-offX, -offY);
            try {
              win.onPaint(g);
            } finally {
              g.origin(0, 0);
            }
            buf.presentTo(Gdi(hdc), x: offX, y: offY);
          } finally {
            buf.dispose();
          }
        }
      } finally {
        // ★ endPaint 必须无条件执行（配对 BeginPaint，漏了会让 Windows
        //   认为这块区域永远"正在绘制"，后续 WM_PAINT 再不来）。
        //   _paintPending 同理：不复位的话 invalidate() 会被永久短路。
        endPaint(h, ps);
        calloc.free(ps);
        if (win != null) {
      win._paintPending = false;
      win._pendingLevel = 0;
    }
      }
      return 0;

    case wmEraseBkgnd:
      return 1; // 已全窗自绘，避免系统再刷一遍底色造成闪烁

    case wmSize:
      if (win != null) {
        final w = lp & 0xFFFF;
        final ht = (lp >> 16) & 0xFFFF;
        win._width = w;
        win._height = ht;
        win.onResize(w, ht);
        win.invalidate();
      }
      return 0;

    case wmSetFocus:
      if (win != null) {
        win._hasFocus = true;
        win.invalidate();
      }
      return 0;

    case wmKillFocus:
      if (win != null) {
        win._hasFocus = false;
        win.invalidate();
      }
      return 0;

    case wmMouseMove:
      if (win != null) {
        final (sx, sy) = clientXYOf(lp);
        final moved = win.mouseX != sx || win.mouseY != sy;
        win.mouseX = sx;
        win.mouseY = sy;
        if (moved) win.onMove(sx, sy);
      }
      return 0;

    case wmLButtonDown:
      if (win != null) {
        // ★ 用消息自带的坐标，不用 win.mouseX/mouseY（见 clientXYOf 的说明）。
        //   同时把它同步进 win，后续绘制里的 hover 判断才不会跟点击错开一帧。
        final (sx, sy) = clientXYOf(lp);
        win.mouseX = sx;
        win.mouseY = sy;
        win.onClick(sx, sy);
      }
      return 0;

    case wmLButtonUp:
      if (win != null) {
        final (sx, sy) = clientXYOf(lp);
        win.mouseX = sx;
        win.mouseY = sy;
        win.onRelease(sx, sy);
      }
      return 0;

    case wmMouseWheel:
      if (win != null) {
        final raw = (wp >> 16) & 0xFFFF;
        final sd = (raw & 0x8000) != 0 ? raw - 0x10000 : raw;
        // ★ 滚轮的 lParam 是**屏幕**坐标（与其它鼠标消息不同），
        //   必须 ScreenToClient 之后再判定，否则"鼠标在哪个面板上"永远判错。
        var (sx, sy) = clientXYOf(lp);
        final pt = calloc<Point>()
          ..ref.x = sx
          ..ref.y = sy;
        screenToClient(h, pt);
        sx = pt.ref.x;
        sy = pt.ref.y;
        calloc.free(pt);
        win.mouseX = sx;
        win.mouseY = sy;
        win.onWheel(sx, sy, sd);
      }
      return 0;

    case wmMouseHWheel:
      if (win != null) {
        final raw = (wp >> 16) & 0xFFFF;
        final hd = (raw & 0x8000) != 0 ? raw - 0x10000 : raw;
        // ★ 同样要 ScreenToClient。方向要**取反**：Windows 的横向滚轮
        //   "正数 = 往左"，而我们的约定是"正 = 往右"，不取反滚起来是反的。
        var (sx, sy) = clientXYOf(lp);
        final pt = calloc<Point>()
          ..ref.x = sx
          ..ref.y = sy;
        screenToClient(h, pt);
        sx = pt.ref.x;
        sy = pt.ref.y;
        calloc.free(pt);
        win.mouseX = sx;
        win.mouseY = sy;
        win.onHWheel(sx, sy, -hd);
      }
      return 0;

    case wmKeyDown:
      if (win != null) win.onKey(wp);
      return 0;

    case wmChar:
      if (win != null) win.onChar(wp);
      return 0;

    case wmClose:
      if (win != null && !win.onClosing()) return 0;
      destroyWindow(h);
      return 0;

    case wmDestroy:
      // ★ 绝对不能在任意窗口销毁时 postQuitMessage。
      //   postQuitMessage 的含义是"请求整个线程的消息循环结束"，它不分是
      //   哪个窗口。我们这里有多个窗口（主窗 + 扫榜设置子窗），
      //   子窗一关（比如点「开始扫榜」时它会自己 destroyWindow）就
      //   postQuitMessage → **整个程序退出**。
      //   这正是"点扫榜自动退出"的原因。
      //
      //   正确做法：这里只做清理；"是否该退出"由消息循环在
      //   `_windows.every((w) => w.isDisposed)` 时统一判断。
      WindowHost.byHwnd.remove(h);
      if (win != null) {
        win._disposed = true;
        win.onDestroyed();
      }
      // 让 App 知道少了一个窗口：清掉已销毁项、并唤醒主循环立刻重判。
      // （主循环自己会在"一个窗口都不剩"时结束，而不是靠 postQuitMessage。）
      App.instance?.notifyDestroyed();
      return 0;
  }
  return defWindowProcW(h, msg, wp, lp);
}

/// 把窗口的**非客户区（标题栏 + 边框）**染成深色，跟客户区的深色主题接上。
///
/// ★ 为什么必须做：不改的话，用户看到的是"上面一条亮白标题栏 + 下面一片深色"，
///   这是深色自绘程序最典型的割裂感，也是"看起来很廉价"的主因。
///   三条路一起走，哪条能用算哪条（覆盖 Win10 各 build 到 Win11）：
///     ① DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE=20)，失败再试 19；
///     ② Win11 再直接指定标题栏/文字颜色（属性 35/36）；
///     ③ SetWindowTheme(hwnd, "", "") 让主题引擎别用经典浅色控件主题。
void applyDarkTitleBar(int hwnd, {int captionColor = 0, bool dark = true}) {
  if (hwnd == 0) return;
  try {
    // ★ 切浅色主题时必须能**关掉**它：属性值传 0 就是"用系统默认（浅色）"。
    //   原来这里恒写 1 —— 那样一旦切到浅色主题，标题栏会留在深色，
    //   和客户区割裂（正是当初要修的那个"上黑下白"问题，方向反过来而已）。
    final p = calloc<Int32>()..value = dark ? 1 : 0;
    var r = dwmSetWindowAttribute(
        hwnd, dwmwaUseImmersiveDarkMode, p.cast(), 4);
    if (r != 0) {
      r = dwmSetWindowAttribute(
          hwnd, dwmwaUseImmersiveDarkModeOld, p.cast(), 4);
    }
    if (captionColor != 0 && dark) {
      final c = calloc<Int32>()..value = captionColor;
      dwmSetWindowAttribute(hwnd, dwmwaCaptionColor, c.cast(), 4);
      calloc.free(c);
    }
    calloc.free(p);
  } on Object {
    // 老系统没有 dwmapi 也照跑，只是标题栏保持浅色 —— 不能因此崩掉界面
  }
  try {
    final empty = ''.toNativeUtf16();
    setWindowTheme(hwnd, empty, empty);
    calloc.free(empty);
  } on Object {}
}

/// 让进程"DPI 感知"，否则系统会对整个窗口做位图拉伸 ——
/// 高分屏上直接表现为**字糊、发灰**（截图里那种"看不清"的感觉）。
void enableDpiAwareness() {
  try {
    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
    if (setProcessDpiAwarenessContext(-4) != 0) return;
  } on Object {}
  try {
    setProcessDPIAware();
  } on Object {}
}

/// 在当前 DPI 下，把"想要的**客户区**尺寸"换算成"该传给 CreateWindowExW
/// 的**外框**尺寸"。
///
/// ★ 不换算的后果：请求 1240x800 在 125% 缩放下客户区只剩 ~992x640，
///   布局按 1240 宽算就会横向溢出、竖向被裁 —— 看起来像"界面塌了"。
///   这是自绘 UI 里最容易被误判成"绘制 bug"的环境问题。
///
/// ★ 无边框窗口（[wsFramelessWindow]）**不需要这一步**：没有标题栏、
///   加上 `WM_NCCALCSIZE` 返回 0 之后，外框尺寸 == 客户区尺寸。
///   反倒是不该换算 —— 多算出来的那几十像素会让客户区比布局预期更宽，
///   右侧留一条背景色空档。
(int, int) clientToWindowSize(int clientW, int clientH,
    {int style = wsOverlappedWindow}) {
  final r = calloc<Rect>()
    ..ref.left = 0
    ..ref.top = 0
    ..ref.right = clientW
    ..ref.bottom = clientH;
  adjustWindowRectEx(r, style, 0, 0);
  final w = r.ref.width;
  final h = r.ref.height;
  calloc.free(r);
  return (w > 0 ? w : clientW, h > 0 ? h : clientH);
}

/// 给窗口接上现代外观的三件套：圆角（Win11）、极细描边、投影。
///
/// ★ 为什么无边框之后必须补这一步：系统的标题栏和边框一走，
///   窗口就变成"桌面上贴的一张纯色纸"——没有圆角、没有阴影、没有描边，
///   边缘和桌面糊在一起。这三个属性就是把它"浮起来"的关键。
/// ★ 全部包在 try 里：Win10 不认识属性 33/34，会返回非 0，忽略即可，
///   绝不能因为老系统就崩。
void applyModernFrame(int hwnd, {int borderColor = 0, bool shadow = true}) {
  if (hwnd == 0) return;
  try {
    final prefs = calloc<Int32>()..value = dwmwcpRound;
    dwmSetWindowAttribute(hwnd, dwmwaWindowCornerPreference, prefs.cast(), 4);
    calloc.free(prefs);
  } on Object {}
  if (borderColor != 0) {
    try {
      final c = calloc<Int32>()..value = borderColor;
      dwmSetWindowAttribute(hwnd, dwmwaBorderColor, c.cast(), 4);
      calloc.free(c);
    } on Object {}
  }
  if (shadow) {
    try {
      // 1px 边距：足以让 DWM 画出投影，又不会吃进任何可见内容。
      final m = calloc<Margins>()
        ..ref.cxLeftWidth = frameShadowMargin
        ..ref.cxRightWidth = frameShadowMargin
        ..ref.cyTopHeight = frameShadowMargin
        ..ref.cyBottomHeight = frameShadowMargin;
      dwmExtendFrameIntoClientArea(hwnd, m);
      calloc.free(m);
    } on Object {}
  }
}

/// 应用。负责注册窗口类、建窗、跑消息循环。
class App {
  App({this.className = 'RankScanApp'});

  /// 当前应用实例（子窗口要从这里取消息循环）。
  static App? instance;

  final String className;
  final List<AppWindow> _windows = [];
  Timer? _pump;
  bool _classRegistered = false;
  int _hInstance = 0;

  static const int _maxMessagesPerTick = 64;

  int get hInstance => _hInstance;

  /// 启动应用并创建主窗口；返回的 Future 在**所有**窗口关闭后完成。
  Future<void> run(AppWindow win,
      {int width = 1180, int height = 760, bool center = true}) async {
    enableDpiAwareness();
    instance = this;
    _hInstance = getModuleHandleW(nullptr);
    // 记下主线程 id：窗口过程里没法可靠拿到它，而"唤醒消息循环"要用。
    _threadId = getCurrentThreadId();
    _ensureClass();

    final hwnd = _create(win, win.title, width, height, center: center);
    showWindow(hwnd, swShow);
    updateWindow(hwnd);
    win.onResize(win.width, win.height);

    return _pumpLoop();
  }

  /// 探针用：只建窗、不跑消息循环（建完就能量尺寸、查可见性）。
  /// 这是为了把"环境问题"和"消息循环问题"分开测。
  int runProbe(AppWindow win,
      {int width = 1180, int height = 760, bool center = true}) {
    instance = this;
    _hInstance = getModuleHandleW(nullptr);
    _threadId = getCurrentThreadId();
    _ensureClass();
    final hwnd = _create(win, win.title, width, height, center: center);
    showWindow(hwnd, swShow);
    updateWindow(hwnd);
    win.onResize(win.width, win.height);
    return hwnd;
  }

  /// 探针用：清掉探针建的窗口（不跑消息循环，所以直接 destroy）。
  void probeQuit() {
    for (final w in _windows.toList()) {
      if (w.hwnd != 0) destroyWindow(w.hwnd);
    }
    _windows.clear();
    disposeFontCache();
    instance = null;
  }

  /// 开一个**子窗口**（非模态）。
  ///
  /// ★ 不用 Win32 模态对话框：模态要跑嵌套消息循环，会和我们这套
  ///   "Timer 分片 + PeekMessage" 的实现互相饿死（外层 Timer 拿不到消息，
  ///   界面直接冻住）。子窗口交互上等价，且没有这个陷阱。
  ///
  /// ★ [ownerHwnd] 会作为 CreateWindowExW 的 `hWndParent` 传下去 ——
  ///   这样主窗最小化时子窗跟随、主窗挡住时子窗浮在主窗之上。
  ///   之前这里传的是 0（无 owner），表现为"设置窗最小化后藏在主窗下面
  ///   找不到了"。
  AppWindow runChild(AppWindow child,
      {int width = 700, int height = 600, int? ownerHwnd}) {
    // 先清掉已经销毁的子窗，否则"都关了"的判定会被它拖住。
    _windows.removeWhere((w) => w.isDisposed);
    _create(child, child.title, width, height,
        center: ownerHwnd == null, ownerHwnd: ownerHwnd ?? 0);
    showWindow(child.hwnd, swShow);
    updateWindow(child.hwnd);
    child.onResize(child.width, child.height);
    return child;
  }

  /// 主题切换后重刷所有窗口。
  ///
  /// 做两件事：
  ///   ① **非客户区**（无边框窗口的 1px 描边 / 带系统标题栏时的标题栏色）——
  ///      这两个是 DWM 属性，只在建窗时设过，不重刷就会留着旧主题的颜色；
  ///   ② 每个窗口整窗重绘 —— 客户区的颜色全部来自 `Palette`，
  ///      不重绘等于"数据换了、像素没换"。
  void refreshTheme() {
    for (final w in _windows.toList()) {
      if (w.isDisposed || w.hwnd == 0) continue;
      try {
        if (w.frameless) {
          applyModernFrame(w.hwnd, borderColor: paletteLineBgr);
        } else {
          applyDarkTitleBar(w.hwnd,
              captionColor: captionBgBgr, dark: Palette.isDark);
        }
      } on Object {
        // 老系统上 DWM 属性可能不支持 —— 不能因为外观问题让界面崩
      }
      w.invalidate();
    }
  }

  /// 某个窗口被销毁后调用（由窗口过程触发），让"都关了"的判定及时生效。
  void notifyDestroyed() {
    _windows.removeWhere((w) => w.isDisposed);
    if (_threadId != 0) postThreadMessageW(_threadId, wmAppWake, 0, 0);
  }

  void _ensureClass() {
    if (_classRegistered) return;
    final proc = Pointer.fromFunction<WndProcNative>(_wndProc, 0);
    final cls = calloc<WndClassW>();
    cls.ref.style = csHredraw | csVredraw;
    cls.ref.lpfnWndProc = proc;
    cls.ref.hInstance = _hInstance;
    cls.ref.hCursor = loadCursorW(0, idcArrow);
    cls.ref.lpszClassName = className.toNativeUtf16();
    final atom = registerClassW(cls);
    calloc.free(cls.ref.lpszClassName);
    calloc.free(cls);
    if (atom == 0) throw StateError('RegisterClassW 失败');
    _classRegistered = true;
  }

  int _create(AppWindow win, String title, int width, int height,
      {bool center = true, int ownerHwnd = 0}) {
    final pcls = className.toNativeUtf16();
    final ptitle = title.toNativeUtf16();

    final style = win.frameless
        ? (win.resizable ? wsFramelessWindow : wsFramelessDialog)
        : wsOverlappedWindow;

    // ★ 传进来的 width/height 是**客户区**目标尺寸（布局按它算），
    //   但带系统边框的 CreateWindowExW 要的是**外框**尺寸 —— 不补标题栏/边框
    //   的差，客户区会比预期小一圈；叠加 DPI 缩放后，横向溢出、竖向被裁，
    //   界面看起来就像"塌了"。
    //   无边框窗口（WM_NCCALCSIZE 返回 0）外框 == 客户区，跳过换算。
    var (outerW, outerH) =
        win.frameless ? (width, height) : clientToWindowSize(width, height, style: style);

    // 屏幕装不下就缩到工作区（留 24px 余量），别让窗口大到按钮够不着。
    final (waW, waH) = _workArea;
    if (outerW > waW - 24) outerW = waW - 24;
    if (outerH > waH - 24) outerH = waH - 24;

    var x = 120, y = 90;
    if (center) {
      x = ((_screenWidth - outerW) ~/ 2).clamp(0, 3000);
      y = ((_screenHeight - outerH) ~/ 2).clamp(0, 2000);
      if (x < 0) x = 0;
      if (y < 0) y = 0;
    }
    final hwnd = createWindowExW(0, pcls, ptitle, style, x, y,
        outerW, outerH, ownerHwnd, 0, _hInstance, nullptr);
    calloc.free(pcls);
    calloc.free(ptitle);
    if (hwnd == 0) throw StateError('CreateWindowExW 失败');

    if (win.frameless) {
      // 无边框：系统不画标题栏，圆角/阴影/描边全部自己接。
      applyModernFrame(hwnd, borderColor: paletteLineBgr);
    } else {
      // 带系统标题栏的老路径：把标题栏染成与客户区主题一致（深/浅都跟着走）。
      applyDarkTitleBar(hwnd,
          captionColor: captionBgBgr, dark: Palette.isDark);
    }
    redrawWindow(hwnd, nullptr, 0,
        rdwInvalidate | rdwErase | rdwFrame | rdwUpdatenow);

    win.hwnd = hwnd;
    WindowHost.byHwnd[hwnd] = win;
    _windows.add(win);

    // ★ 无边框窗口第一次 WM_NCCALCSIZE 发生在 CreateWindowExW 内部，
    //   那时的客户区还是"带边框"的尺寸；这里再取一次 GetClientRect
    //   拿到真实值，避免首帧按错误尺寸分配 BackBuffer。
    final rc = calloc<Rect>();
    getClientRect(hwnd, rc);
    win._width = rc.ref.width;
    win._height = rc.ref.height;
    calloc.free(rc);
    return hwnd;
  }

  /// 分片消息循环。所有窗口共用这一个。
  Future<void> _pumpLoop() {
    final done = Completer<void>();
    final msg = calloc<Msg>();

    void finish(Timer t) {
      t.cancel();
      calloc.free(msg);
      disposeFontCache();
      instance = null;
      if (!done.isCompleted) done.complete();
    }

    _pump = Timer.periodic(const Duration(milliseconds: 8), (t) {
      var n = 0;
      while (n < _maxMessagesPerTick && peekMessageW(msg, 0, 0, 0, pmRemove) != 0) {
        // WM_QUIT 是"整个循环该结束了"的唯一信号。
        // ★ 注意：这个信号现在**只**由 App.quit() 显式发出（postQuitMessage），
        //   不再由"某个窗口被销毁"顺手发出 —— 否则关掉子窗口会退出整个程序。
        if (msg.ref.message == 0x0012) {
          finish(t);
          return;
        }
        // 自定义唤醒消息没有目标窗口，交给 defWindowProc 会被丢掉，直接跳过。
        if (msg.ref.message == wmAppWake) {
          n++;
          continue;
        }
        translateMessage(msg);
        dispatchMessageW(msg);
        n++;
      }
      if (_windows.isEmpty || _windows.every((w) => w.isDisposed)) {
        finish(t);
      }
    });
    return done.future;
  }

  void _forget(AppWindow w) {
    _windows.remove(w);
  }

  /// 主屏工作区尺寸（去掉任务栏）。窗口居中要按**工作区**而不是全屏算，
  /// 否则窗口下半截会藏到任务栏底下。
  ///
  /// ★ 之前这里用 `GetCursorPos().x > 0 ? 1920 : 1920` —— 不管怎样都返回
  ///   1920x1080，在小屏/高 DPI 上会把窗口摆到屏幕外。现在改成真测量。
  (int, int) get _workArea {
    final r = calloc<Rect>();
    final ok = systemParametersInfoW(48, 0, r.cast(), 0); // SPI_GETWORKAREA
    if (ok != 0 && r.ref.width > 0 && r.ref.height > 0) {
      final w = r.ref.width, h = r.ref.height;
      calloc.free(r);
      return (w, h);
    }
    calloc.free(r);
    final w = getSystemMetrics(0);
    final h = getSystemMetrics(1);
    return (w > 0 ? w : 1280, h > 0 ? h : 800);
  }

  int get _screenWidth => _workArea.$1;

  int get _screenHeight => _workArea.$2;

  /// 请求退出（关闭所有窗口）。
  ///
  /// ★ 这是**唯一**能让消息循环结束的入口。窗口过程不再自动退出程序，
  ///   所以"关掉一个子窗口把整个程序带走"这类事故不会再发生。
  void quit() {
    for (final w in _windows.toList()) {
      if (!w.isDisposed && w.hwnd != 0) destroyWindow(w.hwnd);
    }
    _windows.removeWhere((w) => w.isDisposed);
    if (_windows.isEmpty && _threadId != 0) {
      postThreadMessageW(_threadId, wmAppWake, 0, 0);
    }
  }
}

/// 打开文件或 URL（用系统默认程序）。成功返回 true。
bool openExternal(String target) {
  final op = 'open'.toNativeUtf16();
  final file = target.toNativeUtf16();
  final r = shellExecuteW(0, op, file, nullptr, nullptr, swShowNormal);
  calloc.free(op);
  calloc.free(file);
  return r > 32; // ShellExecuteW 约定：返回值 >32 才算成功
}

/// 是否运行在 Windows 上（非 Windows 直接拒绝启动 GUI）。
bool get platformSupportsGui => Platform.isWindows;

/// 离屏自检用：在**没有真实 HWND** 的情况下设置窗口客户区尺寸。
///
/// [AppWindow._width] / `_height` 平时由窗口过程在 `WM_SIZE` 里写，
/// 但自检要绕开真窗口，所以这里开一个受控入口 ——
/// 而不是把它改成 public 字段（那会让"谁能改宽高"变成无约束）。
void setSizeForTest(AppWindow w, int width, int height) {
  w.setSizeForTest(width, height);
}

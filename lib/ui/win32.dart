/// Win32 ffi 绑定 —— 只绑定这个软件真正用到的那部分 API。
///
/// ★ 两条 ffi 硬约束（踩过）：
///   ① `lookupFunction` 里 `IntPtr`/`UintPtr` 的 native 与 dart 签名必须写一致，
///      不能一边 `IntPtr` 一边 Dart `int`，否则报 "not a valid and instantiated
///      subtype of NativeType"。
///   ② `Pointer.fromFunction` **只接受顶层静态函数**，闭包/局部函数一律报
///      "fromFunction expects a static function"。所以窗口过程必须是顶层函数，
///      UI 状态也就只能放全局 —— 这一点决定了整个 UI 层的组织方式。
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

export 'package:ffi/ffi.dart' show Utf16;

// ── 库 ──
// ignore: non_constant_identifier_names
final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
// ignore: non_constant_identifier_names
final DynamicLibrary gdi32 = DynamicLibrary.open('gdi32.dll');
// ignore: non_constant_identifier_names
final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
// ignore: non_constant_identifier_names
final DynamicLibrary shell32 = DynamicLibrary.open('shell32.dll');
// ★ ole32：只借一个 CoTaskMemFree（释放 shell 返回的 PIDL）。
//   **不要**因为它姓 COM 就以为打开了 COM —— 只查一个释放函数而已。
// ignore: non_constant_identifier_names
final DynamicLibrary ole32 = DynamicLibrary.open('ole32.dll');
// ignore: non_constant_identifier_names
final DynamicLibrary comdlg32 = DynamicLibrary.open('comdlg32.dll');
// ignore: non_constant_identifier_names
final DynamicLibrary uxtheme = DynamicLibrary.open('uxtheme.dll');
// ignore: non_constant_identifier_names
final DynamicLibrary dwmapi = DynamicLibrary.open('dwmapi.dll');
// ★ advapi32：查注册表（`RegQueryValueExW`）—— 用来找 http 关联的真实浏览器
//   可执行文件路径。**不用** `AssocQueryStringW` 是因为 shlwapi 在部分精简
//   系统上缺失，而 advapi32 是所有 Windows 都在的核心库。
// ignore: non_constant_identifier_names
final DynamicLibrary advapi32 = DynamicLibrary.open('advapi32.dll');

// ★ GetLastError：Win32 调用失败后拿错误码。用它把"失败了"变成"为什么失败"
//   （例如无交互桌面会话时 RegisterClassW 会失败，错误码能区分这种情况）。
final getLastError =
    kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');

// ── user32 ──
/// `GetWindowThreadProcessId`：窗口 → 进程 id。
final getWindowThreadProcessId = user32.lookupFunction<
    Uint32 Function(IntPtr, Pointer<Uint32>),
    int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');

/// `OpenProcess`：拿进程句柄（只要求 PROCESS_QUERY_LIMITED_INFORMATION）。
final openProcess = kernel32.lookupFunction<
    IntPtr Function(Uint32, Int32, Uint32),
    int Function(int, int, int)>('OpenProcess');

final closeHandle =
    kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'CloseHandle');

/// `QueryFullProcessImageNameW`：取进程的可执行文件完整路径。
final queryFullProcessImageNameW = kernel32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>),
    int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)>(
    'QueryFullProcessImageNameW');

final getModuleHandleW = kernel32.lookupFunction<
    IntPtr Function(Pointer<Utf16>),
    int Function(Pointer<Utf16>)>('GetModuleHandleW');

final registerClassW = user32.lookupFunction<
    Uint16 Function(Pointer<WndClassW>),
    int Function(Pointer<WndClassW>)>('RegisterClassW');

final createWindowExW = user32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, IntPtr, IntPtr, IntPtr,
        IntPtr, IntPtr, IntPtr, IntPtr, IntPtr, Pointer<Void>),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, int, int, int,
        int, Pointer<Void>)>('CreateWindowExW');

final defWindowProcW = user32.lookupFunction<
    IntPtr Function(IntPtr, Uint32, UintPtr, IntPtr),
    int Function(int, int, int, int)>('DefWindowProcW');

final showWindow = user32.lookupFunction<Int32 Function(IntPtr, Int32),
    int Function(int, int)>('ShowWindow');

final updateWindow = user32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('UpdateWindow');

/// 窗口当前是否处于最小化状态（主窗恢复被最小化的子窗时用来判断）。
final isIconic = user32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('IsIconic');

/// 移动/缩放/改 Z 序窗口。无边框窗首帧重算非客户区后会带 SWP_* 标志调用
/// （不移动、不改尺寸、不激活，只让系统按新边框重算一遍）。
final setWindowPos = user32.lookupFunction<
    Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int)>('SetWindowPos');

/// 把窗口带到前台（用户重复点"数据管理"时把已开的那扇窗拎上来）。
///
/// ★ 系统对"别的进程抢前台"有限制，但**同进程内**调用是允许的，
///   所以这里不会失败；返回 0 也不影响功能（窗口只是没被激活）。
final bringWindowToTop = user32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('BringWindowToTop');

final setForegroundWindow = user32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('SetForegroundWindow');

/// `GetForegroundWindow`：当前前台窗口句柄（没有则 0）。
///
/// ★ 用途之一是**测试模态对话框**：`SHBrowseForFolderW` 会阻塞调用线程，
///   只能从另一个 isolate 给"前台窗口"发 `WM_CLOSE` 把它关掉，
///   以此判断"框到底弹出来没有"（见 `bin/_probe_folder_dialog.dart`）。
final getForegroundWindow =
    user32.lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');

/// `GetActiveWindow`：**本线程**的活动窗口（没有则 0）。
final getActiveWindow =
    user32.lookupFunction<IntPtr Function(), int Function()>('GetActiveWindow');

final setWindowTextW = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>),
    int Function(int, Pointer<Utf16>)>('SetWindowTextW');

final peekMessageW = user32.lookupFunction<
    Int32 Function(Pointer<Msg>, IntPtr, Uint32, Uint32, Uint32),
    int Function(Pointer<Msg>, int, int, int, int)>('PeekMessageW');

final translateMessage = user32.lookupFunction<Int32 Function(Pointer<Msg>),
    int Function(Pointer<Msg>)>('TranslateMessage');

final dispatchMessageW = user32.lookupFunction<IntPtr Function(Pointer<Msg>),
    int Function(Pointer<Msg>)>('DispatchMessageW');

final postQuitMessage =
    user32.lookupFunction<Void Function(Int32), void Function(int)>('PostQuitMessage');

/// 往**线程**（而不是某个窗口）的消息队列里投一条消息。
/// 用来在没有窗口可点时唤醒消息循环 —— `PostMessage` 需要一个 hwnd，
/// 而"所有窗口都关了"这种情况下恰恰没有。
final postThreadMessageW = user32.lookupFunction<
    Int32 Function(Uint32, Uint32, UintPtr, IntPtr),
    int Function(int, int, int, int)>('PostThreadMessageW');

/// 当前线程 id。kernel32 导出。
final getCurrentThreadId =
    kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');

final destroyWindow = user32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('DestroyWindow');

final invalidateRect = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Rect>, Int32),
    int Function(int, Pointer<Rect>, int)>('InvalidateRect');

final beginPaint = user32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<PaintStruct>),
    int Function(int, Pointer<PaintStruct>)>('BeginPaint');

final endPaint = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<PaintStruct>),
    int Function(int, Pointer<PaintStruct>)>('EndPaint');

final getClientRect = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Rect>),
    int Function(int, Pointer<Rect>)>('GetClientRect');

/// 窗口外框矩形（含标题栏与边框）。用来对比"请求的客户区尺寸"。
/// `GetConsoleWindow`：本进程附着的控制台窗口句柄（没有则 0）。
final getConsoleWindow =
    kernel32.lookupFunction<IntPtr Function(), int Function()>('GetConsoleWindow');

/// `FreeConsole`：**主动脱离**父控制台。
///
/// ★★ 为什么必须调（用户反馈"多了一个无用窗口，关掉它软件也一起关"）：
///   从 `cmd` 或 `.cmd` 里启动一个 **GUI 程序**时，Windows 会把它**附着到父控制台**。
///   那个控制台窗口（标题就是本程序的完整路径、黑底、带滚动条）看起来像个
///   "多出来的无用窗口"；而一旦关掉它，系统会向所有附着进程发 `CTRL_CLOSE`
///   —— 整个程序跟着一起死。
///   GUI 程序本来不需要控制台，所以启动时直接脱离：窗口还在（那是 cmd 的），
///   但**关它不会再杀掉我们**。
final freeConsole = kernel32.lookupFunction<Int32 Function(), int Function()>(
    'FreeConsole');

/// **浏览器可执行文件名**（小写，不带 .exe）。
///
/// ★★ 为什么按**进程名**认而不是按窗口类名（我上一版就是按类名，有假阳性）：
///   `Chrome_WidgetWin_1` 是**所有 Chromium 系**的窗口类 —— 包括 Electron 应用
///   （WorkBuddy、VS Code、各种客户端）。按类名找，"找到"的可能是**别的程序的窗口**，
///   于是明明没打开浏览器却报成功。进程名才是"这是不是一个浏览器"的硬判据。
const browserProcessNames = {
  'msedge', 'chrome', 'firefox', 'brave', 'vivaldi', 'opera', 'chromium',
  'iexplore', '360se', '360chrome', 'sogouexplorer', 'maxthon', 'qqbrowser',
};

/// 浏览器**空白页**的标题特征 —— 命中就说明"窗口起来了但没导航过去"。
const browserBlankTitleMarkers = [
  '新建标签页', '新标签页', '新建选项卡', '新建标签', '起始页', '新分页',
  'new tab', 'about:blank', 'about:newtab',
  // ★ "无标题" 也算：那是**页面还没加载完**时浏览器的占位标题
  //   （实测 Edge 刚起来时标题是"无标题 - 用户配置 1 - Microsoft Edge"，
  //   这时候报"已打开"就是假成功 —— 得继续等它变成真正的页面标题）。
  '无标题', 'untitled',
];

/// 取窗口所属进程的可执行文件名（小写、不含扩展名）；拿不到返回 ''。
String processNameOfWindow(int hwnd) {
  final pidOut = calloc<Uint32>();
  var hProc = 0;
  final buf = calloc<Uint16>(1024);
  try {
    getWindowThreadProcessId(hwnd, pidOut);
    final pid = pidOut.value;
    if (pid == 0) return '';
    // PROCESS_QUERY_LIMITED_INFORMATION = 0x1000（Vista+，权限要求最低）
    hProc = openProcess(0x1000, 0, pid);
    if (hProc == 0) return '';
    final n = calloc<Uint32>()..value = 1024;
    final ok = queryFullProcessImageNameW(hProc, 0, buf.cast<Utf16>(), n);
    calloc.free(n);
    if (ok == 0) return '';
    final sb = StringBuffer();
    for (var i = 0; i < 1024; i++) {
      final c = buf[i];
      if (c == 0) break;
      sb.writeCharCode(c);
    }
    final full = sb.toString();
    final slash = full.lastIndexOf(RegExp(r'[\\/]'));
    var base = slash >= 0 ? full.substring(slash + 1) : full;
    if (base.toLowerCase().endsWith('.exe')) {
      base = base.substring(0, base.length - 4);
    }
    return base.toLowerCase();
  } on Object {
    return '';
  } finally {
    if (hProc != 0) closeHandle(hProc);
    calloc.free(pidOut);
    calloc.free(buf);
  }
}

/// 列出**所有**可见的浏览器顶层窗口（类名 + 进程名都对的那种）。
///
/// ★ 为什么要"所有"：只看第一个会挑到 Edge 的辅助窗口或"还原页面"提示 ——
///   两个都踩过（日志里出现过 `(标题为空)` 和 `还原页面`）。
///   调用方应该按**标题对不对得上**去挑。
List<int> browserWindows() {
  final out = <int>[];
  final proc = Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_findAllCb, 1);
  _allSink = out;
  try {
    enumWindows(proc, 0);
  } on Object {
    // 枚举失败就当没有
  } finally {
    _allSink = null;
  }
  return out;
}

List<int>? _allSink;

int _findAllCb(int hwnd, int lparam) {
  final sink = _allSink;
  if (sink == null) return 1;
  if (isWindowVisible(hwnd) == 0) return 1;
  final (cls, title) = windowClassAndTitle(hwnd);
  if (title.isEmpty) return 1;
  if (!browserWindowClasses.contains(cls)) return 1;
  if (!browserProcessNames.contains(processNameOfWindow(hwnd))) return 1;
  sink.add(hwnd);
  return 1; // 继续枚举（要全部）
}

/// 找**可见的浏览器顶层窗口**（没有则返回 0）。
///
/// ★ 为什么要它："ShellExecuteW 返回 42"只代表"请求交出去了"，
///   不代表"页面上真的出现了" —— 用户报"点了没反应"时，必须**去找那个窗口**。
int findBrowserWindow() {
  var found = 0;
  final proc = Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_findBrowserCb, 1);
  _findSink = (h) {
    found = h;
  };
  enumWindows(proc, 0);
  _findSink = null;
  return found;
}

void Function(int hwnd)? _findSink;

int _findBrowserCb(int hwnd, int lparam) {
  if (_findSink == null) return 1;
  if (isWindowVisible(hwnd) == 0) return 1;
  final (cls, title) = windowClassAndTitle(hwnd);
  // ★★ 三个条件**都要满足**（我上一版只查了进程名，于是挑到了 Edge 的
  //   辅助窗口 —— 标题为空，而空标题不含"新建标签页"特征，
  //   结果被判成"已加载"，日志里那句"(标题为空)"就是这么来的）：
  //     ① 窗口类名是浏览器窗口类（排除同进程的辅助/工具窗口）；
  //     ② 进程名是浏览器（排除 Electron 应用 —— 它们的窗口类也叫
  //        `Chrome_WidgetWin_1`）；
  //     ③ 标题非空（真浏览器窗口总有标题）。
  if (title.isEmpty) return 1;
  if (!browserWindowClasses.contains(cls)) return 1;
  if (!browserProcessNames.contains(processNameOfWindow(hwnd))) return 1;
  _findSink!(hwnd);
  return 0; // 停止枚举
}

/// 找**"提权实例冲突"对话框**（Edge 弹的那个"现有实例正在以提升的权限运行"）。
///
/// ★ 判据用**窗口类 `#32770`（系统对话框）+ 标题含 Microsoft Edge** ——
///   这两个一起用才不会误判（普通 Edge 窗口的类名是 `Chrome_WidgetWin_1`）。
///   实测抓到的那个框，类名就是 `#32770`、标题是 `Microsoft Edge`。
///
/// 返回对话框句柄（没有则 0）。
int findBrowserElevationDialog() {
  var found = 0;
  final proc = Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_elevCb, 1);
  _elevSink = (h) {
    found = h;
  };
  try {
    enumWindows(proc, 0);
  } on Object {
    // 枚举失败就当没有
  } finally {
    _elevSink = null;
  }
  return found;
}

void Function(int hwnd)? _elevSink;

int _elevCb(int hwnd, int lparam) {
  if (_elevSink == null) return 1;
  if (isWindowVisible(hwnd) == 0) return 1;
  final (cls, title) = windowClassAndTitle(hwnd);
  if (cls != '#32770') return 1; // 系统对话框
  if (!title.toLowerCase().contains('microsoft edge')) return 1;
  _elevSink!(hwnd);
  return 0;
}

/// 这个窗口标题看起来是不是"空白页/新建标签页"（= 没导航过去）。
bool isBlankBrowserTitle(String title) {
  // ★ 空标题也算"没加载" —— 我上一版漏了这一条，于是"(标题为空)"被当成成功。
  if (title.trim().isEmpty) return true;
  final t = title.toLowerCase();
  for (final m in browserBlankTitleMarkers) {
    if (t.contains(m)) return true;
  }
  return false;
}

/// 浏览器窗口的类名（配合 [processNameOfWindow] 一起判，两个都要对）。
const browserWindowClasses = {
  'Chrome_WidgetWin_1', // Edge / Chrome / 各类 Chromium
  'MozillaWindowClass', // Firefox
  'IEFrame', // IE 内核
};

/// `OpenProcessToken`：拿进程的访问令牌。
final getCurrentProcessId = kernel32.lookupFunction<Uint32 Function(),
    int Function()>('GetCurrentProcessId');

final openProcessToken = advapi32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
    int Function(int, int, Pointer<IntPtr>)>('OpenProcessToken');

/// `GetTokenInformation`：读令牌里的信息（这里只用来读"是否提权"）。
// ★ Dart 那侧的指针元素类型要用 `Uint32`（不是 `Uint32`）——
//   本项目其它绑定的写法都是这样（`Pointer<Uint32>`），
//   写错会报 "invalid-type"，而且报错指向的是**原生**那半截签名，很容易看歪。
final getTokenInformation = advapi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
    int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)>(
    'GetTokenInformation');

const int tokenQuery = 0x0008;
const int tokenElevation = 20; // TOKEN_INFORMATION_CLASS.TokenElevation

/// 某个进程是不是**以提升的权限**（管理员）在跑。
///
/// ★★ 这是**读令牌**得出的结论，不是"能不能打开它"那种猜测：
///   之前那版用 `OpenProcess(PROCESS_QUERY_INFORMATION)` 是否被拒来判断，
///   拿 explorer / svchost / pid 4 一校准就发现不成立
///   （SYSTEM 级的 svchost 照样打得开）。读令牌才是硬证据。
bool isProcessElevated(int pid) {
  if (pid == 0) return false;
  var hProc = 0, hTok = 0;
  final tok = calloc<IntPtr>();
  final buf = calloc<Uint8>(4);
  final ret = calloc<Uint32>();
  try {
    // 0x1000 = PROCESS_QUERY_LIMITED_INFORMATION（跨完整性级别也允许）
    hProc = openProcess(0x1000, 0, pid);
    if (hProc == 0) return false;
    if (openProcessToken(hProc, tokenQuery, tok) == 0) return false;
    hTok = tok.value;
    if (getTokenInformation(hTok, tokenElevation, buf.cast(), 4, ret) == 0) {
      return false;
    }
    return buf[0] != 0; // TOKEN_ELEVATION.TokenIsElevated
  } on Object {
    return false;
  } finally {
    if (hTok != 0) closeHandle(hTok);
    if (hProc != 0) closeHandle(hProc);
    calloc.free(tok);
    calloc.free(buf);
    calloc.free(ret);
  }
}

/// 本进程自己是不是提权运行的。
bool selfIsElevated() => isProcessElevated(getCurrentProcessId());

/// 浏览器是不是**以管理员身份**在跑（读令牌得出的结论，不是猜的）。
///
/// ★ 用途是**诊断与文案**：真提权时日志里写明白，
///   用户看到的提示也能说"已核实"而不是"可能"。
///   ★ 不用它来决定"要不要试" —— 试了也没关系，程序会替用户点掉那个框；
///     而"判错就永远不试"的代价更大（第 37 轮的教训）。
bool browserIsElevated() {
  for (final pid in browserProcessIds()) {
    if (isProcessElevated(pid)) return true;
  }
  return false;
}

/// `GetDlgItem`：按控件 id 拿对话框里的子控件句柄。
final getDlgItem = user32.lookupFunction<IntPtr Function(IntPtr, Int32),
    int Function(int, int)>('GetDlgItem');

/// 点掉"提权实例冲突"对话框里的「**是(Y)**」。
///
/// ★★ **主流程刻意不用它**（第 39 轮，用户录屏为证）：那个「是」=
///   "用普通权限重启 Edge"，点下去会把用户**开着的所有 Edge 窗口一起关掉** ——
///   代价远大于收益，而且页面照样没打开。
///   **那个框是 Edge 自己的，不该由我们去点。**
///
///   留着它的原因：① `bin/_probe_click_dialog.dart` 用它做端到端验证
///   （自己弹一个标准 Yes/No 框，断言返回值 = 6/IDYES）；
///   ② 万一将来需要"自动处理那个框"，这段是**已经被验证过**的实现。
///
/// 两条路都发一遍（幂等 —— 框关掉之后第二条自然无效）：
///   ① `GetDlgItem(IDYES)` 拿到按钮 → `BM_CLICK`；
///   ② 给对话框发 `WM_COMMAND(IDYES)`（标准 MessageBox 的常规做法）。
bool clickElevationDialogYes(int dlg) {
  if (dlg == 0) return false;
  const wmCommand = 0x0111, idYes = 6, bmClick = 0x00F5;
  var sent = false;
  try {
    final btn = getDlgItem(dlg, idYes);
    if (btn != 0) {
      sendMessageW(btn, bmClick, 0, 0);
      sent = true;
    }
    sendMessageW(dlg, wmCommand, idYes, 0);
    sent = true;
  } on Object {
    return sent;
  }
  return sent;
}

/// 列出所有**属于浏览器进程**的窗口的 pid（任何窗口类都算）。
///
/// ★ 为什么不用 [browserWindows]：那个要求窗口类是 `Chrome_WidgetWin_1`，
///   而 Edge 在"只有后台进程、没有顶层窗口"时**只剩辅助窗口**
///   （日志里出现过 `EdgeUiInputTopWndClass`）—— 那种状态恰恰是最需要认出来的。
List<int> browserProcessIds() {
  final out = <int>{};
  final proc = Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_pidCb, 1);
  _pidSink = out;
  try {
    enumWindows(proc, 0);
  } on Object {
    // 枚举失败就当没有
  } finally {
    _pidSink = null;
  }
  return out.toList();
}

Set<int>? _pidSink;

int _pidCb(int hwnd, int lparam) {
  final sink = _pidSink;
  if (sink == null) return 1;
  final pid = processIdOfWindow(hwnd);
  if (pid == 0) return 1;
  // 进程名要查一次，但只在"还没收过这个 pid"时查（去重）
  if (sink.contains(pid)) return 1;
  final name = processNameOfWindow(hwnd);
  if (browserProcessNames.contains(name)) sink.add(pid);
  return 1;
}

/// 窗口 → 进程 id（0 = 拿不到）。
int processIdOfWindow(int hwnd) {
  final out = calloc<Uint32>();
  try {
    getWindowThreadProcessId(hwnd, out);
    return out.value;
  } on Object {
    return 0;
  } finally {
    calloc.free(out);
  }
}

// ★ 这里原本有一个 `browserRunningElevated()`（用
//   `OpenProcess(PROCESS_QUERY_INFORMATION)` 是否被拒来判"对方提权"）。
//   **它被撤掉了**：拿 explorer / svchost / pid 4 校准过 ——
//   SYSTEM 级别的 svchost 照样能打开，而且 `GetLastError()` 会被后续
//   FFI 调用冲掉（实测拿到 0 而不是 5）。判据不成立。
//   一个会误判的"事前预检"比没有预检更糟。改用"认出那个框之后**替用户点『是』**"。

/// 从注册表读出 http 协议关联的**浏览器可执行文件完整路径**（拿不到返回 null）。
///
/// 走 `HKEY_CLASSES_ROOT\http\shell\open\command` 的默认值 ——
/// 形如 `"C:\...\msedge.exe" --single-argument %1` 或 `"C:\...\chrome.exe" -- "%1"`。
/// 只用 advapi32（不依赖可能缺失的 shlwapi）。
String? defaultBrowserExe() {
  final sub = 'http\\shell\\open\\command'.toNativeUtf16();
  final phk = calloc<IntPtr>();
  final buf = calloc<Uint8>(4096);
  try {
    var rc = regOpenKeyExW(hkeyClassesRoot | keyWow64_64Key, sub, 0, keyRead, phk);
    if (rc != 0) {
      rc = regOpenKeyExW(hkeyClassesRoot, sub, 0, keyRead, phk);
    }
    if (rc != 0) return null;
    final size = calloc<Uint32>()..value = 4096;
    final type = calloc<Uint32>();
    final q = regQueryValueExW(phk.value, nullptr, nullptr, type, buf, size);
    calloc.free(size);
    calloc.free(type);
    if (q != 0) return null;
    final sb = StringBuffer();
    for (var i = 0; i + 1 < 4096; i += 2) {
      final c = buf[i] | (buf[i + 1] << 8);
      if (c == 0) break;
      sb.writeCharCode(c);
    }
    final cmd = sb.toString().trim();
    if (cmd.isEmpty) return null;
    if (cmd.startsWith('"')) {
      final end = cmd.indexOf('"', 1);
      if (end > 1) return cmd.substring(1, end);
    }
    final sp = cmd.indexOf(' ');
    return sp > 0 ? cmd.substring(0, sp) : cmd;
  } on Object {
    return null;
  } finally {
    if (phk.value != 0) regCloseKey(phk.value);
    calloc.free(sub);
    calloc.free(phk);
    calloc.free(buf);
  }
}

/// 换一条路打开网址：**直接起注册表里那个浏览器 exe**，把地址当参数给它。
///
/// ★ 为什么还要这一手：`ShellExecuteW` 走的是 shell 关联那一层，
///   而用户机器上实测它**把 URL 弄丢了**（Edge 起来了却停在"新建标签页"）。
///   绕开 shell 直接起 exe，能救回"关联这一环坏了"的情况。
///   ★ 仍然**只起系统默认浏览器**（注册表里那个），不是自己挑浏览器。
bool launchBrowserDirect(String url, {bool forceNewWindow = false}) {
  final exe = defaultBrowserExe();
  if (exe == null) return false;
  final appPtr = exe.toNativeUtf16();
  // 参数要带引号：地址里可能有 & 之类的字符，不加引号会被 cmd 风格解析截断。
  //
  // ★ [forceNewWindow]：加 `--new-window`（Chromium 系都认）。
  //   实测用户机器上 Edge **在后台跑着但不开窗**：URL 交给那个后台实例后
  //   它就吞掉了。强制它开一个新窗口是唯一还能试的招。
  final cmdLine =
      (forceNewWindow ? '--new-window "$url"' : '"$url"').toNativeUtf16();
  final si = calloc<StartupInfoW>();
  final pi = calloc<ProcessInformation>();
  var ok = false;
  var hProc = 0;
  try {
    si.ref.cb = sizeOf<StartupInfoW>();
    final r = createProcessW(appPtr, cmdLine, nullptr, nullptr, 0, 0, nullptr,
        nullptr, si, pi);
    ok = r != 0;
    hProc = pi.ref.hProcess;
  } on Object {
    ok = false;
  } finally {
    if (hProc != 0) closeHandle(hProc);
    if (pi.ref.hThread != 0) closeHandle(pi.ref.hThread);
    calloc.free(appPtr);
    calloc.free(cmdLine);
    calloc.free(si);
    calloc.free(pi);
  }
  return ok;
}

/// 把窗口**恢复并置前**（用户要的"自动跳转"里"看得见"那一半）。
void bringWindowToFront(int hwnd) {
  if (hwnd == 0) return;
  try {
    if (isIconic(hwnd) != 0) showWindow(hwnd, swRestore);
    setForegroundWindow(hwnd);
  } on Object {
    // 前台抢占有限制（别的进程正持有前台）—— 失败也不影响"窗口已经开了"
  }
}

/// `EnumWindows`：遍历所有**顶层**窗口（回调返回 0 即停止）。
///
/// ★ 用途：诊断"屏幕上多出来一个窗口"这类问题 —— 把窗口**类名**打出来是最硬的证据
///   （`#32770`=对话框、`ConsoleWindowClass`=控制台、`Chrome_WidgetWin_1`=Edge/Chrome）。
final enumWindows = user32.lookupFunction<
    Int32 Function(Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>,
        IntPtr),
    int Function(Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>,
        int)>('EnumWindows');

final getClassNameW = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Int32),
    int Function(int, Pointer<Utf16>, int)>('GetClassNameW');

final getWindowTextW = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Int32),
    int Function(int, Pointer<Utf16>, int)>('GetWindowTextW');

/// 读一个窗口的（类名, 标题）。缓冲区长度按 Windows 的约定给足。
(String, String) windowClassAndTitle(int hwnd) {
  const n = 512;
  final cls = calloc<Uint16>(n);
  final txt = calloc<Uint16>(n);
  try {
    getClassNameW(hwnd, cls.cast<Utf16>(), n);
    getWindowTextW(hwnd, txt.cast<Utf16>(), n);
    String read(Pointer<Uint16> p) {
      final sb = StringBuffer();
      for (var i = 0; i < n; i++) {
        final c = p[i];
        if (c == 0) break;
        sb.writeCharCode(c);
      }
      return sb.toString();
    }

    return (read(cls), read(txt));
  } finally {
    calloc.free(cls);
    calloc.free(txt);
  }
}

final getWindowRect = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Rect>),
    int Function(int, Pointer<Rect>)>('GetWindowRect');

final isWindowVisible =
    user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'IsWindowVisible');

/// `AdjustWindowRectEx` 把"想要的客户区尺寸"换算成"该传给 CreateWindowExW
/// 的外框尺寸"。不换算就会踩 DPI 缩放 —— 请求 1240x800 在 125% 缩放下
/// **客户区只剩 992x640**，界面看起来"塌了"。
final adjustWindowRectEx = user32.lookupFunction<
    Int32 Function(Pointer<Rect>, Uint32, Int32, Uint32),
    int Function(Pointer<Rect>, int, int, int)>('AdjustWindowRectEx');

/// 屏幕度量：0=SM_CXSCREEN 1=SM_CYSCREEN。
final getSystemMetrics =
    user32.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'GetSystemMetrics');

/// `SystemParametersInfoW`，用 48=SPI_GETWORKAREA 取工作区。
final systemParametersInfoW = user32.lookupFunction<
    Int32 Function(Uint32, Uint32, Pointer<Void>, Uint32),
    int Function(int, int, Pointer<Void>, int)>('SystemParametersInfoW');

/// 进程 DPI 感知（109=AreDpiAwarenessContextSet 相关，这里只用 setter）。
final setProcessDpiAwarenessContext = user32.lookupFunction<
    Int32 Function(IntPtr),
    int Function(int)>('SetProcessDpiAwarenessContext');

/// `SetProcessDPIAware`（老 API，Vista+）。拿不到前者时的兜底。
final setProcessDPIAware =
    user32.lookupFunction<Int32 Function(), int Function()>('SetProcessDPIAware');

/// `GetDpiForSystem`（Win10 1607+）：启动时取系统 DPI，失败回退 96。
final getDpiForSystem =
    user32.lookupFunction<Uint32 Function(), int Function()>('GetDpiForSystem');

// ★ 这里**故意没有** `GetDpiForWindow`。
//   它一度被声明出来但从未使用（AOT 的 tree-shaker 会把符号名一起删掉，
//   于是"源码里有、exe 里查不到"—— 查发布版字符串时会被误判成"这个功能没进包"）。
//   实际上也不需要它：窗口换监视器时系统会发 `WM_DPICHANGED`，
//   wParam 低 16 位就是新 DPI，比主动去问更及时。
//   需要时再加回来，别留着当摆设。

/// GDI 度量：88=LOGPIXELSX（水平 DPI）。
final getDeviceCaps = gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32),
    int Function(int, int)>('GetDeviceCaps');

const int logPixelsX = 88;

final fillRect = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Rect>, IntPtr),
    int Function(int, Pointer<Rect>, int)>('FillRect');

final frameRect = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Rect>, IntPtr),
    int Function(int, Pointer<Rect>, int)>('FrameRect');

final setTimer = user32.lookupFunction<
    IntPtr Function(IntPtr, IntPtr, Uint32, IntPtr),
    int Function(int, int, int, int)>('SetTimer');

final killTimer = user32.lookupFunction<Int32 Function(IntPtr, IntPtr),
    int Function(int, int)>('KillTimer');

final getCursorPos = user32.lookupFunction<
    Int32 Function(Pointer<Point>),
    int Function(Pointer<Point>)>('GetCursorPos');

final screenToClient = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Point>),
    int Function(int, Pointer<Point>)>('ScreenToClient');

final setCursor = user32.lookupFunction<IntPtr Function(IntPtr),
    int Function(int)>('SetCursor');

// ── 真实鼠标输入（自检用：`PostMessage` 绕过了鼠标输入队列，
//    测不出"真点一下会发生什么"）──
final setCursorPos = user32.lookupFunction<Int32 Function(Int32, Int32),
    int Function(int, int)>('SetCursorPos');

final clientToScreen = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Point>),
    int Function(int, Pointer<Point>)>('ClientToScreen');

/// 合成一次鼠标事件（老 API，但够用且签名简单）。
///
/// ★ 为什么不用 `SendInput`：那个要填 `INPUT` 结构体数组（联合体 + 对齐），
///   为了一次自检点一下，`mouse_event` 的 5 个整数参数就够。
final mouseEvent = user32.lookupFunction<
    Void Function(Uint32, Uint32, Uint32, Uint32, IntPtr),
    void Function(int, int, int, int, int)>('mouse_event');

const int mouseEventLeftDown = 0x0002;
const int mouseEventLeftUp = 0x0004;

/// `SendMessageW` —— **同步**把消息投给窗口过程并拿到返回值。
///
/// ★ 用途：问窗口"这个坐标算不算客户区"（`WM_NCHITTEST`）。
///   真实点击走的就是这条路：系统先做命中测试，返回 `HTCAPTION` 的坐标
///   会变成**拖动窗口**，`WM_LBUTTONDOWN` 根本不会发到应用 ——
///   表现就是"点了没反应"。这条只有主动发 `WM_NCHITTEST` 才验得到。
final sendMessageW = user32.lookupFunction<
    IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
    int Function(int, int, int, int)>('SendMessageW');

final findWindowW = user32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
    int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');

/// `LoadCursorW(hInstance, MAKEINTRESOURCE(id))` —— 第二个参数是"整数当指针"，
/// 所以签名用 IntPtr 而不是 Pointer<Utf16>（用 IDC_ARROW=32512 之类的资源 id）。
final loadCursorW = user32.lookupFunction<
    IntPtr Function(IntPtr, IntPtr),
    int Function(int, int)>('LoadCursorW');

final messageBoxW = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, int)>('MessageBoxW');

final setCapture =
    user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('SetCapture');

final releaseCapture = user32.lookupFunction<IntPtr Function(),
    int Function()>('ReleaseCapture');

final scrollWindowEx = user32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, Pointer<Rect>, Pointer<Rect>, IntPtr,
        Pointer<Rect>, Uint32),
    int Function(int, int, int, Pointer<Rect>, Pointer<Rect>, int, Pointer<Rect>,
        int)>('ScrollWindowEx');

/// 异步投递一条消息到窗口队列。
///
/// ★ 关闭窗口必须走它（见 [AppWindow.requestClose]）而不是 `DestroyWindow`：
///   异步的意义是"把关闭请求排在当前这轮消息之后"，于是
///   [AppWindow.onClosing] 里的确认框能正常弹出、用户取消也来得及。
final postMessageW = user32.lookupFunction<
    Int32 Function(IntPtr, Uint32, UintPtr, IntPtr),
    int Function(int, int, int, int)>('PostMessageW');

/// 最大化状态。自绘标题栏的"最大化/还原"按钮图标要靠它二选一。
final isZoomed =
    user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsZoomed');

// ── gdi32 ──
final createSolidBrush = gdi32.lookupFunction<IntPtr Function(Uint32),
    int Function(int)>('CreateSolidBrush');

final createPen = gdi32.lookupFunction<IntPtr Function(Int32, Int32, Uint32),
    int Function(int, int, int)>('CreatePen');

final createFontW = gdi32.lookupFunction<
    IntPtr Function(Int32, Int32, Int32, Int32, Int32, Uint32, Uint32, Uint32, Uint32,
        Uint32, Uint32, Uint32, Uint32, Pointer<Utf16>),
    int Function(int, int, int, int, int, int, int, int, int, int, int, int, int,
        Pointer<Utf16>)>('CreateFontW');

final selectObject = gdi32.lookupFunction<IntPtr Function(IntPtr, IntPtr),
    int Function(int, int)>('SelectObject');

final deleteObject = gdi32.lookupFunction<IntPtr Function(IntPtr),
    int Function(int)>('DeleteObject');

final setTextColor = gdi32.lookupFunction<Uint32 Function(IntPtr, Uint32),
    int Function(int, int)>('SetTextColor');

final getTextColor = gdi32.lookupFunction<Uint32 Function(IntPtr),
    int Function(int)>('GetTextColor');

final setBkMode = gdi32.lookupFunction<Int32 Function(IntPtr, Int32),
    int Function(int, int)>('SetBkMode');

final setBkColor = gdi32.lookupFunction<Uint32 Function(IntPtr, Uint32),
    int Function(int, int)>('SetBkColor');

final textOutW = gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, Pointer<Utf16>, Int32),
    int Function(int, int, int, Pointer<Utf16>, int)>('TextOutW');

// ★ DrawTextW / DrawTextExW 在 **user32.dll**，不在 gdi32.dll 里。
//   别的文本 API（TextOutW / GetTextExtentPoint32W）确实在 gdi32，
//   所以很容易顺手写成 gdi32.lookupFunction —— 编译期不报错，
//   运行期 lookup 直接抛 "Failed to lookup symbol 'DrawTextW' (code 127)"，
//   表现就是窗口全白、一个字都不显示。
final drawTextW = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Int32, Pointer<Rect>, Uint32),
    int Function(int, Pointer<Utf16>, int, Pointer<Rect>, int)>('DrawTextW');

final getTextExtentPoint32W = gdi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Int32, Pointer<Size>),
    int Function(int, Pointer<Utf16>, int, Pointer<Size>)>('GetTextExtentPoint32W');

final roundRect = gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, Int32, Int32, Int32, Int32),
    int Function(int, int, int, int, int, int, int)>('RoundRect');

final rectangle = gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, Int32, Int32),
    int Function(int, int, int, int, int)>('Rectangle');

final getStockObject = gdi32.lookupFunction<IntPtr Function(Int32),
    int Function(int)>('GetStockObject');

final moveToEx = gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, Pointer<Point>),
    int Function(int, int, int, Pointer<Point>)>('MoveToEx');

/// `SetViewportOrgEx(hdc, x, y, nullptr)` —— 平移坐标原点。
///
/// ★ 脏区重绘的关键：只重画状态栏那一条时，把原点平移到它左上角，
///   于是整幅界面照常画（坐标不用改），但只有那一条真的落到位图上。
///   没有这个 API 就只能给每个绘制函数加 offset 参数。
final setViewportOrgEx = gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, Pointer<Point>),
    int Function(int, int, int, Pointer<Point>)>('SetViewportOrgEx');

final lineTo = gdi32.lookupFunction<Int32 Function(IntPtr, Int32, Int32),
    int Function(int, int, int)>('LineTo');

// ── 裁剪（视口裁剪用）──
//
// 没有裁剪 API 时，"只画视口内的行"那种 `if (y < bottom)` 判断只是**起点守卫**：
// 它能防止"从屏幕外开始画一行"，但挡不住"一行从视口内开始、画到视口外"——
// 那一行的后半截会画进相邻区域（内容压到底栏、滚动时内容浮到卡片外）。
// 真正的裁剪必须在 GDI 层做（IntersectClipRect + SaveDC/RestoreDC 成对）。
/// `StretchDIBits` —— 把一段**裸像素**直接贴到 DC（自动缩放）。
///
/// ★ 用它而不是自己 CreateDIBSection + BitBlt：书封面是**每本书一张**，
///   走 DIB section 就得为每张图建一个 GDI 对象并管生命周期；
///   StretchDIBits 只借一块调用方持有的内存，画完即走，没有句柄泄漏风险。
///   代价是每次都要传一个 BITMAPINFOHEADER（很小，栈上建即可）。
final stretchDIBits = gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
        Int32, Pointer<Uint8>, Pointer<Void>, Uint32, Uint32),
    int Function(int, int, int, int, int, int, int, int, int, Pointer<Uint8>,
        Pointer<Void>, int, int)>('StretchDIBits');

/// `DIB_RGB_COLORS`（`wingdi.h`）。
const int dibRgbColors = 0;

/// `SRCCOPY`（`wingdi.h`）：直接拷贝，不做任何位运算。
const int srcCopy = 0x00CC0020;

final intersectClipRect = gdi32.lookupFunction<Int32 Function(IntPtr, Int32, Int32, Int32, Int32),
    int Function(int, int, int, int, int)>('IntersectClipRect');

final saveDC = gdi32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('SaveDC');

final restoreDC = gdi32.lookupFunction<Int32 Function(IntPtr, Int32),
    int Function(int, int)>('RestoreDC');

final setSmoothing = gdi32.lookupFunction<Int32 Function(IntPtr, Int32),
    int Function(int, int)>('SetStretchBltMode');

final createCompatibleDC = gdi32.lookupFunction<IntPtr Function(IntPtr),
    int Function(int)>('CreateCompatibleDC');

final createCompatibleBitmap = gdi32.lookupFunction<
    IntPtr Function(IntPtr, Int32, Int32),
    int Function(int, int, int)>('CreateCompatibleBitmap');

final bitBlt = gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, Int32, Int32, IntPtr, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int, int, int)>('BitBlt');

final deleteDC =
    gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');

// ── 离屏渲染成图（自检/截图用，正式界面不走这条路径）──

/// 32 位 DIB 节：能在内存里拿到真实像素指针，用来把界面导出成 PNG。
/// `CreateCompatibleBitmap` 拿不到像素，只有 DIB 节可以。
final createDIBSection = gdi32.lookupFunction<
    IntPtr Function(IntPtr, BitmapInfoPtr, Uint32, Pointer<Pointer<Void>>,
        IntPtr, Uint32),
    int Function(int, BitmapInfoPtr, int, Pointer<Pointer<Void>>, int,
        int)>('CreateDIBSection');

final getDC =
    user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');

final releaseDC = user32.lookupFunction<Int32 Function(IntPtr, IntPtr),
    int Function(int, int)>('ReleaseDC');

/// `BITMAPINFOHEADER`。字段顺序/大小必须和 windows.h 逐字一致，
/// 差一个 DWORD 就会得到"看着能跑、像素全是花的"。
final class BitmapInfoHeader extends Struct {
  @Uint32()
  external int size;
  @Int32()
  external int width;
  @Int32()
  external int height; // 负数 = 自上而下
  @Uint16()
  external int planes;
  @Uint16()
  external int bitCount;
  @Uint32()
  external int compression;
  @Uint32()
  external int sizeImage;
  @Int32()
  external int xPelsPerMeter;
  @Int32()
  external int yPelsPerMeter;
  @Uint32()
  external int clrUsed;
  @Uint32()
  external int clrImportant;
}

/// `BITMAPINFO` = header + 调色板。
///
/// ★ 用 `calloc` 分配 40 字节的 [BitmapInfoHeader] 就够了：
///   CreateDIBSection 只用得到 head 部分，且传指针时类型擦成
///   `Pointer<Void>`。0 调色板 = 不需要（24/32 位 DIB 无调色板）。
typedef BitmapInfoPtr = Pointer<BitmapInfoHeader>;


// ── shell32 ──
final shellExecuteW = shell32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Utf16>, Int32),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        int)>('ShellExecuteW');

// ── CreateProcessW：显式起浏览器（绕开"提权实例冲突"） ──
//
// ★ 为什么需要它（2026-09-28 实测定位）：
//   用户把 Edge 以**管理员身份**常驻打开后，普通权限的本工具调
//   `ShellExecuteW("open", url)` → 系统起一个 msedge.exe → 它要把 URL
//   投递给**已存在的提升权限 Edge 实例** → 被 UIPI（完整性级别隔离）挡下 →
//   Edge 弹框「现有实例正在以提升的权限运行，是否用普通权限重启?」→
//   用户点「否」→ Edge 退出，**页面永远不出现**。
//   而 `ShellExecuteW` 对此一无所知，照样返回 42（成功）—— 于是日志里
//   全是"成功"，用户看到的却是"点了没反应"。
//   对策：**不依赖 shell 关联**，自己 `CreateProcessW` 起浏览器，
//   并带上 `--user-data-dir=<本工具私有目录>`，让新实例与用户那个提升
//   权限的实例**彻底隔离**，从根上不产生冲突。
final createProcessW = kernel32.lookupFunction<
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>, Pointer<Void>,
        Int32, Uint32, Pointer<Void>, Pointer<Utf16>, Pointer<StartupInfoW>,
        Pointer<ProcessInformation>),
    int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>, Pointer<Void>, int,
        int, Pointer<Void>, Pointer<Utf16>, Pointer<StartupInfoW>,
        Pointer<ProcessInformation>)>('CreateProcessW');

/// STARTUPINFOW（winbase.h）。64 位下 104 字节。
///
/// ★ 指针字段一律声明成 `IntPtr`（本项目所有结构体都这么写）——
///   Dart FFI 的 `@Pointer()` 注解写法在新版 SDK 上会被拒，
///   而 `IntPtr` 在 64 位下与指针同宽，布局完全一致。
///
/// ★ `cb` 必须写成**结构体真实大小**：`CreateProcessW` 按它读内存，
///   写小了系统读到的就是半截结构体（字段被当垃圾）。
final class StartupInfoW extends Struct {
  @Uint32()
  external int cb;

  @IntPtr()
  external int lpReserved;

  @IntPtr()
  external int lpDesktop;

  @IntPtr()
  external int lpTitle;

  @Uint32()
  external int dwX;

  @Uint32()
  external int dwY;

  @Uint32()
  external int dwXSize;

  @Uint32()
  external int dwYSize;

  @Uint32()
  external int dwXCountChars;

  @Uint32()
  external int dwYCountChars;

  @Uint32()
  external int dwFillAttribute;

  @Uint32()
  external int dwFlags;

  @Uint16()
  external int wShowWindow;

  @Uint16()
  external int cbReserved2;

  @IntPtr()
  external int lpReserved2;

  @IntPtr()
  external int hStdInput;

  @IntPtr()
  external int hStdOutput;

  @IntPtr()
  external int hStdError;
}

/// PROCESS_INFORMATION（processthreadsapi.h）。64 位下 24 字节。
final class ProcessInformation extends Struct {
  @IntPtr()
  external int hProcess;

  @IntPtr()
  external int hThread;

  @Uint32()
  external int dwProcessId;

  @Uint32()
  external int dwThreadId;
}

final getFileAttributesW = kernel32.lookupFunction<
    Uint32 Function(Pointer<Utf16>),
    int Function(Pointer<Utf16>)>('GetFileAttributesW');

// ── advapi32：读注册表找 http 关联的真实浏览器路径 ──
//
// ★ 为什么**不用** `AssocQueryStringW`：它在 shlwapi.dll 里，而
//   `HKEY_CLASSES_ROOT\http\UserChoice\ProgId` → `<ProgId>\shell\open\
//   command` 这条纯注册表路线只用 advapi32（所有 Windows 都在）。
//   两层查询，代码可控，失败回退 ShellExecuteW。
final regOpenKeyExW = advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
    int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>('RegOpenKeyExW');

final regQueryValueExW = advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
        Pointer<Uint8>, Pointer<Uint32>),
    int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
        Pointer<Uint8>, Pointer<Uint32>)>('RegQueryValueExW');

final regCloseKey =
    advapi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'RegCloseKey');

const int hkeyClassesRoot = 0x80000000;
const int keyRead = 0x20019; // KEY_READ
const int keyWow64_64Key = 0x0100;

/// `OpenProcess` 的访问权：查询进程信息（比 LIMITED 要求高 ——
/// **正因为要求高，"拒绝访问"才成了"对方完整性级别更高"的判据**）。
const int processQueryInformation = 0x0400;

// ── comdlg32：选文件对话框 ──
//
// ★ 为什么用**旧版** GetOpenFileNameW 而不是 IFileOpenDialog（COM）：
//   COM 那条路要 CoCreateInstance 一个 Shell 对象，而本项目在裸 exe 里
//   已经确认没有 COM/WinRT 激活上下文（OCR 那一轮的结论）。虽然经典 COM
//   （CoInitialize + CoCreateInstance）理论上可用，但那要额外引入 ole32 与
//   一整套接口槽位——为了一个"选张图片"的对话框，代价与风险都不划算。
//   GetOpenFileNameW 是纯 Win32，零初始化，够用。
final getOpenFileNameW = comdlg32.lookupFunction<
    Int32 Function(Pointer<OpenFileNameW>),
    int Function(Pointer<OpenFileNameW>)>('GetOpenFileNameW');

/// OPENFILENAMEW（commdlg.h）。
///
/// ★ 字段顺序**必须与头文件完全一致** —— 结构体布局错了，
///   系统会读到垃圾指针然后崩。这里按 64 位布局（含 4 字节对齐填充）排。
///
/// ★ 只声明到 `lpstrFile` 之后的常用字段；`lpstrInitialDir` 与 `lpstrTitle`
///   之后的字段用不到就省略（系统只看 `lStructSize` 声明的大小）。
///   但 `lStructSize` 必须传**真实的大结构体大小**，传小了系统会拒绝。
final class OpenFileNameW extends Struct {
  @Uint32()
  external int lStructSize;

  @IntPtr()
  external int hwndOwner;

  @IntPtr()
  external int hInstance;

  @IntPtr()
  external int lpstrFilter;

  @IntPtr()
  external int lpstrCustomFilter;

  @Uint32()
  external int nMaxCustFilter;

  @Uint32()
  external int nFilterIndex;

  @IntPtr()
  external int lpstrFile;

  @Uint32()
  external int nMaxFile;

  @IntPtr()
  external int lpstrFileTitle;

  @Uint32()
  external int nMaxFileTitle;

  @IntPtr()
  external int lpstrInitialDir;

  @IntPtr()
  external int lpstrTitle;

  @Uint32()
  external int flags;

  @Uint16()
  external int nFileOffset;

  @Uint16()
  external int nFileExtension;

  @IntPtr()
  external int lpstrDefExt;

  @IntPtr()
  external int lCustData;

  @IntPtr()
  external int lpfnHook;

  @IntPtr()
  external int lpTemplateName;

  @IntPtr()
  external int pvReserved;

  @Uint32()
  external int dwReserved;

  @Uint32()
  external int flagsEx;
}

// OFN_* 标志位（commdlg.h）
const int ofnReadOnly = 0x00000001;
const int ofnOverwritePrompt = 0x00000002;
const int ofnHideReadOnly = 0x00000004;
const int ofnNoChangeDir = 0x00000008;
const int ofnShowHelp = 0x00000010;
const int ofnEnableHook = 0x00000020;
const int ofnEnableTemplate = 0x00000040;
const int ofnNoValidate = 0x00000100;
const int ofnAllowMultiSelect = 0x00000200;
const int ofnExtensionDifferent = 0x00000400;
const int ofnPathMustExist = 0x00000800;
const int ofnFileMustExist = 0x00001000;
const int ofnCreatePrompt = 0x00002000;
const int ofnShareAware = 0x00004000;
const int ofnNoReadOnlyReturn = 0x00008000;
const int ofnNoTestFileCreate = 0x00010000;
const int ofnNoNetworkButton = 0x00020000;
const int ofnExplorer = 0x00080000;
const int ofnLongNames = 0x00100000;

// ── shell32 / ole32：选文件夹对话框 ──
//
// ★ 为什么用**旧版** SHBrowseForFolderW 而不是 IFileDialog(COM)：
//   与选文件对话框同一条理由（见上面 GetOpenFileNameW 的说明）——
//   裸 exe 里没有 COM 激活上下文，为了"选一个目录"去拉 ole32 + 一整套
//   接口槽位不划算。SHBrowseForFolderW 是纯 shell32，零初始化。
//
// ★ 它返回的是 **PIDL**（item id list）而不是字符串，必须再过一次
//   SHGetPathFromIDListW 才拿到路径，最后 CoTaskMemFree 释放 PIDL ——
//   漏了最后一步就是每次选目录泄漏一小块内存。
final shBrowseForFolderW = shell32.lookupFunction<
    IntPtr Function(Pointer<BrowseInfoW>),
    int Function(Pointer<BrowseInfoW>)>('SHBrowseForFolderW');

final shGetPathFromIDListW = shell32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint16>),
    int Function(int, Pointer<Uint16>)>('SHGetPathFromIDListW');

/// 把路径字符串解析成 PIDL（给 `BROWSEINFOW.pidlRoot` 当"起始目录"用）。
///
/// ★ 为什么需要它：`BROWSEINFOW` **没有** `lpstrInitialDir` 那样的字段
///   （不像 `OPENFILENAMEW`）。想让文件夹框"从上次那个目录打开"，
///   唯一的办法就是把那个目录先解析成 PIDL 塞进 `pidlRoot`。
///   参数：`(pszName, pbc, ppidl, sfgaoIn, psfgaoOut)`；成功返回 S_OK(0)。
///   `pbc` / `psfgaoOut` 传 nullptr 即可（本用途不需要绑定上下文与属性）。
final shParseDisplayName = shell32.lookupFunction<
    Int32 Function(Pointer<Utf16>, IntPtr, Pointer<IntPtr>, Uint32,
        Pointer<Uint32>),
    int Function(Pointer<Utf16>, int, Pointer<IntPtr>, int,
        Pointer<Uint32>)>('SHParseDisplayName');

/// BROWSEINFOW（shlobj_core.h）。
///
/// ★ 字段顺序必须与头文件一致；64 位下 `ulFlags` 后面是 `lpfn`(IntPtr)，
///   再往后 `lParam`。这里声明到 `lParam` 为止（够用），
///   `lStructSize` 由系统按结构体实际大小校验 —— 传对了才收。
final class BrowseInfoW extends Struct {
  @IntPtr()
  external int hwndOwner;
  @IntPtr()
  external int pidlRoot;
  @IntPtr()
  external int pszDisplayName;
  @IntPtr()
  external int lpszTitle;
  @Uint32()
  external int ulFlags;
  @IntPtr()
  external int lpfn;
  @IntPtr()
  external int lParam;
  @Int32()
  external int iImage;
}

// BIF_* 标志位（shlobj_core.h）
//
// ★ BIF_USENEWUI 在头文件里**不是独立位**，而是这两个位的组合：
//     #define BIF_USENEWUI (BIF_EDITBOX | BIF_NEWDIALOGSTYLE)
//   历史 bug：曾把 0x4000 当 BIF_USENEWUI —— 那是 BIF_BROWSEINCLUDEFILES
//   （"允许选择文件"），对新式文件夹框毫无意义。
const int bifReturnOnlyFsDirs = 0x0001;
const int bifEditBox = 0x0010;
const int bifNewDialogStyle = 0x0040;
const int bifNoNewFolderButton = 0x0200;

/// COM 任务内存释放（PIDL 由 shell 用 CoTaskMemAlloc 分配，必须这样还）。
final coTaskMemFree = ole32.lookupFunction<Void Function(IntPtr), void Function(int)>(
    'CoTaskMemFree');

// ★★ 第 22 轮核心修复：`SHBrowseForFolderW` + `BIF_NEWDIALOGSTYLE` 的
//    **硬性前置条件**是"调用线程已初始化 COM"（微软文档明确写了
//    "The calling application is responsible for initializing COM with
//    CoInitialize or OleInitialize"）。本项目的 UI 线程此前从没初始化过 COM，
//    于是"选文件夹"框会**弹不出来 / 选完返回不了可用路径** ——
//    用户看到的就是"选择任何文件夹都不行"。
//    `cover_image.dart` 里那次 CoInitializeEx 只发生在**取封面**那条路上，
//    而且它跑在别的时机，救不了这里。
final coInitializeEx = ole32.lookupFunction<
    Int32 Function(IntPtr, Uint32),
    int Function(int, int)>('CoInitializeEx');

/// `COINIT_APARTMENTTHREADED`。UI 线程**必须**用这个（STA）——
/// shell 的浏览框、模态框都依赖 STA；用 MTA 会拿到 `RPC_E_CHANGED_MODE`。
const int coInitApartmentThreaded = 0x2;

/// 是否已经在**本线程**成功初始化过 COM（幂等标记）。
bool _comReady = false;

/// 确保**当前线程**已按 STA 初始化 COM。可重复调用。
///
/// 返回值：
///   · 0  = `S_OK`（本次成功初始化）
///   · 1  = `S_FALSE`（本线程已经初始化过，同样可用）
///   · 0x80010106 = `RPC_E_CHANGED_MODE`（本线程已用别的套间模式初始化过）——
///     对 `SHBrowseForFolderW` 仍基本可用，所以也当"够用"处理。
/// 其余负值按失败处理（此时还能退回不带 NEWDIALOGSTYLE 的旧式框）。
bool ensureComInitialized() {
  if (_comReady) return true;
  try {
    // 第 1 个参数是 `PVOID pvReserved`，映射到 Dart 就是 int，必须传 0。
    final hr = coInitializeEx(0, coInitApartmentThreaded);
    // S_OK / S_FALSE / RPC_E_CHANGED_MODE 都算"COM 可用了"
    _comReady = hr == 0 || hr == 1 || hr == -2147417850;
    return _comReady;
  } on Object {
    return false;
  }
}

// ── user32：剪贴板（读文本，供"粘贴文本存为附件"用）──
final openClipboard = user32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('OpenClipboard');
final closeClipboard = user32.lookupFunction<Int32 Function(), int Function()>(
    'CloseClipboard');
final getClipboardData =
    user32.lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        'GetClipboardData');
final isClipboardFormatAvailable =
    user32.lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'IsClipboardFormatAvailable');
const int cfUnicodeText = 13;

// ── user32：剪贴板（写文本，供"打不开浏览器就把地址交给用户"用）──
final emptyClipboard =
    user32.lookupFunction<Int32 Function(), int Function()>('EmptyClipboard');
final setClipboardData =
    user32.lookupFunction<IntPtr Function(Uint32, IntPtr),
        int Function(int, int)>('SetClipboardData');

// ── kernel32：全局内存 ──
//
// ★ 剪贴板要的是 **GMEM_MOVEABLE** 的全局内存句柄（不是普通 malloc 的指针）：
//   系统会接管这块内存的所有权，所以 `SetClipboardData` 成功之后
//   **绝对不能再 GlobalFree** —— 那是经典的双重释放。
final globalAlloc = kernel32.lookupFunction<IntPtr Function(Uint32, IntPtr),
    int Function(int, int)>('GlobalAlloc');
final globalLock = kernel32.lookupFunction<Pointer<Void> Function(IntPtr),
    Pointer<Void> Function(int)>('GlobalLock');
final globalUnlock =
    kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'GlobalUnlock');
final globalFree =
    kernel32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
        'GlobalFree');
const int gmemMoveable = 0x0002;

/// `GetFileAttributesW` 的属性位：目标是不是目录（pickFolderDialog 选完校验用）。
const int fileAttributeDirectory = 0x00000010;

// ── 常量 ──
const int wsOverlappedWindow = 0x00CF0000;

// 无边框窗口用的样式位。
// 目标组合 = WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX
// ---- 关键点：**不要 WS_CAPTION**，它的存在就是"系统标题栏"本身。
//      去掉之后系统的非客户区只剩一圈可缩放边框，再由
//      WM_NCCALCSIZE 返回 0 把这一圈也让给客户区 → 得到整块自绘画布。
const int wsPopup = 0x80000000;
const int wsCaption = 0x00C00000;
const int wsThickFrame = 0x00040000;
const int wsMinimizeBox = 0x00020000;
const int wsMaximizeBox = 0x00010000;
const int wsClipSiblings = 0x04000000;

/// 无边框主窗口样式。
const int wsFramelessWindow =
    wsPopup | wsThickFrame | wsMinimizeBox | wsMaximizeBox;

/// 弹窗子窗口样式（对话框用）：`WS_POPUP` + 细边框，**不可缩放**。
///
/// ★ 子窗口必须显式带 `WS_CLIPSIBLINGS`，否则它重绘时会连带把父窗口
///   在重叠区域的像素擦成父窗口背景色，出现"拖对话框拖出一路黑条"。
const int wsFramelessDialog = wsPopup | wsClipSiblings;

const int csHredraw = 0x0002;
const int csVredraw = 0x0001;
const int swShow = 5;
const int swMaximize = 3;
const int swRestore = 9;

// ── SetWindowPos 标志（winuser.h）──
const int swpNoSize = 0x0001;
const int swpNoMove = 0x0002;
const int swpNoZOrder = 0x0004;
const int swpNoActivate = 0x0010;
const int swpFrameChanged = 0x0020;

const int wmDestroy = 0x0002;
const int wmSize = 0x0005;

/// `WM_DPICHANGED`：wParam 低 16 位是新 DPI，lParam 是建议 RECT*。
const int wmDpiChanged = 0x02E0;
const int wmSetFocus = 0x0007;
const int wmKillFocus = 0x0008;
const int wmPaint = 0x000F;
const int wmClose = 0x0010;
const int wmEraseBkgnd = 0x0014;
const int wmKeyDown = 0x0100;

/// WM_CHAR —— **已经过键盘布局翻译的字符**（0x0102）。
///
/// ★ 自绘的文本输入框必须吃 WM_CHAR 而不是 WM_KEYDOWN：
///   WM_KEYDOWN 给的只是虚拟键码（A-Z 是 0x41-0x5A，与"用户实际敲出的字符"
///   在中文输入法下完全不是一回事）。要让用户能用输入法打中文，
///   就得收 WM_CHAR。
const int wmChar = 0x0102;
const int wmTimer = 0x0113;

/// `WM_NCCALCSIZE` —— 系统在算"非客户区该占多大"。
/// `wParam == 1` 时**返回 0 就等于宣告"非客户区是 0 像素"**，
/// 客户区直接铺满整窗。这是无边框改造的核心开关。
const int wmNcCalcSize = 0x0083;

/// `WM_NCHITTEST` —— 系统问"屏幕坐标 (x,y) 落在窗口的哪个部位"。
/// 返回值决定后续鼠标行为：返回 `HTCAPTION` 系统就会帮你拖动窗口，
/// 返回 `HTLEFT` 之类系统就会帮你缩放 —— **不用手写拖拽循环**。
const int wmNcHitTest = 0x0084;
const int wmNcPaint = 0x0085;
const int wmNcActivate = 0x0086;

/// `WM_NCHITTEST` 返回值。
const int htClient = 1;
const int htCaption = 2;
const int htLeft = 10;
const int htRight = 11;
const int htTop = 12;
const int htTopLeft = 13;
const int htTopRight = 14;
const int htBottom = 15;
const int htBottomLeft = 16;
const int htBottomRight = 17;

const int wmMouseMove = 0x0200;
const int wmLButtonDown = 0x0201;
const int wmLButtonUp = 0x0202;
const int wmMouseWheel = 0x020A;

/// 横向滚轮（触摸板双指横扫 / 倾斜滚轮）。与 [wmMouseWheel] 同结构，
/// 但 `wParam` 的高 16 位是**横向**增量，且**方向相反**（正数 = 往左滚）。
const int wmMouseHWheel = 0x020E;
const int wmMouseLeave = 0x02A3;

/// `DwmExtendFrameIntoClientArea` 用的 1px 边距 —— 撑阴影又不吃进内容。
const int frameShadowMargin = 1;

const int pmRemove = 1;
const int transparent = 1;
const int nullBrush = 5;
const int whiteBrush = 0;
const int whitePen = 6;
const int srccopy = 0x00CC0020;

const int dtLeft = 0x00000000;
const int dtCenter = 0x00000001;
const int dtRight = 0x00000002;
const int dtVcenter = 0x00000004;
const int dtSingleLine = 0x00000020;
const int dtEndEllipsis = 0x00008000;
const int dtWordBreak = 0x00000010;
const int dtNoPrefix = 0x00000800;

const int idcArrow = 32512;
const int idcHand = 32649;
const int idcWait = 32514;
const int idcSizeNs = 32645;

const int swShowNormal = 1;

/// `SetWindowTheme(hwnd, L"", L"")` —— 让窗口的非客户区（标题栏/边框）
/// 跟随系统深色主题。
final setWindowTheme = uxtheme.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>)>('SetWindowTheme');

/// `DwmSetWindowAttribute` —— 用它把标题栏直接染成深色。
///
/// ★ 这是把"白色标题栏 + 深色客户区"这个最刺眼的割裂感修掉的**关键 API**。
///   Win10 1809+ 用属性 19（DWMWA_USE_IMMERSIVE_DARK_MODE），
///   早期 build 用 20 —— 两个都试一遍，哪个成功算哪个。
final dwmSetWindowAttribute = dwmapi.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
    int Function(int, int, Pointer<Void>, int)>('DwmSetWindowAttribute');

const int dwmwaUseImmersiveDarkMode = 20; // 1809+
const int dwmwaUseImmersiveDarkModeOld = 19; // 更早的预览版
const int dwmwaCaptionColor = 35; // 22000+ (Win11)
const int dwmwaTextColor = 36;

/// Win11 圆角偏好（`DWMWA_WINDOW_CORNER_PREFERENCE`，build 22000+）。
/// 只在 Win11 上生效；Win10 会返回 E_INVALIDARG，忽略即可。
const int dwmwaWindowCornerPreference = 33;
const int dwmwaBorderColor = 34; // Win11：窗口 1px 描边色
const int dwmwcpRound = 2;

/// `DwmExtendFrameIntoClientArea` —— 撑出窗口阴影。
///
/// ★ 无边框 + 自绘标题栏之后系统不再画阴影，窗口会像"贴在桌面上的一张纸"。
///   把边距设成 1px、配合 `DWMWA_BORDER_COLOR` 拿到极细描边，
///   再让 Win11 的圆角偏好接上，才有现代窗口的立体感。
///
/// ★ 副作用（踩过）：一旦扩展了 DWM 帧，**客户区左上角会被 DWM 当作玻璃区**，
///   如果窗口类背景刷没设成黑色又没有全窗重绘，会看到 1px 白边。
///   本程序的 `_wndProcImpl` 在 `WM_PAINT` 里整窗填充背景色，所以是安全的。
final dwmExtendFrameIntoClientArea = dwmapi.lookupFunction<
    Int32 Function(IntPtr, Pointer<Margins>),
    int Function(int, Pointer<Margins>)>('DwmExtendFrameIntoClientArea');

final class Margins extends Struct {
  @Int32()
  external int cxLeftWidth;
  @Int32()
  external int cxRightWidth;
  @Int32()
  external int cyTopHeight;
  @Int32()
  external int cyBottomHeight;
}

/// `TrackMouseEvent` 的参数结构（`TRACKMOUSEEVENT`）。
final class TrackMouseEventStruct extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int dwFlags;
  @IntPtr()
  external int hwndTrack;
  @Uint32()
  external int dwHoverTime;
}

const int tmeLeave = 0x00000002;

/// `RedrawWindow` —— 改完非客户区颜色后强制重画边框。
final redrawWindow = user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Rect>, IntPtr, Uint32),
    int Function(int, Pointer<Rect>, int, int)>('RedrawWindow');

const int rdwInvalidate = 0x0001;
const int rdwErase = 0x0004;
const int rdwFrame = 0x0400;
const int rdwAllChildren = 0x0080;
const int rdwUpdatenow = 0x0100;

/// COLORREF 是 BGR，不是 RGB。写错会让红蓝互换。
int rgb(int r, int g, int b) => (b << 16) | (g << 8) | r;

// ── 结构体 ──

typedef WndProcNative = IntPtr Function(
    Pointer<Void> hwnd, Uint32 msg, UintPtr wParam, IntPtr lParam);

final class WndClassW extends Struct {
  @Uint32()
  external int style;
  external Pointer<NativeFunction<WndProcNative>> lpfnWndProc;
  @Int32()
  external int cbClsExtra;
  @Int32()
  external int cbWndExtra;
  @IntPtr()
  external int hInstance;
  @IntPtr()
  external int hIcon;
  @IntPtr()
  external int hCursor;
  @IntPtr()
  external int hbrBackground;
  external Pointer<Utf16> lpszMenuName;
  external Pointer<Utf16> lpszClassName;
}

final class Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class Size extends Struct {
  @Int32()
  external int cx;
  @Int32()
  external int cy;
}

final class Msg extends Struct {
  @IntPtr()
  external int hwnd;
  @Uint32()
  external int message;
  @UintPtr()
  external int wParam;
  @IntPtr()
  external int lParam;
  @Uint32()
  external int time;
  external Point pt;
}

final class Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;

  int get width => right - left;
  int get height => bottom - top;
}

final class PaintStruct extends Struct {
  @IntPtr()
  external int hdc;
  @Int32()
  external int fErase;
  external Rect rcPaint;
  @Int32()
  external int fRestore;
  @Int32()
  external int fIncUpdate;
  @Array(32)
  external Array<Uint8> rgbReserved;
}

// ── 便利封装：选文件 / 读剪贴板 ──

/// 弹出「打开文件」对话框，返回用户选择的绝对路径；取消返回 null。
///
/// [filter] 是 Windows 的过滤器串，格式：
///   `'图片\0*.png;*.jpg;*.jpeg;*.bmp;*.gif\0所有文件\0*.*\0\0'`
/// ★ 分隔符是 **NUL（`\0`）而不是 `|`**（`|` 是 Qt/MFC 的写法），
///   末尾必须**两个 NUL** 收尾 —— 少一个系统会读到越界内存。
///
/// ★ 为什么不用 `Pointer<Utf16>` 从 Dart 字符串直接转换 filter：
///   Dart 的 `toNativeUtf16()` 会在末尾补一个 NUL，但过滤器需要**内嵌** NUL，
///   按段落拼好后一次性分配更可控。
String? openImageFileDialog(int ownerHwnd, {String? title, String? initialDir}) {
  // 过滤器：图片 + 所有文件
  const filter = '图片文件\0*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp\0'
      '所有文件\0*.*\0\0';
  final filterUnits = filter.codeUnits;

  const maxPath = 1024;
  // ★ 所有 native 分配都放进同一个 try —— 任何一步抛异常（OOM /
  //   toNativeUtf16 失败）都会在 finally 里把已分配的清掉，不留泄漏。
  Pointer<Uint16> filterPtr = nullptr;
  Pointer<Uint16> fileBuf = nullptr;
  Pointer<Utf16> titlePtr = nullptr;
  Pointer<Utf16> dirPtr = nullptr;
  Pointer<OpenFileNameW> ofn = nullptr;
  try {
    filterPtr = calloc<Uint16>(filterUnits.length + 1);
    for (var i = 0; i < filterUnits.length; i++) {
      filterPtr[i] = filterUnits[i];
    }
    filterPtr[filterUnits.length] = 0;

    fileBuf = calloc<Uint16>(maxPath);
    fileBuf[0] = 0;

    titlePtr = title == null ? nullptr : title.toNativeUtf16();
    dirPtr = initialDir == null ? nullptr : initialDir.toNativeUtf16();

    ofn = calloc<OpenFileNameW>();
    ofn.ref
      ..lStructSize = sizeOf<OpenFileNameW>()
      ..hwndOwner = ownerHwnd
      ..hInstance = 0
      ..lpstrFilter = filterPtr.address
      ..lpstrCustomFilter = 0
      ..nMaxCustFilter = 0
      ..nFilterIndex = 1
      ..lpstrFile = fileBuf.address
      ..nMaxFile = maxPath
      ..lpstrFileTitle = 0
      ..nMaxFileTitle = 0
      ..lpstrInitialDir = dirPtr.address
      ..lpstrTitle = titlePtr.address
      // ★ OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST 必须都开：
      //   不开的话用户能手动敲一个不存在的路径进来，后面读文件才报错，
      //   错误位置离用户的操作很远，体验差。
      ..flags = ofnPathMustExist | ofnFileMustExist | ofnExplorer |
          ofnLongNames
      ..nFileOffset = 0
      ..nFileExtension = 0
      ..lpstrDefExt = 0
      ..lCustData = 0
      ..lpfnHook = 0
      ..lpTemplateName = 0
      ..pvReserved = 0
      ..dwReserved = 0
      ..flagsEx = 0;

    final ok = getOpenFileNameW(ofn);
    if (ok == 0) return null; // 取消
    // 读回 NUL 结尾的宽字符串
    final sb = StringBuffer();
    for (var i = 0; i < maxPath; i++) {
      final c = fileBuf[i];
      if (c == 0) break;
      sb.writeCharCode(c);
    }
    final s = sb.toString();
    return s.isEmpty ? null : s;
  } finally {
    if (ofn != nullptr) calloc.free(ofn);
    if (fileBuf != nullptr) calloc.free(fileBuf);
    if (filterPtr != nullptr) calloc.free(filterPtr);
    if (titlePtr != nullptr) calloc.free(titlePtr);
    if (dirPtr != nullptr) calloc.free(dirPtr);
  }
}

/// 弹出「选择文件夹」对话框，返回用户选中的**绝对目录路径**；取消返回 null。
///
/// ★ 用户原话："不能自定义导出位置、导入位置"。根因是导出目录写死成
///   `out/导出`。有了这个函数，调用方就能让用户自己挑一个目录。
///
/// ★★ 第 22 轮的真根因（用户报"选择任何文件夹都不行"）：
///   `SHBrowseForFolderW` 配 `BIF_NEWDIALOGSTYLE` 时，**调用线程必须先
///   初始化 COM**（微软文档原文："The calling application is responsible
///   for initializing COM with CoInitialize or OleInitialize"）。本项目 UI
///   线程此前**从未**初始化 COM，于是新式文件夹框要么弹不出来、要么选完
///   拿不到可用路径 —— 用户看到的就是"选哪个目录都没用"。
///   所以现在**先 [ensureComInitialized]**，再做两次尝试：
///     ① 新式框（BIF_NEWDIALOGSTYLE | BIF_EDITBOX，即 USENEWUI，带侧边栏，体验好）；
///     ② 若 ① 返回空/失败，退回**旧式框**（不带 NEWDIALOGSTYLE）——
///        旧式框对 COM 无额外要求，是最可靠的兜底。
///   "返回空"要区分**用户点了取消**和**框根本没起来**：两者都拿到 0，
///   分不清就再试一次旧式框；用户真取消时旧式框也会再弹一次，虽然多一步，
///   但**绝不至于让功能彻底不可用**（当前 bug 就是这个）。
///
/// ★ 另外三个细节也缺一不可：
///   ① `ulFlags` 必须含 [bifReturnOnlyFsDirs]（否则用户能选"我的电脑"这种虚拟项，
///      拿到的是一个不存在的路径）；[bifEditBox] 让用户能直接粘路径。
///   ② `pszDisplayName` 是**必填**缓冲区（哪怕不用它）—— 传 null 系统会崩。
///   ③ 拿到的 PIDL 必须 [coTaskMemFree]（shell 分配的内存），否则每次泄漏。
String? pickFolderDialog(int ownerHwnd, {String? title, String? initialDir}) {
  // ★ 先补 COM：这是新式文件夹框能工作的前提。
  ensureComInitialized();

  // 初值目录：解析成 PIDL 传给 pidlRoot，让框**从上次那个目录打开**。
  // `SHParseDisplayName` 失败（目录不存在/没权限）就退回 0（= 桌面根），
  // 绝不能因为"上次的目录没了"就让整个对话框失败。
  var rootPidl = 0;
  if (initialDir != null && initialDir.trim().isNotEmpty) {
    final dirPtr = initialDir.toNativeUtf16();
    final out = calloc<IntPtr>();
    try {
      // `pbc` 与 `psfgaoOut` 是可选的，传 0（nullptr）即可。
      final hr = shParseDisplayName(dirPtr, 0, out, 0, nullptr);
      if (hr == 0 && out.value != 0) rootPidl = out.value;
    } on Object {
      rootPidl = 0;
    } finally {
      calloc.free(dirPtr);
      calloc.free(out);
    }
  }

  try {
    // ① 新式框
    final a = _browseForFolder(ownerHwnd, title: title, rootPidl: rootPidl,
        modern: true);
    if (a != null && _isExistingDirectory(a)) return a;
    // ② 旧式框兜底（对新式框的失败/COM 异常最稳）
    final b = _browseForFolder(ownerHwnd, title: title, rootPidl: rootPidl,
        modern: false);
    // ★ 选中的必须是**真实存在的目录**：个别 shell/虚拟项会给出不存在
    //   或不是目录的路径；这种一律当"取消/失败"返回 null，别把坏路径
    //   交给导出逻辑，让报错出现在离用户操作很远的地方。
    return (b != null && _isExistingDirectory(b)) ? b : null;
  } finally {
    if (rootPidl != 0) coTaskMemFree(rootPidl);
  }
}

/// 路径是否为**真实存在的目录**（`GetFileAttributesW` + FILE_ATTRIBUTE_DIRECTORY）。
///
/// `SHBrowseForFolderW` 大多数时候给出真实目录，但虚拟项/异常 shell
/// 扩展可能给回不存在或非目录的路径；这种一律当失败，避免坏路径流到
/// 导出逻辑里才报错。
bool _isExistingDirectory(String path) {
  final p = path.toNativeUtf16();
  try {
    final attr = getFileAttributesW(p);
    return attr != 0xFFFFFFFF && (attr & fileAttributeDirectory) != 0;
  } on Object {
    return false;
  } finally {
    calloc.free(p);
  }
}

/// [pickFolderDialog] 的单次尝试。返回选中的绝对路径；取消/失败返回 null。
String? _browseForFolder(int ownerHwnd,
    {String? title, required int rootPidl, required bool modern}) {
  const maxPath = 1024;
  // pszDisplayName 必填：给一块够大的缓冲让系统填，我们不用它的值。
  final display = calloc<Uint16>(maxPath);
  for (var i = 0; i < maxPath; i++) {
    display[i] = 0;
  }
  final titlePtr = title == null ? nullptr : title.toNativeUtf16();
  final bi = calloc<BrowseInfoW>();
  final pathBuf = calloc<Uint16>(maxPath);
  var pidl = 0;
  try {
    bi.ref
      ..hwndOwner = ownerHwnd
      ..pidlRoot = rootPidl
      ..pszDisplayName = display.address
      ..lpszTitle = titlePtr.address
      // ★ modern 分支 = BIF_NEWDIALOGSTYLE；BIF_USENEWUI 只是
      //   (BIF_EDITBOX | BIF_NEWDIALOGSTYLE) 的组合别名，
      //   不能再用 0x4000（那是 BIF_BROWSEINCLUDEFILES）。
      ..ulFlags = bifReturnOnlyFsDirs |
          bifEditBox |
          (modern ? bifNewDialogStyle : 0)
      ..lpfn = 0
      ..lParam = 0
      ..iImage = 0;

    pidl = shBrowseForFolderW(bi);
    if (pidl == 0) return null; // 取消（或框没起来）

    final ok = shGetPathFromIDListW(pidl, pathBuf);
    if (ok == 0) return null;
    final sb = StringBuffer();
    for (var i = 0; i < maxPath; i++) {
      final c = pathBuf[i];
      if (c == 0) break;
      sb.writeCharCode(c);
    }
    final s = sb.toString();
    return s.isEmpty ? null : s;
  } on Object {
    return null;
  } finally {
    // ★ PIDL 必须还：它是 shell 用 CoTaskMemAlloc 分配的。
    if (pidl != 0) coTaskMemFree(pidl);
    calloc.free(bi);
    calloc.free(pathBuf);
    calloc.free(display);
    if (titlePtr != nullptr) calloc.free(titlePtr);
  }
}

/// 读剪贴板里的 Unicode 文本；没有文本或打不开剪贴板时返回 null。
///
/// ★ `OpenClipboard` 会**失败**（另一个进程正持有剪贴板），这是正常竞争，
///   不是错误 —— 所以返回 null 让调用方给个"稍后再试"的提示即可。
/// ★ `GetClipboardData` 返回的是**属于系统**的句柄，**绝对不要 GlobalFree** ——
///   释放它会把剪贴板数据弄坏（经典坑）。
String? readClipboardText() {
  if (isClipboardFormatAvailable(cfUnicodeText) == 0) return null;
  if (openClipboard(0) == 0) return null;
  try {
    final h = getClipboardData(cfUnicodeText);
    if (h == 0) return null;
    // ★ HGLOBAL 句柄**必须**先 GlobalLock 才能当指针用，而且锁了就要配对
    //   GlobalUnlock。这里读的是系统拥有的剪贴板内存，**永远不能 GlobalFree**
    //   （经典的双重释放坑，会把别人的剪贴板数据弄坏）。
    final p = globalLock(h).cast<Uint16>();
    if (p.address == 0) return null;
    try {
      final sb = StringBuffer();
      // CF_UNICODETEXT 是以 NUL 结尾的宽字符串；上限给足避免坏数据导致死循环。
      for (var i = 0; i < 1 << 22; i++) {
        final c = p[i];
        if (c == 0) break;
        sb.writeCharCode(c);
      }
      return sb.toString();
    } finally {
      globalUnlock(h);
    }
  } finally {
    closeClipboard();
  }
}

/// 把 [text] 放进剪贴板（CF_UNICODETEXT）。成功返回 true。
///
/// ★ 为什么要它：`ShellExecuteW` 打不开浏览器时（没默认浏览器 / 被策略拦），
///   光在状态栏说"失败"帮不上忙 —— 把地址复制好，用户至少能手动粘。
bool writeClipboardText(String text) {
  if (openClipboard(0) == 0) return false;
  try {
    if (emptyClipboard() == 0) return false;
    // UTF-16 + 结尾 NUL
    final bytes = (text.length + 1) * 2;
    final h = globalAlloc(gmemMoveable, bytes);
    if (h == 0) return false;
    final p = globalLock(h).cast<Uint16>();
    if (p.address == 0) {
      globalFree(h);
      return false;
    }
    for (var i = 0; i < text.length; i++) {
      p[i] = text.codeUnitAt(i);
    }
    p[text.length] = 0;
    globalUnlock(h);
    if (setClipboardData(cfUnicodeText, h) == 0) {
      globalFree(h);
      return false;
    }
    // ★ 所有权已交给系统 —— 这里**不能**再 free。
    return true;
  } finally {
    closeClipboard();
  }
}

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
// ignore: non_constant_identifier_names
final DynamicLibrary comdlg32 = DynamicLibrary.open('comdlg32.dll');
// ignore: non_constant_identifier_names
final DynamicLibrary uxtheme = DynamicLibrary.open('uxtheme.dll');
// ignore: non_constant_identifier_names
final DynamicLibrary dwmapi = DynamicLibrary.open('dwmapi.dll');

// ── user32 ──
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

/// 把窗口带到前台（用户重复点"数据管理"时把已开的那扇窗拎上来）。
///
/// ★ 系统对"别的进程抢前台"有限制，但**同进程内**调用是允许的，
///   所以这里不会失败；返回 0 也不影响功能（窗口只是没被激活）。
final setForegroundWindow = user32.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('SetForegroundWindow');

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

const int wmDestroy = 0x0002;
const int wmSize = 0x0005;
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
  final filterPtr = calloc<Uint16>(filterUnits.length + 1);
  for (var i = 0; i < filterUnits.length; i++) {
    filterPtr[i] = filterUnits[i];
  }
  filterPtr[filterUnits.length] = 0;

  const maxPath = 1024;
  final fileBuf = calloc<Uint16>(maxPath);
  fileBuf[0] = 0;

  final titlePtr = title == null ? nullptr : title.toNativeUtf16();
  final dirPtr = initialDir == null ? nullptr : initialDir.toNativeUtf16();

  final ofn = calloc<OpenFileNameW>();
  try {
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
    calloc.free(ofn);
    calloc.free(fileBuf);
    calloc.free(filterPtr);
    if (titlePtr != nullptr) calloc.free(titlePtr);
    if (dirPtr != nullptr) calloc.free(dirPtr);
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
    final p = Pointer<Uint16>.fromAddress(h);
    final sb = StringBuffer();
    // CF_UNICODETEXT 是以 NUL 结尾的宽字符串；上限给足避免坏数据导致死循环。
    for (var i = 0; i < 1 << 22; i++) {
      final c = p[i];
      if (c == 0) break;
      sb.writeCharCode(c);
    }
    return sb.toString();
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

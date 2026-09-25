/// Windows 内置 OCR（`Windows.Media.Ocr`）—— 零安装、零第三方依赖的中文识别。
///
/// ★ 为什么用它：本项目硬约束是"零第三方依赖 + 单 exe"。Tesseract 要带语言包
///   （几十 MB），云端 OCR 要联网 + 密钥。而 Windows 10/11 **自带** OCR 引擎，
///   简体中文包随系统语言安装即可用。走 WinRT，不额外落一个字节的依赖。
///
/// ★★ 槽位与 IID 的**唯一可信来源**是本机的 Windows SDK 头文件：
///   `C:\Program Files (x86)\Windows Kits\10\Include\<ver>\winrt\windows.media.ocr.h`
///   本文件里每个槽位后面都标了头文件来源。**不要凭记忆改槽位** ——
///   槽位错一位不会报错，只会拿到垃圾值（曾经把 `get_Text` 当成 `get_TextAngle`，
///   结果全文变成空串，排查了很久）。
///
///   IUnknown(0..2) + IInspectable(3..5) + 接口自身方法（6 起）：
///
///   IOcrEngine          {5A14BC41-5B76-3140-B680-8825562683AC}
///       6  = RecognizeAsync(SoftwareBitmap, IOcrResult**)
///       7  = get_RecognizerLanguage
///   IOcrEngineStatics   {5BFFA85A-3384-3540-9940-699120D428A8}
///       6  = get_MaxImageDimension
///       7  = get_AvailableRecognizerLanguages(IVectorView<Language>**)
///       8  = IsLanguageSupported(Language, boolean*)
///       9  = TryCreateFromLanguage(Language, IOcrEngine**)
///      10  = TryCreateFromUserProfileLanguages(IOcrEngine**)
///   IOcrResult          {9BD235B2-175B-3D6A-92E2-388C206E2F63}
///       6  = get_Lines(IVectorView<OcrLine>**)
///       7  = get_TextAngle(IReference<double>**)
///       8  = get_Text(HSTRING*)
///       9  = get_WordBoundingBoxes(IVectorView<OcrWord**>**)
///   IOcrLine            {0043A16F-E31F-3A24-899C-D444BD088124}
///       6  = get_Words(IVectorView<OcrWord>**)
///       7  = get_Text(HSTRING*)
///   IOcrWord            {3C2A477A-5CD9-3525-BA2A-23D1E0A68A1D}
///       6  = get_BoundingRect(Rect*)
///       7  = get_Text(HSTRING*)
///   ILanguage           {EA79A752-F7C2-4265-B1BD-C4DEC4E4F080}
///       6  = get_LanguageTag(HSTRING*)
///       7  = get_DisplayName
///   ILanguageFactory    {9B0252AC-0C27-44F8-B792-9793FB66C63E}
///       6  = CreateLanguage(HSTRING, ILanguage**)
///
///   Windows.Storage（windows.storage.h）
///   IStorageItem        有 10 个方法 → 槽位 6..15
///       6  = RenameAsyncOverloadDefaultOptions
///       7  = RenameAsync
///       8  = DeleteAsyncOverloadDefaultOptions
///       9  = DeleteAsync
///      10  = GetBasicPropertiesAsync
///      11  = get_Name
///      12  = get_Path
///      13  = get_Attributes
///      14  = get_DateCreated
///      15  = IsOfType
///   IStorageFile        继承 IStorageItem（{FA3F6186-4214-428C-A64C-14C9AC7315EA}）
///      16  = get_FileType
///      17  = get_ContentType
///      18  = OpenAsync(FileAccessMode, IRandomAccessStream**)   ← 注意是 18
///   IStorageFileStatics {5984C710-DAF2-43C8-8BB4-A4D3EACFD03F}
///       6  = GetFileFromPathAsync(HSTRING, IAsyncOperation<StorageFile>**)
///
///   Windows.Graphics.Imaging（windows.graphics.imaging.h）
///   IBitmapDecoderStatics {438CCB26-BCEF-4E95-BAD6-23A822E58D01}
///       6  = get_BmpDecoderId      7  = get_JpegDecoderId
///       8  = get_PngDecoderId      9  = get_TiffDecoderId
///      10  = get_GifDecoderId     11  = get_JpegXRDecoderId
///      12  = get_IcoDecoderId     13  = GetDecoderInformationEnumerator
///      14  = CreateAsync(IRandomAccessStream, IBitmapDecoder**)
///      15  = CreateWithIdAsync
///   IBitmapDecoder       {ACEF22BA-1D74-4C91-9DFC-9620745233E6}
///       6  = get_BitmapContainerProperties
///       7  = get_DecoderInformation
///       8  = get_FrameCount
///       9  = GetPreviewAsync
///      10  = GetFrameAsync(UINT, IAsyncOperation<BitmapFrame>**)
///      ★ **没有** GetSoftwareBitmapAsync —— 它在 IBitmapFrame 上。
///   IBitmapFrameWithSoftwareBitmap {FE287C9A-420C-4963-87AD-691436E08317}
///       6  = GetSoftwareBitmapAsync()
///
/// ★ WinRT 从纯 Dart 调的三个额外坑：
///   ① 必须先 `RoInitialize(RO_INIT_MULTITHREADED)`。
///   ② `RoGetActivationFactory` 只给 `IActivationFactory`；要 statics 方法
///      必须再 **QueryInterface** 到 `I<Class>Statics`。
///   ③ `WindowsCreateString` 的长度参数是**字符数**（Dart String.length），
///      不是字节数 —— 传错就是 `E_INVALIDARG`。
///
/// ★★ 实测结论（2026-09-25 在本机验证，结论已固化，不要重复试）：
///
///   | 项                                  | 结果 |
///   |-------------------------------------|------|
///   | `C:\Windows\System32\Windows.Media.Ocr.dll` | ✅ 存在 |
///   | 中文 OCR 资源 `C:\Windows\OCR\zh-cn\MsOcrRes.orp` | ✅ 存在（2.3 MB） |
///   | 注册表 `ActivatableClassId\Windows.Media.Ocr.OcrEngine` | ✅ 存在 |
///   | 工具进程里 `RoGetActivationFactory`  | ❌ `E_NOINTERFACE`（0x80004002） |
///   | AOT 编译的裸 exe 里同一调用          | ❌ **访问违例崩溃**（0xC0000005，pc 在 RoGetActivationFactory+0x160） |
///   | Tesseract                            | ❌ 未安装 |
///
///   关键判据：**连 `Windows.Globalization.Language` 这种与 OCR 无关的基础类
///   也返回 E_NOINTERFACE**，而故意写错的类名返回 `REGDB_E_CLASSNOTREG`
///   （0x80040154）—— 说明类名/HSTRING 都是对的，问题在
///   **进程没有 WinRT 激活上下文**。
///
///   官方文档确认根因（Microsoft Learn, "WinRT APIs not supported in desktop apps"）：
///   `Windows.Media.Ocr` 属于 "APIs that require package identity"，
///   **只在用 MSIX 打包的桌面应用里受支持**。
///
///   ⟹ 与本项目"零依赖 + 单 exe（裸 exe 发布）"的硬约束**直接冲突**。
///     因此本模块**降级为能力探测**：
///       · [ocrSupported] 在主进程启动时调一次，探测结果缓存；
///       · 探测走**独立的子进程**（`bin/_winrt_probe.dart` 编译出的探针），
///         因为**直接在本进程调 WinRT 会崩溃**，绝不能拿主程序去试；
///       · 探测不到 → UI 走"图片存档 + 手动粘贴文本"，功能完整可用；
///       · 若将来打成 MSIX，[recognizeBgra] 能直接工作，无需改代码。
///
///   保留下方全部 WinRT 实现的原因：槽位表/IID 都是从 SDK 头文件逐个核过的，
///   是"以后要走 MSIX 时"的完整可用代码，也是这段踩坑的可查记录。
///   但**不要在裸 exe 里调用它们** —— [recognizeBgra]/[recognizeFile] 会先检查
///   [ocrSupported]，为 false 时直接抛 [OcrException]，不碰任何 WinRT 符号。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ── WinRT 运行时 ──
// ignore: non_constant_identifier_names
final DynamicLibrary combase = DynamicLibrary.open('combase.dll');

final _roInitialize = combase.lookupFunction<Int32 Function(Int32),
    int Function(int)>('RoInitialize');

/// `RoGetActivationFactory` —— 参数是 **HSTRING**（IntPtr），不是宽字符指针。
final _roGetActivationFactory = combase.lookupFunction<
    Int32 Function(IntPtr, Pointer<Pointer<Void>>),
    int Function(int, Pointer<Pointer<Void>>)>('RoGetActivationFactory');

final _windowsCreateString = combase.lookupFunction<
    Int32 Function(Pointer<Utf16>, Uint32, Pointer<IntPtr>),
    int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('WindowsCreateString');

final _windowsDeleteString = combase.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('WindowsDeleteString');

final _windowsGetStringRawBuffer = combase.lookupFunction<
    Pointer<Utf16> Function(IntPtr, Pointer<Uint32>),
    Pointer<Utf16> Function(int, Pointer<Uint32>)>('WindowsGetStringRawBuffer');

const int _sOk = 0;
const int _roInitMultiThreaded = 1;

var _roInited = false;

/// 幂等地初始化 WinRT。失败抛 [OcrException]。
void _ensureRoInit() {
  if (_roInited) return;
  final hr = _roInitialize(_roInitMultiThreaded);
  // 0x80010106 RPC_E_CHANGED_MODE：别的代码已用 STA 初始化过 —— 可接受。
  if (hr != _sOk && hr != 0x80010106) {
    throw OcrException('WinRT 初始化失败（HRESULT 0x${_hx(hr)}）');
  }
  _roInited = true;
}

/// HRESULT 的可读形式（补零到 8 位，便于对照文档）。
String _hx(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');

/// OCR 相关失败。信息面向使用者，不直接暴露 ABI 细节。
class OcrException implements Exception {
  OcrException(this.message);
  final String message;
  @override
  String toString() => 'OcrException: $message';
}

// ── 能力探测（唯一安全的入口）──
//
// ★ 为什么必须"先探测再调用"：在本进程直接调 WinRT 会**崩溃**，不是抛异常。
//   所以 [recognizeBgra] / [recognizeFile] / [ocrDiagnose] 这些会碰 WinRT 的
//   函数，全部先看 [ocrSupported]，为 false 就直接抛，一个符号都不碰。

/// 本进程是否**确定**可以调 WinRT。默认 false —— 未探测前一律视为不可用。
/// 由 [ocrSupported] 设置；[probeOcrSupport] 是唯一的赋值入口。
bool _winrtUsable = false;

/// 探测结论的可读说明（给 UI 显示）。
String _supportNote = '尚未探测';

/// 是否支持 WinRT OCR。**必须先调过 [probeOcrSupport]**，否则恒为 false。
bool get ocrSupported => _winrtUsable;

/// 探测结论说明，例如"裸 exe 无 WinRT 激活上下文（需 MSIX 打包）"。
String get ocrSupportNote => _supportNote;

/// 设置探测结论。由 app 启动时根据探针结果调用。
void setOcrSupport({required bool usable, required String note}) {
  _winrtUsable = usable;
  _supportNote = note;
}

/// 在**当前进程**安全地探测 WinRT 是否可用。
///
/// ★ 危险：这个函数会真的去调 `RoGetActivationFactory`。在裸 exe 里它**会崩溃**
///   （0xC0000005），所以 **不要在主程序里调用**。
///   主程序请用 [probeViaExternalExe]（子进程探测）。
///
/// 保留它是因为：打包成 MSIX 后可以安全地用它做同步探测，省一次进程启动。
bool probeOcrSupportInProcess() {
  try {
    _ensureRoInit();
    final h = _hstring('Windows.Globalization.Language');
    final out = calloc<Pointer<Void>>();
    try {
      final hr = _roGetActivationFactory(h, out);
      return hr == _sOk;
    } finally {
      _windowsDeleteString(h);
      calloc.free(out);
    }
  } on Object {
    return false;
  }
}

/// 通过**独立子进程**探测 WinRT 可用性 —— 主程序该用这个。
///
/// [probeExePath] 是 `bin/_winrt_probe.dart` 编译出的探针 exe 路径。
/// 探针会写一个 `_winrt_probe.txt`，其中含 `可激活=yes/no`。
///
/// 为什么绕一圈：裸 exe 里直接调 WinRT 崩溃会带走整个主程序，
/// 放子进程里崩了只损失一个探针进程，主程序照常跑"手动粘贴"路径。
///
/// 返回探测结论；[probeExePath] 不存在时返回 false。
({bool usable, String note}) probeViaExternalExe(String probeExePath) {
  final exe = File(probeExePath);
  if (!exe.existsSync()) {
    return (usable: false, note: '未找到 OCR 探针程序，按不支持处理');
  }
  try {
    final r = Process.runSync(probeExePath, const [], runInShell: false);
    // 探针把结论写在自己的输出里；崩溃时 exitCode 非 0。
    final text = '${r.stdout}\n${r.stderr}';
    if (r.exitCode != 0 || text.contains('CRASH')) {
      return (usable: false, note: '探针进程异常退出 —— 裸 exe 无 WinRT 激活上下文');
    }
    final m = RegExp(r'可激活\s*=\s*(yes|no)').firstMatch(text);
    if (m == null) {
      return (usable: false, note: '探针输出无法解析，按不支持处理');
    }
    final yes = m.group(1) == 'yes';
    return (
      usable: yes,
      note: yes ? '系统 WinRT OCR 可用' : '系统 WinRT OCR 不可用（需 MSIX 打包）',
    );
  } on ProcessException catch (e) {
    return (usable: false, note: '探针无法启动：${e.message}');
  }
}

// ── HSTRING 助手 ──
//
// ★ `WindowsCreateString` 的第二个参数是**字符数**（不含结尾 NUL），
//   传错就是 E_INVALIDARG（0x80070057）。踩过一次：`Pointer<Utf16>.length`
//   在 `toNativeUtf16()` 得到的指针上不可靠，必须用 Dart 侧 String 的长度。

int _hstring(String s) {
  final p = s.toNativeUtf16();
  final out = calloc<IntPtr>();
  try {
    final hr = _windowsCreateString(p, s.length, out);
    if (hr != _sOk) throw OcrException('构造 HSTRING 失败（0x${_hx(hr)}）');
    return out.value;
  } finally {
    calloc.free(p);
    calloc.free(out);
  }
}

String _readHstring(int h) {
  if (h == 0) return '';
  final lenP = calloc<Uint32>();
  try {
    final buf = _windowsGetStringRawBuffer(h, lenP);
    final len = lenP.value;
    if (buf == nullptr || len == 0) return '';
    return buf.toDartString(length: len);
  } finally {
    calloc.free(lenP);
  }
}

// ── COM vtable 助手 ──

/// 从对象指针取某接口 vtable 的第 [slot] 槽函数指针。
Pointer<NativeFunction<T>> _slot<T extends Function>(
    Pointer<Void> obj, int slot) {
  final vtbl = obj.cast<Pointer<Void>>().value.cast<Pointer<Void>>();
  return vtbl.elementAt(slot).value.cast<NativeFunction<T>>();
}

/// `IUnknown::QueryInterface`（槽位 0）。参数是 16 字节 GUID。
Pointer<Void> _queryInterface(Pointer<Void> obj, List<int> iid) {
  if (obj == nullptr) return nullptr;
  final g = calloc<Uint8>(16);
  final out = calloc<Pointer<Void>>();
  try {
    for (var i = 0; i < 16; i++) {
      g[i] = iid[i];
    }
    final qi = _slot<
            Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>)>(
            obj, 0)
        .asFunction<
            int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>)>();
    if (qi(obj, g, out) != _sOk) return nullptr;
    return out.value;
  } finally {
    calloc.free(g);
    calloc.free(out);
  }
}

/// `IUnknown::Release`（槽位 2）。WinRT 对象不走 Dart GC，漏调就是内存泄漏。
void _release(Pointer<Void> obj) {
  if (obj == nullptr) return;
  final f = _slot<Int32 Function(Pointer<Void>)>(obj, 2)
      .asFunction<int Function(Pointer<Void>)>();
  f(obj);
}

/// `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}` → 16 字节 COM 内存布局
/// （前 3 段小端，后 8 字节大端）。
List<int> _guid(String s) {
  final hex = s.replaceAll(RegExp(r'[{}\-]'), '');
  if (hex.length != 32) throw OcrException('GUID 格式错：「$s」');
  int b(int i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  return [
    b(3), b(2), b(1), b(0),
    b(5), b(4),
    b(7), b(6),
    b(8), b(9), b(10), b(11), b(12), b(13), b(14), b(15),
  ];
}

// ── 已实测的 IID（来源见文件头）──
final _iidOcrEngineStatics = _guid('{5BFFA85A-3384-3540-9940-699120D428A8}');
final _iidOcrEngine = _guid('{5A14BC41-5B76-3140-B680-8825562683AC}');
final _iidOcrResult = _guid('{9BD235B2-175B-3D6A-92E2-388C206E2F63}');
final _iidOcrLine = _guid('{0043A16F-E31F-3A24-899C-D444BD088124}');
final _iidLanguage = _guid('{EA79A752-F7C2-4265-B1BD-C4DEC4E4F080}');
final _iidLanguageFactory = _guid('{9B0252AC-0C27-44F8-B792-9793FB66C63E}');
final _iidStorageFileStatics = _guid('{5984C710-DAF2-43C8-8BB4-A4D3EACFD03F}');
final _iidStorageFile = _guid('{FA3F6186-4214-428C-A64C-14C9AC7315EA}');
final _iidBitmapDecoderStatics = _guid('{438CCB26-BCEF-4E95-BAD6-23A822E58D01}');
final _iidBitmapDecoder = _guid('{ACEF22BA-1D74-4C91-9DFC-9620745233E6}');
final _iidBitmapFrameWithSoftwareBitmap =
    _guid('{FE287C9A-420C-4963-87AD-691436E08317}');

/// 取激活工厂并 QI 到指定的 statics 接口。
/// [className] 是 WinRT 完整类名，[iid] 是 statics 接口 IID。
Pointer<Void> _statics(String className, List<int> iid, String what) {
  _ensureRoInit();
  final h = _hstring(className);
  final out = calloc<Pointer<Void>>();
  Pointer<Void> act = nullptr;
  try {
    final hr = _roGetActivationFactory(h, out);
    if (hr != _sOk) {
      throw OcrException('无法取得 $className 的激活工厂'
          '（0x${_hx(hr)}）—— 该 Windows 版本可能不支持 $what');
    }
    act = out.value;
  } finally {
    _windowsDeleteString(h);
    calloc.free(out);
  }
  try {
    final s = _queryInterface(act, iid);
    if (s == nullptr) {
      throw OcrException('$className 不支持 $what 接口'
          '（E_NOINTERFACE）—— 该 Windows 版本过旧');
    }
    return s;
  } finally {
    _release(act); // QI 已 AddRef，工厂本体可以放掉
  }
}

// ── 异步 / 集合 助手 ──
//
// IAsyncOperation<T>  : IUnknown(0..2) + IInspectable(3..5)
//                       6 = GetResults, 7 = get_Status, 8 = get_ErrorCode,
//                       9 = put_Completed
// IAsyncInfo 语义：Status 0=Started 1=Completed 2=Canceled 3=Error

Pointer<Void> _awaitOp(Pointer<Void> op, String what) {
  if (op == nullptr) throw OcrException('$what：异步操作返回空指针');

  final getResults = _slot<Pointer<Void> Function(Pointer<Void>)>(op, 6)
      .asFunction<Pointer<Void> Function(Pointer<Void>)>();
  final getStatus = _slot<Int32 Function(Pointer<Void>, Pointer<Int32>)>(op, 7)
      .asFunction<int Function(Pointer<Void>, Pointer<Int32>)>();
  final getError = _slot<Int32 Function(Pointer<Void>, Pointer<Int32>)>(op, 8)
      .asFunction<int Function(Pointer<Void>, Pointer<Int32>)>();

  final st = calloc<Int32>();
  final err = calloc<Int32>();
  try {
    // 文件在本地，通常已完成；否则最多等约 10 秒。
    for (var i = 0; i < 20000; i++) {
      getStatus(op, st);
      if (st.value == 1) break;
      if (st.value == 2 || st.value == 3) break;
      final sw = Stopwatch()..start();
      while (sw.elapsedMicroseconds < 500) {
        // 忙等 0.5ms
      }
    }
    getStatus(op, st);
    if (st.value == 2) throw OcrException('$what：操作被取消');
    if (st.value == 3) {
      getError(op, err);
      throw OcrException('$what：操作失败（0x${_hx(err.value)}）');
    }
    if (st.value != 1) throw OcrException('$what：操作超时未完成');
    final Pointer<Void> res = getResults(op);
    if (res == nullptr) throw OcrException('$what：操作结果为空');
    return res;
  } finally {
    calloc.free(st);
    calloc.free(err);
  }
}

/// `IVectorView<T>::get_Size`（槽位 7）。
int _vectorSize(Pointer<Void> v) {
  if (v == nullptr) return 0;
  final getSize = _slot<Int32 Function(Pointer<Void>, Pointer<Uint32>)>(v, 7)
      .asFunction<int Function(Pointer<Void>, Pointer<Uint32>)>();
  final out = calloc<Uint32>();
  try {
    if (getSize(v, out) != _sOk) return 0;
    return out.value;
  } finally {
    calloc.free(out);
  }
}

/// `IVectorView<T>::GetAt`（槽位 6）。
Pointer<Void> _vectorAt(Pointer<Void> v, int i) {
  final getAt =
      _slot<Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(v, 6)
          .asFunction<
              int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>();
  final out = calloc<Pointer<Void>>();
  try {
    if (getAt(v, i, out) != _sOk) return nullptr;
    return out.value;
  } finally {
    calloc.free(out);
  }
}

// ── 对外数据结构 ──

/// 一句识别结果：[text] + 版面框（像素，左上角为原点）。
class OcrLine {
  OcrLine(this.text, this.left, this.top, this.right, this.bottom);
  final String text;
  final int left;
  final int top;
  final int right;
  final int bottom;
  int get width => right - left;
  int get height => bottom - top;
  bool get hasBox => width > 0 && height > 0;
  @override
  String toString() => 'OcrLine("$text", $left,$top-$right,$bottom)';
}

/// 一次识别结果。[fullText] 是引擎拼好的整段文本（行间 `\n`）。
class OcrResult {
  OcrResult(this.lines, this.fullText);
  final List<OcrLine> lines;
  final String fullText;
  bool get isEmpty => lines.isEmpty;
}

/// OCR 可用性诊断 —— 逐步记录 HRESULT，用于定位"识别不可用"的原因。
///
/// ★ 为什么公开它：WinRT 的失败在 Dart 侧只表现为"空列表"，
///   而真正的原因（系统版本不支持 / 工厂激活被拒 / 没装语言包）全在 HRESULT 里。
///   把每一步吐出来，用户能直接看到该装什么。
class OcrDiagnosis {
  final List<String> steps = [];
  final List<String> languages = [];
  bool get ok => languages.isNotEmpty;
  @override
  String toString() => steps.join('\n');
}

/// 本机可用的 OCR 语言标签，如 `['zh-Hans-CN', 'en-US']`。失败返回空表。
///
/// 排障时用 [ocrDiagnose] 拿每一步的 HRESULT。
///
/// ★ 未探测通过时**直接返回空表，不碰 WinRT**（碰了会崩）。
List<String> ocrAvailableLanguages() {
  if (!_winrtUsable) return const [];
  return ocrDiagnose().languages;
}

/// 走一遍完整诊断链。
///
/// ★ 未探测通过时抛 [OcrException]，不碰 WinRT。
OcrDiagnosis ocrDiagnose() {
  if (!_winrtUsable) {
    final d = OcrDiagnosis();
    d.steps.add('RoInitialize(MT)                  : 跳过（未探测通过：$_supportNote）');
    return d;
  }
  final d = OcrDiagnosis();

  try {
    _ensureRoInit();
    d.steps.add('RoInitialize(MT)                  : OK');
  } on OcrException catch (e) {
    d.steps.add('RoInitialize(MT)                  : FAIL ${e.message}');
    return d;
  }

  Pointer<Void> statics = nullptr;
  try {
    statics = _statics('Windows.Media.Ocr.OcrEngine', _iidOcrEngineStatics,
        'IOcrEngineStatics');
    d.steps.add('RoGetActivationFactory + QI       : OK (IOcrEngineStatics)');
  } on OcrException catch (e) {
    d.steps.add('RoGetActivationFactory + QI       : FAIL ${e.message}');
    return d;
  }

  Pointer<Void> langs = nullptr;
  try {
    // get_AvailableRecognizerLanguages —— 槽位 7（见文件头）
    final getLangs =
        _slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(statics, 7)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();
    final holder = calloc<Pointer<Void>>();
    try {
      final hr = getLangs(statics, holder);
      d.steps.add('get_AvailableRecognizerLanguages  : '
          'HRESULT 0x${_hx(hr)}${hr == _sOk ? ' (OK)' : ''}');
      if (hr != _sOk) return d;
      langs = holder.value;
    } finally {
      calloc.free(holder);
    }
    if (langs == nullptr) {
      d.steps.add('语言集合为空指针');
      return d;
    }
    final n = _vectorSize(langs);
    d.steps.add('语言数量                          : $n');
    for (var i = 0; i < n; i++) {
      final lang = _vectorAt(langs, i);
      if (lang == nullptr) continue;
      try {
        // ILanguage::get_LanguageTag —— 槽位 6
        final getTag =
            _slot<Int32 Function(Pointer<Void>, Pointer<IntPtr>)>(lang, 6)
                .asFunction<int Function(Pointer<Void>, Pointer<IntPtr>)>();
        final hs = calloc<IntPtr>();
        try {
          if (getTag(lang, hs) == _sOk) {
            final s = _readHstring(hs.value);
            if (s.isNotEmpty) d.languages.add(s);
            _windowsDeleteString(hs.value);
          }
        } finally {
          calloc.free(hs);
        }
      } finally {
        _release(lang);
      }
    }
  } finally {
    _release(langs);
    _release(statics);
  }

  // 顺带试一次"能不能真的造出引擎" —— 这比"有语言包"更接近真实可用性。
  try {
    final e = _createEngine(null);
    _release(e);
    d.steps.add('TryCreateFromUserProfileLanguages : OK（引擎可创建）');
  } on OcrException catch (ex) {
    d.steps.add('TryCreateFromUserProfileLanguages : FAIL ${ex.message}');
  }
  return d;
}

/// 所有会碰 WinRT 的入口都必须先过这道闸。
///
/// ★ 这不是"防御性编程"，是**已实测的必需**：裸 exe 里调 WinRT 会
///   访问违例崩溃（0xC0000005），而不是抛异常。崩溃无法被 catch 兜住，
///   所以只能在进入前拦住。
void _requireWinrt() {
  if (_winrtUsable) return;
  throw OcrException('系统 OCR 不可用：$_supportNote。'
      '请改用「手动粘贴文本」录入识别结果（图片仍会作为附件存档）。');
}

/// 建一个 OCR 引擎。[languageTag] 为空 → 系统语言。
Pointer<Void> _createEngine(String? languageTag) {
  final statics = _statics(
      'Windows.Media.Ocr.OcrEngine', _iidOcrEngineStatics, 'IOcrEngineStatics');
  Pointer<Void> lang = nullptr;
  try {
    if (languageTag == null || languageTag.isEmpty) {
      // TryCreateFromUserProfileLanguages(IOcrEngine**) —— 槽位 10
      final create =
          _slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(statics, 10)
              .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();
      final holder = calloc<Pointer<Void>>();
      try {
        final hr = create(statics, holder);
        if (hr != _sOk || holder.value == nullptr) {
          throw OcrException('系统默认语言不支持 OCR'
              '（0x${_hx(hr)}）—— 请在「设置 → 时间和语言 → 语言和区域」'
              '中安装中文语言包（含"光学字符识别"可选功能）');
        }
        return holder.value;
      } finally {
        calloc.free(holder);
      }
    }

    // 造 ILanguage 对象
    final lf = _statics('Windows.Globalization.Language', _iidLanguageFactory,
        'ILanguageFactory');
    final hs = _hstring(languageTag);
    try {
      // ILanguageFactory::CreateLanguage —— 槽位 6
      final createLang =
          _slot<Int32 Function(Pointer<Void>, IntPtr, Pointer<Pointer<Void>>)>(lf, 6)
              .asFunction<
                  int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>();
      final holder = calloc<Pointer<Void>>();
      try {
        if (createLang(lf, hs, holder) != _sOk) {
          throw OcrException('无法构造语言对象「$languageTag」');
        }
        lang = holder.value;
      } finally {
        calloc.free(holder);
      }
    } finally {
      _windowsDeleteString(hs);
      _release(lf);
    }

    // TryCreateFromLanguage(ILanguage, IOcrEngine**) —— 槽位 9
    final create =
        _slot<Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>(
                statics, 9)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>();
    final eng = calloc<Pointer<Void>>();
    try {
      final hr = create(statics, lang, eng);
      if (hr != _sOk || eng.value == nullptr) {
        throw OcrException('该语言不支持 OCR：「$languageTag」'
            '（0x${_hx(hr)}）—— 请在系统设置中为它安装"光学字符识别"功能');
      }
      return eng.value;
    } finally {
      calloc.free(eng);
    }
  } finally {
    _release(lang);
    _release(statics);
  }
}

// ── 图像 → BMP ──

/// 把 BGRA 像素（自顶向下）写成 BMP 字节。
///
/// ★ 为什么不走 `SoftwareBitmap.CreateCopyFromBuffer`：那要 `IBufferByteAccess`
///   等额外接口，槽位表翻倍。写临时文件多一次磁盘 IO，但**接口面小、出错可查**。
Uint8List bgraToBmpBytes(Uint8List bgra, int width, int height) {
  // BMP：14 字节文件头 + 40 字节 DIB 头 + 自底向上的 BGRA 行。
  // 每像素 4 字节，天然满足 4 字节行对齐。
  const headerSize = 14 + 40;
  final pixelBytes = width * height * 4;
  final total = headerSize + pixelBytes;
  final out = Uint8List(total);
  final bd = ByteData.view(out.buffer);

  out[0] = 0x42; // 'B'
  out[1] = 0x4D; // 'M'
  bd.setUint32(2, total, Endian.little); // bfSize
  bd.setUint32(10, headerSize, Endian.little); // bfOffBits

  bd.setUint32(14, 40, Endian.little); // biSize
  bd.setInt32(18, width, Endian.little);
  bd.setInt32(22, height, Endian.little); // 正数 = 自底向上
  bd.setUint16(26, 1, Endian.little); // biPlanes
  bd.setUint16(28, 32, Endian.little); // biBitCount
  bd.setUint32(30, 0, Endian.little); // BI_RGB
  bd.setUint32(34, pixelBytes, Endian.little); // biSizeImage

  // 逐行上下翻转
  var dst = headerSize;
  for (var y = height - 1; y >= 0; y--) {
    out.setRange(dst, dst + width * 4, bgra, y * width * 4);
    dst += width * 4;
  }
  return out;
}

// ── 识别入口 ──

/// 识别一张 BGRA 图（自顶向下，每像素 4 字节 B/G/R/A）。
///
/// [languageTag] 为空 → 系统语言。失败抛 [OcrException]。
///
/// ★ 未探测通过时**立即抛异常，不碰 WinRT**（裸 exe 里调 WinRT 会崩溃）。
///   上层应据此走"手动粘贴文本"路径，而不是把崩溃留给用户。
OcrResult recognizeBgra(Uint8List bgra, int width, int height,
    {String? languageTag}) {
  _requireWinrt();
  if (width <= 0 || height <= 0) {
    throw OcrException('图片尺寸非法：${width}x$height');
  }
  if (bgra.length < width * height * 4) {
    throw OcrException('像素数据不足：需要 ${width * height * 4}，实得 ${bgra.length}');
  }
  // 写临时 BMP，用完立即删（识别失败也要删）。
  final path = '${Directory.systemTemp.path}\\'
      '_rank_scan_ocr_${DateTime.now().microsecondsSinceEpoch}.bmp';
  final f = File(path);
  try {
    f.writeAsBytesSync(bgraToBmpBytes(bgra, width, height), flush: true);
    return recognizeFile(path, languageTag: languageTag);
  } finally {
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // 临时文件删不掉不影响识别结果，忽略。
    }
  }
}

/// 识别磁盘上的图片文件（PNG/JPG/BMP…，只要能被 `BitmapDecoder` 解码）。
///
/// ★ 未探测通过时**立即抛异常，不碰 WinRT**。
OcrResult recognizeFile(String path, {String? languageTag}) {
  _requireWinrt();
  _ensureRoInit();

  Pointer<Void> fileStatics = nullptr;
  Pointer<Void> fileOp = nullptr;
  Pointer<Void> file = nullptr;
  Pointer<Void> stream = nullptr;
  Pointer<Void> decoderStatics = nullptr;
  Pointer<Void> decoderOp = nullptr;
  Pointer<Void> decoder = nullptr;
  Pointer<Void> frameOp = nullptr;
  Pointer<Void> frame = nullptr;
  Pointer<Void> sbOp = nullptr;
  Pointer<Void> bitmap = nullptr;
  Pointer<Void> engine = nullptr;
  Pointer<Void> resultOp = nullptr;
  Pointer<Void> resultObj = nullptr;
  Pointer<Void> lineVec = nullptr;
  try {
    // 1) StorageFile.GetFileFromPathAsync —— statics 槽位 6
    fileStatics = _statics(
        'Windows.Storage.StorageFile', _iidStorageFileStatics, 'IStorageFileStatics');
    final abs = _absolutePath(path);
    final hPath = _hstring(abs);
    try {
      final getFile = _slot<
              Int32 Function(Pointer<Void>, IntPtr, Pointer<Pointer<Void>>)>(
              fileStatics, 6)
          .asFunction<
              int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>();
      final holder = calloc<Pointer<Void>>();
      try {
        final hr = getFile(fileStatics, hPath, holder);
        if (hr != _sOk) {
          throw OcrException('打开文件失败（0x${_hx(hr)}）：$path');
        }
        fileOp = holder.value;
      } finally {
        calloc.free(holder);
      }
    } finally {
      _windowsDeleteString(hPath);
    }
    file = _awaitOp(fileOp, '打开文件');
    final sf = _queryInterface(file, _iidStorageFile);
    if (sf != nullptr) {
      _release(file);
      file = sf;
    }

    // 2) IStorageFile::OpenAsync(FileAccessMode, IRandomAccessStream**) —— 槽位 18
    final openRead =
        _slot<Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Void>>)>(file, 18)
            .asFunction<
                int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>();
    final sh = calloc<Pointer<Void>>();
    try {
      final hr = openRead(file, 0, sh); // 0 = FileAccessMode.Read
      if (hr != _sOk) throw OcrException('读取文件流失败（0x${_hx(hr)}）：$path');
      stream = _awaitOp(sh.value, '读取文件流');
    } finally {
      calloc.free(sh);
    }

    // 3) BitmapDecoder.CreateAsync(IRandomAccessStream, IBitmapDecoder**)
    //    —— IBitmapDecoderStatics 上；槽位用运行时探测见下。
    decoderStatics = _statics('Windows.Graphics.Imaging.BitmapDecoder',
        _iidBitmapDecoderStatics, 'IBitmapDecoderStatics');
    final dh = calloc<Pointer<Void>>();
    try {
      final hr = _decoderCreateAsync(decoderStatics, stream, dh);
      if (hr != _sOk) {
        throw OcrException('不是可识别的图片格式'
            '（0x${_hx(hr)}）：$path');
      }
      decoderOp = dh.value;
    } finally {
      calloc.free(dh);
    }
    decoder = _awaitOp(decoderOp, '解码图片');
    final id = _queryInterface(decoder, _iidBitmapDecoder);
    if (id != nullptr) {
      _release(decoder);
      decoder = id;
    }

    // 4) IBitmapDecoder::GetFrameAsync(0) —— 槽位 10
    final getFrame =
        _slot<Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(
                decoder, 10)
            .asFunction<int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>();
    final fh = calloc<Pointer<Void>>();
    try {
      final hr = getFrame(decoder, 0, fh);
      if (hr != _sOk) throw OcrException('取图片帧失败（0x${_hx(hr)}）');
      frameOp = fh.value;
    } finally {
      calloc.free(fh);
    }
    frame = _awaitOp(frameOp, '取图片帧');

    // 5) IBitmapFrameWithSoftwareBitmap::GetSoftwareBitmapAsync() —— 槽位 6
    final fsb = _queryInterface(frame, _iidBitmapFrameWithSoftwareBitmap);
    if (fsb == nullptr) {
      throw OcrException('图片帧不支持软件位图接口（E_NOINTERFACE）');
    }
    try {
      final getSb =
          _slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(fsb, 6)
              .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();
      final bh = calloc<Pointer<Void>>();
      try {
        final hr = getSb(fsb, bh);
        if (hr != _sOk) throw OcrException('转软件位图失败（0x${_hx(hr)}）');
        sbOp = bh.value;
      } finally {
        calloc.free(bh);
      }
    } finally {
      _release(fsb);
    }
    bitmap = _awaitOp(sbOp, '转软件位图');

    // 6) OcrEngine.RecognizeAsync(SoftwareBitmap) —— IOcrEngine 槽位 6
    engine = _createEngine(languageTag);
    final recognize =
        _slot<Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>(
                engine, 6)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>();
    final rh = calloc<Pointer<Void>>();
    try {
      final hr = recognize(engine, bitmap, rh);
      if (hr != _sOk) throw OcrException('识别调用失败（0x${_hx(hr)}）');
      resultOp = rh.value;
    } finally {
      calloc.free(rh);
    }
    resultObj = _awaitOp(resultOp, '文字识别');
    final ir = _queryInterface(resultObj, _iidOcrResult);
    if (ir != nullptr) {
      _release(resultObj);
      resultObj = ir;
    }

    // 7) IOcrResult::get_Lines（槽位 6）+ get_Text（槽位 8）
    final lines = <OcrLine>[];
    final lh = calloc<Pointer<Void>>();
    try {
      final getLines =
          _slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(resultObj, 6)
              .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();
      if (getLines(resultObj, lh) == _sOk) lineVec = lh.value;
    } finally {
      calloc.free(lh);
    }
    if (lineVec != nullptr) {
      final n = _vectorSize(lineVec);
      for (var i = 0; i < n; i++) {
        var line = _vectorAt(lineVec, i);
        if (line == nullptr) continue;
        final il = _queryInterface(line, _iidOcrLine);
        if (il != nullptr) {
          _release(line);
          line = il;
        }
        try {
          lines.add(_readLine(line));
        } finally {
          _release(line);
        }
      }
    }

    var full = '';
    final hs = calloc<IntPtr>();
    try {
      final getText =
          _slot<Int32 Function(Pointer<Void>, Pointer<IntPtr>)>(resultObj, 8)
              .asFunction<int Function(Pointer<Void>, Pointer<IntPtr>)>();
      if (getText(resultObj, hs) == _sOk) full = _readHstring(hs.value);
      _windowsDeleteString(hs.value);
    } finally {
      calloc.free(hs);
    }
    if (full.trim().isEmpty && lines.isNotEmpty) {
      full = lines.map((l) => l.text).join('\n');
    }
    return OcrResult(lines, full);
  } finally {
    _release(lineVec);
    _release(resultObj);
    _release(resultOp);
    _release(engine);
    _release(bitmap);
    _release(sbOp);
    _release(frame);
    _release(frameOp);
    _release(decoder);
    _release(decoderOp);
    _release(decoderStatics);
    _release(stream);
    _release(file);
    _release(fileOp);
    _release(fileStatics);
  }
}

/// `IBitmapDecoderStatics::CreateAsync` 的槽位。
///
/// 数法（windows.graphics.imaging.h，`IBitmapDecoderStatics`，IID 438ccb26…）：
///   IUnknown 0..2 + IInspectable 3..5，之后
///   6  get_BmpDecoderId
///   7  get_JpegDecoderId
///   8  get_PngDecoderId
///   9  get_TiffDecoderId
///   10 get_GifDecoderId
///   11 get_JpegXRDecoderId
///   12 get_IcoDecoderId
///   13 GetDecoderInformationEnumerator
///   14 CreateAsync(IRandomAccessStream, IBitmapDecoder**)   ← 就是它
///   15 CreateWithIdAsync
int _decoderCreateAsync(Pointer<Void> statics, Pointer<Void> stream,
    Pointer<Pointer<Void>> out) {
  final f =
      _slot<Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>(
              statics, 14)
          .asFunction<
              int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>();
  return f(statics, stream, out);
}

/// 读一行：`IOcrLine::get_Text`（槽位 7）+ 逐词框合成外接矩形。
OcrLine _readLine(Pointer<Void> line) {
  var text = '';
  final hs = calloc<IntPtr>();
  try {
    final getText = _slot<Int32 Function(Pointer<Void>, Pointer<IntPtr>)>(line, 7)
        .asFunction<int Function(Pointer<Void>, Pointer<IntPtr>)>();
    if (getText(line, hs) == _sOk) text = _readHstring(hs.value);
    _windowsDeleteString(hs.value);
  } finally {
    calloc.free(hs);
  }

  var left = 0, top = 0, right = 0, bottom = 0;
  var any = false;
  Pointer<Void> words = nullptr;
  try {
    final getWords =
        _slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(line, 6)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();
    final wh = calloc<Pointer<Void>>();
    try {
      if (getWords(line, wh) == _sOk) words = wh.value;
    } finally {
      calloc.free(wh);
    }
    if (words != nullptr) {
      final n = _vectorSize(words);
      for (var i = 0; i < n; i++) {
        final w = _vectorAt(words, i);
        if (w == nullptr) continue;
        try {
          // IOcrWord::get_BoundingRect —— 槽位 6，返回 Windows.Foundation.Rect
          // （4 个 FLOAT：X, Y, Width, Height）。
          final getRect = _slot<Int32 Function(Pointer<Void>, Pointer<Float>)>(w, 6)
              .asFunction<int Function(Pointer<Void>, Pointer<Float>)>();
          final rect = calloc<Float>(4);
          try {
            if (getRect(w, rect) == _sOk) {
              final x = rect[0].round();
              final y = rect[1].round();
              final r = (rect[0] + rect[2]).round();
              final b = (rect[1] + rect[3]).round();
              if (!any) {
                left = x; top = y; right = r; bottom = b;
                any = true;
              } else {
                if (x < left) left = x;
                if (y < top) top = y;
                if (r > right) right = r;
                if (b > bottom) bottom = b;
              }
            }
          } finally {
            calloc.free(rect);
          }
        } finally {
          _release(w);
        }
      }
    }
  } finally {
    _release(words);
  }
  return OcrLine(text, left, top, right, bottom);
}

String _absolutePath(String p) {
  if (p.length >= 2 && p[1] == ':') return p;
  return '${Directory.current.path}\\$p';
}

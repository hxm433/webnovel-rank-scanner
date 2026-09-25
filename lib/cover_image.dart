/// 封面图片解码 —— 借系统 **WIC**（Windows Imaging Component）。
///
/// ★ 为什么必须借系统解码器：四个平台的封面 CDN 给的是 **JPEG / WebP**
///   （实测：起点 `/150` 是 `image/jpeg`，`/150.webp` 是 `image/webp`），
///   而本项目手写的解码器只有 PNG（`lib/png.dart`）。
///   自己写 JPEG 还勉强（基线 ~600 行），写 WebP 里的 VP8 完全不现实。
///
/// ★ 为什么是 WIC 而不是别的：
///   - `OleLoadPictureFile`（oleaut32）更简单，但它**不认 WebP**；
///   - WinRT 的 `BitmapDecoder` 在本项目的裸 exe 里**会崩**（见 `lib/ocr.dart`
///     的实测结论：0xC0000005，需 MSIX 打包）；
///   - WIC 走的是**经典 COM**（`CoCreateInstance`），不需要 WinRT 激活上下文。
///     这是本项目里唯一一条"零依赖 + 能解 JPEG/WebP"的路。
///
/// ★★ 槽位与 GUID 的**唯一可信来源**是本机 SDK 头文件：
///   `C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um\wincodec.h`
///   每个槽位后面都标了它对应的函数名。**不要凭记忆改** ——
///   槽位错一位不会报错，只会拿到垃圾指针然后崩。
///
///   IUnknown 占 0..2，其余接口的**自有**方法从 3 开始；
///   继承来的方法排在前面（所以 IWICFormatConverter 的 Initialize 在 8 而不是 3）。
///
///   IWICImagingFactory {CACAF262-9370-4615-A13B-9F5539DA4C0A}
///       3  CreateDecoderFromFilename(LPCWSTR, const GUID*, DWORD, WICDecodeOptions, IWICBitmapDecoder**)
///      10  CreateFormatConverter(IWICFormatConverter**)
///      11  CreateBitmapScaler(IWICBitmapScaler**)
///   IWICBitmapDecoder {9EDDE9E7-8DEE-47ea-99DF-E6FAF2ED44BF}
///      13  GetFrame(UINT, IWICBitmapFrameDecode**)
///   IWICBitmapSource {00000120-a8f2-4877-ba0a-fd2b6645fb94}
///       3  GetSize(UINT*, UINT*)
///       7  CopyPixels(const WICRect*, UINT, UINT, BYTE*)
///   IWICBitmapScaler {00000302-a8f2-4877-ba0a-fd2b6645fb94}
///       8  Initialize(IWICBitmapSource*, UINT, UINT, WICBitmapInterpolationMode)
///   IWICFormatConverter {00000301-a8f2-4877-ba0a-fd2b6645fb94}
///       8  Initialize(IWICBitmapSource*, REFWICPixelFormatGUID, WICBitmapDitherType,
///                     IWICPalette*, double, WICBitmapPaletteType)
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ───────────────────────── Win32 / COM 绑定 ─────────────────────────

final DynamicLibrary _ole32 = DynamicLibrary.open('ole32.dll');

final _coInitializeEx = _ole32.lookupFunction<
    Int32 Function(Pointer<Void>, Uint32),
    int Function(Pointer<Void>, int)>('CoInitializeEx');

final _coUninitialize =
    _ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize');

final _coCreateInstance = _ole32.lookupFunction<
    Int32 Function(Pointer<Guid16>, Pointer<Void>, Uint32, Pointer<Guid16>,
        Pointer<Pointer<Void>>),
    int Function(Pointer<Guid16>, Pointer<Void>, int, Pointer<Guid16>,
        Pointer<Pointer<Void>>)>('CoCreateInstance');

/// 16 字节 GUID（`GUID` 结构体，Dart 里按字节数组传最省事）。
final class Guid16 extends Struct {
  @Array(16)
  external Array<Uint8> bytes;
}

/// 用 `0x6fddc324, 0x4e03, 0x4bfe, b1 85 3d 77 76 8d c9 0f` 这种写法建一个 GUID。
///
/// ★ 前三个字段是**小端**，后八个是字节序原样 —— 这是 GUID 的线格式，
///   写成大端会拿到一个不存在的接口。
Pointer<Guid16> _guid(int d1, int d2, int d3, List<int> rest) {
  final p = calloc<Guid16>();
  final b = p.ref.bytes;
  b[0] = d1 & 0xFF;
  b[1] = (d1 >> 8) & 0xFF;
  b[2] = (d1 >> 16) & 0xFF;
  b[3] = (d1 >> 24) & 0xFF;
  b[4] = d2 & 0xFF;
  b[5] = (d2 >> 8) & 0xFF;
  b[6] = d3 & 0xFF;
  b[7] = (d3 >> 8) & 0xFF;
  for (var i = 0; i < 8; i++) {
    b[8 + i] = rest[i];
  }
  return p;
}

const int _clsCtxInprocServer = 0x1;
const int _genericRead = 0x80000000;

/// 取 COM 对象的第 [i] 个 vtable 槽位。
///
/// ★ 这里是**最容易写错的一步**，错法还很隐蔽：`Pointer.elementAt(i)` 返回的是
///   "第 i 个槽位的**地址**"，不是槽位里的值 —— 少读一次就会把"指向函数指针的
///   指针"当成函数指针去调，直接访问违例（第一次就是这么崩的）。
///   两次解引用：对象 → vtable 基址；vtable + i×指针宽 → 函数地址。
Pointer<NativeFunction<T>> _slot<T extends Function>(Pointer<Void> obj, int i) {
  final vtable = obj.cast<Pointer<Pointer<Void>>>().value; // 对象首字段 = vtable 基址
  final fn = vtable.cast<IntPtr>().elementAt(i).value; // 第 i 个槽位里的函数地址
  return Pointer<NativeFunction<T>>.fromAddress(fn);
}

void _release(Pointer<Void> obj) {
  if (obj == nullptr) return;
  // ★ `asFunction` 的类型参数要写 **Dart 侧**的签名（int），不是原生侧的
  //   （Int32）—— 写反了编译期就报 "Expected type ... to be ..."。
  _slot<Int32 Function(Pointer<Void>)>(obj, 2)
      .asFunction<int Function(Pointer<Void>)>()(obj);
}

/// 解码结果：BGRA（与 `lib/png.dart`、GDI 的 DIB 口径一致）。
class BgraImage {
  const BgraImage(this.width, this.height, this.bgra);
  final int width;
  final int height;
  final Uint8List bgra;
}

// ───────────────────────── 可用性探测 ─────────────────────────

/// WIC 是否可用。**必须先探测再解码** —— 探测本身只做
/// `CoInitializeEx` + `CoCreateInstance`，失败也只是个 HRESULT（不会崩），
/// 但一旦真去调 vtable 就不一样了，所以先把"能不能拿到工厂"问清楚。
class WicSupport {
  static bool? _usable;
  static String _note = '未探测';

  static bool get usable => _usable == true;
  static String get note => _note;

  /// 探测一次（幂等）。
  static bool probe() {
    if (_usable != null) return _usable!;
    final coInit = _coInitializeEx(nullptr, 2); // COINIT_APARTMENTTHREADED
    // S_OK(0) / S_FALSE(1) / RPC_E_CHANGED_MODE(0x80010106) 都算"COM 可用"
    final comOk = coInit == 0 || coInit == 1 || coInit == -2147417850;
    if (!comOk) {
      _usable = false;
      _note = 'CoInitializeEx 失败（0x${(coInit & 0xFFFFFFFF).toRadixString(16)}）';
      return false;
    }
    final clsid = _guid(0xCACAF262, 0x9370, 0x4615,
        [0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A]);
    final iid = _guid(0xEC5EC8A9, 0xC395, 0x4314,
        [0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70]);
    final out = calloc<Pointer<Void>>();
    final hr = _coCreateInstance(clsid, nullptr, _clsCtxInprocServer, iid, out);
    final factory = out.value;
    if (hr == 0 && factory != nullptr) {
      _release(factory);
      _usable = true;
      _note = '系统 WIC 可用（可解 JPEG / PNG / WebP / GIF）';
    } else {
      _usable = false;
      _note = 'CoCreateInstance(WICImagingFactory) 失败'
          '（hr=0x${(hr & 0xFFFFFFFF).toRadixString(16)}）';
    }
    calloc.free(clsid);
    calloc.free(iid);
    calloc.free(out);
    return _usable!;
  }
}

// ───────────────────────── 解码 ─────────────────────────

/// 把 [path] 指向的图片解码并**缩放到 [wantW]×[wantH]**，返回 BGRA。
///
/// 失败返回 null（调用方退回占位卡，绝不抛 —— 一张封面读不出来不该影响整张表）。
BgraImage? decodeCoverFile(String path, int wantW, int wantH) {
  if (!WicSupport.probe() || wantW <= 0 || wantH <= 0) return null;

  final clsid = _guid(0xCACAF262, 0x9370, 0x4615,
      [0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A]);
  final iid = _guid(0xEC5EC8A9, 0xC395, 0x4314,
      [0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70]);
  final out = calloc<Pointer<Void>>();
  Pointer<Void> factory = nullptr;
  Pointer<Void> decoder = nullptr;
  Pointer<Void> frame = nullptr;
  Pointer<Void> scaler = nullptr;
  Pointer<Void> conv = nullptr;
  final pathPtr = path.toNativeUtf16();
  Pointer<Uint8>? buf;
  try {
    if (_coCreateInstance(clsid, nullptr, _clsCtxInprocServer, iid, out) != 0) {
      return null;
    }
    factory = out.value;
    if (factory == nullptr) return null;

    // 3 = CreateDecoderFromFilename(wzFilename, vendor, access, options, out)
    final hrDec = _slot<
            Int32 Function(Pointer<Void>, Pointer<Utf16>, Pointer<Void>, Uint32,
                Int32, Pointer<Pointer<Void>>)>(factory, 3)
        .asFunction<
            int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Void>, int,
                int, Pointer<Pointer<Void>>)>()(
        factory, pathPtr, nullptr, _genericRead, 0, out);
    if (hrDec != 0) return null;
    decoder = out.value;

    // 13 = GetFrame(0, out)
    if (_slot<Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(
                decoder, 13)
            .asFunction<
                int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>()(
        decoder, 0, out) !=
        0) {
      return null;
    }
    frame = out.value;

    // 11 = CreateBitmapScaler(out) —— 让系统按 Fant 插值缩，比我们自己盒式抽样好
    if (_slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(factory, 11)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>()(
        factory, out) !=
        0) {
      return null;
    }
    scaler = out.value;
    // 8 = IWICBitmapScaler::Initialize(src, w, h, mode=3 Fant)
    if (_slot<
                Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Uint32,
                    Int32)>(scaler, 8)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Void>, int, int, int)>()(
        scaler, frame, wantW, wantH, 3) !=
        0) {
      return null;
    }

    // 10 = CreateFormatConverter(out)
    if (_slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(factory, 10)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>()(
        factory, out) !=
        0) {
      return null;
    }
    conv = out.value;
    // 8 = IWICFormatConverter::Initialize(src, dstFormat, dither, palette, alpha, paletteType)
    final fmtBgra = _guid(0x6FDDC324, 0x4E03, 0x4BFE,
        [0xB1, 0x85, 0x3D, 0x77, 0x76, 0x8D, 0xC9, 0x0F]);
    final hrInit = _slot<
            Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Guid16>, Int32,
                Pointer<Void>, Double, Int32)>(conv, 8)
        .asFunction<
            int Function(Pointer<Void>, Pointer<Void>, Pointer<Guid16>, int,
                Pointer<Void>, double, int)>()(
        conv, scaler, fmtBgra, 0, nullptr, 0, 0);
    calloc.free(fmtBgra);
    if (hrInit != 0) return null;

    // 7 = CopyPixels(prc=null 全图, stride, size, buffer)
    final stride = wantW * 4;
    final size = stride * wantH;
    buf = calloc<Uint8>(size);
    if (_slot<
                Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Uint32,
                    Pointer<Uint8>)>(conv, 7)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Void>, int, int,
                    Pointer<Uint8>)>()(
        conv, nullptr, stride, size, buf) !=
        0) {
      return null;
    }
    return BgraImage(wantW, wantH, Uint8List.fromList(buf.asTypedList(size)));
  } on Object {
    // 解码失败一律返回 null（占位卡兜底），不让一张图带崩界面
    return null;
  } finally {
    if (buf != null) calloc.free(buf);
    _release(conv);
    _release(scaler);
    _release(frame);
    _release(decoder);
    _release(factory);
    calloc.free(clsid);
    calloc.free(iid);
    calloc.free(out);
    calloc.free(pathPtr);
  }
}

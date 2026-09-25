/// GDI 绘图封装 —— 把易错的句柄管理、颜色转换、字体缓存集中到一处。
///
/// ★ 三个必须守住的点：
///   ① **每次 SelectObject 都要还原**：GDI 对象是进程级共享的，漏还原会
///      把新选的字体/画刷泄漏到后续绘制，表现为"有些控件字体突然变样"。
///   ② **颜色是 BGR**：`rgb()` 在 win32.dart 里已经调好通道序，别在别处
///      自己 `(r<<16)|(g<<8)|b`。
///   ③ **字体要缓存**：CreateFontW 每个 WM_PAINT 建一次会在拖动窗口时
///      堆积大量 GDI 对象（进程上限 10000，超了直接画不出东西）。
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'win32.dart';

/// 一个矩形区域（逻辑坐标）。
class Rc {
  const Rc(this.left, this.top, this.right, this.bottom);
  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;
  bool get isEmpty => width <= 0 || height <= 0;

  bool contains(int x, int y) =>
      x >= left && x < right && y >= top && y < bottom;

  /// 两个矩形是否相交（用于"这一格还在不在可见区域里"）。
  bool overlaps(Rc o) =>
      left < o.right && o.left < right && top < o.bottom && o.top < bottom;

  /// 交集；不相交时返回 null。
  ///
  /// ★ 用途：**命中区要裁到可见区域**。
  ///   行/单元格是按"整表自然坐标"算的，横向滚动后它们可能有一半在视口外。
  ///   直接拿整格登记命中区，就会在视口外造出一片"看不见但能点"的区域
  ///   （而且点它还会真的打开书）—— 用户会以为"点空白处也会跳转"。
  Rc? intersect(Rc o) {
    final l = left > o.left ? left : o.left;
    final t = top > o.top ? top : o.top;
    final r = right < o.right ? right : o.right;
    final b = bottom < o.bottom ? bottom : o.bottom;
    if (r <= l || b <= t) return null;
    return Rc(l, t, r, b);
  }

  Rc inset(int dx, int dy) =>
      Rc(left + dx, top + dy, right - dx, bottom - dy);

  /// 用 left/top 当宽高构造（布局时更顺手）。
  static Rc xywh(int x, int y, int w, int h) => Rc(x, y, x + w, y + h);

  @override
  String toString() => 'Rc($left,$top,$right,$bottom)';
}

/// 一个 GDI 设备上下文包装。
///
/// 所有绘制都通过它，保证 SelectObject 成对还原。
class Gdi {
  Gdi(this.hdc);

  final int hdc;
  final List<int> _stack = <int>[];

  static Pointer<Utf16> _w(String s) => s.toNativeUtf16();

  // ── 坐标原点 ──

  /// 平移坐标原点。
  ///
  /// ★ 用途：脏区重绘时，把"客户区坐标"整体搬到"被收窄的 BackBuffer"里。
  ///   有了它，`onPaint` 完全不用知道自己在画整窗还是画一小条 ——
  ///   所有绘制代码照旧按客户区坐标写，位移由 GDI 在设备层做掉。
  ///   （另一条路是给每个绘制函数加 offset 参数，那要改几十处签名。）
  ///
  /// 传 (0,0) 复位。必须在用完前复位，否则会影响后续同 DC 的绘制。
  void origin(int dx, int dy) {
    setViewportOrgEx(hdc, dx, dy, nullptr);
  }

  // ── 裁剪 ──

  /// 把后续绘制**真正**限制在 [r] 内，返回一个"退出时恢复裁剪"的收尾器。
  ///
  /// 用法：
  /// ```dart
  /// final done = g.clipTo(inner);
  /// ... 画内容 ...
  /// done();
  /// ```
  ///
  /// 为什么必须有它：滚动区域里"只画视口内的行"那种 `if (y < bottom)` 判断
  /// 只是**起点守卫** —— 挡不住"一行从视口内开始、画到视口外"，
  /// 那半截会压到相邻区域（底栏文字叠在内容上、滚上去的内容浮到卡片外）。
  ///
  /// 用 `SaveDC`/`RestoreDC` 而不是手动再 `IntersectClipRect` 回原区域——
  /// 后者要求调用方自己知道原区域，容易漏；SaveDC 是成对栈，天然安全。
  /// Dart 没有 RAII，所以返回一个函数当收尾器，配合 `try/finally` 用。
  void Function() clipTo(Rc r) {
    final saved = saveDC(hdc);
    intersectClipRect(hdc, r.left, r.top, r.right, r.bottom);
    return () {
      if (saved != 0) restoreDC(hdc, saved);
    };
  }

  // ── 填充 ──

  void fill(Rc r, int color) {
    final brush = createSolidBrush(color);
    final pr = calloc<Rect>()
      ..ref.left = r.left
      ..ref.top = r.top
      ..ref.right = r.right
      ..ref.bottom = r.bottom;
    fillRect(hdc, pr, brush);
    calloc.free(pr);
    deleteObject(brush);
  }

  /// 描边（用画笔画矩形边框，不含填充）。
  void stroke(Rc r, int color, {int width = 1}) {
    final pen = createPen(0, width, color);
    final old = selectObject(hdc, pen);
    final brush = getStockObject(nullBrush);
    final oldBrush = selectObject(hdc, brush);
    rectangle(hdc, r.left, r.top, r.right, r.bottom);
    selectObject(hdc, oldBrush);
    selectObject(hdc, old);
    deleteObject(pen);
  }

  /// 圆角矩形（按钮/卡片底）。
  void roundFill(Rc r, int fillColor, int borderColor, {int radius = 8}) {
    final brush = createSolidBrush(fillColor);
    final pen = createPen(0, 1, borderColor);
    final ob = selectObject(hdc, brush);
    final op = selectObject(hdc, pen);
    roundRect(hdc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
    selectObject(hdc, op);
    selectObject(hdc, ob);
    deleteObject(brush);
    deleteObject(pen);
  }

  void line(int x1, int y1, int x2, int y2, int color, {int width = 1}) {
    final pen = createPen(0, width, color);
    final old = selectObject(hdc, pen);
    moveToEx(hdc, x1, y1, nullptr);
    lineTo(hdc, x2, y2);
    selectObject(hdc, old);
    deleteObject(pen);
  }

  // ── 字体 ──

  /// ★ 字体质量：显式用 **CLEARTYPE_QUALITY(5)**，不要留 DEFAULT_QUALITY(0)。
  ///
  /// `DrawTextW` 走的是 GDI 老路径，默认不保证做亚像素抗锯齿（ClearType）。
  /// DEFAULT_QUALITY 让系统"自己挑"，在部分环境里会退化成灰度抗锯齿 →
  /// 小字号（11px 那档）发虚、字距不匀，观感比实际需要的更"旧"。
  /// 显式声明 CLEARTYPE_QUALITY 是零成本的观感提升（不换栈、不引 COM）。
  static const int _cleartypeQuality = 5;

  /// 取（并缓存）一个字体句柄。[size] 是磅值（会自动转成 GDI 需要的负逻辑高）。
  int font({int size = 14, bool bold = false, String face = 'Microsoft YaHei'}) {
    final key = '$face|$size|${bold ? 1 : 0}';
    final hit = _fontCache[key];
    if (hit != null) return hit;
    final p = _w(face);
    final h = createFontW(
      -size, 0, 0, 0, bold ? 700 : 400,
      0, 0, 0,
      134, // fdwCharSet = GB2312_CHARSET（中文）
      0, // fdwOutputPrecision = OUT_DEFAULT_PRECIS
      0, // fdwClipPrecision = CLIP_DEFAULT_PRECIS
      _cleartypeQuality, // fdwQuality = CLEARTYPE_QUALITY
      0, // fdwPitchAndFamily = DEFAULT_PITCH | FF_DONTCARE
      p,
    );
    calloc.free(p);
    _fontCache[key] = h;
    return h;
  }

  /// 用指定字体画单行文字。[align] 见 [dtLeft]/[dtCenter]/[dtRight]。
  void text(
    String s,
    Rc r,
    int color, {
    int size = 14,
    bool bold = false,
    int align = dtLeft,
    bool vcenter = true,
    bool ellipsis = true,
    String face = 'Microsoft YaHei',
    int padLeft = 0,
  }) {
    if (s.isEmpty) return;
    final f = font(size: size, bold: bold, face: face);
    final old = selectObject(hdc, f);
    setBkMode(hdc, transparent);
    setTextColor(hdc, color);
    final flags = align |
        (vcenter ? dtVcenter : 0) |
        dtSingleLine |
        dtNoPrefix |
        (ellipsis ? dtEndEllipsis : 0);
    final pr = calloc<Rect>()
      ..ref.left = r.left + padLeft
      ..ref.top = r.top
      ..ref.right = r.right
      ..ref.bottom = r.bottom;
    final p = _w(s);
    drawTextW(hdc, p, -1, pr, flags);
    calloc.free(p);
    calloc.free(pr);
    selectObject(hdc, old);
  }

  /// 多行文字（自动换行）。
  void paragraph(
    String s,
    Rc r,
    int color, {
    int size = 14,
    bool bold = false,
    int lineHeight = 0,
  }) {
    if (s.isEmpty) return;
    final f = font(size: size, bold: bold);
    final old = selectObject(hdc, f);
    setBkMode(hdc, transparent);
    setTextColor(hdc, color);
    final pr = calloc<Rect>()
      ..ref.left = r.left
      ..ref.top = r.top
      ..ref.right = r.right
      ..ref.bottom = r.bottom;
    final p = _w(s);
    drawTextW(hdc, p, -1, pr, dtLeft | dtWordBreak | dtNoPrefix);
    calloc.free(p);
    calloc.free(pr);
    selectObject(hdc, old);
  }

  /// 量一段文字的像素宽度（布局要靠它，不能靠字符数估算 —— 中英混排差很多）。
  int measure(String s, {int size = 14, bool bold = false}) {
    final f = font(size: size, bold: bold);
    final old = selectObject(hdc, f);
    final p = _w(s);
    final sz = calloc<Size>();
    getTextExtentPoint32W(hdc, p, s.length, sz);
    final w = sz.ref.cx;
    calloc.free(sz);
    calloc.free(p);
    selectObject(hdc, old);
    return w;
  }

  /// 推入一个 GDI 对象（之后 [pop] 还原）。用于需要连续绘制同色同笔的场景。
  /// 把一段 **BGRA 裸像素**贴到 [dst]（按 dst 尺寸缩放）。
  ///
  /// 像素口径与 `lib/png.dart`、WIC 解码结果一致（BGRA，每像素 4 字节）。
  /// 用 `StretchDIBits` + 负高度 = 自上而下，所以内存里的第一行就是屏幕上的第一行。
  void bgra(Rc dst, Uint8List pixels, int srcW, int srcH) {
    if (dst.isEmpty || srcW <= 0 || srcH <= 0) return;
    if (pixels.length < srcW * srcH * 4) return;
    final bi = calloc<BitmapInfoHeader>();
    try {
      bi.ref
        ..size = 40
        ..width = srcW
        ..height = -srcH // 负 = 自上而下（与我们的内存布局一致）
        ..planes = 1
        ..bitCount = 32
        ..compression = 0; // BI_RGB
      final buf = calloc<Uint8>(pixels.length);
      try {
        buf.asTypedList(pixels.length).setAll(0, pixels);
        stretchDIBits(
            hdc,
            dst.left,
            dst.top,
            dst.width,
            dst.height,
            0,
            0,
            srcW,
            srcH,
            buf,
            bi.cast<Void>(),
            dibRgbColors,
            srcCopy);
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(bi);
    }
  }

  void push(int obj) {
    _stack.add(selectObject(hdc, obj));
  }

  void pop() {
    if (_stack.isEmpty) return;
    selectObject(hdc, _stack.removeLast());
  }

  static final Map<String, int> _fontCache = {};

  /// 缓存过的字体句柄（退出时统一释放）。
  static Iterable<int> get cachedHandles => _fontCache.values;

  static void clearFontCache() => _fontCache.clear();
}

/// 双缓冲：在内存 DC 上画完再一次性 BitBlt 到屏幕。
///
/// 不自绘缓冲的话，窗口拖动/滚动时能看到明显闪烁。
///
/// ★ 必须用 **32 位 DIB 节**（`CreateDIBSection`），不能用
///   `CreateCompatibleBitmap(CreateCompatibleDC(0), …)`。
///   后者在"兼容 DC 的默认位图是 1bpp 单色"的情况下会建出一张**单色**位图，
///   于是整窗只剩纯黑/纯白 —— 表现就是"窗内一片漆黑、字几乎看不见"。
///   这个坑在离屏渲染路径（直接建 DIB）里**完全不会出现**，
///   所以只有真窗口截屏才能复现：一度被误判成"用户屏幕的问题"。
class BackBuffer {
  BackBuffer(this.width, this.height) {
    _hdc = createCompatibleDC(0);
    _bitmap = _create32bppBitmap(_hdc, width, height, _bits);
    _old = selectObject(_hdc, _bitmap);
    gdi = Gdi(_hdc);
  }

  /// 建一张 32 位自顶向下的 DIB 节，并回填像素指针。
  static int _create32bppBitmap(
      int hdc, int w, int h, List<Pointer<Void>> bitsOut) {
    final ww = w < 1 ? 1 : w;
    final hh = h < 1 ? 1 : h;
    final bi = calloc<BitmapInfoHeader>();
    bi.ref
      ..size = 40
      ..width = ww
      ..height = -hh // 负 = 自上而下
      ..planes = 1
      ..bitCount = 32
      ..compression = 0;
    final ppv = calloc<Pointer<Void>>();
    final hbmp = createDIBSection(hdc, bi, 0, ppv, 0, 0);
    bitsOut
      ..clear()
      ..add(ppv.value);
    calloc.free(bi);
    calloc.free(ppv);
    return hbmp;
  }

  final int width;
  final int height;
  late final int _hdc;
  late final int _bitmap;
  late final int _old;
  late final Gdi gdi;

  /// 像素首地址（BGRA，自上而下）。给"真窗口截屏"校验用。
  final List<Pointer<Void>> _bits = [];
  Pointer<Void> get bits => _bits.isEmpty ? nullptr : _bits.first;

  /// 把这块缓冲直接读成 BGRA 字节（不经过屏幕，验证绘制结果用）。
  Uint8List readBgra() {
    final n = width * height * 4;
    final out = Uint8List(n);
    final p = bits.cast<Uint8>();
    if (p.address != 0) {
      for (var i = 0; i < n; i++) {
        out[i] = p[i];
      }
    }
    return out;
  }

  /// 贴到目标 DC。
  ///
  /// [x]/[y] 是目标位置 —— 脏区重绘时缓冲只覆盖脏区那一块，
  /// 必须贴回它在客户区里的真实位置，否则内容会跑到左上角。
  void presentTo(Gdi target, {int x = 0, int y = 0}) {
    bitBlt(target.hdc, x, y, width, height, _hdc, 0, 0, srccopy);
  }

  void dispose() {
    selectObject(_hdc, _old);
    deleteObject(_bitmap);
    deleteDC(_hdc);
  }
}

/// 释放字体缓存（退出时调用，避免 GDI 对象计数告警）。
void disposeFontCache() {
  for (final h in Gdi.cachedHandles.toList()) {
    deleteObject(h);
  }
  Gdi.clearFontCache();
}

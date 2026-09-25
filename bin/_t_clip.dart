/// 裁剪回归自检 —— 证明 `Gdi.clipTo()` 真的把绘制**限制**在矩形内。
///
/// 覆盖第 7 轮修的三个 bug 里"同源"的两个（B 莫名空白 / C 字体重叠）：
///   - 无裁剪时，"一行从视口内开始、画到视口外"那半截会压到相邻区域；
///     滚上去的内容会浮到卡片外 —— 前者=字体重叠，后者=莫名空白。
///   - `if (y < bottom)` 这类判断只是**起点守卫**，挡不住上面两种情况。
///
/// 断言方式：在离屏 BackBuffer 上，
///   ① 裁剪内画一个**超出裁剪区**的矩形 → 裁剪外像素必须**不变**；
///   ② 裁剪内区域的像素必须**真的变了**；
///   ③ 裁剪撤销后，再画同样的矩形 → 裁剪外像素**应当**变了（证明恢复生效）。
/// 这是硬像素级断言，不依赖视觉。
///
/// 运行：dart run bin/_t_clip.dart
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../lib/png.dart';
import '../lib/ui/dialogs.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/win32.dart' show rgb;

int _pass = 0;
int _fail = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✅ $name');
  } else {
    _fail++;
    stdout.writeln('  ❌ $name${detail == null ? '' : ' — $detail'}');
  }
}

/// 直接读 BackBuffer 的位图像素（BGRA，32bpp 自上而下，stride = width*4）。
/// 每次调用都重新 readBgra() —— 简单、够用（测试图很小）。
///
/// 返回值**故意**与 `win32.dart` 的 `rgb()` 同构：`(b<<16)|(g<<8)|r`
/// （GDI COLORREF 是 BGR 打包）。这样测试里的颜色常量可以直接写 `rgb(...)`，
/// 不会踩"以为 0xFF0000 是红、实际是蓝"的坑。
int _px(BackBuffer buf, int x, int y) {
  final bgra = buf.readBgra();
  final off = (y * buf.width + x) * 4;
  final b = bgra[off];
  final g = bgra[off + 1];
  final r = bgra[off + 2];
  return (b << 16) | (g << 8) | r;
}

void main() {
  stdout.writeln('== 裁剪回归（Gdi.clipTo 真裁剪验证）==');

  final buf = BackBuffer(200, 120);
  try {
    final g = buf.gdi;

    // 底色白，裁剪区内画红 —— 一律用 rgb() 构造，避免 BGRA/BGR 手工打包出错。
    final white = rgb(255, 255, 255);
    final red = rgb(255, 0, 0);
    final green = rgb(0, 255, 0);
    final blue = rgb(0, 0, 255);
    g.fill(Rc.xywh(0, 0, 200, 120), white);

    // 裁剪区：x 50..100, y 30..70
    final clip = Rc.xywh(50, 30, 50, 40);

    // ② 裁剪内区域必须真的被画到
    final end = g.clipTo(clip);
    // 故意画一个**远超裁剪区**的矩形（涵盖整屏）—— 模拟"一行画到视口外"。
    g.fill(Rc.xywh(0, 0, 200, 120), red);
    end();

    // ① 裁剪区内的点 → 红
    _check('裁剪区内 (75,50) 被画成红', _px(buf, 75, 50) == red,
        'got=0x${_px(buf, 75, 50).toRadixString(16)}');
    // ① 裁剪区外的点 → 仍是白（没被越界绘制污染）
    _check('裁剪区左外 (20,50) 保持白（未越界）', _px(buf, 20, 50) == white,
        'got=0x${_px(buf, 20, 50).toRadixString(16)}');
    _check('裁剪区右外 (150,50) 保持白（未越界）', _px(buf, 150, 50) == white,
        'got=0x${_px(buf, 150, 50).toRadixString(16)}');
    _check('裁剪区上外 (75,10) 保持白（未越界）', _px(buf, 75, 10) == white,
        'got=0x${_px(buf, 75, 10).toRadixString(16)}');
    _check('裁剪区下外 (75,100) 保持白（未越界）', _px(buf, 75, 100) == white,
        'got=0x${_px(buf, 75, 100).toRadixString(16)}');

    // 边界像素：裁剪区左缘内侧 1px 应是红，左缘外侧 1px 应是白
    _check('裁剪左缘内侧 (50,50) 为红', _px(buf, 50, 50) == red);
    _check('裁剪左缘外侧 (49,50) 为白', _px(buf, 49, 50) == white);

    // ③ 裁剪撤销后，同样画满屏 → 裁剪区外**应当**变红
    final end2 = g.clipTo(clip);
    g.fill(Rc.xywh(50, 30, 50, 40), green); // 只改裁剪内为绿
    end2();
    g.fill(Rc.xywh(0, 0, 200, 120), blue); // 撤裁后画满屏蓝
    _check('撤销裁剪后 (20,50) 变蓝（证明 RestoreDC 生效）',
        _px(buf, 20, 50) == blue,
        'got=0x${_px(buf, 20, 50).toRadixString(16)}');

    // ④ 嵌套裁剪：内层是外层的子集 → 内层更紧。
    g.fill(Rc.xywh(0, 0, 200, 120), white);
    final outEnd = g.clipTo(Rc.xywh(0, 0, 100, 100));
    final inEnd = g.clipTo(Rc.xywh(0, 0, 50, 50)); // 与外层求交 → 0..50
    g.fill(Rc.xywh(0, 0, 200, 120), red);
    inEnd();
    outEnd();
    _check('嵌套裁剪内层交集 (25,25) 为红', _px(buf, 25, 25) == red);
    _check('嵌套裁剪外层内/内层外 (75,75) 保持白', _px(buf, 75, 75) == white);
  } finally {
    buf.dispose();
  }

  _checkDialogFooterNoOverlap();

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

/// 端到端：扫榜设置窗滚到底时，**最后一行不能进入底栏条带**。
///
/// 这是问题 C（字体重叠）的端到端复现 + 断言：
///   底栏文本区 = 卡片底缘以下；裁剪生效后，卡片内不可能画到那里。
/// 做法：滚到最大，渲染一帧，取底栏条带中央行的像素 —— 它必须**纯是底栏背景**
///   （Palette.surface 之外不该出现勾选框描边色 / 行底色）。
void _checkDialogFooterNoOverlap() {
  final owner = MainWindow(outRoot: 'out');
  final dlg = ScanDialogWindow(owner: owner);
  const w = 1040, h = 720;
  dlg.testSetSize(w, h);
  dlg.onPaint(Gdi(0)); // 建布局
  final maxY = dlg.testMaxScroll();
  dlg.testSetScroll(maxY);
  final buf = BackBuffer(w, h);
  try {
    dlg.onPaint(buf.gdi);
    final inner = dlg.testInnerRect();
    // 卡片底缘（inner.bottom）以下、footer 文字所在行 = 底栏条带。
    final footY = inner.bottom + (34 * Metrics.factor).round() ~/ 2;
    final y = footY < h ? footY : h - 5;
    // 抽样整行：底栏区不该出现"勾选框边框色" Palette.lineStrong/line
    // 的连续水平线段（那意味着内容画进来了）。
    var lineStrongCount = 0;
    final bgra = buf.readBgra();
    for (var x = inner.left; x < inner.right; x++) {
      final o = (y * w + x) * 4;
      final b = bgra[o], g = bgra[o + 1], r = bgra[o + 2];
      // Palette.lineStrong = rgb(55,62,77) / line = rgb(38,43,54)：勾选框描边色。
      final isLine = ((r - 55).abs() < 5 && (g - 62).abs() < 5 && (b - 77).abs() < 5) ||
          ((r - 38).abs() < 4 && (g - 43).abs() < 4 && (b - 54).abs() < 4);
      if (isLine) lineStrongCount++;
    }
    // 底栏里出现大量勾选框描边像素 = 内容没被裁掉（压进底栏）。
    _check('设置窗 滚到底时底栏条带无勾选框描边（不重叠）y=$y',
        lineStrongCount < 20, '描边像素=$lineStrongCount');
  } finally {
    buf.dispose();
  }
}

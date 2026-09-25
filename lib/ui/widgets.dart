/// 自绘控件库 —— 按钮 / 复选框 / 下拉框 / 标签页 / 表格 / 滚动条。
///
/// 设计约定：
///   ① 每个控件有**唯一整数 id**，命中测试靠 id 回传，不用坐标魔法数；
///   ② 绘制函数是纯函数（不读全局状态），状态由调用方传入；
///   ③ 所有控件尺寸都过 [Gdi.measure] 实测，不用"字符数 × 常数"估算
///      （中英混排在估算下会错位，这是自绘 UI 最常见的丑）；
///   ④ **所有度量读 [Metrics]，不写死数字** —— 这样窗口变大时
///      字号/行高/圆角会整套跟着放大，视觉密度保持一致。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'gdi.dart';
import 'theme.dart';
import 'win32.dart';

/// 控件的交互状态。
class CtlState {
  const CtlState({
    this.hot = false,
    this.pressed = false,
    this.enabled = true,
    this.active = false,
  });
  final bool hot;
  final bool pressed;
  final bool enabled;

  /// 选中/激活（用于标签页、下拉项这类"当前项"）。
  final bool active;
}

// ───────────────────────── 按钮 ─────────────────────────

/// 按钮风格。primary 用于主操作（开始扫榜），ghost 用于次要操作。
enum BtnKind { primary, normal, ghost, danger }

/// 画一个现代风格按钮。
///
/// 现代感来自四件事（都不是花哨效果，是"少即是多"）：
///   - 圆角偏大（[Metrics.radiusSmall]，随缩放变大）
///   - 描边很淡、只在 hover 时亮起来；primary 干脆无描边
///   - 底色用 4 档明度递进，而不是"灰底+黑边"
///   - 文字居中、字重区分（primary 用 bold）
void drawButton(
  Gdi g,
  Rc r, {
  required String label,
  required BtnKind kind,
  required CtlState st,
  int? fontSize,
}) {
  final fs = fontSize ?? Metrics.fontSize;
  int fill, border, fg;
  if (!st.enabled) {
    fill = Palette.surfaceAlt;
    border = Palette.line;
    fg = Palette.fgFaint;
  } else {
    switch (kind) {
      case BtnKind.primary:
        fill = (st.pressed || st.hot) ? Palette.accentHover : Palette.accent;
        border = fill; // primary 无描边，纯色块
        fg = Palette.bg;
      case BtnKind.danger:
        fill = st.hot ? Palette.dangerHover : Palette.bad;
        border = fill;
        fg = Palette.bg;
      case BtnKind.ghost:
        // ghost 平时几乎"看不见"（只有淡描边），hover 才浮出来
        fill = st.hot ? Palette.surfaceHigh : Palette.surface;
        border = st.hot ? Palette.lineStrong : Palette.line;
        fg = st.hot ? Palette.fg : Palette.fgSub;
      case BtnKind.normal:
        fill = st.pressed
            ? Palette.surfaceAlt
            : (st.hot ? Palette.surfaceHigh : Palette.surface);
        border = st.hot ? Palette.accent : Palette.lineStrong;
        fg = st.hot ? Palette.accent : Palette.fg;
    }
  }
  g.roundFill(r, fill, border, radius: Metrics.radiusSmall);
  g.text(label, r, fg,
      size: fs, align: dtCenter, bold: kind == BtnKind.primary);
}

// ───────────────────── 自绘窗口按钮（最小化/最大化/关闭）─────────────────────

/// 自绘标题栏上的窗口按钮种类。
enum WinBtnKind { minimize, maximize, restore, close }

/// 窗口按钮的控件 id。
///
/// ★ 放在库级而不是 [MainWindow] 里：主窗和设置窗都要用，
///   而它们是**跨类引用** —— 把常量挂在 `MainWindow` 上，
///   `ScanDialogWindow` 里写 `const [MainWindow.idWinClose]` 会报
///   "Not a constant expression"（跨类静态常量在 const 上下文里不算常量）。
///
/// 取值避开：主窗业务控件 100-104 / 表格 200-202 / 标签页 300 /
/// 下拉 400 / 平台 chip 500-599+i / 侧栏 1000+i / 对话框 900-904。
/// 用 700 段，谁都不会撞。
const int idWinMinimize = 700;
const int idWinMaximize = 701;
const int idWinClose = 702;

/// 画一个窗口按钮，并返回它的矩形（供调用方登记命中区）。
///
/// ★ 图标**全部用线段/方框矢量画**，不用字体字符。
///   原因：`\uE921`（Segoe MDL2 的最小化字形）在非英文系统、
///   或者字体被换掉时是**方框**——而窗口按钮画成方框比"丑"严重得多，
///   用户会以为程序坏了。三根线一画就没有这个风险。
///
/// ★ 关闭按钮 hover 用 Windows 标准红 `#E81123`，这是用户肌肉记忆，
///   改成主色青反而让人在"想关窗"的时候犹豫半秒。
Rc drawWinButton(
  Gdi g,
  int x,
  int y, {
  required WinBtnKind kind,
  required bool hot,
  required bool pressed,
  required bool windowActive,
}) {
  final w = Metrics.winBtnW;
  final h = Metrics.winBtnH;
  final r = Rc.xywh(x, y, w, h);

  final isClose = kind == WinBtnKind.close;
  int bg;
  if (isClose) {
    bg = (hot || pressed) ? (pressed ? Palette.closeActive : Palette.closeHover) : 0;
  } else {
    bg = pressed
        ? Palette.winBtnActive
        : (hot ? Palette.winBtnHover : 0);
  }
  // 0 = "不填充"：Gdi.fill 把 0 当透明会误画成黑块，
  // 所以无底色时干脆不调 fill —— 让标题栏底色透出来。
  if (bg != 0) {
    g.fill(r, bg);
  }

  // ★ 关闭按钮的叉**平时不能是白的**。
  //   原来是 `isClose ? Palette.closeGlyph(白)` 恒成立 —— 深色顶栏上看不出问题，
  //   但浅色主题的顶栏本身就是白的，白叉画在白底上等于**按钮消失**
  //   （实测：浅色下关闭按钮的墨迹像素数 = 0）。
  //   正确做法：只有 hover/按下（那时底色是 Windows 标准红）才用白叉，
  //   平时和其它两个按钮用同一个前景色。
  final glyph = (hot || pressed)
      ? (isClose ? Palette.closeGlyph : Palette.winBtnGlyphHot)
      : (windowActive ? Palette.winBtnGlyph : Palette.fgInactive);

  // 图标边长 10px（@100%）—— Windows 原生就是 10px，这个尺寸最"对"。
  final s = (10 * Metrics.factor).round().clamp(8, 16);
  final cx = x + w ~/ 2;
  final cy = y + h ~/ 2;
  final l = cx - s ~/ 2;
  final t = cy - s ~/ 2;
  final rr = l + s;
  final bb = t + s;
  final stroke = (1.4 * Metrics.factor).round().clamp(1, 3);

  switch (kind) {
    case WinBtnKind.minimize:
      // ★ 横线画在**图标框的垂直中线**上，与最大化/还原的方框共用一个光心。
      //   原来画在 `cy + s/2`（图标框下沿），实测比另两个图标低 5px ——
      //   三个按钮并排时一眼就能看出"最小化的那条线掉下去了"。
      //   一根没有高度的线，视觉光心就是它的所在行，所以取几何中线即可。
      g.line(l, cy, rr, cy, glyph, width: stroke);
    case WinBtnKind.maximize:
      // 空心方框：原生最大化图标是 1px 边框的方块。
      g.line(l, t, rr, t, glyph, width: stroke);
      g.line(rr, t, rr, bb, glyph, width: stroke);
      g.line(rr, bb, l, bb, glyph, width: stroke);
      g.line(l, bb, l, t, glyph, width: stroke);
    case WinBtnKind.restore:
      // 还原：两个错开叠放的方框（前框实线、后框两段折角）。
      final o = (3 * Metrics.factor).round().clamp(2, 5);
      final l2 = l + o, t2 = t + o;
      // 后框只画上、右两段（其余被前框遮住）
      g.line(l2, t, l2, t2, glyph, width: stroke);
      g.line(l2, t, rr, t, glyph, width: stroke);
      g.line(rr, t, rr, bb, glyph, width: stroke);
      // 前框
      g.line(l, t2, rr - o, t2, glyph, width: stroke);
      g.line(rr - o, t2, rr - o, bb, glyph, width: stroke);
      g.line(rr - o, bb, l, bb, glyph, width: stroke);
      g.line(l, bb, l, t2, glyph, width: stroke);
    case WinBtnKind.close:
      // X 用两条对角线画，比字体字形更锐利。
      g.line(l, t, rr, bb, glyph, width: stroke);
      g.line(rr, t, l, bb, glyph, width: stroke);
  }
  return r;
}

// ───────────────────────── 矢量小图标 ─────────────────────────

/// 折叠箭头（chevron）。收起 = 朝右，展开 = 朝下。
///
/// 抽成公共控件是为了**两处一致**：侧栏的平台分组和设置窗的树节点
/// 用同一个箭头，用户在两处学到的是同一个语汇。
/// （全部用线段画，不依赖字体里有没有 ▸ / ▾ —— 那两个字形在
/// 非英文系统或字体被替换时会变成方框。）
void drawChevron(Gdi g, int cx, int cy,
    {required bool expanded, required int color, double scale = 1.0}) {
  final arm = ((4 * Metrics.factor) * scale).round().clamp(3, 9);
  final lw = (1.6 * Metrics.factor).round().clamp(1, 3);
  if (expanded) {
    g.line(cx - arm, cy - arm ~/ 2, cx, cy + arm ~/ 2, color, width: lw);
    g.line(cx, cy + arm ~/ 2, cx + arm, cy - arm ~/ 2, color, width: lw);
  } else {
    g.line(cx - arm ~/ 2, cy - arm, cx + arm ~/ 2, cy, color, width: lw);
    g.line(cx + arm ~/ 2, cy, cx - arm ~/ 2, cy + arm, color, width: lw);
  }
}

/// 放大镜图标（搜索框用）。同样是矢量画。
void drawSearchGlyph(Gdi g, int cx, int cy, int color, {double scale = 1.0}) {
  final rad = ((4.5 * Metrics.factor) * scale).round().clamp(3, 10);
  final lw = (1.5 * Metrics.factor).round().clamp(1, 3);
  const segs = 10;
  for (var i = 0; i < segs; i++) {
    final a1 = -0.9 + i * (5.0 / segs);
    final a2 = -0.9 + (i + 1) * (5.0 / segs);
    g.line((cx + rad * _cosT(a1)).round(), (cy + rad * _sinT(a1)).round(),
        (cx + rad * _cosT(a2)).round(), (cy + rad * _sinT(a2)).round(), color,
        width: lw);
  }
  final d = (rad * 0.75).round();
  g.line(cx + d, cy + d, cx + d + (rad ~/ 2), cy + d + (rad ~/ 2), color,
      width: lw);
}

/// 斜杠圆圈（"隐藏"按钮用）。
void drawSlashCircle(Gdi g, int cx, int cy, int color, {double scale = 1.0}) {
  final rad = ((5 * Metrics.factor) * scale).round().clamp(4, 9);
  final lw = (1.5 * Metrics.factor).round().clamp(1, 3);
  const segs = 10;
  for (var i = 0; i < segs; i++) {
    final a1 = i * 6.2831853 / segs;
    final a2 = (i + 1) * 6.2831853 / segs;
    g.line((cx + rad * _cosT(a1)).round(), (cy + rad * _sinT(a1)).round(),
        (cx + rad * _cosT(a2)).round(), (cy + rad * _sinT(a2)).round(), color,
        width: lw);
  }
  final d = (rad * 0.72).round();
  g.line(cx - d, cy + d, cx + d, cy - d, color, width: lw);
}

// 圆/斜杠只要几条线段，为它 import 'dart:math' 不划算 —— 泰勒展开足够准
// （归一到 [-π, π] 后展开到 6 阶，误差 < 1e-3，画出来看不出差别）。
double _cosT(double a) => _taylorCos(a);
double _sinT(double a) => _taylorCos(a - 1.5707963267948966);

double _taylorCos(double x) {
  const pi = 3.1415926535897932;
  while (x > pi) {
    x -= 2 * pi;
  }
  while (x < -pi) {
    x += 2 * pi;
  }
  final x2 = x * x;
  return 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720;
}

// ───────────────────────── 复选框 ─────────────────────────
//
// ★ 第 9 轮**整体删除**（`checkBoxSize` / `drawCheckbox` / `drawCheckboxRow` /
//   `drawTriStateCheckbox` 四个）。
//
//   原因不是"没地方用了"，而是用户明确要求"不能用方框勾选"：
//   扫榜设置的选中语义改成了**整行变蓝框**（与侧栏选中项同一套语汇）。
//   把复选框控件留在库里，下一个人做列表时顺手又会用它，
//   于是同一个界面里出现两种"选中"表达 —— 那正是要消灭的东西。
//   真需要复选框时，从 git 历史里取回来即可（本文件一直有完整注释）。

// ───────────────────────── 本数步进器 ─────────────────────────

/// 步进器总宽（随缩放）。布局与命中定位都用它，避免两处算不一致。
int get stepperWidth => (108 * Metrics.factor).round();
int get stepperHeight => (22 * Metrics.factor).round();

/// "− 20 本 +" 步进器。返回 (减按钮矩形, 值区矩形, 加按钮矩形)。
///
/// [enabled]=false 时整组灰显且不登记命中（未勾选的榜不该能改本数）——
/// 这是"可读但不可点"的正确表达，比藏起来更让人明白"勾上才能设"。
///
/// ★ [unit] 是为了去掉两处"先画'本'再拿底色盖掉"的补丁：
///   保留份数量词是"份/不限"、数据管理里也是"份"，原来调用方得自己
///   覆盖重画。量词参数化之后，公共控件就不用再被绕着改。
///
/// ★ [editing] / [editText]：值区可以**直接输入任意数字**（见 `onChar`）。
///   不是只有预设档位可选 —— 用户原话"本数要可以任意修改，不是只有几个选择"。
(Rc, Rc, Rc) drawStepper(
  Gdi g,
  int x,
  int y, {
  required int value,
  required bool enabled,
  required bool hotMinus,
  required bool hotPlus,
  int cap = 500,
  String unit = '本',
  bool editing = false,
  String? editText,
  bool valueHot = false,
}) {
  final u = Metrics.factor;
  final w = stepperWidth;
  final h = stepperHeight;
  final btnW = h; // 方形按钮
  final full = Rc.xywh(x, y, w, h);
  final minus = Rc.xywh(x, y, btnW, h);
  final plus = Rc.xywh(x + w - btnW, y, btnW, h);
  final valBox = Rc.xywh(x + btnW, y, w - btnW * 2, h);

  final line = enabled ? Palette.lineStrong : Palette.line;
  final txt = enabled ? Palette.fg : Palette.fgFaint;
  // 外框
  g.roundFill(full, Palette.surfaceAlt, line, radius: (5 * u).round());
  // 中间值区（比两侧略深，读起来像"可编辑的显示位"）
  g.fill(valBox, enabled ? Palette.surface : Palette.surfaceAlt);
  if (editing) {
    // 编辑态：值区描一圈主色，一眼看出"这里在等你打字"
    g.roundFill(valBox, Palette.surface, Palette.accent,
        radius: (4 * u).round());
  } else if (valueHot && enabled) {
    // 悬停：给一条主色下划线，暗示"点这里能输入"
    g.roundFill(valBox, Palette.hover, Palette.hover, radius: (4 * u).round());
    g.fill(Rc.xywh(valBox.left + (3 * u).round(), valBox.bottom - (2 * u).round(),
            valBox.width - (6 * u).round(), (1.5 * u).round().clamp(1, 2)),
        Palette.accent);
  }

  void seg(Rc r, String glyph, bool hot, bool on) {
    if (!on) return;
    if (hot) {
      g.roundFill(r, Palette.hover, Palette.hover, radius: (4 * u).round());
    }
    // 用矢量线画 ± —— 不依赖字体里有没有 U+2212
    final cx = r.left + r.width ~/ 2;
    final cy = r.top + r.height ~/ 2;
    final arm = (4 * u).round().clamp(3, 7);
    final lw = (1.4 * u).round().clamp(1, 3);
    g.line(cx - arm, cy, cx + arm, cy, txt, width: lw);
    if (glyph == '+') g.line(cx, cy - arm, cx, cy + arm, txt, width: lw);
  }

  seg(minus, '-', hotMinus, true);
  seg(plus, '+', hotPlus, true);

  // 数值 + 量词
  // ★ 排版铁律：先算出"整块"宽度 need，按 need 居中；两个框用**同一个 gap** 切分，
  //   框宽**正好等于实测文字宽**。
  //   旧写法有两个坑：① `tw + 4` 给数字框多撑了 4px；② 第二框只隔 2px。
  //   实测 valBox 宽 64、tw=14、uw=11 → "30" 框 [40,58]、"本" 框 [56,71]，
  //   **重叠 2px**，GDI 各自画自己的，看上去就是"3 0 本"错位。
  final label = editing ? (editText ?? '$value') : '$value';
  final showUnit = !editing || (editText ?? '').isEmpty;
  final tw = g.measure(label, size: Metrics.fontSizeTiny, bold: true);
  final uw = showUnit ? g.measure(unit, size: Metrics.fontSizeTiny) : 0;
  final gap = showUnit ? (5 * u).round().clamp(3, 8) : 0;
  final need = tw + gap + uw;
  final startX = valBox.left + ((valBox.width - need) ~/ 2).clamp(0, valBox.width);
  g.text(label, Rc.xywh(startX, valBox.top, tw, valBox.height),
      editing ? Palette.accent : txt,
      size: Metrics.fontSizeTiny, bold: true);
  if (showUnit) {
    g.text(unit, Rc.xywh(startX + tw + gap, valBox.top, uw, valBox.height),
        enabled ? Palette.fgDim : Palette.fgFaint, size: Metrics.fontSizeTiny);
  }
  if (editing) {
    // 光标
    final cx = startX + tw + (1 * u).round();
    if (cx < valBox.right - (2 * u).round()) {
      g.fill(
          Rc.xywh(cx, valBox.top + (3 * u).round(),
              (1.5 * u).round().clamp(1, 2), valBox.height - (6 * u).round()),
          Palette.accent);
    }
  }

  return (minus, valBox, plus);
}

// ───────────── 行内紧凑步进器（每个榜一行一个）─────────────

/// 行内步进器尺寸。
int get rowStepperW => (112 * Metrics.factor).round();
int get rowStepperH => (24 * Metrics.factor).round();

/// 紧凑步进器 —— 给"列表里每一行都有自己的本数"用。
///
/// ★ 与 [drawStepper] 的分工：那个是**面板级**控件（有常驻外框和底色），
///   一屏只会出现一两个；这个一屏可能有 40 个，画外框会变成一片栅格。
///   所以默认**无底色**，只有"悬停 / 这一行被选中 / 正在编辑"时才浮出来 ——
///   既能一眼看到本数，又不会把列表糊成表格。
(Rc, Rc, Rc) drawRowStepper(
  Gdi g,
  int x,
  int y, {
  required int value,
  required bool emphasized,
  required bool hotMinus,
  required bool hotPlus,
  required bool hotValue,
  bool editing = false,
  String? editText,
  String unit = '本',
}) {
  final u = Metrics.factor;
  final w = rowStepperW;
  final h = rowStepperH;
  final btnW = h;
  final full = Rc.xywh(x, y, w, h);
  final minus = Rc.xywh(x, y, btnW, h);
  final plus = Rc.xywh(x + w - btnW, y, btnW, h);
  final valBox = Rc.xywh(x + btnW, y, w - btnW * 2, h);

  final lit = emphasized || editing || hotMinus || hotPlus || hotValue;
  if (lit) {
    g.roundFill(full, Palette.surface, editing ? Palette.accent : Palette.line,
        radius: (5 * u).round());
  }

  void seg(Rc r, String glyph, bool hot) {
    if (hot) {
      g.roundFill(r, Palette.hover, Palette.hover, radius: (4 * u).round());
    }
    final cx = r.left + r.width ~/ 2;
    final cy = r.top + r.height ~/ 2;
    final arm = (3.5 * u).round().clamp(3, 6);
    final lw = (1.4 * u).round().clamp(1, 3);
    final col = hot ? Palette.accent : Palette.fgSub;
    g.line(cx - arm, cy, cx + arm, cy, col, width: lw);
    if (glyph == '+') g.line(cx, cy - arm, cx, cy + arm, col, width: lw);
  }

  seg(minus, '-', hotMinus);
  seg(plus, '+', hotPlus);

  final label = editing ? (editText ?? '$value') : '$value';
  final showUnit = !editing || (editText ?? '').isEmpty;
  final tw = g.measure(label, size: Metrics.fontSizeTiny, bold: true);
  final uw = showUnit ? g.measure(unit, size: Metrics.fontSizeTiny) : 0;
  final gap = showUnit ? (4 * u).round().clamp(3, 6) : 0;
  final need = tw + gap + uw;
  final startX = valBox.left + ((valBox.width - need) ~/ 2).clamp(0, valBox.width);
  g.text(label, Rc.xywh(startX, valBox.top, tw, valBox.height),
      editing ? Palette.accent : (emphasized ? Palette.fg : Palette.fgSub),
      size: Metrics.fontSizeTiny, bold: true);
  if (showUnit) {
    g.text(unit, Rc.xywh(startX + tw + gap, valBox.top, uw, valBox.height),
        Palette.fgFaint, size: Metrics.fontSizeTiny);
  }
  if (editing) {
    final cx = startX + tw + (1 * u).round();
    if (cx < valBox.right - (2 * u).round()) {
      g.fill(
          Rc.xywh(cx, valBox.top + (3 * u).round(),
              (1.5 * u).round().clamp(1, 2), valBox.height - (6 * u).round()),
          Palette.accent);
    }
  } else if (hotValue) {
    // 悬停时给一条下划线，暗示"点这里能直接输入"
    g.fill(Rc.xywh(valBox.left + (2 * u).round(), valBox.bottom - (2 * u).round(),
            valBox.width - (4 * u).round(), (1.5 * u).round().clamp(1, 2)),
        Palette.accent);
  }

  return (minus, valBox, plus);
}

// ───────────────────────── 下拉框 ─────────────────────────

void drawDropdown(
  Gdi g,
  Rc r, {
  required String value,
  required bool open,
  required CtlState st,
  bool placeholder = false,
}) {
  g.roundFill(
    r,
    st.hot || open ? Palette.surfaceHigh : Palette.surface,
    open ? Palette.accent : (st.hot ? Palette.lineStrong : Palette.line),
    radius: Metrics.radiusSmall,
  );
  final pad = (10 * Metrics.factor).round();
  g.text(value, r, placeholder ? Palette.fgFaint : Palette.fg,
      size: Metrics.fontSize, padLeft: pad);

  // 右侧箭头：两条线画的 chevron，比字符更可控
  final u = Metrics.factor;
  final ax = r.right - (16 * u).round();
  final ay = r.top + r.height ~/ 2;
  final col = st.enabled ? Palette.fgDim : Palette.fgFaint;
  final lw = (1.6 * u).round().clamp(1, 3);
  g.line((ax - 4 * u).round(), (ay - 2 * u).round(), ax, (ay + 2 * u).round(),
      col, width: lw);
  g.line(ax, (ay + 2 * u).round(), (ax + 4 * u).round(), (ay - 2 * u).round(),
      col, width: lw);
}

/// 下拉展开后的浮层。点中返回**绝对**索引，点外面返回 -1，浮层内空白返回 -2。
///
/// ★ 超过 [maxVisible] 时不再"截断丢弃"（以前第 13 项之后既画不出也点不到，
///   用户永远选不到历史更早的基准）。改为**窗口化**：以 [selectedIndex] 为中心
///   取一段可见区间，选中的那一项必然在窗口内，从而整份列表都能选到。
int drawDropdownMenu(
  Gdi g,
  Rc anchor,
  List<String> items, {
  required int selectedIndex,
  required int mouseX,
  required int mouseY,
  int maxVisible = 12,
}) {
  final itemH = (30 * Metrics.factor).round();
  final n = items.length;
  final visible = n > maxVisible ? maxVisible : n;
  final pad = (6 * Metrics.factor).round();
  final h = visible * itemH + pad * 2;

  // 窗口起点：让 selectedIndex 尽量居中露出。
  var start = 0;
  if (n > visible) {
    start = selectedIndex - visible ~/ 2;
    start = start.clamp(0, n - visible);
  }

  var top = anchor.bottom + (3 * Metrics.factor).round();
  final box = Rc.xywh(
      anchor.left,
      top,
      anchor.width < (140 * Metrics.factor).round()
          ? (140 * Metrics.factor).round()
          : anchor.width,
      h);

  // 浮层投影：深色主题下垫一层**更深**的色，不能垫浅灰（会形成发光白边）。
  final off = (3 * Metrics.factor).round();
  g.roundFill(Rc.xywh(box.left + 2, box.top + off, box.width, box.height),
      Palette.shadow, Palette.shadow, radius: Metrics.radius);
  g.roundFill(box, Palette.surfaceAlt, Palette.lineStrong, radius: Metrics.radius);

  var hit = -1;
  final ipad = (4 * Metrics.factor).round();
  for (var i = 0; i < visible; i++) {
    final abs = start + i;
    final ir = Rc.xywh(
        box.left + ipad, box.top + pad + i * itemH, box.width - ipad * 2, itemH);
    final hot = ir.contains(mouseX, mouseY);
    if (hot) hit = abs;
    if (abs == selectedIndex) {
      g.roundFill(ir, Palette.selected, Palette.selected, radius: Metrics.radiusSmall);
      g.text(items[abs], ir, Palette.accent,
          size: Metrics.fontSize, padLeft: (10 * Metrics.factor).round());
    } else {
      if (hot) g.roundFill(ir, Palette.hover, Palette.hover, radius: Metrics.radiusSmall);
      g.text(items[abs], ir, Palette.fg,
          size: Metrics.fontSize, padLeft: (10 * Metrics.factor).round());
    }
  }
  // 上下还有更多时，在浮层右上角标一个很淡的计数，告诉用户列表没画完。
  final below = n - (start + visible);
  if (start > 0 || below > 0) {
    final tag = StringBuffer();
    if (start > 0) tag.write('↑$start ');
    if (below > 0) tag.write('↓$below');
    g.text(tag.toString().trim(),
        Rc.xywh(box.right - (56 * Metrics.factor).round(), box.top,
            (50 * Metrics.factor).round(), pad),
        Palette.fgFaint,
        size: Metrics.fontSize, align: dtRight, ellipsis: false);
  }
  return box.contains(mouseX, mouseY) ? hit : -2;
}

// ───────────────────── 带分组标题的下拉菜单 ─────────────────────

/// 菜单里的一组。`title` 为空 = 不画分组标题。
class MenuSection {
  const MenuSection(this.title, this.items);
  final String title;
  final List<String> items;
}

/// 分组菜单的排版结果。
class SectionedMenuLayout {
  SectionedMenuLayout(this.box, this.headers, this.items);
  final Rc box;

  /// 每个分组标题的矩形（`title` 为空的组没有条目）。
  final List<Rc> headers;

  /// 每一项：`(组下标, 项下标, 矩形)`。
  final List<(int, int, Rc)> items;
}

/// 分组菜单的排版。**绘制与命中登记共用这一份** ——
/// 两处各算一遍是自绘 UI 最容易漂移的地方。
SectionedMenuLayout layoutSectionedMenu(
    Rc anchor, List<MenuSection> sections) {
  final u = Metrics.factor;
  final itemH = (30 * u).round();
  final headH = (26 * u).round();
  final pad = (6 * u).round();
  final ipad = (4 * u).round();

  var h = pad * 2;
  for (final s in sections) {
    if (s.title.isNotEmpty) h += headH;
    h += s.items.length * itemH;
  }
  final top = anchor.bottom + (3 * u).round();
  final w = anchor.width < (176 * u).round() ? (176 * u).round() : anchor.width;
  final box = Rc.xywh(anchor.left, top, w, h);

  final headers = <Rc>[];
  final items = <(int, int, Rc)>[];
  var y = box.top + pad;
  for (var si = 0; si < sections.length; si++) {
    final s = sections[si];
    if (s.title.isNotEmpty) {
      headers.add(Rc.xywh(box.left + (12 * u).round(), y,
          box.width - (24 * u).round(), headH));
      y += headH;
    }
    for (var ii = 0; ii < s.items.length; ii++) {
      items.add(
          (si, ii, Rc.xywh(box.left + ipad, y, box.width - ipad * 2, itemH)));
      y += itemH;
    }
  }
  return SectionedMenuLayout(box, headers, items);
}

/// 画一份带分组标题的下拉菜单。
///
/// ★ 与 [drawDropdownMenu] 共用同一套视觉常数（圆角 / 投影 / 行高 / 悬停底色），
///   只是多了一行"分组标题"和一条极淡的分隔线。不合并成一个函数，是因为
///   那个的入参是扁平 `List<String>`，为加标题改签名会牵动所有调用点。
///
/// 返回点中的 `(组下标, 项下标)`；点浮层内空白返回 `(-2, -1)`；点外面 `(-1, -1)`。
(int, int) drawSectionedMenu(
  Gdi g,
  Rc anchor,
  List<MenuSection> sections, {
  required int mouseX,
  required int mouseY,
}) {
  final u = Metrics.factor;
  final l = layoutSectionedMenu(anchor, sections);
  final box = l.box;

  // 投影 + 面板（与 drawDropdownMenu 同参数）
  final off = (3 * u).round();
  g.roundFill(Rc.xywh(box.left + 2, box.top + off, box.width, box.height),
      Palette.shadow, Palette.shadow, radius: Metrics.radius);
  g.roundFill(box, Palette.surfaceAlt, Palette.lineStrong,
      radius: Metrics.radius);

  for (var i = 0; i < l.headers.length; i++) {
    final hr = l.headers[i];
    g.text(sections[i].title, hr, Palette.fgFaint,
        size: Metrics.fontSizeTiny, bold: true, vcenter: true);
    // 第二组起，标题上方画一条极淡的分隔线（分组感靠它，不靠粗描边）
    if (i > 0) {
      g.line(box.left + (10 * u).round(), hr.top - (2 * u).round(),
          box.right - (10 * u).round(), hr.top - (2 * u).round(), Palette.line);
    }
  }

  var hit = (-1, -1);
  for (final (si, ii, ir) in l.items) {
    final hot = ir.contains(mouseX, mouseY);
    if (hot) {
      hit = (si, ii);
      g.roundFill(ir, Palette.hover, Palette.hover,
          radius: Metrics.radiusSmall);
    }
    g.text(sections[si].items[ii], ir, hot ? Palette.fg : Palette.fgSub,
        size: Metrics.fontSize, padLeft: (10 * u).round());
  }
  return box.contains(mouseX, mouseY) ? hit : (-1, -1);
}

/// 计算下拉浮层的矩形（供外部做命中判断）。必须与 [drawDropdownMenu] 同规则。
Rc dropdownMenuRect(Rc anchor, int itemCount, {int maxVisible = 12}) {
  final itemH = (30 * Metrics.factor).round();
  final visible = itemCount > maxVisible ? maxVisible : itemCount;
  final pad = (6 * Metrics.factor).round();
  final h = visible * itemH + pad * 2;
  var top = anchor.bottom + (3 * Metrics.factor).round();
  final w = anchor.width < (140 * Metrics.factor).round()
      ? (140 * Metrics.factor).round()
      : anchor.width;
  return Rc.xywh(anchor.left, top, w, h);
}

// ───────────────────────── 标签页 ─────────────────────────

/// 画一组**下划线式**标签页（现代 UI 的常见做法：没有边框盒子，
/// 靠一条主色下划线标示当前项），返回每个标签的矩形。
List<Rc> drawTabs(
  Gdi g,
  int x,
  int y,
  int height,
  List<String> labels, {
  required int selected,
  required int mouseX,
  required int mouseY,
}) {
  final rects = <Rc>[];
  final u = Metrics.factor;
  var cx = x;
  for (var i = 0; i < labels.length; i++) {
    final tw = g.measure(labels[i], size: Metrics.fontSize, bold: true) +
        (28 * u).round();
    final r = Rc.xywh(cx, y, tw, height);
    rects.add(r);
    final on = i == selected;
    final hot = r.contains(mouseX, mouseY);

    if (hot && !on) {
      g.roundFill(r.inset((4 * u).round(), (6 * u).round()), Palette.hover,
          Palette.hover, radius: Metrics.radiusSmall);
    }
    g.text(labels[i], r, on ? Palette.fg : (hot ? Palette.fgSub : Palette.fgFaint),
        size: Metrics.fontSize, align: dtCenter, bold: on);

    if (on) {
      // 当前项：底部一条主色短横线（长度比文字略宽，视觉上"托住"文字）
      final lineW = (tw * 0.62).round();
      final lx = r.left + (r.width - lineW) ~/ 2;
      final ly = r.bottom - (3 * u).round();
      final th = (2 * u).round().clamp(2, 4);
      g.roundFill(Rc.xywh(lx, ly, lineW, th), Palette.accent, Palette.accent,
          radius: th);
    }
    cx += tw + (4 * u).round();
  }
  return rects;
}

// ───────────────────────── 徽标 / 状态胶囊 ─────────────────────────

/// 画一个状态标签（如「数据到手」「20 条」）。返回它的矩形。
///
/// 现代做法：药丸形（半径=高度一半）+ 同色淡底 + 同色文字，不用描边。
Rc drawBadge(
  Gdi g,
  int x,
  int y,
  int height,
  String text, {
  required int fg,
  int? bg,
  int? fontSize,
  bool bold = false,
}) {
  final fs = fontSize ?? Metrics.fontSizeTiny;
  final padx = (10 * Metrics.factor).round();
  final tw = g.measure(text, size: fs, bold: bold) + padx * 2;
  final r = Rc.xywh(x, y, tw, height);
  final back = bg ?? blend(fg, Palette.surface, 0.84);
  g.roundFill(r, back, back, radius: height ~/ 2);
  g.text(text, r, fg, size: fs, align: dtCenter, bold: bold);
  return r;
}

/// 把 [src] 以 [t] 的比例混到 [dst] 上（0=全 dst，1=全 src）。
int blend(int src, int dst, double t) {
  final sr = src & 0xFF, sg = (src >> 8) & 0xFF, sb = (src >> 16) & 0xFF;
  final dr = dst & 0xFF, dg = (dst >> 8) & 0xFF, db = (dst >> 16) & 0xFF;
  int m(int a, int b) => (a * (1 - t) + b * t).round().clamp(0, 255);
  return rgb(m(sr, dr), m(sg, dg), m(sb, db));
}

// ───────────────────────── 卡片 ─────────────────────────

/// 画一张卡片（圆角面板 + 淡描边 + 可选标题带）。返回内容区起始 y。
///
/// [title] 为空时只画面板，标题带不画。
Rc drawCard(Gdi g, Rc card, {String? title, String? badge, int? badgeColor}) {
  g.roundFill(card, Palette.surface, Palette.line, radius: Metrics.radius);
  if (title == null || title.isEmpty) {
    return Rc.xywh(card.left, card.top, card.width, card.height);
  }
  final th = Metrics.cardTitleH;
  // 标题带：比卡片亮一档，且**只在上半部画圆角**（用整块圆角再压下方）
  g.fill(Rc.xywh(card.left + 1, card.top + 1, card.width - 2, th),
      Palette.surfaceAlt);
  g.line(card.left + 1, card.top + th, card.right - 1, card.top + th,
      Palette.line);

  final padx = (16 * Metrics.factor).round();
  g.text(title, Rc.xywh(card.left + padx, card.top, card.width - 200, th),
      Palette.fg, size: Metrics.fontSizeTitle, bold: true);
  if (badge != null) {
    final bx = card.left +
        padx +
        g.measure(title, size: Metrics.fontSizeTitle, bold: true) +
        (10 * Metrics.factor).round();
    final bh = (20 * Metrics.factor).round();
    drawBadge(g, bx, card.top + (th - bh) ~/ 2, bh, badge,
        fg: badgeColor ?? Palette.fgDim);
  }
  return Rc.xywh(card.left, card.top + th, card.width, card.height - th);
}

/// 提示条（左强调竖线 + 同色淡底）。返回它的矩形，便于继续往下排。
Rc drawHint(Gdi g, Rc area, int y, String text, int color,
    {int height = 0}) {
  final h = height > 0 ? height : (30 * Metrics.factor).round();
  final r = Rc.xywh(area.left, y, area.width, h);
  final back = blend(color, Palette.surface, 0.88);
  g.roundFill(r, back, back, radius: Metrics.radiusSmall);
  final lw = (3 * Metrics.factor).round().clamp(2, 5);
  g.fill(Rc.xywh(r.left, r.top, lw, r.height), color);
  g.text(text, Rc.xywh(r.left + lw + (10 * Metrics.factor).round(), r.top,
          r.width - lw - 20, r.height),
      color, size: Metrics.fontSizeSmall, vcenter: true);
  return r;
}

// ───────────────────────── 表格 ─────────────────────────

/// 表格绘制结果。
///
/// ★ [cellRects] 是"第 i 行第 c 列"的真实矩形，与绘制用的是**同一份** widths ——
///   调用方（书链接按钮、封面缩略图）不必再自己反推列宽。
///   以前数据管理窗就是自己算了一遍列宽，那种"两份实现"迟早会漂移
///   （列宽一改，按钮就画偏）。
class TableRender {
  TableRender(this.headerRects, this.rowsDrawn,
      {this.rowRects = const [],
      this.cellRects = const [],
      this.rowIndices = const []});
  final List<Rc> headerRects;
  final int rowsDrawn;

  /// 每个**已绘制**数据行的矩形（下标与 `rows` 一致；未绘制的行没有条目）。
  final List<Rc> rowRects;

  /// 每个已绘制行的各列矩形：`cellRects[i][colIndex]`（`i` 与 [rowRects] 同序）。
  final List<List<Rc>> cellRects;

  /// `rowRects[i]` 对应的是 `rows` 里的第几行。
  ///
  /// ★ 必须有它：表格会滚动，`rowRects[0]` 不一定是第 0 行。
  ///   调用方（书链接）要按"这是哪一本书"登记命中区，靠 top 反推下标
  ///   在滚动量不是行高整数倍时会算错一行。
  final List<int> rowIndices;
}

/// 画一个数据表格。所有度量（行高/字号/内边距）都读 [Metrics]，
/// 列宽用 [Column.scaledWidth] —— 所以窗口变大时整张表跟着放大。
TableRender drawTable(
  Gdi g,
  Rc area,
  List<Column> cols,
  List<List<String>> rows, {
  required int scrollY,
  required int mouseX,
  required int mouseY,
  int? hoverRow,
  int? selectedRow,
  List<int>? rowColors,
  List<List<int?>>? cellColors,
  List<int>? cellMonoWidth,
  int? rowHeight,
  int? headerRowHeight,
  int? fontSize,
  double widthScale = 1.0,
}) {
  // ★ 行高可按表指定：带封面的「榜单明细」要更高，其余表 42px 就够。
  //   不指定就用通用值（老调用点一行都不用改）。
  final rowH = rowHeight ?? Metrics.rowHeight;
  final headerH = headerRowHeight ?? Metrics.headerRowHeight;
  final fs = fontSize ?? Metrics.fontSize;
  final padx = (10 * Metrics.factor * widthScale).round();

  final contentH = rows.length * rowH;
  final viewH = area.height - headerH;
  final needScroll = contentH > viewH;
  final scrollW = needScroll ? (11 * Metrics.factor).round() : 0;
  final usableW = area.width - scrollW;

  // ★ [widthScale]：整表按比例放大（用户要求"每一栏都整体放大 1.5 倍"）。
  //   列宽、内边距、字号一起放大 —— 只放大列宽会让文字显得空，只放大字号会挤。
  int scaledW(Column c) => (c.width * Metrics.factor * widthScale).round();
  var fixed = 0;
  var stretchCount = 0;
  for (final c in cols) {
    if (c.stretch) {
      stretchCount++;
    } else {
      fixed += scaledW(c);
    }
  }
  final minStretch = (80 * Metrics.factor).round();
  final stretchW = stretchCount == 0
      ? 0
      : ((usableW - fixed) / stretchCount).round();
  final widths = [
    for (final c in cols)
      c.stretch ? (stretchW < minStretch ? minStretch : stretchW) : scaledW(c)
  ];

  // 表头
  final headRects = <Rc>[];
  g.fill(area, Palette.surface);
  g.fill(Rc.xywh(area.left, area.top, usableW, headerH), Palette.surfaceAlt);
  g.line(area.left, area.top + headerH, area.left + usableW, area.top + headerH,
      Palette.line);

  var cx = area.left;
  for (var i = 0; i < cols.length; i++) {
    final r = Rc.xywh(cx, area.top, widths[i], headerH);
    headRects.add(r);
    g.text(cols[i].title, r, Palette.fgFaint,
        size: (fs * 0.9).round(),
        align: cols[i].align,
        bold: true,
        padLeft: padx);
    cx += widths[i];
  }

  // 行区（只画视口内的行）
  final bodyTop = area.top + headerH;
  final bodyBottom = area.bottom;
  final total = rows.length;
  final firstIdx = (scrollY / rowH).floor();
  final visibleCount = ((bodyBottom - bodyTop) / rowH).ceil() + 2;
  var drawn = 0;

  // ★ 真裁剪到**行区**。
  //   `if (ry + rowH < bodyTop || ry > bodyBottom) continue` 是**起点守卫**，
  //   挡不住"从行区内开始、画到行区外"：滚动量不是行高整数倍时，
  //   第一行的顶边落在 bodyTop 之上（ry = bodyTop - 余数），它会**压住表头**
  //   ——因为表头是先画的。滚一点就能看到表头被啃掉一截。
  //   裁剪之后，行区永远不越界，表头也就永远完整。
  final endRowClip = g.clipTo(Rc.xywh(area.left, bodyTop, area.width,
      bodyBottom - bodyTop));
  final rowRects = <Rc>[];
  final cellRects = <List<Rc>>[];
  final rowIndices = <int>[];
  try {
  for (var k = 0; k < visibleCount; k++) {
    final i = firstIdx + k;
    if (i < 0 || i >= total) continue;
    final ry = bodyTop + i * rowH - scrollY;
    if (ry + rowH < bodyTop || ry > bodyBottom) continue;
    final row = rows[i];
    final rr = Rc.xywh(area.left, ry, area.width, rowH);
    rowRects.add(rr);
    rowIndices.add(i);
    final cells = <Rc>[];

    if (selectedRow == i) {
      g.fill(rr, Palette.selected);
    } else if (hoverRow == i || rr.contains(mouseX, mouseY)) {
      g.fill(rr, Palette.rowHover);
    } else if (i.isOdd) {
      g.fill(rr, Palette.zebra);
    }

    var vx = area.left;
    for (var c = 0; c < cols.length; c++) {
      final cr = Rc.xywh(vx, ry, widths[c], rowH);
      cells.add(cr);
      final txt = c < row.length ? row[c] : '';
      var col = Palette.fg;
      final cc = (cellColors != null && i < cellColors.length)
          ? cellColors[i]
          : null;
      if (cc != null && c < cc.length && cc[c] != null) {
        col = cc[c]!;
      } else if (rowColors != null && i < rowColors.length && c == 0) {
        col = rowColors[i];
      }
      final isMono = cellMonoWidth != null && c < cellMonoWidth.length;
      g.text(txt, cr, col,
          size: fs, align: cols[c].align, padLeft: isMono ? 4 : padx);
      vx += widths[c];
    }
    cellRects.add(cells);
    g.line(area.left, ry + rowH - 1, area.left + usableW, ry + rowH - 1,
        Palette.lineFaint);
    drawn++;
  }
  } finally {
    endRowClip();
  }

  g.line(area.left, area.bottom - 1, area.right, area.bottom - 1, Palette.line);
  return TableRender(headRects, drawn,
      rowRects: rowRects, cellRects: cellRects, rowIndices: rowIndices);
}

/// 表格内容总高（用于滚动范围计算）。必须与 [drawTable] 用同一组行高。
int tableContentHeight(int rowCount, {int? rowHeight, int? headerRowHeight}) =>
    (headerRowHeight ?? Metrics.headerRowHeight) +
    rowCount * (rowHeight ?? Metrics.rowHeight);

// ───────────────────────── 滚动条 ─────────────────────────

/// 现代细滚动条：窄轨道 + 圆角滑块，且**不占表格内容宽度**（叠在上面画）。
Rc drawScrollbar(
  Gdi g,
  Rc track, {
  required int contentHeight,
  required int viewHeight,
  required int scrollY,
  required bool hot,
}) {
  final w = (11 * Metrics.factor).round();
  final bar = Rc.xywh(track.right - w, track.top, w, track.height);
  if (contentHeight <= viewHeight || viewHeight <= 0) {
    return Rc.xywh(bar.left, bar.top, 0, 0);
  }

  final u = Metrics.factor;
  final pad = (3 * u).round();
  final thumbW = w - pad * 2;

  final ratio = viewHeight / contentHeight;
  var thumbH = (bar.height * ratio).round();
  final minThumb = (32 * u).round();
  if (thumbH < minThumb) thumbH = minThumb;

  final maxScroll = contentHeight - viewHeight;
  final maxTop = bar.height - thumbH;
  final t = maxScroll <= 0 ? 0.0 : (scrollY / maxScroll).clamp(0.0, 1.0);
  final thumbTop = bar.top + (maxTop * t).round();

  final thumb = Rc.xywh(bar.left + pad, thumbTop, thumbW, thumbH);
  g.roundFill(thumb,
      hot ? Palette.lineStrong : Palette.scrollThumb,
      hot ? Palette.lineStrong : Palette.scrollThumb,
      radius: thumbW ~/ 2);
  return thumb;
}

// ───────────────────────── 文本工具 ─────────────────────────

/// 万/亿缩写，与报告和网页口径一致。
/// 人类可读的数量。万/亿单位，超过"万亿"量级改用科学计数。
///
/// ★ 必须处理**离谱的大数**：脏数据里出现过 `9223372036854775807`（int64 上限），
///   旧实现直接按"亿"再吐一遍 → 界面上显示 `9223372036854775807亿`，
///   看着像真数据。超过 1e13（10 万亿）已经远超任何真实指标，
///   此时用 `1.2e15` 这种写法，一眼能看出"这个数不对劲"。
/// 同时兜住 Infinity/NaN（JSON 的 `1e999`）。
String wan(num? n) {
  if (n == null) return '-';
  final v = n.toDouble();
  if (!v.isFinite) return '非有限数';
  if (v.isNaN) return 'NaN';
  final a = v.abs();
  if (a >= 1e13) return v.toStringAsExponential(1);
  if (a >= 100000000) return '${(v / 100000000).toStringAsFixed(2)}亿';
  if (a >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
  if (v == v.roundToDouble()) return '${v.toInt()}';
  return v.toStringAsFixed(2);
}

/// 按像素宽度截断文本。
String ellipsize(Gdi g, String s, int maxWidth, {int? size}) {
  final fs = size ?? Metrics.fontSize;
  if (g.measure(s, size: fs) <= maxWidth) return s;
  var lo = 0, hi = s.length;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (g.measure('${s.substring(0, mid)}…', size: fs) <= maxWidth) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo <= 0 ? '…' : '${s.substring(0, lo)}…';
}

/// 分配一个 Pointer<Utf16> 并及时释放的便捷函数（绘制里高频用）。
T withUtf16<T>(String s, T Function(Pointer<Utf16>) fn) {
  final p = s.toNativeUtf16();
  try {
    return fn(p);
  } finally {
    calloc.free(p);
  }
}

// ───────────────────────── 横向滚动条 ─────────────────────────

/// 现代细横向滚动条（与纵向那条同一套视觉：窄轨道 + 圆角滑块）。
///
/// ★ 为什么需要它：明细表整表放大 1.5 倍后总宽超过可用宽，
///   没有横向滚动的话最右边的列会被直接挤出屏幕（用户点不到）。
Rc drawHScrollbar(
  Gdi g,
  Rc track, {
  required int contentWidth,
  required int viewWidth,
  required int scrollX,
  required bool hot,
}) {
  final u = Metrics.factor;
  final h = (11 * u).round();
  final bar = Rc.xywh(track.left, track.bottom - h, track.width, h);
  if (contentWidth <= viewWidth || viewWidth <= 0) {
    return Rc.xywh(bar.left, bar.top, 0, 0);
  }

  final pad = (3 * u).round();
  final thumbH = h - pad * 2;

  final ratio = viewWidth / contentWidth;
  var thumbW = (bar.width * ratio).round();
  final minThumb = (32 * u).round();
  if (thumbW < minThumb) thumbW = minThumb;

  final maxScroll = contentWidth - viewWidth;
  final maxLeft = bar.width - thumbW;
  final t = maxScroll <= 0 ? 0.0 : (scrollX / maxScroll).clamp(0.0, 1.0);
  final thumbLeft = bar.left + (maxLeft * t).round();

  final thumb = Rc.xywh(thumbLeft, bar.top + pad, thumbW, thumbH);
  final col = hot ? Palette.lineStrong : Palette.scrollThumb;
  g.roundFill(thumb, col, col, radius: thumbH ~/ 2);
  return thumb;
}

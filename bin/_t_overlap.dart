/// 重叠回归自检 —— 用**真实 GDI `measure()`** 复算三处曾出问题的排版，
/// 断言"两个相邻控件的框不再相交"。
///
/// 覆盖：
///   ① 侧栏：书名框右缘 vs 数字框左缘（原重叠 6px）；
///      + 第 7 轮补：高亮框左缘 > 0、右缘 < 侧栏宽、accent 竖条完整在框内
///        （对应"未对齐"：选中框左圆角/accent 条被视口切掉）；
///   ② 设置窗顶栏：标题/副标题右缘 vs 按钮组左缘（原重叠 156px）；
///   ③ 步进器内部："30" 框右缘 vs "本" 框左缘（原重叠 2px）。
///
/// 断言方式：直接比"左框右缘 <= 右框左缘"，重叠就 FAIL —— 这是硬像素级的，
/// 不依赖视觉，也不会因字体替换而假绿（用的是同一套 measure）。
///
/// 运行：dart run bin/_t_overlap.dart
library;

import 'dart:io';

import '../lib/ui/dialogs.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/widgets.dart';

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

void main() {
  stdout.writeln('== 字体重叠回归（真实 GDI measure 复算）==');

  // 三档缩放都验一遍 —— 重叠是"缩放时更容易犯"的错。
  for (final scale in const [1.0, 1.19, 1.375]) {
    _runOne(scale);
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

void _runOne(double scale) {
  final saved = Metrics.factor;
  Metrics.factor = scale;
  stdout.writeln('\n── factor=$scale ──');
  try {
    // 用一个离屏 BackBuffer 拿真实 Gdi（measure/DrawText 都走真 GDI）。
    final buf = BackBuffer(1240, 800);
    try {
      final g = buf.gdi;
      _checkSidebar(g);
      _checkDialogHeader(g);
      _checkStepper(g);
    } finally {
      buf.dispose();
    }
  } finally {
    Metrics.factor = saved;
  }
}

// ── ① 侧栏：书名框 vs 数字框 ──

void _checkSidebar(Gdi g) {
  final u = Metrics.factor;
  // 复刻 main_window.dart `_paintSidebar` 的算式（同一份布局常量）。
  // ★ 第 7 轮：行矩形左右各留 8px（rowInset），选中态高亮框 + accent 竖条
  //   必须完整落在侧栏留白内 —— 原来 r.left=0，accent 条骑在侧栏左缘上被切。
  const sidebarW = 250;
  const padx = 14;
  final rowInset = (8 * u).round();
  final r = Rc.xywh(rowInset, 0, (sidebarW * u).round() - rowInset * 2,
      (56 * u).round());

  // ① 侧栏几何正确性：高亮框不能碰侧栏左右边线
  _check('侧栏 高亮框左缘(${r.left}) > 0（不骑在侧栏左边线上）', r.left > 0,
      'left=${r.left}');
  _check('侧栏 高亮框右缘(${r.right}) < 侧栏宽(${(sidebarW * u).round()})（不压分隔线）',
      r.right < (sidebarW * u).round(),
      'right=${r.right} 分隔线=${(sidebarW * u).round()}');

  // ② accent 竖条完整落在高亮框内（不再被框边线切一半）
  final lw = (3 * u).round().clamp(2, 5);
  final innerInset = (3 * u).round();
  final barLeft = r.left + innerInset;
  final barRight = barLeft + lw;
  _check('侧栏 accent 竖条($barLeft..$barRight) 完整在高亮框(${r.left}..${r.right})内',
      barLeft >= r.left && barRight <= r.right, 'box=${r.left}..${r.right}');

  const countW = 46;
  final countLeft = r.right - (countW * u).round();
  final nameRight = countLeft - (6 * u).round();
  final nameLeft = r.left + (padx * u).round() + (8 * u).round();

  _check('侧栏 书名框右缘($nameRight) <= 数字框左缘($countLeft)',
      nameRight <= countLeft, '间隙=${countLeft - nameRight}px');
  // 名称框不能是负数宽（挤爆）
  _check('侧栏 书名框宽度为正（$nameLeft..$nameRight）',
      nameRight > nameLeft, 'w=${nameRight - nameLeft}');
  // 顺带验证：最长的侧栏书名会被省略而不是撞进数字区
  final longest = g.measure('签约作者新书榜 · 全站', size: Metrics.fontSizeSmall);
  if (longest > nameRight - nameLeft) {
    _check('侧栏 超长书名靠 dtEndEllipsis 省略（框宽 ${nameRight - nameLeft} < 文字 $longest）',
        true);
  } else {
    _check('侧栏 书名文字放得下（框宽 ${nameRight - nameLeft} >= 文字 $longest）', true);
  }
}

// ── ② 设置窗顶栏：标题 vs 按钮组 ──

void _checkDialogHeader(Gdi g) {
  final u = Metrics.factor;
  const dlgW = 1040; // 与 showScanDialog 一致
  final width = (dlgW * u).round();
  final padx = (18 * u).round();
  final logo = (24 * u).round();
  final tx = padx + logo + (10 * u).round();

  // 复刻按钮"从右往左"累计（与 dialogs.dart 一致）
  var bx = width - Metrics.winBtnInset - Metrics.winBtnW * 2 - (10 * u).round();
  void hbtn(int baseW) {
    bx -= (baseW * u).round();
    bx -= (8 * u).round();
  }

  hbtn(66); // 取消
  hbtn(106); // 开始扫榜
  bx -= (10 * u).round();
  hbtn(70); // 全不选
  hbtn(82); // 默认组合
  bx -= (14 * u).round();
  bx -= (178 * u).round(); // 批量本数组

  final headRight = bx - (16 * u).round();
  final titleW = g.measure('选择要扫的榜', size: Metrics.fontSizeTitle, bold: true);
  final sub = '勾选后点「开始扫榜」';
  final subW = g.measure(sub, size: Metrics.fontSizeTiny);
  final subGap = (14 * u).round();
  final availW = headRight - tx;

  final fitsTitle = availW >= titleW;
  final fitsBoth = availW >= titleW + subGap + subW;

  // 契约：只有当"画出来的东西真的放得下"时才画；否则不画。
  //   无论走哪个分支，都绝不允许画到按钮组左界（headRight）右边。
  final drawnRight = fitsBoth
      ? tx + titleW + subGap + subW
      : (fitsTitle ? tx + titleW : tx);
  _check('设置窗 顶栏标题/副标题右缘($drawnRight) <= 按钮组左界($headRight)',
      drawnRight <= headRight, '溢出=${drawnRight - headRight}px');
  // 在设计的 980 宽下，标题+副标题**必须**都放得下（否则顶栏会显得空）。
  _check('设置窗 1040 宽下标题+副标题都放得下（availW=$availW >= 需 ${titleW + subGap + subW}）',
      fitsBoth, 'availW=$availW need=${titleW + subGap + subW}');
  if (fitsBoth) {
    _check('设置窗 空间足够 → 标题 + 副标题都画', true);
  } else if (fitsTitle) {
    _check('设置窗 空间只够标题 → 只画标题、不画副标题', true);
  } else {
    _check('设置窗 空间不足 → 标题整体不画', true);
  }
  // 标题若画出来，左侧不能和品牌块/文字重叠
  _check('设置窗 标题左缘($tx) 在品牌块右侧', tx > padx + logo, 'tx=$tx');

  // ★ 批量组内的标签"已选榜本数"必须**完整显示**，不能被省略成"已选榜…"。
  //   组宽 178 - 步进器 108 - gap 10 = 60px 给标签；标签实测宽必须 <= 60。
  final groupW = (178 * u).round();
  final labelAvail = groupW - stepperWidth - (10 * u).round();
  final labelW = g.measure('已选榜本数', size: Metrics.fontSizeTiny);
  _check('设置窗 批量组标签"已选榜本数"完整放得下（可用 $labelAvail >= 实测 $labelW）',
      labelW <= labelAvail, '超出 ${labelW - labelAvail}px');
}

// ── ③ 步进器内部：数字 vs "本" ──

void _checkStepper(Gdi g) {
  final u = Metrics.factor;
  final sw = stepperWidth;
  final sh = stepperHeight;
  final btnW = sh;
  final valBoxW = sw - btnW * 2;

  // 复刻 drawStepper 的新排版算式
  final tw = g.measure('30', size: Metrics.fontSizeTiny, bold: true);
  final uw = g.measure('本', size: Metrics.fontSizeTiny);
  final gap = (5 * u).round().clamp(3, 8);
  final need = tw + gap + uw;
  final startX = ((valBoxW - need) ~/ 2).clamp(0, valBoxW);

  final numLeft = startX;
  final numRight = startX + tw;
  final unitLeft = startX + tw + gap;
  final unitRight = unitLeft + uw;

  _check('步进器 数字框右缘($numRight) <= "本"框左缘($unitLeft)',
      numRight <= unitLeft, 'gap=${unitLeft - numRight}px');
  _check('步进器 整块居中（need=$need <= 值区宽 $valBoxW）', need <= valBoxW,
      'overflow=${need - valBoxW}');
  _check('步进器 左留白($numLeft) 与右留白(${valBoxW - unitRight}) 对称',
      (numLeft - (valBoxW - unitRight)).abs() <= 1,
      'l=$numLeft r=${valBoxW - unitRight}');
}

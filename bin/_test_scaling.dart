/// 缩放回归 —— 同一界面在多档窗口尺寸下渲染，检查**字号确实跟着变、但不过头**。
///
/// 判定不靠肉眼：直接读 [Metrics.factor] 与实测文本像素宽度。
///
/// ★ 第 17 轮改了曲线（用户："整体放大太突兀，需要柔和一点"），
///   于是这一节守的**性质**也跟着变：
///     ① 仍然要真的变大（否则又回到"窗口拉大只有空白变多"那个老问题）；
///     ② 但不能"整块被吹大" —— 上限 1.4、放大倍数 < 1.45；
///     ③ 因子必须**量化到 2%**（拖动窗口时界面持续抖动就是没量化）；
///     ④ 有**死区**：窗口动几个像素不该让整套度量重排。
///
/// 运行：dart run bin/_test_scaling.dart
library;

import 'dart:io';

import '../lib/png.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/win32.dart';
import '_render_shots.dart' show renderBgra;

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

/// 在一张离屏 DC 上量一段文字的像素宽度。
int measureAt(String s, int fontSize) {
  final screen = getDC(0);
  final mem = createCompatibleDC(screen);
  final g = Gdi(mem);
  final w = g.measure(s, size: fontSize, bold: true);
  deleteDC(mem);
  releaseDC(0, screen);
  return w;
}

void main() {
  const sample = '网文扫榜工具';
  const sizes = <(String, int, int)>[
    ('860x560  小窗', 860, 560),
    ('1240x800 基准', 1240, 800),
    ('1600x1000 中屏', 1600, 1000),
    ('1920x1200 大屏', 1920, 1200),
  ];

  stdout.writeln('=== 缩放回归：字号随窗口变，但不过头 ===\n');
  stdout.writeln('窗口                 factor   字号   文本宽度');
  stdout.writeln('-' * 52);

  final dir = Directory('build/shots')..createSync(recursive: true);
  final factors = <double>[];
  var firstW = 0;
  var lastW = 0;
  for (final (label, w, h) in sizes) {
    // ★ 走和真实窗口一样的路径：先 applyTo，再取 Metrics
    UiScale.applyTo(w, h);
    final fs = Metrics.fontSize;
    final tw = measureAt(sample, fs);
    factors.add(Metrics.factor);
    if (firstW == 0) firstW = tw;
    lastW = tw;
    stdout.writeln('${label.padRight(18)} '
        '${Metrics.factor.toStringAsFixed(3).padRight(8)} '
        '${fs.toString().padRight(6)} $tw');

    final mw = MainWindow(outRoot: 'out');
    mw.reload();
    mw.testSetSize(w, h);
    final bgra = renderBgra(mw.onPaint, w, h);
    final png = bgraToPng(bgra, w, h);
    File('${dir.path}/scale_${w}x$h.png').writeAsBytesSync(png);
  }

  final ratio = lastW / firstW;
  stdout.writeln('');
  stdout.writeln('最小窗文本宽度 = $firstW px');
  stdout.writeln('最大窗文本宽度 = $lastW px');
  stdout.writeln('放大倍数 = ${ratio.toStringAsFixed(2)}x\n');

  stdout.writeln('── 判据 ──');
  _check('字号确实随窗口变大（>1.2x）', ratio > 1.2,
      'ratio=${ratio.toStringAsFixed(2)}');
  _check('放大不过头（<1.45x）', ratio < 1.45,
      'ratio=${ratio.toStringAsFixed(2)}');
  _check('因子不超过上限 ${UiScale.maxFactor}',
      factors.every((f) => f <= UiScale.maxFactor + 1e-9),
      factors.join(','));
  _check('因子单调不降（窗口越大字越大）',
      [for (var i = 1; i < factors.length; i++) factors[i] >= factors[i - 1]]
          .every((x) => x),
      factors.join(','));
  _check('因子量化到 2% 的整数倍（避免拖动时持续重排）',
      factors.every((f) =>
          ((f / UiScale.quantum) - (f / UiScale.quantum).round()).abs() < 1e-6),
      factors.join(','));

  // 死区：窗口只动几个像素，因子必须**不变**（返回 false = 不需要重排）
  UiScale.applyTo(1240, 800);
  final f0 = Metrics.factor;
  final changed = UiScale.applyTo(1246, 804);
  _check('窗口小改（+6px）不触发重排（死区生效）',
      !changed && Metrics.factor == f0,
      'changed=$changed factor=${Metrics.factor}');
  // 但改得够多时**必须**重排
  final big = UiScale.applyTo(1500, 950);
  _check('窗口大改（+260px）触发重排', big && Metrics.factor > f0,
      'changed=$big factor=${Metrics.factor}');

  // ── ⑥ DPI 缩放（第 22 轮加的 PER_MONITOR_AWARE_V2）──
  //
  // ★ 为什么必须有这一段：进程开了 DPI 感知之后，系统**不再**对窗口做位图拉伸，
  //   "逻辑尺寸 → 物理像素"这一步就得 UI 自己做。做漏了的表现是
  //   "150% 缩放下整个界面偏小"—— 而这在高 DPI 机器上才会暴露，
  //   在 100% 的开发机上永远看不到。所以只能靠算术断言把它钉住。
  stdout.writeln('\n── ⑥ DPI 缩放 ──');
  try {
    // 200% DPI 下，同样一块 1240x800 的**物理**客户区 = 620x400 逻辑尺寸。
    // 逻辑上小于基准窗 → 布局因子收到下限 1.0，再乘回 DPI → 2.0。
    Metrics.dpiScale = 2.0;
    final f200 = UiScale.factorFor(1240, 800);
    _check('200% DPI：1240x800 物理 → factor = 2.0（= 逻辑 1.0 × DPI 2）',
        (f200 - 2.0).abs() < 0.02, f200.toStringAsFixed(3));

    // 100% DPI 下同一块区域：布局因子就是它自己
    Metrics.dpiScale = 1.0;
    final f100 = UiScale.factorFor(1240, 800);
    _check('100% DPI：同一块物理区域 factor = 1.0',
        (f100 - 1.0).abs() < 0.02, f100.toStringAsFixed(3));

    // ★ 关键性质：**同一个逻辑尺寸**在不同 DPI 下应当得到同一个物理缩放。
    //   200% DPI 下给 2480x1600 物理（= 1240x800 逻辑），应当和
    //   100% DPI 下给 1240x800 得到同样的 factor 曲线位置（再乘 2）。
    Metrics.dpiScale = 2.0;
    final f200big = UiScale.factorFor(2480, 1600);
    _check('200% DPI 下 2480x1600（= 1240x800 逻辑）落在基准档',
        (f200big - 2.0).abs() < 0.02, f200big.toStringAsFixed(3));
    Metrics.dpiScale = 1.0;
    final f100base = UiScale.factorFor(1240, 800);
    _check('同一逻辑尺寸在 100% / 200% 下只差一个 DPI 倍数',
        (f200big - f100base * 2.0).abs() < 0.05,
        '200%=$f200big 100%=$f100base');

    // 量化步长也要跟着 DPI 放大，否则高 DPI 下"2% 的死区"变成 1%，
    // 拖动窗口时界面会持续重排（用户报过"拖动时抖"）。
    Metrics.dpiScale = 2.0;
    Metrics.factor = 2.0;
    final tiny = UiScale.applyTo(2482, 1601); // 逻辑上只动了 1px
    _check('200% DPI 下 1px 抖动不触发重排（死区跟着 DPI 放大）', !tiny,
        'changed=$tiny factor=${Metrics.factor}');
    final big2 = UiScale.applyTo(2600, 1700);
    _check('200% DPI 下窗口大改仍然重排', big2 && Metrics.factor > 2.0,
        'changed=$big2 factor=${Metrics.factor}');

    // 兜底：dpiScale 未初始化 / 非法时不能把界面算成 0
    Metrics.dpiScale = 0;
    final f0dpi = UiScale.factorFor(1240, 800);
    _check('dpiScale = 0（未初始化）时按 100% 处理，不会算出 0',
        f0dpi > 0.5, f0dpi.toStringAsFixed(3));
  } finally {
    Metrics.dpiScale = 1.0;
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

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

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

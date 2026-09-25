/// 端到端验证：**用真实数据目录**跑一遍封面（含旧快照的兜底）。
///
/// 这一节回答的是用户实际遇到的问题："为什么一个封面都没有"。
/// 真实 `out/` 里的快照都是封面字段上线**之前**采集的（没有 `cover_url`），
/// 所以必须证明"**没有那个字段也能出封面**"：
///
///   · 起点   → 封面地址是 `bookId` 的纯函数，直接**推导**（不用额外请求）
///   · 番茄   → 榜单接口不给封面 → 去**书籍页**扒一次（懒加载 + 永久缓存）
///   · 七猫   → 同上
///   · 晋江   → 书页里**没有**封面 → 老实画占位卡
///
/// ★ 它会真的打网络（每本书一次，之后永久缓存）—— 这正是正式程序的行为，
///   跑完 `out/扫榜/_covers/` 里就有图了，打开界面直接能看。
///
/// 运行：dart run bin/_probe_cover_real.dart [数据目录]
library;

import 'dart:io';

import '../lib/png.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '_render_shots.dart' show renderBgra;

/// 封面列的取样窗口 —— **从实际布局算出来**，不写死坐标。
///
/// ★ 这里踩过一次坑：整表放大 1.5 倍之后 rank 列从 44 变 66、封面列从 52 变 78，
///   而取样窗口还是旧的那一组 → 量到了"# 列"上，得出"一个封面都没有"的假结论。
///   所以现在**不写死**：用 `mw.testDetailArea` + 列宽公式现算。
///   布局再变，这里跟着变。
int _colLeft = 0;
int _colRight = 0;
int _colTop = 0;
int _colBottom = 0;

/// 按明细表当前布局设置取样窗口（必须在渲染一帧之后调用）。
void setCoverColumnFrom(MainWindow mw) {
  final area = mw.testDetailArea;
  if (area == null) return;
  final u = Metrics.factor;
  final s = mw.testDetailScale; // ★ 自适应缩放，不是写死的 1.5
  final rankW = (44 * u * s).round();
  final coverW = (52 * u * s).round();
  // 内缩 6px：避开列分隔线与圆角，只取封面图真正占的那块
  _colLeft = area.left + rankW + 6;
  _colRight = area.left + rankW + coverW - 6;
  _colTop = area.top + mw.testDetailHeaderHeight + 6;
  _colBottom = area.bottom - 14; // 让开底部那条横向滚动条
}

/// 数"有封面"与"无封面"两次渲染在封面列里的差异像素。
int diffInCoverColumn(List<int> a, List<int> b, int width) {
  var diff = 0;
  for (var y = _colTop; y < _colBottom; y++) {
    for (var x = _colLeft; x < _colRight; x++) {
      final o = (y * width + x) * 4;
      if (a[o] != b[o] || a[o + 1] != b[o + 1] || a[o + 2] != b[o + 2]) diff++;
    }
  }
  return diff;
}

Future<void> main(List<String> args) async {
  final outRoot = args.isNotEmpty ? args[0] : 'out';
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: outRoot);
  Palette.apply(AppTheme.dark);
  mw.reload();

  final all = mw.vm?.all ?? const [];
  stdout.writeln('数据目录: $outRoot    快照 ${all.length} 份');
  if (all.isEmpty) {
    stdout.writeln('没有快照，无从验证');
    exitCode = 2;
    return;
  }
  stdout.writeln('（起点=bookId 推导；番茄/七猫=扒书籍页；晋江=没有来源，占位卡）\n');

  // ★ 宽窗口出图：基准窗（1240×800）下 8 列放不下，「链接」列会被挤出视口，
  //   而这张图要同时展示"真封面 + 可点开的书链接"。
  const w = 2400, h = 1400;
  final dir = Directory('build/shots')..createSync(recursive: true);
  var anyOk = false;

  for (final src in const ['qidian', 'fanqie', 'qimao', 'jjwxc']) {
    final list = all.where((m) => m.source == src).toList();
    if (list.isEmpty) {
      stdout.writeln('[${src.padRight(7)}] 没有快照，跳过');
      continue;
    }
    list.sort((a, b) => b.count.compareTo(a.count));
    final t = list.first;
    mw.testSelect(t.id);
    mw.testSetSize(w, h);
    renderBgra(mw.onPaint, w, h); // 第一帧把可见行喂进封面队列
    setCoverColumnFrom(mw); // ★ 取样窗口按**当前布局**现算

    final c = mw.covers!;
    final before = c.fetched;
    var n = 0;
    while (c.hasWork && n < 200) {
      await c.pump(force: true);
      n++;
    }
    final got = c.fetched - before;

    // ★ 断言用"**两次渲染对比**"而不是颜色丰富度启发式：
    //   有封面 vs 没封面（把 covers 置空 → 全走占位卡），数封面列里的差异像素。
    //   颜色那种判据会被"彩色书名 / 徽标"骗过 —— 第 17 轮实测里晋江明明没有
    //   封面也被判成"有"。两次渲染对比是自校准的，不依赖任何阈值假设。
    final withCovers = bgraToPng(renderBgra(mw.onPaint, w, h), w, h);
    final saved = mw.covers;
    mw.covers = null; // 关掉封面 → 全部画占位卡
    final noCovers = bgraToPng(renderBgra(mw.onPaint, w, h), w, h);
    mw.covers = saved;

    final a = decodePngBytes(withCovers)!;
    final b = decodePngBytes(noCovers)!;
    final diff = diffInCoverColumn(a.bgra, b.bgra, a.width);

    final ok = diff > 800;
    anyOk = anyOk || ok;
    final label = '${t.board}${t.category == null ? '' : '·${t.category}'}';
    stdout.writeln('[${src.padRight(7)}] $label  ${t.count} 条  '
        '新取 $got 张  封面列差异 $diff 像素  '
        '${ok ? "✅ 真封面" : "— 占位卡（该平台没有封面来源）"}');
    if (ok) {
      File('${dir.path}/11_真实数据封面_$src.png')
          .writeAsBytesSync(withCovers);
    }
  }

  stdout.writeln('');
  stdout.writeln(anyOk
      ? '[OK]   至少一个平台能出真封面'
      : '[FAIL] 一个封面都没出来');
  exitCode = anyOk ? 0 : 1;
}

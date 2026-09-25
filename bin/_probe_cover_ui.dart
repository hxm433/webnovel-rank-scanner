/// 端到端验证「封面 + 每本书链接」：造一份**带 cover_url 的快照**，
/// 预先把真图塞进封面缓存目录，然后离屏渲染主窗。
///
/// ★ 为什么不走网络：这一节要证明的是"缓存 → 解码 → 贴到表格里"这条链路，
///   网络那一段由 `_probe_wic.dart` 单独验。分开验，失败时才知道坏在哪一段。
///
/// 运行：
///   dart run bin/_probe_cover_ui.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/png.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '_render_shots.dart' show renderBgra;

/// 一个真实存在的起点封面（已下载到 build/_covtest/qd.jpg）。
const String _realCover =
    'https://bookcover.yuewen.com/qdbimg/349573/1040765595/150';

Future<void> main() async {
  final root = Directory('build/_coverui')..createSync(recursive: true);
  final outRoot = root.path;
  final snapDir = Directory('$outRoot${Platform.pathSeparator}扫榜'
      '${Platform.pathSeparator}qidian');
  snapDir.createSync(recursive: true);

  // ── 1. 造一份快照：一半有封面、一半没有（验证"没图也不塌"）──
  final entries = <Map<String, Object?>>[];
  for (var i = 1; i <= 12; i++) {
    entries.add({
      'rank': i,
      'title': '样例书名$i',
      'author': '作者$i',
      'book_id': '104076559$i',
      'category': '玄幻',
      'url': 'https://book.qidian.com/info/104076559$i/',
      // 前 8 条有封面，后 4 条没有 → 占位卡与真图混排，看宽度是否一致
      if (i <= 8) 'cover_url': _realCover,
      'metrics': {'yuepiao': 100000 - i * 1000},
    });
  }
  // ★ 快照文件的最外层是 `{"result": …}` 包一层（见 lib/store.dart 的
  //   RankSnapshot.toJson）—— 少了它会被判"缺 result 字段"直接跳过。
  final snap = {
   'result': {
    'query': {
      'source': 'qidian',
      'board': '月票榜',
      'limit': 12,
      'category_name': null,
      'category_id': null,
    },
    'entries': entries,
    'fetched_at': DateTime(2026, 9, 25, 12).toIso8601String(),
   },
  };
  File('${snapDir.path}${Platform.pathSeparator}月票榜_20260925.json')
      .writeAsStringSync(jsonEncode(snap));

  // ── 2. 预置封面缓存：把真图按 bookId 放进 _covers/qidian/ ──
  final cacheDir = Directory('$outRoot${Platform.pathSeparator}扫榜'
      '${Platform.pathSeparator}_covers${Platform.pathSeparator}qidian')
    ..createSync(recursive: true);
  final jpg = File('build/_covtest/qd.jpg');
  if (!jpg.existsSync()) {
    stderr.writeln('缺少 build/_covtest/qd.jpg —— 先跑 _probe_wic.dart');
    exitCode = 2;
    return;
  }
  final bytes = jpg.readAsBytesSync();
  for (var i = 1; i <= 8; i++) {
    File('${cacheDir.path}${Platform.pathSeparator}104076559$i.img')
        .writeAsBytesSync(bytes);
  }

  // ── 3. 渲染 ──
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: outRoot);
  Palette.apply(AppTheme.dark);
  mw.reload();
  stdout.writeln('载入错误: ${mw.loadErrors}');
  stdout.writeln('快照数: ${mw.vm?.all.length}  选中: ${mw.currentMeta()?.id}');
  // ★ 用**宽窗口**出图：基准窗（1240×800）下 8 列放不下，
  //   「链接」列会被挤到视口外 —— 而这张图正是要展示"封面 + 可点开的书链接"。
  //   宽窗下 8 列全放得下，封面与「打开」按钮同框。
  const w = 2400, h = 1400;
  mw.testSetSize(w, h);

  // ★ 先画一帧把"可见行"喂给封面队列，再排空它 —— 离线渲染没有事件循环，
  //   定时器不会跑，不排空的话永远只画占位卡。
  final warm = renderBgra(mw.onPaint, w, h);
  final drained = await mw.drainCoversForTest();
  stdout.writeln('封面队列排空 $drained 次，'
      '已取 ${mw.covers?.fetched} 张 / 失败 ${mw.covers?.failed}');

  final bgra = renderBgra(mw.onPaint, w, h);
  assert(warm.isNotEmpty);
  final png = bgraToPng(bgra, w, h);
  final dir = Directory('build/shots')..createSync(recursive: true);
  File('${dir.path}/10_封面与链接.png').writeAsBytesSync(png);
  stdout.writeln('已渲染 build/shots/10_封面与链接.png（${w}x$h，'
      '${(png.length / 1024).toStringAsFixed(0)} KB）');

  // ── 4. 断言：封面格真的画出了"非底色"的像素 ──
  //    真图（夜无疆封面）是暖色调，跟占位卡明显不同。
  //
  // ★ 取样窗口**从实际布局算**，不写死坐标 —— 整表放大 1.5 倍时
  //   rank 列 44→66、封面列 52→78，写死的窗口会量到"# 列"上去，
  //   然后得出"一个封面都没有"的假结论（这个坑踩过一次）。
  final img = decodePngBytes(png)!;
  int rgbAt(int x, int y) {
    final o = (y * img.width + x) * 4;
    return (img.bgra[o + 2] << 16) | (img.bgra[o + 1] << 8) | img.bgra[o];
  }

  final area = mw.testDetailArea;
  final u = Metrics.factor;
  final s = mw.testDetailScale; // ★ 自适应缩放，不是写死的 1.5
  final rankW = (44 * u * s).round();
  final coverW = (52 * u * s).round();
  final x0 = (area?.left ?? 270) + rankW + 6;
  final x1 = (area?.left ?? 270) + rankW + coverW - 6;
  final y0 = (area?.top ?? 330) + mw.testDetailHeaderHeight + 6;
  final y1 = (area?.bottom ?? 760) - 14;

  var colored = 0;
  for (var y = y0; y < y1; y += 3) {
    for (var x = x0; x < x1; x += 2) {
      final c = rgbAt(x, y);
      final r = (c >> 16) & 0xFF, gg = (c >> 8) & 0xFF, b = c & 0xFF;
      // "暖色"= R 明显大于 B（夜无疆封面是暖橙调）
      if (r > b + 25) colored++;
    }
  }
  stdout.writeln('封面列取样窗口 x=[$x0,$x1) y=[$y0,$y1)');
  stdout.writeln('封面区域暖色像素 = $colored'
      '（真图应 >200；全占位卡会接近 0）');
  stdout.writeln(colored > 200
      ? '[OK]   真封面确实画进表格了'
      : '[FAIL] 没看到真封面的像素');
  exitCode = colored > 200 ? 0 : 1;
}

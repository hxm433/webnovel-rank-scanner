/// 诊断：「榜单明细」整表放大 1.5 倍之后的**版面账**。
///
/// 运行：dart run bin/_probe_detail_layout.dart [outRoot]
///
/// 输出的是可复算的数（列宽 / 可见区间 / 溢出了多少），
/// 不是"看着差不多" —— 判断"有没有被挤出屏幕"必须靠坐标，不能靠看图
/// （截图一缩小，视觉判断就会出错，这个坑踩过）。
library;

import 'dart:io';

import '../lib/png.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '_render_shots.dart' show renderBgra;

/// COLORREF（`0x00BBGGRR`）→ 渲染像素的 `0xRRGGBB`。
///
/// ★ 这两个字节序**不一样**：`Palette.xxx` 是 COLORREF，而 DIB 里读出来的
///   像素是 RGB。直接拿 Palette 的值比像素永远不相等（踩过）。
int _refToRgb(int c) =>
    ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF);

/// 在 [y] 这一行上数"等于 [rgb] 的像素"个数。
int _countInRow(List<int> bgra, int width, int y, int x0, int x1, int rgb) {
  var n = 0;
  for (var x = x0; x < x1; x++) {
    final o = (y * width + x) * 4;
    final c = (bgra[o + 2] << 16) | (bgra[o + 1] << 8) | bgra[o];
    if (c == rgb) n++;
  }
  return n;
}

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'out';
  var w = 1240, h = 800;
  String? shotPath;
  for (final a in args) {
    if (a.startsWith('--size=')) {
      final p = a.substring(7).split('x');
      if (p.length == 2) {
        w = int.tryParse(p[0]) ?? w;
        h = int.tryParse(p[1]) ?? h;
      }
    } else if (a.startsWith('--shot=')) {
      shotPath = a.substring(7);
    }
  }
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();
  mw.testSetSize(w, h);
  final px0 = renderBgra(mw.onPaint, w, h);
  if (shotPath != null) {
    File(shotPath).writeAsBytesSync(bgraToPng(px0, w, h));
    stdout.writeln('已写截图 $shotPath（${w}x$h）\n');
  }

  final area = mw.testDetailArea;
  final natural = mw.testDetailNaturalWidth;
  final u = Metrics.factor;

  stdout.writeln('== 明细表版面账 ==');
  stdout.writeln('窗口           $w x $h');
  final ds = mw.testDetailScale;
  stdout.writeln('缩放 factor    $u');
  stdout.writeln('明细缩放       ${ds.toStringAsFixed(3)}'
      '（上限 ${Metrics.detailScale}；自适应：放得下就用满，放不下就等比缩）');
  stdout.writeln('行高 / 表头高  ${mw.testDetailRowHeight} / ${mw.testDetailHeaderHeight}');
  stdout.writeln('正文字号       ${mw.testDetailFontSize}');
  stdout.writeln('封面           ${mw.testCoverWidth}x${mw.testCoverHeight}'
      '（解码 ${Metrics.coverDecodeW}x${Metrics.coverDecodeH}）');
  stdout.writeln('自然总宽       $natural');
  stdout.writeln('可见区         $area');
  if (area != null) {
    final maxX = natural - area.width;
    stdout.writeln('横向溢出       $maxX px'
        '（占全表 ${(maxX * 100 / natural).toStringAsFixed(0)}%）');
    stdout.writeln('纵向上限       ${mw.testDetailMaxScroll}');
    stdout.writeln('横向滚动条     ${mw.testDetailHScrollRect}');
    // ★ 这一组是"右侧有没有空缺"的判据。
    //   放得下时**实画宽必须等于可见宽** —— 否则右边就会空一块，
    //   而 stretch 列（备注）还停在基准宽、文字被截断。
    final drawnW = mw.testDetailDrawnWidth;
    final fits = natural <= area.width;
    final vBar = (11 * Metrics.factor).round();
    stdout.writeln('画法           ${fits ? "撑满可用区（无横向滚动）" : "按自然总宽（横向滚动）"}');
    stdout.writeln('实画宽         $drawnW  ${fits ? (drawnW == area.width ? "✅ 撑满（右侧无空缺）" : "❌ 没撑满，右侧空 ${area.width - drawnW} px") : "（放不下，按自然宽）"}');
    // 内容真正画到的右缘：drawTable 内部会再让开纵向滚动条一格。
    // ★ 只在"放得下"时才有"贴齐"可言；放不下时内容本来就该溢出到视口外。
    final contentRight =
        area.left + drawnW - (mw.testDetailMaxScroll > 0 ? vBar : 0);
    final expectRight =
        area.right - (mw.testDetailMaxScroll > 0 ? vBar : 0);
    if (fits) {
      stdout.writeln('内容右缘       $contentRight（期望 $expectRight）'
          '  ${contentRight == expectRight ? "✅ 贴齐" : "⚠️ 差 ${expectRight - contentRight} px"}');
    } else {
      stdout.writeln('内容右缘       $contentRight（放不下，溢出到视口外属正常；'
          '往右滚 ${natural - area.width} px 才能看全）');
    }

    // ── 量像素：行高到底是不是 90 ──
    //
    // ★ 常量写对了不等于**画出来**就是那个数（布局里可能用了别的行高）。
    //   每一行的底边都有一条 `Palette.lineFaint` 分隔线，横贯整行 ——
    //   量相邻两条线的距离，就是渲染出来的真实行高。
    final px = renderBgra(mw.onPaint, w, h);
    final lineRgb = _refToRgb(Palette.lineFaint);
    final x0 = area.left + 4;
    final x1 = area.left + area.width - 60; // 让开右侧纵向滚动条
    final span = x1 - x0;
    final lines = <int>[];
    for (var y = area.top + 2; y < area.bottom - 2; y++) {
      if (_countInRow(px, w, y, x0, x1, lineRgb) > span * 0.9) lines.add(y);
    }
    stdout.writeln('\n-- 量像素：行分隔线 --');
    stdout.writeln('扫描宽度       $span px（x=$x0..$x1）');
    stdout.writeln('分隔线 y 坐标  $lines');
    if (lines.length >= 2) {
      final pitches = <int>[];
      for (var i = 1; i < lines.length; i++) {
        pitches.add(lines[i] - lines[i - 1]);
      }
      stdout.writeln('相邻间距       $pitches');
      final ok = pitches.every((p) => p == mw.testDetailRowHeight);
      stdout.writeln('渲染出来的行高 = ${pitches.first}'
          '（期望 ${mw.testDetailRowHeight}）  ${ok ? "✅ 一致" : "❌ 不一致"}');
      final rowsVisible = lines.length;
      stdout.writeln('一屏可见行数   ≈ $rowsVisible');
    } else {
      stdout.writeln('❌ 没找到分隔线 —— 判据失效，得换个量法');
    }

    // 各列在两种偏移下的可见区间 —— 这是"哪一列被挤出屏幕"的唯一可靠判据。
    const cols = <(String, int)>[
      ('#', 44),
      ('封面', 52),
      ('书名', 220),
      ('作者', 104),
      ('题材', 88),
      ('指标', 190),
      ('备注', 150),
      ('链接', 62),
    ];
    for (final x in [0, maxX < 0 ? 0 : maxX]) {
      stdout.writeln('\n-- scrollX = $x 时各列可见情况 --');
      var left = area.left - x;
      for (final (name, bw) in cols) {
        final cw = (bw * u * ds).round();
        final l = left, r = left + cw;
        final visL = l < area.left ? area.left : l;
        final visR = r > area.right ? area.right : r;
        final vis = visR - visL;
        final tag = vis <= 0
            ? '❌ 完全看不见'
            : (vis < cw ? '⚠️ 只露 $vis/${cw}px' : '✅ 完整可见');
        stdout.writeln('  ${name.padRight(4)} x=[${l.toString().padLeft(5)},'
            '${r.toString().padLeft(5)}]  宽 $cw  $tag');
        left = r;
      }
    }
  }
}

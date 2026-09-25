/// 一次性探针：量出三个窗口按钮（最小化 / 最大化-还原 / 关闭）的**图标墨迹包围盒**。
///
/// 为什么需要它：用户报了两件事 ——
///   ① 浅色主题下"关闭叉看不见"；
///   ② 图标错位（深浅都有）。
/// 这两条都只能靠**量像素**确认，靠看图猜会把"圆角/描边"误当成图标。
///
/// 运行：dart run bin/_probe_titlebar.dart [outRoot]
library;

import 'dart:io';

import '../lib/png.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/widgets.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'out';
  const w = 1240;
  const h = 200;

  for (final theme in AppTheme.values) {
    Palette.apply(theme);
    final mw = MainWindow(outRoot: root);
    Palette.apply(theme);
    mw.reload();
    mw.testSetSize(w, h);
    final buf = BackBuffer(w, h);
    mw.onPaint(buf.gdi);
    final png = bgraToPng(buf.readBgra(), w, h);
    buf.dispose();
    final img = decodePngBytes(png);
    if (img == null) {
      stderr.writeln('解码失败');
      exit(1);
    }

    int rgbAt(int x, int y) {
      final o = (y * img.width + x) * 4;
      return (img.bgra[o + 2] << 16) | (img.bgra[o + 1] << 8) | img.bgra[o];
    }

    int rgbOf(int cr) =>
        ((cr & 0xFF) << 16) | (cr & 0xFF00) | ((cr >> 16) & 0xFF);

    // 顶栏底色（非客户区之外的部分）—— 直接读 Palette，别写死。
    final header = rgbOf(Palette.headerBg);
    stdout.writeln('\n=== ${theme.label} ===  header=#'
        '${header.toRadixString(16).padLeft(6, '0')}');

    const labels = ['最小化', '最大化/还原', '关闭'];
    final bw = Metrics.winBtnW;
    final inset = Metrics.winBtnInset;
    for (var i = 0; i < 3; i++) {
      final x0 = w - inset - bw * (3 - i);
      final x1 = x0 + bw;
      var minX = 9999, maxX = -1, minY = 9999, maxY = -1, ink = 0;
      for (var y = 0; y < Metrics.winBtnH; y++) {
        for (var x = x0; x < x1; x++) {
          if (rgbAt(x, y) == header) continue;
          ink++;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
      final cy = (Metrics.winBtnH ~/ 2);
      if (ink == 0) {
        stdout.writeln('  ${labels[i].padRight(12)} 按钮 [$x0,$x1)  '
            '**没有任何墨迹**（图标不可见）');
        continue;
      }
      final midY = (minY + maxY) / 2;
      stdout.writeln('  ${labels[i].padRight(12)} 按钮 [$x0,$x1)  '
          '墨迹 $ink px  包围盒 x=[$minX,$maxX] y=[$minY,$maxY]  '
          '中心 y=${midY.toStringAsFixed(1)}（按钮中线 $cy，偏差 '
          '${(midY - cy).toStringAsFixed(1)}）');
    }
  }
}

/// 回归测试 —— 锁住**只有真窗口才暴露**的两个 bug。
///
/// 这两个都不是 Dart 逻辑错，离屏渲染与单元测试**全都测不出来**：
///
///  ① **双缓冲位图退化成单色**：`CreateCompatibleBitmap(CreateCompatibleDC(0))`
///     可能建出 1bpp 位图 → 整个窗口只剩纯黑/纯白，字几乎看不见。
///     离屏渲染走的是 `CreateDIBSection`，永远正常 —— 所以只有真窗才复现。
///
///  ② **启动不自动载入数据**：`reload()` 只在点按钮时调，于是开窗后左侧永远
///     "正在读取快照…"、右侧永远"没有可显示的数据"。
///
/// 这个脚本起真窗、真消息循环，然后把 `BackBuffer` 的像素**直接读出来**判定，
/// 不依赖截屏权限。
library;

import 'dart:async';
import 'dart:io';

import '../lib/ui/app.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';

int _pass = 0, _fail = 0;
void ok(String s) {
  _pass++;
  print('  [OK]   $s');
}

void bad(String s) {
  _fail++;
  print('  [FAIL] $s');
}

void check(bool c, String s) => c ? ok(s) : bad(s);

Future<void> main() async {
  print('=== 真窗口回归：位图保真 + 启动载数据 ===\n');

  final win = MainWindow(outRoot: 'out');
  final app = App();
  final done = app.run(win, width: 1240, height: 800);

  await Future<void>.delayed(const Duration(milliseconds: 1000));

  print('[1] 启动是否自动载入数据');
  check(win.vm != null, 'vm 已建立');
  check((win.vm?.snapshotCount ?? 0) > 0,
      '载入快照 —— ${win.vm?.snapshotCount} 份 / ${win.vm?.recordCount} 条');
  check((win.vm?.recordCount ?? 0) > 0, '记录数 > 0');
  check(win.loadErrors.isEmpty, '解析零错误');

  print('\n[2] 双缓冲必须是 32 位彩色（不是单色）');
  final buf = BackBuffer(win.width, win.height);
  try {
    win.onPaint(buf.gdi);
    final px = buf.readBgra();

    // 统计不同颜色数量。单色位图只有 2 种颜色（纯黑/纯白）。
    final seen = <int>{};
    for (var i = 0; i + 3 < px.length; i += 4) {
      // BGRA → 打包成 int（丢掉 alpha，不参与比较）
      final c = (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
      seen.add(c);
    }
    print('       不同颜色数 = ${seen.length}');
    check(seen.length > 12, '颜色丰富（>12）—— 不是单色位图');
    check(!(seen.length == 2), '不是"只有纯黑+纯白"的单色退化');

    // 关键色必须真的画上去了。
    // ★ 断言值从 [Palette] 现取，不写死十六进制 —— 否则一改配色测试就假失败
    //   （本轮现代化改版就踩了这个：底色从 #171a21 变成 #0f1116）。
    //
    // 注意两处通道序，很容易搞反：
    //   Palette 里存的是 **COLORREF（0x00BBGGRR）**
    //   而从 DIB 读出来的像素是 **BGRA**，我在这里拼成 **0xRRGGBB**
    // 所以两边都要转成 0xRRGGBB 才能比较。
    int hexOf(int colorref) {
      final r = colorref & 0xFF;
      final g = (colorref >> 8) & 0xFF;
      final b = (colorref >> 16) & 0xFF;
      return (r << 16) | (g << 8) | b;
    }

    int at(int x, int y) {
      final o = (y * win.width + x) * 4;
      return (px[o + 2] << 16) | (px[o + 1] << 8) | px[o]; // RGB
    }

    final header = at(2, 2);
    final wantHeader = hexOf(Palette.headerBg);
    check(header == wantHeader,
        '顶栏底色 = 主题色 #${wantHeader.toRadixString(16)}（实际 #${header.toRadixString(16)}）');

    // 内容区：左侧栏或卡片区的深色都算对（版面会随缩放变，别钉死某个坐标）
    final contentTop = at(win.width ~/ 2, 56);
    final deepColors = {
      hexOf(Palette.bg),
      hexOf(Palette.sidebar),
      hexOf(Palette.surface),
      hexOf(Palette.surfaceAlt),
      hexOf(Palette.headerBg),
    };
    check(deepColors.contains(contentTop),
        '内容区底色是主题深色（实际 #${contentTop.toRadixString(16)}）');

    // 顶栏一定有亮色文字（纯黑位图会给 0 或 0xffffff）
    var bright = 0;
    for (var y = 8; y < 44; y++) {
      for (var x = 14; x < 220; x++) {
        final c = at(x, y);
        final r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
        if (r + g + b > 300) bright++;
      }
    }
    print('       顶栏标题区亮像素 = $bright');
    check(bright > 60, '顶栏标题文字已绘制（亮像素 >60）');
  } finally {
    buf.dispose();
  }

  print('\n[3] 窗口客户区尺寸正确');
  check(win.width >= 1200 && win.height >= 760,
      '客户区 ${win.width}x${win.height}（请求 1240x800）');

  print('\n=== 结果: $_pass 通过 / $_fail 失败 ===');

  app.quit();
  await done.timeout(const Duration(seconds: 3), onTimeout: () {});
  exit(_fail == 0 ? 0 : 1);
}

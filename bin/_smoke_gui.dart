/// 窗口基座的接线自检：建一个最小窗口，画点东西，3 秒后自动退出。
///
/// 这不是给用户用的界面，是**基座的冒烟测试** —— 验证 win32/gdi/app
/// 三层能在真实项目里编译并跑通，再往上堆控件。
library;

import 'dart:async';

import 'package:ffi/ffi.dart';

import '../lib/ui/app.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/win32.dart';

class _SmokeWindow extends AppWindow {
  @override
  String get title => 'GUI 基座自检';

  @override
  void onPaint(Gdi g) {
    final bg = rgb(246, 247, 249);
    g.fill(Rc.xywh(0, 0, width, height), bg);

    // 顶栏
    g.fill(Rc.xywh(0, 0, width, 48), rgb(255, 255, 255));
    g.line(0, 48, width, 48, rgb(224, 227, 232));
    g.text('扫榜工具 · GUI 基座自检', Rc.xywh(16, 0, 400, 48), rgb(24, 28, 36),
        size: 16, bold: true);

    // 一张卡片
    final card = Rc.xywh(20, 70, 320, 90);
    g.roundFill(card, rgb(255, 255, 255), rgb(226, 230, 236));
    g.text('窗口尺寸', Rc.xywh(card.left + 14, card.top + 8, 200, 22),
        rgb(120, 130, 145), size: 12);
    g.text('$width × $height', Rc.xywh(card.left + 14, card.top + 30, 280, 30),
        rgb(24, 28, 36), size: 22, bold: true);
    g.text('鼠标 ($mouseX, $mouseY)', Rc.xywh(card.left + 14, card.top + 60, 280, 20),
        rgb(90, 100, 115), size: 12);

    // 一个按钮样式的块
    final btn = Rc.xywh(360, 88, 130, 38);
    final hot = btn.contains(mouseX, mouseY);
    g.roundFill(btn, hot ? rgb(230, 242, 255) : rgb(255, 255, 255),
        hot ? rgb(90, 160, 250) : rgb(210, 216, 224));
    g.text('单 exe 可打包', btn, rgb(30, 90, 180), size: 14, align: dtCenter);

    // 状态栏
    g.fill(Rc.xywh(0, height - 26, width, height), rgb(240, 242, 245));
    g.text('ffi 绑定 OK · GDI 绘制 OK · 消息循环 OK · 3 秒后自动退出',
        Rc.xywh(12, height - 26, width - 24, 26), rgb(100, 110, 125), size: 12);
  }

  @override
  void onMove(int x, int y) => invalidate();
}

Future<void> main() async {
  if (!platformSupportsGui) {
    print('这个自检只能在 Windows 上跑');
    return;
  }
  final app = App(className: 'RankScanSmoke');
  final win = _SmokeWindow();
  Timer(const Duration(seconds: 3), () => app.quit());
  await app.run(win, width: 620, height: 380);
  print('基座自检完成，窗口已干净退出');
}

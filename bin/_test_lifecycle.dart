/// 验证「关掉子窗口不再退出整个程序」。
///
/// 这是"点扫榜自动退出"的根因回归测试：窗口过程以前在**任何**窗口
/// 销毁时都调 postQuitMessage，而 postQuitMessage 是"结束整个线程的
/// 消息循环"，不分是哪个窗口 —— 所以子窗一关，主窗也一起没了。
library;

import 'dart:async';
import 'dart:io';

import '../lib/ui/app.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/win32.dart';

int _pass = 0, _fail = 0;
void _check(String what, bool ok, [String extra = '']) {
  if (ok) {
    _pass++;
    print('  [OK]   $what${extra.isEmpty ? '' : ' — $extra'}');
  } else {
    _fail++;
    print('  [FAIL] $what${extra.isEmpty ? '' : ' — $extra'}');
  }
}

/// 一个最小窗口：只画个底色，用来验证生命周期。
class Probe extends AppWindow {
  Probe(this.name);
  final String name;
  bool destroyed = false;
  @override
  String get title => 'probe-$name';
  @override
  void onPaint(Gdi g) => g.fill(Rc.xywh(0, 0, width, height), rgb(240, 240, 245));
  @override
  void onDestroyed() {
    destroyed = true;
    print('    [$name] onDestroyed 触发');
  }
}

void main() async {
  print('=== 多窗口生命周期回归 ===\n');

  final app = App(className: 'RankScanLifecycleProbe');
  final mainWin = Probe('main');

  // 起主窗，消息循环在后台跑
  final appDone = app.run(mainWin, width: 400, height: 300);
  var appExited = false;
  unawaited(appDone.then((_) {
    appExited = true;
  }));

  await Future<void>.delayed(const Duration(milliseconds: 400));
  _check('主窗已建立', mainWin.hwnd != 0, 'hwnd=${mainWin.hwnd}');
  _check('消息循环运行中（未退出）', !appExited);

  // 开子窗
  print('\n[1] 开子窗');
  final child = Probe('child');
  app.runChild(child, width: 300, height: 200);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  _check('子窗已建立', child.hwnd != 0, 'hwnd=${child.hwnd}');
  _check('子窗未销毁', !child.destroyed);

  // ★ 关键：销毁子窗 —— 修复前这里会把整个程序带走
  print('\n[2] 销毁子窗（修复前这一步会让程序整体退出）');
  destroyWindow(child.hwnd);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  _check('子窗已销毁', child.destroyed);
  _check('★ 主窗仍然存活', !mainWin.destroyed);
  _check('★ 程序没有退出', !appExited,
      appExited ? '【程序被误退出 —— 根因未修复！】' : '');

  // 子窗没了，主窗应该还能画
  print('\n[3] 子窗销毁后主窗仍能重绘');
  final buf = BackBuffer(mainWin.width, mainWin.height);
  mainWin.onPaint(buf.gdi);
  buf.dispose();
  _check('主窗重绘成功', true);
  _check('主窗句柄仍有效', mainWin.hwnd != 0);

  // 最后关主窗 —— 这时才该退出
  print('\n[4] 关掉主窗（这时才应该退出）');
  destroyWindow(mainWin.hwnd);
  await Future<void>.delayed(const Duration(milliseconds: 800));
  _check('主窗已销毁', mainWin.destroyed);
  _check('★ 程序正常退出', appExited);

  print('\n=== 结果: $_pass 通过 / $_fail 失败 ===');
  exit(_fail == 0 ? 0 : 1);
}

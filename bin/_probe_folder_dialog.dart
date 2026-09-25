/// 文件夹选择框**真的弹出来了吗**？
///
/// ★ 为什么必须真弹一次：`_t_com_folder.dart` 只验了"函数可引用"，
///   从没验过"框能不能起来"。而用户报"导出根本无法使用"，
///   最可疑的就是这一步 —— 导出流程里唯一的系统对话框。
///
/// 做法：主 isolate 调 [pickFolderDialog]（它是**模态**的，会阻塞主线程），
/// 另起一个 isolate 睡 2 秒后给前台窗口发 WM_CLOSE。
///   - 调用耗时 ≥1.5 秒 → 框真的起来了（阻塞过）✅
///   - 耗时≈0 → 框压根没出现 ❌
///
/// 运行：dart run bin/_probe_folder_dialog.dart
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:io';

import '../lib/ui/win32.dart';

void _closer(SendPort _) {
  // 用同步 sleep：这个 isolate 只需要"到点发一条消息"
  sleep(const Duration(milliseconds: 2500));
  try {
    final fg = getForegroundWindow();
    if (fg != 0) {
      postMessageW(fg, wmClose, 0, 0);
    }
  } on Object {
    // 拿不到就算了，主线程那边会超时
  }
}

Future<void> main() async {
  stdout.writeln('=== 文件夹选择框可用性 ===');
  stdout.writeln('COM 初始化：${ensureComInitialized()}');

  stdout.writeln('spawn 关闭器…');
  final rp = ReceivePort();
  await Isolate.spawn(_closer, rp.sendPort);
  stdout.writeln('关闭器已起，准备弹框…');

  final sw = Stopwatch()..start();
  String? picked;
  Object? err;
  try {
    // ★ 给一个"上次目录"：目录框应当从它打开；这里用当前目录。
    picked = pickFolderDialog(0,
        title: '探针：随便点一下「选择文件夹」或直接关掉', initialDir: Directory.current.path);
  } on Object catch (e) {
    err = e;
  }
  sw.stop();

  final ms = sw.elapsedMilliseconds;
  stdout.writeln('调用耗时 ${ms}ms，返回 ${picked == null ? "null（取消/失败）" : picked}');
  if (err != null) stdout.writeln('异常：$err');
  if (ms >= 1500) {
    stdout.writeln('[OK] 文件夹框**确实弹出来了**（阻塞了 ${ms}ms，被 WM_CLOSE 关掉）');
  } else {
    stdout.writeln('[FAIL] 文件夹框**没有弹出来**（${ms}ms 就返回了）—— '
        '用户看到的"选任何文件夹都没用"就是这个');
    exitCode = 1;
  }
}

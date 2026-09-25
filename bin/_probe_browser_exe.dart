/// 看注册表解出来的默认浏览器 exe，以及"找浏览器窗口"现在挑到哪个窗口。
library;

import 'dart:io';

import '../lib/ui/win32.dart';

void main() {
  stdout.writeln('defaultBrowserExe() = ${defaultBrowserExe()}');
  final h = findBrowserWindow();
  stdout.writeln('findBrowserWindow() = $h');
  if (h != 0) {
    final (cls, title) = windowClassAndTitle(h);
    stdout.writeln('  类名 = $cls');
    stdout.writeln('  标题 = $title');
    stdout.writeln('  进程 = ${processNameOfWindow(h)}');
    stdout.writeln('  isBlankBrowserTitle = ${isBlankBrowserTitle(title)}');
  }
  stdout.writeln('空标题算空白页吗：${isBlankBrowserTitle('')}');
}

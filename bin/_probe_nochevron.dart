/// 一次性探针：渲染"搜索=番茄"的设置窗，肉眼确认**没有题材的榜不画折叠箭头**。
library;
import 'dart:io';
import '../lib/png.dart';
import '../lib/ui/dialogs.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'build/fixture_out';
  final dir = Directory('build/shots')..createSync(recursive: true);
  for (final theme in AppTheme.values) {
    Palette.apply(theme);
    final dlg = ScanDialogWindow(owner: MainWindow(outRoot: root));
    Palette.apply(theme);
    const w = 1040, h = 720;
    dlg.testSetSize(w, h);
    dlg.search = '番茄';
    final buf = BackBuffer(w, h);
    dlg.onPaint(buf.gdi);
    final png = bgraToPng(buf.readBgra(), w, h);
    buf.dispose();
    final suffix = theme == AppTheme.dark ? '' : '_浅色';
    File('${dir.path}/9_无题材榜不画箭头$suffix.png').writeAsBytesSync(png);
    stdout.writeln('9_无题材榜不画箭头$suffix.png  ${w}x$h');
  }
}

/// 编译冒烟：把主窗口整条链路拉起来（只编译，不开窗）。
library;

import '../lib/ui/main_window.dart';
import '../lib/ui/dialogs.dart';

void main() {
  print('main_window + dialogs 编译通过');
  print('MainWindow idSeriesTable=${MainWindow.idSeriesTable}');
}

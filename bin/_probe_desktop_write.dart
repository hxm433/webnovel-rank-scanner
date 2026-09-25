/// 复现"导出榜单图到桌面 → errno = 5 拒绝访问"。
///
/// 运行：dart run bin/_probe_desktop_write.dart [目录]
library;

import 'dart:io';

void main(List<String> args) {
  final dir = args.isNotEmpty ? args[0] : 'C:\\Users\\hxm\\Desktop';
  stdout.writeln('目标目录 = $dir');
  final d = Directory(dir);
  stdout.writeln('存在 = ${d.existsSync()}');

  // ① 普通小文件
  try {
    final f = File('$dir${Platform.pathSeparator}_probe_plain.txt');
    f.writeAsStringSync('hello', flush: true);
    stdout.writeln('✅ 写文本文件成功：${f.path}（${f.lengthSync()} 字节）');
    f.deleteSync();
  } on Object catch (e) {
    stdout.writeln('❌ 写文本文件失败：$e');
  }

  // ② 用榜单图那个文件名（中文 + 下划线 + 数字）
  const name = '榜单_起点_新人作者新书榜_全站_20260925.png';
  final p = '$dir${Platform.pathSeparator}$name';
  stdout.writeln('目标文件 = $p');
  stdout.writeln('文件名长度（字符）= ${name.length}，全路径长度 = ${p.length}');
  stdout.writeln('已存在 = ${File(p).existsSync()}');
  try {
    // 写一小段假 PNG 头，验证"能不能在这个路径上创建文件"
    File(p).writeAsBytesSync(List<int>.filled(64, 0), flush: true);
    stdout.writeln('✅ 写 PNG 文件成功（${File(p).lengthSync()} 字节）');
    File(p).deleteSync();
    stdout.writeln('   （已清理测试文件）');
  } on Object catch (e) {
    stdout.writeln('❌ 写 PNG 文件失败：$e');
  }

  // ③ 列出目录里所有 榜单_* 文件（可能是残留的只读/占用文件）
  stdout.writeln('\n目录里已有的「榜单」相关文件：');
  var n = 0;
  for (final e in d.listSync()) {
    final base = e.path.split(Platform.pathSeparator).last;
    if (base.contains('榜单')) {
      n++;
      final st = e.statSync();
      stdout.writeln('  $base  ${st.size} 字节  mode=${st.mode}');
    }
  }
  if (n == 0) stdout.writeln('  （没有）');
}

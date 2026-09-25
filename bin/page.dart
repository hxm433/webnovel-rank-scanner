/// 生成**单文件网页**：把快照与分析结果直接内嵌进 HTML，双击即看，不需要起服务。
///
/// 用法：
///   dart run bin/page.dart              # 生成 榜单页.html
///   dart run bin/page.dart --open       # 生成并用默认浏览器打开
///   dart run bin/page.dart --out out --name 榜单页.html
library;

import 'dart:convert';
import 'dart:io';

import '../lib/report_data.dart';
import '../lib/snapshot_index.dart';

Future<void> main(List<String> argv) async {
  var root = 'out';
  var name = '榜单页.html';
  for (var i = 0; i < argv.length; i++) {
    if (argv[i] == '--out' && i + 1 < argv.length) root = argv[++i];
    if (argv[i] == '--name' && i + 1 < argv.length) name = argv[++i];
  }

  final errors = <String>[];
  final index = SnapshotIndex.load(root, errors: errors);
  if (index.items.isEmpty) {
    stderr.writeln('没有找到快照：$root/扫榜/**/*.json —— 先跑 dart run bin/scan.dart sweep');
    exit(1);
  }

  final tpl = File('web/page_template.html');
  if (!tpl.existsSync()) {
    stderr.writeln('缺模板 web/page_template.html');
    exit(1);
  }

  final payload = const JsonEncoder.withIndent('  ').convert(buildPayload(index, errors));
  // 内嵌进 <script type="application/json">：唯一的破坏性序列是 `</`（会提前闭合标签）。
  // 在 JSON 字符串里把它写成 `<\/` 是合法转义，解析后内容不变。
  final safe = payload.replaceAll('</', r'<\/');
  final html = tpl.readAsStringSync().replaceFirst('__DATA__', safe);

  final out = File(name)..writeAsStringSync(html, flush: true);
  final kb = (out.lengthSync() / 1024).round();
  stdout.writeln('已生成 ${out.absolute.path}');
  stdout.writeln('  ${index.items.length} 份快照 / '
      '${index.items.fold<int>(0, (a, m) => a + m.count)} 条记录 / ${kb} KB');
  if (errors.isNotEmpty) stdout.writeln('  注意：${errors.length} 个文件解析失败（已写进页面顶部）');

  if (argv.contains('--open') && Platform.isWindows) {
    try {
      await Process.start('cmd', ['/c', 'start', '', out.absolute.path]);
    } on Object {
      stdout.writeln('  （没能自动打开，请双击上面的文件）');
    }
  }
}

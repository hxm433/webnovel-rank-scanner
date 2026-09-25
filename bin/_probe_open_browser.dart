/// 直接调 `openExternal` 打开一个网址，只报告返回码；
/// "浏览器到底有没有起来"由外面的 bash 查（本机 dart 起不了子进程）。
library;

import 'dart:io';

import '../lib/ui/app.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'https://www.qimao.com/shuku/195958/';
  var rc = 0;
  final ok = openExternal(url, detail: (r) => rc = r);
  stdout.writeln('openExternal ok=$ok rc=$rc');
  await Future<void>.delayed(const Duration(seconds: 25));
  stdout.writeln('done');
}

/// 探针：封面**真的从网络取一次**（含白名单 / 落盘 / 解码）。
library;
import 'dart:io';
import '../lib/cover_store.dart';

Future<void> main() async {
  final root = Directory('build/_covnet')..createSync(recursive: true);
  final store = CoverStore(root: root.path, requestGapMs: 0);
  const url = 'https://bookcover.yuewen.com/qdbimg/349573/1040765595/150';
  stdout.writeln('白名单校验: ${isAllowedCoverHost(Uri.parse(url))}');
  stdout.writeln('非白名单域名被拒: ${!isAllowedCoverHost(Uri.parse("https://evil.example.com/x.jpg"))}');
  final img = store.peek('qidian', 'net-test-1', url);
  stdout.writeln('peek 首次返回（应为 null，异步取）: $img');
  var n = 0;
  while (store.hasWork && n < 50) { await store.pump(force: true); n++; }
  final got = store.peek('qidian', 'net-test-1', url);
  stdout.writeln('排空 $n 次 → 已取 ${store.fetched} 张 / 失败 ${store.failed}');
  stdout.writeln('解码结果: ${got == null ? "null" : "${got.width}x${got.height} ${got.bgra.length} 字节"}');
  final cached = File('${root.path}/qidian/net-test-1.img');
  stdout.writeln('落盘缓存: ${cached.existsSync() ? "${cached.lengthSync()} 字节" : "无"}');
  // 二次访问必须**不打网络**（fetched 不再增长）
  final before = store.fetched;
  final store2 = CoverStore(root: root.path, requestGapMs: 0);
  store2.peek('qidian', 'net-test-1', url);
  while (store2.hasWork) { await store2.pump(force: true); }
  stdout.writeln('二次访问走了磁盘缓存（新取 ${store2.fetched} 张，应为 0）: ${store2.fetched == 0}');
  stdout.writeln('（首次 fetched=$before）');
  exitCode = (got != null && store2.fetched == 0) ? 0 : 1;
}

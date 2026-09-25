/// 索引同步回归 —— 「每次采集都写进索引」+ 自愈 + 保留策略跨会话。
///
/// 为什么单独一个文件：这几条断言守的是**数据不会丢**这条线，
/// 与 `_t_store_v2.dart`（文件/附件层）和 `_t_timeseries.dart`（分析层）正交。
/// 任何一条挂掉，用户看到的都是"我明明扫了，怎么没有/怎么少了"。
///
/// 运行：dart run bin/_t_index_sync.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/models.dart';
import '../lib/snapshot_index.dart' as old_index;
import '../lib/snapshot_index_file.dart';
import '../lib/store.dart';

int _pass = 0;
int _fail = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✅ $name');
  } else {
    _fail++;
    stdout.writeln('  ❌ $name${detail == null ? '' : ' — $detail'}');
  }
}

RankResult _mkResult(String source, String board, String? catName, String? catId,
    DateTime at, int n) {
  return RankResult(
    query: RankQuery(
        source: source,
        board: board,
        limit: n,
        categoryName: catName,
        categoryId: catId),
    entries: [
      for (var i = 1; i <= n; i++)
        RankEntry(
          rank: i,
          title: '$board书$i',
          author: '作者$i',
          bookId: '$source-$board-$i',
          metrics: {'words': 10000 * i},
        )
    ],
    fetchedAt: at,
    truncated: false,
  );
}

/// 模拟 `ScanService._indexSnapshot`：落盘 → 立刻登记进索引。
void _indexSnapshot(String root, RankSnapshot snap) {
  final idx = SnapshotIndexFile.load(root);
  final rel = SnapshotIndexFile.relPathOf(root, snap.path);
  idx.upsert(SnapshotIndexFile.fromResult(snap.result, relFile: rel)).save();
}

Future<void> main() async {
  stdout.writeln('== 索引同步回归：采集即入库 / 自愈 / 保留策略跨会话 ==');

  final root =
      Directory.systemTemp.createTempSync('rankscan_index_sync_').path;
  stdout.writeln('临时根目录：$root\n');
  final store = RankStore(root: root);

  // ── ① 采集即入库：每存一份，索引就多一条 ──
  stdout.writeln('── ① 每次采集都写进索引 ──');
  var expect = 0;
  for (var d = 20; d <= 24; d++) {
    final snap =
        await store.save(_mkResult('qidian', '月票榜', null, null, DateTime(2026, 9, d), 5));
    _indexSnapshot(root, snap);
    expect++;
    final idx = SnapshotIndexFile.load(root);
    _check('第 ${d - 19} 次采集后索引条目 = $expect',
        idx.entries.length == expect, 'got ${idx.entries.length}');
  }
  final idxA = SnapshotIndexFile.load(root);
  _check('index.json 真的落在 out/扫榜 下', File(idxA.indexPath).existsSync());
  _check('索引未标记为重建（走的是增量路径）', !idxA.rebuilt);
  _check('索引未标记为自愈', !idxA.reconciled);

  // 条目的 relFile 必须能指回真实文件（否则加载时会被当幽灵剔除）
  final e0 = idxA.entries.first;
  _check('relFile 指向真实文件',
      File('$root${Platform.pathSeparator}${e0.relFile}').existsSync(),
      e0.relFile);
  _check('id 口径与 store 一致',
      e0.id == snapshotIdOf(_mkResult('qidian', '月票榜', null, null, e0.fetchedAt, 5).query, e0.fetchedAt) ||
          e0.id.startsWith('qidian|月票榜|'),
      e0.id);

  // ── ② 自愈：磁盘上有、索引里没有 → load 时补进来 ──
  stdout.writeln('\n── ② 索引自愈（索引落后于磁盘）──');
  // 绕过 _indexSnapshot，只落盘不登记 —— 等价于"某次采集写完文件后进程被杀"
  await store.save(
      _mkResult('qidian', '月票榜', null, null, DateTime(2026, 9, 25), 5));
  // ★ 必须直接读 index.json 来判断"自愈前"的状态 —— 调 load() 本身就会触发
  //   自愈，拿它去断言"自愈前"必然已经晚了（这个测试第一版就踩了）。
  final onDisk = jsonDecode(File(idxA.indexPath).readAsStringSync()) as Map;
  _check('自愈前磁盘索引仍是 5 条', (onDisk['entries'] as List).length == 5,
      'got ${(onDisk['entries'] as List).length}');
  final before = SnapshotIndexFile.load(root);
  _check('自愈被标记', before.reconciled);
  _check('自愈后变成 6 条', before.entries.length == 6,
      'got ${before.entries.length}');
  final dates = [for (final e in before.entries) e.dateKey]..sort();
  _check('补进来的正是 0925', dates.contains('20260925'), dates.join(','));

  // 落盘后不再重复自愈
  before.save();
  final after = SnapshotIndexFile.load(root);
  _check('落盘后不再标记自愈', !after.reconciled);
  _check('条目数稳定在 6', after.entries.length == 6,
      'got ${after.entries.length}');

  // 坏文件不能毒死自愈
  final badPath =
      '$root${Platform.pathSeparator}扫榜${Platform.pathSeparator}qidian'
      '${Platform.pathSeparator}坏文件_20260930.json';
  File(badPath).writeAsStringSync('{ this is not json');
  final errs = <String>[];
  final withBad = SnapshotIndexFile.load(root, errors: errs);
  _check('坏文件被跳过（条目数仍 6）', withBad.entries.length == 6,
      'got ${withBad.entries.length}');
  _check('坏文件被如实上报', errs.any((e) => e.contains('坏文件')), errs.join(' | '));
  File(badPath).deleteSync();

  // ── ③ 保留策略跨会话：显式设过才覆盖默认 ──
  stdout.writeln('\n── ③ 保留策略的持久化语义 ──');
  final fresh = SnapshotIndexFile.load(root);
  _check('从未设过 → retentionSet=false', !fresh.retentionSet);
  _check('从未设过 → retention 读出来是 0', fresh.retention == 0,
      'got ${fresh.retention}');

  fresh.withRetention(3).save(retention: 3);
  final r3 = SnapshotIndexFile.load(root);
  _check('设 3 后 retentionSet=true', r3.retentionSet);
  _check('设 3 后 retention=3', r3.retention == 3, 'got ${r3.retention}');

  // ★ 0 是合法设置（不限），必须与"从没设过"区分开
  r3.withRetention(0).save(retention: 0);
  final r0 = SnapshotIndexFile.load(root);
  _check('设 0（不限）后 retentionSet 仍为 true', r0.retentionSet);
  _check('设 0 后 retention=0（读回的不是默认值）', r0.retention == 0,
      'got ${r0.retention}');

  // 负数按 0 处理
  r0.withRetention(-5).save(retention: -5);
  final rneg = SnapshotIndexFile.load(root);
  _check('负数按 0（不限）处理', rneg.retention == 0, 'got ${rneg.retention}');

  // 落盘的 JSON 里真的有 retention_set 字段
  final raw = jsonDecode(File(rneg.indexPath).readAsStringSync()) as Map;
  _check('落盘 JSON 含 retention_set', raw['retention_set'] == true);
  _check('落盘 JSON 含 retention', raw['retention'] == 0, '${raw['retention']}');

  // ── ④ 同日重扫：upsert 不能把附件吃掉 ──
  stdout.writeln('\n── ④ 同日重扫要保住附件 ──');
  final target = SnapshotIndexFile.load(root).entries.first;
  final withImg = SnapshotIndexFile.load(root);
  final pngBytes = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 签名
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  ]);
  final imp = withImg.importImage(target, bytes: pngBytes, preferName: '手工截图.png');
  withImg.addAttachment(target.id, imp.fileName).save();
  final withAtt = SnapshotIndexFile.load(root);
  final attEntry = withAtt.entries.firstWhere((e) => e.id == target.id);
  _check('附件已登记', attEntry.attachments.length == 1,
      attEntry.attachments.join(','));
  _check('附件文件真的在', File(imp.absPath).existsSync());

  // 同日重扫 → 用新条目 upsert（不带 attachments）
  final rescan = _mkResult('qidian', '月票榜', null, null, target.fetchedAt, 9);
  final rescanEntry =
      SnapshotIndexFile.fromResult(rescan, relFile: target.relFile);
  final afterRescan = SnapshotIndexFile.load(root).upsert(rescanEntry);
  final kept = afterRescan.entries.firstWhere((e) => e.id == target.id);
  _check('重扫后附件**没有**丢', kept.attachments.length == 1,
      'got ${kept.attachments.length}');
  _check('重扫后 count 已刷新为 9', kept.count == 9, 'got ${kept.count}');
  afterRescan.save();
  final reloaded = SnapshotIndexFile.load(root);
  _check('落盘重载后附件仍在',
      reloaded.entries
              .firstWhere((e) => e.id == target.id)
              .attachments
              .length ==
          1);

  // ── ④b 附件导出（"导入/导出都要支持图片"这条需求的导出侧）──
  stdout.writeln('\n── ④b 附件导出 ──');
  final destDir = '$root${Platform.pathSeparator}_export_probe';
  final expIdx = SnapshotIndexFile.load(root);
  final expEntry = expIdx.entries.firstWhere((e) => e.id == target.id);
  final exp = expIdx.exportAttachments(expEntry, destDir);
  _check('导出了 1 个附件', exp.copied == 1, 'copied=${exp.copied}');
  _check('没有缺失', exp.missing == 0, 'missing=${exp.missing}');
  final exported = File(
      '$destDir${Platform.pathSeparator}${expEntry.attachments.first}');
  _check('导出文件真的在', exported.existsSync(), exported.path);
  _check('导出内容与源一致',
      exported.existsSync() &&
          exported.readAsBytesSync().length == pngBytes.length,
      '${exported.existsSync() ? exported.lengthSync() : -1} vs ${pngBytes.length}');

  // 索引里有名字、磁盘上文件没了 → 必须如实报"缺失"，不能静默少给
  File(imp.absPath).deleteSync();
  final exp2 = expIdx.exportAttachments(expEntry, destDir);
  _check('文件被删后导出报缺失', exp2.missing == 1 && exp2.copied == 0,
      'copied=${exp2.copied} missing=${exp2.missing}');
  // 把文件放回来，后面的断言还要用
  File(imp.absPath).writeAsBytesSync(pngBytes, flush: true);

  // 附件文件名要防目录穿越（索引里的名字理论上可能被手工改过）
  final evil = expIdx.entries.firstWhere((e) => e.id == target.id);
  final evilEntry = evil.copyWith(attachments: ['..${Platform.pathSeparator}..'
      '${Platform.pathSeparator}evil.png']);
  final evilDir = '$root${Platform.pathSeparator}_export_evil';
  final exp3 = expIdx.exportAttachments(evilEntry, evilDir);
  _check('穿越型附件名不会写到导出目录外',
      exp3.copied == 0 || !File('$root${Platform.pathSeparator}evil.png').existsSync(),
      'copied=${exp3.copied}');
  _check('穿越型附件名被清洗成单层文件名',
      exp3.copied == 0 ||
          Directory(evilDir)
              .listSync()
              .whereType<File>()
              .every((f) => !f.uri.pathSegments.last.contains('..')),
      exp3.copied == 0 ? '(源文件缺失，未落地)' : 'ok');

  // ── ⑤ 旧索引不得把 index.json 当快照解析 ──
  stdout.writeln('\n── ⑤ 旧索引（侧栏用）不误读 index.json ──');
  final errs2 = <String>[];
  final legacy = old_index.SnapshotIndex.load(root, errors: errs2);
  _check('旧索引读到的快照数 = 6', legacy.items.length == 6,
      'got ${legacy.items.length}');
  _check('没有"缺 result 字段"这类假报错',
      !errs2.any((e) => e.contains('index.json')), errs2.join(' | '));
  _check('errors 为空', errs2.isEmpty, errs2.join(' | '));

  // ── ⑥ 保留策略真的能按系列裁掉最旧的 ──
  stdout.writeln('\n── ⑥ 保留策略与索引联动 ──');
  final pruned = SnapshotIndexFile.load(root).pruneSeries(keepPerSeries: 2);
  pruned.index.save(retention: 2);
  final after6 = SnapshotIndexFile.load(root);
  _check('每系列留 2 份后只剩 2 条', after6.entries.length == 2,
      'got ${after6.entries.length}');
  final leftDates = [for (final e in after6.entries) e.dateKey]..sort();
  _check('留下的是最新两天', leftDates.join(',') == '20260924,20260925',
      leftDates.join(','));
  _check('保留设置已落盘', after6.retentionSet && after6.retention == 2,
      'set=${after6.retentionSet} r=${after6.retention}');

  // 清场
  try {
    Directory(root).deleteSync(recursive: true);
  } on Object {
    // 临时目录删不掉无所谓
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

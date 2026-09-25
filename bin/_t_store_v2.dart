/// 数据层回归（第 8 轮）：索引文件 / 保留策略 / 图片附件 / 向后兼容。
///
/// 运行：dart run bin/_t_store_v2.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/models.dart';
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

/// 造一份最小可用的 RankResult。
RankResult _mkResult(String source, String board, String? catName, String? catId,
    DateTime at, int n) {
  return RankResult(
    query: RankQuery(
        source: source, board: board, limit: n, categoryName: catName, categoryId: catId),
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

Future<void> main() async {
  stdout.writeln('== 数据层回归：索引 / 保留策略 / 附件 / 兼容 ==');

  final tmpRoot = Directory.systemTemp
      .createTempSync('rankscan_store_v2_')
      .path;
  stdout.writeln('临时根目录：$tmpRoot\n');

  final store = RankStore(root: tmpRoot);

  // ── ① 保存 5 天，每系列留 2 份 → 应只剩最新 2 份 ──
  stdout.writeln('── ① 保留策略（每系列留 2 份）──');
  for (var d = 20; d <= 24; d++) {
    await store.save(_mkResult('qidian', '月票榜', null, null, DateTime(2026, 9, d), 5));
  }
  final afterSave = await store.recent('qidian', '月票榜', limit: 99);
  _check('保存 5 天后磁盘有 5 份（未剪枝）', afterSave.length == 5,
      'got ${afterSave.length}');

  final rep = await store.pruneSeries(
      source: 'qidian', board: '月票榜', keepPerSeries: 2);
  _check('剪枝删除 3 份', rep.deletedFiles == 3, 'got ${rep.deletedFiles}');
  final afterPrune = await store.recent('qidian', '月票榜', limit: 99);
  _check('剪枝后只剩 2 份', afterPrune.length == 2, 'got ${afterPrune.length}');
  final kept = afterPrune.map((s) => s.result.fetchedAt.day).toList()..sort();
  _check('保留的是**最新** 2 天（23/24）', kept.join(',') == '23,24', 'got ${kept.join(',')}');

  // ── ② 不同系列各自计数，互不影响 ──
  stdout.writeln('\n── ② 保留策略按系列隔离 ──');
  for (var d = 20; d <= 24; d++) {
    await store.save(_mkResult('qidian', '畅销榜', '玄幻', '21', DateTime(2026, 9, d), 3));
  }
  await store.pruneSeries(
      source: 'qidian', board: '畅销榜', categoryName: '玄幻', categoryId: '21', keepPerSeries: 2);
  final xuanhuan = await store.recent('qidian', '畅销榜', categoryName: '玄幻', limit: 99);
  final yuepiao = await store.recent('qidian', '月票榜', limit: 99);
  _check('畅销榜·玄幻 剪枝后 2 份', xuanhuan.length == 2, 'got ${xuanhuan.length}');
  _check('剪畅销榜**不影响**月票榜（仍 2 份）', yuepiao.length == 2,
      'got ${yuepiao.length}');

  // ── ③ keepPerSeries = 0 表示不限 ──
  stdout.writeln('\n── ③ 保留份数=0 → 不限 ──');
  final r0 = await store.pruneSeries(
      source: 'qidian', board: '月票榜', keepPerSeries: 0);
  _check('=0 时不删任何文件', r0.deletedFiles == 0, 'got ${r0.deletedFiles}');
  _check('月票榜仍 2 份',
      (await store.recent('qidian', '月票榜', limit: 99)).length == 2);

  // ── ④ 索引：重建（老目录 → 有索引）──
  stdout.writeln('\n── ④ 索引重建（向后兼容）──');
  final idx = SnapshotIndexFile.load(tmpRoot);
  _check('从磁盘重建出条目', idx.entries.isNotEmpty, 'got ${idx.entries.length}');
  _check('标记为 rebuilt', idx.rebuilt);
  _check('索引条目数 = 4（月票榜2 + 畅销榜2）', idx.entries.length == 4,
      'got ${idx.entries.length}');

  // ── ⑤ 索引：写盘后重新加载，不再 rebuild ──
  stdout.writeln('\n── ⑤ 索引写盘 / 重载 ──');
  idx.save(retention: 2);
  _check('index.json 已生成', File(idx.indexPath).existsSync());
  final idx2 = SnapshotIndexFile.load(tmpRoot);
  _check('重载后不再标记 rebuilt', !idx2.rebuilt);
  _check('重载条目数一致（4）', idx2.entries.length == 4, 'got ${idx2.entries.length}');
  _check('保留策略被持久化（2）', idx2.retention == 2, 'got ${idx2.retention}');

  // ── ⑥ 索引：条目按新→旧排序 ──
  stdout.writeln('\n── ⑥ 索引排序 ──');
  final nf = idx2.newestFirst;
  var sorted = true;
  for (var i = 1; i < nf.length; i++) {
    if (nf[i - 1].fetchedAt.isBefore(nf[i].fetchedAt)) sorted = false;
  }
  _check('newestFirst 严格新→旧', sorted);
  _check('首条是最新的（0924）', nf.first.dateKey.endsWith('0924'),
      'got ${nf.first.dateKey}');

  // ── ⑦ 索引：upsert 同 id 覆盖（同日覆盖语义）──
  stdout.writeln('\n── ⑦ upsert 同日覆盖 ──');
  final same = _mkResult('qidian', '月票榜', null, null, DateTime(2026, 9, 24), 9);
  final e = IndexEntry(
    id: SnapshotIndexFile.snapshotId(same),
    source: 'qidian',
    board: '月票榜',
    category: null,
    dateKey: '20260924',
    fetchedAt: same.fetchedAt,
    count: 9,
    ok: true,
    relFile: '扫榜/qidian/月票榜_20260924.json',
  );
  final idx3 = idx2.upsert(e, same);
  _check('upsert 后条目数不变（同 id 覆盖）', idx3.entries.length == 4,
      'got ${idx3.entries.length}');
  final got = idx3.entries.firstWhere((x) => x.id == e.id);
  _check('该条 count 已更新为 9', got.count == 9, 'got ${got.count}');

  // ── ⑧ 幽灵条目：索引指向的文件被手工删掉 → 加载时剔除 ──
  stdout.writeln('\n── ⑧ 幽灵条目剔除 ──');
  final target = File('$tmpRoot/扫榜/qidian/月票榜_20260923.json');
  final hadTarget = target.existsSync();
  if (hadTarget) target.deleteSync();
  final errs = <String>[];
  final idx4 = SnapshotIndexFile.load(tmpRoot, errors: errs);
  _check('已删文件的条目被剔除（4→3）', idx4.entries.length == 3,
      'got ${idx4.entries.length}');
  _check('剔除非静默（errors 里有说明）', errs.any((e) => e.contains('已不存在')),
      'errors=$errs');

  // ── ⑨ 图片附件：目录 + 索引登记 + 随剪枝清理 ──
  //
  // ★ 测试设计注意：⑤ 已经 save() 过 index.json，而 ⑨ 新增的附件**不在**
  //   那份索引里。若这里直接 load()，会走"读 index.json"分支（快、但不重扫），
  //   附件永远读不到 —— 那是测试自己挖的坑，不是代码问题。
  //   所以这里先删掉 index.json，强制走 _rebuild()（真实场景：用户手工塞了
  //   一张图进附件目录，下次开软件应当能被发现）。
  stdout.writeln('\n── ⑨ 图片附件 ──');
  final attDir = await store.attachmentDirFor('qidian', '月票榜_20260924');
  _check('附件目录已创建', attDir.existsSync(), attDir.path);
  File('${attDir.path}/趋势截图.png').writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);
  File(idx.indexPath).deleteSync(); // 强制 rebuild

  final errs2 = <String>[];
  final idx5 = SnapshotIndexFile.load(tmpRoot, errors: errs2);
  final withAtt = idx5.entries.where((x) => x.attachments.isNotEmpty).toList();
  _check('rebuild 后索引识别到 1 个附件', withAtt.length == 1, 'got ${withAtt.length}');
  if (withAtt.isNotEmpty) {
    _check('附件文件名正确', withAtt.first.attachments.first == '趋势截图.png',
        'got ${withAtt.first.attachments}');
  }
  _check('附件挂在"月票榜 0924"这条上',
      withAtt.isNotEmpty && withAtt.first.dateKey.endsWith('0924'),
      withAtt.isEmpty ? '(无)' : withAtt.first.id);

  // 索引登记也要能持久化：addAttachment + save → 重载仍带附件
  final idx6 = idx5.addAttachment(withAtt.first.id, '趋势截图.png');
  idx6.save(retention: 2);
  final idx7 = SnapshotIndexFile.load(tmpRoot);
  _check('附件登记落盘后可重载', !idx7.rebuilt && File(idx.indexPath).existsSync());

  // 走到这里"月票榜"系列的磁盘现状：① 留下 23/24 → ⑧ 手工删了 23 → 只剩 24。
  // 再存 25/26/27 共 3 份 → 磁盘共 4 份 → 保持 2 应删掉最旧 2 份（24、25），
  // 其中 24 正是挂着"趋势截图.png"的那份 → 附件目录必须被连带清掉。
  for (var d = 25; d <= 27; d++) {
    await store.save(_mkResult('qidian', '月票榜', null, null, DateTime(2026, 9, d), 4));
  }
  final rep2 = await store.pruneSeries(
      source: 'qidian', board: '月票榜', keepPerSeries: 2);
  _check('剪枝删了旧份（4→2）', rep2.deletedFiles == 2, 'got ${rep2.deletedFiles}');
  _check('剪掉的正是旧的两份（24、25）',
      rep2.prunedIds.any((id) => id.endsWith('20260924')) &&
          rep2.prunedIds.any((id) => id.endsWith('20260925')),
      'pruned=${rep2.prunedIds}');
  _check('附件目录随旧份被清（不存在）', !attDir.existsSync(), attDir.path);
  final yuepiao2 = await store.recent('qidian', '月票榜', limit: 99);
  final keptDays = yuepiao2.map((s) => s.result.fetchedAt.day).toList()..sort();
  _check('剪枝后留下最新 2 天（26、27）', keptDays.join(',') == '26,27',
      'got ${keptDays.join(',')}');

  // ── ⑩ snapshotIdOf 与 IndexEntry.snapshotId 口径一致 ──
  stdout.writeln('\n── ⑩ id 口径一致 ──');
  final q = RankQuery(source: 'qidian', board: '月票榜', limit: 5);
  final at = DateTime(2026, 9, 24);
  _check('store 与 index 生成的 id 相同',
      snapshotIdOf(q, at) == SnapshotIndexFile.snapshotId(_mkResult('qidian', '月票榜', null, null, at, 1)),
      'a=${snapshotIdOf(q, at)}');
  _check('全站与 null 归一到同一 id',
      snapshotIdOf(RankQuery(source: 'qidian', board: '月票榜', limit: 5, categoryName: '全站'), at) ==
          snapshotIdOf(q, at));

  // ── ⑪ 附件文件级 API：导入 / 重名保护 / 读取 / 删除 ──
  //
  // ★ 这一段测的是"用户导入图片"真正会走的路：
  //   文件真的被复制进附件目录，索引真的登记，重名不覆盖，能读回、能删。
  stdout.writeln('\n── ⑪ 附件文件级 API ──');
  final idxA = SnapshotIndexFile.load(tmpRoot, errors: <String>[]);
  final attTarget = idxA.entries.firstWhere((e) => e.source == 'qidian');
  final srcImg = File('${Directory.systemTemp.path}/_imp_src_01.png')
    ..writeAsBytesSync([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 签名
      0x00, 0x00, 0x00, 0x0D,
    ]);

  final imp1 = idxA.importImage(attTarget, srcPath: srcImg.path);
  _check('导入后文件真的落地', File(imp1.absPath).existsSync(), imp1.absPath);
  _check('文件名沿用源名', imp1.fileName == '_imp_src_01.png', imp1.fileName);

  // 再导一次同名 → 必须变成 _2，绝不覆盖
  final imp2 = idxA.importImage(attTarget, srcPath: srcImg.path);
  _check('同名再导不覆盖（自动加 _2）',
      imp2.fileName == '_imp_src_01_2.png', imp2.fileName);
  _check('两张图都在', File(imp1.absPath).existsSync() &&
      File(imp2.absPath).existsSync());

  // 直接写字节（导出榜单为图片的场景：内存里生成，不用先落盘）
  final imp3 = idxA.importImage(attTarget,
      bytes: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 9, 9, 9, 9]),
      preferName: '榜单导出');
  _check('bytes 导入按 PNG 签名补扩展名',
      imp3.fileName == '榜单导出.png', imp3.fileName);
  _check('bytes 导入内容正确',
      File(imp3.absPath).readAsBytesSync().length == 8);

  final listed = idxA.listAttachments(attTarget);
  _check('listAttachments 列出 3 个', listed.length == 3, 'got ${listed.length}');
  _check('listAttachments 带字节数',
      listed.every((x) => x.bytes > 0), '$listed');

  // 索引登记 + 落盘 → 重载仍在
  var idxB = idxA;
  for (final n in [imp1.fileName, imp2.fileName, imp3.fileName]) {
    idxB = idxB.addAttachment(attTarget.id, n);
  }
  idxB.save(retention: 2);
  final idxC = SnapshotIndexFile.load(tmpRoot, errors: <String>[]);
  final reloaded =
      idxC.entries.firstWhere((e) => e.id == attTarget.id);
  _check('三个附件登记都落盘并可重载', reloaded.attachments.length == 3,
      'got ${reloaded.attachments}');

  // 读回字节
  final back = idxC.readAttachment(reloaded, imp3.fileName);
  _check('readAttachment 读回同样内容',
      back != null && back.length == 8 && back[0] == 0x89);
  _check('readAttachment 不存在返回 null',
      idxC.readAttachment(reloaded, 'no_such.png') == null);

  // 删一个附件（文件 + 索引）
  _check('deleteAttachment 返回 true',
      idxC.deleteAttachment(reloaded, imp2.fileName));
  _check('删除后文件不在了',
      !File('${idxC.attachmentDir(reloaded)}/${imp2.fileName}').existsSync());
  final idxD = idxC.removeAttachment(reloaded.id, imp2.fileName);
  final after = idxD.entries.firstWhere((e) => e.id == reloaded.id);
  _check('索引里也移除了该附件', after.attachments.length == 2,
      'got ${after.attachments}');

  // ── ⑫ 附件目录随快照删除而清理（deleteEntry）──
  stdout.writeln('\n── ⑫ 删除单条快照连带附件 ──');
  final dirBeforeDelete = Directory(idxD.attachmentDir(after));
  _check('删除前附件目录存在', dirBeforeDelete.existsSync());
  final del = idxD.deleteEntry(after.id);
  _check('deleteEntry 删掉 1 个数据文件', del.deletedFiles == 1,
      'got ${del.deletedFiles}');
  _check('deleteEntry 移除 1 条索引', del.deletedEntries == 1,
      'got ${del.deletedEntries}');
  _check('附件目录被连带清理', !dirBeforeDelete.existsSync());
  _check('索引里已无该条',
      del.index.entries.every((e) => e.id != after.id));

  // 清理
  try {
    srcImg.deleteSync();
  } on Object {}
  try {
    Directory(tmpRoot).deleteSync(recursive: true);
  } on Object {}

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

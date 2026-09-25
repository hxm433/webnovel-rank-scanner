/// 快照存储：价值在趋势，不在单次排名。
///
/// 路径 `<out>/扫榜/{source}/{board}[_{category}]_{YYYYMMDD}.json`，
/// **同日覆盖、跨日独立**；写入用"临时文件 + 原子替换"，
/// 单个坏文件不影响其余快照。
///
/// ★ 第 8 轮新增：
///   ① **保留策略** —— 每个"系列"（同平台+同榜+同题材）最多留 N 份，
///      新写入后自动删掉最旧的（连带它的图片附件）。N=0 表示不限。
///   ② 图片附件目录 `<out>/扫榜/_attachments/{snapshotId}/`，
///      与快照同生命周期，随保留策略一起清。
library;

import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// 一份快照的稳定标识（与文件名同源，便于 index 与磁盘双向查找）。
///
/// 格式：`{source}|{board}|{catPart}|{YYYYMMDD}`，其中 catPart 为空时写 `-`。
String snapshotIdOf(RankQuery q, DateTime when) {
  final catName = RankStore._normCategoryName(q.categoryName);
  final catId = RankStore._normCategoryId(q.categoryId);
  final catPart = catName == null ? (catId ?? '-') : '$catName#${catId ?? '-'}';
  final y = when.year.toString().padLeft(4, '0');
  final m = when.month.toString().padLeft(2, '0');
  final d = when.day.toString().padLeft(2, '0');
  return '${q.source}|${q.board}|$catPart|$y$m$d';
}

class RankSnapshot {
  RankSnapshot({required this.path, required this.result});
  final String path;
  final RankResult result;

  Map<String, Object?> toJson() => {
        'path': path,
        'saved_at': DateTime.now().toIso8601String(),
        'result': result.toJson(),
      };

  static RankSnapshot? fromJson(Map<String, Object?> j) {
    final p = j['path'];
    final r = j['result'];
    if (p is! String || r is! Map) return null;
    return RankSnapshot(path: p, result: RankResult.fromJson(r.cast<String, Object?>()));
  }
}

/// 保留策略的一次执行结果（用于界面如实汇报）。
class PruneReport {
  PruneReport(this.deletedFiles, this.deletedAttachments, this.prunedIds);
  final int deletedFiles;
  final int deletedAttachments;
  final List<String> prunedIds;
  bool get didAnything => deletedFiles > 0 || deletedAttachments > 0;
}

class RankStore {
  RankStore({required this.root});
  final String root;

  /// 图片附件根目录。
  String get attachmentsRoot =>
      '$root${Platform.pathSeparator}扫榜${Platform.pathSeparator}_attachments';

  String pathFor(RankQuery q, DateTime when) {
    final y = when.year.toString().padLeft(4, '0');
    final m = when.month.toString().padLeft(2, '0');
    final d = when.day.toString().padLeft(2, '0');
    final board = _safe(q.board);
    // ★ 分类要**归一 + 带上 id**，两个坑一起补：
    //   ① '全站' 与 null 指的是同一张榜（都能解析成 catId=-1），
    //      旧实现把它们写成 `月票榜.全站_日期.json` 和 `月票榜_日期.json`
    //      两个文件 → 同一张榜被拆成两个数据系列，跨日趋势对比直接断掉。
    //   ② 文件名只有 board + categoryName，**不含 categoryId**。
    //      畅销榜 catid=21（玄幻）与 catid=4（都市）会落到同一个
    //      `畅销榜_日期.json` → 后一次静默覆盖前一次，用户丢数据还不自知。
    //   现在：'全站'/空 一律归成空串（不写 .全站），非全站分类则带 "_c<id>"。
    final catName = _normCategoryName(q.categoryName);
    final catId = _normCategoryId(q.categoryId);
    final cat = catName == null
        ? (catId == null ? '' : '_c$catId')
        : '.${_safe(catName)}${catId == null ? '' : '_c$catId'}';
    return '$root${Platform.pathSeparator}扫榜'
        '${Platform.pathSeparator}${_safe(q.source)}'
        '${Platform.pathSeparator}${board}$cat'
        '_$y$m$d.json';
  }

  /// '全站'、'全部'、空串都归一成 null（= 不区分题材）。
  static String? _normCategoryName(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s == '全站' || s == '全部' || s == '所有') return null;
    return s;
  }

  /// 与 `全站` 等价的 catId（-1 / '' / '0'）归一成 null。
  static String? _normCategoryId(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s == '-1' || s == '0') return null;
    return s;
  }

  Future<RankSnapshot> save(RankResult result) async {
    final path = pathFor(result.query, result.fetchedAt);
    final f = File(path);
    await f.parent.create(recursive: true);
    // ★ 临时文件名必须**唯一**。旧代码固定叫 `$path.tmp`，
    //   所有并发写入共享同一个临时名，两个写入可以互相踩（配合并行扫榜可达）。
    final tmp = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await tmp.writeAsString(
          const JsonEncoder.withIndent('  ').convert(RankSnapshot(
                  path: path, result: result)
              .toJson()), flush: true);
      await tmp.rename(path);
    } on Object {
      // 写失败就把临时文件清掉，别在数据目录里留垃圾。
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } on Object {
          // 清不掉也不影响主流程
        }
      }
      rethrow;
    }
    return RankSnapshot(path: path, result: result);
  }

  /// 一个"系列"的目录 + 文件名前缀（同平台同榜同题材共用）。
  (Directory, String) _seriesLocator(
      String source, String board, String? categoryName, String? categoryId) {
    final dir = Directory(
        '$root${Platform.pathSeparator}扫榜${Platform.pathSeparator}${_safe(source)}');
    final catName = _normCategoryName(categoryName);
    final catId = _normCategoryId(categoryId);
    final cat = catName == null
        ? (catId == null ? '' : '_c$catId')
        : '.${_safe(catName)}${catId == null ? '' : '_c$catId'}';
    return (dir, '${_safe(board)}$cat'
        '_');
  }

  /// ★ 保留策略：每个系列只留最新 [keepPerSeries] 份（0 = 不限）。
  ///
  /// 删除顺序严格"最旧优先"，且**只删同系列**的文件 —— 不同榜/不同题材
  /// 各自计数，不会因为 A 榜扫得多就把 B 榜的老数据挤掉。
  ///
  /// 副产物：返回被清理的快照 id 列表，调用方据此同步清理图片附件与索引。
  Future<PruneReport> pruneSeries({
    required String source,
    required String board,
    String? categoryName,
    String? categoryId,
    required int keepPerSeries,
  }) async {
    if (keepPerSeries <= 0) return PruneReport(0, 0, const []);
    final (dir, prefix) = _seriesLocator(source, board, categoryName, categoryId);
    if (!await dir.exists()) return PruneReport(0, 0, const []);

    final files = <File>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.endsWith('.json')) continue;
      if (!name.startsWith(prefix)) continue;
      files.add(e);
    }
    if (files.length <= keepPerSeries) return PruneReport(0, 0, const []);

    // 文件名即 YYYYMMDD，天然可排序：升序 = 旧→新。
    files.sort((a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last));
    final doomed = files.sublist(0, files.length - keepPerSeries);

    var delFiles = 0;
    var delAttach = 0;
    final ids = <String>[];
    for (final f in doomed) {
      final name = f.uri.pathSegments.last;
      // 从文件名反推快照 id（source|board|cat|date）。
      final date = _dateFromFileName(name);
      if (date != null) ids.add(snapshotIdOf(_queryOf(source, board, categoryName, categoryId), date));
      try {
        await f.delete();
        delFiles++;
      } on Object {
        continue; // 删不掉就留着，不阻断
      }
      // 连带清理该快照的图片附件目录。
      final attDir = Directory(
          '$attachmentsRoot${Platform.pathSeparator}${_safe(source)}'
          '${Platform.pathSeparator}${_safe(_stem(name))}');
      if (await attDir.exists()) {
        try {
          final n = attDir.listSync().length;
          await attDir.delete(recursive: true);
          delAttach += n;
        } on Object {
          // 附件清理失败不影响主流程
        }
      }
    }
    return PruneReport(delFiles, delAttach, ids);
  }

  static RankQuery _queryOf(
      String source, String board, String? categoryName, String? categoryId) {
    return RankQuery(
      source: source,
      board: board,
      limit: 0,
      categoryId: categoryId,
      categoryName: categoryName,
    );
  }

  /// 从 `月票榜_20260924.json` 取出 `20260924` → DateTime。
  static DateTime? _dateFromFileName(String name) {
    final m = RegExp(r'_(\d{4})(\d{2})(\d{2})\.json$').firstMatch(name);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return null;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return DateTime(y, mo, d);
  }

  static String _stem(String fileName) =>
      fileName.endsWith('.json') ? fileName.substring(0, fileName.length - 5) : fileName;

  /// 一份快照的图片附件目录（不存在则创建）。
  Future<Directory> attachmentDirFor(String source, String snapshotStem) async {
    final d = Directory(
        '$attachmentsRoot${Platform.pathSeparator}${_safe(source)}'
        '${Platform.pathSeparator}${_safe(snapshotStem)}');
    await d.create(recursive: true);
    return d;
  }

  Future<List<RankSnapshot>> recent(String source, String board,
      {String? categoryName, int limit = 2}) async {
    final dir = Directory('$root${Platform.pathSeparator}扫榜'
        '${Platform.pathSeparator}$source');
    if (!await dir.exists()) return const [];
    final prefix = '${_safe(board)}'
        '${(categoryName == null || categoryName.isEmpty) ? '' : '.${_safe(categoryName)}'}_';
    final files = <File>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.endsWith('.json')) continue;
      if (!name.startsWith(prefix)) continue;
      files.add(e);
    }
    // 文件名即日期，天然可排序（倒序 = 新→旧）
    files.sort((a, b) => b.uri.pathSegments.last.compareTo(a.uri.pathSegments.last));
    final out = <RankSnapshot>[];
    for (final f in files.take(limit)) {
      try {
        final data = jsonDecode(await f.readAsString());
        if (data is Map) {
          final s = RankSnapshot.fromJson(data.cast<String, Object?>());
          if (s != null) out.add(s);
        }
      } on Object {
        continue; // 单份损坏不拖垮其余
      }
    }
    return out;
  }

  /// Windows 保留设备名（不区分大小写，且**带扩展名也照样保留**）。
  static const Set<String> _reserved = {
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
  };

  /// 清洗成**安全的单层文件名**。
  ///
  /// ★ 旧实现只替换 `[\\/:*?"<>|]` 和控制字符，挡不住三种情况（实测）：
  ///   ① 目录穿越：`..` 原样通过 → `扫榜\..\CON.aux._2026.json` 跑到上级目录；
  ///   ② Windows 保留名：`CON`、`aux.` 这类建文件会失败或行为诡异；
  ///   ③ 结尾的点/空格：Windows 会静默去掉，导致"写的路径"和"读的路径"不一致。
  ///   现在逐条挡掉，并限制长度（NTFS 单段上限 255）。
  static String _safe(String s) {
    var out = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    // 结尾的点和空格 Windows 会吞掉 → 换掉，保证路径可预测。
    out = out.replaceAll(RegExp(r'[. ]+$'), '_');
    // 纯 '.' / '..' 直接换掉（否则构成上级目录引用）。
    if (out == '.' || out == '..' || out.trim().isEmpty) out = '_';
    // 保留名：整个名字（或点号前的部分）命中就加前缀。
    final stem = out.split('.').first.toLowerCase();
    if (_reserved.contains(stem)) out = '_$out';
    if (out.length > 120) out = out.substring(0, 120);
    return out;
  }
}

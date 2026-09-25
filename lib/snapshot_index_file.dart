/// 数据索引 `out/扫榜/index.json` —— 快照清单 + 保留策略设置。
///
/// ★ 为什么需要它（而不是每次递归 glob 所有 JSON）：
///   ① 加载从 O(读全部文件) 降到 O(读一个索引)，扫榜数据累积后差别很大；
///   ② 图片附件要跟快照**绑定**，索引是记录"哪个快照有哪些图"的唯一位置；
///   ③ 保留策略（每系列留 N 份）是**用户设置**，需要一个持久化落点。
///
/// ★ 向后兼容：索引缺失或损坏时，自动从磁盘 JSON 重建（老目录无缝升级）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// 索引里的一条快照记录。
class IndexEntry {
  IndexEntry({
    required this.id,
    required this.source,
    required this.board,
    this.category,
    this.categoryId,
    required this.dateKey,
    required this.fetchedAt,
    required this.count,
    required this.ok,
    required this.relFile,
    this.attachments = const [],
  });

  /// 稳定标识：`{source}|{board}|{catPart}|{YYYYMMDD}`。
  final String id;
  final String source;
  final String board;
  final String? category;
  final String? categoryId;
  final String dateKey;
  final DateTime fetchedAt;
  final int count;
  final bool ok;

  /// 相对 `out/` 的文件路径（不含 out 前缀），便于整体搬目录。
  final String relFile;

  /// 图片附件文件名列表（相对于该快照的附件目录）。
  final List<String> attachments;

  String get seriesKey => '$source|$board|${_normCategory(category) ?? '-'}';

  String get label =>
      '$board${category == null ? '' : ' · $category'}';

  static String? _normCategory(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s == '全站' || s == '全部' || s == '所有') return null;
    return s;
  }

  IndexEntry copyWith({List<String>? attachments, int? count, bool? ok}) => IndexEntry(
        id: id,
        source: source,
        board: board,
        category: category,
        categoryId: categoryId,
        dateKey: dateKey,
        fetchedAt: fetchedAt,
        count: count ?? this.count,
        ok: ok ?? this.ok,
        relFile: relFile,
        attachments: attachments ?? this.attachments,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'source': source,
        'board': board,
        'category': category,
        'category_id': categoryId,
        'date': dateKey,
        'fetched_at': fetchedAt.toIso8601String(),
        'count': count,
        'ok': ok,
        'file': relFile,
        if (attachments.isNotEmpty) 'attachments': attachments,
      };

  static IndexEntry? fromJson(Map<String, Object?> j) {
    final id = j['id'];
    final src = j['source'];
    final brd = j['board'];
    final file = j['file'];
    if (id is! String || src is! String || brd is! String || file is! String) {
      return null;
    }
    DateTime at;
    try {
      at = DateTime.parse('${j['fetched_at']}');
    } on Object {
      at = DateTime.now();
    }
    return IndexEntry(
      id: id,
      source: src,
      board: brd,
      category: j['category'] as String?,
      categoryId: j['category_id'] as String?,
      dateKey: '${j['date'] ?? ''}',
      fetchedAt: at,
      count: (j['count'] as num?)?.toInt() ?? 0,
      ok: j['ok'] != false,
      relFile: file,
      attachments: [
        for (final a in (j['attachments'] as List?) ?? const []) '$a'
      ],
    );
  }
}

/// 索引文件的门面：读 / 写 / 重建 / 增删。
class SnapshotIndexFile {
  SnapshotIndexFile._(this.root, this.entries, this._newestFirst, this._retention,
      this._rebuilt, [this._retentionSet = false]);

  final String root;

  /// 全部条目（按平台固定顺序 + 组内时间倒序排好，供侧栏直接消费）。
  final List<IndexEntry> entries;

  /// 全局新→旧（供"最近扫描"等快速取用）。
  final List<IndexEntry> _newestFirst;

  /// 每个系列保留份数（0 = 不限）。
  final int _retention;

  /// 本次加载是否走了"从磁盘重建"这条路（界面可提示）。
  final bool _rebuilt;

  /// 用户是否**显式设置过**保留份数。
  ///
  /// ★ 为什么需要这个布尔：`0` 是一个合法设置（"不限"），而索引缺失/重建时
  ///   读出来的也是 `0`。两者分不开的话，界面就无法判断"该沿用磁盘上的设置"
  ///   还是"该用默认值"—— 会把用户设的"不限"当成"从没设过"。
  final bool _retentionSet;

  /// 本次加载是否**从磁盘补进了索引里没有的快照**（自愈）。
  ///
  /// ★ 调用方（主窗）看到它为 true 就应该 `save()` 一次，把补齐的结果落盘，
  ///   免得每次启动都要重新扫描一遍。
  bool _reconciled = false;

  int get retention => _retention;
  bool get retentionSet => _retentionSet;
  bool get rebuilt => _rebuilt;
  bool get reconciled => _reconciled;

  List<IndexEntry> get newestFirst => List.unmodifiable(_newestFirst);

  /// 索引文件路径。
  String get indexPath =>
      '$root${Platform.pathSeparator}扫榜${Platform.pathSeparator}index.json';

  // ── 加载 ──

  /// 读索引；缺失/损坏/版本不符 → 从磁盘重建。
  ///
  /// [errors] 收集坏文件说明，**不静默吞掉**（沿用旧实现的原则）。
  static SnapshotIndexFile load(String root, {List<String>? errors}) {
    final path = '$root${Platform.pathSeparator}扫榜'
        '${Platform.pathSeparator}index.json';
    final f = File(path);
    if (f.existsSync()) {
      try {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map) {
          final ver = (raw['version'] as num?)?.toInt() ?? 0;
          final list = raw['entries'];
          if (ver >= 1 && list is List) {
            final out = <IndexEntry>[];
            for (final e in list) {
              if (e is! Map) continue;
              final en = IndexEntry.fromJson(e.cast<String, Object?>());
              if (en != null) out.add(en);
            }
            final retention = (raw['retention'] as num?)?.toInt() ?? 0;
            final retentionSet = raw['retention_set'] == true;
            // ★ 索引里的路径要落地校验：文件被用户手工删了 → 剔除该条，
            //   否则界面会出现"点进去空白"的幽灵条目。
            final alive = <IndexEntry>[];
            for (final en in out) {
              if (File('$root${Platform.pathSeparator}${en.relFile}').existsSync()) {
                alive.add(en);
              } else {
                errors?.add('索引条目 ${en.id} 指向的文件已不存在，已忽略');
              }
            }
            // ★ 自愈：磁盘上有、索引里没有的快照要补进来。
            //   这是"每次采集都自动放入"的**兜底**——正常路径是采集完立刻
            //   upsert（见 ScanService），但只要有一次没写成（进程被杀、
            //   磁盘只读、用户手工拷了个 JSON 进来），索引就会永久落后于磁盘：
            //   表现为"明明扫了，侧栏里却没有/时间线缺了一期"。
            //   代价只是多一次目录列举（不解析已知文件），换来索引永不落后。
            final added = _reconcile(root, alive, errors: errors);
            final all = added.isEmpty ? alive : [...alive, ...added];
            return SnapshotIndexFile._(
                root, all, _sortNewest(all), retention, false, retentionSet)
              .._reconciled = added.isNotEmpty;
          }
        }
        errors?.add('索引版本不识别，已从磁盘重建');
      } on Object catch (e) {
        errors?.add('索引损坏（$e），已从磁盘重建');
      }
    }
    final rebuilt = _rebuild(root, errors: errors);
    return SnapshotIndexFile._(
        root, rebuilt, _sortNewest(rebuilt), 0, true);
  }

  /// 找出"磁盘上有、索引里没有"的快照并解析成条目。
  ///
  /// 与 [_rebuild] 的区别：只解析**索引里没有**的那几个文件，
  /// 已有条目一律不碰 —— 所以正常情况下（索引是最新的）它只做一次目录列举。
  static List<IndexEntry> _reconcile(String root, List<IndexEntry> known,
      {List<String>? errors}) {
    final dir = Directory('$root${Platform.pathSeparator}扫榜');
    if (!dir.existsSync()) return const [];
    final seen = <String>{
      for (final e in known) e.relFile.replaceAll('\\', '/')
    };
    final out = <IndexEntry>[];
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.json')) continue;
      if (_isIndexJson(f.path)) continue;
      final rel = _relPath(root, f.path);
      if (seen.contains(rel)) continue;
      try {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is! Map) {
          errors?.add('${f.path}: 顶层不是对象');
          continue;
        }
        final r = raw['result'];
        if (r is! Map) {
          errors?.add('${f.path}: 缺 result 字段');
          continue;
        }
        final result = RankResult.fromJson(r.cast<String, Object?>());
        out.add(fromResult(result, relFile: rel).copyWith(
          attachments: _scanAttachments(root, result.query.source, rel),
        ));
      } on Object catch (e) {
        errors?.add('${f.path}: 解析失败 $e');
      }
    }
    return out;
  }

  /// 是不是索引文件自身（`扫榜/index.json`）—— 递归扫描时要排掉。
  static bool _isIndexJson(String absPath) {
    final p = absPath.replaceAll('\\', '/');
    final segs = p.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return false;
    if (segs.last.toLowerCase() != 'index.json') return false;
    return segs.length < 2 || segs[segs.length - 2] == '扫榜';
  }

  /// 递归扫描 `扫榜/**/*.json` 重建条目（老目录升级用）。
  static List<IndexEntry> _rebuild(String root, {List<String>? errors}) {
    final dir = Directory('$root${Platform.pathSeparator}扫榜');
    final out = <IndexEntry>[];
    if (!dir.existsSync()) return out;
    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .where((f) => !f.path.endsWith('index.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final f in files) {
      try {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is! Map) {
          errors?.add('${f.path}: 顶层不是对象');
          continue;
        }
        final r = raw['result'];
        if (r is! Map) {
          errors?.add('${f.path}: 缺 result 字段');
          continue;
        }
        final result = RankResult.fromJson(r.cast<String, Object?>());
        final rel = _relPath(root, f.path);
        // ★ 与"采集后写索引"共用同一个工厂 —— 两条路造出的条目必须逐字段一致，
        //   否则重建出来的索引与增量写入的索引会对不上（表现为"重建后附件丢了"
        //   或"seriesKey 变了导致时间线断成两条"）。
        out.add(fromResult(result, relFile: rel).copyWith(
          attachments: _scanAttachments(root, result.query.source, rel),
        ));
      } on Object catch (e) {
        errors?.add('${f.path}: 解析失败 $e');
      }
    }
    return out;
  }

  /// 扫描某个快照的图片附件目录，返回文件名列表。
  static List<String> _scanAttachments(String root, String source, String relFile) {
    final stem = relFile.split(RegExp(r'[\\/]')).last;
    final stemNoExt =
        stem.endsWith('.json') ? stem.substring(0, stem.length - 5) : stem;
    final d = Directory(
        '$root${Platform.pathSeparator}扫榜${Platform.pathSeparator}_attachments'
        '${Platform.pathSeparator}${_safe(source)}'
        '${Platform.pathSeparator}${_safe(stemNoExt)}');
    if (!d.existsSync()) return const [];
    return [
      for (final e in d.listSync())
        if (e is File && _isImage(e.path)) e.uri.pathSegments.last
    ];
  }

  // ── 保存 ──

  /// 写索引。
  ///
  /// [retention] 非空 = 这次调用**显式设定**了保留份数 → 落盘时带上
  /// `retention_set: true`，下次启动才能区分"用户选了不限(0)"与"从没设过"。
  void save({int? retention}) {
    final f = File(indexPath);
    f.parent.createSync(recursive: true);
    // 负数一律按 0（不限）落盘：调用方可能直接把手输值传进来，
    // 写个 -5 进索引的话，下次读出来既不等于 0 也不是合法份数，
    // 保留策略那边 `keepPerSeries > 0` 判false 才侥幸没删错东西 ——
    // 别把正确性建立在"下游恰好也做了判断"上。
    final raw = retention ?? _retention;
    final effective = raw < 0 ? 0 : raw;
    final payload = {
      'version': 1,
      'saved_at': DateTime.now().toIso8601String(),
      'retention': effective,
      'retention_set': retention != null || _retentionSet,
      'entries': [for (final e in entries) e.toJson()],
    };
    // 同样用"临时文件 + 原子替换"，避免写一半崩了留下坏索引。
    final tmp = File('$indexPath.${DateTime.now().microsecondsSinceEpoch}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload),
        flush: true);
    tmp.renameSync(indexPath);
  }

  // ── 变更 ──

  /// 新增或替换一条（同 id 覆盖 —— 对应"同日覆盖"语义）。
  ///
  /// [result] 可选：早先的签名要求调用方把 [RankResult] 一起传进来，
  /// 但索引条目 [IndexEntry] 已经把需要的字段都摘出来了，参数在实现里根本没用上，
  /// 反而逼着"只想登记一条"的调用方（如挂附件）先去找一份结果。
  /// 保留成可选位参，是为了不破坏已有调用点。
  SnapshotIndexFile upsert(IndexEntry e, [RankResult? result]) {
    // ★ 覆盖时必须**保住已有附件**。
    //   同一天重扫同一张榜是常态（"同日覆盖"语义），而附件（用户手工存的
    //   截图/粘贴文本）跟这次重扫毫无关系 —— 直接用新条目覆盖会把附件列表
    //   清空，索引里没了名字，磁盘上的图就变成再也点不开的孤儿文件。
    var merged = e;
    for (final x in entries) {
      if (x.id != e.id) continue;
      if (x.attachments.isNotEmpty) {
        merged = e.copyWith(attachments: [
          // 并集去重，且保持"旧在前"的稳定顺序
          ...x.attachments,
          for (final a in e.attachments)
            if (!x.attachments.contains(a)) a,
        ]);
      }
      break;
    }
    final next = <IndexEntry>[
      for (final x in entries)
        if (x.id != e.id) x,
      merged,
    ];
    return SnapshotIndexFile._(
        root, next, _sortNewest(next), _retention, _rebuilt, _retentionSet);
  }

  /// 按 id 删除一条。
  SnapshotIndexFile removeById(String id) {
    final next = [
      for (final x in entries)
        if (x.id != id) x
    ];
    return SnapshotIndexFile._(
        root, next, _sortNewest(next), _retention, _rebuilt, _retentionSet);
  }

  /// 设定保留份数（负数按 0 = 不限处理），并标记为"用户显式设过"。
  SnapshotIndexFile withRetention(int r) => SnapshotIndexFile._(
      root, entries, _newestFirst, r < 0 ? 0 : r, _rebuilt, true);

  /// 给某个快照追加一个图片附件名。
  SnapshotIndexFile addAttachment(String id, String fileName) {
    final next = [
      for (final x in entries)
        if (x.id == id)
          x.copyWith(attachments: [...x.attachments, fileName])
        else
          x
    ];
    return SnapshotIndexFile._(
        root, next, _newestFirst, _retention, _rebuilt, _retentionSet);
  }

  /// 移除某个快照的某个图片附件名。
  SnapshotIndexFile removeAttachment(String id, String fileName) {
    final next = [
      for (final x in entries)
        if (x.id == id)
          x.copyWith(
              attachments: [
                for (final a in x.attachments)
                  if (a != fileName) a
              ])
        else
          x
    ];
    return SnapshotIndexFile._(
        root, next, _newestFirst, _retention, _rebuilt, _retentionSet);
  }

  // ── 图片附件（文件级操作）──
  //
  // ★ 附件目录约定：`out/扫榜/_attachments/{source}/{快照文件名词干}/`
  //   放在"扫榜"目录下、以 `_` 开头，这样 `_rebuild()` 的递归扫描
  //   （只看 `*.json`）天然不会误抓附件目录里的东西。
  //   附件与快照**同生命周期** —— 快照被保留策略删掉时，附件目录一起删。

  /// 某个快照的附件目录（绝对路径）。目录不一定存在。
  String attachmentDir(IndexEntry e) => attachmentDirFor(
      root, e.source, e.relFile.split(RegExp(r'[\\/]')).last);

  /// 按 source + 快照文件名（含扩展名）算附件目录。
  static String attachmentDirFor(String root, String source, String fileName) {
    final stem = fileName.toLowerCase().endsWith('.json')
        ? fileName.substring(0, fileName.length - 5)
        : fileName;
    return [
      root,
      '扫榜',
      '_attachments',
      _safe(source),
      _safe(stem),
    ].join(Platform.pathSeparator);
  }

  /// 列出某快照的全部附件（文件名 + 字节数），按名称排序。
  List<({String name, int bytes})> listAttachments(IndexEntry e) {
    final d = Directory(attachmentDir(e));
    if (!d.existsSync()) return const [];
    final out = <({String name, int bytes})>[];
    for (final f in d.listSync().whereType<File>()) {
      if (!_isImage(f.path)) continue;
      out.add((name: f.uri.pathSegments.last, bytes: f.lengthSync()));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// 把一张图片复制进某快照的附件目录。返回落地的文件名。
  ///
  /// [preferName] 为空时用源文件名；重名自动加 `_2` / `_3` 后缀，
  /// **绝不覆盖**已存在的附件（用户手工截的两张图不能互相吃掉）。
  ///
  /// [bytes] 非空时直接写字节（用于"导出榜单为图片"这类内存里生成的图，
  /// 不用先落盘再拷）；否则从 [srcPath] 复制。
  ({String fileName, String absPath}) importImage(
      IndexEntry e, {
    String? srcPath,
    Uint8List? bytes,
    String? preferName,
  }) {
    if (srcPath == null && bytes == null) {
      throw ArgumentError('importImage 需要 srcPath 或 bytes 之一');
    }
    final dir = Directory(attachmentDir(e))..createSync(recursive: true);
    final base = _safe(_stemOf(preferName ?? _baseName(srcPath!) ));
    final ext = _extOf(preferName ?? srcPath!)
        .ifEmpty(_extFromBytes(bytes) ?? '.png');
    var name = '$base$ext';
    var n = 2;
    while (File('${dir.path}${Platform.pathSeparator}$name').existsSync()) {
      name = '${base}_$n$ext';
      n++;
    }
    final dst = '${dir.path}${Platform.pathSeparator}$name';
    if (bytes != null) {
      File(dst).writeAsBytesSync(bytes, flush: true);
    } else {
      File(srcPath!).copySync(dst);
    }
    return (fileName: name, absPath: dst);
  }

  /// 删除某快照的某个附件文件。
  bool deleteAttachment(IndexEntry e, String fileName) {
    final p = '${attachmentDir(e)}${Platform.pathSeparator}$fileName';
    final f = File(p);
    if (!f.existsSync()) return false;
    try {
      f.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// 读取某附件的字节（给"导出附件"/"预览"用）。
  Uint8List? readAttachment(IndexEntry e, String fileName) {
    final f = File('${attachmentDir(e)}${Platform.pathSeparator}$fileName');
    if (!f.existsSync()) return null;
    try {
      return f.readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }

  /// 把某快照的全部附件复制到 [destDir]（目录不存在会创建）。
  ///
  /// 返回 `(copied, missing)` —— 复制成功的个数、以及"索引里有名字但文件
  /// 已不在磁盘上"的个数。**缺失要如实报出来**：静默少几个文件，
  /// 用户会以为导出的就是全部。
  ({int copied, int missing}) exportAttachments(IndexEntry e, String destDir) {
    Directory(destDir).createSync(recursive: true);
    var copied = 0;
    var missing = 0;
    for (final name in e.attachments) {
      final bytes = readAttachment(e, name);
      if (bytes == null) {
        missing++;
        continue;
      }
      // ★ 文件名要再洗一遍：索引里的名字来自用户磁盘，理论上可能是 `..`
      //   或绝对路径片段 —— 直接拼进导出路径就是目录穿越。
      final safe = _safe(name);
      File('$destDir${Platform.pathSeparator}$safe')
          .writeAsBytesSync(bytes, flush: true);
      copied++;
    }
    return (copied: copied, missing: missing);
  }

  /// 删除某快照的整个附件目录（快照被剪掉时调用）。
  static void deleteAttachmentDirFor(
      String root, String source, String fileName) {
    final p = attachmentDirFor(root, source, fileName);
    final d = Directory(p);
    if (!d.existsSync()) return;
    try {
      d.deleteSync(recursive: true);
    } on FileSystemException {
      // 删不掉不阻断主流程（可能被看图程序占用）；下次保存时索引已无此条。
    }
  }

  // ── 清理 ──

  /// 单个系列最多保留 [keepPerSeries] 份（0 = 不限）。
  ///
  /// ★ "系列"= `source|board|归一化category`（见 [IndexEntry.seriesKey]）。
  ///   按 [IndexEntry.fetchedAt] 倒序，超出的**连同数据文件与附件目录**一起删。
  ///
  /// 返回 `(deletedFiles, deletedEntries)` —— 删掉的数据文件数、条目数
  /// （附件目录另计，但会一并清理）。
  PruneResult pruneSeries({required int keepPerSeries}) {
    var next = [...entries];
    var files = 0;
    var entriesRemoved = 0;
    if (keepPerSeries > 0) {
      final bySeries = <String, List<IndexEntry>>{};
      for (final e in next) {
        bySeries.putIfAbsent(e.seriesKey, () => []).add(e);
      }
      final doomed = <IndexEntry>[];
      for (final list in bySeries.values) {
        list.sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
        if (list.length > keepPerSeries) {
          doomed.addAll(list.sublist(keepPerSeries));
        }
      }
      if (doomed.isNotEmpty) {
        final ids = <String>{
          for (final e in doomed) e.id
        };
        for (final e in doomed) {
          // 数据文件
          final fp = '$root${Platform.pathSeparator}${e.relFile}';
          final f = File(fp);
          if (f.existsSync()) {
            try {
              f.deleteSync();
              files++;
            } on FileSystemException {
              // 忽略：索引仍会剔除该条，避免幽灵条目
            }
          }
          // 附件目录（与快照同生命周期）
          deleteAttachmentDirFor(
              root, e.source, e.relFile.split(RegExp(r'[\\/]')).last);
          entriesRemoved++;
        }
        next = [
          for (final e in next)
            if (!ids.contains(e.id)) e
        ];
      }
    }
    // 顺带清掉"指向的文件已不存在"的僵尸条目与它们的附件目录
    final alive = <IndexEntry>[];
    for (final e in next) {
      final fp = '$root${Platform.pathSeparator}${e.relFile}';
      if (File(fp).existsSync()) {
        alive.add(e);
      } else {
        deleteAttachmentDirFor(
            root, e.source, e.relFile.split(RegExp(r'[\\/]')).last);
        entriesRemoved++;
      }
    }
    final out = SnapshotIndexFile._(
        root, alive, _sortNewest(alive), _retention, _rebuilt, _retentionSet);
    return PruneResult(out, files, entriesRemoved);
  }

  /// 手动删除单条快照（数据文件 + 附件目录 + 索引条目）。
  PruneResult deleteEntry(String id) {
    IndexEntry? e;
    for (final x in entries) {
      if (x.id == id) {
        e = x;
        break;
      }
    }
    var files = 0;
    var removed = 0;
    if (e != null) {
      final f = File('$root${Platform.pathSeparator}${e.relFile}');
      if (f.existsSync()) {
        try {
          f.deleteSync();
          files++;
        } on FileSystemException {
          // 忽略
        }
      }
      deleteAttachmentDirFor(
          root, e.source, e.relFile.split(RegExp(r'[\\/]')).last);
      removed = 1;
    }
    final next = [
      for (final x in entries)
        if (x.id != id) x
    ];
    final out = SnapshotIndexFile._(
        root, next, _sortNewest(next), _retention, _rebuilt, _retentionSet);
    return PruneResult(out, files, removed);
  }

  // ── 工具 ──

  static String _baseName(String path) {
    final segs = path.replaceAll('\\', '/').split('/');
    return segs.isEmpty ? path : segs.last;
  }

  static String _stemOf(String fileName) {
    final i = fileName.lastIndexOf('.');
    return i <= 0 ? fileName : fileName.substring(0, i);
  }

  static String _extOf(String fileName) {
    final i = fileName.lastIndexOf('.');
    return i <= 0 ? '' : fileName.substring(i).toLowerCase();
  }

  static String? _extFromBytes(Uint8List? b) {
    if (b == null || b.length < 4) return null;
    if (b[0] == 0x89 && b[1] == 0x50) return '.png';
    if (b[0] == 0xFF && b[1] == 0xD8) return '.jpg';
    if (b[0] == 0x42 && b[1] == 0x4D) return '.bmp';
    if (b[0] == 0x47 && b[1] == 0x49) return '.gif';
    return null;
  }

  /// 同系列的其它条目（按时间倒序，不含自身）—— 供跨期对比用。
  List<IndexEntry> seriesOf(IndexEntry e, {bool excludeSelf = true}) {
    final list = entries
        .where((x) => x.seriesKey == e.seriesKey && (!excludeSelf || x.id != e.id))
        .toList()
      ..sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
    return list;
  }

  // ── id 口径 ──

  /// 从一次采集结果直接造一条索引记录。
  ///
  /// [relFile] 是相对 `out/` 的路径（用 [relPathOf] 算）。
  /// 这是"每次采集都写进索引"那条链路的唯一入口 —— 采完立刻 upsert 落盘，
  /// 索引就不会落后于磁盘。
  static IndexEntry fromResult(RankResult r, {required String relFile}) {
    final q = r.query;
    return IndexEntry(
      id: snapshotId(r),
      source: q.source,
      board: q.board,
      category: q.categoryName,
      categoryId: q.categoryId,
      dateKey: _ymd(r.fetchedAt),
      fetchedAt: r.fetchedAt,
      count: r.entries.length,
      ok: r.quality?.ok ?? r.entries.isNotEmpty,
      relFile: relFile,
    );
  }

  /// 绝对路径 → 相对 `out/` 的路径（统一用 `/` 分隔，便于整体搬目录）。
  static String relPathOf(String root, String abs) => _relPath(root, abs);

  static String snapshotId(RankResult r) {
    final q = r.query;
    final cn = IndexEntry._normCategory(q.categoryName);
    final cid = _normCatId(q.categoryId);
    final catPart = cn == null ? (cid ?? '-') : '$cn#${cid ?? '-'}';
    return '${q.source}|${q.board}|$catPart|${_ymd(r.fetchedAt)}';
  }

  static String? _normCatId(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s == '-1' || s == '0') return null;
    return s;
  }

  static List<IndexEntry> _sortNewest(List<IndexEntry> list) {
    final out = [...list]..sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
    return out;
  }

  static String _relPath(String root, String abs) {
    var p = abs.replaceAll('\\', '/');
    var r = root.replaceAll('\\', '/');
    if (!r.endsWith('/')) r = '$r/';
    if (p.startsWith(r)) p = p.substring(r.length);
    return p;
  }

  static bool _isImage(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.png') ||
        p.endsWith('.jpg') ||
        p.endsWith('.jpeg') ||
        p.endsWith('.bmp') ||
        p.endsWith('.gif') ||
        p.endsWith('.webp');
  }

  static String _safe(String s) {
    var out = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    out = out.replaceAll(RegExp(r'[. ]+$'), '_');
    if (out == '.' || out == '..' || out.trim().isEmpty) out = '_';
    if (out.length > 120) out = out.substring(0, 120);
    return out;
  }
}

/// [SnapshotIndexFile.pruneSeries] / [deleteEntry] 的结果。
class PruneResult {
  PruneResult(this.index, this.deletedFiles, this.deletedEntries);
  final SnapshotIndexFile index;

  /// 被删除的数据文件数。
  final int deletedFiles;

  /// 被移除的索引条目数（含附件目录被清理的）。
  final int deletedEntries;

  @override
  String toString() =>
      'PruneResult(files=$deletedFiles, entries=$deletedEntries)';
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

String _ymd(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

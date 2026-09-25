/// 快照索引：把 `out/扫榜/**/*.json` 读成一份可枚举的清单。
///
/// ★ 页面**只拿到整数 id，永远拿不到文件路径** —— 路径由服务端从
///   已加载的索引里查表得到，从结构上排除目录穿越。
library;

import 'dart:convert';
import 'dart:io';

import 'models.dart';

class SnapshotMeta {
  SnapshotMeta({
    required this.id,
    required this.file,
    required this.result,
  });

  final int id;
  final File file;
  final RankResult result;

  String get source => result.query.source;
  String get board => result.query.board;

  /// 展示用的题材名（保留原样，'全站' 仍显示为 '全站'）。
  String? get category => result.query.categoryName;

  int get count => result.entries.length;
  DateTime get fetchedAt => result.fetchedAt;
  String get dateKey => _ymd(result.fetchedAt);
  bool get ok => result.quality?.ok ?? result.entries.isNotEmpty;

  /// 分组键：同一"数据系列"的最新/上一份靠它配对。
  ///
  /// ★ 题材必须**归一**：`'全站'` 与 `null` 在源里都能解析成同一张榜
  ///   （起点 catId=-1），但旧实现直接拿原文拼 key，于是同一张榜被拆成
  ///   两个系列（`月票榜.全站_..` vs `月票榜_..`），跨日趋势对比从此断裂。
  ///   归一后同榜的快照才会正确配对成"上期 / 本期"。
  String get seriesKey => '$source|$board|${_normCategory(category) ?? '-'}';

  /// '全站'/'全部'/空 一律视为"不区分题材"。
  static String? _normCategory(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s == '全站' || s == '全部' || s == '所有') return null;
    return s;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'source': source,
        'board': board,
        'category': category,
        'series_key': seriesKey,
        'date': dateKey,
        'fetched_at': fetchedAt.toIso8601String(),
        'count': count,
        'ok': ok,
        'quality_summary': result.quality?.summary,
        'problems': result.quality?.problems ?? const [],
        'robots': result.robotsVerdict,
        'source_url': result.sourceUrl,
        'file': file.uri.pathSegments.last,
      };
}

class SnapshotIndex {
  SnapshotIndex._(this.items);

  final List<SnapshotMeta> items;

  /// 用已有的快照列表构造（GUI 里视图模型已经持有列表，避免重复读盘）。
  factory SnapshotIndex.fromItems(List<SnapshotMeta> items) =>
      SnapshotIndex._(items);

  SnapshotMeta? byId(int id) {
    for (final m in items) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 同系列的其它快照（按时间倒序，不含自己）—— 用作默认对比基准
  List<SnapshotMeta> series(SnapshotMeta m, {bool excludeSelf = true}) {
    final out = items
        .where((x) => x.seriesKey == m.seriesKey && (!excludeSelf || x.id != m.id))
        .toList()
      ..sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
    return out;
  }

  /// 从目录加载。坏文件跳过但记进 errors，**不静默吞掉**。
  static SnapshotIndex load(String root, {List<String>? errors}) {
    final dir = Directory('$root${Platform.pathSeparator}扫榜');
    final items = <SnapshotMeta>[];
    if (!dir.existsSync()) return SnapshotIndex._(items);
    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        // ★ 必须排掉索引自身（`out/扫榜/index.json`）。
        //   它是"快照清单"，不是快照 —— 顶层没有 `result` 字段，
        //   留着它每加载一次就会往 errors 里塞一条"缺 result 字段"，
        //   界面上表现为"1 个快照文件解析失败"，而实际上一个都没坏。
        .where((f) => !_isIndexFile(f))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    // ★★ id 必须**稳定**。原来这里发一遍、排序后又按位置重发一遍
    //   （`id: i + 1`），于是每采一份新快照、全体 id 都往后挪一位 ——
    //   而 `selectedId` 是跨 reload 保留的，明细页/导出会**悄悄切到另一份快照**。
    //   现在按文件路径算一个稳定 id（FNV-1a），路径不变 id 就不变。
    final usedIds = <int>{};
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
        var sid = _stableIdOf(f.path);
        // 极小概率的哈希碰撞：往后挪，保证同一批里唯一
        while (usedIds.contains(sid)) {
          sid = sid == 0xFFFFFFFF ? 1 : sid + 1;
        }
        usedIds.add(sid);
        items.add(SnapshotMeta(
            id: sid,
            result: RankResult.fromJson(r.cast<String, Object?>()),
            file: f));
      } on Object catch (e) {
        errors?.add('${f.path}: 解析失败 $e');
      }
    }
    // 新→旧，页面默认看到最新（**只排序，不再重发 id**）
    items.sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
    return SnapshotIndex._(items);
  }
}

/// 由文件路径算一个**稳定** id（FNV-1a 32 位）。
///
/// 不用 `dart:math` 的 hash：那个每次进程启动都不同（有随机种子），
/// 跨会话就不稳定了 —— 而"跨会话稳定"正是这里要的东西。
int _stableIdOf(String path) {
  var h = 0x811C9DC5;
  for (final c in path.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h == 0 ? 1 : h;
}

/// 是不是"索引文件"而不是快照。
///
/// 索引固定落在 `扫榜/index.json`（见 `SnapshotIndexFile.indexPath`），
/// 所以只认"直接位于 `扫榜/` 下的 index.json"；快照在平台子目录里，
/// 即便哪天真叫 index.json 也不会被误伤。
bool _isIndexFile(File f) {
  final segs = f.uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return false;
  final name = segs.last.toLowerCase();
  if (name != 'index.json') return false;
  // `…/扫榜/index.json` → 倒数第二段应当是 `扫榜`
  if (segs.length < 2) return true;
  return segs[segs.length - 2] == '扫榜';
}

String _ymd(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

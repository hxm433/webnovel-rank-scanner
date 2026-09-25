/// 采集服务层 —— **CLI 与 GUI 共用的唯一入口**。
///
/// 原来 `bin/scan.dart` 把「建白名单 / 建限速器 / 建适配器 / 跑一个榜 / 存快照」
/// 全写在 main 里，GUI 想复用只能抄一遍 —— 抄一遍就意味着护栏有两份实现，
/// 迟早有一份会被改漏（限速器尤其危险：两个实例等于风控阈值翻倍）。
///
/// 所以把这段抽到这里，`scan.dart` 与 GUI 都只调 [ScanService]。
library;

import 'dart:ffi';
import 'dart:io';

import 'guard.dart';
import 'models.dart';
import 'snapshot_index_file.dart';
import 'sources.dart';
import 'store.dart';

/// 一个榜的采集耗时与结果，供 GUI 显示进度用。
class ScanOutcome {
  ScanOutcome({
    required this.result,
    required this.elapsed,
    required this.error,
  });
  final RankResult result;
  final Duration elapsed;

  /// 非 null = 这次没成功（网络/策略/解析）。result 里也有 quality，但
  /// 这里是"异常文本"，两者互补：quality 给用户看，error 给日志看。
  final String? error;

  bool get hasData => result.entries.isNotEmpty;
}

/// 采集服务。**一个实例对应一份护栏配置**：
/// 限速器是实例级单例，风控按 IP 记，所以整个进程只应存在一个
/// [ScanService]（GUI 里就是全局那一个）。
/// 按**保留后的条数**重算质量摘要。
///
/// 只动"计数"与"摘要里那句数字"，`problems` 原样保留（那些是抓取过程的问题，
/// 与截断无关）。[kept] == [total] 时原样返回，不做无谓改动。
RankQuality _recountQuality(RankQuality? q, int kept, int total) {
  if (q == null) {
    return RankQuality(ok: kept > 0, validCount: kept, totalCount: total);
  }
  if (kept == total) return q;
  final base = q.summary == null || q.summary!.isEmpty ? '' : '${q.summary}；';
  return RankQuality(
    ok: q.ok && kept > 0,
    validCount: kept,
    totalCount: total,
    summary: '${base}按本数上限保留 $kept/$total 条（其余未落盘）',
    problems: q.problems,
  );
}

class ScanService {
  ScanService({
    required this.outRoot,
    Duration minInterval = const Duration(seconds: 2),
    this.onProgress,
  })  : _whitelist = DomainWhitelist(const [
          'm.qidian.com', 'www.qidian.com', 'qidian.com',
          'www.qimao.com', 'qimao.com',
          'www.jjwxc.net', 'jjwxc.net',
          'fanqienovel.com',
        ]),
        _limiter = RateLimiter(minInterval: minInterval) {
    _fetcher = Fetcher(
      whitelist: _whitelist,
      robots: RobotsGuard(),
      limiter: _limiter,
    );
    store = RankStore(root: outRoot);
    // ★ 适配器只建一次：番茄的 rank_version / 分类表 / 字体哈希缓存在实例上，
    //   重复建会重复请求 /rank 页。
    adapters = {
      'qidian': QidianSource(_fetcher),
      'fanqie': FanqieSource(_fetcher),
      'qimao': QimaoSource(_fetcher),
      'jjwxc': JinjiangSource(_fetcher),
    };
  }

  final String outRoot;
  final DomainWhitelist _whitelist;
  final RateLimiter _limiter;
  late final Fetcher _fetcher;
  late final RankStore store;
  late final Map<String, RankSourceAdapter> adapters;

  /// 进度回调：GUI 用它刷新"正在扫哪个榜"。CLI 传 null 即可。
  void Function(String message)? onProgress;

  /// 最近一次请求的 robots 判定文本（随结果一起出去给人看）。
  String? get lastVerdict => _fetcher.lastVerdict;

  void log(String msg) => onProgress?.call(msg);

  /// 本地枚举，不联网：把"猜榜名"变成"查字典"。
  List<BoardInfo> enumerateBoards() {
    final out = <BoardInfo>[];
    for (final a in adapters.values) {
      out.add(BoardInfo(
        sourceId: a.sourceId,
        displayName: a.displayName,
        boards: a.supportedBoards,
        categories: switch (a) {
          QidianSource() => QidianSource.categories.keys.toList(),
          _ => const <String>[],
        },
      ));
    }
    return out;
  }

  /// 番茄的分类表是**运行时从 /rank 页拿的**（不联网就没有），
  /// 所以单独开一个异步入口给 GUI 填充下拉框。
  Future<List<String>> fanqieCategories(String gender) async {
    final fs = adapters['fanqie'];
    if (fs is! FanqieSource) return const [];
    try {
      final cs = await fs.categoriesOf(gender);
      return [for (final c in cs) '${c['name']}'];
    } on Object {
      return const [];
    }
  }

  /// 采集单个榜。**不抛异常**：所有失败都包进 [ScanOutcome]，
  /// 因为 GUI 里一个榜失败不该让整个界面崩掉。
  Future<ScanOutcome> scanOne({
    required String source,
    required String board,
    String? category,
    int limit = 20,
  }) async {
    final started = DateTime.now();
    final adapter = adapters[source];
    if (adapter == null) {
      return ScanOutcome(
        result: _failed(source, board, category, '未知数据源「$source」'),
        elapsed: Duration.zero,
        error: 'unknown source',
      );
    }

    try {
      final q = RankQuery(
        source: source,
        board: board,
        limit: limit,
        categoryName: category,
      );
      final outcome = await adapter.fetch(q);
      // ★ 截断归服务层，不归适配器（否则 truncated 永远 false）
      final all = outcome.entries;
      final entries = all.take(limit).toList();
      final cut = all.length > limit;
      final result = RankResult(
        query: q,
        entries: entries,
        fetchedAt: DateTime.now(),
        truncated: cut,
        // ★★ 截断之后 quality 的**数字必须跟着改**。
        //   原来是把适配器给的 quality 原样带过来：落盘 20 条、`truncated:true`，
        //   而 quality 里写着 `valid_count: 3000`（晋江一次给 3000 条）——
        //   界面拿它当"质量"显示，`sparse` 也按 3000 判，
        //   于是"20 条（已截断）"和"3000 行"自相矛盾。
        quality: _recountQuality(outcome.quality, entries.length, all.length),
        sourceUrl: outcome.url,
        robotsVerdict: lastVerdict,
      );
      // 结构上禁止携带正文字段
      MetadataOnlyPolicy.checkFields([
        for (final e in entries) ...e.extra.keys,
      ]);
      // ★ 空结果不落盘：否则会把当天已抓到的好快照覆盖成空文件
      if (entries.isNotEmpty) {
        final snap = await store.save(result);
        _indexSnapshot(snap);
      }
      return ScanOutcome(
        result: result,
        elapsed: DateTime.now().difference(started),
        error: entries.isEmpty ? (result.quality?.summary ?? 'empty') : null,
      );
    } on RankPolicyException catch (e) {
      return ScanOutcome(
        result: _blocked(source, board, category, e),
        elapsed: DateTime.now().difference(started),
        error: 'POLICY ${e.code.name}: ${e.reason}',
      );
    } on Object catch (e) {
      return ScanOutcome(
        result: _failed(source, board, category, '$e'),
        elapsed: DateTime.now().difference(started),
        error: '$e',
      );
    }
  }

  /// 把刚落盘的快照登记进索引（`out/扫榜/index.json`）。
  ///
  /// ★ 为什么采集层要管索引：索引是"这次扫了什么、历史上扫过什么"的唯一
  ///   权威清单，时间线与保留策略都读它。若只在采集后写数据文件、不更新索引，
  ///   就会出现"文件在磁盘上、但侧栏/时间线里没有"的割裂。
  ///   （自愈兜底见 `SnapshotIndexFile._reconcile`，但那只是保险，不是主路径。）
  ///
  /// 写索引失败**不算这次采集失败**：快照本身已经安全落盘了，
  /// 索引落后会在下次 load 时被自动补齐 —— 所以这里只记一条进度消息。
  void _indexSnapshot(RankSnapshot snap) {
    try {
      final idx = SnapshotIndexFile.load(outRoot);
      final rel = SnapshotIndexFile.relPathOf(outRoot, snap.path);
      idx.upsert(SnapshotIndexFile.fromResult(snap.result, relFile: rel)).save();
    } on Object catch (e) {
      log('索引登记失败（快照已存盘，下次载入会自动补齐）：$e');
    }
  }

  /// 一轮批量采集。是 GUI「开始扫榜」按钮的实际执行体。
  Future<List<ScanOutcome>> scanBatch(List<ScanTarget> targets) async {
    final out = <ScanOutcome>[];
    for (final t in targets) {
      log('正在扫 ${t.source}/${t.board}${t.category == null ? '' : '/${t.category}'}');
      final r = await scanOne(
        source: t.source,
        board: t.board,
        category: t.category,
        limit: t.limit,
      );
      log('${r.hasData ? '完成' : '未取到'} '
          '${t.source}/${t.board} ${r.result.entries.length} 条 '
          '(${r.elapsed.inMilliseconds}ms)');
      out.add(r);
    }
    return out;
  }

  RankResult _blocked(String s, String b, String? c, RankPolicyException e) =>
      RankResult(
        query: RankQuery(source: s, board: b, categoryName: c),
        entries: const [],
        fetchedAt: DateTime.now(),
        quality: RankQuality(
          ok: false,
          validCount: 0,
          totalCount: 0,
          summary: switch (e.code) {
            RankPolicyCode.domainNotAllowed => '域名不在白名单',
            RankPolicyCode.robotsDenied => 'robots 协议禁止',
            RankPolicyCode.metadataOnlyViolated => '试图携带正文字段',
            RankPolicyCode.blockedByTechMeasure => '检测到反爬技术措施，已停手（不做绕过）',
            _ => '策略拦截',
          },
          problems: [e.reason],
        ),
      );

  RankResult _failed(String s, String b, String? c, String err) => RankResult(
        query: RankQuery(source: s, board: b, categoryName: c),
        entries: const [],
        fetchedAt: DateTime.now(),
        quality: RankQuality(
          ok: false,
          validCount: 0,
          totalCount: 0,
          summary: '网络或解析失败',
          problems: [err],
        ),
      );
}

/// 一个可勾选的采集目标。
class ScanTarget {
  const ScanTarget({
    required this.source,
    required this.board,
    this.category,
    this.limit = 20,
  });
  final String source;
  final String board;
  final String? category;

  /// 这个榜要抓多少本。UI 里每个已选榜可各自设定；
  /// 上限由各数据源的能力决定（起点 www 站可达 500，其余多为 20）。
  final int limit;
}

/// 每个数据源**单榜最多能抓多少本**（UI 用它给步进器定上限并提示）。
///
/// ★ 这是"能力上限"，不是"建议值"：起点 www 站实测 25 页 × 20 = 500；
///   移动站/其它站只给一页 20 条。UI 拿它当步进器上限，超了也不会更准。
const Map<String, int> sourceLimitCap = {
  'qidian': 500,
  'fanqie': 100,
  'qimao': 50,
  'jjwxc': 50,
};

/// 给某个数据源的默认本数（保守值，避免第一次就扫 500 本等太久）。
const Map<String, int> sourceDefaultLimit = {
  'qidian': 20,
  'fanqie': 20,
  'qimao': 20,
  'jjwxc': 20,
};

/// 一个数据源的可用榜与题材（给 GUI 建树用）。
class BoardInfo {
  const BoardInfo({
    required this.sourceId,
    required this.displayName,
    required this.boards,
    required this.categories,
  });
  final String sourceId;
  final String displayName;
  final List<String> boards;
  final List<String> categories;
}

/// 判断标准输出是不是能安全打印中文的终端。
///
/// ★ 实测：Windows 控制台默认代码页是 GBK（936），直接 print 中文会乱码，
///   所以 CLI 里非 ASCII 要转义；但 GUI 窗口里必须原样输出。
///
/// 旧实现读环境变量 `CHCP` —— 那个变量**根本不存在**（`chcp` 是 cmd 内置命令，
/// 不导出环境变量），于是恒为 false，即便用户在 UTF-8 终端里也照样把中文转成
/// `\uXXXX`，报告里中文全是转义码（审查报告第 18 条）。
///
/// 正确做法：直接问系统当前控制台输出代码页 [GetConsoleOutputCP]。
/// 65001 = UTF-8 → 可安全打印中文；其它（936/GBK、437 等）→ 走转义。
bool get consoleIsUtf8Safe {
  if (!Platform.isWindows) return true;
  final env = Platform.environment;
  // 允许显式覆盖，方便测试与"我知道自己在干嘛"的场景。
  final forced = env['SCAN_FORCE_UTF8'];
  if (forced == '1' || forced == 'true') return true;
  if (forced == '0' || forced == 'false') return false;
  final cp = _consoleOutputCodePage();
  // 取不到（无控制台 / 非 Windows 终端）时保守当作不安全，保持旧行为。
  if (cp == null) return false;
  return cp == 65001;
}

int? _consoleOutputCodePage() {
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final getCp = k32.lookupFunction<Uint32 Function(), int Function()>(
        'GetConsoleOutputCP');
    final cp = getCp();
    return cp == 0 ? null : cp;
  } catch (_) {
    return null;
  }
}

/// 扫榜可行性 Demo 入口（CLI）。
///
/// 用法：
///   dart run bin/scan.dart boards
///   dart run bin/scan.dart scan --source qidian --board 月票榜 --category 玄幻
///   dart run bin/scan.dart sweep                     # 跑一轮周扫，产出报告
///   dart run bin/scan.dart sweep --selftest-trend    # 额外验证差分渲染
///
/// ★ 采集逻辑**不在这里**：白名单/robots/限速/适配器/存快照全在
///   `lib/scan_service.dart`，GUI 用的是同一份。这里只负责参数解析与报告渲染。
///
/// 退出码约定（借 oh-story 的红线）：0 全成 / 1 零产物 / 2 部分产物。
library;

import 'dart:io';

import '../lib/analysis.dart';
import '../lib/models.dart';
import '../lib/scan_service.dart';

late final ScanService svc;

Future<void> main(List<String> argv) async {
  final args = _Args(argv);
  final outRoot = args.get('out') ?? 'out';
  final cmd = argv.isEmpty ? 'help' : argv[0];

  if (cmd == 'help') {
    _usage();
    return;
  }

  svc = ScanService(
    outRoot: outRoot,
    // ★ 全程只有这一个限速器实例：风控按 IP 记，多实例等于变相放宽
    minInterval: Duration(milliseconds: args.intOf('ms') ?? 2000),
  );

  switch (cmd) {
    case 'boards':
      _printBoards();
      break;
    case 'scan':
      await _cmdScan(args, outRoot);
      break;
    case 'sweep':
      await _cmdSweep(args, outRoot);
      break;
    default:
      _usage();
  }
}

void _usage() {
  stdout.writeln('''
rank-scan demo  (pure Dart, zero third-party deps)

  dart run bin/scan.dart boards
  dart run bin/scan.dart scan --source qidian --board <name> [--category <name>] [--limit 20]
  dart run bin/scan.dart sweep [--selftest-trend] [--limit 20] [--ms 2000] [--out out]

exit code: 0 all ok / 1 nothing produced / 2 partial''');
}

/// 两段式第一步：**本地枚举，不联网**（把"猜榜名"变成"查字典"）
void _printBoards() {
  stdout.writeln('sources & boards (local enumeration, no network):');
  for (final s in svc.enumerateBoards()) {
    stdout.writeln('\n[${s.sourceId}] ${_esc(s.displayName)}');
    for (final b in s.boards) {
      stdout.writeln('  - ${_esc(b)}');
    }
    if (s.categories.isNotEmpty) {
      stdout.writeln('  categories: ${_esc(s.categories.join(' '))}');
    } else if (s.sourceId == 'fanqie') {
      stdout.writeln('  (fanqie categories are fetched live from /rank page)');
    }
  }
  stdout.writeln('\nthen: scan --source <id> --board <name>');
}

Future<void> _cmdScan(_Args args, String outRoot) async {
  final source = args.get('source') ?? '';
  if (!svc.adapters.containsKey(source)) {
    stdout.writeln('unknown source: "$source"  (run: boards)');
    exit(1);
  }
  final r = await svc.scanOne(
    source: source,
    board: args.get('board') ?? '',
    category: args.get('category'),
    limit: args.intOf('limit') ?? 20,
  );
  _echo(r);
  final report = _render([_Run(r.result)], []);
  stdout.writeln('report: ${_writeReport(outRoot, report)}');
  exit(r.result.entries.isEmpty ? 1 : 0);
}

void _echo(ScanOutcome r) {
  final q = r.result.query;
  stdout.writeln('[${r.result.quality?.ok == true ? 'ok ' : 'warn'}] ${q.source} '
      'board=${_esc(q.board)} cat=${_esc(q.categoryName ?? '-')} '
      'n=${r.result.entries.length}'
      '${r.result.truncated ? ' (truncated)' : ''}');
}

Future<void> _cmdSweep(_Args args, String outRoot) async {
  final limit = args.intOf('limit') ?? 20;
  final collected = <_Run>[];
  final failures = <String>[];

  Future<void> go(String source, String board, String? category) async {
    final r = await svc.scanOne(
        source: source, board: board, category: category, limit: limit);
    _echo(r);
    collected.add(_Run(r.result));
    if (r.result.entries.isEmpty) {
      failures.add('${source} ${_esc(board)}/${_esc(category ?? '-')} -> '
          '${_esc(r.error ?? r.result.quality?.summary ?? 'empty')}');
    }
  }

  stdout.writeln('== sweep start (limit=$limit, min interval 2000ms) ==');
  // 起点：全站四榜（风向 + 付费认可 + 编辑口味）
  for (final b in ['畅销榜', '月票榜', '签约作者新书榜', '新人作者新书榜']) {
    await go('qidian', b, '全站');
  }
  // 起点：题材榜（赛道饱和度）—— 相对原版实现的新增通道
  for (final c in ['玄幻', '都市', '仙侠', '科幻']) {
    await go('qidian', '畅销榜', c);
  }
  await go('qidian', '月票榜', '玄幻');
  // 免费平台
  await go('qimao', '男频大热榜', null);
  await go('qimao', '女频大热榜', null);
  // 番茄：分类表是**运行时从 /rank 页拿的**，所以取前 3 个分类各扫一次
  //（只扫默认第一个分类的话，"题材占比 100%"是采样假象，不是市场结论）
  final fqCats = await svc.fanqieCategories('1');
  if (fqCats.isEmpty) {
    failures.add('fanqie category enumeration failed');
  } else {
    for (final c in fqCats.take(3)) {
      await go('fanqie', '男频阅读榜', c);
    }
  }
  // 女频付费
  await go('jjwxc', '总分排行榜', null);
  await go('jjwxc', '新晋作者榜', null);

  final trendSection = args.has('selftest-trend') ? _selftestTrend(collected) : '';
  final report = _render(collected, failures, trendSection: trendSection);
  final path = _writeReport(outRoot, report);
  final okCount = collected.where((c) => c.result.entries.isNotEmpty).length;
  stdout.writeln('== sweep done: ok=$okCount empty_or_blocked=${failures.length} '
      'snapshots+report under "$outRoot/" ==');
  stdout.writeln('report: $path');
  if (collected.every((c) => c.result.entries.isEmpty)) exit(1);
  exit(failures.isEmpty ? 0 : 2);
}

/// 用两份**真实但不同榜**的数据验证差分渲染（不是趋势结论，只是引擎自检）
String _selftestTrend(List<_Run> runs) {
  RankResult? pick(String source, String board, String? cat) {
    for (final r in runs) {
      if (r.result.query.source == source &&
          r.result.query.board == board &&
          r.result.query.categoryName == cat &&
          r.result.entries.isNotEmpty) {
        return r.result;
      }
    }
    return null;
  }

  final prev = pick('qidian', '畅销榜', '玄幻');
  final curr = pick('qidian', '月票榜', '玄幻');
  if (prev == null || curr == null) return '';
  return const RankAnalyzer()
      .analyze(curr, previous: prev)
      .toMarkdown(sourceName: '起点（玄幻）', board: '畅销榜 → 月票榜',
          note: '★ 自检：两份数据来自**不同榜单**而非不同日期，只验证差分渲染，不构成趋势结论');
}

String _render(List<_Run> runs, List<String> failures, {String trendSection = ''}) {
  final sb = StringBuffer();
  sb.writeln('# 扫榜报告（可行性 Demo）');
  sb.writeln();
  sb.writeln('- 生成时间：${DateTime.now().toIso8601String()}');
  sb.writeln('- 采集方式：纯 Dart `HttpClient` + SSR/接口内嵌 JSON；**无浏览器、无 Cookie、无第三方数据服务**');
  sb.writeln('- 请求前依次过：域名白名单 → robots → 限速（2 秒）；返回后过：风控特征 → 元数据-only');
  sb.writeln('- 快照目录：`out/扫榜/{source}/{榜名[_题材]}_{YYYYMMDD}.json`（同日覆盖、跨日独立）');
  sb.writeln();
  sb.writeln('> ⚠️ **各平台指标口径不同**（起点=月票/推荐/字数，番茄=在读，七猫=热度，晋江=积分），'
      '**禁止跨平台比大小**。');
  sb.writeln();

  sb.writeln('## 一、总览');
  sb.writeln();
  sb.writeln('| 数据源 | 榜单 | 题材 | 条数 | 质量摘要 | robots 判定 |');
  sb.writeln('|---|---|---|---|---|---|');
  for (final r in runs) {
    final q = r.result;
    sb.writeln('| ${q.query.source} | ${q.query.board} | ${q.query.categoryName ?? '-'} '
        '| ${q.entries.length} | ${q.quality?.summary ?? '-'} | ${q.robotsVerdict ?? '-'} |');
  }
  sb.writeln();

  if (failures.isNotEmpty) {
    sb.writeln('## 二、空结果或被拦截');
    sb.writeln();
    for (final f in failures) {
      sb.writeln('- $f');
    }
    sb.writeln();
  }

  sb.writeln('## 三、逐榜分析（确定性统计，代码可复现）');
  sb.writeln();
  const analyzer = RankAnalyzer();
  for (final r in runs) {
    if (r.result.entries.isEmpty) continue;
    final q = r.result.query;
    sb.writeln(analyzer.analyze(r.result).toMarkdown(
        sourceName: _sourceName(q.source),
        board: q.categoryName == null ? q.board : '${q.board} · ${q.categoryName}'));
  }

  final merged = <String, List<RankEntry>>{};
  for (final r in runs) {
    for (final e in r.result.entries) {
      final c = (e.category ?? '').trim();
      if (c.isEmpty) continue;
      (merged[c] ??= []).add(e);
    }
  }
  sb.writeln('## 四、本轮跨榜题材汇总');
  sb.writeln();
  sb.writeln('> ⚠️ 本表**混合了各平台自己的题材命名**（起点"玄幻/都市"、番茄"西方奇幻/东方仙侠/科幻末世"、'
      '晋江"言情"），三者不是同一套分类体系，"出现次数"也只能反映**本轮扫了哪些榜**，'
      '不代表全平台热度。要严谨结论请按平台分别统计。');
  sb.writeln();
  sb.writeln('| 题材 | 出现次数 | 最好名次 | 平均字数(万字) |');
  sb.writeln('|---|---|---|---|');
  final rows = merged.entries.map((e) {
    final w = e.value.map((x) => x.metrics['words']).whereType<num>().toList();
    return [
      e.key,
      e.value.length,
      e.value.map((x) => x.rank).reduce((a, b) => a < b ? a : b),
      w.isEmpty
          ? '-'
          : (w.reduce((a, b) => a + b) / w.length / 10000).toStringAsFixed(1),
    ];
  }).toList()
    ..sort((a, b) => (b[1] as int).compareTo(a[1] as int));
  for (final r in rows.take(18)) {
    sb.writeln('| ${r[0]} | ${r[1]} | ${r[2]} | ${r[3]} |');
  }
  sb.writeln();

  if (trendSection.isNotEmpty) {
    sb.writeln('## 五、差分引擎自检');
    sb.writeln();
    sb.writeln(trendSection);
  }

  sb.writeln('## ${trendSection.isEmpty ? '五' : '六'}、能支撑什么判断 / 不能支撑什么');
  sb.writeln();
  sb.writeln('**能**：题材分布与饱和度、新书风向（签约/新人榜）、书名与子分类热词、'
      '跨快照排名升降、字数体量区间、完结状态分布。');
  sb.writeln();
  sb.writeln('**不能**：起点首订/均订/追读（付费侧数据，公开榜单页没有）；'
      '番茄书名的字体反爬（已用内置映射表还原，但该表绑定字体哈希，'
      '番茄换字体后会退回〔名待补〕而不是猜）；'
      '单日排名波动的解读（免费平台日入库量巨大，须连续多期才可比）。');
  sb.writeln();
  sb.writeln('## 附：留给模型的解读任务');
  sb.writeln();
  sb.writeln('把上面的**数字**交给模型，只做三件事：为什么这类能爆 → 差异化定位 → 风险与验证动作。'
      '样本 <15 条或质量摘要含"未解析/拦截"时，**禁止输出"可行性=高"**。');
  return sb.toString();
}

String _sourceName(String id) => switch (id) {
      'qidian' => '起点',
      'fanqie' => '番茄',
      'qimao' => '七猫',
      'jjwxc' => '晋江',
      _ => id,
    };

String _writeReport(String outRoot, String content) {
  final n = DateTime.now();
  final dir = Directory('$outRoot/reports')..createSync(recursive: true);
  final path = '${dir.path}${Platform.pathSeparator}'
      'report_${n.year}${_p(n.month)}${_p(n.day)}_${_p(n.hour)}${_p(n.minute)}.md';
  File(path).writeAsStringSync(content, flush: true);
  return path.replaceAll('\\', '/');
}

String _p(int v) => v.toString().padLeft(2, '0');

/// 控制台若不支持 UTF-8（默认 GBK），中文必乱码 —— 此时进度行只输出 ASCII
/// （非 ASCII 转 `\uXXXX`）。★ 改成**按实际控制台代码页动态判断**：
/// 在已经 `chcp 65001` 的终端里就原样输出中文，不再一律转义成看不懂的 `\uXXXX`
/// （审查报告第 18 条）。判断逻辑见 [consoleIsUtf8Safe]。
String _esc(String s) {
  if (consoleIsUtf8Safe) return s.replaceAll(RegExp(r'\s+'), '_');
  final sb = StringBuffer();
  for (final r in s.runes) {
    if (r < 128) {
      sb.writeCharCode(r);
    } else {
      sb.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
    }
  }
  return sb.toString().replaceAll(RegExp(r'\s+'), '_');
}

class _Run {
  _Run(this.result);
  final RankResult result;
}

class _Args {
  _Args(List<String> argv) {
    for (var i = 1; i < argv.length; i++) {
      final a = argv[i];
      if (!a.startsWith('--')) continue;
      final key = a.substring(2);
      final nxt = i + 1 < argv.length ? argv[i + 1] : null;
      if (nxt == null || nxt.startsWith('--')) {
        flags.add(key);
      } else {
        map[key] = nxt;
        i++;
      }
    }
  }
  final Map<String, String> map = {};
  final Set<String> flags = {};

  String? get(String k) => map[k];
  bool has(String k) => flags.contains(k);
  int? intOf(String k) => map[k] == null ? null : int.tryParse(map[k]!);
}

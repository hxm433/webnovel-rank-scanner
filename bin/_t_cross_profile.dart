/// 跨平台题材画像回归（第 22 轮）。
///
/// 用户要求："跨榜分析用榜单上小说分类的占比，分析每个网站主流是什么小说，
/// 对比其他网站"。跨平台能比的只有**题材数**与**集中度**（各平台分类体系不同，
/// 名字对不齐），所以这两个口径必须算得对、且只有一份实现。
///
/// 运行：dart run bin/_t_cross_profile.dart [数据目录]
library;

import 'dart:io';

import '../lib/ui/main_window.dart';
import '../lib/ui/theme.dart';
import '../lib/ui/view_model.dart';

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

void main(List<String> args) {
  final root = args.isNotEmpty ? args[0] : 'out';
  stdout.writeln('== 跨平台题材画像 ==');

  // ── ① 口径本身 ──
  stdout.writeln('\n── ① 画像口径 ──');
  final p = PlatformCategoryProfile('qidian', [
    CategoryStat('都市', 36, 1, null),
    CategoryStat('玄幻', 62, 1, null),
    CategoryStat('仙侠', 31, 3, null),
    CategoryStat('科幻', 26, 2, null),
    CategoryStat('游戏', 1, 50, null),
  ]);
  _check('按条数降序排列', p.sorted.first.category == '玄幻',
      p.sorted.map((c) => c.category).join(','));
  _check('总数 = 各项之和', p.total == 36 + 62 + 31 + 26 + 1, '${p.total}');
  _check('题材数正确', p.categoryCount == 5, '${p.categoryCount}');
  _check('Top1 占比 = 最大项 / 总数',
      (p.top1Share - 62 / 156).abs() < 1e-9, '${p.top1Share}');
  _check('Top3 占比 = 前三之和 / 总数',
      (p.top3Share - (62 + 36 + 31) / 156).abs() < 1e-9, '${p.top3Share}');
  _check('Top3 ≥ Top1（集中度是累计的）', p.top3Share >= p.top1Share);
  _check('Top3 ≤ 1', p.top3Share <= 1.0);
  _check('一句话摘要带百分比',
      p.topSummary() == '玄幻 40% · 都市 23% · 仙侠 20%', p.topSummary());
  _check('多题材的平台不算 coarse', !p.coarse);

  // 只有一个题材 → 集中度必然 100%，但那不是"极度集中"，是"没细分"
  final one = PlatformCategoryProfile('jjwxc', [CategoryStat('言情', 55, 1, null)]);
  _check('只有一个题材时 coarse = true（界面会标"未细分题材"）', one.coarse);
  _check('coarse 平台的 Top3 = 100%', (one.top3Share - 1.0).abs() < 1e-9);

  // 空数据不能除零
  final empty = PlatformCategoryProfile('x', const []);
  _check('空画像不除零（占比返回 0）',
      empty.top1Share == 0 && empty.top3Share == 0);

  // ── ② 组装：跳过没有题材数据的平台 ──
  stdout.writeln('\n── ② 组装 ──');
  final profs = buildPlatformProfiles({
    'a': [CategoryStat('甲', 3, 1, null)],
    'b': const <CategoryStat>[],
    'c': [CategoryStat('乙', 0, 0, null)],
    'd': [CategoryStat('丙', 2, 1, null), CategoryStat('丁', 1, 2, null)],
  });
  _check('空平台被跳过', !profs.any((x) => x.source == 'b'),
      profs.map((x) => x.source).join(','));
  _check('总数为 0 的平台被跳过', !profs.any((x) => x.source == 'c'),
      profs.map((x) => x.source).join(','));
  _check('有数据的平台都在', profs.length == 2, profs.length.toString());

  // ── ③ 真实数据 ──
  stdout.writeln('\n── ③ 真实数据（$root）──');
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();
  final all = mw.vm?.all ?? const [];
  if (all.isEmpty) {
    stdout.writeln('  (跳过：数据目录里没有快照)');
  } else {
    final real = buildPlatformProfiles(mw.vm!.bySource);
    stdout.writeln('  平台画像：');
    for (final x in real) {
      stdout.writeln('    ${x.source.padRight(8)} 题材 ${x.categoryCount}'
          '  条数 ${x.total}  Top1 ${(x.top1Share * 100).toStringAsFixed(0)}%'
          '  Top3 ${(x.top3Share * 100).toStringAsFixed(0)}%'
          '${x.coarse ? "  （未细分题材）" : ""}');
      stdout.writeln('      ${x.topSummary()}');
    }
    _check('真实数据里至少两个平台有题材画像', real.length >= 2,
        real.length.toString());
    _check('每个平台的 Top3 都在 [0,1] 内',
        real.every((x) => x.top3Share >= 0 && x.top3Share <= 1.0));
    _check('每个平台的 Top3 ≥ Top1',
        real.every((x) => x.top3Share >= x.top1Share - 1e-9));
    _check('题材数 ≥ 1 的平台都被保留',
        real.every((x) => x.categoryCount >= 1));
    // 跨榜分析的默认平台应当是"题材最细"的那个（否则上来就是一张空表）
    final widest = real.reduce((a, b) => a.categoryCount >= b.categoryCount ? a : b);
    stdout.writeln('  题材最细的平台：${widest.source}（${widest.categoryCount} 个）');
    _check('默认平台（题材最细）不是 coarse 的',
        !widest.coarse || real.length == 1);
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

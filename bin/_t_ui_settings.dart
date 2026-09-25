/// 界面层回归（第 9 轮）：主题切换 / 设置持久化 / 侧栏折叠与隐藏 / 设置窗的树。
///
/// 这一层最容易出的错是"状态存了但没生效"或"生效了但没存" ——
/// 所以断言分成两半：**改了之后界面状态对不对**、**重开之后还在不在**。
///
/// 运行：dart run bin/_t_ui_settings.dart
library;

import 'dart:convert';
import 'dart:io';

import '../lib/models.dart';
import '../lib/png.dart';
import '../lib/snapshot_index_file.dart';
import '../lib/store.dart';
import '../lib/ui/data_manager.dart';
import '../lib/ui/dialogs.dart';
import '../lib/ui/gdi.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/settings.dart';
import '../lib/ui/theme.dart';

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

RankResult _mk(String source, String board, String? cat, String? catId,
    DateTime at, int n) {
  return RankResult(
    query: RankQuery(
        source: source,
        board: board,
        limit: n,
        categoryName: cat,
        categoryId: catId),
    entries: [
      for (var i = 1; i <= n; i++)
        RankEntry(
          rank: i,
          title: '$board书$i',
          author: '作者$i',
          bookId: '$source-$board-${cat ?? '-'}-$i',
          metrics: {'words': 10000 * i},
        )
    ],
    fetchedAt: at,
  );
}

/// 造一份带索引的临时数据目录。
Future<String> _mkRoot() async {
  final root = Directory.systemTemp.createTempSync('rankscan_ui_').path;
  final store = RankStore(root: root);
  var idx = SnapshotIndexFile.load(root);
  for (var d = 20; d <= 22; d++) {
    for (final spec in const [
      ('qidian', '月票榜', null, null),
      ('qidian', '畅销榜', '玄幻', '21'),
      ('qimao', '男频大热榜', null, null),
    ]) {
      final r = _mk(spec.$1, spec.$2, spec.$3, spec.$4,
          DateTime(2026, 9, d), 5 + d % 3);
      final snap = await store.save(r);
      idx = idx.upsert(SnapshotIndexFile.fromResult(r,
          relFile: SnapshotIndexFile.relPathOf(root, snap.path)));
    }
  }
  idx.save();
  return root;
}

void main() async {
  stdout.writeln('== 界面层回归：主题 / 设置 / 侧栏 / 设置窗树 ==');

  // ── ① 主题 ──
  stdout.writeln('\n── ① 深色 / 浅色 ──');
  Palette.apply(AppTheme.dark);
  final dark = Palette.snapshot();
  Palette.apply(AppTheme.light);
  final light = Palette.snapshot();
  _check('两套色板字段数一致', dark.length == light.length,
      '${dark.length} vs ${light.length}');
  var diff = 0;
  for (final k in dark.keys) {
    if (dark[k] != light[k]) diff++;
  }
  _check('绝大多数颜色真的不同（>30 个）', diff > 30, 'diff=$diff');
  // ★ 对比度性质：浅色主题必须"浅底深字"，深色主题必须"深底浅字"。
  //   断言性质而不是断言具体色值 —— 色值可以调，性质不能破。
  _check('浅色：底比字亮', luminanceOf(light['bg']!) > luminanceOf(light['fg']!) + 0.4,
      'bg=${luminanceOf(light['bg']!).toStringAsFixed(2)} '
      'fg=${luminanceOf(light['fg']!).toStringAsFixed(2)}');
  _check('深色：字比底亮', luminanceOf(dark['fg']!) > luminanceOf(dark['bg']!) + 0.4,
      'bg=${luminanceOf(dark['bg']!).toStringAsFixed(2)} '
      'fg=${luminanceOf(dark['fg']!).toStringAsFixed(2)}');
  _check('浅色的"面"比"底"亮（卡片浮起来）',
      luminanceOf(light['surface']!) > luminanceOf(light['bg']!));
  _check('深色的"面"比"底"亮（同一条分层纪律）',
      luminanceOf(dark['surface']!) > luminanceOf(dark['bg']!));
  _check('浅色投影不是深黑（否则一圈脏边）',
      luminanceOf(light['shadow']!) > 0.5,
      luminanceOf(light['shadow']!).toStringAsFixed(2));
  Palette.apply(AppTheme.dark);
  final back = Palette.snapshot();
  var same = true;
  for (final k in dark.keys) {
    if (dark[k] != back[k]) same = false;
  }
  _check('切回深色与初始逐色一致（apply 幂等）', same);
  _check('theme.toggled 往返', AppTheme.dark.toggled == AppTheme.light &&
      AppTheme.light.toggled == AppTheme.dark);
  _check('fromId 容错（未知值 → 深色）',
      AppTheme.fromId('???') == AppTheme.dark && AppTheme.fromId('light') == AppTheme.light);

  // ── ② 设置持久化 ──
  stdout.writeln('\n── ② 设置持久化 ──');
  final root = await _mkRoot();
  final s = UiSettings();
  _check('默认主题 = 深色', s.theme == AppTheme.dark);
  _check('默认没有任何隐藏/折叠', s.hiddenSeries.isEmpty &&
      s.collapsedSources.isEmpty && s.expandedBoards.isEmpty);
  s.theme = AppTheme.light;
  s.hideSeries('qidian|月票榜|-');
  s.collapsedSources.add('qimao');
  s.expandedBoards.add('qidian|畅销榜');
  _check('save 成功', s.save(root));
  _check('ui.json 已落盘', File(UiSettings.pathOf(root)).existsSync());
  final s2 = UiSettings.load(root);
  _check('主题读回', s2.theme == AppTheme.light);
  _check('隐藏项读回', s2.hiddenSeries.contains('qidian|月票榜|-'));
  _check('侧栏折叠读回', s2.collapsedSources.contains('qimao'));
  _check('榜展开读回', s2.expandedBoards.contains('qidian|畅销榜'));

  // 损坏的文件不能让软件起不来
  File(UiSettings.pathOf(root)).writeAsStringSync('{ 这不是 json');
  final s3 = UiSettings.load(root);
  _check('坏文件 → 退回默认', s3.theme == AppTheme.dark && s3.hiddenSeries.isEmpty);
  _check('坏文件被如实上报', UiSettings.errors.isNotEmpty,
      UiSettings.errors.join(' | '));
  // 字段类型不对也要能活
  File(UiSettings.pathOf(root)).writeAsStringSync(
      jsonEncode({'theme': 'light', 'hidden_series': 'not-a-list', 'collapsed_sources': [1, 'ok']}));
  final s4 = UiSettings.load(root);
  _check('非数组字段被忽略且上报',
      s4.hiddenSeries.isEmpty && UiSettings.errors.isNotEmpty);
  _check('数组里的非字符串项被丢弃',
      s4.collapsedSources.length == 1 && s4.collapsedSources.contains('ok'),
      s4.collapsedSources.join(','));
  _check('同一次加载里 theme 仍生效', s4.theme == AppTheme.light);
  // 复原
  UiSettings().save(root);

  // ── ③ 侧栏：折叠 ──
  stdout.writeln('\n── ③ 侧栏折叠 ──');
  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  mw.reload();
  void paintMw(int w, int h) {
    final buf = BackBuffer(w, h);
    try {
      mw.testSetSize(w, h);
      mw.onPaint(buf.gdi);
    } finally {
      buf.dispose();
    }
  }

  paintMw(1240, 800);
  final allRows = mw.sideItemCount;
  _check('侧栏有 9 份快照（3 榜 × 3 天）', allRows == 9, 'got $allRows');
  final g0 = mw.vm!.groups.firstWhere((g) => g.sourceId == 'qidian');
  _check('起点组 6 份', g0.items.length == 6, '${g0.items.length}');

  mw.toggleSidebarGroup(0); // 折叠第一个分组（起点）
  paintMw(1240, 800);
  _check('折叠起点后可见行少了 6 行', mw.sideItemCount == allRows - 6,
      '${mw.sideItemCount}');
  _check('折叠状态已存盘', mw.settings.collapsedSources.isNotEmpty);
  mw.toggleSidebarGroup(0);
  paintMw(1240, 800);
  _check('再点一次展开回来', mw.sideItemCount == allRows, '${mw.sideItemCount}');

  // ── ④ 侧栏：隐藏（数据还在） ──
  stdout.writeln('\n── ④ 隐藏 = 只是不显示 ──');
  final beforeAll = mw.vm!.all.length;
  // 找到第一行对应的系列并隐藏
  final target = mw.sideRows.first;
  // ★ 改成按**稳定 id** 隐藏：下标口径在滚动后会错位（见 main_window 的注释）
  mw.hideSidebarMeta(mw.sideRows.first.id);
  paintMw(1240, 800);
  _check('可见份数少了 3（该系列 3 天）', mw.vm!.snapshotCount == beforeAll - 3,
      '${mw.vm!.snapshotCount}');
  _check('**数据还在** all 里（份数不变）', mw.vm!.all.length == beforeAll,
      '${mw.vm!.all.length}');
  _check('被隐藏的那份仍能按 id 查到', mw.vm!.all.any((m) => m.id == target.id));
  _check('隐藏状态已存盘', mw.settings.hiddenSeries.contains(target.seriesKey));
  _check('侧栏可见行同步减少', mw.sideItemCount == allRows - 3,
      '${mw.sideItemCount}');
  _check('隐藏份数如实统计', mw.vm!.hiddenCount == 3, '${mw.vm!.hiddenCount}');
  _check('状态栏写明隐藏了几份', mw.statusText.contains('隐藏'), mw.statusText);

  // 隐藏后重开（新建主窗）依然记得
  final mw2 = MainWindow(outRoot: root);
  mw2.reload();
  _check('重开后隐藏仍然生效', mw2.vm!.hiddenCount == 3, '${mw2.vm!.hiddenCount}');

  // 恢复
  mw.unhideSeries(target.seriesKey);
  paintMw(1240, 800);
  _check('恢复显示后可见份数回到 9', mw.vm!.snapshotCount == beforeAll,
      '${mw.vm!.snapshotCount}');
  _check('恢复后隐藏计数归零', mw.vm!.hiddenCount == 0);

  // ── ⑤ 设置窗的树 ──
  stdout.writeln('\n── ⑤ 扫榜设置窗：折叠树 + 三态 ──');
  final dlg = ScanDialogWindow(owner: mw);
  void paintDlg(int w, int h) {
    final buf = BackBuffer(w, h);
    try {
      dlg.testSetSize(w, h);
      dlg.onPaint(buf.gdi);
    } finally {
      buf.dispose();
    }
  }

  paintDlg(1040, 720);
  final rows0 = dlg.treeRows.length;
  final srcRows = dlg.treeRows.where((r) => r.kind == 0).length;
  final boardRows = dlg.treeRows.where((r) => r.kind == 1).length;
  final catRows = dlg.treeRows.where((r) => r.kind == 2).length;
  _check('有 4 个平台行', srcRows == 4, '$srcRows');
  _check('榜行数 = 全部榜（37）', boardRows == 37, '$boardRows');
  _check('★ 榜**默认折叠**：一个题材行都不显示', catRows == 0, '$catRows');
  _check('总行数 = 平台 + 榜', rows0 == srcRows + boardRows, '$rows0');

  // 展开一个榜 → 出现它的题材行
  final boardRow = dlg.treeRows.firstWhere(
      (r) => r.kind == 1 && r.source == 'qidian' && r.board == '月票榜');
  dlg.testToggleCollapse(boardRow);
  paintDlg(1040, 720);
  final cats = dlg.treeRows.where((r) => r.kind == 2).length;
  _check('展开月票榜后出现 14 个题材行', cats == 14, '$cats');
  _check('展开的榜被记下来', dlg.expandedBoards.contains('qidian|月票榜'));

  // 三态：默认勾的是"全站"，所以平台行是"部分选中"
  final srcRow = dlg.treeRows.firstWhere((r) => r.kind == 0 && r.source == 'qidian');
  _check('起点平台行：已选 2 / 共 14 榜', srcRow.total == 14 && srcRow.on == 2,
      'on=${srcRow.on} total=${srcRow.total}');

  // ★ 点榜行 = 只勾"全站"这一档，不是勾满 14 个题材
  dlg.checked.clear();
  final monthRow = dlg.treeRows.firstWhere(
      (r) => r.kind == 1 && r.source == 'qidian' && r.board == '月票榜');
  dlg.testToggleRow(monthRow);
  paintDlg(1040, 720);
  _check('点榜行只勾 1 个键', dlg.checked.length == 1, '${dlg.checked}');
  _check('勾的是"全站"档（不是 14 个题材）',
      dlg.checked.contains('qidian|月票榜|全站'), '${dlg.checked}');
  final targets = dlg.testTargets();
  _check('只产生 1 个采集目标（不是 14 个）', targets.length == 1,
      '${targets.length}');
  _check('目标题材 = 全站', targets.first.category == '全站',
      '${targets.first.category}');

  // 再点一次 → 取消
  dlg.testToggleRow(monthRow);
  _check('再点一次取消勾选', dlg.checked.isEmpty, '${dlg.checked}');

  // 点平台行 = 勾该平台所有榜的默认档
  dlg.checked.clear();
  final qdSrc = dlg.treeRows.firstWhere((r) => r.kind == 0 && r.source == 'qidian');
  dlg.testToggleRow(qdSrc);
  _check('点平台行 = 勾该平台全部 14 个榜', dlg.checked.length == 14,
      '${dlg.checked.length}');
  _check('全部都是"全站"档（没有题材被顺带勾上）',
      dlg.checked.every((k) => k.endsWith('|全站')), '${dlg.checked}');
  dlg.testToggleRow(qdSrc);
  _check('再点平台行 = 全部取消', dlg.checked.isEmpty);

  // ── ⑤b 选中 = 蓝框（不是方框勾选），且数字必须落在蓝框里面 ──
  stdout.writeln('\n── ⑤b 选中样式与"数字在框内" ──');
  dlg.checked.clear();
  dlg.checked.addAll(['qidian|月票榜|全站', 'qidian|畅销榜|全站']);
  paintDlg(1040, 720);
  final selRow = dlg.treeRows.firstWhere(
      (r) => r.kind == 1 && r.source == 'qidian' && r.board == '月票榜');
  final unselRow = dlg.treeRows.firstWhere(
      (r) => r.kind == 1 && r.source == 'qidian' && r.board == '推荐榜');
  _check('选中的榜行 state = 2（会画蓝色高亮框）',
      dlg.testStateOf(selRow) == 2, '${dlg.testStateOf(selRow)}');
  _check('未选的榜行 state = 0', dlg.testStateOf(unselRow) == 0,
      '${dlg.testStateOf(unselRow)}');
  final qd = dlg.treeRows.firstWhere((r) => r.kind == 0 && r.source == 'qidian');
  _check('部分选中的平台行 state = 1', dlg.testStateOf(qd) == 1,
      '${dlg.testStateOf(qd)}');

  // ★ 用户原话："数字 30 往左调整一下，保证在蓝色框内"。
  //   断言的是**几何关系**：右侧控件（本数步进器 / 徽标）必须比行框右缘内收 ≥8px。
  //
  //   ★ 第 10 轮改：本数不再是只读徽标，而是**每行一个可编辑的步进器**，
  //     所以断言的对象从"徽标"换成了"步进器"（要求一样：整块在蓝框内）。
  final rowR = dlg.testRowRect(selRow.id);
  _check('选中行有行框矩形', rowR != null);
  final rs = dlg.testRowStepper('qidian', '月票榜');
  _check('选中行有本数步进器', rs != null);
  if (rowR != null && rs != null) {
    final (minus, value, plus) = rs;
    final gap = rowR.right - plus.right;
    _check('★ 步进器右缘在行框内 ≥8px（数字不会被蓝框切）', gap >= 8,
        'gap=$gap');
    _check('步进器完全落在行框内（四边）',
        minus.left > rowR.left &&
            plus.right < rowR.right &&
            minus.top >= rowR.top &&
            plus.bottom <= rowR.bottom,
        'row=$rowR stepper=[$minus..$plus]');
    _check('值区夹在减号与加号之间',
        minus.right <= value.left && value.right <= plus.left);
  }
  // 平台行的徽标（"2/14"）同样要在行框内
  final srcRow2 = dlg.treeRows.firstWhere((r) => r.kind == 0 && r.source == 'qidian');
  final srcR = dlg.testRowRect(srcRow2.id);
  final srcB = dlg.testBadgeRect(srcRow2.id);
  if (srcR != null && srcB != null) {
    _check('平台行徽标右缘在行框内 ≥8px', srcR.right - srcB.right >= 8,
        'gap=${srcR.right - srcB.right}');
  }

  // 三态的行底色必须不同（全选 = 选中底，部分 = 主色淡底，未选 = 无）
  _check('三态的底色是三个不同的色值',
      {Palette.selected, Palette.accentSoft}.length == 2);

  // ── ⑥ 搜索过滤 ──
  stdout.writeln('\n── ⑥ 搜索过滤 ──');
  dlg.checked.clear();
  dlg.search = '月票';
  paintDlg(1040, 720);
  final hitBoards = dlg.treeRows.where((r) => r.kind == 1).length;
  _check('搜"月票"只剩 1 个榜行', hitBoards == 1, '$hitBoards');
  dlg.search = '玄幻';
  paintDlg(1040, 720);
  _check('搜题材词"玄幻"能命中（题材行展开）',
      dlg.treeRows.any((r) => r.kind == 2 && r.cat == '玄幻'),
      'rows=${dlg.treeRows.length}');
  _check('搜题材词时只列命中的题材行（不是每榜 14 行噪声）',
      dlg.treeRows.where((r) => r.kind == 2).every((r) => r.cat == '玄幻'),
      dlg.treeRows.where((r) => r.kind == 2).map((r) => r.cat).join(','));
  _check('搜"玄幻"命中 14 个榜、每榜 1 行玄幻',
      dlg.treeRows.where((r) => r.kind == 2).length == 14,
      '${dlg.treeRows.where((r) => r.kind == 2).length}');
  dlg.search = '不存在的榜名xyz';
  paintDlg(1040, 720);
  _check('无命中 → 树为空', dlg.treeRows.isEmpty, '${dlg.treeRows.length}');
  dlg.search = '';
  paintDlg(1040, 720);
  // 注意：前面展开过「月票榜」，所以清空搜索后应当比初始多出它的 14 个题材行
  _check('清空搜索后恢复（含已展开的月票榜 14 行）',
      dlg.treeRows.length == rows0 + 14,
      '${dlg.treeRows.length} vs ${rows0 + 14}');

  // 输入法/键盘：走 onChar
  dlg.searchFocus = true;
  for (final ch in '月票'.codeUnits) {
    dlg.onChar(ch);
  }
  _check('onChar 能输入中文', dlg.search == '月票', dlg.search);
  dlg.onKey(0x08); // Backspace
  _check('Backspace 删一个字符', dlg.search == '月', dlg.search);
  dlg.onKey(0x1B); // Esc
  _check('Esc 清空并失焦', dlg.search.isEmpty && !dlg.searchFocus);
  dlg.search = '';
  paintDlg(1040, 720);

  // ── ⑦ 数据管理窗 ──
  stdout.writeln('\n── ⑦ 数据管理窗 ──');
  final dm = DataManagerWindow(owner: mw);
  void paintDm(int w, int h) {
    final buf = BackBuffer(w, h);
    try {
      dm.testSetSize(w, h);
      dm.onPaint(buf.gdi);
    } finally {
      buf.dispose();
    }
  }

  paintDm(1000, 640);
  _check('识别出 3 个系列', dm.testSeriesCount == 3, '${dm.testSeriesCount}');
  _check('默认选中第一个系列', dm.testSelectedSeries != null);
  _check('第一个系列有 3 期', dm.testCurrentCount == 3, '${dm.testCurrentCount}');
  final buckets = DataManagerWindow.buildBuckets(
      SnapshotIndexFile.load(root).entries);
  _check('系列内按期倒序（新→旧）',
      buckets.every((b) =>
          b.entries.length < 2 ||
          b.entries.first.fetchedAt.isAfter(b.entries.last.fetchedAt)));
  _check('系列间按平台固定顺序（起点在七猫前）',
      buckets.first.source == 'qidian', buckets.first.source);
  _check('日期范围标签正确',
      buckets.first.rangeLabel.contains('2026-09-20') &&
          buckets.first.rangeLabel.contains('2026-09-22'),
      buckets.first.rangeLabel);
  _check('紧凑范围标签形如 09-20→09-22',
      buckets.first.shortRangeLabel == '09-20→09-22',
      buckets.first.shortRangeLabel);

  // 删除一期：文件与索引都要少
  final first = buckets.first.entries.first;
  final filePath = '${root}${Platform.pathSeparator}${first.relFile}';
  _check('待删文件存在', File(filePath).existsSync());
  _check('删除成功', dm.testDeleteSnapshot(first.id));
  _check('数据文件真的没了', !File(filePath).existsSync());
  paintDm(1000, 640);
  _check('该系列剩 2 期', dm.testCurrentCount == 2, '${dm.testCurrentCount}');
  final reloaded = SnapshotIndexFile.load(root);
  _check('索引里也没了', !reloaded.entries.any((e) => e.id == first.id));
  _check('其它系列没被波及', reloaded.entries.length == 8,
      '${reloaded.entries.length}');

  // 隐藏 → 主窗侧栏跟着变
  final bucket = buckets.first;
  dm.toggleHidden(bucket.key);
  _check('数据管理窗里标记为隐藏', mw.settings.hiddenSeries.contains(bucket.key));
  paintMw(1240, 800);
  _check('主窗侧栏同步（可见份数减少）',
      mw.vm!.snapshotCount == reloaded.entries.length - 2,
      '${mw.vm!.snapshotCount} vs ${reloaded.entries.length - 2}');
  dm.restoreAllHidden();
  _check('全部恢复后隐藏清空', mw.settings.hiddenSeries.isEmpty);

  // ── ⑧ 窗口按钮图标（深浅两套都要看得见、且共用一个光心）──
  //
  // ★ 这一节来自用户报的两个现象：
  //   ① 浅色主题下"关闭叉看不见"—— 白叉画在白顶栏上，墨迹像素数 = 0；
  //   ② 图标错位 —— 最小化的横线比另两个低 5px。
  //   两条都只能靠**量像素**确认（看图容易把圆角/描边误当成图标）。
  stdout.writeln('\n── ⑧ 窗口按钮图标 ──');
  for (final theme in AppTheme.values) {
    Palette.apply(theme);
    final w3 = MainWindow(outRoot: root);
    Palette.apply(theme);
    w3.reload();
    w3.testSetSize(1240, 200);
    final buf = BackBuffer(1240, 200);
    w3.onPaint(buf.gdi);
    final png = bgraToPng(buf.readBgra(), 1240, 200);
    buf.dispose();
    final img = decodePngBytes(png);
    if (img == null) {
      _check('${theme.label}：截图可解码', false);
      continue;
    }
    int rgbAt(int x, int y) {
      final o = (y * img.width + x) * 4;
      return (img.bgra[o + 2] << 16) | (img.bgra[o + 1] << 8) | img.bgra[o];
    }

    int rgbOf(int cr) =>
        ((cr & 0xFF) << 16) | (cr & 0xFF00) | ((cr >> 16) & 0xFF);
    final header = rgbOf(Palette.headerBg);
    final centers = <double>[];
    const names = ['最小化', '最大化/还原', '关闭'];
    for (var i = 0; i < 3; i++) {
      final x0 = 1240 - Metrics.winBtnInset - Metrics.winBtnW * (3 - i);
      final x1 = x0 + Metrics.winBtnW;
      var ink = 0, minY = 9999, maxY = -1;
      for (var y = 0; y < Metrics.winBtnH; y++) {
        for (var x = x0; x < x1; x++) {
          if (rgbAt(x, y) == header) continue;
          ink++;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
      _check('${theme.label}：${names[i]}图标可见（墨迹 $ink px）', ink > 5,
          'ink=$ink');
      if (ink > 0) centers.add((minY + maxY) / 2);
    }
    if (centers.length == 3) {
      final lo = centers.reduce((a, b) => a < b ? a : b);
      final hi = centers.reduce((a, b) => a > b ? a : b);
      _check('${theme.label}：三个图标共用一个光心（偏差 ≤1px）', hi - lo <= 1,
          'centers=${centers.join(",")}');
    }
  }
  Palette.apply(AppTheme.dark);

  // ── ⑨ "窄长条"不回归：表格行高与侧栏分组头的比例 ──
  //
  // ★ 用户第 14 轮的原话："这两个地方的窄长条很不好看，适当调宽一些"。
  //   两处都是**横条太薄**：表格数据行 34px、侧栏平台分组头 32px。
  //   这一节把判据钉成比例，避免以后又被改回去：
  //     ① 表格行高 ≥ 字号 × 3（原来只满足 ×2.4 的底线，能读但显薄）；
  //     ② 侧栏分组头的**实测高度**要占到侧栏宽度的 16% 以上
  //        （32/250 = 12.8% 就是那条"薄片"；44/250 = 17.6%）。
  stdout.writeln('\n── ⑨ 行高比例（"窄长条"不回归）──');
  _check('表格行高 ≥ 字号 × 3',
      Metrics.rowHeight >= Metrics.fontSize * 3,
      'rowHeight=${Metrics.rowHeight} fontSize=${Metrics.fontSize}');
  _check('表头比数据行更高（有"标题带"的分量）',
      Metrics.headerRowHeight > Metrics.rowHeight,
      '${Metrics.headerRowHeight} vs ${Metrics.rowHeight}');

  Palette.apply(AppTheme.dark);
  final mw4 = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw4.reload();
  mw4.testSetSize(1240, 800);
  final buf4 = BackBuffer(1240, 800);
  mw4.onPaint(buf4.gdi);
  final png4 = bgraToPng(buf4.readBgra(), 1240, 800);
  buf4.dispose();
  final img4 = decodePngBytes(png4);
  if (img4 != null) {
    int rgbAt4(int x, int y) {
      final o = (y * img4.width + x) * 4;
      return (img4.bgra[o + 2] << 16) | (img4.bgra[o + 1] << 8) | img4.bgra[o];
    }

    int rgbOf4(int cr) =>
        ((cr & 0xFF) << 16) | ((cr & 0xFF00) << 8 >> 8) | ((cr >> 16) & 0xFF);
    final alt = rgbOf4(Palette.surfaceAlt);
    // 沿侧栏中线扫一列，找第一段 surfaceAlt 色带 = 第一个平台分组头
    final col = Metrics.sidebarWidth ~/ 2;
    var start = -1;
    var end = -1;
    for (var y = Metrics.headerHeight; y < 800; y++) {
      final hit = rgbAt4(col, y) == alt;
      if (hit && start < 0) start = y;
      if (!hit && start >= 0) {
        end = y;
        break;
      }
    }
    final grpH = end > start ? end - start : 0;
    _check('侧栏平台分组头实测高度 ≥ 40px', grpH >= 40, 'grpH=$grpH');
    final ratio = grpH / Metrics.sidebarWidth;
    _check('分组头高度 / 侧栏宽度 ≥ 16%（不是"薄片"）', ratio >= 0.16,
        '${(ratio * 100).toStringAsFixed(1)}%  (grpH=$grpH, '
        'sidebar=${Metrics.sidebarWidth})');
  }

  // 清场
  try {
    Directory(root).deleteSync(recursive: true);
  } on Object {
    // 临时目录删不掉无所谓
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

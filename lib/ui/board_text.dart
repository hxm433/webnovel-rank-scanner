/// 「榜单明细」单元格文本 —— **界面与导出图共用的唯一口径**。
///
/// ★ 为什么必须抽出来：这两个地方原来各写一份，于是同一份数据在
///   **屏幕上**和**导出的图里**长得不一样（用户原话："导出榜单与软件内的
///   榜单明细差别很大"）。凡是"同一份数据要出现在两个地方"的格式化，
///   都只留一份实现 —— 否则改了界面忘了图，或者反过来，都会静默地不一致。
library;

import '../models.dart';
import '../report_data.dart';
import 'widgets.dart';
import 'win32.dart';

/// 指标列：`月票 12.3万 · 字数 45.6万`（多指标合成一格）。
///
/// ★ 为什么不是"一个指标一列"：一列一个指标时列数随平台变（起点 2 个、
///   番茄 2 个、七猫 1 个…），版面每换一个榜就变一次，而且宽度抢得很凶。
///   合成一格之后，任何平台都是同一套列。
String metricTextOf(RankEntry e, {String? source}) {
  final parts = <String>[];
  for (final en in e.metrics.entries) {
    final label =
        metricLabelFor(en.key, source: source).replaceAll(RegExp('（.*'), '');
    parts.add('$label ${wan(en.value)}');
  }
  // words 放最后（体量不是热度）
  parts.sort((a, b) => a.startsWith('字数') ? 1 : (b.startsWith('字数') ? -1 : 0));
  return parts.isEmpty ? '-' : parts.join(' · ');
}

/// 备注列：`榜变 -1 · 连载` 这类**短字段**。
///
/// ★ 不塞小说简介（第 19 轮，用户明确要求）：简介是多行几百字，
///   塞进一格必然被截断，还会把真正有用的短字段挤没。
///   简介仍在快照 JSON / 导出里，只是不占这一列。
String noteTextOf(RankEntry e) {
  final notes = <String>[];
  final ex = e.extra;
  if (ex['indexChange'] != null) notes.add('榜变 ${ex['indexChange']}');
  if (ex['rankPosDiff'] != null) notes.add('API变化 ${ex['rankPosDiff']}');
  if (ex['status'] != null) notes.add('${ex['status']}');
  if (ex['creationStatus'] != null) {
    notes.add(ex['creationStatus'] == '0' ? '完结' : '连载');
  }
  if (ex['isOver'] != null) notes.add(ex['isOver'] == '1' ? '完结' : '连载');
  return notes.isEmpty ? '-' : notes.join(' · ');
}

/// 书名（字体混淆时带 `〔名待补〕` 标记）。
String titleTextOf(RankEntry e) =>
    e.titleObfuscated ? '${e.title}〔名待补〕' : e.title;

/// 作者（空则 `-`）。
String authorTextOf(RankEntry e) => e.author.isEmpty ? '-' : e.author;

/// 题材（空则 `-`）。
String categoryTextOf(RankEntry e) => (e.category ?? '').isEmpty ? '-' : e.category!;

// ─────────────────────────────────────────────────────────────────────────
//  列定义 —— **界面「榜单明细」与导出榜单图共用这一份**
//
//  ★ 用户报过："导出榜单与软件内的榜单明细差别很大"。根因就是两边
//    各写了一套列（界面 8 列、导出图 4 列且顺序不同）。列的顺序、表头文字、
//    单元格文本只要各写一份，就一定会漂移 —— 所以收敛到这里。
// ─────────────────────────────────────────────────────────────────────────

/// 「榜单明细」的一列。
enum BoardCol { rank, cover, title, author, category, metric, note, link }

/// 列顺序（界面与导出图都按这个顺序排）。
const List<BoardCol> boardCols = BoardCol.values;

/// 表头文字（封面列没有表头 —— 一格图放不下字，写了反而挤）。
String boardColTitle(BoardCol c) => switch (c) {
      BoardCol.rank => '#',
      BoardCol.cover => '',
      BoardCol.title => '书名',
      BoardCol.author => '作者',
      BoardCol.category => '题材',
      BoardCol.metric => '指标',
      BoardCol.note => '备注',
      BoardCol.link => '链接',
    };

/// 列的**基准宽度**（界面再乘 factor × 自适应缩放；导出图乘 factor）。
int boardColBaseWidth(BoardCol c) => switch (c) {
      BoardCol.rank => 44,
      BoardCol.cover => 52,
      BoardCol.title => 220,
      BoardCol.author => 104,
      BoardCol.category => 88,
      BoardCol.metric => 220,
      BoardCol.note => 110,
      BoardCol.link => 62,
    };

/// 哪一列吃"余量"。
///
/// ★ 是**书名**不是备注：书名是唯一"越长越有用"的列（会被截断），
///   备注只有 `榜变 -1 · 连载` 这种短字段 —— 给它余量就是一片空白放四个字。
bool boardColStretch(BoardCol c) => c == BoardCol.title;

/// 对齐方式（`win32.dart` 里的 dtLeft / dtRight / dtCenter）。
int boardColAlign(BoardCol c) => switch (c) {
      // 名次与指标是数字列 → 右对齐（数字右对齐才好按位数比大小）
      BoardCol.rank || BoardCol.metric => dtRight,
      BoardCol.cover || BoardCol.link => dtCenter,
      _ => dtLeft,
    };

/// 是否右对齐（导出图只区分"左/右"，居中的封面列按左处理）。
bool boardColRightAligned(BoardCol c) => boardColAlign(c) == dtRight;

/// 单元格文本。
///
/// [BoardCol.link] 在界面里是一个**按钮**，文本只是它的标签；
/// 导出图会**跳过这一列**（静态图里画个"打开"没有任何意义），
/// 所以这里的返回值导出侧用不到。
String boardColText(BoardCol c, RankEntry e, {String? source}) => switch (c) {
      BoardCol.rank => '${e.rank}',
      BoardCol.cover => '',
      BoardCol.title => titleTextOf(e),
      BoardCol.author => authorTextOf(e),
      BoardCol.category => categoryTextOf(e),
      BoardCol.metric => metricTextOf(e, source: source),
      BoardCol.note => noteTextOf(e),
      BoardCol.link => (e.url ?? '').isEmpty ? '-' : '打开',
    };

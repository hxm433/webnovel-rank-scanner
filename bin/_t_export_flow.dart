/// 导出流程回归（第 25 轮重做）。
///
/// 用户原话："导出根本无法使用，整个导出功能重做"。
/// 老流程是"每导出一次弹一个**模态**文件夹框"，于是：
///   · 框弹不出来 / 弹到主窗后面 / 选到不可写的盘 → 表现都是"导出没反应"；
///   · 而且**测试根本没法自动化** —— 模态框会把测试永远卡住。
/// 现在：**导出直接落到固定落点，不弹任何框**；要改落点就点菜单里那一项。
///
/// ★ 这个文件最关键的断言是"**它跑得完**"：如果哪天有人把弹框加回导出路径，
///   这个脚本会直接挂住（而不是悄悄通过）。
///
/// 运行：dart run bin/_t_export_flow.dart
library;

import 'dart:io';

import '../lib/exporters.dart';
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

void main() {
  final root = Directory.systemTemp.createTempSync('export_flow_').path;
  stdout.writeln('== 导出流程回归（数据目录 $root）==');

  // 造一份最小快照，让"当前快照"存在
  final src = Directory('${root}${Platform.pathSeparator}扫榜'
      '${Platform.pathSeparator}qidian')..createSync(recursive: true);
  File('${src.path}${Platform.pathSeparator}月票榜_20260925.json')
      .writeAsStringSync('''
{"path":"x","saved_at":"2026-09-25T10:00:00",
 "result":{
  "query":{"source":"qidian","board":"月票榜","limit":3},
  "fetched_at":"2026-09-25T10:00:00",
  "source_url":"https://www.qidian.com/rank/yuepiao/",
  "robots":"www.qidian.com:允许 /rank/",
  "quality":{"ok":true,"valid_count":2,"total_count":2,"summary":"测试夹具"},
  "entries":[
   {"rank":1,"title":"测试书甲","author":"作者甲","book_id":"1",
    "url":"https://book.qidian.com/info/1/",
    "metrics":{"monthticket":1200,"words":340000},
    "category":"玄幻","tags":[],"extra":{"isOver":"0"}},
   {"rank":2,"title":"测试书乙","author":"作者乙","book_id":"2",
    "url":"https://book.qidian.com/info/2/",
    "metrics":{"monthticket":900,"words":210000},
    "category":"都市","tags":[],"extra":{"isOver":"1"}}
  ]}}''');

  Palette.apply(AppTheme.dark);
  final mw = MainWindow(outRoot: root);
  Palette.apply(AppTheme.dark);
  mw.reload();

  final all = mw.vm?.all ?? const [];
  _check('快照载入成功', all.length == 1, '${all.length}');
  if (all.isEmpty) {
    stdout.writeln('\n== 汇总：$_pass 通过 / $_fail 失败 ==');
    exitCode = 1;
    return;
  }
  mw.testSelect(all.first.id);

  // ── ① 默认落点 = 数据目录下的 out/导出，且**不弹框** ──
  stdout.writeln('\n── ① 默认导出落点 ──');
  final def = mw.testEffectiveExportDir;
  _check('默认落点 = 默认导出目录', def == mw.testDefaultExportDir, def);
  _check('默认落点包含导出字样',
      (def ?? '').replaceAll('\\', '/').contains('导出'), '$def');
  _check('★ 默认（未开「先问文件夹」）时落点非空 —— 一键导出不弹框',
      def != null, '$def');

  // ── ② 走"菜单那条路"导出 CSV：不弹框、真落盘 ──
  //
  // ★ 这一步能返回就说明没有弹模态框（否则整个脚本会卡死在这里）。
  stdout.writeln('\n── ② 一键导出（走菜单路径）──');
  final p1 = mw.testExportViaMenuPath('csv');
  _check('CSV 导出返回了路径（没有弹框，否则这里会挂住）', p1 != null, '${mw.statusText}');
  if (p1 != null) {
    final f = File(p1);
    _check('文件真的落盘了', f.existsSync() && f.lengthSync() > 0,
        '${f.existsSync() ? f.lengthSync() : "不存在"}');
    _check('落在默认导出目录里',
        f.parent.path == def, '${f.parent.path} vs $def');
    final body = f.readAsStringSync();
    _check('CSV 里有链接列且**原样**是快照里的地址',
        body.contains('https://book.qidian.com/info/1/'), '没找到原始链接');
  }

  // ── ③ 改落点：立刻生效，且导出到新地方 ──
  stdout.writeln('\n── ③ 改落点（等价于点「设置导出位置…」）──');
  final custom = Directory('${root}${Platform.pathSeparator}我的导出').path;
  mw.testSetExportDir(custom);
  _check('落点已改成自定义目录', mw.testEffectiveExportDir == custom,
      mw.testEffectiveExportDir);
  final p2 = mw.testExportViaMenuPath('json');
  _check('JSON 导出到新落点', p2 != null, '${mw.statusText}');
  if (p2 != null) {
    _check('文件落在自定义目录里',
        File(p2).parent.path == custom, File(p2).parent.path);
  }

  // ── ④ 落点不可写/不存在 → 如实退回默认，不崩 ──
  stdout.writeln('\n── ④ 落点异常时退回默认 ──');
  mw.testSetExportDir('${root}${Platform.pathSeparator}不存在的盘Z'
      '${Platform.pathSeparator}x');
  final fallback = mw.testEffectiveExportDir;
  _check('落点目录会被自动创建（Windows 上建得出来就算通过）',
      fallback != null && Directory(fallback).existsSync(), '$fallback');

  // ── ④b xlsx 导出（Excel 原生格式）──
  //
  // ★ 与 CSV 的区别不是"换个后缀"：xlsx 的字符串走 `inlineStr`，
  //   **结构上不可能是公式**（CSV 只能靠前置单引号这种内容层面的补丁），
  //   而且能放多张表。这里只验"生成得出来、是合法 ZIP 头、落到该落的地方"，
  //   结构层面（ZIP/CRC/XML 良构/单元格内容）交给 `tool/check_xlsx.py` 独立验。
  stdout.writeln('\n── ④b xlsx 导出 ──');
  final xdir = '${root}${Platform.pathSeparator}build_xlsx';
  final xp = mw.testExportXlsxTo(xdir);
  _check('xlsx 导出返回了路径', xp != null, '${mw.statusText}');
  if (xp != null) {
    final f = File(xp);
    _check('xlsx 文件真的落盘且非空',
        f.existsSync() && f.lengthSync() > 500,
        '${f.existsSync() ? f.lengthSync() : "不存在"}');
    final head = f.existsSync() ? f.readAsBytesSync().take(4).toList() : <int>[];
    _check('以 ZIP 本地头 PK\\x03\\x04 开头（xlsx 就是 ZIP）',
        head.length == 4 &&
            head[0] == 0x50 && head[1] == 0x4B && head[2] == 3 && head[3] == 4,
        '$head');
    _check('文件名后缀是 .xlsx', xp.endsWith('.xlsx'), xp);

    // ★ 再留一份到**固定路径**：本机沙箱里 `dart run` 起不了子进程
    //   （`CreateFile failed 231`），所以"用别的程序能不能打开"这件事
    //   只能交给 `tool/check_xlsx.py` 由 bash 单独调 —— 它得知道去哪读文件。
    final stable = Directory('build${Platform.pathSeparator}_xlsx_test')
      ..createSync(recursive: true);
    final stablePath = '${stable.path}${Platform.pathSeparator}导出流程.xlsx';
    File(stablePath).writeAsBytesSync(File(xp).readAsBytesSync());
    stdout.writeln('      （另存一份给外部校验：$stablePath）');
  }

  // ── ⑤ 落点字段的持久化（老配置键名 last_export_dir 仍读得进来）──
  stdout.writeln('\n── ⑤ 设置持久化 ──');
  // 用真实落盘路径验"老键名仍读得进来"：写一份老格式的 ui.json 再 load
  final cfg = Directory('${root}${Platform.pathSeparator}cfg')
    ..createSync(recursive: true);
  File('${cfg.path}${Platform.pathSeparator}ui.json')
      .writeAsStringSync('{"theme":"dark","last_export_dir":"D:\\\\我的导出"}');
  final s = UiSettings.load(cfg.path);
  _check('★ 老配置键 last_export_dir 仍能读成 exportDir',
      s.exportDir == r'D:\我的导出', '${s.exportDir}');
  _check('序列化回去仍用老键名（老版本读得懂）',
      s.toJson()['last_export_dir'] == r'D:\我的导出',
      '${s.toJson()['last_export_dir']}');

  // ── ⑥ 落盘加固：写不进去时**必须退回默认目录**而不是报错 ──
  //
  // ★ 背景：用户报过"导出榜单图失败：PathAccessException ... errno = 5"，
  //   目标是桌面。本机复现不出来 —— 那是**偶发占用**（看图软件 / 杀软扫描 /
  //   索引器 / 网盘同步）。既然是偶发，就不能只重试一次了事，
  //   必须保证"导出这件事一定有结果"：写不进去就退回默认目录，
  //   并**如实告诉用户换地方了**（悄悄换地方 = 用户以为又失败了）。
  stdout.writeln('\n── ⑥ 落盘加固（占用 / 不可写时退回默认目录）──');
  // 造一个**不可能写进去**的目标：拿一个"文件"当目录用
  final notADir = File('${root}${Platform.pathSeparator}我是文件不是目录')
    ..writeAsStringSync('x');
  final fb = Directory('${root}${Platform.pathSeparator}兜底目录')
    ..createSync(recursive: true);

  final r1 = saveBytes(notADir.path, fb.path, '榜单_测试', 'png',
      List<int>.filled(32, 7));
  _check('★ 目标目录写不进去时**退回兜底目录**（而不是抛错）',
      r1.path.startsWith(fb.path), r1.path);
  _check('★ 退回时带上原因（UI 要把它说出来）', r1.movedWhy != null,
      '${r1.movedWhy}');
  _check('退回后文件真的在', File(r1.path).existsSync());

  // 兜底目录也写不进去 → 才允许抛错，且错误里要能看出两个目录
  try {
    saveBytes(notADir.path, notADir.path, 'x', 'png', List<int>.filled(4, 1));
    _check('两边都写不进去时应当抛错', false, '居然没抛');
  } on Object catch (e) {
    _check('两边都写不进去时抛错，且错误里点明了目录',
        e.toString().contains(notADir.path), '$e');
  }

  // 重名不覆盖：第二次导出应当加 (1)
  final r2 = saveBytes(fb.path, fb.path, '重名测试', 'txt', [65]);
  final r3 = saveBytes(fb.path, fb.path, '重名测试', 'txt', [66]);
  _check('★ 重名自动加序号，不覆盖已有文件',
      r2.path != r3.path && File(r2.path).existsSync() &&
          File(r3.path).existsSync(), '${r2.path} / ${r3.path}');

  stdout.writeln('\n== 汇总：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

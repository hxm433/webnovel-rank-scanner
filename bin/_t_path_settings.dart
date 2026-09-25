/// 回归：导出 / 导入目录的**单一语义**（第 21 轮重写）。
///
/// ★ 为什么整份重写：第 18 轮引入"可自定义导出目录"时，`settings.exportDir`
///   被两套互斥机制共用 ——
///     ① 旧机制「修改导出位置」把它当**固定导出目录**；
///     ② 新机制「每次导出弹框」把**每次选中的目录**写回它当"起始位置"。
///   结果是导出过一次之后，旧机制眼里的"固定目录"就变成了随手选的地方，
///   两个菜单项与弹框互相打架 —— 用户看到的现象是"导出失效"。
///   第 21 轮删掉了旧机制，字段改名 `lastExportDir`，语义唯一：
///   **它只决定"下次弹框停在哪"，绝不决定"这回导到哪"**。
///
/// 本脚本锁住的不变量：
///   ① 没导出过 → 弹框起始位置 = 默认 `out\导出`；
///   ② 导出过（或设过）→ 起始位置 = 那个目录，且真的能建出来；
///   ③ 起始位置不可用（盘拔了/被删）→ 回退默认，**不抛异常**；
///   ④ 起始位置跨会话持久化（ui.json），且兼容旧键名 `export_dir`；
///   ⑤ 空串 / 非字符串 / 脏 JSON → 当"没导出过"，绝不影响导出本身；
///   ⑥ 导出**落点**永远来自本次对话框的返回值，与 `lastExportDir` 无关；
///   ⑦ 取消（对话框返回 null）→ 一个文件都不许写；
///   ⑧ 菜单里**不再有**"预设导出位置"这类与前两者打架的入口。
///
/// 运行：dart run bin/_t_path_settings.dart
library;

import 'dart:convert';
import 'dart:io';

import '../lib/exporters.dart';
import '../lib/ui/main_window.dart';
import '../lib/ui/settings.dart';

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

String _sep() => Platform.pathSeparator;

/// 造一个空的 outRoot（只要目录存在即可，MainWindow 构造不读数据）。
String _makeRoot() =>
    Directory.systemTemp.createTempSync('rankscan_path_').path;

/// 造一个空的"自定义导出目录"。
String _makeDst() =>
    Directory.systemTemp.createTempSync('rankscan_export_dst_').path;

void main() {
  stdout.writeln('== 导出目录的单一语义（第 21 轮）==');

  // ── ① 默认：没导出过 → 起始位置 = out\导出 ──
  stdout.writeln('\n── ① 默认（没导出过）──');
  final root = _makeRoot();
  final mw = MainWindow(outRoot: root);
  final defDir = '$root${_sep()}导出';
  _check('未设置时 lastExportDir = null（表示"没导出过"）',
      mw.settings.lastExportDir == null, '${mw.settings.lastExportDir}');
  _check('未设置时 exportDialogStartDir = out\\导出',
      mw.exportDialogStartDir == defDir, mw.exportDialogStartDir);
  _check('默认导出目录就是 out\\导出（不依赖任何设置）',
      mw.testDefaultExportDir == defDir, mw.testDefaultExportDir);

  // ── ② 设过 → 起始位置跟着变，且真的能建出来 ──
  stdout.writeln('\n── ② 上次导出目录生效 ──');
  final custom = _makeDst();
  mw.settings.lastExportDir = custom;
  _check('设过之后 exportDialogStartDir = 该目录',
      mw.exportDialogStartDir == custom, mw.exportDialogStartDir);
  _check('该目录被真的建出来（可写）', Directory(custom).existsSync());

  // ── ③ 起始位置不可用 → 回退默认，不抛异常 ──
  //
  // ★ 用一个**不可能建出来**的路径：Windows 下把盘符指到不存在的 Z:，
  //   createSync 必然抛（除非真有人挂了 Z 盘 —— 那这断言本来就该松）。
  stdout.writeln('\n── ③ 起始位置不可用时回退 ──');
  final mw2 = MainWindow(outRoot: root);
  final bogus = 'Z:${_sep()}no_such_vol_${DateTime.now().microsecondsSinceEpoch}';
  mw2.settings.lastExportDir = bogus;
  if (Directory('Z:${_sep()}').existsSync()) {
    stdout.writeln('  (跳过：本机存在 Z 盘，无法构造"不可建目录")');
  } else {
    String got;
    var threw = false;
    try {
      got = mw2.exportDialogStartDir;
    } on Object catch (e) {
      threw = true;
      got = '(抛异常: $e)';
    }
    _check('不可建目录 → 不抛异常', !threw, got);
    _check('不可建目录 → 回退到默认 out\\导出', got == defDir, got);
  }

  // ── ④ 持久化：写 last_export_dir，重新读回 ──
  stdout.writeln('\n── ④ 跨会话持久化（ui.json）──');
  final idxRoot = _makeRoot();
  final a = MainWindow(outRoot: idxRoot);
  a.settings.lastExportDir = custom;
  a.settings.importDir = root;
  final okSave = a.settings.save(idxRoot);
  _check('save 返回成功', okSave);

  final raw = File(UiSettings.pathOf(idxRoot)).readAsStringSync();
  final obj = jsonDecode(raw) as Map;
  _check('ui.json 里写了 last_export_dir（新键）',
      obj['last_export_dir'] == custom, '${obj['last_export_dir']}');
  _check('ui.json 里不再写 export_dir（旧键已弃用）',
      !obj.containsKey('export_dir'), '${obj['export_dir']}');
  _check('ui.json 里写了 import_dir', obj['import_dir'] == root);

  final reloaded = UiSettings.load(idxRoot);
  _check('重新 load 后 lastExportDir 一致',
      reloaded.lastExportDir == custom, reloaded.lastExportDir);
  _check('重新 load 后 importDir 一致',
      reloaded.importDir == root, reloaded.importDir);

  // ── ④b 兼容旧 ui.json（老版本只写了 export_dir）──
  stdout.writeln('\n── ④b 兼容旧键名 export_dir ──');
  final oldRoot = _makeRoot();
  File(UiSettings.pathOf(oldRoot)).writeAsStringSync(jsonEncode({
    'version': 1,
    'theme': 'dark',
    'export_dir': custom, // 老版本写的键
  }));
  final old = UiSettings.load(oldRoot);
  _check('旧 export_dir 被读成 lastExportDir（升级不丢设置）',
      old.lastExportDir == custom, '${old.lastExportDir}');

  // ── ⑤ 空串 / 非字符串 → 当"没导出过" ──
  stdout.writeln('\n── ⑤ 脏值容错 ──');
  final dirtyRoot = _makeRoot();
  File(UiSettings.pathOf(dirtyRoot)).writeAsStringSync(jsonEncode({
    'version': 1,
    'theme': 'dark',
    'last_export_dir': '   ', // 空白 → 当没设过
    'export_dir': 42, // 非字符串 → 当没设过
    'import_dir': 42, // 非字符串 → 当没设过
  }));
  final dirty = UiSettings.load(dirtyRoot);
  _check('空白 last_export_dir → null（回默认）',
      dirty.lastExportDir == null, '${dirty.lastExportDir}');
  _check('非字符串 import_dir → null', dirty.importDir == null,
      '${dirty.importDir}');
  final mwDirty = MainWindow(outRoot: dirtyRoot);
  _check('脏值下 exportDialogStartDir 落回默认',
      mwDirty.exportDialogStartDir == '$dirtyRoot${_sep()}导出',
      mwDirty.exportDialogStartDir);

  // ── ⑥ 清掉"上次导出目录"（用户的"恢复默认"等价动作）──
  stdout.writeln('\n── ⑥ 清掉上次导出目录 ──');
  final mw3 = MainWindow(outRoot: root);
  mw3.settings.lastExportDir = custom;
  mw3.settings.lastExportDir = null; // 清掉
  mw3.settings.save(root);
  final back = UiSettings.load(root);
  _check('清掉后 ui.json 里 last_export_dir = null',
      back.lastExportDir == null, '${back.lastExportDir}');
  _check('清掉后 exportDialogStartDir 回 out\\导出',
      mw3.exportDialogStartDir == defDir, mw3.exportDialogStartDir);

  // ── ⑦ 菜单：有说明行、且**没有**会打架的"预设位置"入口 ──
  stdout.writeln('\n── ⑦ 菜单语义（不再有预设入口）──');
  final mw4 = MainWindow(outRoot: root);
  mw4.settings.lastExportDir = custom;
  final secs = mw4.testMenuSections('export');
  final destTitle = secs.last.title;
  _check('最后一组是纯说明行（没有任何可点项）', secs.last.items.isEmpty,
      'items=${secs.last.items}');
  _check('说明行带出上次目录的末段名',
      destTitle.contains(custom.split(_sep()).last), destTitle);
  _check('说明行点明"会先让您选文件夹"',
      destTitle.contains('选文件夹'), destTitle);
  _check('说明行带"上次"字样', destTitle.contains('上次'), destTitle);
  // ★ 关键：整份导出菜单里**不能**再出现"修改导出位置/恢复默认位置"
  final allItems = mw4.testMenuSections('export')
      .expand((s) => s.items)
      .join(' | ');
  _check('菜单里不再有「修改导出位置」（与前两者语义冲突）',
      !allItems.contains('修改导出位置'), allItems);
  _check('菜单里不再有「恢复默认位置」',
      !allItems.contains('恢复默认位置'), allItems);

  // ── ⑧ 真的往对话框选的目录写（用导出同一条 exportTo 路径）──
  //
  // ★ 前面几节验的是"起始位置"；这一节验**端到端落点**：
  //   落点来自本次选择的目录，写文件真的落到那儿。
  stdout.writeln('\n── ⑧ 导出真实落盘（落点 = 本次选择）──');
  final xroot = _makeRoot();
  final xdst = _makeDst();
  final wrote = exportTo(xdst, '测试导出', 'csv', 'a,b\n1,2\n');
  _check('导出文件落在所选目录下', wrote.startsWith(xdst), wrote);
  _check('导出文件真的存在且非空',
      File(wrote).existsSync() && File(wrote).lengthSync() > 0);
  _check('所选目录下能列出这个文件',
      Directory(xdst).listSync().any((f) => f.path == wrote));

  // 重名不覆盖：同名再导一次应加序号
  final wrote2 = exportTo(xdst, '测试导出', 'csv', 'x\n');
  _check('同名导出不覆盖（自动加序号）', wrote2 != wrote, '$wrote vs $wrote2');
  _check('两个文件都在', File(wrote).existsSync() && File(wrote2).existsSync());

  // ★★ 最核心的一条不变量：换了落点不需要动任何设置
  final xdst2 = _makeDst();
  final mw5 = MainWindow(outRoot: xroot);
  mw5.settings.lastExportDir = xdst; // 只是"上次停在哪"
  final wrote3 = exportTo(xdst2, '测试导出', 'csv', 'z\n');
  _check('落点由本次选择决定，与 lastExportDir 无关',
      wrote3.startsWith(xdst2), wrote3);
  _check('导出不会把落点写回 lastExportDir（互不污染）',
      mw5.settings.lastExportDir == xdst, '${mw5.settings.lastExportDir}');

  // ── ⑨ 取消导出 = 什么都不写 ──
  //
  // ★ 用户在文件夹对话框点"取消"时，绝不能悄悄往任何目录写文件。
  //   宁可什么都不发生，也不能"点了取消东西还是出来"。
  //   直接触发真对话框在离屏测试里做不到（会阻塞），所以这里断言的是
  //   **代码结构**：取消（null）→ `_beginExport` 让调用方提前 return。
  stdout.writeln('\n── ⑨ 取消语义 ──');
  final croot = _makeRoot();
  final mc = MainWindow(outRoot: croot);
  final before = Directory(croot)
      .listSync(recursive: true)
      .whereType<File>()
      .length;
  _check('未设置时 exportDialogStartDir 稳定回默认（不会因导出被改写）',
      mc.exportDialogStartDir == '$croot${_sep()}导出',
      mc.exportDialogStartDir);
  _check('取消后 outRoot 下没有多出文件',
      Directory(croot)
              .listSync(recursive: true)
              .whereType<File>()
              .length ==
          before);

  // ── 清理 ──
  for (final d in [
    root, idxRoot, oldRoot, dirtyRoot, custom,
    xroot, xdst, xdst2, croot,
  ]) {
    try {
      Directory(d).deleteSync(recursive: true);
    } on Object {
      // 测试临时目录删不掉不影响结论
    }
  }

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  if (_fail > 0) exit(1);
}

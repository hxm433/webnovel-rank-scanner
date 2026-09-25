/// 界面设置的持久化 —— `out/ui.json`。
///
/// ★ 为什么跟 `扫榜/index.json` 分开：那是**数据**（快照清单 + 保留策略 + 附件），
///   这是**偏好**（主题、折叠状态、隐藏了哪些榜）。两者的生命周期完全不同 ——
///   删掉 `ui.json` 只是"设置回到默认"，绝不该影响任何一份快照；
///   而索引一旦损坏，扫榜数据的可见性就受影响。混在一起会让"重置外观"
///   变成一件危险的事。
///
/// ★ 读写纪律（与索引一致）：
///   ① **缺失/损坏一律退回默认值**，并把原因记进 [errors]（不静默吞）；
///   ② 写盘用"临时文件 + 原子替换"，避免写一半崩了留下半个坏文件；
///   ③ 任何字段都**容忍类型不对**（手工改坏的 JSON 不该让软件起不来）。
library;

import 'dart:convert';
import 'dart:io';

import 'theme.dart';

/// 界面偏好。
class UiSettings {
  UiSettings({
    this.theme = AppTheme.dark,
    Set<String>? collapsedSources,
    Set<String>? collapsedScanSources,
    Set<String>? expandedBoards,
    Set<String>? hiddenSeries,
    this.showHidden = false,
    this.sidebarCollapsed = false,
    this.exportDir,
    this.askExportDir = false,
    this.importDir,
  })  : collapsedSources = collapsedSources ?? <String>{},
        collapsedScanSources = collapsedScanSources ?? <String>{},
        expandedBoards = expandedBoards ?? <String>{},
        hiddenSeries = hiddenSeries ?? <String>{};

  /// 主题档位。
  AppTheme theme;

  /// **导出落点**（null = 用默认的 `out/导出`）。
  ///
  /// ★★ 第 25 轮改回"固定导出目录"这个语义 —— 因为"每次导出都弹文件夹框"
  ///   被用户判定为**不可用**（原话："导出根本无法使用，整个导出功能重做"）。
  ///   每导出一次要点三次对话框（选目录 → 完成提示 → 打开目录），
  ///   而"选目录"这一步一旦弹不出来/弹到后面/选到不可写的盘，
  ///   用户看到的就是"导出没反应"。
  ///   现在：**点菜单项 → 直接出文件 → 一个完成提示**。
  ///   想换地方就点菜单里的「设置导出位置…」，弹一次框、记下来。
  ///
  /// ★ JSON 键仍是 `last_export_dir`（老配置照样读得进来）。
  String? exportDir;

  /// 导出前是否**先问一次文件夹**（用户 2026-10-02 的要求）。
  ///
  /// ★ 为什么做成开关而不是直接改成"每次都问"：
  ///   第 25 轮用户判定"每次导出都弹框"**根本不可用**（一次导出要点三次对话框，
  ///   而且选目录那一步弹不出来/弹到后面/选到不可写盘，表现就是"导出没反应"），
  ///   所以改成了"直接导到固定落点"。
  ///   这一轮用户又要"可以自定义导出位置" —— 两个诉求都对，于是给一个**显式开关**：
  ///   默认关（一键出文件），想每次自己挑就打开。
  bool askExportDir;

  /// 自定义**导入起始目录**（null = 用当前工作目录）。
  ///
  /// ★ "选一张图片挂为附件"的对话框默认从哪开，用户想固定下来。
  String? importDir;

  /// 侧栏里**折叠起来的平台**（sourceId）。
  ///
  /// ★ 存"折叠的"而不是"展开的"：这样**默认全展开**（空集合），
  ///   老用户第一次升级时看到的是熟悉的完整列表，而不是"什么都折叠了"。
  final Set<String> collapsedSources;

  /// 扫榜设置窗里**折叠起来的平台**（sourceId）。默认展开。
  final Set<String> collapsedScanSources;

  /// 扫榜设置窗里**展开的榜**（key = `source|board`）。
  ///
  /// ★ 存"展开的"而不是"折叠的"：起点的每个榜都挂着 14 个题材，
  ///   默认全展开就是 196 行 —— 用户一开窗看到的就是一堵墙。
  ///   所以榜**默认折叠**，只显示"榜名 + 已选数"，想挑题材再点开。
  final Set<String> expandedBoards;

  /// 侧栏里**隐藏的系列**（`IndexEntry.seriesKey` = `source|board|题材`）。
  ///
  /// ★ 隐藏的语义是"**只是不显示**"：快照文件、索引条目、附件一个都不动。
  ///   所以它绝不能进保留策略、也不能参与任何"已删除"的统计 ——
  ///   否则用户会以为"隐藏 = 删掉"，然后再也不敢点。
  final Set<String> hiddenSeries;

  /// 是否临时把已隐藏的项也显示出来（管理用；不持久化的语义更安全，
  /// 但这里持久化它 —— 用户正忙着整理时，重启后回到"看得见"更顺手）。
  bool showHidden;

  /// 整个侧栏是否收起（给内容区更多宽度）。
  bool sidebarCollapsed;

  /// 加载期间发现的问题（坏文件、字段类型不对……）。
  static final List<String> errors = [];

  static String pathOf(String outRoot) =>
      '$outRoot${Platform.pathSeparator}ui.json';

  /// 读设置；文件不存在或坏了都退回默认值。
  static UiSettings load(String outRoot) {
    errors.clear();
    final f = File(pathOf(outRoot));
    if (!f.existsSync()) return UiSettings();
    try {
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) {
        errors.add('ui.json 顶层不是对象，已用默认设置');
        return UiSettings();
      }
      final s = UiSettings(
        theme: AppTheme.fromId(_str(raw['theme'])),
        collapsedSources: _strSet(raw['collapsed_sources'], 'collapsed_sources'),
        collapsedScanSources: _strSet(
            raw['collapsed_scan_sources'], 'collapsed_scan_sources'),
        expandedBoards: _strSet(raw['expanded_boards'], 'expanded_boards'),
        hiddenSeries: _strSet(raw['hidden_series'], 'hidden_series'),
        showHidden: raw['show_hidden'] == true,
        sidebarCollapsed: raw['sidebar_collapsed'] == true,
        // ★ 兼容旧 ui.json 的 `export_dir`：老版本把它当"固定导出目录"存，
        //   新语义是"上次选中的文件夹" —— 两者对这个字段的**取值形态一致**
        //   （都是一个绝对路径），所以直接读进来当起始位置即可，不会误事。
        askExportDir: raw['ask_export_dir'] == true,
        exportDir: _nonEmpty(raw['last_export_dir']) ??
            _nonEmpty(raw['export_dir']),
        importDir: _nonEmpty(raw['import_dir']),
      );
      return s;
    } on Object catch (e) {
      errors.add('ui.json 解析失败（$e），已用默认设置');
      return UiSettings();
    }
  }

  static String? _str(Object? v) => v is String ? v : null;

  /// 读一个"可空字符串"字段：非字符串或空白一律当"没设过"。
  ///
  /// ★ 空串必须归一成 null：手工把 `export_dir` 改成 `""` 的人，
  ///   期待的是"回到默认目录"，而不是"导出到当前工作目录"。
  static String? _nonEmpty(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  /// 字符串数组容错读法：非数组 → 空集合；数组里的非字符串项被丢弃并记录。
  static Set<String> _strSet(Object? v, String field) {
    if (v == null) return <String>{};
    if (v is! List) {
      errors.add('ui.json 的 $field 不是数组，已忽略');
      return <String>{};
    }
    final out = <String>{};
    for (final e in v) {
      if (e is String) {
        out.add(e);
      } else {
        errors.add('ui.json 的 $field 里有非字符串项，已忽略');
      }
    }
    return out;
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'saved_at': DateTime.now().toIso8601String(),
        'theme': theme.id,
        'collapsed_sources': collapsedSources.toList()..sort(),
        'collapsed_scan_sources': collapsedScanSources.toList()..sort(),
        'expanded_boards': expandedBoards.toList()..sort(),
        'hidden_series': hiddenSeries.toList()..sort(),
        'show_hidden': showHidden,
        'sidebar_collapsed': sidebarCollapsed,
        'ask_export_dir': askExportDir,
        'last_export_dir': exportDir,
        'import_dir': importDir,
      };

  /// 原子写盘。返回是否成功（失败时把原因记进 [errors]）。
  bool save(String outRoot) {
    try {
      final path = pathOf(outRoot);
      final f = File(path);
      f.parent.createSync(recursive: true);
      final tmp =
          File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
      tmp.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(toJson()),
          flush: true);
      tmp.renameSync(path);
      return true;
    } on Object catch (e) {
      errors.add('ui.json 写入失败（$e）');
      return false;
    }
  }

  // ── 隐藏项的便捷操作（都返回"是否真的变了"，便于调用方决定要不要存盘）──

  bool hideSeries(String seriesKey) => hiddenSeries.add(seriesKey);

  bool unhideSeries(String seriesKey) => hiddenSeries.remove(seriesKey);

  bool isHidden(String seriesKey) => hiddenSeries.contains(seriesKey);

  /// 清空全部隐藏（"全部恢复显示"）。
  bool clearHidden() {
    if (hiddenSeries.isEmpty) return false;
    hiddenSeries.clear();
    return true;
  }
}

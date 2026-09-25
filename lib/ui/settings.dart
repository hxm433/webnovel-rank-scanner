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
  })  : collapsedSources = collapsedSources ?? <String>{},
        collapsedScanSources = collapsedScanSources ?? <String>{},
        expandedBoards = expandedBoards ?? <String>{},
        hiddenSeries = hiddenSeries ?? <String>{};

  /// 主题档位。
  AppTheme theme;

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
      );
      return s;
    } on Object catch (e) {
      errors.add('ui.json 解析失败（$e），已用默认设置');
      return UiSettings();
    }
  }

  static String? _str(Object? v) => v is String ? v : null;

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

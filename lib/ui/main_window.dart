/// 主窗口 —— 把侧栏 / 工具栏 / 内容区 / 状态栏串起来。
///
/// 界面结构（对齐用户选的三块功能）：
///   ┌─ 顶栏：标题 + 扫榜设置入口 ──────────────────────────┐
///   ├─ 左侧栏：平台 → 榜（点选切换数据）                    │
///   ├─ 内容区：① 榜单明细  ② 历史对比  ③ 跨榜分析（标签页）  │
///   └─ 状态栏：扫描进度 / 结果提示 ────────────────────────┘
///
/// ★ 扫榜与界面**不共享可变状态**：扫榜跑在异步任务里，
///   通过 [ScanProgress] 把消息投递给界面，界面只读它的快照。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import '../analysis.dart';
import '../exporters.dart';
import '../models.dart';
import '../report_data.dart';
import '../scan_service.dart';
import '../snapshot_index.dart';
import '../snapshot_index_file.dart';
import '../store.dart';
import '../timeseries.dart';
import '../trend_insight.dart';
import 'app.dart';
import 'board_text.dart';
import 'chart.dart';
import 'data_manager.dart';
import '../cover_store.dart';
import 'dialogs.dart';
import 'gdi.dart';
import 'image_export.dart';
import 'settings.dart';
import 'theme.dart';
import 'view_model.dart';
import 'widgets.dart';
import 'win32.dart';

/// 标签页
const int tabDetail = 0;
const int tabDiff = 1;
const int tabCross = 2;

/// 扫榜任务的状态机。
enum ScanPhase { idle, running, done }

/// 把 [src] 以 [t] 的比例混到 [dst] 上（0=全 dst，1=全 src）。
///
/// 这是首屏淡入的实现手段：GDI 没有图层透明度，但把每个颜色按进度
/// 混向窗口底色，观感完全等价，且不需要引入任何新 API。
int _blendColor(int src, int dst, double t) {
  final sr = src & 0xFF, sg = (src >> 8) & 0xFF, sb = (src >> 16) & 0xFF;
  final dr = dst & 0xFF, dg = (dst >> 8) & 0xFF, db = (dst >> 16) & 0xFF;
  int m(int a, int b) => (a * (1 - t) + b * t).round().clamp(0, 255);
  return rgb(m(sr, dr), m(sg, dg), m(sb, db));
}

/// 字数变化的中文格式（带符号 + 万/字单位）。
///
/// ★ 单独写一个而不是复用 [wan]：`wan` 是"数量级展示"，
///   这里要的是**变化量**，必须显式带 `+` 号，否则用户分不清
///   是"当前值"还是"涨了多少"。
String signedWords(int n) {
  final abs = n.abs();
  final unit = abs >= 10000 ? '${(abs / 10000).toStringAsFixed(1)}万' : '$abs';
  if (n > 0) return '+$unit';
  if (n < 0) return '-$unit';
  return '0';
}

class MainWindow extends AppWindow {
  MainWindow({required this.outRoot}) {
    // ★ 主题必须在**建窗之前**就定好：窗口过程一收到 WM_CREATE/WM_SIZE
    //   就会绘制首帧，那时 `Palette` 若还是默认档，用户会看到"先深后浅"
    //   闪一下。构造函数是唯一的时机。
    settings = UiSettings.load(outRoot);
    Palette.apply(settings.theme);
  }

  final String outRoot;

  /// 界面偏好（主题 / 折叠状态 / 隐藏的榜）。见 `settings.dart`。
  late UiSettings settings;

  /// 存盘（失败只记消息，不打断交互 —— 设置存不上不该让软件不能用）。
  void saveSettings() {
    if (!settings.save(outRoot)) {
      final e = UiSettings.errors.isEmpty ? '未知原因' : UiSettings.errors.last;
      lastMessage = '设置未能保存：$e';
    }
  }

  @override
  String get title => '网文扫榜工具';

  // ── 数据状态 ──
  ViewModel? vm;
  final List<String> loadErrors = [];

  /// 当前选中的快照 meta id（0 = 未选）。
  int selectedId = 0;
  int curTab = tabDetail;

  /// 明细表滚动。
  int detailScroll = 0;

  /// 时间序列（历史对比）滚动与区间档位。
  int seriesScroll = 0;

  /// 当前区间档位（近 7 期 / 近 30 期 / 全部）。
  TimeRange seriesRange = TimeRange.all;

  /// 折线图看的是哪一种量（排名 / 指标 / 字数）。
  ChartMetric seriesBy = ChartMetric.rank;

  /// 折线画几条（0 = 全部）。
  int seriesTop = 6;

  /// 跨榜信号表的纵向滚动偏移。
  ///
  /// ★ 为什么需要：这张表最多 30 本，而它只分到卡片里的一小块高度 ——
  ///   没有滚动的话"共 30 本 · 显示前 1 本"，剩下 29 本永远看不到。
  int crossScroll = 0;

  /// 当前时间线（缓存，避免每帧重算 + 重读磁盘）。
  SeriesView? series;

  /// 已解析的快照数据缓存：`id → RankResult`。
  ///
  /// ★ 为什么必须缓存：装配时间线要读每期的 JSON 全文，
  ///   而重绘是每帧都发生的（鼠标移动就会触发）。不缓存的话
  ///   "保留 100 期"时每一帧都要读 100 个文件 —— 界面会直接卡死。
  final Map<String, RankResult> _resultCache = {};

  /// 缓存对应的系列键（换了榜就要重新装配）。
  String? _seriesCacheKey;

  /// 侧栏滚动（快照多了要能滚）。
  int sidebarScroll = 0;
  int sidebarContentH = 0;

  /// 侧栏**可见行**（已过滤隐藏项、已跳过折叠的分组）。
  ///
  /// ★ 为什么要留一份：点击时拿到的是"第 i 行"，而"第 i 行是哪一份快照"
  ///   只有绘制时才知道（受折叠/隐藏/滚动影响）。绘制时把它填好，
  ///   点击时按下标取 —— 比在点击里重算一遍布局稳得多。
  final List<SnapshotMeta> sideRows = [];

  /// 侧栏分组数（供分组头的命中判定遍历用）。
  int sideGroupCount = 0;

  /// 跨榜分析：选中平台。
  String crossSource = '';

  // ── 扫榜任务状态 ──
  ScanService? service;
  ScanPhase phase = ScanPhase.idle;
  String statusText = '就绪';
  String? lastMessage;
  int scanDone = 0;
  int scanTotal = 0;
  List<ScanTarget> pendingTargets = [];
  Timer? _progressTimer;
  double _spin = 0;

  // ── 控件 id 常量（命中测试用，避免坐标魔法数）──
  static const int idScanButton = 100;
  static const int idReloadButton = 101;
  static const int idExportButton = 102;
  static const int idOpenButton = 103;
  static const int idRefreshButton = 104;
  static const int idImportButton = 105;
  static const int idThemeButton = 106;

  /// 「榜单明细」里每本书的链接命中区。
  ///
  /// ★ 两段：书名格（点书名也能打开，符合"标题即链接"的通用语汇）
  ///   与「打开」按钮格。两个 id 段分开，互不重叠。
  /// 跨榜页的"平台 chip"。
  ///
  /// ★ 原来用的是 `600 + i`，**与导出菜单项（600..605）撞号**：
  ///   点"CSV 明细表"会被当成"点第 0 个平台 chip" —— 菜单不关、导出不执行，
  ///   只把 `crossSource` 换了一下。4 个平台时 6 个菜单项坏 4 个。
  ///   现在换成独立段（800 起），菜单段谁都不会碰到。
  static const int idCrossChipBase = 800;

  /// 跨榜分析里"各平台主流题材对比"表格的**行**（点行 = 切到那个平台）。
  static const int idCrossRowBase = 900;

  static const int idBookLinkBase = 3000;
  /// ★ 与 [idBookLinkBase] 之间留 **1096** 而不是 400：
  ///   起点的本数上限是 500（`scan_service.sourceLimitCap`），
  ///   只留 400 的话第 400 行的"打开"会算进书名段 → 点它会打开**第 0 行那本书**。
  static const int idBookTitleLinkBase = 4096;

  /// **整行**的书链接命中区（第 19 轮补）。
  ///
  /// ★ 为什么要它：原来只有「打开」按钮和书名格能点 —— 按钮在宽屏下
  ///   只有约 97×50 像素，用户点了没反应时根本分不清是"没点准"还是"坏了"。
  ///   明细表这一行的**唯一动作**就是打开这本书，那就让整行都能点。
  static const int idBookRowLinkBase = 5120;
  static const int idManageButton = 107;
  static const int idDetailTable = 200;

  /// 明细表的**横向滚动条**（整表放大后放不下时才出现）。
  static const int idDetailHScroll = 210;
  static const int idDiffTable = 201;
  static const int idCrossTable = 202;
  static const int idSeriesTable = 203;
  static const int idTabBase = 300;
  static const int idOpenSource = 500;

  // ── 时间序列（历史对比）控件 id ──
  static const int idRangeLast7 = 410;
  static const int idRangeLast30 = 411;
  static const int idRangeAll = 412;
  static const int idSeriesInfo = 413;

  /// 折线图**看图口径**：排名 / 指标 / 字数。
  ///
  /// ★ 用户要求："历史对比用折线图，最好是每本书各自数据变化的折线图，
  ///   比如参考数据的变化和排名的变化"。排名与指标**方向相反**
  ///   （名次越小越好、指标越大越好），所以是两套 y 轴，必须能切。
  static const int idMetricRank = 420;
  static const int idMetricValue = 421;
  static const int idMetricWords = 422;

  /// 折线**画几条**：6 / 12 / 全部。
  static const int idTop6 = 430;
  static const int idTop12 = 431;
  static const int idTopAll = 432;

  // ── 导出/导入下拉菜单 ──
  //
  // ★ 为什么不用"点一下全导出"的老做法：用户要的是**选择性地拿一份东西**，
  //   而不是每次都产 3 个文件再自己去里面挑。菜单的每一项对应一种产物。
  //   菜单项 id 用独立区间（600+），与按钮 id 不冲突。
  static const int menuExportCsv = 600;
  static const int menuExportJson = 601;
  static const int menuExportBundle = 602;
  static const int menuExportBoardImage = 603;
  static const int menuExportTrendImage = 604;

  static const int menuExportAttachments = 605;

  static const int menuImportImage = 610;
  static const int menuImportText = 611;

  /// 当前展开的菜单：'' = 没有；'export' / 'import'。
  ///
  /// ★ 用**一个**字段而不是两个 bool：两个 bool 会允许"两个菜单同时开"，
  ///   而实际语义是互斥的（开一个必然关另一个）。
  String openMenu = '';

  /// 菜单里悬停到的项 id（-1 = 无）。
  int menuHotId = -1;

  // 窗口按钮（idWinMinimize / idWinMaximize / idWinClose）定义在 widgets.dart，
  // 因为设置子窗也要用，而跨类静态常量在 const 上下文里不可用。

  /// 布局计算出来的矩形，绘制时写入、点击时读用。
  final Map<int, Rc> hitRects = {};
  final Map<int, int> listIndexBase = {};

  /// 侧栏条目的 id 从 1000 起。
  static const int sidebarIdBase = 1000;
  int sideItemCount = 0;

  /// 侧栏平台分组头的 id（点击折叠/展开）。
  static const int sidebarGroupIdBase = 1100;

  /// 侧栏每行的"隐藏"小按钮 id（hover 才显形）。
  static const int sidebarHideIdBase = 1200;

  /// 侧栏底部「已隐藏 N · 管理」入口。
  static const int idSidebarManage = 1300;

  /// 当前 hover 到的侧栏行下标（-1 = 无）。用来决定"隐藏"小按钮是否显形。
  int sideHoverRow = -1;

  // ── 外观 / 动画状态 ──

  /// 自绘窗口按钮的悬停高亮（-1 = 无）。
  int _winBtnHot = -1;

  /// 界面淡入进度 0→1（首帧从 0 起，到 1 停）。
  ///
  /// ★ 为什么要"淡入"：窗口从无到有是**瞬变**，自绘 UI 没有系统动画兜底，
  ///   直接出现会显得生硬。200ms 淡入是最省的"软件感"来源 ——
  ///   不需要任何额外合成层，只是在绘制时乘一个 alpha 系数。
  double _fadeIn = 0;

  /// 淡入动画的定时器（跑完即停，不留常驻 tick）。
  Timer? _fadeTimer;

  /// 标签页切换动画的起始页（-1 = 没在切换）。
  int _tabAnimFrom = -1;

  /// 标签页切换进度 0→1。
  double _tabAnim = 1;

  Timer? _tabTimer;

  /// 首次绘制前是否已自动载入过数据。
  ///
  /// ★ 之前忘了这一步：`reload()` 只在"点重载按钮"时调，于是启动后
  ///   左侧永远是"正在读取快照…"、右侧永远"没有可显示的数据" ——
  ///   用户会以为软件坏了（明明 `out/` 里有 18 份快照）。
  bool _autoLoaded = false;

  // ── 绘制 ──

  // ── 无边框窗口钩子 ──

  /// 标题栏高度 = 顶栏高度。整条顶栏都是可拖动区，
  /// 除非上面的按钮/下拉把它"抢"走（见 [onHitTest]）。
  @override
  int get captionHeight => Metrics.headerHeight;

  @override
  int? onHitTest(int x, int y) {
    final h = Metrics.headerHeight;
    if (y < 0 || y >= h) return null; // 非标题栏交给系统（缩放边已在外层判过）

    // ★ 顺序很重要：**先判按钮、再判拖拽区**。
    //   反过来会让"点关闭按钮"变成"拖动窗口"，用户会觉得程序坏了。
    //   这里的命中区来自上一帧的 hitRects —— 布局没有变化时它必然有效；
    //   首帧还没画过则 hitRects 为空，退化成"整条可拖"，无副作用。
    for (final id in const [idWinMinimize, idWinMaximize, idWinClose]) {
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) return htClient;
    }
    // 顶栏上的操作按钮（导出/重载/数据管理/主题/扫榜设置）也要排除，否则点不动。
    for (final id in const [
      idScanButton,
      idReloadButton,
      idExportButton,
      idImportButton,
      idManageButton,
      idThemeButton,
    ]) {
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) return htClient;
    }
    // 品牌区也留给拖拽（它没有交互），所以不排除。
    return htCaption;
  }

  @override
  void onWindowStateChanged() {
    // 最大化/还原后标题栏按钮图标要换（□ ↔ ❐），重绘一次。
    invalidate();
  }

  // ── 动画 ──

  /// 启动首屏淡入（只跑一次）。
  void _startFadeIn() {
    if (_fadeTimer != null || _fadeIn >= 1) return;
    _fadeIn = 0;
    // ★ 16ms ≈ 60fps。不用 8ms：再快人眼分辨不出，只是白烧 CPU。
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      _fadeIn += 0.09; // ≈ 11 帧 ≈ 180ms 走完
      if (_fadeIn >= 1) {
        _fadeIn = 1;
        t.cancel();
        _fadeTimer = null;
      }
      invalidate();
    });
  }

  /// 标签页切换动画：新页从下往上滑入（用轻微位移 + 淡入模拟）。
  void _startTabAnim(int from) {
    _tabAnimFrom = from;
    _tabAnim = 0;
    _tabTimer?.cancel();
    _tabTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      _tabAnim += 0.14; // ≈ 7 帧 ≈ 110ms
      if (_tabAnim >= 1) {
        _tabAnim = 1;
        _tabAnimFrom = -1;
        t.cancel();
        _tabTimer = null;
      }
      invalidate();
    });
  }

  /// 淡入系数：把颜色按进度混向底色。
  ///
  /// ★ 用"混色"而不是"设置 alpha"：GDI 没有真正的图层透明度，
  ///   但把每个颜色按 t 混向背景色，观感上等价且不需要任何新 API。
  int _fade(int color) {
    if (_fadeIn >= 1) return color;
    return _blendColor(color, Palette.bg, _fadeIn);
  }

  /// 只让状态栏那一条失效。
  ///
  /// 扫榜进度更新（文字 + 转圈）只影响状态栏，用整窗重绘是浪费：
  /// 每次都要把上方几百行的表格重新排版绘制一遍。
  void _invalidateStatusBar() {
    final h = Metrics.statusHeight;
    invalidateRectClient(Rc.xywh(0, height - h, width, h));
  }

  @override
  void onDestroyed() {
    // ★ 必须清掉定时器：窗口没了还 tick 就是在已释放的 hwnd 上调 invalidate。
    _fadeTimer?.cancel();
    _tabTimer?.cancel();
    _progressTimer?.cancel();
    _coverTimer?.cancel(); // 封面拉取队列也要停
  }

  @override
  void onResize(int w, int h) {
    // ★ 先更新缩放：字号/行高/间距都挂在 Metrics 上，
    //   窗口一变就要整套重算，然后重绘才拿得到新尺寸。
    final changed = UiScale.applyTo(w, h);

    // 窗口拿到真实尺寸后立刻载一次数据。
    // 放在 onResize 而不是构造函数：构造函数里读磁盘会把建窗拖慢，
    // 而且那时还没有客户区尺寸、也刷不了界面。
    if (!_autoLoaded && w > 0 && h > 0) {
      _autoLoaded = true;
      _startFadeIn();
      reload();
      return;
    }
    if (changed) invalidate();
  }


  @override
  void onPaint(Gdi g) {
    hitRects.clear();
    g.fill(Rc.xywh(0, 0, width, height), Palette.bg);

    _paintHeader(g);
    _paintSidebar(g);
    _paintContent(g);
    _paintStatus(g);

    // ★ 下拉菜单必须**最后画**（在所有内容之上）—— 它是一层浮层。
    //   若在 _paintHeader 里就画，后面 _paintContent 会把它盖掉下半截。
    _paintPopMenu(g);

    // 扫榜中时画一层轻遮罩提示（防误操作）
    if (phase == ScanPhase.running) _paintScanOverlay(g);
  }

  // ── 导出 / 导入 下拉菜单 ──

  // ── 菜单结构：**按用途分两块** ──
  //
  // ★ 用户要求："导入导出功能分为两块，一块是榜单本身，另一块是趋势分析和历史对比"。
  //   这两类产物的**口径完全不同**，混在一个平铺列表里，用户分不清
  //   "我导出的到底是这一份榜，还是这个榜的历史"：
  //     · 榜单 = **单份快照**的内容（明细 / 图片 / 附件）；
  //     · 趋势·对比 = **跨期**的产物（趋势图 / 全部快照汇总里的两两对比）。
  //   菜单里用分组标题写清楚，标题本身就是"这是什么"的说明。
  static const List<(int, String)> _boardItems = [
    (menuExportCsv, 'CSV 明细表'),
    (menuExportJson, 'JSON（单份快照 + 分析）'),
    (menuExportBoardImage, '榜单图片（PNG 长图）'),
    (menuExportAttachments, '附件（图片 / 文本）'),
  ];

  static const List<(int, String)> _trendItems = [
    (menuExportTrendImage, '趋势图（PNG，含解读）'),
    (menuExportBundle, '全部快照汇总（含两两对比）'),
  ];

  static const List<(int, String)> _importItems = [
    (menuImportImage, '图片 → 存为该快照的附件'),
    (menuImportText, '粘贴文本 → 存为附件文本'),
  ];

  /// 菜单 → 分组。`title` 为空表示整份菜单只有一组（不画标题，免得噪声）。
  List<MenuSection> _sectionsOf(String menu) {
    if (menu == 'export') {
      return [
        MenuSection('榜单（这一份快照）',
            [for (final it in _boardItems) it.$2]),
        MenuSection('趋势分析 / 历史对比',
            [for (final it in _trendItems) it.$2]),
      ];
    }
    return [
      MenuSection('', [for (final it in _importItems) it.$2]),
    ];
  }

  /// 分组里的第 (si, ii) 项 → 控件 id。**必须与 [_sectionsOf] 同序**。
  int _idAt(String menu, int si, int ii) {
    if (menu == 'export') {
      final list = si == 0 ? _boardItems : _trendItems;
      return list[ii].$1;
    }
    return _importItems[ii].$1;
  }

  /// 全部菜单项（供"点外面就关"这类判定用）。
  List<(int, String)> _itemsOf(String menu) {
    if (menu == 'export') return [..._boardItems, ..._trendItems];
    return _importItems;
  }

  /// 菜单锚点（按钮矩形）。
  Rc _anchorOf(String menu) {
    final id = menu == 'export' ? idExportButton : idImportButton;
    return hitRects[id] ?? const Rc(0, 0, 0, 0);
  }

  /// 画下拉菜单浮层，并登记每项的命中矩形。
  void _paintPopMenu(Gdi g) {
    if (openMenu.isEmpty) return;
    final anchor = _anchorOf(openMenu);
    if (anchor.width == 0) return;
    final sections = _sectionsOf(openMenu);
    menuHotId = -1;
    // ★ 排版只算一次：命中区与绘制用同一份 rects（两份实现必然漂移）
    final l = layoutSectionedMenu(anchor, sections);
    for (final (si, ii, r) in l.items) {
      hitRects[_idAt(openMenu, si, ii)] = r;
    }
    drawSectionedMenu(g, anchor, sections, mouseX: mouseX, mouseY: mouseY);
  }

  /// 菜单里某一项的点击处理。返回 true = 已消费。
  bool _handleMenuClick(int x, int y) {
    if (openMenu.isEmpty) return false;
    final l = layoutSectionedMenu(_anchorOf(openMenu), _sectionsOf(openMenu));
    for (final (si, ii, r) in l.items) {
      if (!r.contains(x, y)) continue;
      final id = _idAt(openMenu, si, ii);
      openMenu = '';
      invalidate();
      _onMenuCommand(id);
      return true;
    }
    // 点在菜单外 → 关（不影响本次点击的其它处理：这里就直接关掉并消费，
    // 避免"关菜单"和"点到下面的按钮"同时发生，那会让用户莫名其妙）
    if (!l.box.contains(x, y)) {
      openMenu = '';
      invalidate();
      return true;
    }
    return true; // 点在菜单框内的空白 → 吃掉
  }

  void _paintHeader(Gdi g) {
    final h = Metrics.headerHeight;
    final u = Metrics.factor;
    // ★ 首屏淡入：顶栏整体参与掺色（含它的分隔线），
    //   所以窗口出现的瞬间是"从底色里浮出来"，不是"啪"地一下全亮。
    g.fill(Rc.xywh(0, 0, width, h), _fade(Palette.headerBg));
    g.line(0, h - 1, width, h - 1, _fade(Palette.line));

    // 品牌区：一个小色块 + 标题，比纯文字更像"应用"
    final px = Metrics.captionPadLeft;
    final logo = (26 * u).round();
    final ly = (h - logo) ~/ 2;
    g.roundFill(Rc.xywh(px, ly, logo, logo), _fade(Palette.accent),
        _fade(Palette.accent), radius: (7 * u).round());
    g.text('榜', Rc.xywh(px, ly, logo, logo), _fade(Palette.bg),
        size: Metrics.fontSizeSmall, align: dtCenter, bold: true);

    final tx = px + logo + (12 * u).round();
    final titleColor = hasFocus ? Palette.fg : Palette.fgInactive;
    g.text('网文扫榜', Rc.xywh(tx, 0, 220, h), _fade(titleColor),
        size: Metrics.fontSizeTitle, bold: true);
    final tw = g.measure('网文扫榜', size: Metrics.fontSizeTitle, bold: true);
    final bh = (20 * u).round();
    drawBadge(g, tx + tw + (12 * u).round(), (h - bh) ~/ 2, bh,
        '起点 · 番茄 · 七猫 · 晋江', fg: _fade(Palette.accent));

    // ★ 右侧按钮从**窗口按钮**这一端开始排：自绘窗口按钮必须贴在右上角，
    //   这是所有 Windows 程序的固定位置 —— 换位置用户会找不到关闭键。
    _paintWindowButtons(g, h);

    final winBtnLeft =
        width - Metrics.winBtnInset - Metrics.winBtnW * 3 - (2 * u).round();

    final btnH = Metrics.buttonH;
    var x = winBtnLeft - (10 * u).round();
    void btn(int id, String label, BtnKind kind, int baseW, {bool enabled = true}) {
      final w = (baseW * u).round();
      x -= w;
      final r = Rc.xywh(x, (h - btnH) ~/ 2, w, btnH);
      hitRects[id] = r;
      drawButton(g, r,
          label: label,
          kind: kind,
          st: CtlState(
              hot: r.contains(mouseX, mouseY) && _winBtnHot == -1,
              enabled: enabled));
      x -= (8 * u).round();
    }

    final running = phase == ScanPhase.running;
    btn(idImportButton, '导入', BtnKind.ghost, 64, enabled: vm != null);
    btn(idExportButton, '导出', BtnKind.ghost, 64, enabled: vm != null);
    btn(idManageButton, '数据管理', BtnKind.ghost, 92, enabled: vm != null);
    btn(idReloadButton, '重载数据', BtnKind.ghost, 90);
    btn(idScanButton, running ? '正在扫榜…' : '扫榜设置',
        BtnKind.primary, 104, enabled: !running);
    // 主题切换放在最左（离主操作最远），且是**图标 + 文字**而不是纯图标：
    // 太阳/月亮在自绘 GDI 里画出来就是两个小图形，用户不一定一眼认得出
    // 它跟"白天/黑夜"有关 —— 写上"浅色/深色"就没有歧义了。
    btn(idThemeButton, Palette.isDark ? '浅色' : '深色', BtnKind.ghost, 70);
  }

  /// 右上角三个窗口按钮（最小化 / 最大化-还原 / 关闭）。
  ///
  /// ★ 这里是**纯读取**：hot 状态只由 [onMove] 维护（它是鼠标位置的唯一
  ///   来源）。绘制阶段顺手回写状态会导致"画一次改一次"，
  ///   和 onMove 的判断互相打架，hover 就会闪。
  void _paintWindowButtons(Gdi g, int headerH) {
    final bw = Metrics.winBtnW;
    final inset = Metrics.winBtnInset;
    // 按钮顶到窗口上沿：原生窗口就是这样，留白反而显得"漂浮"。
    const by = 0;
    var x = width - inset - bw * 3;

    final maxKind = isMaximized ? WinBtnKind.restore : WinBtnKind.maximize;

    for (var i = 0; i < 3; i++) {
      final kind = i == 0
          ? WinBtnKind.minimize
          : (i == 1 ? maxKind : WinBtnKind.close);
      final id = i == 0
          ? idWinMinimize
          : (i == 1 ? idWinMaximize : idWinClose);
      final r = Rc.xywh(x, by, bw, Metrics.winBtnH);
      hitRects[id] = r;

      // ★ 按钮区域必须排除在标题栏拖拽之外（在 onHitTest 里做），
      //   否则按下去走的是系统 HTCAPTION 拖动，按钮反馈全失效 ——
      //   这是无边框窗口最经典的坑。
      final hot = _winBtnHot == id;
      drawWinButton(g, x, by,
          kind: kind,
          hot: hot,
          pressed: false,
          windowActive: hasFocus);
      x += bw;
    }
  }

  void _paintSidebar(Gdi g) {
    final w = Metrics.sidebarWidth;
    final top = Metrics.headerHeight;
    final bottom = height - Metrics.statusHeight;
    final u = Metrics.factor;
    g.fill(Rc.xywh(0, top, w, bottom - top), Palette.sidebar);
    g.line(w, top, w, bottom, Palette.line);

    if (vm == null) {
      g.text('正在读取快照…',
          Rc.xywh((12 * u).round(), top + (16 * u).round(), w - 24, 24),
          Palette.fgDim, size: Metrics.fontSizeSmall);
      return;
    }

    // 视口（滚动裁剪）
    final view = Rc.xywh(0, top, w, bottom - top);

    final headH = (26 * u).round();
    // ★ 分组头 32 → 44、条目 46 → 52（第 14 轮）。
    //   32px 的"平台条"在 250px 宽的侧栏里就是一条薄片（用户说的"窄长条"）；
    //   条目跟着一起加，否则**分组头比条目还矮**，层级就反了。
    final grpH = Metrics.sidebarGroupHeight;
    final itemH = Metrics.sidebarItemHeight;
    final padx = (14 * u).round();
    final rowInset = (8 * u).round();

    // ★ 底部"管理入口"只在真的有隐藏项时占位 —— 常驻一条没有内容的横条
    //   等于白吃 30px 的高度（侧栏本来就窄）。
    final footH = vm!.hiddenCount > 0 ? (30 * u).round() : 0;
    final listBottom = bottom - footH;

    var y = top + (10 * u).round() - sidebarScroll;

    // ★ 真裁剪到侧栏视口：滚动时内容不能溢出到状态栏/内容区。
    //   （下面的 `if (y + itemH > top && y < bottom)` 只是起点守卫，
    //   挡不住"一行从视口内开始、画到视口外"。）
    final endSideClip = g.clipTo(view);
    // ★ idx / contentBottom 必须声明在 try 之外：try/finally 的块作用域
    //   不会把它们泄漏到后面（滚动条布局要用）。踩过一次编译错误。
    var idx = 0;
    var gi = 0;
    var contentBottom = y;
    sideRows.clear();
    try {
      g.text('数据快照 · ${vm!.snapshotCount} 份 / ${vm!.recordCount} 条'
          '${vm!.hiddenCount > 0 ? '（隐藏 ${vm!.hiddenCount}）' : ''}',
          Rc.xywh(padx, y, w - padx * 2, headH), Palette.fgFaint,
          size: Metrics.fontSizeTiny);
      y += headH;

      for (final grp in vm!.groups) {
        if (grp.items.isEmpty && grp.hiddenCount == 0) continue;
        final collapsed = settings.collapsedSources.contains(grp.sourceId);
        final gid = sidebarGroupIdBase + gi;

        // ── 平台分组头（**可点：折叠/展开**）──
        if (y + grpH > top && y < listBottom) {
          final gh = Rc.xywh(0, y, w, grpH);
          hitRects[gid] = gh;
          final ghot = gh.contains(mouseX, mouseY);
          g.fill(gh, ghot ? Palette.hover : Palette.surfaceAlt);
          g.fill(Rc.xywh(0, y, (3 * u).round().clamp(2, 5), grpH), Palette.accent);

          // 折叠箭头（收起=朝右，展开=朝下）—— 用线段画，不依赖字体字形
          final ax = padx + (5 * u).round();
          final ay = y + grpH ~/ 2;
          final arm = (4 * u).round().clamp(3, 6);
          final lw = (1.6 * u).round().clamp(1, 3);
          final acol = ghot ? Palette.accent : Palette.fgSub;
          if (collapsed) {
            g.line(ax - arm ~/ 2, ay - arm, ax + arm ~/ 2, ay, acol, width: lw);
            g.line(ax + arm ~/ 2, ay, ax - arm ~/ 2, ay + arm, acol, width: lw);
          } else {
            g.line(ax - arm, ay - arm ~/ 2, ax, ay + arm ~/ 2, acol, width: lw);
            g.line(ax, ay + arm ~/ 2, ax + arm, ay - arm ~/ 2, acol, width: lw);
          }

          final labelX = ax + arm + (8 * u).round();
          g.text(grp.title,
              Rc.xywh(labelX, y, w - labelX - (52 * u).round(), grpH),
              Palette.fg, size: Metrics.fontSizeSidebar, bold: true);
          // 徽标：可见数（+ 隐藏数）
          final badge = grp.hiddenCount > 0
              ? '${grp.items.length}+${grp.hiddenCount}'
              : '${grp.items.length}';
          // 徽标随分组头一起放大（18 → 24），否则在大了一号的条上显得孤零零
          final bh = (26 * u).round();
          drawBadge(
              g,
              w - padx - g.measure(badge, size: Metrics.fontSizeSidebar) - (8 * u).round(),
              y + (grpH - bh) ~/ 2,
              bh,
              badge,
              fg: grp.hiddenCount > 0 ? Palette.warn : Palette.fgDim,
              fontSize: Metrics.fontSizeSidebarSub);
        }
        y += grpH;
        gi++;
        if (collapsed) {
          y += (4 * u).round();
          contentBottom = y;
          continue;
        }

        for (final it in grp.items) {
          if (y + itemH > top && y < listBottom) {
            // ★ 行矩形左右各留 8px —— 选中态高亮框（含左侧 accent 竖条）
            //   必须**完整**落在留白里。原来 r.left=0，accent 条正好压在
            //   侧栏左边缘上：左半边被视口裁掉、右半边糊在 `w` 分隔线上，
            //   视频帧 y=202 行实测 `x=0..1` 是 accent 色、`x=2..7` 是
            //   其反锯齿残影 `(0,29,50)`，高亮框左缘"齐边无留白"——
            //   这就是用户说的"未对齐"。
            final r = Rc.xywh(rowInset, y, w - rowInset * 2, itemH);
            final id = sidebarIdBase + idx;
            hitRects[id] = r;
            listIndexBase[id] = it.meta.id;
            sideRows.add(it.meta);

            final on = it.meta.id == selectedId;
            final hot = r.contains(mouseX, mouseY);
            if (on) {
              g.roundFill(r, Palette.selected, Palette.selectedBorder,
                  radius: Metrics.radiusSmall);
              // 选中项左侧再压一条主色竖条（比整框描边更"轻"）。
              // 竖条贴在高亮框内缘（r.left + 3px），不再骑在框边线上。
              final lw = (3 * u).round().clamp(2, 5);
              final innerInset = (3 * u).round();
              g.roundFill(
                  Rc.xywh(r.left + innerInset, r.top + (8 * u).round(), lw,
                      r.height - (16 * u).round()),
                  Palette.accent,
                  Palette.accent,
                  radius: lw ~/ 2);
            } else if (hot) {
              g.roundFill(r, Palette.hover, Palette.hover,
                  radius: Metrics.radiusSmall);
            }

            // 书名 / 日期两行；数字右对齐
            final dot = (7 * u).round();
            final dotTop = r.top + (itemH - dot) ~/ 2;
            final dotColor = it.ok ? Palette.ok : Palette.bad;
            g.roundFill(Rc.xywh(r.left + padx - (5 * u).round(), dotTop, dot, dot),
                dotColor, dotColor, radius: dot ~/ 2);

            // ★ 数字列宽**只定义一次**，书名框右缘由它反推。
            //   原来两条算式各写一个魔数（书名 "- 48"、数字右缘 "right - 46"），
            //   谁也不知道对方在哪 → 书名框实际右缘 202、数字框左缘 196，
            //   **重叠 6px**（书名撞进数字里）。
            //
            // ★ 右缘再往左收 8px（`r.right - 8u`）：选中时整行是一圈**蓝框**，
            //   数字若贴着 `r.right` 就等于压在框线上（用户原话：
            //   "数字 30 往左调整一下，保证在蓝色框内"）。8px 是描边+圆角
            //   都吃进去之后仍有呼吸感的宽度。
            const countW = 46; // 数字列（含左间隙）宽度，单位：逻辑像素
            final countRight = r.right - (8 * u).round();
            final countLeft = countRight - (countW * u).round();
            final nameRight = countLeft - (6 * u).round(); // 再留 6px 硬间隙
            final nameW = nameRight - (r.left + padx + (8 * u).round());
            final lineH = (itemH - (10 * u).round()) ~/ 2;
            g.text(it.label,
                Rc.xywh(r.left + padx + (8 * u).round(), r.top + (7 * u).round(),
                    nameW, lineH),
                Palette.fg, size: Metrics.fontSizeSidebar, bold: on);
            g.text(it.dateLabel,
                Rc.xywh(r.left + padx + (8 * u).round(),
                    r.top + (9 * u).round() + lineH, nameW, lineH),
                Palette.fgFaint, size: Metrics.fontSizeSidebarSub);

            // ★ 悬停时**用"隐藏"按钮顶掉数字**，而不是并排画两个。
            //   侧栏只有 250px，右端再挤一个按钮必然和数字重叠；
            //   而"数字"在 hover 的这一刻是可以让位的（松手就回来）。
            final hideR = Rc.xywh(r.right - (34 * u).round(),
                r.top + (itemH - (22 * u).round()) ~/ 2, (22 * u).round(),
                (22 * u).round());
            // ★ 隐藏按钮的命中区**必须也按 meta.id 反查**。
            //   `idx` 是"全量下标"（`idx++` 在可见性守卫之外），而
            //   `sideRows` 只收**画出来**的行 —— 侧栏一滚动，两套下标就错位：
            //   要么 `i >= sideRows.length` 静默无效，要么**隐藏了另一张榜**。
            //   选中行（上面 listIndexBase）早就是这么做的，这里照抄。
            hitRects[sidebarHideIdBase + idx] = hideR;
            listIndexBase[sidebarHideIdBase + idx] = it.meta.id;
            if (hot) {
              _paintHideGlyph(g, hideR, hideR.contains(mouseX, mouseY));
            } else {
              g.text('${it.count}',
                  Rc.xywh(countLeft, r.top, (countW * u).round(), itemH),
                  Palette.fgSub, size: Metrics.fontSizeTiny, align: dtRight);
              // （右缘已内收 8px —— 见上面 countRight 的说明）
            }
          }
          y += itemH;
          idx++;
        }
        // 这一组有隐藏项 → 一行小字说明（绝不静默）
        if (grp.hiddenCount > 0 && y + (20 * u).round() > top && y < listBottom) {
          g.text('　已隐藏 ${grp.hiddenCount} 项（数据仍在）',
              Rc.xywh(padx, y, w - padx * 2, (20 * u).round()), Palette.fgFaint,
              size: Metrics.fontSizeTiny);
          y += (20 * u).round();
        }
        y += (6 * u).round();
        contentBottom = y;
      }
    } finally {
      // ★ 内容画完，撤掉裁剪 —— 滚动条必须画在裁剪之外（否则被切成半截）
      endSideClip();
    }
    sideItemCount = idx;
    sideGroupCount = gi;

    // ── 底部：隐藏管理入口（只在有隐藏项时出现）──
    if (footH > 0) {
      final fr = Rc.xywh(0, bottom - footH, w, footH);
      final hot = fr.contains(mouseX, mouseY);
      hitRects[idSidebarManage] = fr;
      g.fill(fr, hot ? Palette.hover : Palette.surfaceAlt);
      g.line(0, fr.top, w, fr.top, Palette.line);
      final txt = '已隐藏 ${vm!.hiddenCount} 项 · 管理';
      g.text(txt, Rc.xywh(padx, fr.top, w - padx * 2, footH),
          hot ? Palette.accent : Palette.fgSub,
          size: Metrics.fontSizeTiny, vcenter: true, bold: hot);
    }

    // 侧栏滚动条
    final contentH = contentBottom - top + sidebarScroll;
    final viewH = listBottom - top;
    sidebarContentH = contentH;
    if (contentH > viewH) {
      final sArea = Rc.xywh(0, top, w, viewH);
      drawScrollbar(g, sArea,
          contentHeight: contentH,
          viewHeight: viewH,
          scrollY: sidebarScroll,
          hot: sArea.contains(mouseX, mouseY));
    }
    // 视口兜底：内容不足一屏时不留滚动
    if (contentH <= viewH && sidebarScroll != 0) sidebarScroll = 0;
    if (view.isEmpty) return;
  }

  /// 行右侧的"隐藏"小按钮：一个圆圈加一道斜杠（矢量画，不依赖字体）。
  void _paintHideGlyph(Gdi g, Rc r, bool hot) {
    g.roundFill(r, hot ? Palette.hover : Palette.surface, Palette.line,
        radius: Metrics.radiusSmall);
    drawSlashCircle(g, r.left + r.width ~/ 2, r.top + r.height ~/ 2,
        hot ? Palette.warn : Palette.fgFaint);
  }

  void _paintContent(Gdi g) {
    final u = Metrics.factor;
    final left = Metrics.sidebarWidth + 1;
    final top = Metrics.headerHeight;
    final w = width - left;
    final bottom = height - Metrics.statusHeight;
    final area = Rc.xywh(left, top, w, bottom - top);
    final padx = (18 * u).round();

    // 标签页（下划线式）
    final tabH = Metrics.tabHeight;
    final tabLabels = ['榜单明细', '历史对比', '跨榜分析'];
    final rects = drawTabs(g, area.left + padx, area.top, tabH, tabLabels,
        selected: curTab, mouseX: mouseX, mouseY: mouseY);
    for (var i = 0; i < rects.length; i++) {
      hitRects[idTabBase + i] = rects[i];
    }
    // 标签条下的分隔线，只画到最后一个标签的右边（现代 UI 的做法：
    // 不是横贯整屏的一条线，而是"内容区起点"）
    final lineX = rects.isEmpty ? area.right : rects.last.right + (8 * u).round();
    g.line(area.left, area.top + tabH, lineX, area.top + tabH, Palette.line);

    final body = Rc.xywh(area.left + padx, area.top + tabH + (14 * u).round(),
        area.width - padx * 2, area.height - tabH - (22 * u).round());

    if (vm == null) {
      g.text('没有可显示的数据', body, Palette.fgDim, size: Metrics.fontSize);
      return;
    }
    final cur = currentMeta();
    if (cur == null) {
      _paintEmpty(g, body);
      return;
    }

    switch (curTab) {
      case tabDetail:
        _paintDetail(g, body, cur);
      case tabDiff:
        _paintDiff(g, body, cur);
      case tabCross:
        _paintCross(g, body);
    }
  }

  void _paintEmpty(Gdi g, Rc area) {
    final u = Metrics.factor;
    g.roundFill(area, Palette.surface, Palette.line, radius: Metrics.radius);
    final cx = area.left;
    final cy = area.top + area.height ~/ 2 - (40 * u).round();
    g.text('左侧还没有快照', Rc.xywh(cx, cy, area.width, (30 * u).round()),
        Palette.fg, size: Metrics.fontSizeTitle, align: dtCenter, bold: true);
    g.text('点右上角「扫榜设置」抓一轮数据（约 35 秒，16 次请求）',
        Rc.xywh(cx, cy + (34 * u).round(), area.width, (24 * u).round()),
        Palette.fgSub, size: Metrics.fontSize, align: dtCenter);
  }

  // ── 标签页①：榜单明细 ──

  /// 卡片与提示条的绘制统一在 [widgets.dart] 的 `drawCard` / `drawHint` 里
  /// —— 这样主窗和设置窗用的是同一套视觉，不会各自长歪。

  void _paintDetail(Gdi g, Rc area, SnapshotMeta m) {
    final u = Metrics.factor;
    var y = area.top;

    // 头部信息卡（132 而不是 108：多出的 24px 正好放"附件"那一行）
    final headH = (132 * u).round();
    final head = Rc.xywh(area.left, y, area.width, headH);
    g.roundFill(head, Palette.surface, Palette.line, radius: Metrics.radius);
    final padx = (18 * u).round();

    final view = SnapshotView(m, const RankAnalyzer().analyze(m.result));
    final titleText = '${view.title} · ${view.subtitle}';
    g.text(titleText,
        Rc.xywh(head.left + padx, head.top + (12 * u).round(),
            head.width - 200, (26 * u).round()),
        Palette.fg, size: Metrics.fontSizeTitle, bold: true);

    final (badgeText, badgeKind) = view.statusBadge;
    final badgeColor = badgeKind == 0
        ? Palette.ok
        : (badgeKind == 1 ? Palette.warn : Palette.bad);
    final bh = (22 * u).round();
    final bx = head.left +
        padx +
        g.measure(titleText, size: Metrics.fontSizeTitle, bold: true) +
        (14 * u).round();
    final r1 = drawBadge(g, bx, head.top + (13 * u).round(), bh, badgeText,
        fg: badgeColor);
    drawBadge(g, r1.right + (8 * u).round(), r1.top, bh, '${m.count} 条',
        fg: Palette.fgSub);

    var subY = head.top + (48 * u).round();
    final subH = (20 * u).round();
    final step = (19 * u).round();
    if (m.result.robotsVerdict != null) {
      g.text('robots：${m.result.robotsVerdict}',
          Rc.xywh(head.left + padx, subY, head.width - padx * 2, subH),
          Palette.fgDim, size: Metrics.fontSizeSmall);
      subY += step;
    }
    if (view.qualitySummary != null) {
      g.text('质量：${view.qualitySummary}',
          Rc.xywh(head.left + padx, subY, head.width - padx * 2, subH),
          Palette.fgSub, size: Metrics.fontSizeSmall);
      subY += step;
    }
    for (final p in view.problems.take(1)) {
      g.text('问题：$p',
          Rc.xywh(head.left + padx, subY, head.width - padx * 2, subH),
          Palette.warn, size: Metrics.fontSizeSmall);
      subY += step;
    }
    // ★ 附件要**看得见**：导入的图片/文本如果界面上一个字都不提，
    //   用户会以为"导入没成功"，然后再导一遍 —— 文件越堆越多。
    //   这里只显示数量与文件名（不内嵌预览：自绘 GDI 里解码缩放图片是另一摊事），
    //   配合「导出 → 附件」菜单就能把原图拿走。
    final atts = attachmentsOf(m);
    g.text(
        atts.isEmpty
            ? '附件：无（用「导入」菜单可挂截图 / 粘贴文本）'
            : '附件 ${atts.length} 个：${atts.join('、')}',
        Rc.xywh(head.left + padx, subY, head.width - padx * 2, subH),
        atts.isEmpty ? Palette.fgFaint : Palette.accent,
        size: Metrics.fontSizeSmall,
        ellipsis: true);

    // 打开来源按钮
    if (view.sourceUrl != null) {
      final bw = (110 * u).round();
      final r = Rc.xywh(head.right - padx - bw, head.top + (13 * u).round(), bw,
          Metrics.buttonH);
      hitRects[idOpenSource] = r;
      drawButton(g, r,
          label: '打开来源页',
          kind: BtnKind.ghost,
          st: CtlState(hot: r.contains(mouseX, mouseY)));
    }

    y += headH + (12 * u).round();

    // 指标口径提示
    final hint = drawHint(g, area, y, '指标口径：${_metricLegend(m)}', Palette.accent);
    y = hint.bottom + (12 * u).round();

    // 明细表 —— 套一层卡片
    final card = Rc.xywh(area.left, y, area.width, area.bottom - y);
    final content = drawCard(g, card, title: '榜单明细', badge: '${m.count} 条');
    final tableArea = Rc.xywh(content.left + 1, content.top, content.width - 2,
        content.height - 1);

    // ★★ 列定义在 [board_text.dart] —— **界面与导出的榜单图共用同一份**。
    //
    //   用户报过"导出榜单与软件内的榜单明细差别很大"：根因就是两边各写了一套列
    //   （界面 8 列、导出图 4 列且顺序不同）。顺序、表头文字、单元格文本、
    //   基准宽、对齐方式、谁吃余量 —— 全部只有一份，改一处两边都改。
    //   唯一的例外是「链接」：它在界面里是可点按钮，导出图会跳过它。
    final cols = <Column>[
      for (final c in boardCols)
        Column(
          key: c.name,
          title: boardColTitle(c),
          width: boardColBaseWidth(c),
          align: boardColAlign(c),
          stretch: boardColStretch(c),
        ),
    ];

    final rows = <List<String>>[];
    final colors = <int>[];
    // 书名那一格单独上色（可点 → 用链接色），其余格子跟随行色。
    final cellColors = <List<int?>>[];
    for (final e in m.result.entries) {
      final hasLink = (e.url ?? '').isNotEmpty;
      rows.add([
        for (final c in boardCols) boardColText(c, e, source: m.source),
      ]);
      colors.add(e.titleObfuscated ? Palette.obfuscated : Palette.fg);
      // 书名那一格单独上色（可点 → 用链接色），其余格子跟随行色。
      cellColors.add([
        for (final c in boardCols)
          c == BoardCol.title
              ? (hasLink
                  ? (e.titleObfuscated ? Palette.obfuscated : Palette.accent)
                  : (e.titleObfuscated ? Palette.obfuscated : Palette.fg))
              : null,
      ]);
    }

    hitRects[idDetailTable] = tableArea;

    // ★★ 明细表的缩放是**自适应**的：能 1.5 倍就 1.5 倍，窗口不够宽就等比缩到
    //    刚好放得下。见 [Metrics.detailScaleFor]。
    //
    //    用户第 20 轮的原话是"小窗口时，右边无法看见" ——
    //    死守 1.5 倍的结果是「链接」列被挤出屏幕：看不到「打开」按钮，
    //    也就无从点开书籍详情页（用户另一句"链接还是点不开"多半就是这个）。
    //    "看得全"优先于"放得大"，但窗口一宽回来，1.5 倍立刻恢复。
    final baseTotal = cols.fold<int>(0, (a, c) => a + c.width);
    final vBarW = (11 * u).round();
    detailS = Metrics.detailScaleFor(
        available: tableArea.width - vBarW, baseTotal: baseTotal);

    final detailRowH = Metrics.detailRowHeightAt(detailS);
    final detailHeadH = Metrics.detailHeaderHeightAt(detailS);
    final contentH = tableContentHeight(rows.length,
        rowHeight: detailRowH, headerRowHeight: detailHeadH);
    final viewH = tableArea.height - detailHeadH;
    detailScroll = detailScroll.clamp(0, (contentH - viewH) < 0 ? 0 : contentH - viewH);

    // 自然总宽 = Σ(列基准宽 × factor × 缩放)。列基准宽写死在 cols 里，
    // 这里按同一个公式复算（自检会拿它对照）。
    final naturalW = (baseTotal * u * detailS).round();
    naturalWOfDetail = naturalW;
    final maxX = (naturalW - tableArea.width) < 0 ? 0 : naturalW - tableArea.width;
    detailScrollX = detailScrollX.clamp(0, maxX);
    detailTableArea = tableArea;

    // ★★ 画多宽：**放不下才按自然总宽，放得下就撑满可用区**。
    //
    //   原来这里恒为 `naturalW`，于是"宽屏下自然总宽 < 可用宽"时，
    //   整张表按自然宽画完就收笔 —— 右侧留出一大片空白，
    //   而 stretch 列（备注）却还停在基准宽、文字被截成 "任…"。
    //   同一块地方一边空着一边截断，是最容易被一眼看穿的版面 bug。
    //   撑满之后余量全部给 stretch 列，两边都正常。
    final drawW = naturalW > tableArea.width ? naturalW : tableArea.width;
    detailDrawnW = drawW;
    detailDrawnRight = tableArea.left + drawW;

    // 画的时候把整个表**左移** detailScrollX，并裁剪到可见区域 ——
    // 这样列宽/命中矩形都还是真实坐标，只有"看得见哪一段"被控制。
    final drawArea = Rc.xywh(tableArea.left - detailScrollX, tableArea.top,
        drawW, tableArea.height);
    final endTableClip = g.clipTo(tableArea);
    final TableRender tr;
    try {
      tr = drawTable(g, drawArea, cols, rows,
          scrollY: detailScroll,
          mouseX: mouseX,
          mouseY: mouseY,
          rowColors: colors,
          cellColors: cellColors,
          rowHeight: detailRowH,
          headerRowHeight: detailHeadH,
          fontSize: Metrics.detailFontAt(detailS),
          widthScale: detailS);
    } finally {
      endTableClip();
    }

    // ★★ 逐行补画「封面缩略图」与「打开」按钮 —— **必须在同一个裁剪里**。
    //
    //   这两样按行的"整表自然坐标"摆（只有 drawTable 算得准），
    //   横向滚动之后它们的 x 可能落在视口之外。原来这段写在 `endTableClip()`
    //   **之后**，于是视口外的封面/按钮会直接糊到侧栏或别的面板上。
    //
    //   更要命的是它当时配了一个"整行可见"的守卫：
    //       if (!cells[2].overlaps(tableArea)) continue;
    //   `cells[2]` 是**书名格** —— 用户往右滚去看「链接」列时，书名格正好
    //   滚出屏幕，于是**整行被跳过**：「打开」按钮既不画也不登记命中区，
    //   点它当然毫无反应。用户报的"链接还是点不开"就是这个。
    //
    //   现在的做法：画的部分交给裁剪（越界自然被裁掉），
    //   命中区一律 intersect 到可见区后再登记（null 就不登记）。
    //   两条规则各自独立，不再互相牵连。
    {
      final endClip2 = g.clipTo(tableArea);
      try {
        detailLinks.clear();
        detailLinkCount = m.result.entries.length;
        final body = Rc.xywh(tableArea.left, tableArea.top + detailHeadH,
            tableArea.width, tableArea.height - detailHeadH);
        for (var i = 0; i < tr.rowIndices.length; i++) {
          final rowIdx = tr.rowIndices[i];
          if (rowIdx < 0 || rowIdx >= m.result.entries.length) continue;
          final cells = tr.cellRects[i];
          if (cells.length < cols.length) continue;
          final e = m.result.entries[rowIdx];
          final url = e.url ?? '';

          // 封面格：**只有真的露出来才取图**（懒加载的本意就是这个）
          if (cells[1].overlaps(tableArea)) {
            _paintCover(g, cells[1], e, m.source, rowIdx);
          }

          // 整行可点 —— **即使这一行没有 url 也登记**：点了会如实告诉你
          // "这一行没有可打开的书链接"，比点了毫无反应强。
          final rowHit = tr.rowRects[i].intersect(body);
          if (rowHit != null) hitRects[idBookRowLinkBase + rowIdx] = rowHit;

          // 链接格：一个小按钮（没链接就不画，也不登记按钮命中）
          if (url.isEmpty) continue;
          final cr = cells[7];
          // 按钮跟着整表一起缩放（不然放大的行里嵌一个小按钮很突兀）
          final bw = (46 * u * detailS).round();
          final bh = (24 * u * detailS).round();
          final br = Rc.xywh(cr.left + (cr.width - bw) ~/ 2,
              cr.top + (cr.height - bh) ~/ 2, bw, bh);
          final hot = br.contains(mouseX, mouseY) ||
              cells[2].contains(mouseX, mouseY); // 书名格也算（书名是链接）
          detailLinks[rowIdx] = url;
          final titleHit = cells[2].intersect(body);
          if (titleHit != null) hitRects[idBookTitleLinkBase + rowIdx] = titleHit;
          final btnHit = br.intersect(body);
          if (btnHit != null) hitRects[idBookLinkBase + rowIdx] = btnHit;

          g.roundFill(br, hot ? Palette.accent : Palette.surfaceAlt,
              hot ? Palette.accent : Palette.line, radius: Metrics.radiusSmall);
          g.text('打开', br, hot ? Palette.bg : Palette.accent,
              size: Metrics.detailFontAt(detailS), align: dtCenter, bold: hot);
          // 书名悬停时加一条下划线（"这是链接"的通用语汇）
          if (cells[2].contains(mouseX, mouseY)) {
            final tw = g.measure(
                e.titleObfuscated ? '${e.title}〔名待补〕' : e.title,
                size: Metrics.detailFontAt(detailS), bold: false);
            final pad = (10 * u * detailS).round();
            final maxW = cells[2].width - pad * 2;
            final uw = tw > maxW ? maxW : tw;
            g.fill(
                Rc.xywh(cells[2].left + pad, cells[2].bottom - (13 * u).round(),
                    uw, (2 * u).round().clamp(1, 3)),
                Palette.accent);
          }
        }
      } finally {
        endClip2();
      }
    }

    // ★ 两条滚动条都"叠在内容上"，所以右下角会**互相压住**：
    //   先画的纵向那条，尾巴被后画的横向那条盖掉一截 —— 拖到底时看着像断了一节。
    //   这里把两条各让出一格：纵向短一个横向条的高度，横向短一个纵向条的宽度。
    final barW = (11 * u).round();
    final vPresent = rows.isNotEmpty && contentH > viewH;
    final hPresent = maxX > 0;

    if (rows.isNotEmpty) {
      final vTrack = hPresent
          ? Rc.xywh(tableArea.left, tableArea.top, tableArea.width,
              tableArea.height - barW)
          : tableArea;
      drawScrollbar(g, vTrack,
          contentHeight: contentH,
          viewHeight: viewH,
          scrollY: detailScroll,
          hot: tableArea.contains(mouseX, mouseY));
    }

    // 横向滚动条（只在真的放不下时出现）—— 贴表格底边一条。
    if (hPresent) {
      final hb = Rc.xywh(tableArea.left, tableArea.bottom - barW,
          tableArea.width - (vPresent ? barW : 0), barW);
      detailHScroll = hb;
      hitRects[idDetailHScroll] = hb;
      drawHScrollbar(g, hb,
          contentWidth: naturalW,
          viewWidth: tableArea.width,
          scrollX: detailScrollX,
          hot: hb.contains(mouseX, mouseY));
    } else {
      detailHScroll = null;
    }
  }

  /// 封面仓库（懒加载 + 落盘缓存 + 系统解码）。
  ///
  /// ★ 为 null 表示"还没准备好"（没数据目录）—— 界面直接画占位卡，不报错。
  CoverStore? covers;
  Timer? _coverTimer;

  /// 起一个低频定时器驱动封面队列。
  ///
  /// ★ 为什么用定时器而不是"在绘制里 await"：绘制必须是同步的（GDI 那套
  ///   句柄生命周期不跨 await），所以只能"取图在后台、取到后重绘"。
  ///   定时器空闲时只做一次 `hasWork` 判断，代价可忽略。
  void _ensureCoverPump() {
    if (_coverTimer != null) return;
    _coverTimer = Timer.periodic(const Duration(milliseconds: 140), (t) async {
      final c = covers;
      if (c == null || !c.hasWork) {
        // ★ 队列空了就**把自己停掉**，不要挂着一个常驻定时器：
        //   ① 常驻定时器会让 Dart 进程永不退出（自检脚本跑完卡住不返回，
        //      第 17 轮就是这么发现 `_t_cover_link` 超时的）；
        //   ② 没事干的时候每 140ms 醒一次纯属浪费。
        //   新的一行滚进视口时，_paintCover 会重新把它拉起来。
        t.cancel();
        _coverTimer = null;
        return;
      }
      final changed = await c.pump();
      if (changed && !isDisposed) invalidate();
    });
  }

  /// 画一格封面：**真图**或**占位卡**，两者都是严格 3:4。
  ///
  /// ★ 占位卡不是"凑合"：没有封面地址的榜（晋江的表格页没有图）本来就没有图，
  ///   画一个"看起来像书封的卡片"比留一片空白更像成品；而且它保证了
  ///   **每一行的封面格宽度一致**，不会因为有没有图而让整张表左右跳动。
  void _paintCover(Gdi g, Rc cell, RankEntry e, String source, int rowIdx) {
    final w = Metrics.coverWidthAt(detailS);
    final h = Metrics.coverHeightAt(detailS);
    final r = Rc.xywh(cell.left + (cell.width - w) ~/ 2,
        cell.top + (cell.height - h) ~/ 2, w, h);
    // ★ 用 coverUrlFor 而不是 e.coverUrl：旧快照里没有 cover_url，
    //   但起点封面能从 bookId 推导出来 —— 不推导的话老数据永远是占位卡。
    final img = covers?.peek(source, e.bookId,
        coverUrlFor(source, e.bookId, e.coverUrl));
    // peek 可能刚把这一行排进队列 —— 定时器只在有活的时候存在
    if (covers?.hasWork == true) _ensureCoverPump();
    if (img != null) {
      g.bgra(r, img.bgra, img.width, img.height);
      g.stroke(r, Palette.line, width: 1);
      return;
    }
    // 占位卡：书名首字 + 由书名哈希决定的稳定底色（同一本书每次颜色都一样）
    final seed = e.title.isEmpty ? 0 : e.title.codeUnits.first + e.title.length;
    final hue = seed % 6;
    const fills = [
      (0x1f3a5f, 0x8ec7ff),
      (0x3a2450, 0xd7a9ff),
      (0x143b32, 0x8fe3c4),
      (0x4a2a1c, 0xffc09a),
      (0x2a2f45, 0xb9c4ff),
      (0x402030, 0xffa8c8),
    ];
    final (bg, fgc) = fills[hue];
    final back = rgb((bg >> 16) & 0xFF, (bg >> 8) & 0xFF, bg & 0xFF);
    final fore = rgb((fgc >> 16) & 0xFF, (fgc >> 8) & 0xFF, fgc & 0xFF);
    g.roundFill(r, back, Palette.line, radius: (3 * Metrics.factor).round());
    final ch = e.title.isEmpty ? '书' : e.title.substring(0, 1);
    g.text(ch, r, fore,
        size: Metrics.fontSize, align: dtCenter, bold: true);
    // 底部一条细线，让它读起来像"书的封底折线"而不是一个纯色块
    g.fill(Rc.xywh(r.left + 4, r.bottom - (5 * Metrics.factor).round(),
            r.width - 8, (1.5 * Metrics.factor).round().clamp(1, 2)),
        fore);
  }

  /// 自检：读菜单分组（不外传 _sectionsOf，避免测试脚本碰私有成员）。
  List<MenuSection> testMenuSections(String menu) => _sectionsOf(menu);

  /// 自检：分组里的第 (si, ii) 项对应的控件 id。
  int testMenuIdAt(String menu, int si, int ii) => _idAt(menu, si, ii);

  /// 自检：把封面队列排空（跳过限速）。
  ///
  /// ★ 离线渲染时没有事件循环，定时器不会跑 —— 不排空的话永远只画占位卡。
  Future<int> drainCoversForTest() async {
    final c = covers;
    if (c == null) return 0;
    var n = 0;
    while (c.hasWork && n < 500) {
      await c.pump(force: true);
      n++;
    }
    return n;
  }

  /// 每本书的链接（行下标 → URL）。点击时按 id 反查。
  ///
  /// ★ 用**行下标**做键而不是书名：书名会重名、会被字体混淆。
  final Map<int, String> detailLinks = {};

  /// 当前快照的条目数（链接命中区的遍历上界）。
  int detailLinkCount = 0;

  /// 明细表的**横向滚动**偏移。
  ///
  /// ★ 为什么必须有：明细表整表放大 1.5 倍之后，总宽（约 1140px）
  ///   超过了内容区可用宽（1240 窗口下约 951px）—— 不横向滚动的话，
  ///   最右边的「链接」列会被挤出屏幕，用户根本点不到"打开"。
  int detailScrollX = 0;

  /// 明细表的可见区域（点击时用它把命中限制在**看得见的地方**）。
  Rc? detailTableArea;

  /// 明细表的横向滚动条矩形（供命中）。
  Rc? detailHScroll;

  /// 明细表的**自然总宽**（绘制时写入；滚轮/点击要用它算上限）。
  int naturalWOfDetail = 0;

  /// 明细表这一帧**实际画了多宽**（= max(自然总宽, 可用宽)）。
  ///
  /// ★ 与 [naturalWOfDetail] 分开记：自然总宽是"内容需要多宽"，
  ///   实画宽是"这一帧真的铺开了多宽"。宽屏下后者更大（撑满可用区）。
  int detailDrawnW = 0;

  /// 明细表这一帧画到的右边界（客户区坐标）。
  int detailDrawnRight = 0;

  /// 明细表这一帧的**实际缩放**（自适应，见 [Metrics.detailScaleFor]）。
  ///
  /// ★ 行高 / 表头高 / 字号 / 封面 / 「打开」按钮**全部按它算** ——
  ///   只缩列宽不缩这些，版面会走形（一行里空一大块）。
  double detailS = Metrics.detailScale;

  /// 打开第 [rowIdx] 本书的详情页。
  ///
  /// ★ 第 19 轮修正：原来无论成没成都写"已打开详情页：…"。
  ///   `ShellExecuteW` 失败（没装默认浏览器 / 被策略拦 / 关联被劫持）时
  ///   用户看到的是"已打开"，然后去找那个根本没开的浏览器 ——
  ///   比直接说"失败"更糟。现在**如实报**，并把地址放进剪贴板兜底。
  void openBookLink(int rowIdx) {
    final url = detailLinks[rowIdx];
    if (url == null || url.isEmpty) {
      statusText = '这一行没有可打开的书链接（快照里没抓到 url）';
      invalidate();
      return;
    }
    if (openExternal(url)) {
      statusText = '已打开详情页：$url';
    } else {
      final copied = writeClipboardText(url);
      statusText = copied
          ? '打不开浏览器（系统拒绝了打开请求），地址已复制到剪贴板'
          : '打不开浏览器（系统拒绝了打开请求）：$url';
    }
    invalidate();
  }

  String _metricLegend(SnapshotMeta m) {
    final keys = <String>{};
    for (final e in m.result.entries) {
      keys.addAll(e.metrics.keys);
    }
    if (keys.isEmpty) return '无';
    // ★ 带上平台名 —— 否则同一份快照里可能出现别平台的标签。
    return keys.map((k) => metricLabelFor(k, source: m.source)).join('，');
  }

  // ── 标签页②：历史对比（跨时间段与自身对比）──
  //
  // ★ 这一页的语义已经改了：不再让用户"手挑两份快照"，
  //   而是把**同一张榜自己**的所有历史快照按时序排开。
  //   对比基准 = 它自己的过去，这才符合"看不同时间的变化"。

  /// 确保时间线已装配（选了别的榜 / 区间变了 / 数据变了才重算）。
  void _ensureSeries(SnapshotMeta m) {
    final key = '${m.seriesKey}|${seriesRange.name}';
    if (_seriesCacheKey == key && series != null) return;

    // 找同系列的全部快照（侧栏已经把所有快照的 RankResult 解析好了）。
    final sameMetas = vm!.all.where((x) => x.seriesKey == m.seriesKey).toList();
    if (sameMetas.isEmpty) sameMetas.add(m);

    // ★ 不需要再读磁盘：ViewModel.all 里的每份 SnapshotMeta 已经带着
    //   解析好的 RankResult。之前那版 `_loadResult` 是多余的 ——
    //   在"保留 365 期"的场合它会每次重绘都读 365 个文件。
    final allEntries = metasToEntries(sameMetas);
    final byId = <String, RankResult>{};
    for (final meta in sameMetas) {
      final e = metaToEntry(meta);
      byId[e.id] = meta.result;
      _resultCache[e.id] = meta.result;
    }

    // 按区间档位截取尾部，只把这几期喂给时间线。
    final sortedEntries = [...allEntries]
      ..sort((a, b) {
        final c = a.fetchedAt.compareTo(b.fetchedAt);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final selectedIds =
        seriesRange.apply(sortedEntries).map((e) => e.id).toSet();
    final selectedResults = <String, RankResult>{
      for (final e in byId.entries)
        if (selectedIds.contains(e.key)) e.key: e.value,
    };

    final errors = <String>[];
    series = buildSeriesView(
      allSeriesEntries: allEntries,
      results: selectedResults,
      range: seriesRange,
    );
    series!.errors.addAll(errors);
    _seriesCacheKey = key;
    seriesScroll = 0;
  }

  /// 数据变更后让时间线缓存失效。
  void _invalidateSeriesCache() {
    _seriesCacheKey = null;
    series = null;
  }

  void _paintDiff(Gdi g, Rc area, SnapshotMeta m) {
    final u = Metrics.factor;
    _ensureSeries(m);
    final sv = series;
    final ts = sv?.analysis;
    var y = area.top;

    // ── 顶部条：这张榜的"自身历史"信息 + 区间档位 ──
    final barH = (48 * u).round();
    final bar = Rc.xywh(area.left, y, area.width, barH);
    g.roundFill(bar, Palette.surface, Palette.line, radius: Metrics.radius);
    final padx = (18 * u).round();

    g.text('对比范围', Rc.xywh(bar.left + padx, bar.top, (76 * u).round(), barH),
        Palette.fgSub, size: Metrics.fontSizeSmall);

    // 区间药丸按钮组（近 7 期 / 近 30 期 / 全部）
    final chipH = (30 * u).round();
    var cx = bar.left + padx + (76 * u).round();
    final ranges = [TimeRange.last7, TimeRange.last30, TimeRange.all];
    final rangeIds = [idRangeLast7, idRangeLast30, idRangeAll];
    for (var i = 0; i < ranges.length; i++) {
      final label = ranges[i].label;
      final tw = g.measure(label, size: Metrics.fontSizeSmall) + (24 * u).round();
      final r = Rc.xywh(cx, bar.top + (barH - chipH) ~/ 2, tw, chipH);
      hitRects[rangeIds[i]] = r;
      final on = seriesRange == ranges[i];
      final hot = r.contains(mouseX, mouseY);
      g.roundFill(r,
          on ? Palette.selected : (hot ? Palette.hover : Palette.surfaceAlt),
          on ? Palette.selectedBorder : Palette.line,
          radius: Metrics.radiusSmall);
      g.text(label, r, on ? Palette.accent : Palette.fgSub,
          size: Metrics.fontSizeSmall, align: dtCenter, bold: on);
      cx += tw + (8 * u).round();
    }

    // ── 看图口径：排名 / 指标 / 字数 ──
    //
    // ★ 为什么放在这里而不是图里：它是**这一张图的口径**，
    //   和"对比范围"是同一层的东西（都在决定"画什么"）。
    void chip(String label, int id, bool on, {int labelW = 0}) {
      final tw = g.measure(label, size: Metrics.fontSizeSmall) +
          (20 * u).round();
      final r = Rc.xywh(cx, bar.top + (barH - chipH) ~/ 2, tw, chipH);
      hitRects[id] = r;
      final hot = r.contains(mouseX, mouseY);
      g.roundFill(r,
          on ? Palette.selected : (hot ? Palette.hover : Palette.surfaceAlt),
          on ? Palette.selectedBorder : Palette.line,
          radius: Metrics.radiusSmall);
      g.text(label, r, on ? Palette.accent : Palette.fgSub,
          size: Metrics.fontSizeSmall, align: dtCenter, bold: on);
      cx += tw + (6 * u).round();
    }

    cx += (10 * u).round();
    g.text('看图', Rc.xywh(cx, bar.top, (36 * u).round(), barH), Palette.fgSub,
        size: Metrics.fontSizeSmall);
    cx += (36 * u).round();
    chip('排名', idMetricRank, seriesBy == ChartMetric.rank);
    chip('指标', idMetricValue, seriesBy == ChartMetric.value);
    chip('字数', idMetricWords, seriesBy == ChartMetric.words);

    cx += (10 * u).round();
    g.text('条数', Rc.xywh(cx, bar.top, (36 * u).round(), barH), Palette.fgSub,
        size: Metrics.fontSizeSmall);
    cx += (36 * u).round();
    chip('6', idTop6, seriesTop == 6);
    chip('12', idTop12, seriesTop == 12);
    chip('全部', idTopAll, seriesTop == 0);

    // 右侧：系列名 + 期数摘要（如实说明被截断没）。
    // ★ 空间不够就**不画** —— 它只是说明文字，被切一半反而更糟。
    final seriesLabel = '${sourceName(m.source)} · ${m.board}'
        '${m.category == null ? '' : ' · ${m.category}'}';
    final totalP = sv?.totalPeriods ?? 0;
    final shownP = ts?.periodCount ?? 0;
    final rangeNote = totalP > shownP
        ? '共 $totalP 期 · 当前显示近 $shownP 期'
        : '共 $totalP 期';
    final labelLeft = cx + (12 * u).round();
    if (bar.right - padx - labelLeft > (150 * u).round()) {
      g.text('$seriesLabel   $rangeNote',
          Rc.xywh(labelLeft, bar.top, bar.right - padx - labelLeft, barH),
          Palette.fgDim,
          size: Metrics.fontSizeSmall, align: dtRight);
    }
    y += barH + (12 * u).round();

    if (ts == null || ts.periodCount == 0) {
      final boxH = (100 * u).round();
      final box = Rc.xywh(area.left, y, area.width, boxH);
      g.roundFill(box, Palette.surface, Palette.line, radius: Metrics.radius);
      g.text('这张榜还没有历史数据。',
          Rc.xywh(box.left + padx, box.top + (20 * u).round(),
              box.width - padx * 2, (24 * u).round()),
          Palette.fg, size: Metrics.fontSize);
      g.text('★ 每次扫榜都会按天存一份。多扫几天，这里就会出现'
          '「排名怎么变、数据怎么变」的时间线。',
          Rc.xywh(box.left + padx, box.top + (52 * u).round(),
              box.width - padx * 2, (24 * u).round()),
          Palette.fgDim, size: Metrics.fontSizeSmall);
      return;
    }

    if (!ts.hasComparison) {
      // 只有一期：可以看明细，但不能叫"趋势"。
      final boxH = (100 * u).round();
      final box = Rc.xywh(area.left, y, area.width, boxH);
      g.roundFill(box, Palette.surface, Palette.line, radius: Metrics.radius);
      g.text('这张榜目前只有 1 期数据（${ts.points.first.isoDate}），'
          '还构不成趋势对比。',
          Rc.xywh(box.left + padx, box.top + (20 * u).round(),
              box.width - padx * 2, (24 * u).round()),
          Palette.fg, size: Metrics.fontSize);
      g.text('下面照常显示这一期的名次与数据；再扫一次（换个日期）就能看到变化。',
          Rc.xywh(box.left + padx, box.top + (52 * u).round(),
              box.width - padx * 2, (24 * u).round()),
          Palette.fgDim, size: Metrics.fontSizeSmall);
      y += boxH + (12 * u).round();
    }

    final summary = SeriesSummary.of(ts);

    // ── 概览卡（8 张：两行）──
    // ★ 第一行是"变化"（最新期 vs 上期），第二行是"体量"（最新期 vs 首期）。
    //   两组数字含义不同，必须视觉分开，否则用户会把"总字数"当成"变化量"。
    // ★ 概览卡从 72 压到 66、行间距 12 压到 10：这两处一共省出 16px，
    //   正好够下面「解读栏」多显示一行 —— 而那一行就是一条"可能的原因"。
    //   概览卡只是数字+标签，压 6px 不影响可读性。
    final cardH = (66 * u).round();
    final gap = (10 * u).round();
    final cols = 4;
    final cw = (area.width - gap * (cols - 1)) ~/ cols;

    void cardRow(int row, List<(String, String, int)> items) {
      for (var i = 0; i < items.length; i++) {
        final r = Rc.xywh(area.left + i * (cw + gap), y, cw, cardH);
        g.roundFill(r, Palette.surface, Palette.line, radius: Metrics.radius);
        g.text(items[i].$1,
            Rc.xywh(r.left + padx, r.top + (8 * u).round(), cw - padx * 2,
                (34 * u).round()),
            items[i].$3, size: Metrics.fontSizeHuge, bold: true);
        g.text(items[i].$2,
            Rc.xywh(r.left + padx, r.top + (41 * u).round(), cw - padx * 2,
                (20 * u).round()),
            Palette.fgDim, size: Metrics.fontSizeSmall);
      }
      y += cardH + gap;
    }

    // 第一行：最新一期 vs 上一期的变化
    cardRow(0, [
      ('${summary.freshCount}', '新上榜', Palette.up),
      ('${summary.upCount}', '排名上升', Palette.up),
      ('${summary.downCount}', '排名下降', Palette.down),
      ('${summary.goneCount}', '已掉榜', Palette.down),
    ]);
    // 第二行：体量与常驻
    final wordsFirst = summary.totalWordsFirst;
    final wordsLast = summary.totalWordsLatest;
    final wordsDelta = (wordsFirst == null || wordsLast == null)
        ? null
        : wordsLast - wordsFirst;
    cardRow(1, [
      ('${summary.countLatest}',
          '本期上榜（首期 ${summary.countFirst}）', Palette.fg),
      (wordsLast == null ? '—' : wanText(wordsLast),
          wordsDelta == null ? '本期总字数' : '本期总字数（首发 ${signedWords(wordsDelta)}）',
          Palette.fg),
      ('${summary.evergreenCount}', '全期在榜', Palette.accent),
      ('${summary.periodCount}', '期数', Palette.fgSub),
    ]);

    // ── 变化提示（同系列 = 可信的时间趋势）──
    final hint = drawHint(
        g,
        area,
        y,
        '这些是同一张榜在不同日期的自身对比 —— 最新一期相对上一期。'
        '${ts.evergreens.isNotEmpty ? '其中 ${ts.evergreens.length} 本全期都在榜。' : ''}',
        Palette.accent);
    y = hint.bottom + (12 * u).round();

    // ── 趋势解读（事实 + 候选原因）──
    //
    // ★ 用户要的是"为什么变了"，不是只有数字。但原因不能随口给 ——
    //   所有解读都由 `trend_insight.dart` 的**规则**从可复算的数字推出来，
    //   并且**事实与候选原因视觉上分开**（事实=主色点、原因=警告色点 + 置信标签），
    //   底部常驻一句"原因均为候选解释，需人工核实"。
    final insight = buildTrendInsight(ts);
    final insightLines = insight.lines;

    // ── 排名趋势折线图 + 解读（同一张卡：左边看图，右边看"为什么"）──
    //
    // ★ 高度按剩余空间分配，但给一个下限：太矮的折线图读不出趋势。
    //   空间不够时的退化顺序是明确的：两列 → 叠放 → 只放解读 → 只放图 → 都不放
    //   （把空间全留给下面的明细表）。绝不把内容画到卡片外面。
    final remain = area.bottom - y;
    // ★ 给明细表留的高度必须 = 表格自己的下限(80) + 它与本卡之间的间距(12)，
    //   否则会出现"预算说够、表格却因不足 80 直接不画"的浪费：
    //   窄窗下就是这副样子 —— 解读栏吃满了空间，下面本该有的明细表整块消失。
    final tableFloor = (80 * u).round() + (12 * u).round();
    final budget = remain - tableFloor;
    final minChart = (170 * u).round();
    final maxChart = (250 * u).round();
    final legendH = (18 * u).round();
    final insightLineH = (18 * u).round();
    final insightPadH = (24 * u).round() + (8 * u).round();
    final insightFooterH = (17 * u).round();
    final minInsightH = insightPadH + 3 * insightLineH;
    // ★ 解读栏**要多少就给多少**（在预算内）：它是这张卡里唯一无法压缩的
    //   内容（折线图给多高都行，多一行解读却需要固定的 18px）。
    //   这里把卡片标题高度也算进去 —— 少算它就会出现"算出来放得下、
    //   实际少显示一行"的偏差。
    final wantInsightH = Metrics.cardTitleH +
        insightPadH +
        insightLines.length * insightLineH +
        insightFooterH;
    final wantChartH = (remain * 0.42).round().clamp(minChart, maxChart);
    final twoCol = area.width >= (780 * u).round();
    final chartSeries = pickChartSeries(ts,
        top: seriesTop == 0 ? 999 : seriesTop, by: seriesBy);

    var insightCardH = 0;
    var showChart = false;
    var showInsight = false;
    var stacked = false;

    if (twoCol) {
      insightCardH = wantChartH > wantInsightH ? wantChartH : wantInsightH;
      if (insightCardH > budget) insightCardH = budget;
      showChart = chartSeries.isNotEmpty && insightCardH >= minChart;
      showInsight = insightLines.isNotEmpty && insightCardH >= minInsightH;
      if (!showChart && !showInsight) insightCardH = 0;
    } else {
      final both = minChart + (10 * u).round() + wantInsightH;
      if (budget >= both) {
        stacked = true;
        showChart = chartSeries.isNotEmpty;
        showInsight = insightLines.isNotEmpty;
        insightCardH = both;
      } else if (budget >= minInsightH && insightLines.isNotEmpty) {
        // 空间只够一块：优先"为什么"，折线图让位（数字在下面的明细表里还有）
        showInsight = true;
        insightCardH = wantInsightH > budget ? budget : wantInsightH;
      } else if (budget >= minChart && chartSeries.isNotEmpty) {
        showChart = true;
        insightCardH = budget > maxChart ? maxChart : budget;
      }
    }

    if (insightCardH >= (72 * u).round() && (showChart || showInsight)) {
      final ccard = Rc.xywh(area.left, y, area.width, insightCardH);
      final metricName = switch (seriesBy) {
        ChartMetric.rank => '排名',
        ChartMetric.value => '指标',
        ChartMetric.words => '字数',
      };
      final content = drawCard(g, ccard,
          title: showChart ? '$metricName趋势与解读' : '趋势解读',
          badge: showChart
              ? (seriesBy == ChartMetric.rank
                  ? '取波动/名次最优的 ${chartSeries.length} 本'
                  : '取变化最大的 ${chartSeries.length} 本')
              : '${insight.periods} 期 · 全部书',
          badgeColor: Palette.fgDim);

      final dates = [for (final p in ts.points) p.shortDate];

      void paintChart(Rc r) {
        if (r.height < (90 * u).round()) return;
        drawLegend(
            g,
            Rc.xywh(r.left + (2 * u).round(), r.top, r.width - (4 * u).round(),
                legendH),
            chartSeries);
        final plot = Rc.xywh(
            r.left + (6 * u).round(),
            r.top + legendH + (2 * u).round(),
            r.width - (12 * u).round(),
            r.height - legendH - (4 * u).round());
        if (plot.height < (40 * u).round()) return;
        hitRects[idDiffTable] = plot;
        // ★ 名次走反向轴 + 固定量程（便于跨榜对齐）；指标/字数走正向轴。
        drawTrendChart(
          g,
          plot,
          dates: dates,
          series: chartSeries,
          mouseX: mouseX,
          mouseY: mouseY,
          axis: seriesBy == ChartMetric.rank
              ? ChartAxis.rank
              : ChartAxis.value,
          maxRank: seriesBy == ChartMetric.rank ? _niceRankCap(ts) : null,
        );
      }

      void paintInsight(Rc r) {
        if (r.height < (44 * u).round()) return;
        // 底部常驻一句边界说明 —— 它**不参与截断**，
        // 否则"哪些是猜的"这句最关键的提醒会随空间不足一起消失。
        final footerH = insightFooterH;
        final footer = insight.enough
            ? '▲ 原因均为候选解释（由数字按规则推出），需人工核实'
            : insight.caveat;
        final avail = r.height - insightPadH - footerH;

        // ★ 空间不够时**先保"原因"、再让"事实"**。
        //   上面四张概览卡 + 下面的逐期明细表已经把"变了多少"说得很全，
        //   解读栏的独特价值就在"为什么" —— 若按自然顺序从头截断，
        //   恰好会把用户最想要的那几行裁掉（第一版就是这么错的）。
        final factLines = [for (final l in insightLines) if (l.isFact) l];
        final hypLines = [for (final l in insightLines) if (!l.isFact) l];
        // 至少给事实留 1 行（否则只剩猜测、没有趋势，读者没有判断依据）
        final minFactLines = avail >= insightLineH * 2 ? 1 : 0;
        var hypShow = ((avail - minFactLines * insightLineH) / insightLineH)
            .floor()
            .clamp(0, hypLines.length);
        var factShow = ((avail - hypShow * insightLineH) / insightLineH)
            .floor()
            .clamp(0, factLines.length);
        // 事实还有富余就把空出来的行还给原因（两轮收敛，避免互相让位）
        hypShow = ((avail - factShow * insightLineH) / insightLineH)
            .floor()
            .clamp(0, hypLines.length);
        final shown = <InsightLine>[
          ...factLines.take(factShow),
          ...hypLines.take(hypShow),
        ];
        final hidden = insightLines.length - shown.length;

        final dot = (5 * u).round();
        final indent = dot + (8 * u).round();
        var iy = r.top + (2 * u).round();
        for (final ln in shown) {
          final col = ln.isFact ? Palette.accent : Palette.warn;
          g.fill(Rc.xywh(r.left, iy + insightLineH ~/ 2 - dot ~/ 2, dot, dot), col);
          var textRight = r.right;
          if (ln.tag != null) {
            final tagW =
                g.measure(ln.tag!, size: Metrics.fontSizeTiny) + (10 * u).round();
            g.text(ln.tag!, Rc.xywh(r.right - tagW, iy, tagW, insightLineH), col,
                size: Metrics.fontSizeTiny, align: dtRight);
            textRight = r.right - tagW - (6 * u).round();
          }
          g.text(ln.text,
              Rc.xywh(r.left + indent, iy, textRight - r.left - indent,
                  insightLineH),
              ln.isFact ? Palette.fgSub : Palette.fg,
              size: Metrics.fontSizeTiny, ellipsis: true);
          iy += insightLineH;
        }
        if (hidden > 0 && iy + insightLineH <= r.bottom - footerH) {
          g.text('…另有 $hidden 条（窗口拉大或导出后可看全）',
              Rc.xywh(r.left + indent, iy, r.width - indent, insightLineH),
              Palette.fgFaint, size: Metrics.fontSizeTiny, ellipsis: true);
        }
        g.text(footer, Rc.xywh(r.left, r.bottom - footerH, r.width, footerH),
            Palette.fgFaint, size: Metrics.fontSizeTiny, ellipsis: true);
      }

      if (stacked) {
        final chartH = minChart;
        paintChart(Rc.xywh(content.left, content.top, content.width, chartH));
        paintInsight(Rc.xywh(content.left, content.top + chartH + (10 * u).round(),
            content.width, content.height - chartH - (10 * u).round()));
      } else if (showChart && showInsight) {
        final colGap = (16 * u).round();
        final chartW = ((content.width - colGap) * 0.58).round();
        paintChart(Rc.xywh(content.left, content.top, chartW, content.height));
        paintInsight(Rc.xywh(content.left + chartW + colGap, content.top,
            content.width - chartW - colGap, content.height));
      } else if (showChart) {
        paintChart(content);
      } else {
        paintInsight(content);
      }
      y = ccard.bottom + (12 * u).round();
    }

    // ── 逐期明细表 ──
    final tableCard = Rc.xywh(area.left, y, area.width, area.bottom - y);
    if (tableCard.height < (80 * u).round()) return;

    final metricKey = dominantMetricKey(ts);
    final mLabel = metricLabel(metricKey);
    final content2 = drawCard(g, tableCard,
        title: '逐期名次与数据',
        badge: '${ts.rangeLabel} · $mLabel',
        badgeColor: Palette.fgDim);

    final tableArea = Rc.xywh(content2.left + 1, content2.top,
        content2.width - 2, content2.height - 1);

    // 列：书名 | 首期 | 上期 | 本期 | 排名变化 | 字数 | 字数变化 | 累计变化
    final tcols = <Column>[
      const Column(key: 'title', title: '书名', width: 220, stretch: true),
      const Column(key: 'first', title: '首期', width: 62, align: dtRight),
      const Column(key: 'prev', title: '上期', width: 62, align: dtRight),
      const Column(key: 'curr', title: '本期', width: 62, align: dtRight),
      const Column(key: 'chg', title: '较上期', width: 84, align: dtRight),
      const Column(key: 'total', title: '较首期', width: 84, align: dtRight),
      const Column(key: 'words', title: '字数', width: 88, align: dtRight),
      const Column(key: 'dw', title: '字数变化', width: 92, align: dtRight),
    ];

    final rows = <List<String>>[];
    final colors = <int>[];
    final cellCols = <List<int?>>[];

    for (final t in ts.tracks) {
      final label = t.obfuscated ? '${t.title}〔名待补〕' : t.label;
      final lastP = t.points.isEmpty ? null : t.points.last;
      final prevP =
          t.points.length < 2 ? null : t.points[t.points.length - 2];
      final firstListed = t.points.where((p) => p.rank > 0).toList();
      final firstP = firstListed.isEmpty ? null : firstListed.first;

      String rankText(TrackPoint? p) =>
          p == null ? '—' : (p.rank > 0 ? '#${p.rank}' : '掉榜');

      final chg = t.latestRankChange;
      final String chgText;
      final int chgColor;
      if (lastP != null && lastP.rank <= 0) {
        chgText = '掉榜';
        chgColor = Palette.down;
      } else if (prevP != null && prevP.rank <= 0 && lastP != null) {
        chgText = '新上';
        chgColor = Palette.up;
      } else if (chg == null) {
        chgText = '—';
        chgColor = Palette.flat;
      } else if (chg > 0) {
        chgText = '↑ +$chg';
        chgColor = Palette.up;
      } else if (chg < 0) {
        chgText = '↓ $chg';
        chgColor = Palette.down;
      } else {
        chgText = '→ 持平';
        chgColor = Palette.flat;
      }

      final sinceFirst = t.sinceFirstRankChange;
      final String totalText;
      final int totalColor;
      if (sinceFirst == null) {
        totalText = '—';
        totalColor = Palette.flat;
      } else if (sinceFirst > 0) {
        totalText = '↑ +$sinceFirst';
        totalColor = Palette.up;
      } else if (sinceFirst < 0) {
        totalText = '↓ $sinceFirst';
        totalColor = Palette.down;
      } else {
        totalText = '→ 持平';
        totalColor = Palette.flat;
      }

      final words = lastP?.words;
      final dw = t.latestWordsChange;

      rows.add([
        label,
        rankText(firstP),
        rankText(prevP),
        rankText(lastP),
        chgText,
        totalText,
        words == null ? '—' : wanText(words),
        dw == null ? '—' : signedWords(dw),
      ]);
      colors.add(t.obfuscated ? Palette.obfuscated : Palette.fg);
      cellCols.add([
        null,
        null,
        null,
        (lastP != null && lastP.rank <= 0) ? Palette.down : null,
        chgColor,
        totalColor,
        null,
        dw == null
            ? null
            : (dw > 0 ? Palette.up : (dw < 0 ? Palette.down : Palette.flat)),
      ]);
    }

    if (rows.isEmpty) {
      g.text('没有可显示的书目', tableArea, Palette.fgDim,
          size: Metrics.fontSizeSmall, align: dtCenter);
      return;
    }

    final contentH = tableContentHeight(rows.length);
    final viewH = tableArea.height - Metrics.headerRowHeight;
    seriesScroll =
        seriesScroll.clamp(0, (contentH - viewH) < 0 ? 0 : contentH - viewH);

    // ★ idDiffTable 已被折线图占用（悬停用），明细表用另一个 id 避免打架：
    //   折线图只在绘图区响应悬停，明细表负责滚轮。这里用 idDiffTable 的
    //   "兄弟" id —— 明细表滚轮区域。
    hitRects[idSeriesTable] = tableArea;
    drawTable(g, tableArea, tcols, rows,
        scrollY: seriesScroll,
        mouseX: mouseX,
        mouseY: mouseY,
        rowColors: colors,
        cellColors: cellCols);

    drawScrollbar(g, tableArea,
        contentHeight: contentH,
        viewHeight: viewH,
        scrollY: seriesScroll,
        hot: tableArea.contains(mouseX, mouseY));
  }

  /// y 轴上限：取所有绘制线里最差名次，向上取整到一个"整档"，
  /// 让折线图不至于因为一条 #200 的线把其他线压成一条平线。
  // y 轴量程统一走 chart.dart 的 [niceRankCap]（原来这里和 image_export
  // 各有一份、算法还不一样 → 屏幕上的图和导出的图 y 轴不一致）。
  int _niceRankCap(TimeSeriesAnalysis ts) => niceRankCap(ts);

  // ── 标签页③：跨榜分析 ──

  void _paintCross(Gdi g, Rc area) {
    final u = Metrics.factor;
    var y = area.top;

    // 平台选择：药丸按钮组
    final sources = vm!.bySource.keys.toList();
    if (sources.isEmpty) {
      g.text('还没有快照数据', Rc.xywh(area.left, y, area.width, (30 * u).round()),
          Palette.fgDim, size: Metrics.fontSize);
      return;
    }
    if (crossSource.isEmpty || !sources.contains(crossSource)) {
      // ★ 默认选**题材最细**的平台：晋江这种"整站只有一个言情"的，
      //   拿它当默认等于上来就给用户看一张只有一行的分布表。
      var bestSrc = sources.first;
      var bestN = -1;
      for (final s in sources) {
        final n = (vm!.bySource[s] ?? const <CategoryStat>[]).length;
        if (n > bestN) {
          bestN = n;
          bestSrc = s;
        }
      }
      crossSource = bestSrc;
    }

    final chipH = (32 * u).round();
    var x = area.left;
    for (var i = 0; i < sources.length; i++) {
      final s = sources[i];
      final label = sourceName(s);
      final tw = g.measure(label, size: Metrics.fontSize) + (32 * u).round();
      final r = Rc.xywh(x, y, tw, chipH);
      final id = idCrossChipBase + i;
      hitRects[id] = r;
      final on = s == crossSource;
      final hot = r.contains(mouseX, mouseY);
      g.roundFill(r,
          on ? Palette.accentSoft : (hot ? Palette.hover : Palette.surface),
          on ? Palette.accent : Palette.line, radius: chipH ~/ 2);
      g.text(label, r, on ? Palette.accent : Palette.fgSub,
          size: Metrics.fontSize, align: dtCenter, bold: on);
      x += tw + (8 * u).round();
    }
    y += chipH + (14 * u).round();

    final padx = (18 * u).round();

    // ══ 卡片①：各平台主流题材（**可对比**的那几样）══
    //
    // ★ 为什么不把各平台的题材并成一张对比图：**各平台的分类体系根本不同**
    //   （起点 玄幻/仙侠/都市，番茄 都市高武/架空历史，晋江 言情/纯爱…），
    //   名字对不齐，硬凑成一张"共同分类表"出来的结论是编的。
    //   所以这里比的是**真的可比的东西**：
    //     题材数、头部三题材占比（集中度）、以及"该平台自己的前三题材"。
    //   集中度才是"这个网站主流有多集中"的直接答案。
    // ★ 口径（题材数 / Top1 / Top3）**只在 PlatformCategoryProfile 里算一次** ——
    //   在绘制代码里各写一遍的话，两处算岔了界面上也看不出来。
    final profiles = buildPlatformProfiles(vm!.bySource);

    if (profiles.isNotEmpty) {
      final rowH = (30 * u).round();
      final headH = (22 * u).round();
      final noteH = (46 * u).round(); // 口径 + 结论，两行
      final cardH = Metrics.cardTitleH + headH + profiles.length * rowH +
          noteH + (10 * u).round();
      final c1 = Rc.xywh(area.left, y, area.width, cardH);
      final content = drawCard(g, c1,
          title: '各平台主流题材对比',
          badge: '各自分类体系 · 比的是集中度',
          badgeColor: Palette.fgDim);

      // 列宽 + **列间距**（没有间距时表头会挤成 "条数头部三题材占比"）
      final colGap = (14 * u).round();
      final wPlat = (84 * u).round();
      final wNum = (58 * u).round();
      final wBar = (110 * u).round();
      final wPct = (48 * u).round();
      final wMain = content.width -
          padx * 2 -
          wPlat -
          wNum * 2 -
          wBar -
          wPct -
          colGap * 4;
      var ry = content.top + (4 * u).round();

      void head(String t, int left, int w, {int align = dtLeft}) {
        g.text(t, Rc.xywh(left, ry, w, headH), Palette.fgFaint,
            size: Metrics.fontSizeTiny, align: align, bold: true);
      }

      var hx = content.left + padx;
      head('平台', hx, wPlat);
      hx += wPlat + colGap;
      head('题材', hx, wNum, align: dtRight);
      hx += wNum + colGap;
      head('条数', hx, wNum, align: dtRight);
      hx += wNum + colGap;
      head('集中度（前三题材占比）', hx, wBar + wPct + (6 * u).round());
      hx += wBar + wPct + colGap;
      head('主流题材（前 3，带各自占比）', hx, wMain);
      ry += headH;

      for (var pi = 0; pi < profiles.length; pi++) {
        final prof = profiles[pi];
        final src = prof.source;
        final on = src == crossSource;
        final rowR = Rc.xywh(content.left + (6 * u).round(), ry,
            content.width - (12 * u).round(), rowH);
        // 点行 = 切到那个平台（下面的「题材分布」跟着换）
        hitRects[idCrossRowBase + pi] = rowR;
        if (on) {
          g.roundFill(rowR, Palette.selected, Palette.selected,
              radius: Metrics.radiusSmall);
        } else if (rowR.contains(mouseX, mouseY)) {
          g.roundFill(rowR, Palette.rowHover, Palette.rowHover,
              radius: Metrics.radiusSmall);
        }
        var rx = content.left + padx;
        g.text(sourceName(src), Rc.xywh(rx, ry, wPlat, rowH),
            on ? Palette.accent : Palette.fg,
            size: Metrics.fontSizeSmall, bold: on, vcenter: true);
        rx += wPlat + colGap;
        g.text('${prof.categoryCount}', Rc.xywh(rx, ry, wNum, rowH),
            Palette.fgSub,
            size: Metrics.fontSizeTiny, align: dtRight, vcenter: true);
        rx += wNum + colGap;
        g.text('${prof.total}', Rc.xywh(rx, ry, wNum, rowH), Palette.fgSub,
            size: Metrics.fontSizeTiny, align: dtRight, vcenter: true);
        rx += wNum + colGap;
        // 集中度条：Top3 占比（**同一个量**，所以四个平台可以直接比长短）
        final barR = Rc.xywh(rx, ry + (rowH - (9 * u).round()) ~/ 2, wBar,
            (9 * u).round());
        g.roundFill(barR, Palette.surfaceHigh, Palette.surfaceHigh,
            radius: barR.height ~/ 2);
        final fill = (barR.width * prof.top3Share).round();
        if (fill > 2) {
          g.roundFill(Rc.xywh(barR.left, barR.top, fill, barR.height),
              on ? Palette.accent : Palette.fgSub,
              on ? Palette.accent : Palette.fgSub,
              radius: barR.height ~/ 2);
        }
        rx += wBar + (6 * u).round();
        g.text('${(prof.top3Share * 100).toStringAsFixed(0)}%',
            Rc.xywh(rx, ry, wPct, rowH), Palette.fg,
            size: Metrics.fontSizeTiny, vcenter: true);
        rx += wPct + colGap;
        var top3txt = prof.topSummary();
        // ★ 只有一个题材 → 集中度必然 100%，那不是"集中"，是"没细分"。
        //   不标出来会被读成"这个平台极度集中"。
        if (prof.coarse) top3txt = '$top3txt（该平台未细分题材）';
        g.text(ellipsize(g, top3txt, wMain, size: Metrics.fontSizeTiny),
            Rc.xywh(rx, ry, wMain, rowH),
            on ? Palette.fg : Palette.fgSub,
            size: Metrics.fontSizeTiny, vcenter: true);
        ry += rowH;
      }

      // 口径 + 结论（**必须写**：不写"条数"会被当成"本数"）
      final mostT3 = profiles.reduce(
          (a, b) => a.top3Share >= b.top3Share ? a : b);
      final leastT3 = profiles.reduce(
          (a, b) => a.top3Share <= b.top3Share ? a : b);
      final mostT1 = profiles.reduce((a, b) => a.top1Share >= b.top1Share ? a : b);
      final nw = content.width - padx * 2;
      g.text('口径：全部快照里的**上榜条目**累计（同一本书多期上榜会重复计入）；'
          '各平台分类体系不同，名字不能直接对齐 —— 所以这里比的是集中度。',
          Rc.xywh(content.left + padx, ry + (2 * u).round(), nw,
              (20 * u).round()),
          Palette.fgDim,
          size: Metrics.fontSizeTiny);
      g.text('最集中：${sourceName(mostT3.source)}'
          '（前三 ${(mostT3.top3Share * 100).toStringAsFixed(0)}%）'
          ' · 最分散：${sourceName(leastT3.source)}'
          '（前三 ${(leastT3.top3Share * 100).toStringAsFixed(0)}%）'
          ' · 头部单题材最重：${sourceName(mostT1.source)}'
          '（${mostT1.sorted.first.category} ${(mostT1.top1Share * 100).toStringAsFixed(0)}%）',
          Rc.xywh(content.left + padx, ry + (22 * u).round(), nw,
              (20 * u).round()),
          Palette.fgSub,
          size: Metrics.fontSizeTiny);
      y = c1.bottom + (14 * u).round();
    }

    // ══ 剩下两块按可用高度分配 ══
    // 高度预算：**先给「题材分布」保底**（它是细节，但也是用户点进来的目的），
    // 剩下的才给「跨榜信号」——后者只是"顺带一提"。
    final rest = area.bottom - y;
    final gap = (14 * u).round();
    if (rest < (150 * u).round()) return;
    // 「跨榜信号」现在**自己能滚**，所以只要给它一块"看得见两行"的高度就够，
    // 剩下的全给「题材分布」（那才是这一页的主体）。
    var c3H = (rest * 0.30).round().clamp((140 * u).round(), (190 * u).round());
    var c2H = rest - (c3H > 0 ? c3H + gap : 0);
    if (c2H < (150 * u).round()) {
      // 连"题材分布"都摆不下 → 放弃跨榜信号，把高度全给它
      c3H = 0;
      c2H = rest;
    }

    final stats = vm!.bySource[crossSource] ?? const <CategoryStat>[];
    if (stats.isEmpty) {
      g.text('这个平台没有题材信息',
          Rc.xywh(area.left, y, area.width, (30 * u).round()), Palette.fgDim,
          size: Metrics.fontSize);
      return;
    }

    // ── 卡片②：该平台的题材分布（完整列表）──
    final perRow = (28 * u).round();
    final distCard = Rc.xywh(area.left, y, area.width, c2H);
    drawCard(g, distCard,
        title: '题材分布',
        badge: '${sourceName(crossSource)} 自己的分类体系',
        badgeColor: Palette.fgDim);

    var ry2 = distCard.top + Metrics.cardTitleH + (8 * u).round();
    final total = stats.fold<int>(0, (a, b) => a + b.count);
    final labelW = (150 * u).round();
    final rightW = (170 * u).round();
    final barW = distCard.width - padx * 2 - labelW - (16 * u).round() - rightW;
    final barH = (10 * u).round();
    // 能放几行就放几行（空间被上面那张对比卡吃掉之后，这里要自适应）
    final room = distCard.bottom - ry2 - (24 * u).round();
    final fit = (room / perRow).floor().clamp(0, stats.length);
    final shown = fit < stats.length ? (fit > 1 ? fit - 1 : fit) : fit;
    for (var i = 0; i < shown; i++) {
      final c = stats[i];
      g.text(c.category,
          Rc.xywh(distCard.left + padx, ry2, labelW, perRow), Palette.fg,
          size: Metrics.fontSizeSmall, vcenter: true);
      final pct = total == 0 ? 0.0 : c.count / total;
      final fillW = (barW * pct).round();
      final barR = Rc.xywh(distCard.left + padx + labelW,
          ry2 + (perRow - barH) ~/ 2, barW, barH);
      g.roundFill(barR, Palette.surfaceAlt, Palette.surfaceAlt,
          radius: barH ~/ 2);
      if (fillW > 2) {
        g.roundFill(Rc.xywh(barR.left, barR.top, fillW, barH), Palette.accent,
            Palette.accent, radius: barH ~/ 2);
      }
      final rx = barR.right + (14 * u).round();
      g.text('${c.count} 条 · ${(pct * 100).toStringAsFixed(1)}%',
          Rc.xywh(rx, ry2, rightW, perRow), Palette.fgSub,
          size: Metrics.fontSizeTiny, vcenter: true);
      g.text('#${c.bestRank} 最好', Rc.xywh(rx, ry2, rightW, perRow),
          Palette.fgFaint, size: Metrics.fontSizeTiny, align: dtRight,
          vcenter: true);
      ry2 += perRow;
    }
    if (shown < stats.length) {
      g.text('…… 另有 ${stats.length - shown} 个题材（导出 JSON 可看全部）',
          Rc.xywh(distCard.left + padx, ry2, distCard.width - padx * 2,
              (22 * u).round()),
          Palette.fgDim, size: Metrics.fontSizeTiny);
    }
    y = distCard.bottom + (14 * u).round();

    // ── 卡片③：跨榜信号 ──
    if (c3H <= 0) return;
    final cross = vm!.crossBoardBooks();
    final ccard = Rc.xywh(area.left, y, area.width, c3H);
    if (ccard.height < (110 * u).round()) return;
    final content3 = drawCard(g, ccard,
        title: '同时出现在多个榜的书',
        badge: '跨榜信号 · 记越多榜越可能是真在被推着走',
        badgeColor: Palette.accent);

    if (cross.isEmpty) {
      g.text('本轮没有书同时出现在多个榜上。',
          Rc.xywh(content3.left + padx, content3.top + (34 * u).round(),
              (420 * u).round(), (24 * u).round()),
          Palette.fgSub, size: Metrics.fontSizeSmall);
      return;
    }

    final cols = <Column>[
      const Column(key: 't', title: '书名', width: 260, stretch: true),
      const Column(key: 'n', title: '榜数', width: 60, align: dtRight),
      const Column(key: 'w', title: '出现在哪些榜', width: 480),
    ];
    final topOfTable = content3.top + (6 * u).round();
    final tableArea = Rc.xywh(content3.left + 1, topOfTable, content3.width - 2,
        content3.bottom - topOfTable);
    hitRects[idCrossTable] = tableArea;
    final rows = <List<String>>[];
    final colors = <int>[];
    for (final b in cross.take(30)) {
      rows.add([
        b.obfuscated ? '${b.title}〔名待补〕' : b.title,
        '${b.boards.toSet().length}',
        b.boards.toSet().join('；'),
      ]);
      colors.add(b.obfuscated ? Palette.obfuscated : Palette.fg);
    }
    final contentH = tableContentHeight(rows.length);
    final viewH = tableArea.height - Metrics.headerRowHeight;
    crossScroll = crossScroll.clamp(0, (contentH - viewH) < 0 ? 0 : contentH - viewH);
    drawTable(g, tableArea, cols, rows,
        scrollY: crossScroll, mouseX: mouseX, mouseY: mouseY,
        rowColors: colors);
    if (contentH > viewH) {
      drawScrollbar(g, tableArea,
          contentHeight: contentH,
          viewHeight: viewH,
          scrollY: crossScroll,
          hot: tableArea.contains(mouseX, mouseY));
    }
  }

  // ── 状态栏 ──

  void _paintStatus(Gdi g) {
    final u = Metrics.factor;
    final top = height - Metrics.statusHeight;
    g.fill(Rc.xywh(0, top, width, Metrics.statusHeight), Palette.surfaceAlt);
    g.line(0, top, width, top, Palette.line);

    var left = (16 * u).round();
    if (phase == ScanPhase.running) {
      // 转圈动画（几根长度渐变的线，无需真圆弧）
      _spin += 0.28;
      final rad = (7 * u).round();
      final cx = left + rad, cy = top + Metrics.statusHeight ~/ 2;
      for (var i = 0; i < 8; i++) {
        final a = _spin + i * 0.785;
        final alpha = i / 8.0;
        final col = blend(Palette.accent, Palette.surfaceAlt, alpha);
        final x1 = (cx + rad * 0.6 * _cos(a)).round();
        final y1 = (cy + rad * 0.6 * _sin(a)).round();
        final x2 = (cx + rad * _cos(a)).round();
        final y2 = (cy + rad * _sin(a)).round();
        g.line(x1, y1, x2, y2, col, width: (2 * u).round().clamp(1, 3));
      }
      left += rad * 2 + (8 * u).round();
    }

    g.text(statusText,
        Rc.xywh(left, top, width - (340 * u).round(), Metrics.statusHeight),
        phase == ScanPhase.running ? Palette.accent : Palette.fgSub,
        size: Metrics.fontSizeTiny);

    if (lastMessage != null) {
      g.text(lastMessage!,
          Rc.xywh(width - (460 * u).round(), top, (440 * u).round(),
              Metrics.statusHeight),
          Palette.fgFaint, size: Metrics.fontSizeTiny, align: dtRight);
    }
  }

  static double _cos(double a) => _taylorCos(a);
  static double _sin(double a) => _taylorCos(a - 1.5707963267948966);

  /// 不引 dart:math 的三角函数太浪费 —— 这里只要个近似圈，
  /// 用几项泰勒展开足够（视觉上看不出差别）。
  static double _taylorCos(double x) {
    // 归一到 [-pi, pi]
    const pi = 3.1415926535897932;
    while (x > pi) {
      x -= 2 * pi;
    }
    while (x < -pi) {
      x += 2 * pi;
    }
    final x2 = x * x;
    return 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720;
  }

  void _paintScanOverlay(Gdi g) {
    final u = Metrics.factor;
    final o = Rc.xywh(Metrics.sidebarWidth + (16 * u).round(),
        Metrics.headerHeight + (12 * u).round(), (250 * u).round(),
        (44 * u).round());
    g.roundFill(o, Palette.accentSoft, Palette.accent, radius: Metrics.radiusSmall);
    g.text('扫榜进行中 ${scanDone}/${scanTotal}',
        Rc.xywh(o.left + (14 * u).round(), o.top, o.width - (28 * u).round(),
            o.height),
        Palette.accent, size: Metrics.fontSize, bold: true);
  }

  // ── 交互 ──

  SnapshotMeta? currentMeta() => _metaById(selectedId);

  SnapshotMeta? _metaById(int id) {
    if (id == 0 || vm == null) return null;
    for (final m in vm!.all) {
      if (m.id == id) return m;
    }
    return null;
  }

  @override
  bool onClick(int x, int y) {
    // ★ 自绘窗口按钮**必须最先判**。
    //   它们在右上角，和顶栏按钮、下拉浮层的命中区可能有重叠（缩放后
    //   顶栏按钮排到最右侧时），而且它们的行为（关窗）比其它任何操作
    //   都"重"，被判掉了用户会觉得程序失控。
    for (final id in const [idWinMinimize, idWinMaximize, idWinClose]) {
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) {
        // ★ 对话框类按钮不能"按下即触发"吗？可以 —— 这里就是按下即触发，
        //   和 Windows 原生窗口按钮一致（用户不需要抬起）。
        //   按下态只用于这一次绘制的视觉反馈：先把 down 记上、重绘一帧，
        //   动作本身在重绘后立刻发生，避免"看起来卡在按下态"。
        switch (id) {
          case idWinMinimize:
            minimizeWindow();
          case idWinMaximize:
            toggleMaximize();
          case idWinClose:
            // ★ 走 WM_CLOSE 而不是 destroyWindow：
            //   扫榜进行中时 [onClosing] 要弹确认框，直接销毁就绕过它了。
            requestClose();
        }
        return true;
      }
    }

    // 标签页
    for (var i = 0; i < 3; i++) {
      final r = hitRects[idTabBase + i];
      if (r != null && r.contains(x, y)) {
        if (curTab != i) {
          final from = curTab;
          curTab = i;
          _startTabAnim(from); // 轻微滑入过渡，让切换"有分量"
        }
        invalidate();
        return true;
      }
    }

    // 历史对比的区间档位（近 7 期 / 近 30 期 / 全部）
    for (final entry in const [
      (idRangeLast7, TimeRange.last7),
      (idRangeLast30, TimeRange.last30),
      (idRangeAll, TimeRange.all),
    ]) {
      if (_hit(entry.$1, x, y)) {
        if (seriesRange != entry.$2) {
          seriesRange = entry.$2;
          _invalidateSeriesCache();
          invalidate();
        }
        return true;
      }
    }

    // 折线口径：排名 / 指标 / 字数（**不需要**重算时间线，只是换个量来画）
    for (final entry in const [
      (idMetricRank, ChartMetric.rank),
      (idMetricValue, ChartMetric.value),
      (idMetricWords, ChartMetric.words),
    ]) {
      if (_hit(entry.$1, x, y)) {
        if (seriesBy != entry.$2) {
          seriesBy = entry.$2;
          invalidate();
        }
        return true;
      }
    }
    // 折线画几条（0 = 全部）
    for (final entry in const [(idTop6, 6), (idTop12, 12), (idTopAll, 0)]) {
      if (_hit(entry.$1, x, y)) {
        if (seriesTop != entry.$2) {
          seriesTop = entry.$2;
          invalidate();
        }
        return true;
      }
    }

    // ── 侧栏 ──
    //
    // ★ 判定顺序：**隐藏小按钮 → 分组头 → 行本身**。
    //   隐藏按钮嵌在行矩形**内部**，先判行的话永远点不到它
    //   （这类"子控件在父控件内部"的顺序错误，在第 6 轮删单榜步进器时
    //   踩过一次：点本数会把榜取消勾选）。
    for (var i = 0; i < sideItemCount; i++) {
      final hid = sidebarHideIdBase + i;
      if (_hit(hid, x, y)) {
        hideSidebarMeta(listIndexBase[hid]);
        return true;
      }
    }
    for (var gi = 0; gi < sideGroupCount; gi++) {
      if (_hit(sidebarGroupIdBase + gi, x, y)) {
        toggleSidebarGroup(gi);
        return true;
      }
    }
    if (_hit(idSidebarManage, x, y)) {
      openDataManager();
      return true;
    }
    for (var i = 0; i < sideItemCount; i++) {
      final id = sidebarIdBase + i;
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) {
        final metaId = listIndexBase[id];
        if (metaId != null) {
          selectedId = metaId;
          detailScroll = 0;
          seriesScroll = 0;
          // ★ 换了榜就要重新装配时间线（是另一张榜的历史了）。
          _invalidateSeriesCache();
          invalidate();
        }
        return true;
      }
    }

    // ★ 菜单判定**必须在 chip 之前**：菜单是浮层，它盖在内容之上，
    //   点在菜单上的坐标同时也落在它下面的 chip 矩形里 ——
    //   先判 chip 就等于"看到的上层点不到"。
    if (openMenu.isNotEmpty && _handleMenuClick(x, y)) return true;

    // 跨榜平台切换
    final sources = vm?.bySource.keys.toList() ?? const <String>[];
    for (var i = 0; i < sources.length; i++) {
      final r = hitRects[idCrossChipBase + i];
      if (r != null && r.contains(x, y)) {
        crossSource = sources[i];
        crossScroll = 0;
        invalidate();
        return true;
      }
    }
    // 「各平台主流题材对比」表：点行 = 切到那个平台
    final profiles = buildPlatformProfiles(vm?.bySource ?? const {});
    for (var i = 0; i < profiles.length; i++) {
      final r = hitRects[idCrossRowBase + i];
      if (r != null && r.contains(x, y)) {
        if (crossSource != profiles[i].source) {
          crossSource = profiles[i].source;
          crossScroll = 0;
          invalidate();
        }
        return true;
      }
    }

    // 明细表横向滚动条：点滑块两侧 = 翻一页
    final hb = detailHScroll;
    if (hb != null && hb.contains(x, y)) {
      final area = detailTableArea;
      if (area != null) {
        final page = (area.width * 0.8).round();
        _scrollDetailX(x < area.left + area.width ~/ 2 ? -page : page);
      }
      return true;
    }

    // ★ 每本书的链接：**必须排在表格/行判定之前**（它嵌在表格行里）。
    //   命中区由 _paintDetail 按行登记，行数取决于当前快照。
    //   判定顺序：整行 → 书名格 → 「打开」按钮 —— 三个都指向同一本书，
    //   谁先命中都一样，但**整行在最前**才不会被别的判定抢走。
    for (var i = 0; i < detailLinkCount; i++) {
      if (_hit(idBookRowLinkBase + i, x, y) ||
          _hit(idBookTitleLinkBase + i, x, y) ||
          _hit(idBookLinkBase + i, x, y)) {
        openBookLink(i);
        return true;
      }
    }

    // 顶部按钮
    if (_hit(idScanButton, x, y)) {
      // ★ 按钮画成灰的"正在扫榜…"时必须**真的点不动**。
      //   原来只把 enabled 交给 drawButton 看，点击照样开设置窗 ——
      //   而设置窗的「开始扫榜」也不判 phase，于是能并行开第二次扫描
      //   （ScanService 自己写着"两个实例 = 限速翻倍"）。
      if (phase == ScanPhase.running) {
        statusText = '正在扫榜，等这一轮结束再改设置';
        invalidate();
        return true;
      }
      openScanDialog();
      return true;
    }
    if (_hit(idReloadButton, x, y)) {
      reload();
      return true;
    }
    if (_hit(idManageButton, x, y)) {
      openDataManager();
      return true;
    }
    if (_hit(idThemeButton, x, y)) {
      toggleTheme();
      return true;
    }
    if (_hit(idExportButton, x, y)) {
      openMenu = openMenu == 'export' ? '' : 'export'; // 再点一次收起
      invalidate();
      return true;
    }
    if (_hit(idImportButton, x, y)) {
      openMenu = openMenu == 'import' ? '' : 'import';
      invalidate();
      return true;
    }
    if (_hit(idOpenSource, x, y)) {
      final m = currentMeta();
      final url = m?.result.sourceUrl;
      if (url != null) openExternal(url);
      return true;
    }
    return false;
  }

  bool _hit(int id, int x, int y) {
    final r = hitRects[id];
    return r != null && r.contains(x, y);
  }

  /// 明细表横向偏移的唯一入口（滚轮 / 横向滚轮 / 拖滚动条都走它）。
  ///
  /// ★ 三个入口各算一遍 `maxX` 很容易算岔 —— 这里只留一份。
  bool _scrollDetailX(int dx) {
    final area = detailTableArea;
    if (area == null) return false;
    final maxX = (naturalWOfDetail - area.width) < 0
        ? 0
        : naturalWOfDetail - area.width;
    if (maxX <= 0) return false;
    final next = (detailScrollX + dx).clamp(0, maxX);
    if (next == detailScrollX) return false;
    detailScrollX = next;
    invalidate();
    return true;
  }

  @override
  void onHWheel(int x, int y, int delta) {
    // 横向滚轮：指针在明细表上（含滚动条）才处理，正 = 往右。
    final detail = hitRects[idDetailTable];
    if (detail != null && detail.contains(x, y)) {
      _scrollDetailX(delta * (48 * Metrics.factor).round());
    }
  }

  @override
  void onWheel(int x, int y, int delta) {
    final step = delta > 0 ? -Metrics.rowHeight * 3 : Metrics.rowHeight * 3;

    // ★ 指针落在**横向滚动条**那一条上时，滚轮改成横向滚。
    //   自绘 UI 里没有修饰键信息（onWheel 拿不到 Shift），
    //   所以用"指针在滚动条上"这个空间条件来区分，不需要按键。
    final hb = detailHScroll;
    if (hb != null && hb.contains(x, y)) {
      _scrollDetailX(-delta * (48 * Metrics.factor).round());
      return;
    }
    final detail = hitRects[idDetailTable];
    if (detail != null && detail.contains(x, y)) {
      detailScroll = (detailScroll + step).clamp(0, _maxScroll(detail, idDetailTable));
      invalidate();
      return;
    }
    // 历史对比：折线图区不滚，明细表区滚
    final seriesT = hitRects[idSeriesTable];
    if (seriesT != null && seriesT.contains(x, y)) {
      seriesScroll =
          (seriesScroll + step).clamp(0, _maxScroll(seriesT, idSeriesTable));
      invalidate();
      return;
    }
    // 跨榜信号表滚动
    final crossT = hitRects[idCrossTable];
    if (crossT != null && crossT.contains(x, y)) {
      crossScroll =
          (crossScroll + step).clamp(0, _maxScroll(crossT, idCrossTable));
      invalidate();
      return;
    }
    // 侧栏滚动
    if (x < Metrics.sidebarWidth && y > Metrics.headerHeight) {
      final maxV = sidebarContentH - (height - Metrics.headerHeight - Metrics.statusHeight);
      sidebarScroll = (sidebarScroll + step).clamp(0, maxV < 0 ? 0 : maxV);
      invalidate();
      return;
    }
  }

  int _maxScroll(Rc area, int id) {
    final m = currentMeta();
    if (m == null) return 0;
    final int n;
    if (id == idDetailTable) {
      n = m.result.entries.length;
    } else if (id == idSeriesTable) {
      n = series?.analysis.tracks.length ?? 0;
    } else if (id == idCrossTable) {
      n = vm?.crossBoardBooks().length ?? 0;
    } else {
      n = 0;
    }
    // ★ 明细表的行高与**表头高**都是放大过的一档，这里必须与绘制用同一组，
    //   否则滚轮的"到底"比绘制的"到底"短一截 —— 最后一行永远滚不全
    //   （差的是两倍表头高之差：2 × (69 − 46) = 46px，正好半行）。
    final isDetail = id == idDetailTable;
    final contentH = tableContentHeight(n,
        rowHeight: isDetail ? Metrics.detailRowHeightAt(detailS) : null,
        headerRowHeight: isDetail ? Metrics.detailHeaderHeightAt(detailS) : null);
    final viewH = area.height -
        (isDetail ? Metrics.detailHeaderHeightAt(detailS) : Metrics.headerRowHeight);
    final maxV = contentH - viewH;
    return maxV < 0 ? 0 : maxV;
  }

  @override
  void onMove(int x, int y) {
    // ★ 不要无条件 invalidate()。
    //
    //   这是本轮性能优化的**主要热点**：鼠标每移动 1px 就触发一次
    //   整窗重绘 —— 而重绘一次要重建整个表格（几十行 × 十几列的
    //   DrawTextW），在 30 万条记录的榜单上就是十几毫秒。
    //   结果鼠标一划窗口就掉帧，看起来"卡"。
    //
    //   实际上绝大多数移动**不需要重绘**：只有两种情况需要 ——
    //    ① 进了/出了一个按钮或行（hotId 变了）→ hover 高亮要换；
    //    ② 在自绘窗口按钮上移动（右上角那三个）→ 也要换高亮。
    //   其余情况直接跳过，省掉整帧开销。
    final newHot = _hitTestHot(x, y);
    final newWinBtn = _hitTestWinBtn(x, y);
    if (newHot == hotId && newWinBtn == _winBtnHot) return;
    hotId = newHot;
    _winBtnHot = newWinBtn;
    invalidate();
  }

  /// 当前鼠标落在哪个**业务控件**上（hitRects 里的 id，没有则 -1）。
  ///
  /// 只做按钮级判断，不做整表逐行 —— 逐行判断的开销和重绘差不多，
  /// 那就失去优化意义了。
  ///
  /// ★ 但**"整张表"这类容器必须排最后**：`idDetailTable` 覆盖整个表格区域，
  ///   而它是最先登记的，`hitRects` 又是按插入顺序遍历 ——
  ///   先命中它就等于"鼠标在表内怎么移动都返回同一个 id"，
  ///   `onMove` 判定"没变"直接 return，于是行 hover、「打开」按钮的
  ///   hover 高亮**永远不会更新**（看着像"点了没反应"的一部分成因）。
  int _hitTestHot(int x, int y) {
    int? container;
    for (final e in hitRects.entries) {
      if (!e.value.contains(x, y)) continue;
      if (_isContainerId(e.key)) {
        container ??= e.key;
        continue;
      }
      return e.key;
    }
    return container ?? -1;
  }

  /// 只是"一块区域"、不是具体控件的 id（hover 判定里优先度最低）。
  static bool _isContainerId(int id) =>
      id == idDetailTable ||
      id == idDiffTable ||
      id == idCrossTable ||
      id == idSeriesTable;

  /// 当前鼠标落在哪个窗口按钮上（-1 = 无）。
  int _hitTestWinBtn(int x, int y) {
    for (final id in const [idWinMinimize, idWinMaximize, idWinClose]) {
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) return id;
    }
    return -1;
  }

  // ── 主题 ──

  /// 深色 ↔ 浅色。切换后要**三件事**同时做，少一件都会留下不一致：
  ///   ① 换 `Palette` 的色值；② 重刷窗口非客户区（描边/标题栏）；③ 整窗重绘。
  void toggleTheme() {
    final next = Palette.theme.toggled;
    Palette.apply(next);
    settings.theme = next;
    saveSettings();
    // 子窗口（设置窗 / 数据管理窗）也要跟着换 —— 它们画的是同一套 Palette，
    // 但**必须被显式重绘**，否则会一直停在旧主题的像素上。
    App.instance?.refreshTheme();
    statusText = '已切换到${next.label}主题';
    invalidate();
  }

  // ── 侧栏：折叠与隐藏 ──

  /// 折叠/展开第 [gi] 个平台分组。
  void toggleSidebarGroup(int gi) {
    if (vm == null || gi < 0 || gi >= vm!.groups.length) return;
    final id = vm!.groups[gi].sourceId;
    if (!settings.collapsedSources.remove(id)) settings.collapsedSources.add(id);
    saveSettings();
    invalidate();
  }

  /// 隐藏侧栏第 [i] 行对应的**系列**（不是单份快照）。
  ///
  /// ★ 为什么按系列而不是按份：用户的心智是"这张榜我不想在左边看到"，
  ///   而不是"我想藏掉 9 月 24 号那一份"。按份隐藏会让侧栏变成
  ///   一堆同名的残片，且时间线会出现"期数对不上"的假象。
  /// 按**稳定 id** 隐藏一份快照所属的系列。
  ///
  /// ★ 用 id 而不是下标：侧栏滚动后"第 i 行"是什么取决于滚动量，
  ///   而下标在绘制/点击两处的口径已经错过一次（见上面 hideRects 的注释）。
  void hideSidebarMeta(int? metaId) {
    if (metaId == null) return;
    SnapshotMeta? m;
    for (final x in vm?.all ?? const <SnapshotMeta>[]) {
      if (x.id == metaId) {
        m = x;
        break;
      }
    }
    if (m == null) return;
    if (!settings.hideSeries(m.seriesKey)) return;
    saveSettings();
    // 被隐藏的正好是当前选中项 → 换到第一份可见的，别让右侧停在"看不见的榜"上
    if (selectedId == m.id) {
      reload();
    } else {
      vm = ViewModel.load(outRoot,
          errors: loadErrors, hidden: settings.hiddenSeries);
      invalidate();
    }
    statusText = '已隐藏「${m.board}${m.category == null ? '' : ' · ${m.category}'}」';
    lastMessage = '数据仍在磁盘上，可在侧栏底部「管理」里恢复显示';
    invalidate();
  }

  /// 恢复某个系列的显示。
  void unhideSeries(String seriesKey) {
    if (!settings.unhideSeries(seriesKey)) return;
    saveSettings();
    reload();
    statusText = '已恢复显示';
    invalidate();
  }

  // ── 数据管理窗 ──

  /// 打开中的数据管理窗（避免重复打开）。
  DataManagerWindow? dataManager;

  void openDataManager() {
    if (vm == null) reload();
    if (dataManager != null && !dataManager!.isDisposed) {
      // 已经开着 → 把它带到前面（重新 setFocus 即可）
      setForegroundWindow(dataManager!.hwnd);
      return;
    }
    final app = App.instance;
    if (app == null) return;
    final w = DataManagerWindow(owner: this);
    dataManager = w;
    app.runChild(w, width: 1000, height: 640, ownerHwnd: hwnd);
  }

  // ── 数据加载 ──

  void reload() {
    loadErrors.clear();
    vm = ViewModel.load(outRoot,
        errors: loadErrors, hidden: settings.hiddenSeries);
    // ★ 磁盘数据变了，之前缓存的快照内容、时间线、附件清单全部失效。
    _resultCache.clear();
    _attachCacheKey = null; // 附件清单（导入了新图之后必须重读）
    _invalidateSeriesCache();
    // 封面仓库：与数据目录同级（`out/扫榜/_covers`），随快照一起被保留策略管理
    covers ??= CoverStore(
      root: '$outRoot${_sep}扫榜${_sep}_covers',
      // 解码尺寸比显示尺寸留一档余量：窗口放到最大时仍然清晰。
      // 缓存里存的是**原始图片字节**，所以调大它不会重新下载，只是重新解码。
      decodeW: Metrics.coverDecodeW,
      decodeH: Metrics.coverDecodeH,
    );
    _ensureCoverPump();
    _syncIndex();
    // ★ 选中项的兜底要用 **visible** 而不是 all：
    //   被隐藏的榜还在 `all` 里，拿它兜底会出现"侧栏里没有这一项、
    //   右边却显示着它的明细"这种对不上的状态。
    final vis = vm!.visible;
    if (vis.isNotEmpty && !_isVisibleSelection(selectedId)) {
      selectedId = vis.first.id;
    }
    statusText = vis.isEmpty
        ? (vm!.all.isEmpty
            ? '还没有快照数据 —— 点「扫榜设置」抓一轮'
            : '所有榜单都被隐藏了 —— 点侧栏底部「管理」恢复显示')
        : '已载入 ${vm!.snapshotCount} 份快照 / ${vm!.recordCount} 条记录'
            '${vm!.hiddenCount > 0 ? '（另有 ${vm!.hiddenCount} 份已隐藏）' : ''}';
    if (loadErrors.isNotEmpty) {
      lastMessage = '${loadErrors.length} 个快照文件解析失败';
    }
    invalidate();
  }

  /// 当前选中项是否**在可见集合**里。
  bool _isVisibleSelection(int id) {
    final m = _metaById(id);
    if (m == null) return false;
    return !vm!.isHidden(m);
  }

  /// 与磁盘上的 `out/扫榜/index.json` 对齐。
  ///
  /// 做两件事：
  ///   ① **自愈** —— 磁盘上有、索引里没有的快照补进去并落盘。
  ///      （主路径是采集完立刻写索引；这里是"某次没写成"的兜底。）
  ///   ② **读回设置** —— 用户上次设的「每榜保留份数」。
  ///      只有索引里显式存过（`retention_set`）才覆盖默认值，
  ///      否则会把"从没设过"当成"用户选了 0 = 不限"。
  void _syncIndex() {
    try {
      final idxErrors = <String>[];
      final idx = SnapshotIndexFile.load(outRoot, errors: idxErrors);
      // 索引缺失/损坏被重建，或落后于磁盘被补齐 —— 都要立刻落盘，
      // 否则每次启动都得重扫一遍；更糟的是"索引文件压根不存在"这种状态
      // 会一直持续到用户改一次保留设置为止。
      if (idx.reconciled || idx.rebuilt) idx.save();
      if (idx.retentionSet) retentionPerSeries = idx.retention;
      if (idxErrors.isNotEmpty && loadErrors.isEmpty) {
        lastMessage = '索引有 ${idxErrors.length} 处需注意（已自动处理）';
      }
    } on Object catch (e) {
      loadErrors.add('索引同步失败：$e');
    }
  }

  // ── 扫榜 ──

  void openScanDialog() {
    if (vm == null) reload();
    // ★ 与 openDataManager 同一套守卫：已经开着就把它带到前面，
    //   否则连点两下会叠出两个设置窗（两份勾选状态各改各的）。
    final c = child;
    if (c != null && !c.isDisposed) {
      setForegroundWindow(c.hwnd);
      return;
    }
    showScanDialog(this);
  }

  /// 打开中的子窗口（用来避免重复打开同一设置窗）。
  AppWindow? child;

  void attachChild(AppWindow w) => child = w;

  void childClosed(AppWindow w) {
    if (identical(child, w)) child = null;
    invalidate();
  }

  /// 执行一批采集目标。
  ///
  /// [keepPerSeries] 是「每榜保留份数」（0 = 不限）。扫描结束、数据落盘后
  /// 立刻按系列裁剪超出的旧快照 —— **在 reload 之前**做，这样界面一次性
  /// 拿到"已经裁过"的清单，不会先显示一堆再看着它们消失。
  Future<void> startScan(List<ScanTarget> targets,
      {int? keepPerSeries}) async {
    if (targets.isEmpty) return;
    service ??= ScanService(outRoot: outRoot);
    if (keepPerSeries != null && keepPerSeries != retentionPerSeries) {
      retentionPerSeries = keepPerSeries;
      // ★ 用户设的保留份数要**跨会话**留住：它是数据策略，不是本次扫描参数。
      //   不落盘的话，重启后悄悄退回默认值 —— 用户会以为"我明明设了 3 份，
      //   怎么又给我留了 10 份"（而且是不可逆的：多留的还在，少删的也还在）。
      persistRetention();
    }

    pendingTargets = targets;
    scanTotal = targets.length;
    scanDone = 0;
    phase = ScanPhase.running;
    statusText = '准备开始…';
    lastMessage = null;
    invalidate();

    // 进度动画（扫榜本身是 await 的，动画靠定时器）
    //
    // ★ 只失效**状态栏那一条**，不是整窗。
    //   转圈动画每 60ms 动一次，整窗重绘意味着每 60ms 重建一次表格；
    //   一场扫榜动辄几分钟，那是上万次无意义的表格重建 —— 界面会明显掉帧。
    //   收窄到状态栏后，一次重绘只画几十个像素的字。
    _progressTimer ??= Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (phase == ScanPhase.running) _invalidateStatusBar();
    });

    final outcomes = <ScanOutcome>[];
    for (final t in targets) {
      statusText =
          '正在扫 ${sourceName(t.source)} · ${t.board}${t.category == null ? '' : ' · ${t.category}'}';
      _invalidateStatusBar();
      final r = await service!.scanOne(
        source: t.source,
        board: t.board,
        category: t.category,
        limit: t.limit,
      );
      outcomes.add(r);
      scanDone++;
      _invalidateStatusBar();
    }

    phase = ScanPhase.done;
    _progressTimer?.cancel();
    _progressTimer = null;

    final ok = outcomes.where((o) => o.hasData).length;
    final fail = outcomes.length - ok;
    statusText = '扫榜完成：$ok 个榜有数据${fail > 0 ? '，$fail 个没取到' : ''}';
    lastMessage = '共 ${outcomes.fold<int>(0, (a, o) => a + o.result.entries.length)} 条记录';

    // ★ 裁剪必须在 reload 之前：reload 会读索引并把清单推给界面，
    //   先 reload 再裁剪的话，用户会先看到超出的旧快照、再看着它们被删掉，
    //   期间还能点到一份即将消失的快照（点开就是"数据缺失"）。
    final pruned = _applyRetention();

    reload();
    if (fail > 0) {
      // 把失败原因放到状态栏，让用户知道"不是界面卡了"
      final first = outcomes.firstWhere((o) => !o.hasData, orElse: () => outcomes.first);
      lastMessage = '失败示例：${first.error ?? '未知原因'}';
    }
    // ★ 裁剪是**破坏性**动作：删了几个快照必须如实报出来。
    //   静默删除会让用户以为"数据怎么少了"却找不到原因。
    if (pruned.deletedEntries > 0) {
      statusText = '$statusText；已按保留策略清理 ${pruned.deletedEntries} 份旧快照'
          '（每榜保留 ${retentionPerSeries == 0 ? '不限' : '$retentionPerSeries 份'}）';
    }
    invalidate();
  }

  /// 应用「每榜保留份数」策略。
  ///
  /// [retentionPerSeries] == 0 表示不限（只清僵尸条目，不删有效快照）。
  /// 返回被删掉的条目数 —— 调用方用它决定要不要在状态栏如实汇报。
  ///
  /// ★ 为什么是"每**系列**"而不是"每**榜**"：同一张榜会有多个题材变体
  ///   （月票榜·玄幻 / 月票榜·都市），它们是**各自独立的时间线**。
  ///   若按"榜名"计数，选 8 个题材时保留策略会在这 8 条时间线之间抢名额，
  ///   用户看到的是"我设了保留 10 份，结果每个题材只剩 1 份"。
  ({int deletedEntries, int deletedFiles}) _applyRetention() {
    try {
      final idx = SnapshotIndexFile.load(outRoot);
      final res = idx.pruneSeries(keepPerSeries: retentionPerSeries);
      if (res.deletedEntries > 0) res.index.save();
      return (
        deletedEntries: res.deletedEntries,
        deletedFiles: res.deletedFiles,
      );
    } on Object catch (e) {
      // 裁剪失败不能影响扫榜结果本身（数据已经落盘了）
      lastMessage = '保留策略未生效：$e';
      return (deletedEntries: 0, deletedFiles: 0);
    }
  }

  /// 把当前「每榜保留份数」写进索引（跨会话保留）。
  ///
  /// 数据管理窗也会调它（那边改了保留份数，主窗的设置必须跟着走，
  /// 否则下次扫榜又按旧值裁 —— 两处口径不一致是数据丢失的经典来源）。
  void persistRetention() {
    try {
      SnapshotIndexFile.load(outRoot)
          .withRetention(retentionPerSeries)
          .save(retention: retentionPerSeries);
    } on Object catch (e) {
      lastMessage = '保留策略未能保存：$e';
    }
  }

  /// 「每榜保留份数」。0 = 不限。
  ///
  /// 由设置窗在开始扫榜时写入；启动时从索引读回（见 [_syncIndex]）。
  int retentionPerSeries = 10;

  /// 导出目录（所有导出物的统一落点）。
  String get exportDir => '$outRoot${_sep}导出';

  /// 当前快照的导出文件名主干（平台_榜单_题材_日期）。
  String _exportBase(SnapshotMeta m) => safeFileName('${sourceName(m.source)}_${m.board}'
      '${m.category == null ? '' : '_${m.category}'}_${m.dateKey}');

  /// 下拉菜单里的某一项被点了。
  ///
  /// ★ 每项只做**一件事**，且做完把真实结果（路径 / 条数 / 失败原因）写进
  ///   状态栏 —— 旧版一次性产 3 个文件、状态栏写"CSV / JSON / 全量"，
  ///   用户根本不知道哪个文件对应什么。现在点哪项产哪个，一一对应。
  void _onMenuCommand(int id) {
    switch (id) {
      case menuExportCsv:
        _exportOne('csv', (m) => snapshotToCsv(m));
      case menuExportJson:
        _exportOne('json', (m) => snapshotToJson(m));
      case menuExportBundle:
        _exportBundle();
      case menuExportBoardImage:
        // 导出榜单图要**先备齐封面**（异步），所以这里显式 unawaited：
        // 不 await 是有意的（不阻塞消息循环），但要用 unawaited 表明"我知道"。
        unawaited(_exportBoardImage());
      case menuExportTrendImage:
        _exportTrendImage();
      case menuExportAttachments:
        _exportAttachments();
      case menuImportImage:
        _importImageAttachment();
      case menuImportText:
        _importTextAttachment();
    }
  }

  /// 导出成功后**统一走这里**：状态栏 + 明确的信息框。
  ///
  /// ★ 用户原话："导出时没有提示"。根因是导出完会 `openExternal(dir)`
  ///   把导出目录弹到前台 —— **那个窗口抢走了注意力**，应用自己的状态栏
  ///   写了什么根本没人看见。所以必须弹一个模态框把结果说清楚。
  ///
  /// 弹框放在 `openExternal` **之前**：先让用户看到"导出到哪了"，
  /// 再让资源管理器跳出来。反过来的话框会被压在后面。
  void _reportExport(String what, String path, String detail) {
    statusText = '已导出$what：$path';
    lastMessage = detail;
    invalidate();
    infoDialog(hwnd, '导出完成',
        '已导出$what\n\n$path\n$detail\n\n点「确定」后会自动打开导出目录。');
  }

  void _exportOne(String ext, String Function(SnapshotMeta) render) {
    final m = currentMeta();
    if (m == null) {
      statusText = '先选一份快照再导出';
      invalidate();
      return;
    }
    try {
      final dir = exportDir;
      final path = exportTo(dir, _exportBase(m), ext, render(m));
      _lastExportDir = dir;
      _reportExport(ext.toUpperCase(), path, '${m.source} · ${m.board} · ${m.count} 条');
      openExternal(dir);
    } on Object catch (e) {
      statusText = '导出失败：$e';
    }
    invalidate();
  }

  void _exportBundle() {
    if (vm == null) return;
    try {
      final dir = exportDir;
      // ★ 全量导出必须带上**真正的**概览与对比。
      //   旧代码传的是两个字面量 `const {}`，于是磁盘上的
      //   `全部快照_*.json` 里 `overview={} comparisons={}`，
      //   而状态栏还写着"CSV / JSON / 全量"——用户以为拿到了全套分析。
      final index = SnapshotIndex.fromItems(vm!.all);
      final now = DateTime.now();
      final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      final path = exportTo(
        dir,
        '全部快照_$stamp',
        'json',
        bundleToJson(vm!.all, overview(index), comparisonsByPair(index)),
      );
      _lastExportDir = dir;
      _reportExport('${vm!.all.length} 份快照汇总', path, '含概览与两两对比');
      openExternal(dir);
    } on Object catch (e) {
      statusText = '导出失败：$e';
    }
    invalidate();
  }

  /// 导出「当前榜单」为 PNG 长图（整榜，不受窗口可视区限制）。
  ///
  /// ★ 列与**界面「榜单明细」一致**（`# / 封面 / 书名 / 作者 / 题材 / 指标 / 备注`），
  ///   单元格文本走 [board_text.dart] 同一份实现 —— 用户报过
  ///   "导出榜单与软件内的榜单明细差别很大"。
  Future<void> _exportBoardImage() async {
    final m = currentMeta();
    if (m == null) return;
    try {
      final entries = List<RankEntry>.of(m.result.entries)
        ..sort((a, b) => a.rank.compareTo(b.rank));

      // ★ 先把封面备齐再画。导出图是"整榜"，用户会拿它跟界面比：
      //   界面里可见行有真封面、导出图里却全是占位卡，那一定被当成 bug。
      //   取图走同一个 CoverStore（限速、落盘缓存都照旧），
      //   期间在状态栏如实说明"在等什么"。
      final store = covers;
      var waited = 0;
      if (store != null) {
        for (final e in entries) {
          store.peek(m.source, e.bookId,
              coverUrlFor(m.source, e.bookId, e.coverUrl));
        }
        if (store.hasWork) {
          statusText = '正在导出榜单图：先备齐封面…';
          invalidate();
          final sw = Stopwatch()..start();
          while (store.hasWork && sw.elapsed < const Duration(seconds: 10)) {
            await store.pump();
            waited = sw.elapsed.inMilliseconds;
            // 限速挡下（还没到下一次请求时间）时让出事件循环，别空转
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        }
      }

      final img = renderBoardImage(
        m,
        width: 980,
        // ★ 只读内存：能取到就画真封面，取不到画占位卡（不再触发新请求）
        coverLookup: store == null
            ? null
            : (e) => store.peek(
                m.source, e.bookId, coverUrlFor(m.source, e.bookId, e.coverUrl)),
      );
      if (img == null) {
        statusText = '这份快照没有条目，画不出榜单图';
        invalidate();
        return;
      }
      final dir = exportDir;
      final path = saveImage(dir, '榜单_${_exportBase(m)}', img);
      _lastExportDir = dir;
      var detail =
          '${img.width}x${img.height}，${(img.pngBytes / 1024).round()} KB，共 ${m.count} 条';
      if (store != null) {
        detail += '\n封面：已取 ${store.fetched} 张 / 失败 ${store.failed} 张'
            '${waited > 0 ? '（等了 ${(waited / 1000).toStringAsFixed(1)} 秒）' : ''}';
      }
      _reportExport('榜单图', path, detail);
      openExternal(dir);
    } on Object catch (e) {
      statusText = '导出榜单图失败：$e';
    }
    invalidate();
  }

  /// 导出「当前系列的趋势图」为 PNG。
  void _exportTrendImage() {
    final m = currentMeta();
    if (m == null) return;
    try {
      // `_ensureSeries` 返回 void，结果落在 `series` 字段上（带缓存，不会重算）。
      // 复用界面同一条时间线 —— 导出的图与屏幕上看到的必然一致。
      _ensureSeries(m);
      final ts = series?.analysis;
      if (ts == null) {
        statusText = '这份快照不在任何时间线里，画不出趋势';
        invalidate();
        return;
      }
      // ★ 把解读一起画进图里：导出的图常常是拿去给别人看的，
      //   只给折线等于把"为什么"留给读者自己猜。
      final insightLines = buildTrendInsight(ts).lines;
      final extraH = insightLines.isEmpty
          ? 0
          : (26 + insightLines.length * 18 + 20) + 18;
      final img = renderTrendImage(
        ts,
        width: 980,
        height: 520 + extraH,
        rangeLabel: _rangeLabelOf(seriesRange),
        insight: insightLines,
      );
      if (img == null) {
        statusText = '这个系列还没有可比期的数据';
        invalidate();
        return;
      }
      final dir = exportDir;
      final path = saveImage(dir, '趋势_${_exportBase(m)}', img);
      _lastExportDir = dir;
      _reportExport('趋势图',
          path, '${img.width}x${img.height}，${ts.periodCount} 期（${ts.rangeLabel}）');
      openExternal(dir);
    } on Object catch (e) {
      statusText = '导出趋势图失败：$e';
    }
    invalidate();
  }

  String _rangeLabelOf(TimeRange r) => switch (r) {
        TimeRange.last7 => '近 7 期',
        TimeRange.last30 => '近 30 期',
        TimeRange.all => '全部',
      };

  /// 当前快照的附件文件名清单（带一层缓存：选中项没变就不重复读索引）。
  ///
  /// ★ 缓存键用**稳定 id**（`metaToEntry(m).id`）而不是内存里的自增 id ——
  ///   自增 id 每次 reload 都会重排，拿它当缓存键会读到上一份快照的附件。
  List<String> attachmentsOf(SnapshotMeta m) {
    final key = metaToEntry(m).id;
    if (_attachCacheKey == key) return _attachCache;
    _attachCacheKey = key;
    try {
      final idx = SnapshotIndexFile.load(outRoot);
      var found = const <String>[];
      for (final e in idx.entries) {
        if (e.id == key) {
          found = e.attachments;
          break;
        }
      }
      _attachCache = found;
    } on Object {
      _attachCache = const [];
    }
    return _attachCache;
  }

  String? _attachCacheKey;
  List<String> _attachCache = const [];

  /// 导出当前快照的全部附件到 `out/导出/附件_{平台}_{榜}_{日期}/`。
  ///
  /// ★ 为什么要"导出一份"而不是只提供"打开附件目录"：
  ///   附件目录藏在 `扫榜/_attachments/` 下面，用户很难自己找到；
  ///   而导出目录是**用户已经熟悉的地方**（CSV / 图片都往那儿放）。
  void _exportAttachments() {
    final m = currentMeta();
    if (m == null) {
      statusText = '先选一份快照再导出附件';
      invalidate();
      return;
    }
    try {
      final idx = SnapshotIndexFile.load(outRoot);
      final id = metaToEntry(m).id;
      IndexEntry? entry;
      for (final e in idx.entries) {
        if (e.id == id) {
          entry = e;
          break;
        }
      }
      if (entry == null || entry.attachments.isEmpty) {
        statusText = '这份快照还没有附件（用「导入」菜单挂一张截图试试）';
        invalidate();
        return;
      }
      final dir = '$exportDir${_sep}附件_${_exportBase(m)}';
      final r = idx.exportAttachments(entry, dir);
      _lastExportDir = dir;
      _reportExport(
          '${r.copied} 个附件',
          dir,
          r.missing > 0
              ? '有 ${r.missing} 个附件文件已不在磁盘上，已跳过'
              : entry.attachments.join('、'));
      openExternal(dir);
    } on Object catch (e) {
      statusText = '导出附件失败：$e';
    }
    invalidate();
  }

  /// 导入一张图片，存为**当前快照的佐证附件**。
  ///
  /// ★ 为什么不直接做 OCR：本机实测 WinRT OCR 在裸 exe 里不可用
  ///   （见 `lib/ocr.dart` 的结论），所以这里只负责"存档"，
  ///   文字识别走「粘贴文本」那条路。图片本身作为证据留着，永远有用。
  void _importImageAttachment() {
    final m = currentMeta();
    if (m == null) {
      statusText = '先选一份快照，图片才能挂到它上面';
      invalidate();
      return;
    }
    final src = openImageFileDialog(hwnd,
        title: '选择要存档为该快照附件的图片',
        initialDir: Directory.current.path);
    if (src == null) {
      statusText = '已取消导入';
      invalidate();
      return;
    }
    // ★ 这一步才需要索引：附件挂在**稳定 id** 上（不是内存里的自增 id），
    //   否则重启后附件就找不回对应的快照了。
    try {
      final idx = SnapshotIndexFile.load(outRoot);
      final entry = metaToEntry(m);
      final upserted = idx.upsert(entry);
      final res = upserted.importImage(
        upserted.entries.firstWhere((e) => e.id == entry.id),
        srcPath: src,
      );
      // ★★ 必须**登记进索引**。`importImage` 只负责把文件拷进附件目录，
      //   它不会改索引 —— 少了这一步：① 界面 `attachmentsOf()` 查不到，
      //   用户看不到自己刚导入的附件；② 保留策略会把附件目录当"僵尸"清掉。
      //   而状态栏已经写了"已存档附件" —— 那就是在骗用户。
      upserted.addAttachment(entry.id, res.fileName).save();
      statusText = '已存档附件：${res.fileName}';
      lastMessage = '挂在 ${m.source} · ${m.board} · ${m.dateKey} 上';
    } on Object catch (e) {
      statusText = '导入图片失败：$e';
    }
    reload();
    invalidate();
  }

  /// 导入剪贴板文本，存为附件（.txt）。
  ///
  /// 这是"手动粘贴文本"的落点：用户从别处（截图工具、PDF、聊天记录）
  /// 复制一段榜单快照文本，挂到对应快照上留档。
  void _importTextAttachment() {
    final m = currentMeta();
    if (m == null) {
      statusText = '先选一份快照，文本才能挂到它上面';
      invalidate();
      return;
    }
    final text = readClipboardText();
    if (text == null || text.trim().isEmpty) {
      statusText = '剪贴板里没有文本（或剪贴板被别的程序占用，稍后再试）';
      invalidate();
      return;
    }
    try {
      final idx = SnapshotIndexFile.load(outRoot);
      final entry = metaToEntry(m);
      final upserted = idx.upsert(entry);
      final target = upserted.entries.firstWhere((e) => e.id == entry.id);
      final bytes = const Utf8Encoder().convert(text);
      final res = upserted.importImage(target,
          bytes: bytes, preferName: '粘贴文本_${m.dateKey}.txt');
      // 同上：登记进索引，否则这条文本附件等于白存
      upserted.addAttachment(entry.id, res.fileName).save();
      statusText = '已存档文本附件：${res.fileName}'
          '（${text.length} 字）';
    } on Object catch (e) {
      statusText = '导入文本失败：$e';
    }
    reload();
    invalidate();
  }

  /// 最近一次导出的目录（供"打开导出目录"按钮用）。
  String? get lastExportDir => _lastExportDir;

  String? _lastExportDir;

  /// 重新打开上次导出目录（没导出过就打开默认导出目录）。
  void openExportDir() {
    final dir = _lastExportDir ?? '$outRoot${_sep}导出';
    try {
      Directory(dir).createSync(recursive: true);
    } on Object {
      // 建不出来就让 openExternal 报错
    }
    openExternal(dir);
  }

  @override
  bool onClosing() {
    if (phase == ScanPhase.running) {
      // 正在扫榜时关窗要确认（避免半途丢数据）
      final r = confirmDialog(
        hwnd,
        '扫榜还在进行中',
        '现在关闭会中断本次采集。已抓到的榜都已存盘，不会丢。\n确定要关闭吗？',
      );
      return r;
    }
    return true;
  }

  static String get _sep => Platform.isWindows ? '\\' : '/';

  // ── 自检钩子 ──
  //
  // 本机沙箱跑不了 `dart analyze` / `dart compile kernel`（管道句柄耗尽，
  // 一律 CreateFile failed 231），所以"能不能编译"只能靠真跑一遍来验证。
  // 下面这些 @visibleForTesting 等价物，就是给自检脚本用的。

  /// 不经窗口就设置客户区尺寸（等价于收到 WM_SIZE）。
  /// 自检：明细表的自然总宽（整表放大后的宽度）。
  int get testDetailNaturalWidth => naturalWOfDetail;

  /// 自检：把明细表横向滚到 [x]（超出上限会被夹住）。
  void testScrollDetailX(int x) {
    final area = detailTableArea;
    final maxX = area == null
        ? 0
        : (naturalWOfDetail - area.width).clamp(0, 1 << 30);
    detailScrollX = x.clamp(0, maxX);
  }

  /// 自检：按稳定 id 选中一份快照（等价于点了侧栏那一行）。
  void testSelect(int id) {
    selectedId = id;
    detailScroll = 0;
    seriesScroll = 0;
    _invalidateSeriesCache();
  }

  void testSetSize(int w, int h) {
    setSizeForTest(this, w, h);
  }

  /// 切标签页（等价于点了标签）。
  void testSetTab(int tab) => curTab = tab;

  /// 自检：明细表这一帧的实际缩放（自适应，1.0 ~ 1.5）。
  double get testDetailScale => detailS;

  /// 自检：明细表这一帧的行高 / 表头高 / 字号 / 封面尺寸（都按实际缩放算）。
  int get testDetailRowHeight => Metrics.detailRowHeightAt(detailS);
  int get testDetailHeaderHeight => Metrics.detailHeaderHeightAt(detailS);
  int get testDetailFontSize => Metrics.detailFontAt(detailS);
  int get testCoverWidth => Metrics.coverWidthAt(detailS);
  int get testCoverHeight => Metrics.coverHeightAt(detailS);

  /// 自检：明细表的纵向滚动上限（滚轮"能滚到哪"与绘制"画到哪"必须一致）。
  int get testDetailMaxScroll {
    final r = hitRects[idDetailTable];
    return r == null ? 0 : _maxScroll(r, idDetailTable);
  }

  /// 自检：明细表这一帧**画到的右边界**（客户区坐标）。
  ///
  /// 用来断言"宽屏下表格撑满可用区、右侧不留空缺"。
  int get testDetailDrawnRight => detailDrawnRight;

  /// 自检：明细表这一帧实际画了多宽。
  int get testDetailDrawnWidth => detailDrawnW;

  /// 自检：第 [rowIdx] 行的**整行**链接命中区。
  Rc? testBookRowRect(int rowIdx) => hitRects[idBookRowLinkBase + rowIdx];

  /// 自检：第 [rowIdx] 行的「打开」按钮命中区。
  Rc? testBookButtonRect(int rowIdx) => hitRects[idBookLinkBase + rowIdx];

  /// 自检：按**导出同一条路径**渲染当前榜单图。
  ///
  /// [withCovers] = false 时不画封面（走占位卡）——
  /// 两次渲染的封面列像素一比，就能证明"真封面确实进了导出图"。
  RenderedImage? testRenderBoardImage({bool withCovers = true}) {
    final m = currentMeta();
    if (m == null) return null;
    final store = covers;
    return renderBoardImage(
      m,
      width: 980,
      coverLookup: (!withCovers || store == null)
          ? null
          : (e) => store.peek(
              m.source, e.bookId, coverUrlFor(m.source, e.bookId, e.coverUrl)),
    );
  }

  /// 自检：第 [rowIdx] 行备注列**真正显示的文本**。
  String testNoteTextOf(int rowIdx) {
    final m = currentMeta();
    if (m == null || rowIdx < 0 || rowIdx >= m.result.entries.length) return '';
    return noteTextOf(m.result.entries[rowIdx]);
  }

  /// 自检：明细表当前纵向偏移。
  int get testDetailScrollY => detailScroll;

  /// 自检：明细表当前横向偏移。
  int get testDetailScrollX => detailScrollX;

  /// 自检：明细表可见区域矩形。
  Rc? get testDetailArea => detailTableArea;

  /// 自检：横向滚动条矩形（没溢出时为 null）。
  Rc? get testDetailHScrollRect => detailHScroll;

  /// 自检：把纵向滚到 [y]（走与滚轮同一条夹取路径）。
  void testScrollDetailY(int y) {
    final r = hitRects[idDetailTable];
    if (r == null) return;
    detailScroll = y.clamp(0, _maxScroll(r, idDetailTable));
  }

  /// 自检：模拟一次横向滚轮。
  void testHWheel(int x, int y, int delta) => onHWheel(x, y, delta);
}

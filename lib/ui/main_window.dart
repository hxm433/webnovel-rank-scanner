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
import 'dart:ffi';
import 'dart:io' show Directory, File, FileMode, Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis.dart';
import '../exporters.dart';
import '../models.dart';
import '../report_data.dart';
import '../scan_service.dart';
import '../snapshot_index.dart';
import '../snapshot_index_file.dart';
import '../xlsx.dart';
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
// ★ 原来这里有一份 `_blendColor`，与 `widgets.dart` 的 `blend` **逐字相同**
//   （审查报告 #46）。两份同时存在 = 改一处不改另一处会让"淡入"和"徽标底色"
//   的算法悄悄分叉，所以删掉私有那份、直接用公共的 `blend`。

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

  /// 临时提示条（toast）的文本与到期时间。
  ///
  /// ★ 为什么要有它：状态栏只有一行小字，而且在**浏览器抢走焦点之后**
  ///   用户根本看不到。点「打开」这种事必须有一个**在窗口里、盖在所有内容之上**
  ///   的回执 —— 否则"点了有没有反应"永远说不清。
  String? toastText;
  DateTime? toastUntil;

  /// 打开书链接的尝试日志（`out/扫榜/_open_log.txt`）。
  ///
  /// ★ 用户连着报了三轮"链接打不开"，而每一轮我这边都验通了。
  ///   这种"复现不了"的问题只能靠**留证据**：每一次打开尝试都把
  ///   `ShellExecuteW` 的返回值、兜底结果、最终 URL 写进文件。
  File? _openLog;

  /// `_open_log.txt` 超过 512 KB 时**只保留最近这么多行**。
  ///
  /// ★ 为什么不无限追加：这份日志的用途是"看最近几次走了哪条路"，
  ///   历史记录没有价值，而用户点一年它就会长一年。
  static const int _openLogKeep = 500;

  /// 跨榜信号表的纵向滚动偏移。
  ///
  /// ★ 为什么需要：这张表最多 30 本，而它只分到卡片里的一小块高度 ——
  ///   没有滚动的话"共 30 本 · 显示前 1 本"，剩下 29 本永远看不到。
  int crossScroll = 0;

  /// 跨榜聚合缓存：`vm` 实例变了（reload / 隐藏后重建）就自动失效。
  ///
  /// ★ 为什么必须缓存：`crossBoardBooks()` 内部会重建 SnapshotIndex 并跑
  ///   一次全量 overview；跨榜页每帧重跑等于把整库条目重新聚合一遍。
  ViewModel? _crossCacheVm;
  List<CrossBoardBook>? _crossBooksCache;
  List<PlatformCategoryProfile>? _crossProfilesCache;

  /// 当前时间线（缓存，避免每帧重算 + 重读磁盘）。
  SeriesView? series;

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

  /// 明细表的**竖向滚动条**命中区（只覆盖 drawScrollbar 实际画的 11px 条带）。
  ///
  /// ★ 必须有独立 id：它叠在表格右缘的"整行可点"链接区之上，
  ///   没有它的话点滚动条会直接 openBookLink 打开浏览器。
  static const int idDetailVScroll = 211;
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

  /// 「Excel 表格（.xlsx）」。
  ///
  /// ★ 与 CSV 的区别不是"换个后缀"：xlsx 是 Excel 的**原生**格式 ——
  ///   字符串以 `inlineStr` 存，**结构上就不可能是公式**（CSV 只能靠
  ///   内容层面的"前置单引号"打补丁）；而且能放**多张表**。
  static const int menuExportXlsx = 606;

  static const int menuImportImage = 610;
  static const int menuImportText = 611;

  /// 「设置导入起始目录」。
  static const int menuChooseImportDir = 621;

  /// 「设置导出位置…」。
  ///
  /// ★ 第 25 轮：导出不再每次都弹目录框（用户判定那样"根本不可用"），
  ///   改成"直接导到固定位置 + 菜单里可改"。
  ///
  /// ★ 编号说明：620 曾在第 21 轮被删（那版方案是"每次导出弹框选目录"），
  ///   现在**恢复**这一项、占用 620；622 是第 21 轮预留的空号，不复用。
  static const int menuChooseExportDir = 620;

  /// 「每次导出前先问文件夹」的开关（菜单文字里带当前状态）。
  static const int menuAskExportDir = 623;

  // ★ 第 21 轮曾把「导出位置」整组删掉（见 `_destItems` 的注释），
  //   第 25 轮按用户要求加回来 —— 但语义只有一套：
  //   **导出直接落到 `settings.exportDir`（默认 out\导出），想改就点这一项**。

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
  void _startTabAnim() {
    _tabAnim = 0;
    _tabTimer?.cancel();
    _tabTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      _tabAnim += 0.14; // ≈ 7 帧 ≈ 110ms
      if (_tabAnim >= 1) {
        _tabAnim = 1;
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
    return blend(color, Palette.bg, _fadeIn);
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

    // ★ 临时提示条**最后画**（盖在菜单之上）：它是"刚才那一下发生了什么"的回执，
    //   被任何东西压住都等于没有。
    _paintToast(g);
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
    (menuExportXlsx, 'Excel 表格（.xlsx，多张表）'),
    (menuExportCsv, 'CSV 明细表'),
    (menuExportJson, 'JSON（单份快照 + 分析）'),
    (menuExportBoardImage, '榜单图片（PNG 长图）'),
    (menuExportAttachments, '附件（图片 / 文本）'),
  ];

  static const List<(int, String)> _trendItems = [
    (menuExportTrendImage, '趋势图（PNG，含解读）'),
    (menuExportBundle, '全部快照汇总（含两两对比）'),
  ];

  /// 导出位置的设置项。
  ///
  /// ★★ 第 25 轮把这一组**加回来**了（第 21 轮曾整组删掉）。
  ///   第 21 轮的方案是"每次导出都弹文件夹选择框"，本意是让用户当场决定；
  ///   但用户实测判定**根本不可用** —— 每导出一次要点三次对话框，
  ///   而"选目录"这一步一旦弹不出来/弹到主窗后面/选到不可写的盘，
  ///   表现就是"导出没反应"。
  ///   现在的语义回到**单一且明确**的那一套：
  ///     · 导出**直接落到固定目录**（默认 `out\导出`，不再弹框）；
  ///     · 想换地方 → 点这一项，弹一次框、记进 `settings.exportDir`。
  ///   一套语义、一个入口，不存在"两个字段互相打架"的空间。
  static const List<(int, String)> _destItems = [
    (menuChooseExportDir, '设置导出位置…'),
    (menuAskExportDir, ''),
  ];

  static const List<(int, String)> _importItems = [
    (menuImportImage, '图片 → 存为该快照的附件'),
    (menuImportText, '粘贴文本 → 存为附件文本'),
    (menuChooseImportDir, '设置图片的起始目录…'),
  ];

  /// 菜单 → 分组。`title` 为空表示整份菜单只有一组（不画标题，免得噪声）。
  List<MenuSection> _sectionsOf(String menu) {
    if (menu == 'export') {
      return [
        MenuSection('榜单（这一份快照）',
            [for (final it in _boardItems) it.$2]),
        MenuSection('趋势分析 / 历史对比',
            [for (final it in _trendItems) it.$2]),
        // ★ 第 21 轮：这一组不再放"预设导出位置"之类的东西了（原因见 _destItems
        //   的注释）。只留一句**说明**（空 items 的组在排版上就是一行灰色小字），
        //   把"每次导出都会让你选文件夹、上次停在哪"讲清楚 ——
        //   用户不需要、也没法在这里预设任何东西。
        MenuSection('导出到：${_shortDirLabel(settings.exportDir ?? _defaultExportDir)}',
            [
          for (final it in _destItems)
            it.$1 == menuAskExportDir
                // ★ 开关状态必须**写在菜单文字里** —— 否则用户没法知道它在哪一档
                ? '每次导出前先问文件夹（当前：${settings.askExportDir ? "开" : "关"}）'
                : it.$2,
        ]),
      ];
    }
    return [
      MenuSection('', [for (final it in _importItems) it.$2]),
    ];
  }

  /// 把目录路径缩成"能在菜单标题里放得下"的形式（只留最后一段）。
  ///
  /// ★ 菜单标题是**显示用**的，整条长路径会把它撑爆、挤掉后面的项。
  ///   完整路径在点击后的信息框里给出。
  static String _shortDirLabel(String p) {
    final t = p.replaceAll('\\', '/');
    final i = t.lastIndexOf('/');
    return i < 0 || i == t.length - 1 ? t : t.substring(i + 1);
  }

  /// 分组里的第 (si, ii) 项 → 控件 id。**必须与 [_sectionsOf] 同序**。
  ///
  /// ★ 第 21 轮起导出菜单只有两组带项的（榜单 / 趋势），第三组是纯说明行
  ///   （`items` 为空），`_idAt` 永远不会被第三组调用 —— 这里仍写全，
  ///   好在将来往那组加项时不会静默取错。
  int _idAt(String menu, int si, int ii) {
    if (menu == 'export') {
      final list = switch (si) {
        0 => _boardItems,
        1 => _trendItems,
        _ => _destItems,
      };
      return list[ii].$1;
    }
    return _importItems[ii].$1;
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

    _ensureDetailCache(m);
    final view = _detailViewCache!;
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
    final atts = _detailAttachmentsCache!;
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
    final hint = drawHint(
        g, area, y, '指标口径：${_detailLegendCache!}', Palette.accent);
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

    final rows = _detailRowsCache!;
    final colors = _detailRowColorCache!;
    final cellColors = _detailCellColorCache!;

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
          // ★ 旧快照里起点存的是会撞 WAF 的 `book.qidian.com/info/…`；
          // ★ 第 25 轮：**原样登记快照里的地址**，不做任何改写。
          //   用户原话："直接把链接放入就行了，不要搞别的"。
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
      // ★ 只登记 drawScrollbar 实际绘制的右侧 11px 条带；vTrack 是整个表格，
      //   整块登记会把所有行点击都吃掉。
      if (vPresent) {
        hitRects[idDetailVScroll] =
            Rc.xywh(vTrack.right - barW, vTrack.top, barW, vTrack.height);
      }
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

  /// 明细页按快照重建一次纯格式化缓存（同一份快照后续每帧复用）。
  ///
  /// ★ rows/cellColors 是对**全部条目**做的 boardColText 格式化（含正则），
  ///   一帧真正只画十几行；不缓存的话 hover/滚动/状态栏重绘都会重跑全量。
  void _ensureDetailCache(SnapshotMeta m) {
    if (m.id == _detailCacheId && _detailRowsCache != null) return;
    _detailCacheId = m.id;
    _detailViewCache = SnapshotView(m, const RankAnalyzer().analyze(m.result));
    final rows = <List<String>>[];
    final rowColors = <int>[];
    final cellColors = <List<int?>>[];
    for (final e in m.result.entries) {
      final hasLink = (e.url ?? '').isNotEmpty;
      rows.add([
        for (final c in boardCols) boardColText(c, e, source: m.source),
      ]);
      rowColors.add(e.titleObfuscated ? Palette.obfuscated : Palette.fg);
      cellColors.add([
        for (final c in boardCols)
          c == BoardCol.title
              ? (hasLink
                  ? (e.titleObfuscated ? Palette.obfuscated : Palette.accent)
                  : (e.titleObfuscated ? Palette.obfuscated : Palette.fg))
              : null,
      ]);
    }
    _detailRowsCache = rows;
    _detailRowColorCache = rowColors;
    _detailCellColorCache = cellColors;
    _detailLegendCache = _metricLegend(m);
    _detailAttachmentsCache = attachmentsOf(m);
  }

  /// 换主题/换数据后丢清明细缓存（颜色是按当时的 Palette 烘进去的）。
  void _invalidateDetailCache() {
    _detailCacheId = -1;
    _detailViewCache = null;
    _detailRowsCache = null;
    _detailCellColorCache = null;
    _detailRowColorCache = null;
    _detailLegendCache = null;
    _detailAttachmentsCache = null;
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
    // ★ 用 runes.first 而不是 codeUnits.first（审查报告 #37）：
    //   `codeUnits` 是 UTF-16 码元，书名首字符若是 emoji 这类补充平面字符，
    //   取到的是**高位代理**（0xD800-0xDBFF），`seed % 6` 的分布会明显偏斜 ——
    //   占位封面的配色会挤在少数几档上。
    final seed = e.title.isEmpty ? 0 : e.title.runes.first + e.title.length;
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
    final ch =
        e.title.isEmpty ? '书' : String.fromCharCode(e.title.runes.first);
    g.text(ch, r, fore,
        size: Metrics.fontSize, align: dtCenter, bold: true);
    // 底部一条细线，让它读起来像"书的封底折线"而不是一个纯色块
    g.fill(Rc.xywh(r.left + 4, r.bottom - (5 * Metrics.factor).round(),
            r.width - 8, (1.5 * Metrics.factor).round().clamp(1, 2)),
        fore);
  }

  /// 自检：读菜单分组（不外传 _sectionsOf，避免测试脚本碰私有成员）。
  List<MenuSection> testMenuSections(String menu) => _sectionsOf(menu);

  /// 自检：默认导出目录（`out/导出`）。
  ///
  /// ★ 第 21 轮：导出的落点由用户在对话框里当场决定，所以"默认导出目录"
  ///   只用来给**弹框定起点**。测试要能确认它仍是 `out/导出`。
  String get testDefaultExportDir => _defaultExportDir;

  /// 自检：分组里的第 (si, ii) 项对应的控件 id。
  int testMenuIdAt(String menu, int si, int ii) => _idAt(menu, si, ii);

  /// 自检：打开某个下拉菜单（`'export'` / `'import'`），
  /// 好让下一次绘制把每项的命中区登记进去。
  void testOpenMenu(String menu) {
    openMenu = menu;
    invalidate();
  }

  /// 自检：摆一下鼠标位置（`_paintPopMenu` 的 hover 判定要用）。
  void testSetMouse(int x, int y) {
    mouseX = x;
    mouseY = y;
  }

  /// 自检：读某个控件 id 当前的命中矩形（没登记则 null）。
  Rc? testHitRect(int id) => hitRects[id];

  /// 自检：**跳过文件夹对话框**，把当前快照按 [ext] 导出到 [dir]。
  ///
  /// ★ 存在的理由：`_exportOne` 会弹真实目录框，headless 下没法交互。
  ///   这个入口走**同样**的渲染 + 写盘代码，只是把"落点"直接给定，
  ///   用来验证"给定目录之后"这条链路（第 22 轮排查"导出无效"用）。
  ///   返回实际写入的路径；没有当前快照或导出抛错时返回 null。
  String? testExportOneTo(String dir, String ext) {
    final m = currentMeta();
    if (m == null) return null;
    try {
      final content = ext == 'json' ? snapshotToJson(m) : snapshotToCsv(m);
      final path = exportTo(dir, _exportBase(m), ext, content);
        statusText = '已导出${ext.toUpperCase()}：$path';
      return path;
    } on Object catch (e) {
      statusText = '导出失败：$e';
      return null;
    }
  }

  /// 自检：当前生效的导出落点（开了"先问文件夹"时返回 null = 要先弹框）。
  String? get testEffectiveExportDir => _beginExport();

  /// 自检：直接设置导出落点（等价于在「设置导出位置…」里选完）。
  void testSetExportDir(String? dir) {
    settings.exportDir = dir;
    saveSettings();
  }

  /// 自检：直接设置「每次导出前先问文件夹」开关。
  void testSetAskExportDir(bool on) {
    settings.askExportDir = on;
    saveSettings();
  }

  /// 自检：按**菜单项那条路径**导出一次 —— 走 `_beginExport`（不弹框那条）。
  ///
  /// ★ 这条断言的价值在于"**它跑得完**"：老方案里 `_beginExport` 会弹一个
  ///   **模态**文件夹框，测试会**永远卡住**。现在它直接返回落点，
  ///   于是"导出一次并拿到路径"本身就成了"不再弹框"的证明。
  String? testExportViaMenuPath(String ext) {
    final m = currentMeta();
    if (m == null) return null;
    final dir = _beginExport(what: ext.toUpperCase());
    if (dir == null) return null; // 开了"先问文件夹"且用户取消
    try {
      final path = exportTo(dir, _exportBase(m), ext,
          ext == 'json' ? snapshotToJson(m) : snapshotToCsv(m));
      statusText = '已导出${ext.toUpperCase()}：$path';
      return path;
    } on Object catch (e) {
      statusText = '导出失败：$e';
      return null;
    }
  }

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

  /// 明细页的**按快照缓存**（同一份快照每帧直接复用，不再重建）。
  ///
  /// ★ 为什么必须缓存：rows/cellColors 是对**全部条目**做 boardColText
  ///   格式化（含正则），而一帧真正只画十几行；缓存随 `m.id` 失效，
  ///   reload / 换主题时清空。
  int _detailCacheId = -1;
  SnapshotView? _detailViewCache;
  List<List<String>>? _detailRowsCache;
  List<List<int?>>? _detailCellColorCache;
  List<int>? _detailRowColorCache;
  String? _detailLegendCache;
  List<String>? _detailAttachmentsCache;

  /// 索引里的附件清单（稳定 id → 文件名），由 [_syncIndex] 载入索引时顺手填好，
  /// 绘制路径就不用为了附件再同步读一遍 index.json。
  Map<String, List<String>> _attachmentsById = const {};

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

  /// 弹一条临时提示（盖在界面最上层，几秒后自己消失）。
  void _toast(String msg, {int ms = 6000}) {
    toastText = msg;
    toastUntil = DateTime.now().add(Duration(milliseconds: ms));
    invalidate();
    Timer(Duration(milliseconds: ms + 50), () {
      if (isDisposed) return;
      if (toastUntil != null &&
          DateTime.now().isBefore(toastUntil!)) {
        return; // 期间又弹了一条更新的，别把它清掉
      }
      toastText = null;
      toastUntil = null;
      invalidate();
    });
  }


  /// 等一个**真的打开了页面**的浏览器窗口。
  ///
  /// 返回 `(窗口句柄, 是否像加载成功)`：
  ///   · `hwnd == 0`          → 压根没等到浏览器窗口；
  ///   · `hwnd != 0, ok=false` → 窗口起来了，但标题是"新建标签页"这类**空白页**
  ///     （用户实测过这种：Edge 开了，页面却没导航过去）。
  ///
  /// ★ 为什么要"等"：Edge 冷启动要好几秒（实测点完 1.5s 才出现窗口），
  ///   而且会**先**显示新建标签页、**再**导航过去 —— 所以空白标题要
  ///   继续等，不能立刻判失败。
  /// [timeout] 每"路"给多少时间：前面的路短一点（失败了赶紧换下一条），
  /// 最后一条给足（冷启动 + 导航最慢的就是它）。
  /// 本次运行**已经确认**过"Edge 以管理员身份运行"这个冲突。
  ///
  /// ★ 记住它，是为了**不再重复弹窗**：撞过一次之后再点「打开」，
  ///   直接给结论、不再去试那几条路 —— 试了只会再触发 Edge 自己那个
  ///   「现有实例正在以提升的权限运行」框，用户白白多关一个窗。
  ///   重启工具即恢复重试（那时 Edge 可能已经不是管理员身份了）。
  bool elevationAlreadyTold = false;

  /// 是否撞上了"Edge 以管理员身份运行"那个提权冲突对话框。
  ///
  /// ★ 命中它就**别再等了** —— 那个框在等用户点「是/否」，
  ///   页面不可能自己出现；而且提示要说**准**（不是"浏览器慢"，是权限冲突）。
  bool browserElevationBlocked = false;

  Future<(int, bool)> _waitForBrowserWindow(
      {Duration timeout = const Duration(seconds: 7),
      String url = '',
      String bookTitle = ''}) async {
    final sw = Stopwatch()..start();
    var lastSeen = 0;
    while (sw.elapsed < timeout) {
      // ★★ 这里原本会**替用户点掉**那个提权框的「是(Y)」。
      //   **已撤销**（第 39 轮，用户录屏为证）：那个按钮 = "用普通权限重启 Edge"，
      //   点下去会把用户**开着的所有 Edge 窗口一起关掉**，而页面照样没打开 ——
      //   代价远大于收益。那个框是 Edge 自己的，**不该由我们去点**。
      //   现在只"认出来 + 如实说"。
      if (findBrowserElevationDialog() != 0) {
        browserElevationBlocked = true;
        return (0, false);
      }
      // ★ 枚举**所有**浏览器窗口，挑"标题对得上这本书/这个平台"的那个。
      //   只看第一个会挑到 Edge 的辅助窗口或"还原页面"提示（都踩过）。
      final hits = browserWindows();
      for (final h in hits) {
        final (_, title) = windowClassAndTitle(h);
        if (_browserTitleMatches(title, url, bookTitle)) return (h, true);
      }
      if (hits.isNotEmpty) lastSeen = hits.first;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return (lastSeen, false);
  }

  /// 这个浏览器窗口标题，像不像"真的打开了我们那个页面"？
  ///
  /// 判据（命中任一即可）：
  ///   · 标题里有**书名前 4 个字**（书名没被字体反爬混淆时最准）；
  ///   · 标题里有**平台站点名**（起点 / 番茄 / 七猫 / 晋江 —— 页面标题基本都带）。
  ///
  /// ★ 为什么不能只判"非空且不是新建标签页"：Edge 的**"还原页面"提示窗口**
  ///   同样是非空标题、同样属于 msedge 进程 —— 那样会再报一次假成功。
  ///   宁可判成"没能确认"（诚实），也不要谎报。
  bool _browserTitleMatches(String title, String url, String bookTitle) {
    if (isBlankBrowserTitle(title)) return false;
    final t = title.toLowerCase();
    final bt = bookTitle.trim();
    // 书名前 4 个字（太短会误命中，太长遇到截断会漏）
    if (bt.length >= 4) {
      final head = bt.substring(0, 4).toLowerCase();
      if (t.contains(head)) return true;
    } else if (bt.length >= 2 && t.contains(bt.toLowerCase())) {
      return true;
    }
    // 平台站点名（从地址里认）
    for (final e in const {
      'qidian.com': '起点',
      'fanqienovel.com': '番茄',
      'qimao.com': '七猫',
      'jjwxc.net': '晋江',
    }.entries) {
      if (url.contains(e.key) && title.contains(e.value)) return true;
    }
    return false;
  }

  /// 当前那个浏览器窗口的标题（写日志用）。
  String _browserTitle(int hwnd) {
    if (hwnd == 0) return '(没有浏览器窗口)';
    try {
      final (_, t) = windowClassAndTitle(hwnd);
      return t.isEmpty ? '(标题为空)' : t;
    } on Object {
      return '(读标题失败)';
    }
  }

  /// 当时所有可见顶层窗口的清单（类名 + 标题）—— "点了没反应"的证据。
  ///
  /// ★ 窗口**类名**是最硬的证据：`Chrome_WidgetWin_1` = 浏览器、
  ///   `ConsoleWindowClass` = 控制台、`#32770` = 系统对话框。
  String _windowDump() {
    final sb = StringBuffer();
    final proc = Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(_dumpCb, 1);
    _dumpSink = sb;
    try {
      enumWindows(proc, 0);
    } on Object {
      return '    (枚举窗口失败)';
    } finally {
      _dumpSink = null;
    }
    return sb.toString().trimRight();
  }

  // ★ 注意：`_dumpSink` **只**能是顶层变量（见文件末尾）——
  //   回调是顶层函数，`Pointer.fromFunction` 拿到的是它；
  //   这里再声明一个同名**实例字段**的话，方法写的是字段、回调读的是顶层，
  //   结果就是"枚举跑完了但一个字都没写进去"（踩过）。

  /// 往 `out/扫榜/_open_log.txt` 追加一行打开记录（失败也不影响功能）。
  void _logOpen(String what, String url, int rc, String note) {
    try {
      final f = _openLog ??=
          File('$outRoot${_sep}扫榜${_sep}_open_log.txt');
      f.parent.createSync(recursive: true);
      final t = DateTime.now();
      final ts = '${t.year}-${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')} '
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}';
      // ★ 日志**只留最近 [_openLogKeep] 行**：这份日志是"复现不了的问题"
      //   留的证据，看的是最近几次；不封顶的话它会一直长（用户点一年就一年长）。
      //   先截断再追加，代价是一次读文件 —— 只在超过上限时才发生。
      if (f.existsSync() && f.lengthSync() > 512 * 1024) {
        final lines = f.readAsLinesSync();
        if (lines.length > _openLogKeep) {
          f.writeAsStringSync(
              '${lines.sublist(lines.length - _openLogKeep).join('\n')}\n',
              flush: true);
        }
      }
      // ★ 记完这一行再附上**当时的窗口清单** —— "点了没反应"这类问题
      //   只能靠现场证据（窗口类名是最硬的）。
      f.writeAsStringSync(
          '$ts\t$what\trc=$rc\t$note\t$url\n'
          '    当时的可见顶层窗口：\n${_windowDump()}\n',
          mode: FileMode.append, flush: true);
    } on Object {
      // 日志写不进去绝不能影响"打开"这件事本身
    }
  }

  /// 打开第 [rowIdx] 本书的详情页 —— **把快照里的地址原样交给系统**。
  ///
  /// ★★ 第 25 轮按用户要求大幅简化（原话："直接把链接放入就行了，不要搞别的"）。
  ///   之前这里叠了两条"聪明"的路，实测都是坑，而且**都在用户想看的那一页
  ///   前面加了东西** —— 这正是"无法正确跳转"的来源：
  ///     · **窄窗启动页**：起点 m 站会检测 `outerWidth > 1024` 并回跳 www 站
  ///       （www 站命中 WAF），于是生成了一个本地 HTML、用 760px 弹窗去开 m 站。
  ///       但 `file://` 页面上的 `window.open` 基本必被 Chromium 弹窗拦截，
  ///       用户看到的就是**一张空白本地页**。
  ///     · **隔离实例**：为了绕开"用户 Edge 以管理员身份常驻"的 UIPI 冲突，
  ///       用 `--user-data-dir=<私有目录>` 起了一个**全新 profile** 的 Edge ——
  ///       全新 profile 会走 Edge 的**首次运行流程**（欢迎页/导入数据），
  ///       用户看到的仍然不是书籍详情页。
  ///   现在只剩一条路：**`ShellExecuteW` 直接交给系统默认浏览器**
  ///   （用户自己的 profile、自己的登录态、自己的窗口），
  ///   失败再走 cmd 的 `start`（另一套关联解析）。就这样，不再有别的。
  ///
  /// 三件事仍然要做，少一件都会让用户觉得"点了没反应"：
  ///   ① **真的打开**；② **看得见** —— 窗口里弹一条盖在最上一层的提示条
  ///   （状态栏会被浏览器挡住）；③ **留证据** —— 写 `out/扫榜/_open_log.txt`，
  ///   含返回码与走了哪条路（"用户说不行、我这边验通"这类问题只能靠这个定位）。
  Future<void> openBookLink(int rowIdx) async {
    // ★ 打开前先**读令牌**确认浏览器权限（这是硬证据，不是猜）：
    //   真提权就写进日志，免得下次还要来回问"到底是不是管理员身份"。
    final browserElevated = browserIsElevated();
    if (browserElevated) {
      _logOpen('(前置)', rowIdx < detailLinks.length ? (detailLinks[rowIdx] ?? '') : '',
          0, '读令牌确认：浏览器是管理员身份运行（本工具${selfIsElevated() ? "也是" : "不是"}）');
    }

    final raw = detailLinks[rowIdx];
    final m = currentMeta();
    final title = (m != null && rowIdx < m.result.entries.length)
        ? boardColText(BoardCol.title, m.result.entries[rowIdx])
        : '这本书';
    if (raw == null || raw.isEmpty) {
      statusText = '这一行没有可打开的书链接（快照里没抓到 url）';
      _toast('这一行没有可打开的书链接（快照里没抓到 url）');
      _logOpen(title, '-', 0, '没有 url');
      return;
    }

    // ★★ 出站前**必须**过协议白名单（安全审查，2026-10-02）：
    //   这个地址会被交给 `ShellExecuteW`，而那是"按 shell 关联执行"——
    //   `file:///C:/…/calc.exe` 或裸路径会被真的运行起来。
    //   快照里的 url 来自第三方页面，不能当可信输入。
    final url = safeExternalUrl(raw);
    if (url == null) {
      statusText = '这一行的链接不是 http/https，为安全起见不打开：$raw';
      _toast('这一行的链接不是网页地址，为安全起见没有打开\n$raw', ms: 9000);
      _logOpen(title, raw, 0, '协议不在白名单，拒绝打开');
      return;
    }

    var rc = 0;
    // ★★ 不要在这里就写剪贴板（深度审查发现）：那样"打开成功"也会把用户
    //   剪贴板里的东西冲掉。复制地址只是**失败时的兜底**，
    //   所以推迟到"确实需要它"的时候再写 —— 见下面各失败分支。
    var copied = false;
    bool copyForFallback() => copied = writeClipboardText(url);
    final ok = openExternal(url, owner: hwnd, detail: (r) => rc = r);
    if (ok) {
      // ★★ 「返回码说成功」≠「用户真的看见了」。
      //   用户原话："**这个就是误导你出错的原因**" —— 程序一直报"已打开"，
      //   而 `ShellExecuteW` 返回 >32 只代表"请求交给系统了"。实际情况是：
      //     · Edge 冷启动要好几秒（实测点完 1.5s 才出现窗口）；
      //     · 用户的 Edge 有多个配置（窗口标题里写着"用户配置 1"），
      //       新窗口可能开在**另一个配置的窗口里、而且不在最前面**。
      //   所以这里**真的去找那个浏览器窗口**：找到就置前；找不到就如实说，
      //   而不是继续报"已在浏览器打开"。
      statusText = '已打开详情页：$url';
      _toast('正在打开浏览器…\n$url', ms: 2000);
      final (bw, loaded) = await _waitForBrowserWindow(
          timeout: const Duration(seconds: 6), url: url, bookTitle: title);
      if (loaded) {
        bringWindowToFront(bw);
        statusText = '已打开详情页：$url';
        _toast('已在浏览器打开：$title\n$url');
        _logOpen(title, url, rc,
            'ShellExecuteW 成功；页面已加载，窗口已置前\n    '
            '浏览器窗口标题：${_browserTitle(bw)}');
        return;
      }
      // ★★ 撞上"Edge 以管理员身份运行"的提权冲突时：
      //   这是用户机器上实测的根因 —— 系统弹了
      //   「Microsoft Edge 未响应，因为现有实例正在以提升的权限运行。
      //     是否要用普通权限重启现有实例？」→ 用户点了「否」→ 页面永不出现。
      //
      // ★ 这里原本还有一条"用 `runas` 把浏览器按提升权限起起来"的路
      //   （两边同级就不撞 UIPI）—— **去掉了**：它会弹一个 UAC 确认框，
      //   而用户明确说过"弹窗太多了"。而且上面已经会**替用户点掉 Edge 那个框**
      //   （点完 Edge 就用普通权限重启，页面随即能打开），再叠 UAC 是负收益。
      if (browserElevationBlocked) {
        statusText = 'Edge 以管理员身份运行，系统拦下了这次打开（已替你点「是」，仍没成功）';
        _logOpen(title, url, rc,
            '撞上提权实例冲突对话框（Edge 以管理员身份运行）；已替用户点「是」，'
            '页面仍未打开');
        copyForFallback();
        _toast('Edge 弹了一个「现有实例正在以提升的权限运行」的框，页面没能打开。\n\n'
            '请在**那个框**里点「是(Y)」（= 让 Edge 用普通权限重启），\n'
            '然后再点一次「打开」。\n\n'
            '★ 也先看一眼：页面有时会开在**另一个 Edge 窗口**里 ——\n'
            '你的 Edge 开着多个窗口时，新页面不一定会出现在最前面。\n\n'
            '地址已复制到剪贴板：\n$url',
            ms: 24000);
        // ★ 这里**故意不弹模态框**（原来叠了一个系统 MessageBox，
        //   和上面的提示条说的是同一件事 —— 用户反馈"弹窗太多了"）。
        //   本项目自己的原则就是"主流程里不许有模态对话框"；
        //   提示条已经把三个办法写全了。
        elevationAlreadyTold = true; // 本次运行不再重试
        return;
      }

      // ── 第二条路：**直接起注册表里那个浏览器 exe**（绕开 shell 关联）──
      //
      // ★ 为什么要多这一条：用户机器上实测 `ShellExecuteW` **把 URL 弄丢了**
      //   （Edge 起来了却停在"新建标签页"，地址栏是空的）。shell 关联那一环
      //   出了问题，那就别经过它 —— 直接 CreateProcess 默认浏览器 exe，
      //   把地址当参数给它。仍然只起**系统默认浏览器**，不是自己挑。
      final okDirect = launchBrowserDirect(url);
      final (bw1, loaded1) = okDirect
          ? await _waitForBrowserWindow(
              timeout: const Duration(seconds: 6), url: url, bookTitle: title)
          : (0, false);
      if (loaded1) {
        bringWindowToFront(bw1);
        statusText = '已打开详情页：$url';
        _toast('已在浏览器打开：$title\n$url');
        _logOpen(title, url, rc,
            'ShellExecuteW 没加载成功；直接起浏览器 exe 成功\n    '
            '浏览器窗口标题：${_browserTitle(bw1)}');
        return;
      }

      // ── 第三条路：强制**开新窗口**（`--new-window`）──
      //
      // ★ 为什么要它：用户机器上 Edge **在后台跑着但不开窗**（日志里只有
      //   `EdgeUiInputTopWndClass` 这类辅助窗口，没有任何顶层窗口）——
      //   URL 交给那个后台实例后被吞了。`--new-window` 是唯一还能试的招。
      final okNew = launchBrowserDirect(url, forceNewWindow: true);
      final (bwN, loadedN) = okNew
          ? await _waitForBrowserWindow(
              timeout: const Duration(seconds: 9), url: url, bookTitle: title)
          : (0, false);
      if (loadedN) {
        bringWindowToFront(bwN);
        statusText = '已打开详情页：$url';
        _toast('已在浏览器打开：$title\n$url');
        _logOpen(title, url, rc,
            '前两条没成功；--new-window 强制新窗口成功\n    '
            '浏览器窗口标题：${_browserTitle(bwN)}');
        return;
      }

      // ── 第四条路：cmd 的 `start`（又一套关联解析）──
      final okAlt = await openExternalFallback(url);
      final (bw2, loaded2) = okAlt
          ? await _waitForBrowserWindow(
              timeout: const Duration(seconds: 10), url: url, bookTitle: title)
          : (0, false);
      if (loaded2) {
        bringWindowToFront(bw2);
        statusText = '已打开详情页：$url';
        _toast('已在浏览器打开：$title\n$url');
        _logOpen(title, url, rc,
            '前两条都没加载成功；cmd start 后成功\n    '
            '浏览器窗口标题：${_browserTitle(bw2)}');
        return;
      }
      // ★ 两条路都没成功 —— 这时才把地址放进剪贴板（兜底）
      final copiedNow = copied || copyForFallback();
      // ★ 两条路都没成功 —— 如实说，**不再报"已在浏览器打开"**。

      final stuck = bw2 != 0
          ? bw2
          : (bwN != 0 ? bwN : (bw1 != 0 ? bw1 : bw));
      statusText = stuck != 0
          ? '浏览器起来了，但页面没打开（停在空白页）'
          : '已把地址交给系统，但没能确认浏览器窗口出现（$rc）';
      _logOpen(title, url, rc,
          '四条路都没能确认页面加载；地址已复制=$copiedNow\n    '
          '浏览器窗口标题：${_browserTitle(stuck)}');
      _toast(stuck != 0
          ? '没能确认到页面标题。★ 最可能的情况：\n'
              '页面开在了你**另一个 Edge 窗口（或后台标签）**里 ——\n'
              '你的 Edge 开着多个窗口时，新页面不一定会出现在最前面。\n'
              '先看看任务栏有没有 Edge 在闪，或按 Alt+Tab 找一下。\n\n'
              '确实没有的话，再试：把 Edge 完全退出（含托盘图标）后重新点「打开」；\n'
              '或在 Edge 设置里关掉「启动增强 / 后台继续运行」。\n\n'
              '地址已复制到剪贴板：\n$url'
          : '已经把地址交给系统浏览器，但没能确认窗口出现。\n'
              '★ 先看看任务栏有没有 Edge 在闪（可能开在别的窗口里）。\n'
              '${copiedNow ? "地址已复制到剪贴板，可以直接粘贴打开。" : ""}\n$url',
          ms: 14000);
      return;
    }

    // 兜底：cmd 的 `start` 走的是另一套关联解析
    final ok2 = await openExternalFallback(url);
    if (ok2) {
      final (bw, loaded) =
          await _waitForBrowserWindow(url: url, bookTitle: title);
      if (bw != 0) bringWindowToFront(bw);
      statusText = loaded ? '已打开详情页（走兜底路径）：$url' : '浏览器起来了，但页面没打开（停在空白页）';
      _toast(loaded
          ? '已在浏览器打开：$title\n$url'
          : '浏览器起来了，但页面没打开。地址已复制到剪贴板。\n$url', ms: 10000);
      _logOpen(title, url, rc,
          'ShellExecuteW 返回 $rc，cmd start 兜底；loaded=$loaded\n    '
          '浏览器窗口标题：${_browserTitle(bw)}');
      return;
    }

    statusText = copied
        ? '浏览器未能自动打开，地址已复制到剪贴板（$rc）'
        : '打不开浏览器（系统返回 $rc）：$url';
    _logOpen(title, url, rc, '两条路都失败；剪贴板=${copied ? "已复制" : "复制失败"}');
    _toast('浏览器未能自动打开\n$url\n${copied ? "地址已复制到剪贴板，请手动粘贴到浏览器地址栏" : ""}', ms: 12000);
    infoDialog(hwnd, '请手动打开',
        '${copied ? "浏览器未能自动打开，但地址已复制到剪贴板。\n\n打开浏览器（Edge），按 Ctrl+V 粘贴即可访问：\n\n" : "请手动复制下面的地址，粘进浏览器访问：\n\n"}$url');
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

    series = buildSeriesView(
      allSeriesEntries: allEntries,
      results: selectedResults,
      range: seriesRange,
    );
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

    void cardRow(List<(String, String, int)> items) {
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
    cardRow([
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
    cardRow([
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
    final profiles = _crossProfiles();

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
      g.text('口径：全部快照里的上榜条目累计（同一本书多期上榜会重复计入）；'
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
    final cross = _crossBooks();
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

  /// 临时提示条：屏幕下方居中，深色卡片 + 白字，几秒后自己消失。
  void _paintToast(Gdi g) {
    final msg = toastText;
    if (msg == null) return;
    final u = Metrics.factor;
    final lines = msg.split('\n');
    final padx = (18 * u).round();
    final pady = (12 * u).round();
    final fs = Metrics.fontSize;
    final lineH = (fs + 8 * u).round();
    var textW = 0;
    for (final l in lines) {
      final w = g.measure(l, size: fs);
      if (w > textW) textW = w;
    }
    final w = textW + padx * 2;
    final h = lines.length * lineH + pady * 2;
    final r = Rc.xywh(((width - w) / 2).round(),
        (height - Metrics.statusHeight - h - (24 * u).round()).round(), w, h);
    // 投影 + 卡片：与其它浮层同一套视觉
    g.roundFill(r.inset(-1, -1), Palette.shadow, Palette.shadow,
        radius: Metrics.radius + 1);
    g.roundFill(r, Palette.surfaceHigh, Palette.accent, radius: Metrics.radius);
    for (var i = 0; i < lines.length; i++) {
      g.text(lines[i],
          Rc.xywh(r.left + padx, r.top + pady + i * lineH,
              r.width - padx * 2, lineH),
          i == 0 ? Palette.fg : Palette.fgDim,
          size: fs, bold: i == 0, vcenter: true, ellipsis: true);
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

  // ★ 这里原本有一份**手写的泰勒展开** cos/sin（`_taylorCos`）。
  //   2026-10-02 安全/质量审查时删掉，直接用 `dart:math`：
  //     · 原注释写"不引 dart:math 太浪费"——可它是 **SDK 核心库**，零依赖零成本，
  //       而且 `lib/ui/chart.dart` 早就 import 了它；
  //     · 同一份实现还被抄到了 `widgets.dart`（两份不一致的风险）；
  //     · 那份实现要先 while 循环归一化角度再展开 6 阶，比 `math.cos` 又慢又不准。
  static double _cos(double a) => math.cos(a);
  static double _sin(double a) => math.sin(a);

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
      // ★ 与 visible 口径一致：被隐藏的系列不能因为 selectedId 还指着它
      //   就继续出现在右侧（隐藏 = 界面不显示）。
      if (m.id == id && !vm!.isHidden(m)) return m;
    }
    return null;
  }

  @override
  bool onClick(int x, int y) {
    // ★★ 浮层优先：只要有打开的菜单，这一次点击就先交给菜单处理。
    //   - 点在菜单项/菜单框内：执行或吞掉（_handleMenuClick 负责）；
    //   - 点在菜单外：只关闭菜单并消费这次点击，**不能**再触发下层动作。
    //   否则点侧栏/标签页会带着菜单一起执行，上层看起来"穿透"了。
    if (openMenu.isNotEmpty && _handleMenuClick(x, y)) return true;

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
          curTab = i;
          _startTabAnim(); // 轻微滑入过渡，让切换"有分量"
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
    final profiles = _crossProfiles();
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

    // 明细表竖向滚动条：必须排在书籍链接之前，否则点滚动条会触发 openBookLink。
    final vt = hitRects[idDetailVScroll];
    if (vt != null && vt.contains(x, y)) {
      final area = detailTableArea;
      if (area != null) {
        final maxV = _maxScroll(area, idDetailTable);
        final viewH = area.height - Metrics.detailHeaderHeightAt(detailS);
        final page = (viewH ~/ 2).clamp(1, 1 << 20);
        final up = y < vt.top + vt.height ~/ 2;
        detailScroll = (detailScroll + (up ? -page : page)).clamp(0, maxV);
        invalidate();
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
        // 打开是异步的（失败要走兜底 + 弹框），这里不 await：
        // 点击处理必须立刻返回，否则消息循环会被"等浏览器"卡住。
        unawaited(openBookLink(i));
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
      n = _crossBooks().length;
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

  /// 跨榜书单 / 平台画像缓存（同一份 vm 只聚合一次）。
  List<CrossBoardBook> _crossBooks() {
    if (!identical(_crossCacheVm, vm) || _crossBooksCache == null) {
      _crossCacheVm = vm;
      _crossBooksCache = vm?.crossBoardBooks() ?? const [];
      _crossProfilesCache = buildPlatformProfiles(vm?.bySource ?? const {});
    }
    return _crossBooksCache!;
  }

  List<PlatformCategoryProfile> _crossProfiles() {
    _crossBooks();
    return _crossProfilesCache ?? const [];
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
    // ★ 折线图 / 逐期表 / 跨榜表整块共用一个 hot id，指针在块内移动时
    //   `newHot == hotId` 成立，但它们的 hover（准星、行高亮）是按
    //   mouseX/mouseY 现画的 —— 不重绘就会停在进入点。这几块必须按移动重绘。
    final repaintOnMove = newHot == idDiffTable ||
        newHot == idSeriesTable ||
        newHot == idCrossTable;
    if (newHot == hotId && newWinBtn == _winBtnHot && !repaintOnMove) return;
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

  /// 只有 idDetailTable 是"容器"：它的行/按钮都有子命中区，
  /// 先命中容器会吞掉子控件的 hover。
  ///
  /// 折线图 / 逐期表 / 跨榜表没有子命中区，而且自身就靠 mouseX/mouseY
  /// 画 hover（准星、行高亮）—— 必须作为具体 hot id 返回，onMove 才会重绘。
  static bool _isContainerId(int id) => id == idDetailTable;

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
    // 明细缓存里烘了旧 Palette 的颜色，必须随主题一起失效。
    _invalidateDetailCache();
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
      // ★ 与 reload 同口径：先清旧错误，避免同一批坏文件被反复追加。
      loadErrors.clear();
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

  /// 把已开着的子窗带到最前；最小化时先还原再激活。
  ///
  /// ★ SetForegroundWindow 不会 restore 最小化窗口（实测点了像没反应），
  ///   所以必须先判 IsIconic，再决定要不要 SW_RESTORE。
  void _bringChildToFront(int childHwnd) {
    if (childHwnd == 0) return;
    if (isIconic(childHwnd) != 0) showWindow(childHwnd, swRestore);
    setForegroundWindow(childHwnd);
  }

  void openDataManager() {
    if (vm == null) reload();
    if (dataManager != null && !dataManager!.isDisposed) {
      // 已经开着 → 把它带到前面（重新 setFocus 即可）
      _bringChildToFront(dataManager!.hwnd);
      return;
    }
    final app = App.instance;
    if (app == null) return;
    final w = DataManagerWindow(owner: this);
    dataManager = w;
    // 尺寸语义：这里传**设计尺寸**，物理尺寸由 App._create 统一按
    // Metrics.factor（含 DPI）换算，调用方不要再乘一次。
    app.runChild(w, width: 1000, height: 640, ownerHwnd: hwnd);
  }

  // ── 数据加载 ──

  void reload() {
    loadErrors.clear();
    vm = ViewModel.load(outRoot,
        errors: loadErrors, hidden: settings.hiddenSeries);
    // ★ 磁盘数据变了，之前缓存的快照内容、时间线、附件清单全部失效。
    _attachCacheKey = null; // 附件清单（导入了新图之后必须重读）
    _attachmentsById = const {};
    _invalidateDetailCache();
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
    if (vis.isEmpty) {
      // ★ 全部隐藏/全部被剪掉：右侧必须跟着空，不能停在被隐藏的那一份上。
      selectedId = 0;
    } else if (!_isVisibleSelection(selectedId)) {
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
      // ★ 顺手缓存附件清单：明细页绘制时不用再同步读一遍索引。
      _attachmentsById = {for (final e in idx.entries) e.id: e.attachments};
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
      _bringChildToFront(c.hwnd);
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

    try {
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
    } finally {
      // ★ 无论正常还是异常，都要退出正在扫榜状态，否则按钮永久禁用、
      //   60ms 转圈定时器常驻。
      phase = ScanPhase.done;
      _progressTimer?.cancel();
      _progressTimer = null;
      invalidate();
    }
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

  /// 默认导出目录（`out/导出`）。
  ///
  /// ★ 它现在只承担**一个**角色：文件夹选择框**第一次**打开时的起点
  ///   （以及"从没导出过"时的兜底）。**不是**导出的落点 ——
  ///   落点永远由用户在对话框里当场决定。
  String get _defaultExportDir {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final local = '$exeDir${_sep}导出';
    try {
      Directory(local).createSync(recursive: true);
      return local;
    } on Object {
    }
    return '$outRoot${_sep}导出';
  }

  /// 文件夹选择框的**初始位置**。
  ///
  /// ★ 优先用"上次导出选过的目录"，没有就用默认的 `out/导出`。
  ///   一定要先确认目录能用：用户上次选的可能是 U 盘 / 网络盘，
  ///   拔了之后 `SHBrowseForFolderW` 会停在一个不存在的位置（表现为
  ///   对话框打开就报错或停在"桌面"）—— 不如干脆回退到默认目录。
  /// **导出落点**：用户在菜单里设过的目录，没设过就用默认的 `out\导出`。
  ///
  /// ★ 目录不存在就建；建不出来（盘符没了 / 没权限）**如实退回默认目录**
  ///   并在状态栏说明 —— 绝不把"写不进去的路径"交给导出逻辑，
  ///   那会让报错出现在离用户操作很远的地方。
  String get exportDialogStartDir {
    final want = settings.exportDir;
    if (want != null && want.trim().isNotEmpty) {
      try {
        Directory(want).createSync(recursive: true);
        return want;
      } on Object {
      }
    }
    return _defaultExportDir;
  }

  /// 弹一次文件夹选择框，把结果记成**导出落点**。
  ///
  /// ★★ 只在「设置导出位置…」里调用 —— **导出本身不再弹框**（第 25 轮）。
  ///   第 21 轮曾把"每次导出都弹框选目录"当成唯一语义（当时的用户原话是
  ///   "点击导出 → 选中格式 → 弹出选择文件夹"）；但实测下来那条路
  ///   **根本不可用**：每导出一次要点三次对话框，而"选目录"这一步
  ///   只要弹不出来 / 弹到主窗后面 / 选到不可写的盘，表现就是"导出没反应"。
  ///   所以现在改成"直接导到固定落点 + 菜单里可改"，这里只负责"改"。
  ///
  /// ★ 取消（点"取消"关掉对话框）返回 null，调用方**必须直接中止**，
  ///   并如实说"已取消" —— 绝不悄悄落到默认目录。
  String? askExportDir({String? title}) {
    final picked = pickFolderDialog(hwnd,
        title: title ?? '选择导出到的文件夹',
        initialDir: exportDialogStartDir);
    if (picked == null) return null;
    if (picked != settings.exportDir) {
      settings.exportDir = picked;
      saveSettings();
    }
    return picked;
  }

  /// 导出前统一入口：**直接给出落点，不弹任何框**。
  ///
  /// ★★ 第 25 轮重做的核心就是这一行。原方案"每次导出都弹文件夹选择框"
  ///   被用户判定为**根本不可用**：每导出一次要点三次对话框
  ///   （选目录 → 完成提示 → 打开目录），而"选目录"这一步只要
  ///   弹不出来 / 弹到主窗后面 / 选到不可写的盘，表现就是"导出没反应"。
  ///   现在：**点菜单项 → 直接出文件 → 一个完成提示**。
  ///   要换地方就点菜单里的「设置导出位置…」（弹一次框，记住）。
  String? _beginExport({String? what}) {
    if (!settings.askExportDir) return exportDialogStartDir;
    final picked = askExportDir(
        title: what == null ? '选择导出到的文件夹' : '选择「$what」导出到的文件夹');
    if (picked == null) {
      // ★ 取消 = 本次不导出。绝不悄悄落到默认目录 ——
      //   那等于"用户点了取消、东西还是被写到了别处"，最恼人的一类行为。
      statusText = '已取消${what == null ? '导出' : '导出$what'}（没有选文件夹）';
      lastMessage = '没有选择目标文件夹，本次未导出任何文件。';
      invalidate();
      return null;
    }
    return picked;
  }

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
      case menuExportXlsx:
        _exportXlsx();
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
      case menuAskExportDir:
        settings.askExportDir = !settings.askExportDir;
        saveSettings();
        statusText = settings.askExportDir
            ? '已打开：每次导出前先问文件夹'
            : '已关闭：导出直接落到 ${_shortDirLabel(exportDialogStartDir)}';
        invalidate();
      case menuChooseExportDir:
        _chooseExportDir();
      case menuChooseImportDir:
        _chooseImportDir();
    }
  }

  /// 「设置导出位置…」：弹一次框，把结果记成导出落点。
  ///
  /// ★ 这是**唯一**会弹文件夹框的地方（导出本身不再弹）。
  void _chooseExportDir() {
    final picked = askExportDir(title: '选择导出到的文件夹');
    if (picked == null) {
      statusText = '已取消设置导出位置';
      invalidate();
      return;
    }
    statusText = '导出位置已设为：$picked';
    invalidate();
    infoDialog(hwnd, '导出位置已更新',
        '以后点「导出」里的任何一项，文件都会直接存到这个目录（不再每次都问）：\n\n$picked');
  }

  /// 「设置图片的起始目录」：决定"导入图片"对话框默认从哪打开。
  void _chooseImportDir() {
    final picked = pickFolderDialog(hwnd,
        title: '选择导入图片时的起始目录', initialDir: settings.importDir ?? Directory.current.path);
    if (picked == null) {
      statusText = '已取消设置导入起始目录';
      invalidate();
      return;
    }
    settings.importDir = picked;
    saveSettings();
    statusText = '导入起始目录已设为：$picked';
    invalidate();
    infoDialog(hwnd, '导入起始目录已更新',
        '以后点「图片 → 存为该快照的附件」时，会从这个目录开始找：\n\n$picked');
  }

  /// 导出成功后**统一走这里**：状态栏 + 明确的信息框。
  ///
  /// ★ 用户原话："导出时没有提示"。根因是导出完会 `openExternal(dir)`
  ///   把导出目录弹到前台 —— **那个窗口抢走了注意力**，应用自己的状态栏
  ///   写了什么根本没人看见。所以必须弹一个模态框把结果说清楚。
  ///
  /// 弹框放在 `openExternal` **之前**：先让用户看到"导出到哪了"，
  /// 再让资源管理器跳出来。反过来的话框会被压在后面。
  /// [movedWhy] 非空 = 没写进用户设的那个目录，退回默认目录了 ——
  /// 这时**必须把话说明白**：悄悄换个地方存，用户会以为"导出又失败了"。
  void _reportExport(String what, String path, String detail,
      {String? movedWhy}) {
    statusText = '已导出$what：$path';
    lastMessage = detail;
    invalidate();
    infoDialog(
        hwnd,
        movedWhy == null ? '导出完成' : '导出完成（换了存放位置）',
        '已导出$what\n\n$path\n$detail\n'
        '${movedWhy == null ? '' : '\n⚠ $movedWhy\n'
            '（多半是那个目录里有文件正被杀软/看图软件占着，稍后可再导一次）\n'}'
        '\n点「确定」后会自动打开导出目录。');
  }

  /// 导出 **xlsx**（Excel 原生格式）。
  ///
  /// 三张表，各回答一个问题：
  ///   ① 「榜单明细」—— 这份榜里有什么（列与界面**同源**：`boardCols`）；
  ///   ② 「指标口径」—— 那些数字分别是什么意思（跨平台比之前必须先看这个）；
  ///   ③ 「榜单信息」—— 这份数据是什么时候、从哪抓的，质量如何。
  ///
  /// ★ 为什么不是"把 CSV 改个后缀"：xlsx 的字符串走 `inlineStr`，
  ///   **结构上不可能是公式**；而 CSV 只能靠"前置单引号"这种内容层面的补丁。
  ///   多张表也是 CSV 表达不了的。
  void _exportXlsx() {
    final m = currentMeta();
    if (m == null) {
      statusText = '先选一份快照再导出';
      invalidate();
      return;
    }
    final dir = _beginExport(what: 'Excel');
    if (dir == null) return;
    try {
      final bytes = _xlsxBytesFor(m);
      final r = saveBytes(dir, _defaultExportDir, _exportBase(m), 'xlsx', bytes);
      _reportExport(
        'Excel 表格',
        r.path,
        '3 张表（明细 ${m.count} 行 / 指标口径 / 榜单信息），'
        '${(bytes.length / 1024).round()} KB',
        movedWhy: r.movedWhy,
      );
      openExternal(r.dir);
    } on Object catch (e) {
      statusText = '导出 Excel 失败：$e';
      invalidate();
      infoDialog(hwnd, '导出 Excel 失败', '生成 xlsx 时出错：\n\n$e');
    }
  }

  /// 自检：按菜单那条路生成 xlsx 并落盘（**不弹完成框**），返回落盘路径。
  ///
  /// ★ 与 `_exportXlsx` 共用 [_xlsxBytesFor] —— 不复制一份"造表"的逻辑，
  ///   否则测过的那份和真跑的那份迟早会分叉。
  String? testExportXlsxTo(String dir) {
    final m = currentMeta();
    if (m == null) return null;
    try {
      return saveBytes(dir, dir, _exportBase(m), 'xlsx', _xlsxBytesFor(m)).path;
    } on Object catch (e) {
      statusText = '导出 Excel 失败：$e';
      return null;
    }
  }

  /// 生成这份快照的 xlsx 字节（纯函数：不碰磁盘、不弹框）。
  Uint8List _xlsxBytesFor(SnapshotMeta m) {
    {
      // ── 表① 明细：列与界面「榜单明细」同源（去掉封面列 —— 表里放不了图）──
      final cols = [
        for (final c in boardCols)
          if (c != BoardCol.cover) c,
      ];
      final detail = <List<Object?>>[
        [for (final c in cols) boardColTitle(c)],
        for (final e in m.result.entries)
          [for (final c in cols) boardColText(c, e, source: m.source)],
      ];

      // ── 表② 指标口径：把这份榜里出现过的指标名与含义列出来 ──
      final keys = <String>{};
      for (final e in m.result.entries) {
        keys.addAll(e.metrics.keys);
      }
      final ordered = keys.toList()
        ..sort((a, b) {
          if (a == 'words') return 1;
          if (b == 'words') return -1;
          return a.compareTo(b);
        });
      // ★ 这里**不编**"单位/说明"列 —— 项目里没有那张表，
      //   而标签本身已经带了语义（如「字数（体量，不是热度）」）。
      //   比"编一列看着专业的说明"更重要的，是把**跨平台不可比**写在明面上。
      final legend = <List<Object?>>[
        ['指标（内部键）', '显示名'],
        for (final k in ordered) [k, metricLabelFor(k, source: m.source)],
        const <Object?>[],
        ['注意', metricsWarning],
      ];

      // ── 表③ 榜单信息：数据来路与质量 ──
      final info = <List<Object?>>[
        ['项目', '值'],
        ['平台', sourceName(m.source)],
        ['榜单', m.board],
        ['题材', m.category ?? '（未细分）'],
        ['日期', m.dateKey],
        ['条数', m.count],
        ['抓取时间', m.fetchedAt.toIso8601String()],
        ['来源页', m.result.sourceUrl ?? '（无）'],
        ['robots 判定', m.result.robotsVerdict ?? '（未记录）'],
        ['质量摘要', m.result.quality?.summary ?? '（无）'],
        ['生成工具', '网文扫榜工具'],
      ];

      return buildXlsx([
        XlsxSheet('榜单明细', detail),
        XlsxSheet('指标口径', legend),
        XlsxSheet('榜单信息', info),
      ]);
    }
  }

  void _exportOne(String ext, String Function(SnapshotMeta) render) {
    final m = currentMeta();
    if (m == null) {
      statusText = '先选一份快照再导出';
      invalidate();
      return;
    }
    // ★ 先问"导到哪"（用户要求的流程：选格式 → 选文件夹 → 导出）。
    //   取消就整件事作罢，不落到默认目录。
    final dir = _beginExport(what: ext.toUpperCase());
    if (dir == null) return;
    try {
      final r = exportToDetailed(
          dir, _defaultExportDir, _exportBase(m), ext, render(m));
      _reportExport(ext.toUpperCase(), r.path,
          '${sourceName(m.source)} · ${m.board} · ${m.count} 条',
          movedWhy: r.movedWhy);
      openExternal(r.dir);
    } on Object catch (e) {
      statusText = '导出失败：$e';
      invalidate();
      infoDialog(hwnd, '导出失败', '写文件时出错：\n\n$e');
    }
    invalidate();
  }

  void _exportBundle() {
    if (vm == null) return;
    final dir = _beginExport(what: '全部快照汇总');
    if (dir == null) return;
    try {
      // ★ 全量导出必须带上**真正的**概览与对比。
      //   旧代码传的是两个字面量 `const {}`，于是磁盘上的
      //   `全部快照_*.json` 里 `overview={} comparisons={}`，
      //   而状态栏还写着"CSV / JSON / 全量"——用户以为拿到了全套分析。
      final index = SnapshotIndex.fromItems(vm!.all);
      final now = DateTime.now();
      final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      final r = exportToDetailed(
        dir,
        _defaultExportDir,
        '全部快照_$stamp',
        'json',
        bundleToJson(vm!.all, overview(index), comparisonsByPair(index)),
      );
      _reportExport('${vm!.all.length} 份快照汇总', r.path, '含概览与两两对比',
          movedWhy: r.movedWhy);
      openExternal(r.dir);
    } on Object catch (e) {
      statusText = '导出失败：$e';
      invalidate();
      infoDialog(hwnd, '导出失败', '写文件时出错：\n\n$e');
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
    // ★ 问目录放在**备齐封面之前**：备封面要联网、最多等 10 秒，
    //   用户如果只是想取消，不该让他先等十秒再取消。
    final dir = _beginExport(what: '榜单图');
    if (dir == null) return;
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
        // ★ 不写死画布宽：默认按缩放推（980 × factor），否则 150% 下书名会被压扁
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
      final r = saveImageDetailed(
          dir, _defaultExportDir, '榜单_${_exportBase(m)}', img);
        var detail =
          '${img.width}x${img.height}，${(img.pngBytes / 1024).round()} KB，共 ${m.count} 条';
      if (store != null) {
        detail += '\n封面：已取 ${store.fetched} 张 / 失败 ${store.failed} 张'
            '${waited > 0 ? '（等了 ${(waited / 1000).toStringAsFixed(1)} 秒）' : ''}';
      }
      _reportExport('榜单图', r.path, detail, movedWhy: r.movedWhy);
      openExternal(r.dir);
    } on Object catch (e) {
      statusText = '导出榜单图失败：$e';
      invalidate();
      infoDialog(hwnd, '导出榜单图失败', '写图片时出错：\n\n$e');
    }
    invalidate();
  }

  /// 导出「当前系列的趋势图」为 PNG。
  void _exportTrendImage() {
    final m = currentMeta();
    if (m == null) return;
    final dir = _beginExport(what: '趋势图');
    if (dir == null) return;
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
      final r = saveImageDetailed(
          dir, _defaultExportDir, '趋势_${_exportBase(m)}', img);
      _reportExport('趋势图', r.path,
          '${img.width}x${img.height}，${ts.periodCount} 期（${ts.rangeLabel}）',
          movedWhy: r.movedWhy);
      openExternal(r.dir);
    } on Object catch (e) {
      statusText = '导出趋势图失败：$e';
      invalidate();
      infoDialog(hwnd, '导出趋势图失败', '写图片时出错：\n\n$e');
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
    // ★ 优先用 _syncIndex 载入的清单：绘制路径里不再同步读一遍 index.json。
    final preloaded = _attachmentsById[key];
    if (preloaded != null) {
      _attachCache = preloaded;
      return _attachCache;
    }
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
    // ★ 先问目录（用户要求的流程），取消就作罢。
    final baseDir = _beginExport(what: '附件');
    if (baseDir == null) return;
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
      // 附件是一批文件，在用户选的目录下再开一个子目录，免得散落一地。
      final dir = '$baseDir${_sep}附件_${_exportBase(m)}';
      final r = idx.exportAttachments(entry, dir);
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
    // ★ 起始目录优先用用户设的 importDir（菜单里能改），没设过才退到工作目录。
    final src = openImageFileDialog(hwnd,
        title: '选择要存档为该快照附件的图片',
        initialDir: settings.importDir ?? Directory.current.path);
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

  /// 自检：窗口创建时的**设计尺寸**（逻辑值，未乘 factor）。
  ///
  /// ★ 用途是那条恒等式：`客户区 == 设计尺寸 × Metrics.factor`。
  ///   DPI 缩放漏了的话它立刻不成立 —— 见 `bin/main.dart` 的发布版自检。
  (int, int) get testDesignSize => (designW, designH);

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

/// `EnumWindows` 回调：把可见顶层窗口的（类名 / 标题）写进 [_dumpSink]。
///
/// ★ 必须是**顶层函数**：`Pointer.fromFunction` 只接受顶层或静态函数。
StringBuffer? _dumpSink;

int _dumpCb(int hwnd, int lparam) {
  final sink = _dumpSink;
  if (sink == null) return 1;
  if (isWindowVisible(hwnd) == 0) return 1;
  final (cls, title) = windowClassAndTitle(hwnd);
  if (cls.isEmpty && title.isEmpty) return 1;
  // ★ **进程名**这一列是诊断的关键：只写"类名 | 标题"的话，
  //   看到 `Chrome_WidgetWin_1 | WorkBuddy AI` 还得猜它属于谁；
  //   而"浏览器窗口到底有没有出现过"完全取决于进程名（msedge）。
  final proc = processNameOfWindow(hwnd);
  sink.writeln('    [$hwnd] ${proc.isEmpty ? "?" : proc} | $cls | $title');
  return 1;
}

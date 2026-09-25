/// 视觉主题 —— 颜色、字号、圆角、间距集中一处。
///
/// ★ 配色照搬数据页（`web/page_template.html` 的 :root），但在深色底上
///   做了一轮"现代化"：更低的对比度分级、更柔的描边、更大的圆角。
///   理由不是"好看"这种主观话 —— 而是**同一份数据在两个界面里必须长得一样**。
///
/// ★ 涨跌语义：网页里 `.up` 是**绿**、`.down` 是**红**（衡量"表现好坏"，
///   不是 A 股涨跌）。所以 新上榜/排名上升=绿，掉榜/下降=红。
library;

import 'win32.dart';

/// 主题档位。
enum AppTheme {
  dark('深色'),
  light('浅色');

  const AppTheme(this.label);
  final String label;

  AppTheme get toggled => this == dark ? light : dark;

  /// 存档用的短名（`ui.json` 里就写这个）。
  String get id => name;

  static AppTheme fromId(String? id) =>
      id == 'light' ? AppTheme.light : AppTheme.dark;
}

/// 语义色板 —— **两套**（深色 / 浅色），字段名完全一致。
///
/// ★ 为什么字段是可变静态量而不是 `final`：
///   全项目 300+ 处都写 `Palette.surface` 这种访问方式。改成
///   `theme.surface` 要动每一处，改动面大且容易漏；把"当前档位"藏在
///   [Palette] 里，调用点一行都不用改 —— 代价是**换主题必须整窗重绘**，
///   而这一条本来就成立（颜色变了不重绘等于没换）。
///
/// ★ 浅色不是"把深色反过来"这么简单，有三处必须单独设计：
///   ① **投影**：深色主题下投影要更深，浅色主题下投影只能是**淡灰蓝**
///      —— 浅色底上垫深黑会变成一圈脏边。
///   ② **主色**：深色底上的青（#58c4fa）在白底上对比度不足，浅色主题要用
///      更深一档的蓝（#0b7fd4）。
///   ③ **按钮文字**：`primary` 按钮的前景用的是 `Palette.bg` —— 深色主题下
///      是"深字压亮色块"，浅色主题下 bg 很浅，压在蓝底上仍然可读，这是
///      刻意让两者共用同一条规则的结果，不要去给按钮加"反色"分支。
class Palette {
  const Palette._();

  /// 当前档位（默认深色 —— 与历史版本一致，老用户不会突然被换掉）。
  static AppTheme _theme = AppTheme.dark;
  static AppTheme get theme => _theme;
  static bool get isDark => _theme == AppTheme.dark;

  // ── 当前生效的色值 ──
  //
  // 初始值 = 深色档（与历史版本逐色一致，所以"不调 apply 也不会有任何变化"）。
  static int bg = _dark.bg; // 最底：窗口底
  static int sidebar = _dark.sidebar; // 侧栏：比底亮一档
  static int surface = _dark.surface; // 卡片
  static int surfaceAlt = _dark.surfaceAlt; // 卡片内的次级面（表头/标题带）
  static int surfaceHigh = _dark.surfaceHigh; // hover / 选中态的面
  static int headerBg = _dark.headerBg; // 顶栏

  static int line = _dark.line;
  static int lineStrong = _dark.lineStrong;
  static int lineFaint = _dark.lineFaint; // 行分隔线，几乎看不见

  static int fg = _dark.fg; // 主文字
  static int fgSub = _dark.fgSub; // 次级
  static int fgDim = _dark.fgDim; // 弱化（说明文字）
  static int fgFaint = _dark.fgFaint; // 最弱（表头辅助）

  static int accent = _dark.accent; // 主色
  static int accentHover = _dark.accentHover;
  static int accentSoft = _dark.accentSoft; // 主色淡底
  static int accentGlow = _dark.accentGlow;

  static int ok = _dark.ok; // 绿
  static int warn = _dark.warn; // 橙
  static int bad = _dark.bad; // 红

  static int hover = _dark.hover;
  static int selected = _dark.selected;
  static int selectedBorder = _dark.selectedBorder;
  static int rowHover = _dark.rowHover;

  static int up = _dark.up;
  static int down = _dark.down;
  static int flat = _dark.flat;

  static int obfuscated = _dark.obfuscated;
  static int shadow = _dark.shadow; // 投影
  static int zebra = _dark.zebra; // 斑马纹
  static int scrollThumb = _dark.scrollThumb;
  static int scrollTrack = _dark.scrollTrack;
  static int dangerHover = _dark.dangerHover;

  static int winBtnHover = _dark.winBtnHover;
  static int winBtnActive = _dark.winBtnActive;
  static int winBtnGlyph = _dark.winBtnGlyph;
  static int winBtnGlyphHot = _dark.winBtnGlyphHot;
  static int closeHover = _dark.closeHover; // Windows 标准关闭红（两套共用）
  static int closeActive = _dark.closeActive;
  static int closeGlyph = _dark.closeGlyph;

  /// 非激活窗口的标题栏文字（失焦时整体压暗一档）。
  static int fgInactive = _dark.fgInactive;

  // ── 科幻感的"装饰"色（不参与语义，只用于强调元素）──
  //
  // ★ 这两条只在**装饰**上用：折叠箭头的发光、卡片左上角的角标线。
  //   它们不许承载信息 —— 颜色一旦承载信息就必须在浅色主题下也可辨，
  //   而装饰件不需要。
  static int glowLine = _dark.glowLine; // 极淡的主色描边（角标/网格）
  static int gridDot = _dark.gridDot; // 背景点阵（只当纹理）

  /// 深色档（**唯一来源**）。
  ///
  /// ★ 为什么要有这个结构：色值如果"声明处写一遍、apply 里再写一遍"，
  ///   两处必然漂移（改了 apply 忘了声明，或者反过来）。现在
  ///   字段声明与 [apply] 都从同一个 [_ColorSet] 取，改一处即可。
  static final _ColorSet _dark = _ColorSet(
    // 底与面（四档亮度，构成层次）
    bg: rgb(11, 13, 17),
    sidebar: rgb(15, 17, 22),
    surface: rgb(20, 23, 29),
    surfaceAlt: rgb(27, 31, 39),
    surfaceHigh: rgb(34, 39, 49),
    headerBg: rgb(15, 17, 22),
    // 线
    line: rgb(38, 43, 54),
    lineStrong: rgb(55, 62, 77),
    lineFaint: rgb(28, 32, 41),
    // 字
    fg: rgb(233, 236, 242),
    fgSub: rgb(163, 172, 188),
    fgDim: rgb(124, 134, 152),
    fgFaint: rgb(92, 101, 117),
    // 强调
    accent: rgb(88, 196, 250),
    accentHover: rgb(116, 210, 255),
    accentSoft: rgb(22, 42, 56),
    accentGlow: rgb(30, 58, 76),
    // 语义
    ok: rgb(74, 222, 145),
    warn: rgb(252, 186, 88),
    bad: rgb(255, 118, 118),
    // 交互
    hover: rgb(27, 32, 41),
    selected: rgb(26, 47, 62),
    selectedBorder: rgb(88, 196, 250),
    rowHover: rgb(24, 29, 37),
    up: rgb(74, 222, 145),
    down: rgb(255, 118, 118),
    flat: rgb(124, 134, 152),
    // 其它
    obfuscated: rgb(252, 186, 88),
    shadow: rgb(5, 6, 9), // 深色主题下投影只能更深
    zebra: rgb(17, 20, 25),
    scrollThumb: rgb(64, 73, 91),
    scrollTrack: rgb(20, 23, 29),
    dangerHover: rgb(255, 145, 145),
    winBtnHover: rgb(30, 35, 45),
    winBtnActive: rgb(38, 44, 56),
    winBtnGlyph: rgb(180, 189, 204),
    winBtnGlyphHot: rgb(240, 244, 250),
    closeHover: rgb(232, 17, 35),
    closeActive: rgb(208, 12, 30),
    closeGlyph: rgb(255, 255, 255),
    fgInactive: rgb(138, 147, 163),
    glowLine: rgb(38, 78, 100),
    gridDot: rgb(24, 28, 36),
  );

  /// 浅色档（"冷白 + 玻璃"那一类现代浅色，不是 Win98 灰）。
  ///
  /// 三处与深色**不对称**的设计（照抄深色会出问题）：
  ///   ① 底色带一点蓝（#f3f6fb 而不是纯 #ffffff）：纯白会让卡片"浮不起来"
  ///      （卡片也是白的），必须靠底色略暗才能用**亮度差**分层。
  ///   ② 主色比深色档**更深**一档：#58c4fa 在白底上对比度只有 2.1:1，
  ///      读不清；#0b7fd4 有 4.6:1，过 WCAG AA。
  ///   ③ 投影只能是**淡灰蓝**：浅色底上垫深黑会变成一圈脏边。
  static final _ColorSet _light = _ColorSet(
    bg: rgb(243, 246, 251),
    sidebar: rgb(237, 241, 248),
    surface: rgb(255, 255, 255),
    surfaceAlt: rgb(247, 249, 253),
    surfaceHigh: rgb(232, 238, 248),
    headerBg: rgb(255, 255, 255),
    line: rgb(221, 227, 238),
    lineStrong: rgb(195, 205, 221),
    lineFaint: rgb(238, 241, 246),
    fg: rgb(26, 31, 43),
    fgSub: rgb(74, 85, 103),
    fgDim: rgb(107, 118, 136),
    fgFaint: rgb(152, 161, 178),
    accent: rgb(11, 127, 212),
    accentHover: rgb(34, 150, 233),
    accentSoft: rgb(226, 240, 253),
    accentGlow: rgb(207, 230, 251),
    ok: rgb(22, 148, 74),
    warn: rgb(197, 111, 8),
    bad: rgb(205, 46, 46),
    hover: rgb(233, 238, 247),
    selected: rgb(220, 234, 253),
    selectedBorder: rgb(11, 127, 212),
    rowHover: rgb(242, 246, 252),
    up: rgb(22, 148, 74),
    down: rgb(205, 46, 46),
    flat: rgb(107, 118, 136),
    obfuscated: rgb(197, 111, 8),
    shadow: rgb(198, 210, 228),
    zebra: rgb(250, 251, 254),
    scrollThumb: rgb(195, 205, 221),
    scrollTrack: rgb(255, 255, 255),
    dangerHover: rgb(224, 68, 68),
    winBtnHover: rgb(233, 238, 247),
    winBtnActive: rgb(219, 227, 239),
    winBtnGlyph: rgb(91, 102, 120),
    winBtnGlyphHot: rgb(26, 31, 43),
    closeHover: rgb(232, 17, 35),
    closeActive: rgb(208, 12, 30),
    closeGlyph: rgb(255, 255, 255),
    fgInactive: rgb(163, 172, 188),
    glowLine: rgb(200, 224, 246),
    gridDot: rgb(232, 238, 248),
  );

  /// 切换到 [t]（重复调用同档位是幂等的）。
  static void apply(AppTheme t) {
    _theme = t;
    _assign(t == AppTheme.light ? _light : _dark);
  }

  static void _assign(_ColorSet c) {
    bg = c.bg;
    sidebar = c.sidebar;
    surface = c.surface;
    surfaceAlt = c.surfaceAlt;
    surfaceHigh = c.surfaceHigh;
    headerBg = c.headerBg;
    line = c.line;
    lineStrong = c.lineStrong;
    lineFaint = c.lineFaint;
    fg = c.fg;
    fgSub = c.fgSub;
    fgDim = c.fgDim;
    fgFaint = c.fgFaint;
    accent = c.accent;
    accentHover = c.accentHover;
    accentSoft = c.accentSoft;
    accentGlow = c.accentGlow;
    ok = c.ok;
    warn = c.warn;
    bad = c.bad;
    hover = c.hover;
    selected = c.selected;
    selectedBorder = c.selectedBorder;
    rowHover = c.rowHover;
    up = c.up;
    down = c.down;
    flat = c.flat;
    obfuscated = c.obfuscated;
    shadow = c.shadow;
    zebra = c.zebra;
    scrollThumb = c.scrollThumb;
    scrollTrack = c.scrollTrack;
    dangerHover = c.dangerHover;
    winBtnHover = c.winBtnHover;
    winBtnActive = c.winBtnActive;
    winBtnGlyph = c.winBtnGlyph;
    winBtnGlyphHot = c.winBtnGlyphHot;
    closeHover = c.closeHover;
    closeActive = c.closeActive;
    closeGlyph = c.closeGlyph;
    fgInactive = c.fgInactive;
    glowLine = c.glowLine;
    gridDot = c.gridDot;
  }

  /// 当前档位的色板快照（**给测试用**）。
  ///
  /// ★ 为什么需要它：颜色断言不能写死字面量（写死的话换主题必然假红），
  ///   但也不能只断言"等于 Palette.xxx" —— 那等于没断言。
  ///   有了快照，测试可以断言"浅色与深色的 bg 确实不同"这类**性质**。
  static Map<String, int> snapshot() => {
        'bg': bg,
        'sidebar': sidebar,
        'surface': surface,
        'surfaceAlt': surfaceAlt,
        'surfaceHigh': surfaceHigh,
        'headerBg': headerBg,
        'line': line,
        'lineStrong': lineStrong,
        'lineFaint': lineFaint,
        'fg': fg,
        'fgSub': fgSub,
        'fgDim': fgDim,
        'fgFaint': fgFaint,
        'accent': accent,
        'accentHover': accentHover,
        'accentSoft': accentSoft,
        'accentGlow': accentGlow,
        'ok': ok,
        'warn': warn,
        'bad': bad,
        'hover': hover,
        'selected': selected,
        'selectedBorder': selectedBorder,
        'rowHover': rowHover,
        'up': up,
        'down': down,
        'flat': flat,
        'obfuscated': obfuscated,
        'shadow': shadow,
        'zebra': zebra,
        'scrollThumb': scrollThumb,
        'scrollTrack': scrollTrack,
        'dangerHover': dangerHover,
        'winBtnHover': winBtnHover,
        'winBtnActive': winBtnActive,
        'winBtnGlyph': winBtnGlyph,
        'winBtnGlyphHot': winBtnGlyphHot,
        'closeHover': closeHover,
        'closeActive': closeActive,
        'closeGlyph': closeGlyph,
        'fgInactive': fgInactive,
        'glowLine': glowLine,
        'gridDot': gridDot,
      };
}

/// 一套完整色值（[Palette] 的内部载体）。
///
/// 做成类而不是 `Map<String,int>`：字段名有类型检查、拼错立刻报错，
/// 而且 IDE 能补全 —— 换主题这种"几十个颜色一起改"的活儿，靠字符串键太脆。
class _ColorSet {
  const _ColorSet({
    required this.bg,
    required this.sidebar,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceHigh,
    required this.headerBg,
    required this.line,
    required this.lineStrong,
    required this.lineFaint,
    required this.fg,
    required this.fgSub,
    required this.fgDim,
    required this.fgFaint,
    required this.accent,
    required this.accentHover,
    required this.accentSoft,
    required this.accentGlow,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.hover,
    required this.selected,
    required this.selectedBorder,
    required this.rowHover,
    required this.up,
    required this.down,
    required this.flat,
    required this.obfuscated,
    required this.shadow,
    required this.zebra,
    required this.scrollThumb,
    required this.scrollTrack,
    required this.dangerHover,
    required this.winBtnHover,
    required this.winBtnActive,
    required this.winBtnGlyph,
    required this.winBtnGlyphHot,
    required this.closeHover,
    required this.closeActive,
    required this.closeGlyph,
    required this.fgInactive,
    required this.glowLine,
    required this.gridDot,
  });

  final int bg;
  final int sidebar;
  final int surface;
  final int surfaceAlt;
  final int surfaceHigh;
  final int headerBg;
  final int line;
  final int lineStrong;
  final int lineFaint;
  final int fg;
  final int fgSub;
  final int fgDim;
  final int fgFaint;
  final int accent;
  final int accentHover;
  final int accentSoft;
  final int accentGlow;
  final int ok;
  final int warn;
  final int bad;
  final int hover;
  final int selected;
  final int selectedBorder;
  final int rowHover;
  final int up;
  final int down;
  final int flat;
  final int obfuscated;
  final int shadow;
  final int zebra;
  final int scrollThumb;
  final int scrollTrack;
  final int dangerHover;
  final int winBtnHover;
  final int winBtnActive;
  final int winBtnGlyph;
  final int winBtnGlyphHot;
  final int closeHover;
  final int closeActive;
  final int closeGlyph;
  final int fgInactive;
  final int glowLine;
  final int gridDot;
}

/// 某个颜色的**感知亮度**（0..1，ITU-R BT.601）。
///
/// ★ 用途：主题是两套的，任何"半透明叠色"都必须知道底色是深是浅 ——
///   比如下拉浮层的投影、`blend()` 出来的淡底。有了它就不用写
///   `if (isDark) ... else ...` 分支。
double luminanceOf(int colorref) {
  final r = colorref & 0xFF;
  final g = (colorref >> 8) & 0xFF;
  final b = (colorref >> 16) & 0xFF;
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
}

/// 尺寸度量 —— **可缩放**。
///
/// ★ 这是本轮的核心改动。原来全是 `static const`，于是：
///   ① 字号恒为 13px，在大屏上小得看不清；
///   ② 窗口拉大时只有空白变多，内容不跟着长 —— 显得"老旧、不像现代软件"。
///
/// 现在改成由 [UiScale.factor] 驱动的静态值，窗口尺寸一变就整套重算：
///   字号、行高、内边距、圆角、控件高度**同比例**放大，视觉密度保持不变。
///
/// 缩放区间刻意收在 1.0~1.6：再小字会糊，再大一次能看到的信息太少。
/// 基准窗口是 1240x800（布局就是按它设计的）。
class Metrics {
  const Metrics._();

  // ── 缩放因子（由 UiScale 在 onResize 时写入）──
  static double factor = 1.0;

  /// 按比例取整（字号这种小数值四舍五入更稳）。
  static int _s(int base) => (base * factor).round();

  // ── 这些随缩放变化：用 getter 而不是 const ──
  static int get headerHeight => _s(56);
  static int get statusHeight => _s(28);
  /// 侧栏宽度。250 → **280**（第 20 轮）。
  ///
  /// ★ 用户原话："左侧的榜单列表太小了，适当增大一些"。
  ///   250px 在 1240 宽的窗口里只占 20%，而这一列要放
  ///   "月票榜·玄幻 / 20260926 / 30" 三样东西 —— 榜名稍微长一点就被截。
  ///   280 之后榜名有 ~150px 可用，常见榜名（6~8 字）能完整显示。
  static int get sidebarWidth => _s(280);

  /// 侧栏**条目**行高。52 → **62**（第 20 轮，跟着"太小了"一起调）。
  ///
  /// ★ 条目里有两行字（榜名 + 日期），62px 让两行之间有余量，
  ///   而不是挤成一条薄片。
  static int get sidebarItemHeight => _s(62);

  /// 侧栏**平台分组头**行高。44 → **50**。
  static int get sidebarGroupHeight => _s(50);

  /// 侧栏主文字（榜名）字号。13 → **15**。
  static int get fontSizeSidebar => _s(15);

  /// 侧栏次文字（日期 / 计数）字号。11 → **12**。
  static int get fontSizeSidebarSub => _s(12);
  static int get toolbarHeight => _s(42);

  /// 表格数据行高。
  ///
  /// ★ 34 → 42（第 14 轮）。34 只是刚过"行高 ≥ 字号 × 2.4"这条底线
  ///   （14px 字 → 33.6），能读但**观感是一条条薄片** —— 用户原话是
  ///   "窄长条很不好看"。42 = 字号的 3 倍，行与行之间有呼吸，
  ///   而且和 42px 的"数据管理"左栏行、44px 的侧栏分组头对得上。
  static int get rowHeight => _s(42);

  /// 表头行高。比数据行再高一点（46），让表头有"标题带"的分量。
  static int get headerRowHeight => _s(46);

  /// 「榜单明细」整表放大倍数 —— **上限**（用户要求"每一栏都整体放大 1.5 倍"）。
  ///
  /// ★ 实际用多少由**可用宽**决定，见 [detailScaleFor]。
  ///   窗口不够宽时死守 1.5 倍的结果是"右边的列被挤出屏幕"——
  ///   用户看不到「链接」列，也就无从点开书籍详情页。
  static const double detailScale = 1.5;

  /// 明细表缩放的**下限**：再窄也不缩到比"没放大"还小（那时宁可横向滚动）。
  static const double detailMinScale = 1.0;

  /// 由可用宽反推明细表这一帧该用多大缩放。
  ///
  /// ★ 语义："**能 1.5 就 1.5，放不下就等比缩到刚好放得下**"。
  ///   明细表的自然总宽 = Σ列基准宽 × factor × 缩放，是缩放的线性函数，
  ///   所以直接解 `baseTotal × u × s ≤ available` 即可。
  ///   缩到 [detailMinScale] 还不够就返回它 —— 剩下的交给横向滚动。
  static double detailScaleFor({
    required int available,
    required int baseTotal,
  }) {
    final u = factor;
    if (available <= 0 || baseTotal <= 0 || u <= 0) return detailScale;
    final s = available / (baseTotal * u);
    if (s >= detailScale) return detailScale;
    if (s <= detailMinScale) return detailMinScale;
    return s;
  }

  // ── 明细表的各项度量：全部是「基准 × factor × 缩放 s」──
  //
  // ★ 为什么做成函数而不是常量：缩放是**自适应**的（见 detailScaleFor），
  //   行高/字号/封面必须跟着同一个 s 走，否则版面会走形
  //   （列宽缩了、行高没缩 → 一行里空一大块）。
  static int detailRowHeightAt(double s) => _s((60 * s).round());
  static int detailHeaderHeightAt(double s) => _s((46 * s).round());
  static int detailFontAt(double s) => _s((14 * s).round());
  static int coverWidthAt(double s) => _s((36 * s).round());
  static int coverHeightAt(double s) => _s((48 * s).round());

  /// 「榜单明细」的行高（按**上限**缩放；实际绘制请用 [detailRowHeightAt]）。
  ///
  /// ★ 为什么不直接把 [rowHeight] 改大：其余表格（逐期名次、跨榜、数据管理）
  ///   没有图片，跟着一起变高只是白占屏幕。所以明细表单独一档。
  static int get detailRowHeight => detailRowHeightAt(detailScale);

  /// 「榜单明细」的表头行高（按上限缩放）。
  static int get detailHeaderHeight => detailHeaderHeightAt(detailScale);

  /// 「榜单明细」的正文字号（按上限缩放）。
  static int get detailFontSize => detailFontAt(detailScale);

  /// 书封面缩略图尺寸 —— **严格 3:4**（书封面的通用比例）。
  ///
  /// ★ 用户要求"对应区域长宽调整到确保比例适合，不会太窄也不会太宽"。
  ///   3:4 是绝大多数书封面的实际比例；按别的比例缩放会把封面拉变形
  ///   （人像变胖/变瘦），那比"小一点"难看得多。
  static int get coverWidth => coverWidthAt(detailScale);
  static int get coverHeight => coverHeightAt(detailScale);

  /// 封面**解码**尺寸：比显示尺寸再留一档余量（窗口放到最大时仍清晰）。
  ///
  /// ★ 只影响解码，不影响显示尺寸 —— 缓存里存的是**原始图片字节**，
  ///   所以调大它不会让已经缓存好的封面重新下载，只是重新解一次。
  static int get coverDecodeW => _s(76);
  static int get coverDecodeH => _s(101);

  static int get fontSize => _s(14);
  static int get fontSizeSmall => _s(13);
  static int get fontSizeTiny => _s(11);
  static int get fontSizeTitle => _s(17);
  static int get fontSizeHuge => _s(26);

  static int get radius => _s(9);
  static int get radiusSmall => _s(6);
  static int get pad => _s(14);
  static int get padSmall => _s(9);

  static int get cardTitleH => _s(38);
  static int get tabHeight => _s(38);

  /// 按钮高度（现代 UI 的按钮偏大）。
  static int get buttonH => _s(34);

  // ── 自绘标题栏 ──

  /// 标题栏按钮宽度。Windows 标准是 46x32（@100%），这里按缩放走。
  static int get winBtnW => _s(46);

  /// 标题栏按钮高度 —— 直接吃满整条标题栏，视觉上更"贴边"、更像原生窗口。
  static int get winBtnH => _s(32);

  /// 标题栏按钮到窗口右上角的留白。
  static int get winBtnInset => _s(6);

  /// 标题栏左侧品牌区到窗口左缘的留白。
  static int get captionPadLeft => _s(16);

  /// 标题栏拖拽条带的最小高度（= headerHeight 时整条都能拖）。
  static int get captionDragH => headerHeight;
}

/// 窗口尺寸 → 缩放因子。
///
/// 用**较大的一边**做主判据，避免"很宽但很矮"的窗口把字撑得放不下。
/// 也设了上限：字号无限放大会让表格一屏只剩两三行，反而不好用。
class UiScale {
  const UiScale._();

  /// 基准窗口（布局按它设计）。
  static const double baseW = 1240;
  static const double baseH = 800;

  static const double minFactor = 1.0;

  /// 上限从 1.6 收到 **1.4**（第 17 轮）。
  ///
  /// ★ 用户原话："整体放大太突兀，需要柔和一点"。
  ///   1.6 意味着 1920 宽的窗口里字号是 22px、行高 67px —— 一屏只剩几行，
  ///   而且和"窗口只是变大了一点"的直觉完全不成比例。1.4 封顶后，
  ///   大窗口是"更舒展"而不是"整块被吹大"。
  static const double maxFactor = 1.4;

  /// 缩放曲线的权重：纯线性（1.0）在大屏上太激进。
  ///
  /// 0.75 → **0.52**：同样是 1600×1000 的窗口，因子从 1.29 降到 1.20，
  /// 观感上"跟着窗口长了一点"，而不是"突然放大一档"。
  static const double _weight = 0.52;

  /// 缩放**量化步长**：因子只在这个粒度上变。
  ///
  /// ★ 这是"柔和"的另一半：不量化的话，窗口每动 1px 因子就变一点点，
  ///   整套度量（字号/行高/列宽/圆角）都要重排重绘 ——
  ///   表现就是拖动窗口时界面**持续抖动**。量化到 2% 之后，
  ///   拖一大段才跳一次，而且是均匀的小步，不会"突然大一圈"。
  static const double quantum = 0.02;

  /// 由窗口客户区尺寸算缩放因子（未量化；量化在 [applyTo] 里做）。
  static double factorFor(int width, int height) {
    if (width <= 0 || height <= 0) return minFactor;
    final byW = width / baseW;
    final byH = height / baseH;
    // 取较小者：两个方向都装得下才算"真的变大了"
    final raw = byW < byH ? byW : byH;
    var f = 1 + (raw - 1) * _weight;
    if (f < minFactor) f = minFactor;
    if (f > maxFactor) f = maxFactor;
    return f;
  }

  /// 把缩放因子写进 [Metrics]，并返回它是否**变了**。
  ///
  /// 返回"有没有变"很重要：变了才需要让所有缓存的测量值（列宽、文本宽度）
  /// 失效并重排；没变就别白费一次全量重绘。
  static bool applyTo(int width, int height) {
    // 量化 + 死区：小于一个步长的变化直接忽略，避免拖动窗口时界面持续重排。
    final f = (factorFor(width, height) / quantum).round() * quantum;
    if ((f - Metrics.factor).abs() < quantum - 1e-9) return false;
    Metrics.factor = f;
    return true;
  }
}

/// 一列的定义（表格用）。
///
/// [width] 是**基准宽度**（按 factor=1 设计），实际渲染时乘 [Metrics.factor]。
class Column {
  const Column({
    required this.key,
    required this.title,
    required this.width,
    this.align = dtLeft,
    this.stretch = false,
  });

  final String key;
  final String title;
  final int width;
  final int align;

  /// 是否吃剩余宽度（同一表里最多一列设 true）。
  final bool stretch;

  /// 缩放后的实际宽度。
  int get scaledWidth => (width * Metrics.factor).round();
}

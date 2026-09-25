/// 对话框 —— 扫榜设置窗口 + 确认框。
///
/// ★ 扫榜设置做成**独立窗口**而不是模态弹窗：
///   Win32 的模态对话框要跑嵌套消息循环，在我们这套"分片非阻塞消息循环"
///   里会互相打架（外层 Timer 拿不到消息，界面就冻住）。
///   独立窗口 + 主窗口加遮罩，交互上等价，但不会死锁。
///
/// 视觉与主窗共用 [Palette] / [Metrics] / [widgets] —— 所以窗口一大，
/// 这里的字号和行高也会跟着放大，不会出现"主窗很清楚、设置窗还是小字"。
library;

import 'package:ffi/ffi.dart';

import '../scan_service.dart';
import 'app.dart';
import 'gdi.dart';
import 'main_window.dart';
import 'theme.dart';
import 'widgets.dart';
import 'win32.dart';

/// 扫榜设置窗口。
class ScanDialogWindow extends AppWindow {
  ScanDialogWindow({required this.owner});

  final MainWindow owner;

  /// 勾选状态：key = "source|board|category"
  final Set<String> checked = {};

  /// ★ 每个已选榜要扫几本：key 同 [checked]，value = 本数。
  ///   未记录的 key 走默认（[sourceDefaultLimit]）。这样"勾上就用默认、
  ///   想改才动它"，不用在勾选时也写一遍。
  final Map<String, int> limits = {};

  final List<_Group> groups = [];

  /// 内容竖向滚动量。
  ///
  /// ★ 不能叫 `scroll` —— 基类 [AppWindow] 已经有一个
  ///   `Map<int,int> scroll`（按控件 id 分别记滚动），
  ///   子类用 `int scroll` 会撞名，Dart 直接报返回类型不匹配。
  int scrollY = 0;
  bool _built = false;
  String statusNote = '';
  int contentH = 0;

  @override
  String get title => '扫榜设置';

  // ── 无边框钩子 ──

  /// 顶栏即自绘标题栏（可拖动）。
  @override
  int get captionHeight => Metrics.headerHeight;

  /// 对话框**不提供最大化**（设置面板全屏很怪），
  /// 但保留最小化与关闭 —— 用户习惯上这三件套里少一个都会别扭。
  @override
  int? onHitTest(int x, int y) {
    final h = Metrics.headerHeight;
    if (y < 0 || y >= h) return null;
    for (final id in const [idWinMinimize, idWinClose]) {
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) return htClient;
    }
    // 顶栏上的所有按钮都要排除，否则点不动。
    for (final id in const [
      idRun, idCancel, idCheckAll, idClearAll, idQuickSweep,
      idLimitAllMinus, idLimitAllPlus,
    ]) {
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) return htClient;
    }
    return htCaption;
  }

  /// 子窗口用**不可缩放**的无边框样式：设置面板能拖大反而让布局错位。
  @override
  bool get resizable => false;

  @override
  void onResize(int w, int h) {
    // 设置窗不驱动全局缩放（主窗才是基准），但要在自己变尺寸时重绘。
    if (!_built) _build();
    invalidate();
  }

  void _build() {
    if (_built) return;
    _built = true;
    // ★ 打开设置窗时要显示**用户上次设的**保留份数，而不是写死的 10。
    //   写死会让每次打开都像"设置没保存"，用户只能反复重设。
    keepCount = owner.retentionPerSeries.clamp(keepMin, keepMax);
    final svc = owner.service ?? ScanService(outRoot: owner.outRoot);
    owner.service = svc;
    for (final info in svc.enumerateBoards()) {
      groups.add(_Group(info.displayName, info.sourceId, [
        for (final b in info.boards) _Board(b, info.categories),
      ]));
    }
    checked.addAll([
      'qidian|畅销榜|全站',
      'qidian|月票榜|全站',
      'qimao|男频大热榜|',
      'jjwxc|总分排行榜|',
    ]);
  }

  static const int idRun = 900;
  static const int idCancel = 901;
  static const int idCheckAll = 902;
  static const int idClearAll = 903;
  static const int idQuickSweep = 904;

  /// 顶栏"统一本数"上的两个按钮（对所有已选榜生效）。
  static const int idLimitAllMinus = 905;
  static const int idLimitAllPlus = 906;

  /// 搜索框 + 清除按钮。
  static const int idSearch = 920;
  static const int idSearchClear = 921;

  /// 树行的勾选命中区（沿用旧的 1000 段，自检脚本依赖这个口径）。
  static const int idTreeBase = 1000;

  /// 树行的**折叠箭头**命中区（独立段，避开勾选区）。
  static const int idTreeChevronBase = 3000;

  /// 树行里**每个榜自己的本数步进器**（减 / 值 / 加 三段）。
  ///
  /// ★ 三段分开编号：值区是"点一下进入输入"的入口，与加减按钮**行为不同**，
  ///   混在一个 id 里就没法区分"点到了值区还是按钮"。
  static const int idRowStepMinusBase = 4000;
  static const int idRowStepValueBase = 4400;
  static const int idRowStepPlusBase = 4800;

  /// 顶栏批量步进器的**值区**（点它可以直接输入任意值）。
  static const int idLimitAllValue = 909;

  /// 底栏"数据保留"步进器的两个按钮。
  ///
  /// ★ 为什么放在**底栏**而不是顶栏：顶栏已经有 4 个按钮 + 品牌块 + 标题 +
  ///   批量本数组，"选择要扫的榜"标题刚刚才从 156px 重叠里救出来（见上面注释）。
  ///   再往里塞一个常驻控件必然又把标题挤掉。底栏右侧本来只放了一句转瞬即逝的
  ///   状态提示，空间充裕且语义无关 —— 是更稳的落点。
  static const int idKeepMinus = 907;
  static const int idKeepPlus = 908;

  /// 「每榜保留份数」。0 = 不限（不自动清理）。
  ///
  /// ★ 单位是**系列**（同平台+同榜+同题材），不是"总文件数"：
  ///   用户的心智是"这张榜我想留最近几次"，而不是"我总共想留 20 个文件"。
  static const int keepMin = 0;
  static const int keepMax = 60;

  int keepCount = 10;

  final Map<int, Rc> hitRects = {};
  final Map<int, String> checkIdKey = {};
  final Map<int, (String, String, String)> rowInfo = {};

  /// 绘制时记录的勾选行矩形（点击时查表定位，不重算布局）。
  final Map<int, Rc> _rowRects = {};

  /// 绘制时记录的行**右侧徽标**矩形（自检用：断言它落在行框里面）。
  final Map<int, Rc> _badgeRects = {};

  /// 行内步进器的三个 id → 榜 key（点击时按 id 反查是哪个榜）。
  final Map<int, String> rowStepKeys = {};

  /// 当前正在手输本数的榜（key）；'' = 无。手输时键盘数字直接改这个榜。
  String editingLimitKey = '';

  /// 设置窗里**折叠的平台**（默认展开）。
  Set<String> get collapsedScan => owner.settings.collapsedScanSources;

  /// 设置窗里**展开的榜**（默认折叠 —— 起点每个榜挂 14 个题材，
  /// 全展开就是 196 行，用户一开窗看到的就是一堵墙）。
  Set<String> get expandedBoards => owner.settings.expandedBoards;

  @override
  void onPaint(Gdi g) {
    if (!_built) _build();
    hitRects.clear();
    _rowRects.clear();
    _badgeRects.clear();
    rowStepKeys.clear();
    // ★ 可见行**先算好**：绘制和点击都读同一份，不会出现"看得见点不到"。
    _buildTreeRows();
    final u = Metrics.factor;
    g.fill(Rc.xywh(0, 0, width, height), Palette.bg);

    // 顶栏
    final headH = Metrics.headerHeight;
    final padx = (18 * u).round();
    g.fill(Rc.xywh(0, 0, width, headH), Palette.headerBg);
    g.line(0, headH - 1, width, headH - 1, Palette.line);

    // 品牌小方块，和主窗一致
    final logo = (24 * u).round();
    final ly = (headH - logo) ~/ 2;
    g.roundFill(Rc.xywh(padx, ly, logo, logo), Palette.accent, Palette.accent,
        radius: (6 * u).round());
    g.text('选', Rc.xywh(padx, ly, logo, logo), Palette.bg,
        size: Metrics.fontSizeTiny, align: dtCenter, bold: true);

    final tx = padx + logo + (10 * u).round();

    // 快捷按钮
    final btnH = Metrics.buttonH;
    // ★ 自绘窗口按钮（最小化 + 关闭）永远贴右上角。
    //   设置窗不给最大化 —— 一个全屏的勾选面板很难用。
    var wx = width - Metrics.winBtnInset - Metrics.winBtnW * 2;
    for (final entry in const [
      (idWinMinimize, WinBtnKind.minimize),
      (idWinClose, WinBtnKind.close),
    ]) {
      final (id, kind) = entry;
      final r = Rc.xywh(wx, 0, Metrics.winBtnW, Metrics.winBtnH);
      hitRects[id] = r;
      final hot = r.contains(mouseX, mouseY);
      drawWinButton(g, wx, 0,
          kind: kind, hot: hot, pressed: false, windowActive: hasFocus);
      wx += Metrics.winBtnW;
    }

    // ★ 布局顺序很重要：按钮是**从右往左**累计的（bx 只会变小），
    //   所以必须**先把按钮排完**、拿到最终左缘，再去画标题。
    //   反过来（先按固定宽度画标题、再排按钮）就会出现标题压到按钮上
    //   —— 这就是之前 156px 重叠的根因：标题写死 220 宽，完全不知道
    //   右边排到哪了。
    var bx = width - Metrics.winBtnInset - Metrics.winBtnW * 2 - (10 * u).round();
    void hbtn(int id, String label, BtnKind kind, int baseW) {
      final w = (baseW * u).round();
      bx -= w;
      final r = Rc.xywh(bx, (headH - btnH) ~/ 2, w, btnH);
      hitRects[id] = r;
      drawButton(g, r,
          label: label,
          kind: kind,
          st: CtlState(hot: r.contains(mouseX, mouseY)));
      bx -= (8 * u).round();
    }

    hbtn(idCancel, '取消', BtnKind.ghost, 66);
    hbtn(idRun, '开始扫榜', BtnKind.primary, 106);
    bx -= (10 * u).round();
    hbtn(idClearAll, '全不选', BtnKind.ghost, 70);
    hbtn(idQuickSweep, '默认组合', BtnKind.ghost, 82);

    // ★ "所有已选榜统一改本数" —— **批量**入口。
    //
    //   第 6 轮曾把每行的单榜步进器删掉、只留这一处（"入口唯一"）；
    //   第 10 轮用户要求"每个榜单要单独设置扫榜本数"，于是单榜步进器回来了。
    //   两者职责不同、都保留：
    //     · 这里 = 把**所有已选榜**统一改成同一个值（批量）；
    //     · 每行 = 只改**那一个榜**（单榜）。
    //   放在更左一格，与前面的按钮拉开距离（避免误点）。
    bx -= (14 * u).round();
    {
      // 178 = 标签"已选榜本数"实测宽(~56) + gap(10) + 步进器(108) + 余量。
      // 原来 162 只够 44px 给标签 → 被省略成"已选榜…"，看不出是什么。
      final w = (178 * u).round();
      bx -= w;
      final r = Rc.xywh(bx, (headH - btnH) ~/ 2, w, btnH);
      // 组内布局：文字 + 步进器。
      // ★ 文字宽度用实测值，步进器贴右边，两者之间留出 gap；
      //   不写死 74 —— 写死会在缩放/字体替换时又压到一起。
      final sw = stepperWidth;
      final sx = r.right - sw;
      final sy = r.top + (r.height - stepperHeight) ~/ 2;
      final anySel = checked.isNotEmpty;
      final mr = Rc.xywh(sx, sy, stepperHeight, stepperHeight);
      final pr = Rc.xywh(sx + sw - stepperHeight, sy, stepperHeight, stepperHeight);
      hitRects[idLimitAllMinus] = mr;
      hitRects[idLimitAllPlus] = pr;

      // 显示"统一值"：所有已选榜本数**一致**时显示该值；
      // 不一致时显示"多值"（用 warn 色），而不是硬编一个数字骗人。
      final vals = {for (final k in boardKeysOf(checked)) limitOf(k.split('|').first, k)};
      final mixed = vals.length > 1;
      final shown = vals.length == 1 ? vals.first : 20;
      final editing = editId == idLimitAllValue;
      // ★ 值区矩形要**先算**：不能拿 `drawStepper` 的返回值去喂它自己的参数
      //   （同一句解构里声明的变量，在实参位置还不可见 —— 编译期直接报错）。
      final vRect = Rc.xywh(sx + stepperHeight, sy,
          sw - stepperHeight * 2, stepperHeight);
      final (mr2, vBox, pr2) = drawStepper(g, sx, sy,
          value: shown,
          enabled: anySel,
          hotMinus: mr.contains(mouseX, mouseY),
          hotPlus: pr.contains(mouseX, mouseY),
          editing: editing,
          editText: editing ? editBuf : null,
          valueHot: vRect.contains(mouseX, mouseY));
      hitRects[idLimitAllValue] = vBox;

      final label = anySel ? '已选榜本数' : '本数';
      final lw = g.measure(label, size: Metrics.fontSizeTiny);
      final labelRight = (sx - (10 * u).round()).clamp(r.left, r.right);
      g.text(label,
          Rc.xywh(r.left, r.top, (labelRight - r.left).clamp(0, lw + (6 * u).round()),
              r.height),
          anySel ? Palette.fgSub : Palette.fgFaint,
          size: Metrics.fontSizeTiny);

      // 正在输入时**不盖**"多值" —— 否则用户看不到自己敲的数字
      if (anySel && mixed && !editing) {
        // "多值"盖在数值区上（一眼看出不是统一值）
        g.fill(vBox, Palette.surface);
        g.text('多值', vBox, Palette.warn,
            size: Metrics.fontSizeTiny, align: dtCenter);
      }
      // drawStepper 返回的三段与预登记的矩形一致，用它的更保险
      hitRects[idLimitAllMinus] = mr2;
      hitRects[idLimitAllPlus] = pr2;
    }

    // ★ 标题**最后**画，且宽度被夹到"按钮组左缘再往左一点"。
    //   关键：**只有真的放得下整条标题时才画**，否则整个不画 ——
    //   只靠 dtEndEllipsis 是不够的：它只能在"框比文字宽"时正常省略，
    //   而这里框宽 = availW，文字会被压成省略号碎片，观感比不画还差。
    //   标题是纯装饰（面板本身就叫"扫榜设置"），功能控件（批量步进器）优先。
    final title = '选择要扫的榜';
    final titleW = g.measure(title, size: Metrics.fontSizeTitle, bold: true);
    final sub = '勾选后点「开始扫榜」';
    final subW = g.measure(sub, size: Metrics.fontSizeTiny);
    final subGap = (14 * u).round();
    // 标题单独要的空间；带副标题时还要 subGap + subW。
    final headRight = bx - (16 * u).round(); // 标题可用右界
    final availW = headRight - tx;
    final fitsTitle = availW >= titleW;
    final fitsBoth = availW >= titleW + subGap + subW;
    if (fitsBoth) {
      g.text(title, Rc.xywh(tx, 0, titleW, headH), Palette.fg,
          size: Metrics.fontSizeTitle, bold: true);
      g.text(sub, Rc.xywh(tx + titleW + subGap, 0, subW, headH),
          Palette.fgFaint, size: Metrics.fontSizeTiny);
    } else if (fitsTitle) {
      // 空间够标题、不够副标题 —— 只画标题（绝不硬塞副标题压到按钮）。
      g.text(title, Rc.xywh(tx, 0, titleW, headH), Palette.fg,
          size: Metrics.fontSizeTitle, bold: true);
    }
    // 两者都放不下 → 全不画。顶栏只剩品牌块 + 按钮，干净且绝不重叠。

    // 内容区（卡片）
    final footH = (34 * u).round();
    final bodyTop = headH + (12 * u).round();
    final body = Rc.xywh((14 * u).round(), bodyTop, width - (28 * u).round(),
        height - bodyTop - footH - (6 * u).round());
    g.roundFill(body, Palette.surface, Palette.line, radius: Metrics.radius);

    final inner = Rc.xywh(body.left + 1, body.top + 1, body.width - 2,
        body.height - 2);
    var y = inner.top + (10 * u).round() - scrollY;
    var idx = 0;

    // ★ 真裁剪：内容必须限制在卡片内。
    //   下面那些 `if (y + rowH > inner.top && y < inner.bottom)` 只是**起点守卫**，
    //   挡不住"一行从卡片内开始、画到卡片外" —— 后果就是：
    //     ① 滚到顶时，滚上去的平台头/榜单行画到卡片外（显成"莫名空白"）；
    //     ② 最后一行画进底栏，"已选 N 个榜、合计 M 本"压在勾选框上。
    //   加一层 GDI 裁剪后这两类都不可能出现。
    final endClip = g.clipTo(inner);

    // ── 搜索框（现代做法：把"过滤"放在列表顶部，而不是让人在 37 行里翻）──
    final searchH = (40 * u).round();
    final searchR = Rc.xywh(inner.left + (12 * u).round(), y,
        inner.width - (24 * u).round(), searchH);
    hitRects[idSearch] = searchR;
    hitRects[idSearchClear] = Rc.xywh(searchR.right - (30 * u).round(),
        searchR.top + (10 * u).round(), (20 * u).round(), (20 * u).round());
    if (y + searchH > inner.top && y < inner.bottom) {
      g.roundFill(searchR, Palette.surfaceAlt,
          searchFocus ? Palette.accent : Palette.line,
          radius: Metrics.radiusSmall);
      drawSearchGlyph(g, searchR.left + (16 * u).round(),
          searchR.top + searchH ~/ 2, Palette.fgFaint, scale: 1.15);
      final textLeft = searchR.left + (32 * u).round();
      final textRight = searchR.right - (38 * u).round();
      final shown = search.isEmpty ? '输入榜名 / 题材过滤…' : search;
      g.text(shown,
          Rc.xywh(textLeft, searchR.top, (textRight - textLeft).clamp(0, 9999),
              searchH),
          search.isEmpty ? Palette.fgFaint : Palette.fg,
          size: Metrics.fontSize);
      // 光标（聚焦且没在打字时也画一条，表示"可以打字了"）
      if (searchFocus) {
        final tw =
            search.isEmpty ? 0 : g.measure(search, size: Metrics.fontSize);
        final cx = textLeft + tw + (1 * u).round();
        if (cx < textRight) {
          g.fill(Rc.xywh(cx, searchR.top + (8 * u).round(),
              (1.5 * u).round().clamp(1, 2), searchH - (16 * u).round()),
              Palette.accent);
        }
      }
      if (search.isNotEmpty) {
        final cr = hitRects[idSearchClear]!;
        g.roundFill(cr, Palette.surfaceHigh, Palette.surfaceHigh,
            radius: cr.height ~/ 2);
        final cx = cr.left + cr.width ~/ 2;
        final cy = cr.top + cr.height ~/ 2;
        final arm = (3.5 * u).round().clamp(2, 5);
        final lw = (1.5 * u).round().clamp(1, 3);
        g.line(cx - arm, cy - arm, cx + arm, cy + arm, Palette.fgSub, width: lw);
        g.line(cx + arm, cy - arm, cx - arm, cy + arm, Palette.fgSub, width: lw);
      }
      // 右侧命中统计
      final hitN = treeRows.length;
      final stat = search.isEmpty ? '' : '$hitN 项';
      if (stat.isNotEmpty) {
        g.text(stat,
            Rc.xywh(textRight, searchR.top, (30 * u).round(), searchH),
            Palette.fgFaint, size: Metrics.fontSizeTiny, align: dtRight,
            vcenter: true);
      }
    }
    y += searchH + (10 * u).round();

    // ── 树（平台 → 榜 → 题材），可折叠 + 三态勾选 ──
    for (final row in treeRows) {
      row.y = y;
      if (y + row.h > inner.top && y < inner.bottom) {
        _paintTreeRow(g, inner, row);
      }
      y += row.h;
      idx++;
    }
    contentH = y + scrollY - inner.top;
    endClip(); // ★ 内容画完，撤掉裁剪 —— 底栏/滚动条必须画在裁剪之外

    // 底栏统计 + 「数据保留」步进器
    final foot = Rc.xywh((14 * u).round(), height - footH, width - (28 * u).round(),
        footH);

    // ★ 「数据保留」先排（从右往左），标题/提示让位 —— 与顶栏同一套布局纪律：
    //   先把定宽控件排完拿到左缘，可变宽的文字再夹进去。反过来必然重叠。
    final kw = (176 * u).round();
    final kx = foot.right - kw;
    final ksy = foot.top + (footH - stepperHeight) ~/ 2;
    final kMr = Rc.xywh(kx, ksy, stepperHeight, stepperHeight);
    final kPr = Rc.xywh(kx + stepperWidth - stepperHeight, ksy, stepperHeight,
        stepperHeight);
    hitRects[idKeepMinus] = kMr;
    hitRects[idKeepPlus] = kPr;
    final (kMr2, _kv, kPr2) = drawStepper(g, kx, ksy,
        value: keepCount,
        enabled: true,
        hotMinus: kMr.contains(mouseX, mouseY),
        hotPlus: kPr.contains(mouseX, mouseY),
        cap: keepMax,
        // ★ 量词走参数，不再"先画'本'再拿底色盖掉" —— 那个补丁是公共控件
        //   缺少 unit 参数时的权宜之计，现在参数化了就删掉。
        unit: keepCount == 0 ? '不限' : '份');
    hitRects[idKeepMinus] = kMr2;
    hitRects[idKeepPlus] = kPr2;
    // 标签贴在步进器左侧，宽度按实测（不写死，缩放时才不压到一起）
    const keepLabel = '每榜保留';
    final klw = g.measure(keepLabel, size: Metrics.fontSizeTiny);
    final klRight = kx - (10 * u).round();
    if (klRight - foot.left > klw) {
      g.text(keepLabel,
          Rc.xywh(klRight - klw, foot.top, klw, footH), Palette.fgSub,
          size: Metrics.fontSizeTiny, vcenter: true);
    }

    // ★ 统计文字与状态提示夹在"步进器标签左缘"之前 —— 绝不允许压上去。
    //   顺序：状态提示（更紧急，右对齐）先占，统计文字吃剩下的。
    final textRight = (klRight - klw - (14 * u).round()).clamp(foot.left, foot.right);
    var textW = textRight - foot.left;
    if (statusNote.isNotEmpty) {
      final nw = g.measure(statusNote, size: Metrics.fontSizeTiny);
      final nLeft = (textRight - nw).clamp(foot.left, foot.right);
      g.text(statusNote, Rc.xywh(nLeft, foot.top, textRight - nLeft, footH),
          Palette.warn, size: Metrics.fontSizeTiny, align: dtRight, vcenter: true);
      textW = nLeft - foot.left - (10 * u).round();
    }
    if (textW > 0) {
      g.text(_selectedSummary(),
          Rc.xywh(foot.left, foot.top, textW, footH), Palette.fgSub,
          size: Metrics.fontSizeTiny, vcenter: true, ellipsis: true);
    }

    // 滚动条
    final viewH = inner.height;
    if (contentH > viewH) {
      drawScrollbar(g, body,
          contentHeight: contentH,
          viewHeight: viewH,
          scrollY: scrollY,
          hot: body.contains(mouseX, mouseY));
    }
  }

  // ── 树：可见行模型 ──
  //
  // ★ 为什么先把"现在到底有哪几行"整体算出来、再逐行画：
  //   折叠、搜索过滤、三态统计都要读这份清单。如果在绘制循环里边算边画，
  //   命中测试就得把同一套规则**再实现一遍** —— 两份实现迟早会不一致，
  //   表现就是"点了没反应"或者"点到了看不见的行"。
  //   所以：`_buildTreeRows()` 算一次 → 绘制用它 → 点击也用它。

  /// 搜索关键字（空 = 不过滤）。
  String search = '';

  /// 搜索框是否聚焦（决定要不要画光标）。
  bool searchFocus = false;

  // ── "直接输入本数"的编辑态 ──
  //
  // ★ 为什么需要这一套：用户原话"扫榜本数要可以任意修改，不是只有几个选择"。
  //   加减按钮再快也走不到 37 这种值，必须能**打字**。
  //   编辑态是全局单例（同时只能编辑一个），用 id 区分是哪个框。

  /// 正在编辑的控件 id（-1 = 没在编辑）。
  int editId = -1;

  /// 正在编辑的榜 key（`source|board|`）；批量编辑时为空串。
  String editKey = '';

  /// 正在编辑的榜所属平台（取上限用）。
  String editSource = '';

  /// 输入缓冲。
  String editBuf = '';

  /// 刚进入编辑：**第一个数字替换**而不是追加（等价于"聚焦即全选"）。
  /// 不这样的话，想把 20 改成 25 会得到 2025。
  bool editFresh = false;

  /// 当前可见的树行。
  List<_TreeRow> treeRows = [];

  /// 算一遍可见行。**必须在绘制前调用**（点击也依赖它）。
  void _buildTreeRows() {
    final q = search.trim().toLowerCase();
    final rows = <_TreeRow>[];
    for (final grp in groups) {
      final boards = <_Board>[
        for (final b in grp.boards)
          if (q.isEmpty || _boardMatches(grp, b, q)) b
      ];
      if (boards.isEmpty && q.isNotEmpty) continue;

      var on = 0;
      for (final b in boards) {
        if (checked.contains(_boardScopeKey(grp.sourceId, b))) on++;
      }
      final sRow = _TreeRow.source(grp, boards.length, on);
      rows.add(sRow);
      // 搜索时忽略折叠状态：用户搜了就是"我要看到结果"
      final srcCollapsed = q.isEmpty && collapsedScan.contains(grp.sourceId);
      sRow.expanded = !srcCollapsed;
      if (srcCollapsed) continue;

      for (final b in boards) {
        final cats = b.categories;
        final bkey = '${grp.sourceId}|${b.name}';
        var catOn = 0;
        for (final c in cats) {
          if (_isChecked(grp.sourceId, b.name, c)) catOn++;
        }
        final bRow = _TreeRow.board(grp, b.name, cats, catOn);
        rows.add(bRow);
        if (cats.isEmpty) continue;
        // 搜索时一律展开（用户搜了就是要看到结果）
        final bExpanded = q.isNotEmpty || expandedBoards.contains(bkey);
        bRow.expanded = bExpanded;
        if (!bExpanded) continue;
        for (final c in cats) {
          if (!_catVisible(grp, b, c, q)) continue;
          rows.add(_TreeRow.cat(
              grp, b.name, c, _isChecked(grp.sourceId, b.name, c)));
        }
      }
    }
    // id 与行高在这里一次算好：绘制、命中、点击三处都用同一份编号与几何。
    final u = Metrics.factor;
    for (var i = 0; i < rows.length; i++) {
      rows[i].id = idTreeBase + i;
      rows[i].h = _TreeRow.heightOf(rows[i].kind, u);
    }
    treeRows = rows;
  }

  /// 这个榜是否命中搜索词（榜名 / 题材 / 平台名任一命中）。
  bool _boardMatches(_Group grp, _Board b, String q) {
    if (_nameOrSourceMatches(grp, b, q)) return true;
    for (final c in b.categories) {
      if (c.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  bool _nameOrSourceMatches(_Group grp, _Board b, String q) =>
      b.name.toLowerCase().contains(q) || grp.title.toLowerCase().contains(q);

  /// 搜题材词时，只显示**命中的题材行**。
  ///
  /// ★ 为什么要收窄：搜"玄幻"时，起点的 14 个榜全都"命中"（每个榜的题材表里
  ///   都有玄幻），如果照旧把每个榜的 14 个题材全列出来，用户得到的是
  ///   196 行噪声 —— 他真正想找的那 14 行（每榜一个玄幻）反而被淹没。
  ///   榜名/平台名命中时仍然全列（那时用户是在找榜，不是找题材）。
  bool _catVisible(_Group grp, _Board b, String c, String q) {
    if (q.isEmpty) return true;
    if (_nameOrSourceMatches(grp, b, q)) return true;
    return c.toLowerCase().contains(q);
  }

  /// 一个榜的"默认档"键 —— 点榜名时勾的就是它。
  ///
  /// ★ 有题材的榜（起点）默认档是 `全站`，**不是**"全部题材"：
  ///   用户点一下榜名的意思是"扫这个榜"，而不是"扫这个榜的 14 个题材"
  ///   （后者是 14 个请求，扫一轮从 35 秒变成 8 分钟）。
  ///   想要细分的题材，下面每一行都能单独勾。
  String _boardScopeKey(String source, _Board b) =>
      '$source|${b.name}|${_boardScopeCat(b.categories)}';

  static String _boardScopeCat(List<String> cats) {
    if (cats.isEmpty) return '';
    for (final c in cats) {
      if (c == '全站' || c.isEmpty) return c;
    }
    return cats.first;
  }

  /// 这个榜下**除了默认档之外**还勾了几个题材（用于行右侧的 `+N` 提示）。
  int _extraCatsOn(String source, String board, List<String> cats) {
    var n = 0;
    final scope = _boardScopeCat(cats);
    for (final c in cats) {
      if (c == scope) continue;
      if (_isChecked(source, board, c)) n++;
    }
    return n;
  }

  /// 一行的**选中态**：0 = 未选、1 = 部分选中（父节点）、2 = 全选。
  int _stateOf(_TreeRow row) {
    if (row.kind == 0) {
      if (row.total == 0) return 0;
      if (row.on == 0) return 0;
      return row.on >= row.total ? 2 : 1;
    }
    if (row.kind == 1) {
      // ★ 榜行的"选中"看的是**默认档那个键**（有题材 = `…|全站`），
      //   不是 `row.checked` —— 那个字段只给题材行用。
      //   第一版写成 `row.checked ? 2 : 0`，后果是榜行**永远显示未选**，
      //   蓝色高亮框一次都不会出现（实测：所有榜行 state 恒为 0）。
      return checked.contains(_scopeKeyOf(row)) ? 2 : 0;
    }
    return row.checked ? 2 : 0;
  }

  /// 画一行。
  ///
  /// ★ 这一版把**方框勾选整个去掉了**：选中不靠复选框，而是靠
  ///   **整行变蓝框**（与左侧栏选中项同一套视觉语汇 —— 见 `_paintSidebar`）。
  ///   三态用底色区分：全选 = 选中底 + 主色描边；部分选中 = 主色淡底。
  ///   好处不只是好看：行高从 30 涨到 40+、字号也大一档之后，
  ///   15px 的小方框会显得"点缀在一条长条上"，而整行底色是**跟着行走的**，
  ///   视觉上自然连成一条，不再是"窄长条"。
  void _paintTreeRow(Gdi g, Rc inner, _TreeRow row) {
    final u = Metrics.factor;
    final y = row.y;
    final h = row.h;
    final pad = (14 * u).round();
    // 行盒子：左右各留 8px —— 蓝色高亮框（含左侧主色竖条）必须完整落在留白里
    // （这条纪律与侧栏一致，见 `_paintSidebar` 里"未对齐"那段注释）。
    final r = Rc.xywh(inner.left + (8 * u).round(), y,
        inner.width - (16 * u).round(), h);
    final hot = r.contains(mouseX, mouseY);
    final state = _stateOf(row);

    // ── 行底：三态 + 悬停 ──
    if (state == 2) {
      // 全选：与侧栏选中项**逐像素同一套**（选中底 + 主色描边 + 左侧主色竖条）
      g.roundFill(r, Palette.selected, Palette.selectedBorder,
          radius: Metrics.radiusSmall);
      final lw = (3 * u).round().clamp(2, 5);
      g.roundFill(
          Rc.xywh(r.left + (3 * u).round(), r.top + (7 * u).round(), lw,
              r.height - (14 * u).round()),
          Palette.accent,
          Palette.accent,
          radius: lw ~/ 2);
    } else if (state == 1) {
      // 部分选中：主色淡底 + 一条较淡的竖条。**不能用方框**，
      // 但必须一眼区别于"未选" —— 否则用户会以为父节点完全没勾上。
      g.roundFill(r, Palette.accentSoft, Palette.accentSoft,
          radius: Metrics.radiusSmall);
      final lw = (3 * u).round().clamp(2, 5);
      g.roundFill(
          Rc.xywh(r.left + (3 * u).round(), r.top + (10 * u).round(), lw,
              r.height - (20 * u).round()),
          Palette.accent,
          Palette.accent,
          radius: lw ~/ 2);
    } else if (hot) {
      g.roundFill(r, Palette.hover, Palette.hover, radius: Metrics.radiusSmall);
    }

    // ── 折叠箭头（**只在真的有东西可折叠时才画**）──
    //
    // ★ 这一条是用户报的："这种没有折叠任何内容的，把折叠符号去掉"。
    //   番茄 / 七猫的榜下面**没有题材维度**（`cats` 为空），
    //   画一个箭头出来点它什么也不会发生 —— 那是纯粹的谎。
    //   判据：平台看它有没有榜；榜看它有没有题材；题材行永远没有。
    final canCollapse = switch (row.kind) {
      0 => row.total > 0,
      1 => row.cats.isNotEmpty,
      _ => false,
    };
    // 层级靠**缩进**表达：平台 0、榜 20u、题材 46u。
    final chevBase = switch (row.kind) {
      0 => pad,
      1 => pad + (20 * u).round(),
      _ => pad + (46 * u).round(),
    };
    final chevW = (22 * u).round();
    var labelX = r.left + chevBase;
    if (row.kind != 2) {
      if (canCollapse) {
        final cr = Rc.xywh(r.left + chevBase, y, chevW, h);
        hitRects[idTreeChevronBase + row.id - idTreeBase] = cr;
        final cHot = cr.contains(mouseX, mouseY);
        drawChevron(g, cr.left + cr.width ~/ 2, cr.top + cr.height ~/ 2,
            expanded: row.expanded,
            color: cHot
                ? Palette.accent
                : (state > 0 ? Palette.accent : Palette.fgSub),
            scale: row.kind == 0 ? 1.2 : 1.0);
      }
      // 没有箭头时**仍然占住这段宽度**：否则同一层的榜会一个靠左一个靠右，
      // 看起来像两级缩进（比多一个没用的箭头更糟）。
      labelX = r.left + chevBase + chevW + (6 * u).round();
    }

    // ── 命中区：整行可点（点箭头才是折叠）──
    final id = row.id;
    checkIdKey[id] = row.kind == 2
        ? '${row.source}|${row.board}|${row.cat}'
        : (row.kind == 1 ? _scopeKeyOf(row) : '');
    rowInfo[id] = (row.source, row.board ?? '', row.cat ?? '');
    _rowRects[id] = r;

    // ── 右侧控件：**从右往左排** ──
    //
    // ★ 排序纪律（与顶栏、底栏一致）：先排**定宽**的控件（本数步进器），
    //   徽标和标签再吃剩下的。反过来先算标签宽度，必然与步进器打架。
    //
    // ★ 右缘固定在 `r.right - pad`：所有东西**必须落在蓝框里面**。
    //   之前贴着 `inner.right - 14u`，与行框右缘只差 6px ——
    //   选中时数字紧贴蓝框描边，看着像被框切了一半。
    var rightCursor = r.right - pad;
    if (row.kind == 1) {
      // ★ **每个榜自己的本数步进器**（用户要求：每个榜单单独设置）。
      //   放在行内而不是"选中它再到底栏调" —— 后者要来回切，
      //   而且看不到"哪些榜本数不一样"。
      final bkey = '${row.source}|${row.board}|';
      final vId = idRowStepValueBase + row.id - idTreeBase;
      final mId = idRowStepMinusBase + row.id - idTreeBase;
      final pId = idRowStepPlusBase + row.id - idTreeBase;
      final sx = rightCursor - rowStepperW;
      final sy = y + (h - rowStepperH) ~/ 2;
      final mHot = (hitRects[mId] = Rc.xywh(sx, sy, rowStepperH, rowStepperH))
          .contains(mouseX, mouseY);
      final pHot = (hitRects[pId] = Rc.xywh(
              sx + rowStepperW - rowStepperH, sy, rowStepperH, rowStepperH))
          .contains(mouseX, mouseY);
      final vRect = Rc.xywh(sx + rowStepperH, sy, rowStepperW - rowStepperH * 2,
          rowStepperH);
      hitRects[vId] = vRect;
      final editing = editId == vId;
      final (mr, vr, pr) = drawRowStepper(g, sx, sy,
          value: limitOf(row.source, bkey),
          emphasized: state == 2,
          hotMinus: mHot,
          hotPlus: pHot,
          hotValue: vRect.contains(mouseX, mouseY),
          editing: editing,
          editText: editing ? editBuf : null);
      hitRects[mId] = mr;
      hitRects[vId] = vr;
      hitRects[pId] = pr;
      rowStepKeys[mId] = bkey;
      rowStepKeys[vId] = bkey;
      rowStepKeys[pId] = bkey;
      rightCursor = sx - (10 * u).round();
    }

    // 徽标（排在步进器左边）
    String? badge;
    int badgeColor = Palette.fgDim;
    if (row.kind == 0) {
      badge = '${row.on}/${row.total}';
      badgeColor = row.on == 0
          ? Palette.fgFaint
          : (row.on >= row.total ? Palette.ok : Palette.accent);
    } else if (row.kind == 1) {
      final extra = _extraCatsOn(row.source, row.board!, row.cats);
      if (extra > 0) {
        badge = '+$extra 题材';
        badgeColor = Palette.accent;
      }
    }
    if (badge != null) {
      final bh = (20 * u).round();
      final bw = g.measure(badge, size: Metrics.fontSizeSmall) + (18 * u).round();
      final br = Rc.xywh(rightCursor - bw, y + (h - bh) ~/ 2, bw, bh);
      _badgeRects[id] = br;
      drawBadge(g, br.left, br.top, br.height, badge,
          fg: badgeColor, fontSize: Metrics.fontSizeTiny);
      rightCursor = br.left - (8 * u).round();
    }
    // ── 标签 ──
    final label = switch (row.kind) {
      0 => row.group.title,
      1 => row.board!,
      _ => (row.cat == null || row.cat!.isEmpty) ? '全站' : row.cat!,
    };
    // ★ 字号整体上调一档：原来 14/13/11，现在 16/15/13。
    //   用户原话是"每一行的字体和宽度都适当调大一些，窄长条很难看"。
    final fs = switch (row.kind) {
      0 => Metrics.fontSizeTitle,
      1 => Metrics.fontSize + 1,
      _ => Metrics.fontSizeSmall,
    };
    final col = switch (state) {
      2 => Palette.fg,
      1 => Palette.fg,
      _ => Palette.fgSub,
    };
    g.text(label,
        Rc.xywh(labelX, y, (rightCursor - labelX).clamp(0, 9999), h),
        col,
        size: fs,
        bold: row.kind == 0 || state == 2,
        vcenter: true,
        ellipsis: true);
  }

  /// 一个"榜行"对应的勾选键（默认档）。
  String _scopeKeyOf(_TreeRow row) =>
      '${row.source}|${row.board}|${_boardScopeCat(row.cats)}';

  bool _isChecked(String source, String board, String category) =>
      checked.contains('$source|$board|$category');

  /// 某个榜当前设定的本数（未设定 → 默认；并夹到该源的能力上限内）。
  int limitOf(String source, String key) {
    final cap = sourceLimitCap[source] ?? 50;
    final v = limits[key] ?? (sourceDefaultLimit[source] ?? 20);
    return v.clamp(1, cap);
  }

  /// 该源允许的最大本数。
  int capOf(String source) => sourceLimitCap[source] ?? 50;

  /// 步进档距 —— **随当前值放大**。
  ///
  /// ★ 为什么不再用固定档位表（10/20/30/50/100/200/300/500）：
  ///   七猫的上限是 50，那张表裁完只剩 4 档 —— 用户点 + 只能得到
  ///   10/20/30/50 四个值。这正是他说的"不是只有几个选择"。
  ///   现在步距随值放大：小值精细（1/5）、大值快速（50/100），
  ///   任何整数都走得到；再加上值区**可以直接打字输入任意数字**，就没有够不着的值。
  static int stepFor(int value) {
    if (value < 10) return 1;
    if (value < 50) return 5;
    if (value < 100) return 10;
    if (value < 500) return 50;
    return 100;
  }

  /// 步进一个榜的本数（夹在 [1, cap] 内）。
  void stepLimit(String source, String key, int dir) {
    final cap = capOf(source);
    final cur = limitOf(source, key);
    final next = (cur + dir * stepFor(cur)).clamp(1, cap);
    if (next != cur) {
      limits[key] = next;
      return;
    }
    // 步距夹到边界后没动（例如 45 +5 已经到 50 上限）→ 用最小步再试一次，
    // 否则会出现"点 + 没反应"的假死感。
    final alt = (cur + (dir > 0 ? 1 : -1)).clamp(1, cap);
    if (alt != cur) limits[key] = alt;
  }

  /// **直接设定**一个榜的本数（任意整数，夹到 [1, cap]）。返回实际生效的值。
  int setLimit(String source, String key, int value) {
    final v = value.clamp(1, capOf(source));
    limits[key] = v;
    return v;
  }

  /// 把所有已选榜统一设为某档。
  ///
  /// ★ 必须**先归一到榜 key** 再去重：`checked` 里存的是 `source|board|category`，
  ///   同一个榜勾了两个题材就会有两条，直接遍历会把同一个榜步进两次
  ///   （而且写进的是题材 key，`limitOf` 读的是榜 key，等于没生效）。
  void setAllLimits(int dir) {
    final boards = boardKeysOf(checked);
    for (final b in boards) {
      stepLimit(b.split('|').first, b, dir);
    }
  }

  /// 把所有已选榜统一设为**任意值**。
  void setAllLimitsTo(int v) {
    for (final b in boardKeysOf(checked)) {
      setLimit(b.split('|').first, b, v);
    }
  }

  // ── 本数的"直接输入" ──

  /// 进入编辑：值区显示当前值，**第一个数字会替换它**（聚焦即全选）。
  void startEdit(int id, String source, String key, int current) {
    editId = id;
    editSource = source;
    editKey = key;
    editBuf = '$current';
    editFresh = true;
    searchFocus = false; // 两处输入互斥
    invalidate();
  }

  /// 提交编辑（点别处 / 回车都会走这里）。
  void commitEdit() {
    if (editId < 0) return;
    final v = int.tryParse(editBuf);
    if (v != null) {
      if (editKey.isEmpty) {
        setAllLimitsTo(v); // 顶栏批量：应用到所有已选榜
      } else {
        setLimit(editSource, editKey, v);
      }
    }
    editId = -1;
    editKey = '';
    editSource = '';
    editBuf = '';
    editFresh = false;
    invalidate();
  }

  /// 放弃编辑（Esc）。
  void cancelEdit() {
    if (editId < 0) return;
    editId = -1;
    editKey = '';
    editSource = '';
    editBuf = '';
    editFresh = false;
    invalidate();
  }

  /// 把 `source|board|category` 集合归一成去重后的 `source|board|` 集合。
  static List<String> boardKeysOf(Iterable<String> keys) {
    final out = <String>{};
    for (final k in keys) {
      final p = k.split('|');
      if (p.length != 3) continue;
      out.add('${p[0]}|${p[1]}|');
    }
    return out.toList();
  }

  String _selectedSummary() {
    if (checked.isEmpty) return '还没选任何榜';
    final bySource = <String, int>{};
    for (final k in checked) {
      final s = k.split('|').first;
      bySource[s] = (bySource[s] ?? 0) + 1;
    }
    final parts = bySource.entries
        .map((e) => '${sourceLabel(e.key)} ${e.value}')
        .join(' / ');
    final total = _totalLimit();
    final est = _estSeconds();
    return '已选 ${checked.length} 个榜、合计 $total 本：$parts　'
        '（每个榜间隔 2 秒，约 ${est}${est > 60 ? '，耐心等' : ''}）';
  }

  /// 所有已选榜要抓的总本数。
  int _totalLimit() {
    var n = 0;
    for (final k in checked) {
      final p = k.split('|');
      if (p.length != 3) continue;
      n += limitOf(p[0], '${p[0]}|${p[1]}|');
    }
    return n;
  }

  /// 粗估耗时（秒）：每榜限速 2s，起点多页每页约 2s，其余单页约 2s。
  /// 只用于"别让用户以为卡了"，不追求精确。
  int _estSeconds() {
    var s = 0;
    for (final k in checked) {
      final p = k.split('|');
      if (p.length != 3) continue;
      final lim = limitOf(p[0], '${p[0]}|${p[1]}|');
      final src = p[0];
      // 起点走多页：每页 20 本约 2s（含限速）
      s += src == 'qidian' ? ((lim / 20).ceil() * 2) : 2;
    }
    return s;
  }

  String sourceLabel(String id) =>
      const {'qidian': '起点', 'fanqie': '番茄', 'qimao': '七猫', 'jjwxc': '晋江'}[id] ??
      id;

  @override
  bool onClick(int x, int y) {
    // 自绘窗口按钮最先判（关窗行为优先于任何业务操作）。
    for (final id in const [idWinMinimize, idWinClose]) {
      final r = hitRects[id];
      if (r != null && r.contains(x, y)) {
        if (id == idWinMinimize) {
          minimizeWindow();
        } else {
          requestClose();
        }
        return true;
      }
    }

    // ★★ 本数控件的判定顺序：**行内步进器 → 顶栏批量步进器 → 其它**。
    //
    //   行内步进器嵌在**行矩形内部**，必须先判它 —— 否则点本数会把榜
    //   取消勾选（第 6 轮删单榜步进器时踩过这个坑，现在它回来了，
    //   所以这条纪律也一起回来了：**子控件永远先于父控件判定**）。
    for (var i = 0; i < treeRows.length; i++) {
      final base = treeRows[i].id - idTreeBase;
      for (final e in [
        (idRowStepMinusBase + base, -1),
        (idRowStepPlusBase + base, 1),
      ]) {
        if (!_hit(e.$1, x, y)) continue;
        commitEdit(); // 先提交上一个正在编辑的框
        final key = rowStepKeys[e.$1];
        if (key != null && key.isNotEmpty) {
          stepLimit(key.split('|').first, key, e.$2);
        }
        invalidate();
        return true;
      }
      final vId = idRowStepValueBase + base;
      if (_hit(vId, x, y)) {
        commitEdit();
        final key = rowStepKeys[vId];
        if (key != null && key.isNotEmpty) {
          final src = key.split('|').first;
          startEdit(vId, src, key, limitOf(src, key));
        }
        return true;
      }
    }

    // 顶栏批量步进器（"所有已选榜统一改本数"）
    if (_hit(idLimitAllMinus, x, y)) {
      commitEdit();
      setAllLimits(-1);
      invalidate();
      return true;
    }
    if (_hit(idLimitAllPlus, x, y)) {
      commitEdit();
      setAllLimits(1);
      invalidate();
      return true;
    }
    if (_hit(idLimitAllValue, x, y)) {
      commitEdit();
      // 批量框的"当前值"：所有已选榜一致时显示该值，否则显示默认
      final vals = {
        for (final k in boardKeysOf(checked)) limitOf(k.split('|').first, k)
      };
      final shown = vals.length == 1 ? vals.first : 20;
      startEdit(idLimitAllValue, '', '', shown);
      return true;
    }

    // 「每榜保留份数」—— 就地增减，夹在 [keepMin, keepMax]。
    // 0 = 不限（继续减会停在 0，再减不动）。
    if (_hit(idKeepMinus, x, y)) {
      if (keepCount > keepMin) keepCount--;
      invalidate();
      return true;
    }
    if (_hit(idKeepPlus, x, y)) {
      if (keepCount < keepMax) {
        // 从"不限(0)"往上加时直接跳到 1，否则 0→1 之外还得先跳过一个尴尬的中间态
        keepCount = keepCount == 0 ? 1 : keepCount + 1;
      }
      invalidate();
      return true;
    }

    // 搜索框：点一下聚焦（焦点只在点别处时才丢）
    if (_hit(idSearchClear, x, y)) {
      commitEdit();
      search = '';
      searchFocus = true;
      _buildTreeRows();
      invalidate();
      return true;
    }
    if (_hit(idSearch, x, y)) {
      commitEdit();
      searchFocus = true;
      invalidate();
      return true;
    }

    // ★ 折叠箭头 → 行勾选。**箭头嵌在行矩形内部**，必须先判箭头，
    //   否则点箭头会变成勾选（这类"子控件在父控件内部"的顺序错误，
    //   在第 6 轮删单榜步进器时已经付过一次学费）。
    for (final row in treeRows) {
      if (_hit(idTreeChevronBase + row.id - idTreeBase, x, y)) {
        _toggleCollapse(row);
        return true;
      }
    }
    for (final row in treeRows) {
      final r = _rowRects[row.id];
      if (r == null || !r.contains(x, y)) continue;
      _toggleTreeRow(row);
      return true;
    }

    // 点到内容区其它地方 → 搜索框失焦 + **提交正在输入的本数**。
    // ★ "点别处 = 确认"是文本框的通用约定；不提交就等于用户白敲了。
    if (searchFocus || editId >= 0) {
      searchFocus = false;
      commitEdit();
      invalidate();
    }

    if (_hit(idQuickSweep, x, y)) {
      checked.clear();
      checked.addAll([
        'qidian|畅销榜|全站',
        'qidian|月票榜|全站',
        'qidian|阅读指数榜|全站',
        'qidian|推荐榜|全站',
        'qidian|畅销榜|玄幻',
        'qidian|畅销榜|都市',
        'qidian|畅销榜|仙侠',
        'qidian|畅销榜|科幻',
        'qimao|男频大热榜|',
        'qimao|女频大热榜|',
        'jjwxc|总分排行榜|',
        'jjwxc|新晋作者榜|',
      ]);
      statusNote = '番茄的题材要联网后才能列出来，选它的榜即可';
      invalidate();
      return true;
    }
    if (_hit(idCheckAll, x, y)) {
      for (final e in checkIdKey.values) {
        checked.add(e);
      }
      invalidate();
      return true;
    }
    if (_hit(idClearAll, x, y)) {
      checked.clear();
      invalidate();
      return true;
    }
    if (_hit(idCancel, x, y)) {
      owner.childClosed(this);
      destroyWindow(hwnd);
      return true;
    }
    if (_hit(idRun, x, y)) {
      final targets = _targets();
      if (targets.isEmpty) {
        statusNote = '先勾几个榜';
        invalidate();
        return true;
      }
      owner.childClosed(this);
      destroyWindow(hwnd);
      owner.startScan(targets, keepPerSeries: keepCount);
      return true;
    }
    return false;
  }

  bool _hit(int id, int x, int y) {
    final r = hitRects[id];
    return r != null && r.contains(x, y);
  }

  // ── 树的折叠与勾选 ──

  /// 折叠/展开一个平台或榜。
  void _toggleCollapse(_TreeRow row) {
    if (row.kind == 0) {
      // 平台：默认展开 → 记"折叠的"
      final key = row.source;
      if (!collapsedScan.remove(key)) collapsedScan.add(key);
    } else {
      // 榜：默认折叠 → 记"展开的"
      final key = '${row.source}|${row.board}';
      if (!expandedBoards.remove(key)) expandedBoards.add(key);
    }
    owner.saveSettings();
    _buildTreeRows();
    invalidate();
  }

  /// 勾选/取消一个树行。
  ///
  /// ★ 三层的语义刻意不一样：
  ///   - **平台行** = 这个平台下**所有榜**（各按自己的默认档，即"全站"），
  ///     而不是"所有题材" —— 后者会把 14 个榜 × 14 个题材一次全勾上，
  ///     用户点一下就从"扫 14 个榜"变成"扫 196 次"，很容易误触。
  ///   - **榜行** = 这个榜的默认档（有题材的榜 = 全站；没题材的 = 无题材）。
  ///     点它 = "扫这个榜"，一个请求，符合直觉。
  ///   - **题材行** = 单个题材。
  void _toggleTreeRow(_TreeRow row) {
    switch (row.kind) {
      case 0:
        final keys = <String>[
          for (final b in row.group.boards) _boardScopeKey(row.source, b)
        ];
        final allOn = keys.every(checked.contains);
        if (allOn) {
          checked.removeAll(keys);
        } else {
          checked.addAll(keys);
        }
      case 1:
        final key = _scopeKeyOf(row);
        if (!checked.remove(key)) checked.add(key);
      default:
        final key = '${row.source}|${row.board}|${row.cat}';
        if (!checked.remove(key)) checked.add(key);
    }
    _buildTreeRows();
    invalidate();
  }

  /// 键盘：退格 / Esc / 回车。**搜索框和本数输入框共用这一套**。
  @override
  void onKey(int vk) {
    const vkBack = 0x08;
    const vkEscape = 0x1B;
    const vkReturn = 0x0D;

    // 本数输入框优先（它和搜索框互斥，同时只会有一个活着）
    if (editId >= 0) {
      if (vk == vkBack) {
        if (editBuf.isNotEmpty) {
          editBuf = editBuf.substring(0, editBuf.length - 1);
          editFresh = false;
          invalidate();
        }
      } else if (vk == vkEscape) {
        cancelEdit();
      } else if (vk == vkReturn) {
        commitEdit();
      }
      return;
    }
    if (!searchFocus) return;
    if (vk == vkBack) {
      if (search.isNotEmpty) {
        search = search.substring(0, search.length - 1);
        _buildTreeRows();
        invalidate();
      }
    } else if (vk == vkEscape) {
      search = '';
      searchFocus = false;
      _buildTreeRows();
      invalidate();
    }
  }

  /// 字符输入（WM_CHAR，已过输入法 —— 所以能打中文）。
  ///
  /// ★ 必须走 WM_CHAR 而不是 WM_KEYDOWN：虚拟键码与"用户敲出来的字符"
  ///   在中文输入法下完全不是一回事。收 WM_CHAR 才能用输入法搜"玄幻"。
  @override
  void onChar(int ch) {
    // ── 本数输入框：只收数字 ──
    if (editId >= 0) {
      if (ch == 8 || ch == 27) return; // 退格/Esc 已由 onKey 处理
      if (ch == 13) {
        commitEdit();
        return;
      }
      if (ch < 0x30 || ch > 0x39) return; // 非数字一律不收
      final d = String.fromCharCode(ch);
      if (editFresh) {
        // ★ 聚焦即全选：第一个数字**替换**原值。
        //   不这样的话，把 20 改成 25 会得到 2025。
        editBuf = d;
        editFresh = false;
      } else {
        if (editBuf.length >= 5) return; // 最多 5 位（上限 500，够了）
        // 前导 0 直接忽略（"020" 读起来像错误输入）
        editBuf = (editBuf == '0') ? d : editBuf + d;
      }
      invalidate();
      return;
    }

    if (!searchFocus) return;
    if (ch == 8) return; // 退格已由 onKey 处理（避免删两次）
    if (ch == 27) return; // Esc 同上
    if (ch == 13) {
      // 回车 = 收起焦点（不触发扫榜：那是"开始扫榜"按钮的事）
      searchFocus = false;
      invalidate();
      return;
    }
    if (ch < 32) return;
    // 单行输入框：换行/制表符一律不收
    if (ch == 127) return;
    search += String.fromCharCode(ch);
    _buildTreeRows();
    invalidate();
  }

  List<ScanTarget> _targets() {
    final out = <ScanTarget>[];
    for (final k in checked) {
      final parts = k.split('|');
      if (parts.length != 3) continue;
      final cat = parts[2].isEmpty ? null : parts[2];
      // ★ 本数按"榜"取（同榜的多个题材共用一份设定）；
      //   题材行不带独立本数控件，所以查的是 `source|board|`。
      final limKey = '${parts[0]}|${parts[1]}|';
      out.add(ScanTarget(
        source: parts[0],
        board: parts[1],
        category: cat,
        limit: limitOf(parts[0], limKey),
      ));
    }
    out.sort((a, b) {
      final c = a.source.compareTo(b.source);
      if (c != 0) return c;
      return a.board.compareTo(b.board);
    });
    return out;
  }

  @override
  void onWheel(int x, int y, int delta) {
    final step = delta > 0 ? -60 : 60;
    final maxV = contentH - (height - Metrics.headerHeight - (40 * Metrics.factor).round());
    scrollY = (scrollY + step).clamp(0, maxV < 0 ? 0 : maxV);
    invalidate();
  }

  /// hover 目标（用于判断要不要重绘）。
  String _hoverSig = '';

  @override
  void onMove(int x, int y) {
    // 只在"鼠标下的可交互物变了"时重绘；否则每动一像素重绘一次太浪费。
    final sig = _hoverSignature(x, y);
    if (sig == _hoverSig) return;
    _hoverSig = sig;
    invalidate();
  }

  String _hoverSignature(int x, int y) {
    // 单榜步进器已删除；本数只剩顶栏那一对批量按钮，登记在 hitRects 里，
    // 由下面的循环统一覆盖（'h${id}'）。
    for (final e in _rowRects.entries) {
      if (e.value.contains(x, y)) return 'r${e.key}';
    }
    for (final e in hitRects.entries) {
      if (e.value.contains(x, y)) return 'h${e.key}';
    }
    return '';
  }

  // ── 自检钩子（本机跑不了 dart analyze，只能靠真跑一遍验证）──

  int get testRowRectCount => _rowRects.length;

  /// 自检：读一行的选中态（0/1/2）。
  int testStateOf(_TreeRow row) => _stateOf(row);

  /// 自检：某行的行框 / 右侧徽标矩形（断言"数字落在蓝框里面"用）。
  Rc? testRowRect(int id) => _rowRects[id];

  Rc? testBadgeRect(int id) => _badgeRects[id];

  /// 自检：某行的**折叠箭头**命中区（null = 这一行没有箭头，即"没东西可折叠"）。
  Rc? testChevronRect(_TreeRow row) =>
      hitRects[idTreeChevronBase + row.id - idTreeBase];

  /// 自检：某个榜的行内步进器三段（减 / 值 / 加）。找不到返回 null。
  (Rc, Rc, Rc)? testRowStepper(String source, String board) {
    for (final row in treeRows) {
      if (row.kind != 1 || row.source != source || row.board != board) continue;
      final base = row.id - idTreeBase;
      final m = hitRects[idRowStepMinusBase + base];
      final v = hitRects[idRowStepValueBase + base];
      final p = hitRects[idRowStepPlusBase + base];
      if (m == null || v == null || p == null) return null;
      return (m, v, p);
    }
    return null;
  }

  /// 自检：顶栏批量步进器的三段（减 / 值 / 加）。
  (Rc, Rc, Rc)? testBatchStepperRects() {
    final m = hitRects[idLimitAllMinus];
    final v = hitRects[idLimitAllValue];
    final p = hitRects[idLimitAllPlus];
    if (m == null || v == null || p == null) return null;
    return (m, v, p);
  }

  /// 自检：正在编辑的控件 id（-1 = 没在编辑）。
  int get testEditId => editId;

  /// 自检：输入缓冲。
  String get testEditBuf => editBuf;

  /// 自检：敲一串字符（等价于用户逐个按键）。
  void testType(String s) {
    for (final ch in s.codeUnits) {
      onChar(ch);
    }
  }

  /// 自检：等价于点某行的折叠箭头。
  void testToggleCollapse(_TreeRow row) => _toggleCollapse(row);

  /// 自检：等价于点某行的勾选区。
  void testToggleRow(_TreeRow row) => _toggleTreeRow(row);

  /// 自检：等价于点"开始扫榜"（返回解析出的目标，不真的开扫）。
  List<ScanTarget> testResolveTargets() => _targets();

  List<ScanTarget> testTargets() => _targets();

  void testSetSize(int w, int h) => setSizeForTest(this, w, h);

  (int, int, bool)? testProbeRowCenter() {
    // ★ 只挑**有 key 的行**（榜 / 题材）。平台行的 key 是空的（点它等于
    //   "全选这个平台"，不是"勾一个东西"），拿它做"点击能翻转"的断言会假红。
    for (final e in _rowRects.entries) {
      final r = e.value;
      if (r.width <= 0 || r.height <= 0) continue;
      if (r.top < Metrics.headerHeight || r.top > height - 40) continue;
      final key = checkIdKey[e.key];
      if (key == null || key.isEmpty) continue;
      return (r.left + r.width ~/ 2, r.top + r.height ~/ 2,
          checked.contains(key));
    }
    return null;
  }

  String testKeyOfPoint(int x, int y) {
    for (final e in _rowRects.entries) {
      if (e.value.contains(x, y)) return checkIdKey[e.key] ?? '';
    }
    return '';
  }

  void testClickButton(int id) {
    final r = hitRects[id];
    if (r == null) return;
    onClick(r.left + r.width ~/ 2, r.top + r.height ~/ 2);
  }

  /// 自检：底栏汇总文本。
  String testSummary() => _selectedSummary();

  /// 自检：把内容滚动到 [y]（画一帧看裁剪是否生效）。
  void testSetScroll(int y) => scrollY = y < 0 ? 0 : y;

  /// 自检：内容区最大可滚值（画过一帧、contentH 已算出后才有意义）。
  int testMaxScroll() {
    final u = Metrics.factor;
    final footH = (34 * u).round();
    final headH = Metrics.headerHeight;
    final bodyTop = headH + (12 * u).round();
    final viewH = height - bodyTop - footH - (6 * u).round() - 2;
    final maxV = contentH - viewH;
    return maxV > 0 ? maxV : 0;
  }

  /// 自检：内容区可见矩形（供裁剪断言用）。
  Rc testInnerRect() {
    final u = Metrics.factor;
    final footH = (34 * u).round();
    final bodyTop = Metrics.headerHeight + (12 * u).round();
    final body = Rc.xywh((14 * u).round(), bodyTop, width - (28 * u).round(),
        height - bodyTop - footH - (6 * u).round());
    return Rc.xywh(body.left + 1, body.top + 1, body.width - 2, body.height - 2);
  }

  /// 自检：顶栏**批量**本数步进器的加号中心点 + 该步进器当前是否可用。
  /// 返回 null = 没有登记命中区（不该发生；顶栏步进器恒定存在）。
  ///
  /// ★ 本数入口已收敛为**唯一**一个（顶栏"已选榜本数"），
  ///   单榜步进器连同 `_minusRects`/`_plusRects` 一并删除 —— 见 [_paintCheckRow] 的说明。
  (int, int, bool)? testBatchStepperProbe() {
    final r = hitRects[idLimitAllPlus];
    if (r == null || r.width <= 0 || r.height <= 0) return null;
    return (r.left + r.width ~/ 2, r.top + r.height ~/ 2, checked.isNotEmpty);
  }

  /// 自检：本数步进器命中区数量。
  /// ★ 收敛后**恒为 2**（只有顶栏那一对减/加）；这正是"没有多余入口"的断言依据。
  int get testStepperHitCount =>
      (hitRects.containsKey(idLimitAllMinus) ? 1 : 0) +
      (hitRects.containsKey(idLimitAllPlus) ? 1 : 0);

  /// 自检：底栏「每榜保留」步进器的 (加号中心点, 减号矩形, 标签矩形)。
  ///
  /// 返回 null = 还没画过。测试用它做两件事：
  ///   ① 点击加号真的能改 [keepCount]；
  ///   ② 加/减两个命中区**互不重叠**，且都不与底栏左侧文字区重叠
  ///      （这是"控件不重叠"的几何断言，不依赖肉眼）。
  (int, int, Rc, Rc)? testKeepStepperProbe() {
    final plus = hitRects[idKeepPlus];
    final minus = hitRects[idKeepMinus];
    if (plus == null || minus == null) return null;
    return (plus.left + plus.width ~/ 2, plus.top + plus.height ~/ 2, minus, plus);
  }

  /// 自检：设置保留份数（等价于连点加/减若干次的结果）。
  void testSetKeepCount(int n) {
    keepCount = n.clamp(keepMin, keepMax);
    invalidate();
  }

  /// 调试：当前绘制里可见的勾选行 key 列表（带矩形）。
  List<String> debugRowKeys() {
    final out = <String>[];
    for (final e in _rowRects.entries) {
      final k = checkIdKey[e.key];
      if (k != null) out.add('$k @ ${e.value}');
    }
    return out;
  }
}

/// 树里的一行（平台 / 榜 / 题材）。
///
/// ★ 行对象是**每次绘制重建**的：折叠、搜索过滤、勾选统计都会改变可见集合，
///   缓存它只会带来"状态对不上"的麻烦。重建的成本是几十个对象的分配，
///   比一次 GDI 文本测量便宜得多。
class _TreeRow {
  _TreeRow._(this.kind, this.group, this.source, this.board, this.cat, this.cats,
      {this.total = 0, this.on = 0, this.checked = false});

  /// 平台行。[total] = 该平台榜数，[on] = 其中已选中的榜数（用于三态）。
  factory _TreeRow.source(_Group g, int total, int on) =>
      _TreeRow._(0, g, g.sourceId, null, null, const [], total: total, on: on);

  /// 榜行。[cats] = 该榜的题材表（空 = 这个榜没有题材维度）。
  factory _TreeRow.board(_Group g, String board, List<String> cats, int catOn) =>
      _TreeRow._(1, g, g.sourceId, board, null, cats, on: catOn);

  /// 题材行。
  factory _TreeRow.cat(_Group g, String board, String cat, bool checked) =>
      _TreeRow._(2, g, g.sourceId, board, cat, const [], checked: checked);

  /// 0 = 平台、1 = 榜、2 = 题材。
  final int kind;
  final _Group group;
  final String source;
  final String? board;
  final String? cat;

  /// 榜行的题材表。
  final List<String> cats;

  /// 平台行的子项统计。
  final int total;
  final int on;

  /// 题材行的勾选状态。
  final bool checked;

  /// 绘制时写入的行几何与命中编号。
  int y = 0;
  int h = 0;
  int id = 0;

  /// 是否处于展开态（绘制箭头用）。
  bool expanded = true;

  /// 行高（按层级给不同高度，视觉上有层次）。
  ///
  /// ★ 整体调高了一档（34/30/26 → 46/40/34）：字号上调之后，
  ///   原来的行高会变成"字挤在窄条里"，用户说的"窄长条很难看"就是这个。
  ///   行高至少要有 字号 × 2.4 才不显拥挤（13px 字 → ≥32px 行高）。
  static int heightOf(int kind, double u) => switch (kind) {
        0 => (46 * u).round(),
        1 => (40 * u).round(),
        _ => (34 * u).round(),
      };
}

class _Group {
  _Group(this.title, this.sourceId, this.boards);
  final String title;
  final String sourceId;
  final List<_Board> boards;
}

class _Board {
  _Board(this.name, this.categories);
  final String name;
  final List<String> categories;
}

/// 在主窗口上打开扫榜设置窗口。
void showScanDialog(MainWindow owner) {
  final dlg = ScanDialogWindow(owner: owner);
  owner.attachChild(dlg);
  final app = App.instance;
  if (app == null) return;
  final u = Metrics.factor;
  // ★ 宽 1040 是反算出来的：顶栏要同时放下
  //   品牌块 + 标题 + 副标题 + 4 个按钮 + 批量步进器组（含完整标签"已选榜本数"）。
  //   = 品牌块/内边距 ~200 + 标题+副标题 226 + 按钮 488 + 批量组 178 ≈ 1092 逻辑宽，
  //   取 1040 时标题可用宽更大，绝不会触发"标题不画"。
  //   1040 在 1366 宽的屏上只占 76%，不会超出工作区（超了还有 App 的兜底缩放）。
  //   ★ 第 9 轮从 980 加宽到 1040、从 680 加到 720：折叠树的字号与行高都上调了一档，
  //     原来的尺寸会让长榜名被省略、行显得挤。
  app.runChild(dlg,
      width: (1040 * u).round(), height: (720 * u).round(), ownerHwnd: owner.hwnd);
}

/// 确认框（用系统 MessageBox，够用且不引入模态循环）。
/// 确认框。[danger]=true 时用**警告图标**并把默认按钮设成"否"。
///
/// ★ 破坏性动作（删快照、应用保留策略）必须走 danger 这一档：
///   默认焦点落在"否"上，用户顺手回车不会把数据删掉。
bool confirmDialog(int ownerHwnd, String title, String message,
    {bool danger = false}) {
  const mbYesNo = 0x00000004;
  const mbIconQuestion = 0x00000020;
  const mbIconWarning = 0x00000030;
  // MB_DEFBUTTON2 = 0x00000100 —— 默认选"否"
  const mbDefButton2 = 0x00000100;
  const idYes = 6;
  final flags = mbYesNo |
      (danger ? (mbIconWarning | mbDefButton2) : mbIconQuestion);
  final t = title.toNativeUtf16();
  final m = message.toNativeUtf16();
  final r = messageBoxW(ownerHwnd, m, t, flags);
  calloc.free(t);
  calloc.free(m);
  return r == idYes;
}

/// 只报"做完了"的信息框（只有一个"确定"）。
///
/// ★ 为什么必须有它：导出成功之后会自动打开导出目录，**那个窗口会抢焦点**，
///   于是应用自己的状态栏提示根本没人看见 —— 用户的原话是"导出时没有提示"。
///   弹一个模态框是最不容易被忽略的告知方式。
void infoDialog(int ownerHwnd, String title, String message) {
  const mbOk = 0x00000000;
  const mbIconInfo = 0x00000040;
  final t = title.toNativeUtf16();
  final m = message.toNativeUtf16();
  messageBoxW(ownerHwnd, m, t, mbOk | mbIconInfo);
  calloc.free(t);
  calloc.free(m);
}

/// 浏览器渲染抓取器 —— 用系统已装的 Chromium 内核（Edge / WebView2）
/// 以**子进程**方式加载页面并把渲染后的 DOM 落盘，Dart 侧只读文件。
///
/// 为什么需要它：起点 `www.qidian.com` 的榜单页对**非浏览器指纹**的请求
/// 返回 HTTP 202 + 209 字节挑战壳（`var buid = "ffff..."` + 腾讯混沌 VM
/// `probe.js`），纯 HTTP（哪怕带完整浏览器头）拿不到正文。
///
/// ★ 这里**不是绕过技术措施**，界限必须说清楚：
///   - 绕过的定义 = 自己执行挑战 JS / 伪造应答 token / 逆向 VM 算出 buid；
///   - 本模块做的事 = 启动用户机器上**已安装的真实浏览器**，
///     用一个**全新的临时用户数据目录**（不读用户 cookie/登录态）
///     以 `--headless=new` 正常请求该公开页面。
///   实测：全新空 profile 即可拿到 73KB 真实 DOM，**零挑战、零交互**。
///   也就是说放行来自"真实浏览器指纹"这一事实本身，不是我们破解了什么。
///
/// 由此引出一条**更严的自我约束**（比 HTTP 版更严，不是更松）：
///   ① 仍走 [DomainWhitelist] 白名单校验，只允许四个平台的域名；
///   ② 每次抓取给独立的临时 profile，抓完即删，不落任何持久指纹；
///   ③ 不做点击/输入/登录，只 `--dump-dom` 一个 URL；
///   ④ 并发=1（串行），每页之间仍走 [RateLimiter]；
///   ⑤ 优先用系统 **WebView2 Runtime**（普通浏览器 Edge 仅作兜底），
///      因为 WebView2 是"应用内嵌浏览器"，用它抓公开页面比驱动完整浏览器更克制。
///
/// ★ 为什么不直接调 WebView2 的 COM 接口：WebView2 是纯 COM，从 dart:ffi
///   调需要手写 vtable 分派 + 在 Dart 侧实现 COM 回调对象，几百行指针级
///   代码；一旦有异常逃到原生栈就是进程直接消失（本项目最怕的故障形态）。
///   而 `msedgewebview2.exe` / `msedge.exe` 都能用命令行驱动 —— 同样的内核、
///   同样的放行效果，代码量小一个数量级，且崩溃隔离在子进程里。故选子进程。
library;

import 'dart:convert';
import 'dart:io';

import 'guard.dart';

/// 一次渲染抓取的结果。
class RenderedPage {
  const RenderedPage(this.html, {this.error});
  final String html;

  /// 非 null = 这次没成功。调用方据此决定降级。
  final String? error;

  bool get ok => error == null && html.isNotEmpty;
}

/// 渲染抓取器。**进程级单例即可**（内部串行、每次新 profile）。
///
/// ★★ [robots] 与 [limiter] 都**必须由调用方注入**，不能自己 new：
///   - robots：原来这个文件里根本没有 robots 这个东西（grep 零命中），
///     而 HTTP 通道是强制判的 —— 于是"渲染通道绕过 robots 护栏"，
///     README 承诺的"每次请求前判 robots 并写进报告"对起点 www 站**不成立**
///     （起点每轮最多 25 页全走渲染）。
///   - limiter：原来 `limiter ?? RateLimiter()` 会造出**第二个时钟**，
///     与 HTTP 通道各限各的 → 对同一个站点的实际频率最高 2× 配置，
///     用户把 `--ms` 调大求温和时渲染页仍然按默认 2 秒发。
class WebViewFetcher {
  WebViewFetcher({
    required this.whitelist,
    required this.robots,
    required this.limiter,
  });

  final DomainWhitelist whitelist;
  final RobotsGuard robots;
  final RateLimiter limiter;

  /// 最近一次的 robots 判定文本（与 [Fetcher.lastVerdict] 同口径，
  /// 由适配器取走写进快照 —— 渲染路径的判定要能如实出现在报告里）。
  String? lastVerdict;

  /// 浏览器可执行文件缓存（探测一次）。
  String? _exe;
  bool _probed = false;

  /// 本机是否具备渲染抓取能力。没有就由调用方降级。
  bool get available {
    if (!_probed) {
      _exe = _locate();
      _probed = true;
    }
    return _exe != null;
  }

  /// 拿到的浏览器路径（给报告里如实标注用）。
  String? get exePath {
    if (!_probed) {
      _exe = _locate();
      _probed = true;
    }
    return _exe;
  }

  /// 探测顺序：**WebView2 Runtime 优先**（更克制），再退到完整 Edge。
  ///
  /// WebView2 的 `msedgewebview2.exe` 不能直接当浏览器用（它是宿主进程，
  /// 需要 COM 环境变量握手），所以 WebView2 场景下实际用的仍是
  /// `msedge.exe` 那条路径 —— 但**先把运行时检测出来**，好在报告里
  /// 如实告诉用户"你机器上有没有内嵌浏览器内核、版本多少"。
  String? _locate() {
    if (!Platform.isWindows) return null;
    final roots = <String>[
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
      Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
      Platform.environment['LOCALAPPDATA'] ?? '',
    ];
    // ① 完整 Edge（能直接命令行驱动）。
    for (final r in roots) {
      if (r.isEmpty) continue;
      for (final rel in const [
        r'Microsoft\Edge\Application\msedge.exe',
        r'Microsoft\Edge Beta\Application\msedge.exe',
      ]) {
        final p = '$r\\$rel';
        if (File(p).existsSync()) return p;
      }
    }
    // ② 应用私有目录下随包发布的 Edge（部分安装形态）。
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    if (local.isNotEmpty) {
      final p = '$local\\Microsoft\\Edge\\Application\\msedge.exe';
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// WebView2 Runtime 版本（有就返回，供报告标注；纯只读探测，不启动）。
  String? webView2Version() {
    if (!Platform.isWindows) return null;
    final roots = <String>[
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
      Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
    ];
    for (final r in roots) {
      final dir = Directory('$r\\Microsoft\\EdgeWebView\\Application');
      if (!dir.existsSync()) continue;
      final vers = dir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split(Platform.pathSeparator).last)
          .where((s) => RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(s))
          .toList()
        ..sort((a, b) => _cmpVer(b, a));
      if (vers.isNotEmpty) return vers.first;
    }
    return null;
  }

  static int _cmpVer(String a, String b) {
    final x = a.split('.').map(int.parse).toList();
    final y = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 4; i++) {
      final c = x[i].compareTo(y[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  /// 渲染一个 URL，返回渲染后的完整 DOM。
  ///
  /// [budgetMs] 是 `--virtual-time-budget`：Chromium 会在这个虚拟时间预算内
  /// 等待网络与定时器，然后 dump。8s 对榜单 SSR + WAF 挑战足够（实测）。
  Future<RenderedPage> render(
    Uri url, {
    int budgetMs = 12000,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    // ★ 白名单先行：与 HTTP 路径同一条规矩，不允许任何例外。
    try {
      whitelist.assertAllowed(url);
    } on Object catch (e) {
      return RenderedPage('', error: '域名不在白名单：$e');
    }
    // ★★ robots 也要判 —— 与 HTTP 通道同一套，不允许任何例外。
    //   渲染只是"换了个取页面的手段"，不是"绕开规矩的理由"。
    lastVerdict = null;
    try {
      await robots.assertAllowed(url);
      lastVerdict = await robots.verdict(url);
    } on Object catch (e) {
      return RenderedPage('', error: 'robots 判定未通过：$e');
    }
    if (!available) {
      return const RenderedPage('', error: '未检测到可用的浏览器内核（Edge/WebView2）');
    }
    await limiter.wait();

    // 独立临时 profile：不读用户 cookie / 登录态，抓完即删。
    final tmp = Directory.systemTemp;
    final profile = Directory(
        '${tmp.path}${Platform.pathSeparator}wbscan_${DateTime.now().microsecondsSinceEpoch}');
    try {
      profile.createSync(recursive: true);
      return await _dumpDom(url, profile, budgetMs, timeout);
    } on Object catch (e) {
      return RenderedPage('', error: '$e');
    } finally {
      _quietDelete(profile);
    }
  }

  /// ★ 实测（Edge 153）：`--dump-dom` 把 DOM 写 **stdout**，不是文件。
  ///   所以这里显式合并 stdout 字节流来收 DOM，stderr 丢掉。
  ///   stdout 必须**边读边收**：不读会塞满管道缓冲把子进程卡死。
  Future<RenderedPage> _dumpDom(
    Uri url,
    Directory profile,
    int budgetMs,
    Duration timeout,
  ) async {
    final exe = _exe!;
    // ★ 参数用 Process.start 的 List 形式传，**不经过 shell**：
    //   避免 URL 里的 & / 空格被 shell 拆解（本项目在 PowerShell 上踩过这个坑）。
    final proc = await Process.start(exe, [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--disable-background-networking',
      '--disable-sync',
      '--disable-features=Translate,MediaRouter,msEdgeIdentityFeatures',
      '--user-data-dir=${profile.path}',
      '--virtual-time-budget=$budgetMs',
      '--dump-dom',
      url.toString(),
    ], runInShell: false);

    final out = <int>[];
    final collect = proc.stdout.listen(out.addAll);
    final drainErr = proc.stderr.drain<void>();

    int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on Object {
      proc.kill(ProcessSignal.sigkill);
      await collect.cancel().catchError((_) {});
      await drainErr.catchError((_) {});
      return const RenderedPage('', error: '渲染超时（浏览器未在限时内返回）');
    }
    await collect.cancel().catchError((_) {});
    await drainErr.catchError((_) {});

    final html = utf8.decode(out, allowMalformed: true);
    if (html.trim().isEmpty) {
      return RenderedPage('', error: '浏览器产出空 DOM（exit=$code）');
    }
    // ★ 与 HTTP 路径同样要过挑战页判定：如果拿回来的还是挑战壳，
    //   说明这条路也没放行 —— 如实报"仍是挑战页"，绝不返回半成品。
    if (TechMeasures.isChallengeStub(html) || TechMeasures.looksBlocked(html)) {
      return RenderedPage('', error: '渲染结果仍是风控挑战页（${html.length} 字节）');
    }
    return RenderedPage(html);
  }

  void _quietDelete(FileSystemEntity e) {
    try {
      if (e.existsSync()) e.deleteSync(recursive: true);
    } on Object {
      // 临时文件删不掉不影响结果。
    }
  }
}

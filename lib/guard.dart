/// 护栏层 + 传输层 + 内嵌 JSON 提取。
///
/// 四道护栏与 EmbeddedJson 均按 `lib/rank/rank_guard.dart`、
/// `rank_source_web.dart` 的原版思路移植（含他们踩过的坑），
/// demo 里额外加了一条：**robots 判定结果要能打印出来给人看**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class RankPolicyException implements Exception {
  const RankPolicyException(this.reason, {this.code = RankPolicyCode.policyDenied});
  final String reason;
  final RankPolicyCode code;
  @override
  String toString() => 'RankPolicyException($code): $reason';
}

enum RankPolicyCode {
  policyDenied,
  domainNotAllowed,
  robotsDenied,

  /// 无法判定 robots（拿不到文件，且处于保守模式）。与 [robotsDenied] 区分开，
  /// 因为"站点禁止"和"我们没查到"是两件事，报告的措辞也不该一样。
  robotsUnknown,
  metadataOnlyViolated,
  sourceNotConfigured,
  blockedByTechMeasure,
  redirectNotAllowed,
}

/// ① 域名白名单：精确 host + 子域，顺带挡 SSRF。
class DomainWhitelist {
  DomainWhitelist(Iterable<String> hosts)
      : _hosts = hosts.map((h) => h.trim().toLowerCase()).where((h) => h.isNotEmpty).toSet();
  final Set<String> _hosts;

  bool isAllowed(Uri url) {
    final host = url.host.toLowerCase();
    if (host.isEmpty) return false;
    if (_hosts.contains(host)) return true;
    return _hosts.any((h) => host.endsWith('.$h'));
  }

  void assertAllowed(Uri url) {
    if (!isAllowed(url)) {
      throw RankPolicyException('目标域名 ${url.host} 不在扫榜白名单内',
          code: RankPolicyCode.domainNotAllowed);
    }
  }
}

/// ② robots：保守子集 + 按 host 缓存。
///
/// ★ 三条修正（都是"护栏看着在、其实没在"的真凶）：
///   ① 旧代码拼 URL 时写死 `'${url.scheme}://${url.host}/robots.txt'`，
///      **丢掉了端口**。非默认端口的站点必然连不上 → 被判成"没有 robots.txt"。
///   ② 任何异常（连接被拒、超时、403、非 200）都塌缩成 `null`，
///      而 `null` 又被当成"没有 robots.txt = 允许" → **等于随便抓**。
///   ③ 判定文本把 403/超时 也写成"无 robots.txt（按规范视为允许）"——
///      这句话本身还是错的，403 不等于文件不存在。
///
///   现在把三态分清楚：[_RobotsLookup.notFound]（明确 404 = 视为允许）、
///   [_RobotsLookup.fetched]（按规则判定）、[_RobotsLookup.unknown]（拿不到）。
///   **unknown 时不再谎报"允许"**：判定文本如实写"未能判定"，
///   由调用方决定怎么处理（见 [isAllowed] 的 `strict` 开关）。
class RobotsGuard {
  RobotsGuard({this.agentToken = 'rankscan-demo'});
  final String agentToken;
  final Map<String, _RobotsLookup> _cache = {};

  /// 缓存里某 host 的判定结果（供报告使用）。
  _RobotsLookup? peek(Uri url) => _cache[url.host];

  Future<String> verdict(Uri url) async {
    final look = await _loadFor(url);
    return look.describe(url, agentToken: agentToken);
  }

  /// 是否允许抓取。
  ///
  /// [strict] = true 时，"未能判定"（拿不到 robots.txt）按**拒绝**处理。
  /// 默认 false 保持与旧版一致的可用性（拿不到就放行），
  /// 但判定文本会如实说明是"未能判定"而不是"没有"。
  Future<bool> isAllowed(Uri url, {bool strict = false}) async {
    final look = await _loadFor(url);
    return switch (look.kind) {
      _RobotsLookupKind.fetched => look.file!.isAllowed(url.path, agentToken: agentToken),
      _RobotsLookupKind.notFound => !strict,
      _RobotsLookupKind.unknown => !strict,
    };
  }

  Future<void> assertAllowed(Uri url, {bool strict = false}) async {
    if (!await isAllowed(url, strict: strict)) {
      final look = await _loadFor(url);
      final why = look.kind == _RobotsLookupKind.fetched
          ? '按 ${url.host} 的 robots 协议，路径 ${url.path} 禁止抓取'
          : '无法判定 ${url.host} 的 robots 协议（${look.note}），保守起见已停止采集';
      throw RankPolicyException(why,
          code: look.kind == _RobotsLookupKind.fetched
              ? RankPolicyCode.robotsDenied
              : RankPolicyCode.robotsUnknown);
    }
  }

  Future<_RobotsLookup> _loadFor(Uri url) async {
    final key = url.host;
    if (_cache.containsKey(key)) return _cache[key]!;
    _RobotsLookup look;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      // ★ 用 replace 保住端口。旧写法丢端口 → 非 80/443 的站点必然误判。
      final robotsUrl = url.replace(path: '/robots.txt', query: '');
      final req = await client.getUrl(robotsUrl);
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final bytes = <int>[];
        await for (final c in resp) {
          bytes.addAll(c);
        }
        look = _RobotsLookup.fetched(
            _RobotsFile.parse(utf8.decode(bytes, allowMalformed: true)));
      } else if (resp.statusCode == 404 || resp.statusCode == 410) {
        // ★ 只有明确的"不存在"才等价于允许（这才是规范说的意思）。
        look = _RobotsLookup.notFound();
      } else {
        // 403 / 401 / 5xx：**不是**"没有"，是"拿不到"。
        look = _RobotsLookup.unknown('HTTP ${resp.statusCode}');
      }
    } on Object catch (e) {
      look = _RobotsLookup.unknown(_shortError(e));
    } finally {
      client?.close(force: true);
    }
    _cache[key] = look;
    return look;
  }

  static String _shortError(Object e) {
    final s = '$e';
    if (s.contains('SocketException') || s.contains('Connection refused')) {
      return '连接失败';
    }
    if (s.contains('Timeout') || s.contains('timed out')) return '超时';
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }
}

enum _RobotsLookupKind { fetched, notFound, unknown }

class _RobotsLookup {
  _RobotsLookup._(this.kind, this.file, this.note);
  factory _RobotsLookup.fetched(_RobotsFile f) =>
      _RobotsLookup._(_RobotsLookupKind.fetched, f, '');
  factory _RobotsLookup.notFound() =>
      _RobotsLookup._(_RobotsLookupKind.notFound, null, 'HTTP 404');
  factory _RobotsLookup.unknown(String note) =>
      _RobotsLookup._(_RobotsLookupKind.unknown, null, note);

  final _RobotsLookupKind kind;
  final _RobotsFile? file;
  final String note;

  String describe(Uri url, {String agentToken = 'rankscan-demo'}) {
    switch (kind) {
      case _RobotsLookupKind.fetched:
        final allowed = file!.isAllowed(url.path, agentToken: agentToken);
        return '${url.host}:${allowed ? '允许' : '禁止'} ${url.path}';
      case _RobotsLookupKind.notFound:
        // 只有这里才配说"没有 robots.txt"。
        return '${url.host}:无 robots.txt（HTTP 404，按规范视为允许）';
      case _RobotsLookupKind.unknown:
        return '${url.host}:**未能判定** robots（$note）—— 不能当作"没有 robots.txt"';
    }
  }
}

class _RobotsFile {
  _RobotsFile(this.groups);
  final List<_RobotsGroup> groups;

  /// ★ 按 **user-agent 分组** 解析，而不是把命中的组平铺成一条列表。
  ///   旧实现把 `*` 组和 `rankscan-demo` 组的规则合并进同一个数组，
  ///   再用"最长匹配"取规则 → 专为 `rankscan-demo` 写的 `Disallow: /`
  ///   会被 `*` 组的 `Allow: /` 用最长匹配吃掉（实测：期望 false，得到 true）。
  ///   规范要求的是"取最匹配的那一组，在该组内再比规则"。
  static _RobotsFile parse(String text) {
    final groups = <_RobotsGroup>[];
    var agents = <String>[];
    var current = <_RobotsRule>[];

    void flush() {
      if (agents.isEmpty) return;
      groups.add(_RobotsGroup(List.of(agents), List.of(current)));
      agents = <String>[];
      current = <_RobotsRule>[];
    }

    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final key = line.substring(0, i).trim().toLowerCase();
      var value = line.substring(i + 1).trim();
      final hash = value.indexOf('#');
      if (hash >= 0) value = value.substring(0, hash).trim();
      if (key == 'user-agent') {
        if (current.isNotEmpty) flush();
        agents.add(value.toLowerCase());
      } else if (key == 'disallow') {
        if (agents.isEmpty) continue;
        current.add(_RobotsRule(value, allow: false));
      } else if (key == 'allow') {
        if (agents.isEmpty) continue;
        current.add(_RobotsRule(value, allow: true));
      }
    }
    flush();
    return _RobotsFile(groups);
  }

  /// 找出对 [agentToken] 最具体的那一组（精确名优先于 `*`），在组内判定。
  bool isAllowed(String path, {String agentToken = 'rankscan-demo'}) {
    final token = agentToken.toLowerCase();
    _RobotsGroup? exact;
    _RobotsGroup? star;
    for (final g in groups) {
      for (final a in g.agents) {
        if (a == '*') {
          star ??= g;
        } else if (token.contains(a) || a.contains(token)) {
          // 按规范，UA 匹配是子串匹配（大小写不敏感）。
          exact = g;
        }
      }
    }
    final group = exact ?? star;
    if (group == null) return true;
    return group.isAllowed(path);
  }
}

/// 一条 user-agent 行（可能含多个 agent）下的规则集合。
class _RobotsGroup {
  const _RobotsGroup(this.agents, this.rules);
  final List<String> agents;
  final List<_RobotsRule> rules;

  bool isAllowed(String path) {
    _RobotsRule? best;
    for (final r in rules) {
      if (!r.matches(path)) continue;
      if (best == null || r.specificity > best.specificity) {
        best = r;
      } else if (r.specificity == best.specificity && r.allow && !best.allow) {
        best = r;
      }
    }
    // 组内没有任何规则命中 → 允许（robots 的默认语义）。
    return best == null || best.allow;
  }
}

class _RobotsRule {
  const _RobotsRule(this.pattern, {required this.allow});
  final String pattern;
  final bool allow;
  bool get isEmptyDisallow => !allow && pattern.isEmpty;
  int get specificity => pattern.length;

  /// ★ 支持规范里的 `$` 结尾锚点。
  ///   旧实现不支持，`Disallow: /search$` 会被当成前缀 `/search` 匹配，
  ///   于是 `/search.html` 也被误禁（过度封锁），属于"看起来更保守、实则不符规范"。
  bool matches(String path) {
    if (isEmptyDisallow) return false;
    var pat = pattern;
    var endAnchored = false;
    if (pat.endsWith(r'$')) {
      endAnchored = true;
      pat = pat.substring(0, pat.length - 1);
    }
    if (!pat.contains('*')) {
      if (endAnchored) return path == pat;
      return path.startsWith(pat);
    }
    final parts = pat.split('*');
    var pos = 0;
    for (var i = 0; i < parts.length; i++) {
      final seg = parts[i];
      if (seg.isEmpty) continue;
      final idx = path.indexOf(seg, pos);
      if (idx < 0) return false;
      if (i == 0 && idx != 0) return false;
      pos = idx + seg.length;
    }
    // 带 `*` 且结尾锚定：最后一段必须贴到末尾。
    if (endAnchored) {
      final tail = parts.last;
      return tail.isEmpty ? true : path.endsWith(tail);
    }
    return true;
  }
}

/// ③ 元数据-only：出现正文字段名直接抛，让"抓正文"在结构上不可能。
class MetadataOnlyPolicy {
  static const Set<String> forbidden = {
    'content', 'body', 'text', 'chapter', 'chapters', 'chapter_content',
    'chaptercontent', 'novelcontent', '正文', '章节内容', '章节', '内容',
  };

  static void checkFields(Iterable<String> keys) {
    for (final k in keys) {
      if (forbidden.contains(k.trim().toLowerCase())) {
        throw RankPolicyException('扫榜结果不允许携带内容字段「$k」（只允许榜单元数据）',
            code: RankPolicyCode.metadataOnlyViolated);
      }
    }
  }
}

/// ④ 反爬技术措施特征：命中就停手，绝不绕过。
class TechMeasures {
  /// 只用**完整短语**：宽泛词形会误杀整站
  /// （七猫正常页面的脚本地址里就含 captcha 字样）。
  static const List<String> signals = [
    '百度安全验证', '访问过于频繁', '请输入验证码', '滑动验证', '访问被拒绝',
    'probe.js', 'var buid = "ffff',
  ];

  static bool looksBlocked(String body) => signals.any(body.contains);

  /// 验证壳页判据：**先看体积，再看词**。
  ///
  /// ★ 不能只按词匹配 —— 实测起点正常榜单页（52KB）里同样含
  ///   `x-waf-captcha-referer` 字样（那段反劫持脚本本来就在正常页面里），
  ///   按词匹配会把整站误杀（与原版对七猫 `captcha` 的教训同一条）。
  ///   风控壳页的特征是**只有一小段脚本、没有正文**，所以用长度做主判据。
  static bool isChallengeStub(String body) {
    if (body.length >= 8000) return false; // 正常榜单页 50KB+
    final lower = body.toLowerCase();
    return lower.contains('captcha') ||
        lower.contains('waf') ||
        lower.contains('slider') ||
        lower.contains('verify');
  }
}

/// 限速器：两次请求最小间隔。站点风控按 IP 记，界面与 AI 必须共用同一个实例。
///
/// ★ 必须做成"**预约下一个时间槽**"式的串行队列。
///   旧实现把 `_last = now` 写在 `await` **之前**：两个并发调用者读到同一个
///   `last`，各自 sleep 同样的剩余时间，然后**一起发请求**。
///   实测 `minInterval=300ms` 时 3 个并发 `wait()` 总耗时 315ms
///   （串行语义要求 ≥600ms）—— 等于并发下完全没限速。
///   现在改成"先取号、再按号排队"：每个调用者拿到的是**互不重叠**的时间槽。
class RateLimiter {
  RateLimiter({this.minInterval = const Duration(seconds: 2)});
  final Duration minInterval;

  /// 下一个可用时间槽。初值 0 表示"立刻可发"。
  int _nextSlotMs = 0;

  /// 串行化 Promise 链：保证"取槽 + 写入"这段是原子的（Dart 是单线程，
  /// 但只要中间有 `await` 就可能被打断，所以判断与写入之间不能有 await）。
  Future<void> wait() async {
    if (minInterval <= Duration.zero) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final slot = _nextSlotMs <= now ? now : _nextSlotMs;
    // ★ 同步写入下一个槽位（这里没有 await，不会被并发插入）。
    _nextSlotMs = slot + minInterval.inMilliseconds;
    final delayMs = slot - now;
    if (delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
  }
}

const String _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';

/// 传输层。抓取与解析**分成两步**：测试可喂录制夹具不打网络。
/// 字节解码交给数据源（UTF-8 站点直接 [getString]，GBK 站点用 [getBytes] 自行解码）。
class Fetcher {
  Fetcher({required this.whitelist, required this.robots, RateLimiter? limiter})
      : limiter = limiter ?? RateLimiter();
  final DomainWhitelist whitelist;
  final RobotsGuard robots;
  final RateLimiter limiter;

  /// 最近一次的 robots 判定文本。
  String? lastVerdict;

  Future<String> getString(Uri url, {String? referer, String? accept}) async =>
      utf8.decode(await getBytes(url, referer: referer, accept: accept),
          allowMalformed: true);

  Future<List<int>> getBytes(Uri url, {String? referer, String? accept}) async {
    // ★ 自己跟跳转，逐跳校验白名单 + 复查 robots。
    //   旧实现只对**请求 URL** 校验白名单，而 HttpClient 默认 followRedirects=true，
    //   于是一条 302 就能把请求带到白名单外的 host 上（实测抓到
    //   非白名单 host 的正文），"只扫这四个站"的承诺直接失效。
    var current = url;
    var redirects = 0;
    while (true) {
      whitelist.assertAllowed(current);
      // robots 也必须在**每一跳**复查，而不只看最初的 URL。
      await robots.assertAllowed(current);
      lastVerdict = await robots.verdict(current);
      await limiter.wait();

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final req = await client.getUrl(current);
        // ★ 关掉自动跳转，自己控制每一跳。
        //   注意 `followRedirects` 在 **HttpClientRequest** 上，不在 HttpClient 上。
        req.followRedirects = false;
        req.headers.set(
            HttpHeaders.acceptHeader, accept ?? 'text/html,application/json');
        // ★ 默认 UA 是 Dart/x.y，起点移动端直接 403。
        req.headers.set(HttpHeaders.userAgentHeader, _ua);
        if (referer != null) req.headers.set(HttpHeaders.refererHeader, referer);
        final resp = await req.close().timeout(const Duration(seconds: 25));

        // 3xx：取出 Location，校验后续跳，再循环。
        if (resp.isRedirect) {
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          await resp.drain<void>();
          if (loc == null || loc.isEmpty) {
            throw const HttpException('重定向缺少 Location 头');
          }
          redirects++;
          if (redirects > _maxRedirects) {
            throw const RankPolicyException('重定向次数过多，已停止采集',
                code: RankPolicyCode.redirectNotAllowed);
          }
          final next = current.resolve(loc);
          // ★ 提前给出清晰错误，而不是让请求发到白名单外。
          if (!whitelist.isAllowed(next)) {
            throw RankPolicyException(
                '重定向目标 ${next.host} 不在扫榜白名单内（从 ${current.host} 跳转），已停止采集',
                code: RankPolicyCode.redirectNotAllowed);
          }
          current = next;
          continue;
        }

        final bytes = <int>[];
        await for (final c in resp) {
          bytes.addAll(c);
        }
        // HttpClient 自动带 accept-encoding: gzip 并透明解压。
        final probe = utf8.decode(bytes, allowMalformed: true);
        if (resp.statusCode == 202 ||
            TechMeasures.looksBlocked(probe) ||
            TechMeasures.isChallengeStub(probe)) {
          throw RankPolicyException(
            '目标站点返回风控/验证内容（HTTP ${resp.statusCode}、${bytes.length} 字节），'
            '已停止采集（不做绕过处理）',
            code: RankPolicyCode.blockedByTechMeasure,
          );
        }
        if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
        return bytes;
      } finally {
        client.close(force: true);
      }
    }
  }
}

/// 最多跟几跳。超了直接放弃，避免跳转环把采集器吊死。
const int _maxRedirects = 5;

/// 内嵌 JSON 提取：三种站点三种形态，各自的坑都写在注释里。
class EmbeddedJson {
  /// 起点：`<script id="vite-plugin-ssr_pageContext" type="application/json">`
  /// 标签 id 带构建前缀且会随版本变，所以只能按"含 fragment 的 JSON 块"匹配。
  static String? byIdContaining(String html, String fragment) {
    var pos = 0;
    while (true) {
      final tagStart = html.indexOf('<script', pos);
      if (tagStart < 0) return null;
      final gt = html.indexOf('>', tagStart);
      if (gt < 0) return null;
      final end = html.indexOf('</script>', gt);
      if (end < 0) return null;
      final tag = html.substring(tagStart, gt);
      final content = html.substring(gt + 1, end).trim();
      pos = end + 1;
      if (!tag.contains('application/json')) continue;
      final idMatch = RegExp(r'id="([^"]*)"').firstMatch(tag);
      if ((idMatch?.group(1) ?? '').contains(fragment)) return content;
    }
  }

  /// `window.__INITIAL_STATE__=` 后面的对象（值里可能有 undefined 字面量）。
  static Object? initialState(String html, {String marker = '__INITIAL_STATE__='}) {
    final p = html.indexOf(marker);
    if (p < 0) return null;
    final start = html.indexOf('{', p + marker.length - 1);
    if (start < 0) return null;
    final end = _matchBrace(html, start);
    if (end < 0) return null;
    var text = html.substring(start, end + 1);
    text = text.replaceAll(RegExp(r'\bundefined\b'), 'null');
    try {
      return jsonDecode(text);
    } on Object {
      return null;
    }
  }

  /// 七猫：`__NUXT__=(function(形参){return {…}}(实参))`
  /// 必须先取实参表、再替换形参，之后才是能解析的 JSON。
  static Object? nuxtData(String html) {
    const sigStart = '(function(';
    final p = html.indexOf('__NUXT__');
    if (p < 0) return null;
    final fnStart = html.indexOf(sigStart, p);
    if (fnStart < 0) return null;
    const bodyKey = '){return';
    final bodyStart = html.indexOf(bodyKey, fnStart);
    if (bodyStart < 0) return null;
    final objStart = bodyStart + bodyKey.length;
    final objEnd = _matchBrace(html, objStart);
    if (objEnd < 0) return null;
    final literal = html.substring(objStart, objEnd + 1);

    final params = html
        .substring(fnStart + sigStart.length, bodyStart)
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final argsStart = html.indexOf('(', objEnd);
    if (argsStart < 0) return null;
    var depth = 0, inStr = false;
    String quote = '';
    int? argsEnd;
    for (var i = argsStart; i < html.length; i++) {
      final c = html[i];
      if (inStr) {
        if (c == r'\') {
          i++;
          continue;
        }
        if (c == quote) inStr = false;
        continue;
      }
      if (c == '"' || c == "'") {
        inStr = true;
        quote = c;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) {
          argsEnd = i;
          break;
        }
      }
    }
    if (argsEnd == null) return null;
    final values = _splitArgs(html.substring(argsStart + 1, argsEnd));
    // 形参/实参数量不一致 = 结构异常，宁可失败也不给错数据
    if (values.length != params.length) return null;
    final map = <String, String>{
      for (var i = 0; i < params.length; i++) params[i]: values[i].trim()
    };
    final patched = _substitute(literal, map);
    try {
      return jsonDecode(patched);
    } on Object {
      return null;
    }
  }

  static int _matchBrace(String s, int open) {
    var depth = 0, inStr = false;
    String quote = '';
    for (var i = open; i < s.length; i++) {
      final c = s[i];
      if (inStr) {
        if (c == r'\') {
          i++;
          continue;
        }
        if (c == quote) inStr = false;
        continue;
      }
      if (c == '"' || c == "'") {
        inStr = true;
        quote = c;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static List<String> _splitArgs(String s) {
    final out = <String>[];
    final buf = StringBuffer();
    var depth = 0, inStr = false;
    String quote = '';
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (inStr) {
        buf.write(c);
        if (c == r'\') {
          i++;
          if (i < s.length) buf.write(s[i]);
          continue;
        }
        if (c == quote) inStr = false;
        continue;
      }
      if (c == '"' || c == "'") {
        inStr = true;
        quote = c;
        buf.write(c);
        continue;
      }
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') depth--;
      if (c == ',' && depth == 0) {
        out.add(buf.toString());
        buf.clear();
        continue;
      }
      buf.write(c);
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  /// 逐字符扫描：① 不能替换字符串内部的同名内容；
  /// ② Nuxt 的**键名不带引号**，靠"后面跟不跟冒号"区分键/值，键要补引号；
  /// ③ JS 用 !0/!1 表布尔。
  static String _substitute(String literal, Map<String, String> values) {
    final sb = StringBuffer();
    var i = 0;
    while (i < literal.length) {
      final c = literal[i];
      if (c == '"' || c == "'") {
        final quote = c;
        sb.write(c);
        i++;
        while (i < literal.length) {
          final d = literal[i];
          sb.write(d);
          if (d == r'\') {
            i++;
            if (i < literal.length) sb.write(literal[i]);
          } else if (d == quote) {
            i++;
            break;
          }
          i++;
        }
        continue;
      }
      if (RegExp(r'[A-Za-z_\$]').hasMatch(c)) {
        var j = i;
        while (j < literal.length && RegExp(r'[A-Za-z0-9_\$]').hasMatch(literal[j])) {
          j++;
        }
        final word = literal.substring(i, j);
        var k = j;
        while (k < literal.length && (literal[k] == ' ' || literal[k] == '\n')) {
          k++;
        }
        final isKey = k < literal.length && literal[k] == ':';
        if (isKey) {
          sb.write('"$word"');
        } else if (word == 'true' || word == 'false' || word == 'null') {
          sb.write(word);
        } else if (values.containsKey(word)) {
          var v = values[word]!;
          if (v == '!0') v = 'true';
          if (v == '!1') v = 'false';
          sb.write(v);
        } else {
          sb.write('null');
        }
        i = j;
        continue;
      }
      sb.write(c);
      i++;
    }
    return sb.toString();
  }
}

/// 深度查找某个 key 下的数组（key 如 data-v-xxx 会随构建变，不能写死路径）。
List? findList(Object? node, String key, {int depth = 0}) {
  if (depth > 8) return null;
  if (node is Map) {
    for (final e in node.entries) {
      if (e.key.toString() == key && e.value is List) return e.value as List;
      final r = findList(e.value, key, depth: depth + 1);
      if (r != null) return r;
    }
  } else if (node is List) {
    for (final v in node) {
      final r = findList(v, key, depth: depth + 1);
      if (r != null) return r;
    }
  }
  return null;
}

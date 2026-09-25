/// 书封面：**懒加载 + 落盘缓存 + 系统解码**。
///
/// ★ 设计上的四条纪律（每一条都是"不做的话会出问题"）：
///
///   ① **只在真的要显示时才取**。一张榜单 20 本书，四个平台、多张榜、
///      多天历史 —— 无脑全量下载会把请求量从"每榜 1 次"抬到"每榜 21 次"，
///      那是本项目"四道护栏"明确要避免的。所以只有**滚动到可见的行**才会入队，
///      而且每本书**一辈子只下一次**（按 bookId 落盘缓存）。
///
///   ② **只认封面 CDN 的域名**（[coverHosts]）。这些地址来自榜单数据本身，
///      不是用户输入，但仍然逐条校验 —— 数据被污染时不能让程序去请求任意主机。
///
///   ③ **失败就是失败**。取不到 / 解不开 → 返回 null，界面画占位卡。
///      绝不拿别的书的封面顶上，也绝不显示半张花屏。
///
///   ④ **不动主线程**。下载在后台 isolate 之外（`HttpClient` 本来就是异步的），
///      解码是同步的但只做一次 36×48 的小图，代价可忽略。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'cover_image.dart';

/// 允许取封面的 CDN 域名（后缀匹配，带前导点表示"任意子域"）。
///
/// ★ 这张表是**白名单**，不是"黑名单"：不在表里的地址一律拒绝。
///   表里的每一条都对应一个平台实际在用的封面 CDN。
const List<String> coverHosts = [
  'bookcover.yuewen.com', // 起点
  '.fqnovelpic.com', // 番茄
  '.byteimg.com', // 番茄（备用域名）
  '.qimao.com', // 七猫
  '.wtzw.com', // 七猫（实际存图的是这个 CDN，漏了它七猫就一张都出不来）
  '.jjwxc.net', // 晋江
];

/// 从 `bookId` **推导**封面 URL —— 能用推导的就别依赖采集时抓到的那个地址。
///
/// ★ 为什么必须有它：封面是第 17 轮才加的字段，**之前采集的快照里没有 `cover_url`**，
///   界面就只剩占位卡。而起点（榜单最多的那个平台，14 张榜）的封面地址是
///   `bookId` 的**纯函数**：`/qdbimg/349573/{bookId}/150`。
///   实测 6 个真实 bookId 全部 200 + `image/jpeg`（见 README）。
///   于是**旧数据不用重扫就能有封面**，新数据也少一个"HTML 格式变了就失效"的依赖。
///
/// ★ 为什么只有起点：番茄的封面地址带**签名**（`x-signature`）和内容哈希，
///   七猫/晋江同理 —— 都不是 bookId 能算出来的。那两个平台只能等新一轮采集
///   （`cover_url` 随接口一起拿到）。**算不出来就返回 null，不猜。**
String? deriveCoverUrl(String source, String? bookId) {
  if (bookId == null || bookId.isEmpty) return null;
  if (source == 'qidian') {
    // 349573 是阅文给起点作品页的固定站号，不是每本书变的
    return 'https://bookcover.yuewen.com/qdbimg/349573/$bookId/150';
  }
  return null;
}

/// 取封面地址：优先用采集时抓到的，没有再按 [deriveCoverUrl] 推导。
String? coverUrlFor(String source, String? bookId, String? captured) {
  if (captured != null && captured.isNotEmpty) return captured;
  return deriveCoverUrl(source, bookId);
}

/// 「榜单接口里没有封面」的平台 → 去**书籍详情页**捞一次。
///
/// ★ 为什么需要它：实测（2026-09-25）
///   - 番茄 `category/list` 的 `book_list` 里**没有任何封面字段**（别名探测全落空）；
///   - 七猫的 Nuxt 载荷里也没有；
///   - 但两家的**书籍页**静态 HTML 里都有封面 URL（番茄是带签名的
///     `p*-reading-sign.fqnovelpic.com/...`，七猫是 `cdn.wtzw.com/bookimg/...`）。
///   - 晋江的书页里**没有**封面 → 老实画占位卡。
///
/// ★ 代价说清楚：这是"每本书多一次页面请求"（46~78 KB）。所以它同样
///   **懒加载 + 永久缓存**：只有用户真的翻到那一行才取，每本书一辈子只取一次。
///   不想要就把这张表清空 —— 对应平台退回占位卡，其余不受影响。
const Map<String, String> coverPageUrl = {
  'fanqie': 'https://fanqienovel.com/page/{id}',
  'qimao': 'https://www.qimao.com/shuku/{id}/',
};

/// 从书籍页 HTML 里抠封面 URL。抠不到返回 null。
///
/// ★★ 关键：**必须只认"本书封面"那条路径**，不能"抓页面里第一张图"。
///   书籍页上还有"猜你喜欢 / 同类推荐"，那些封面同样落在图片 CDN 上 ——
///   第 17 轮实测：七猫页面里第一条 `public/images/cover/` 是**别人的书**，
///   而且两次抓取还不一样（推荐位在轮换）。**显示错的书封面比不显示更糟。**
///
///   实测出来的"只属于本书封面"的路径特征（2026-09-25，各抓两次都稳定）：
///     · 七猫：`cdn.qimao.com/bookimg/zww/upload/**readerCover**/`（195×260 大图）
///              —— 推荐位走的是 `cdn.wtzw.com/.../public/images/cover/`（90×120 小图）
///     · 番茄：`p*-novel-sign.byteimg.com/**novel-pic**/`（225×300 封面）
///              —— 页面里的 `author-img` 走的是 `p*-reading-sign.fqnovelpic.com/`
///                 且字段名是 `avatarUri`（那是**作者头像**，不是封面）
///
/// ★ [bookId] 作为**加分项**保留：万一以后某家把 bookId 写进文件名，优先取它。
String? extractCoverFromPage(String source, String html, {String? bookId}) {
  final patterns = switch (source) {
    'fanqie' => [
        RegExp(r'https://p\d+-novel-sign\.byteimg\.com/novel-pic/[^"\s\\)]+'),
        RegExp(r'https://p\d+-reading-sign\.fqnovelpic\.com/novel-pic/[^"\s\\)]+'),
      ],
    'qimao' => [
        RegExp(r'https://cdn\.qimao\.com/bookimg/zww/upload/readerCover/[^"\s\\)]+'),
      ],
    _ => const <RegExp>[],
  };
  for (final re in patterns) {
    final all = <String>[];
    for (final m in re.allMatches(html)) {
      // HTML 里 `&` 常被转义成 `&amp;`
      final u = m.group(0)!.replaceAll('&amp;', '&');
      if (!isAllowedCoverHost(Uri.parse(u))) continue;
      all.add(u);
    }
    if (all.isEmpty) continue;
    if (bookId != null && bookId.isNotEmpty) {
      for (final u in all) {
        if (u.contains(bookId)) return u;
      }
    }
    return all.first;
  }
  return null;
}

/// 允许去扒封面的**书籍页**域名（与封面 CDN 分开列，一眼能看出多去了哪儿）。
const List<String> coverPageHosts = [
  'fanqienovel.com', // 番茄
  'www.qimao.com', // 七猫
];

bool isAllowedPageHost(Uri u) {
  if (u.scheme != 'https') return false;
  return coverPageHosts.contains(u.host.toLowerCase());
}

bool isAllowedCoverHost(Uri u) {
  if (u.scheme != 'https' && u.scheme != 'http') return false;
  final h = u.host.toLowerCase();
  for (final a in coverHosts) {
    if (a.startsWith('.')) {
      if (h.endsWith(a)) return true;
    } else if (h == a) {
      return true;
    }
  }
  return false;
}

/// 一张封面在内存里的样子。
class CoverEntry {
  CoverEntry(this.image);
  final BgraImage? image; // null = 取过但失败（记住"别再试"，避免反复打网络）
}

/// 封面仓库。
class CoverStore {
  CoverStore({
    required this.root,
    this.requestGapMs = 120,
    this.decodeW = 36,
    this.decodeH = 48,
  });

  /// 缓存根目录（`out/扫榜/_covers`）。
  final String root;

  /// 两次下载之间的最小间隔（限速）。
  final int requestGapMs;

  /// 解码目标尺寸（与 `Metrics.coverWidth/Height` 的基准一致）。
  final int decodeW;
  final int decodeH;

  /// 内存缓存：`source|bookId` → 结果。
  final Map<String, CoverEntry> _mem = {};

  /// 待取队列（去重）。url 为空 = 需要先去书籍页里捞封面地址。
  final List<(String source, String bookId, String url)> _queue = [];
  final Set<String> _queued = {};

  /// 已经**请求过**的键（成功或失败都算）—— 失败的不再重试。
  final Set<String> _tried = {};

  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;

  /// 统计（状态栏如实报数用）。
  int fetched = 0;
  int failed = 0;
  int get queued => _queue.length;
  int get cached => _mem.length;

  static String _key(String source, String bookId) => '$source|$bookId';

  /// 文件名里不能出现路径分隔符与 Windows 保留字符。
  static String _safe(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');

  String _pathOf(String source, String bookId) =>
      '$root${Platform.pathSeparator}${_safe(source)}'
      '${Platform.pathSeparator}${_safe(bookId)}.img';

  /// **只读内存**：没解过就返回 null（同时把这一行排进队列）。
  ///
  /// ★ 这个函数会被绘制路径每帧调用，所以它**绝不能阻塞**。
  ///   取图是异步的，取到之后由界面重绘来"补上"。
  BgraImage? peek(String source, String? bookId, String? url) {
    if (bookId == null || bookId.isEmpty) return null;
    final k = _key(source, bookId);
    final hit = _mem[k];
    if (hit != null) return hit.image;
    // 没在内存里 → 入队（磁盘上有的话 pump 会直接读盘，不打网络）
    if (!_tried.contains(k) && !_queued.contains(k)) {
      if (url != null && url.isNotEmpty) {
        final u = Uri.tryParse(url);
        if (u == null || !isAllowedCoverHost(u)) {
          _mem[k] = CoverEntry(null);
          _tried.add(k);
          return null;
        }
        _queue.add((source, bookId, url));
        _queued.add(k);
      } else if (coverPageUrl.containsKey(source)) {
        // 榜单里没有封面地址 → 排一个"先扒书籍页"的任务（url 留空作标记）
        _queue.add((source, bookId, ''));
        _queued.add(k);
      } else {
        // 这个平台既没地址也没书页可扒 → 记成失败，不再重试
        _mem[k] = CoverEntry(null);
        _tried.add(k);
      }
    }
    return null;
  }

  /// 处理队列里的**一个**任务。由界面用一个低频定时器驱动。
  ///
  /// 返回 true = 内存缓存有变化（界面该重绘）。
  ///
  /// [force]=true 时**跳过限速** —— 只给自检用（离线跑、没有事件循环，
  /// 靠定时器驱动的话队列永远排不空）。
  Future<bool> pump({bool force = false}) async {
    if (_busy || _queue.isEmpty) return false;
    if (!force) {
      // 限速：两次下载之间至少隔 [requestGapMs]
      final since = DateTime.now().difference(_lastRequest).inMilliseconds;
      if (since < requestGapMs) return false;
    }

    _busy = true;
    final (source, bookId, url) = _queue.removeAt(0);
    final k = _key(source, bookId);
    _queued.remove(k);
    _tried.add(k);
    try {
      final f = File(_pathOf(source, bookId));
      Uint8List bytes;
      if (f.existsSync() && f.lengthSync() > 0) {
        // 命中磁盘缓存：不打网络（这是"每本书一辈子只下一次"的落点）
        bytes = f.readAsBytesSync();
      } else {
        // url 为空 = 先去书籍页把封面地址捞出来
        var imageUrl = url;
        if (imageUrl.isEmpty) {
          final pageUrl = coverPageUrl[source]!.replaceAll('{id}', bookId);
          final page = await _get(pageUrl);
          if (page.isEmpty) {
            _mem[k] = CoverEntry(null);
            failed++;
            return true;
          }
          imageUrl = extractCoverFromPage(source, String.fromCharCodes(page),
                  bookId: bookId) ??
              '';
          if (imageUrl.isEmpty) {
            _mem[k] = CoverEntry(null);
            failed++;
            return true;
          }
        }
        bytes = await _get(imageUrl);
        if (bytes.isEmpty) {
          _mem[k] = CoverEntry(null);
          failed++;
          return true;
        }
        try {
          f.parent.createSync(recursive: true);
          f.writeAsBytesSync(bytes, flush: true);
        } on Object {
          // 落盘失败不影响本次显示（内存里已经有了）
        }
        fetched++;
      }
      // 解码要在**写盘之后**做：写盘是"留档"，解码是"这次要显示"
      final img = decodeCoverFile(f.path, decodeW, decodeH);
      _mem[k] = CoverEntry(img);
      if (img == null) failed++;
      return true;
    } on Object {
      _mem[k] = CoverEntry(null);
      failed++;
      return true;
    } finally {
      _lastRequest = DateTime.now();
      _busy = false;
    }
  }

  /// 真正的一次 GET（图片或书籍页）。
  ///
  /// 与 `lib/guard.dart` 的取数路径分开：那条路带 robots 判定与 referer 策略，
  /// 而封面是**图片资源**、在另一个 CDN 上，两者口径不该混。这里只做
  /// "白名单 + 限速 + 不跟随跨域重定向 + 超时" 四件事。
  ///
  /// ★ 书籍页的 host（fanqienovel.com / qimao.com）不在封面 CDN 白名单里，
  ///   所以这里按"**平台主站 + 封面 CDN**"两张表合并校验 —— 仍然不是"任意域名"。
  Future<Uint8List> _get(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
    try {
      final u = Uri.parse(url);
      if (!isAllowedCoverHost(u) && !isAllowedPageHost(u)) return Uint8List(0);
      final req = await client.getUrl(u);
      req.followRedirects = false; // 跨域重定向一律不跟（白名单之外不去）
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return Uint8List(0);
      final b = BytesBuilder();
      await for (final chunk in resp) {
        b.add(chunk);
        // 单张封面超过 4 MB 就当异常（正常是 20~80 KB；书籍页 ~80 KB）
        if (b.length > 4 * 1024 * 1024) break;
      }
      return b.takeBytes();
    } on Object {
      return Uint8List(0);
    } finally {
      client.close(force: true);
    }
  }

  /// 队列里还有活时返回 true（界面据此决定要不要继续起定时器）。
  bool get hasWork => _queue.isNotEmpty;

  /// 自检：直接取一个页面/图片（走同一套白名单与超时）。
  Future<Uint8List> fetchPageForTest(String url) => _get(url);
}

/// 把 `build/shots/` 里**值得入库**的截图挑进 `docs/screenshots/`。
///
/// ★ 为什么要挑而不是全搬：`build/shots/` 是**工作目录**，里面混着
///   一次性诊断图（exe 截图、裁剪放大图、四档缩放对照……），
///   几十张全进仓库既没必要也会把 README 淹没。
///   这里只保留"README 里真正会引用到的"那几张，并按主题改名成 ASCII，
///   免得中文文件名在某些 git 客户端/CI 上出问题。
///
/// ★ 为什么需要"缩"：仓库里的图是给人**在网页上看**的，
///   1240x800 全尺寸当然更清楚，但每张 ~115 KB × 十几张就上兆了。
///   默认 `--factor=2`（长宽各减半）后每张 ~35 KB，README 里完全够看。
///
/// 用法：
///   dart run tool/pick_shots.dart                 # 默认 2 倍缩小 → docs/screenshots
///   dart run tool/pick_shots.dart --factor=1      # 原尺寸（要清楚就选它）
///   dart run tool/pick_shots.dart --src=build/shots --dst=docs/screenshots
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/png.dart';

/// 入选清单：`(源文件名, 入库文件名)`。
///
/// 顺序就是 README 里的展示顺序：先"日常用的三个标签页"，
/// 再"两个对话框"，最后"浅色主题对照"与"导出的图"。
const List<(String, String)> picked = [
  // ★ 头图用**真实数据**那张（起点月票榜·玄幻，真封面 + 「打开」按钮同框），
  //   而不是 `10_封面与链接.png` —— 后者是合成夹具，书名是"样例书名1"，
  //   放进 README 第一眼看到的是假书名，不像个能用的工具。
  ('11_真实数据封面_qidian.png', '00-cover-and-links-dark.png'),
  ('1_榜单明细.png', '01-board-detail-dark.png'),
  ('2_历史对比.png', '02-trend-vs-self-dark.png'),
  ('3_跨榜分析.png', '03-cross-board-dark.png'),
  ('7_扫榜设置.png', '04-scan-dialog-dark.png'),
  ('6_数据管理.png', '05-data-manager-dark.png'),
  ('8_侧栏隐藏态.png', '06-sidebar-hidden-dark.png'),
  ('趋势图_qidian_月票榜.png', '07-exported-trend-png.png'),
  // ★ 导出的榜单长图（列与界面「榜单明细」一致）—— 第 22 轮修的就是它
  ('30_导出榜单图_qidian.png', '10-exported-board-png.png'),
  ('1_榜单明细_浅色.png', '08-board-detail-light.png'),
  ('7_扫榜设置_浅色.png', '09-scan-dialog-light.png'),
];

/// 最近邻（盒式平均）缩小。只支持整数倍，够用且不会有重采样伪影。
Uint8List downscaleBgra(Uint8List src, int w, int h, int factor) {
  if (factor <= 1) return src;
  final nw = w ~/ factor;
  final nh = h ~/ factor;
  final out = Uint8List(nw * nh * 4);
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      var r = 0, g = 0, b = 0, a = 0, n = 0;
      for (var dy = 0; dy < factor; dy++) {
        for (var dx = 0; dx < factor; dx++) {
          final o = ((y * factor + dy) * w + (x * factor + dx)) * 4;
          if (o + 3 >= src.length) continue;
          b += src[o];
          g += src[o + 1];
          r += src[o + 2];
          a += src[o + 3];
          n++;
        }
      }
      if (n == 0) continue;
      final o2 = (y * nw + x) * 4;
      out[o2] = b ~/ n;
      out[o2 + 1] = g ~/ n;
      out[o2 + 2] = r ~/ n;
      out[o2 + 3] = a ~/ n;
    }
  }
  return out;
}

void main(List<String> args) {
  var src = 'build/shots';
  var dst = 'docs/screenshots';
  var factor = 2;
  for (final a in args) {
    if (a.startsWith('--src=')) src = a.substring(6);
    if (a.startsWith('--dst=')) dst = a.substring(6);
    if (a.startsWith('--factor=')) {
      factor = int.tryParse(a.substring(9)) ?? factor;
    }
  }
  if (factor < 1) factor = 1;

  final out = Directory(dst)..createSync(recursive: true);
  var ok = 0;
  var missing = 0;
  for (final (from, to) in picked) {
    final f = File('$src/$from');
    if (!f.existsSync()) {
      stdout.writeln('  跳过（不存在）：$from');
      missing++;
      continue;
    }
    final img = decodePngBytes(f.readAsBytesSync());
    if (img == null) {
      stdout.writeln('  跳过（解码失败）：$from');
      missing++;
      continue;
    }
    final bgra = downscaleBgra(img.bgra, img.width, img.height, factor);
    final nw = img.width ~/ factor;
    final nh = img.height ~/ factor;
    final png = bgraToPng(bgra, nw, nh);
    File('$dst/$to').writeAsBytesSync(png, flush: true);
    stdout.writeln('  $from  ->  $to  ${nw}x$nh  '
        '${(png.length / 1024).toStringAsFixed(0)} KB');
    ok++;
  }
  stdout.writeln('\n入库 $ok 张（跳过 $missing）→ $dst/');
  if (missing > 0) {
    stdout.writeln('提示：先跑 `dart run bin/_render_shots.dart <outRoot>` 生成截图。');
  }
}

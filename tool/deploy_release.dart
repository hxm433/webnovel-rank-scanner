/// 把刚打好的 exe 同步到「发布版」目录 —— 打包流程的最后一步。
///
/// 用法：`dart run tool/deploy_release.dart <成品exe路径>`
///
/// ★★ 为什么这一步必须存在（第 19 / 22 轮各栽过一次）：
///   用户不会去 `build\` 里找新 exe，他只点 `build\发布版\网文扫榜工具.exe`。
///   只打包不部署 = 用户看到的还是旧版，然后报"改了怎么还是老样子"。
///   "打完包"与"部署到发布版"**必须是一个动作**。
///
/// ★★ 为什么用 Dart 写而不是写进 .cmd / .ps1：
///   路径里有中文（`发布版`、`网文扫榜工具.exe`）。cmd 按**控制台代码页**
///   解码 .bat 文件 —— 在代码页不是 936 的终端里（例如从 Git Bash 调
///   `cmd /c`），这些中文字面量会被解成 U+FFFD，于是脚本"复制成功"、
///   文件却落进了一个 `������` 的垃圾目录（实测踩到）。
///   Dart 源码是 UTF-8，字符串常量**不受代码页影响**，一次写好到处都对。
///   打包流程本来就需要 Dart SDK，不额外引入依赖。
library;

import 'dart:io';

const String _exeName = '网文扫榜工具.exe';
const String _releaseDirName = '发布版';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/deploy_release.dart <成品exe路径>');
    exit(2);
  }
  final src = File(args[0]);
  if (!src.existsSync()) {
    stderr.writeln('[X] 找不到成品 ${src.path}');
    exit(1);
  }

  final buildDir = src.parent;
  final relDir = Directory('${buildDir.path}${Platform.pathSeparator}$_releaseDirName');
  if (!relDir.existsSync()) relDir.createSync(recursive: true);
  final dst = File('${relDir.path}${Platform.pathSeparator}$_exeName');

  // ── 先备份旧版（可回退）──
  String? bakPath;
  if (dst.existsSync()) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    bakPath = '${dst.path}.bak_$stamp';
    dst.copySync(bakPath);
  }

  // ── 覆盖目标 ──
  //
  // ★★ 不能直接 `writeAsBytesSync` 覆盖：目标 exe 常常被**读句柄**占着
  //    （Defender 实时扫描 / 资源管理器缩略图 / 搜索索引器），
  //    Windows 会以 `errno = 32`（另一个程序正在使用此文件）拒绝"以写方式打开"。
  //    而**改名替换**不受影响 —— 读句柄只阻止写入，不阻止 MoveFileEx 替换目录项。
  //    所以：先写一个临时名，再改名盖上去。（这条在打包 exe 时已经踩过一次。）
  final tmp = File('${dst.path}.new');
  if (tmp.existsSync()) tmp.deleteSync();
  tmp.writeAsBytesSync(src.readAsBytesSync(), flush: true);
  try {
    tmp.renameSync(dst.path);
  } on Object catch (e) {
    // 极少数情况下改名也不行（例如目标正被**执行**）→ 如实报错，别假装成功
    try {
      tmp.deleteSync();
    } on Object {
      // 清理失败无所谓
    }
    stderr.writeln('[X] 覆盖发布版失败：$e');
    stderr.writeln('    目标可能正在运行，或被杀软/索引器独占。请关掉它再重试。');
    exit(1);
  }

  // ── 校验：写完必须**真的**在磁盘上、且与源一致 ──
  //
  // ★ 不校验等于没部署：曾经出现过"脚本报复制成功、文件其实落进了
  //   一个乱码目录"（cmd 按控制台代码页解码中文字面量的锅）。
  //   所以这里读回来逐字节比一遍。
  if (!dst.existsSync()) {
    stderr.writeln('[X] 部署后目标文件不存在：${dst.path}');
    exit(1);
  }
  final a = src.readAsBytesSync();
  final b = dst.readAsBytesSync();
  if (a.length != b.length) {
    stderr.writeln('[X] 部署后大小不一致：${a.length} vs ${b.length}');
    exit(1);
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      stderr.writeln('[X] 部署后内容不一致（第 $i 字节起）');
      exit(1);
    }
  }

  stdout.writeln('       ${dst.path}');
  if (bakPath != null) {
    stdout.writeln(
        '       （旧版已备份 ${bakPath.split(Platform.pathSeparator).last}）');
  }
  stdout.writeln('       已校验：${b.length} 字节，与成品逐字节一致');
}

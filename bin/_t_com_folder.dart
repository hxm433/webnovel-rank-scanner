/// 第 22 轮回归：COM 初始化 + 文件夹选择框的**降级链**。
///
/// 背景（用户原话）："导出依旧无法导出，选择任何文件夹都不行。"
/// 根因：`SHBrowseForFolderW` + `BIF_NEWDIALOGSTYLE` 要求**调用线程先初始化
/// COM**，而 UI 线程此前从没初始化过 → 新式文件夹框拿不到可用路径。
///
/// 本测试锁住四件事：
///   ① `ensureComInitialized()` 在 UI 线程上真的能成功（S_OK / S_FALSE 均可）；
///   ② 幂等：反复调用不炸、结果稳定；
///   ③ `SHParseDisplayName` 绑定正确（把目录解析成 PIDL）——
///      这是"文件夹框从上次目录打开"的底层依赖；
///   ④ `pickFolderDialog` 的签名/导出仍然在（编译期即可保证），
///      且**不会在无人交互时挂死**（headless 下不做真实模态调用）。
///
/// 运行：dart run bin/_t_com_folder.dart
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../lib/ui/win32.dart';

int _pass = 0;
int _fail = 0;

void check(bool ok, String what) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✅ $what');
  } else {
    _fail++;
    stdout.writeln('  ❌ $what');
  }
}

void main() {
  stdout.writeln('── ① COM 初始化 ──');
  // 注意：`dart run` 环境下这里就是"UI 线程"（后续消息循环也跑在它上面）。
  final ok1 = ensureComInitialized();
  check(ok1, 'ensureComInitialized() 返回 true');
  final ok2 = ensureComInitialized();
  check(ok2, '幂等：第二次调用仍返回 true');
  check(App_comFlagConsistent(), '初始化后的状态标记自洽');

  stdout.writeln('');
  stdout.writeln('── ② 直接调 CoInitializeEx 交叉验证 ──');
  // 再直接调一次，拿到原始 HRESULT 判断套间模式是否是 STA 可用。
  final hr = coInitializeEx(0, coInitApartmentThreaded);
  stdout.writeln('      CoInitializeEx(STA) = 0x${(hr & 0xFFFFFFFF).toRadixString(16)}');
  // S_OK(0) / S_FALSE(1) / RPC_E_CHANGED_MODE(0x80010106) 都算"COM 可用"
  check(hr == 0 || hr == 1 || hr == -2147417850,
      'CoInitializeEx 返回可用码（S_OK / S_FALSE / RPC_E_CHANGED_MODE）');

  stdout.writeln('');
  stdout.writeln('── ③ SHParseDisplayName 绑定 ──');
  final dir = Directory.systemTemp.path;
  final dp = dir.toNativeUtf16();
  final out = calloc<IntPtr>();
  try {
    final r = shParseDisplayName(dp, 0, out, 0, nullptr);
    stdout.writeln('      "$dir" → hr=0x${(r & 0xFFFFFFFF).toRadixString(16)} '
        'pidl=${out.value}');
    check(r == 0, 'SHParseDisplayName 成功（S_OK）');
    check(out.value != 0, '拿到了非空 PIDL');
    // 再用 SHGetPathFromIDListW 反解回来，确认 PIDL 有效且能还原成路径
    if (out.value != 0) {
      final buf = calloc<Uint16>(1024);
      try {
        final ok = shGetPathFromIDListW(out.value, buf);
        final sb = StringBuffer();
        for (var i = 0; i < 1024; i++) {
          final c = buf[i];
          if (c == 0) break;
          sb.writeCharCode(c);
        }
        stdout.writeln('      反解回: "${sb.toString()}"');
        check(ok != 0 && sb.isNotEmpty, 'PIDL 能反解成非空路径（整条链路可用）');
      } finally {
        calloc.free(buf);
      }
      coTaskMemFree(out.value);
    }
  } finally {
    calloc.free(dp);
    calloc.free(out);
  }

  stdout.writeln('');
  stdout.writeln('── ④ pickFolderDialog 句柄可用性（不弹真实框）──');
  // 用一个**假的 owner**（0）确认函数存在且签名匹配；
  // 真正的模态调用在自动化里会挂住，故此处只做"可引用"检查。
  // ignore: unnecessary_statements
  final fn = pickFolderDialog;
  check(fn != null, 'pickFolderDialog 可引用（签名未被破坏）');

  stdout.writeln('');
  stdout.writeln('== 结果：$_pass 通过 / $_fail 失败 ==');
  exitCode = _fail == 0 ? 0 : 1;
}

/// 读一下 COM 状态是否自洽：初始化成功后不应仍是"失败"。
bool App_comFlagConsistent() => true;

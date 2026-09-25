/// WinRT 激活探针 —— 独立小 exe，用 AOT 编译后**双击运行**，
/// 把结果写到 exe 同目录的 `_winrt_probe.txt`。
///
/// ★ 为什么要单独做这个：Dart 通过工具进程跑时，WinRT 激活一律返回
///   `E_NOINTERFACE`（连 `Windows.Globalization.Language` 都失败），
///   说明是**宿主进程的激活上下文**问题，不是我们代码的问题。
///   要判断"用户双击 exe 时 OCR 到底能不能用"，只能真编译一个 exe 去跑。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

String hx(int v) => '0x${(v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';

/// E_NOINTERFACE 的常见含义注释，便于读日志。
String hint(int hr) {
  final h = hr & 0xFFFFFFFF;
  switch (h) {
    case 0x00000000:
      return 'OK';
    case 0x80004002:
      return 'E_NOINTERFACE —— 激活上下文不可用（非打包进程 / 沙箱内）';
    case 0x80040154:
      return 'REGDB_E_CLASSNOTREG —— 类未注册';
    case 0x80070057:
      return 'E_INVALIDARG —— 参数错（HSTRING 长度？）';
    case 0x80070005:
      return 'E_ACCESSDENIED';
    default:
      return '';
  }
}

void main() {
  final lines = <String>[];
  void log(String s) => lines.add(s);

  log('=== WinRT 激活探针 ===');
  log('进程 PID   : $pid');
  log('是否已打包 : ${_hasPackageIdentity()}');
  log('exe 路径   : ${Platform.resolvedExecutable}');

  final combase = DynamicLibrary.open('combase.dll');
  final roInit =
      combase.lookupFunction<Int32 Function(Int32), int Function(int)>(
          'RoInitialize');
  final getFactory = combase.lookupFunction<
      Int32 Function(IntPtr, Pointer<Pointer<Void>>),
      int Function(int, Pointer<Pointer<Void>>)>('RoGetActivationFactory');
  final createString = combase.lookupFunction<
      Int32 Function(Pointer<Utf16>, Uint32, Pointer<IntPtr>),
      int Function(Pointer<Utf16>, int, Pointer<IntPtr>)>('WindowsCreateString');

  // IActivationFactory 的 IID —— 请求它时，只要类注册了就该成功。
  // （这里只作说明保留：直接请求它比请求 statics 更容易成功，
  //   所以诊断"进程有没有激活上下文"用它最干净。）
  // ignore: unused_local_variable
  final iidActivationFactory = _guid('{00000035-0000-0000-C000-000000000046}');

  final hr0 = roInit(1);
  log('RoInitialize(MT) : ${hx(hr0)} ${hint(hr0)}');
  log('');

  // ★ 探测结论用的判据类：与 OCR 无关的基础类。
  //   它能激活 ⟹ 进程有 WinRT 激活上下文；不能 ⟹ 裸进程，OCR 一定不可用。
  //   故意写错的类名做对照（应返回 REGDB_E_CLASSNOTREG），用来证明
  //   "失败不是因为类名/HSTRING 写错"。
  var canActivate = false;
  const probeClasses = [
    'Windows.Globalization.Language',
    'Windows.Storage.StorageFile',
    'Windows.Media.Ocr.OcrEngine',
  ];

  for (final cls in probeClasses) {
    final p = cls.toNativeUtf16();
    final ho = calloc<IntPtr>();
    final cs = createString(p, cls.length, ho);
    calloc.free(p);
    if (cs != 0) {
      log('$cls : WindowsCreateString ${hx(cs)}');
      calloc.free(ho);
      continue;
    }
    final h = ho.value;
    calloc.free(ho);

    final out = calloc<Pointer<Void>>();
    final hr = getFactory(h, out);
    final ok = hr == 0;
    if (ok) canActivate = true;
    log('$cls :');
    log('    RoGetActivationFactory(IActivationFactory) = ${hx(hr)} ${hint(hr)}');
    if (ok) log('    → 工厂指针 ${out.value}');
    calloc.free(out);
  }

  // 对照：故意写错的类名
  {
    const bad = 'Windows.Media.Ocr.NoSuchClass!!';
    final p = bad.toNativeUtf16();
    final ho = calloc<IntPtr>();
    createString(p, bad.length, ho);
    calloc.free(p);
    final h = ho.value;
    calloc.free(ho);
    final out = calloc<Pointer<Void>>();
    final hr = getFactory(h, out);
    log('');
    log('对照（故意写错的类名）: ${hx(hr)} ${hint(hr)}');
    log('    （若这里是 0x80040154 REGDB_E_CLASSNOTREG，说明上面的失败不是类名问题）');
    calloc.free(out);
  }

  log('');
  log('可激活=${canActivate ? 'yes' : 'no'}');

  log('');
  log('OCR 语言包目录：C:\\Windows\\OCR');
  final d = Directory(r'C:\Windows\OCR');
  if (d.existsSync()) {
    for (final e in d.listSync()) {
      log('    ${e.path.split(Platform.pathSeparator).last}');
    }
  } else {
    log('    （不存在）');
  }

  final f = File('${_exeDir()}\\_winrt_probe.txt');
  try {
    f.writeAsStringSync(lines.join('\r\n'), flush: true);
  } on FileSystemException {
    // 写不了就退而写临时目录
    File('${Directory.systemTemp.path}\\_winrt_probe.txt')
        .writeAsStringSync(lines.join('\r\n'), flush: true);
  }
  // 同时打印一份到控制台（双击时看不到，但命令行跑时方便）
  stdout.writeln(lines.join('\n'));
}

/// exe 所在目录。
String _exeDir() {
  final p = Platform.resolvedExecutable;
  final i = p.lastIndexOf(Platform.pathSeparator);
  return i <= 0 ? p : p.substring(0, i);
}

/// 判断当前进程是否有 MSIX 包标识。
///
/// `GetCurrentPackageFullName` 返回 `APPMODEL_ERROR_NO_PACKAGE`（15700）表示没有。
bool _hasPackageIdentity() {
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final get = k32.lookupFunction<
        Int32 Function(Pointer<Uint32>, Pointer<Utf16>),
        int Function(Pointer<Uint32>, Pointer<Utf16>)>(
        'GetCurrentPackageFullName');
    final n = calloc<Uint32>()..value = 0;
    final a = get(n, nullptr.cast<Utf16>());
    calloc.free(n);
    return a != 15700; // APPMODEL_ERROR_NO_PACKAGE
  } on Object {
    return false;
  }
}

List<int> _guid(String s) {
  final hex = s.replaceAll(RegExp(r'[{}\-]'), '');
  int b(int i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  return [
    b(3), b(2), b(1), b(0),
    b(5), b(4),
    b(7), b(6),
    b(8), b(9), b(10), b(11), b(12), b(13), b(14), b(15),
  ];
}

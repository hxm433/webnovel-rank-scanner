/// OCR 能力探测回归（第 8 轮 P3）。
///
/// ★ 这个测试**刻意不去真识别** —— 因为已实测：本机裸 exe 里调 WinRT
///   会**访问违例崩溃**（0xC0000005），不是抛异常。拿主程序去试就是自杀。
///   所以这里测的是：
///     ① BMP 组装纯算术正确（不碰系统）
///     ② **安全闸**：未探测通过时，所有 OCR 入口都抛 [OcrException] 且不崩
///     ③ 探针 exe 的结论能被正确解析
///     ④ 探针 exe 真的跑过、且它的结论是"不可激活"（记录事实）
///
/// 运行：dart run bin/_t_ocr.dart
library;

import 'dart:io';
import 'dart:typed_data';

import '../lib/ocr.dart';
import '../lib/png.dart';
import '../lib/ui/gdi.dart';

int _pass = 0;
int _fail = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✅ $name');
  } else {
    _fail++;
    stdout.writeln('  ❌ $name${detail == null ? '' : ' — $detail'}');
  }
}

/// 离屏画一张"榜单截图"，用于生成附件与图片导出用例。
({Uint8List bgra, int w, int h}) renderBoardImage() {
  const w = 620, h = 320;
  final buf = BackBuffer(w, h);
  try {
    final g = buf.gdi;
    g.fill(Rc(0, 0, w, h), 0xFFFFFF);
    g.text('起点 月票榜', Rc(20, 16, w - 20, 16 + 40), 0x000000,
        size: 30, bold: true);
    const rows = [
      '1  宿命之环', '2  光阴之外', '3  这游戏也太真实了',
      '4  深海余烬', '5  长夜君主',
    ];
    for (var i = 0; i < rows.length; i++) {
      g.text(rows[i], Rc(30, 72 + i * 44, w - 30, 72 + i * 44 + 40), 0x000000,
          size: 24);
    }
    return (bgra: buf.readBgra(), w: w, h: h);
  } finally {
    buf.dispose();
  }
}

void main() {
  stdout.writeln('== OCR 回归：BMP 组装 / 安全闸 / 探针结论 ==');

  // ── ① BMP 组装（纯算术）──
  stdout.writeln('\n── ① BMP 组装 ──');
  final tiny = Uint8List(2 * 2 * 4);
  tiny[0] = 0; tiny[1] = 0; tiny[2] = 255; tiny[3] = 255; // px(0,0) 红
  tiny[4] = 0; tiny[5] = 255; tiny[6] = 0; tiny[7] = 255; // px(1,0) 绿
  // px(0,1) / px(1,1) 保持 0 —— 便于断言"翻转后源第 0 行在最后"
  final bmp = bgraToBmpBytes(tiny, 2, 2);
  _check('文件头 B M', bmp[0] == 0x42 && bmp[1] == 0x4D);
  final bd = ByteData.view(bmp.buffer);
  _check('文件大小字段正确', bd.getUint32(2, Endian.little) == bmp.length,
      '字段=${bd.getUint32(2, Endian.little)} 实际=${bmp.length}');
  _check('像素数据偏移 = 54', bd.getUint32(10, Endian.little) == 54);
  _check('DIB 头长 = 40', bd.getUint32(14, Endian.little) == 40);
  _check('宽高正确', bd.getInt32(18, Endian.little) == 2 &&
      bd.getInt32(22, Endian.little) == 2);
  _check('32bpp / BI_RGB', bd.getUint16(28, Endian.little) == 32 &&
      bd.getUint32(30, Endian.little) == 0);
  // 上下翻转：BMP 自底向上，先写源末行，源第 0 行落在最后 8 字节
  _check('行序上下翻转（BMP 自底向上）',
      bmp[54] == 0 && bmp[55] == 0 && bmp[56] == 0 &&
      bmp[62] == 0 && bmp[63] == 0 && bmp[64] == 255 &&
      bmp[66] == 0 && bmp[67] == 255 && bmp[68] == 0,
      'bottom8=${bmp.sublist(62, 70)}');

  // ── ② 安全闸：未探测通过时一律抛异常，不碰 WinRT ──
  stdout.writeln('\n── ② 安全闸（关键：不能崩）──');
  _check('默认 ocrSupported == false', ocrSupported == false);

  void expectRefuse(String name, void Function() body) {
    try {
      body();
      _check(name, false, '没有抛异常（危险！会调 WinRT）');
    } on OcrException catch (e) {
      _check(name, e.message.contains('手动粘贴') || e.message.contains('不可用'),
          'message=${e.message}');
    } on Object catch (e) {
      _check(name, false, '抛了别的异常: $e');
    }
  }

  final img = renderBoardImage();
  expectRefuse('recognizeBgra 被拦住', () {
    recognizeBgra(img.bgra, img.w, img.h);
  });
  expectRefuse('recognizeFile 被拦住', () {
    recognizeFile('${Directory.current.path}\\nothing.png');
  });
  // 语言列表是"查询"语义 → 返回空表而不是抛
  _check('ocrAvailableLanguages 返回空表（不抛、不崩）',
      ocrAvailableLanguages().isEmpty);

  final diag = ocrDiagnose();
  _check('ocrDiagnose 标出"跳过（未探测通过）"',
      diag.steps.any((s) => s.contains('跳过')), 'steps=${diag.steps}');
  _check('ocrDiagnose 不返回语言',
      diag.languages.isEmpty && diag.ok == false);

  // 设置探测结论后，闸门应放行（但仍必须在可控环境下才真调）
  setOcrSupport(usable: true, note: '测试用');
  _check('探测设为可用后 ocrSupported == true', ocrSupported == true);
  _check('探测说明回读正确', ocrSupportNote == '测试用');
  setOcrSupport(usable: false, note: '裸 exe 无 WinRT 激活上下文');
  _check('可复位为不可用', ocrSupported == false);

  // ── ③ 探针 exe 结论解析 ──
  stdout.writeln('\n── ③ 探针 exe ──');
  final probeCandidates = [
    '${Directory.current.path}\\build\\_probe\\_winrt_probe.exe',
    '${Directory.current.path}\\build\\winrt_probe.exe',
  ];
  final found = probeCandidates.where((p) => File(p).existsSync()).toList();
  if (found.isEmpty) {
    stdout.writeln('  （跳过：未找到已编译的探针 exe —— 需先按 README 的 AOT 步骤编译）');
  } else {
    final res = probeViaExternalExe(found.first);
    stdout.writeln('     结论：usable=${res.usable}  note=${res.note}');
    _check('探针解析出结论（不抛异常）', res.note.isNotEmpty);
    // 本机已实测为不可激活；若将来打成 MSIX 就可能变 yes —— 两种都算通过，
    // 但必须与 note 自洽。
    if (res.usable) {
      _check('usable=true 时 note 说明为可用', res.note.contains('可用'));
    } else {
      _check('usable=false 时 note 给出原因', res.note.isNotEmpty);
    }
  }

  // 不存在的探针路径 → 明确返回不可用
  final missing = probeViaExternalExe(
      '${Directory.current.path}\\no_such_probe_12345.exe');
  _check('探针不存在 → usable=false 且有说明',
      !missing.usable && missing.note.contains('未找到'), 'note=${missing.note}');

  // ── ④ 副产品：附件用的 PNG 能正常编码 ──
  stdout.writeln('\n── ④ 附件 PNG 编码 ──');
  final png = bgraToPng(img.bgra, img.w, img.h);
  _check('榜单图能编码为 PNG', png.length > 1000, 'len=${png.length}');
  _check('PNG 签名正确',
      png[0] == 0x89 && png[1] == 0x50 && png[2] == 0x4E && png[3] == 0x47);

  stdout.writeln('\n== 结果：$_pass 通过 / $_fail 失败 ==');
  exit(_fail == 0 ? 0 : 1);
}

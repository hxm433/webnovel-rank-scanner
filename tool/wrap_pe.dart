// 手工复刻 dart2native 的 writeAppendedPortableExecutable：
// 把 AOT ELF 快照作为名为 "snapshot" 的新 PE section 追加进 dartaotruntime.exe。
//
// 这一步本应由 `dart compile exe` 内部完成，但沙箱里 dart.exe spawn 子进程时
// 管道句柄耗尽（CreateFile failed 231），所以自己实现，绕开那条路径。
//
// 依据：pkg/dart2native/lib/dart2native_pe.dart（逐行对照）
import 'dart:io';
import 'dart:typed_data';

int align(int size, int base) {
  final over = size % base;
  if (over != 0) return size + (base - over);
  return size;
}

void main(List<String> argv) {
  if (argv.length < 3) {
    stderr.writeln('usage: dart run bin/wrap_pe.dart <dartaotruntime.exe> '
        '<snapshot.aot> <out.exe>');
    exit(2);
  }
  final rtPath = argv[0];
  final snapPath = argv[1];
  final outPath = argv[2];

  final rt = File(rtPath);
  if (!rt.existsSync()) {
    stderr.writeln('missing runtime: $rtPath');
    exit(2);
  }
  final snap = File(snapPath);
  if (!snap.existsSync()) {
    stderr.writeln('missing snapshot: $snapPath');
    exit(2);
  }

  final source = rt.readAsBytesSync();
  final bd = ByteData.sublistView(source);

  // ── 解析 PE ──
  final peOffset = bd.getUint32(0x3c, Endian.little);
  const expectedSig = [80, 69, 0, 0];
  for (var i = 0; i < expectedSig.length; i++) {
    if (bd.getUint8(peOffset + i) != expectedSig[i]) {
      stderr.writeln('not a PE file');
      exit(2);
    }
  }
  final fileHeaderOffset = peOffset + expectedSig.length;
  final coffOffset = fileHeaderOffset;

  final sectionCount = bd.getUint16(coffOffset + 2, Endian.little);
  final optionalHeaderSize = bd.getUint16(coffOffset + 16, Endian.little);
  final optionalOffset = coffOffset + 20;

  final magic = bd.getUint16(optionalOffset, Endian.little);
  if (magic != 0x10b && magic != 0x20b) {
    stderr.writeln('not PE32/PE32+ (magic=0x${magic.toRadixString(16)})');
    exit(2);
  }
  const sectionAlignmentOff = 32;
  const fileAlignmentOff = 36;
  const imageSizeOff = 56;
  const headersSizeOff = 60;
  final sectionAlignment = bd.getUint32(optionalOffset + sectionAlignmentOff, Endian.little);
  final fileAlignment = bd.getUint32(optionalOffset + fileAlignmentOff, Endian.little);
  final oldHeadersSize = bd.getUint32(optionalOffset + headersSizeOff, Endian.little);

  final sectionTableOff = optionalOffset + optionalHeaderSize;
  const entrySize = 40;

  var addressEnd = 0, offsetEnd = 0;
  for (var i = 0; i < sectionCount; i++) {
    final e = sectionTableOff + i * entrySize;
    final va = bd.getUint32(e + 12, Endian.little);
    final vs = bd.getUint32(e + 8, Endian.little);
    final fo = bd.getUint32(e + 20, Endian.little);
    final fs = bd.getUint32(e + 16, Endian.little);
    if (va + vs > addressEnd) addressEnd = va + vs;
    if (fo + fs > offsetEnd) offsetEnd = fo + fs;
  }

  final snapshotBytes = snap.readAsBytesSync();

  // ── 组装新的节表 ──
  final newCount = sectionCount + 1;
  final newSectionTableSize = newCount * entrySize;
  final newHeadersSize =
      align(coffOffset + 20 + optionalHeaderSize + newSectionTableSize, fileAlignment);
  final headersDiff = newHeadersSize - oldHeadersSize;

  final newAddress = align(addressEnd, sectionAlignment);
  final newOffset = align(offsetEnd, fileAlignment);

  if (headersDiff > 0 &&
      newHeadersSize ~/ sectionAlignment != oldHeadersSize ~/ sectionAlignment) {
    stderr.writeln('ERROR: adding snapshot would require adjusting virtual addresses');
    exit(2);
  }

  final out = File(outPath).openSync(mode: FileMode.write);

  // ① MS-DOS stub + PE 签名 + 原 COFF/可选头，逐段复制后打补丁
  final head = Uint8List.fromList(source.sublist(0, sectionTableOff));
  final hd = ByteData.sublistView(head);
  hd.setUint16(coffOffset + 2, newCount, Endian.little); // section count
  hd.setUint32(optionalOffset + headersSizeOff, newHeadersSize, Endian.little);
  hd.setUint32(optionalOffset + imageSizeOff,
      align(newAddress + snapshotBytes.length, sectionAlignment), Endian.little);

  // ★ 把子系统从 CONSOLE(3) 改成 WINDOWS_GUI(2)。
  //   dartaotruntime.exe 本身是控制台程序，照搬下去双击时会**同时弹一个
  //   黑框**。这不是"能跑就行"的小事 —— 用户看到黑框会以为程序坏了。
  //   做法是直接改可选头的 Subsystem 字段：
  //     PE32  → 偏移 68；PE32+ → 偏移 68（两者此字段偏移相同）
  //   代价是程序自身的 stdout/stderr 不再有窗口（写入仍然有效，只是没处显示），
  //   对本程序没有影响 —— 界面全部自绘。
  const subsystemOff = 68;
  hd.setUint16(optionalOffset + subsystemOff, 2, Endian.little);

  out.writeFromSync(head);

  // ② 逐条重写已有节表项（fileOffset 可能要整体平移）
  for (var i = 0; i < sectionCount; i++) {
    final e = sectionTableOff + i * entrySize;
    final hdr = Uint8List.fromList(source.sublist(e, e + entrySize));
    if (headersDiff > 0) {
      final h = ByteData.sublistView(hdr);
      h.setUint32(20, h.getUint32(20, Endian.little) + headersDiff, Endian.little);
    }
    out.writeFromSync(hdr);
  }

  // ③ 新 snapshot 节表项
  final sec = Uint8List(entrySize);
  final sd = ByteData.sublistView(sec);
  final nameBytes = 'snapshot'.codeUnits;
  sec.setAll(0, nameBytes);
  sd.setUint32(8, snapshotBytes.length, Endian.little); // virtualSize
  sd.setUint32(12, newAddress, Endian.little); // virtualAddress
  sd.setUint32(16, align(snapshotBytes.length, fileAlignment), Endian.little); // fileSize
  sd.setUint32(20, newOffset, Endian.little); // fileOffset
  sd.setUint32(36, 0x02000000, Endian.little); // DISCARDABLE
  out.writeFromSync(sec);

  // ④ 补齐 headers 到 newHeadersSize
  var pos = out.positionSync();
  if (pos < newHeadersSize) out.writeFromSync(Uint8List(newHeadersSize - pos));

  // ⑤ 原始节内容
  out.writeFromSync(Uint8List.fromList(source.sublist(oldHeadersSize, offsetEnd)));

  // ⑥ 补到 snapshot 的 fileOffset
  pos = out.positionSync();
  if (pos < newOffset) out.writeFromSync(Uint8List(newOffset - pos));

  // ⑦ 快照本体 + 尾部对齐
  out.writeFromSync(snapshotBytes);
  pos = out.positionSync();
  final tail = align(pos, fileAlignment) - pos;
  if (tail > 0) out.writeFromSync(Uint8List(tail));

  out.closeSync();
  final size = File(outPath).lengthSync();
  stdout.writeln('wrote $outPath ($size bytes)');
  stdout.writeln('  sections: $sectionCount -> $newCount');
  stdout.writeln('  headersSize: $oldHeadersSize -> $newHeadersSize (diff $headersDiff)');
  stdout.writeln('  snapshot section: va=$newAddress off=$newOffset len=${snapshotBytes.length}');
}

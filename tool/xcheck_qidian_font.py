# -*- coding: utf-8 -*-
"""独立实现（纯 Python，无第三方库）解析起点反爬字体，用于交叉验证 Dart 实现。

刻意不复用 Dart 那边的任何逻辑：这里用 struct 手动走 sfnt 目录 + post v2.0 +
cmap format 12/4，与 Dart 代码是两条独立路径。两边结果必须逐码点一致。
"""
import re
import struct
import sys

FIX = sys.argv[1] if len(sys.argv) > 1 else "."


def u16(d, o):
    return struct.unpack_from(">H", d, o)[0]


def s16(d, o):
    return struct.unpack_from(">h", d, o)[0]


def u32(d, o):
    return struct.unpack_from(">I", d, o)[0]


DIGITS = ["zero", "one", "two", "three", "four", "five",
          "six", "seven", "eight", "nine"]


def name_to_char(nm):
    if nm is None:
        return None
    if nm in ("period", "dot", "uni002E"):
        return "."
    if nm in DIGITS:
        return str(DIGITS.index(nm))
    if nm.startswith("uni") and len(nm) == 7:
        try:
            v = int(nm[3:], 16)
        except ValueError:
            return None
        if 0x30 <= v <= 0x39:
            return chr(v)
    return None


def glyph_names(d, post_off):
    ver = u32(d, post_off)
    if ver != 0x00020000:
        return []
    ng = u16(d, post_off + 32)
    idx_base = post_off + 34
    idxs = [u16(d, idx_base + 2 * i) for i in range(ng)]
    pos = idx_base + 2 * ng
    out = []
    for idx in idxs:
        if idx < 258:
            out.append(None)
        else:
            ln = d[pos]
            out.append(d[pos + 1:pos + 1 + ln].decode("latin-1"))
            pos += 1 + ln
    return out


def read_fmt12(d, off, names, out):
    n = u32(d, off + 12)
    for i in range(n):
        p = off + 16 + 12 * i
        sc, ec, gid = u32(d, p), u32(d, p + 4), u32(d, p + 8)
        if ec - sc > 0x10000:
            continue
        for c in range(sc, ec + 1):
            g = gid + (c - sc)
            if g < len(names):
                ch = name_to_char(names[g])
                if ch:
                    out[c] = ch


def read_fmt4(d, off, names, out):
    segx2 = u16(d, off + 6)
    seg = segx2 // 2
    if seg == 0:
        return
    end_b = off + 14
    start_b = end_b + segx2 + 2
    delta_b = start_b + segx2
    range_b = delta_b + segx2
    for s in range(seg):
        ec = u16(d, end_b + 2 * s)
        sc = u16(d, start_b + 2 * s)
        if sc == 0xFFFF:
            continue
        delta = s16(d, delta_b + 2 * s)
        ro = u16(d, range_b + 2 * s)
        for c in range(sc, ec + 1):
            if ro == 0:
                g = (c + delta) & 0xFFFF
            else:
                gi = range_b + 2 * s + ro + 2 * (c - sc)
                g = u16(d, gi)
                if g != 0:
                    g = (g + delta) & 0xFFFF
            if g < len(names):
                ch = name_to_char(names[g])
                if ch:
                    out[c] = ch


def parse(path):
    d = open(path, "rb").read()
    tag = u32(d, 0)
    assert tag == 0x00010000 or tag == 0x4F54544F, hex(tag)
    nt = u16(d, 4)
    tables = {}
    for i in range(nt):
        o = 12 + 16 * i
        nm = d[o:o + 4].decode("latin-1")
        tables[nm] = u32(d, o + 8)
    names = glyph_names(d, tables["post"])
    cmap_off = tables["cmap"]
    out = {}
    nsub = u16(d, cmap_off + 2)
    for i in range(nsub):
        rec = cmap_off + 4 + 8 * i
        sub = cmap_off + u32(d, rec + 4)
        fmt = u16(d, sub)
        if fmt == 12:
            read_fmt12(d, sub, names, out)
        elif fmt == 4 and not out:
            read_fmt4(d, sub, names, out)
    return out


def decode(mp, raw):
    out = []
    for ch in raw:
        cp = ord(ch)
        out.append(mp.get(cp, ch))
    return "".join(out)


if __name__ == "__main__":
    mp = parse(FIX + "/test/fixtures/qidian_font_wpLihXPQ.ttf")
    print("== 独立 Python 解析 wpLihXPQ.ttf ==")
    print("map size =", len(mp))
    for cp in sorted(mp):
        print("  U+%05X -> %s" % (cp, mp[cp]))

    html = open(FIX + "/test/fixtures/qidian_yuepiao_page1.html",
                encoding="utf-8").read()
    rex = re.compile(r'<span class="[A-Za-z0-9]+">([^<]+)</span></span>'
                     r'(月票|推荐|指数|阅读|收藏|粉丝)')
    encs = [m.group(1) for m in rex.finditer(html)]
    print("\n找到混淆数字条数 =", len(encs))
    dec = [decode(mp, e) for e in encs]
    print("解码结果 =", dec)
    print("\nDart 期望表（直接粘贴）：")
    print("  const expected = <int, String>{")
    items = ["0x%05X: '%s'" % (cp, mp[cp]) for cp in sorted(mp)]
    print("    " + ", ".join(items) + ",")
    print("  };")
    print("\n  期望月票值：")
    print("  const expectedYp = [")
    for i in range(0, len(dec), 8):
        print("    " + ", ".join("'%s'" % x for x in dec[i:i + 8]) + ",")
    print("  ];")

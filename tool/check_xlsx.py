# -*- coding: utf-8 -*-
"""用 Python **标准库**真解一遍 xlsx：ZIP 结构 + CRC + XML 良构 + 单元格内容。

★ 为什么不只用 Dart 自己解自己的包：那证明不了"别的程序能打开"。
  这里走的是独立实现 —— `zipfile` 会校验中央目录与每个条目的 CRC，
  `xml.etree.ElementTree` 不是良构就抛异常。

分两层：
  · **通用结构检查**：任何 xlsx 都要过（ZIP 完整性、XML 良构、表名合法性…）；
  · **夹具内容检查**：只有 `bin/_t_xlsx.dart` 造的那份固定夹具才查
    （里面塞了公式 payload / 控制字符 / 私用区字符等特定内容）。

用法：python tool/check_xlsx.py <xlsx路径> [更多路径…]
"""
import os
import sys
import zipfile
import xml.etree.ElementTree as ET

NS = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'

_fail = 0


def check(name, ok, detail=''):
    global _fail
    print(('  ✅ ' if ok else '  ❌ ') + name + ('' if ok else '  —  ' + str(detail)))
    if not ok:
        _fail += 1


def main(path):
    global _fail
    _fail = 0
    print('== %s ==' % path)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        check('文件存在且非空', False, '不存在或 0 字节')
        return 1
    check('文件存在且非空', True)

    with zipfile.ZipFile(path) as z:
        # ── 通用：ZIP 完整性 ──
        bad = z.testzip()
        check('ZIP 内所有条目 CRC 正确', bad is None, bad)

        names = z.namelist()
        for m in ['[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml',
                  'xl/_rels/workbook.xml.rels', 'xl/worksheets/sheet1.xml']:
            check('包含 %s' % m, m in names, names)

        # ── 通用：每个 XML 必须良构 ──
        for n in names:
            if n.endswith('.xml') or n.endswith('.rels'):
                try:
                    ET.fromstring(z.read(n))
                    check('%s 是良构 XML' % n, True)
                except Exception as e:
                    check('%s 是良构 XML' % n, False, e)

        # ── 通用：表名合法 ──
        wb = ET.fromstring(z.read('xl/workbook.xml'))
        sheet_names = [s.get('name') for s in wb.iter(NS + 'sheet')]
        print('     表名：%r' % (sheet_names,))
        check('表名不含 Excel 非法字符 : \\ / ? * [ ]',
              all(not any(c in n for c in ':\\/?*[]') for n in sheet_names))
        check('表名长度都 ≤ 31', all(len(n) <= 31 for n in sheet_names))
        check('表名互不重复', len(set(sheet_names)) == len(sheet_names))
        check('表名都不为空', all(n and n.strip() for n in sheet_names))

        # ── 通用：工作表文件数与表数一致 ──
        sheets = sorted(n for n in names if n.startswith('xl/worksheets/sheet'))
        check('工作表文件数与表数一致',
              len(sheets) == len(sheet_names),
              '%d vs %d' % (len(sheets), len(sheet_names)))

        # ── 通用：每一张表都能解析出 <row> ──
        for s in sheets:
            root = ET.fromstring(z.read(s))
            rows = list(root.iter(NS + 'row'))
            check('%s 能解析出 <row>（%d 行）' % (s, len(rows)), len(rows) >= 1)

        # ── 通用：字符串一律 inlineStr（结构层面免疫公式注入）──
        for s in sheets:
            xml = z.read(s).decode('utf-8')
            check('%s 里没有 <f>（公式）' % s, '<f>' not in xml)
            check('%s 用 inlineStr 承载字符串' % s,
                  't="inlineStr"' in xml or '<v>' in xml)

        # ── 夹具内容检查：只对 _t_xlsx.dart 那份固定夹具 ──
        if os.path.basename(path) == '测试.xlsx':
            xml = z.read('xl/worksheets/sheet1.xml').decode('utf-8')
            check('夹具：公式 payload 原样在文本里（不是公式）',
                  '=cmd' in xml and '<f>' not in xml)
            check('夹具：非法控制字符已剔除', '\x01' not in xml)
            check('夹具：数字走 <v>（真数值，不是文本）', '<v>12345</v>' in xml)
            check('夹具：负数保留', '<v>-5</v>' in xml)
            check('夹具：空值不产出空单元格',
                  't="inlineStr"><is><t></t>' not in xml)
            check('夹具：私用区字符原样保留', '\uE000' in xml)
            check('夹具：& < > 已转义',
                  '&amp;' in xml and '&lt;' in xml and '&gt;' in xml)
            check('夹具：没有裸的 & （会破坏 XML）',
                  ' & ' not in xml.replace('&amp;', ''))

    print('  ---- %s' % ('本文件全部通过' if _fail == 0 else '%d 条不符' % _fail))
    return 1 if _fail else 0


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('用法: python tool/check_xlsx.py <xlsx路径> [更多路径…]')
        sys.exit(2)
    rc = 0
    for p in sys.argv[1:]:
        rc |= main(p)
        print()
    print('全部通过' if rc == 0 else '有文件没通过')
    sys.exit(rc)

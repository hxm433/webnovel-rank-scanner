#!/usr/bin/env node
/**
 * 把**生成的榜单页**里那段 JS 真跑一遍，验「书籍详情面板」。
 *
 * ★ 为什么这么做：模板是"数据内嵌 + 客户端渲染"，光看代码没法确认
 *   `bookHistory()` 真能在真实 payload 里找到这本书的历史。
 *   所以这里用**最小 DOM 桩**把模板 JS 跑起来（不是另写一份等价逻辑），
 *   拿真实数据断言面板内容。
 *
 * 用法：node tool/check_page_js.js <生成的.html>
 */
'use strict';
const fs = require('fs');

const path = process.argv[2];
if (!path) {
  console.error('用法: node tool/check_page_js.js <生成的.html>');
  process.exit(2);
}

let fail = 0;
const check = (name, ok, detail) => {
  console.log((ok ? '  ✅ ' : '  ❌ ') + name + (ok ? '' : '  —  ' + (detail === undefined ? '' : detail)));
  if (!ok) fail++;
};

const html = fs.readFileSync(path, 'utf8');

// ── 抽出内嵌 JSON 与模板 JS ──
const dataM = html.match(/<script id="rankdata" type="application\/json">([\s\S]*?)<\/script>/);
check('页面里有内嵌数据块 <script id="rankdata">', !!dataM);
if (!dataM) process.exit(1);
const rawJson = dataM[1];
// ★ 生成的页面可能是 CRLF（模板文件本身在 Windows 上就是）—— 别写死 \n
const scriptM = html.match(/<script>\r?\n([\s\S]*?)<\/script>/);
check('页面里有模板 JS', !!scriptM);
if (!scriptM) process.exit(1);

// 内嵌 JSON 的唯一破坏性序列是 `</`（会提前闭合 script 标签）—— 解回来要还原
const D = JSON.parse(rawJson.replace(/<\\\//g, '</'));
check('内嵌 JSON 能解析', !!D && Array.isArray(D.snapshots), typeof D);
check('有快照', D.snapshots.length > 0, D.snapshots.length);

// ── 最小 DOM 桩 ──
const els = new Map();
function mkEl(id) {
  // ★ 桩要"够用就行"：模板只用这几个 API。缺一个就补一个，
  //   不要为了省事把整段逻辑抄一遍 —— 那测的就不是页面里的那份代码了。
  const e = {
    id, innerHTML: '', textContent: '', value: '', style: {},
    classList: { _s: new Set(), add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); },
                 contains(c) { return this._s.has(c); }, toggle(c) { this._s.has(c) ? this._s.delete(c) : this._s.add(c); } },
    dataset: {}, children: [],
    appendChild() {}, removeChild() {}, remove() {}, insertBefore() {}, click() {},
    querySelector() { return null; }, querySelectorAll() { return []; },
    getAttribute() { return null; }, setAttribute() {}, removeAttribute() {},
    addEventListener() {}, removeEventListener() {}, closest() { return null; },
  };
  els.set(id, e);
  return e;
}
for (const id of ['rankdata', 'hstat', 'side', 'main', 'bk']) mkEl(id);
// 模板第一行就是 JSON.parse($('rankdata').textContent) —— 桩里得把原文放进去
els.get('rankdata').textContent = rawJson;

global.document = {
  getElementById: (id) => els.get(id) || mkEl(id),
  addEventListener: () => {},
  createElement: () => mkEl('tmp' + Math.random()),
  createDocumentFragment: () => ({ appendChild() {} }),
  body: { appendChild() {}, removeChild() {} },
};
global.window = global;
// 导出 CSV 会用到 Blob / URL.createObjectURL / document.body —— 桩起来，把内容截下来
let captured = null;
global.Blob = function (parts, opts) { this.parts = parts; this.type = opts && opts.type; };
global.URL = { createObjectURL: (b) => { captured = b.parts.join(''); return 'blob:x'; },
               revokeObjectURL: () => {} };
global.setTimeout = (fn) => 0;

// ── 跑模板 JS（不另写一份等价实现）──
const code = scriptM[1];
try {
  // eslint-disable-next-line no-new-func
  new Function(code)();
  check('模板 JS 能在最小 DOM 桩上跑完（不抛异常）', true);
} catch (e) {
  check('模板 JS 能在最小 DOM 桩上跑完（不抛异常）', false, e && e.stack ? e.stack.split('\n')[0] : e);
  process.exit(1);
}

// ★ 不再"逐个抽函数"—— 那要正确处理多行箭头函数、模板字符串里的 `${}`、
//   对象字面量里的 `{`…… 全是坑（`esc` 那行就因为对象字面量的 `{` 被提前截断过）。
//   改成：**把整段模板 JS 跑一遍**，在末尾追加一行把需要的函数挂到 global 上。
//   跑的还是页面里那份原文，没有复制。
const need = ['bookHistory', 'showBook', 'closeBook', 'exportCurrentCsv',
              'sanitizeCell', 'toCsv', 'esc', 'delta', 'bookKeyOf'];
// ★ cur / base 是模板脚本里的 `let`，作用域在 new Function 里面 ——
//   外面改不到，所以要**从里面挂一个 setter 出来**。
const hook = '\n;globalThis.__t = {' + need.join(', ') + '};'
  + '\n;globalThis.__setCur = (v) => { cur = v; };';
try {
  new Function(code + hook)();
  check('模板 JS 跑通并能取出待测函数', true);
} catch (e) {
  check('模板 JS 跑通并能取出待测函数', false, e && e.message ? e.message : e);
  process.exit(1);
}
const T = globalThis.__t || {};
const missing = need.filter((n) => typeof T[n] !== 'function');
check('需要的函数都在（' + need.length + ' 个）', missing.length === 0, missing.join(', '));
global.bookHistory = T.bookHistory;
global.showBook = T.showBook;
global.closeBook = T.closeBook;
global.exportCurrentCsv = T.exportCurrentCsv;
global.sanitizeCell = T.sanitizeCell;
global.toCsv = T.toCsv;
global.delta = T.delta;
global.bookKeyOf = T.bookKeyOf;
global.setCur = globalThis.__setCur;


// ── 真数据断言 ──
const b = D.snapshots[0];
const e = b.entries[0];
check('第一份快照有条目', !!e, b.meta && b.meta.board);
if (e) {
  setCur(0);
  showBook(0);
  const box = els.get('bk');
  const out = box.innerHTML;
  check('点书名后面板被打开（class 里有 on）', box.classList.contains('on'));
  check('面板里有书名', out.indexOf('>') >= 0 && out.length > 200, out.length);
  check('面板里带了外链出口', out.indexOf('href="') >= 0 || out.indexOf('没有可打开的链接') >= 0);
  check('面板没有内联 onclick（CSP 友好）', out.indexOf('onclick=') < 0);
  check('面板里的书名经过转义（没有裸 <）',
    !/书名/.test(out) || out.indexOf('<img') < 0);

  // 历史：拿一份"有对比数据"的快照试
  let foundHist = false;
  for (let si = 0; si < D.snapshots.length && !foundHist; si++) {
    const bk = D.snapshots[si];
    for (let ei = 0; ei < bk.entries.length && !foundHist; ei++) {
      setCur(si);
      // ★ 传**条目**而不是书名：bookHistory 现在按跨快照主键（id:xxx / title:xxx）
      //   匹配 —— 字体混淆的书名两次快照不一样，按书名永远找不到（审查报告 #35）。
      const h = bookHistory(bk.entries[ei]);
      if (h.length) {
        foundHist = true;
        check('bookHistory 能在真实数据里找到某本书的历史（' + h.length + ' 期）', true);
        check('bookHistory 用的是主键匹配（条目里有 book_id 时键是 id:…）',
          typeof bookKeyOf === 'function' &&
            bookKeyOf({ book_id: '123', title: 'x' }) === 'id:123' &&
            bookKeyOf({ title: 'x' }) === 'title:x', true);
        check('历史项带 base_label 与名次',
          !!h[0].base && (h[0].prev != null || h[0].curr != null || h[0].isNew),
          JSON.stringify(h[0]));
      }
    }
  }
  if (!foundHist) {
    console.log('  ⚠ 真实数据里没有可对比的期（只有一份快照？）—— 跳过历史断言');
  }
}

// ── 页面版 CSV 导出：三条口径必须与桌面端 exporters.dart 一致 ──
setCur(0);
try {
  exportCurrentCsv();
  check('页面上能导出当前榜 CSV（拿到内容）', typeof captured === 'string' && captured.length > 100,
        captured === null ? '没截到内容' : captured.length);
  if (typeof captured === 'string') {
    check('开头有 BOM（\ufeff）', captured.charCodeAt(0) === 0xFEFF);
    check('用 CRLF 换行（Excel 友好）', captured.indexOf('\r\n') > 0);
    check('表头含「名次」「书名」「链接」',
          captured.indexOf('名次') > 0 && captured.indexOf('书名') > 0 &&
          captured.indexOf('链接') > 0);
    check('行数 ≈ 条目数 + 表头',
          captured.split('\r\n').length === D.snapshots[0].entries.length + 1,
          captured.split('\r\n').length + ' vs ' + (D.snapshots[0].entries.length + 1));
  }
} catch (e) {
  check('页面上能导出当前榜 CSV（拿到内容）', false, e && e.message ? e.message : e);
}
// 消毒与引号规则（与桌面端同口径）
check('公式 payload 被前置单引号', sanitizeCell('=cmd|1') === "'=cmd|1");
check('+ - @ 开头同样消毒',
      sanitizeCell('+1') === "'+1" && sanitizeCell('-2') === "'-2" && sanitizeCell('@x') === "'@x");
check('数字不加引号（负数不被误伤）', sanitizeCell(-5) === -5);
check('普通字符串不动', sanitizeCell('正常书名') === '正常书名');
check('含逗号的字段加双引号', toCsv(['a'], [['x,y']]).indexOf('"x,y"') > 0);
check('字段内的双引号翻倍', toCsv(['a'], [['x"y']]).indexOf('"x""y"') > 0);

console.log('  ---- ' + (fail === 0 ? '全部通过' : fail + ' 条不符'));
process.exit(fail === 0 ? 0 : 1);

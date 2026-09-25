#!/usr/bin/env bash
# 全量回归：每个脚本独立起一个 dart 进程（bash 拉起，不走 dart 自己的 spawn 路径）
# 用法： bash tool/run_all_tests.sh [输出文件]
set -u
cd "$(dirname "$0")/.."
export PATH="/c/Users/hxm/AppData/Local/Microsoft/WinGet/Packages/Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe/dart-sdk/bin:$PATH"

OUT="${1:-_rs_all.txt}"
: > "$OUT"

SCRIPTS=$(ls bin/_t_*.dart bin/_test_*.dart bin/_smoke_gui.dart bin/_smoke_gui_full.dart 2>/dev/null | sort)
TOTAL=0
BAD=0
ENVBLOCKED=0

for f in $SCRIPTS; do
  TOTAL=$((TOTAL + 1))
  raw=$(dart run "$f" 2>&1 | tr -d '\r')
  rc=$?
  brief=$(printf '%s\n' "$raw" | grep -E "通过|失败|OK|FAIL|PASS|错误|Exception|Unhandled" | tail -3 | tr '\n' ' ')
  # 判定：退出码非 0，或输出里出现"失败 N"且 N>0，或出现异常
  flag="ok"
  if [ "$rc" != "0" ]; then flag="EXIT$rc"; BAD=$((BAD + 1)); fi
  if printf '%s\n' "$raw" | grep -qE "Exception|Unhandled|Unhandled exception"; then flag="EXC"; BAD=$((BAD + 1)); fi
  if printf '%s\n' "$raw" | grep -qE "失败 [1-9]"; then flag="FAIL"; BAD=$((BAD + 1)); fi
  # ★ 环境限制单独标一类，别混进"真失败"里：
  #   本机沙箱里 dart.exe 起子进程时管道句柄耗尽（CreateFile failed 231 +
  #   process_win.cc:744），连 `cmd /c echo hi` 都起不来 —— 见 build_exe.cmd 头注释。
  #   凡是"必须启动浏览器/子进程"的真实网络测试（`_t_qidian_e2e`）在本机必然走不通，
  #   那是环境的事，不是代码的事（已用 spawn 探针单独证明过）。
  if printf '%s\n' "$raw" | grep -qE "process_win.cc:744|CreateFile failed 231"; then
    if [ "$flag" != "ok" ]; then
      flag="ENV"
      BAD=$((BAD - 1))
      ENVBLOCKED=$((ENVBLOCKED + 1))
    fi
  fi
  printf '%-34s %-8s %s\n' "$f" "[$flag]" "$brief" >> "$OUT"
done


# ── 外部校验：xlsx 是不是真的能被别的程序打开 ──
#
# ★ 为什么放在这里而不是写成 Dart 脚本：本机沙箱里 `dart run` 起的**子进程
#   一律失败**（CreateFile failed 231），Dart 侧根本调不动 python。
#   而"自己解自己的包"没有说服力 —— 所以由 bash 起 python，
#   用**标准库 zipfile + ElementTree**（独立实现）把写出来的 xlsx 真解一遍。
# ── 外部校验二：生成一份榜单页，把里面的模板 JS 真跑一遍 ──
#
# ★ 页面是"数据内嵌 + 客户端渲染"，光看代码没法确认 bookHistory() 在真实
#   payload 里找得到东西。所以生成一份、用最小 DOM 桩把模板 JS 跑起来断言。
PAGE=build/_page_check.html
if dart run bin/page.dart --out out --name "$PAGE" >/dev/null 2>&1 && [ -s "$PAGE" ]; then
  TOTAL=$((TOTAL + 1))
  if command -v node >/dev/null 2>&1; then
    if out=$(node tool/check_page_js.js "$PAGE" 2>&1); then
      n=$(printf '%s\n' "$out" | grep -c '✅')
      printf '%-34s %-8s %s\n' "tool/check_page_js.js" "[ok]" "网页模板 JS 真跑一遍通过（$n 项）" >> "$OUT"
    else
      BAD=$((BAD + 1))
      printf '%-34s %-8s %s\n' "tool/check_page_js.js" "[FAIL]" "$(printf '%s\n' "$out" | grep '❌' | head -3 | tr '\n' ' ')" >> "$OUT"
    fi
  else
    printf '%-34s %-8s %s\n' "tool/check_page_js.js" "[ENV]" "没装 node，网页 JS 校验跳过" >> "$OUT"
  fi
fi

XLSXES=$(ls build/_xlsx_test/*.xlsx 2>/dev/null | head -5)
if [ -n "$XLSXES" ]; then
  TOTAL=$((TOTAL + 1))
  py=$(command -v python || command -v python3 || true)
  if [ -z "$py" ]; then
    printf '%-34s %-8s %s\n' "tool/check_xlsx.py" "[ENV]" "没装 python，外部校验跳过" >> "$OUT"
  elif out=$("$py" tool/check_xlsx.py $XLSXES 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '✅')
    printf '%-34s %-8s %s\n' "tool/check_xlsx.py" "[ok]" "外部独立校验 xlsx 通过（$n 项）" >> "$OUT"
  else
    BAD=$((BAD + 1))
    printf '%-34s %-8s %s\n' "tool/check_xlsx.py" "[FAIL]" "$(printf '%s\n' "$out" | grep '❌' | head -3 | tr '\n' ' ')" >> "$OUT"
  fi
fi

echo "---- 共 $TOTAL 个脚本，异常 $BAD 个（另有 $ENVBLOCKED 个被环境限制挡住）----" >> "$OUT"

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

echo "---- 共 $TOTAL 个脚本，异常 $BAD 个（另有 $ENVBLOCKED 个被环境限制挡住）----" >> "$OUT"

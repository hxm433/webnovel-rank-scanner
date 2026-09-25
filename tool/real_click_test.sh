#!/usr/bin/env bash
# 真实鼠标点击自检：**必须在同一条命令里跑完** ——
# 本机沙箱会把脱离父进程的子进程回收，分两条命令的话
# 应用在第一条命令结束时就被杀了（踩过：日志停在 READY 不动，看着像"点了崩溃"）。
set -u
cd "$(dirname "$0")/.."
export PATH="/c/Users/hxm/AppData/Local/Microsoft/WinGet/Packages/Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe/dart-sdk/bin:$PATH"

OUT_ROOT="${1:-out}"
SIZE="${2:-1400x900}"
LOG="_real_click.txt"
rm -f "$LOG"

# ① 起应用（等一次真实点击）
dart run bin/main.dart \
  --selftest-wait-click="$LOG" \
  --selftest-size="$SIZE" \
  --selftest-after=2000 \
  --selftest-wait-ms=9000 "$OUT_ROOT" >/dev/null 2>&1 &
APP_PID=$!

# ② 等它报出按钮的屏幕坐标
COORD=""
for _ in $(seq 1 60); do
  if [ -f "$LOG" ]; then
    COORD=$(grep -m1 '^READY ' "$LOG" 2>/dev/null | awk '{print $2" "$3}')
    [ -n "$COORD" ] && break
  fi
  sleep 0.3
done
if [ -z "$COORD" ]; then
  echo "[FAIL] 应用没有报出按钮坐标"
  cat "$LOG" 2>/dev/null
  kill "$APP_PID" 2>/dev/null
  exit 1
fi
echo "按钮屏幕坐标：$COORD"

# ③ 真实点击（点两下：第一下可能只用来激活窗口）
dart run bin/_probe_real_click.dart $COORD 2>&1 | tr -d '\r'
sleep 1
dart run bin/_probe_real_click.dart $COORD 2>&1 | tr -d '\r'

# ④ 等应用自己收尾（它等到 statusText 变化就立刻写日志退出）
for _ in $(seq 1 60); do
  if grep -q 'statusText:' "$LOG" 2>/dev/null; then break; fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
  sleep 0.3
done
wait "$APP_PID" 2>/dev/null

echo "=== 日志 ==="
cat "$LOG" | tr -d '\r'

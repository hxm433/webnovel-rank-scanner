#!/usr/bin/env bash
# 沿一条水平线扫 WM_NCHITTEST，找出"从 HTCLIENT 变成 HTRIGHT"的分界 x。
# 分界点 = 应用算出来的 `窗口宽 - grip`，一比就知道它的 cw 是不是对的。
set -u
cd "$(dirname "$0")/.."
export PATH="/c/Users/hxm/AppData/Local/Microsoft/WinGet/Packages/Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe/dart-sdk/bin:$PATH"

OUT_ROOT="${1:-out}"
SIZE="${2:-1400x900}"
LOG="_hittest_app.txt"
rm -f "$LOG" _ht_debug.txt

dart run bin/main.dart \
  --selftest-wait-click="$LOG" \
  --selftest-size="$SIZE" \
  --selftest-after=2000 \
  --selftest-wait-ms=25000 --debug-hittest=_ht_debug.txt "$OUT_ROOT" >/dev/null 2>&1 &
APP_PID=$!

HWND=""
for _ in $(seq 1 60); do
  if [ -f "$LOG" ]; then
    HWND=$(grep -m1 '^hwnd=' "$LOG" 2>/dev/null | sed 's/.*=0x//' | awk '{print $1}')
    [ -n "$HWND" ] && grep -q '窗口屏幕矩形=' "$LOG" && break
  fi
  sleep 0.3
done
HWND_DEC=$((16#$HWND))
WIN=$(grep -m1 '窗口屏幕矩形=' "$LOG" | sed 's/.*=(\([0-9-]*\),\([0-9-]*\))\.\.(\([0-9-]*\),\([0-9-]*\)).*/\1 \2 \3 \4/')
set -- $WIN
L=$1; T=$2; R=$3; B=$4
CY=$(( (T + B) / 2 ))
echo "窗口 ($L,$T)..($R,$B)  宽=$(( R - L ))  扫描线 y=$CY"
# ★ 一次进程内扫完（每次 `dart run` 要 1 秒，逐点起进程会拖到应用超时退出）
dart run bin/_probe_hittest.dart --scan "$HWND_DEC" $L $R "$CY" 10 2>&1 | tr -d '\r'
echo "--- 沿竖直中线扫（找上下分界）---"
CX=$(( (L + R) / 2 ))
dart run bin/_probe_hittest.dart --scan-y "$HWND_DEC" $T $B "$CX" 10 2>&1 | tr -d '\r'

kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null

#!/usr/bin/env bash
# 命中测试自检：起应用 → 让它报出「打开」按钮的屏幕坐标 → 主动发 WM_NCHITTEST 问它
# "这个坐标算不算客户区"。
#
# ★ 为什么必须这样验：真实点击先过 WM_NCHITTEST，返回 HTCAPTION 就变成拖动窗口，
#   WM_LBUTTONDOWN 根本不会发到应用。而 PostMessage 直接投递、跳过这一步 ——
#   所以"PostMessage 能点开"证明不了"真实点击能点开"。
#
# 本机沙箱**不能合成真实鼠标输入**（SetCursorPos 返回成功但光标不动），
# 所以用 WM_NCHITTEST 代替：它才是决定真实点击去向的那一步。
set -u
cd "$(dirname "$0")/.."
export PATH="/c/Users/hxm/AppData/Local/Microsoft/WinGet/Packages/Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe/dart-sdk/bin:$PATH"

OUT_ROOT="${1:-out}"
SIZE="${2:-1400x900}"
LOG="_hittest_app.txt"
rm -f "$LOG"

dart run bin/main.dart \
  --selftest-wait-click="$LOG" \
  --selftest-size="$SIZE" \
  --selftest-after=2000 \
  --selftest-wait-ms=12000 "$OUT_ROOT" >/dev/null 2>&1 &
APP_PID=$!

HWND=""
COORD=""
for _ in $(seq 1 60); do
  if [ -f "$LOG" ]; then
    HWND=$(grep -m1 '^hwnd=' "$LOG" 2>/dev/null | sed 's/.*=0x//' | awk '{print $1}')
    COORD=$(grep -m1 '^READY ' "$LOG" 2>/dev/null | awk '{print $2" "$3}')
    [ -n "$HWND" ] && [ -n "$COORD" ] && break
  fi
  sleep 0.3
done
if [ -z "$HWND" ] || [ -z "$COORD" ]; then
  echo "[FAIL] 应用没报出 hwnd/坐标"
  cat "$LOG" 2>/dev/null
  kill "$APP_PID" 2>/dev/null
  exit 1
fi
HWND_DEC=$((16#$HWND))
echo "hwnd=$HWND_DEC  按钮屏幕坐标=$COORD"

echo "--- 按钮位置 ---"
dart run bin/_probe_hittest.dart "$HWND_DEC" $COORD 2>&1 | tr -d '\r'

# 再问几个参照点：标题栏（应该是 HTCAPTION）、客户区中央（应该是 HTCLIENT）
WIN=$(grep -m1 '窗口屏幕矩形=' "$LOG" 2>/dev/null | sed 's/.*=(\([0-9-]*\),\([0-9-]*\))\.\.(\([0-9-]*\),\([0-9-]*\)).*/\1 \2 \3 \4/')
if [ -n "$WIN" ]; then
  set -- $WIN
  CX=$(( ($1 + $3) / 2 ))
  echo "--- 客户区中央 ($CX,$(( $2 + 200 ))) ---"
  dart run bin/_probe_hittest.dart "$HWND_DEC" "$CX" "$(( $2 + 200 ))" 2>&1 | tr -d '\r'
  echo "--- 顶栏 ($CX,$(( $2 + 20 ))) ---"
  dart run bin/_probe_hittest.dart "$HWND_DEC" "$CX" "$(( $2 + 20 ))" 2>&1 | tr -d '\r'
fi

kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null
echo "=== 应用日志 ==="
cat "$LOG" | tr -d '\r'

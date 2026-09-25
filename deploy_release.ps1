# ============================================================
#  部署脚本：把刚打好的 exe 同步到「发布版」目录。
#
#  ★★ 为什么必须有这一步（第 19 轮的血泪教训）：
#    用户报"链接打不开 / 导出位置改不了 / 导出图列顺序不对"，
#    排查半天发现**代码早就修好了** —— 问题是他双击的是
#    `build\发布版\网文扫榜工具.exe`，那是 Sep25 的旧构建，
#    比修复早了两天。用户不会自己去 build\ 里找新 exe，
#    他只会点那个「发布版」—— 所以"打完包"必须跟着"部署到发布版"。
#
#  用法:  powershell -File deploy_release.ps1
# ============================================================
param(
  [string]$Proj = ""
)
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Proj)) { $Proj = $PSScriptRoot }
$Proj = (Resolve-Path $Proj).Path

$src = Join-Path $Proj "build\网文扫榜工具.exe"
if (-not (Test-Path $src)) {
  Write-Output "[X] 找不到成品 $src —— 先跑 build_exe.ps1"
  exit 1
}

$relDir = Join-Path $Proj "build\发布版"
if (-not (Test-Path $relDir)) { New-Item -ItemType Directory -Path $relDir -Force | Out-Null }
$dst = Join-Path $relDir "网文扫榜工具.exe"

# ── 先备份旧 exe（可回退）──
if (Test-Path $dst) {
  $bak = Join-Path $relDir ("网文扫榜工具.exe.bak_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
  Copy-Item -Force $dst $bak
  Write-Output "旧版已备份: $bak"
}

Copy-Item -Force $src $dst
$sz = (Get-Item $dst).Length
$mb = [math]::Round($sz / 1MB, 1)
Write-Output ""
Write-Output "  [OK] 已部署到发布版"
Write-Output "       $dst"
Write-Output "       大小: $mb MB"
Write-Output ""
Write-Output "  用户直接双击上面的 exe，或跑同目录的「启动.cmd」即可。"
exit 0

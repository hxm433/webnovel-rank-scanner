# ============================================================
#  打包单 exe —— 手工 AOT 编译 + PE 包装（PowerShell 版）
#
#  ★ 与 build_exe.cmd 等价；之所以另有一份 PS 版，是因为本机沙箱里
#    PowerShell 工具禁止调用 cmd.exe。两份脚本的**每一步都对齐**，
#    改其中一份时务必同步另一份。
#
#  ★★ 核心坑（第 18 轮定位）：
#    gen_snapshot.exe 读不了含中文的路径。项目目录叫「扫榜demo」，
#    于是它读 program.dill 报 "Unable to read file"，然后静默产出 0 字节
#    aot —— 若 wrap 那边残留旧 snapshot.aot，就会"假成功"。
#    对策：整个 AOT 链路放进纯 ASCII 临时目录，最后才把成品拷回项目。
#
#  用法:  powershell -File build_exe.ps1  [-Proj <项目目录>]
# ============================================================
param(
  [string]$Proj = ""
)

$ErrorActionPreference = "Continue"
if ([string]::IsNullOrWhiteSpace($Proj)) {
  $Proj = $PSScriptRoot
}
$Proj = (Resolve-Path $Proj).Path

function Fail($msg) {
  Write-Output ""
  Write-Output "[X] $msg"
  if ($script:TMPD) { Write-Output "临时目录: $($script:TMPD)" }
  exit 1
}

# ── 找 Dart SDK ──
$cands = @(
  (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe\dart-sdk\bin"),
  "C:\tools\dart-sdk\bin",
  (Join-Path $env:LOCALAPPDATA "dart-sdk\bin")
)
$BIN = $null
foreach ($c in $cands) {
  if (Test-Path (Join-Path $c "dartaotruntime.exe")) { $BIN = $c; break }
}
if (-not $BIN) {
  $w = Get-Command dart -ErrorAction SilentlyContinue
  if ($w) { $BIN = Split-Path $w.Source -Parent }
}
if (-not $BIN) { Fail "找不到 Dart SDK。请把 dart-sdk\bin 加到 PATH，或改本脚本里的路径列表。" }
if (-not (Test-Path (Join-Path $BIN "..\lib\_internal\vm_platform_product.dill"))) {
  Fail "$BIN 看起来不是完整的 Dart SDK（缺 vm_platform_product.dill）。"
}
Write-Output "Dart SDK: $BIN"

# ── 入口与产物 ──
$ENTRY = Join-Path $Proj "bin\main.dart"
if (-not (Test-Path $ENTRY)) { Fail "找不到入口 $ENTRY" }
$OUTDIR = Join-Path $Proj "build"
if (-not (Test-Path $OUTDIR)) { New-Item -ItemType Directory -Path $OUTDIR -Force | Out-Null }
$OUT = Join-Path $OUTDIR "网文扫榜工具.exe"

$pkgcfg = Join-Path $Proj ".dart_tool\package_config.json"
if (-not (Test-Path $pkgcfg)) {
  Write-Output "[1/5] dart pub get（首次需要）"
  & (Join-Path $BIN "dart.exe") pub get --directory=$Proj
  if ($LASTEXITCODE -ne 0) { Fail "dart pub get 失败" }
}

# ── 纯 ASCII 工作目录 ──
# ★ 必须确认临时目录本身是 ASCII：某些中文用户名会带进中文。
$TMPD = $null
$asciiOk = { param($p) $p -match '^[\x20-\x7E]*$' }
$workRoot = $env:TEMP
if (-not (& $asciiOk $workRoot)) { $workRoot = "C:\Windows\Temp" }
if (-not (Test-Path $workRoot)) { $workRoot = $env:TEMP }
if (-not (& $asciiOk $workRoot)) { Fail "找不到纯 ASCII 的临时目录（gen_snapshot 需要）" }
$TMPD = Join-Path $workRoot ("rankscan_aot_" + (Get-Random) + (Get-Random))
if (Test-Path $TMPD) { Remove-Item -Recurse -Force $TMPD }
New-Item -ItemType Directory -Path $TMPD -Force | Out-Null
Write-Output "临时工作目录: $TMPD"

$kernelSnap = Join-Path $BIN "snapshots\gen_kernel_aot.dart.snapshot"
$vmPlat = Join-Path $BIN "..\lib\_internal\vm_platform_product.dill"
$dill = Join-Path $TMPD "program.dill"

Write-Output "[2/5] gen_kernel_aot"
$a1 = @(
  $kernelSnap,
  "--platform=$vmPlat",
  "--packages=$pkgcfg",
  "-Ddart.vm.product=true",
  "--target-os=windows",
  "--aot",
  "--no-embed-sources",
  "--output=$dill",
  "--invocation-modes=compile",
  "--verbosity=error",
  $ENTRY
)
& (Join-Path $BIN "dartaotruntime.exe") @a1
if ($LASTEXITCODE -ne 0) { Fail "gen_kernel_aot 失败 (exit=$LASTEXITCODE)" }
if (-not (Test-Path $dill)) { Fail "gen_kernel 没有产出 program.dill" }
$dillSz = (Get-Item $dill).Length
if ($dillSz -eq 0) { Fail "program.dill 是 0 字节" }
Write-Output "    program.dill = $dillSz 字节"

Write-Output "[3/5] gen_snapshot"
# ★ 先删旧 aot —— 否则失败时 wrap 拿旧货当真，产出"假成功"。
$aot = Join-Path $TMPD "snapshot.aot"
if (Test-Path $aot) { Remove-Item -Force $aot }
$a2 = @(
  "--snapshot-kind=app-aot-elf",
  "--elf=$aot",
  $dill
)
& (Join-Path $BIN "utils\gen_snapshot.exe") @a2
if ($LASTEXITCODE -ne 0) { Fail "gen_snapshot 失败 (exit=$LASTEXITCODE)" }
if (-not (Test-Path $aot)) { Fail "gen_snapshot 没有产出 snapshot.aot（很可能是路径含非 ASCII）" }
$aotSz = (Get-Item $aot).Length
if ($aotSz -eq 0) { Fail "snapshot.aot 是 0 字节（路径含非 ASCII 的典型症状）" }
Write-Output "    snapshot.aot = $aotSz 字节"

Write-Output "[4/5] wrap PE（把快照作为 snapshot 节追加进 dartaotruntime）"
$packed = Join-Path $TMPD "packed.exe"
$a3 = @(
  (Join-Path $Proj "tool\wrap_pe.dart"),
  (Join-Path $BIN "dartaotruntime.exe"),
  $aot,
  $packed
)
& (Join-Path $BIN "dart.exe") @a3
if ($LASTEXITCODE -ne 0) { Fail "wrap_pe.dart 失败 (exit=$LASTEXITCODE)" }
if (-not (Test-Path $packed)) { Fail "wrap 没有产出 exe" }
Copy-Item -Force $packed $OUT
if (-not (Test-Path $OUT)) { Fail "拷贝成品到 $OUT 失败" }

Remove-Item -Recurse -Force $TMPD

# ── [5/5] 嵌图标 ──
$ico = Join-Path $Proj "assets\icon\app.ico"
if (Test-Path $ico) {
  Write-Output "[5/5] 嵌入图标"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Proj "tool\embed_icon.ps1") $OUT $ico
  if ($LASTEXITCODE -ne 0) { Write-Output "[warn] 图标嵌入失败（exe 照常能用，只是资源管理器里不显示图标）" }
}

$fsz = (Get-Item $OUT).Length
$mb = [math]::Round($fsz / 1MB, 1)

# ── 自动部署到「发布版」──
# ★★ 与 build_exe.cmd 的 [6/6] 完全同一步（两份脚本必须保持一致）：
#    用户只会点「发布版」里那个 exe，只打包不部署 = 用户看到的还是旧版。
#    部署逻辑放在 tool/deploy_release.dart 里 —— 中文路径不受控制台代码页影响，
#    并且会逐字节校验、处理"目标被占用"。
Write-Output "[6/6] 部署到发布版"
& (Join-Path $BIN "dart.exe") (Join-Path $Proj "tool\deploy_release.dart") $OUT
if ($LASTEXITCODE -ne 0) { Write-Output "[warn] 部署到发布版失败（exe 已打好，在 $OUT；关掉正在运行的旧版再重跑）" }

Write-Output ""
Write-Output "  [OK] 打包完成"
Write-Output "       $OUT"
Write-Output "       大小: $mb MB"
Write-Output ""
Write-Output "  数据目录在 exe 同级的 out\ ，重打包不会覆盖它。"
exit 0

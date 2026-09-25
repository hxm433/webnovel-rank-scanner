@echo off
rem ============================================================
rem  打包单 exe —— 手工 AOT 编译 + PE 包装
rem
rem  为什么不直接用 `dart compile exe`：
rem    本机沙箱里 dart.exe spawn 子进程时管道句柄被耗尽，
rem    一律报 "CreateFile failed 231 (所有的管道范例都在使用中)"
rem    + process_win.cc:744，且与路径是否为中文无关。
rem    所以走等价的三步手工链路，产物完全一致。
rem
rem  用法:  build_exe.cmd            直接双击 = 打包本目录
rem         build_exe.cmd <项目目录>
rem ============================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set PROJ=%~1
if "%PROJ%"=="" set PROJ=%~dp0.

rem ── 找 Dart SDK ──
set BIN=
for %%D in (
  "%LOCALAPPDATA%\Microsoft\WinGet\Packages\Google.DartSDK_Microsoft.Winget.Source_8wekyb3d8bbwe\dart-sdk\bin"
  "C:\tools\dart-sdk\bin"
  "%LOCALAPPDATA%\dart-sdk\bin"
) do (
  if not defined BIN if exist "%%~D\dartaotruntime.exe" set BIN=%%~D
)
if not defined BIN (
  where dart >nul 2>nul
  if not errorlevel 1 for /f "delims=" %%P in ('where dart') do set DARTEXE=%%P
)
if not defined BIN if defined DARTEXE (
  for %%P in ("%DARTEXE%") do set BIN=%%~dpP
)
if not defined BIN (
  echo [X] 找不到 Dart SDK。请把 dart-sdk\bin 加到 PATH，或改本脚本里的路径列表。
  exit /b 2
)
if not exist "%BIN%\..\lib\_internal\vm_platform_product.dill" (
  echo [X] %BIN% 看起来不是完整的 Dart SDK^(缺 vm_platform_product.dill^)。
  exit /b 2
)

rem ── 入口与产物 ──
set ENTRY=%PROJ%\bin\main.dart
if not exist "%ENTRY%" (
  echo [X] 找不到入口 %ENTRY%
  exit /b 2
)
set OUT=%PROJ%\build\网文扫榜工具.exe
if not exist "%PROJ%\build" mkdir "%PROJ%\build"

if not exist "%PROJ%\.dart_tool\package_config.json" (
  echo [1/5] dart pub get ^(首次需要^)
  "%BIN%\dart.exe" pub get --directory="%PROJ%"
  if errorlevel 1 goto fail
)

set TMPD=%TEMP%\rankscan_aot_%RANDOM%%RANDOM%
mkdir "%TMPD%" 2>nul

echo [2/5] gen_kernel_aot
"%BIN%\dartaotruntime.exe" "%BIN%\snapshots\gen_kernel_aot.dart.snapshot" "--platform=%BIN%\..\lib\_internal\vm_platform_product.dill" "--packages=%PROJ%\.dart_tool\package_config.json" -Ddart.vm.product=true --target-os=windows --aot --no-embed-sources "--output=%TMPD%\program.dill" --invocation-modes=compile --verbosity=error "%ENTRY%"
if errorlevel 1 goto fail

echo [3/5] gen_snapshot
rem ★ 注意：这里**不能**加 --aot，会报 "Unrecognized flags: aot"
"%BIN%\utils\gen_snapshot.exe" "--snapshot-kind=app-aot-elf" "--elf=%TMPD%\snapshot.aot" "%TMPD%\program.dill"
if errorlevel 1 goto fail

echo [4/5] wrap PE ^(把快照作为 snapshot 节追加进 dartaotruntime^)
"%BIN%\dart.exe" "%PROJ%\tool\wrap_pe.dart" "%BIN%\dartaotruntime.exe" "%TMPD%\snapshot.aot" "%OUT%"
if errorlevel 1 goto fail

rd /s /q "%TMPD%"
rem ── [5/5] 嵌图标：ico 由 tool\make_icon.py 生成，源文件在 assets\icon\
if exist "%PROJ%\assets\icon\app.ico" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJ%\tool\embed_icon.ps1" "%OUT%" "%PROJ%\assets\icon\app.ico"
  if errorlevel 1 echo [warn] 图标嵌入失败（exe 照常能用，只是资源管理器里不显示图标）
)
for %%F in ("%OUT%") do set FSZ=%%~zF
set /a FSZMB=%FSZ%/1048576
echo.
echo   [OK] 打包完成
echo        %OUT%
echo        大小: %FSZMB% MB
echo.
echo   数据目录在 exe 同级的 out\ ，重打包不会覆盖它。
exit /b 0

:fail
echo.
echo [X] 打包失败，临时目录: %TMPD%
exit /b 1

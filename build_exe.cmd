@echo off
rem ============================================================
rem  打包单 exe —— 手工 AOT 编译 + PE 包装
rem
rem  为什么不直接用 `dart compile exe`：
rem    本机沙箱里 dart.exe spawn 子进程时管道句柄被耗尽，
rem    一律报 "CreateFile failed 231 (所有的管道范例都在使用中)"
rem    + process_win.cc:744。所以走等价的三步手工链路。
rem
rem  ★★ 关键坑（第 18 轮定位）：
rem    `gen_snapshot.exe` **读不了含中文的路径**。项目目录叫 `扫榜demo`，
rem    于是它读 program.dill 时报 "Unable to read file: ...\扫榜demo\...",
rem    然后静默产出 0 字节的 aot —— 而 wrap 那边如果残留着上次的 snapshot.aot，
rem    就会"看起来成功、实际上用的是旧货"。这就是之前 exitcode=255 的真因。
rem
rem    对策：**把整个 AOT 链路放进纯 ASCII 的临时目录**跑（%TEMP% 下面），
rem    只在最后一步把成品 exe 拷回项目里。输入源码路径含中文没关系 ——
rem    gen_kernel 能吃中文输入，是 gen_snapshot 读不了中文**文件路径**。
rem    所以我们把 program.dill 生成到 ASCII 临时目录，后面就全是 ASCII 路径了。
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

rem ── 工作目录（先试 %TEMP%，建不出来才退到 %SystemRoot%\Temp）──
rem
rem ★★ 为什么改成"先试着建"而不是"先判断路径是否纯 ASCII"：
rem    原实现是 `echo %TEMP%| findstr /r /c:"^[ -~]*$"` 判非 ASCII，
rem    但那个字符类在 cmd 下**不可靠** —— 空格会被 findstr 当成参数分隔，
rem    实测 errorlevel 恒为 1（哪怕 %TEMP% 是纯 ASCII 的
rem    C:\Users\xxx\AppData\Local\Temp）。于是脚本**每次都**回退到
rem    C:\Windows\Temp，而那个目录要管理员权限 → 普通用户跑就是
rem    "[X] 建不出临时目录"，构建直接死在第一步。
rem    "预测路径能不能用"本来就不可靠，**建一次看结果**才是对的。
rem
rem ★ 用 `call :label` 而不是 if(...) 块：块里的 %TMPD% 在**解析时**就展开了，
rem   块内 set 的新值在同一块里读不到（经典 batch 坑）。
set TMPD=
set WORKROOT=%TEMP%
call :mkwork "%WORKROOT%"
if not defined TMPD call :mkwork "%SystemRoot%\Temp"
if not defined TMPD (
  echo [X] 建不出临时目录（%TEMP% 与 %SystemRoot%\Temp 都不可写）
  exit /b 2
)
echo 临时工作目录: %TMPD%
goto :workready

:mkwork
set "_TRY=%~1\rankscan_aot_%RANDOM%%RANDOM%"
if exist "%_TRY%" rd /s /q "%_TRY%"
mkdir "%_TRY%" 2>nul
if exist "%_TRY%" set TMPD=%_TRY%
exit /b 0

:workready

echo [2/5] gen_kernel_aot
"%BIN%\dartaotruntime.exe" "%BIN%\snapshots\gen_kernel_aot.dart.snapshot" "--platform=%BIN%\..\lib\_internal\vm_platform_product.dill" "--packages=%PROJ%\.dart_tool\package_config.json" -Ddart.vm.product=true --target-os=windows --aot --no-embed-sources "--output=%TMPD%\program.dill" --invocation-modes=compile --verbosity=error "%ENTRY%"
if errorlevel 1 goto fail
if not exist "%TMPD%\program.dill" (
  echo [X] gen_kernel 没有产出 program.dill
  goto fail
)
for %%F in ("%TMPD%\program.dill") do set DILLSZ=%%~zF
if "%DILLSZ%"=="0" (
  echo [X] program.dill 是 0 字节
  goto fail
)
echo     program.dill = %DILLSZ% 字节

echo [3/5] gen_snapshot
rem ★ 注意：这里**不能**加 --aot，会报 "Unrecognized flags: aot"
rem ★ 先删掉可能的旧 aot —— 否则失败了 wrap 会拿旧货当真，产出"假成功"。
if exist "%TMPD%\snapshot.aot" del /q "%TMPD%\snapshot.aot"
"%BIN%\utils\gen_snapshot.exe" "--snapshot-kind=app-aot-elf" "--elf=%TMPD%\snapshot.aot" "%TMPD%\program.dill"
if errorlevel 1 goto fail
if not exist "%TMPD%\snapshot.aot" (
  echo [X] gen_snapshot 没有产出 snapshot.aot ^(很可能是路径含非 ASCII^)
  goto fail
)
for %%F in ("%TMPD%\snapshot.aot") do set AOTSZ=%%~zF
if "%AOTSZ%"=="0" (
  echo [X] snapshot.aot 是 0 字节 ^(路径含非 ASCII 的典型症状^)
  goto fail
)
echo     snapshot.aot = %AOTSZ% 字节

echo [4/5] wrap PE ^(把快照作为 snapshot 节追加进 dartaotruntime^)
rem ★ 也把成品先出到 ASCII 目录，最后再拷回 —— 万一 wrap 也挑路径呢。
"%BIN%\dart.exe" "%PROJ%\tool\wrap_pe.dart" "%BIN%\dartaotruntime.exe" "%TMPD%\snapshot.aot" "%TMPD%\packed.exe"
if errorlevel 1 goto fail
if not exist "%TMPD%\packed.exe" (
  echo [X] wrap 没有产出 exe
  goto fail
)
copy /y "%TMPD%\packed.exe" "%OUT%" >nul
if errorlevel 1 (
  echo [X] 拷贝成品到 %OUT% 失败
  goto fail
)

rd /s /q "%TMPD%"
rem ── [5/5] 嵌图标：ico 由 tool\make_icon.py 生成，源文件在 assets\icon\
if exist "%PROJ%\assets\icon\app.ico" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJ%\tool\embed_icon.ps1" "%OUT%" "%PROJ%\assets\icon\app.ico"
  if errorlevel 1 echo [warn] 图标嵌入失败（exe 照常能用，只是资源管理器里不显示图标）
)
for %%F in ("%OUT%") do set FSZ=%%~zF
set /a FSZMB=%FSZ%/1048576

rem ── 自动部署到「发布版」──
rem
rem ★★ 为什么"打包"必须顺手"部署"（第 19 / 22 轮各栽过一次）：
rem    用户不会去 build\ 里找新 exe，他只点 `build\发布版\网文扫榜工具.exe`。
rem    只打包不部署 = 用户看到的还是旧版，然后报"改了怎么还是老样子"。
rem
rem ★★ 为什么这一步交给 Dart 而不是在本脚本里 copy：
rem    路径里有中文（发布版 / 网文扫榜工具.exe），而批处理脚本是按
rem    **控制台代码页**解码的 —— 代码页不是 936 时（例如从 Git Bash 调
rem    cmd 的 /c 参数），这些中文字面量会被解成 U+FFFD，
rem    于是"复制成功"、文件却落进了一个乱码目录（实测踩到）。
rem    Dart 源码是 UTF-8，字符串不受代码页影响；打包流程本来就要 Dart SDK。
rem    那个工具还会**逐字节校验**，并处理"目标 exe 被占用"（改名替换），
rem    失败时明确报错而不是假装成功。
echo [6/6] 部署到发布版
"%BIN%\dart.exe" "%PROJ%\tool\deploy_release.dart" "%OUT%"
if errorlevel 1 echo [warn] 部署到发布版失败（exe 已打好，在 %OUT%；关掉正在运行的旧版再重跑本脚本）

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

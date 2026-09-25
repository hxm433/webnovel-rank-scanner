@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo  [1] 抓一轮榜单数据（约 35 秒，16 次请求，每次间隔 1.5 秒）
echo  [2] 生成并打开网页（用现有快照，不联网）
echo  [3] 两个都要：先抓，再生成网页        （直接回车 = 3）
echo.
set /p c=选一个（1/2/3）: 
if "%c%"=="" set c=3
if "%c%"=="1" goto scan
if "%c%"=="2" goto page

:scan
echo.
echo == 正在抓取（起点 / 番茄 / 七猫 / 晋江）==
dart run bin/scan.dart sweep --selftest-trend --limit 20 --ms 1500
if errorlevel 1 echo. & echo 注意：有榜单没抓到，详情看 out\reports 里最新的 md
if "%c%"=="1" goto end

:page
echo.
echo == 生成网页 ==
dart run bin/page.dart --open
echo 生成后双击  榜单页.html  也能看（不需要联网、不需要开服务）
:end
echo.
pause

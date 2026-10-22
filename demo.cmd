@echo off
setlocal
set "ROOT=%~dp0"
set "NODE="
for /f "delims=" %%i in ('where node 2^>nul') do if not defined NODE set "NODE=%%i"
if not defined NODE if exist "C:\Tool\Node.js\node.exe" set "NODE=C:\Tool\Node.js\node.exe"
if not defined NODE set "NODE=node"

echo.
echo   演示数据（假数据，不动真实账单）
echo.
echo   这一版一次跑出五种效果：
echo     命中 / 会心一击 / 大出血           （红 / 粉 / 白）
echo     未命中                             （灰，漏账）
echo     免费回合                           （蓝，这轮没花钱）
echo.
echo   只看某一种：
echo     node tools\demo.mjs --miss 6            只看未命中（灰）
echo     node tools\demo.mjs --free 6            只看免费回合（蓝）
echo     node tools\demo.mjs --burst 5 --force 大出血
echo     node tools\demo.mjs --burst 5 --force 会心一击
echo.

"%NODE%" "%ROOT%tools\demo.mjs" --burst 18 --gap 150
ping -n 6 127.0.0.1 >nul
endlocal

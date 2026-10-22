@echo off
setlocal
set "ROOT=%~dp0.."
set "NODE="
for /f "delims=" %%i in ('where node 2^>nul') do if not defined NODE set "NODE=%%i"
if not defined NODE if exist "C:\Tool\Node.js\node.exe" set "NODE=C:\Tool\Node.js\node.exe"
if not defined NODE set "NODE=node"
"%NODE%" "%ROOT%tools\reset-balance.mjs"
ping -n 4 127.0.0.1 >nul
endlocal

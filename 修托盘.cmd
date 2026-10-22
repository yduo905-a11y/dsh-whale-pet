@echo off
chcp 65001 >nul
echo 正在把桌宠的托盘图标钉回可见托盘区…
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\fix-tray.ps1" %*
echo.
pause

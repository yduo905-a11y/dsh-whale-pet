@echo off
setlocal
set "ROOT=%~dp0"
set "PSH="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PSH for /f "delims=" %%i in ('where pwsh 2^>nul') do if not defined PSH set "PSH=%%i"
if not defined PSH set "PSH=powershell"
echo ????????????????????????????? 10 ???????????????...
"%PSH%" -NoProfile -STA -ExecutionPolicy Bypass -File "%ROOT%host\dsh-overlay.ps1" -RenderPreview
echo.
echo ???????????%ROOT%preview
ping -n 5 127.0.0.1 >nul
endlocal

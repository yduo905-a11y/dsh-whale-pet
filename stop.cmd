@echo off
setlocal
set "ROOT=%~dp0"
echo ?? dsh-overlay ...

set "PSH="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PSH for /f "delims=" %%i in ('where pwsh 2^>nul') do if not defined PSH set "PSH=%%i"
if not defined PSH set "PSH=powershell"

rem 1) ?? PID ????????????????????????? PID ?????????
"%PSH%" -NoProfile -ExecutionPolicy Bypass -Command "$root='%ROOT%'; foreach ($name in @('host','core')) { $pf = Join-Path $root ('logs\' + $name + '.pid'); if (-not (Test-Path -LiteralPath $pf)) { Write-Host ($name + ': ??? PID ?????????'); continue }; $v = 0; [void][int]::TryParse(((Get-Content -LiteralPath $pf -Raw) -replace '\s',''), [ref]$v); $p = $null; if ($v -gt 0) { $p = Get-Process -Id $v -ErrorAction SilentlyContinue }; if ($p -and ($p.ProcessName -match '^(node|powershell|pwsh)$')) { Stop-Process -Id $v -Force -ErrorAction SilentlyContinue; Write-Host ($name + ': ???? pid ' + $v) } else { Write-Host ($name + ': ??????????????') }; Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }"

rem 2) ????????????????????????
"%PSH%" -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*core\server.mjs*' -or $_.CommandLine -like '*core/server.mjs*' -or $_.CommandLine -like '*host\dsh-overlay.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>nul

echo ????????????????????????
ping -n 4 127.0.0.1 >nul
endlocal

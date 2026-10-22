@echo off
rem ---------------------------------------------------------------
rem  dsh-overlay host boot: start core + host WITHOUT taking a pipe
rem  (PS 5.1 dies with a CLR "unhandled error" when its stdout is a
rem   redirected pipe; file redirection is safe. Same as pet.cmd.)
rem  Usage: host-boot.cmd [pet]
rem ---------------------------------------------------------------
setlocal
set "ROOT=%~dp0"
if not exist "%ROOT%logs" mkdir "%ROOT%logs"

rem --- TEMP workaround -------------------------------------------
rem  When the launcher is started from a restricted/sandboxed
rem  process tree the child PowerShell may not be allowed to write
rem  to %LOCALAPPDATA%\Temp. PowerShell's Add-Type then throws
rem  UnauthorizedAccessException, the host dies before it can log
rem  anything, and the launcher shows "浮层反复退出".
rem  Point TEMP/TMP at a folder inside the install dir instead.
set "DSHTMP=%ROOT%logs\tmp"
if not exist "%DSHTMP%" mkdir "%DSHTMP%" >nul 2>nul
set "TEMP=%DSHTMP%"
set "TMP=%DSHTMP%"

set "NODE="
for /f "delims=" %%i in ('where node 2^>nul') do if not defined NODE set "NODE=%%i"
if not defined NODE if exist "C:\Tool\Node.js\node.exe" set "NODE=C:\Tool\Node.js\node.exe"
if not defined NODE set "NODE=node"

set "PSH="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PSH for /f "delims=" %%i in ('where pwsh 2^>nul') do if not defined PSH set "PSH=%%i"
if not defined PSH set "PSH=powershell"

rem core: only start one if nothing already listens on the bus
"%PSH%" -NoProfile -ExecutionPolicy Bypass -Command "try{$c=New-Object Net.Sockets.TcpClient;$c.Connect('127.0.0.1',17777);$c.Close();exit 0}catch{exit 1}"
if errorlevel 1 (
  start "dsh-core" /min cmd /c ""%NODE%" "%ROOT%core\server.mjs" > "%ROOT%logs\core.log" 2>&1"
)

set "MODE="
if /i "%~1"=="pet" set "MODE=-PetMode"

rem host: file redirection only, never a pipe; TEMP pinned inside install dir
start "dsh-host" /min cmd /c ""%PSH%" -NoProfile -STA -ExecutionPolicy Bypass -File "%ROOT%host\dsh-overlay.ps1" %MODE% > "%ROOT%logs\host_console.log" 2>&1"

endlocal

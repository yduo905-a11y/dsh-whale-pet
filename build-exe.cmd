@echo off
setlocal
set "ROOT=%~dp0"

rem ?? VS ????? Roslyn ?????????????? dotnet SDK???????? MSBuild ?????
set "CSC="
for %%d in (
  "C:\Program Files\Microsoft Visual Studio\18\Community"
  "C:\Program Files\Microsoft Visual Studio\17\Community"
  "C:\Program Files\Microsoft Visual Studio\18\Professional"
  "C:\Program Files\Microsoft Visual Studio\17\Professional"
  "C:\Program Files\Microsoft Visual Studio\18\Enterprise"
  "C:\Program Files\Microsoft Visual Studio\17\Enterprise"
  "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community"
) do (
  if not defined CSC if exist "%%~d\MSBuild\Current\Bin\Roslyn\csc.exe" set "CSC=%%~d\MSBuild\Current\Bin\Roslyn\csc.exe"
)
if not defined CSC (
  for /f "delims=" %%i in ('where csc.exe 2^>nul') do if not defined CSC set "CSC=%%i"
)
if not defined CSC (
  echo [x] ???? csc.exe?????? Visual Studio???? .NET ????D?????? .NET SDK??
  pause
  exit /b 1
)

echo ??????: %CSC%
if not exist "%ROOT%assets\dafeiyu.ico" (
  echo [i] ???????????????????? ...
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%ROOT%tools\make-icon.ps1"
)

"%CSC%" /nologo /target:winexe /platform:anycpu /optimize+ ^
  /out:"%ROOT%dafeiyu.exe" ^
  /win32icon:"%ROOT%assets\dafeiyu.ico" ^
  /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll ^
  "%ROOT%src\DshOverlayLauncher.cs"

if errorlevel 1 (
  echo [x] ???????
  pause
  exit /b 1
)
echo.
echo [??] ???????: %ROOT%dafeiyu.exe
dir /b "%ROOT%dafeiyu.exe"
ping -n 3 127.0.0.1 >nul
endlocal

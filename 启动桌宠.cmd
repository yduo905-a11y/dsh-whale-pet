@echo off
chcp 65001 >nul
rem 启动桌宠：先跑本目录的 dafeiyu.exe（解压到哪就在哪跑，不需要 root.txt）。
rem 如果本目录没有，再试 C:\Tool\DSHPet\ 里的那份（作者自用的安装位置）。
setlocal
if exist "%~dp0dafeiyu.exe" (
    start "" "%~dp0dafeiyu.exe"
) else if exist "C:\Tool\DSHPet\dafeiyu.exe" (
    start "" "C:\Tool\DSHPet\dafeiyu.exe"
) else (
    echo 找不到 dafeiyu.exe，请确认它跟这个 cmd 在同一个文件夹里。
    pause
)
endlocal
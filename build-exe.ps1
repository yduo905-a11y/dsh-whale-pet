# 一条命令重编 + 签名 + 部署（真身 → C:\Tool\DSHPet，转发器 → 工作区）
# 用法：  pwsh -File <项目目录>\build-exe.ps1
$ErrorActionPreference = 'Stop'
$root  = $PSScriptRoot
$msbuild = 'C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe'
$signtool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
$pfx   = Join-Path $root 'build\sign\dafeiyu.pfx'
$pwd_  = 'dafeiyu-pet-2026'

Write-Host '== 1/4 编译（MSBuild，与 VS 里 F6 等价）=='
& $msbuild (Join-Path $root 'Dafeiyu.sln') /t:Rebuild /p:Configuration=Release /v:minimal /nologo
if ($LASTEXITCODE -ne 0) { throw '编译失败' }

$body  = Join-Path $root 'src\bin\Release\net48\dafeiyu.exe'
$relay = Join-Path $root 'src\bin\Release\net48\dafeiyu-relay.exe'

Write-Host '== 2/4 停掉正在跑的实例 =='
$running = Get-Process -Name dafeiyu -ErrorAction SilentlyContinue
if ($running) {
    if (Test-Path 'C:\Tool\DSHPet\dafeiyu.exe') { & 'C:\Tool\DSHPet\dafeiyu.exe' --stop | Out-Null }
    Start-Sleep -Seconds 4
    Get-Process -Name dafeiyu -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

Write-Host '== 3/4 部署 =='
Copy-Item $body 'C:\Tool\DSHPet\dafeiyu.exe' -Force
Copy-Item $relay (Join-Path $root 'dafeiyu.exe') -Force

Write-Host '== 4/4 签名 + 校验 =='
foreach ($f in @('C:\Tool\DSHPet\dafeiyu.exe', (Join-Path $root 'dafeiyu.exe'))) {
    & $signtool sign /f $pfx /p $pwd_ /fd SHA256 /td SHA256 /tr 'http://timestamp.digicert.com' $f | Out-Null
    $s = Get-AuthenticodeSignature $f
    Write-Host ("  {0}  {1}B  签名={2}" -f $f, (Get-Item $f).Length, $s.Status)
}

Write-Host '完成。双击 大肥鱼桌宠.lnk 或 C:\Tool\DSHPet\dafeiyu.exe 启动。'

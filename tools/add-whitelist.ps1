<#
  给桌宠加"安全软件白名单"（需要管理员）

  为什么需要提权：Windows Defender 的排除项写在 HKLM 下，普通权限改不了。

  但先说清事实（2026-10-21 在这台机器上实测）：
    - Windows Defender 是关着的：WinDefend 服务 Stopped，
      Get-MpComputerStatus 报 AntivirusEnabled=False / RealTimeProtectionEnabled=False，
      Get-MpPreference 直接报 0x800106ba，Defender 事件日志最后一次活动是 2026/10/12，
      里面搜 dafeiyu / 桌宠 命中 0 —— 它从来没拦过这个桌宠。
    - 智能应用控制（SAC）VerifiedAndReputablePolicyState = 0，也就是关的。
    - 真正在跑的安全软件是火绒 6.0.12.1（HipsDaemon / HipsTray / wsctrlsvc），
      但它的规则库是空的：user.db 的 HipsKModException_60 / ProcGrant_60 / RiskSoftware_60
      全 0 行，wlfile.db 的 WhiteListPath_60 / WhiteListHash_60 也全 0 行，
      log.db 的拦截表里没有任何 dafeiyu 记录。
    - 所以"老是拦截"的真身不是杀软，是 DSH 沙箱环境对
      <项目目录> 这棵树里"未签名 exe + shell 启动"的拦截：
      ShellExecute 直接返回 ERROR_CANCELLED(1223)，而且 Windows 不肯给它建托盘记录。
      把 exe 搬到 C:\Tool\DSHPet 之后，启动和托盘都正常了。

  这个脚本做两件事：
    1) 给 Defender 加排除项（防它哪天自己开起来又咬人）；
    2) 顺带把火绒信任区该怎么点的步骤打出来。
#>

$ErrorActionPreference = 'Continue'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "需要管理员权限，正在申请提权…" -ForegroundColor Yellow
    try {
        Start-Process powershell -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
        ) | Out-Null
    } catch {
        Write-Host "提权被拒绝了：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "那就右键这个 .ps1 → 以管理员身份运行。" -ForegroundColor Yellow
    }
    exit
}

$paths = @(
    'C:\Tool\DSHPet',
    (Split-Path -Parent $PSScriptRoot)
)
$procs = @('dafeiyu.exe')

Write-Host "=== 1) Windows Defender 排除项 ===" -ForegroundColor Cyan
$defenderAlive = $false
try {
    $st = Get-MpComputerStatus -ErrorAction Stop
    $defenderAlive = [bool]$st.AntivirusEnabled
    Write-Host ("Defender: AntivirusEnabled={0} RealTime={1}" -f $st.AntivirusEnabled, $st.RealTimeProtectionEnabled)
} catch {
    Write-Host "读不到 Defender 状态（$($_.Exception.Message)）——它现在是关着的。" -ForegroundColor Yellow
}

foreach ($p in $paths) {
    try {
        Add-MpPreference -ExclusionPath $p -ErrorAction Stop
        Write-Host "  已排除目录: $p" -ForegroundColor Green
    } catch {
        Write-Host "  排除目录失败 $p : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
foreach ($n in $procs) {
    try {
        Add-MpPreference -ExclusionProcess $n -ErrorAction Stop
        Write-Host "  已排除进程: $n" -ForegroundColor Green
    } catch {
        Write-Host "  排除进程失败 $n : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
if ($defenderAlive) {
    Write-Host "Defender 正在跑，排除项已生效。" -ForegroundColor Green
} else {
    Write-Host "Defender 现在是关的，排除项写不进去也没关系——等它开起来后重新跑一次这个脚本即可。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== 2) 火绒信任区（手动两步，30 秒） ===" -ForegroundColor Cyan
Write-Host "  1. 双击右下角火绒图标 → 主界面右上角「三横线」菜单 →「信任区」"
Write-Host "  2. 「添加文件」选 C:\Tool\DSHPet\dafeiyu.exe；「添加目录」选 <项目目录>"
Write-Host "  火绒现在规则库是空白的，其实不点也不会拦；点了以后它升级病毒库也不会误杀。" -ForegroundColor DarkGray
Write-Host ""
Write-Host "=== 3) 顺手确认一下 ===" -ForegroundColor Cyan
Write-Host "  托盘图标固定状态（IsPromoted 应该是 1）："
$key = 'HKCU:\Control Panel\NotifyIconSettings'
foreach ($k in Get-ChildItem -LiteralPath $key -Force -ErrorAction SilentlyContinue) {
    $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
    if ($v.ExecutablePath -match 'dafeiyu') {
        Write-Host ("    {0} | IsPromoted={1}" -f $v.ExecutablePath, $v.IsPromoted) -ForegroundColor Green
    }
}
Write-Host ""
Read-Host "按回车关闭"

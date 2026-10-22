<#
  修托盘 —— 把桌宠的鲸鱼图标钉回任务栏可见托盘区

  原理（2026-10-21 实测）：
    Windows 11 给每个托盘图标在
      HKCU\Control Panel\NotifyIconSettings\<一串数字>
    里存一条记录：UID / ExecutablePath / InitialTooltip / IconSnapshot + IsPromoted。
    IsPromoted=1 = 固定在可见托盘区；缺省或 0 = 缩进 ^ 溢出面板。

    三个坑：
      1) 启动器如果在消息循环之后再做一次 Visible=false→true 重注册，Windows 会把那次
         注册当成"新图标"，顺手把 IsPromoted 写回 0 —— 图标又缩回溢出。
         DshOverlayLauncher.cs 的 BuildTray 现在会先读 IsPromoted，是 1 就跳过二次注册。
      2) exe 换路径后旧记录不认；新路径如果没记录，图标只能在溢出面板，
         设置里「其他系统托盘图标」列表也看不到它 ——
         这就是"复制粘贴到别的文件夹，托盘就不见了"。
      3) 杀掉进程后马上重启（间隔不到 1~2 秒），shell 还在拆旧图标，
         新图标的 promoted 状态会被丢掉 —— 所以本脚本宁可多等一会儿并复查。

  用法：
    powershell -ExecutionPolicy Bypass -File fix-tray.ps1
    powershell -ExecutionPolicy Bypass -File fix-tray.ps1 -Exe "C:\别的路径\dafeiyu.exe"
#>
param(
    [string]$Exe = 'C:\Tool\DSHPet\dafeiyu.exe',
    [switch]$NoRestart
)

$ErrorActionPreference = 'Continue'
$RegRoot = 'HKCU:\Control Panel\NotifyIconSettings'

function Find-Entry([string]$exe) {
    foreach ($k in Get-ChildItem -LiteralPath $RegRoot -Force -ErrorAction SilentlyContinue) {
        $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($v.ExecutablePath -and ($v.ExecutablePath -ieq $exe)) { return $k }
    }
    return $null
}

function Test-TrayVisible {
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
        $auto = [System.Windows.Automation.AutomationElement]
        $tb = $auto::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            (New-Object System.Windows.Automation.PropertyCondition($auto::ClassNameProperty, 'Shell_TrayWnd')))
        if (-not $tb) { return $null }
        $btns = $tb.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition($auto::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
        $overflowX = 99999
        foreach ($b in $btns) {
            $r = $b.Current.BoundingRectangle
            if ($r.Width -le 0) { continue }
            if ($b.Current.Name -eq '显示隐藏的图标') { $overflowX = $r.X }
        }
        foreach ($b in $btns) {
            $r = $b.Current.BoundingRectangle
            if ($r.Width -le 0) { continue }
            if ($b.Current.Name -match '大肥鱼|鲸娘|dafeiyu' -and $r.X -ge $overflowX) { return $true }
        }
        return $false
    } catch { return $null }
}

$entry = Find-Entry $Exe
if (-not $entry) {
    Write-Host "找不到 $Exe 的托盘记录。" -ForegroundColor Yellow
    Write-Host "说明这个路径下的图标还没被 Windows 收编 —— 先启动一次桌宠，" -ForegroundColor Yellow
    Write-Host "在 ^ 溢出面板里看到鲸鱼头像之后，再回来跑这个脚本。" -ForegroundColor Yellow
    exit 1
}

Set-ItemProperty -LiteralPath $entry.PSPath -Name IsPromoted -Value 1 -Type DWord
Write-Host ("条目 {0}（{1}）已标记 IsPromoted=1" -f $entry.PSChildName, $Exe) -ForegroundColor Green

if ($NoRestart) { exit 0 }

# 只杀 dafeiyu.exe 会留下它的子进程（node core / node usage / powershell 浮层），
# 旧 core 还占着 127.0.0.1:17777，新 core 起来就 EADDRINUSE 直接死 → 启动器疯狂重启。
function Stop-Pet {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'server\.mjs|dsh-usage\.mjs' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'dsh-overlay[.]ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process -Name 'dafeiyu' -ErrorAction SilentlyContinue | Stop-Process -Force
}

# 杀掉 → 等 shell 收尸 → 重启 → 复查，必要时再来一遍
for ($try = 1; $try -le 3; $try++) {
    Stop-Pet
    Start-Sleep -Milliseconds (1200 + 600 * $try)
    $ok = Test-Path $Exe
    if (-not $ok) { Write-Host "找不到程序本体：$Exe" -ForegroundColor Red; exit 1 }
    # 用 CreateProcess 而不是 Start-Process：Start-Process 走 ShellExecute，
    # 未签名的 exe 会被 SmartScreen 拦一下（"Windows 已保护你的电脑"）。
    $psi = New-Object System.Diagnostics.ProcessStartInfo($Exe)
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = (Split-Path -Parent $Exe)
    [void][System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Seconds (5 + $try)
    $vis = Test-TrayVisible
    if ($vis -eq $true) {
        Write-Host ("第 {0} 次尝试：鲸鱼头像已经在可见托盘区了（时钟左边，不用点 ^）。" -f $try) -ForegroundColor Green
        exit 0
    }
    if ($vis -eq $false) {
        Write-Host ("第 {0} 次尝试：图标还没固定住，再试一次…" -f $try) -ForegroundColor Yellow
    } else {
        Write-Host ("第 {0} 次尝试：查不到任务栏信息，重启完了，你自己瞄一眼右下角。" -f $try) -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""
Write-Host "三次都没固定住。兜底办法（30 秒，100% 灵）：" -ForegroundColor Cyan
Write-Host "  设置 > 个性化 > 任务栏 > 其他系统托盘图标 > dafeiyu.exe 把开关打开" -ForegroundColor Cyan
Write-Host "  打开后别再用旧版启动器（旧版会二次注册把状态冲掉）。" -ForegroundColor Cyan

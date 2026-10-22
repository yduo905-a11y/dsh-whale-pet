#requires -Version 5.1
# dsh-overlay 插件宿主：加载 plugins\* 里的浮层插件，连核心总线，跑 WPF 渲染循环
param(
  [switch]$RenderPreview,
  [string]$PreviewDir = '',
  [int]$RunSeconds = 0,
  [switch]$NoCore,
  [switch]$PetMode,
  [string[]]$Only = @(),
  [switch]$Verbose
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'host-lib.ps1')

$root = Split-Path $PSScriptRoot -Parent
$cfg = Read-DshJson (Join-Path $root 'core\config.json')
Initialize-DshLog -Path (Join-Path $root 'logs\host.log')

if (-not $PreviewDir) { $PreviewDir = Join-Path $root 'preview' }
$tickMs = if ($cfg.host -and $cfg.host.tickMs) { [int]$cfg.host.tickMs } else { 40 }

$logDir = Join-Path $root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# 单实例保护：已经有宿主在跑就退出，避免双击两次叠一堆窗口
$pidFile = Join-Path $logDir 'host.pid'
try {
  if (Test-Path -LiteralPath $pidFile) {
    $oldPid = 0
    [void][int]::TryParse((((Get-Content -LiteralPath $pidFile -Raw) -replace '\s', '')), [ref]$oldPid)
    if ($oldPid -gt 0 -and $oldPid -ne $PID) {
      $old = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
      if ($old -and ($old.ProcessName -match '^(powershell|pwsh)$')) {
        Write-DshLog ("检测到已有实例 pid {0}，本次不重复启动（要重启请先跑 stop.cmd）" -f $oldPid)
        exit 0
      }
    }
  }
} catch {}
[IO.File]::WriteAllText($pidFile, [string]$PID)

# 兜底：任何没被插件 try/catch 吃掉的异常都只记日志，不把整个宿主崩掉
trap {
  Write-DshLog ("未捕获异常（已拦截）: {0}" -f $_.Exception.Message) 'error'
  continue
}
try {
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Add_UnhandledException({
    param($sender, $e)
    Write-DshLog ("渲染线程异常（已拦截，继续运行）: {0}" -f $e.Exception.Message) 'error'
    $e.Handled = $true
  })
} catch {}

Write-DshLog ("宿主启动：预览={0} 不连核心={1} 插件过滤=[{2}]" -f [bool]$RenderPreview, [bool]$NoCore, ($Only -join ','))

# ------------------------------------------------------------------ context
$ctx = [pscustomobject]@{
  Root         = $root
  Config       = $cfg
  Preview      = [bool]$RenderPreview
  Bus          = $null
  BusConnected = $false
  BusHost      = if ($cfg.bus) { $cfg.bus.host } else { '127.0.0.1' }
  BusPort      = if ($cfg.bus) { [int]$cfg.bus.port } else { 17777 }
  Plugins      = @()
  AnchorX      = 0.0
  AnchorY      = 0.0
  AnchorW      = 280.0
  AnchorH      = 336.0
  AnchorDirty  = $false
  OverlayVisible = $true
  PreviewMs    = 0.0
  HitCount     = 0
  StartBalance = [double]$cfg.balance.startCny
  RequestStop  = $null
  HasWindows   = $false
}

# ------------------------------------------------------------------ plugin loading
function New-PluginRuntime {
  param([System.IO.DirectoryInfo]$Dir)
  $meta = Read-DshJson (Join-Path $Dir.FullName 'plugin.json')
  if (-not $meta) { return $null }
  $ps1 = Join-Path $Dir.FullName 'plugin.ps1'
  if (-not (Test-Path -LiteralPath $ps1)) { return $null }

  $dirLiteral = $Dir.FullName.Replace('\', '/')
  $body = [IO.File]::ReadAllText($ps1, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
  # 插件跑在独立模块里，把宿主公共库一起塞进去，避免跨作用域找不到函数
  # 注意：动态模块里 $PSScriptRoot 被引擎接管、读不到自定义值，所以用 $DshDir 传插件目录
  $lib = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'host-lib.ps1'), [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
  $logPath = (Join-Path $root 'logs\host.log').Replace('\', '/')
  $src = "`$DshDir = '$dirLiteral'`r`n" + $lib + "`r`nInitialize-DshLog -Path '$logPath'`r`n" + $body
  $module = New-Module -Name ([string]$meta.id) -ScriptBlock ([scriptblock]::Create($src))

  return [pscustomobject]@{
    Id          = [string]$meta.id
    Meta        = $meta
    Dir         = $Dir.FullName
    Module      = $module
    # 注意：跨模块调用一律用位置参数，避免 -Event/-Evt 这类参数名不匹配的坑
    Initialize  = $module.NewBoundScriptBlock({ param($c) Initialize-Plugin $c })
    GetWindows  = $module.NewBoundScriptBlock({ param($c) Get-PluginWindows $c })
    Update      = $module.NewBoundScriptBlock({ param($c, $e) if (Get-Command Update-Plugin -ErrorAction SilentlyContinue) { Update-Plugin $c $e } })
    Tick        = $module.NewBoundScriptBlock({ param($c, $ms) if (Get-Command Tick-Plugin -ErrorAction SilentlyContinue) { Tick-Plugin $c $ms } })
    PreviewPose = $module.NewBoundScriptBlock({ param($c, $ms) if (Get-Command Set-PluginPreviewPose -ErrorAction SilentlyContinue) { Set-PluginPreviewPose -Context $c -Ms $ms } })
    Windows     = @()
  }
}

$pluginDirs = @()
$pdir = Join-Path $root 'plugins'
if (Test-Path -LiteralPath $pdir) { $pluginDirs = @(Get-ChildItem -LiteralPath $pdir -Directory | Sort-Object Name) }

$runtime = New-Object System.Collections.ArrayList
foreach ($d in $pluginDirs) {
  $meta = Read-DshJson (Join-Path $d.FullName 'plugin.json')
  if (-not $meta) { Write-DshLog ("跳过 {0}（没有 plugin.json）" -f $d.Name) 'warn'; continue }
  if ($meta.enabled -eq $false) { Write-DshLog ("跳过 {0}（enabled=false）" -f $meta.id); continue }
  if ($Only.Count -gt 0 -and ($Only -notcontains $meta.id)) { Write-DshLog ("跳过 {0}（-Only 过滤）" -f $meta.id); continue }
  try {
    $rt = New-PluginRuntime -Dir $d
    if ($rt) { [void]$runtime.Add($rt); Write-DshLog ("加载插件 {0} v{1} ({2})" -f $rt.Id, $meta.version, $meta.name) }
  } catch {
    Write-DshLog ("插件 {0} 加载失败：{1}" -f $d.Name, $_.Exception.Message) 'error'
  }
}
$ctx.Plugins = @($runtime)

foreach ($rt in $runtime) {
  try { & $rt.Initialize $ctx | Out-Null }
  catch { Write-DshLog ("插件 {0} 初始化失败：{1}" -f $rt.Id, $_.Exception.Message) 'error' }
  try { $rt.Windows = @(& $rt.GetWindows $ctx) }
  catch { Write-DshLog ("插件 {0} 取窗口失败：{1}" -f $rt.Id, $_.Exception.Message) 'error' }
}

function Invoke-DshStop {
  # 右键「退出浮层」/ 托盘退出：先落 stop.flag。
  # 否则启动器的守护进程（每 4 秒一回）会发现"浮层不在了"→ 判成崩溃 → 自动把它重启回来 ✗
  try { Set-Content -LiteralPath (Join-Path $root 'logs\stop.flag') -Value 'quit by user' -Encoding ASCII } catch {}
  if ($ctx.HitCount -gt 0) { Write-DshLog ("本次会话共处理 {0} 次命中" -f $ctx.HitCount) }
  foreach ($rt in $ctx.Plugins) {
    foreach ($w in $rt.Windows) { try { $w.Close() } catch {} }
  }
  try { Remove-Item -LiteralPath (Join-Path $root 'logs\host.pid') -Force -ErrorAction SilentlyContinue } catch {}
  try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch {}
}
$ctx.RequestStop = { Invoke-DshStop }

# ------------------------------------------------------------------ show windows
foreach ($rt in $runtime) {
  $clickThrough = $false
  if ($rt.Meta.window -and $rt.Meta.window.clickThrough) { $clickThrough = $true }
  foreach ($w in $rt.Windows) {
    try {
      $w.Show()
      $w.ShowInTaskbar = $false
      if ($clickThrough) { [void](Set-DshWindowClickThrough -Window $w) }
      else { [void](Set-DshWindowClickThrough -Window $w -Disable) }
      Set-DshWindowTopmost -Window $w
      $ctx.HasWindows = $true
    } catch { Write-DshLog ("窗口显示失败（{0}）：{1}" -f $rt.Id, $_.Exception.Message) 'error' }
  }
}
if (-not $ctx.HasWindows) { Write-DshLog '没有任何插件窗口可显示，退出' 'error'; exit 1 }

# 桌宠模式：伤害数字现在是一块跟着挂件走的小面板，所以不再隐藏（要隐藏用托盘/右键的开关）
if ($PetMode) {
  Write-DshLog '桌宠模式：伤害数字面板跟随挂件显示（托盘/右键可关）'
}

# ------------------------------------------------------------------ preview timeline
$pv = $null
if ($RenderPreview) {
  $pulseRt = @($ctx.Plugins | Where-Object { $_.Id -eq 'dsh-damage-pulse' })[0]
  $whaleRt = @($ctx.Plugins | Where-Object { $_.Id -eq 'dsh-whale-widget' })[0]
  $dir = $PreviewDir
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  $ps = @{
    Steps      = (New-Object System.Collections.ArrayList)
    Idx        = 0
    T0         = [DateTime]::Now
    Frames     = @{ pulse = (New-Object System.Collections.ArrayList); pulse2 = (New-Object System.Collections.ArrayList); whale = (New-Object System.Collections.ArrayList) }
    PulseShot  = $null
    WhaleShot  = $null
    Dir        = $dir
    Files      = (New-Object System.Collections.ArrayList)
    Boxes      = @{}
  }
  $vs = Get-DshVirtualScreen
  $pEl = if ($pulseRt) { $pulseRt.Windows[0].Content } else { $null }
  $wEl = if ($whaleRt) { $whaleRt.Windows[0].Content } else { $null }

  function Add-Step {
    param([int]$At, [scriptblock]$Body)
    [void]$ps.Steps.Add([pscustomobject]@{ At = $At; Do = $Body })
  }

  function New-Hit {
    param([double]$Cost, [string]$Name, [double]$Size, [string]$Color, [string]$Glow, [int]$Combo, [bool]$Crit)
    return [pscustomobject]@{
      t = 'hit'; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); source = 'preview'; model = 'deepseek-flash'
      costCny = $Cost; label = ('{0} -{1:F4}¥' -f $Name, $Cost)
      tier = [pscustomobject]@{ name = $Name; size = $Size; color = $Color; glow = $Glow; shakeMs = 240; weight = 'Black'; italic = $Crit }
      crit = $Crit; combo = $Combo; balanceCny = 78.92 - $Cost; totalSpentCny = $Cost; startBalanceCny = 78.92
    }
  }

  function Shot-Pulse {
    param([string]$Tag, [string]$Bucket = 'pulse', [int]$Ms = -1)
    if ($Ms -ge 0) { & $pulseRt.PreviewPose $ctx ([double]$Ms) }
    try { $pEl.InvalidateVisual(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render) } catch {}
    $bmp = Get-DshLiveBitmap -Element $pEl
    # 同一组的帧用同一个裁切框，filmstrip 才整齐
    if ($ps.Boxes.ContainsKey($Bucket)) { $box = $ps.Boxes[$Bucket] }
    else {
      $box = Get-DshContentBox -Bitmap $bmp -Backdrop '#0E1116' -Padding 34
      if (-not $box.Empty) { $ps.Boxes[$Bucket] = $box }
    }
    $crop = Crop-DshBitmap -Bitmap $bmp -X $box.X -Y $box.Y -W $box.W -H $box.H
    $path = Join-Path $ps.Dir ('_p_{0}.png' -f $Tag)
    Save-DshBitmap -Bitmap $crop -Path $path | Out-Null
    if ($ps.Frames.ContainsKey($Bucket)) { [void]$ps.Frames[$Bucket].Add($path) }
    $ps.PulseShot = $crop
  }

  function Shot-Whale {
    param([string]$Tag, [switch]$Strip, [int]$Ms = -1)
    if ($Ms -ge 0) { & $whaleRt.PreviewPose $ctx ([double]$Ms) }
    try { $wEl.InvalidateVisual(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render) } catch {}
    $bmp = Get-DshLiveBitmap -Element $wEl
    $path = Join-Path $ps.Dir ('_w_{0}.png' -f $Tag)
    Save-DshBitmap -Bitmap $bmp -Path $path | Out-Null
    if ($Strip) { [void]$ps.Frames['whale'].Add($path) }
    $ps.WhaleShot = $bmp
    return $path
  }

  # ---- 时间线：普通命中 -> 暴击 -> 挂件受击 -> 低余额 -> 桌面合成
  Add-Step 250 { & $pulseRt.Update $ctx (New-Hit -Cost 0.0034 -Name '命中' -Size 30 -Color '#FF4747' -Glow '#FF1E1E' -Combo 1 -Crit $false); $ctx.HitCount++ }
  Add-Step 520 { & $pulseRt.Update $ctx (New-Hit -Cost 0.0019 -Name '命中' -Size 26 -Color '#FF5A5A' -Glow '#FF2020' -Combo 2 -Crit $false); $ctx.HitCount++ }
  Add-Step 760 { & $pulseRt.Update $ctx (New-Hit -Cost 0.0048 -Name '命中' -Size 32 -Color '#FF4030' -Glow '#FF1000' -Combo 3 -Crit $false); $ctx.HitCount++ }
  # 场景 1：普通命中连打（伤害数字条）
  Add-Step 380 { Shot-Pulse -Tag 'a380' -Bucket 'pulse' -Ms 380 }
  Add-Step 470 { Shot-Pulse -Tag 'a470' -Bucket 'pulse' -Ms 470 }
  Add-Step 620 { Shot-Pulse -Tag 'a620' -Bucket 'pulse' -Ms 620 }
  Add-Step 900 { Shot-Pulse -Tag 'a900' -Bucket 'pulse' -Ms 900 }
  Add-Step 1250 { Shot-Pulse -Tag 'a1250' -Bucket 'pulse' -Ms 1250 }
  Add-Step 1560 { Shot-Pulse -Tag 'a1560' -Bucket 'pulse' -Ms 1560 }

  # 场景 2：暴击 + 闪屏 + 抖屏
  Add-Step 1800 { & $pulseRt.Update $ctx (New-Hit -Cost 0.046 -Name '暴击' -Size 38 -Color '#FFB03A' -Glow '#FF7A00' -Combo 9 -Crit $true); $ctx.HitCount++ }
  Add-Step 1860 { Shot-Pulse -Tag 'b1860' -Bucket 'pulse2' -Ms 1860 }
  Add-Step 1950 { Shot-Pulse -Tag 'b1950' -Bucket 'pulse2' -Ms 1950 }
  Add-Step 2100 { Shot-Pulse -Tag 'b2100' -Bucket 'pulse2' -Ms 2100 }
  Add-Step 2320 { Shot-Pulse -Tag 'b2320' -Bucket 'pulse2' -Ms 2320 }
  Add-Step 2600 { Shot-Pulse -Tag 'b2600' -Bucket 'pulse2' -Ms 2600 }
  Add-Step 2900 { Shot-Pulse -Tag 'b2900' -Bucket 'pulse2' -Ms 2900 }

  # 场景 3：挂件受击
  Add-Step 3200 {
    & $whaleRt.Update $ctx ([pscustomobject]@{ t = 'state'; balanceCny = 78.92; totalSpentCny = 0; hits = 0; combo = 0; startBalanceCny = 78.92 })
    & $whaleRt.Update $ctx (New-Hit -Cost 0.0034 -Name '命中' -Size 30 -Color '#FF4747' -Glow '#FF1E1E' -Combo 3 -Crit $false)
    & $whaleRt.Update $ctx (New-Hit -Cost 0.0052 -Name '命中' -Size 32 -Color '#FF4030' -Glow '#FF1000' -Combo 4 -Crit $false)
  }
  Add-Step 3280 { Shot-Whale -Tag 'c3280' -Strip -Ms 3280 | Out-Null }
  Add-Step 3400 { Shot-Whale -Tag 'c3400' -Strip -Ms 3400 | Out-Null }
  Add-Step 3560 { Shot-Whale -Tag 'c3560' -Strip -Ms 3560 | Out-Null }
  Add-Step 3780 { Shot-Whale -Tag 'c3780' -Strip -Ms 3780 | Out-Null }
  Add-Step 4020 { Shot-Whale -Tag 'c4020' -Strip -Ms 4020 | Out-Null }
  Add-Step 4300 { Shot-Whale -Tag 'c4300' -Strip -Ms 4300 | Out-Null }

  # 场景 4：低余额状态
  Add-Step 4600 {
    & $whaleRt.Update $ctx ([pscustomobject]@{ t = 'state'; balanceCny = 11.2; totalSpentCny = 67.72; hits = 421; combo = 0; startBalanceCny = 78.92 })
  }
  Add-Step 5000 { [void](Shot-Whale -Tag 'low' -Ms 5000) }
  Add-Step 5200 {
    & $whaleRt.Update $ctx ([pscustomobject]@{ t = 'state'; balanceCny = 78.6; totalSpentCny = 0.32; hits = 9; combo = 0; startBalanceCny = 78.92 })
  }
  Add-Step 5450 { & $whaleRt.Update $ctx ([pscustomobject]@{ t = 'pat' }) }
  Add-Step 5650 { [void](Shot-Whale -Tag 'idle' -Ms 5650) }

  # 场景 5：桌面合成图
  Add-Step 5800 {
    & $whaleRt.Update $ctx ([pscustomobject]@{ t = 'state'; balanceCny = 78.9; totalSpentCny = 0.02; hits = 5; combo = 0; startBalanceCny = 78.92 })
    & $pulseRt.Update $ctx (New-Hit -Cost 0.0034 -Name '命中' -Size 30 -Color '#FF4747' -Glow '#FF1E1E' -Combo 5 -Crit $false)
  }
  Add-Step 5920 { & $pulseRt.Update $ctx (New-Hit -Cost 0.0128 -Name '暴击' -Size 36 -Color '#FFB03A' -Glow '#FF7A00' -Combo 6 -Crit $true); $ctx.HitCount++ }
  Add-Step 6150 { Shot-Pulse -Tag 'hero' -Bucket 'hero' -Ms 6150 }
  Add-Step 6220 { [void](Shot-Whale -Tag 'hero' -Ms 6220) }
  Add-Step 6400 {
    $dw = 1280; $dh = 720
    $ww = [int]$whaleRt.Windows[0].Width
    $wh = [int]$whaleRt.Windows[0].Height
    $wX = $dw - $ww - 28
    $wY = $dh - $wh - 64
    $layers = (New-Object System.Collections.ArrayList)
    # 伤害数字贴在挂件左上方，跟真实布局一致
    if ($ps.PulseShot) {
      $pw = $ps.PulseShot.PixelWidth
      $ph = $ps.PulseShot.PixelHeight
      [void]$layers.Add([pscustomobject]@{
          Bitmap = $ps.PulseShot
          X = $wX - $pw - 8
          Y = $wY + 24
          W = $pw
          H = $ph
        })
    }
    if ($ps.WhaleShot) { [void]$layers.Add([pscustomobject]@{ Bitmap = $ps.WhaleShot; X = $wX; Y = $wY; W = $ww; H = $wh }) }
    $comp = Export-DshCompositePng -Path (Join-Path $ps.Dir 'desktop-mock.png') -Width $dw -Height $dh -Layers @($layers)
    [void]$ps.Files.Add($comp)
    Write-DshLog ("预览输出 {0}" -f $comp)
  }

  Add-Step 6900 {
    foreach ($k in @('pulse', 'pulse2', 'whale')) {
      $list = @($ps.Frames[$k])
      if ($list.Count -gt 0) {
        $name = switch ($k) { 'pulse' { 'damage-pulse-normal.png' } 'pulse2' { 'damage-pulse-crit.png' } 'whale' { 'whale-hit.png' } }
        $out = Join-DshFilmstrip -Paths $list -OutPath (Join-Path $ps.Dir $name)
        [void]$ps.Files.Add($out)
        Write-DshLog ("预览输出 {0}" -f $out)
      }
    }
    $idle = Join-Path $ps.Dir '_w_idle.png'
    $low = Join-Path $ps.Dir '_w_low.png'
    if (Test-Path $idle) { Copy-Item -LiteralPath $idle -Destination (Join-Path $ps.Dir 'whale-idle.png') -Force; [void]$ps.Files.Add((Join-Path $ps.Dir 'whale-idle.png')) }
    if (Test-Path $low) { Copy-Item -LiteralPath $low -Destination (Join-Path $ps.Dir 'whale-low.png') -Force; [void]$ps.Files.Add((Join-Path $ps.Dir 'whale-low.png')) }
    Get-ChildItem -LiteralPath $ps.Dir -Filter '_*.png' | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-DshLog '预览渲染完成'
    Invoke-DshStop
  }

  $pv = [pscustomobject]@{ S = $ps; Run = $true }
  # 按时间排序，避免"后加的早期步骤"被推迟执行
  $sorted = @($ps.Steps | Sort-Object At)
  $ps.Steps.Clear()
  foreach ($x in $sorted) { [void]$ps.Steps.Add($x) }
  Write-DshLog ("预览模式：窗口会短暂显示 {0} 秒用于采集动画帧" -f 7)
}

# ------------------------------------------------------------------ bus
function Connect-DshCore {
  $bus = New-DshBusClient -Host $ctx.BusHost -Port $ctx.BusPort
  if ($bus) {
    $ctx.Bus = $bus
    $ctx.BusConnected = $true
    Write-DshLog ("已连接核心总线 tcp://{0}:{1}" -f $ctx.BusHost, $ctx.BusPort)
    return $true
  }
  $ctx.BusConnected = $false
  return $false
}
if (-not $NoCore) {
  if (-not (Connect-DshCore)) { Write-DshLog '核心未启动，稍后自动重连（先跑 start.cmd）' 'warn' }
}

# ------------------------------------------------------------------ loop
$st = @{
  LastTick  = [DateTime]::Now
  Start     = [DateTime]::Now
  LastConn  = [DateTime]::MinValue
  Reconnect = if ($cfg.host -and $cfg.host.reconnectMs) { [int]$cfg.host.reconnectMs } else { 1500 }
  RunMs     = if ($RunSeconds -gt 0) { $RunSeconds * 1000 } else { 0 }
  NoCore    = [bool]$NoCore
}

$pvScript = $pv
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($tickMs)

$onTick = {
  $now = [DateTime]::Now
  $elapsed = ($now - $st.LastTick).TotalMilliseconds
  $st.LastTick = $now
  $c = $ctx

  if (-not $st.NoCore -and (-not $c.BusConnected) -and ($now - $st.LastConn).TotalMilliseconds -ge $st.Reconnect) {
    $st.LastConn = $now
    Connect-DshCore | Out-Null
  }

  if ($c.BusConnected -and $c.Bus) {
    $evts = Read-DshBus $c.Bus
    if (-not $c.Bus.Client.Connected) { $c.BusConnected = $false; $c.Bus = $null }
    foreach ($e in $evts) {
      if ($e.t -eq 'hello') { if ($e.startBalanceCny) { $c.StartBalance = [double]$e.startBalanceCny }; continue }
      if ($e.t -eq 'togglePlugin') {
        $want = [bool]$e.visible
        foreach ($rt2 in $c.Plugins) {
          if ($rt2.Id -ne $e.id) { continue }
          foreach ($wdw in $rt2.Windows) {
            try {
              if ($want) { $wdw.Visibility = [System.Windows.Visibility]::Visible }
              else { $wdw.Visibility = [System.Windows.Visibility]::Collapsed }
            } catch {}
          }
        }
        $c.OverlayVisible = $want
        Write-DshLog ("伤害数字 -> {0}" -f $(if ($want) { '开' } else { '关' }))
      }
      if ($e.t -eq 'hit') { $c.HitCount++ }
      if ($e.t -eq 'ui' -and $e.cmd -eq 'tick') {
        # 托盘「性能模式」：运行中直接换帧率，不用重启宿主
        $ms = 0
        try { $ms = [int]$e.value } catch {}
        if ($ms -ge 20 -and $ms -le 200) {
          $script:tickMs = $ms
          $timer.Interval = [TimeSpan]::FromMilliseconds($ms)
          Write-DshLog ("渲染帧率 -> 每帧 {0}ms（{1}）" -f $ms, $(if ($ms -le 50) { '流畅' } else { '省电' }))
        }
      }
      if ($e.t -eq 'state' -or $e.t -eq 'reset') {
        if ($e.startBalanceCny) { $c.StartBalance = [double]$e.startBalanceCny }
        if ($e.hits -ne $null) { $c.HitCount = [int]$e.hits }
      }
      foreach ($rt in $c.Plugins) {
        try { & $rt.Update $c $e } catch { Write-DshLog ("插件 {0} 处理事件出错：{1}`n{2}" -f $rt.Id, $_.Exception.Message, $_.ScriptStackTrace) 'error' }
      }
    }
  }

  if ($c.AnchorDirty) {
    $c.AnchorDirty = $false
    $anchorEvt = [pscustomobject]@{ t = 'anchor'; x = $c.AnchorX; y = $c.AnchorY; w = $c.AnchorW; h = $c.AnchorH }
    foreach ($rt in $c.Plugins) { try { & $rt.Update $c $anchorEvt } catch {} }
  }

  foreach ($rt in $c.Plugins) {
    try { & $rt.Tick $c $elapsed } catch { Write-DshLog ("插件 {0} Tick 出错：{1}" -f $rt.Id, $_.Exception.Message) 'error' }
  }

  # 预览时间线
  if ($pvScript -and $pvScript.Run) {
    $s = $pvScript.S
    $el = ($now - $s.T0).TotalMilliseconds
    while ($s.Idx -lt $s.Steps.Count -and $s.Steps[$s.Idx].At -le $el) {
      $step = $s.Steps[$s.Idx]
      $s.Idx++
      $ctx.PreviewMs = [double]$step.At
      try { & $step.Do } catch { Write-DshLog ("预览步骤 {0}ms 出错：{1}`n{2}" -f $step.At, $_.Exception.Message, $_.ScriptStackTrace) 'error' }
    }
  }

  if ($st.RunMs -gt 0 -and ($now - $st.Start).TotalMilliseconds -ge $st.RunMs) {
    Write-DshLog ("达到 -RunSeconds 时限（{0}s），退出" -f $RunSeconds)
    $timer.Stop()
    Invoke-DshStop
  }
}.GetNewClosure()

$timer.Add_Tick($onTick)
$timer.Start()

Write-DshLog ("进入渲染循环，tick={0}ms" -f $tickMs)
[System.Windows.Threading.Dispatcher]::Run() | Out-Null
Write-DshLog '宿主退出'

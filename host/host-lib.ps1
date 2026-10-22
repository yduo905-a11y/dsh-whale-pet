# dsh-overlay 宿主公共库：日志 / 总线客户端 / 窗口工具 / 离屏渲染
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('Dsh.Native' -as [type])) {
  Add-Type -Namespace Dsh -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
'@
}

$script:DshLogPath = $null

function Initialize-DshLog {
  param([string]$Path)
  $script:DshLogPath = $Path
  try { $d = Split-Path $Path -Parent; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } } catch {}
}

function Write-DshLog {
  param([string]$Message, [string]$Level = 'info')
  $line = '{0} [{1}] {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
  Write-Host $line
  if ($script:DshLogPath) {
    try { Add-Content -LiteralPath $script:DshLogPath -Value $line -Encoding UTF8 } catch {}
  }
}

function Read-DshJson {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
  $raw = $raw.TrimStart([char]0xFEFF)
  return $raw | ConvertFrom-Json
}

function Write-DshJson {
  param($Object, [string]$Path)
  $json = $Object | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function New-DshBrush {
  param([string]$Hex)
  if (-not $Hex) { return $null }
  $c = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
  return $c
}

# ------------------------------------------------------------------ bus
function New-DshBusClient {
  param([string]$Host = '127.0.0.1', [int]$Port = 17777, [int]$TimeoutMs = 600)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($Host, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $client.Close(); return $null }
    $client.EndConnect($iar)
  } catch { try { $client.Close() } catch {}; return $null }
  $client.NoDelay = $true
  return [pscustomobject]@{
    Client = $client
    Buffer = ''
    Host   = $Host
    Port   = $Port
    Ok     = $true
  }
}

function Test-DshBusAlive {
  param($Bus)
  if (-not $Bus) { return $false }
  try { return [bool]$Bus.Client.Connected } catch { return $false }
}

function Read-DshBus {
  param($Bus)
  $events = New-Object System.Collections.ArrayList
  if (-not $Bus -or -not $Bus.Client) { return $events }
  try {
    if (-not $Bus.Client.Connected) { return $events }
    $stream = $Bus.Client.GetStream()
    $buf = New-Object byte[] 16384
    while ($stream.DataAvailable) {
      $n = $stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $Bus.Buffer += [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    }
  } catch { return $events }

  while ($true) {
    $i = $Bus.Buffer.IndexOf("`n")
    if ($i -lt 0) { break }
    $line = $Bus.Buffer.Substring(0, $i).Trim()
    $Bus.Buffer = $Bus.Buffer.Substring($i + 1)
    if (-not $line) { continue }
    try { [void]$events.Add(($line | ConvertFrom-Json)) } catch {}
  }
  return $events
}

function Send-DshBus {
  param($Bus, $Object)
  if (-not $Bus -or -not $Bus.Client -or -not $Bus.Client.Connected) { return $false }
  try {
    $json = ($Object | ConvertTo-Json -Compress -Depth 8) + "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Bus.Client.GetStream().Write($bytes, 0, $bytes.Length)
    return $true
  } catch { return $false }
}

# ------------------------------------------------------------------ windows
function Get-DshVirtualScreen {
  $w = [System.Windows.SystemParameters]::VirtualScreenWidth
  $h = [System.Windows.SystemParameters]::VirtualScreenHeight
  $l = [System.Windows.SystemParameters]::VirtualScreenLeft
  $t = [System.Windows.SystemParameters]::VirtualScreenTop
  return [pscustomobject]@{ Left = $l; Top = $t; Width = $w; Height = $h }
}

function Get-DshPrimaryScreen {
  # Primary monitor bounds in WPF DIP space (Window.Left/Top use DIPs, 96 dpi).
  # WinForms Screen.Bounds returns PHYSICAL pixels; on a 150%-scaled display
  # using those numbers as DIPs pushes the widget 1.5x too far and off screen
  # (the widget is invisible while the log still claims it was pulled back).
  # Convert physical -> DIP so this matches Window.Left/Top and Get-DshVirtualScreen.
  try {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $dipW = [double][System.Windows.SystemParameters]::PrimaryScreenWidth
    $dipH = [double][System.Windows.SystemParameters]::PrimaryScreenHeight
    $sx = 1.0
    $sy = 1.0
    if ($dipW -gt 10 -and $b.Width -gt 10) { $sx = [double]$b.Width / $dipW }
    if ($dipH -gt 10 -and $b.Height -gt 10) { $sy = [double]$b.Height / $dipH }
    if ($sx -le 0) { $sx = 1.0 }
    if ($sy -le 0) { $sy = 1.0 }
    return [pscustomobject]@{
      Left   = [double]$b.Left   / $sx
      Top    = [double]$b.Top    / $sy
      Width  = [double]$b.Width  / $sx
      Height = [double]$b.Height / $sy
    }
  } catch { }
  return [pscustomobject]@{
    Left   = [System.Windows.SystemParameters]::VirtualScreenLeft
    Top    = [System.Windows.SystemParameters]::VirtualScreenTop
    Width  = [System.Windows.SystemParameters]::PrimaryScreenWidth
    Height = [System.Windows.SystemParameters]::PrimaryScreenHeight
  }
}

# ------------------------------------------------------------------ animation helpers
function New-DshDoubleAnimation {
  param(
    [double]$From, [double]$To, [int]$Ms,
    [switch]$AutoReverse, [switch]$Forever,
    [string]$Ease = 'None', [double]$Amplitude = 0.35, [int]$BeginMs = 0, [string]$Fill = 'Hold'
  )
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation
  $a.From = $From
  $a.To = $To
  $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms))
  if ($BeginMs -gt 0) { $a.BeginTime = [TimeSpan]::FromMilliseconds($BeginMs) }
  if ($AutoReverse) { $a.AutoReverse = $true }
  if ($Forever) { $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever }
  switch ($Ease) {
    'Cubic' { $a.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseOut' } }
    'CubicInOut' { $a.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseInOut' } }
    'Sine' { $a.EasingFunction = New-Object System.Windows.Media.Animation.SineEase -Property @{ EasingMode = 'EaseInOut' } }
    'Back' { $a.EasingFunction = New-Object System.Windows.Media.Animation.BackEase -Property @{ Amplitude = $Amplitude; EasingMode = 'EaseOut' } }
  }
  if ($Fill -eq 'Stop') { $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop }
  return $a
}

function New-DshKeyframeAnimation {
  # 默认 Hold：动画结束后停在最后一个关键帧（值即"静止状态"），避免回落时闪一下
  param([double[]]$Values, [int]$Ms, [string]$Fill = 'Hold')
  $da = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
  $da.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms))
  if ($Fill -eq 'Stop') { $da.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop }
  $n = [Math]::Max(1, $Values.Count - 1)
  for ($i = 0; $i -lt $Values.Count; $i++) {
    $t = [TimeSpan]::FromMilliseconds([int]($Ms * $i / $n))
    $kf = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame([double]$Values[$i], $t)
    [void]$da.KeyFrames.Add($kf)
  }
  return $da
}

function Start-DshAnim {
  param($Target, $Property, $Animation)
  # .NET Framework 的 Animatable 只有 2/3 参数重载，没有 isControllable 版本
  $Target.BeginAnimation($Property, $Animation, [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)
}

# ---- 数值版缓动：预览模式用同一套曲线直接摆姿势（不依赖 WPF 渲染循环）
function Get-DshEase {
  param([string]$Kind, [double]$T)
  $t = [Math]::Max(0.0, [Math]::Min(1.0, $T))
  switch ($Kind) {
    'Cubic' { return 1.0 - [Math]::Pow(1.0 - $t, 3) }
    'Sine' { return [Math]::Sin($t * [Math]::PI / 2.0) }
    'Back' { $s = 1.7; $u = $t - 1.0; return 1.0 + ($s + 1.0) * [Math]::Pow($u, 3) + $s * [Math]::Pow($u, 2) }
    default { return $t }
  }
}

function Get-DshOpacityCurve {
  param([double]$T)
  $t = [Math]::Max(0.0, [Math]::Min(1.0, $T))
  if ($t -lt 0.18) { return $t / 0.18 }
  if ($t -lt 0.72) { return 1.0 }
  return [Math]::Max(0.0, (1.0 - $t) / 0.28)
}

function Get-DshKeyframeValue {
  param([double[]]$Values, [double]$T)
  $n = $Values.Count - 1
  if ($n -le 0) { return $Values[0] }
  if ($T -le 0.0) { return $Values[0] }
  if ($T -ge 1.0) { return $Values[$n] }
  $pos = $T * $n
  $i = [int][Math]::Floor($pos)
  if ($i -ge $n) { return $Values[$n] }
  $f = $pos - $i
  return $Values[$i] + ($Values[$i + 1] - $Values[$i]) * $f
}

function New-DshWindowFromXaml {
  param([string]$Xaml, [string]$Tag = 'window')
  $doc = New-Object System.Xml.XmlDocument
  $doc.LoadXml($Xaml)
  $reader = New-Object System.Xml.XmlNodeReader $doc
  $win = [System.Windows.Markup.XamlReader]::Load($reader)
  $win.Tag = $Tag
  # 任务栏/Alt+Tab 隐藏：WPF 的 ShowInTaskbar=False 与 WindowStyle=ToolWindow 对分层窗口不可靠，
  # 必须等 HWND 真的建立后补上 WS_EX_TOOLWINDOW(0x80)，否则任务栏会多出一个空白小窗口按钮。
  try {
    $win.Add_SourceInitialized({
      try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
        if ($h -ne [IntPtr]::Zero) {
          $ex = [Dsh.Native]::GetWindowLong($h, -20)
          if (($ex -band 0x80) -eq 0) { [void][Dsh.Native]::SetWindowLong($h, -20, ($ex -bor 0x80)) }
        }
      } catch {}
    }.GetNewClosure())
  } catch {}
  return $win
}

function Set-DshWindowClickThrough {
  param([System.Windows.Window]$Window, [switch]$Disable)
  $helper = New-Object System.Windows.Interop.WindowInteropHelper $Window
  $h = $helper.Handle
  $GWL_EXSTYLE = -20
  $WS_EX_TRANSPARENT = 0x20
  $WS_EX_LAYERED = 0x80000
  $WS_EX_TOOLWINDOW = 0x80
  $WS_EX_NOACTIVATE = 0x8000000
  $ex = [Dsh.Native]::GetWindowLong($h, $GWL_EXSTYLE)
  if ($Disable) { $ex = $ex -band (-bnot ($WS_EX_TRANSPARENT -bor $WS_EX_NOACTIVATE)) }
  else { $ex = $ex -bor $WS_EX_TRANSPARENT -bor $WS_EX_LAYERED -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE }
  [void][Dsh.Native]::SetWindowLong($h, $GWL_EXSTYLE, $ex)
  return $h
}

function Set-DshWindowTopmost {
  param([System.Windows.Window]$Window)
  try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper $Window
    [void][Dsh.Native]::SetWindowPos($helper.Handle, [IntPtr]::new(-1), 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010)
  } catch {}
}

# ------------------------------------------------------------------ offscreen render
function Export-DshElementPng {
  param(
    [System.Windows.FrameworkElement]$Element,
    [int]$Width,
    [int]$Height,
    [string]$Path,
    [string]$Backdrop = '',
    [int]$CropX = -1,
    [int]$CropY = -1,
    [int]$CropW = 0,
    [int]$CropH = 0
  )
  $rtb = Get-DshElementBitmap -Element $Element -Width $Width -Height $Height
  $src = $rtb
  $ow = $Width; $oh = $Height
  if ($CropW -gt 0 -and $CropH -gt 0 -and $CropX -ge 0 -and $CropY -ge 0) {
    $x = [Math]::Max(0, [Math]::Min($Width - 1, $CropX))
    $y = [Math]::Max(0, [Math]::Min($Height - 1, $CropY))
    $w = [Math]::Min($CropW, $Width - $x)
    $h = [Math]::Min($CropH, $Height - $y)
    $src = New-Object System.Windows.Media.Imaging.CroppedBitmap($rtb, (New-Object System.Windows.Int32Rect($x, $y, $w, $h)))
    $ow = $w; $oh = $h
  }

  $dv = New-Object System.Windows.Media.DrawingVisual
  $dc = $dv.RenderOpen()
  if ($Backdrop) {
    $br = New-DshBrush $Backdrop
    $dc.DrawRectangle($br, $null, (New-Object System.Windows.Rect(0, 0, $ow, $oh)))
  }
  $dc.DrawImage($src, (New-Object System.Windows.Rect(0, 0, $ow, $oh)))
  $dc.Close()

  $out = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($ow, $oh, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $out.Render($dv)

  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($out))
  $dir = Split-Path $Path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $fs = [IO.File]::Create($Path)
  $enc.Save($fs)
  $fs.Close()
  return $Path
}

function Get-DshElementBitmap {
  param([System.Windows.FrameworkElement]$Element, [int]$Width, [int]$Height)
  $Element.Measure((New-Object System.Windows.Size($Width, $Height)))
  $Element.Arrange((New-Object System.Windows.Rect(0, 0, $Width, $Height)))
  $Element.UpdateLayout()
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($Element)
  return $rtb
}

function Get-DshLiveBitmap {
  param([System.Windows.FrameworkElement]$Element)
  # 按元素真实 DPI 抓图，否则高 DPI 屏上坐标系会整体缩放
  $dpi = Get-DshDpi -Element $Element
  $sx = [double]$dpi.DpiScaleX
  $sy = [double]$dpi.DpiScaleY
  $w = [int][Math]::Max(1, [Math]::Round($Element.ActualWidth * $sx))
  $h = [int][Math]::Max(1, [Math]::Round($Element.ActualHeight * $sy))
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, [double]$dpi.PixelsPerInchX, [double]$dpi.PixelsPerInchY, [System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($Element)
  return $rtb
}

function Get-DshDpi {
  param([System.Windows.FrameworkElement]$Element)
  try {
    if ($Element -and $Element.IsLoaded) { return [System.Windows.Media.VisualTreeHelper]::GetDpi($Element) }
  } catch {}
  return [pscustomobject]@{ DpiScaleX = 1.0; DpiScaleY = 1.0; PixelsPerInchX = 96.0; PixelsPerInchY = 96.0 }
}

function Save-DshBitmap {
  param($Bitmap, [string]$Path)
  $dir = Split-Path $Path -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
  $fs = [IO.File]::Create($Path)
  $enc.Save($fs)
  $fs.Close()
  return $Path
}

function Crop-DshBitmap {
  param($Bitmap, [int]$X, [int]$Y, [int]$W, [int]$H)
  $x = [Math]::Max(0, [Math]::Min($Bitmap.PixelWidth - 1, $X))
  $y = [Math]::Max(0, [Math]::Min($Bitmap.PixelHeight - 1, $Y))
  $w = [Math]::Min($W, $Bitmap.PixelWidth - $x)
  $h = [Math]::Min($H, $Bitmap.PixelHeight - $y)
  return (New-Object System.Windows.Media.Imaging.CroppedBitmap($Bitmap, (New-Object System.Windows.Int32Rect($x, $y, $w, $h))))
}

function Get-DshContentBox {
  # 内容自适应裁切：按背景色对比找出真实出现的像素范围（避免 DPI/坐标换算误差）
  param(
    $Bitmap,
    [string]$Backdrop = '#0E1116',
    [int]$Padding = 36,
    [int]$Step = 3
  )
  $conv = New-Object System.Windows.Media.ImageBrush
  $fmt = [System.Windows.Media.PixelFormats]::Pbgra32
  $w = $Bitmap.PixelWidth; $h = $Bitmap.PixelHeight
  $buf = New-Object byte[] ($w * $h * 4)
  $Bitmap.CopyPixels($buf, $w * 4, 0)
  $bc = (New-DshBrush $Backdrop).Color
  $minX = $w; $minY = $h; $maxX = -1; $maxY = -1
  for ($y = 0; $y -lt $h; $y += $Step) {
    $row = $y * $w * 4
    for ($x = 0; $x -lt $w; $x += $Step) {
      $i = $row + $x * 4
      $b = $buf[$i]; $g = $buf[$i + 1]; $r = $buf[$i + 2]; $a = $buf[$i + 3]
      if ($a -lt 8) { continue }
      $d = [Math]::Abs($r - $bc.R) + [Math]::Abs($g - $bc.G) + [Math]::Abs($b - $bc.B)
      if ($d -gt 24) {
        if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
        if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }
  if ($maxX -lt 0) { return [pscustomobject]@{ X = 0; Y = 0; W = $w; H = $h; Empty = $true } }
  $x0 = [Math]::Max(0, $minX - $Padding)
  $y0 = [Math]::Max(0, $minY - $Padding)
  $x1 = [Math]::Min($w - 1, $maxX + $Padding)
  $y1 = [Math]::Min($h - 1, $maxY + $Padding)
  return [pscustomobject]@{ X = $x0; Y = $y0; W = ($x1 - $x0 + 1); H = ($y1 - $y0 + 1); Empty = $false }
}

function Export-DshCompositePng {
  param(
    [string]$Path,
    [int]$Width = 1280,
    [int]$Height = 720,
    $Layers = @(),
    [string]$Title = 'dsh-overlay'
  )
  $dv = New-Object System.Windows.Media.DrawingVisual
  $dc = $dv.RenderOpen()
  $bg = New-DshBrush '#FF0E1116'
  $barY = $Height - 48
  $icoY = $Height - 40
  $boxY = $Height - 38
  $dc.DrawRectangle($bg, $null, (New-Object System.Windows.Rect(0, 0, $Width, $Height)))
  $dc.DrawRectangle((New-DshBrush '#FF161A21'), $null, (New-Object System.Windows.Rect(64, 74, 372, 376)))
  $dc.DrawRectangle((New-DshBrush '#FF1E232C'), $null, (New-Object System.Windows.Rect(64, 74, 372, 34)))
  $dc.DrawRectangle((New-DshBrush '#FF2A303A'), $null, (New-Object System.Windows.Rect(84, 86, 110, 10)))
  $dc.DrawRectangle((New-DshBrush '#FF12161C'), $null, (New-Object System.Windows.Rect(84, 132, 300, 12)))
  $dc.DrawRectangle((New-DshBrush '#FF12161C'), $null, (New-Object System.Windows.Rect(84, 158, 262, 12)))
  $dc.DrawRectangle((New-DshBrush '#FF12161C'), $null, (New-Object System.Windows.Rect(84, 184, 282, 12)))
  $dc.DrawRectangle((New-DshBrush '#FF12161C'), $null, (New-Object System.Windows.Rect(84, 210, 196, 12)))
  $dc.DrawRectangle((New-DshBrush '#FF3A3F47'), $null, (New-Object System.Windows.Rect(0, $barY, $Width, 48)))
  $dc.DrawRectangle((New-DshBrush '#FF565C66'), $null, (New-Object System.Windows.Rect(18, $icoY, 34, 30)))
  $dc.DrawRectangle((New-DshBrush '#FF3E444D'), $null, (New-Object System.Windows.Rect(70, $boxY, 190, 26)))
  foreach ($l in $Layers) {
    $dc.DrawImage($l.Bitmap, (New-Object System.Windows.Rect($l.X, $l.Y, $l.W, $l.H)))
  }
  $dc.Close()
  $out = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $out.Render($dv)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($out))
  $fs = [IO.File]::Create($Path)
  $enc.Save($fs)
  $fs.Close()
  return $Path
}

function Join-DshFilmstrip {
  param([string[]]$Paths, [string]$OutPath, [string]$Backdrop = '#14161A')
  $imgs = @()
  foreach ($p in $Paths) {
    # OnLoad：读完立刻释放文件句柄，否则后面的清理删不掉中间帧
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.UriSource = [Uri]$p
    $bi.EndInit()
    $bi.Freeze()
    $imgs += $bi
  }
  $w = 0; $h = 0
  foreach ($i in $imgs) { $w += $i.PixelWidth + 8; if ($i.PixelHeight -gt $h) { $h = $i.PixelHeight } }
  $w += 8; $h += 16
  $dv = New-Object System.Windows.Media.DrawingVisual
  $dc = $dv.RenderOpen()
  $dc.DrawRectangle((New-DshBrush $Backdrop), $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
  $x = 8
  foreach ($i in $imgs) {
    $dc.DrawImage($i, (New-Object System.Windows.Rect($x, 8, $i.PixelWidth, $i.PixelHeight)))
    $x += $i.PixelWidth + 8
  }
  $dc.Close()
  $out = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $out.Render($dv)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($out))
  $fs = [IO.File]::Create($OutPath)
  $enc.Save($fs)
  $fs.Close()
  return $OutPath
}

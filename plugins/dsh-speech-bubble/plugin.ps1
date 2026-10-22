# dsh-speech-bubble —— 独立的手绘思考气泡面板
# 固定尺寸（统一大小），跟着挂件右侧显示；右侧放不下就自动往左挪，保证整条都在屏幕里
Set-StrictMode -Off

$script:Bub = $null

function Initialize-Plugin {
  param($Context)
  $cfg = Read-DshJson (Join-Path $DshDir 'plugin.json')
  $s = $cfg.settings

  $bw = [double]$s.bubbleWidth; if ($bw -le 0) { $bw = 300.0 }
  $bh = [double]$s.bubbleHeight; if ($bh -le 0) { $bh = 108.0 }
  $tail = [double]$s.tailHeight; if ($tail -le 0) { $tail = 44.0 }
  $stroke = [double]$s.stroke; if ($stroke -le 0) { $stroke = 4.0 }
  $font = [double]$s.fontSize; if ($font -le 0) { $font = 13.5 }
  $panelW = $bw + 2 * $stroke + 24
  $panelH = $bh + $tail + 2 * $stroke + 16

  $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" Left="0" Top="0"
        Width="$panelW" Height="$panelH">
  <Canvas x:Name="Root" Width="$panelW" Height="$panelH" Opacity="0" IsHitTestVisible="False" Background="Transparent">
    <Grid x:Name="Bubble" Width="$bw" Height="$bh" Canvas.Left="12" Canvas.Top="$($stroke + 4)">
      <Ellipse x:Name="BubbleBg" Fill="$($s.fill)" Stroke="$($s.strokeColor)" StrokeThickness="$stroke"/>
      <TextBlock x:Name="BubbleText" Text="" TextWrapping="Wrap" TextAlignment="Center"
                 FontFamily="Microsoft YaHei UI" FontSize="$font" FontWeight="SemiBold"
                 Foreground="$($s.textColor)" Margin="28,10,28,10"
                 HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Grid>
    <Ellipse x:Name="Dot1" Width="26" Height="20" Stroke="$($s.strokeColor)" StrokeThickness="$stroke"
             Fill="$($s.fill)" Canvas.Left="56" Canvas.Top="$($stroke + 4 + $bh - 6)"/>
    <Ellipse x:Name="Dot2" Width="16" Height="12" Stroke="$($s.strokeColor)" StrokeThickness="$($stroke * 0.9)"
             Fill="$($s.fill)" Canvas.Left="38" Canvas.Top="$($stroke + 4 + $bh + 16)"/>
  </Canvas>
</Window>
"@

  $win = New-DshWindowFromXaml -Xaml $xaml -Tag 'dsh-speech-bubble'
  $win.ShowInTaskbar = $false
  $win.Topmost = $true
  if ($Context.Preview) { $win.Content.Background = New-DshBrush '#FF0E1116' }

  $script:Bub = [pscustomobject]@{
    Config     = $cfg
    Settings   = $s
    Window     = $win
    Root       = $win.FindName('Root')
    Bubble     = $win.FindName('Bubble')
    BubbleText = $win.FindName('BubbleText')
    Dot1       = $win.FindName('Dot1')
    Dot2       = $win.FindName('Dot2')
    PanelW     = $panelW
    PanelH     = $panelH
    Left       = [double]::NaN
    Top        = [double]::NaN
    AnchorX    = 0.0
    AnchorY    = 0.0
    AnchorW    = 280.0
    AnchorH    = 336.0
    HideAt     = [DateTime]::MinValue
    Shown      = $false
  }
  Update-BubblePosition -Context $Context
  $script:PreviewOn = [bool]$Context.Preview
  Write-DshLog ("思考气泡已就绪：面板 {0}x{1} 气泡 {2}x{3}" -f [int]$panelW, [int]$panelH, [int]$bw, [int]$bh)
}

function Get-PluginWindows {
  param($Context)
  if ($script:Bub) { return @($script:Bub.Window) }
  return @()
}

function Update-BubblePosition {
  # 默认贴在挂件右边；右边空间不够就往左挪（再不够就贴屏幕左边界），纵向同理
  param($Context)
  $B = $script:Bub
  if (-not $B) { return }
  $s = $B.Settings
  # 夹屏要用「整个虚拟桌面」（多显示器合并范围），不能用主屏：
  # 挂件被拖到副屏时，用主屏夹会把气泡硬拉回主屏，看起来就是"气泡卡在前一个屏幕里过不去"。
  # 而且虚拟屏坐标是 DIP，跟挂件窗口的 Left/Top 同一套单位，混用不会错位。
  $pri = Get-DshVirtualScreen
  $ovX = [double]$s.overlapPetX; if ($ovX -eq 0) { $ovX = 24.0 }
  $ovY = [double]$s.offsetY
  $pad = [double]$s.screenPad; if ($pad -lt 0) { $pad = 10.0 }
  $side = 'left'
  try { if ($s.side) { $side = [string]$s.side } } catch {}
  $stroke = [double]$s.stroke; if ($stroke -le 0) { $stroke = 4.0 }
  $bw = [double]$s.bubbleWidth
  $bh = [double]$s.bubbleHeight
  $bubX = 12.0                 # 气泡在面板内的左上角（与 XAML 保持一致）
  $bubY = $stroke + 4.0

  $screenL = $pri.Left + $pad
  $screenR = $pri.Left + $pri.Width - $pad
  $screenT = $pri.Top + $pad
  $screenB = $pri.Top + $pri.Height - $pad

  # 首选：气泡贴在挂件左侧（漫画里人物说话那种），纵向略高一点
  if ($side -eq 'right') {
    $left = $B.AnchorX + $B.AnchorW - $ovX - $bubX          # 气泡左边缘压住挂件右边
  } else {
    $left = $B.AnchorX + $ovX - ($bubX + $bw)               # 气泡右边缘压住挂件左边
  }
  $top = $B.AnchorY + $ovY - $bubY

  # 兜底：夹进屏幕
  if ($left + $B.PanelW -gt $screenR) { $left = $screenR - $B.PanelW }
  if ($left -lt $screenL) { $left = $screenL }
  if ($top + $B.PanelH -gt $screenB) { $top = $screenB - $B.PanelH }
  if ($top -lt $screenT) { $top = $screenT }

  # 尾巴两个小圆点：气泡在左边时，圆点挂到气泡右下角（朝向挂件）
  $BubDot = $script:Bub
  if ($BubDot.Dot1 -and $BubDot.Dot2) {
    $dot1W = 26.0; $dot1H = 20.0; $dot2W = 16.0; $dot2H = 12.0
    if ($side -eq 'left') {
      $d1x = $bubX + $bw - 44.0 - $dot1W
      $d2x = $bubX + $bw - 44.0 + 18.0 - $dot2W
    } else {
      $d1x = $bubX + 44.0
      $d2x = $bubX + 44.0 - 18.0
    }
    $d1y = $bubY + $bh - 6.0
    $d2y = $bubY + $bh + 16.0
    [System.Windows.Controls.Canvas]::SetLeft($BubDot.Dot1, $d1x)
    [System.Windows.Controls.Canvas]::SetTop($BubDot.Dot1, $d1y)
    [System.Windows.Controls.Canvas]::SetLeft($BubDot.Dot2, $d2x)
    [System.Windows.Controls.Canvas]::SetTop($BubDot.Dot2, $d2y)
  }

  if ([double]::IsNaN($B.Left) -or [Math]::Abs($left - [double]$B.Left) -gt 0.5 -or [Math]::Abs($top - [double]$B.Top) -gt 0.5) {
    $B.Left = $left
    $B.Top = $top
    if ($B.Window) { $B.Window.Left = $left; $B.Window.Top = $top }
  }
}

function Show-Bubble {
  param($Context, [string]$Text, [int]$HoldMs = 2400)
  $B = $script:Bub
  if (-not $B) { return }
  $B.BubbleText.Text = $Text
  $B.HideAt = (Get-Date).AddMilliseconds($HoldMs)
  $B.Shown = $true
  Update-BubblePosition -Context $Context
  if ($B.Settings.debugPosition) {
    Write-DshLog ("[bubble] '{0}' 面板@{1:N0},{2:N0} 挂件@{3:N0},{4:N0} {5:N0}x{6:N0}" -f `
        $Text, $B.Left, $B.Top, $B.AnchorX, $B.AnchorY, $B.AnchorW, $B.AnchorH)
  }
  if ($script:PreviewOn) { $B.Root.Opacity = 1 }
  else {
    $ms = [int]([double]$B.Settings.fadeMs); if ($ms -le 0) { $ms = 160 }
    $null = Start-DshAnim -Target $B.Root -Property ([System.Windows.UIElement]::OpacityProperty) -Animation (New-DshKeyframeAnimation -Values @(0.0, 1.0) -Ms $ms -Fill Hold)
  }
}

function Hide-Bubble {
  $B = $script:Bub
  if (-not $B) { return }
  $B.Shown = $false
  if ($script:PreviewOn) { $B.Root.Opacity = 0 }
  else {
    $ms = [int]([double]$B.Settings.fadeMs); if ($ms -le 0) { $ms = 160 }
    $null = Start-DshAnim -Target $B.Root -Property ([System.Windows.UIElement]::OpacityProperty) -Animation (New-DshKeyframeAnimation -Values @(1.0, 0.0) -Ms ([int]($ms * 1.6)) -Fill Hold)
  }
}

function Update-Plugin {
  param($Context, $Evt)
  if (-not $script:Bub) { return }
  switch ($Evt.t) {
    'bubble' {
      $hold = 2400
      try { if ($Evt.holdMs) { $hold = [int]$Evt.holdMs } } catch {}
      Show-Bubble -Context $Context -Text ([string]$Evt.text) -HoldMs $hold
    }
    'anchor' {
      $script:Bub.AnchorX = [double]$Evt.x
      $script:Bub.AnchorY = [double]$Evt.y
      if ($Evt.w) { $script:Bub.AnchorW = [double]$Evt.w }
      if ($Evt.h) { $script:Bub.AnchorH = [double]$Evt.h }
      Update-BubblePosition -Context $Context
    }
    default { }
  }
}

function Tick-Plugin {
  param($Context, [double]$ElapsedMs)
  $B = $script:Bub
  if (-not $B) { return }
  if ($B.Shown -and (Get-Date) -gt $B.HideAt) { Hide-Bubble }
}

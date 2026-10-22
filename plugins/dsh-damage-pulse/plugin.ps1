# dsh-damage-pulse —— 全屏鼠标穿透浮层，把每一次「花钱」打成游戏伤害数字
# 动画一律走 Animatable.BeginAnimation（.NET Framework 只支持这个最稳）
Set-StrictMode -Off

$script:Pulse = $null
$script:PreviewOn = $false
$script:PreviewMs = 0.0

function Initialize-Plugin {
  param($Context)

  $cfg = Read-DshJson (Join-Path $DshDir 'plugin.json')
  $s = $cfg.settings
  $vs = Get-DshVirtualScreen
  $panelW = 1000.0; $panelH = 620.0
  try { if ([double]$s.panelWidth -gt 0) { $panelW = [double]$s.panelWidth } } catch {}
  try { if ([double]$s.panelHeight -gt 0) { $panelH = [double]$s.panelHeight } } catch {}
  $pri0 = Get-DshPrimaryScreen

  $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" Left="$($pri0.Left + 20)" Top="$($pri0.Top + 20)"
        Width="$panelW" Height="$panelH">
  <Grid x:Name="Root" ClipToBounds="False" Background="Transparent">
    <Grid.RenderTransform>
      <TranslateTransform x:Name="RootShift" X="0" Y="0"/>
    </Grid.RenderTransform>
    <Canvas x:Name="Layer" ClipToBounds="False"/>
  </Grid>
</Window>
"@

  $win = New-DshWindowFromXaml -Xaml $xaml -Tag 'dsh-damage-pulse'
  $win.ShowInTaskbar = $false
  $win.Topmost = $true

  # 预览模式给一张不透明底色，否则捕获出来的发光字会带透明通道伪影
  if ($Context.Preview) { $win.Content.Background = New-DshBrush '#FF0E1116' }

  # 初始挂件位置：先按主屏右下角猜一个，真正的坐标/尺寸由挂件通过 anchor 事件同步过来
  $anchorX = $pri0.Left + $pri0.Width - 280 - 28
  $anchorY = $pri0.Top + $pri0.Height - 336 - 64
  $anchorW = 280.0
  $anchorH = 336.0

  $script:Pulse = [pscustomobject]@{
    Config       = $cfg
    Settings     = $s
    VirtualScreen = $vs
    Window       = $win
    Root         = $win.Content
    Layer        = $win.FindName('Layer')
    Flash        = $null                        # 旧的整面板红框已删除：改用数字自身发光
    Shift        = $win.FindName('RootShift')
    Active       = (New-Object System.Collections.ArrayList)
    LastBorn     = [DateTime]::MinValue     # 上一发数字的时间（用来判断这次是不是「孤立命中」）
    AnchorX      = $anchorX
    AnchorY      = $anchorY
    AnchorW      = $anchorW
    AnchorH      = $anchorH
    SpawnX       = ($anchorX - 300.0)
    SpawnY       = ($anchorY + 240.0)
    TextX        = 44.0
    TextY        = 520.0
    AnchorMode   = [string]$s.anchorMode
    CustomX      = [double]$s.anchorX
    CustomY      = [double]$s.anchorY
    PanelW       = $panelW
    PanelH       = $panelH
    PanelLeft    = [double]::NaN
    PanelTop     = [double]::NaN
    Justify      = 'left'
    CritScale    = 1.0
    FlashOpacity = [double]($Context.Config.fx.flashOpacity)
    FlashAt      = 0.0
    ShakeAt      = 0.0
    ShakeMs      = 240.0
  }
  try {
    $cs = [double]$s.critScale
    if ($cs -ge 0.4 -and $cs -le 3.0) { $script:Pulse.CritScale = $cs }
  } catch {}
  $script:PreviewOn = [bool]$Context.Preview
  $script:PreviewMs = 0.0
  Update-PulsePanelPosition -Context $Context
  Write-DshLog ("伤害脉冲已就绪：模式 {0} 面板 {1}x{2} @ {3},{4}" -f $script:Pulse.AnchorMode, [int]$panelW, [int]$panelH, [int]$script:Pulse.PanelLeft, [int]$script:Pulse.PanelTop)
}

function Get-PluginWindows {
  param($Context)
  if ($script:Pulse) { return @($script:Pulse.Window) }
  return @()
}

function New-FontWeight {
  param([string]$Name)
  switch ($Name) {
    'Black' { return [System.Windows.FontWeights]::Black }
    'Heavy' { return [System.Windows.FontWeights]::Heavy }
    'SemiBold' { return [System.Windows.FontWeights]::SemiBold }
    default { return [System.Windows.FontWeights]::Bold }
  }
}

function Update-PulsePanelPosition {
  # 伤害数字画在「一块跟挂件走的小面板」里，而不是整个虚拟屏的浮层：
  #   1) 不受多屏/混合 DPI 影响（面板永远落在主屏内）
  #   2) 桌宠模式也能看到数字（面板就贴在挂件旁边）
  param($Context)
  $P = $script:Pulse
  if (-not $P) { return }
  $s = $P.Settings
  $pri = Get-DshPrimaryScreen
  $pw = [double]$P.PanelW
  $ph = [double]$P.PanelH
  $pad = 20.0
  try { if ([double]$s.presetPadding -gt 0) { $pad = [double]$s.presetPadding } } catch {}
  $tpX = 44.0
  try { if ([double]$s.textPadding -gt 0) { $tpX = [double]$s.textPadding } } catch {}
  $tpY = 520.0
  try { if ([double]$s.textBaseY -gt 0) { $tpY = [double]$s.textBaseY } } catch {}

  # spawnX/spawnY = 数字「出生点」的屏幕绝对坐标（右对齐时是右边缘，左对齐时是左边缘）
  $spawnX = 0.0; $spawnY = 0.0
  $left = 0.0; $top = 0.0; $justify = 'left'

  switch ([string]$P.AnchorMode) {
    'topLeft'      { $left = $pri.Left + $pad;                           $top = $pri.Top + $pad }
    'topCenter'    { $left = $pri.Left + ($pri.Width - $pw) / 2;         $top = $pri.Top + $pad }
    'topRight'     { $left = $pri.Left + $pri.Width - $pw - $pad;        $top = $pri.Top + $pad;                    $justify = 'right' }
    'left'         { $left = $pri.Left + $pad;                           $top = $pri.Top + ($pri.Height - $ph) / 2 }
    'right'        { $left = $pri.Left + $pri.Width - $pw - $pad;        $top = $pri.Top + ($pri.Height - $ph) / 2;  $justify = 'right' }
    'bottomLeft'   { $left = $pri.Left + $pad;                           $top = $pri.Top + $pri.Height - $ph - $pad }
    'bottomCenter' { $left = $pri.Left + ($pri.Width - $pw) / 2;         $top = $pri.Top + $pri.Height - $ph - $pad }
    'bottomRight'  { $left = $pri.Left + $pri.Width - $pw - $pad;        $top = $pri.Top + $pri.Height - $ph - $pad;  $justify = 'right' }
    'custom'       { $left = $P.CustomX;                                 $top = $P.CustomY }
    default        {  # 'widget'：出生点按「挂件窗口尺寸的比例」算，换设备/换缩放都不会跑偏
      $sox = -300.0; $soy = 240.0     # 老配置的绝对偏移，只在拿不到挂件尺寸时兜底
      try { if ($s.spawnOffsetX -ne $null) { $sox = [double]$s.spawnOffsetX } } catch {}
      try { if ($s.spawnOffsetY -ne $null) { $soy = [double]$s.spawnOffsetY } } catch {}
      $fx = 0.05; $fy = 0.45
      try { if ($s.spawnFracX -ne $null) { $fx = [double]$s.spawnFracX } } catch {}
      try { if ($s.spawnFracY -ne $null) { $fy = [double]$s.spawnFracY } } catch {}
      $aw = 0.0; $ah = 0.0
      try { $aw = [double]$P.AnchorW } catch {}
      try { $ah = [double]$P.AnchorH } catch {}
      if ($aw -gt 4 -and $ah -gt 4) {
        $spawnX = $P.AnchorX + $aw * $fx
        $spawnY = $P.AnchorY + $ah * $fy
      } else {
        $spawnX = $P.AnchorX + $sox
        $spawnY = $P.AnchorY + $soy
      }
      # 挂件默认在屏幕右下角，数字往挂件左边长（右对齐），别让它冲出屏幕
      $justify = 'right'
      $left = $spawnX - ($pw - $tpX)
      $top  = $spawnY - $tpY
    }
  }

  # 预设模式沿用老语义：文字左边缘落在 (left + tpX, top + tpY)
  if ($spawnX -eq 0.0 -and $spawnY -eq 0.0) {
    $spawnX = $left + $tpX
    $spawnY = $top + $tpY
  }

  # 夹进「整个虚拟屏」保证一定看得见；widget 模式下这样才能跟着挂件跑到任意一块屏
  $vsl = 0.0; $vst = 0.0; $vsw = 0.0; $vsh = 0.0
  try {
    $vsl = [double][System.Windows.SystemParameters]::VirtualScreenLeft
    $vst = [double][System.Windows.SystemParameters]::VirtualScreenTop
    $vsw = [double][System.Windows.SystemParameters]::VirtualScreenWidth
    $vsh = [double][System.Windows.SystemParameters]::VirtualScreenHeight
  } catch {}
  if ($vsw -gt 0) {
    if ($left -lt $vsl) { $left = $vsl }
    if ($top -lt $vst) { $top = $vst }
    if ($left + $pw -gt $vsl + $vsw) { $left = $vsl + $vsw - $pw }
    if ($top + $ph -gt $vst + $vsh) { $top = $vst + $vsh - $ph }
  }

  $P.Justify = $justify
  # 关键：面板被夹回屏幕里以后，出生点要按「面板最终位置」反算，
  # 否则文字会跟着面板一起被拖到屏幕角落（这就是以前数字跑很远的原因）
  $P.SpawnX = $spawnX
  $P.SpawnY = $spawnY
  $P.TextX = $spawnX - $left
  $P.TextY = $spawnY - $top
  if ([double]::IsNaN($P.PanelLeft) -or [Math]::Abs($left - [double]$P.PanelLeft) -gt 0.5 -or [Math]::Abs($top - [double]$P.PanelTop) -gt 0.5) {
    $P.PanelLeft = $left
    $P.PanelTop = $top
    if ($P.Window) {
      $P.Window.Left = $left
      $P.Window.Top = $top
    }
  }
}

function New-PulseHit {
  param($Context, $Evt)
  $P = $script:Pulse
  if (-not $P) { return }
  if ($script:PreviewOn) { $script:PreviewMs = [double]$Context.PreviewMs }
  $s = $P.Settings
  $vs = $P.VirtualScreen

  $size = 30.0
  if ($Evt.tier -and $Evt.tier.size) { $size = [double]$Evt.tier.size }
  # 暴击字号倍率（托盘「暴击数字：小/大」或 --ui critScale）：紧跟字号取值，保证 FontSize/发光/描边都用放大后的值
  $critScale = 1.0
  try { $critScale = [double]$P.CritScale } catch {}
  if ($critScale -gt 1.001 -or $critScale -lt 0.999) {
    $size = [Math]::Round($size * $critScale, 1)
    if ($s.debugLife) { Write-DshLog ('[pulse] 字号倍率 {0} -> {1}px' -f $critScale, $size) }
  }
  $colorHex = if ($Evt.tier -and $Evt.tier.color) { $Evt.tier.color } else { '#FF4747' }
  $glowHex = if ($Evt.tier -and $Evt.tier.glow) { $Evt.tier.glow } else { '#FF1E1E' }
  $italic = [bool]($Evt.tier -and $Evt.tier.italic)

  $now = Get-Date
  $recent = @($P.Active | Where-Object { ($now - $_.Born).TotalMilliseconds -lt [double]$s.stackWindowMs })
  $jx = Get-Random -Minimum (0 - [int]$s.jitterX) -Maximum ([int]$s.jitterX + 1)
  $jy = Get-Random -Minimum (0 - [int]$s.jitterY) -Maximum ([int]$s.jitterY + 1)
  $tp = 44.0
  try { if ([double]$s.textPadding -gt 0) { $tp = [double]$s.textPadding } } catch {}
  $tpY = 520.0
  try { if ([double]$s.textBaseY -gt 0) { $tpY = [double]$s.textBaseY } } catch {}
  $rise = [double]$s.riseDistance
  # 原始手感：每条往上抬 stackGap（比字高小，所以大字号会互相压着）→ 重叠 = 打击感
  $idx = $recent.Count
  # 出生点用 Update-PulsePanelPosition 算好的「面板内坐标」（已经扣掉面板被夹回屏幕的位移）
  $tx = $tp
  $ty = $tpY
  try { if ($P.TextX -ne $null) { $tx = [double]$P.TextX } } catch {}
  try { if ($P.TextY -ne $null) { $ty = [double]$P.TextY } } catch {}
  $baseX = $tx + $jx
  $baseY = $ty - ($idx * [double]$s.stackGap) + $jy
  $justify = [string]$P.Justify
  $life = [double]$s.lifeMs
  # 真实使用里命中是稀疏的（几秒一发），单发没有「叠字」的打击感 —— 给孤立命中多留 40% 时间，看得清
  $isoFactor = 1.4
  try { if ([double]$s.isolatedLifeFactor -gt 0) { $isoFactor = [double]$s.isolatedLifeFactor } } catch {}
  $isoGap = 1400.0
  try { if ([double]$s.isolatedGapMs -gt 0) { $isoGap = [double]$s.isolatedGapMs } } catch {}
  $prevBorn = [DateTime]::MinValue
  try { if ($P.LastBorn) { $prevBorn = [DateTime]$P.LastBorn } } catch {}
  $isolated = ($prevBorn -eq [DateTime]::MinValue) -or (($now - $prevBorn).TotalMilliseconds -ge $isoGap)
  if ($isolated) { $life = [Math]::Round($life * $isoFactor) }
  try { $P.LastBorn = $now } catch {}
  if ($s.debugLife) { Write-DshLog ('[pulse] 数字寿命 = {0}ms（孤立命中 = {1}）' -f [int]$life, [bool]$isolated) }
  $pop = [double]$s.popScale

  # 描边副本：游戏字体那种厚度
  $strokeOffset = [double]$s.strokeOffset * $critScale
  $stroke = New-Object System.Windows.Controls.TextBlock
  $stroke.Text = $Evt.label
  $stroke.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
  $stroke.FontSize = $size
  $stroke.FontWeight = New-FontWeight 'Bold'
  $stroke.FontStyle = if ($italic) { [System.Windows.FontStyles]::Italic } else { [System.Windows.FontStyles]::Normal }
  $stroke.Foreground = New-DshBrush '#990000'
  $stStroke = New-Object System.Windows.Media.TranslateTransform(0, 16)
  $stroke.RenderTransform = $stStroke
  [System.Windows.Controls.Canvas]::SetLeft($stroke, $baseX + $strokeOffset)
  [System.Windows.Controls.Canvas]::SetTop($stroke, $baseY + $strokeOffset)

  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $Evt.label
  $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
  $tb.FontSize = $size
  $tb.FontWeight = New-FontWeight $(if ($Evt.tier -and $Evt.tier.weight) { $Evt.tier.weight } else { 'Bold' })
  $tb.FontStyle = if ($italic) { [System.Windows.FontStyles]::Italic } else { [System.Windows.FontStyles]::Normal }
  $tb.Foreground = New-DshBrush $colorHex
  $tb.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
  $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
  $glow.Color = (New-DshBrush $glowHex).Color
  $glow.BlurRadius = [Math]::Round($size * 0.95)
  $glow.ShadowDepth = 0
  $glow.Opacity = 0.95
  if ($Evt.crit) {
    # 暴击：把数字自身的发光调浓调大（替代删掉的面板级红色矩形）
    $glow.BlurRadius = [Math]::Round($size * 1.75)
    $glow.Opacity = 1.0
  }
  $tb.Effect = $glow
  $stScale = New-Object System.Windows.Media.ScaleTransform($pop, $pop)
  $stTrans = New-Object System.Windows.Media.TranslateTransform(0, 16)
  $stGroup = New-Object System.Windows.Media.TransformGroup
  [void]$stGroup.Children.Add($stScale)
  [void]$stGroup.Children.Add($stTrans)
  $tb.RenderTransform = $stGroup
  [System.Windows.Controls.Canvas]::SetLeft($tb, $baseX)
  [System.Windows.Controls.Canvas]::SetTop($tb, $baseY)

  # 水平对齐：右对齐时把文字整体左移一个文本宽度，让它「右边缘」正好落在出生点上
  if ($justify -ne 'left') {
    try {
      $tb.Measure((New-Object System.Windows.Size(4000, 4000)))
      $tw = [double]$tb.DesiredSize.Width
      $shift = if ($justify -eq 'right') { 0.0 - $tw } else { 0.0 - $tw / 2.0 }
      # 贴边保护：挂件拖到屏幕左边/右边时，右对齐会把整条数字顶出屏幕
      # （实测挂件 left=-148 时数字完全看不见）。这里把文字框拉回可视区，左右各留 8px。
      try {
        $screenL = [double][System.Windows.SystemParameters]::VirtualScreenLeft
        $screenW = [double][System.Windows.SystemParameters]::VirtualScreenWidth
        $panelL = 0.0
        try { if ($P.Left -ne $null) { $panelL = [double]$P.Left } } catch {}
        $textL = $panelL + $baseX + $shift
        if ($textL -lt ($screenL + 8)) {
          $baseX = $baseX + (($screenL + 8) - $textL)
        }
        $textR = $panelL + $baseX + $shift + $tw
        $limitR = $screenL + $screenW - 8
        if ($textR -gt $limitR) {
          $baseX = $baseX - ($textR - $limitR)
        }
      } catch {}
      [System.Windows.Controls.Canvas]::SetLeft($tb, $baseX + $shift)
      [System.Windows.Controls.Canvas]::SetLeft($stroke, $baseX + $shift + $strokeOffset)
    } catch {}
  }

  if ($s.debugPosition) {
    $fx = [System.Windows.Controls.Canvas]::GetLeft($tb)
    $fy = [System.Windows.Controls.Canvas]::GetTop($tb)
    Write-DshLog (("[pos] mode={0} 面板@({1:N0},{2:N0}) 面板内=({3:N0},{4:N0}) 屏幕=({5:N0},{6:N0}) 挂件@({7:N0},{8:N0}) 尺寸=({9:N0}x{10:N0})" -f `
        $P.AnchorMode, $P.PanelLeft, $P.PanelTop, $fx, $fy, ($fx + [double]$P.PanelLeft), ($fy + [double]$P.PanelTop), $P.AnchorX, $P.AnchorY, $P.AnchorW, $P.AnchorH))
  }

  $drift = Get-Random -Minimum -14 -Maximum 15

  $entry = [pscustomobject]@{
    Born        = $now
    FontSize    = $size
    Spawn       = if ($script:PreviewOn) { [double]$script:PreviewMs } else { 0.0 }
    Life        = $life
    Rise        = $rise
    Drift       = $drift
    Pop         = $pop
    Text        = $tb
    Stroke      = $stroke
    Scale       = $stScale
    Trans       = $stTrans
    StrokeTrans = $stStroke
  }
  if ($s.debugPosition) { Write-DshLog (("[pulse] 加入 面板={0}x{1} 文字=({2},{3}) 宽={4} 可见={5} 层数={6}") -f $P.Window.ActualWidth, $P.Window.ActualHeight, [System.Windows.Controls.Canvas]::GetLeft($tb), [System.Windows.Controls.Canvas]::GetTop($tb), $tb.ActualWidth, $tb.Visibility, $P.Layer.Children.Count) }

  [void]$P.Layer.Children.Add($stroke)
  [void]$P.Layer.Children.Add($tb)
  [void]$P.Active.Add($entry)

  if ($script:PreviewOn) {
    # 预览：不启动 WPF 动画，交给 Set-PluginPreviewPose 用同一套曲线摆姿势
    Set-PluginPreviewPose -Context $Context -Ms ([double]$script:PreviewMs)
    return
  }

  # 淡入+停留+淡出（关键帧直接打在 Opacity 上）
  $null = Start-DshAnim -Target $tb -Property ([System.Windows.UIElement]::OpacityProperty) -Animation (New-DshKeyframeAnimation -Values @(0, 1, 1, 1, 1, 0) -Ms ([int]$life) -Fill Hold)
  $null = Start-DshAnim -Target $stroke -Property ([System.Windows.UIElement]::OpacityProperty) -Animation (New-DshKeyframeAnimation -Values @(0, 1, 1, 1, 1, 0) -Ms ([int]$life) -Fill Hold)

  # 弹出（带过冲）
  $null = Start-DshAnim -Target $stScale -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) -Animation (New-DshDoubleAnimation -From $pop -To 1.0 -Ms 190 -Ease Back -Amplitude ([double]($s.overshoot - 1.0) * 3.2))
  $null = Start-DshAnim -Target $stScale -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) -Animation (New-DshDoubleAnimation -From $pop -To 1.0 -Ms 190 -Ease Back -Amplitude ([double]($s.overshoot - 1.0) * 3.2))

  # 上飘 + 轻微横漂
  $null = Start-DshAnim -Target $stTrans -Property ([System.Windows.Media.TranslateTransform]::YProperty) -Animation (New-DshDoubleAnimation -From 16.0 -To $rise -Ms ([int]$life) -Ease Cubic)
  $null = Start-DshAnim -Target $stTrans -Property ([System.Windows.Media.TranslateTransform]::XProperty) -Animation (New-DshDoubleAnimation -From 0.0 -To $drift -Ms ([int]$life) -Ease Sine)
  $null = Start-DshAnim -Target $stStroke -Property ([System.Windows.Media.TranslateTransform]::YProperty) -Animation (New-DshDoubleAnimation -From 16.0 -To $rise -Ms ([int]$life) -Ease Cubic)
  $null = Start-DshAnim -Target $stStroke -Property ([System.Windows.Media.TranslateTransform]::XProperty) -Animation (New-DshDoubleAnimation -From 0.0 -To $drift -Ms ([int]$life) -Ease Sine)

  if ($Evt.crit) {
    if ($s.flashOnCrit) { Invoke-PulseFlash }
    if ($s.screenShake) { Invoke-PulseShake -Strength ([double]$Evt.tier.shakeMs) }
  }
}

# 旧的"整面板红色矩形闪光"已删除：那是个 1000x620 的径向渐变（中心透明、边缘实心红），
# 被面板窗口边缘裁成硬直边，看起来就是一块偏到挂件左上的红板子。
# 现在暴击的强调交给数字自身的红色发光（见 New-PulseHit 里的 crit 处理）。
function Invoke-PulseFlash {
  return
}

function Invoke-PulseShake {
  param([double]$Strength = 200)
  $P = $script:Pulse
  if (-not $P) { return }
  $ms = [int][Math]::Max(140, $Strength)
  if ($script:PreviewOn) {
    $P.ShakeAt = [double]$script:PreviewMs
    $P.ShakeMs = $ms
    return
  }
  $null = Start-DshAnim -Target $P.Shift -Property ([System.Windows.Media.TranslateTransform]::XProperty) -Animation (New-DshKeyframeAnimation -Values @(0, 7, -5.6, 3.8, -2.1, 0) -Ms $ms)
  $null = Start-DshAnim -Target $P.Shift -Property ([System.Windows.Media.TranslateTransform]::YProperty) -Animation (New-DshKeyframeAnimation -Values @(0, 5, -4, 2.7, -1.5, 0) -Ms $ms)
}

function Update-Plugin {
  param($Context, $Evt)
  if (-not $script:Pulse) { return }
  switch ($Evt.t) {
    'hit' { New-PulseHit -Context $Context -Evt $Evt }
    'miss' { New-PulseHit -Context $Context -Evt $Evt }       # 灰色「未命中」，样式由核心下发的 tier 决定
    'freeTurn' { New-PulseHit -Context $Context -Evt $Evt }   # 蓝色「免费回合」
    'anchor' {
      $aw = 0.0; $ah = 0.0
      try { if ($Evt.w -ne $null) { $aw = [double]$Evt.w } } catch {}
      try { if ($Evt.h -ne $null) { $ah = [double]$Evt.h } } catch {}
      Set-PluginAnchor -Context $Context -X ([double]$Evt.x) -Y ([double]$Evt.y) -W $aw -H $ah
      Update-PulsePanelPosition -Context $Context
    }
    'setAnchor' {
      if ($Evt.mode) { $script:Pulse.AnchorMode = [string]$Evt.mode }
      if ($Evt.x -ne $null) { $script:Pulse.CustomX = [double]$Evt.x }
      if ($Evt.y -ne $null) { $script:Pulse.CustomY = [double]$Evt.y }
      Update-PulsePanelPosition -Context $Context
      Write-DshLog ("伤害数字锚点 -> {0} ({1:N0},{2:N0})" -f $script:Pulse.AnchorMode, $script:Pulse.CustomX, $script:Pulse.CustomY)
    }
    'ui' {
      $cmd = [string]$Evt.cmd
      if ($cmd -eq 'critScale') {
        $v = 1.0
        try { $v = [double]$Evt.value } catch {}
        if ($v -ge 0.4 -and $v -le 3.0) {
          $script:Pulse.CritScale = $v
          try {
            $cfgDir = ''
            try { $cfgDir = [string]$DshDir } catch {}
            if (-not $cfgDir) { try { $cfgDir = [string]$Context.Dir } catch {} }
            $cfgPath = Join-Path $cfgDir 'plugin.json'
            $raw = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8)
            $lit = $v.ToString([Globalization.CultureInfo]::InvariantCulture)
            if ($raw -match '"critScale"\s*:') {
              $raw = [Text.RegularExpressions.Regex]::Replace($raw, '"critScale"\s*:\s*[0-9.]+', ('"critScale": ' + $lit))
            } else {
              $raw = [Text.RegularExpressions.Regex]::Replace($raw, '"debugPosition"\s*:', ('"critScale": ' + $lit + ',' + [char]10 + '      "debugPosition":'), 'None', [TimeSpan]::FromSeconds(2))
            }
            [IO.File]::WriteAllText($cfgPath, $raw, (New-Object Text.UTF8Encoding($true)))
          } catch { Write-DshLog ('[pulse] 写 critScale 失败：' + $_.Exception.Message) }
          Write-DshLog ('暴击字号倍率 -> {0:P0}' -f $v)
        }
      }
    }
    default { }
  }
}

function Tick-Plugin {
  param($Context, [double]$ElapsedMs)
  $P = $script:Pulse
  if (-not $P) { return }
  if ($P.Active.Count -gt 0) {
    $now = Get-Date
    # 按每条数字自己的寿命判断（孤立命中会活得更久），不是统一用 settings.lifeMs
    $dead = @($P.Active | Where-Object {
      $lim = [double]$P.Settings.lifeMs + 400
      try { if ([double]$_.Life -gt 0) { $lim = [double]$_.Life + 400 } } catch {}
      ($now - $_.Born).TotalMilliseconds -gt $lim
    })
    foreach ($d in $dead) {
      try {
        [void]$P.Layer.Children.Remove($d.Text)
        [void]$P.Layer.Children.Remove($d.Stroke)
      } catch {}
      [void]$P.Active.Remove($d)
    }
  }
}

function Set-PluginAnchor {
  param($Context, [double]$X, [double]$Y, [double]$W = 0.0, [double]$H = 0.0)
  if ($script:Pulse) {
    $script:Pulse.AnchorX = $X
    $script:Pulse.AnchorY = $Y
    if ($W -gt 4) { $script:Pulse.AnchorW = $W }
    if ($H -gt 4) { $script:Pulse.AnchorH = $H }
  }
}

function Set-PluginPreviewPose {
  param($Context, [double]$Ms)
  $P = $script:Pulse
  if (-not $P) { return }
  $script:PreviewMs = $Ms
  foreach ($e in @($P.Active)) {
    $age = $Ms - [double]$e.Spawn
    if ($age -lt 0) { $age = 0 }
    $t = if ([double]$e.Life -gt 0) { $age / [double]$e.Life } else { 1.0 }
    $op = Get-DshOpacityCurve $t
    $e.Text.Opacity = $op
    $e.Stroke.Opacity = $op
    $popT = [Math]::Min(1.0, $age / 190.0)
    $sc = [double]$e.Pop + (1.0 - [double]$e.Pop) * (Get-DshEase 'Back' $popT)
    $e.Scale.ScaleX = $sc
    $e.Scale.ScaleY = $sc
    $y = 16.0 + ([double]$e.Rise - 16.0) * (Get-DshEase 'Cubic' $t)
    $x = [double]$e.Drift * (Get-DshEase 'Sine' $t)
    $e.Trans.X = $x
    $e.Trans.Y = $y
    $e.StrokeTrans.X = $x
    $e.StrokeTrans.Y = $y
  }
  if ($P.Flash -and $P.FlashAt -gt 0) {
    $ft = [Math]::Min(1.0, ([double]$Ms - [double]$P.FlashAt) / 340.0)
    $P.Flash.Opacity = Get-DshKeyframeValue @(0.0, [double]$P.FlashOpacity, [double]$P.FlashOpacity, 0.0) $ft
  }
  if ($P.ShakeAt -gt 0) {
    $st = [Math]::Min(1.0, ([double]$Ms - [double]$P.ShakeAt) / [double]$P.ShakeMs)
    $P.Shift.X = Get-DshKeyframeValue @(0, 7, -5.6, 3.8, -2.1, 0) $st
    $P.Shift.Y = Get-DshKeyframeValue @(0, 5, -4, 2.7, -1.5, 0) $st
  }
}

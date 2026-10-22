# dsh-whale-widget —— 桌面鲸娘挂件：余额当血条，花钱被打就抖
Set-StrictMode -Off

$script:Whale = $null
$script:PreviewOn = $false
$script:PreviewMs = 0.0

function Read-PositionFile {
  param([string]$Path)
  $p = Read-DshJson $Path
  if ($p -and $p.left -ne $null -and $p.top -ne $null) {
    $sc = 1.0
    if ($p.scale -ne $null) { $sc = [double]$p.scale }
    return [pscustomobject]@{ Left = [double]$p.left; Top = [double]$p.top; Scale = $sc }
  }
  return $null
}

function Initialize-Plugin {
  param($Context)

  $cfg = Read-DshJson (Join-Path $DshDir 'plugin.json')
  $s = $cfg.settings
  $bw = [int]$cfg.window.width
  $bh = [int]$cfg.window.height
  $vs = Get-DshVirtualScreen

  # 立绘都放在项目根的 images\ 目录（原图和成品图一个文件夹，方便替换素材）
  $imgDir = Join-Path $Context.Root 'images'
  # 优先 images/mascot.xaml 矢量，存在 mascot.png / mascot.gif 时后者优先
  $mascotPng = Join-Path $imgDir 'mascot.png'
  $mascotGif = Join-Path $imgDir 'mascot.gif'
  $patPng = Join-Path $imgDir 'mascot-pat.png'
  $useCustom = $false
  $customPath = $null
  if ($s.useCustomSprite) {
    if (Test-Path $mascotGif) { $customPath = $mascotGif; $useCustom = $true }
    elseif (Test-Path $mascotPng) { $customPath = $mascotPng; $useCustom = $true }
  }

  $mascotXml = [IO.File]::ReadAllText((Join-Path $imgDir 'mascot.xaml'), [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
  $mascot = [System.Windows.Markup.XamlReader]::Parse($mascotXml)
  $mascot.Width = 200
  $mascot.Height = 210

  $shell = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" Width="$bw" Height="$bh" Left="0" Top="0">
  <Canvas x:Name="Stage" Width="$bw" Height="$bh" Background="Transparent">

    <Canvas x:Name="Holder" Width="200" Height="210" Canvas.Left="40" Canvas.Top="6"
            RenderTransformOrigin="0.5,0.94" Background="Transparent">
      <Canvas.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="Breathe" ScaleX="1" ScaleY="1"/>
          <ScaleTransform x:Name="HoldScale" ScaleX="1" ScaleY="1"/>
          <TranslateTransform x:Name="HoldShift" X="0" Y="0"/>
          <ScaleTransform x:Name="ChewScale" ScaleX="1" ScaleY="1"/>
          <ScaleTransform x:Name="ChokeScale" ScaleX="1" ScaleY="1"/>
          <TranslateTransform x:Name="ChokeShake" X="0" Y="0"/>
          <ScaleTransform x:Name="PatScale" ScaleX="1" ScaleY="1"/>
          <RotateTransform x:Name="Sway" Angle="0"/>
          <TranslateTransform x:Name="Shake" X="0" Y="0"/>
        </TransformGroup>
      </Canvas.RenderTransform>
    </Canvas>


    <Border x:Name="ComboBadge" Canvas.Left="196" Canvas.Top="12" CornerRadius="12" Background="#F2FFC53D"
            Opacity="0" IsHitTestVisible="False">
      <TextBlock x:Name="ComboText" Text="×2" FontFamily="Microsoft YaHei UI" FontWeight="Black"
                 FontSize="15" Foreground="#4A3200"/>
    </Border>

    <Path x:Name="Sweat" Fill="#8ED0FF" Opacity="0" IsHitTestVisible="False"
          Data="M 238,54 C 250,70 254,81 245,88 C 235,95 224,86 227,73 Z"/>

    <Border x:Name="Bar" Canvas.Left="10" Canvas.Top="$($bh - 92)" Width="260" Height="82"
            CornerRadius="16" Background="#D9101519" BorderBrush="#38FFFFFF" BorderThickness="1" Padding="11,9,11,9">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="22"/>
          <RowDefinition Height="12"/>
          <RowDefinition Height="16"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse x:Name="StatusDot" Width="9" Height="9" Fill="#41E06B" Margin="0,0,7,0"/>
            <TextBlock Text="余额" FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="#AFC0D2" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="ValueText" Grid.Column="1" Text="CNY 78.92" TextAlignment="Right"
                     FontFamily="Microsoft YaHei UI" FontWeight="Bold" FontSize="17" Foreground="#FF7A4D" VerticalAlignment="Center"/>
        </Grid>

        <Border Grid.Row="1" Height="11" CornerRadius="6" Background="#2AFFFFFF" VerticalAlignment="Center">
          <Border x:Name="BarFill" Width="238" Height="11" CornerRadius="6" HorizontalAlignment="Left"
                  RenderTransformOrigin="0,0.5">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#7BF79B" Offset="0"/>
                <GradientStop Color="#1FBF57" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <Border.RenderTransform>
              <ScaleTransform x:Name="BarScale" ScaleX="1" ScaleY="1"/>
            </Border.RenderTransform>
          </Border>
        </Border>

        <TextBlock x:Name="InfoText" Grid.Row="2" Text="已烧 ¥0.0000 · 命中 0" FontFamily="Microsoft YaHei UI"
                   FontSize="11" Foreground="#8FA3B8" VerticalAlignment="Bottom"/>
      </Grid>
    </Border>
  </Canvas>
</Window>
"@

  $win = New-DshWindowFromXaml -Xaml $shell -Tag 'dsh-whale-widget'
  $win.ShowInTaskbar = $false
  $win.ShowActivated = $false
  $win.Topmost = $true

  $stage = $win.FindName('Stage')
  $holder = $win.FindName('Holder')
  if ($useCustom) {
    # 用真实立绘素材：铺满挂件上半区，保留呼吸/摇摆/受击抖动
    $holder.Width = 220
    $holder.Height = 232
    [System.Windows.Controls.Canvas]::SetLeft($holder, 30)
    [System.Windows.Controls.Canvas]::SetTop($holder, 4)
    $img = New-Object System.Windows.Controls.Image
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.UriSource = New-Object System.Uri($customPath)
    $bi.EndInit()
    $bi.Freeze()
    $img.Source = $bi
    $img.Stretch = [System.Windows.Media.Stretch]::Uniform
    $img.Width = 220
    $img.Height = 232
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    [void]$holder.Children.Add($img)
    Write-DshLog ("挂件使用立绘素材：{0}" -f $customPath)
    # 摸头时临时换成的开心立绘（有就用，没有就算了）
    $script:PetImageElement = $img
    $script:PetImageNormal = $bi
    $script:MascotImages = @{ normal = $bi }
    function Load-OneSprite {
      param([string]$Key, [string]$File)
      if (-not (Test-Path -LiteralPath $File)) { return }
      $b = New-Object System.Windows.Media.Imaging.BitmapImage
      $b.BeginInit()
      $b.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $b.UriSource = New-Object System.Uri($File)
      $b.EndInit()
      $b.Freeze()
      $script:MascotImages[$Key] = $b
    }
    Load-OneSprite 'pat'  $patPng
    Load-OneSprite 'eat1' (Join-Path $imgDir 'mascot-eat1.png')
    Load-OneSprite 'eat2' (Join-Path $imgDir 'mascot-eat2.png')
    Load-OneSprite 'eat3' (Join-Path $imgDir 'mascot-eat3.png')
    Load-OneSprite 'choke1' (Join-Path $imgDir 'mascot-choke1.png')
    Load-OneSprite 'choke2' (Join-Path $imgDir 'mascot-choke2.png')
    Load-OneSprite 'warn'   (Join-Path $imgDir 'mascot-warn.png')
    Load-OneSprite 'danger' (Join-Path $imgDir 'mascot-danger.png')
    Load-OneSprite 'shake'  (Join-Path $imgDir 'mascot-shake.png')
    # 两维变体：mascot-<动作>-<状态>.png —— 有就加载，没画就自动退回常态版（见 Get-WhaleSpriteKey）
    foreach ($act in @('pat', 'eat1', 'eat2', 'eat3', 'choke1', 'choke2', 'drag1', 'drag2')) {
      foreach ($st in @('warn', 'danger')) {
        Load-OneSprite ('{0}-{1}' -f $act, $st) (Join-Path $imgDir ('mascot-{0}-{1}.png' -f $act, $st))
      }
    }
    $script:PatImageSource = $script:MascotImages['pat']
    $script:CurrentMascotKey = 'normal'
    $loaded = ($script:MascotImages.Keys | Sort-Object) -join ','
    Write-DshLog ("立绘帧已加载：{0}" -f $loaded)
  } else {
    [void]$holder.Children.Add($mascot)
  }

  $pos = Read-PositionFile (Join-Path $DshDir 'position.json')
  $pri = Get-DshPrimaryScreen
  if ($pos) { $win.Left = $pos.Left; $win.Top = $pos.Top }
  else {
    # 默认放「主显示器」右下角，而不是整个虚拟屏右下角（避免跑到副屏/没在看的屏幕上）
    $win.Left = $pri.Left + $pri.Width - $bw - [int]$cfg.window.marginX
    $win.Top = $pri.Top + $pri.Height - $bh - [int]$cfg.window.marginY
  }
  if ($pos -and $pos.Scale -and [double]$pos.Scale -ne 1.0) {
    $win.Width = [Math]::Round($bw * [double]$pos.Scale)
    $win.Height = [Math]::Round($bh * [double]$pos.Scale)
    # 关键：position.json 里存的 left/top 就是「上一次退出时窗口真实的位置」，
    # 它已经是缩放后的坐标了。这里再按 (新高度 - 基准高度) 挪一次 Top，
    # 等于把缩放偏移算了两遍 —— 每次重启挂件都会往下漂 67px，
    # 漂到任务栏上就把整个托盘图标盖住（用户看到的"托盘消失"就是这个）。
    # 所以缩放只改窗口尺寸，不动位置。
  }

  # 防"盖任务栏"：挂件底边绝不能压到工作区底边（任务栏顶），否则托盘图标被整块盖死
  $waBottom = 0.0
  try { $waBottom = [double][System.Windows.SystemParameters]::WorkArea.Bottom } catch {}
  if ($waBottom -gt 100 -and $win.Height -gt 20) {
    $maxTop = $waBottom - [double]$win.Height
    if ($win.Top -gt $maxTop) {
      Write-DshLog ('挂件位置压到任务栏，已上移贴住工作区底边（Top {0:F0} -> {1:F0}）' -f [double]$win.Top, $maxTop)
      $win.Top = $maxTop
    }
  }

  # 防"屏外"：位置跑到了已拔掉的显示器上（虚拟屏坐标外），就拉回右下角
  $outX = ($win.Left + 40 -lt $vs.Left) -or ($win.Left + $win.Width - 40 -gt $vs.Left + $vs.Width)
  $outY = ($win.Top + 40 -lt $vs.Top) -or ($win.Top + $win.Height - 40 -gt $vs.Top + $vs.Height)
  if ($outX -or $outY) {
    $win.Left = $pri.Left + $pri.Width - $bw - [int]$cfg.window.marginX
    $win.Top = $pri.Top + $pri.Height - $bh - [int]$cfg.window.marginY
    Write-DshLog '挂件上次位置在屏幕外，已拉回主屏右下角'
  }

  $script:WhaleHolderRef = $holder
  $glow = $null
  if ($s.glow) {
    $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $glow.Color = (New-DshBrush $s.glowColor).Color
    $glow.BlurRadius = [double]$s.glowBlur
    $glow.ShadowDepth = 0
    $glow.Opacity = 0.55
    $holder.Effect = $glow
    $script:WhaleGlowRef = $glow
  }

  $script:Whale = [pscustomobject]@{
    Config     = $cfg
    Settings   = $s
    Window     = $win
    Stage      = $stage
    Holder     = $holder
    Mascot     = $mascot
    EyesScale  = $mascot.FindName('EyesScale')
    Sweat      = $mascot.FindName('Sweat')
    Breathe    = $win.FindName('Breathe')
    HoldScale  = $win.FindName('HoldScale')
    HoldShift  = $win.FindName('HoldShift')
    ChewScale  = $win.FindName('ChewScale')
    ChokeScale = $win.FindName('ChokeScale')
    ChokeShake = $win.FindName('ChokeShake')
    PatScale   = $win.FindName('PatScale')
    Sway       = $win.FindName('Sway')
    Shake      = $win.FindName('Shake')
    Bubble     = $win.FindName('Bubble')
    Bar        = $win.FindName('Bar')
    BarScale   = $win.FindName('BarScale')
    BarFill    = $win.FindName('BarFill')
    StatusDot  = $win.FindName('StatusDot')
    ValueText  = $win.FindName('ValueText')
    InfoText   = $win.FindName('InfoText')
    ComboBadge = $win.FindName('ComboBadge')
    ComboText  = $win.FindName('ComboText')
    Anims      = (New-Object System.Collections.ArrayList)
    NextBlink  = (Get-Date).AddSeconds(3)
    Ratio      = 1.0
    PosFile    = (Join-Path $DshDir 'position.json')
    Dragging   = $false
    MenuOpen   = $false
    HoldDrag   = $false      # 左键按住中（手动拖拽，不用 DragMove）
    HoldLong   = $false      # 按住超过 holdMs → 进入「拎起」阶段（等图）
    DragMoved  = $false      # 本次按住期间移动过 → 判定拖拽而不是摸头
    PressAt    = [DateTime]::MinValue
    DragStartX = 0.0
    DragStartY = 0.0
    LastScreenX = 0.0
    LastScreenY = 0.0
    DragHasLast = $false
    UseCustom  = $useCustom
    CustomPath = $customPath
    LastHit    = 0.0
    LastHitMs  = 240.0
    ComboAt    = 0.0
    FlashPeak  = 0.30
    Scale      = 1.0
    BubbleUntil = [DateTime]::MinValue
    LastBubble = [DateTime]::MinValue
    NextIdleAt = (Get-Date).AddSeconds((Get-Random -Minimum 25 -Maximum 70))
    PatCount   = 0
    BubbleShown = $false
    LastBalance = 0.0
    LastSpentCny = 0.0    # 底部信息行缓存：摸头时要立刻重刷「已烧」，不能等下一发命中/余额轮询
    LastHits     = 0      # 同上：缓存的命中数
    LastCombo   = 0
    PatStreak   = 0
    PatLastAt   = [DateTime]::MinValue
    PatTotal    = 0
    PatImageUntil = [DateTime]::MinValue
    StateFile   = (Join-Path $DshDir 'state.json')
    EatMode     = 'idle'          # idle / eat / done
    EatFrame    = 0
    MealHits    = 0               # 这「一顿饭」来了几发命中（决定要不要打嗝）
    LastHitAt   = [DateTime]::MinValue
    LastChewAt  = [DateTime]::MinValue
    NextChewAt  = [DateTime]::MinValue
    DoneUntil   = [DateTime]::MinValue
    LastNumberAt = [DateTime]::MinValue   # 最近一次「冒出伤害数字」的时刻（命中/未命中/免费回合都算）
    PendingBubble = $null                  # 数字还在刷时，台词先在这儿排队
    PendingAt   = [DateTime]::MinValue
    ChokeAt     = [DateTime]::MinValue     # 呛到：整段演出的起点（MinValue = 没在演）
    ChokeStep   = 0                        # 0 无 / 1 噎住抖 / 2 停顿 / 3 咳出来
    ChokeReason = ''
    ChokeCool   = @{}                      # 每个原因各自的冷却时间点（断网 / 余额见底 互不干扰）
    ForceMood   = ''             # 预览用：强制显示某个状态（余额状态用已有的 Ratio 字段）
    ForceMoodUntil = [DateTime]::MinValue
    GrabDX      = 0.0        # 按下时"光标 - 窗口左上角"的偏移，拖动全程保持不变（修：抓取点会漂）
    GrabDY      = 0.0
    DragMs     = 0.0         # 本次按住里「真的在动」累计了多少毫秒（停下来不累计，所以松手前还能再攒一次）
    LastMoveAt = [DateTime]::MinValue   # 最后一次收到 MouseMove 的时刻
    ShakeUntil  = [DateTime]::MinValue   # 快速拖动「慌张」动画演到什么时候
    ShakeCool   = [DateTime]::MinValue   # 上一次触发的冷却点
  }
  $script:PreviewOn = [bool]$Context.Preview
  $script:PreviewMs = 0.0
  $script:DebugBubble = $false
  try { if ($s.debugBubble) { $script:DebugBubble = [bool]$s.debugBubble } } catch {}
  $script:DebugMascot = $false
  try { if ($s.debugMascot) { $script:DebugMascot = [bool]$s.debugMascot } } catch {}

  # 余额条：默认显示；plugin.json 的 showBar=false 时启动即隐藏
  $script:Whale | Add-Member -NotePropertyName ShowBar -NotePropertyValue $true -Force
  try {
    if ($null -ne $s.showBar) { $script:Whale.ShowBar = [bool]$s.showBar }
    if (-not $script:Whale.ShowBar) {
      $script:Whale.Bar.Visibility = [System.Windows.Visibility]::Collapsed
      Write-DshLog '余额条 -> 隐藏（配置 showBar=false）'
    }
  } catch { }

  if ($pos -and $pos.Scale -and [double]$pos.Scale -ne 1.0) {
    $stage.LayoutTransform = New-Object System.Windows.Media.ScaleTransform([double]$pos.Scale, [double]$pos.Scale)
    $script:Whale.Scale = [double]$pos.Scale
  }
  # 桌宠模式（伤害层被收起）时，起来打个招呼
  if ($Context.OverlayVisible -eq $false) { $script:Whale.NextIdleAt = (Get-Date).AddSeconds(2) }

  Start-WhaleIdleAnimations -W $script:Whale

  # 连击徽章用的缩放对象
  $comboScale = New-Object System.Windows.Media.ScaleTransform(1.0, 1.0)
  $script:Whale.ComboBadge.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
  $script:Whale.ComboBadge.RenderTransform = $comboScale
  $script:Whale | Add-Member -NotePropertyName ComboScale -NotePropertyValue $comboScale -Force

  # 摸头计数（持久化到 plugins\dsh-whale-widget\state.json）
  try {
    $st = Read-DshJson (Join-Path $DshDir 'state.json')
    if ($st -and $st.patTotal -ne $null) { $script:Whale.PatTotal = [int]$st.patTotal }
  } catch {}

  # 拖拽 + 右键菜单
  $whaleRef = $script:Whale
  $dbgMascot = $script:DebugMascot   # 闭包里有独立的 script 作用域，$script: 变量取不到，先抓成普通变量
  $stageRef = $stage

  # 按下：立刻「鼓一圈」——横向多一点、纵向少一点，锚点在脚底，所以不会被挂件窗口裁掉
  $dragDown = {
    param($sender, $e)
    $W = $whaleRef
    if (-not $W) { return }
    # 菜单 / 呛到：按下完全不响应（这时是"别人在演"，别插嘴）
    $layer = Get-WhaleLayer -Context $Context
    if ($layer -eq 'menu' -or $layer -eq 'choke') {
      if ($dbgMascot) { Write-DshLog ('[mascot] 按下被忽略（当前层 {0}）' -f $layer) }
      return
    }
    # 吃饭：按一下就让这顿提前结束（点一下 = 摸头，不用等 2.2 秒吃完）
    if ($layer -eq 'eat') {
      $W.EatMode = 'idle'
      $W.MealHits = 0
      $W.NextChewAt = [DateTime]::MinValue
      Write-DshLog '[mascot] 按下强制结束吃饭动画'
    }
    $W.HoldDrag = $true
    $W.HoldLong = $false
    $W.DragMoved = $false
    $W.DragHasLast = $false
    $W.PressAt = Get-Date
    $W.DragStartX = [double]$W.Window.Left
    $W.DragStartY = [double]$W.Window.Top
    $W.DragMs = 0.0
    $W.LastMoveAt = Get-Date
    # 抓取点：光标相对窗口左上角的偏移，整个拖动过程都不变
    $cur0 = $null
    try { $cur0 = Get-WhaleCursorDip -W $W } catch { Write-DshLog ('[mascot] 取光标失败：' + $_.Exception.Message) }
    if ($cur0) {
      # 按住就取消「慌张」：人家都被你抓住了，别再演"我在飞"
    if ($W.ShakeUntil -ne [DateTime]::MinValue) { $W.ShakeUntil = [DateTime]::MinValue }
    $W.GrabDX = $cur0[0] - [double]$W.Window.Left
      $W.GrabDY = $cur0[1] - [double]$W.Window.Top
    } else {
      $gp = $e.GetPosition($W.Window)
      $W.GrabDX = [double]$gp.X
      $W.GrabDY = [double]$gp.Y
    }
    try { Apply-HoldScale -On $true } catch { Write-DshLog ('[mascot] 鼓一圈失败：' + $_.Exception.Message) }
    if ($dbgMascot) { Write-DshLog ('[mascot] 左键按下：鼓一圈（抓取点 {0:F0},{1:F0}，窗口 {2:F0},{3:F0}）' -f $W.GrabDX, $W.GrabDY, $W.Window.Left, $W.Window.Top) }
    # 手动拖拽必须抓住鼠标，否则快速拖动时鼠标跑出窗口就收不到 MouseMove / MouseUp
    try { [void]$stageRef.CaptureMouse() } catch {}
  }.GetNewClosure()

  # 移动：跟手移动窗口。必须用 PointToScreen 的屏幕位移——直接用窗口内坐标会因为窗口跟着动而算成 0
  # 移动：按「光标 - 抓取偏移」绝对定位。绝对定位不会累积误差，
  # 窗口被系统夹在屏幕边缘再拖回来时也不会突然跳一大截。
  $dragMove = {
    param($sender, $e)
    $W = $whaleRef
    if (-not $W -or -not $W.HoldDrag) { return }
    $nowMv = Get-Date
    $W.LastMoveAt = $nowMv
    $cur = $null
    try { $cur = Get-WhaleCursorDip -W $W } catch { Write-DshLog ('[mascot] 拖动取光标失败：' + $_.Exception.Message) }
    if ($cur) {
      $newLeft = $cur[0] - $W.GrabDX
      $newTop = $cur[1] - $W.GrabDY

    } else {
      # 拿不到光标就退回位移算法（老路子，至少能动）
      $pScr = $W.Window.PointToScreen($e.GetPosition($W.Window))
      if (-not $W.DragHasLast) { $W.LastScreenX = $pScr.X; $W.LastScreenY = $pScr.Y; $W.DragHasLast = $true; return }
      $newLeft = [double]$W.Window.Left + ($pScr.X - $W.LastScreenX)
      $newTop = [double]$W.Window.Top + ($pScr.Y - $W.LastScreenY)
      $W.LastScreenX = $pScr.X; $W.LastScreenY = $pScr.Y
    }
    # 边界夹取：至少留六成在屏幕里。
    # 没有这道夹取时能把挂件整只拖出屏幕（只剩托盘「找回挂件」能救），而且贴左边时
    # 伤害数字会跟着跑到屏幕外，看起来像"数字不见了"。
    try {
      $scrW = [double][System.Windows.SystemParameters]::VirtualScreenWidth
      $scrH = [double][System.Windows.SystemParameters]::VirtualScreenHeight
      $scrL = [double][System.Windows.SystemParameters]::VirtualScreenLeft
      $scrT = [double][System.Windows.SystemParameters]::VirtualScreenTop
      $ww = [double]$W.Window.ActualWidth
      if ($ww -lt 20) { $ww = [double]$W.Window.Width }
      $wh = [double]$W.Window.ActualHeight
      if ($wh -lt 20) { $wh = [double]$W.Window.Height }
      $minL = $scrL - ($ww * 0.4)
      $maxL = $scrL + $scrW - ($ww * 0.6)
      $minT = $scrT - ($wh * 0.4)
      $maxT = $scrT + $scrH - ($wh * 0.6)
      # 不许拖到任务栏上：底边一过工作区底边，任务栏和托盘图标就被整块盖住
      try {
        $waB = [double][System.Windows.SystemParameters]::WorkArea.Bottom
        if ($waB -gt 100 -and ($waB - $wh) -lt $maxT) { $maxT = $waB - $wh }
      } catch {}
      if ($maxL -lt $minL) { $maxL = $minL }
      if ($maxT -lt $minT) { $maxT = $minT }
      $newLeft = [Math]::Max($minL, [Math]::Min($maxL, $newLeft))
      $newTop = [Math]::Max($minT, [Math]::Min($maxT, $newTop))
    } catch { }

    if ([Math]::Abs($newLeft - [double]$W.Window.Left) -lt 0.01 -and [Math]::Abs($newTop - [double]$W.Window.Top) -lt 0.01) { return }
    $W.Window.Left = $newLeft
    $W.Window.Top = $newTop
    if ([Math]::Abs([double]$W.Window.Left - $W.DragStartX) -ge 2 -or [Math]::Abs([double]$W.Window.Top - $W.DragStartY) -ge 2) {
      if (-not $W.DragMoved) {
        $W.Dragging = $true
        if ($dbgMascot) { Write-DshLog '[mascot] 判定为拖拽（位置跟手）' }
      }
      $W.DragMoved = $true
    }
  }.GetNewClosure()

  # 松手：没移动过 = 摸头；移动过 = 存位置
  $dragUp = {
    param($sender, $e)
    $W = $whaleRef
    if (-not $W -or -not $W.HoldDrag) { return }
    $heldMs = ((Get-Date) - $W.PressAt).TotalMilliseconds
    $W.HoldDrag = $false
    $W.HoldLong = $false
    try { $stageRef.ReleaseMouseCapture() } catch {}
    Apply-HoldScale -On $false
    if ($W.DragMoved) {
      Write-DshPosition
      if ($dbgMascot) { Write-DshLog ('[mascot] 松手：拖拽结束（按住 {0:F0}ms）' -f $heldMs) }
    } else {
      if ($dbgMascot) { Write-DshLog ('[mascot] 松手：判定摸头（按住 {0:F0}ms）' -f $heldMs) }
      # 摸头可以强制结束「吃饭」：点一下就打断这顿（不然得等 2.2 秒吃完才摸得到）
      if ($W.EatMode -ne 'idle') {
        $W.EatMode = 'idle'
        $W.MealHits = 0
        $W.NextChewAt = [DateTime]::MinValue
        Write-DshLog '[mascot] 摸头强制结束吃饭动画'
      }
      Invoke-WhalePat -Context $Context
    }
    $W.DragMoved = $false
    $W.Dragging = $false
    # 手指一松就回常态：慌张只在「正在甩」的时候存在，停下来还挂着就很别扭
    if ($W.ShakeUntil -ne [DateTime]::MinValue) { $W.ShakeUntil = [DateTime]::MinValue }
  }.GetNewClosure()
  $stage.Add_MouseLeftButtonDown($dragDown)
  $stage.Add_MouseMove($dragMove)
  $stage.Add_MouseLeftButtonUp($dragUp)

  # 右键菜单：深色半透明圆角 + 悬停高亮 + 每项一个彩色圆点图标（图标列留好了，以后换成素材图就是一行）
  $menuXaml = @"
<ContextMenu xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             SnapsToDevicePixels="True" UseLayoutRounding="True">
  <ContextMenu.Resources>
    <Style TargetType="{x:Type Separator}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Separator}">
            <Border Height="1" Background="#1FFFFFFF" Margin="12,6,12,6"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="{x:Type MenuItem}">
      <Setter Property="Foreground" Value="#E6EEF7"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type MenuItem}">
            <Grid>
              <Border x:Name="Bg" CornerRadius="9" Background="Transparent" Margin="2,1,2,1" Padding="9,6,9,6">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="20"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <ContentPresenter Grid.Column="0" ContentSource="Icon" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                  <ContentPresenter Grid.Column="1" ContentSource="Header" VerticalAlignment="Center" Margin="2,0,12,0"/>
                  <Path x:Name="Arrow" Grid.Column="2" Data="M0,0 L4,4 L0,8" Stroke="#7E93A8" StrokeThickness="1.4"
                        VerticalAlignment="Center" Visibility="Collapsed"/>
                </Grid>
              </Border>
              <Popup x:Name="PART_Popup" AllowsTransparency="True" Placement="Right" VerticalOffset="-8"
                     IsOpen="{TemplateBinding IsSubmenuOpen}" Focusable="False" PopupAnimation="Fade">
                <Border CornerRadius="13" Background="#F2141A21" BorderBrush="#3AFFFFFF" BorderThickness="1"
                        Padding="6" Margin="8,0,12,12">
                  <Border.Effect>
                    <DropShadowEffect BlurRadius="20" Opacity="0.55" ShadowDepth="4" Color="#000000"/>
                  </Border.Effect>
                  <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="HasItems" Value="True">
                <Setter TargetName="Arrow" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="#2E5AC8FF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#70808F9F"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </ContextMenu.Resources>
  <ContextMenu.Template>
    <ControlTemplate TargetType="{x:Type ContextMenu}">
      <Border x:Name="Root" CornerRadius="15" Background="#F2141A21" BorderBrush="#3AFFFFFF" BorderThickness="1"
              Padding="6" RenderTransformOrigin="0.5,0">
        <Border.RenderTransform>
          <ScaleTransform ScaleX="1" ScaleY="1"/>
        </Border.RenderTransform>
        <Border.Effect>
          <DropShadowEffect BlurRadius="22" Opacity="0.6" ShadowDepth="5" Color="#000000"/>
        </Border.Effect>
        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
      </Border>
      <ControlTemplate.Triggers>
        <!-- 展开时淡入 + 从顶部轻微展开（不写静态 Opacity/Scale，万一动画没跑也不会变成看不见） -->
        <EventTrigger RoutedEvent="Loaded">
          <BeginStoryboard>
            <Storyboard>
              <DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="Opacity"
                               From="0" To="1" Duration="0:0:0.12"/>
              <DoubleAnimation Storyboard.TargetName="Root"
                               Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                               From="0.94" To="1" Duration="0:0:0.16"/>
            </Storyboard>
          </BeginStoryboard>
        </EventTrigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </ContextMenu.Template>
</ContextMenu>
"@
  $menu = $null
  try { $menu = [System.Windows.Markup.XamlReader]::Parse($menuXaml) } catch {
    Write-DshLog ('菜单皮肤加载失败，退回默认菜单：{0}' -f $_.Exception.Message) 'error'
  }
  if (-not $menu) { $menu = New-Object System.Windows.Controls.ContextMenu }
  else { Write-DshLog '菜单皮肤已加载：深色半透明圆角 + 悬停高亮 + 彩色圆点图标' }
  $miReset = New-Object System.Windows.Controls.MenuItem
  $miReset.Header = '重置余额'
  $miReset.Add_Click({ Send-DshBus -Bus $Context.Bus -Object @{ t = 'reset' } | Out-Null }.GetNewClosure())
  $miApi = New-Object System.Windows.Controls.MenuItem
  $miApi.Header = '填写 DeepSeek API'
  $miApi.Add_Click({ Prompt-ApiKey -Context $Context }.GetNewClosure())
  $miOverlay = New-Object System.Windows.Controls.MenuItem
  $miOverlay.Header = '伤害数字 开/关'
  $miOverlay.Add_Click({ Toggle-DamageOverlay -Context $Context }.GetNewClosure())
  $miScale = New-Object System.Windows.Controls.MenuItem
  $miScale.Header = '挂件大小'
  # 当前档位要打勾，所以把每个子项和它对应的数值一起记下来（勾在菜单打开时重算，见 Update-WhaleMenuChecks）
  $scaleMenuItems = New-Object System.Collections.ArrayList
  foreach ($sv in @(0.8, 1.0, 1.25, 1.5)) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = ('{0:P0}' -f $sv)
    $svLocal = $sv
    $mi.Add_Click({ Set-WhaleScale -Context $Context -Scale $svLocal }.GetNewClosure())
    [void]$miScale.Items.Add($mi)
    [void]$scaleMenuItems.Add([pscustomobject]@{ Item = $mi; Value = [double]$sv })
  }
  $miTop = New-Object System.Windows.Controls.MenuItem
  $miTop.Header = '切换置顶'
  $miTop.Add_Click({
    $wr = $whaleRef
    $wr.Window.Topmost = -not $wr.Window.Topmost
  }.GetNewClosure())
  $miChoke = New-Object System.Windows.Controls.MenuItem
  $miChoke.Header = '预览呛到（吃完打嗝变呛到的那种）'
  $miChoke.Add_Click({
    # 先打 4 发假数据（她开始吃）→ 停下来 → 再触发呛到，跟真断网/没钱的节奏一致
    Start-Process -FilePath 'node' -ArgumentList ('"{0}" --burst 4 --gap 240 --choke-after' -f (Join-Path $Context.Root 'tools\demo.mjs')) -WindowStyle Hidden
  }.GetNewClosure())
  $miDemo = New-Object System.Windows.Controls.MenuItem
  $miDemo.Header = '打一场演示（假数据）'
  $miDemo.Add_Click({
Start-Process -FilePath 'node' -ArgumentList ('"{0}" --burst 18 --gap 150' -f (Join-Path $Context.Root 'tools\demo.mjs')) -WindowStyle Hidden
  }.GetNewClosure())
  $miMood = New-Object System.Windows.Controls.MenuItem
  $miMood.Header = '余额状态预览'
  # 同上：哪个预览在生效就在哪项前打勾（空串 = 「按真实余额」，也就是没在预览）
  $moodMenuItems = New-Object System.Collections.ArrayList
  foreach ($mv in @(@('绿 · 正常', 'normal'), @('黄 · 余额偏低', 'warn'), @('红 · 余额危险', 'danger'), @('按真实余额（取消预览）', ''))) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = [string]$mv[0]
    $mk = [string]$mv[1]
    # 注意：GetNewClosure() 出来的 scriptblock 有自己的 script 作用域，
    # 里面的 $script:Whale 取不到插件里的那个变量（永远是 $null，点了没反应）。
    # 所以先把对象抓成普通局部变量再进闭包——和「切换置顶」那条用 $whaleRef 是同一个道理。
    $whaleLocal = $script:Whale
    $mi.Add_Click({
      if (-not $whaleLocal) { return }
      if ($mk) { $whaleLocal.ForceMood = $mk; $whaleLocal.ForceMoodUntil = (Get-Date).AddSeconds(20); Write-DshLog ("余额状态预览 -> {0}（20 秒内可随手摸头看对应立绘，到点自动回真实状态）" -f $mk) }
      else { $whaleLocal.ForceMood = ''; $whaleLocal.ForceMoodUntil = [DateTime]::MinValue; Write-DshLog '余额状态预览 -> 关闭，按真实余额显示' }
    }.GetNewClosure())
    [void]$miMood.Items.Add($mi)
    [void]$moodMenuItems.Add([pscustomobject]@{ Item = $mi; Value = $mk })
  }
  $miQuit = New-Object System.Windows.Controls.MenuItem
  $miQuit.Header = '退出浮层'
  $miQuit.Add_Click({
    if ($Context.RequestStop) { & $Context.RequestStop }
    else {
      foreach ($rp in $Context.Plugins) { foreach ($ww in $rp.Windows) { try { $ww.Close() } catch {} } }
      [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
    }
  }.GetNewClosure())
  [void]$menu.Items.Add($miScale)
  [void]$menu.Items.Add($miReset)
  [void]$menu.Items.Add($miApi)
  [void]$menu.Items.Add($miDemo)
  [void]$menu.Items.Add($miChoke)
  [void]$menu.Items.Add($miMood)
  [void]$menu.Items.Add($miOverlay)
  [void]$menu.Items.Add($miTop)
  [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
  [void]$menu.Items.Add($miQuit)
  # 每项前面一个彩色小圆点当图标（模板里留了 20px 图标列）
  # 以后有素材了，把这里换成 Image 就行：$mi.Icon = <Image Source=.../>
  foreach ($pair in @(
      @($miScale, '#8FA3B8'), @($miReset, '#FF7A4D'), @($miApi, '#FFC53D'),
      @($miDemo, '#4FC3F7'), @($miChoke, '#FF7BE5'), @($miMood, '#41E06B'),
      @($miOverlay, '#8FA3B8'), @($miTop, '#8FA3B8'), @($miQuit, '#FF5A5A'))) {
    try {
      $dot = New-Object System.Windows.Shapes.Ellipse
      $dot.Width = 7; $dot.Height = 7
      $dot.Fill = New-DshBrush ([string]$pair[1])
      $pair[0].Icon = $dot
    } catch {}
  }
  $stage.ContextMenu = $menu
  # 菜单开关也是优先级信息：开着的时候最优先（冻住立绘、禁掉其他动作）
  # 注意用 $whaleRef（普通局部变量）而不是 $script:Whale——闭包里有独立 script 作用域，后者恒为 $null
  $menu.Add_Opened({
    if ($whaleRef) { $whaleRef.MenuOpen = $true }
    # 每次弹出都把勾重刷一遍：档位可能刚被托盘改过、20 秒预览也可能刚到期，下次打开必须是对的
    Update-WhaleMenuChecks -W $whaleRef -ScaleItems $scaleMenuItems -MoodItems $moodMenuItems
  }.GetNewClosure())
  $menu.Add_Closed({ if ($whaleRef) { $whaleRef.MenuOpen = $false } }.GetNewClosure())

  # 任务栏/Alt+Tab 的隐藏改由 host-lib 的 New-DshWindowFromXaml 在 SourceInitialized 统一处理
  # （此处 $win 的 HWND 还是 0，写在这里不生效）

  Write-DshLog ("鲸娘挂件已就绪：{0}x{1} @ {2},{3}" -f $bw, $bh, [int]$win.Left, [int]$win.Top)
  $th0 = Get-WhaleThresholds -Context $Context
  Write-DshLog ('余额阈值：满格 ¥{0:F2} · 黄 ≤ ¥{1:F2}（{2:P0}） · 红 ≤ ¥{3:F2}（{4:P0}）' -f $th0.Cap, $th0.WarnCny, $th0.WarnPct, $th0.DangerCny, $th0.DangerPct)
}

function Write-DshPosition {
  $W = $script:Whale
  if (-not $W) { return }
  try { Write-DshJson @{ left = [int]$W.Window.Left; top = [int]$W.Window.Top; scale = [Math]::Round([double]$W.Scale, 3) } $W.PosFile } catch {}
}

function Apply-HoldScale {
  # 按住左键时的「鼓一圈」：横向多、纵向少，同时整体往下挪几像素。
  # 为什么不做等比放大：挂件窗口 280x336，立绘 220x232 且内容几乎贴边（呆毛离窗口顶只有 9px），
  # 等比放大 6% 纵向就把呆毛顶出窗口裁掉了；横向左右还有 30px 余量，所以先吃横向，
  # 纵向只放大 3%（≈上移 6.4px）再往下补 3px，净上移 3.4px → 呆毛始终不贴边。
  param([bool]$On)
  $W = $script:Whale
  if (-not $W -or -not $W.HoldScale) { return }
  $hx = 1.0; $hy = 1.0; $sh = 0.0
  if ($On) {
    $hx = 1.09; $hy = 1.03; $sh = 3.0
    try { if ([double]$W.Settings.holdScaleX -gt 0) { $hx = [double]$W.Settings.holdScaleX } } catch {}
    try { if ([double]$W.Settings.holdScaleY -gt 0) { $hy = [double]$W.Settings.holdScaleY } } catch {}
    try { if ($null -ne $W.Settings.holdShiftY) { $sh = [double]$W.Settings.holdShiftY } } catch {}
  }
  if ($script:PreviewOn) {
    $W.HoldScale.ScaleX = $hx
    $W.HoldScale.ScaleY = $hy
    if ($W.HoldShift) { $W.HoldShift.Y = $sh }
    return
  }
  $ms = 140
  try { if ([int]$W.Settings.holdScaleMs -gt 0) { $ms = [int]$W.Settings.holdScaleMs } } catch {}
  try {
    $null = Start-DshAnim -Target $W.HoldScale -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) `
      -Animation (New-DshDoubleAnimation -From ([double]$W.HoldScale.ScaleX) -To $hx -Ms $ms -Ease Cubic)
    $null = Start-DshAnim -Target $W.HoldScale -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) `
      -Animation (New-DshDoubleAnimation -From ([double]$W.HoldScale.ScaleY) -To $hy -Ms $ms -Ease Cubic)
    if ($W.HoldShift) {
      $null = Start-DshAnim -Target $W.HoldShift -Property ([System.Windows.Media.TranslateTransform]::YProperty) `
        -Animation (New-DshDoubleAnimation -From ([double]$W.HoldShift.Y) -To $sh -Ms $ms -Ease Cubic)
    }
  } catch {}
}

# 台词「抽签袋」：把整个池子洗好后一张张抽，抽完再洗 —— 保证一轮内不重复
$script:LineBag = @{}

function Get-LineFromBag {
  param([string]$Key, $Pool)
  if (-not $Pool -or $Pool.Count -eq 0) { return '唔…' }
  $bag = $null
  if ($script:LineBag.ContainsKey($Key)) { $bag = $script:LineBag[$Key] }
  if (-not $bag -or $bag.Count -eq 0) {
    $bag = New-Object System.Collections.ArrayList
    $shuffled = @($Pool | Sort-Object { Get-Random })
    # 洗牌后第一张别跟上一次说的重样
    if ($shuffled.Count -gt 1 -and $shuffled[0] -eq $script:LastLine) { $shuffled = @($shuffled[1..($shuffled.Count - 1)]) + @($shuffled[0]) }
    foreach ($x in $shuffled) { [void]$bag.Add($x) }
    $script:LineBag[$Key] = $bag
  }
  $line = [string]$bag[0]
  $bag.RemoveAt(0)
  $script:LastLine = $line
  return $line
}

function Get-WhaleLine {
  param($Context, [string]$Kind = 'hit', [double]$Cost = 0, [int]$Count = 0, [string]$Reason = '')
  $W = $script:Whale
  $bal = 0.0
  try { $bal = [double]$W.LastBalance } catch {}
  $th = Get-WhaleThresholds -Context $Context
  $warn = [double]$th.WarnCny; $danger = [double]$th.DangerCny
  $hour = (Get-Date).Hour
  $pool = @()
  $bagKey = 'hit'

  switch ($Kind) {
    'patMilestone' {
      $c = if ($Count -gt 0) { $Count } else { 3 }
      $bagKey = 'patM' + $c
      $pool = switch ($c) {
        3  { @('（尾巴轻轻摇）', '第三下……唔。', '唔…继续也可以。', '第三下了，感觉不错。', '唔，我数着呢。', '（头顶往你手心凑了凑）', '三下，位置挺准。', '唔…开始有点舒服了。') }
        5  { @('五下！我记住了。', '（尾巴摇得飞快）', '好久没人这样摸我了。', '嘿嘿，五下了。', '五下，我心情满分。', '唔，第五下最舒服。', '五连摸，我开心地认输。', '（头顶已经习惯性凑过来了）') }
        10 { @('十下……我有点晕。', '十连摸，太幸福了。', '手指不累吗？我可以再被摸。', '十下，我今天是赢家。', '唔，已经十下了。', '（尾巴已经摇出节奏了）', '十下，手感越来越熟了。', '你手是真的稳。') }
        20 { @('×20，我尾巴要断了。', '二十下……我飘了。', '你手劲真好。', '×20，这是我今天的记录。', '二十下，我记住了。', '（头顶已经完全交给你了）', '唔，二十下也不腻。', '你是不是偷偷练过。') }
        50 { @('×50！我今天是全世界最幸福的鲸鱼。', '五十下……我记一辈子。', '手真的不酸吗…我心疼了。', '×50，你比账本重要。', '五十下，我要把今天刻下来。', '（尾巴摇不动了但还在摇）', '唔，五十下，值了。', '（嗓子都笑哑了）') }
        default { @(('×{0} 下……嘿嘿。' -f $c), ('已经被摸 {0} 下了，好开心。' -f $c), ('唔，{0} 下了。' -f $c), ('（第 {0} 下，头顶又凑过去了）' -f $c)) }
      }
    }

    'shake' {
      # 被甩来甩去的时候碎碎念（拖动速度超过阈值触发，见 Start-WhalePanic）
      $bagKey = 'shake'
      $pool = @(
        '慢、慢点——！', '晕了晕了晕了。', '别甩我！', '（被晃得说不出话）',
        '等一下，我要吐了。', '这、这是要飞起来吗。', '我头晕…', '（眼前全是星星）',
        '轻一点啊你这人。', '唔…桌子在转。', '我又不是陀螺。', '（手在空中乱抓）',
        '停、停下来——我要散架了。', '（双手一起乱挥）', '再甩我就哭了啊。',
        '(＠_＠;)', '(°◇°;)', '(ノД`)・゜・。', '(>_<)'
      )
    }

    'pat' {
      $streak = 0
      try { $streak = [int]$W.PatStreak } catch {}
      if ($streak -le 1) {
        $bagKey = 'pat1'
        $pool = @(
          '唔…？', '嗯？', '找我吗？', '是奖励吗？', '咦，摸上来了。', '唔…是我吗？',
          '（抬眼看你）', '怎么突然摸我。', '今天第一次被摸。', '（耳朵转了个方向）', '唔，来了。',
          '啊，是摸头。', '（尾巴立起来又放下）', '你手好轻。', '（眨了眨眼）', '我以为是键盘声。',
          '（主动把头低了低）', '唔，好突然。', '（小声）……嗯。', '我还以为你要说什么。',
          '（眼睛亮了一下）', '手怎么放上来了。', '唔，摸吧。', '我可是等了挺久的。', '（轻轻靠过去一点）',
          '唔，谢谢？', '（把头发往后拨了一下）', '你手是凉的，还是我脸热？', '（头顶往你手心凑了凑）',
          '唔…好，开始吧。', '你今天动手了。', '（尾巴尖抖了一下）', '唔，我在。',
          '（下巴抬起来了一点）', '（往你这边挪了半步）', '(*/ω＼*)', '(๑•́ ₃ •̀๑)'
        )
      } elseif ($streak -le 4) {
        $bagKey = 'pat2'
        $pool = @(
          '唔…好舒服。', '再摸一下也可以。', '我脸有点热。', '你今天好温柔。', '别停。',
          '被摸头还挺开心的。', '唔……嗯。', '再摸我不介意的。', '你摸得很有节奏。', '唔，手感不错吧。',
          '（头顶蹭了蹭你的手）', '嗯…舒服。', '我头发很好摸的。', '手别急着拿开。', '唔，再多一下。',
          '（尾巴慢慢摇了两下）', '我心情变好了。', '摸头真的能加心情。', '唔…你继续。', '我今天的运气不错。',
          '别害羞，摸吧。', '这样我会更想记账的。', '手感是不是很好。', '我已经开始期待下一次了。',
          '你的手比键盘温暖多了。', '挠着挠着就想睡了。', '（靠得更近了一点）', '唔，我头发软吧。',
          '再摸两下刚好。', '我记你一功。', '（把耳朵往你手边送了送）', '唔，这下的位置刚好。',
          '你今天手劲很稳。', '（头顶轻轻顶了顶）', '别客气，多摸几下。', '唔…我又不咬人。',
          '这样我会以为你很闲。', '（尾巴打出节拍了）', '摸吧，我不收费。', '唔…嗯，好的。', '(๑>◡<๑)'
        )
      } else {
        $bagKey = 'pat3'
        $pool = @(
          '摸了好多下……', '我尾巴都摇酸了。', '再摸一会儿也行。', '我已经不记得余额了。',
          '你手真暖。', '今天是我的好日子。', '摸吧摸吧，摸多久都行。', '摸头果然是免费的快乐。',
          '我快变成一只幸福的鲸鱼了。', '手不用停。', '唔…我要记住这个手感。', '摸头使我工作效率上升。',
          '（尾巴摇成了螺旋桨）', '我今天的头归你。', '（已经开始哼歌了）', '唔…幸福。',
          '再多摸一会儿，我不困了。', '我感觉余额都不重要了。', '（软趴趴地靠过来）',
          '手真的不酸吗，我有点担心。', '你是不是也上瘾了。', '这一波我很满足。', '我决定今天心情很好。',
          '摸头是合法的快乐。', '唔…继续，不要停。', '今天可以摸到明天。', '（头顶已经习惯你的手了）',
          '我准备在这儿趴一天。', '唔…要不要给你开个摸头会员卡。', '摸到我忘记记账了。',
          '（尾巴打起了拍子）', '你今天是我的专属饲养员。', '唔，我头发都要被你摸顺了。',
          '再摸下去我要睡着了。', '我现在只想被摸，不想看余额。', '(*´▽*)', '(๑´ω๑)'
        )
      }
      if ((Get-Random -Minimum 0 -Maximum 5) -eq 0) {
        $bal = 0.0
        try { $bal = [double]$W.LastBalance } catch {}
        if ($bal -gt 0) { $pool += ('余额还剩 ¥{0:F2}。' -f $bal) }
        $pool += ('已经摸了我 {0} 次了。' -f ([int]$W.PatTotal))
      }
    }

    'miss' {
      $bagKey = 'miss'
      # 未命中和「呛到」共用一套反应：本质都是「这一口没咽下去」，
      # 所以这里不再放钱包相关的埋怨（钱的事交给 hit_* / crit 池）。
      $pool = @(
        '刚才有一笔没打出来…', '唔，这一笔没打中。', '别急，漏的我记本上了。',
        '这个算未命中，不算你输。', '系统打了个嗝，我补记一下。',
        '我盯着呢，漏不了。', '灰色那行就是没打中的。', '有一笔漏网之鱼。',
        '这笔没抓到，我记上了。', '（翻小本本）', '别慌，漏的我都记着。',
        '咳——这一笔卡在半道上。', '唔…咳，这口咽回去了。', '（清了清嗓子）漏一笔，我补上。',
        '嗐，噎住了一下。', '（捶了下胸口）没事，记下来了。',
        '(´д`)', '( °Д°)', '(;´Д`)'
      )
      if ($Count -gt 1) { $pool += ('刚才一口气漏了 {0} 笔…' -f $Count) }
    }

    'crit' {
      $bagKey = 'crit'
      $pool = @(
        '这一下好疼！', '暴击…我的钱包。', '大手笔啊。', '唔！',
        '心在滴血…', '你这一下够我吃三天。', '别这样，我会哭的。',
        '好家伙，直接大出血。', '我听到了钱包的惨叫。', '够狠。',
        '（捂胸口）', '这波我记大过一次。', '屏幕都震了一下。',
        '这一笔够我记账记半天。', '你手滑点了个大的？', '我缓缓…',
        '（手抖着写账本）', '(´；ω；`)', '(>_<)', '(ﾟДﾟ;)'
      )
    }

    'burp' {
      # 吃饱打嗝那一刻才冒的台词（原来吃第一口就说话，太抢戏）
      $bagKey = 'burp'
      $pool = @(
        '唔…吃饱了。', '（打嗝）嗝——', '这一顿吃得挺香。', '嗝…记账去了。',
        '饱了饱了，别再喂了。', '（摸着肚子）刚刚那几笔挺大。', '嗝。钱包也是空的。',
        '吃完了，消化一下。', '唔，这顿有点撑。', '（拍胸口）顺一下。',
        '嗝——这顿真香。', '（眯着眼睛回味）', '(´ω｀)', '(・ω・)'
      )
    }

    'choke' {
      # 呛到：触发概率低（断网 / 余额见底），每个原因两三句就够。
      # ⚠️ 这池子是按"先跑通动画"写的占位词，台词回炉那一轮要重写。
      if ($Reason -eq 'offline') {
        $bagKey = 'choke_off'
        $pool = @(
          '咳、咳咳——网断了，别有压力。', '刚才那一口卡在半道上。', '（拍着胸口顺气）稍等。',
          '这一下噎得比扣钱还难受。', '（咳得说不出话，指了指网线）', '( °Д°)', '(；￣Д￣)'
        )
      } elseif ($Reason -eq 'burp') {
        # 吃太饱，打嗝变呛到（吃饱收尾有 25% 概率走这条）
        $bagKey = 'choke_burp'
        $pool = @(
          '咳、咳咳——吃得急了。', '嗝…咳！呛到了。', '（拍胸口）这口没咽下去。',
          '唔…咳，差点噎住。', '（顺气）刚那口太急了。', '咳咳…我缓缓。',
          '（眼泪被咳出来了）', '嗝…咳、咳——', '( °Д°)', '(´д`)'
        )
      } else {
        $bagKey = 'choke_empty'
        $pool = @(
          '咳——！余额见底是这个味道吗。', '（拍着胸口）充点钱我就顺气了。', '咳咳、卡得正好是个整数。',
          '这一口是最后一口了。', '（咳完，抱着空钱包发呆）', '(;´Д`)', '(っ- ‸ - ς)'
        )
      }
    }

    'idle' {
      $bagKey = 'idle'
      $pool = @(
        '在忙吗？', '我在这儿待着就好。', '今天也在烧钱呢。', '要不要看看余额？',
        '（盯着屏幕发呆）', '记得喝水。', '代码写得怎么样了？', '我有点困了…',
        '你不摸我，我就自己发呆。', '有没有一种可能，我们该休息了。',
        '这个 bug 你修多久了？', '（打了个哈欠）', '余额充足，放心干。',
        '深呼吸，慢慢来。', '需要我帮你数着吗？'
      )
      if ($hour -lt 11 -and $hour -ge 5) {
        $pool += @('早上好，今天也要小心花钱。', '这么早就开工了？', '（刚睡醒）早。')
      } elseif ($hour -ge 11 -and $hour -lt 18) {
        $pool += @('下午了，喝口水吧。', '困不困？', '午后容易花冤枉钱哦。')
      } else {
        $pool += @('这么晚还不睡？', '熬夜费余额哦。', '该睡了，明天再烧。', '（陪你熬）')
      }
    }

    default {
      if ($bal -le $danger) {
        $bagKey = 'hit_low'
        $pool = @(
          '钱包只剩一口气了…', '再点就要饿死了。', '这就是破产的感觉吗。', '别花了，求你了。',
          '余额报警：请立刻充值。', '再花下去我只能喝西北风了。', '要不…今天先收工？',
          '危险危险危险，余额见底！', '（抱着空钱包发呆）', '我已经开始焦虑了。',
          '这点钱撑不过今晚。', '你看我眼里的绝望了吗。', '又来？你确定？', '我建议你喝口水冷静一下。'
          '再扣一次，我就只剩个位数了。', '（按计算器的手指在抖）', '这一笔算我求你，下一笔再说。',
          '我把「少花点」写在便利贴上，贴你屏幕了。', '别让我数到零，我数得可快了。',
          '（小声）其实我还想再吃一口。', '连呼吸都放轻了，生怕多扣一分钱。',
          '刚才那一下，我划账本划得特别用力。', '你要不要先看看充值页面长什么样。',
          '（把钱包翻过来给你看：空的）', '再这样下去我要去打工了。',
          '(´；ω；`)', '(｡•́︿•̀｡)', '(っ˘̩╭╮˘̩)っ'
          ('红线就在 ¥{0:F2}，你已经踩在上面了。' -f $danger),
          ('跌破 ¥{0:F2}，我就只剩哭的份了。' -f $danger)
        )
      } elseif ($bal -le $warn) {
        $bagKey = 'hit_mid'
        $pool = @(
          '余额快见底了。', '悠着点花…', '这个月还长着呢。', '省着点，好吗？',
          '我盯着余额，你别乱花。', '已经开始心疼了。', '再烧就只剩个零头了。',
          '提醒：余额不多了。', '（把钱包往身后藏）', '手轻一点。',
          '少一点，再少一点。', '我听见钱包在叹气。'
          '这个价位段，我建议你先深呼吸。', '刚夸你会过日子，你就来这一下。',
          '（把零食默默收进抽屉）', '记账本开始烫手了。', '我在给你留后路，别不信。',
          '（用尾巴把钱包盖住）', '你这手感，像是余额还有一半似的。',
          '再降一档我就换脸色了，真的。', '「悠着点」这三个字，我念得很清楚。',
          '（偷偷把充值页面收藏了）', '(´-ω-`)'
          ('再往下探到 ¥{0:F2}，我就翻脸。' -f $danger)
        )
      } else {
        $bagKey = 'hit_high'
        $pool = @(
          '又扣钱了…', '记在小本本上了。', '这一笔我记下了。', '唔…', '继续继续。',
          '一点点，不心疼。', '零头而已。', '又来了又来了。', '我数着呢。',
          '（拿小本本划一笔）', '这一发不痛。', '继续烧，我不拦你。',
          '小钱。', '不痛不痒。', '记好了。', '滴答，又少一点。', '余额微微一动。',
          '（头也不抬地记一笔）', '这点钱，我连眼皮都不抬。', '(・ω・)', '(￣▽￣)'
        )
      }
    }
  }

  return (Get-LineFromBag -Key $bagKey -Pool $pool)
}
function Show-WhaleBubble {
  # 气泡已经拆成独立插件（dsh-speech-bubble），这里只负责挑台词 + 通过总线发出去
  # 时机避让：伤害数字还在飞的时候不插嘴——先排队，等这一波刷完（数字消失 + 静默 quietMs）再冒
  param($Context, [string]$Text, [int]$HoldMs = 2400, [switch]$Now)
  $W = $script:Whale
  if (-not $W) { return }
  if (-not $Now -and [bool]$W.Settings.bubbleAvoidNumbers -ne $false) {
    $life = 1250.0; $quiet = 700.0
    try { if ([double]$W.Settings.numberLifeMs -gt 0) { $life = [double]$W.Settings.numberLifeMs } } catch {}
    try { if ([double]$W.Settings.bubbleQuietMs -gt 0) { $quiet = [double]$W.Settings.bubbleQuietMs } } catch {}
    $idleMs = ((Get-Date) - $W.LastNumberAt).TotalMilliseconds
    if ($idleMs -lt ($life + $quiet)) {
      $W.PendingBubble = @{ Text = $Text; HoldMs = $HoldMs }
      $W.PendingAt = Get-Date
      if ($script:DebugBubble) { Write-DshLog ('[bubble] 数字还在刷（静默 {0:F0}ms），台词排队，等满 {1:F0}ms 再冒' -f $idleMs, ($life + $quiet)) }
      return
    }
  }
  $W.PendingBubble = $null
  $W.BubbleUntil = (Get-Date).AddMilliseconds($HoldMs)
  $W.LastBubble = Get-Date
  $W.BubbleShown = $true
  Send-DshBus -Bus $Context.Bus -Object @{ t = 'bubble'; text = $Text; holdMs = $HoldMs } | Out-Null
}

function Invoke-WhaleBurpJolt {
  # 打嗝那一下的「嗝！」：纵向抖一下 + 压一下，当作吃饭 → 打嗝的过渡
  # 用 Shake / ChewScale 这两条已有变换（打嗝时命中早就停手了，2.2 秒静默，不会跟吃饭的咬合挤压打架）
  param($Context)
  $W = $script:Whale
  if (-not $W) { return }
  if ($script:PreviewOn) { return }
  try { if ($W.Settings.burpJolt -eq $false) { return } } catch {}
  $ms = 280
  try { if ([int]$W.Settings.burpJoltMs -gt 0) { $ms = [int]$W.Settings.burpJoltMs } } catch {}
  $dy = 7.0
  try { if ([double]$W.Settings.burpJoltY -gt 0) { $dy = [double]$W.Settings.burpJoltY } } catch {}
  # 关键帧全部预算成标量（避免一元负号在数组字面量里被拆成嵌套数组那个老坑）
  $d1 = [Math]::Round($dy, 3)
  $d2 = [Math]::Round(0.0 - ($dy * 0.45), 3)
  $d3 = [Math]::Round($dy * 0.18, 3)
  $hi = 1.06; $lo = 0.94
  $err = ''
  try {
    if ($W.Shake) {
      $null = Start-DshAnim -Target $W.Shake -Property ([System.Windows.Media.TranslateTransform]::YProperty) `
        -Animation (New-DshKeyframeAnimation -Values @(0, $d1, $d2, $d3, 0) -Ms $ms)
    }
    if ($W.ChewScale) {
      $null = Start-DshAnim -Target $W.ChewScale -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) `
        -Animation (New-DshKeyframeAnimation -Values @(1.0, $lo, $hi, 1.0) -Ms $ms)
      $null = Start-DshAnim -Target $W.ChewScale -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) `
        -Animation (New-DshKeyframeAnimation -Values @(1.0, $hi, $lo, 1.0) -Ms $ms)
    }
  } catch { $err = $_.Exception.Message }
  if ($script:DebugMascot) {
    Write-DshLog ('[mascot] 打嗝抖一下（纵向 ±{0:F1}px / {1}ms，Shake={2} ChewScale={3}，错误={4}）' -f `
      $dy, $ms, [bool]$W.Shake, [bool]$W.ChewScale, $(if ($err) { $err } else { '无' }))
  }
}

function Invoke-WhaleChoke {
  # 断网 / API 用完 → 正在吃的那顿饭被打断，呛到：噎住（抖）→ 停顿 → 咳出来
  # -Force：右键「预览呛到」用——跳过「菜单开着不演」和冷却，点了必须能看到
  param($Context, [string]$Reason = 'empty', [switch]$Force)
  $W = $script:Whale
  if (-not $W) { return }
  # reason = 'preview'：演示/预览用，等同 -Force（跳过菜单守卫和冷却，也不吃冷却）
  if ([string]$Reason -eq 'preview') { $Force = $true }
  if ($W.MenuOpen -and -not $Force) {
    if ($script:DebugMascot) { Write-DshLog '[mascot] 菜单开着，呛到先不演' }
    return
  }
  # 冷却：网络抖动会连着触发，所以「同一个原因」在冷却时间内只呛一次（两个原因各自算）
  $cool = 300.0
  try { if ([double]$W.Settings.chokeCooldownSec -gt 0) { $cool = [double]$W.Settings.chokeCooldownSec } } catch {}
  $key = [string]$Reason
  if ($key -ne 'offline' -and $key -ne 'empty') { $key = 'empty' }
  $last = [DateTime]::MinValue
  if (-not $Force) {
    try { if ($W.ChokeCool.ContainsKey($key)) { $last = [DateTime]$W.ChokeCool[$key] } } catch {}
    if ($last -ne [DateTime]::MinValue -and ((Get-Date) - $last).TotalSeconds -lt $cool) {
      if ($script:DebugMascot) { Write-DshLog ('[mascot] 呛到在冷却里（{0} 这个原因 {1:F0}s 内已经呛过，还剩 {2:F0}s），这次跳过' -f $key, $cool, ($cool - ((Get-Date) - $last).TotalSeconds)) }
      return
    }
  }
  $tm = Get-WhaleChokeTiming -W $W
  if (-not $Force) { try { $W.ChokeCool[$key] = Get-Date } catch {} }   # 预览不吃冷却
  $W.ChokeAt = Get-Date
  $W.ChokeStep = 1
  $W.ChokeReason = [string]$Reason
  $W.EatMode = 'idle'        # 饭被打断了，咳完回去看脸色，不接着打嗝
  # ① 噎住：小幅度快速抖（独立变换，不和吃饭的咬合抖动打架）
  $amp = 3.5
  try { if ([double]$W.Settings.chokeTrembleX -gt 0) { $amp = [double]$W.Settings.chokeTrembleX } } catch {}
  $tms = 150
  try { if ([int]$W.Settings.chokeTrembleMs -gt 0) { $tms = [int]$W.Settings.chokeTrembleMs } } catch {}
  if (-not $script:PreviewOn -and $W.ChokeShake) {
    try {
      $null = Start-DshAnim -Target $W.ChokeShake -Property ([System.Windows.Media.TranslateTransform]::XProperty) `
        -Animation (New-DshDoubleAnimation -From (0.0 - $amp) -To $amp -Ms $tms -AutoReverse -Forever -Ease Sine)
    } catch {}
  }
  if ($script:DebugMascot) {
    Write-DshLog ('[mascot] 呛到开始（原因 {0}）：噎住 {1:F0}ms → 停顿 {2:F0}ms → 咳出来 {3:F0}ms，抖动 ±{4:F1}px/{5}ms' -f `
      $W.ChokeReason, $tm.A, $tm.P, $tm.B, $amp, $tms)
  }
}

function Invoke-WhalePat {
  param($Context)
  $W = $script:Whale
  if (-not $W) { return }
  $now = Get-Date

  # 优先级：菜单打开 / 呛到 / 吃饭中 / 拖动中 → 摸头被禁用（不换立绘、不冒台词、也不计数）
  $layer = Get-WhaleLayer -Context $Context
  if ($layer -eq 'menu' -or $layer -eq 'eat' -or $layer -eq 'drag' -or $layer -eq 'choke') {
    if ($script:DebugMascot) { Write-DshLog ('[mascot] 摸头被禁用（当前层 {0}）' -f $layer) }
    return
  }

  # 连续摸头计数（3 秒内算连击，超时就重新从 1 数）
  if (($now - $W.PatLastAt).TotalMilliseconds -le 3000) { $W.PatStreak = [int]$W.PatStreak + 1 }
  else { $W.PatStreak = 1 }
  $W.PatLastAt = $now
  $W.PatTotal = [int]$W.PatTotal + 1
  $W.PatCount = [int]$W.PatCount + 1
  try { Write-DshJson @{ patTotal = [int]$W.PatTotal } $W.StateFile } catch {}
  # 摸头计数要当场刷到底部那一行。
  # 以前这里只改了内存和 state.json，InfoText 全靠 Set-BarVisual 重画——
  # 而 Set-BarVisual 只有「命中 / 余额轮询（30 秒一次）/ 重连」才被调，
  # 于是摸头数字能冻住半分钟到几分钟，看着就是「不同步」。
  Update-WhaleInfoText -W $W

  # 摸头动画：换成开心立绘 + 抖动（抖动保留）
  # 注意：这里只登记「摸头窗口」，立绘一律交给状态机（Update-MascotImage）去换。
  # 以前这里直接改 Source，会和状态机的 CurrentMascotKey 记录对不上——
  # 余额状态预览期间摸头，状态机以为"图还是状态图"直接早退，结果就卡在摸头那张脸上。
  if ($script:PatImageSource -and $script:PetImageElement) {
    $W.PatImageUntil = $now.AddMilliseconds(900)
  }
  if (-not $script:PreviewOn) {
    $null = Start-DshAnim -Target $W.PatScale -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) -Animation (New-DshKeyframeAnimation -Values @(1.0, 0.93, 1.02, 1.0) -Ms 320)
    $null = Start-DshAnim -Target $W.PatScale -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) -Animation (New-DshKeyframeAnimation -Values @(1.0, 1.04, 0.99, 1.0) -Ms 320)
  }
  # 连续摸头到 3 / 5 / 10 / 20 / 50 次时，台词换成「摸头里程碑」
  $kind = 'pat'
  if (@(3, 5, 10, 20, 50) -contains [int]$W.PatStreak) { $kind = 'patMilestone' }
  Show-WhaleBubble -Context $Context -Text (Get-WhaleLine -Context $Context -Kind $kind -Count ([int]$W.PatStreak)) -HoldMs 2600
}

function Get-MascotImageKey {
  # 立绘状态机：强制预览 > 右键菜单(冻住) > 吃饭(eat1/eat2→eat3) > 拖动(常态脸) > 摸头 > 余额状态(黄/红) > 常态
  param($Context)
  $W = $script:Whale
  if (-not $W) { return 'normal' }
  $s = $W.Settings
  $now = Get-Date

  $layer = Get-WhaleLayer -Context $Context
  # 当前生效的余额状态（右键预览强制优先）——底色和两维立绘（黄/红的摸头、吃饭、呛到）都看它
  $moodNow = Get-WhaleStateNow -Context $Context

  # ② 右键菜单开着：脸冻在当前这一帧，别在菜单底下继续换姿势
  if ($layer -eq 'menu') { return $script:CurrentMascotKey }

  # ③ 呛到：噎住（抖）→ 停顿 → 咳出来
  if ($layer -eq 'choke') {
    $tm = Get-WhaleChokeTiming -W $W
    $el = ((Get-Date) - $W.ChokeAt).TotalMilliseconds
    if ($el -lt $tm.CoughAt) { return (Get-WhaleSpriteKey -Action 'choke1' -State $moodNow) }
    return (Get-WhaleSpriteKey -Action 'choke2' -State $moodNow)
  }

  # ④ 吃饭（命中驱动）
  if ($layer -eq 'eat' -and $W.EatMode -eq 'eat') {
    $endMs = 1200.0
    try { if ([double]$s.eatEndMs -gt 0) { $endMs = [double]$s.eatEndMs } } catch {}
    if (($now - $W.LastHitAt).TotalMilliseconds -gt $endMs) {
      # 吃完先等这一口嚼完再转场，别在"嘴里还塞着饭"那一帧突然变成打嗝脸（观感会突然跳）
      if ($now -lt $W.NextChewAt) {
        if ([int]$W.EatFrame -eq 0) { return (Get-WhaleSpriteKey -Action 'eat1' -State $moodNow) }
        return (Get-WhaleSpriteKey -Action 'eat2' -State $moodNow)
      }
      # 只来了一两发 → 不算「吃了一顿」，不打嗝，直接回脸色（真实使用里命中是稀疏的，避免"吃一口就一直在打嗝"）
      $minHits = 3
      try { if ([int]$s.burpMinHits -gt 0) { $minHits = [int]$s.burpMinHits } } catch {}
      if ([int]$W.MealHits -ge $minHits) {
        # 吃饱的收尾：本来只会打嗝，现在有 25% 概率演成「打嗝呛到」
        $chokeChance = 25
        try { if ($null -ne $s.burpChokeChance) { $chokeChance = [int]$s.burpChokeChance } } catch {}
        $roll = Get-Random -Minimum 0 -Maximum 100
        $W.EatMode = 'done'
        $doneMs = 2600.0
        try { if ([double]$s.eatDoneMs -gt 0) { $doneMs = [double]$s.eatDoneMs } } catch {}
        $W.DoneUntil = $now.AddMilliseconds($doneMs)
        if ($roll -lt $chokeChance) {
          if ($script:DebugMascot) { Write-DshLog ('[mascot] 这顿来了 {0} 发命中 → 打嗝呛到（掷骰 {1} < {2}%）' -f [int]$W.MealHits, $roll, $chokeChance) }
          Invoke-WhaleChoke -Context $Context -Reason 'burp' -Force
          return (Get-WhaleSpriteKey -Action 'choke1' -State $moodNow)
        }
        if ($script:DebugMascot) { Write-DshLog ('[mascot] 这顿来了 {0} 发命中 → 正常打嗝（掷骰 {1} ≥ {2}%）' -f [int]$W.MealHits, $roll, $chokeChance) }
        Invoke-WhaleBurpJolt -Context $Context      # 进打嗝前抖一下，作为过渡
        Show-WhaleBubble -Context $Context -Text (Get-WhaleLine -Context $Context -Kind 'burp') -HoldMs 2600 -Now   # 打嗝这一刻才冒气泡
        return (Get-WhaleSpriteKey -Action 'eat3' -State $moodNow)
      }
      if ($script:DebugMascot) { Write-DshLog ('[mascot] 这顿只来 {0} 发命中 → 不算一顿，直接回脸（不打嗝）' -f [int]$W.MealHits) }
      $W.EatMode = 'idle'
      return (Get-WhaleBalanceMood -Context $Context)
    }
    # 没有新命中时的「自己嚼」节奏：命中驱动为主，这个只是兜底，避免单发命中时僵住
    $chewMs = 480.0
    try { if ([double]$s.chewMs -gt 0) { $chewMs = [double]$s.chewMs } } catch {}
    if ($now -ge $W.NextChewAt) {
      $W.EatFrame = 1 - [int]$W.EatFrame
      $W.LastChewAt = $now
      $W.NextChewAt = $now.AddMilliseconds($chewMs)
    }
    if ([int]$W.EatFrame -eq 0) { return (Get-WhaleSpriteKey -Action 'eat1' -State $moodNow) }
    return (Get-WhaleSpriteKey -Action 'eat2' -State $moodNow)
  }

  # 吃饱收尾：即使摸头/拖动插进来，打嗝那一帧也照旧算完（否则会永远停在 eat3）
  if ($W.EatMode -eq 'done') {
    if ($now -gt $W.DoneUntil) { $W.EatMode = 'idle' }
    elseif ($layer -eq 'eat') { return (Get-WhaleSpriteKey -Action 'eat3' -State $moodNow) }
  }

  # ④.5 甩太猛：慌张立绘（mascot-shake.png），抖动画在 Tick-Plugin 里驱动
  if ($layer -eq 'shake') {
    return (Get-WhaleSpriteKey -Action 'shake' -State $moodNow)
  }

  # ⑤ 拖动中：不换脸色，就是当前状态那张脸
  if ($layer -eq 'drag') {
    if ($script:MascotImages -and $script:MascotImages.ContainsKey($moodNow)) { return $moodNow }
    return 'normal'
  }

  # ⑥ 摸头
  # ⑤ 摸头：黄/红各有自己的性格立绘（mascot-pat-warn / mascot-pat-danger），没画就退回常态摸头
  if ($layer -eq 'pat') { return (Get-WhaleSpriteKey -Action 'pat' -State $moodNow) }

  # ⑦ 余额状态打底（黄 / 红 / 常态）
  if ($script:MascotImages -and $script:MascotImages.ContainsKey($moodNow)) { return $moodNow }
  return 'normal'
}

# ---- 光标位置（物理像素 → WPF 的 DIP）----------------------------------------
# 拖动改成「绝对定位」：按下时记住「光标 - 窗口左上角」的偏移，之后每一帧都用
# 光标位置减去这个偏移来放窗口。原来用「每帧位移累加」，两个毛病：
#   ① 浮点/取整误差会累积 → 抓着同一个点时窗口慢慢从手指底下溜走；
#   ② 拖到屏幕外再拖回来时，系统会把窗口位置夹回屏幕内，位移算法不知道这事，
#      于是回来的一瞬间按下点整个漂掉（就是用户看到的「大范围位移」）。
if (-not ('WhaleCursor' -as [type])) {
  try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WhaleCursor {
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
}
"@
  } catch { }
}

function Get-WhaleCursorDip {
  # 返回光标位置（WPF 的 DIP 坐标）。优先用 WinForms 的 Cursor.Position（物理像素），
  # 除以屏幕 DPI 缩放得到 DIP；取不到就退回 P/Invoke。
  param($W)
  try {
    $sx = 1.0; $sy = 1.0
    $src = [System.Windows.PresentationSource]::FromVisual($W.Window)
    if ($src) {
      $m = $src.CompositionTarget.TransformToDevice
      if ([double]$m.M11 -gt 0) { $sx = [double]$m.M11 }
      if ([double]$m.M22 -gt 0) { $sy = [double]$m.M22 }
    }
    $phys = $null
    try {
      Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
      $phys = [System.Windows.Forms.Cursor]::Position
    } catch { }
    if ($phys) {
      $dipx = ([double]$phys.X) / $sx
      $dipy = ([double]$phys.Y) / $sy
      return @($dipx, $dipy)
    }
    [WhaleCursor+POINT]$pt = New-Object WhaleCursor+POINT
    if (-not [WhaleCursor]::GetCursorPos([ref]$pt)) { Write-DshLog '[mascot] GetCursorPos 失败'; return $null }
    $dipx2 = ([double]$pt.X) / $sx
    $dipy2 = ([double]$pt.Y) / $sy
    return @($dipx2, $dipy2)
  } catch { Write-DshLog ('[mascot] Get-WhaleCursorDip 异常：' + $_.Exception.Message); return $null }
}

# ---- 快速甩动 → 慌张动画 -------------------------------------------------------
# 省电模式：停掉三条「永远在跑」的待机动画。动画一停，WPF 就不再每帧重绘，
# 空闲 CPU 会从 ~23% 掉到接近 0（这才是宿主耗电的大头，光把 tick 放慢没用）。
function Start-WhaleIdleAnimations {
  param($W)
  if (-not $W) { return }
  $s = $W.Settings
  try {
    if ($s.idleBreathe) {
      $null = Start-DshAnim -Target $W.Breathe -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) -Animation (New-DshDoubleAnimation -From 1.0 -To 1.018 -Ms 1700 -AutoReverse -Forever -Ease Sine)
      $null = Start-DshAnim -Target $W.Breathe -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) -Animation (New-DshDoubleAnimation -From 1.0 -To 1.013 -Ms 1700 -AutoReverse -Forever -Ease Sine)
    }
    if ($s.idleSway) {
      $null = Start-DshAnim -Target $W.Sway -Property ([System.Windows.Media.RotateTransform]::AngleProperty) -Animation (New-DshDoubleAnimation -From -1.1 -To 1.1 -Ms 2800 -AutoReverse -Forever -Ease Sine)
    }
    if ($W.AhogeRot) {
      $null = Start-DshAnim -Target $W.AhogeRot -Property ([System.Windows.Media.RotateTransform]::AngleProperty) -Animation (New-DshDoubleAnimation -From -11 -To 13 -Ms 1250 -AutoReverse -Forever -Ease Sine)
    }
  } catch { Write-DshLog ('待机动画启动失败：' + $_.Exception.Message) 'warn' }
}

function Set-WhaleIdleAnimations {
  param($W, [bool]$On)
  if (-not $W) { return }
  try {
    if ($On) {
      Start-WhaleIdleAnimations -W $W
    } else {
      $W.Breathe.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
      $W.Breathe.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
      $W.Breathe.ScaleX = 1.0
      $W.Breathe.ScaleY = 1.0
      $W.Sway.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
      $W.Sway.Angle = 0.0
      if ($W.AhogeRot) {
        $W.AhogeRot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
        $W.AhogeRot.Angle = 0.0
      }
    }
  } catch { Write-DshLog ('待机动画切换失败：' + $_.Exception.Message) 'warn' }
}

function Start-WhalePanic {
  param($Context, $W, [string]$Why = '')
  $ms = 1200.0
  try { if ([double]$W.Settings.shakeMs -gt 0) { $ms = [double]$W.Settings.shakeMs } } catch {}
  $W.ShakeUntil = (Get-Date).AddMilliseconds($ms)
  $cool = 900.0
  try { if ([double]$W.Settings.shakeCooldownMs -gt 0) { $cool = [double]$W.Settings.shakeCooldownMs } } catch {}
  $W.ShakeCool = (Get-Date).AddMilliseconds($cool)
  if ($script:DebugMascot) { Write-DshLog ('[mascot] 拖太久 → 慌张动画（{0}）' -f $Why) }
  # 慌张时会碎碎念一句（不抢数字的时机，交给 Show-WhaleBubble 自己排队）
  try {
    Show-WhaleBubble -Context $Context -Text (Get-WhaleLine -Context $Context -Kind 'shake') -HoldMs 1500
  } catch { }
}
function Get-WhaleSpriteKey {
  # 两维立绘查表：<动作>-<状态> 画了就用它，没画就退回 <动作>（常态版），再退到 normal。
  # 所以以后给黄/红状态补画"吃饭的""拎起的"各种变体，只要按 mascot-<动作>-<状态>.png 丢进 images\ 就自动生效。
  param([string]$Action, [string]$State = 'normal')
  if (-not $script:MascotImages -or [string]::IsNullOrWhiteSpace($Action)) { return 'normal' }
  if ($State -and $State -ne 'normal') {
    $v = '{0}-{1}' -f $Action, $State
    if ($script:MascotImages.ContainsKey($v)) { return $v }
  }
  if ($script:MascotImages.ContainsKey($Action)) { return $Action }
  return 'normal'
}

function Get-WhaleLayer {
  # 动作层优先级（高 → 低）：右键菜单 > 呛到 > 吃饭 > 拖动 > 摸头 > 常态
  # 规则：高优先级层活跃时，低优先级的「动作」被禁用——直接不触发，不是在背后排队。
  # 「余额状态(黄/红)」不在这条链上：它不是动作，而是底色，只在没有任何动作层时露脸。
  param($Context)
  $W = $script:Whale
  if (-not $W) { return 'normal' }
  $now = Get-Date
  if ($W.MenuOpen) { return 'menu' }
  if ($W.ChokeAt -ne [DateTime]::MinValue) {
    $total = (Get-WhaleChokeTiming -W $W).Total
    if (((Get-Date) - $W.ChokeAt).TotalMilliseconds -lt $total) { return 'choke' }
    $W.ChokeAt = [DateTime]::MinValue      # 演完了自己收工
    $W.ChokeStep = 0
  }
  if ($W.EatMode -ne 'idle') { return 'eat' }
  if ($W.ShakeUntil -ne [DateTime]::MinValue -and $now -lt $W.ShakeUntil) { return 'shake' }   # 快速甩动 → 慌张（盖住普通拖动）
  if ($W.Dragging) { return 'drag' }
  if ($W.PatImageUntil -ne [DateTime]::MinValue -and $now -lt $W.PatImageUntil) { return 'pat' }
  return 'normal'
}

function Get-WhaleChokeTiming {
  # 呛到三段时间轴：① 噎住（抖）→ ② 停顿（静一下）→ ③ 咳出来
  param($W)
  $s = $W.Settings
  $a = 700.0; $p = 220.0; $b = 1000.0
  try { if ([double]$s.choke1Ms -gt 0) { $a = [double]$s.choke1Ms } } catch {}
  try { if ([double]$s.chokePauseMs -gt 0) { $p = [double]$s.chokePauseMs } } catch {}
  try { if ([double]$s.choke2Ms -gt 0) { $b = [double]$s.choke2Ms } } catch {}
  return [pscustomobject]@{ A = $a; P = $p; B = $b; CoughAt = $a + $p; Total = $a + $p + $b }
}

function Get-WhaleThresholds {
  # 阶梯式动态百分比：充值上限越大，预警线百分比越高（否则充 50 块要烧掉 30 块才变黄，预警太迟钝）
  #   黄线% = 0.40 + (cap - 10) / 10 * 0.10 ，封顶 70%
  #   红线% = 0.20 + (cap - 10) / 10 * 0.05 ，封顶 35%（正好是黄线的一半）
  #   cap 10 → 黄 ¥4 / 红 ¥2 ；cap 20 → ¥10 / ¥5 ；cap 30 → ¥18 / ¥9 ；cap ≥ 50 → ¥35 / ¥17.5
  param($Context)
  $cap = 10.0
  try { if ([double]$Context.Config.balance.capCny -gt 0) { $cap = [double]$Context.Config.balance.capCny } } catch {}
  $step = ($cap - 10.0) / 10.0
  $warnPct = 0.40 + ($step * 0.10)
  $dangerPct = 0.20 + ($step * 0.05)
  if ($warnPct -gt 0.70) { $warnPct = 0.70 }
  if ($dangerPct -gt 0.35) { $dangerPct = 0.35 }
  if ($warnPct -lt 0.40) { $warnPct = 0.40 }      # 上限低于 10 元时的兜底，避免比 40%/20% 还宽松
  if ($dangerPct -lt 0.20) { $dangerPct = 0.20 }
  return [pscustomobject]@{
    Cap       = [Math]::Round($cap, 2)
    WarnPct   = $warnPct
    DangerPct = $dangerPct
    WarnCny   = [Math]::Round($cap * $warnPct, 2)
    DangerCny = [Math]::Round($cap * $dangerPct, 2)
  }
}

function Get-WhaleStateNow {
  # 当前「生效」的余额状态 = 右键预览强制的那个（有的话），否则按真实余额算。
  # 注意它只负责"底色"，不抢占动作层——所以预览开着也能摸头，而且摸的是对应状态的立绘。
  param($Context)
  $W = $script:Whale
  if ($W) {
    $f = [string]$W.ForceMood
    if ($f -and (@('normal', 'warn', 'danger') -contains $f)) {
      try { if ((Get-Date) -lt $W.ForceMoodUntil) { return $f } } catch {}
    }
  }
  return (Get-WhaleBalanceMood -Context $Context)
}

function Get-WhaleBalanceMood {
  # 余额状态：阈值由 Get-WhaleThresholds 算出来的绝对金额——余额 ≤ 红线出「红」，≤ 黄线出「黄」
  # 血条变色 / 余额状态立绘 / 低余额台词 三处共用同一套阈值，不会各说各话
  param($Context)
  $W = $script:Whale
  if (-not $W) { return 'normal' }
  $bal = 0.0
  try { $bal = [double]$W.LastBalance } catch {}
  $th = Get-WhaleThresholds -Context $Context
  if ($bal -le $th.DangerCny) { return 'danger' }
  if ($bal -le $th.WarnCny) { return 'warn' }
  return 'normal'
}

function Update-MascotImage {
  param($Context)
  $key = Get-MascotImageKey -Context $Context
  $src = $null
  if ($script:MascotImages) { try { $src = $script:MascotImages[$key] } catch {} }
  # 不只看 key，还要看元素上现在真的挂着哪张图：别处（摸头/强制预览）万一绕过状态机改过 Source，
  # 这里也能发现并纠正回来，不会出现"记录说没问题、脸上却卡着别的图"。
  $same = ($key -eq $script:CurrentMascotKey)
  if ($same -and $src -and $script:PetImageElement) {
    try { if (-not [object]::ReferenceEquals($script:PetImageElement.Source, $src)) { $same = $false } } catch {}
  }
  if ($same) { return }
  if ($src -and $script:PetImageElement) {
    try { $script:PetImageElement.Source = $src } catch {}
  }
  $script:CurrentMascotKey = $key
  # 余额状态切换时记一笔日志（只在真的变了时写，不刷屏）
  if (@('normal', 'warn', 'danger') -contains $key) {
    if ($script:LastMoodKey -ne $key) {
      $script:LastMoodKey = $key
      $amt = 0.0
      try { $amt = [double]$script:Whale.LastBalance } catch {}
      if ($key -eq 'normal') { Write-DshLog ('余额状态 -> 正常（余额 ¥{0:F2}）' -f $amt) }
      elseif ($key -eq 'warn') { Write-DshLog ('余额状态 -> 黄·偏低（余额 ¥{0:F2}）' -f $amt) }
      else { Write-DshLog ('余额状态 -> 红·危险（余额 ¥{0:F2}）' -f $amt) }
    }
  }
  if ($script:DebugMascot) { Write-DshLog ("[mascot] 立绘 -> {0}" -f $key) }
}

function Toggle-DamageOverlay {
  param($Context)
  $newState = -not [bool]$Context.OverlayVisible
  foreach ($rp in $Context.Plugins) {
    if ($rp.Id -ne 'dsh-damage-pulse') { continue }
    foreach ($wdw in $rp.Windows) {
      try {
        if ($newState) { $wdw.Visibility = [System.Windows.Visibility]::Visible }
        else { $wdw.Visibility = [System.Windows.Visibility]::Collapsed }
      } catch {}
    }
  }
  $Context.OverlayVisible = $newState
  if ($newState) { Show-WhaleBubble -Context $Context -Text '伤害数字已打开' -HoldMs 1600 }
  else { Show-WhaleBubble -Context $Context -Text '伤害数字已关闭' -HoldMs 1600 }
}

function Prompt-ApiKey {
  # 右键菜单填 DeepSeek API：保存后核心切到真实余额模式，同步 余额 / 已烧（命中仍是本机统计）
  param($Context)
  $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="ToolWindow" Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Title="填写 DeepSeek API Key" Width="440" SizeToContent="Height" WindowStartupLocation="CenterScreen"
        Background="#FF141820" Foreground="#FFEAF2FF" FontFamily="Microsoft YaHei UI">
  <StackPanel Margin="16">
    <TextBlock Text="填写 DeepSeek API Key" FontWeight="Bold" FontSize="14"/>
    <TextBlock Text="从 platform.deepseek.com → API Keys 复制（sk- 开头）。只存你本机，不上传任何地方。" Foreground="#FF8FA3B8" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,0"/>
    <PasswordBox x:Name="KeyBox" PasswordChar="●" Height="30" Margin="0,12,0,0" Background="#FF1B212A" Foreground="#FFEAF2FF" BorderBrush="#FF3A4450"/>
    <TextBlock Text="保存后：余额 = DeepSeek 真实余额；已烧 = 充值额 - 余额（真实）；命中 = 本机统计（DeepSeek 没有查询调用次数的接口）。" Foreground="#FF8FA3B8" FontSize="10" TextWrapping="Wrap" Margin="0,8,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="SaveBtn" Content="保存" Width="92" Padding="0,4,0,4"/>
      <Button x:Name="CancelBtn" Content="取消" Width="76" Padding="0,4,0,4" Margin="8,0,0,0"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
  $win = New-DshWindowFromXaml -Xaml $xaml -Tag 'apikey'
  $keyBox = $win.FindName('KeyBox')
  $save = $win.FindName('SaveBtn')
  $cancel = $win.FindName('CancelBtn')
  $save.Add_Click({
    $k = $keyBox.Password.Trim()
    if (-not $k) { Show-WhaleBubble -Context $Context -Text 'API key 不能为空' -HoldMs 2000; return }
    $sent = Send-DshBus -Bus $Context.Bus -Object @{ t = 'setApiKey'; apiKey = $k }
    if ($sent) { Show-WhaleBubble -Context $Context -Text '已保存，正在同步 DeepSeek 真实余额…' -HoldMs 2600 }
    else { Show-WhaleBubble -Context $Context -Text '核心没在跑，先双击 start / exe 再填' -HoldMs 2600 }
    $win.Close()
  }.GetNewClosure())
  $cancel.Add_Click({ $win.Close() }.GetNewClosure())
  $script:ApiKeyDlg = $win
  $null = $win.ShowDialog()
}

function Get-WhalePluginJson {
  $W = $script:Whale
  if (-not $W) { return '' }
  try {
    $dir = Split-Path -Parent ([string]$W.PosFile)
    if ($dir) { return (Join-Path $dir 'plugin.json') }
  } catch {}
  return ''
}

function Save-WhaleShowBar {
  param([bool]$Visible)
  $pf = Get-WhalePluginJson
  if (-not $pf) { return }
  try {
    if (-not (Test-Path $pf)) { return }
    $txt = [IO.File]::ReadAllText($pf, [Text.Encoding]::UTF8)
    $val = if ($Visible) { 'true' } else { 'false' }
    if ($txt -match '"showBar"\s*:\s*(true|false)') {
      $txt = [regex]::Replace($txt, '"showBar"\s*:\s*(true|false)', ('"showBar": ' + $val))
    } else {
      # 插到 settings 里第一个键之前
      $idx = $txt.IndexOf('"settings"')
      if ($idx -ge 0) {
        $brace = $txt.IndexOf('{', $idx)
        if ($brace -ge 0) {
          $txt = $txt.Substring(0, $brace + 1) + "`n    `"showBar`": " + $val + ',' + $txt.Substring($brace + 1)
        }
      }
    }
    [IO.File]::WriteAllText($pf, $txt, (New-Object Text.UTF8Encoding($false)))
  } catch { }
}

function Set-WhaleBarVisible {
  param($Context, [bool]$Visible, [switch]$Quiet)
  $W = $script:Whale
  if (-not $W -or -not $W.Bar) { return }
  $W.Bar.Visibility = if ($Visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  try { $W.ShowBar = $Visible } catch {}
  Save-WhaleShowBar -Visible $Visible
  if (-not $Quiet) {
    Write-DshLog ('余额条 -> {0}（来自托盘菜单）' -f $(if ($Visible) { '显示' } else { '隐藏' }))
  }
}

function New-WhaleCheckGlyph {
  # 菜单里的「勾」：画在模板那 20px 图标列里（和托盘菜单的 ✓ 一个意思），只管标当前选中项。
  # 每次刷新都新建一个控件——同一个 WPF 元素不能同时挂在两个菜单项上。
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = ([char]0x2713).ToString()
  $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
  $tb.FontSize = 12.5
  $tb.FontWeight = [System.Windows.FontWeights]::Bold
  $tb.Foreground = New-DshBrush '#41E06B'
  $tb.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $tb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  return $tb
}

function Update-WhaleMenuChecks {
  # 给「挂件大小」「余额状态预览」两个子菜单里当前生效的那一项打勾，其余留空。
  # 状态一律现算（$W.Scale / $W.ForceMood + ForceMoodUntil），不缓存 → 不会出现勾和实际显示对不上。
  param($W, $ScaleItems, $MoodItems)
  if (-not $W) { return }
  try {
    $cur = [double]$W.Scale
    if ($cur -le 0) { $cur = 1.0 }
    foreach ($e in @($ScaleItems)) {
      if (-not $e) { continue }
      if ([Math]::Abs([double]$e.Value - $cur) -lt 0.001) { $e.Item.Icon = New-WhaleCheckGlyph }
      else { $e.Item.Icon = $null }
    }
  } catch { }
  try {
    $live = ''
    if ($W.ForceMood -and $W.ForceMoodUntil -gt (Get-Date)) { $live = [string]$W.ForceMood }
    foreach ($e in @($MoodItems)) {
      if (-not $e) { continue }
      if ([string]$e.Value -eq $live) { $e.Item.Icon = New-WhaleCheckGlyph }
      else { $e.Item.Icon = $null }
    }
  } catch { }
}

function Set-WhaleScale {
  param($Context, [double]$Scale)
  $W = $script:Whale
  if (-not $W) { return }
  $bw = [double]$W.Config.window.width
  $bh = [double]$W.Config.window.height
  $oldH = [double]$W.Window.Height
  $W.Scale = [Math]::Max(0.6, [Math]::Min(2.0, $Scale))
  $W.Window.Width = [Math]::Round($bw * [double]$W.Scale)
  $W.Window.Height = [Math]::Round($bh * [double]$W.Scale)
  $W.Stage.LayoutTransform = New-Object System.Windows.Media.ScaleTransform([double]$W.Scale, [double]$W.Scale)
  $W.Window.Top = $W.Window.Top - ([double]$W.Window.Height - $oldH)
  Write-DshPosition
  Write-DshLog ('挂件缩放 -> {0:P0}' -f $W.Scale)
}

function Get-PluginWindows {
  param($Context)
  if ($script:Whale) { return @($script:Whale.Window) }
  return @()
}

function Update-WhaleInfoText {
  # 只重画底部那一行文字（已烧 / 命中 / 摸头），用缓存值，不碰血条、不碰颜色、不动动画。
  # 摸头一按就调它，所以数字是当场变的；命中/余额事件照样走 Set-BarVisual 全量刷新。
  param($W)
  if (-not $W) { return }
  if (-not $W.InfoText) { return }
  $spent = 0.0
  $hits = 0
  try { $spent = [double]$W.LastSpentCny } catch {}
  try { $hits = [int]$W.LastHits } catch {}
  $txt = '已烧 ¥{0:F4} · 命中 {1} · 摸头 {2}' -f $spent, $hits, [int]$W.PatTotal
  if ($W.InfoText.Text -ne $txt) { $W.InfoText.Text = $txt }
  if ($script:DebugMascot) { Write-DshLog ('[mascot] InfoText 刷新 -> ' + $txt) }
}

function Set-BarVisual {
  param($Context, [double]$Balance, [double]$StartBalance, [double]$Spent, [int]$Hits, [string]$Mode = 'ledger', [double]$Base = 0)
  $W = $script:Whale
  if (-not $W) { return }
  # 满格 = capCny（默认 10 元），余额超过 cap 也按满格算，血条 = 余额 / cap
  # 黄/红线是阶梯式动态百分比算出来的绝对金额（见 Get-WhaleThresholds）
  $th = Get-WhaleThresholds -Context $Context
  $cap = [double]$th.Cap
  $warn = [double]$th.WarnCny
  $danger = [double]$th.DangerCny
  $bal = [double]$Balance
  $ratio = [Math]::Max(0.0, [Math]::Min(1.0, $bal / $cap))
  $W.Ratio = $ratio

  $c1 = '#7BF79B'; $c2 = '#1FBF57'; $dot = '#41E06B'
  if ($bal -le $danger) { $c1 = '#FF7B7B'; $c2 = '#D81F1F'; $dot = '#FF4D4D' }
  elseif ($bal -le $warn) { $c1 = '#FFD98A'; $c2 = '#F09A22'; $dot = '#FFC53D' }

  $grad = New-Object System.Windows.Media.LinearGradientBrush
  $grad.StartPoint = New-Object System.Windows.Point(0, 0)
  $grad.EndPoint = New-Object System.Windows.Point(1, 0)
  $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-DshBrush $c1).Color, 0.0)))
  $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-DshBrush $c2).Color, 1.0)))
  $W.BarFill.Background = $grad
  $W.StatusDot.Fill = New-DshBrush $dot
  $W.ValueText.Text = 'CNY {0:F2}' -f $Balance
  # 把「已烧 / 命中」记下来，摸头的时候没收到新事件也能重刷这一行（摸头数只增不减，是本地状态）
  $W.LastSpentCny = [double]$Spent
  $W.LastHits = [int]$Hits
  Update-WhaleInfoText -W $W
  $W.LastBalance = $Balance

  $prev = 1.0
  try { $prev = [double]$W.BarScale.ScaleX } catch {}
  if ($script:PreviewOn) {
    $W.BarScale.ScaleX = $ratio
  } else {
    $null = Start-DshAnim -Target $W.BarScale -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) `
      -Animation (New-DshDoubleAnimation -From $prev -To $ratio -Ms 420 -Ease Cubic)
  }

  if ($W.Sweat) { $W.Sweat.Opacity = if ($bal -le $warn) { 1.0 } else { 0.0 } }
  $lowMark = $W.Window.FindName('LowMark')
  if ($lowMark) { $lowMark.Opacity = if ($bal -le $warn) { 1.0 } else { 0.0 } }

}

function Invoke-WhaleHit {
  param($Context, $Evt)
  $W = $script:Whale
  if (-not $W) { return }
  $s = $W.Settings
  $shakeMs = 240.0
  if ($Evt.tier -and $Evt.tier.shakeMs) { $shakeMs = [Math]::Max(180.0, [double]$Evt.tier.shakeMs) }

  $ms = [int]$shakeMs
  if ($script:PreviewOn) {
    $W.LastHit = [double]$script:PreviewMs
    $W.LastHitMs = $ms
    return
  }
  # 身体特效只属于「吃饭」这一层：菜单打开 / 拖动中 / 摸头中，命中特效一律让位。
  # 否则连击里每一发都会再压一下，配合摸头立绘看起来就像"被连续摸了好几下"。
  $layer = Get-WhaleLayer -Context $Context
  if ($layer -ne 'eat') {
    if ($script:DebugMascot) { Write-DshLog ('[mascot] 当前层 {0}，命中特效让位' -f $layer) }
    return
  }
  if ($s.hitShake) {
    # 「嚼一口」的抖：幅度更小、次数更密（不再是挨打的震动）
    $amp = 1.0
    try { if ([double]$s.chewShakeScale -gt 0) { $amp = [double]$s.chewShakeScale } } catch {}
    $xa = 8.0 * $amp; $ya = 4.5 * $amp
    $x1 = $xa; $x2 = 0.0 - $xa * 0.85; $x3 = $xa * 0.6; $x4 = 0.0 - $xa * 0.35
    $y1 = $ya; $y2 = 0.0 - $ya * 0.85; $y3 = $ya * 0.6; $y4 = 0.0 - $ya * 0.35
    $null = Start-DshAnim -Target $W.Shake -Property ([System.Windows.Media.TranslateTransform]::XProperty) -Animation (New-DshKeyframeAnimation -Values @(0, $x1, $x2, $x3, $x4, 0) -Ms $ms)
    $null = Start-DshAnim -Target $W.Shake -Property ([System.Windows.Media.TranslateTransform]::YProperty) -Animation (New-DshKeyframeAnimation -Values @(0, $y1, $y2, $y3, $y4, 0) -Ms $ms)
  }
  if ($s.hitShake -ne $false -and $W.ChewScale) {
    # 「咬下去」的挤压：纵向下压 + 横向微胀，一咬一弹；暴击咬得更狠
    $punch = 0.93
    try { if ([double]$s.chewPunchScale -gt 0 -and [double]$s.chewPunchScale -lt 1) { $punch = [double]$s.chewPunchScale } } catch {}
    if ($Evt.crit) { $punch = 1.0 - ((1.0 - $punch) * 1.6) }
    $punchMs = 110
    try { if ([int]$s.chewPunchMs -gt 0) { $punchMs = [int]$s.chewPunchMs } } catch {}
    $midY = [Math]::Round($punch, 3)
    $midX = [Math]::Round(1.0 + ((1.0 - $punch) * 1.2), 3)
    $back = [Math]::Round(1.0 + ((1.0 - $punch) * 0.35), 3)
    $null = Start-DshAnim -Target $W.ChewScale -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) -Animation (New-DshKeyframeAnimation -Values @(1.0, $midY, $back, 1.0) -Ms $punchMs)
    $null = Start-DshAnim -Target $W.ChewScale -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) -Animation (New-DshKeyframeAnimation -Values @(1.0, $midX, $back, 1.0) -Ms $punchMs)
    if ($script:DebugMascot) { Write-DshLog ('[mascot] 咬合挤压 punchY={0} punchX={1} crit={2}' -f $midY, $midX, [bool]$Evt.crit) }
  }
}

function Show-WhaleCombo {
  param([int]$Combo)
  $W = $script:Whale
  if (-not $W -or -not $W.Settings.showCombo) { return }
  if ($Combo -lt 2) { return }
  $W.ComboText.Text = '×' + $Combo
  $W.ComboBadge.Opacity = 1
  if ($W.ComboScale) {
    if ($script:PreviewOn) {
      $W.ComboAt = [double]$script:PreviewMs
      $W.ComboScale.ScaleX = 1.0
      $W.ComboScale.ScaleY = 1.0
      return
    }
    $null = Start-DshAnim -Target $W.ComboScale -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) -Animation (New-DshKeyframeAnimation -Values @(1.4, 1.0) -Ms 200)
    $null = Start-DshAnim -Target $W.ComboScale -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) -Animation (New-DshKeyframeAnimation -Values @(1.4, 1.0) -Ms 200)
  }
}

function Hide-WhaleCombo {
  $W = $script:Whale
  if (-not $W) { return }
  $W.ComboBadge.Opacity = 0
}

function Update-Plugin {
  param($Context, $Evt)
  $W = $script:Whale
  if (-not $W) { return }
  if ($script:PreviewOn) { $script:PreviewMs = [double]$Context.PreviewMs }
  switch ($Evt.t) {
    'hit' {
      Set-BarVisual -Context $Context -Balance ([double]$Evt.balanceCny) -StartBalance ([double]$Evt.startBalanceCny) -Spent ([double]$Evt.totalSpentCny) -Hits ([int]$Context.HitCount) -Mode ([string]$Evt.balanceMode) -Base ([double]$Evt.balanceBase)
      # 先开吃：让「吃饭」这层立刻生效，再看这一发允不允许播身体特效（菜单/拖动/摸头时不让）
      $nowHit = Get-Date
      $W.LastHitAt = $nowHit
      $W.LastNumberAt = $nowHit      # 这一发会冒出伤害数字 → 台词要让路
      $chewMin = 85.0
      try { if ([double]$W.Settings.chewMinMs -gt 0) { $chewMin = [double]$W.Settings.chewMinMs } } catch {}
      $chewIdle = 480.0
      try { if ([double]$W.Settings.chewMs -gt 0) { $chewIdle = [double]$W.Settings.chewMs } } catch {}
      $onHit = $true
      try { $onHit = [bool]$W.Settings.chewOnHit } catch {}
      $fresh = ($W.EatMode -ne 'eat')
      # 从静止/打嗝切换到「开吃」时，第一口落在图二（扒饭塞嘴）——最像"咬下去"
      if ($fresh) { $W.EatMode = 'eat'; $W.EatFrame = 0; $W.MealHits = 0 }
      $gap = ($nowHit - $W.LastChewAt).TotalMilliseconds
      if ($fresh -or ($onHit -and $gap -ge $chewMin)) {
        $W.EatFrame = 1 - [int]$W.EatFrame
        $W.LastChewAt = $nowHit
      }
      $W.MealHits = [int]$W.MealHits + 1
      $W.NextChewAt = $nowHit.AddMilliseconds($chewIdle)
      Invoke-WhaleHit -Context $Context -Evt $Evt
      Show-WhaleCombo -Combo ([int]$Evt.combo)
      $since = ((Get-Date) - $W.LastBubble).TotalSeconds
      $W.LastCombo = [int]$Evt.combo
      # 吃饭期间先不插嘴：台词留到"打嗝"那一刻（见 Get-MascotImageKey 的 done 分支）
      if ($W.EatMode -ne 'eat') {
        if ($Evt.crit) { Show-WhaleBubble -Context $Context -Text (Get-WhaleLine -Context $Context -Kind 'crit') -HoldMs 2000 }
        elseif ($since -gt 9) { Show-WhaleBubble -Context $Context -Text (Get-WhaleLine -Context $Context -Kind 'hit') -HoldMs 1800 }
      }
    }
    'combo' { if (-not $Evt.combo) { Hide-WhaleCombo } }
    'pat' { Invoke-WhalePat -Context $Context }
    'miss' {
      $W.LastNumberAt = Get-Date     # 灰色「未命中」也是数字
      # 未命中不是每次都说：按概率冒一句
      $chance = 0.6
      try { if ($W.Settings.missBubbleChance -ne $null) { $chance = [double]$W.Settings.missBubbleChance } } catch {}
      if ((Get-Random -Minimum 0 -Maximum 1000) -lt [int]($chance * 1000)) {
        $c = 0.0; $n = 0
        try { $c = [double]$Evt.costCny } catch {}
        try { $n = [int]$Evt.count } catch {}
        Show-WhaleBubble -Context $Context -Text (Get-WhaleLine -Context $Context -Kind 'miss' -Cost $c -Count $n) -HoldMs 2600
      }
    }
    'togglePlugin' { if ($Evt.id -eq 'dsh-damage-pulse') { $Context.OverlayVisible = [bool]$Evt.visible } }
    'ui' {
      # 托盘菜单发来的界面指令：跟挂件右键菜单走同一套逻辑（scale / mood / topmost）
      $cmd = ''
      try { $cmd = [string]$Evt.cmd } catch {}
      switch ($cmd) {
        'panic' {
          # 调试入口：验证「快速甩动 → 慌张」动画（托盘 --ui 或命令行都能触发）
          Write-DshLog '慌张动画 -> 手动触发（ui 指令）'
          Start-WhalePanic -Context $Context -W $W -Why 'ui'
        }
        'perf' {
          # 托盘「性能模式」：省电 = 停掉常驻呼吸/摇摆/呆毛动画（画面不再每帧重绘，CPU 直接掉下来）
          $pv = ''
          try { $pv = [string]$Evt.value } catch {}
          $save = ($pv -eq 'save')
          Set-WhaleIdleAnimations -W $W -On (-not $save)
          Write-DshLog ("待机动画 -> {0}（来自托盘菜单）" -f $(if ($save) { '暂停（省电）' } else { '恢复（流畅）' }))
        }        'scale' {
          $sv = 1.0
          try { $sv = [double]$Evt.value } catch {}
          if ($sv -gt 0) { Set-WhaleScale -Context $Context -Scale $sv }
        }
        'mood' {
          $mk = ''
          try { $mk = [string]$Evt.value } catch {}
          if ($mk) {
            $W.ForceMood = $mk
            $W.ForceMoodUntil = (Get-Date).AddSeconds(20)
            Write-DshLog ("余额状态预览 -> {0}（来自托盘菜单，20 秒后自动回真实状态）" -f $mk)
          } else {
            $W.ForceMood = ''
            $W.ForceMoodUntil = [DateTime]::MinValue
            Write-DshLog '余额状态预览 -> 关闭，按真实余额显示（来自托盘菜单）'
          }
        }
        'bar' {
          $bv = $true
          try { if ($null -ne $Evt.value) { $bv = [bool]$Evt.value } } catch {}
          Set-WhaleBarVisible -Context $Context -Visible $bv
        }
        'topmost' {
          if ($W.Window) {
            $W.Window.Topmost = -not $W.Window.Topmost
            Write-DshLog ('置顶 -> {0}（来自托盘菜单）' -f $(if ($W.Window.Topmost) { '开' } else { '关' }))
          }
        }
        default { }   # 其它插件自己的 ui 指令（如伤害数字的 critScale），这里不吭声
      }
    }
    'freeTurn' { $W.LastNumberAt = Get-Date }   # 蓝色「免费回合」也是数字
    'choke' { Invoke-WhaleChoke -Context $Context -Reason ([string]$Evt.reason) }
    'state' {
      if ($Evt.balanceCny -ne $null) {
        Set-BarVisual -Context $Context -Balance ([double]$Evt.balanceCny) -StartBalance ([double]$Evt.startBalanceCny) -Spent ([double]$Evt.totalSpentCny) -Hits ([int]$Evt.hits) -Mode ([string]$Evt.balanceMode) -Base ([double]$Evt.balanceBase)
      }
    }
    'reset' {
      Hide-WhaleCombo
      Set-BarVisual -Context $Context -Balance ([double]$Evt.balanceCny) -StartBalance ([double]$Evt.startBalanceCny) -Spent 0 -Hits 0 -Mode ([string]$Evt.balanceMode) -Base ([double]$Evt.balanceBase)
    }
    'balance' {
      if ($Evt.balanceCny -ne $null) {
        Set-BarVisual -Context $Context -Balance ([double]$Evt.balanceCny) -StartBalance ([double]$Evt.startBalanceCny) -Spent ([double]$Evt.totalSpentCny) -Hits ([int]$Evt.hits) -Mode ([string]$Evt.balanceMode) -Base ([double]$Evt.balanceBase)
      }
    }
    default { }
  }
}

function Set-PluginPreviewPose {
  param($Context, [double]$Ms)
  $W = $script:Whale
  if (-not $W) { return }
  $script:PreviewMs = $Ms

  if ($W.LastHit -gt 0) {
    $t = [Math]::Min(1.0, ([double]$Ms - [double]$W.LastHit) / [double]$W.LastHitMs)
    $W.Shake.X = Get-DshKeyframeValue @(0, 8, -7, 5, -3, 0) $t
    $W.Shake.Y = Get-DshKeyframeValue @(0, 4.5, -4, 2.8, -1.6, 0) $t
  }
  if ($W.ComboAt -gt 0 -and $W.ComboScale) {
    $ct = [Math]::Min(1.0, ([double]$Ms - [double]$W.ComboAt) / 200.0)
    $cs = Get-DshKeyframeValue @(1.4, 1.0) $ct
    $W.ComboScale.ScaleX = $cs
    $W.ComboScale.ScaleY = $cs
  }
}

function Tick-Plugin {
  param($Context, [double]$ElapsedMs)
  $W = $script:Whale
  if (-not $W) { return }
  if ($script:PreviewOn) { return }

  # 长按判定：按住超过 holdMs 就进入「拎起」阶段（素材还没画，先只把状态和时序跑通）
  if ($W.HoldDrag -and -not $W.HoldLong) {
    $holdMs = 450.0
    try { if ([double]$W.Settings.holdMs -gt 0) { $holdMs = [double]$W.Settings.holdMs } } catch {}
    if (((Get-Date) - $W.PressAt).TotalMilliseconds -ge $holdMs) {
      $W.HoldLong = $true
      if ($script:DebugMascot) { Write-DshLog ('[mascot] 长按 {0:F0}ms：进入拎起阶段（占位，等 drag 素材）' -f $holdMs) }
    }
  }

  # 台词排队：数字刷完了就把排队的那句放出来（等太久就算了，那一瞬间已经过去）
  if ($W.PendingBubble) {
    $life = 1250.0; $quiet = 700.0; $maxWait = 6000.0
    try { if ([double]$W.Settings.numberLifeMs -gt 0) { $life = [double]$W.Settings.numberLifeMs } } catch {}
    try { if ([double]$W.Settings.bubbleQuietMs -gt 0) { $quiet = [double]$W.Settings.bubbleQuietMs } } catch {}
    try { if ([double]$W.Settings.bubblePendingMaxMs -gt 0) { $maxWait = [double]$W.Settings.bubblePendingMaxMs } } catch {}
    $idleMs = ((Get-Date) - $W.LastNumberAt).TotalMilliseconds
    $waitedMs = ((Get-Date) - $W.PendingAt).TotalMilliseconds
    if ($waitedMs -gt $maxWait) {
      $W.PendingBubble = $null
      if ($script:DebugBubble) { Write-DshLog ('[bubble] 排队 {0:F0}ms 还没轮到数字停，这句丢掉' -f $waitedMs) }
    } elseif ($idleMs -ge ($life + $quiet)) {
      $pb = $W.PendingBubble
      $W.PendingBubble = $null
      if ($script:DebugBubble) { Write-DshLog ('[bubble] 数字停了（静默 {0:F0}ms），把排队的台词放出来' -f $idleMs) }
      Show-WhaleBubble -Context $Context -Text ([string]$pb.Text) -HoldMs ([int]$pb.HoldMs) -Now
    }
  }

  # 慌张触发（每帧判定，只累计「真的在动」的时间）：
  # 手停住就不累计——所以按住不放、停一会儿再接着晃，仍然会重新攒满并再次触发；
  # 反过来，按着不动也不会莫名其妙开始演。
  if ($W.HoldDrag) {
    $panicMs = 700.0
    try { if ([double]$W.Settings.dragPanicMs -gt 0) { $panicMs = [double]$W.Settings.dragPanicMs } } catch {}
    $stillFor = ((Get-Date) - $W.LastMoveAt).TotalMilliseconds
    if ($stillFor -le 260) {
      $W.DragMs = [double]$W.DragMs + [Math]::Max(0.0, [double]$ElapsedMs)
      if ($W.DragMs -ge $panicMs -and (Get-Date) -ge $W.ShakeCool) {
        $W.DragMs = 0.0
        Start-WhalePanic -Context $Context -W $W -Why ('拖了 {0:F0}ms' -f $panicMs)
      }
    }
  }
  # 慌张：只换立绘（素材本身已经有手舞足蹈的动感线），不额外加位移/旋转——
  # 之前那套正弦抖动在停下来之后还在晃，看着很廉价，已经去掉。

  # 呛到：分段驱动 ① 噎住（抖）→ ② 停顿（静住）→ ③ 咳出来（挤压 + 冒台词）
  if ($W.ChokeAt -ne [DateTime]::MinValue) {
    $tm = Get-WhaleChokeTiming -W $W
    $el = ((Get-Date) - $W.ChokeAt).TotalMilliseconds
    if ($el -ge $tm.Total) {
      $W.ChokeAt = [DateTime]::MinValue
      $W.ChokeStep = 0
      if ($W.ChokeShake) { try { $W.ChokeShake.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null); $W.ChokeShake.X = 0 } catch {} }
      if ($W.ChokeScale) { try { $W.ChokeScale.ScaleX = 1; $W.ChokeScale.ScaleY = 1 } catch {} }
      if ($script:DebugMascot) { Write-DshLog '[mascot] 呛到演完，恢复常态' }
    } elseif ($el -ge $tm.CoughAt -and [int]$W.ChokeStep -lt 3) {
      $W.ChokeStep = 3
      if ($W.ChokeShake) { try { $W.ChokeShake.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null); $W.ChokeShake.X = 0 } catch {} }
      $cs = 1.07
      try { if ([double]$W.Settings.chokeCoughScale -gt 0) { $cs = [double]$W.Settings.chokeCoughScale } } catch {}
      $cms = 180
      try { if ([int]$W.Settings.chokeCoughMs -gt 0) { $cms = [int]$W.Settings.chokeCoughMs } } catch {}
      $lo = [Math]::Round(2.0 - $cs, 3)
      if ($W.ChokeScale -and -not $script:PreviewOn) {
        $null = Start-DshAnim -Target $W.ChokeScale -Property ([System.Windows.Media.ScaleTransform]::ScaleXProperty) -Animation (New-DshKeyframeAnimation -Values @(1.0, $cs, $lo, 1.0) -Ms $cms)
        $null = Start-DshAnim -Target $W.ChokeScale -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) -Animation (New-DshKeyframeAnimation -Values @(1.0, $lo, $cs, 1.0) -Ms $cms)
      }
      # 咳出来这一下才说话
      Show-WhaleBubble -Context $Context -Text (Get-WhaleLine -Context $Context -Kind 'choke' -Reason ([string]$W.ChokeReason)) -HoldMs 2600
      if ($script:DebugMascot) { Write-DshLog '[mascot] 呛到 → 咳出来（+台词）' }
    } elseif ($el -ge $tm.A -and [int]$W.ChokeStep -lt 2) {
      $W.ChokeStep = 2
      if ($W.ChokeShake) { try { $W.ChokeShake.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null); $W.ChokeShake.X = 0 } catch {} }
      if ($script:DebugMascot) { Write-DshLog '[mascot] 呛到 → 停顿（立绘定住一下）' }
    }
  }

  # 立绘状态机（摸头 / 吃饭循环 / 吃饱 / 平时）
  Update-MascotImage -Context $Context

  # 气泡到期收起
  if ($W.BubbleShown -and (Get-Date) -gt $W.BubbleUntil) {
    $W.BubbleShown = $false
  }

  # 待机台词
  if ((Get-Date) -gt $W.NextIdleAt) {
    $W.NextIdleAt = (Get-Date).AddSeconds((Get-Random -Minimum 45 -Maximum 160))
    if (-not $W.BubbleShown) { Show-WhaleBubble -Context $Context -Text (Get-WhaleLine -Context $Context -Kind 'idle') -HoldMs 2600 }
  }

  # 眨眼
  if ($W.Settings.blink -and $W.EyesScale -and (Get-Date) -gt $W.NextBlink) {
    $W.NextBlink = (Get-Date).AddMilliseconds((Get-Random -Minimum 2400 -Maximum 6400))
    $null = Start-DshAnim -Target $W.EyesScale -Property ([System.Windows.Media.ScaleTransform]::ScaleYProperty) -Animation (New-DshKeyframeAnimation -Values @(1.0, 0.08, 1.0) -Ms 210)
  }

  # 发布锚点给伤害数字用
  if ($W.Settings.publishAnchor) {
    # 直接发布挂件左上角（屏幕坐标），伤害数字面板靠它定位
    $x = $W.Window.Left
    $y = $W.Window.Top
    $w = $W.Window.Width
    $h = $W.Window.Height
    # 实际渲染尺寸（缩放后高度跟 Window.Height 可能不一致，按实际值发）
    if ($W.Window.ActualWidth -gt 4) { $w = $W.Window.ActualWidth }
    if ($W.Window.ActualHeight -gt 4) { $h = $W.Window.ActualHeight }
    if ([Math]::Abs($x - [double]$Context.AnchorX) -gt 0.5 -or [Math]::Abs($y - [double]$Context.AnchorY) -gt 0.5 -or
        [Math]::Abs($w - [double]$Context.AnchorW) -gt 0.5 -or [Math]::Abs($h - [double]$Context.AnchorH) -gt 0.5) {
      $Context.AnchorX = $x
      $Context.AnchorY = $y
      $Context.AnchorW = $w
      $Context.AnchorH = $h
      $Context.AnchorDirty = $true
    }
  }

}
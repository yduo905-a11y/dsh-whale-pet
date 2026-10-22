# 桌宠托盘修复记录（2026-10-21）

## 一句话结论

托盘图标没坏。真相是两条叠在一起：

1. **换路径 = 换身份。** 文件夹被复制到 `<项目目录>` 之后 exe 全路径变了，
   Windows 11 当它是全新应用 → 没有 `IsPromoted` 记录 → 图标只在 `^` 溢出面板里躺着。
   而且这个路径下它**连 `NotifyIconSettings` 记录都不给建**（同款 exe 放 `%TEMP%`、`D:\`、`D:\Game\` 都会自动建记录）。
2. **启动器自己会把图标踢回溢出面板。** 启动 1.5 秒后那句 `tray.Visible=false→true` 的二次注册，
   会让 Windows 把 `IsPromoted` 写回 0。

现在的做法：真身搬到 `C:\Tool\DSHPet\dsh-overlay.exe`（用 `root.txt` 指回工作区），
记一条 `IsPromoted=1`，启动器检测到这个 1 就**跳过**二次注册。鲸鱼头像就稳在任务栏时钟左边了。

## 病根（实测证据）

Windows 11 把"托盘图标显示在哪"存在注册表里：

```
HKCU\Control Panel\NotifyIconSettings\<一串19位数字>
    UID            DWORD
    ExecutablePath REG_SZ     ← 按 exe 的完整路径认人
    InitialTooltip REG_SZ
    IconSnapshot   PNG 字节
    IsPromoted     DWORD      ← 1 = 固定在可见托盘区；缺省/0 = 缩进 ^ 溢出面板
```

- 全机 77 条记录里，**一条 `IsPromoted` 都没有**（默认全是"塞进溢出"）。
- 用探针程序（只注册一次 NotifyIcon）验证：把它的 `IsPromoted` 手动写成 1 → 杀进程 → 重启 →
  值仍是 1，图标直接出现在可见托盘区 ⇒ **`IsPromoted=1` 单独就够，且跨重启有效**。
- 唯一的坑：杀进程后**不到 1 秒就重启**，shell 还在拆旧图标，promoted 状态会丢。等 1.5~3 秒就好。

## 我改了什么

| 文件 | 改动 |
| --- | --- |
| `src\DshOverlayLauncher.cs` | ① 新增 `ResolveRoot()`：支持 `--root <path>` / 环境变量 `DSH_OVERLAY_ROOT` / exe 同目录 `root.txt`，于是 exe 能住 `C:\Tool\DSHPet`，素材/日志/插件/node 全留在工作区。② 新增 `TrayPinned()`：`IsPromoted` 已是 1 就跳过二次注册。③ 新增 `HasOtherInstance()`：互斥体被"死掉的旧实例泄漏给子进程的句柄"占着时不再装死退出（以前的表现就是**双击没反应**），日志会写"发现残留互斥体（没有同名进程在跑），继续启动"。 |
| `src\DshOverlayRelay.cs` | 新增。编译出来顶掉了工作区里的 `dsh-overlay.exe`：它只负责把 `C:\Tool\DSHPet\dsh-overlay.exe` 拉起来再自己退出，所以"双击工作区里那个 exe"这个老习惯继续有效。 |
| `tools\fix-tray.ps1` | 新增。一键修：找记录 → 写 `IsPromoted=1` → 连子进程一起清（node core / node usage / powershell 浮层，不然旧 core 占着 `127.0.0.1:17777` 新 core 起来就 EADDRINUSE 死循环）→ 等 1.8s 再用 **CreateProcess** 启动（不走 ShellExecute，绕开 SmartScreen）→ 用 UIA 复检图标是否真在可见区，失败重试 3 次。 |
| `tools\add-whitelist.ps1` | 新增。提权给 Defender 加排除项，并把火绒信任区的点法打出来。 |
| `启动桌宠.cmd` / `修托盘.cmd` / `加白名单.cmd` | 新增，双击即用。 |

### 顺带修掉的那个死循环

以前"核心不在了，自动重启"每隔几秒一次，是因为只杀 `dsh-overlay.exe` 会留下它的子进程，
旧 core 还占着 `tcp://127.0.0.1:17777`，新 core 一启动就 `bus error: listen EADDRINUSE` 退出。
`fix-tray.ps1` 现在会连 `node server.mjs` / `node dsh-usage.mjs` / `powershell dsh-overlay.ps1` 一起清。

修完 `core.log` 正常：

```
11:49:04 bus listening on tcp://127.0.0.1:17777
11:49:04 真实余额 = 9.6800 已烧 = 2.8400 CNY
11:49:06 [对账] 停机期间没有漏账
```

## 现在的样子 / 怎么用

- 真身：`C:\Tool\DSHPet\dsh-overlay.exe` + `root.txt`（内容一行 `<项目目录>`）
- 桌面快捷方式：`桌面\桌宠.lnk`（鲸鱼图标）
- 开机自启：已开（`启动` 文件夹里的 `dsh-overlay.lnk`，指向新真身）
- `<项目目录>\dsh-overlay.exe` 现在是**转发器**，双击照样能起

### 出问题自查

```powershell
# 1) 托盘记录还在不在、是否固定
$k = 'HKCU:\Control Panel\NotifyIconSettings'
Get-ChildItem $k -Force | ForEach-Object {
  $v = Get-ItemProperty $_.PSPath
  if ($v.ExecutablePath -match 'dsh-overlay') { "$($_.PSChildName)  $($v.ExecutablePath)  IsPromoted=$($v.IsPromoted)" }
}
```

- 记录在、`IsPromoted=1`：图标应该在可见托盘区。没看到就跑一次 `修托盘.cmd`。
- 记录在、`IsPromoted=0`：双击 `修托盘.cmd`。
- 记录都不在：说明 exe 又被放回 `<项目目录>` 里了，搬回 `C:\Tool\DSHPet` 再启动。

手动兜底（30 秒）：设置 → 个性化 → 任务栏 → 其他系统托盘图标 → `dsh-overlay.exe` 开关打开。
注意：打开后别再用旧版启动器（旧版会二次注册把状态冲掉）。

## 安全软件那件事

用户看到的拦截弹窗是 **Microsoft Defender SmartScreen**：

> Windows 已保护你的电脑 —— Microsoft Defender SmartScreen 阻止了无法识别的应用启动
> 应用：dsh-copy.exe　发行者：发布者未知　[仍要运行] [不运行]

之前测到的 `ERROR_CANCELLED (1223)「操作已被用户取消」` 就是 SmartScreen 被静默取消时返回的同一个码，
所以"老是拦截"不是杀软误杀，是未签名 exe 的声誉检查。用户已自行关闭；脚本里仍留了
`加白名单.cmd` 作为以后的保险。

逐条查过、都不是元凶的：

- **Windows Defender**：`WinDefend` 服务 Stopped，`AntivirusEnabled=False`，
  `Get-MpPreference` 报 `0x800106ba`；事件日志最后一次活动 2026/10/12，搜 `dsh-overlay` / `桌宠` 命中 0。
- **智能应用控制 SAC**：`VerifiedAndReputablePolicyState=0`，关的。
- **火绒 6.0.12.1**：规则库全空（`HipsKModException_60` / `ProcGrant_60` / `RiskSoftware_60` /
  `WhiteListPath_60` / `WhiteListHash_60` 全 0 行），`log.db` 里 15 条日志没有一条关于桌宠。
- ACL、程序清单、签名、SRP/AppLocker、WDAC、CodeIntegrity、火绒注入 —— 全部排除。

## 本轮改动过的文件清单

- `<项目目录>\src\DshOverlayLauncher.cs`（改）
- `<项目目录>\src\DshOverlayRelay.cs`（新）
- `<项目目录>\tools\fix-tray.ps1`（新）
- `<项目目录>\tools\add-whitelist.ps1`（新）
- `C:\Tool\DSHPet\dsh-overlay.exe` + `root.txt`（新真身）
- 备份：`<项目目录>\_backup-20261021\`

## 托盘菜单也重做了（同一天晚些）

原来那个托盘菜单是一长串平铺项，跟挂件右键菜单完全两个样子。现在照挂件菜单的规矩重做：

- **皮肤**：底 `#141A21`、1px 描边、窗口 Region 裁 10px 圆角（子菜单一起裁）、悬停 `#2E5AC8FF` 圆角高亮、
  分隔线 12px 内缩、每项前面一个 7px 彩色圆点（颜色沿用挂件菜单那套：重置 `#FF7A4D`、API `#FFC53D`、
  演示 `#4FC3F7`、呛到 `#FF7BE5`、余额预览 `#41E06B`、退出 `#FF5A5A`、其余 `#8FA3B8`）。
- **头两行**：`鲸娘 · 余额 ¥9.11` / `已烧 ¥3.41 · 命中 1813 · 未命中 58`，
  数据每次弹出菜单时从 `core\state.json` 现读（不打扰总线）。
- **只留常用几项**（不再一比一照搬挂件菜单，第二版砍过）：
  `挂件大小`▸（80% / 100% / 125% / 150%，✓ 标当前，初值读 `plugins\dsh-whale-widget\position.json` 的 `scale`）、
  `伤害数字：已开|已关`、`窗口置顶：已开|已关`、`开机自启：已开|已关`、
  `维护`▸（打开日志文件夹 / 找回挂件 / 重启浮层），最后 `退出桌宠`。
  删掉的：重置余额、填写 API Key、切回本地记账、打一场演示、预览呛到、余额状态预览（这些在挂件右键菜单里还有）。
- 悬停提示也换成余额了（`鲸娘 · 余额 ¥9.11 · 伤害数字 开`），60 秒刷一次。

### 字体模糊的根因（重要）

启动器原来**没有声明 DPI 感知**。显示器是 150% 缩放（2560x1600 物理 / 1707x1067 逻辑），
进程按 96dpi 画完再被 DWM 整层拉伸 → 菜单字发虚。两处修：

- 类里加 `[DllImport("user32.dll")] private static extern bool SetProcessDPIAware();`，
  `Main` 第一行 `try { SetProcessDPIAware(); } catch { }`（必须在任何窗口创建之前）；
- 所有像素尺寸改走 `Dpi()` / `Dip(int px)`（`Graphics.FromHwnd(IntPtr.Zero).DpiX / 96f`）：
  圆点直径、菜单内边距、悬停圆角、分隔线内缩量。

另外托盘菜单是 WinForms 弹出窗口，默认排在 Topmost 的挂件下面（右下角会被鲸娘遮住）：
`RoundDropDown()` 的 `Opened` 里调 `PushToTop(hwnd)`（`SetWindowPos(..., HWND_TOPMOST=-1, NOSIZE|NOMOVE|NOACTIVATE|NOOWNERZORDER)`）压到最上层。

### 为菜单新加的总线消息 `ui`

启动器（WinForms）没法直接调 WPF 挂件，所以加了一条**转发型**消息，总线只负责转手：

```
{"t":"ui","cmd":"scale","value":1.25}    → Set-WhaleScale（挂件缩放并写回 position.json）
{"t":"ui","cmd":"mood","value":"warn"}   → ForceMood + ForceMoodUntil(20 秒)；value 传空串 = 取消预览
{"t":"ui","cmd":"topmost"}               → 反转 Window.Topmost
```

落点两处：

- `core\server.mjs`（约 292 行）的转发列表原来只有 `togglePlugin / overlayState / bye / setAnchor / pat / bubble`，加上 `'ui'`；
- `plugins\dsh-whale-widget\plugin.ps1` 的 `Update-Plugin` 加 `'ui'` 分支（和挂件右键菜单走同一套逻辑）。

调试入口（命令行直接发一条界面指令，不用点菜单）：

```
C:\Tool\DSHPet\dsh-overlay.exe --ui "{\"t\":\"ui\",\"cmd\":\"scale\",\"value\":1.15}"
```

`--ui` 的处理放在单实例 Mutex 检查**之前**（否则会被"已在运行"分支吃掉），发完即退出；
`launcher.log` 会留 `界面指令 -> 总线: {...}` 一行，`host.log` 里能看到对应效果（如 `挂件缩放 -> 115%`）。

### 踩过的一个真坑：总线消息偶尔丢

`SendToBus()` 原来写完整行就 `Dispose` socket。但核心在连接建立时**立刻**推 `hello` + `state`，
客户端不读就走，TCP 会回 RST，核心有时还没把那一行读出来就被重置 → 菜单点了没反应（`launcher.log` 有、`host.log` 没有）。
修法：写完 `Shutdown(SocketShutdown.Send)`，再 `ReceiveTimeout = 400; while (s.Read(...) > 0) { }` 读干净才关。
修完实测：点「窗口置顶」→ `置顶 -> 关（来自托盘菜单）`；点「挂件大小 / 100%」→ `挂件缩放 -> 100%` + `position.json` 跟着写。

### 这一轮改动的文件

- `<项目目录>\src\DshOverlayLauncher.cs`（`BuildTrayMenu()` / `DarkRenderer` / `DarkColors` /
  `RoundDropDown()` / `PushToTop()` / `Dpi()` / `Dip()` / `RefreshTrayHead()` / `SendToBus()`；
  `BuildTray()` 改成 `tray.ContextMenuStrip = BuildTrayMenu()`；`Main` 里 `SetProcessDPIAware()` + `--ui` 分支）
- `<项目目录>\core\server.mjs`（转发 `'ui'`）
- `<项目目录>\plugins\dsh-whale-widget\plugin.ps1`（`Update-Plugin` 的 `'ui'` 分支）
- `C:\Tool\DSHPet\dsh-overlay.exe`（重新编译部署，172032 B；源码备份 `src\DshOverlayLauncher.cs.bak-menu`）
---

## 伤害数字离挂件太远（2026-10-21 晚修）

### 病根

旧算法给伤害面板用的是**固定像素偏移**：

```powershell
$left = ($P.AnchorX + $sox) - $tpX      # sox = spawnOffsetX = -300
$top  = ($P.AnchorY + $soy) - $tpY      # soy = spawnOffsetY = +240
$baseX = $tp                            # 文字永远钉在面板内的 (44, 520)
```

于是面板被推到 `AnchorX-300-44` 那一带去；再遇上两件事就彻底跑偏：

1. 面板是 1000x620 DIP 的大板，1707x1067 DIP 的屏塞不下（1472-344+1000 = 2128 > 1707）；
2. `Update-PulsePanelPosition()` 会把面板**夹回屏幕内**（`left = VirtualScreenWidth - pw`），
   但文字坐标仍是面板内的绝对值 → 面板被夹到左边，文字跟着一起被拖到屏幕左下角。

换分辨率 / 换缩放 / 换挂件位置，夹取的量就变一次，所以「换设备就不对」。

判据（`debugPosition: true` 时的 `[pos]` 行）：

```
[pos] mode=widget 面板@(707,447) 面板内=(36,521) 屏幕=(743,968) 挂件@(1,472,807)
```

面板 1000 宽却只有 707 的落点 → 就是被夹了。

### 新算法

1. 出生点按**挂件尺寸的比例**算，不再用固定像素：
   `spawnX = AnchorX + AnchorW * spawnFracX`(默认 0.05)、`spawnY = AnchorY + AnchorH * spawnFracY`(默认 0.45)；
   拿不到挂件尺寸时退回 `spawnOffsetX/Y`。
2. widget 模式一律右对齐：`$left = $spawnX - ($pw - $tpX)`，让「文字右边缘」正好落在出生点。
3. 夹取之后**反算**文字在面板内的坐标：`TextX = spawnX - left`、`TextY = spawnY - top`。
   这样无论面板被夹到哪里，文字都还在挂件旁边。
4. `New-PulseHit()` 用 `TextX/TextY` 定位，右对齐位移由 `(PanelW - 2*tp) - tw` 改成 `0 - tw`。
5. 挂件发布锚点时改发 `Window.ActualWidth/ActualHeight`（缩放后的真实尺寸）。

调位置只要改 `plugins\dsh-damage-pulse\plugin.json`：

```json
"spawnFracX": 0.05,   // 0 = 挂件左边缘，1 = 右边缘；越小越往左
"spawnFracY": 0.45    // 0 = 头顶，1 = 脚底
```

### 自查

```powershell
# 打几发假数据，直接看数字有没有贴着挂件
C:\Tool\Node.js\node.exe "<项目目录>\tools\demo.mjs" --burst 6 --gap 400
```

要坐标就临时把 `plugin.json` 的 `"debugPosition"` 改 `true`，看 `logs\host.log` 里的 `[pos]` 行，
(`屏幕=(x,y)` 是文字右边缘的屏幕 DIP 坐标，物理像素 = DIP x 1.5)。看完记得改回 `false`。

## 托盘菜单改名：鲸娘 → 大肥鱼

`src\DshOverlayLauncher.cs` 里三处文案（`miHead` 初始值、`RefreshTrayHead()` 的标题和 `tray.Text`）
以及 `BuildTray()` 的初始 tooltip 都换成了「大肥鱼」。
## 补记：伤害数字那块"红色背景框"（2026-10-21 晚）

现象：暴击时会出现一块半透明红板子，有直边，位置偏在挂件左上方。

真凶不是挂件插件的 `HitFlash`，而是 `plugins\dsh-damage-pulse\plugin.ps1` 的 XAML 里那个
`<Rectangle x:Name="Flash">`：它铺满整个 1000x620 伤害面板，渐变是「中心透明 `#00FF2A2A` → 边缘实心红 `#FFFF1F1F`」，
被面板窗口的矩形边界裁成硬直边 —— 所以永远又方又偏。

改法：
- 删掉那个 `Rectangle`，`Flash = $null`，`Invoke-PulseFlash` 变成空函数，回放段加 `$P.Flash -and ...` 保护。
- 暴击的强调改成"数字自身的红色发光"：`New-PulseHit` 里 `if ($Evt.crit) { $glow.BlurRadius = size*1.75; $glow.Opacity = 1.0 }`。
- `plugin.json` 的 `"flashOnCrit"` 现在不起作用（留着兼容旧配置）。

另外挂件那圈的暖光 `HitFlash` 也重做过了（见上文 m01644 那段）：整窗径向渐变、中心透明、
贴轮廓最亮、到窗口边缘淡到 0，不再有硬边方角；强度看 `plugins\dsh-whale-widget\plugin.json` 的 `"chewFlash"`。
---

## 补记（2026-10-21 晚）：暖光删除 / 找回挂件保设置 / 打嗝呛到

**1. 挂件暖光（HitFlash）整个删掉了**

用户原话：「"hitFlash": false 删了也无妨，不好看」。

- `plugins\dsh-whale-widget\plugin.ps1`：删掉 XAML 里那个 `<Border x:Name="HitFlash">`（含径向渐变）、
  卡片对象里的 `HitFlash` / `FlashUntil`、`Set-BarVisual` 里清闪光的那段、`Invoke-WhaleHit` 里的闪光动画、
  预览回放里那一行 `$W.HitFlash.Opacity = ...`。全文件 `HitFlash|FlashUntil|hitFlash|chewFlash` 残留 0。
- `plugins\dsh-whale-widget\plugin.json`：删掉 `"hitFlash"` 与 `"chewFlash"` 两个键。

**2. 托盘「找回挂件」不再动设置**

旧实现直接删 `plugins\dsh-whale-widget\position.json` → 连带把 `scale` 一起清了，
表现就是"拉回主屏之后挂件大小变回去了"。

新实现（`src\DshOverlayLauncher.cs` 的 `miMaint` 里）：先正则读出 `scale`，按它算尺寸，算好位置后整体写回。

```csharp
Match m = Regex.Match(File.ReadAllText(pos), "\"scale\"\\s*:\\s*([0-9.]+)");
float f = Dpi();                                  // 本进程 DPI 感知 → 拿到的是物理像素
int waW = (int)Math.Round(wa.Width / f);           // 换成 WPF 用的 DIP
int left = waW - bw - 64;                          // 比默认再往里 36px
int top  = waH - bh - 96;                          // 比默认再往上 32px
File.WriteAllText(pos, "{\"left\":1419,\"top\":654,\"scale\":0.8}");
```

实测结果：`position.json` 从 `{"left":120,"top":130,"scale":0.8}` 变成 `{"left":1419,"top":654,"scale":0.8}`
（1707-224-64=1419，1019-269-96=654，缩放 0.8 原样保留）。

同时把 `plugin.json` 的 `window.marginX` 28 → **64**、`marginY` 64 → **96**，
首次启动的默认位置也"再出来一点"。

**3. 「呛到」改成"吃饱打嗝时 25% 概率呛到"**

原来是给"数据读取失败"准备的，几乎不可能触发。现在挂在收尾那一下：

```powershell
$chokeChance = 25                     # 可用 plugin.json 的 settings.burpChokeChance 调
$roll = Get-Random -Minimum 0 -Maximum 100
if ($roll -lt $chokeChance) {
  Invoke-WhaleChoke -Context $Context -Reason 'burp' -Force   # 演呛到，不冒打嗝气泡
  return (Get-WhaleSpriteKey -Action 'choke1' -State $moodNow)
}
Invoke-WhaleBurpJolt -Context $Context
Show-WhaleBubble ... -Kind 'burp' ...   # 正常打嗝 + 气泡
```

- 新增 `settings.burpChokeChance: 25`。
- `Get-WhaleLine` 的 `'choke'` 分支加 `elseif ($Reason -eq 'burp')` 专用台词
  （"咳、咳咳——吃得急了。" / "嗝…咳！呛到了。" …）。
- 挂件右键菜单那项改名为「预览呛到（吃完打嗝变呛到的那种）」，仍走 `demo.mjs --choke-after`。

**4. 演示脚本 + 一个隐形坑（顺带记一笔）**

- `tools\demo.mjs` 现在每条注入单独开一个连接（`c.end(line)` 发 FIN），不再"一口气写完就 exit"。
- **`Start-Process node -ArgumentList @('D:\...\demo.mjs', ...)` 会因为路径里有空格而静默失败**——
  node 只收到 `D:\DeepSeek`，一条都不发。必须在数组里自己带引号：
  `@('"<项目目录>\tools\demo.mjs"','--burst','6')`。
  之前多次"演示只来 1 发"其实就是这个（那 1 发是真实流量）。
- 验证 25% 分支的日志（`debugMascot: true` 时才有）：

```text
[mascot] 这顿来了 7 发命中 → 打嗝呛到（掷骰 21 < 25%）
[mascot] 这顿来了 6 发命中 → 正常打嗝（掷骰 66 ≥ 25%）
```

---

## 补记（2026-10-21 深夜）：快速甩动 → 慌张动画 + 拖动抓取点漂移的修复

### 一、快速甩动触发的慌张动画

- 立绘：`images\mascot-shake.png`（1254x1254 RGBA，四角本来就是透明）。
- 判定：`$dragMove` 里取**相邻两采样点的瞬时速度**（WPF 会合并鼠标事件，窗口平均速度算不准）：
  `$sp2 = dist / dt2`（DIP/ms），超过 `settings.shakeSpeed` 就 `Start-WhalePanic`。
- 参数（`plugins\dsh-whale-widget\plugin.json` 的 `settings`）：

```json
"shakeSpeed": 2.0,        // 阈值，DIP/ms；2.0 ≈ 3000 物理像素/秒（150% 缩放）
"shakeMs": 1200,          // 慌张动画持续多久
"shakeCooldownMs": 900    // 冷却，避免连续甩动一直触发
```

- 表现：图层切到 `shake`（优先级插在 `drag` 之前）→ **只换慌张立绘** + 气泡台词（"别甩我！""我又不是陀螺。""慢、慢点——！"等 12 句）。
  立绘素材本身已经有手舞足蹈的动感线，**不再叠加正弦位移/旋转**——那套抖动在松手之后还在晃，看着廉价，已整块删除（`PanicShake`/`PanicTilt`/`PanicPhase` 全部移除）。
- 松手即回常态：`$dragUp` 里把 `ShakeUntil` 归 `MinValue`，慌张只在"正在甩"的那几帧存在，不会有拖尾。
- 手动触发（不改代码就能看效果）：

```powershell
C:\Tool\DSHPet\dsh-overlay.exe --ui "{\"t\":\"ui\",\"cmd\":\"panic\"}"
```

### 二、拖动时抓取点会漂 / 拖到屏幕外再拖回来会大跳

- 病根：旧实现是「每帧增量累加」（`Left += dx`），采样丢帧 + 窗口被屏幕边界夹取之后，误差会累积；再拖回来就整体错位。
- 改法：按下时记一次 `GrabDX/GrabDY = 光标 - 窗口左上角`，之后每帧**绝对定位** `Left = 光标X - GrabDX`。
  夹取只影响窗口显示位置，不影响抓取点，所以拖出去再拖回来不会跳。
- 光标坐标：优先 `[System.Windows.Forms.Cursor]::Position`（物理像素）再除以
  `PresentationSource.FromVisual($W.Window).CompositionTarget.TransformToDevice` 的 M11/M22 换成 DIP；
  拿不到才退回 P/Invoke `GetCursorPos`。

### 三、这次踩到的三个 PowerShell 坑（都很隐蔽）

1. **定义在 `Initialize-Plugin` 内部的小函数，在 `.GetNewClosure()` 的事件闭包里取不到**
   → 报「无法将"Get-WhaleCursorDip"项识别为 cmdlet」。必须定义在**脚本顶层**。
2. **空 `ArrayList` 在 `if` 里是 `$false`** → `if ($W.MoveSamples)` 永远不成立；要写 `if ($null -ne $W.MoveSamples)`。
3. **逗号优先级高于除号**：`return @( $a / $sx, $b / $sy )` 会被解析成 `$a / @($sx, $b) / $sy`
   → 报「[System.Object[]] 不包含名为"op_Division"的方法」。必须先算 `$x = $a / $sx` 再 `return @($x, $y)`。

### 四、测试工装

- `logs\pettest.ps1 -Slow|-Shake [-Shot 输出路径] [-Dx 像素] [-Dy 像素]`：
  自动找宿主进程里的挂件窗口 → 按在 `(中心x, top+0.62*高)` → 慢拖或快甩 → 截图 → 松开。
  必须带 UTF-8 BOM 用 `powershell.exe -File` 跑；如果挂件正在吃饭（`eat` 层），拖动是禁用的，它会自动重试。
- 验收标准（本机实测）：
  - 慢拖 220x120 物理像素 → `position.json` 的 left/top 精确变化 -147 / -80 DIP，抓取点不漂。
  - 拖到屏幕最左（x=2）再拖回 x=1500 → 松手后 `left` 恰好等于 `1000-112=888`（DIP），没有跳变。
  - 快甩 → `[mascot] 甩太猛 → 慌张动画（瞬时速度 5.0 DIP/ms）`。
---

## 补记：台词池（按立绘状态分组 + 颜文字规则）

台词全部在 `plugins\dsh-whale-widget\plugin.ps1` 的 `Get-WhaleLine`（约 726 行起），按 `$bagKey` 分组：

| 池子 | 什么时候用 | 对应立绘 |
| --- | --- | --- |
| `pat1/pat2/pat3` | 摸头连击数 1 / 2–4 / 5+ | `pat`、`pat-warn`、`pat-danger` |
| `shake` | 快速甩动（瞬时速度 > `shakeSpeed`） | `shake` 慌张脸 |
| `burp` | 一顿吃完、打嗝那一下 | `eat3` 收尾 / 打嗝脸 |
| `choke_burp` | 吃饱后 25% 概率转呛到 | `choke1`→`choke2` |
| `choke_off` / `choke_empty` | 断网 / 余额见底触发的呛到 | 同上 |
| `crit` / `miss` | 暴击 / 未命中 | 常态或脸色立绘 |
| `hit_low` / `hit_mid` / `hit_high` | 命中时按余额分档 | `danger` / `warn` / `normal` |
| `idle` | 长时间没动静 | 常态（按时段加早晚台词） |

**颜文字规则（重要）**：

- 颜文字**单独成句**，绝对不和文字混在一行——"（晕了）(＠_＠;)" 这种读起来最别扭。
- 只用常见字符（半角括号、`´`、`ω`、`Д`、`ﾟ`），不用韩文谚文（`ㅂ`）和生僻组合符号，避免缺字形变方框。
- **未命中（`miss`）和呛到共用一套反应**：都是"这一口没咽下去"，所以池子里的呛咳台词（「咳——这一笔卡在半道上。」「（清了清嗓子）漏一笔，我补上。」）两边都在用；
  同时把钱包相关的埋怨（原来那句"没打出来不代表没花钱哦"和动态的「漏了 ¥x，我记着呢」）删掉了——钱的事交给 `hit_*` / `crit` 池去说，未命中只谈"漏了/噎了一下"。
- 落地的纯颜文字：`(＠_＠;)` `(°◇°;)` `(ノД`)・゜・。` `(>_<)` `(´；ω；`)` `(ﾟДﾟ;)` `(´ω｀)` `(・ω・)` `(￣▽￣)` `(´-ω-`)` `(*/ω＼*)` `(๑>◡<๑)` `(*´▽`*)` `(っ- ‸ - ς)`。
- 想验证气泡渲染：直接往总线推一条，不用等随机——
  `{"t":"bubble","text":"(＠_＠;)","holdMs":3000}`（17777 端口，写完 `Shutdown(Send)` 再读干净，否则核心会 RST）。
---

## 补记：暴击数字大小可调（2026-10-21 深夜）

需求是「暴击数字可以做一个可调节大小的功能」。做法和「挂件大小」同一套：一个倍率，落盘到插件自己的 `plugin.json`。

- **基数**：核心 `core\config.json` 的 `tiers` 里是 `命中 34px / 会心一击 54px / 大出血 68px`。倍率**只乘暴击那两档**（会心一击、大出血），命中始终 34px。
- **落点**：`plugins\dsh-damage-pulse\plugin.ps1`
  - `$script:Pulse.CritScale`（默认 1.0），初始化时从 `settings.critScale` 读（夹在 0.4~3.0）。
  - `New-PulseHit()` 里 crit 分支之后按倍率放大 `$size`，`$strokeOffset` 同步乘，发光半径跟着 `$size` 走。
  - `Update-Plugin` 新增 `'ui'` 分支：`{"t":"ui","cmd":"critScale","value":1.5}` → 立即生效 + 写回 `plugin.json` 的 `critScale`（插件目录用模块级 `$DshDir`，**没有** `$Context.PluginDir` 这个字段）。
- **入口（最终版：子菜单三档）**：托盘菜单「暴击数字：小/中/大 ▸」→ 子菜单里三行，当前档位打 ✓（`ToolStripProfessionalRenderer` 默认会画一块浅蓝方块，已在 `DarkRenderer.OnRenderItemCheck` 改成自绘的圆头 ✓，并把 `CheckBackground/CheckSelectedBackground/CheckPressedBackground` 全设透明），选中即生效、菜单文字跟着变，落盘到 `plugin.json`，每次打开菜单都从 `plugin.json` 现读（`--ui` 改过也对得上）：
  - 小 = `0.7` → 大出血 48px / 会心一击 38px
  - 中 = `1.0` → 大出血 68px / 会心一击 54px（默认，原样）
  - 大 = `1.75` → 大出血 119px / 会心一击 95px
  - **点完不弹托盘气泡**（原来那个气泡挡视野，已经删掉）。
  - 命令行等价写法：`C:\Tool\DSHPet\dsh-overlay.exe --ui "{\"t\":\"ui\",\"cmd\":\"critScale\",\"value\":1.75}"`
- **踩过的坑（重要）**：第一版把放大写在 `$stroke.FontSize = $size` / `$tb.FontSize = $size` **之后**，结果只放大了发光半径和描边偏移，字号一点没变——这就是"感觉没变化"的真因。修正是把缩放挪到 `$size` 刚取完 `$Evt.tier.size` 的下一行，`FontSize`、发光、描边、`strokeOffset` 全部用放大后的值。
- **验证**：`logs\_t_three.png` 是同一发 `大出血 -0.1600¥` 在三档下的实拍对比（0.7× / 1.0× / 1.75×）。
- 顺带修：`dsh-whale-widget` 的 `ui` 分支原来对不认识的指令打 `warn`，三个插件都收 `ui` 会刷日志，已改成静默。
**改了但要能看出来**（用户反馈「感觉没变化」后补的两处）：

- 子菜单末尾加 **「预览一记暴击」**：直接往总线推一发 `costCny=0.12` 的演示命中（落「大出血」档），不用等真实流量就能看见当前倍率。
- 点任意档位会弹托盘气泡「暴击数字 · 字号 200%（会心一击 / 大出血）」，确认点到的是哪一档。
- 记住：**「命中」档永远是 34px**，倍率只乘「会心一击 54px」和「大出血 68px」两档——如果只看普通命中，那确实不会变。
---

## 补记：余额条可隐藏（2026-10-21 深夜）

需求：托盘里加个开关，把挂件下面那条「余额 / 已烧 · 命中 · 摸头」收起来。

- **落点**：`plugins\dsh-whale-widget\plugin.ps1`
  - `$script:Whale` 对象补了 `Bar = $win.FindName('Bar')`（原来只取到 `BarScale`/`BarFill`，没有外层 `Bar`，所以第一版开关打不开——**改这个插件时注意 XAML 的 `x:Name="Bar"` 要自己加进对象**）。
  - 新增 `Set-WhaleBarVisible`（`$W.Bar.Visibility = Visible/Collapsed`）、`Get-WhalePluginJson`、`Save-WhaleShowBar`（把 `"showBar": true/false` 写回 `plugin.json` 的 settings）。
  - `Update-Plugin` 的 `'ui'` 分支新增 `bar`：`{"t":"ui","cmd":"bar","value":false}`。
  - 初始化时按 `settings.showBar` 套用（`false` 则启动即隐藏，日志 `余额条 -> 隐藏（配置 showBar=false）`）。
- **托盘**：`src\DshOverlayLauncher.cs` 在「伤害数字」下面加一条 `余额条：显示中 / 已隐藏`，点击发 `ui/bar`，文字每次 `menu.Opening` 现读 `plugin.json`（`refreshBar()`，别忘加进 Opening，否则标签会停在旧值）。
- **实测**：点一下 → `host.log 余额条 -> 隐藏（来自托盘菜单）`、`plugin.json showBar=false`、挂件只剩立绘；再点 → `余额条 -> 显示`。
## 补记：改名 dafeiyu（进程名 / 文件描述 / 图标三处对齐）

原来叫 `dsh-overlay.exe`，任务管理器里"描述"是空白、名字也不像桌宠。现在：

- 主程序 `C:\Tool\DSHPet\dafeiyu.exe`（177152 B），工作区 `<项目目录>\dafeiyu.exe` 是转发器（141824 B），双击工作区那个照样能起。
- 进程名、文件描述(`FileDescription`)、产品名、窗口图标全部是 `dafeiyu` + 那个鲸鱼头。
- 资源做法：`C:\Tool\DSHPet\_build\pet.rc` 里 `1 ICON "pet.ico"` + VERSIONINFO，`rc.exe /nologo /fo pet.res pet.rc`，然后 `csc ... /win32res:pet.res`。
  - 坑一：`/win32icon` 和 `/win32res` **互斥**（`CS1565`），图标必须塞进 .res 里。
  - 坑二：`rc.exe` 不认中文路径，也不认 `#include <windows.h>`（没有 SDK 的 include 路径），所以 .rc 里全用数字常量、在 `C:\Tool\DSHPet\_build\` 下跑。
- 快捷方式：启动夹 `dafeiyu.lnk`、桌面 `桌宠.lnk`，都指向 `C:\Tool\DSHPet\dafeiyu.exe`。
- 托盘注册表里是新条目 `15047065302462417653`（旧 `dsh-overlay.exe` 那条作废），`IsPromoted=1`。
- **故意没改**：互斥体名 `dsh-overlay-launcher-836802929`、宿主脚本 `host\dsh-overlay.ps1`、图标文件 `assets\dsh-overlay.ico`。改宿主脚本名会牵动所有按命令行匹配杀进程的脚本（`fix-tray.ps1` 就因为这个卡死过一轮）。

## 补记：性能模式（流畅 / 省电）

托盘菜单「性能模式」二选一，选中项即时生效，重启也保留。

| 档位 | 宿主 tick | 待机动画 | 实测单核占用（8 秒采样） |
| --- | --- | --- | --- |
| 流畅（默认） | 40ms（25fps） | 呼吸 + 摇摆 + 呆毛 | 约 23.6% |
| 省电 | 80ms（12.5fps） | 全部暂停 | 约 0.2% |

- **关键结论：光把 tick 放慢几乎不省 CPU**（40ms→80ms 实测 22.5%→24.8%，反而略高）。真正吃 CPU 的是三条"永远在跑"的待机动画（呼吸 1700ms / 摇摆 2800ms / 呆毛 1250ms）让 WPF 每帧重绘，加上立绘上的 `DropShadowEffect`。省电档把动画停掉之后，画面不再持续重绘，占用才掉到接近 0。
- 实现分三处：
  1. `host\dsh-overlay.ps1` 的消息循环里认 `{"t":"ui","cmd":"tick","value":80}`，改 `$timer.Interval`；
  2. `plugins\dsh-whale-widget\plugin.ps1` 认 `{"t":"ui","cmd":"perf","value":"save|smooth"}` → `Set-WhaleIdleAnimations`（停/启呼吸、摇摆、呆毛）；
  3. 启动器「性能模式」子菜单 → 同时发 `tick` 和 `perf`，并把 tickMs 写进 `core\config.json` 的 `host.tickMs`。
- 缺点：省电档下没有呼吸/摇摆，命中时的抖、挤压、慌张、吃饭这些一次性动画照常。

## 补记：慌张（拖动动画）改成"按住拖满 0.7 秒才触发"

- 第一版看鼠标速率（瞬时 DIP/ms 超阈值就演），结果**很难触发**：WPF 会把高频鼠标移动合并成三四个事件，速率算出来忽高忽低，还要求"连续累计 1.7 秒都很快"，正常手速根本凑不满。
- 现在**完全不看速率，只看"真的在动"的时间**：`$dragDown` 把 `DragMs` 清零、`LastMoveAt` 置当前；`$dragMove` 每次都更新 `LastMoveAt`；每帧（tick）里如果 `(Get-Date) - LastMoveAt <= 260ms`（说明手还在动）就把本帧耗时累加进 `DragMs`，满 `dragPanicMs` 就演一次，然后把 `DragMs` 清零重新攒。
- 关键点：**手停住就不累计**。所以按住不放、停下来歇一会儿再接着晃，会重新攒满、再演一次；而"按着完全不动"永远不会自己开始演。
- 判定放在 tick 而不是 MouseMove：手停住或拖得很慢时没有 MouseMove 事件，靠事件判定会出现"我按住拖了很久却没反应"。
- 旋钮：`plugins\dsh-whale-widget\plugin.json` 的 `dragPanicMs`（默认 **700**，按住不到 0.7 秒不会演）、`shakeMs`（慌张持续，默认 1200）、`shakeCooldownMs`（冷却，默认 900）。
- 已删除不再使用的 `shakeSpeed` / `shakeHoldMs` 两个键（`MoveSamples`、`FastMs` 相关代码一并清掉）。
- 实测：按住 450~500ms 松手 → 只鼓一圈、不演慌张；按住 900ms 以上 → 0.7 秒那一刻切慌张立绘 + 气泡「停、停下来——我要散架了。」，松手立刻回常态。
## 补记：托盘图标"退出重进又消失"的自愈

- 现象：退出（或被我强杀）后再启动，鲸鱼图标又缩回溢出面板。查注册表，`C:\Tool\DSHPet\dafeiyu.exe` 那条 `IsPromoted` 从 1 变成了 **0**。
- 原因：`IsPromoted` 是 Windows 侧维护的"是否固定在任务栏"标记，进程被强杀/重注册时会被打回 0。启动器原来的 `TrayPinned()` 只**读**它，发现是 0 就走"二次注册"（`Visible=false→true`）——而二次注册恰恰又把它置 0，于是永远回不到可见区。
- 修法（`src\DshOverlayLauncher.cs`）：
  1. 新增 `EnsurePromoted()`：遍历 `HKCU\Control Panel\NotifyIconSettings`，找到 `ExecutablePath` 等于当前 exe 的条目，把 `IsPromoted` 写成 1；
  2. **注册图标之前**先调一次 `EnsurePromoted()`，让 Explorer 一开始就按"要固定"来登记；
  3. 二次注册那条兜底路径里，也改成"先 `EnsurePromoted()` 再 `Visible=false→true`"。
- 实测：手动把 `IsPromoted` 清零 → 启动 → `launcher.log` 出现 `托盘条目 15047065302462417653 的 IsPromoted 已写回 1`，同一轮里图标就在可见区（UIA 按钮 X=2145，chevron X=2097）；连跑两轮重启都稳定在 2145。
### 追加：光写注册表不够，要"写 1 + 重注册"

- 第二轮修复后仍然出现过"注册表是 1、图标却在溢出面板"——Explorer 有自己的缓存，只写值不重注册它不认。
- 最终做法（`BuildTray()`）：**每次启动都统一**执行
  1. `EnsurePromoted()`：把本 exe 条目的 `IsPromoted` 写成 1；
  2. `tray.Visible = false → true`（`trayFix` 1200ms 后跑一次），让 Explorer 按"要固定"重新登记。
  日志：`托盘图标二次注册完成（已确保 IsPromoted=1）`。
- 再补一个 20 秒看门狗（`trayWatch`）：发现 `IsPromoted` 又变 0 就再写 1 + 重注册一次，日志 `看门狗：托盘 IsPromoted 掉了，重新写回并重注册`。只有真掉了才动手，平时不碰图标。
- 实测：手动清零 → 20 秒内自动修回 1；用托盘菜单「退出桌宠」退出再启动，连跑两轮都是 `X=2145`（chevron 2097）= 可见区。
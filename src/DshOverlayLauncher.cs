// dsh-overlay.exe —— 桌宠启动器（无黑窗口 / 托盘菜单 / 进程守护）
// 编译：build-exe.cmd（用 VS 自带 Roslyn csc，目标 .NET Framework 4.x，无需装任何东西）
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

namespace DshOverlay
{
    internal static class Program
    {
        private const string MutexName = "dsh-overlay-launcher-836802929";

        private static string root;
        private static string nodePath;
        private static string pshPath;
        private static int busPort = 17777;
        private static bool overlayVisible;
        private static Process coreProc;
        // Host handle: used ONLY to read its exit code for diagnostics.
        // We do NOT redirect its stdio (see StartHost).
        private static Process hostProc;
        private static bool hostDeathLogged;
        private static NotifyIcon tray;
        private static System.Windows.Forms.Timer watchdog;
        private static bool stopping;
        private static int hostRestarts;
        private static int coreRestarts;
        // DSH 用量旁听进程：把 ~/.dsh 的 token 增量换算成伤害注进总线
        private static Process usageProc;
        private static int usageRestarts;
        private static bool usageDeathLogged;
        private static DateTime hostStartedAt = DateTime.MinValue;
        private static DateTime hostBackoffUntil = DateTime.MinValue;
        private static DateTime hostRestartWindowStart = DateTime.MinValue;
        private static int hostRestartWindowCount;
        private static readonly object logLock = new object();

        // 宿主启动后至少等这么久再判死（避免刚起来就被误判成“反复退出”）
        private const int HostSettleMs = 12000;
        // 60 秒窗口内最多连续重启 4 次；到顶不是永久放弃，而是歇 30 秒再来
        private const int HostRestartBurst = 4;
        private const int HostRestartWindowSec = 60;
        private const int HostRestartCooldownSec = 30;

        private static string LogDir { get { return Path.Combine(root, "logs"); } }
        private static string PidHost { get { return Path.Combine(LogDir, "host.pid"); } }
        private static string PidCore { get { return Path.Combine(LogDir, "core.pid"); } }
        private static string PidUsage { get { return Path.Combine(LogDir, "usage.pid"); } }
        private static string StopFlag { get { return Path.Combine(LogDir, "stop.flag"); } }
        private static string BalloonRequest { get { return Path.Combine(LogDir, "balloon.request"); } }
        // 用户手动把图标拖进溢出区（任务栏 ^）后，我们记住这个选择，下次启动不再强行固定回来。
        // 文件存在 = 用户要它待在溢出区；不存在 = 固定在任务栏。
        private static string TrayHiddenFlag { get { return Path.Combine(LogDir, "tray-hidden.flag"); } }

        // DPI 感知：必须在建任何窗口之前声明。这台机器桌面是 150% 缩放，
        // 不声明的话整个进程按 96dpi 画完再被 DWM 拉伸 1.5 倍，菜单上的字就糊了。
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [STAThread]
        private static void Main(string[] args)
        {
            try { SetProcessDPIAware(); } catch { }

            root = ResolveRoot(args);

            bool wantOverlay = HasArg(args, "--overlay");
            bool wantStop = HasArg(args, "--stop");
            bool wantPreview = HasArg(args, "--preview");
            bool wantHelp = HasArg(args, "--help") || HasArg(args, "-h") || HasArg(args, "/?");

            if (HasArg(args, "--autostart")) { SetAutostart(true); return; }
            if (HasArg(args, "--no-autostart")) { SetAutostart(false); return; }

            if (wantHelp) { ShowHelp(); return; }

            if (wantStop) { StopEverything(true); return; }

            if (wantPreview) { RunPreview(); return; }

            // 调试/脚本用：dsh-overlay.exe --ui "{\"t\":\"ui\",\"cmd\":\"scale\",\"value\":1.25}"
            // 直接把一条界面指令丢给总线（托盘菜单点下去走的就是这条路），然后退出。
            // 必须放在单实例检查之前，否则桌宠已经在跑时这条会被当成"第二个实例"吃掉。
            if (HasArg(args, "--ui"))
            {
                busPort = ReadBusPort();
                string payload = GetArgValue(args, "--ui");
                if (!string.IsNullOrEmpty(payload)) SendUi(payload);
                return;
            }

            // 单实例：已经有启动器在跑就只做一件事
            bool createdNew;
            Mutex mutex = new Mutex(true, MutexName, out createdNew);
            if (!createdNew)
            {
                // 互斥体可能被"已经死掉、但句柄泄漏给某个子进程"的旧实例占着。
                // 这时如果确实没有同名进程在跑，就当残留处理，继续启动，
                // 否则用户会遇到"双击没反应、托盘也不出来"。
                if (!HasOtherInstance())
                {
                    LogLine("发现残留互斥体（没有同名进程在跑），继续启动");
                }
                else
                {
                    // 旧实例可能正在退出（点"退出桌宠"之后还要 4 秒收尾、关图标）。
                    // 这时候立刻放弃，用户看到的就是"双击没反应、托盘里的鲸鱼也没了"。
                    // 所以只盯着"同名进程还在不在"等（最多 8 秒），它一退我们就接手；
                    // 互斥体本身不能当判据——句柄会被 node 子进程继承，进程死了它还占着。
                    LogLine("发现另一实例在跑，最多等 8 秒让它退出后接手");
                    for (int i = 0; i < 40 && HasOtherInstance(); i++) System.Threading.Thread.Sleep(200);
                    if (HasOtherInstance())
                    {
                        if (wantOverlay) SendToBus("{\"t\":\"togglePlugin\",\"id\":\"dsh-damage-pulse\",\"visible\":true}");
                        else ShowBalloonOnce("大肥鱼 已在运行", "看右下角托盘图标（鲸鱼头像）就能操作它。");
                        return;
                    }
                    LogLine("旧实例已退出，本次启动直接接手");
                }
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            nodePath = FindNode();
            pshPath = FindPowerShell();
            busPort = ReadBusPort();

            // 伤害数字默认打开（现在是跟着挂件的小面板，不打扰；托盘里可以随时关）
            overlayVisible = true;

            if (nodePath == null)
            {
                MessageBox.Show(
                    "没找到 node.exe。\n\n装一个 Node 18+（https://nodejs.org），或把 node.exe 放进 dafeiyu\\runtime\\ 目录。",
                    "dsh-overlay", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            if (!Directory.Exists(LogDir)) Directory.CreateDirectory(LogDir);
            try { if (File.Exists(StopFlag)) File.Delete(StopFlag); } catch { }

            TryDelete(PidHost);
            TryDelete(PidCore);
            TryDelete(PidUsage);

            StartCore();
            StartUsage();
            overlayVisible = ReadOverlayFlag();   // 上次关掉的话，重启也别自己开回来
            StartHost(overlayVisible);
            BuildTray();
            StartWatchdog();

            Application.ApplicationExit += delegate { StopEverything(false); };
            Application.Run();
            GC.KeepAlive(mutex);
        }

        // ---------------------------------------------------------------- 启动子进程
        private static void StartCore()
        {
            string script = Path.Combine(root, @"core\server.mjs");
            if (!File.Exists(script)) { LogLine("找不到 core\\server.mjs"); return; }
            // 核心自己会写 logs\core.log（UTF-8）；这里把它的控制台输出收到另一个文件，避免同一条日志写两遍、且中文被代码页搞乱
            coreProc = StartHidden(nodePath, Quote(script), Path.Combine(LogDir, "core_stdout.log"));
            LogLine("核心已启动" + (coreProc == null ? "（失败）" : " pid " + coreProc.Id));
        }

        /// <summary>DSH 用量旁听：把 ~/.dsh 的 token 增量换成伤害，注入总线（不动核心账本）。</summary>
        private static void StartUsage()
        {
            string script = Path.Combine(root, @"tools\dsh-usage.mjs");
            if (!File.Exists(script)) { LogLine("没有 tools\\dsh-usage.mjs，跳过 DSH 用量旁听"); return; }
            usageDeathLogged = false;
            usageProc = StartHidden(nodePath, Quote(script), Path.Combine(LogDir, "dsh-usage_stdout.log"));
            if (usageProc != null)
            {
                try { File.WriteAllText(PidUsage, usageProc.Id.ToString()); } catch { }
            }
            LogLine("用量旁听已启动" + (usageProc == null ? "（失败）" : " pid " + usageProc.Id) + "（DSH 花钱也会咬）");
        }

        private static void StartHost(bool overlay)
        {
            string script = Path.Combine(root, @"host\dsh-overlay.ps1");
            if (!File.Exists(script)) { LogLine("找不到 host\\dsh-overlay.ps1"); return; }
            // Spawn the PowerShell host DIRECTLY from this exe: no cmd.exe involved, no console
            // window (CreateNoWindow), and deliberately NO stdio redirection. The host already
            // writes everything it needs into logs\host.log, so it does not need a pipe.
            // TEMP/TMP are pinned to logs\tmp because a restricted token can deny %TEMP%,
            // which makes the host's Add-Type fail during dot-sourcing and kills it instantly.
            TryDelete(PidHost);
            hostDeathLogged = false;
            string tmpDir = Path.Combine(LogDir, "tmp");
            try { if (!Directory.Exists(tmpDir)) Directory.CreateDirectory(tmpDir); } catch { }
            ProcessStartInfo psi = new ProcessStartInfo(pshPath, HostArgs(script, overlay));
            psi.WorkingDirectory = root;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = false;
            psi.RedirectStandardError = false;
            try
            {
                psi.EnvironmentVariables["TEMP"] = tmpDir;
                psi.EnvironmentVariables["TMP"] = tmpDir;
            }
            catch { }
            Process p = null;
            try { p = Process.Start(psi); } catch (Exception ex) { LogLine("浮层启动失败: " + ex.Message); }
            hostProc = p;
            hostStartedAt = DateTime.Now;
            LogLine("浮层已启动" + (p == null ? "（拉起失败）" : " pid " + p.Id) + (overlay ? "（含伤害数字）" : "（桌宠模式）"));
        }

        private static string HostArgs(string script, bool overlay)
        {
            return "-NoProfile -STA -ExecutionPolicy Bypass -File " + Quote(script) + (overlay ? "" : " -PetMode");
        }

        private static Process StartHidden(string exe, string arguments, string logPath)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exe, arguments);
                psi.WorkingDirectory = root;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                Process p = new Process();
                p.StartInfo = psi;
                p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { AppendLog(logPath, e.Data); };
                p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { AppendLog(logPath, e.Data); };
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                return p;
            }
            catch (Exception ex)
            {
                LogLine("启动失败: " + ex.Message);
                return null;
            }
        }

        private static void AppendLog(string path, string line)
        {
            if (string.IsNullOrEmpty(line)) return;
            try
            {
                lock (logLock)
                {
                    File.AppendAllText(path, line + Environment.NewLine, new UTF8Encoding(false));
                }
            }
            catch { }
        }

        private static void LogLine(string msg)
        {
            AppendLog(Path.Combine(LogDir, "launcher.log"),
                DateTime.Now.ToString("HH:mm:ss") + " " + msg);
        }

        // ---------------------------------------------------------------- 托盘
        private static void BuildTray()
        {
            tray = new NotifyIcon();
            string ico = Path.Combine(root, @"assets\dsh-overlay.ico");
            bool customIcon = false;
            try
            {
                if (File.Exists(ico)) { tray.Icon = new Icon(ico); customIcon = true; }
            }
            catch { customIcon = false; }
            if (!customIcon)
            {
                // 备用：直接取 exe 里嵌的图标
                try
                {
                    Icon assoc = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                    if (assoc != null) { tray.Icon = assoc; customIcon = true; }
                }
                catch { }
            }
            if (!customIcon) tray.Icon = SystemIcons.Application;
            tray.Text = "大肥鱼 · 桌宠" + (overlayVisible ? " · 伤害数字 开" : "");
            bool wantHidden = WantTrayHidden();
            if (wantHidden)
            {
                // 上次用户亲手把它拖进溢出区了 —— 尊重这个选择，只按"隐藏"身份注册一次，
                // 不写 IsPromoted=1、也不做二次注册，否则又会被搬回可见托盘区。
                EnsureHidden();
                tray.Visible = true;
                LogLine("托盘图标按记忆收在溢出区（你之前拖进去的，本次不强行固定）");
            }
            else
            {
                // 注册之前先把注册表里的 IsPromoted 写回 1。
                // 退出/被强杀/改名之后这个值会被打回 0（Windows 侧行为），下次启动就缩回溢出面板，
                // 所以每次启动都先自愈一次，再让 Explorer 按 1 的身份去"安家"。
                EnsurePromoted(true);
                tray.Visible = true;
                LogLine("托盘图标已注册（" + (customIcon ? "自定义头像" : "系统默认图标") + "）");
            }
            // 这 1.2 秒后的第二次注册是**必须的**，不能省。
            // 原因（实测）：Windows 只在 NIM_ADD 那一刻读
            // HKCU\Control Panel\NotifyIconSettings\<key>\IsPromoted 来决定
            // 这个图标放"可见托盘区"还是"溢出面板"。第一次 NIM_ADD 时这个 key 刚被创建，
            // Explorer 已经按"新图标默认进溢出"记住了它，之后再改注册表它也不会当场搬家——
            // 必须 Visible=false→true 再 NIM_ADD 一次，让它按 1 重新安家。
            // 但重注册偶尔会把 IsPromoted 当场打回 0（日志里 18 秒后看门狗抓到过这种回落），
            // 所以注册完立刻再补写一次 1。全程只注册这一次，之后不再折腾，避免闪烁。
            {
                System.Windows.Forms.Timer trayFix = new System.Windows.Forms.Timer();
                trayFix.Interval = 1200;
                trayFix.Tick += delegate
                {
                    trayFix.Stop();
                    try
                    {
                        if (WantTrayHidden())
                        {
                            // 用户要它待在溢出区：不折腾，直接收工
                            trayFix.Dispose();
                            return;
                        }
                        bool wasPinned = TrayPinned();
                        EnsurePromoted();          // 先写 1：重注册时 Explorer 读到的是"要固定"
                        tray.Visible = false;
                        tray.Visible = true;       // 重注册 → 图标从溢出区搬回可见托盘
                        EnsurePromoted();          // 补写：重注册可能把 IsPromoted 打回 0
                        LogLine("托盘图标二次注册完成（进场 IsPromoted=" + (wasPinned ? "1" : "0") + "，出场已确保=1）");
                    }
                    catch { }
                    trayFix.Dispose();
                };
                trayFix.Start();
            }
            tray.DoubleClick += delegate { ShowBalloon("大肥鱼 在跑", "挂件在右下角；右键挂件可以摸头、改大小、退出。"); };

            // 看门狗：不再自己跟 Explorer 抢图标位置，只做一件事 ——
            // 观察注册表里 IsPromoted 的变化，判断用户有没有手动拖动图标（任务栏可见区 ⇄ 溢出区 ^），
            // 然后把用户的这个选择记下来，下次启动照做。
            // 连续两次读到同一个状态才认，避免 Explorer 偶尔把 0 写回来造成误记。
            int[] hiddenVotes = new int[1];
            System.Windows.Forms.Timer trayWatch = new System.Windows.Forms.Timer();
            trayWatch.Interval = 8000;
            trayWatch.Tick += delegate
            {
                try
                {
                    bool pinned = TrayPinned();
                    bool hid = WantTrayHidden();
                    if (hid && pinned)
                    {
                        // 溢出区里待着，注册表却是"固定" —— 用户刚把它拖回任务栏
                        SetTrayHidden(false);
                        hiddenVotes[0] = 0;
                        LogLine("记住你的选择：托盘图标固定回任务栏了（下次启动也在这）");
                    }
                    else if (!hid && !pinned)
                    {
                        // 之前是固定状态，现在注册表说"隐藏" —— 用户把它拖进溢出区了
                        hiddenVotes[0]++;
                        if (hiddenVotes[0] >= 2)
                        {
                            SetTrayHidden(true);
                            hiddenVotes[0] = 0;
                            LogLine("记住你的选择：托盘图标收进溢出区了（点任务栏的 ^ 能找回来）");
                        }
                    }
                    else
                    {
                        hiddenVotes[0] = 0;
                    }
                }
                catch { }
            };
            trayWatch.Start();

            tray.ContextMenuStrip = BuildTrayMenu();

            // 悬停提示里的余额每分钟刷一次（不点菜单也能瞄一眼）；注意 System.Threading 里也有 Timer
            System.Windows.Forms.Timer tipTimer = new System.Windows.Forms.Timer();
            tipTimer.Interval = 60000;
            tipTimer.Tick += delegate { try { RefreshTrayHead(null, null); } catch { } };
            tipTimer.Start();
            RefreshTrayHead(null, null);

            // 第二实例的"已在运行"气泡：不再自己建临时托盘图标（临时图标的注册/注销会
            // 干扰 Explorer 对正式图标的缓存，可能把鲸鱼头像挤没），而是写一个请求文件，
            // 由主实例用自己的托盘图标弹气泡。
            System.Windows.Forms.Timer balloonPoll = new System.Windows.Forms.Timer();
            balloonPoll.Interval = 2000;
            balloonPoll.Tick += delegate
            {
                try
                {
                    if (!File.Exists(BalloonRequest)) return;
                    string[] lines = null;
                    try { lines = File.ReadAllLines(BalloonRequest); } catch { }
                    string t = (lines != null && lines.Length > 0) ? lines[0] : "";
                    string x = (lines != null && lines.Length > 1) ? lines[1] : "";
                    TryDelete(BalloonRequest);
                    if (!string.IsNullOrEmpty(t) && tray != null && tray.Visible) ShowBalloon(t, x);
                }
                catch { }
            };
            balloonPoll.Start();
        }

        // ---------------------------------------------------------------- 托盘菜单
        // 只留几个真正常用的开关（挂件大小 / 伤害数字 / 窗口置顶 / 开机自启），
        // 再加一个「维护」子菜单和「退出」。挂件菜单那一整套功能不往这儿搬。
        // 尺寸一律乘系统 DPI：进程是 DPI-aware 的，150% 屏上按像素算才不会糊。
        private static float dpiScale = 0f;
        private static bool trayTopmost = true;
        private static double trayCritScale = 1.0;

        private static float Dpi()
        {
            if (dpiScale <= 0f)
            {
                try
                {
                    using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) dpiScale = g.DpiX / 96f;
                }
                catch { dpiScale = 1f; }
                if (dpiScale < 0.5f) dpiScale = 1f;
            }
            return dpiScale;
        }

        private static int Dip(int px) { return (int)Math.Round(px * Dpi()); }

        // 挂件窗口现在到底是不是置顶？直接看宿主进程窗口的 WS_EX_TOPMOST，别拿缓存猜。
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        private static bool? PetTopmost()
        {
            if (hostProc == null) return null;
            try { if (hostProc.HasExited) return null; } catch { return null; }
            bool? result = null;
            try
            {
                uint target = (uint)hostProc.Id;
                EnumWindows(delegate(IntPtr h, IntPtr l)
                {
                    uint pid;
                    GetWindowThreadProcessId(h, out pid);
                    if (pid != target) return true;
                    if (!IsWindowVisible(h)) return true;
                    int ex = GetWindowLong(h, -20); // GWL_EXSTYLE
                    if ((ex & 0x8) != 0) { result = true; return false; } // WS_EX_TOPMOST
                    if (!result.HasValue) result = false;
                    return true;
                }, IntPtr.Zero);
            }
            catch { }
            return result;
        }

        private static ContextMenuStrip BuildTrayMenu()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Renderer = new DarkRenderer();
            menu.Font = new Font("Microsoft YaHei UI", 9f);
            menu.ShowImageMargin = true;
            menu.ShowCheckMargin = false;
            menu.ImageScalingSize = new Size(Dip(11), Dip(11));
            menu.DropShadowEnabled = true;
            menu.Padding = new Padding(Dip(5), Dip(6), Dip(5), Dip(6));

            ToolStripMenuItem miHead = new ToolStripMenuItem("大肥鱼 · 余额 —");
            miHead.Enabled = false;
            miHead.Tag = "head";
            miHead.Font = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Bold);
            menu.Items.Add(miHead);

            ToolStripMenuItem miSub = new ToolStripMenuItem("已烧 — · 命中 —");
            miSub.Enabled = false;
            miSub.Tag = "head2";
            miSub.Font = new Font("Microsoft YaHei UI", 8f);
            menu.Items.Add(miSub);
            menu.Items.Add(new ToolStripSeparator());

            // ---- 挂件大小（当前值记在 plugins\dsh-whale-widget\position.json 的 scale 里）
            ToolStripMenuItem miScale = new ToolStripMenuItem("挂件大小");
            miScale.Image = Dot("#8FA3B8");
            double[] scaleValues = new double[] { 0.8, 1.0, 1.25, 1.5 };
            ToolStripMenuItem[] scaleItems = new ToolStripMenuItem[scaleValues.Length];
            Action refreshScale = null;
            for (int i = 0; i < scaleValues.Length; i++)
            {
                double v = scaleValues[i];
                ToolStripMenuItem it = new ToolStripMenuItem(((int)Math.Round(v * 100)) + "%");
                // 不要在选项前放小圆点：选中态是「✓ 」文字前缀（和挂件右键菜单里的勾一致），
                // 每项再顶个灰点会跟 ✓ 打架，看着像两个状态标记。
                it.Click += delegate
                {
                    trayScale = v;
                    SendUi("{\"t\":\"ui\",\"cmd\":\"scale\",\"value\":" + v.ToString("0.##", CultureInfo.InvariantCulture) + "}");
                    refreshScale();
                };
                scaleItems[i] = it;
                miScale.DropDownItems.Add(it);
            }
            refreshScale = delegate
            {
                for (int i = 0; i < scaleItems.Length; i++)
                    scaleItems[i].Text = (Math.Abs(scaleValues[i] - trayScale) < 0.001 ? "✓ " : "   ") + ((int)Math.Round(scaleValues[i] * 100)) + "%";
            };
            try
            {
                string pf = Path.Combine(root, @"plugins\dsh-whale-widget\position.json");
                if (File.Exists(pf))
                {
                    Match m = Regex.Match(File.ReadAllText(pf), "\"scale\"\\s*:\\s*([0-9.]+)");
                    double sv0;
                    if (m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out sv0) && sv0 > 0)
                        trayScale = sv0;
                }
            }
            catch { }
            refreshScale();
            menu.Items.Add(miScale);

            // ---- 暴击数字：小 / 中 / 大三档，走子菜单勾选（不弹气泡）
            ToolStripMenuItem miCritSize = new ToolStripMenuItem("");
            miCritSize.Image = Dot("#FF7BE5");
            ToolStripMenuItem miCritSmall = new ToolStripMenuItem("小（0.7× · 大出血 48px）");
            // 不要图片：勾选态用自绘 ✓（有图片会变成默认的浅蓝方块）
            ToolStripMenuItem miCritMid = new ToolStripMenuItem("中（1.0× · 大出血 68px）");

            ToolStripMenuItem miCritBig = new ToolStripMenuItem("大（1.75× · 大出血 119px）");


            Action refreshCrit = null;
            Action<double> applyCrit = delegate (double v2)
            {
                trayCritScale = v2;
                SendUi("{\"t\":\"ui\",\"cmd\":\"critScale\",\"value\":" + v2.ToString("0.##", CultureInfo.InvariantCulture) + "}");
                if (refreshCrit != null) refreshCrit();
            };
            miCritSmall.Click += delegate { applyCrit(0.7); };
            miCritMid.Click += delegate { applyCrit(1.0); };
            miCritBig.Click += delegate { applyCrit(1.75); };
            miCritSize.DropDownItems.Add(miCritSmall);
            miCritSize.DropDownItems.Add(miCritMid);
            miCritSize.DropDownItems.Add(miCritBig);

            refreshCrit = delegate
            {
                // 每次都从 plugin.json 现读：命令行 --ui 改过也对得上
                try
                {
                    string cf0 = Path.Combine(root, @"plugins\dsh-damage-pulse\plugin.json");
                    if (File.Exists(cf0))
                    {
                        Match m0 = Regex.Match(File.ReadAllText(cf0), "\"critScale\"\\s*:\\s*([0-9.]+)");
                        double cv;
                        if (m0.Success && double.TryParse(m0.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out cv) && cv >= 0.4 && cv <= 3.0)
                            trayCritScale = cv;
                    }
                }
                catch { }
                bool isSmall = Math.Abs(trayCritScale - 0.7) < 0.05;
                bool isMid = Math.Abs(trayCritScale - 1.0) < 0.05;
                bool isBig = trayCritScale > 1.3;
                miCritSmall.Checked = isSmall;
                miCritMid.Checked = isMid && !isBig;
                miCritBig.Checked = isBig;
                miCritSize.Text = isSmall ? "暴击数字：小" : (isBig ? "暴击数字：大" : "暴击数字：中");
            };
            try
            {
                string cf = Path.Combine(root, @"plugins\dsh-damage-pulse\plugin.json");
                if (File.Exists(cf))
                {
                    Match mc = Regex.Match(File.ReadAllText(cf), "\"critScale\"\\s*:\\s*([0-9.]+)");
                    double cv0;
                    if (mc.Success && double.TryParse(mc.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out cv0) && cv0 >= 0.4 && cv0 <= 3.0)
                        trayCritScale = cv0;
                }
            }
            catch { }
            refreshCrit();
            menu.Items.Add(miCritSize);

            // ---- 伤害数字
            ToolStripMenuItem miOverlay = new ToolStripMenuItem(overlayVisible ? "伤害数字：已开" : "伤害数字：已关");
            miOverlay.Image = Dot("#8FA3B8");
            miOverlay.Click += delegate
            {
                overlayVisible = !overlayVisible;
                WriteOverlayFlag(overlayVisible);
                SendToBus("{\"t\":\"togglePlugin\",\"id\":\"dsh-damage-pulse\",\"visible\":" + (overlayVisible ? "true" : "false") + "}");
                miOverlay.Text = overlayVisible ? "伤害数字：已开" : "伤害数字：已关";
                try { RefreshTrayHead(null, null); } catch { }   // 只刷新悬停提示，不动菜单头
            };
            menu.Items.Add(miOverlay);

            // ---- 余额条：隐藏 / 显示（挂件的余额面板，挡视野时可以收起来）
            ToolStripMenuItem miBar = new ToolStripMenuItem("");
            miBar.Image = Dot("#8FA3B8");
            bool barVisible = true;
            Action refreshBar = delegate
            {
                try
                {
                    string cf2 = Path.Combine(root, @"plugins\dsh-whale-widget\plugin.json");
                    if (File.Exists(cf2))
                    {
                        Match m2 = Regex.Match(File.ReadAllText(cf2), "\"showBar\"\\s*:\\s*(true|false)");
                        if (m2.Success) barVisible = m2.Groups[1].Value == "true";
                        else barVisible = true;
                    }
                }
                catch { }
                miBar.Text = barVisible ? "余额条：显示中" : "余额条：已隐藏";
            };
            miBar.Click += delegate
            {
                barVisible = !barVisible;
                SendUi("{\"t\":\"ui\",\"cmd\":\"bar\",\"value\":" + (barVisible ? "true" : "false") + "}");
                miBar.Text = barVisible ? "余额条：显示中" : "余额条：已隐藏";
            };
            refreshBar();
            menu.Items.Add(miBar);

            // ---- 窗口置顶（状态从挂件窗口的 EXSTYLE 实读，不信缓存，免得对不上）
            ToolStripMenuItem miTop = new ToolStripMenuItem("");
            miTop.Image = Dot("#8FA3B8");
            Action refreshTop = delegate
            {
                bool? real = PetTopmost();
                if (real.HasValue) trayTopmost = real.Value;
                miTop.Text = trayTopmost ? "窗口置顶：已开" : "窗口置顶：已关";
            };
            miTop.Click += delegate
            {
                trayTopmost = !trayTopmost;
                SendUi("{\"t\":\"ui\",\"cmd\":\"topmost\"}");
                miTop.Text = trayTopmost ? "窗口置顶：已开" : "窗口置顶：已关";
            };
            refreshTop();
            menu.Items.Add(miTop);

            // ---- 开机自启
            ToolStripMenuItem miAuto = new ToolStripMenuItem("");
            miAuto.Image = Dot("#8FA3B8");
            Action refreshAuto = delegate
            {
                bool on = File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "dafeiyu.lnk"));
                miAuto.Text = on ? "开机自启：已开" : "开机自启：已关";
            };
            miAuto.Click += delegate { ToggleAutostart(); refreshAuto(); };
            refreshAuto();
            menu.Items.Add(miAuto);
            // ---- 性能模式：流畅 / 省电（改宿主帧率，落到 core\config.json 的 host.tickMs）
            ToolStripMenuItem miPerf = new ToolStripMenuItem("性能模式");
            miPerf.Image = Dot("#8FA3B8");
            ToolStripMenuItem miPerfSmooth = new ToolStripMenuItem("流畅（每帧 40ms · 25fps）");
            ToolStripMenuItem miPerfSave = new ToolStripMenuItem("省电（每帧 80ms · 12.5fps）");
            Action refreshPerf = null;
            Action<int> applyPerf = delegate (int ms)
            {
                WriteTickMs(ms);
                SendUi("{\"t\":\"ui\",\"cmd\":\"tick\",\"value\":" + ms.ToString(CultureInfo.InvariantCulture) + "}");
                // 省电档顺带把常驻呼吸/摇摆/呆毛动画停掉，不然光放慢 tick 省不到 CPU
                SendUi("{\"t\":\"ui\",\"cmd\":\"perf\",\"value\":\"" + (ms > 50 ? "save" : "smooth") + "\"}");
                if (refreshPerf != null) refreshPerf();
            };
            miPerfSmooth.Click += delegate { applyPerf(40); };
            miPerfSave.Click += delegate { applyPerf(80); };
            miPerf.DropDownItems.Add(miPerfSmooth);
            miPerf.DropDownItems.Add(miPerfSave);
            refreshPerf = delegate
            {
                int ms = ReadTickMs();
                miPerfSmooth.Checked = ms <= 50;
                miPerfSave.Checked = ms > 50;
                miPerf.Text = ms <= 50 ? "性能模式：流畅" : "性能模式：省电";
            };
            refreshPerf();
            menu.Items.Add(miPerf);

            menu.Items.Add(new ToolStripSeparator());

            // ---- 维护（不常用的塞进去）
            ToolStripMenuItem miMaint = new ToolStripMenuItem("维护");
            miMaint.Image = Dot("#5A6B7C");
            miMaint.DropDownItems.Add(Dot("打开日志文件夹", "#8FA3B8", delegate { OpenFolder("logs"); }));
            miMaint.DropDownItems.Add(new ToolStripSeparator());
            miMaint.DropDownItems.Add(Dot("找回挂件（拉回主屏）", "#4FC3F7", delegate
            {
                double keptScale = trayScale;
                try
                {
                    // 只搬位置、不动设置：旧做法直接删 position.json，会把 scale 一起清掉，
                    // 用户看到的就是"找回挂件顺手把挂件大小改回去了"。
                    string pos = Path.Combine(root, @"plugins\dsh-whale-widget\position.json");
                    if (File.Exists(pos))
                    {
                        Match m = Regex.Match(File.ReadAllText(pos), "\"scale\"\\s*:\\s*([0-9.]+)");
                        double sv;
                        if (m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out sv) && sv > 0)
                            keptScale = sv;
                    }
                    int bw = (int)Math.Round(280 * keptScale);
                    int bh = (int)Math.Round(336 * keptScale);
                    // position.json 里是 WPF 的 DIP 坐标，本进程是 DPI 感知的（拿到的是物理像素），
                    // 所以要先除回缩放比，否则 150% 屏上会算到屏幕外面去。
                    float f = Dpi();
                    if (f <= 0f) f = 1f;
                    Rectangle wa = Screen.PrimaryScreen.WorkingArea;    // 用工作区，别压任务栏
                    int waW = (int)Math.Round(wa.Width / f);
                    int waH = (int)Math.Round(wa.Height / f);
                    int left = waW - bw - 64;                           // 比默认再往里一点，别贴着屏幕边
                    int top = waH - bh - 96;
                    string json = "{\"left\":" + left.ToString(CultureInfo.InvariantCulture)
                        + ",\"top\":" + top.ToString(CultureInfo.InvariantCulture)
                        + ",\"scale\":" + keptScale.ToString(CultureInfo.InvariantCulture) + "}";
                    File.WriteAllText(pos, json);
                }
                catch { }
                RestartHost();
                ShowBalloon("大肥鱼", "已拉回主屏右下角（挂件大小没动）。");
            }));
            miMaint.DropDownItems.Add(Dot("重启浮层", "#4FC3F7", delegate { RestartHost(); }));
            miMaint.DropDownItems.Add(new ToolStripSeparator());
            // 托盘图标放哪：拖也认、这里点也认，永远记住最后一次选择
            ToolStripMenuItem miTraySpot = new ToolStripMenuItem(WantTrayHidden() ? "托盘图标：收在溢出区 → 点此固定回任务栏" : "托盘图标：固定在任务栏 → 点此收进溢出区");
            miTraySpot.Image = Dot("#4FC3F7");
            miTraySpot.Click += delegate { ToggleTrayVisible(); };
            miMaint.DropDownItems.Add(miTraySpot);
            menu.Items.Add(miMaint);

            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(Dot("退出桌宠", "#FF5A5A", delegate
            {
                if (tray != null) tray.Visible = false;
                StopEverything(true);
                Application.Exit();
            }));

            // 每次弹出都刷一遍余额/按钮状态
            menu.Opening += delegate
            {
                try { RefreshTrayHead(miHead, miSub); } catch { }
                try { miTraySpot.Text = WantTrayHidden() ? "托盘图标：收在溢出区 → 点此固定回任务栏" : "托盘图标：固定在任务栏 → 点此收进溢出区"; } catch { }
                try { refreshScale(); refreshCrit(); refreshTop(); refreshAuto(); refreshBar(); refreshPerf(); } catch { }
            };
            RoundDropDown(menu, Dip(10));
            return menu;
        }


        // 把 ToolStripDropDown（含所有子菜单）的窗口 Region 裁成圆角，跟挂件菜单的圆角描边一个调子
        private static void RoundDropDown(ToolStripDropDown dd, int radius)
        {
            if (dd == null) return;
            // 展开后再裁：Opened 时窗口尺寸才是最终值，所以丢到消息队列尾巴上再量一次
            EventHandler apply = delegate
            {
                try
                {
                    dd.BeginInvoke((MethodInvoker)delegate
                    {
                        try { ApplyRoundRegion(dd, radius); } catch { }
                        try { PushToTop(dd.Handle); } catch { }
                    });
                }
                catch { }
            };
            dd.Opened += apply;
            dd.Layout += delegate { try { ApplyRoundRegion(dd, radius); } catch { } };
            foreach (ToolStripItem it in dd.Items)
            {
                ToolStripMenuItem mi = it as ToolStripMenuItem;
                if (mi != null && mi.DropDownItems.Count > 0) RoundDropDown(mi.DropDown, radius);
            }
        }

        private static void ApplyRoundRegion(ToolStripDropDown dd, int radius)
        {
            if (dd.Width < radius * 2 + 4 || dd.Height < radius * 2 + 4) return;
            Rectangle r = new Rectangle(0, 0, dd.Width, dd.Height);
            using (GraphicsPath path = RoundPath(r, radius))
            {
                Region old = dd.Region;
                dd.Region = new Region(path);
                if (old != null) old.Dispose();
            }
        }

        // 菜单窗口提到最上层：挂件是 Topmost 的，不提的话菜单会被大肥鱼糊住半截
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        private static void PushToTop(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return;
            // HWND_TOPMOST(-1)，只改 Z 序，不动位置和大小、也不抢焦点
            SetWindowPos(hwnd, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0200);
        }

        private static GraphicsPath RoundPath(Rectangle r, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int d = radius * 2;
            if (r.Width <= d || r.Height <= d) { path.AddRectangle(r); return path; }
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        // 挂件当前大小 / 余额预览：启动器自己记着，菜单里那个 ✓ 才有意义
        private static double trayScale = 1.0;

        private static void RefreshTrayHead(ToolStripMenuItem head, ToolStripMenuItem sub)
        {
            try
            {
                string p = Path.Combine(root, @"core\state.json");
                if (!File.Exists(p)) return;
                string t = File.ReadAllText(p);
                double bal = Num(t, "\"realBalanceCny\"");
                double balRaw = Num(t, "\"balanceCny\"");
                double spent = Num(t, "\"realSpentCny\"");
                if (double.IsNaN(spent)) spent = Num(t, "\"totalSpentCny\"");
                // realBalanceCny 是真实余额；没接过 API 时才退回本地账本
                double show = double.IsNaN(bal) ? balRaw : bal;
                if (double.IsNaN(show)) show = 0;
                if (double.IsNaN(spent)) spent = 0;
                int hits = (int)Math.Round(Num(t, "\"hits\""));
                int miss = (int)Math.Round(Num(t, "\"missCount\""));
                if (double.IsNaN(hits)) hits = 0;
                if (double.IsNaN(miss)) miss = 0;
                if (head != null) head.Text = "大肥鱼 · 余额 ¥" + show.ToString("F2");
                if (sub != null) sub.Text = "已烧 ¥" + spent.ToString("F2") + " · 命中 " + hits + " · 未命中 " + miss;
                // 顺带把悬停提示也换成余额（鼠标移上去就能看见，不用点开菜单）
                if (tray != null && tray.Visible)
                    tray.Text = "大肥鱼 · 余额 ¥" + show.ToString("F2") + (overlayVisible ? " · 伤害数字 开" : " · 伤害数字 关");
            }
            catch { }
        }

        private static double Num(string text, string key)
        {
            Match m = Regex.Match(text, Regex.Escape(key) + "\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)");
            if (!m.Success) return double.NaN;
            double v;
            if (double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
            return double.NaN;
        }

        private static void SendUi(string json)
        {
            LogLine("界面指令 -> 总线: " + json);
            SendToBus(json);
        }

        private static ToolStripMenuItem Dot(string text, string color, EventHandler onClick)
        {
            ToolStripMenuItem mi = new ToolStripMenuItem(text);
            mi.Image = Dot(color);
            mi.Click += onClick;
            return mi;
        }

        // 菜单里的圆点图标：按 DPI 放大，圆点在 150% 屏上才不会小得像灰尘
        private static Image Dot(string argb)
        {
            int size = Math.Max(9, Dip(11));
            int pad = Math.Max(1, (int)Math.Round(size * 0.18));
            Bitmap bmp = new Bitmap(size, size);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (SolidBrush b = new SolidBrush(Clr(argb)))
                    g.FillEllipse(b, pad, pad, size - pad * 2, size - pad * 2);
            }
            return bmp;
        }

        // "#RRGGBB" 或 "#AARRGGBB"（挂件菜单里的颜色就是这种 8 位写法）
        internal static Color Clr(string hex)
        {
            string s = hex.TrimStart('#');
            if (s.Length == 8)
            {
                int a = int.Parse(s.Substring(0, 2), NumberStyles.HexNumber);
                int r = int.Parse(s.Substring(2, 2), NumberStyles.HexNumber);
                int g = int.Parse(s.Substring(4, 2), NumberStyles.HexNumber);
                int b = int.Parse(s.Substring(6, 2), NumberStyles.HexNumber);
                return Color.FromArgb(a, r, g, b);
            }
            return ColorTranslator.FromHtml("#" + s);
        }

        // 深色菜单：底色 #141A21、1px 描边、圆角悬停、灰掉的项用暗字
        private sealed class DarkColors : ProfessionalColorTable
        {
            public override Color ToolStripDropDownBackground { get { return Clr("#141A21"); } }
            public override Color CheckBackground { get { return Color.Transparent; } }
            public override Color CheckSelectedBackground { get { return Color.Transparent; } }
            public override Color CheckPressedBackground { get { return Color.Transparent; } }
            public override Color ImageMarginGradientBegin { get { return Clr("#141A21"); } }
            public override Color ImageMarginGradientMiddle { get { return Clr("#141A21"); } }
            public override Color ImageMarginGradientEnd { get { return Clr("#141A21"); } }
            public override Color MenuBorder { get { return Clr("#3AFFFFFF"); } }
            public override Color MenuItemBorder { get { return Color.Transparent; } }
            public override Color MenuItemSelected { get { return Clr("#2E5AC8FF"); } }
            public override Color MenuItemSelectedGradientBegin { get { return Clr("#2E5AC8FF"); } }
            public override Color MenuItemSelectedGradientEnd { get { return Clr("#2E5AC8FF"); } }
            public override Color MenuItemPressedGradientBegin { get { return Clr("#2E5AC8FF"); } }
            public override Color MenuItemPressedGradientEnd { get { return Clr("#2E5AC8FF"); } }
            public override Color SeparatorDark { get { return Clr("#1FFFFFFF"); } }
            public override Color SeparatorLight { get { return Clr("#10FFFFFF"); } }
        }

        private sealed class DarkRenderer : ToolStripProfessionalRenderer
        {
            public DarkRenderer() : base(new DarkColors()) { }

            private static GraphicsPath Round(Rectangle r, int radius)
            {
                GraphicsPath path = new GraphicsPath();
                int d = radius * 2;
                if (r.Width <= d || r.Height <= d) { path.AddRectangle(r); return path; }
                path.AddArc(r.X, r.Y, d, d, 180, 90);
                path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
                path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
                path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
                path.CloseFigure();
                return path;
            }

            protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
            {
                using (SolidBrush b = new SolidBrush(Clr("#141A21")))
                    e.Graphics.FillRectangle(b, new Rectangle(Point.Empty, e.ToolStrip.Size));
            }

            protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
            {
                Rectangle r = new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
                using (Pen p = new Pen(Clr("#33FFFFFF"), 1))
                    e.Graphics.DrawRectangle(p, r);
                if (e.ToolStrip is ContextMenuStrip)
                {
                    // 顶部再补一条柔和的高光，跟挂件的圆角描边一个调子
                    using (Pen p2 = new Pen(Clr("#1AFFFFFF"), 1))
                        e.Graphics.DrawLine(p2, 8, 1, e.ToolStrip.Width - 8, 1);
                }
            }

            protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
            {
                ToolStripMenuItem mi = e.Item as ToolStripMenuItem;
                if (mi == null) { base.OnRenderMenuItemBackground(e); return; }
                Rectangle r = new Rectangle(Dip(2), Dip(1), Math.Max(1, e.Item.Width - Dip(4)), Math.Max(1, e.Item.Height - Dip(2)));
                Color fill = Color.Empty;
                if (mi.Enabled && mi.Selected) fill = Clr("#2E5AC8FF");
                else if (mi.Selected) fill = Clr("#1AFFFFFF");
                if (fill == Color.Empty) return;
                using (GraphicsPath path = Round(r, Dip(8)))
                using (SolidBrush b = new SolidBrush(fill))
                    e.Graphics.FillPath(b, path);
            }

            protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
            {
                if (!e.Item.Enabled)
                {
                    // 头两行虽然是禁用的（点了没反应），但也得看得清，所以单独提一点亮度
                    string tag = e.Item.Tag as string;
                    if (tag == "head") e.TextColor = Clr("#C9D6E4");
                    else if (tag == "head2") e.TextColor = Clr("#8FA3B8");
                    else e.TextColor = Clr("#70808F9F");
                }
                else if (e.Item.Selected) e.TextColor = Clr("#FFFFFF");
                else e.TextColor = Clr("#E6EEF7");
                base.OnRenderItemText(e);
            }

            protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
            {
                e.ArrowColor = Clr("#7E93A8");
                base.OnRenderArrow(e);
            }

            // 勾选态自己画：默认 ProfessionalRenderer 会画一块浅蓝方块，和深色皮肤不搭
            protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
            {
                Rectangle r = e.ImageRectangle;
                if (r.Width <= 0 || r.Height <= 0) return;
                Graphics g = e.Graphics;
                System.Drawing.Drawing2D.SmoothingMode old = g.SmoothingMode;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                Color c = e.Item.Selected ? Color.FromArgb(255, 255, 138, 222) : Color.FromArgb(255, 140, 200, 240);
                using (Pen pen = new Pen(c, Math.Max(1.6f, r.Height * 0.13f)))
                {
                    pen.StartCap = System.Drawing.Drawing2D.LineCap.Round;
                    pen.EndCap = System.Drawing.Drawing2D.LineCap.Round;
                    float x = r.Left + r.Width * 0.06f;
                    float y = r.Top + r.Height * 0.52f;
                    g.DrawLines(pen, new PointF[]
                    {
                        new PointF(x + r.Width * 0.10f, y),
                        new PointF(x + r.Width * 0.38f, y + r.Height * 0.28f),
                        new PointF(x + r.Width * 0.86f, y - r.Height * 0.30f)
                    });
                }
                g.SmoothingMode = old;
            }

            protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
            {
                int y = e.Item.Height / 2;
                int inset = Dip(12);
                using (Pen p = new Pen(Clr("#1FFFFFFF"), 1))
                    e.Graphics.DrawLine(p, inset, y, Math.Max(inset + 1, e.Item.Width - inset), y);
            }
        }

        // 真的有另一个本程序在跑吗？互斥体被占并不等于有实例：
        // 旧实例被子进程（node/powershell）继承了句柄后自己死掉，句柄会一直挂着。
        private static bool HasOtherInstance()
        {
            try
            {
                string self = Path.GetFileNameWithoutExtension(Application.ExecutablePath);
                int me = Process.GetCurrentProcess().Id;
                foreach (Process p in Process.GetProcessesByName(self))
                {
                    try { if (p.Id != me) return true; }
                    catch { }
                }
            }
            catch { }
            return false;
        }

        // 读 HKCU\Control Panel\NotifyIconSettings，看本 exe 的托盘条目是不是已经被
        // "提升"到可见托盘区（IsPromoted=1）。这个值由"设置 > 个性化 > 任务栏 >
        // 其他系统托盘图标"里那个开关写入，写入后跨进程重启是稳定的。
        // 把本 exe 在 NotifyIconSettings 里的 IsPromoted 写成 1（没有条目就什么都不做，
        // 等 Explorer 注册图标时自己建）。返回是否写成功。
        private static bool WantTrayHidden()
        {
            try { return File.Exists(TrayHiddenFlag); } catch { return false; }
        }

        private static void SetTrayHidden(bool hidden)
        {
            try
            {
                if (hidden) File.WriteAllText(TrayHiddenFlag, "hidden");
                else if (File.Exists(TrayHiddenFlag)) File.Delete(TrayHiddenFlag);
            }
            catch { }
        }

        // 按"用户要它待在溢出区"的身份写注册表：IsPromoted=0 + IsPromotedByUser=1
        private static void EnsureHidden()
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings", true))
                {
                    if (k == null) return;
                    string self = Application.ExecutablePath;
                    foreach (string name in k.GetSubKeyNames())
                    {
                        using (Microsoft.Win32.RegistryKey e = k.OpenSubKey(name, true))
                        {
                            if (e == null) continue;
                            object exe = e.GetValue("ExecutablePath");
                            if (exe == null) continue;
                            if (!string.Equals(exe.ToString(), self, StringComparison.OrdinalIgnoreCase)) continue;
                            e.SetValue("IsPromoted", 0, Microsoft.Win32.RegistryValueKind.DWord);
                            e.SetValue("IsPromotedByUser", 1, Microsoft.Win32.RegistryValueKind.DWord);
                            LogLine("托盘条目 " + name + " 已按隐藏写回（IsPromoted=0，ByUser=1）");
                        }
                    }
                }
            }
            catch { }
        }

        // 菜单里手动切换：立刻搬家 + 记住
        private static void ToggleTrayVisible()
        {
            bool hid = WantTrayHidden();
            if (hid)
            {
                SetTrayHidden(false);
                EnsurePromoted(true);
                if (tray != null) { tray.Visible = false; tray.Visible = true; }
                LogLine("手动：托盘图标固定回任务栏（已记住）");
                ShowBalloon("大肥鱼", "托盘图标回到任务栏了，下次启动也在这。");
            }
            else
            {
                SetTrayHidden(true);
                EnsureHidden();
                if (tray != null) { tray.Visible = false; tray.Visible = true; }
                LogLine("手动：托盘图标收进溢出区（已记住）");
                ShowBalloon("大肥鱼", "收进溢出区了 —— 点任务栏那个 ^ 就能找到我。");
            }
        }

        private static bool EnsurePromoted() { return EnsurePromoted(false); }

        // forceNotify=true：即使值已经是 1，也先写 0 再写回 1，制造一次"值变化"通知。
        // 实测（2026-10-22 01:59）：注册表本来就是 1/1 时启动，Explorer 仍把图标塞进溢出面板；
        // 手动 0→1 写一遍再启动就出现在可见托盘区。说明 Explorer 按会话缓存了"这个图标是隐藏的"，
        // 只有值真的变了才会重新读取。所以首次注册前必须强制翻转一次。
        private static bool EnsurePromoted(bool forceNotify)
        {
            bool ok = false;
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings", true))
                {
                    if (k == null) return false;
                    string self = Application.ExecutablePath;
                    foreach (string name in k.GetSubKeyNames())
                    {
                        using (Microsoft.Win32.RegistryKey e = k.OpenSubKey(name, true))
                        {
                            if (e == null) continue;
                            object exe = e.GetValue("ExecutablePath");
                            if (exe == null) continue;
                            if (!string.Equals(exe.ToString(), self, StringComparison.OrdinalIgnoreCase)) continue;
                            object cur = e.GetValue("IsPromoted");
                            object byUser = e.GetValue("IsPromotedByUser");
                            bool needPromoted = !(cur is int && (int)cur == 1);
                            bool needUser = !(byUser is int && (int)byUser == 1);
                            if (forceNotify)
                            {
                                // 先归零，让 Explorer 看见"变了"
                                e.SetValue("IsPromoted", 0, Microsoft.Win32.RegistryValueKind.DWord);
                                e.SetValue("IsPromotedByUser", 0, Microsoft.Win32.RegistryValueKind.DWord);
                                System.Threading.Thread.Sleep(40);
                                needPromoted = true;
                                needUser = true;
                            }
                            if (!needPromoted && !needUser) { ok = true; continue; }
                            // Win11 真正决定"显示在任务栏角落"的是 IsPromotedByUser：
                            // 只写 IsPromoted=1 时图标照样缩在溢出面板里（实测），
                            // 两个都写 1 才会从溢出区搬到可见托盘区。
                            e.SetValue("IsPromoted", 1, Microsoft.Win32.RegistryValueKind.DWord);
                            e.SetValue("IsPromotedByUser", 1, Microsoft.Win32.RegistryValueKind.DWord);
                            ok = true;
                            LogLine("托盘条目 " + name + " 的 IsPromoted/IsPromotedByUser 已写回 1" + (forceNotify ? "（强制翻转 0→1）" : ""));
                        }
                    }
                }
            }
            catch { }
            return ok;
        }

        private static bool TrayPinned()
        {
            try
            {
                string exe = Application.ExecutablePath;
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings"))
                {
                    if (k == null) return false;
                    foreach (string name in k.GetSubKeyNames())
                    {
                        using (Microsoft.Win32.RegistryKey sub = k.OpenSubKey(name))
                        {
                            if (sub == null) continue;
                            object p = sub.GetValue("ExecutablePath");
                            if (p == null) continue;
                            if (!string.Equals(Convert.ToString(p), exe, StringComparison.OrdinalIgnoreCase)) continue;
                            object v = sub.GetValue("IsPromoted");
                            object u = sub.GetValue("IsPromotedByUser");
                            if (v == null) return false;
                            try
                            {
                                // 两个都要是 1 才算真的"固定在可见托盘区"（只有 IsPromoted=1 时图标仍在溢出面板）
                                if (Convert.ToInt32(v) == 0) return false;
                                if (u == null) return false;
                                return Convert.ToInt32(u) != 0;
                            }
                            catch { return false; }
                        }
                    }
                }
            }
            catch { }
            return false;
        }

        private static ToolStripMenuItem Menu(string text, EventHandler onClick)
        {
            ToolStripMenuItem mi = new ToolStripMenuItem(text);
            mi.Click += onClick;
            return mi;
        }

        private static void ShowBalloon(string title, string text)
        {
            try
            {
                tray.BalloonTipTitle = title;
                tray.BalloonTipText = text;
                tray.ShowBalloonTip(4000);
            }
            catch { }
        }

        private static void ShowBalloonOnce(string title, string text)
        {
            try
            {
                // 不建临时 NotifyIcon：临时图标注册/注销会干扰 Explorer 对正式图标的缓存。
                // 改成写请求文件，主实例的 balloonPoll 定时器（2 秒一拍）用正式图标弹气泡。
                File.WriteAllText(BalloonRequest, title + Environment.NewLine + text, new UTF8Encoding(false));
            }
            catch { }
        }

        // ---------------------------------------------------------------- 守护
        private static void StartWatchdog()
        {
            watchdog = new System.Windows.Forms.Timer();
            watchdog.Interval = 4000;
            watchdog.Tick += delegate
            {
                if (stopping) return;
                try
                {
                    if (File.Exists(StopFlag))
                    {
                        LogLine("检测到 stop.flag，退出");
                        StopEverything(true);
                        Application.Exit();
                        return;
                    }
                    // Host liveness. Record the exit code once, then fall back to logs\host.pid.
                    if (hostProc != null && !hostDeathLogged)
                    {
                        try
                        {
                            if (hostProc.HasExited)
                            {
                                hostDeathLogged = true;
                                LogLine("浮层进程已退出 exit=0x" + hostProc.ExitCode.ToString("X8"));
                            }
                        }
                        catch { }
                    }
                    if (!HostAlive())
                    {
                        // 刚拉起还没写 pid 的这段时间不算死
                        if ((DateTime.Now - hostStartedAt).TotalMilliseconds >= HostSettleMs &&
                            DateTime.Now >= hostBackoffUntil)
                        {
                            if (DateTime.Now - hostRestartWindowStart > TimeSpan.FromSeconds(HostRestartWindowSec))
                            {
                                hostRestartWindowStart = DateTime.Now;
                                hostRestartWindowCount = 0;
                            }
                            hostRestartWindowCount++;
                            if (hostRestartWindowCount <= HostRestartBurst)
                            {
                                hostRestarts++;
                                LogLine("浮层不在了，自动重启（第 " + hostRestarts + " 次）");
                                StartHost(overlayVisible);
                            }
                            else
                            {
                                hostBackoffUntil = DateTime.Now.AddSeconds(HostRestartCooldownSec);
                                LogLine("浮层连续退出 " + hostRestartWindowCount + " 次，" +
                                        HostRestartCooldownSec + " 秒后再试；细节看 logs\\host_console.log");
                            }
                        }
                    }
                    else if (hostRestartWindowCount > 0 &&
                             DateTime.Now - hostRestartWindowStart > TimeSpan.FromSeconds(HostRestartWindowSec))
                    {
                        // 稳了一段时间，把重启计数清零，下次偶发退出照样能自愈
                        hostRestartWindowCount = 0;
                        hostRestarts = 0;
                    }
                    if (coreProc == null || coreProc.HasExited)
                    {
                        if (coreRestarts < 5)
                        {
                            coreRestarts++;
                            LogLine("核心不在了，自动重启（第 " + coreRestarts + " 次）");
                            StartCore();
                        }
                    }
                    if (usageProc == null || usageProc.HasExited)
                    {
                        if (usageRestarts < 5)
                        {
                            usageRestarts++;
                            LogLine("用量旁听不在了，自动重启（第 " + usageRestarts + " 次）");
                            StartUsage();
                        }
                        else if (!usageDeathLogged)
                        {
                            usageDeathLogged = true;
                            LogLine("用量旁听反复退出，已停止重启；看 logs\\dsh-usage.log");
                        }
                    }
                }
                catch { }
            };
            watchdog.Start();
        }

        private static void RestartHost()
        {
            KillProc(ref hostProc, "浮层");
            KillFromPidFile(PidHost, "powershell");
            TryDelete(PidHost);
            hostRestarts = 0;
            hostRestartWindowCount = 0;
            hostBackoffUntil = DateTime.MinValue;
            StartHost(overlayVisible);
        }

        private static void StopEverything(bool fromUser)
        {
            if (stopping) return;
            stopping = true;
            try { if (watchdog != null) watchdog.Stop(); } catch { }

            if (fromUser)
            {
                try { File.WriteAllText(StopFlag, DateTime.Now.ToString("s")); } catch { }
                SendToBus("{\"t\":\"bye\"}");
            }

            KillProc(ref hostProc, "浮层");
            KillProc(ref coreProc, "核心");
            KillProc(ref usageProc, "用量旁听");
            KillFromPidFile(PidHost, "powershell");
            KillFromPidFile(PidCore, "node");
            KillFromPidFile(PidUsage, "node");
            TryDelete(PidHost);
            TryDelete(PidCore);
            TryDelete(PidUsage);
            if (tray != null) { try { tray.Visible = false; tray.Dispose(); } catch { } }
            LogLine("已全部停止");
        }

        private static void KillProc(ref Process p, string label)
        {
            try
            {
                if (p != null && !p.HasExited)
                {
                    p.Kill();
                    p.WaitForExit(3000);
                    LogLine(label + " 已结束");
                }
            }
            catch (Exception ex) { LogLine(label + " 结束失败: " + ex.Message); }
            p = null;
        }

        private static void KillFromPidFile(string pidFile, string wantName)
        {
            try
            {
                if (!File.Exists(pidFile)) return;
                int pid;
                if (!int.TryParse(File.ReadAllText(pidFile).Trim(), out pid)) return;
                Process p = Process.GetProcessById(pid);
                if (p != null && p.ProcessName.ToLower().StartsWith(wantName))
                {
                    p.Kill();
                    p.WaitForExit(3000);
                    LogLine("按 PID 文件结束 " + p.ProcessName + " " + pid);
                }
            }
            catch { }
        }

        // 宿主是否还活着：读 logs\host.pid，再核对进程名（pid 可能被别的进程复用）
        private static bool HostAlive()
        {
            try
            {
                if (!File.Exists(PidHost))
                {
                    // 刚拉起、还没写 pid 的窗口期先当作活着，别误杀/误重启
                    return (DateTime.Now - hostStartedAt).TotalMilliseconds < HostSettleMs;
                }
                int pid;
                if (!int.TryParse(File.ReadAllText(PidHost).Trim(), out pid) || pid <= 0) return false;
                Process p = Process.GetProcessById(pid);
                if (p == null) return false;
                string name = p.ProcessName.ToLowerInvariant();
                return name == "powershell" || name == "pwsh";
            }
            catch { return false; }
        }

        // ---------------------------------------------------------------- 总线
        // 「伤害数字」开关要能记住：存在 root\tray-overlay.txt（1/0）。
        private static string OverlayFlagPath() { return Path.Combine(root, "tray-overlay.txt"); }

        private static bool ReadOverlayFlag()
        {
            try
            {
                string f = OverlayFlagPath();
                if (File.Exists(f))
                {
                    string s = File.ReadAllText(f).Trim();
                    if (s == "0" || s.Equals("false", StringComparison.OrdinalIgnoreCase)) return false;
                }
            }
            catch { }
            return true;
        }

        private static void WriteOverlayFlag(bool on)
        {
            try { File.WriteAllText(OverlayFlagPath(), on ? "1" : "0"); } catch { }
        }

        // 宿主帧率：写在 core\config.json 的 host.tickMs（宿主启动时读它）
        private static int ReadTickMs()
        {
            try
            {
                string f = Path.Combine(root, @"core\config.json");
                if (File.Exists(f))
                {
                    Match m = Regex.Match(File.ReadAllText(f), "\"tickMs\"\\s*:\\s*(\\d+)");
                    int v;
                    if (m.Success && int.TryParse(m.Groups[1].Value, out v) && v >= 20 && v <= 200) return v;
                }
            }
            catch { }
            return 40;
        }

        private static void WriteTickMs(int ms)
        {
            try
            {
                string f = Path.Combine(root, @"core\config.json");
                if (!File.Exists(f)) return;
                string txt = File.ReadAllText(f);
                if (Regex.IsMatch(txt, "\"tickMs\"\\s*:\\s*\\d+"))
                    txt = Regex.Replace(txt, "(\"tickMs\"\\s*:\\s*)\\d+", "${1}" + ms.ToString(CultureInfo.InvariantCulture), RegexOptions.None);
                File.WriteAllText(f, txt);
                LogLine("宿主帧率 -> " + ms + "ms");
            }
            catch { }
        }

        private static void SendToBus(string json)
        {
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    c.Connect("127.0.0.1", busPort);
                    using (NetworkStream s = c.GetStream())
                    {
                        byte[] b = Encoding.UTF8.GetBytes(json + "\n");
                        s.Write(b, 0, b.Length);
                        s.Flush();
                        // 写完不能马上扔 socket：核心一连上就推了 hello/state，我们不读就走，
                        // 系统会发 RST，核心那头可能还没把这一行读出来就被重置 —— 消息就丢了。
                        // 所以先半关写端，再把核心推过来的那点数据读掉再关。
                        try { c.Client.Shutdown(SocketShutdown.Send); } catch { }
                        try
                        {
                            c.Client.ReceiveTimeout = 400;
                            byte[] tmp = new byte[4096];
                            while (s.Read(tmp, 0, tmp.Length) > 0) { }
                        }
                        catch { }
                    }
                }
            }
            catch (Exception ex) { LogLine("总线发送失败: " + ex.Message); }
        }

        private static int ReadBusPort()
        {
            try
            {
                string cfg = Path.Combine(root, @"core\config.json");
                if (!File.Exists(cfg)) return 17777;
                string text = File.ReadAllText(cfg);
                int i = text.IndexOf("\"bus\"", StringComparison.OrdinalIgnoreCase);
                if (i < 0) return 17777;
                int j = text.IndexOf("\"port\"", i, StringComparison.OrdinalIgnoreCase);
                if (j < 0) return 17777;
                int k = text.IndexOf(':', j);
                int e = k + 1;
                while (e < text.Length && (char.IsDigit(text[e]) || text[e] == ' ')) e++;
                int port;
                if (int.TryParse(text.Substring(k + 1, e - k - 1).Trim(), out port)) return port;
            }
            catch { }
            return 17777;
        }

        // ---------------------------------------------------------------- 工具
        private static void RunPreview()
        {
            string psh = FindPowerShell();
            string script = Path.Combine(root, @"host\dsh-overlay.ps1");
            ProcessStartInfo psi = new ProcessStartInfo(psh,
                "-NoProfile -STA -ExecutionPolicy Bypass -File " + Quote(script) + " -RenderPreview");
            psi.WorkingDirectory = root;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            try { Process.Start(psi); } catch { }
        }

        private static void RunNodeQuiet(string relScript, string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(nodePath, Quote(Path.Combine(root, relScript)) + " " + args);
                psi.WorkingDirectory = root;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                Process.Start(psi);
            }
            catch (Exception ex) { LogLine("跑脚本失败: " + ex.Message); }
        }

        private static void OpenFolder(string relPath)
        {
            try
            {
                string p = Path.Combine(root, relPath);
                if (!Directory.Exists(p)) Directory.CreateDirectory(p);
                Process.Start("explorer.exe", Quote(p));
            }
            catch { }
        }

        private static void ToggleAutostart()
        {
            string lnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "dafeiyu.lnk");
            bool on = File.Exists(lnk);
            SetAutostart(!on);
            ShowBalloon("大肥鱼", on ? "已关闭开机自启" : "已开启开机自启（启动后是桌宠模式）");
        }

        private static void SetAutostart(bool on)
        {
            try
            {
                string lnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "dafeiyu.lnk");
                if (!on)
                {
                    if (File.Exists(lnk)) File.Delete(lnk);
                    return;
                }
                Type t = Type.GetTypeFromProgID("WScript.Shell");
                object sh = Activator.CreateInstance(t);
                object shortcut = t.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, sh, new object[] { lnk });
                Type st = shortcut.GetType();
                st.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { Application.ExecutablePath });
                st.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { root });
                st.InvokeMember("Description", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { "大肥鱼" });
                st.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, shortcut, null);
            }
            catch (Exception ex) { LogLine("自启设置失败: " + ex.Message); }
        }

        private static string FindNode()
        {
            string bundled = Path.Combine(root, @"runtime\node.exe");
            if (File.Exists(bundled)) return bundled;
            string common = @"C:\Tool\Node.js\node.exe";
            if (File.Exists(common)) return common;
            return FindOnPath("node.exe");
        }

        private static string FindPowerShell()
        {
            string win = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (File.Exists(win)) return win;
            string p = FindOnPath("pwsh.exe");
            return p != null ? p : "powershell.exe";
        }

        private static string FindOnPath(string exeName)
        {
            try
            {
                string path = Environment.GetEnvironmentVariable("PATH");
                if (string.IsNullOrEmpty(path)) return null;
                foreach (string dir in path.Split(';'))
                {
                    if (string.IsNullOrEmpty(dir)) continue;
                    try
                    {
                        string full = Path.Combine(dir.Trim(), exeName);
                        if (File.Exists(full)) return full;
                    }
                    catch { }
                }
            }
            catch { }
            return null;
        }

        private static string Quote(string s) { return "\"" + s + "\""; }

        // 启动器允许放在桌宠目录外面（例如 C:\Tool\DSHPet\dsh-overlay.exe），
        // 用 root.txt / 环境变量 DSH_OVERLAY_ROOT / --root 指回真正的桌宠目录。
        // 为什么必须能搬出去：放在 <项目目录> 这棵目录里的未签名 exe，
        // Windows 既不让 shell 直接启动（ERROR_CANCELLED），也不会给它建
        // HKCU\Control Panel\NotifyIconSettings 条目 —— 结果托盘图标永远进不了
        // “其他系统托盘图标”列表，只能在溢出面板里待着，复制到新路径还会“消失”。
        private static string ResolveRoot(string[] args)
        {
            string fromArg = GetArgValue(args, "--root");
            if (!string.IsNullOrEmpty(fromArg) && Directory.Exists(fromArg)) return TrimSlash(fromArg);

            string fromEnv = Environment.GetEnvironmentVariable("DSH_OVERLAY_ROOT");
            if (!string.IsNullOrEmpty(fromEnv) && Directory.Exists(fromEnv)) return TrimSlash(fromEnv);

            string exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            string[] names = new string[] { "root.txt", "pet-root.txt" };
            foreach (string n in names)
            {
                try
                {
                    if (string.IsNullOrEmpty(exeDir)) break;
                    string f = Path.Combine(exeDir, n);
                    if (!File.Exists(f)) continue;
                    string v = File.ReadAllText(f).Trim().Trim('"');
                    if (v.Length > 0 && Directory.Exists(v)) return TrimSlash(v);
                }
                catch { }
            }
            return string.IsNullOrEmpty(exeDir) ? "." : exeDir;
        }

        private static string TrimSlash(string p)
        {
            if (p == null) return p;
            if (p.Length > 3) return p.TrimEnd('\\', '/');
            return p;
        }

        private static string GetArgValue(string[] args, string name)
        {
            if (args == null) return null;
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                if (string.IsNullOrEmpty(a)) continue;
                if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase))
                    return (i + 1 < args.Length) ? args[i + 1] : null;
                if (a.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
                    return a.Substring(name.Length + 1);
            }
            return null;
        }

        private static bool HasArg(string[] args, string name)
        {
            foreach (string a in args)
            {
                if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }

        private static void ShowHelp()
        {
            string msg =
                "dafeiyu.exe —— AI 花钱可视化桌宠\n\n" +
                "  dafeiyu.exe                 桌宠模式（只有右下角小挂件）\n" +
                "  dafeiyu.exe --overlay       完整模式（多一套全屏伤害数字）\n" +
                "  dafeiyu.exe --preview       生成预览图到 preview\\\n" +
                "  dafeiyu.exe --stop          停止所有后台进程\n" +
                "  dafeiyu.exe --autostart     开启开机自启（桌宠模式）\n" +
                "  dafeiyu.exe --no-autostart  关闭开机自启\n\n" +
                "跑起来之后看右下角托盘（鲸鱼头像），所有开关都在那里。";
            MessageBox.Show(msg, "大肥鱼", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }
}

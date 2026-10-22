// DshOverlayRelay —— 桌宠工作区里的"转发器"。
//
// 为什么需要它：
//   这个目录（<项目目录>\...）里的未签名 exe，Windows 不肯给它
//   建 HKCU\Control Panel\NotifyIconSettings 条目，托盘图标就只能缩在溢出面板里，
//   而且 DSH 沙箱里用 shell 启动还会直接 ERROR_CANCELLED。
//   把真正干活的 dsh-overlay.exe 搬到 C:\Tool\DSHPet\ 之后托盘条目自动出现，
//   在设置里打开"其他系统托盘图标"就固定到可见托盘区了。
//
// 这个转发器留在原地，是为了让"双击工作区里的 dsh-overlay.exe"这个老习惯继续能用：
//   它只做一件事 —— 把真正的启动器拉起来，然后自己退出。
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class DshOverlayRelay
{
    private const string DefaultTarget = @"C:\Tool\DSHPet\dafeiyu.exe";

    [STAThread]
    private static void Main(string[] args)
    {
        string target = DefaultTarget;
        string here = Path.GetDirectoryName(Application.ExecutablePath);

        // 允许用同目录下的 pet-target.txt 指定别的主程序位置
        try
        {
            if (here != null)
            {
                string[] hints = new string[] { "pet-target.txt", "root-target.txt" };
                foreach (string h in hints)
                {
                    string f = Path.Combine(here, h);
                    if (!File.Exists(f)) continue;
                    string t = File.ReadAllText(f).Trim().Trim('"');
                    if (t.Length > 0 && File.Exists(t)) { target = t; break; }
                }
            }
        }
        catch { }

        if (!File.Exists(target))
        {
            MessageBox.Show(
                "找不到桌宠主程序：\n" + target +
                "\n\n真身应该放在 C:\\Tool\\DSHPet\\dafeiyu.exe（那里托盘才注册得上）。\n" +
                "如果那个目录没了，把工作区里的 build\\dafeiyu.new.exe 复制过去即可。",
                "dafeiyu 桌宠", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        ProcessStartInfo psi = new ProcessStartInfo(target);
        psi.WorkingDirectory = Path.GetDirectoryName(target);
        // 关键：必须 UseShellExecute=false，直接 CreateProcess 拉起真身。
        // 实测（2026-10-22 02:0x）：走 ShellExecute 时，真身进程虽然起来了，
        // 但 Explorer 给它的托盘图标一律塞进溢出面板（IsPromoted/IsPromotedByUser 都是 1 也没用）；
        // 同一条命令改成 CreateProcess 直启，图标立刻出现在可见托盘区。
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.Arguments = JoinArgs(args);
        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show("启动桌宠失败：" + ex.Message + "\n目标：" + target,
                "dafeiyu 桌宠", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static string JoinArgs(string[] args)
    {
        if (args == null || args.Length == 0) return "";
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        foreach (string a in args)
        {
            if (sb.Length > 0) sb.Append(' ');
            bool needQuote = a.IndexOf(' ') >= 0 || a.IndexOf('\t') >= 0;
            if (needQuote) sb.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
            else sb.Append(a);
        }
        return sb.ToString();
    }
}

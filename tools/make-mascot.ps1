#requires -Version 5.1
# 把任意白底立绘处理成透明底挂件素材
#   powershell -STA -File tools\make-mascot.ps1
#   powershell -STA -File tools\make-mascot.ps1 -Src 别的图.png -MaxSize 640 -Tolerance 20
param(
  [string]$Src = '',
  [string]$Dst = '',
  [int]$Tolerance = 22,
  [int]$MaxSize = 640,
  [int]$Padding = 6,
  [switch]$SkipKey,          # 源图已经是透明底时用这个：只裁切+缩放，不抠背景
  [switch]$Square            # 输出补透明边成正方形（避免换图时缩放跳动）
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'images'
if (-not $Src) { $Src = Join-Path $assets 'mascot-src.png' }
if (-not $Dst) { $Dst = Join-Path $assets 'mascot.png' }
if (-not (Test-Path -LiteralPath $Src)) { throw "找不到源图：$Src" }

if (-not ('DshMascot' -as [type])) {
  Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class DshMascot
{
    public static string Process(string src, string dst, int tol, int maxSize, int padding, bool skipKey, bool square)
    {
        using (var bmp = new Bitmap(src))
        {
            int w = bmp.Width, h = bmp.Height;
            var rect = new Rectangle(0, 0, w, h);
            var data = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            int stride = data.Stride;
            byte[] buf = new byte[stride * h];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, buf.Length);

            if (!skipKey)
            {
                // 以左上角像素为背景基准色
                byte br = buf[2], bg = buf[1], bb = buf[0];
                bool[] bgMask = new bool[w * h];
                var stack = new Stack<int>();
                Func<int, int, int, bool> isBg = (x, y, t) =>
                {
                    int i = y * stride + x * 4;
                    int d = Math.Abs(buf[i + 2] - br) + Math.Abs(buf[i + 1] - bg) + Math.Abs(buf[i] - bb);
                    return d <= t;
                };
                int T = tol * 3;
                for (int x = 0; x < w; x++) { if (isBg(x, 0, T)) stack.Push(x); if (isBg(x, h - 1, T)) stack.Push((h - 1) * w + x); }
                for (int y = 0; y < h; y++) { if (isBg(0, y, T)) stack.Push(y * w); if (isBg(w - 1, y, T)) stack.Push(y * w + w - 1); }
                while (stack.Count > 0)
                {
                    int p = stack.Pop();
                    if (bgMask[p]) continue;
                    int px = p % w, py = p / w;
                    if (!isBg(px, py, T)) continue;
                    bgMask[p] = true;
                    if (px > 0) stack.Push(p - 1);
                    if (px < w - 1) stack.Push(p + 1);
                    if (py > 0) stack.Push(p - w);
                    if (py < h - 1) stack.Push(p + w);
                }

                // 边缘羽化：紧贴背景的浅色像素给半透明
                for (int y = 0; y < h; y++)
                {
                    for (int x = 0; x < w; x++)
                    {
                        int p = y * w + x;
                        if (bgMask[p]) { buf[y * stride + x * 4 + 3] = 0; continue; }
                        bool near = (x > 0 && bgMask[p - 1]) || (x < w - 1 && bgMask[p + 1]) ||
                                    (y > 0 && bgMask[p - w]) || (y < h - 1 && bgMask[p + w]);
                        if (!near) continue;
                        int i = y * stride + x * 4;
                        int lum = (buf[i + 2] + buf[i + 1] + buf[i]) / 3;
                        if (lum > 150)
                        {
                            int a = (int)Math.Max(0, Math.Min(255, (255 - lum) * 255 / 105));
                            if (a < buf[i + 3]) buf[i + 3] = (byte)a;
                        }
                    }
                }
            }
            System.Runtime.InteropServices.Marshal.Copy(buf, 0, data.Scan0, buf.Length);
            bmp.UnlockBits(data);

            // 裁切到内容边界
            int minX = w, minY = h, maxX = -1, maxY = -1;
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    if (buf[y * stride + x * 4 + 3] > 8)
                    {
                        if (x < minX) minX = x; if (x > maxX) maxX = x;
                        if (y < minY) minY = y; if (y > maxY) maxY = y;
                    }
                }
            }
            if (maxX < 0) { minX = 0; minY = 0; maxX = w - 1; maxY = h - 1; }
            minX = Math.Max(0, minX - padding); minY = Math.Max(0, minY - padding);
            maxX = Math.Min(w - 1, maxX + padding); maxY = Math.Min(h - 1, maxY + padding);
            int cw = maxX - minX + 1, ch = maxY - minY + 1;

            int outW = cw, outH = ch;
            if (maxSize > 0 && Math.Max(cw, ch) > maxSize)
            {
                double k = (double)maxSize / Math.Max(cw, ch);
                outW = (int)Math.Round(cw * k); outH = (int)Math.Round(ch * k);
            }
            int canvasW = outW, canvasH = outH;
            if (square) { int side = Math.Max(outW, outH); canvasW = side; canvasH = side; }
            using (var outBmp = new Bitmap(outW, outH, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(outBmp))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    g.DrawImage(bmp, new Rectangle(0, 0, outW, outH), new Rectangle(minX, minY, cw, ch), GraphicsUnit.Pixel);
                }
                if (square)
                {
                    using (var canvas = new Bitmap(canvasW, canvasH, PixelFormat.Format32bppArgb))
                    {
                        using (var g2 = Graphics.FromImage(canvas))
                        {
                            g2.Clear(Color.Transparent);
                            g2.DrawImage(outBmp, new Rectangle((canvasW - outW) / 2, (canvasH - outH) / 2, outW, outH));
                        }
                        canvas.Save(dst, ImageFormat.Png);
                    }
                }
                else outBmp.Save(dst, ImageFormat.Png);
            }
            return string.Format("{4}裁切 {0}x{1} -> 输出 {2}x{3}", cw, ch, outW, outH, skipKey ? "已跳过抠图，" : "");
        }
    }
}
'@
}

$msg = [DshMascot]::Process($Src, $Dst, $Tolerance, $MaxSize, $Padding, [bool]$SkipKey, [bool]$Square)
Write-Host ("源图: {0}" -f $Src)
Write-Host ("输出: {0}" -f $Dst)
Write-Host $msg

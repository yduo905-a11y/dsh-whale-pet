#requires -Version 5.1
# 用挂件立绘生成多尺寸 ICO（PNG 压缩条目，Vista+ 通用）
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File tools\make-icon.ps1
param(
  [string]$Src = '',
  [string]$Dst = '',
  [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256)
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot -Parent
if (-not $Src) { $Src = Join-Path $root 'images\mascot.png' }
if (-not $Dst) { $Dst = Join-Path $root 'assets\dsh-overlay.ico' }
if (-not (Test-Path -LiteralPath $Src)) { throw "找不到源图：$Src" }
$dstDir = Split-Path $Dst -Parent
if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }

$srcImg = [System.Drawing.Image]::FromFile($Src)

function New-SquarePng {
  param([System.Drawing.Image]$Img, [int]$Size)
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  # 小尺寸留 1px 内边距，避免贴边被裁
  $pad = if ($Size -le 32) { 1 } else { [int]($Size * 0.03) }
  $box = $Size - 2 * $pad
  $ratio = [Math]::Min($box / $Img.Width, $box / $Img.Height)
  $w = [int][Math]::Round($Img.Width * $ratio)
  $h = [int][Math]::Round($Img.Height * $ratio)
  $x = [int](($Size - $w) / 2)
  $y = [int](($Size - $h) / 2)
  $g.DrawImage($Img, (New-Object System.Drawing.Rectangle($x, $y, $w, $h)))
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bytes = $ms.ToArray()
  $ms.Dispose(); $bmp.Dispose()
  return , $bytes
}

$entries = @()
foreach ($s in $Sizes) { $entries += [pscustomobject]@{ Size = $s; Data = (New-SquarePng -Img $srcImg -Size $s) } }
$srcImg.Dispose()

$fs = [IO.File]::Create($Dst)
$bw = New-Object IO.BinaryWriter($fs)
$bw.Write([UInt16]0)                      # reserved
$bw.Write([UInt16]1)                      # type = icon
$bw.Write([UInt16]$entries.Count)         # count
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
  $b = if ($e.Size -ge 256) { 0 } else { $e.Size }
  $bw.Write([Byte]$b)                     # width
  $bw.Write([Byte]$b)                     # height
  $bw.Write([Byte]0)                      # colors
  $bw.Write([Byte]0)                      # reserved
  $bw.Write([UInt16]1)                    # planes
  $bw.Write([UInt16]32)                   # bpp
  $bw.Write([UInt32]$e.Data.Length)
  $bw.Write([UInt32]$offset)
  $offset += $e.Data.Length
}
foreach ($e in $entries) { $bw.Write($e.Data) }
$bw.Flush(); $bw.Close(); $fs.Close()

Write-Host ("源图: {0}" -f $Src)
Write-Host ("输出: {0}  ({1} 字节, 尺寸 {2})" -f $Dst, (Get-Item -LiteralPath $Dst).Length, ($Sizes -join '/'))

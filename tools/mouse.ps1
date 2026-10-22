param(
  [Parameter(Mandatory=$true)][string]$Action,
  [int]$X = 0,
  [int]$Y = 0,
  [int]$X2 = 0,
  [int]$Y2 = 0,
  [int]$Steps = 24,
  [int]$HoldMs = 120
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class M {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004, MOVE = 0x0001;
  public static void Down() { mouse_event(LEFTDOWN, 0, 0, 0, IntPtr.Zero); }
  public static void Up() { mouse_event(LEFTUP, 0, 0, 0, IntPtr.Zero); }
}
"@
[M]::SetProcessDPIAware() | Out-Null

function Move-To([int]$px, [int]$py) {
  [M]::SetCursorPos($px, $py) | Out-Null
  Start-Sleep -Milliseconds 30
}

function Glide([int]$fx, [int]$fy, [int]$tx, [int]$ty, [int]$n) {
  for ($i = 1; $i -le $n; $i++) {
    $x = [int]($fx + ($tx - $fx) * $i / $n)
    $y = [int]($fy + ($ty - $fy) * $i / $n)
    [M]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 12
  }
}

switch ($Action) {
  "move"  { Move-To $X $Y; "moved $X,$Y" }
  "click" { Move-To $X $Y; [M]::Down(); Start-Sleep -Milliseconds 60; [M]::Up(); "clicked $X,$Y" }
  "down"  { Move-To $X $Y; [M]::Down(); "down at $X,$Y" }
  "up"    { [M]::Up(); "up" }
  "drag"  {
    Move-To $X $Y
    [M]::Down()
    Start-Sleep -Milliseconds $HoldMs
    Glide $X $Y $X2 $Y2 $Steps
    Start-Sleep -Milliseconds $HoldMs
    [M]::Up()
    "dragged $X,$Y -> $X2,$Y2"
  }
  default { "unknown action" }
}

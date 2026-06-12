# Resets a wedged WSLg (RAIL) window by cycling minimize/restore/maximize.
#
# When WSLg's Wayland configure pipeline wedges (microsoft/wslg#643), the
# Linux client (pgtk Emacs) stops receiving resize/configure events: the
# screen freezes on stale pixels while keyboard input still arrives, and
# Emacs-side maximize requests are silently ignored. Cycling the window
# state from the WINDOWS side forces Weston's RAIL shell to re-sync and
# configure events flow again.
#
# Called from Emacs (+wslg-fix-display, F12) via WSL interop, or manually
# via the "Doom Emacs reparieren" Start-Menu shortcut.
param([string]$TitleMatch = "Doom Emacs")
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public class WslgFix {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  public struct RECT { public int L, T, R, B; }
  delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);
  public static long Find(string match) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, lp) => {
      var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
      if (IsWindowVisible(h) && sb.ToString().Contains(match)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found.ToInt64();
  }
}
"@
$hwnd = [WslgFix]::Find($TitleMatch)
if ($hwnd -eq 0) { Write-Output "window not found"; exit 1 }
[WslgFix]::ShowWindow([IntPtr]$hwnd, 6) | Out-Null   # SW_MINIMIZE
Start-Sleep -Milliseconds 800

# Bare SW_RESTORE can fail to land in the RAIL layer (window stays parked
# minimized at huge negative coordinates). Empirically reliable:
# SW_SHOWNORMAL + SetWindowPos with an explicit on-screen rect, verified
# with retries.
$restored = $false
for ($i = 0; $i -lt 5; $i++) {
  [WslgFix]::ShowWindow([IntPtr]$hwnd, 1) | Out-Null  # SW_SHOWNORMAL
  Start-Sleep -Milliseconds 500
  # 0x0040 = SWP_SHOWWINDOW
  [WslgFix]::SetWindowPos([IntPtr]$hwnd, [IntPtr]::Zero, 100, 100, 1800, 1100, 0x0040) | Out-Null
  Start-Sleep -Milliseconds 900
  $r = New-Object WslgFix+RECT
  [WslgFix]::GetWindowRect([IntPtr]$hwnd, [ref]$r) | Out-Null
  if ($r.L -gt -10000 -and ($r.R - $r.L) -gt 300) { $restored = $true; break }
  Start-Sleep -Milliseconds 600
}
if (-not $restored) { Write-Output "restore failed"; exit 2 }

[WslgFix]::ShowWindow([IntPtr]$hwnd, 3) | Out-Null   # SW_MAXIMIZE
[WslgFix]::SetForegroundWindow([IntPtr]$hwnd) | Out-Null
Write-Output "window reset done"
exit 0

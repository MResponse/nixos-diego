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
[WslgFix]::ShowWindow([IntPtr]$hwnd, 9) | Out-Null   # SW_RESTORE
Start-Sleep -Milliseconds 500
[WslgFix]::ShowWindow([IntPtr]$hwnd, 3) | Out-Null   # SW_MAXIMIZE
[WslgFix]::SetForegroundWindow([IntPtr]$hwnd) | Out-Null
Write-Output "window reset done"
exit 0

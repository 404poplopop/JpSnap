# JpSnap hotkey listener: Ctrl+Alt+J starts jpsnap.vbs. Runs hidden from the Startup folder.
# Shortcut (.lnk) hotkeys only work once Explorer has rescanned, so the hotkey is registered here instead.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $dir 'hotkey.log'
$mutex = New-Object Threading.Mutex($false, 'Local\JpSnapHotkey')
if (-not $mutex.WaitOne(0)) { exit }  # already running
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System; using System.Diagnostics; using System.Runtime.InteropServices; using System.Windows.Forms;
public class JpSnapHotkey : NativeWindow {
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    readonly string vbs;
    public JpSnapHotkey(string vbs) {
        this.vbs = vbs;
        CreateHandle(new CreateParams());
        // MOD_ALT 1 | MOD_CONTROL 2 | MOD_NOREPEAT 0x4000, VK 'J'
        if (!RegisterHotKey(Handle, 1, 0x4003, 0x4A)) throw new Exception("RegisterHotKey Ctrl+Alt+J failed, error " + Marshal.GetLastWin32Error() + " (1409 = taken by another app)");
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) Process.Start("wscript.exe", "\"" + vbs + "\"");  // WM_HOTKEY
        base.WndProc(ref m);
    }
}
'@
try {
    $hk = New-Object JpSnapHotkey (Join-Path $dir 'jpsnap.vbs')
    "$(Get-Date -Format s) registered Ctrl+Alt+J hwnd=$($hk.Handle) pid=$PID" | Out-File -Encoding utf8 $log
    [Windows.Forms.Application]::Run()
} catch {
    "$(Get-Date -Format s) ERROR $($_.Exception.InnerException.Message) $($_.Exception.Message)" | Out-File -Encoding utf8 $log
}

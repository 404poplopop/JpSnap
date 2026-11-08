# JpSnap installer: hotkey shortcut + PC-mode runtime (venv with edge-tts). Safe to rerun.
$dir = "$env:LOCALAPPDATA\JpSnap"
# Start Menu entry for a manual start; the hotkey comes from hotkey.ps1 (shortcut hotkeys need an Explorer rescan).
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut("$([Environment]::GetFolderPath('Programs'))\JpSnap.lnk")
$lnk.TargetPath = "$env:WINDIR\System32\wscript.exe"
$lnk.Arguments = "`"$dir\jpsnap.vbs`""
$lnk.WorkingDirectory = $dir
$lnk.Hotkey = ''
$lnk.Description = 'Snip Japanese text and translate it'
$lnk.Save()
"LNK=" + (Test-Path "$([Environment]::GetFolderPath('Programs'))\JpSnap.lnk")
# Hotkey listener at every logon (Startup folder), hidden through hotkey.vbs.
$hk = (New-Object -ComObject WScript.Shell).CreateShortcut("$([Environment]::GetFolderPath('Startup'))\JpSnap hotkey.lnk")
$hk.TargetPath = "$env:WINDIR\System32\wscript.exe"
$hk.Arguments = "`"$dir\hotkey.vbs`""
$hk.WorkingDirectory = $dir
$hk.Save()
"STARTUP_LNK=" + (Test-Path "$([Environment]::GetFolderPath('Startup'))\JpSnap hotkey.lnk")
if (-not (Test-Path "$dir\venv\Scripts\pythonw.exe")) { & py -3.11 -m venv "$dir\venv" }
& "$dir\venv\Scripts\python.exe" -m pip install -q --disable-pip-version-check edge-tts==7.3.1 2>&1 | Select-Object -Last 2
& "$dir\venv\Scripts\python.exe" -I "$dir\core\jpsnap_core.py" selftest

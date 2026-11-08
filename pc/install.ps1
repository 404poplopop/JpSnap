# JpSnap setup (started by setup.bat): installs or updates JpSnap in %LOCALAPPDATA%\JpSnap for this Windows user.
# No admin needed. Safe to rerun: config.json, the ssh key, known_hosts and the Python venv are kept.
param(
    [ValidateSet('Ask', 'Yes', 'No', 'Keep')][string]$AutoStart = 'Ask',  # start the Ctrl+Alt+J listener with Windows
    [string]$InstallDir = "$env:LOCALAPPDATA\JpSnap",  # any other folder = test install: no shortcuts, nothing started
    [switch]$NoStart  # do not (re)start the Ctrl+Alt+J listener now
)
$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot  # the download: setup.bat at the top, this file in pc\
$isTest = $InstallDir -ne "$env:LOCALAPPDATA\JpSnap"
function Write-JpStep([string]$text, [string]$color = 'Gray') { Write-Host "  $text" -ForegroundColor $color }

# ---------- app files ----------
[void](New-Item -ItemType Directory -Force $InstallDir, "$InstallDir\core")
if (Test-Path "$source\jpsnap_core.py") {  # run from a download or clone (not from an installed copy): copy the app in
    robocopy "$source\pc" $InstallDir /E /NJH /NJS /NFL /NDL /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-JpStep "Copying the app failed (robocopy $LASTEXITCODE)." Red; exit 1 }
    $core = 'jpsnap_core.py', 'schema.json', 'prompt.txt', 'prompt_fast.txt', 'accents.txt'
    Copy-Item -Force ($core | ForEach-Object { Join-Path $source $_ }) "$InstallDir\core"
}
# files from a downloaded zip are marked "from the internet"; Windows would warn on every start
Get-ChildItem "$InstallDir\*", "$InstallDir\lib\*", "$InstallDir\ui\*", "$InstallDir\core\*" -File | Unblock-File
Write-JpStep "App installed in $InstallDir"
. "$InstallDir\lib\config.ps1"

# ---------- first run: translate on this PC unless a server key is there ----------
$cfgFile = Join-Path $InstallDir 'config.json'
if (-not (Test-Path $cfgFile)) {
    $cfg = Read-JpConfig $cfgFile
    if (-not (Test-Path "$InstallDir\jpsnap_key")) { $cfg.run_on = 'pc' }
    Save-JpConfig $cfgFile $cfg
}
$cfg = Read-JpConfig $cfgFile

# ---------- Python venv with the voice (edge-tts); needed when translating on this PC ----------
# Python 3.11-3.14: requirements.txt pins Windows wheels that exist for exactly those versions.
$supported = "import sys; sys.exit(0 if (3, 11) <= sys.version_info[:2] <= (3, 14) else 1)"
$py = $null
if (Get-Command py -ErrorAction SilentlyContinue) {
    foreach ($v in '3.14', '3.13', '3.12', '3.11') {  # a missing version prints to stderr, which 'Stop' would turn into an error
        try { $exe = & py "-$v" -c "import sys; print(sys.executable)" 2>$null } catch { $exe = $null }
        if ($LASTEXITCODE -eq 0 -and $exe) { $py = $exe; break }
    }
}
if (-not $py) {  # the Windows Store "python" stub does not count
    $found = Get-Command python.exe -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
    if ($found) { & $found.Source -c $supported; if ($LASTEXITCODE -eq 0) { $py = $found.Source } }
}
if ($py) {
    if (-not (Test-Path "$InstallDir\venv\Scripts\pythonw.exe")) { Write-JpStep 'Creating the Python environment...'; & $py -m venv "$InstallDir\venv" }
    Write-JpStep 'Installing the voice (edge-tts)...'
    # exact versions with SHA-256 hashes, wheels only: a changed or new release is refused and no build scripts run
    & "$InstallDir\venv\Scripts\python.exe" -m pip install -q --disable-pip-version-check --only-binary=:all: --require-hashes -r "$InstallDir\requirements.txt"
    if ($LASTEXITCODE) { Write-JpStep 'Installing the voice failed. If Python was upgraded, delete the venv folder and run setup.bat again.' Red; exit 1 }
    $check = & "$InstallDir\venv\Scripts\python.exe" -I "$InstallDir\core\jpsnap_core.py" selftest
    if ($check -eq 'selftest ok') { Write-JpStep 'Self-test ok' } else { Write-JpStep "Self-test failed: $check" Red; exit 1 }
} elseif ($cfg.run_on -eq 'pc') {
    Write-JpStep 'Python 3.11-3.14 is missing. Install it (https://www.python.org/downloads/ or: winget install Python.Python.3.12),' Yellow
    Write-JpStep 'then run setup.bat again.' Yellow
}

# ---------- Codex CLI (translations on this PC) ----------
if ($cfg.run_on -eq 'pc') {
    $codex = @(Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\bin" -Recurse -Filter codex.exe -ErrorAction SilentlyContinue) + @(Get-Command codex.exe -ErrorAction SilentlyContinue)
    if ($codex) { Write-JpStep 'Codex found' }
    else { Write-JpStep 'Codex is missing: install the Codex app or CLI and sign in (codex login), or add an OpenAI API key in settings.' Yellow }
}

# ---------- shortcuts and start with Windows ----------
if ($isTest) { Write-JpStep 'Test install: shortcuts and the hotkey listener were left alone.'; exit 0 }
$menu = (New-Object -ComObject WScript.Shell).CreateShortcut("$([Environment]::GetFolderPath('Programs'))\JpSnap.lnk")
$menu.TargetPath = "$env:WINDIR\System32\wscript.exe"; $menu.Arguments = "`"$InstallDir\jpsnap.vbs`""
$menu.WorkingDirectory = $InstallDir; $menu.Description = 'Snip Japanese text and break it down'; $menu.Save()

if ($AutoStart -eq 'Ask') {
    Write-Host ''
    $answer = Read-Host '  Start JpSnap with Windows, so Ctrl+Alt+J always works? [Y/n]'
    $AutoStart = if ($answer -match '^\s*n') { 'No' } else { 'Yes' }
}
if ($AutoStart -ne 'Keep') { Set-JpAutoStart ($AutoStart -eq 'Yes') $InstallDir }

if (-not $NoStart) {  # (re)start the listener so Ctrl+Alt+J works right away, with the files just installed
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains("$InstallDir\hotkey.ps1") } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-Process "$env:WINDIR\System32\wscript.exe" "`"$InstallDir\hotkey.vbs`""
}

Write-Host ''
Write-JpStep 'Ready: press Ctrl+Alt+J and drag over Japanese text.' Green
Write-JpStep "Starts with Windows: $(if (Test-JpAutoStart) { 'yes' } else { 'no' }) (change it in the settings window or run setup.bat again)"
Write-JpStep "Translating on: $(if ($cfg.run_on -eq 'pc') { 'this PC' } else { "the server $($cfg.server)" })"

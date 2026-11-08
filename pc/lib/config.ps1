# Settings in config.json beside jpsnap.ps1. The OpenAI API key is stored DPAPI-encrypted for the current Windows
# user (openai_api_key_dpapi); a plain openai_api_key from older versions is encrypted and removed on first read.
Add-Type -AssemblyName System.Security

$JpDefaults = [ordered]@{ run_on = 'server'; server = ''; fast = $true; voice = 'nanami'; speed = 'normal'; openai_api_key_dpapi = '' }
$JpChoices = @{ run_on = 'server', 'pc'; voice = 'nanami', 'keita'; speed = 'normal', 'slow' }

# user@host only: no spaces, no leading '-', so the value can never turn into an ssh option.
function Test-JpServer([string]$server) { $server -match '^[A-Za-z0-9_][A-Za-z0-9._-]{0,31}@[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z' }
function Test-JpApiKey([string]$key) { $key -cmatch '^(sk-[A-Za-z0-9_-]{8,200})?\z' }

function Protect-JpSecret([string]$plain) {
    if (-not $plain) { return '' }
    [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($plain), $null, 'CurrentUser'))
}
function Unprotect-JpSecret([string]$blob) {
    if (-not $blob) { return '' }
    try { [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($blob), $null, 'CurrentUser')) }
    catch { '' }  # made by another Windows user or damaged: treat as no key
}

function Read-JpConfig([string]$file) {
    $cfg = [ordered]@{}
    foreach ($name in $JpDefaults.Keys) { $cfg[$name] = $JpDefaults[$name] }
    if (-not (Test-Path $file)) { return $cfg }
    $saved = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    foreach ($prop in $saved.PSObject.Properties) {
        $name = $prop.Name; $value = $prop.Value
        if (-not $cfg.Contains($name)) { continue }
        if ($JpChoices.ContainsKey($name) -and $value -notin $JpChoices[$name]) { continue }  # unknown value: keep the default
        if ($name -eq 'fast' -and $value -isnot [bool]) { continue }  # [bool]'false' would be $true
        $cfg[$name] = $value
    }
    if ($saved.openai_api_key) {  # migrate a plain-text key
        if (Test-JpApiKey $saved.openai_api_key) { $cfg.openai_api_key_dpapi = Protect-JpSecret $saved.openai_api_key }
        Save-JpConfig $file $cfg
    }
    $cfg
}

# Change only these fields, in the latest config.json: another JpSnap window may have saved since this one started,
# and writing back this window's whole snapshot would undo that (even restore a removed API key).
function Update-JpConfig([string]$file, [hashtable]$changes) {
    $lock = New-Object Threading.Mutex($false, 'Local\JpSnapConfig')
    try { $owned = $lock.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $owned = $true }
    try {
        $latest = Read-JpConfig $file
        foreach ($name in $changes.Keys) { $latest[$name] = $changes[$name] }
        Save-JpConfig $file $latest
        $latest
    } finally { if ($owned) { $lock.ReleaseMutex() }; $lock.Dispose() }
}

# ---------- start with Windows: a Startup-folder shortcut to hotkey.vbs (the hidden Ctrl+Alt+J listener) ----------
function Get-JpAutoStartLink([string]$startupDir = [Environment]::GetFolderPath('Startup')) { Join-Path $startupDir 'JpSnap hotkey.lnk' }
function Test-JpAutoStart([string]$startupDir = [Environment]::GetFolderPath('Startup')) { Test-Path (Get-JpAutoStartLink $startupDir) }
function Set-JpAutoStart([bool]$on, [string]$installDir, [string]$startupDir = [Environment]::GetFolderPath('Startup')) {
    $link = Get-JpAutoStartLink $startupDir
    if (-not $on) { Remove-Item $link -ErrorAction SilentlyContinue; return }
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    $s.TargetPath = "$env:WINDIR\System32\wscript.exe"; $s.Arguments = "`"$installDir\hotkey.vbs`""
    $s.WorkingDirectory = $installDir; $s.Description = 'JpSnap: Ctrl+Alt+J listener'; $s.Save()
}

function Save-JpConfig([string]$file, $cfg) {
    # own temp file + move, so a crash never leaves a half-written config and two writers never share a temp file
    $tmp = "$file.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Move-Item -Force $tmp $file
}

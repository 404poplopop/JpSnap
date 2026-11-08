# Settings in config.json beside jpsnap.ps1. The OpenAI API key is stored DPAPI-encrypted for the current Windows
# user (openai_api_key_dpapi), and so is the HTTPS token (https_token_dpapi); plain openai_api_key / https_token values
# (older versions, or a token pasted into config.json) are encrypted and removed on first read.
Add-Type -AssemblyName System.Security

$JpDefaults = [ordered]@{ run_on = 'server'; server = ''; https_url = ''; https_token_dpapi = ''; fast = $true; model = 'gpt-6-luna'; fast_tier = $false; voice = 'nanami'; speed = 'normal'; openai_api_key_dpapi = '' }
# keep model in step with MODELS in jpsnap_core.py (the core refuses any other)
$JpModels = 'gpt-6-luna', 'gpt-6-sol', 'gpt-6.1-sol', 'gpt-6.1-terra', 'gpt-6-astra', 'gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol'
$JpChoices = @{ model = $JpModels; run_on = 'server', 'https', 'pc'; voice = 'nanami', 'keita'; speed = 'normal', 'slow' }

# user@host only: no spaces, no leading '-', so the value can never turn into an ssh option.
function Test-JpServer([string]$server) { $server -match '^[A-Za-z0-9_][A-Za-z0-9._-]{0,31}@[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z' }
function Test-JpApiKey([string]$key) { $key -cmatch '^(sk-[A-Za-z0-9_-]{8,200})?\z' }
# https://host[:port][/path]: no credentials, query or spaces; the token goes in a header, never in the URL
function Test-JpHttpsUrl([string]$url) {
    ($url -cmatch '^https://[A-Za-z0-9][A-Za-z0-9.-]{0,252}(:(?<port>[0-9]{1,5}))?(/[A-Za-z0-9._~/-]*)?\z') -and
        (-not $Matches.port -or [int]$Matches.port -in 1..65535)
}
function Test-JpToken([string]$token) { $token -cmatch '^([A-Za-z0-9_-]{32,128})?\z' }

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
        if ($name -in 'fast', 'fast_tier' -and $value -isnot [bool]) { continue }  # [bool]'false' would be $true
        $cfg[$name] = $value
    }
    if ($saved.openai_api_key -or $saved.https_token) {  # migrate plain-text secrets
        if ($saved.openai_api_key -and (Test-JpApiKey $saved.openai_api_key)) { $cfg.openai_api_key_dpapi = Protect-JpSecret $saved.openai_api_key }
        if ($saved.https_token -and (Test-JpToken $saved.https_token)) { $cfg.https_token_dpapi = Protect-JpSecret $saved.https_token }
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

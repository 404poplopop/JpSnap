# config.json handling without UI: wrong types and values fall back to defaults, a plain-text key and HTTPS token are
# encrypted and removed, and the server check refuses anything that could become an ssh option.
. "$PSScriptRoot\lib\config.ps1"
$f = "$env:TEMP\jpsnap_config_test.json"; $out = @()
[IO.File]::WriteAllText($f, '{"fast":"false","fast_tier":"true","model":"gpt-6-luna --oops","run_on":"evil","voice":"keita","server":"me@host","openai_api_key":"sk-plaintext1234567","https_token":"tok_plaintext_0123456789abcdefghijkl"}')
$c = Read-JpConfig $f; $raw = [IO.File]::ReadAllText($f)
$out += 'STRING_BOOL_IGNORED=' + $(if ($c.fast -eq $true) { 'PASS' } else { 'FAIL' })
$out += 'BAD_CHOICE_DEFAULTED=' + $(if ($c.run_on -eq 'server' -and $c.model -eq 'gpt-6-luna' -and $c.fast_tier -eq $false) { 'PASS' } else { 'FAIL' })
$out += 'GOOD_CHOICE_KEPT=' + $(if ($c.voice -eq 'keita') { 'PASS' } else { 'FAIL' })
$migrated = $raw -notmatch 'sk-plaintext' -and (Unprotect-JpSecret $c.openai_api_key_dpapi) -eq 'sk-plaintext1234567'
$out += 'PLAINTEXT_KEY_MIGRATED=' + $(if ($migrated) { 'PASS' } else { 'FAIL' })
$tokenMigrated = $raw -notmatch 'tok_plaintext' -and (Unprotect-JpSecret $c.https_token_dpapi) -eq 'tok_plaintext_0123456789abcdefghijkl'
$out += 'PLAINTEXT_TOKEN_MIGRATED=' + $(if ($tokenMigrated) { 'PASS' } else { 'FAIL' })
$urlOk = (Test-JpHttpsUrl 'https://example.com/jpsnap') -and (Test-JpHttpsUrl 'https://example.com:8443/') -and -not (Test-JpHttpsUrl 'http://example.com') -and
    -not (Test-JpHttpsUrl 'https://u:p@example.com') -and -not (Test-JpHttpsUrl 'https://example.com/?t=1') -and -not (Test-JpHttpsUrl 'https://example.com:65536/') -and -not (Test-JpHttpsUrl 'https://example.com:0/') -and -not (Test-JpHttpsUrl "https://example.com`n")
$tokenOk = (Test-JpToken '') -and (Test-JpToken ('a' * 43)) -and -not (Test-JpToken ('a' * 31)) -and -not (Test-JpToken (('a' * 40) + ' ')) -and -not (Test-JpToken (('a' * 40) + "`n"))
$out += 'HTTPS_CHECKS=' + $(if ($urlOk -and $tokenOk) { 'PASS' } else { 'FAIL' })
$serverOk = (Test-JpServer 'me@192.0.2.10') -and -not (Test-JpServer '-oProxyCommand=x@y') -and -not (Test-JpServer 'a b@c') -and -not (Test-JpServer 'me@-h') -and -not (Test-JpServer "me@host`n")
$out += 'SERVER_CHECK=' + $(if ($serverOk) { 'PASS' } else { 'FAIL' })
$keyOk = (Test-JpApiKey '') -and (Test-JpApiKey 'sk-abc_DEF-12345') -and -not (Test-JpApiKey 'sk-a b c d e f') -and -not (Test-JpApiKey "sk-abcdefgh`n")
$out += 'KEY_CHECK=' + $(if ($keyOk) { 'PASS' } else { 'FAIL' })
# two windows: this one changes speed while another already saved voice=nanami; both survive, no temp file left
$cfg = Read-JpConfig $f
$other = Read-JpConfig $f; $other.voice = 'nanami'; Save-JpConfig $f $other
[void](Update-JpConfig $f @{ speed = 'slow' })
$merged = [IO.File]::ReadAllText($f) | ConvertFrom-Json
$noTmp = -not (Get-ChildItem (Split-Path $f) -Filter "$(Split-Path -Leaf $f).*.tmp")
$out += 'MERGE_KEEPS_OTHER_WINDOW=' + $(if ($merged.voice -eq 'nanami' -and $merged.speed -eq 'slow' -and $merged.openai_api_key_dpapi -and $noTmp) { 'PASS' } else { 'FAIL' })
# start with Windows: the shortcut is made, points at hotkey.vbs, and is removed again (in a temp folder, not the real Startup)
$startup = Join-Path $env:TEMP 'jpsnap_startup_test'; [void](New-Item -ItemType Directory -Force $startup)
Set-JpAutoStart $true 'C:\JpSnapTest' $startup
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Get-JpAutoStartLink $startup))
$made = (Test-JpAutoStart $startup) -and $lnk.TargetPath -like '*\wscript.exe' -and $lnk.Arguments -eq '"C:\JpSnapTest\hotkey.vbs"'
Set-JpAutoStart $false 'C:\JpSnapTest' $startup
$out += 'AUTOSTART_ON_OFF=' + $(if ($made -and -not (Test-JpAutoStart $startup)) { 'PASS' } else { 'FAIL' })
Remove-Item $startup
Remove-Item $f
$out -join "`r`n"

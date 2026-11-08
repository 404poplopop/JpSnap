# config.json handling without UI: wrong types and values fall back to defaults, a plain-text key is encrypted and
# removed, and the server check refuses anything that could become an ssh option.
. "$PSScriptRoot\lib\config.ps1"
$f = "$env:TEMP\jpsnap_config_test.json"; $out = @()
[IO.File]::WriteAllText($f, '{"fast":"false","run_on":"evil","voice":"keita","server":"me@host","openai_api_key":"sk-plaintext1234567"}')
$c = Read-JpConfig $f; $raw = [IO.File]::ReadAllText($f)
$out += 'STRING_BOOL_IGNORED=' + $(if ($c.fast -eq $true) { 'PASS' } else { 'FAIL' })
$out += 'BAD_CHOICE_DEFAULTED=' + $(if ($c.run_on -eq 'server') { 'PASS' } else { 'FAIL' })
$out += 'GOOD_CHOICE_KEPT=' + $(if ($c.voice -eq 'keita') { 'PASS' } else { 'FAIL' })
$migrated = $raw -notmatch 'sk-plaintext' -and (Unprotect-JpSecret $c.openai_api_key_dpapi) -eq 'sk-plaintext1234567'
$out += 'PLAINTEXT_KEY_MIGRATED=' + $(if ($migrated) { 'PASS' } else { 'FAIL' })
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
Remove-Item $f
$out -join "`r`n"

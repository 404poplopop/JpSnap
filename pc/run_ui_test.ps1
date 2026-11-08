param([ValidateSet('server', 'https', 'pc')][string]$Mode = 'server', [switch]$Full, [string]$Model = 'gpt-6-luna', [switch]$FastTier)  # -Full = fast mode off
$d = "$env:LOCALAPPDATA\JpSnap"
$errs = $null; [void][Management.Automation.Language.Parser]::ParseFile("$d\jpsnap.ps1", [ref]$null, [ref]$errs); foreach ($f in Get-ChildItem "$d\lib" -Filter *.ps1) { $e2 = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e2); $errs += $e2 }
"PARSE_ERRORS=" + $errs.Count; $errs | ForEach-Object { $_.Extent.StartLineNumber.ToString() + ': ' + $_.Message }
$cfgBak = if (Test-Path "$d\config.json") { [IO.File]::ReadAllText("$d\config.json") } else { $null }
# the test app gets its own config copy (ui_test.ps1 points JPSNAP_CONFIG at it); the real one is never written
$testDir = "$env:TEMP\jpsnap_test"; Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue; [void](New-Item -ItemType Directory $testDir)
$c = $cfgBak | ConvertFrom-Json; $c.run_on = $Mode; $c | Add-Member -Force fast (-not $Full); $c | Add-Member -Force model $Model; $c | Add-Member -Force fast_tier ([bool]$FastTier); [IO.File]::WriteAllText("$testDir\config.json", ($c | ConvertTo-Json))
Remove-Item "$env:TEMP\jpsnap_ui.txt", "$env:TEMP\jpsnap_shot.png", "$env:TEMP\jpsnap_shot2.png" -ErrorAction SilentlyContinue
$act = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument "`"$d\ui_test.vbs`""
$pr = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
Register-ScheduledTask -TaskName JpSnapUI -Action $act -Principal $pr -Force | Out-Null
Start-ScheduledTask -TaskName JpSnapUI
for ($i = 0; $i -lt 120 -and -not (Test-Path "$env:TEMP\jpsnap_ui.txt"); $i++) { Start-Sleep 2 }
Unregister-ScheduledTask -TaskName JpSnapUI -Confirm:$false
"REAL_CONFIG_UNTOUCHED=" + ([IO.File]::ReadAllText("$d\config.json") -eq $cfgBak) + " MODE=$Mode FAST=$(-not $Full) MODEL=$Model FAST_TIER=$([bool]$FastTier)"
Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
Get-Content "$env:TEMP\jpsnap_ui.txt" -Encoding UTF8 -ErrorAction SilentlyContinue  # result stays in the user's TEMP (screenshots too)

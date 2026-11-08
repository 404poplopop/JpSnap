param([string]$Mode = 'server')
$d = "$env:LOCALAPPDATA\JpSnap"
$errs = $null; [void][Management.Automation.Language.Parser]::ParseFile("$d\jpsnap.ps1", [ref]$null, [ref]$errs); "PARSE_ERRORS=" + $errs.Count; $errs | ForEach-Object { $_.Extent.StartLineNumber.ToString() + ': ' + $_.Message }
$cfgBak = if (Test-Path "$d\config.json") { [IO.File]::ReadAllText("$d\config.json") } else { $null }
if ($Mode -eq 'pc') { $c = $cfgBak | ConvertFrom-Json; $c.run_on = 'pc'; [IO.File]::WriteAllText("$d\config.json", ($c | ConvertTo-Json)) }
Remove-Item "$env:TEMP\jpsnap_ui.txt", "$env:TEMP\jpsnap_shot.png", "$env:TEMP\jpsnap_shot2.png" -ErrorAction SilentlyContinue
$act = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument "`"$d\ui_test.vbs`""
$pr = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
Register-ScheduledTask -TaskName JpSnapUI -Action $act -Principal $pr -Force | Out-Null
Start-ScheduledTask -TaskName JpSnapUI
for ($i = 0; $i -lt 75 -and -not (Test-Path "$env:TEMP\jpsnap_ui.txt"); $i++) { Start-Sleep 2 }
Unregister-ScheduledTask -TaskName JpSnapUI -Confirm:$false
if ($Mode -eq 'pc') { if ($cfgBak) { [IO.File]::WriteAllText("$d\config.json", $cfgBak) } else { Remove-Item "$d\config.json" } }
"CONFIG_RUN_ON=" + ((Get-Content "$d\config.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).run_on)
Get-Content "$env:TEMP\jpsnap_ui.txt" -Encoding UTF8 -ErrorAction SilentlyContinue  # result stays in the user's TEMP (screenshots too)

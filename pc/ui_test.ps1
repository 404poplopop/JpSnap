# Session-1 UI check of jpsnap.ps1: real jpsnap.vbs, snip fed via clipboard, buttons driven by UIA Invoke.
# No mouse or keyboard input: the user works on this PC. Hover levels: hover_test.ps1; real hovering is checked by hand.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -Namespace JpTest -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][JpTest.M]::SetProcessDPIAware()
$d = "$env:LOCALAPPDATA\JpSnap"; $res = "$env:TEMP\jpsnap_ui.txt"; $log = @()
$AE = [Windows.Automation.AutomationElement]
function Find-JpEl($root, $id) { $root.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id))) }
function Find-JpText($root, $name) { $root.FindFirst('Descendants', (New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $name)), (New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::Text))))) }
function Invoke-JpEl($el) { $el.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Set-JpValue($el, [string]$v) { $el.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($v) }
function Get-JpTopWindow([string]$name) {  # an owned dialog is a child of its owner in UI Automation, not of the desktop
    $cond = New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $name)), (New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, [int]$appPid)))
    $found = $AE::RootElement.FindFirst('Children', $cond)
    if (-not $found -and $win) { $found = $win.FindFirst('Children', $cond) }
    $found
}
# The app under test uses the config copy run_ui_test.ps1 made and its own data dir, so the user's deck, history and
# settings are never touched, and only the JpSnap process this test starts is driven and closed.
$testDir = "$env:TEMP\jpsnap_test"
$env:JPSNAP_CONFIG = $cfgFile = "$testDir\config.json"; $env:JPSNAP_DATA = "$testDir\data"; $env:JPSNAP_DEBUG = "$env:TEMP\jpsnap_debug.log"
Remove-Item $env:JPSNAP_DEBUG -ErrorAction SilentlyContinue
$deck = "$testDir\data\deck.tsv"
function Get-JpAppPids { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'jpsnap\.ps1' } | ForEach-Object { $_.ProcessId }) }
$appPid = 0
$t0 = Get-Date
try {
    $bmp = New-Object Drawing.Bitmap 1100, 70
    $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::White)
    $g.DrawString('昨日、友達と駅の近くでラーメンを食べました。', (New-Object Drawing.Font('Yu Gothic', 30, [Drawing.GraphicsUnit]::Pixel)), [Drawing.Brushes]::Black, 8, 8); $g.Dispose()
    $pidsBefore = Get-JpAppPids
    Start-Process "$env:WINDIR\System32\wscript.exe" "`"$d\jpsnap.vbs`""
    for ($i = 0; $i -lt 40 -and -not $appPid; $i++) { Start-Sleep -Milliseconds 250; $appPid = @(Get-JpAppPids | Where-Object { $pidsBefore -notcontains $_ })[0] }
    $ov = $null
    for ($i = 0; $i -lt 30 -and -not $ov; $i++) { Start-Sleep -Milliseconds 500; $ov = Get-Process ScreenClippingHost, SnippingTool -ErrorAction SilentlyContinue }
    Start-Sleep 1
    [Windows.Forms.Clipboard]::SetImage($bmp)
    Get-Process ScreenClippingHost, SnippingTool -ErrorAction SilentlyContinue | Stop-Process -Force  # close the overlay we didn't drag
    $sw = [Diagnostics.Stopwatch]::StartNew(); $tr = ''; $win = $null
    for ($i = 0; $i -lt 60 -and $tr -notmatch 'ramen|fail'; $i++) {
        Start-Sleep 1
        $win = Get-JpTopWindow 'JpSnap'
        if ($win) { $t = Find-JpEl $win 'translation'; if ($t) { $tr = $t.Current.Name } }
    }
    $log += "TRANSLATION=" + $(if ($tr -match 'ramen') { "PASS ($([int]$sw.Elapsed.TotalSeconds) s)" } else { "FAIL '$tr'" })
    # details: the loading bar goes away and grammar notes ("• ...") appear (in fast mode they replace the quick result)
    $textCond = New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::Text)
    $notes = 0; $barGone = $false
    for ($i = 0; $i -lt 60 -and -not ($barGone -and $notes); $i++) {
        $bar = Find-JpEl $win 'busy'; $barGone = -not $bar -or $bar.Current.IsOffscreen
        $notes = @($win.FindAll('Descendants', $textCond) | Where-Object { $_.Current.Name.StartsWith('• ') }).Count
        if (-not ($barGone -and $notes)) { Start-Sleep 1 }
    }
    $log += "DETAILS=" + $(if ($barGone -and $notes) { "PASS ($([int]$sw.Elapsed.TotalSeconds) s, $notes notes)" } else { "FAIL (bar gone $barGone, notes $notes)" })
    $w0 = if ($win) { Find-JpText $win '昨日' }; $w2 = if ($win) { Find-JpText $win '友達' }
    $log += "WORDS=" + $(if ($w0 -and $w2) { 'PASS' } else { 'FAIL' })
    # sentence + every word (10 here) are fetched before any click
    $nmp3 = 0
    for ($i = 0; $i -lt 40 -and $nmp3 -lt 11; $i++) { Start-Sleep -Milliseconds 500; $nmp3 = @(Get-ChildItem $env:TEMP -Filter "jpsnap_tts_$($appPid)_*.mp3").Count }
    $log += "PREFETCH=" + $(if ($nmp3 -ge 11) { 'PASS' } else { 'FAIL' }) + " ($nmp3 clips)"
    $r = $win.Current.BoundingRectangle; $shot = New-Object Drawing.Bitmap ([int]$r.Width + 40), ([int]$r.Height + 200)
    $gg = [Drawing.Graphics]::FromImage($shot); $gg.CopyFromScreen([int]$r.X - 10, [int]$r.Y - 10, 0, 0, $shot.Size); $gg.Dispose(); $shot.Save("$env:TEMP\jpsnap_shot.png")
    # play -> karaoke strip must walk through several words
    $seq = @()
    $play = if ($win) { Find-JpEl $win 'play' }
    if ($play) { Invoke-JpEl $play; $playClock = [Diagnostics.Stopwatch]::StartNew(); $last = ''
        for ($i = 0; $i -lt 120; $i++) { Start-Sleep -Milliseconds 100; $nwd = Find-JpEl $win 'nowWord'
            if ($nwd -and -not $nwd.Current.IsOffscreen) { $n = $nwd.Current.Name; if ($n -and $last -ne $n) { $last = $n; $seq += "$n@$([int]$playClock.ElapsedMilliseconds)" } } else { $last = '' }
            if ($i -eq 25 -and $seq.Count -ge 2) { $gg = [Drawing.Graphics]::FromImage($shot); $gg.CopyFromScreen([int]$r.X - 10, [int]$r.Y - 10, 0, 0, $shot.Size); $gg.Dispose(); $shot.Save("$env:TEMP\jpsnap_shot2.png") } } }
    $log += "KARAOKE=" + $(if ($seq.Count -ge 3) { 'PASS' } else { 'FAIL' }) + " " + ($seq -join ' > ')
    # star -> all words saved to the deck
    $sv = if ($win) { Find-JpEl $win 'save' }
    if ($sv) { Invoke-JpEl $sv; Start-Sleep -Milliseconds 500 }
    $deckNow = if (Test-Path $deck) { [IO.File]::ReadAllText($deck) } else { '' }
    $log += "SAVE=" + $(if ($deckNow -match '友達') { 'PASS' } else { 'FAIL' })
    # settings: a bad server is refused, changes are saved, the API key is stored encrypted
    $cfgBefore = [IO.File]::ReadAllText($cfgFile)
    Invoke-JpEl (Find-JpEl $win 'settings')
    $sw2 = $null; for ($i = 0; $i -lt 20 -and -not $sw2; $i++) { Start-Sleep -Milliseconds 250; $sw2 = Get-JpTopWindow 'JpSnap settings' }
    if ($sw2) {
        $srv = Find-JpEl $sw2 'server'; $origServer = $srv.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
        Set-JpValue $srv '-oProxyCommand=calc.exe x@y'
        Invoke-JpEl (Find-JpEl $sw2 'saveSettings'); Start-Sleep -Milliseconds 500
        $errEl = Find-JpEl $sw2 'error'
        $refused = $errEl -and -not $errEl.Current.IsOffscreen -and [IO.File]::ReadAllText($cfgFile) -eq $cfgBefore
        $log += "SETTINGS_VALIDATE=" + $(if ($refused) { 'PASS' } else { 'FAIL' })
        Set-JpValue $srv $origServer
        $fastEl = Find-JpEl $sw2 'fast'; $fastBefore = $fastEl.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq 'On'
        $fastEl.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
        (Find-JpEl $sw2 'voiceKeita').GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        $keySet = $true; try { Set-JpValue (Find-JpEl $sw2 'apiKey') 'sk-uitest1234567890' } catch { $keySet = $false }
        Invoke-JpEl (Find-JpEl $sw2 'saveSettings')
        $closed = $false; for ($i = 0; $i -lt 20 -and -not $closed; $i++) { Start-Sleep -Milliseconds 250; $closed = -not (Get-JpTopWindow 'JpSnap settings') }
        $raw = [IO.File]::ReadAllText($cfgFile); $c = $raw | ConvertFrom-Json
        $log += "SETTINGS_SAVE=" + $(if ($closed -and $c.voice -eq 'keita' -and [bool]$c.fast -ne $fastBefore -and $c.server -eq $origServer) { 'PASS' } else { "FAIL (closed $closed, $raw)" })
        $log += "KEY_ENCRYPTED=" + $(if (-not $keySet) { 'SKIP (no UIA value on the password box)' } elseif ($c.openai_api_key_dpapi -and $raw -notmatch 'sk-uitest') { 'PASS' } else { 'FAIL' })
    } else { $log += 'SETTINGS_VALIDATE=FAIL (no settings window)' }
    $cl = if ($win) { Find-JpEl $win 'close' }
    if ($cl) { Invoke-JpEl $cl }
    $gone = $false
    for ($i = 0; $i -lt 15 -and -not $gone; $i++) { Start-Sleep -Milliseconds 300; $gone = -not (Get-Process -Id $appPid -ErrorAction SilentlyContinue) }
    $log += "CLOSE=" + $(if ($gone) { 'PASS' } else { 'FAIL' })
    $log += "MP3_CLEANED=" + (-not (Get-ChildItem $env:TEMP -Filter "jpsnap_tts_$($appPid)_*.mp3"))
} catch { $log += "ERROR $_ line $($_.InvocationInfo.ScriptLineNumber)" }
finally {
    if ($appPid) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue }  # only the app this test started
    $log -join "`r`n" | Out-File -Encoding utf8 $res
}

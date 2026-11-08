# Session-1 UI check of jpsnap.ps1: real jpsnap.vbs, snip fed via clipboard, buttons driven by UIA Invoke.
# No mouse or keyboard input: the user works on this PC. Hover tooltips and right-click save are checked by hand.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -Namespace JpTest -Name M -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][JpTest.M]::SetProcessDPIAware()
$d = "$env:LOCALAPPDATA\JpSnap"; $res = "$env:TEMP\jpsnap_ui.txt"; $log = @()
$AE = [Windows.Automation.AutomationElement]
function Find-JpEl($root, $id) { $root.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id))) }
function Find-JpText($root, $name) { $root.FindFirst('Descendants', (New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $name)), (New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::Text))))) }
function Invoke-JpEl($el) { $el.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
$deck = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'JpSnap\deck.tsv'
$deckBefore = if (Test-Path $deck) { [IO.File]::ReadAllBytes($deck) } else { $null }
$histFile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'JpSnap\history.jsonl'
$histBefore = if (Test-Path $histFile) { [IO.File]::ReadAllBytes($histFile) } else { $null }
$t0 = Get-Date
try {
    $bmp = New-Object Drawing.Bitmap 1100, 70
    $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::White)
    $g.DrawString('昨日、友達と駅の近くでラーメンを食べました。', (New-Object Drawing.Font('Yu Gothic', 30, [Drawing.GraphicsUnit]::Pixel)), [Drawing.Brushes]::Black, 8, 8); $g.Dispose()
    Start-Process "$env:WINDIR\System32\wscript.exe" "`"$d\jpsnap.vbs`""
    $ov = $null
    for ($i = 0; $i -lt 30 -and -not $ov; $i++) { Start-Sleep -Milliseconds 500; $ov = Get-Process ScreenClippingHost, SnippingTool -ErrorAction SilentlyContinue }
    Start-Sleep 1
    [Windows.Forms.Clipboard]::SetImage($bmp)
    Get-Process ScreenClippingHost, SnippingTool -ErrorAction SilentlyContinue | Stop-Process -Force  # close the overlay we didn't drag
    $sw = [Diagnostics.Stopwatch]::StartNew(); $tr = ''; $win = $null
    for ($i = 0; $i -lt 60 -and $tr -notmatch 'ramen|fail'; $i++) {
        Start-Sleep 1
        $win = $AE::RootElement.FindFirst('Children', (New-Object Windows.Automation.PropertyCondition($AE::NameProperty, 'JpSnap')))
        if ($win) { $t = Find-JpEl $win 'translation'; if ($t) { $tr = $t.Current.Name } }
    }
    $log += "TRANSLATION=" + $(if ($tr -match 'ramen') { "PASS ($([int]$sw.Elapsed.TotalSeconds) s)" } else { "FAIL '$tr'" })
    $w0 = if ($win) { Find-JpText $win '昨日' }; $w2 = if ($win) { Find-JpText $win '友達' }
    $log += "WORDS=" + $(if ($w0 -and $w2) { 'PASS' } else { 'FAIL' })
    $r = $win.Current.BoundingRectangle; $shot = New-Object Drawing.Bitmap ([int]$r.Width + 40), ([int]$r.Height + 200)
    $gg = [Drawing.Graphics]::FromImage($shot); $gg.CopyFromScreen([int]$r.X - 10, [int]$r.Y - 10, 0, 0, $shot.Size); $gg.Dispose(); $shot.Save("$env:TEMP\jpsnap_shot.png")
    # play -> karaoke strip must walk through several words
    $seq = @()
    $play = if ($win) { Find-JpEl $win 'play' }
    if ($play) { Invoke-JpEl $play
        for ($i = 0; $i -lt 120; $i++) { Start-Sleep -Milliseconds 100; $nwd = Find-JpEl $win 'nowWord'
            if ($nwd -and -not $nwd.Current.IsOffscreen) { $n = $nwd.Current.Name; if ($n -and $seq[-1] -ne $n) { $seq += $n } }
            if ($i -eq 25 -and $seq.Count -ge 2) { $gg = [Drawing.Graphics]::FromImage($shot); $gg.CopyFromScreen([int]$r.X - 10, [int]$r.Y - 10, 0, 0, $shot.Size); $gg.Dispose(); $shot.Save("$env:TEMP\jpsnap_shot2.png") } } }
    $log += "KARAOKE=" + $(if ($seq.Count -ge 3) { 'PASS' } else { 'FAIL' }) + " " + ($seq -join ' > ')
    # star -> all words saved to the deck
    $sv = if ($win) { Find-JpEl $win 'save' }
    if ($sv) { Invoke-JpEl $sv; Start-Sleep -Milliseconds 500 }
    $deckNow = if (Test-Path $deck) { [IO.File]::ReadAllText($deck) } else { '' }
    $log += "SAVE=" + $(if ($deckNow -match '友達') { 'PASS' } else { 'FAIL' })
    $cl = if ($win) { Find-JpEl $win 'close' }
    if ($cl) { Invoke-JpEl $cl }
    $gone = $false
    for ($i = 0; $i -lt 15 -and -not $gone; $i++) { Start-Sleep -Milliseconds 300; $gone = -not (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'jpsnap.ps1' }) }
    $log += "CLOSE=" + $(if ($gone) { 'PASS' } else { 'FAIL' })
    $log += "MP3_CLEANED=" + (-not (Get-ChildItem $env:TEMP -Filter 'jpsnap_tts_*.mp3' | Where-Object { $_.LastWriteTime -gt $t0 }))
} catch { $log += "ERROR $_ line $($_.InvocationInfo.ScriptLineNumber)" }
finally {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'jpsnap.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    if ($deckBefore) { [IO.File]::WriteAllBytes($deck, $deckBefore) } else { Remove-Item $deck -ErrorAction SilentlyContinue }
    if ($histBefore) { [IO.File]::WriteAllBytes($histFile, $histBefore) } else { Remove-Item $histFile -ErrorAction SilentlyContinue }
    $log -join "`r`n" | Out-File -Encoding utf8 $res
}

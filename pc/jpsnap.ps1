# JpSnap: snip a screen region, break its Japanese down with codex (on the server or this PC), read it aloud.
# lib\*.ps1 hold the functions (config, backend, render, speech, deck, settings); ui\*.xaml the windows.
param([string]$TestImage)  # test hook: send this PNG and print the JSON reply, no UI
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type -Namespace JpSnap -Name Win -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
'@
# Started hidden by jpsnap.vbs: the first ShowWindow call takes that hidden flag, so spend it on the console, not the window.
[void][JpSnap.Win]::ShowWindow([JpSnap.Win]::GetConsoleWindow(), 0)

$dir = $PSScriptRoot
foreach ($lib in 'config', 'backend', 'render', 'speech', 'deck', 'settings') { . "$dir\lib\$lib.ps1" }
$utf8 = New-Object Text.UTF8Encoding($false)
$cfgFile = if ($env:JPSNAP_CONFIG) { $env:JPSNAP_CONFIG } else { Join-Path $dir 'config.json' }  # the UI test uses its own copy
$cfg = Read-JpConfig $cfgFile
$dataDir = if ($env:JPSNAP_DATA) { $env:JPSNAP_DATA } else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'JpSnap' }

# Audio left behind by a killed run (a normal close deletes its own).
Get-ChildItem $env:TEMP -Filter 'jpsnap_tts_*.mp3' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } | Remove-Item -ErrorAction SilentlyContinue

if ($TestImage) { [Console]::OutputEncoding = $utf8; (Read-JpCore (Start-JpTranslate ([IO.File]::ReadAllBytes($TestImage)) $false)).Text; exit }

Set-JpPopupsRight
# First run (or a broken server entry): settings before the snip.
if ($cfg.run_on -eq 'server' -and -not (Test-JpServer $cfg.server)) { if (-not (Show-JpSettings $null)) { exit } }

# ---------- snip: the native overlay (same as Win+Shift+S) puts the selection on the clipboard ----------
[Windows.Forms.Clipboard]::Clear()
Start-Process 'ms-screenclip:'
$img = $null
for ($i = 0; $i -lt 600 -and -not $img; $i++) { Start-Sleep -Milliseconds 100; $img = [Windows.Forms.Clipboard]::GetImage() }
if (-not $img) { exit }  # cancelled, or no selection within 60 s
$shot = New-Object IO.MemoryStream
$img.Save($shot, [Drawing.Imaging.ImageFormat]::Png)

# ---------- overlay ----------
$win = Read-JpXaml "$dir\ui\overlay.xaml"
$ui = Get-JpNamed $win @('root', 'close', 'settings', 'save', 'speed', 'play', 'fast', 'status', 'busy', 'words', 'now',
    'nowWord', 'nowPitch', 'nowRomaji', 'nowMeaning', 'translation', 'grammar', 'legend', 'hint')
$ui.hint.Visibility = 'Collapsed'
$player = New-Object Windows.Media.MediaPlayer

# All state in one hashtable, so event handlers can change it without scope prefixes.
$st = @{
    data = $null; full = $false; busy = $true; jobs = @()
    blocks = @(); starts = @(); wordOf = @(); partOf = @(); phrases = @(); phraseOf = @()
    hover = -1; tipFor = -1; tipMode = 'token'; hoverRange = @(); tip = $null
    curFirst = -1; curLast = -1; curPhrase = -1; shownAt = 0; marks = $null
    rate = $cfg.speed; audio = @{}; files = @()
    moved = $false; anchor = $null; area = $null; started = Get-Date
}

function Sync-JpHeader {
    $ui.fast.IsChecked = [bool]$cfg.fast
    $ui.speed.IsChecked = $st.rate -eq 'slow'
    $ui.speed.Content = if ($st.rate -eq 'slow') { '0.7×' } else { '1×' }
}
function Set-JpBusy([bool]$on, [string]$text = '') {
    $st.busy = $on; $ui.busy.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }; $ui.status.Text = $text
}

# Fast mode starts a quick and a full lookup together: the quick one is drawn first, the full one replaces it.
function Start-JpLookup {
    $png = $shot.ToArray()
    if ($cfg.fast) { Add-JpJob (Start-JpTranslate $png $true) { param($r) Complete-JpLookup $r $true } }
    Add-JpJob (Start-JpTranslate $png $false) { param($r) Complete-JpLookup $r $false }
}
function Complete-JpLookup($r, [bool]$quick) {
    if ($quick -and $st.full) { return }  # the full answer came first
    if (-not $r.Ok) {
        if ($quick) { return }  # the full lookup is still running and reports its own errors
        if ($st.data) { Set-JpBusy $false 'Details failed (quick result shown)'; return }
        Set-JpBusy $false 'Translation failed'; $ui.translation.Text = $r.Text
        if ($cfg.run_on -eq 'pc' -and $r.Text -match '401') {
            $ui.translation.Text = "This PC has no OpenAI login: add an API key in settings, or run 'codex login' once.`r`n`r`n$($r.Text)"
        }
        return
    }
    try { $d = $r.Text | ConvertFrom-Json } catch { Set-JpBusy $false 'Bad reply'; $ui.translation.Text = $r.Text; return }
    if (-not $quick) { $st.full = $true; Add-JpHistory $r.Text }
    Write-JpDebug "lookup quick=$quick sentence='$($d.sentence)'"
    if ($quick) { Set-JpBusy $true 'Loading details…' } else { Set-JpBusy $false }
    Show-JpResult $d
    if (@($d.tokens).Count) { Start-JpPrefetch }
}

# ---------- events ----------
$timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(40)
$timer.Add_Tick({ Update-JpHover; Complete-JpJobs; Update-JpKaraoke })
$player.Add_MediaEnded({ $st.marks = $null; $st.curPhrase = -1; Show-JpNow -1 })

$ui.play.Add_Click({ Write-JpDebug 'play click'; Start-JpSpeech $st.data.sentence $true })
$ui.speed.Add_Click({ Set-JpSpeed $(if ($st.rate -eq 'slow') { 'normal' } else { 'slow' }) })
$ui.fast.Add_Click({
    $cfg.fast = [bool]$ui.fast.IsChecked; Save-JpConfig $cfgFile $cfg
    $ui.status.Text = if ($cfg.fast) { 'Fast mode on (next snip)' } else { 'Fast mode off (next snip)' }
})
$ui.settings.Add_Click({
    if (-not (Show-JpSettings $win)) { return }
    $st.rate = $cfg.speed; Sync-JpHeader
    if ($st.data -and @($st.data.tokens).Count) { Start-JpPrefetch }  # voice or speed may have changed
})
$ui.save.Add_Click({ Save-JpWords $st.data.tokens })
$ui.close.Add_Click({ $win.Close() })
# A lone Alt press (used for whole-word hover) would put the window into menu mode and eat the next key.
$win.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'System' -and $e.SystemKey -in 'LeftAlt', 'RightAlt') { $e.Handled = $true } })
$win.Add_PreviewKeyUp({ param($s, $e) if ($e.Key -eq 'System' -and $e.SystemKey -in 'LeftAlt', 'RightAlt') { $e.Handled = $true } })
$win.Add_KeyDown({ param($s, $e)
    if ($e.Key -eq 'Escape') { $win.Close() }
    elseif ($e.Key -eq 'Space' -and $ui.play.IsEnabled) { Start-JpSpeech $st.data.sentence $true }
})
$ui.root.Add_MouseLeftButtonDown({ $st.moved = $true; Set-JpHover -1 'token'; $win.DragMove() })

# Open next to where the selection ended (the cursor), in DIPs, and stay inside that screen's work area as it grows.
$win.Add_Loaded({
    $px = [Windows.Forms.Cursor]::Position
    $toDip = [Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformFromDevice
    $st.anchor = $toDip.Transform((New-Object Windows.Point($px.X, $px.Y)))
    $wa = [Windows.Forms.Screen]::FromPoint($px).WorkingArea
    $st.area = New-Object Windows.Rect($toDip.Transform((New-Object Windows.Point($wa.Left, $wa.Top))), $toDip.Transform((New-Object Windows.Point($wa.Right, $wa.Bottom))))
    $win.Left = $st.anchor.X; $win.Top = $st.anchor.Y
    $win.Activate()
    Sync-JpHeader
    Start-JpLookup
    $timer.Start()
})
$win.Add_SizeChanged({
    if ($st.moved -or -not $st.area) { return }
    $w = $win.ActualWidth; $h = $win.ActualHeight
    $win.Left = [Math]::Max($st.area.Left, [Math]::Min($st.anchor.X, $st.area.Right - $w))
    $win.Top = if ($st.anchor.Y + $h -gt $st.area.Bottom) { [Math]::Max($st.area.Top, $st.anchor.Y - $h) } else { $st.anchor.Y }
})
$win.Add_Closed({ $timer.Stop(); $player.Close(); Stop-JpJobs; if ($st.tip) { $st.tip.IsOpen = $false } })
[void]$win.ShowDialog()

# MediaPlayer releases its file lock asynchronously: keep pumping messages until the cached audio can be deleted.
for ($i = 0; $i -lt 30 -and @($st.files | Where-Object { Test-Path $_ }).Count; $i++) {
    [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
    $st.files | Remove-Item -ErrorAction SilentlyContinue
}

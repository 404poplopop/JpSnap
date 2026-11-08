# JpSnap: snip a screen region, break its Japanese down with codex (server or this PC), read it aloud.
param([string]$TestImage)  # test hook: send this PNG and print the server's JSON, no UI
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
# Started hidden by jpsnap.vbs: the first ShowWindow call takes that hidden flag, so spend it on the console, not the window.
Add-Type -Namespace JpSnap -Name Win -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
[void][JpSnap.Win]::ShowWindow([JpSnap.Win]::GetConsoleWindow(), 0)
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
# config.json: run_on "server" (ssh to the server) or "pc" (everything on this PC), optional OpenAI API key.
$cfgFile = Join-Path $dir 'config.json'
if (-not (Test-Path $cfgFile)) {
    [IO.File]::WriteAllText($cfgFile, (@'
{
  "run_on": "server",
  "server": "",
  "openai_api_key": "",
  "help": "run_on: server = translate and speak on the server over ssh; pc = everything on this PC (needs the Codex app login or openai_api_key). openai_api_key (optional, sk-...): pay per use with your own key instead of the Codex subscription. server: user@host of the machine running server/jp-translate; its host key goes in known_hosts under the name jpsnap-server."
}
'@), (New-Object Text.UTF8Encoding($false)))
}
$cfg = [IO.File]::ReadAllText($cfgFile) | ConvertFrom-Json
$server = [string]$cfg.server
$runOnPc = $cfg.run_on -eq 'pc'
if (-not $runOnPc -and -not $server) { Start-Process notepad.exe "`"$cfgFile`""; exit }  # first run: set the server first
$apiKey = [string]$cfg.openai_api_key
$data = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'JpSnap'  # history.jsonl + deck.tsv (Anki import)
$utf8 = New-Object Text.UTF8Encoding($false)

# Runs jpsnap_core.py (translate | tts) on the server over ssh, or locally when run_on is "pc".
# stdin is ASCII (key line + base64), stdout ASCII JSON, so no console code page touches them.
function Start-JpSsh([string]$cmd, [byte[]]$bytes) {
    if ($runOnPc) {
        $psi = New-Object Diagnostics.ProcessStartInfo "$dir\venv\Scripts\pythonw.exe"
        $psi.Arguments = "-I `"$dir\core\jpsnap_core.py`" $(if ($cmd) { $cmd } else { 'translate' })"
        $psi.EnvironmentVariables['JPSNAP_CODEX'] = (Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\bin" -Recurse -Filter codex.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    } else {
        $psi = New-Object Diagnostics.ProcessStartInfo "$env:WINDIR\System32\OpenSSH\ssh.exe"
        $psi.Arguments = "-T -i `"$dir\jpsnap_key`" -o UserKnownHostsFile=`"$dir\known_hosts`" -o HostKeyAlias=jpsnap-server -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15 $server $cmd"
    }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $p = [Diagnostics.Process]::Start($psi)
    $job = @{ P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
    if (-not $cmd) { $p.StandardInput.Write("$apiKey`n") }  # translate: line 1 = optional API key
    $p.StandardInput.Write([Convert]::ToBase64String($bytes)); $p.StandardInput.Close()
    return $job
}
function Read-JpSsh($job) {  # -> @{ Ok; Text }
    $job.P.WaitForExit()
    $ok = $job.P.ExitCode -eq 0
    return @{ Ok = $ok; Text = $(if ($ok) { $job.Out.Result } else { "Failed (exit $($job.P.ExitCode)): $($job.Err.Result)$($job.Out.Result)".Trim() }) }
}

# Audio left behind by a killed run (normal closes delete their own).
Get-ChildItem $env:TEMP -Filter 'jpsnap_tts_*.mp3' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } | Remove-Item -ErrorAction SilentlyContinue

if ($TestImage) { [Console]::OutputEncoding = $utf8; (Read-JpSsh (Start-JpSsh '' ([IO.File]::ReadAllBytes($TestImage)))).Text; exit }

# Native snip overlay (same as Win+Shift+S); the selection lands on the clipboard.
[Windows.Forms.Clipboard]::Clear()
Start-Process 'ms-screenclip:'
$img = $null
for ($i = 0; $i -lt 600 -and -not $img; $i++) { Start-Sleep -Milliseconds 100; $img = [Windows.Forms.Clipboard]::GetImage() }
if (-not $img) { exit }  # cancelled or 60 s timeout
$ms = New-Object IO.MemoryStream
$img.Save($ms, [Drawing.Imaging.ImageFormat]::Png)

$win = [Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="JpSnap" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" MaxWidth="580" FontFamily="Yu Gothic UI" Foreground="#F0F0F0">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#F0F0F0"/><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="MinWidth" Value="28"/><Setter Property="Height" Value="26"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Focusable" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="Transparent" CornerRadius="5" Padding="6,0"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#33FFFFFF"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="root" CornerRadius="10" Background="#E61C1C1E" BorderBrush="#40FFFFFF" BorderThickness="1" Padding="12,6,8,10">
    <StackPanel MinWidth="240" MaxWidth="556">
      <DockPanel>
        <Button x:Name="close" DockPanel.Dock="Right" Content="&#xE711;" ToolTip="Close (Esc)"/>
        <Button x:Name="settings" DockPanel.Dock="Right" Content="&#xE713;" ToolTip="Settings (config.json: server or PC, optional API key)"/>
        <Button x:Name="save" DockPanel.Dock="Right" Content="&#xE734;" ToolTip="Save the words to your deck (Documents\JpSnap\deck.tsv)" IsEnabled="False"/>
        <Button x:Name="speed" DockPanel.Dock="Right" Content="Slow" FontFamily="Yu Gothic UI" FontSize="12" Opacity="0.5" ToolTip="Toggle slow speech"/>
        <Button x:Name="play" DockPanel.Dock="Right" Content="&#xE768;" ToolTip="Read the sentence aloud" IsEnabled="False"/>
        <TextBlock x:Name="status" Text="Translating..." Opacity="0.6" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
      <WrapPanel x:Name="words" Margin="0,4,0,0"/>
      <Border x:Name="now" Visibility="Collapsed" Margin="0,6,0,0" Padding="10,4" CornerRadius="6" Background="#333D8BFD">
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="nowWord" FontSize="30" VerticalAlignment="Center"/>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="nowPitch"/>
              <TextBlock x:Name="nowRomaji" FontSize="15" Opacity="0.75" Margin="10,0,0,1" VerticalAlignment="Bottom"/>
            </StackPanel>
            <TextBlock x:Name="nowMeaning" FontSize="13" Opacity="0.75"/>
          </StackPanel>
        </StackPanel>
      </Border>
      <TextBlock x:Name="translation" TextWrapping="Wrap" FontSize="15" Margin="0,8,0,0"/>
      <StackPanel x:Name="grammar" Margin="0,6,0,0"/>
      <WrapPanel x:Name="legend" Margin="0,6,0,0" Opacity="0.75"/>
    </StackPanel>
  </Border>
</Window>
'@)
# Windows' "right-handed" menu setting opens WPF popups to the left of the cursor, pushing them off the overlay.
$dropField = [Windows.SystemParameters].GetField('_menuDropAlignment', [Reflection.BindingFlags]'NonPublic, Static')
if ([Windows.SystemParameters]::MenuDropAlignment -and $dropField) { $dropField.SetValue($null, $false) }
$ui = @{}
foreach ($n in 'root', 'close', 'settings', 'save', 'speed', 'play', 'status', 'words', 'now', 'nowWord', 'nowPitch', 'nowRomaji', 'nowMeaning', 'translation', 'grammar', 'legend') {
    $ui[$n] = $win.FindName($n); [Windows.Automation.AutomationProperties]::SetAutomationId($ui[$n], $n)
}
$posColor = @{ noun = '#4FC3F7'; pronoun = '#81D4FA'; verb = '#FF8A65'; adjective = '#CE93D8'; adverb = '#AED581'; particle = '#FFD54F'
    auxiliary = '#F06292'; conjunction = '#B0BEC5'; interjection = '#B0BEC5'; counter = '#4DB6AC'; prefix = '#BCAAA4'; suffix = '#BCAAA4'; other = '#B0BEC5' }
$bc = New-Object Windows.Media.BrushConverter
function New-JpBrush([string]$hex) { $bc.ConvertFromString($hex) }
function New-JpText([string]$text, [double]$size, [double]$opacity = 1) {
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.FontSize = $size; $t.Opacity = $opacity; $t.TextWrapping = 'Wrap'; $t
}
$hoverBrush = New-JpBrush '#22FFFFFF'; $curBrush = New-JpBrush '#663D8BFD'; $clear = [Windows.Media.Brushes]::Transparent

# State lives in one hashtable so event handlers can change it without scope prefixes.
$st = @{ data = $null; blocks = @(); starts = @(); phraseOf = @(); phrases = @(); curFirst = -1; curLast = -1; curPhrase = -1; shownAt = 0; rate = 'normal'; audio = @{}; files = @(); jobs = @(); marks = $null; moved = $false }
$player = New-Object Windows.Media.MediaPlayer

# Pitch accent row: one cell per mora, line on top = high, line at the bottom = low, a vertical step where it changes.
function New-JpPitch($t, [double]$size) {
    $row = New-Object Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Center'
    $mor = @($t.morae); $p = [string]$t.pitch
    $pen = New-JpBrush $(if ($t.pitch_src -eq 'dict') { '#E6FFFFFF' } else { '#66FFFFFF' })  # faint = AI estimate
    $w = [Math]::Max(1.2, $size / 9)
    for ($i = 0; $i -lt $mor.Count; $i++) {
        $c = New-Object Windows.Controls.Border; $c.BorderBrush = $pen; $c.Padding = '0,1,0,1'
        if ($p.Length -eq $mor.Count) {
            $hi = $p[$i] -eq 'H'
            $step = if ($i -gt 0 -and $p[$i] -ne $p[$i - 1]) { $w } else { 0 }
            $c.BorderThickness = New-Object Windows.Thickness($step, $(if ($hi) { $w } else { 0 }), 0, $(if ($hi) { 0 } else { $w }))
        }
        $x = New-JpText $mor[$i] $size 0.85; $x.TextWrapping = 'NoWrap'; $c.Child = $x
        $row.Children.Add($c) | Out-Null
    }
    if (-not $mor.Count) { $row.Children.Add((New-JpText ' ' $size)) | Out-Null }
    $row
}
function Test-JpCur([int]$k) { $k -ge $st.curFirst -and $k -le $st.curLast }
# Highlight tokens first..last and show them in the "now" strip; -1 hides it.
function Show-JpNow([int]$first, [int]$last = $first) {
    for ($k = [Math]::Max(0, $st.curFirst); $k -le $st.curLast -and $k -lt $st.blocks.Count; $k++) { $st.blocks[$k].Background = $clear }
    $st.curFirst = $first; $st.curLast = $last; $st.shownAt = [Environment]::TickCount
    if ($first -lt 0) { $ui.now.Visibility = 'Collapsed'; return }
    $toks = @($st.data.tokens[$first..$last])
    for ($k = $first; $k -le $last; $k++) { $st.blocks[$k].Background = $curBrush }
    $pitch = New-Object Windows.Controls.StackPanel; $pitch.Orientation = 'Horizontal'
    foreach ($t in $toks) { if ($t.pos -ne 'punctuation') { $pitch.Children.Add((New-JpPitch $t 16)) | Out-Null } }
    $ui.nowWord.Text = -join ($toks | ForEach-Object { $_.surface })
    $ui.nowPitch.Child = $pitch
    $ui.nowRomaji.Text = ($toks | Where-Object { $_.romaji } | ForEach-Object { $_.romaji }) -join ' '
    $ui.nowMeaning.Text = ($toks | Where-Object { $_.meaning } | ForEach-Object { $_.meaning }) -join '  ·  '
    $ui.now.Visibility = 'Visible'
}
function Get-JpTokenAt([int]$charIndex) {
    $k = 0; while ($k + 1 -lt $st.starts.Count -and $st.starts[$k + 1] -le $charIndex) { $k++ }; $k
}
function Start-JpClip($clip, [bool]$sentence, [int]$only) {
    $player.Stop(); $player.Open([uri]$clip.file); $player.Play()
    $st.marks = if ($sentence) { $clip.marks } else { $null }
    $st.curPhrase = -1
    Show-JpNow $only
}
# Speak text: a sentence highlights each word as it is spoken; a single word ($only) is shown in the "now" strip.
# $play = $false only fetches the audio into the cache (kept until the window closes).
function Start-JpSpeech([string]$text, [bool]$sentence, [int]$only = -1, [bool]$play = $true) {
    $key = "$($st.rate)|$text"
    if ($st.audio.ContainsKey($key)) { if ($play) { Start-JpClip $st.audio[$key] $sentence $only }; return }
    $pending = @($st.jobs | Where-Object { $_.key -eq $key })
    if ($pending) { if ($play) { $pending[0].play = $true; $pending[0].sentence = $sentence; $pending[0].only = $only; $ui.status.Text = 'Loading voice...' }; return }
    if ($play) { $ui.status.Text = 'Loading voice...' }
    $req = @{ text = $text; rate = $st.rate } | ConvertTo-Json -Compress
    $st.jobs += @{ job = (Start-JpSsh 'tts' $utf8.GetBytes($req)); key = $key; sentence = $sentence; only = $only; play = $play; done = {
        param($r, $ctx)
        if (-not $r.Ok) { if ($ctx.play) { $ui.status.Text = $r.Text }; return }
        $j = $r.Text | ConvertFrom-Json
        $file = Join-Path $env:TEMP ("jpsnap_tts_{0}_{1}.mp3" -f $PID, $st.files.Count)
        [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($j.audio)); $st.files += $file
        $pos = 0; $marks = @()
        foreach ($m in $j.marks) {  # map each spoken word to the token it starts in
            $i = $st.data.sentence.IndexOf([string]$m.text, $pos)
            if ($i -ge 0) { $pos = $i + ([string]$m.text).Length; $marks += @{ t = [double]$m.t; tok = (Get-JpTokenAt $i) } }
        }
        $clip = @{ file = $file; marks = $marks }; $st.audio[$ctx.key] = $clip
        if ($ctx.play) { $ui.status.Text = $st.hint; Start-JpClip $clip $ctx.sentence $ctx.only }
    } }
}
function Save-JpWords($tokens) {
    [void](New-Item -ItemType Directory -Force $data)
    $deck = Join-Path $data 'deck.tsv'
    $enc = { param($s) [Net.WebUtility]::HtmlEncode((([string]$s) -replace '\s+', ' ')) }  # model text is untrusted: no HTML, tabs or newlines in Anki fields
    $have = if (Test-Path $deck) { [IO.File]::ReadAllLines($deck, $utf8) | ForEach-Object { ($_ -split "`t")[0] } } else { @() }
    $new = @(foreach ($t in $tokens) {
        if ($t.pos -in 'particle', 'punctuation', 'auxiliary' -and $tokens.Count -gt 1) { continue }
        if ($have -contains (& $enc $t.surface)) { continue }
        "$(& $enc $t.surface)`t$(& $enc $t.reading) ($(& $enc $t.romaji))<br>$(& $enc $t.meaning)<br><small>$(& $enc $t.pos) · $(& $enc $t.explanation)</small><br><i>$(& $enc $st.data.sentence)</i>"
    })
    if ($new) { [IO.File]::AppendAllText($deck, ($new -join "`n") + "`n", $utf8) }
    $ui.status.Text = "Saved $($new.Count) new word(s) to deck.tsv"
}

function Show-JpResult($r) {
    if (-not $r.Ok) {
        $ui.status.Text = 'Translation failed'; $ui.translation.Text = $r.Text
        if ($runOnPc -and -not $apiKey -and $r.Text -match '401') { $ui.translation.Text = "PC mode has no OpenAI login: put your key in openai_api_key (settings button), or run 'codex login' on this PC once.`r`n`r`n" + $r.Text }
        return
    }
    try { $d = $r.Text | ConvertFrom-Json } catch { $ui.status.Text = 'Bad reply'; $ui.translation.Text = $r.Text; return }
    $st.data = $d
    [void](New-Item -ItemType Directory -Force $data)
    [IO.File]::AppendAllText((Join-Path $data 'history.jsonl'), ('{"time":"' + (Get-Date -Format s) + '","result":' + ($r.Text -replace '\r?\n', '') + "}`n"), $utf8)
    $ui.translation.Text = $d.translation
    foreach ($g in $d.grammar) { $ui.grammar.Children.Add((New-JpText "• $g" 12.5 0.8)) | Out-Null }
    $pos = 0; $starts = @(); $blocks = @(); $seen = @()
    for ($k = 0; $k -lt $d.tokens.Count; $k++) {
        $t = $d.tokens[$k]; $starts += $pos; $pos += $t.surface.Length
        $color = New-JpBrush $(if ($posColor.ContainsKey($t.pos)) { $posColor[$t.pos] } else { '#B0BEC5' })
        $b = New-Object Windows.Controls.Border; $b.CornerRadius = 4; $b.Padding = '2,0,2,1'; $b.Background = $clear; $b.Tag = $k
        [Windows.Automation.AutomationProperties]::SetAutomationId($b, "w$k")
        $sp = New-Object Windows.Controls.StackPanel
        $furi = New-JpPitch $t 11
        $surf = New-JpText $t.surface 24; $roma = New-JpText $(if ($t.romaji) { $t.romaji } else { ' ' }) 10 0.55
        $roma.HorizontalAlignment = 'Center'; $roma.TextWrapping = 'NoWrap'; $surf.HorizontalAlignment = 'Center'
        $line = New-Object Windows.Controls.Border; $line.Height = 3; $line.CornerRadius = 1.5; $line.Margin = '1,1,1,1'
        $line.Background = $(if ($t.pos -eq 'punctuation') { $clear } else { $color })
        foreach ($x in $furi, $surf, $line, $roma) { $sp.Children.Add($x) | Out-Null }
        $b.Child = $sp
        $punct = $t.pos -eq 'punctuation'
        if ($t.meaning -or -not $punct) {  # punctuation gets a tooltip too: its name and why it is placed here
            if (-not $punct -and $seen -notcontains $t.pos) { $seen += $t.pos }
            $tt = New-Object Windows.Controls.ToolTip
            $tt.Background = New-JpBrush '#F5242428'; $tt.Foreground = New-JpBrush '#F0F0F0'; $tt.BorderBrush = $color; $tt.Padding = '10,8'
            $tp = New-Object Windows.Controls.StackPanel; $tp.MaxWidth = 360
            $h = New-JpText $(if ($punct) { $t.surface } else { "$($t.surface)   $($t.reading) · $($t.romaji)" }) 17; $h.FontWeight = 'SemiBold'
            $p = New-JpText $(if ($punct) { 'punctuation' } else { "$($t.pos)  ·  $($t.role)" }) 12.5; $p.Foreground = $(if ($punct) { New-JpBrush '#B0BEC5' } else { $color })
            $m = New-JpText $t.meaning 14.5
            $e = New-JpText $t.explanation 12.5 0.85; $e.Margin = '0,4,0,0'
            $acc = if ($t.pitch_src -eq 'dict' -and $null -ne $t.accent) {
                $n = [int]$t.accent; $mc = @($t.morae).Count
                $kind = if ($n -eq 0) { 'heiban: low start, stays high' } elseif ($n -eq 1) { 'atamadaka: high start, drops after the 1st mora' } elseif ($n -ge $mc) { 'odaka: rises, drops on the next particle' } else { "nakadaka: drops after mora $n" }
                "Pitch [$n] $kind ($($t.pitch), dictionary)"
            } elseif ($t.pitch) { "Pitch $($t.pitch) (AI estimate)" } else { '' }
            $pa = New-JpText $acc 11.5 0.65; $pa.Margin = '0,4,0,0'
            foreach ($x in $h, $p, $m, $e, $pa) { $tp.Children.Add($x) | Out-Null }
            $tt.Content = $tp; $b.ToolTip = $tt
            [Windows.Controls.ToolTipService]::SetInitialShowDelay($b, 120); [Windows.Controls.ToolTipService]::SetShowDuration($b, 60000)
            $b.Add_MouseEnter({ param($s, $e) if (-not (Test-JpCur $s.Tag)) { $s.Background = $hoverBrush } })
            $b.Add_MouseLeave({ param($s, $e) if (-not (Test-JpCur $s.Tag)) { $s.Background = $clear } })
            if (-not $punct) {
            $b.Cursor = 'Hand'
            $b.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })  # a click on a word is not a window drag
            $b.Add_MouseLeftButtonUp({ param($s, $e) $t = $st.data.tokens[$s.Tag]; Start-JpSpeech $(if ($t.reading) { $t.reading } else { $t.surface }) $false $s.Tag })
            $b.Add_MouseRightButtonUp({ param($s, $e) Save-JpWords @($st.data.tokens[$s.Tag]) })
            }
        }
        $ui.words.Children.Add($b) | Out-Null; $blocks += $b
    }
    $st.starts = $starts; $st.blocks = $blocks
    # Karaoke shows phrases (a word plus its particles/endings): single particles flash by too fast to read.
    $phrases = @(); $phraseOf = @()
    for ($k = 0; $k -lt $d.tokens.Count; $k++) {
        if ($k -eq 0 -or $d.tokens[$k].pos -notin 'particle', 'auxiliary', 'suffix', 'punctuation') { $phrases += , @($k, $k) } else { $phrases[-1][1] = $k }
        $phraseOf += $phrases.Count - 1
    }
    $st.phrases = $phrases; $st.phraseOf = $phraseOf
    foreach ($pname in $seen) {
        $lg = New-Object Windows.Controls.StackPanel; $lg.Orientation = 'Horizontal'; $lg.Margin = '0,0,10,0'
        $sw = New-Object Windows.Controls.Border; $sw.Width = 12; $sw.Height = 3; $sw.CornerRadius = 1.5; $sw.Background = New-JpBrush $posColor[$pname]; $sw.Margin = '0,0,4,0'
        $lg.Children.Add($sw) | Out-Null; $lg.Children.Add((New-JpText $pname 11)) | Out-Null
        $ui.legend.Children.Add($lg) | Out-Null
    }
    if ($seen) { $ui.legend.Children.Add((New-JpText 'pitch: line on top = high, at the bottom = low (faint = AI estimate)' 11)) | Out-Null }
    $st.hint = if ($d.tokens.Count) { 'Hover: meaning · click: listen · right-click: save' } else { '' }
    $ui.status.Text = $st.hint
    $ui.play.IsEnabled = $d.tokens.Count -gt 0; $ui.save.IsEnabled = $d.tokens.Count -gt 0
    if ($d.tokens.Count) { Start-JpSpeech $d.sentence $true -1 $false }  # prefetch the voice
}

$timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(40)
$timer.Add_Tick({
    foreach ($j in @($st.jobs)) { if ($j.job.P.HasExited) { $st.jobs = @($st.jobs | Where-Object { $_ -ne $j }); & $j.done (Read-JpSsh $j.job) $j } }
    if ($st.marks) {  # karaoke: highlight the phrase being spoken, each shown at least 350 ms (it catches up after)
        $ms0 = $player.Position.TotalMilliseconds; $k = -1
        foreach ($m in $st.marks) { if ($m.t -le $ms0) { $k = $m.tok } else { break } }
        if ($k -ge 0) {
            $ph = $st.phraseOf[$k]
            if ($ph -ne $st.curPhrase -and ($st.curPhrase -lt 0 -or [Environment]::TickCount - $st.shownAt -ge 350)) {
                $st.curPhrase = $ph; Show-JpNow $st.phrases[$ph][0] $st.phrases[$ph][1]
            }
        }
    }
})
$player.Add_MediaEnded({ $st.marks = $null; $st.curPhrase = -1; Show-JpNow -1 })
$ui.play.Add_Click({ Start-JpSpeech $st.data.sentence $true })
$ui.speed.Add_Click({
    $st.rate = if ($st.rate -eq 'slow') { 'normal' } else { 'slow' }; $ui.speed.Opacity = if ($st.rate -eq 'slow') { 1 } else { 0.5 }
    if ($st.data -and $st.data.tokens.Count) { Start-JpSpeech $st.data.sentence $true -1 $false }  # prefetch this speed too
})
$ui.settings.Add_Click({ Start-Process notepad.exe "`"$cfgFile`"" })  # takes effect on the next snip
$ui.save.Add_Click({ Save-JpWords $st.data.tokens })
$ui.close.Add_Click({ $win.Close() })
$win.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $win.Close() } elseif ($e.Key -eq 'Space' -and $ui.play.IsEnabled) { Start-JpSpeech $st.data.sentence $true } })
$ui.root.Add_MouseLeftButtonDown({ $st.moved = $true; $win.DragMove() })

$win.Add_Loaded({
    # The selection drag ends at the cursor: open next to it, in DIPs, inside that screen's work area.
    $px = [Windows.Forms.Cursor]::Position
    $m = [Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformFromDevice
    $a = $m.Transform((New-Object Windows.Point($px.X, $px.Y)))
    $wa = [Windows.Forms.Screen]::FromPoint($px).WorkingArea
    $st.anchor = $a
    $st.wa = New-Object Windows.Rect($m.Transform((New-Object Windows.Point($wa.Left, $wa.Top))), $m.Transform((New-Object Windows.Point($wa.Right, $wa.Bottom))))
    $win.Left = $a.X + 12; $win.Top = $a.Y + 12
    $win.Activate()
    $st.jobs += @{ job = (Start-JpSsh '' $ms.ToArray()); done = { param($r) Show-JpResult $r } }
    $timer.Start()
})
$win.Add_SizeChanged({
    if ($st.moved -or -not $st.wa) { return }
    $w = $win.ActualWidth; $h = $win.ActualHeight
    $win.Left = [Math]::Max($st.wa.Left, [Math]::Min($st.anchor.X + 12, $st.wa.Right - $w))
    $win.Top = if ($st.anchor.Y + 12 + $h -gt $st.wa.Bottom) { [Math]::Max($st.wa.Top, $st.anchor.Y - $h - 12) } else { $st.anchor.Y + 12 }
})
$win.Add_Closed({
    $timer.Stop(); $player.Close()
    foreach ($j in $st.jobs) { if (-not $j.job.P.HasExited) { $j.job.P.Kill() } }
})
[void]$win.ShowDialog()
# MediaPlayer releases its file lock asynchronously: keep pumping messages until the cached audio can be deleted.
for ($i = 0; $i -lt 30 -and @($st.files | Where-Object { Test-Path $_ }).Count; $i++) {
    [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
    $st.files | Remove-Item -ErrorAction SilentlyContinue
}

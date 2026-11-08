# Drawing the breakdown: word blocks (pitch line, kana, part-of-speech underline, romaji), tooltips, hover levels and
# the "now" strip. Works on $st (state), $ui (named overlay elements) and $st.data (the reply from jpsnap_core.py).

$posColor = @{
    noun = '#4FC3F7'; pronoun = '#81D4FA'; verb = '#FF8A65'; adjective = '#CE93D8'; adverb = '#AED581'; particle = '#FFD54F'
    auxiliary = '#F06292'; conjunction = '#B0BEC5'; interjection = '#B0BEC5'; counter = '#4DB6AC'; prefix = '#BCAAA4'
    suffix = '#BCAAA4'; other = '#B0BEC5'
}
$brushConverter = New-Object Windows.Media.BrushConverter
function New-JpBrush([string]$hex) { $brushConverter.ConvertFromString($hex) }
$hoverBrush = New-JpBrush '#22FFFFFF'; $curBrush = New-JpBrush '#663D8BFD'; $clear = [Windows.Media.Brushes]::Transparent
function Get-JpPosBrush([string]$pos) { New-JpBrush $(if ($posColor.ContainsKey($pos)) { $posColor[$pos] } else { '#B0BEC5' }) }

function Read-JpXaml([string]$path) { [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText($path)) }
function Get-JpNamed($window, [string[]]$names) {  # name -> element, with the name as UI Automation id for the tests
    $map = @{}
    foreach ($n in $names) { $map[$n] = $window.FindName($n); [Windows.Automation.AutomationProperties]::SetAutomationId($map[$n], $n) }
    $map
}
# Windows' "right-handed" menu setting opens WPF popups to the left of the cursor, pushing them off the overlay.
function Set-JpPopupsRight {
    $field = [Windows.SystemParameters].GetField('_menuDropAlignment', [Reflection.BindingFlags]'NonPublic, Static')
    if ([Windows.SystemParameters]::MenuDropAlignment -and $field) { $field.SetValue($null, $false) }
}

function New-JpText([string]$text, [double]$size, [double]$opacity = 1) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.Opacity = $opacity; $t.TextWrapping = 'Wrap'
    if (-not $text) { $t.Visibility = 'Collapsed' }  # fast answers leave some fields empty
    $t
}
function New-JpStack($children, [string]$orientation = 'Vertical') {
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = $orientation
    foreach ($c in $children) { [void]$sp.Children.Add($c) }
    $sp
}

# Pitch accent row: one cell per mora, line on top = high, line at the bottom = low, a vertical step where it changes.
function New-JpPitch($t, [double]$size) {
    $mor = @($t.morae); $p = [string]$t.pitch
    $pen = New-JpBrush $(if ($t.pitch_src -eq 'dict') { '#E6FFFFFF' } else { '#66FFFFFF' })  # faint = AI estimate
    $w = [Math]::Max(1.2, $size / 9)
    $cells = for ($i = 0; $i -lt $mor.Count; $i++) {
        $c = New-Object Windows.Controls.Border; $c.BorderBrush = $pen; $c.Padding = '0,1,0,1'
        if ($p.Length -eq $mor.Count) {
            $hi = $p[$i] -eq 'H'
            $step = if ($i -gt 0 -and $p[$i] -ne $p[$i - 1]) { $w } else { 0 }
            $c.BorderThickness = New-Object Windows.Thickness($step, $(if ($hi) { $w } else { 0 }), 0, $(if ($hi) { 0 } else { $w }))
        }
        $x = New-JpText $mor[$i] $size 0.85; $x.TextWrapping = 'NoWrap'; $c.Child = $x
        $c
    }
    if (-not $mor.Count) { $cells = @(New-JpText ' ' $size) }
    $row = New-JpStack $cells 'Horizontal'; $row.HorizontalAlignment = 'Center'
    $row
}

# ---------- "now" strip: the word or phrase being spoken ----------

function Test-JpCur([int]$k) { $k -ge $st.curFirst -and $k -le $st.curLast }
function Show-JpNow([int]$first, [int]$last = $first) {  # -1 hides it
    for ($k = [Math]::Max(0, $st.curFirst); $k -le $st.curLast -and $k -lt $st.blocks.Count; $k++) { $st.blocks[$k].Background = $clear }
    $st.curFirst = $first; $st.curLast = $last; $st.shownAt = [Environment]::TickCount
    if ($first -lt 0 -or $last -ge $st.blocks.Count) { $ui.now.Visibility = 'Collapsed'; return }
    $toks = @($st.data.tokens[$first..$last])
    for ($k = $first; $k -le $last; $k++) { $st.blocks[$k].Background = $curBrush }
    $ui.nowWord.Text = -join ($toks | ForEach-Object { $_.surface })
    $ui.nowPitch.Child = New-JpStack @(foreach ($t in $toks) { if ($t.pos -ne 'punctuation') { New-JpPitch $t 16 } }) 'Horizontal'
    $ui.nowRomaji.Text = ($toks | Where-Object { $_.romaji } | ForEach-Object { $_.romaji }) -join ' '
    $ui.nowMeaning.Text = ($toks | Where-Object { $_.meaning } | ForEach-Object { $_.meaning }) -join '  ·  '
    $ui.now.Visibility = 'Visible'
}
function Get-JpTokenAt([int]$charIndex) {
    $k = 0; while ($k + 1 -lt $st.starts.Count -and $st.starts[$k + 1] -le $charIndex) { $k++ }; $k
}

# ---------- hover: plain = the token, Alt = the whole word it belongs to, Shift = its part of the sentence ----------

function Get-JpWordText($t) { if ($t.reading) { $t.reading } elseif ($t.surface) { $t.surface } else { $t.text } }
function Get-JpSel([int]$k, [string]$mode) {  # -> @{ first; last; g = the word/part or $null }
    $g = if ($mode -eq 'word') { $st.wordOf[$k] } elseif ($mode -eq 'part') { $st.partOf[$k] }
    if ($g) { @{ first = [int]$g.first; last = [int]$g.last; g = $g } } else { @{ first = $k; last = $k; g = $null } }
}
function Get-JpHoverMode {  # read from the keyboard state, so it works even when the overlay has no focus
    if ([JpSnap.Win]::GetAsyncKeyState(0x12) -lt 0) { 'word' } elseif ([JpSnap.Win]::GetAsyncKeyState(0x10) -lt 0) { 'part' } else { 'token' }
}

function New-JpGroupTip($g, [string]$mode) {
    $pieces = ($st.data.tokens[$g.first..$g.last] | Where-Object { $_.pos -ne 'punctuation' } | ForEach-Object { $_.surface }) -join ' + '
    $head = New-JpText "$($g.text)   $($g.reading)" 17; $head.FontWeight = 'SemiBold'
    $kind = New-JpText $(if ($mode -eq 'word') { "whole word  ·  $pieces" } else { "$($g.role)  ·  $pieces" }) 12.5 0.8
    $why = New-JpText $g.explanation 12.5 0.85; $why.Margin = '0,4,0,0'
    $tip = New-JpStack @($head, $kind, (New-JpText $g.meaning 14.5), $why); $tip.MaxWidth = 380
    $tip
}
function Get-JpPitchNote($t) {
    if ($t.pitch_src -eq 'dict' -and $null -ne $t.accent) {
        $n = [int]$t.accent; $count = @($t.morae).Count
        $kind = if ($n -eq 0) { 'heiban: low start, stays high' } elseif ($n -eq 1) { 'atamadaka: high start, drops after the 1st mora' } elseif ($n -ge $count) { 'odaka: rises, drops on the next particle' } else { "nakadaka: drops after mora $n" }
        "Pitch [$n] $kind ($($t.pitch), dictionary)"
    } elseif ($t.pitch) { "Pitch $($t.pitch) (AI estimate)" } else { '' }
}
function New-JpTokenTip([int]$k) {
    $t = $st.data.tokens[$k]; $punct = $t.pos -eq 'punctuation'
    $head = New-JpText $(if ($punct) { $t.surface } else { "$($t.surface)   $($t.reading) · $($t.romaji)" }) 17; $head.FontWeight = 'SemiBold'
    $kind = New-JpText $(if ($punct) { 'punctuation' } else { "$($t.pos)  ·  $($t.role)" }) 12.5
    $kind.Foreground = $(if ($punct) { New-JpBrush '#B0BEC5' } else { Get-JpPosBrush $t.pos })
    $why = New-JpText $(if ($t.explanation) { $t.explanation } elseif ($st.busy) { 'Explanation loading…' } else { '' }) 12.5 0.85; $why.Margin = '0,4,0,0'
    $pitch = New-JpText (Get-JpPitchNote $t) 11.5 0.65; $pitch.Margin = '0,4,0,0'
    $keys = New-JpText $(if ($st.wordOf[$k]) { 'Alt: whole word · Shift: part of the sentence' } elseif ($st.partOf[$k]) { 'Shift: part of the sentence' } else { '' }) 10.5 0.5
    $keys.Margin = '0,6,0,0'
    $tip = New-JpStack @($head, $kind, (New-JpText $t.meaning 14.5), $why, $pitch, $keys); $tip.MaxWidth = 360
    $tip
}
# Highlight the hovered selection and point its tooltip at it; the UI timer calls this again when Alt/Shift change.
function Set-JpHover([int]$k, [string]$mode) {
    foreach ($i in $st.hoverRange) { if (-not (Test-JpCur $i)) { $st.blocks[$i].Background = $clear } }
    $st.hoverRange = @(); $st.tipFor = $k; $st.tipMode = $mode
    if ($k -lt 0) { return }
    $sel = Get-JpSel $k $mode
    $st.hoverRange = @($sel.first..$sel.last)
    foreach ($i in $st.hoverRange) { if (-not (Test-JpCur $i)) { $st.blocks[$i].Background = $hoverBrush } }
    if ($st.blocks[$k].ToolTip) { $st.blocks[$k].ToolTip.Content = $(if ($sel.g) { New-JpGroupTip $sel.g $mode } else { New-JpTokenTip $k }) }
}
function Update-JpHover {  # timer: follow Alt/Shift while the mouse rests on a word
    if ($st.hover -lt 0) { return }
    $mode = Get-JpHoverMode
    if ($mode -ne $st.tipMode -or $st.hover -ne $st.tipFor) { Set-JpHover $st.hover $mode }
}

# ---------- the breakdown ----------

function New-JpWordBlock([int]$k) {
    $t = $st.data.tokens[$k]; $punct = $t.pos -eq 'punctuation'
    $surface = New-JpText $t.surface 24; $surface.HorizontalAlignment = 'Center'
    $underline = New-Object Windows.Controls.Border; $underline.Height = 3; $underline.CornerRadius = 1.5; $underline.Margin = '1,1,1,1'
    $underline.Background = $(if ($punct) { $clear } else { Get-JpPosBrush $t.pos })
    $romaji = New-JpText $(if ($t.romaji) { $t.romaji } else { ' ' }) 10 0.55; $romaji.HorizontalAlignment = 'Center'; $romaji.TextWrapping = 'NoWrap'

    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 4; $b.Padding = '2,0,2,1'; $b.Background = $clear; $b.Tag = $k
    $b.Child = New-JpStack @((New-JpPitch $t 11), $surface, $underline, $romaji)
    [Windows.Automation.AutomationProperties]::SetAutomationId($b, "w$k")
    if ($punct -and -not $t.meaning) { return $b }

    # punctuation gets a tooltip too: its name and why it is placed here
    $tip = New-Object Windows.Controls.ToolTip
    $tip.Background = New-JpBrush '#F5242428'; $tip.Foreground = New-JpBrush '#F0F0F0'; $tip.Padding = '10,8'
    $tip.BorderBrush = $(if ($punct) { New-JpBrush '#B0BEC5' } else { Get-JpPosBrush $t.pos })
    $tip.Content = New-JpTokenTip $k; $b.ToolTip = $tip
    # below the whole block, not under the cursor: a tip under the cursor covers the next word and swallows its hover
    $tip.Placement = 'Bottom'; $tip.PlacementTarget = $b
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($b, 120); [Windows.Controls.ToolTipService]::SetShowDuration($b, 60000)
    $b.Add_MouseEnter({ param($s, $e) $st.hover = $s.Tag; Set-JpHover $s.Tag (Get-JpHoverMode) })
    # Leave of the old word can arrive after Enter of the new one: only clear the hover if it is still this word's
    $b.Add_MouseLeave({ param($s, $e) if ($st.hover -eq $s.Tag) { $st.hover = -1; Set-JpHover -1 'token' } })
    if ($punct) { return $b }
    $b.Cursor = 'Hand'
    $b.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })  # a click on a word is not a window drag
    $b.Add_MouseLeftButtonUp({ param($s, $e)
        $sel = Get-JpSel $s.Tag $st.tipMode
        $what = if ($sel.g) { $sel.g } else { $st.data.tokens[$s.Tag] }
        Start-JpSpeech (Get-JpWordText $what) $false @($sel.first, $sel.last)
    })
    $b.Add_MouseRightButtonUp({ param($s, $e) Save-JpWords @($st.data.tokens[$s.Tag]) })
    $b
}

function Show-JpLegend {
    $ui.legend.Children.Clear()
    $used = @($st.data.tokens | Where-Object { $_.pos -ne 'punctuation' } | ForEach-Object { $_.pos } | Select-Object -Unique)
    foreach ($pos in $used) {
        $swatch = New-Object Windows.Controls.Border
        $swatch.Width = 12; $swatch.Height = 3; $swatch.CornerRadius = 1.5; $swatch.Background = Get-JpPosBrush $pos; $swatch.Margin = '0,0,4,0'
        $item = New-JpStack @($swatch, (New-JpText $pos 11)) 'Horizontal'; $item.Margin = '0,0,10,0'
        [void]$ui.legend.Children.Add($item)
    }
    if ($used) { [void]$ui.legend.Children.Add((New-JpText 'pitch: line on top = high, at the bottom = low (faint = AI estimate)' 11)) }
}

# Draw a reply (quick or full; a full one replaces the quick one in place).
function Show-JpResult($d) {
    Show-JpNow -1
    $st.data = $d; $st.hover = -1; $st.hoverRange = @(); $st.tipFor = -1
    $count = @($d.tokens).Count
    $st.wordOf = New-Object object[] $count; $st.partOf = New-Object object[] $count  # token -> its word / part
    foreach ($g in @($d.words)) { for ($i = [int]$g.first; $i -le [int]$g.last; $i++) { if (-not $st.wordOf[$i]) { $st.wordOf[$i] = $g } } }
    foreach ($g in @($d.parts)) { for ($i = [int]$g.first; $i -le [int]$g.last; $i++) { if (-not $st.partOf[$i]) { $st.partOf[$i] = $g } } }

    $ui.translation.Text = $d.translation
    $ui.grammar.Children.Clear()
    foreach ($note in @($d.grammar)) { [void]$ui.grammar.Children.Add((New-JpText "• $note" 12.5 0.8)) }

    $ui.words.Children.Clear(); $st.blocks = @(); $st.starts = @(); $pos = 0
    for ($k = 0; $k -lt $count; $k++) {
        $st.starts += $pos; $pos += $d.tokens[$k].surface.Length
        $b = New-JpWordBlock $k; $st.blocks += $b; [void]$ui.words.Children.Add($b)
    }

    # Karaoke shows phrases (a word plus its particles/endings): single particles flash by too fast to read.
    $st.phrases = @(); $st.phraseOf = @()
    for ($k = 0; $k -lt $count; $k++) {
        if ($k -eq 0 -or $d.tokens[$k].pos -notin 'particle', 'auxiliary', 'suffix', 'punctuation') { $st.phrases += , @($k, $k) } else { $st.phrases[-1][1] = $k }
        $st.phraseOf += $st.phrases.Count - 1
    }
    Show-JpLegend
    $ui.hint.Visibility = $(if ($count) { 'Visible' } else { 'Collapsed' })
    $ui.play.IsEnabled = $count -gt 0; $ui.save.IsEnabled = $count -gt 0
}

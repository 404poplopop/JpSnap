# Hover levels without mouse or keyboard input: loads the real lib\render.ps1 and checks what plain,
# Alt (whole word) and Shift (part of the sentence) select and show. Runs anywhere, no window.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. "$PSScriptRoot\lib\render.ps1"
Add-Type -Namespace JpSnap -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);'
function New-TestTok($s, $r) { [pscustomobject]@{ surface = $s; reading = $r; romaji = ''; pos = 'noun'; role = ''; meaning = ''; explanation = ''; pitch = ''; pitch_src = ''; accent = $null; morae = @() } }
$w = [pscustomobject]@{ first = 0; last = 1; text = '8杯'; reading = 'はっぱい'; meaning = 'eight bowls'; explanation = 'はち + はい -> はっぱい' }
$p = [pscustomobject]@{ first = 0; last = 2; text = '8杯食べた'; reading = 'はっぱいたべた'; role = 'quantity and predicate'; meaning = ''; explanation = '' }
$st = @{ data = [pscustomobject]@{ tokens = @((New-TestTok '8' 'はっ'), (New-TestTok '杯' 'ぱい'), (New-TestTok '食べた' 'たべた')); words = @($w); parts = @($p) }
         busy = $false; tip = $null; curFirst = -1; curLast = -1; hoverRange = @(); tipFor = -1; tipMode = 'token'; wordOf = @($w, $w, $null); partOf = @($p, $p, $p); blocks = @() }
$st.blocks = @(foreach ($i in 0..2) { $b = New-Object Windows.Controls.Border; $b.Background = $clear; $b })
function Get-TestState { (@(foreach ($b in $st.blocks) { [int]($b.Background -eq $hoverBrush) }) -join '') + ' ' + $st.tip.Child.Child.Children[0].Text }
$out = @()
foreach ($c in @(@('token', '010', '杯   ぱい'), @('word', '110', '8杯   はっぱい'), @('part', '111', '8杯食べた   はっぱいたべた'))) {
    Set-JpHover 1 $c[0]; $got = Get-TestState
    $out += "HOVER_$($c[0].ToUpper())=" + $(if ($got.StartsWith("$($c[1]) $($c[2])")) { 'PASS' } else { "FAIL '$got'" })
}
Set-JpHover -1 'token'; $out += 'HOVER_LEAVE=' + $(if ((Get-TestState).StartsWith('000')) { 'PASS' } else { 'FAIL' })
$sel = Get-JpSel 2 'word'; $out += 'ALT_NO_WORD=' + $(if ($sel.first -eq 2 -and $sel.last -eq 2 -and -not $sel.g) { 'PASS' } else { 'FAIL' })
$out += 'ALT_CLICK_TEXT=' + $(if ((Get-JpWordText (Get-JpSel 0 'word').g) -eq 'はっぱい') { 'PASS' } else { 'FAIL' })
# moving from word 0 to word 2 with the real blocks and WPF mouse events (raised in-process, no real input),
# in both orders Windows may deliver them: the new word must end up hovered and highlighted
$st.blocks = @(foreach ($i in 0..2) { New-JpWordBlock $i })
function Send-TestMouse($b, $routed) { $a = New-Object Windows.Input.MouseEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0); $a.RoutedEvent = $routed; $b.RaiseEvent($a) }
$enter = [Windows.UIElement]::MouseEnterEvent; $leave = [Windows.UIElement]::MouseLeaveEvent
foreach ($order in 'leave-first', 'enter-first') {
    Set-JpHover -1 'token'; $st.hover = -1
    Send-TestMouse $st.blocks[0] $enter
    if ($order -eq 'leave-first') { Send-TestMouse $st.blocks[0] $leave; Send-TestMouse $st.blocks[2] $enter }
    else { Send-TestMouse $st.blocks[2] $enter; Send-TestMouse $st.blocks[0] $leave }
    $lit = (@(foreach ($b in $st.blocks) { [int]($b.Background -eq $hoverBrush) }) -join '')
    $head = $st.tip.Child.Child.Children[0].Text
    $onNew = $st.tip.IsOpen -and $st.tip.PlacementTarget -eq $st.blocks[2] -and $head.StartsWith('食べた')
    $out += "MOVE_$($order.ToUpper().Replace('-', '_'))=" + $(if ($st.hover -eq 2 -and $lit -eq '001' -and $onNew) { 'PASS' } else { "FAIL (hover $($st.hover), lit $lit, open $($st.tip.IsOpen), '$head')" })
}
$out += 'TIP_BELOW_BLOCK=' + $(if ($st.tip.Placement -eq 'Bottom' -and -not $st.tip.IsHitTestVisible) { 'PASS' } else { 'FAIL' })
Send-TestMouse $st.blocks[2] $leave
$out += 'TIP_CLOSES_ON_LEAVE=' + $(if (-not $st.tip.IsOpen -and $st.hover -eq -1) { 'PASS' } else { 'FAIL' })
# a Leave that never arrives (the stuck case): the timer sees the word is no longer under the pointer and closes the tip
Send-TestMouse $st.blocks[1] $enter
Update-JpHover
$out += 'LOST_LEAVE_RECOVERED=' + $(if (-not $st.tip.IsOpen -and $st.hover -eq -1) { 'PASS' } else { "FAIL (hover $($st.hover), open $($st.tip.IsOpen))" })
$out -join "`r`n" | Out-File -Encoding utf8 "$env:TEMP\jpsnap_hover.txt"

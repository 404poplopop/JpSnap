# Hover levels without mouse or keyboard input: loads the real functions from jpsnap.ps1 and checks what plain,
# Alt (whole word) and Shift (part of the sentence) select and show. Runs anywhere, no window.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\jpsnap.ps1", [ref]$null, [ref]$null)
$names = 'New-JpBrush', 'New-JpText', 'Test-JpCur', 'Get-JpWordText', 'Get-JpSel', 'New-JpGroupTip', 'New-JpTokenTip', 'Set-JpHover'
foreach ($f in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { if ($f.Name -in $names) { . ([ScriptBlock]::Create($f.Extent.Text)) } }
$hoverBrush = New-JpBrush '#22FFFFFF'; $clear = [Windows.Media.Brushes]::Transparent; $posColor = @{}
function New-TestTok($s, $r) { [pscustomobject]@{ surface = $s; reading = $r; romaji = ''; pos = 'noun'; role = ''; meaning = ''; explanation = ''; pitch = ''; pitch_src = ''; accent = $null; morae = @() } }
$w = [pscustomobject]@{ first = 0; last = 1; text = '8杯'; reading = 'はっぱい'; meaning = 'eight bowls'; explanation = 'はち + はい -> はっぱい' }
$p = [pscustomobject]@{ first = 0; last = 2; text = '8杯食べた'; reading = 'はっぱいたべた'; role = 'quantity and predicate'; meaning = ''; explanation = '' }
$st = @{ data = [pscustomobject]@{ tokens = @((New-TestTok '8' 'はっ'), (New-TestTok '杯' 'ぱい'), (New-TestTok '食べた' 'たべた')); words = @($w); parts = @($p) }
         curFirst = -1; curLast = -1; hoverRange = @(); tipFor = -1; tipMode = 'token'; wordOf = @($w, $w, $null); partOf = @($p, $p, $p); blocks = @() }
$st.blocks = @(foreach ($i in 0..2) { $b = New-Object Windows.Controls.Border; $b.Background = $clear; $b.ToolTip = New-Object Windows.Controls.ToolTip; $b })
function Get-TestState { (@(foreach ($b in $st.blocks) { [int]($b.Background -eq $hoverBrush) }) -join '') + ' ' + $st.blocks[1].ToolTip.Content.Children[0].Text }
$out = @()
foreach ($c in @(@('token', '010', '杯   ぱい'), @('word', '110', '8杯   はっぱい'), @('part', '111', '8杯食べた   はっぱいたべた'))) {
    Set-JpHover 1 $c[0]; $got = Get-TestState
    $out += "HOVER_$($c[0].ToUpper())=" + $(if ($got.StartsWith("$($c[1]) $($c[2])")) { 'PASS' } else { "FAIL '$got'" })
}
Set-JpHover -1 'token'; $out += 'HOVER_LEAVE=' + $(if ((Get-TestState).StartsWith('000')) { 'PASS' } else { 'FAIL' })
$sel = Get-JpSel 2 'word'; $out += 'ALT_NO_WORD=' + $(if ($sel.first -eq 2 -and $sel.last -eq 2 -and -not $sel.g) { 'PASS' } else { 'FAIL' })
$out += 'ALT_CLICK_TEXT=' + $(if ((Get-JpWordText (Get-JpSel 0 'word').g) -eq 'はっぱい') { 'PASS' } else { 'FAIL' })
$out -join "`r`n" | Out-File -Encoding utf8 "$env:TEMP\jpsnap_hover.txt"

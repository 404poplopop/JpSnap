# What is kept: history.jsonl (every reply) and deck.tsv (Anki import: front = word, back = HTML) in Documents\JpSnap.

function Add-JpHistory([string]$replyJson) {
    [void](New-Item -ItemType Directory -Force $dataDir)
    $line = '{"time":"' + (Get-Date -Format s) + '","result":' + ($replyJson -replace '\r?\n', '') + "}`n"
    [IO.File]::AppendAllText((Join-Path $dataDir 'history.jsonl'), $line, $utf8)
}

# Model text is untrusted and Anki renders HTML (and scripts): escape it, and keep tabs/newlines out of the fields.
function ConvertTo-JpField($s) { [Net.WebUtility]::HtmlEncode((([string]$s) -replace '\s+', ' ')) }

function Save-JpWords($tokens) {
    if ($st.busy) { $ui.status.Text = 'Details still loading: save in a moment'; return }  # quick results have no explanations
    [void](New-Item -ItemType Directory -Force $dataDir)
    $deck = Join-Path $dataDir 'deck.tsv'
    $have = if (Test-Path $deck) { [IO.File]::ReadAllLines($deck, $utf8) | ForEach-Object { ($_ -split "`t")[0] } } else { @() }
    $sentence = ConvertTo-JpField $st.data.sentence
    $new = @(foreach ($t in $tokens) {
        if ($t.pos -in 'particle', 'punctuation', 'auxiliary' -and $tokens.Count -gt 1) { continue }
        $front = ConvertTo-JpField $t.surface
        if ($have -contains $front) { continue }
        $back = "$(ConvertTo-JpField $t.reading) ($(ConvertTo-JpField $t.romaji))<br>$(ConvertTo-JpField $t.meaning)" +
                "<br><small>$(ConvertTo-JpField $t.pos) · $(ConvertTo-JpField $t.explanation)</small><br><i>$sentence</i>"
        "$front`t$back"
    })
    if ($new) { [IO.File]::AppendAllText($deck, ($new -join "`n") + "`n", $utf8) }
    $ui.status.Text = "Saved $($new.Count) new word(s) to deck.tsv"
}

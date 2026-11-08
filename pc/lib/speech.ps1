# Voice: clips come from jpsnap_core.py tts, are cached per "voice|rate|text" until the window closes, and the sentence
# clip drives the karaoke (each spoken word's position in the sentence -> the phrase to highlight).

function Get-JpClipKey([string]$text) { "$($cfg.voice)|$($st.rate)|$text" }

function Start-JpClip($clip, [bool]$sentence, [int[]]$only) {
    Write-JpDebug "clip $(Split-Path -Leaf $clip.file) sentence=$sentence from=$((Get-PSCallStack)[1].Command)"
    $player.Stop(); $player.Open([uri]$clip.file); $player.Play()
    $st.marks = if ($sentence) { $clip.marks } else { $null }
    $st.curPhrase = -1
    Show-JpNow $only[0] $only[-1]
}

# Speak text: a sentence highlights each phrase as it is spoken; a word or selection ($only = first, last token) is
# shown in the "now" strip. $play = $false only fetches the audio into the cache.
function Start-JpSpeech([string]$text, [bool]$sentence, [int[]]$only = -1, [bool]$play = $true) {
    $key = Get-JpClipKey $text
    if ($st.audio.ContainsKey($key)) { if ($play) { Start-JpClip $st.audio[$key] $sentence $only }; return }
    $pending = @($st.jobs | Where-Object { $_.ctx.cacheKeys -contains $key })
    if ($pending) {  # already on its way: just ask for it to be played when it lands
        Write-JpDebug "pending play=$play key='$key'"
        if ($play) { $ctx = $pending[0].ctx; $ctx.play = $key; $ctx.sentence = $sentence; $ctx.only = $only; $ui.status.Text = 'Loading voice…' }
        return
    }
    Start-JpTts @($text) $(if ($play) { $key } else { '' }) $sentence $only
}

# One tts call for several texts (e.g. every word of the snip); $play = the cache key to play when it arrives.
function Start-JpTts([string[]]$texts, [string]$play = '', [bool]$sentence = $false, [int[]]$only = -1) {
    $keys = @(); $todo = @()
    foreach ($text in $texts) {
        $key = Get-JpClipKey $text
        $known = $keys -contains $key -or $st.audio.ContainsKey($key) -or @($st.jobs | Where-Object { $_.ctx.cacheKeys -contains $key })
        if (-not $known) { $keys += $key; $todo += $text }
    }
    if (-not $todo) { return }
    if ($play) { $ui.status.Text = 'Loading voice…' }
    $req = @{ texts = $todo; rate = $st.rate; voice = $cfg.voice } | ConvertTo-Json -Compress
    $job = Start-JpCore 'tts' ([Convert]::ToBase64String($utf8.GetBytes($req)))
    Write-JpDebug "tts $($todo.Count) texts play='$play' first='$($todo[0])'"
    Add-JpJob $job { param($r, $ctx) Save-JpClips $r $ctx } @{ cacheKeys = $keys; play = $play; sentence = $sentence; only = $only }
}

function Save-JpClips($r, $ctx) {
    if (-not $r.Ok) { if ($ctx.play) { $ui.status.Text = $r.Text }; return }
    $items = @(($r.Text | ConvertFrom-Json).items)
    for ($n = 0; $n -lt $items.Count; $n++) {
        $file = Join-Path $env:TEMP ("jpsnap_tts_{0}_{1}.mp3" -f $PID, $st.files.Count)
        [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($items[$n].audio)); $st.files += $file
        # where each spoken word starts in the sentence (a character index, so it survives a re-render)
        $from = 0; $marks = @()
        foreach ($m in $items[$n].marks) {
            $at = $st.data.sentence.IndexOf([string]$m.text, $from)
            if ($at -ge 0) { $from = $at + ([string]$m.text).Length; $marks += @{ t = [double]$m.t; at = $at } }
        }
        $st.audio[$ctx.cacheKeys[$n]] = @{ file = $file; marks = $marks }
    }
    if ($ctx.play -and $st.audio.ContainsKey($ctx.play)) { $ui.status.Text = ''; Start-JpClip $st.audio[$ctx.play] $ctx.sentence $ctx.only }
}

function Start-JpPrefetch {  # the sentence, then every word, word group and sentence part, so clicks play at once
    Start-JpSpeech $st.data.sentence $true -1 $false
    $texts = @(foreach ($t in $st.data.tokens) { if ($t.pos -ne 'punctuation') { Get-JpWordText $t } }) +
             @(foreach ($g in @($st.data.words) + @($st.data.parts)) { if ($g) { Get-JpWordText $g } })
    Start-JpTts $texts
}

function Set-JpSpeed([string]$rate) {
    $st.rate = $rate; $cfg.speed = $rate; [void](Update-JpConfig $cfgFile @{ speed = $rate })
    Sync-JpHeader
    if ($st.data -and @($st.data.tokens).Count) { Start-JpPrefetch }
}

function Update-JpKaraoke {  # timer: highlight the phrase being spoken, each shown at least 350 ms (it catches up after)
    if (-not $st.marks -or -not $st.blocks.Count) { return }
    $now = $player.Position.TotalMilliseconds; $at = -1
    foreach ($m in $st.marks) { if ($m.t -le $now) { $at = $m.at } else { break } }
    if ($at -lt 0) { return }
    $ph = $st.phraseOf[(Get-JpTokenAt $at)]
    if ($ph -ne $st.curPhrase -and ($st.curPhrase -lt 0 -or [Environment]::TickCount - $st.shownAt -ge 350)) {
        $st.curPhrase = $ph; Show-JpNow $st.phrases[$ph][0] $st.phrases[$ph][1]
    }
}

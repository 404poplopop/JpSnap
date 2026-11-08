# Settings window (ui\settings.xaml). Returns $true when saved; the changes are in $cfg and config.json.

function Show-JpSettings($owner) {
    $w = Read-JpXaml "$dir\ui\settings.xaml"
    $f = Get-JpNamed $w @('root', 'runServer', 'runPc', 'server', 'apiKey', 'keyState', 'removeKey', 'fast',
        'voiceNanami', 'voiceKeita', 'speedNormal', 'speedSlow', 'error', 'saveSettings', 'cancelSettings')
    $f.runServer.IsChecked = $cfg.run_on -eq 'server'; $f.runPc.IsChecked = $cfg.run_on -eq 'pc'
    $f.server.Text = $cfg.server
    $hasKey = [bool](Unprotect-JpSecret $cfg.openai_api_key_dpapi)
    $f.keyState.Text = if ($hasKey) { 'A key is saved, encrypted for your Windows account. Type a new one to replace it.' } else { 'Empty: uses the Codex subscription. A key is stored encrypted for your Windows account.' }
    $f.removeKey.Visibility = if ($hasKey) { 'Visible' } else { 'Collapsed' }
    $f.fast.IsChecked = [bool]$cfg.fast
    $f.voiceNanami.IsChecked = $cfg.voice -eq 'nanami'; $f.voiceKeita.IsChecked = $cfg.voice -eq 'keita'
    $f.speedNormal.IsChecked = $cfg.speed -eq 'normal'; $f.speedSlow.IsChecked = $cfg.speed -eq 'slow'

    $f.saveSettings.Add_Click({
        $server = $f.server.Text.Trim(); $key = $f.apiKey.Password.Trim()
        $problem = if ($f.runServer.IsChecked -and -not (Test-JpServer $server)) { 'Server must look like user@host, e.g. me@192.0.2.10.' }
                   elseif ($server -and -not (Test-JpServer $server)) { 'Server must look like user@host (or leave it empty).' }
                   elseif (-not (Test-JpApiKey $key)) { 'The API key must start with sk- and contain only letters, digits, - and _.' }
        if ($problem) { $f.error.Text = $problem; $f.error.Visibility = 'Visible'; return }
        $changes = @{
            run_on = $(if ($f.runPc.IsChecked) { 'pc' } else { 'server' }); server = $server; fast = [bool]$f.fast.IsChecked
            voice = $(if ($f.voiceKeita.IsChecked) { 'keita' } else { 'nanami' }); speed = $(if ($f.speedSlow.IsChecked) { 'slow' } else { 'normal' })
        }
        # the key only changes when a new one is typed or removal is ticked
        if ($key) { $changes.openai_api_key_dpapi = Protect-JpSecret $key } elseif ($f.removeKey.IsChecked) { $changes.openai_api_key_dpapi = '' }
        $latest = Update-JpConfig $cfgFile $changes
        foreach ($name in @($latest.Keys)) { $cfg[$name] = $latest[$name] }
        $w.DialogResult = $true
    })
    $f.root.Add_MouseLeftButtonDown({ $w.DragMove() })
    if ($owner) { $w.Owner = $owner; $w.WindowStartupLocation = 'CenterOwner' }
    [bool]$w.ShowDialog()
}

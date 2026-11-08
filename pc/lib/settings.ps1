# Settings window (ui\settings.xaml). Returns $true when saved; the changes are in $cfg and config.json.

function Show-JpSettings($owner) {
    $w = Read-JpXaml "$dir\ui\settings.xaml"
    $f = Get-JpNamed $w @('root', 'runServer', 'runHttps', 'runPc', 'server', 'httpsUrl', 'httpsToken', 'tokenState', 'apiKey', 'keyState', 'removeKey', 'fast',
        'voiceNanami', 'voiceKeita', 'speedNormal', 'speedSlow', 'autoStart', 'fastTier', 'model', 'error', 'saveSettings', 'cancelSettings')
    $f.runServer.IsChecked = $cfg.run_on -eq 'server'; $f.runHttps.IsChecked = $cfg.run_on -eq 'https'; $f.runPc.IsChecked = $cfg.run_on -eq 'pc'
    $f.server.Text = $cfg.server; $f.httpsUrl.Text = $cfg.https_url
    $hasToken = [bool](Unprotect-JpSecret $cfg.https_token_dpapi)
    $f.tokenState.Text = if ($hasToken) { 'Token saved (encrypted). Type a new one to replace it.' } else { 'Token: the line in ~/.config/jpsnap/https_token on the server.' }
    $hasKey = [bool](Unprotect-JpSecret $cfg.openai_api_key_dpapi)
    $f.keyState.Text = if ($hasKey) { 'A key is saved, encrypted for your Windows account. Type a new one to replace it.' } else { 'Empty: uses the Codex subscription. A key is stored encrypted for your Windows account.' }
    $f.removeKey.Visibility = if ($hasKey) { 'Visible' } else { 'Collapsed' }
    $f.fast.IsChecked = [bool]$cfg.fast; $f.fastTier.IsChecked = [bool]$cfg.fast_tier
    foreach ($m in $JpModels) { [void]$f.model.Items.Add($m) }; $f.model.SelectedItem = $cfg.model
    $autoBefore = Test-JpAutoStart; $f.autoStart.IsChecked = $autoBefore
    $f.voiceNanami.IsChecked = $cfg.voice -eq 'nanami'; $f.voiceKeita.IsChecked = $cfg.voice -eq 'keita'
    $f.speedNormal.IsChecked = $cfg.speed -eq 'normal'; $f.speedSlow.IsChecked = $cfg.speed -eq 'slow'

    $f.saveSettings.Add_Click({
        $server = $f.server.Text.Trim(); $key = $f.apiKey.Password.Trim(); $url = $f.httpsUrl.Text.Trim(); $token = $f.httpsToken.Password.Trim()
        $problem = if ($f.runServer.IsChecked -and -not (Test-JpServer $server)) { 'Server must look like user@host, e.g. me@192.0.2.10.' }
                   elseif ($server -and -not (Test-JpServer $server)) { 'Server must look like user@host (or leave it empty).' }
                   elseif (($f.runHttps.IsChecked -or $url) -and -not (Test-JpHttpsUrl $url)) { 'HTTPS address must look like https://example.com/jpsnap.' }
                   elseif (-not (Test-JpToken $token)) { 'The token must be 32-128 letters, digits, - or _.' }
                   elseif ($f.runHttps.IsChecked -and -not $token -and -not $hasToken) { 'HTTPS needs the token from the server.' }
                   elseif (-not (Test-JpApiKey $key)) { 'The API key must start with sk- and contain only letters, digits, - and _.' }
        if ($problem) { $f.error.Text = $problem; $f.error.Visibility = 'Visible'; return }
        $changes = @{
            run_on = $(if ($f.runPc.IsChecked) { 'pc' } elseif ($f.runHttps.IsChecked) { 'https' } else { 'server' })
            server = $server; https_url = $url; fast = [bool]$f.fast.IsChecked; fast_tier = [bool]$f.fastTier.IsChecked
            model = $(if ($f.model.SelectedItem) { [string]$f.model.SelectedItem } else { $JpModels[0] })
            voice = $(if ($f.voiceKeita.IsChecked) { 'keita' } else { 'nanami' }); speed = $(if ($f.speedSlow.IsChecked) { 'slow' } else { 'normal' })
        }
        # the key only changes when a new one is typed or removal is ticked
        if ($key) { $changes.openai_api_key_dpapi = Protect-JpSecret $key } elseif ($f.removeKey.IsChecked) { $changes.openai_api_key_dpapi = '' }
        if ($token) { $changes.https_token_dpapi = Protect-JpSecret $token }
        $latest = Update-JpConfig $cfgFile $changes
        if ([bool]$f.autoStart.IsChecked -ne $autoBefore) { Set-JpAutoStart ([bool]$f.autoStart.IsChecked) $dir }  # only when changed
        foreach ($name in @($latest.Keys)) { $cfg[$name] = $latest[$name] }
        $w.DialogResult = $true
    })
    $f.root.Add_MouseLeftButtonDown({ $w.DragMove() })
    if ($owner) { $w.Owner = $owner; $w.WindowStartupLocation = 'CenterOwner' }
    [bool]$w.ShowDialog()
}

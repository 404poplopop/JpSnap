# Runs jpsnap_core.py (translate | tts) on the server over ssh or HTTPS, or locally when run_on is "pc", without blocking the UI:
# Start-JpCore returns a job, Add-JpJob registers what to do with its reply, and the UI timer calls Complete-JpJobs.
# stdin and stdout are ASCII (JSON + base64 in, JSON out), so no console code page touches them.
# A job is a process (@{ P; Out; Err }) or an HTTPS request (@{ Http = task; Cts }).
Add-Type -AssemblyName System.Net.Http

function Start-JpCore([string]$mode, [string]$stdin) {
    if ($cfg.run_on -eq 'https') { return Start-JpHttps $mode $stdin }
    if ($cfg.run_on -eq 'pc') {
        $psi = New-Object Diagnostics.ProcessStartInfo "$dir\venv\Scripts\pythonw.exe"
        $psi.Arguments = "-I `"$dir\core\jpsnap_core.py`" $mode"
        # the Codex app's bundled CLI, else codex.exe on PATH (the npm codex.cmd shim cannot be started without a shell)
        $codex = Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\bin" -Recurse -Filter codex.exe -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        if (-not $codex) { $codex = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source }
        if ($codex) { $psi.EnvironmentVariables['JPSNAP_CODEX'] = $codex }
    } else {
        if (-not (Test-JpServer $cfg.server)) { throw "Server must look like user@host (settings)." }
        $psi = New-Object Diagnostics.ProcessStartInfo "$env:WINDIR\System32\OpenSSH\ssh.exe"
        $psi.Arguments = "-T -i `"$dir\jpsnap_key`" -o UserKnownHostsFile=`"$dir\known_hosts`" -o HostKeyAlias=jpsnap-server " +
            "-o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15 -- $($cfg.server) $mode"
    }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $proc = [Diagnostics.Process]::Start($psi)
    $job = @{ P = $proc; Out = $proc.StandardOutput.ReadToEndAsync(); Err = $proc.StandardError.ReadToEndAsync() }
    $proc.StandardInput.Write($stdin); $proc.StandardInput.Close()
    $job
}

# HTTPS mode, for networks that block ssh: the same body goes to <https_url>/<mode> (server/jp-https).
# HttpClient uses the Windows proxy settings, so it also works where only a corp proxy reaches the internet.
function Start-JpHttps([string]$mode, [string]$body) {
    if (-not (Test-JpHttpsUrl $cfg.https_url)) { throw 'HTTPS address must look like https://host/path (settings).' }
    if (-not $script:JpHttp) {  # one client for the window's life: it keeps the TLS connection
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.DefaultProxyCredentials = [Net.CredentialCache]::DefaultCredentials  # proxies that want the Windows login
        $script:JpHttp = New-Object Net.Http.HttpClient($handler); $script:JpHttp.Timeout = [TimeSpan]::FromSeconds(190)
    }
    $req = New-Object Net.Http.HttpRequestMessage('Post', "$($cfg.https_url.TrimEnd('/'))/$mode")
    $req.Headers.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', (Unprotect-JpSecret $cfg.https_token_dpapi))
    $req.Content = New-Object Net.Http.StringContent($body, [Text.Encoding]::ASCII, 'text/plain')
    $cts = New-Object Threading.CancellationTokenSource
    @{ Http = $script:JpHttp.SendAsync($req, $cts.Token); Cts = $cts }
}

function Test-JpJobDone($job) { if ($job.Http) { $job.Http.IsCompleted } else { $job.P.HasExited } }

function Read-JpCore($job) {  # -> @{ Ok; Text }
    if ($job.Http) {
        try { $resp = $job.Http.GetAwaiter().GetResult() }
        catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; return @{ Ok = $false; Text = "Failed: $($e.Message)" } }
        $text = $resp.Content.ReadAsStringAsync().Result  # already buffered by SendAsync
        if ($resp.IsSuccessStatusCode) { return @{ Ok = $true; Text = $text } }
        if ($text.Length -gt 600) { $text = $text.Substring(0, 600) }  # a proxy's HTML error page
        return @{ Ok = $false; Text = "Failed (HTTP $([int]$resp.StatusCode)): $text".Trim() }
    }
    $job.P.WaitForExit()
    $ok = $job.P.ExitCode -eq 0
    $text = if ($ok) { $job.Out.Result } else { "Failed (exit $($job.P.ExitCode)): $($job.Err.Result)$($job.Out.Result)".Trim() }
    @{ Ok = $ok; Text = $text }
}

function Start-JpTranslate([byte[]]$png, [bool]$fast) {
    $header = @{ key = (Unprotect-JpSecret $cfg.openai_api_key_dpapi); fast = $fast; model = $cfg.model; priority = [bool]$cfg.fast_tier } | ConvertTo-Json -Compress
    Start-JpCore 'translate' ($header + "`n" + [Convert]::ToBase64String($png))
}

# Optional trace for tests and bug hunts: set JPSNAP_DEBUG to a file path.
function Write-JpDebug([string]$msg) {
    if (-not $env:JPSNAP_DEBUG) { return }
    try { Add-Content -Encoding UTF8 $env:JPSNAP_DEBUG "$([int](((Get-Date) - $st.started).TotalMilliseconds)) $msg" } catch { }  # tracing must never break the app
}

function Add-JpJob($job, [scriptblock]$done, [hashtable]$ctx = @{}) { $st.jobs += @{ job = $job; done = $done; ctx = $ctx } }

function Complete-JpJobs {  # runs each finished job's callback with (reply, ctx)
    foreach ($j in @($st.jobs)) {
        if (-not (Test-JpJobDone $j.job)) { continue }
        $st.jobs = @($st.jobs | Where-Object { $_ -ne $j })
        & $j.done (Read-JpCore $j.job) $j.ctx
    }
}

function Stop-JpJobs {
    foreach ($j in $st.jobs) { if ($j.job.Http) { $j.job.Cts.Cancel() } elseif (-not $j.job.P.HasExited) { $j.job.P.Kill() } }
}

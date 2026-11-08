# Runs jpsnap_core.py (translate | tts) on the server over ssh, or locally when run_on is "pc", without blocking the UI:
# Start-JpCore returns a job, Add-JpJob registers what to do with its reply, and the UI timer calls Complete-JpJobs.
# stdin and stdout are ASCII (JSON + base64 in, JSON out), so no console code page touches them.

function Start-JpCore([string]$mode, [string]$stdin) {
    if ($cfg.run_on -eq 'pc') {
        $psi = New-Object Diagnostics.ProcessStartInfo "$dir\venv\Scripts\pythonw.exe"
        $psi.Arguments = "-I `"$dir\core\jpsnap_core.py`" $mode"
        $codex = Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\bin" -Recurse -Filter codex.exe -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($codex) { $psi.EnvironmentVariables['JPSNAP_CODEX'] = $codex.FullName }
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

function Read-JpCore($job) {  # -> @{ Ok; Text }
    $job.P.WaitForExit()
    $ok = $job.P.ExitCode -eq 0
    $text = if ($ok) { $job.Out.Result } else { "Failed (exit $($job.P.ExitCode)): $($job.Err.Result)$($job.Out.Result)".Trim() }
    @{ Ok = $ok; Text = $text }
}

function Start-JpTranslate([byte[]]$png, [bool]$fast) {
    $header = @{ key = (Unprotect-JpSecret $cfg.openai_api_key_dpapi); fast = $fast } | ConvertTo-Json -Compress
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
        if (-not $j.job.P.HasExited) { continue }
        $st.jobs = @($st.jobs | Where-Object { $_ -ne $j })
        & $j.done (Read-JpCore $j.job) $j.ctx
    }
}

function Stop-JpJobs { foreach ($j in $st.jobs) { if (-not $j.job.P.HasExited) { $j.job.P.Kill() } } }

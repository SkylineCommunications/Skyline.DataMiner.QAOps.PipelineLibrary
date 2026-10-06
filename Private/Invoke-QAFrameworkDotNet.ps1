function Invoke-QAFrameworkDotNet {
    <# Inferred helper: the single mockable seam for dotnet. It drains stdout/stderr concurrently, applies a timeout, kills the process tree, supports per-call environment overrides, and disposes process/resources. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [Parameter()][string]$WorkingDirectory = (Get-Location).ProviderPath,
        [Parameter()][hashtable]$Environment,
        [Parameter()][int]$TimeoutSeconds = 600
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'dotnet'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($arg in @($Arguments)) { [void]$psi.ArgumentList.Add($arg) }
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            if ($null -eq $Environment[$key]) { $psi.EnvironmentVariables.Remove([string]$key) } else { $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }
        }
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $stdout = New-Object System.Text.StringBuilder
    $stderr = New-Object System.Text.StringBuilder
    $outHandler = [System.Diagnostics.DataReceivedEventHandler]{ param($s,$e) if ($null -ne $e.Data) { [void]$stdout.AppendLine($e.Data) } }
    $errHandler = [System.Diagnostics.DataReceivedEventHandler]{ param($s,$e) if ($null -ne $e.Data) { [void]$stderr.AppendLine($e.Data) } }
    $timedOut = $false
    try {
        $p.add_OutputDataReceived($outHandler); $p.add_ErrorDataReceived($errHandler)
        if (-not $p.Start()) { throw 'Failed to start dotnet.' }
        $p.BeginOutputReadLine(); $p.BeginErrorReadLine()
        $waitMs = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds * 1000 } else { [int]::MaxValue }
        if (-not $p.WaitForExit($waitMs)) {
            $timedOut = $true
            try {
                if ($IsWindows -or $env:OS -eq 'Windows_NT') { & taskkill /T /F /PID $p.Id 2>$null | Out-Null } else { $p.Kill() }
            } catch { try { $p.Kill() } catch {} }
            $p.WaitForExit() | Out-Null
        } else { $p.WaitForExit() | Out-Null }
        [pscustomobject]@{ ExitCode = if ($timedOut) { -1 } else { $p.ExitCode }; StdOut = $stdout.ToString(); StdErr = $stderr.ToString(); TimedOut = $timedOut }
    }
    finally {
        try { $p.remove_OutputDataReceived($outHandler); $p.remove_ErrorDataReceived($errHandler) } catch {}
        $p.Dispose()
    }
}

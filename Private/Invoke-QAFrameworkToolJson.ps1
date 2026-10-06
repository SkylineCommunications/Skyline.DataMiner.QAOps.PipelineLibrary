function Invoke-QAFrameworkToolJson {
    <# Inferred helper: invokes qaops-qaframework and requires exactly one JSON stdout document, while preserving stderr as bounded failure context. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PipelineDirectory,[Parameter(Mandatory=$true)][string]$Operation,[Parameter(Mandatory=$true)][string[]]$Arguments,[Parameter()][hashtable]$Environment,[Parameter()][int]$TimeoutSeconds = 600)
    $effective = @('tool','run','qaops-qaframework','--') + @($Arguments)
    if (@($effective | Where-Object { $_ -eq '--json' }).Count -eq 0) { $effective += '--json' }
    $r = Invoke-QAFrameworkDotNet -Arguments $effective -WorkingDirectory $PipelineDirectory -Environment $Environment -TimeoutSeconds $TimeoutSeconds
    if ($r.TimedOut) { throw "QAFramework $Operation timed out after $TimeoutSeconds seconds." }
    if ($r.ExitCode -ne 0) { throw "QAFramework $Operation failed with exit code $($r.ExitCode): $(Limit-String $r.StdErr 4000)" }
    $text = $r.StdOut.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw "QAFramework $Operation produced no JSON output. Stderr: $(Limit-String $r.StdErr 4000)" }
    try { return $text | ConvertFrom-Json -ErrorAction Stop } catch { throw "QAFramework $Operation produced invalid JSON output: $($_.Exception.Message). Stderr: $(Limit-String $r.StdErr 4000)" }
}

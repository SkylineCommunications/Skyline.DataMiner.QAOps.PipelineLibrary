function Get-QAFrameworkExecutionOutcome {
    <#
    .SYNOPSIS
        Maps a finished bridge execution onto a QAOps test case outcome.
    .DESCRIPTION
        Ok            - the execution completed with exit code 0.
        NotApplicable - the test threw a NotSupportedException, which QAFramework uses to say
                        that a prerequisite is missing on this system.
        Fail          - anything else, including a failed, cancelled, rejected or timed out
                        execution.
    .PARAMETER Execution
        The finished execution object returned by the QAOps cmdlets.
    .PARAMETER MaximumMessageLength
        The maximum length of the message that is published with the result.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Execution,
        [int]$MaximumMessageLength = 2000
    )

    if ($null -eq $Execution) {
        return [pscustomobject]@{ Outcome = 'Fail'; Message = 'The execution could not be started or was lost.' }
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Execution.StandardOutput, $Execution.StandardError, $Execution.ErrorMessage)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $parts.Add(([string]$value).Trim()) }
    }

    $output = $parts -join [Environment]::NewLine
    $state = [string]$Execution.State
    $exitCode = $Execution.ExitCode

    if ($output -match 'NotSupportedException') {
        return [pscustomobject]@{
            Outcome = 'NotApplicable'
            Message = Limit-String -stringToLimit $output -maxCharacters $MaximumMessageLength
        }
    }

    if ([string]::Equals($state, 'Completed', [StringComparison]::OrdinalIgnoreCase) -and $exitCode -eq 0) {
        return [pscustomobject]@{
            Outcome = 'Ok'
            Message = Limit-String -stringToLimit $output -maxCharacters $MaximumMessageLength
        }
    }

    $reason = "Execution ended with state '$state'"
    if ($null -ne $exitCode) { $reason += " and exit code $exitCode" }
    $reason += '.'

    $message = if ([string]::IsNullOrWhiteSpace($output)) { $reason } else { $reason + [Environment]::NewLine + $output }

    return [pscustomobject]@{
        Outcome = 'Fail'
        Message = Limit-String -stringToLimit $message -maxCharacters $MaximumMessageLength
    }
}

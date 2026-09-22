function Join-QAFrameworkAgentPath {
    <#
    .SYNOPSIS
        Joins a path the way the agent expects it, not the way the orchestrator does.
    .DESCRIPTION
        The orchestrator can be a Linux QAOps Bridge while the DataMiner agents are Windows, so
        Join-Path would build a path with the wrong separator. This helper derives the
        separator from the base path instead: a base that looks like a Windows path keeps
        backslashes, anything else uses forward slashes.
    .PARAMETER Base
        The base path as reported by the agent.
    .PARAMETER Relative
        The relative path to append. Both separators are accepted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Base,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Relative
    )

    if ([string]::IsNullOrWhiteSpace($Base)) { return $Relative }
    if ([string]::IsNullOrWhiteSpace($Relative)) { return $Base }

    $isWindowsStyle = $Base -match '^[A-Za-z]:' -or $Base -match '^\\\\' -or ($Base.Contains('\') -and -not $Base.Contains('/'))
    $separator = if ($isWindowsStyle) { '\' } else { '/' }

    $left = $Base.TrimEnd('\', '/')
    $right = ($Relative -replace '[\\/]+', $separator).Trim('\', '/')

    return $left + $separator + $right
}

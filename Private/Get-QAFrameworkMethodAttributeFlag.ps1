function Get-QAFrameworkMethodAttributeFlag {
    <#
    .SYNOPSIS
        Detects failover method-level attributes in a QAFramework test source file.
    .DESCRIPTION
        BeforeSwitch, AfterSwitch and AfterSwitchBack are declared on methods, not on the
        test class, so they cannot be read from the class attribute block. This helper
        scans the whole source file for attribute lines carrying those names.

        AfterSwitchReInit and AfterSwitchBackReInit are deliberately not matched because
        the word boundary stops at the 'ReInit' suffix.
    .PARAMETER Path
        Path to the .cs file.
    .PARAMETER Content
        Raw source content, used instead of -Path.
    .OUTPUTS
        Hashtable with hasBeforeSwitch, hasAfterSwitch and hasAfterSwitchBack booleans.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'Content')]
        [AllowEmptyString()]
        [string]$Content
    )

    $flags = @{
        hasBeforeSwitch    = $false
        hasAfterSwitch     = $false
        hasAfterSwitchBack = $false
    }

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { return $flags }
        $Content = Get-Content -LiteralPath $Path -Raw
    }

    if ([string]::IsNullOrWhiteSpace($Content)) { return $flags }

    foreach ($line in ($Content -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('[')) { continue }

        if ($trimmed -match '\bBeforeSwitch\b') { $flags['hasBeforeSwitch'] = $true }
        if ($trimmed -match '\bAfterSwitchBack\b') { $flags['hasAfterSwitchBack'] = $true }
        if ($trimmed -match '\bAfterSwitch\b') { $flags['hasAfterSwitch'] = $true }
    }

    return $flags
}

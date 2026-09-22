function Test-QAFrameworkPreRunFilter {
    <#
    .SYNOPSIS
        Applies the legacy pre-run filter to a test name.
    .DESCRIPTION
        The legacy runner accepts three forms for the pre-run filter: 'all' runs every
        PreRunFixture, 'none' runs none of them and anything else is treated as a regular
        expression that is matched against the test name.

        An invalid regular expression is reported and treated as 'none' so a typo cannot
        silently run every pre-run test.
    .PARAMETER Name
        The name of the pre-run test.
    .PARAMETER Filter
        The configured pre-run filter.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Filter
    )

    if ([string]::IsNullOrWhiteSpace($Filter)) { return $true }

    $value = $Filter.Trim()
    if ([string]::Equals($value, 'all', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ([string]::Equals($value, 'none', [StringComparison]::OrdinalIgnoreCase)) { return $false }

    try {
        return [regex]::IsMatch([string]$Name, $value, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    catch {
        Write-Warning "The pre-run filter '$value' is not a valid regular expression: $($_.Exception.Message). No pre-run test is scheduled."
        return $false
    }
}

function Test-QAFrameworkHarvestFilter {
    <#
    .SYNOPSIS
        Decides whether a discovered test is harvested into the test package.
    .DESCRIPTION
        Only the filters that can be evaluated at harvest time are applied here: the
        allow list, the baseline gate and the keyword and squad filters. Everything that
        depends on the cluster the package will run on (version, database, centralized,
        failover, ...) stays a runtime decision of Select-QAFrameworkTest.
    .PARAMETER Test
        The schema v1 metadata object of the test.
    .PARAMETER OnlyTests
        When not empty only these test names are harvested.
    .PARAMETER ForceOnlyTests
        Harvest the tests of -OnlyTests without applying any other filter.
    .PARAMETER BaselineGate
        Required harvests only baseline tests, Additive harvests baseline tests on top of
        the other filters and Disabled ignores the baseline flag.
    .PARAMETER Keywords
        Only harvest tests carrying one of these keywords.
    .PARAMETER ExcludeKeywords
        Do not harvest tests carrying one of these keywords.
    .PARAMETER Squads
        Only harvest tests of one of these squads.
    .PARAMETER ExcludeSquads
        Do not harvest tests of one of these squads.
    .PARAMETER IncludeDisabled
        Harvest tests that carry a Disabled attribute with a reason. They are always kept
        in the metadata; this switch decides whether a script is generated for them.
    .OUTPUTS
        PSCustomObject with Include and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Test,

        [Parameter()][string[]]$OnlyTests = @(),
        [Parameter()][switch]$ForceOnlyTests,
        [Parameter()][ValidateSet('Required', 'Additive', 'Disabled')][string]$BaselineGate = 'Disabled',
        [Parameter()][string[]]$Keywords = @(),
        [Parameter()][string[]]$ExcludeKeywords = @(),
        [Parameter()][string[]]$Squads = @(),
        [Parameter()][string[]]$ExcludeSquads = @(),
        [Parameter()][switch]$IncludeDisabled
    )

    $include = { param([string]$Reason) [pscustomobject]@{ Include = $true; Reason = $Reason } }
    $exclude = { param([string]$Reason) [pscustomobject]@{ Include = $false; Reason = $Reason } }

    $only = @($OnlyTests | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($only.Count -gt 0) {
        if ($only -notcontains $Test.name) {
            return & $exclude "The test is not in the -OnlyTests list."
        }
        if ($ForceOnlyTests) {
            return & $include 'The test is in the -OnlyTests list and -ForceOnlyTests is used.'
        }
    }

    $isBaseline = [bool]$Test.isBaseline

    if ($BaselineGate -eq 'Required' -and -not $isBaseline) {
        return & $exclude 'The test is not a baseline test.'
    }

    if (-not $IncludeDisabled -and $Test.disabled -and -not [string]::IsNullOrWhiteSpace($Test.disabled.reason)) {
        return & $exclude "The test is disabled: $($Test.disabled.reason)"
    }

    if ($BaselineGate -eq 'Additive' -and $isBaseline) {
        return & $include 'The test is a baseline test.'
    }

    $keywordFilter = Resolve-QAFrameworkFilterList -Include $Keywords -Exclude $ExcludeKeywords
    $squadFilter = Resolve-QAFrameworkFilterList -Include $Squads -Exclude $ExcludeSquads

    $testKeywords = [string[]]@($Test.keywords)
    $testSquads = [string[]]@($Test.squads)

    if ($keywordFilter.Include.Count -gt 0 -and -not (Test-QAFrameworkListMatch -Value $testKeywords -Filter $keywordFilter.Include)) {
        return & $exclude "Test keywords [$($testKeywords -join ', ')] do not match the harvest keywords [$($keywordFilter.Include -join ', ')]."
    }

    if ($keywordFilter.Exclude.Count -gt 0 -and (Test-QAFrameworkListMatch -Value $testKeywords -Filter $keywordFilter.Exclude)) {
        return & $exclude "Test keywords [$($testKeywords -join ', ')] match an excluded harvest keyword."
    }

    if ($squadFilter.Include.Count -gt 0 -and -not (Test-QAFrameworkListMatch -Value $testSquads -Filter $squadFilter.Include)) {
        return & $exclude "Test squads [$($testSquads -join ', ')] do not match the harvest squads [$($squadFilter.Include -join ', ')]."
    }

    if ($squadFilter.Exclude.Count -gt 0 -and (Test-QAFrameworkListMatch -Value $testSquads -Filter $squadFilter.Exclude)) {
        return & $exclude "Test squads [$($testSquads -join ', ')] match an excluded harvest squad."
    }

    return & $include 'The test matches the harvest filters.'
}

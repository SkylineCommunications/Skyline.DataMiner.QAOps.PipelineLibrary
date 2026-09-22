function Test-QAFrameworkSolutionCompatible {
    <#
    .SYNOPSIS
        Determines whether the cluster satisfies the SolutionInfo attribute of a test.
    .DESCRIPTION
        The legacy runner only carried SolutionInfo as metadata because the scheduler had no
        way to know which solutions were installed. A QAOps cluster does report them, so the
        gate is enforced whenever the cluster supplies at least one solution version.

        When the cluster reports no solution versions at all the test is kept, so a cluster
        that does not implement the contract yet never silently loses tests.
    .PARAMETER SolutionVersions
        A dictionary of solution name to installed version, from Get-QAFrameworkClusterTopology.
    .PARAMETER Test
        A schema v1 test metadata object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][object]$SolutionVersions,
        [Parameter(Mandatory = $true)][object]$Test
    )

    $compatible = [pscustomobject]@{ IsCompatible = $true; Reason = '' }

    $name = if ($Test.solution) { [string]$Test.solution.name } else { '' }
    if ([string]::IsNullOrWhiteSpace($name) -or $name -eq 'None') { return $compatible }

    $map = @{}
    if ($SolutionVersions -is [System.Collections.IDictionary]) {
        foreach ($key in $SolutionVersions.Keys) { $map[[string]$key] = $SolutionVersions[$key] }
    }
    elseif ($null -ne $SolutionVersions) {
        foreach ($property in $SolutionVersions.PSObject.Properties) { $map[$property.Name] = $property.Value }
    }

    # The cluster does not report solutions, so nothing can be excluded on that basis.
    if ($map.Count -eq 0) { return $compatible }

    $installedKey = $map.Keys | Where-Object { [string]::Equals($_, $name, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if (-not $installedKey) {
        return [pscustomobject]@{ IsCompatible = $false; Reason = "Solution '$name' is not installed on the cluster." }
    }

    $minimum = if ($Test.solution) { [string]$Test.solution.minVersion } else { '' }
    if ([string]::IsNullOrWhiteSpace($minimum)) { return $compatible }

    $required = [version]::new()
    if (-not [version]::TryParse($minimum, [ref]$required)) {
        Write-Warning "Test '$($Test.name)' declares an unparsable minimum solution version '$minimum'; the solution version gate is skipped."
        return $compatible
    }

    $installed = [version]::new()
    if (-not [version]::TryParse([string]$map[$installedKey], [ref]$installed)) {
        Write-Warning "Cluster reports an unparsable version '$($map[$installedKey])' for solution '$name'; the solution version gate is skipped."
        return $compatible
    }

    if ($installed -lt $required) {
        return [pscustomobject]@{ IsCompatible = $false; Reason = "Solution '$name' version $installed is older than the required $required." }
    }

    return $compatible
}

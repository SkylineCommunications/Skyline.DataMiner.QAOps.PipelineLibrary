function ConvertTo-QAFrameworkVersion {
    <#
    .SYNOPSIS
        Converts a QAFramework minimum version string into a comparable version.
    .DESCRIPTION
        Port of TestFilter.ConvertStringToVersion. The legacy format is
        'major.minor.build-CU<number>' where the CU number becomes the revision, so
        '10.1.0.0-CU5' turns into 10.1.0.5.

        The legacy implementation throws when the '-CU' part is missing, which is how
        malformed attribute values are surfaced to the test owner; that behaviour is kept.
    .PARAMETER Version
        The version string to convert.
    .OUTPUTS
        System.Version
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw "The given version is invalid: '$Version', it needs to be in the following format: x.x.x-CU<number>"
    }

    if ($Version -notmatch '-') {
        throw "The given version is invalid: '$Version', it needs to be in the following format: x.x.x-CU<number>"
    }

    $split = $Version.Split('-')
    if ($split.Count -lt 2 -or $split.Count -gt 3) {
        throw "The given version is invalid: '$Version', it needs to be in the following format: x.x.x-CU<number>"
    }

    $cuPart = @($split | Where-Object { $_ -match '(?i)CU' })
    if ($cuPart.Count -ne 1) {
        throw "The given version is invalid: '$Version', it needs to be in the following format: x.x.x-CU<number>"
    }

    $numbers = $split[0].Split('.')
    if ($numbers.Count -lt 3) {
        throw "The given version is invalid: '$Version', it needs to be in the following format: x.x.x-CU<number>"
    }

    $cuNumber = $cuPart[0].Substring($cuPart[0].IndexOf('CU', [StringComparison]::OrdinalIgnoreCase) + 2)

    return [version]::new([int]$numbers[0], [int]$numbers[1], [int]$numbers[2], [int]$cuNumber)
}

function Test-QAFrameworkIsMainRelease {
    <#
    .SYNOPSIS
        Determines whether a DataMiner version is a main release.
    .DESCRIPTION
        Port of TestFilter.IsMainRelease: on a main release the third number is always 0.
    .PARAMETER DataMinerVersion
        The DataMiner version.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [version]$DataMinerVersion
    )

    return ($DataMinerVersion.Build -eq 0)
}

function Test-QAFrameworkSameReleasePath {
    <#
    .SYNOPSIS
        Determines whether two versions are on the same release path.
    .DESCRIPTION
        Port of TestFilter.SameReleasePath: identical major and minor numbers.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][version]$Source,
        [Parameter(Mandatory = $true)][version]$ToCheck
    )

    return ($Source.Major -eq $ToCheck.Major -and $Source.Minor -eq $ToCheck.Minor)
}

function Test-QAFrameworkFeatureReleaseCompatible {
    <#
    .SYNOPSIS
        Feature release version gate.
    .DESCRIPTION
        Port of TestFilter.FeatureReleaseCompatible. A test without a minimum feature
        version is always compatible.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][version]$DataMinerVersion,
        [AllowEmptyString()][AllowNull()][string]$MinimalFeatureVersion
    )

    if ([string]::IsNullOrWhiteSpace($MinimalFeatureVersion)) { return $true }

    $minimum = ConvertTo-QAFrameworkVersion -Version $MinimalFeatureVersion
    return ($DataMinerVersion -ge $minimum)
}

function Test-QAFrameworkMainReleaseCompatible {
    <#
    .SYNOPSIS
        Main release version gate.
    .DESCRIPTION
        Port of TestFilter.MainReleaseCompatible. A test that declares a next main version
        runs as soon as the agent reached it. When the agent sits on the same release path
        as that next main version but has not reached it, the test is not compatible.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][version]$DataMinerVersion,
        [AllowEmptyString()][AllowNull()][string]$MinimalMainVersion,
        [AllowEmptyString()][AllowNull()][string]$MinimalNextMainVersion
    )

    $main = if ([string]::IsNullOrWhiteSpace($MinimalMainVersion)) { [version]::new() } else { ConvertTo-QAFrameworkVersion -Version $MinimalMainVersion }
    $nextMain = if ([string]::IsNullOrWhiteSpace($MinimalNextMainVersion)) { [version]::new() } else { ConvertTo-QAFrameworkVersion -Version $MinimalNextMainVersion }

    if (-not [string]::IsNullOrWhiteSpace($MinimalNextMainVersion) -and $DataMinerVersion -ge $nextMain) {
        return $true
    }

    if (Test-QAFrameworkSameReleasePath -Source $nextMain -ToCheck $DataMinerVersion) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($MinimalMainVersion)) {
        return $false
    }

    return ($DataMinerVersion -ge $main)
}

function Test-QAFrameworkVersionCompatible {
    <#
    .SYNOPSIS
        Determines whether a test may run on the given DataMiner version.
    .DESCRIPTION
        Port of TestFilter.ValidateVersion. When the test declares a main or next-main
        minimum version and the agent runs a main release, the main release rules apply;
        otherwise the feature release rule applies.

        As in the legacy runner, a malformed version attribute makes the test ineligible
        instead of failing the whole run.
    .PARAMETER DataMinerVersion
        The DataMiner version of the cluster.
    .PARAMETER Test
        A schema v1 test metadata object.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][version]$DataMinerVersion,
        [Parameter(Mandatory = $true)][object]$Test
    )

    $minVersion = $Test.minVersion
    $feature = if ($minVersion) { [string]$minVersion.featureRelease } else { '' }
    $main = if ($minVersion) { [string]$minVersion.mainRelease } else { '' }
    $nextMain = if ($minVersion) { [string]$minVersion.nextMainRelease } else { '' }

    try {
        $hasMainRequirement = -not ([string]::IsNullOrWhiteSpace($main) -and [string]::IsNullOrWhiteSpace($nextMain))

        if ($hasMainRequirement -and (Test-QAFrameworkIsMainRelease -DataMinerVersion $DataMinerVersion)) {
            return Test-QAFrameworkMainReleaseCompatible -DataMinerVersion $DataMinerVersion -MinimalMainVersion $main -MinimalNextMainVersion $nextMain
        }

        return Test-QAFrameworkFeatureReleaseCompatible -DataMinerVersion $DataMinerVersion -MinimalFeatureVersion $feature
    }
    catch {
        Write-Warning "Problem during validation of the version on test '$($Test.name)': $($_.Exception.Message). Please verify the MinVersion attribute. The test will not be executed."
        return $false
    }
}

function Test-QAFrameworkLocalDbCompatible {
    <#
    .SYNOPSIS
        Determines whether a test may run against the cluster database.
    .DESCRIPTION
        Port of TestFilter.DbFilter: a test without LocalDB entries supports every
        database. Comparison is case-insensitive on the DBMSType member name.
    .PARAMETER ClusterDbmsType
        The DBMSType name reported by the cluster.
    .PARAMETER Test
        A schema v1 test metadata object.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][AllowNull()][string]$ClusterDbmsType,
        [Parameter(Mandatory = $true)][object]$Test
    )

    $localDbs = @($Test.localDbs)
    if ($localDbs.Count -eq 0) { return $true }

    # The cluster database is unknown, so no test can be excluded on that basis.
    if ([string]::IsNullOrWhiteSpace($ClusterDbmsType)) { return $true }

    foreach ($db in $localDbs) {
        if ([string]::Equals([string]$db, $ClusterDbmsType, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    return $false
}

function New-QAFrameworkTestMetadata {
    <#
    .SYNOPSIS
        Builds a schema v1 QAFramework test metadata object for a single test.
    .DESCRIPTION
        Merges the values found in the C# class attribute block with the values found in
        the legacy .meta file and fills every remaining field with the legacy default.
        Attribute values always win; the .meta file only fills gaps, which keeps legacy
        RTManager tests (that carry no attributes at all) working.
    .PARAMETER CsPath
        Path to the test .cs file. Optional for legacy .meta-only tests.
    .PARAMETER MetaPath
        Path to the .meta file. Optional for attribute-only tests.
    .PARAMETER ClassName
        Restricts the attribute block lookup to a specific class in the .cs file.
    .PARAMETER Name
        Fallback test name when no fixture attribute supplies one.
    .PARAMETER RegressionTestsRoot
        Root used to make the source paths in the output relative.
    .PARAMETER FolderTag
        Automation script folder tag, e.g. 'QAOps\MyPackage\Team\Test'.
    .OUTPUTS
        PSCustomObject following schema v1.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$CsPath,
        [string]$MetaPath,
        [string]$ClassName,
        [string]$Name,
        [string]$RegressionTestsRoot,
        [string]$FolderTag
    )

    $fromAttributes = @{}
    $methodFlags = @{ hasBeforeSwitch = $false; hasAfterSwitch = $false; hasAfterSwitchBack = $false }

    if ($CsPath -and (Test-Path -LiteralPath $CsPath)) {
        $content = Get-Content -LiteralPath $CsPath -Raw

        $blockParams = @{ Content = $content }
        if ($ClassName) { $blockParams['ClassName'] = $ClassName }
        $block = Get-QAFrameworkClassAttributeBlock @blockParams

        if ($block) { $fromAttributes = ConvertFrom-QAFrameworkAttributeBlock -Block $block }
        $methodFlags = Get-QAFrameworkMethodAttributeFlag -Content $content
    }

    $fromMeta = @{}
    if ($MetaPath -and (Test-Path -LiteralPath $MetaPath)) {
        $fromMeta = ConvertFrom-QAFrameworkMetaFile -Path $MetaPath
    }

    # Attributes win, .meta fills the gaps.
    $merged = @{}
    foreach ($key in $fromMeta.Keys) { $merged[$key] = $fromMeta[$key] }
    foreach ($key in $fromAttributes.Keys) { $merged[$key] = $fromAttributes[$key] }

    $resolvedName = $merged['name']
    if ([string]::IsNullOrWhiteSpace($resolvedName)) { $resolvedName = $Name }
    if ([string]::IsNullOrWhiteSpace($resolvedName) -and $CsPath) { $resolvedName = [IO.Path]::GetFileNameWithoutExtension($CsPath) }
    if ([string]::IsNullOrWhiteSpace($resolvedName) -and $MetaPath) { $resolvedName = [IO.Path]::GetFileNameWithoutExtension($MetaPath) }

    $fixture = if ($merged.ContainsKey('fixture')) { $merged['fixture'] } else { 'Standard' }

    $failover = $null
    if ($fixture -eq 'Failover') {
        $failover = if ($merged.ContainsKey('failover')) { $merged['failover'].Clone() } else {
            @{ runDirectBeforeSwitch = $false; runDirectAfterSwitch = $false; runOnNonFailoverSystems = $false }
        }
        foreach ($key in $methodFlags.Keys) { $failover[$key] = $methodFlags[$key] }
        $failover = [pscustomobject]$failover
    }

    $diagnosticRunType = $null
    if ($fixture -eq 'Diagnostic') {
        $diagnosticRunType = if ($merged.ContainsKey('diagnosticRunType')) { $merged['diagnosticRunType'] } else { 'BeforeAndAfter' }
    }

    $disabled = $null
    if ($merged.ContainsKey('disabled') -and $merged['disabled']) {
        $disabled = [pscustomobject]@{ reason = [string]$merged['disabled']['reason'] }
    }

    $minVersion = if ($merged.ContainsKey('minVersion')) {
        [pscustomobject]$merged['minVersion']
    }
    else {
        [pscustomobject]@{ featureRelease = ''; nextMainRelease = ''; mainRelease = '' }
    }

    $solution = if ($merged.ContainsKey('solution')) {
        [pscustomobject]$merged['solution']
    }
    else {
        [pscustomobject]@{ name = 'None'; minVersion = '0.0.0' }
    }

    $arrayKeys = @('keywords', 'squads', 'maintainers', 'customers', 'localDbs', 'dcpIds', 'rnIds', 'projectIds', 'dllReferences')
    $arrays = @{}
    foreach ($key in $arrayKeys) {
        $values = [string[]]@()
        if ($merged.ContainsKey($key) -and $null -ne $merged[$key]) {
            $values = [string[]]@($merged[$key])
        }
        $arrays[$key] = $values
    }

    $getBool = {
        param([string]$Key, [bool]$Default)
        if ($merged.ContainsKey($Key) -and $null -ne $merged[$Key]) { [bool]$merged[$Key] } else { $Default }
    }

    $relative = {
        param([string]$FullPath)
        if (-not $FullPath) { return $null }
        if ($RegressionTestsRoot) {
            try {
                $root = (Resolve-Path -LiteralPath $RegressionTestsRoot -ErrorAction Stop).ProviderPath
                $full = (Resolve-Path -LiteralPath $FullPath -ErrorAction Stop).ProviderPath
                if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                    return $full.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                }
            }
            catch {
                # The path could not be resolved, so the full path is returned as is.
            }
        }
        return $FullPath
    }

    return [pscustomobject]@{
        name                 = $resolvedName
        fixture              = $fixture
        diagnosticRunType    = $diagnosticRunType
        failover             = $failover
        disabled             = $disabled
        weight               = if ($merged.ContainsKey('weight')) { [int]$merged['weight'] } else { 1 }
        canRunConcurrently   = & $getBool 'canRunConcurrently' $true
        targetDma            = if ($merged.ContainsKey('targetDma')) { [string]$merged['targetDma'] } else { 'One' }
        keywords             = $arrays['keywords']
        squads               = $arrays['squads']
        maintainers          = $arrays['maintainers']
        customers            = $arrays['customers']
        minVersion           = $minVersion
        localDbs             = $arrays['localDbs']
        solution             = $solution
        isCentralizedOnly    = & $getBool 'isCentralizedOnly' $false
        isNonCentralizedOnly = & $getBool 'isNonCentralizedOnly' $false
        isRedGreen           = & $getBool 'isRedGreen' $false
        isBaseline           = & $getBool 'isBaseline' $false
        isLeakTest           = & $getBool 'isLeakTest' $false
        dcpIds               = $arrays['dcpIds']
        rnIds                = $arrays['rnIds']
        projectIds           = $arrays['projectIds']
        source               = [pscustomobject]@{
            cs        = & $relative $CsPath
            meta      = & $relative $MetaPath
            folderTag = $FolderTag
        }
        dllReferences        = $arrays['dllReferences']
    }
}

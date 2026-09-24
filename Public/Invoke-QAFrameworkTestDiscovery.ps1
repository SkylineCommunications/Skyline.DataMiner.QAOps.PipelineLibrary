function Invoke-QAFrameworkTestDiscovery {
    <#
    .SYNOPSIS
        Harvests QAFramework tests by invoking the standalone orchestrator.
    .DESCRIPTION
        Installs or updates the package-local QAFramework tool and runs its discover command.
        Attribute parsing, filtering, metadata generation, and dependency harvesting are owned
        by Skyline.DataMiner.QAOps.QAFrameworkOrchestrator.
    .PARAMETER TestPackageContentPath
        Test package content root, or its TestHarvesting directory.
    .PARAMETER RegressionTestsRoot
        RegressionTests source directory. A relative path is resolved from TestHarvesting.
    .PARAMETER FolderTagPrefix
        Override for the generated automation script folder tag prefix.
    .PARAMETER OnlyTests
        Pin these test names in the harvest selection.
    .PARAMETER ForceOnlyTests
        Select only -OnlyTests, bypassing the package's other source filters.
    .PARAMETER BaselineGate
        Override the baseline selection gate.
    .PARAMETER Keywords
        Override the keyword selection. A value prefixed with ! is treated as an exclusion.
    .PARAMETER ExcludeKeywords
        Override keyword exclusions.
    .PARAMETER Squads
        Override the squad selection. A value prefixed with ! is treated as an exclusion.
    .PARAMETER ExcludeSquads
        Override squad exclusions.
    .PARAMETER IncludeDisabled
        Include disabled tests that otherwise match the active source selection.
    .PARAMETER ConfigPath
        Explicit unified or supported legacy QAFramework configuration file.
    .PARAMETER SupplementaryFilesPath
        Validated supplementary-files directory used for configuration overrides.
    .PARAMETER SkipDependencies
        Unsupported. The orchestrator always writes its complete dependency snapshot.
    .EXAMPLE
        Invoke-QAFrameworkTestDiscovery -TestPackageContentPath (Resolve-Path "$PSScriptRoot\..")
    .OUTPUTS
        The JSON discovery report returned by the orchestrator.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TestPackageContentPath,

        [Parameter()]
        [string]$RegressionTestsRoot,

        [Parameter()]
        [string]$FolderTagPrefix,

        [Parameter()]
        [string[]]$OnlyTests,

        [Parameter()]
        [switch]$ForceOnlyTests,

        [Parameter()]
        [ValidateSet('Required', 'Additive', 'Disabled')]
        [string]$BaselineGate,

        [Parameter()]
        [string[]]$Keywords,

        [Parameter()]
        [string[]]$ExcludeKeywords,

        [Parameter()]
        [string[]]$Squads,

        [Parameter()]
        [string[]]$ExcludeSquads,

        [Parameter()]
        [switch]$IncludeDisabled,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$SupplementaryFilesPath,

        [Parameter()]
        [switch]$SkipDependencies
    )

    if ($SkipDependencies) {
        throw '-SkipDependencies is no longer supported. QAFramework discovery writes the dependency snapshot required by the orchestrator.'
    }
    if ($ForceOnlyTests -and (-not $PSBoundParameters.ContainsKey('OnlyTests') -or @($OnlyTests).Count -eq 0)) {
        throw '-ForceOnlyTests requires at least one -OnlyTests name.'
    }

    $paths = Resolve-QAFrameworkContentPath -Path $TestPackageContentPath
    if (-not $PSCmdlet.ShouldProcess($paths.ContentPath, 'Discover QAFramework tests')) {
        return
    }

    $configPathResolved = $null
    $legacyDiscoveryConfig = $null
    $packageConfigInfo = Get-QAFrameworkPackageConfigInfo -ContentPath $paths.ContentPath
    if ($PSBoundParameters.ContainsKey('ConfigPath')) {
        $resolvedConfig = Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop
        if ($resolvedConfig.Provider.Name -ne 'FileSystem' -or -not (Test-Path -LiteralPath $resolvedConfig.ProviderPath -PathType Leaf)) {
            throw "ConfigPath must be an existing file: $ConfigPath"
        }

        $configPathResolved = $resolvedConfig.ProviderPath
        if ((Split-Path -Leaf $configPathResolved) -ieq 'qaframework.discovery.json') {
            try {
                $explicitConfig = Get-Content -LiteralPath $configPathResolved -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                throw "Could not read legacy QAFramework discovery configuration '$configPathResolved': $($_.Exception.Message)"
            }

            if ($explicitConfig -is [pscustomobject] -and $explicitConfig.PSObject.Properties.Name -notcontains 'schemaVersion') {
                $legacyDiscoveryConfig = ConvertFrom-QAFrameworkLegacyDiscoveryConfig -Document $explicitConfig
                $configPathResolved = $null
            }
        }
    }
    else {
        $legacyDiscoveryPath = Join-Path $paths.HarvestPath 'qaframework.discovery.json'
        $allowLegacyDiscoveryConfig = $null -eq $packageConfigInfo -or $packageConfigInfo.Policy -eq 'LegacyPipeline'
        if ($allowLegacyDiscoveryConfig -and (Test-Path -LiteralPath $legacyDiscoveryPath -PathType Leaf)) {
            try {
                $legacyDiscoveryDocument = Get-Content -LiteralPath $legacyDiscoveryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                throw "Could not read legacy QAFramework discovery configuration '$legacyDiscoveryPath': $($_.Exception.Message)"
            }
            $legacyDiscoveryConfig = ConvertFrom-QAFrameworkLegacyDiscoveryConfig -Document $legacyDiscoveryDocument
        }
    }

    $supplementaryPathResolved = $null
    if ($PSBoundParameters.ContainsKey('SupplementaryFilesPath')) {
        $resolvedSupplementaryPath = Resolve-Path -LiteralPath $SupplementaryFilesPath -ErrorAction Stop
        if ($resolvedSupplementaryPath.Provider.Name -ne 'FileSystem' -or -not (Test-Path -LiteralPath $resolvedSupplementaryPath.ProviderPath -PathType Container)) {
            throw "SupplementaryFilesPath must be an existing directory: $SupplementaryFilesPath"
        }
        $supplementaryPathResolved = $resolvedSupplementaryPath.ProviderPath
    }

    $regressionTestsRoot = if ($PSBoundParameters.ContainsKey('RegressionTestsRoot')) {
        $RegressionTestsRoot
    }
    elseif ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains('regressionTestsRoot')) {
        [string]$legacyDiscoveryConfig['regressionTestsRoot']
    }
    else {
        $null
    }
    $sourcePath = $null
    if (-not [string]::IsNullOrWhiteSpace($regressionTestsRoot)) {
        $sourcePath = if ([System.IO.Path]::IsPathRooted($regressionTestsRoot)) {
            [System.IO.Path]::GetFullPath($regressionTestsRoot)
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path $paths.HarvestPath $regressionTestsRoot))
        }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
            throw "RegressionTestsRoot does not exist: $sourcePath"
        }
    }
    elseif ($PSBoundParameters.ContainsKey('RegressionTestsRoot')) {
        throw 'RegressionTestsRoot cannot be empty.'
    }

    $overrides = @{}
    $filter = @{}
    if ($legacyDiscoveryConfig -or (-not $PSBoundParameters.ContainsKey('ConfigPath') -and $null -eq $packageConfigInfo)) {
        $overrides['selectionPolicy'] = 'LegacyPipeline'
    }

    $hasOnlyTests = $PSBoundParameters.ContainsKey('OnlyTests') `
        -or ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains('onlyTests'))
    $onlyTests = if ($PSBoundParameters.ContainsKey('OnlyTests')) {
        [string[]]@($OnlyTests)
    }
    elseif ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains('onlyTests')) {
        [string[]]@($legacyDiscoveryConfig['onlyTests'])
    }
    else {
        [string[]]@()
    }
    if ($hasOnlyTests) {
        if (@($onlyTests | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'OnlyTests cannot contain empty names.'
        }
        $filter['includedTests'] = $onlyTests
    }

    $forceOnlyTests = if ($PSBoundParameters.ContainsKey('ForceOnlyTests')) {
        [bool]$ForceOnlyTests
    }
    elseif ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains('forceOnlyTests')) {
        [bool]$legacyDiscoveryConfig['forceOnlyTests']
    }
    else {
        $false
    }
    if ($forceOnlyTests -and (-not $hasOnlyTests -or $onlyTests.Count -eq 0)) {
        throw '-ForceOnlyTests requires at least one -OnlyTests name.'
    }

    $effectiveBaselineGate = if ($PSBoundParameters.ContainsKey('BaselineGate')) {
        $BaselineGate
    }
    elseif ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains('baselineGate')) {
        [string]$legacyDiscoveryConfig['baselineGate']
    }
    else {
        $null
    }
    if ($null -ne $effectiveBaselineGate) { $filter['baselineGate'] = $effectiveBaselineGate }

    foreach ($selection in @(
        @{ Parameter = 'Keywords'; LegacyKey = 'keywords'; IncludeKey = 'keywords'; ExcludeKey = 'excludeKeywords'; ExcludeParameter = 'ExcludeKeywords' },
        @{ Parameter = 'Squads'; LegacyKey = 'squads'; IncludeKey = 'squads'; ExcludeKey = 'excludeSquads'; ExcludeParameter = 'ExcludeSquads' }
    )) {
        $includeSpecified = $PSBoundParameters.ContainsKey($selection.Parameter) `
            -or ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains($selection.LegacyKey))
        $rawValues = if ($PSBoundParameters.ContainsKey($selection.Parameter)) {
            [string[]]@($PSBoundParameters[$selection.Parameter])
        }
        elseif ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains($selection.LegacyKey)) {
            [string[]]@($legacyDiscoveryConfig[$selection.LegacyKey])
        }
        else {
            [string[]]@()
        }

        $includes = [System.Collections.Generic.List[string]]::new()
        $bangExcludes = [System.Collections.Generic.List[string]]::new()
        foreach ($value in $rawValues) {
            if ([string]::IsNullOrWhiteSpace($value)) { throw "$($selection.Parameter) cannot contain empty values." }
            if ($value.StartsWith('!') -and $value.Length -gt 1) {
                $bangExcludes.Add($value.Substring(1))
            }
            else {
                $includes.Add($value)
            }
        }
        if ($includeSpecified) { $filter[$selection.IncludeKey] = [string[]]$includes }

        $excludeSpecified = $PSBoundParameters.ContainsKey($selection.ExcludeParameter) `
            -or ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains($selection.ExcludeKey))
        $excludes = [System.Collections.Generic.List[string]]::new()
        if ($PSBoundParameters.ContainsKey($selection.ExcludeParameter)) {
            $excludes.AddRange([string[]]@($PSBoundParameters[$selection.ExcludeParameter]))
        }
        elseif ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains($selection.ExcludeKey)) {
            $excludes.AddRange([string[]]@($legacyDiscoveryConfig[$selection.ExcludeKey]))
        }
        $excludes.AddRange([string[]]$bangExcludes)
        if ($excludeSpecified -or $bangExcludes.Count -gt 0) {
            if (@($excludes | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
                throw "$($selection.ExcludeParameter) cannot contain empty values."
            }
            $filter[$selection.ExcludeKey] = [string[]]$excludes
        }
    }

    $effectiveFolderTagPrefix = if ($PSBoundParameters.ContainsKey('FolderTagPrefix')) {
        $FolderTagPrefix
    }
    elseif ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains('folderTagPrefix')) {
        [string]$legacyDiscoveryConfig['folderTagPrefix']
    }
    else {
        $null
    }
    if ($null -ne $effectiveFolderTagPrefix) {
        if ([string]::IsNullOrWhiteSpace($effectiveFolderTagPrefix)) { throw 'FolderTagPrefix cannot be empty.' }
        $overrides['discovery'] = @{ folderTagPrefix = $effectiveFolderTagPrefix }
    }

    if ($forceOnlyTests) {
        $filter['mode'] = 'AttributeOnly'
        $filter['baselineGate'] = 'Disabled'
        $filter['keywords'] = [string[]]@()
        $filter['squads'] = [string[]]@()
        $filter['where'] = $null
        $filter['excludeKeywords'] = [string[]]@()
        $filter['excludeSquads'] = [string[]]@()
        $filter['excludedTests'] = [string[]]@()
        $filter['customers'] = [string[]]@()
    }

    if ($filter.Count -gt 0) {
        $overrides['filter'] = $filter
    }

    $includeDisabled = if ($PSBoundParameters.ContainsKey('IncludeDisabled')) {
        [bool]$IncludeDisabled
    }
    elseif ($legacyDiscoveryConfig -and $legacyDiscoveryConfig.Contains('includeDisabled')) {
        [bool]$legacyDiscoveryConfig['includeDisabled']
    }
    else {
        $false
    }
    if (-not $includeDisabled -and $PSBoundParameters.ContainsKey('IncludeDisabled')) {
        $filter['includedDisabledTests'] = [string[]]@()
        $overrides['filter'] = $filter
    }

    $requestFiles = [System.Collections.Generic.List[string]]::new()
    try {
        $null = Install-QAFrameworkTool -PipelineDirectory $paths.PipelinePath

        $requestPath = New-QAFrameworkRequestFile -Overrides $overrides
        if ($requestPath) { $requestFiles.Add($requestPath) }

        if ($includeDisabled) {
            $previewArguments = @('preview', '--content', $paths.ContentPath, '--include-disabled')
            if ($configPathResolved) { $previewArguments += @('--config', $configPathResolved) }
            if ($sourcePath) { $previewArguments += @('--source', $sourcePath) }
            if ($supplementaryPathResolved) { $previewArguments += @('--supplementary-path', $supplementaryPathResolved) }
            if ($requestPath) { $previewArguments += @('--request-file', $requestPath) }

            $preview = Invoke-QAFrameworkToolJson -PipelineDirectory $paths.PipelinePath -Operation 'preview' -Arguments $previewArguments
            if ($null -eq $preview.disabledCandidates) {
                throw 'QAFramework preview did not return disabledCandidates; disabled tests were not harvested.'
            }

            $disabledNames = [string[]]@(
                $preview.disabledCandidates |
                    ForEach-Object { [string]$_.name } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            $filter['includedDisabledTests'] = $disabledNames
            $overrides['filter'] = $filter
            $requestPath = New-QAFrameworkRequestFile -Overrides $overrides
            if ($requestPath) { $requestFiles.Add($requestPath) }
        }

        $discoverArguments = @('discover', '--content', $paths.ContentPath)
        if ($configPathResolved) { $discoverArguments += @('--config', $configPathResolved) }
        if ($sourcePath) { $discoverArguments += @('--source', $sourcePath) }
        if ($supplementaryPathResolved) { $discoverArguments += @('--supplementary-path', $supplementaryPathResolved) }
        if ($requestPath) { $discoverArguments += @('--request-file', $requestPath) }

        return Invoke-QAFrameworkToolJson -PipelineDirectory $paths.PipelinePath -Operation 'discover' -Arguments $discoverArguments
    }
    finally {
        foreach ($requestFile in $requestFiles) {
            if (Test-Path -LiteralPath $requestFile -PathType Leaf) {
                Remove-Item -LiteralPath $requestFile -Force
            }
        }
    }
}

function Invoke-QAFrameworkTestDiscovery {
    <#
    .SYNOPSIS
        Harvests QAFramework regression tests into a test package.
    .DESCRIPTION
        Walks a RegressionTests tree, parses the QAFramework class attributes and the
        legacy .meta files, applies the harvest time filters and writes everything a test
        package needs to run:

        - <Content>/xmlautomationtests.generated/<test>/script.xml, the DMSScript for the test,
        - <Content>/dependencies.generated/knownautomationtests.generated,
        - <Content>/dependencies.generated/qaframework.tests.json, the schema v1 metadata
          used by Import-QAFrameworkTestMetadata,
        - <Content>/dependencies.generated/testmetadata.generated.json for compatibility
          with packages that still read the legacy metadata file,
        - the GlobalDependencies, TeamDependencies and TestDependencies folders.

        Both tests with a .meta file and attribute only tests carrying [TestFixture] are
        discovered. Attribute values always win over .meta values.

        Disabled tests are kept in the metadata with their reason so the runtime reports
        them as NotExecuted, but no script is generated for them unless -IncludeDisabled
        is used.
    .PARAMETER TestPackageContentPath
        The TestHarvesting folder of the test package, or the test package content root.
        The generated output is written next to it.
    .PARAMETER RegressionTestsRoot
        The RegressionTests folder to walk. Resolved from the discovery configuration or
        by walking up from the content path when it is not given.
    .PARAMETER FolderTagPrefix
        Prefix of the automation script <Folder> tag. Defaults to 'QAOps\'.
    .PARAMETER OnlyTests
        Only harvest these test names.
    .PARAMETER ForceOnlyTests
        Harvest the tests of -OnlyTests without applying any other filter.
    .PARAMETER BaselineGate
        Required harvests only baseline tests, Additive always harvests baseline tests and
        Disabled ignores the baseline flag. Defaults to Disabled.
    .PARAMETER Keywords
        Only harvest tests carrying one of these keywords. Prefix with ! to exclude.
    .PARAMETER ExcludeKeywords
        Do not harvest tests carrying one of these keywords.
    .PARAMETER Squads
        Only harvest tests of one of these squads. Prefix with ! to exclude.
    .PARAMETER ExcludeSquads
        Do not harvest tests of one of these squads.
    .PARAMETER IncludeDisabled
        Also generate a script for tests that are disabled with a reason.
    .PARAMETER ConfigPath
        A qaframework.discovery.json holding the same settings. Defaults to
        <TestHarvesting>/qaframework.discovery.json when it exists.
    .PARAMETER SkipDependencies
        Do not copy the Global, Team and Test dependency folders.
    .EXAMPLE
        Invoke-QAFrameworkTestDiscovery -TestPackageContentPath (Resolve-Path "$PSScriptRoot\..")
    .OUTPUTS
        A discovery report with Scanned, Harvested, Dropped, Tests and the output paths.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TestPackageContentPath,

        [Parameter()][string]$RegressionTestsRoot,
        [Parameter()][string]$FolderTagPrefix = 'QAOps\',

        [Parameter()][string[]]$OnlyTests,
        [Parameter()][switch]$ForceOnlyTests,
        [Parameter()][ValidateSet('Required', 'Additive', 'Disabled')][string]$BaselineGate,
        [Parameter()][string[]]$Keywords,
        [Parameter()][string[]]$ExcludeKeywords,
        [Parameter()][string[]]$Squads,
        [Parameter()][string[]]$ExcludeSquads,
        [Parameter()][switch]$IncludeDisabled,

        [Parameter()][string]$ConfigPath,
        [Parameter()][switch]$SkipDependencies
    )

    $contentRoot = (Resolve-Path -LiteralPath $TestPackageContentPath -ErrorAction Stop).ProviderPath

    # Accept both the content root and its TestHarvesting folder.
    $harvestRoot = if ((Split-Path -Leaf $contentRoot) -eq 'TestHarvesting') {
        $contentRoot
    }
    else {
        Join-Path $contentRoot 'TestHarvesting'
    }

    if (-not (Test-Path -LiteralPath $harvestRoot)) {
        $null = New-Item -ItemType Directory -Path $harvestRoot -Force
    }

    # Configuration file, lowest precedence.
    $settings = @{
        regressionTestsRoot = $null
        folderTagPrefix     = $null
        onlyTests           = @()
        forceOnlyTests      = $false
        baselineGate        = 'Disabled'
        keywords            = @()
        excludeKeywords     = @()
        squads              = @()
        excludeSquads       = @()
        includeDisabled     = $false
    }

    $resolvedConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $harvestRoot 'qaframework.discovery.json' }
    if (Test-Path -LiteralPath $resolvedConfigPath) {
        $document = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
        foreach ($property in $document.PSObject.Properties) {
            $key = $settings.Keys | Where-Object { $_ -eq $property.Name } | Select-Object -First 1
            if ($key -and $null -ne $property.Value) { $settings[$key] = $property.Value }
        }
        Write-Verbose "Discovery settings read from $resolvedConfigPath."
    }

    if ($PSBoundParameters.ContainsKey('RegressionTestsRoot')) { $settings['regressionTestsRoot'] = $RegressionTestsRoot }
    if ($PSBoundParameters.ContainsKey('FolderTagPrefix')) { $settings['folderTagPrefix'] = $FolderTagPrefix }
    if ($PSBoundParameters.ContainsKey('OnlyTests')) { $settings['onlyTests'] = $OnlyTests }
    if ($PSBoundParameters.ContainsKey('ForceOnlyTests')) { $settings['forceOnlyTests'] = [bool]$ForceOnlyTests }
    if ($PSBoundParameters.ContainsKey('BaselineGate')) { $settings['baselineGate'] = $BaselineGate }
    if ($PSBoundParameters.ContainsKey('Keywords')) { $settings['keywords'] = $Keywords }
    if ($PSBoundParameters.ContainsKey('ExcludeKeywords')) { $settings['excludeKeywords'] = $ExcludeKeywords }
    if ($PSBoundParameters.ContainsKey('Squads')) { $settings['squads'] = $Squads }
    if ($PSBoundParameters.ContainsKey('ExcludeSquads')) { $settings['excludeSquads'] = $ExcludeSquads }
    if ($PSBoundParameters.ContainsKey('IncludeDisabled')) { $settings['includeDisabled'] = [bool]$IncludeDisabled }

    if (-not $settings['folderTagPrefix']) { $settings['folderTagPrefix'] = 'QAOps\' }

    # Resolve the RegressionTests root: explicit, then upwards from the harvest folder.
    $testsRoot = $settings['regressionTestsRoot']
    if ($testsRoot -and -not [IO.Path]::IsPathRooted($testsRoot)) {
        $testsRoot = Join-Path $harvestRoot $testsRoot
    }

    if (-not $testsRoot -or -not (Test-Path -LiteralPath $testsRoot)) {
        $candidate = $harvestRoot
        $testsRoot = $null
        for ($level = 0; $level -lt 8 -and $candidate; $level++) {
            $probe = Join-Path $candidate 'RegressionTests'
            if (Test-Path -LiteralPath $probe) { $testsRoot = $probe; break }
            $candidate = Split-Path -Parent $candidate
        }
    }

    if (-not $testsRoot) {
        throw "Could not find a RegressionTests folder above '$harvestRoot'. Use -RegressionTestsRoot to point at it."
    }

    $testsRoot = (Resolve-Path -LiteralPath $testsRoot -ErrorAction Stop).ProviderPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    Write-Verbose "Harvesting the regression tests in $testsRoot."

    $scriptsRoot = Join-Path $harvestRoot 'xmlautomationtests.generated'
    $dependenciesRoot = Join-Path $harvestRoot 'dependencies.generated'
    $globalDependencies = Join-Path $dependenciesRoot 'GlobalDependencies'
    $teamDependencies = Join-Path $dependenciesRoot 'TeamDependencies'
    $testDependencies = Join-Path $dependenciesRoot 'TestDependencies'

    foreach ($path in @($scriptsRoot, $globalDependencies, $teamDependencies, $testDependencies)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    $null = New-Item -ItemType Directory -Path $dependenciesRoot -Force
    $null = New-Item -ItemType Directory -Path $scriptsRoot -Force
    $null = New-Item -ItemType Directory -Path $teamDependencies -Force
    $null = New-Item -ItemType Directory -Path $testDependencies -Force

    if (-not $SkipDependencies) {
        $null = Copy-QAFrameworkDependency -Path (Join-Path $testsRoot 'GlobalDependencies') -Destination $globalDependencies
    }

    # Collect the candidates: every .meta file plus every .cs file with a fixture attribute
    # that has no .meta next to it.
    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($meta in @(Get-ChildItem -LiteralPath $testsRoot -Recurse -Filter *.meta -File -ErrorAction SilentlyContinue)) {
        $cs = [IO.Path]::ChangeExtension($meta.FullName, '.cs')
        $candidates.Add([pscustomobject]@{
                Name      = [IO.Path]::GetFileNameWithoutExtension($meta.Name)
                MetaPath  = $meta.FullName
                CsPath    = if (Test-Path -LiteralPath $cs) { $cs } else { $null }
                Directory = $meta.DirectoryName
            })
    }

    foreach ($cs in @(Get-ChildItem -LiteralPath $testsRoot -Recurse -Filter *.cs -File -ErrorAction SilentlyContinue)) {
        $meta = [IO.Path]::ChangeExtension($cs.FullName, '.meta')
        if (Test-Path -LiteralPath $meta) { continue }

        $content = Get-Content -LiteralPath $cs.FullName -Raw
        if ($content -notmatch '(?m)^\s*\[\s*(TestFixture|PreRunFixture|FailoverTestFixture|DiagnosticTestFixture)\b') { continue }

        $candidates.Add([pscustomobject]@{
                Name      = [IO.Path]::GetFileNameWithoutExtension($cs.Name)
                MetaPath  = $null
                CsPath    = $cs.FullName
                Directory = $cs.DirectoryName
            })
    }

    $tests = [System.Collections.Generic.List[object]]::new()
    $dropped = [System.Collections.Generic.List[object]]::new()
    $knownTests = [System.Collections.Generic.List[string]]::new()
    $legacyMetadata = [System.Collections.Generic.List[object]]::new()
    $teamCache = @{}

    $filterArguments = @{
        OnlyTests       = [string[]]@($settings['onlyTests'])
        BaselineGate    = [string]$settings['baselineGate']
        Keywords        = [string[]]@($settings['keywords'])
        ExcludeKeywords = [string[]]@($settings['excludeKeywords'])
        Squads          = [string[]]@($settings['squads'])
        ExcludeSquads   = [string[]]@($settings['excludeSquads'])
    }
    if ($settings['forceOnlyTests']) { $filterArguments['ForceOnlyTests'] = $true }
    if ($settings['includeDisabled']) { $filterArguments['IncludeDisabled'] = $true }

    foreach ($candidate in $candidates | Sort-Object Name) {
        $relativeFolder = $candidate.Directory.Substring($testsRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $folderTag = ($settings['folderTagPrefix'].TrimEnd('\', '/') + '\' + ($relativeFolder -replace '[\\/]', '\')).TrimEnd('\')

        $metadata = New-QAFrameworkTestMetadata -CsPath $candidate.CsPath -MetaPath $candidate.MetaPath `
            -ClassName $candidate.Name -Name $candidate.Name -RegressionTestsRoot $testsRoot -FolderTag $folderTag

        $decision = Test-QAFrameworkHarvestFilter -Test $metadata @filterArguments
        if (-not $decision.Include) {
            $dropped.Add([pscustomobject]@{ Name = $metadata.name; Reason = $decision.Reason })
            Write-Verbose "Skipping $($metadata.name): $($decision.Reason)"

            # A disabled test still belongs in the runtime metadata when it passes every other
            # harvest filter, so QAOps can show it as NotExecuted with its reason.
            $enabledFilterArguments = @{} + $filterArguments
            $enabledFilterArguments['IncludeDisabled'] = $true
            $enabledDecision = Test-QAFrameworkHarvestFilter -Test $metadata @enabledFilterArguments
            if ($decision.Reason -like 'The test is disabled:*' -and
                $enabledDecision.Include -and
                $metadata.disabled -and
                -not [string]::IsNullOrWhiteSpace([string]$metadata.disabled.reason)) {
                $tests.Add($metadata)
                $legacyMetadata.Add([pscustomobject]@{
                        Name              = $metadata.name
                        DiagnosticRunType = $metadata.diagnosticRunType
                        noParallelGroup   = $null
                        isBaseline        = $metadata.isBaseline
                        keywords          = $metadata.keywords
                        squads            = $metadata.squads
                    })
            }

            continue
        }

        if (-not $candidate.CsPath) {
            $dropped.Add([pscustomobject]@{ Name = $metadata.name; Reason = 'The test has no .cs file, so no automation script could be generated.' })
            Write-Warning "Missing .cs file for $($metadata.name). The test is not harvested."
            continue
        }

        $scriptFolder = Join-Path $scriptsRoot $metadata.name
        $null = New-Item -ItemType Directory -Path $scriptFolder -Force
        $scriptPath = Join-Path $scriptFolder 'script.xml'

        $xml = New-QAFrameworkAutomationScriptXml -Name $metadata.name `
            -CsContent (Get-Content -LiteralPath $candidate.CsPath -Raw) `
            -FolderTag $folderTag -DllReference ([string[]]@($metadata.dllReferences))

        Set-Content -LiteralPath $scriptPath -Value $xml -Encoding utf8

        try {
            $document = [xml]::new()
            $document.Load($scriptPath)
        }
        catch {
            throw "The generated automation script for '$($metadata.name)' is not valid XML: $($_.Exception.Message)"
        }

        $tests.Add($metadata)
        $knownTests.Add($metadata.name)
        $legacyMetadata.Add([pscustomobject]@{
                Name              = $metadata.name
                DiagnosticRunType = $metadata.diagnosticRunType
                noParallelGroup   = $null
                isBaseline        = $metadata.isBaseline
                keywords          = $metadata.keywords
                squads            = $metadata.squads
            })

        if (-not $SkipDependencies) {
            $null = Copy-QAFrameworkDependency -Path (Join-Path $candidate.Directory 'Dependencies') -Destination (Join-Path $testDependencies $metadata.name)

            $segment = ($candidate.Directory.Substring($testsRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) -split '[\\/]')[0]
            if ($segment -and -not $teamCache.ContainsKey($segment)) {
                $teamCache[$segment] = $true
                $null = Copy-QAFrameworkDependency -Path (Join-Path (Join-Path $testsRoot $segment) 'TeamDependencies') -Destination (Join-Path $teamDependencies $segment)
            }
        }
    }

    $knownTestsPath = Join-Path $dependenciesRoot 'knownautomationtests.generated'
    $metadataPath = Join-Path $dependenciesRoot 'qaframework.tests.json'
    $legacyMetadataPath = Join-Path $dependenciesRoot 'testmetadata.generated.json'

    Set-Content -LiteralPath $knownTestsPath -Value ([string[]]@($knownTests)) -Encoding utf8
    ([pscustomobject]@{ schemaVersion = 1; tests = [object[]]@($tests) } | ConvertTo-Json -Depth 8) |
        Set-Content -LiteralPath $metadataPath -Encoding utf8
    (, [object[]]@($legacyMetadata) | ConvertTo-Json -Depth 5) |
        Set-Content -LiteralPath $legacyMetadataPath -Encoding utf8

    # Only dependencies.generated is shipped, so snapshot the package configuration into it.
    foreach ($name in @('qaframework.config.json', 'qaframework.discovery.json')) {
        foreach ($source in @((Join-Path $harvestRoot $name), (Join-Path (Join-Path $contentRoot 'TestPackagePipeline') $name))) {
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $dependenciesRoot $name) -Force
                break
            }
        }
    }

    Write-Host ("Harvested {0} executable test(s), wrote metadata for {1}, skipped {2}." -f $knownTests.Count, $tests.Count, $dropped.Count)

    return [pscustomobject]@{
        RegressionTestsRoot = $testsRoot
        HarvestRoot         = $harvestRoot
        ScriptsPath         = $scriptsRoot
        DependenciesPath    = $dependenciesRoot
        KnownTestsPath      = $knownTestsPath
        MetadataPath        = $metadataPath
        LegacyMetadataPath  = $legacyMetadataPath
        Scanned             = $candidates.Count
        Harvested           = $knownTests.Count
        Tests               = [object[]]@($tests)
        Dropped             = [object[]]@($dropped)
    }
}

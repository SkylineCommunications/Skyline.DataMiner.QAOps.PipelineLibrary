function Invoke-QAFrameworkTestPackage {
    <#
    .SYNOPSIS
        Runs a QAFramework test package through the standalone orchestrator.
    .DESCRIPTION
        Installs or updates the package-local QAFramework tool and invokes its run command.
        Agent preparation, selection, scheduling, Failover, retries, and result publication are
        owned by the orchestrator; a run always revalidates Agent setup.
    .PARAMETER TestPackageContentPath
        Test package content root.
    .PARAMETER Keywords
        Override the keyword selection. A value prefixed with ! is an exclusion for legacy
        PipelineLibrary configurations.
    .PARAMETER ExcludeKeywords
        Override keyword exclusions.
    .PARAMETER Squads
        Override the squad selection. A value prefixed with ! is an exclusion for legacy
        PipelineLibrary configurations.
    .PARAMETER ExcludeSquads
        Override squad exclusions.
    .PARAMETER Customers
        Override the customer selection.
    .PARAMETER ConfigPath
        Explicit unified or supported legacy QAFramework configuration file.
    .PARAMETER SupplementaryFilesPath
        Validated supplementary-files directory used for configuration overrides.
    .PARAMETER ResultsPath
        Optional path for the final JSON summary. Defaults to the QAFramework summary path in
        TestPackagePipeline.
    .PARAMETER SetupTimeoutSeconds
        Maximum duration allowed for Agent setup.
    .PARAMETER SkipPublish
        Do not publish attempt or overall results to QAOps. This is not a dry-run mode.
    .PARAMETER PassThru
        Return the parsed JSON run summary on success.
    .PARAMETER SkipAgentSetup
        Removed. The orchestrator always revalidates Agent setup before scheduling tests.
    .PARAMETER OverallResultName
        Only the standard pipeline_TestPackageExecution result name is supported.
    .EXAMPLE
        Invoke-QAFrameworkTestPackage -TestPackageContentPath (Resolve-Path "$PSScriptRoot\..") -PassThru
    .OUTPUTS
        The parsed JSON run summary when -PassThru is used.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TestPackageContentPath,

        [Parameter()]
        [string[]]$Keywords,

        [Parameter()]
        [string[]]$ExcludeKeywords,

        [Parameter()]
        [string[]]$Squads,

        [Parameter()]
        [string[]]$ExcludeSquads,

        [Parameter()]
        [string[]]$Customers,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$SupplementaryFilesPath,

        [Parameter()]
        [string]$ResultsPath,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$SetupTimeoutSeconds = 1800,

        [Parameter()]
        [switch]$SkipAgentSetup,

        [Parameter()]
        [switch]$SkipPublish,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [string]$OverallResultName = 'pipeline_TestPackageExecution'
    )

    if ($SkipAgentSetup) {
        throw '-SkipAgentSetup is no longer supported. The orchestrator always revalidates Agent setup before running tests.'
    }
    if ($OverallResultName -ne 'pipeline_TestPackageExecution') {
        throw 'Custom -OverallResultName values are no longer supported. The orchestrator publishes the standard pipeline_TestPackageExecution result.'
    }

    $paths = Resolve-QAFrameworkContentPath -Path $TestPackageContentPath
    if (-not $PSCmdlet.ShouldProcess($paths.ContentPath, 'Run QAFramework test package')) {
        return
    }

    $filter = @{}
    $keywordExclusions = [System.Collections.Generic.List[string]]::new()
    $squadExclusions = [System.Collections.Generic.List[string]]::new()
    if ($PSBoundParameters.ContainsKey('Keywords')) {
        $includedKeywords = [System.Collections.Generic.List[string]]::new()
        foreach ($keyword in @($Keywords)) {
            if ([string]::IsNullOrWhiteSpace($keyword)) {
                throw 'Keywords cannot contain empty values.'
            }
            if ($keyword.StartsWith('!', [System.StringComparison]::Ordinal) -and $keyword.Length -gt 1) {
                $keywordExclusions.Add($keyword.Substring(1))
            }
            else {
                $includedKeywords.Add($keyword)
            }
        }
        $filter['keywords'] = [string[]]$includedKeywords
    }
    if ($PSBoundParameters.ContainsKey('ExcludeKeywords')) {
        if (@($ExcludeKeywords | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'ExcludeKeywords cannot contain empty values.'
        }
        $keywordExclusions.AddRange([string[]]@($ExcludeKeywords))
    }
    if ($keywordExclusions.Count -gt 0 -or $PSBoundParameters.ContainsKey('ExcludeKeywords')) {
        $filter['excludeKeywords'] = [string[]]$keywordExclusions
    }
    if ($PSBoundParameters.ContainsKey('Squads')) {
        $includedSquads = [System.Collections.Generic.List[string]]::new()
        foreach ($squad in @($Squads)) {
            if ([string]::IsNullOrWhiteSpace($squad)) {
                throw 'Squads cannot contain empty values.'
            }
            if ($squad.StartsWith('!', [System.StringComparison]::Ordinal) -and $squad.Length -gt 1) {
                $squadExclusions.Add($squad.Substring(1))
            }
            else {
                $includedSquads.Add($squad)
            }
        }
        $filter['squads'] = [string[]]$includedSquads
    }
    if ($PSBoundParameters.ContainsKey('ExcludeSquads')) {
        if (@($ExcludeSquads | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'ExcludeSquads cannot contain empty values.'
        }
        $squadExclusions.AddRange([string[]]@($ExcludeSquads))
    }
    if ($squadExclusions.Count -gt 0 -or $PSBoundParameters.ContainsKey('ExcludeSquads')) {
        $filter['excludeSquads'] = [string[]]$squadExclusions
    }
    if ($PSBoundParameters.ContainsKey('Customers')) {
        if (@($Customers | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'Customers cannot contain empty values.'
        }
        $filter['customers'] = [string[]]@($Customers)
    }

    $overrides = if ($filter.Count -gt 0) { @{ filter = $filter } } else { @{} }
    if ((-not $PSBoundParameters.ContainsKey('ConfigPath')) -and ($null -eq (Get-QAFrameworkPackageConfigInfo -ContentPath $paths.ContentPath))) {
        $overrides['selectionPolicy'] = 'LegacyPipeline'
    }

    $requestPath = $null
    $configPathResolved = $null
    if ($PSBoundParameters.ContainsKey('ConfigPath')) {
        $configPathResolved = Resolve-QAFrameworkPackageFilePath `
            -Path $ConfigPath `
            -ContentPath $paths.ContentPath `
            -Description 'ConfigPath'
    }

    $supplementaryPathResolved = $null
    if ($PSBoundParameters.ContainsKey('SupplementaryFilesPath')) {
        $supplementaryPathResolved = (Resolve-Path -LiteralPath $SupplementaryFilesPath -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $supplementaryPathResolved -PathType Container)) {
            throw "SupplementaryFilesPath must be an existing directory: $SupplementaryFilesPath"
        }
    }

    if ($PSBoundParameters.ContainsKey('ResultsPath')) {
        if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
            throw 'ResultsPath cannot be empty.'
        }
        $summaryPath = if ([System.IO.Path]::IsPathRooted($ResultsPath)) {
            [System.IO.Path]::GetFullPath($ResultsPath)
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path $paths.PipelinePath $ResultsPath))
        }
    }
    else {
        $summaryPath = Join-Path $paths.PipelinePath 'qaops-qaframework-results.json'
    }

    try {
        $null = Install-QAFrameworkTool -PipelineDirectory $paths.PipelinePath
        $requestPath = New-QAFrameworkRequestFile -Overrides $overrides -Directory $paths.PipelinePath

        $arguments = @(
            'run',
            '--content',
            $paths.ContentPath,
            '--setup-timeout-seconds',
            [string]$SetupTimeoutSeconds,
            '--results',
            $summaryPath
        )
        if ($configPathResolved) { $arguments += @('--config', $configPathResolved) }
        if ($supplementaryPathResolved) { $arguments += @('--supplementary-path', $supplementaryPathResolved) }
        if ($requestPath) { $arguments += @('--request-file', $requestPath) }
        if ($SkipPublish) { $arguments += '--skip-publish' }

        try {
            $summary = Invoke-QAFrameworkToolJson -PipelineDirectory $paths.PipelinePath -Operation 'run' -Arguments $arguments
        }
        catch {
            throw [System.InvalidOperationException]::new(
                "$($_.Exception.Message) Summary: $summaryPath",
                $_.Exception)
        }

        if ($PassThru) {
            return $summary
        }

        Write-Host ("QAFramework run {0}: {1} attempt(s), {2} skipped, {3} error(s). Summary: {4}" -f `
            $summary.overallOutcome, @($summary.attempts).Count, @($summary.skipped).Count, @($summary.errors).Count, $summaryPath)
    }
    finally {
        if ($requestPath -and (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
            Remove-Item -LiteralPath $requestPath -Force
        }
    }
}

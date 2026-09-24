function Initialize-QAFrameworkAgents {
    <#
    .SYNOPSIS
        Prepares QAFramework Agents through the standalone orchestrator.
    .DESCRIPTION
        Installs or updates the package-local QAFramework tool and runs its controller-side
        setup command. The orchestrator resolves the active QAOps cluster and prepares its
        eligible Windows DataMiner Agents through QAOps Bridge.
    .PARAMETER TestPackageContentPath
        Test package content root.
    .PARAMETER ConfigPath
        Explicit unified or supported legacy QAFramework configuration file.
    .PARAMETER SupplementaryFilesPath
        Validated supplementary-files directory used for configuration overrides.
    .PARAMETER TimeoutSeconds
        Maximum setup duration per Agent.
    .PARAMETER PassThru
        Return the complete parsed JSON setup report instead of one result per Agent.
    .PARAMETER Topology
        Removed object-based parameter. The orchestrator reads the active cluster from QAOps.
    .PARAMETER Configuration
        Removed object-based parameter. The orchestrator reads package and run configuration.
    .PARAMETER ScriptPath
        Removed parameter. The orchestrator owns the Agent setup implementation.
    .PARAMETER FailoverState
        Removed parameter. Failover state transitions are owned by the orchestrator.
    .PARAMETER SkipDependencies
        Removed parameter. Agent setup is performed by the orchestrator.
    .PARAMETER ContinueOnError
        Removed parameter. Setup failures are reported as terminating errors.
    .EXAMPLE
        Initialize-QAFrameworkAgents -TestPackageContentPath (Resolve-Path "$PSScriptRoot\..")
    .OUTPUTS
        One setup result per Agent, or the complete report when -PassThru is used.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string]$TestPackageContentPath,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$SupplementaryFilesPath,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutSeconds = 1800,

        [Parameter()]
        [switch]$PassThru,

        [Parameter(DontShow = $true)]
        [object]$Topology,

        [Parameter(DontShow = $true)]
        [object]$Configuration,

        [Parameter(DontShow = $true)]
        [string]$ScriptPath,

        [Parameter(DontShow = $true)]
        [int]$FailoverState,

        [Parameter(DontShow = $true)]
        [switch]$SkipDependencies,

        [Parameter(DontShow = $true)]
        [switch]$ContinueOnError
    )

    $removedParameters = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('Topology', 'Configuration', 'ScriptPath', 'FailoverState', 'SkipDependencies', 'ContinueOnError')) {
        if ($PSBoundParameters.ContainsKey($name)) { $removedParameters.Add("-$name") }
    }
    if ($removedParameters.Count -gt 0) {
        throw "$($removedParameters -join ', ') are no longer supported. The orchestrator reads the active QAOps topology and owns Agent setup and Failover state. Use -TestPackageContentPath and package configuration instead."
    }
    if ([string]::IsNullOrWhiteSpace($TestPackageContentPath)) {
        throw 'TestPackageContentPath is required.'
    }

    $paths = Resolve-QAFrameworkContentPath -Path $TestPackageContentPath
    if (-not $PSCmdlet.ShouldProcess($paths.ContentPath, 'Prepare QAFramework Agents')) {
        return
    }

    $arguments = @('setup', '--content', $paths.ContentPath, '--timeout-seconds', [string]$TimeoutSeconds)
    if ($PSBoundParameters.ContainsKey('ConfigPath')) {
        $configPathResolved = Resolve-QAFrameworkPackageFilePath `
            -Path $ConfigPath `
            -ContentPath $paths.ContentPath `
            -Description 'ConfigPath'
        $arguments += @('--config', $configPathResolved)
    }
    if ($PSBoundParameters.ContainsKey('SupplementaryFilesPath')) {
        $supplementaryPathResolved = (Resolve-Path -LiteralPath $SupplementaryFilesPath -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $supplementaryPathResolved -PathType Container)) {
            throw "SupplementaryFilesPath must be an existing directory: $SupplementaryFilesPath"
        }
        $arguments += @('--supplementary-path', $supplementaryPathResolved)
    }

    $null = Install-QAFrameworkTool -PipelineDirectory $paths.PipelinePath
    $report = Invoke-QAFrameworkToolJson -PipelineDirectory $paths.PipelinePath -Operation 'setup' -Arguments $arguments

    if ($PassThru) {
        return $report
    }

    foreach ($agent in @($report.agents)) {
        Write-Output $agent
    }
}

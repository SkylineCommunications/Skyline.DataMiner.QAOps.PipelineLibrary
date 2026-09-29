<#
.SYNOPSIS
    Harvests the QAFramework regression tests into the test package.
.DESCRIPTION
    Copy this file to <TestPackageContent>/TestHarvesting/TestDiscovery.ps1.
    It runs where the test sources are available, for example on a developer machine
    or in the build pipeline. The PipelineLibrary installs or updates the local tool
    and delegates discovery, filtering, and harvesting to the orchestrator.
.PARAMETER RegressionTestsRoot
    RegressionTests source directory. A relative path is resolved from TestHarvesting.
.PARAMETER Keywords
    Override the keyword selection. Prefix a value with ! to exclude it.
.PARAMETER Squads
    Override the squad selection. Prefix a value with ! to exclude it.
.PARAMETER BaselineGate
    Override the baseline gate.
.PARAMETER ConfigPath
    Explicit unified or supported legacy QAFramework configuration file.
.PARAMETER IncludeDisabled
    Include disabled tests that match the active source selection.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$RegressionTestsRoot,

    [Parameter()]
    [string[]]$Keywords,

    [Parameter()]
    [string[]]$ExcludeKeywords,

    [Parameter()]
    [string[]]$Squads,

    [Parameter()]
    [string[]]$ExcludeSquads,

    [Parameter()]
    [string]$BaselineGate,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$SupplementaryFilesPath,

    [Parameter()]
    [switch]$IncludeDisabled
)

$ErrorActionPreference = 'Stop'

Import-Module Skyline.DataMiner.QAOps.PipelineLibrary -Force

$arguments = @{
    TestPackageContentPath = $PSScriptRoot
}
foreach ($name in @(
    'RegressionTestsRoot',
    'Keywords',
    'ExcludeKeywords',
    'Squads',
    'ExcludeSquads',
    'BaselineGate',
    'ConfigPath',
    'SupplementaryFilesPath',
    'IncludeDisabled'
)) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $arguments[$name] = $PSBoundParameters[$name]
    }
}

$report = Invoke-QAFrameworkTestDiscovery @arguments

foreach ($drop in $report.Preview.Dropped) {
    Write-Host ("skipped {0}: {1} - {2}" -f $drop.Name, $drop.ReasonCode, $drop.Reason)
}

Write-Host ("Harvested {0} selected test(s) from {1} scanned candidate(s)." -f `
    @($report.Preview.Selected).Count, @($report.Preview.Scanned).Count)
Write-Host "Known tests: $($report.KnownTestsFile)"
Write-Host "Metadata: $($report.MetadataFile)"

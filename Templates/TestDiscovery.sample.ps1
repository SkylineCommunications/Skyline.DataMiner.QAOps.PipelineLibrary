<#
.SYNOPSIS
    Harvests the QAFramework regression tests into this test package.
.DESCRIPTION
    Copy this file to <TestPackageContent>/TestHarvesting/TestDiscovery.ps1. It runs where
    the sources are, so on a developer machine or in the build pipeline, not on a DataMiner
    agent. Settings can also be put in a qaframework.discovery.json next to this file.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$RegressionTestsRoot,

    [Parameter()]
    [string[]]$Keywords,

    [Parameter()]
    [string[]]$Squads,

    [Parameter()]
    [ValidateSet('Required', 'Additive', 'Disabled')]
    [string]$BaselineGate = 'Disabled'
)

$ErrorActionPreference = 'Stop'

Import-Module Skyline.DataMiner.QAOps.PipelineLibrary -Force

$arguments = @{
    TestPackageContentPath = $PSScriptRoot
    FolderTagPrefix        = 'QAOps\MyTestPackage\'
    BaselineGate           = $BaselineGate
}
if ($RegressionTestsRoot) { $arguments['RegressionTestsRoot'] = $RegressionTestsRoot }
if ($Keywords) { $arguments['Keywords'] = $Keywords }
if ($Squads) { $arguments['Squads'] = $Squads }

$report = Invoke-QAFrameworkTestDiscovery @arguments

foreach ($drop in $report.Dropped) {
    Write-Host ("skipped {0}: {1}" -f $drop.Name, $drop.Reason)
}

Write-Host ("{0} of {1} discovered test(s) harvested into {2}." -f $report.Harvested, $report.Scanned, $report.DependenciesPath)

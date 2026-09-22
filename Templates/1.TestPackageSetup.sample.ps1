<#
.SYNOPSIS
    Prepares every DataMiner agent in the cluster for a QAFramework test package.
.DESCRIPTION
    Copy this file to <TestPackageContent>/TestPackagePipeline/1.TestPackageSetup.ps1.
    It runs on the QAOps Bridge that orchestrates the test package, which does not need
    to have DataMiner installed. The actual agent side work is done by
    TestPackagePipeline/helpers/Initialize-QAFrameworkAgent.ps1, which this call starts
    on every DataMiner agent through a QAOps bridge execution.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [Alias('TestPackageContentPath')]
    [string]$PathToTestPackageContent = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

Import-Module Skyline.DataMiner.QAOps.PipelineLibrary -Force

$configuration = Get-QAFrameworkRunConfiguration -TestPackageContentPath $PathToTestPackageContent
$topology = Get-QAFrameworkClusterTopology

$results = @(Initialize-QAFrameworkAgents -Topology $topology -Configuration $configuration -TestPackageContentPath $PathToTestPackageContent)

foreach ($result in $results) {
    Write-Host ("{0}: {1}" -f $result.BridgeId, $(if ($result.Success) { 'ready' } else { "failed - $($result.Message)" }))
}

if ($results | Where-Object { -not $_.Success }) {
    throw 'Not every DataMiner agent could be prepared for the test package.'
}

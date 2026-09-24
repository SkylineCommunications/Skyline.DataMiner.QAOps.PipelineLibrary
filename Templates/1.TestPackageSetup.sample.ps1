<#
.SYNOPSIS
    Prepares eligible QAFramework Agents for the test package.
.DESCRIPTION
    Copy this file to <TestPackageContent>/TestPackagePipeline/1.TestPackageSetup.ps1.
    The PipelineLibrary installs or updates the package-local QAFramework orchestrator
    and asks it to prepare eligible Windows DataMiner Agents through QAOps Bridge.
.PARAMETER PathToTestPackageContent
    Test package content root.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [Alias('TestPackageContentPath')]
    [string]$PathToTestPackageContent = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

Import-Module Skyline.DataMiner.QAOps.PipelineLibrary -Force

$results = @(Initialize-QAFrameworkAgents -TestPackageContentPath $PathToTestPackageContent)
foreach ($result in $results) {
    Write-Host ("{0}: {1}" -f $result.BridgeName, $result.Message)
}

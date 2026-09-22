<#
.SYNOPSIS
    Runs the QAFramework tests of this test package.
.DESCRIPTION
    Copy this file to <TestPackageContent>/TestPackagePipeline/2.TestPackageExecution.ps1.
    Every test is started on a DataMiner agent through a QAOps bridge execution, so this
    script also runs on a QAOps Bridge without DataMiner, for example a Linux orchestrator.

    Agent setup is repeated here deliberately. QAOps continues with later numbered scripts
    when an earlier script fails, so skipping setup could schedule tests on partially prepared
    agents. Initialize-QAFrameworkAgents is idempotent.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [Alias('TestPackageContentPath')]
    [string]$PathToTestPackageContent = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    [Parameter()]
    [string[]]$Keywords,

    [Parameter()]
    [string[]]$Squads
)

$ErrorActionPreference = 'Stop'

Import-Module Skyline.DataMiner.QAOps.PipelineLibrary -Force

$arguments = @{
    TestPackageContentPath = $PathToTestPackageContent
}
if ($Keywords) { $arguments['Keywords'] = $Keywords }
if ($Squads) { $arguments['Squads'] = $Squads }

Invoke-QAFrameworkTestPackage @arguments

<#
.SYNOPSIS
    Finalizes the QAFramework test package.
.DESCRIPTION
    Copy this file to <TestPackageContent>/TestPackagePipeline/3.TestPackageFinalize.ps1.
    Nothing has to happen here: Invoke-QAFrameworkTestPackage already published every test
    result and the overall pipeline_TestPackageExecution result, and it restored the
    failover state of the cluster. Add package specific cleanup below when needed.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [Alias('TestPackageContentPath')]
    [string]$PathToTestPackageContent
)

Write-Host 'Nothing to finalize.'

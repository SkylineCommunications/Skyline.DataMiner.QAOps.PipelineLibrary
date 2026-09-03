<#
.SYNOPSIS
    Prepares a DataMiner agent to run QAFramework tests.

.DESCRIPTION
    This script runs ON a DataMiner agent, started by Initialize-QAFrameworkAgents through a
    QAOps Bridge execution. It is a parameterised port of the legacy 1.TestPackageSetup.ps1:

    - installs and restores the dataminer-run-automation-script dotnet tool,
    - creates the RTManager root and its Settings\SystemSettings.json, including FailoverState,
    - stops the device simulator so it cannot interfere with the tests,
    - replaces the GlobalDependencies, TeamDependencies and TestDependencies folders and the
      knownautomationtests.txt file with the ones harvested into the test package.

    Copy this file into your test package, for example to
    TestPackagePipeline\helpers\Initialize-QAFrameworkAgent.ps1.

.PARAMETER PathToTestPackageContent
    The test package content root on this agent.

.PARAMETER RtManagerRoot
    The RTManager root folder. Defaults to C:\RTManager\.

.PARAMETER FailoverState
    The failover state to write into SystemSettings.json. 0 is before the switch, 10 after the
    switch and 20 after switching back.

.PARAMETER SystemSettings
    Extra SystemSettings.json values as a JSON string, merged over the defaults.

.PARAMETER SkipToolInstall
    Do not install or restore the dotnet tool.

.PARAMETER SkipDependencies
    Only write the settings; do not touch the dependency folders. Used when the script is
    called again to change the failover state between test phases.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PathToTestPackageContent,

    [Parameter(Mandatory = $false)]
    [string]$RtManagerRoot = 'C:\RTManager\',

    [Parameter(Mandatory = $false)]
    [int]$FailoverState = 0,

    [Parameter(Mandatory = $false)]
    [string]$SystemSettings,

    [Parameter(Mandatory = $false)]
    [switch]$SkipToolInstall,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDependencies
)

$ErrorActionPreference = 'Stop'

function Stop-ProcessIfRunning {
    param([Parameter(Mandatory = $true)][string]$Name)

    $processes = Get-Process -Name $Name -ErrorAction SilentlyContinue
    if (-not $processes) { return }

    Write-Host "Stopping $Name (found $($processes.Count))."
    foreach ($process in $processes) {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
    }
    Start-Sleep -Seconds 2
}

function Remove-PathWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [switch]$IsDirectory
    )

    if (-not (Test-Path -Path $TargetPath)) { return }

    try {
        Remove-Item -Path $TargetPath -Recurse:$IsDirectory -Force -ErrorAction Stop
        return
    }
    catch {
        Write-Warning "Deletion failed for '$TargetPath': $($_.Exception.Message). Stopping SLAutomation and retrying."
    }

    Stop-ProcessIfRunning -Name 'SLAutomation'
    Start-Sleep -Seconds 1
    Remove-Item -Path $TargetPath -Recurse:$IsDirectory -Force -ErrorAction Stop

    Write-Host 'Waiting 120 seconds for SLAutomation to initialise again.'
    Start-Sleep -Seconds 120

    # SLAutomation being killed produces a minidump; remove the one of this run so it does not
    # end up being reported as a system problem.
    try {
        $miniDumpRoot = 'C:\Skyline DataMiner\Logging\MiniDump'
        if (Test-Path -Path $miniDumpRoot) {
            $now = Get-Date
            $closest = Get-ChildItem -Path $miniDumpRoot -Filter '*_Processes disappeared.zip' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property @{ Expression = { [math]::Abs(($_.LastWriteTime - $now).TotalSeconds) } } |
                Select-Object -First 1

            if ($closest) {
                Write-Host "Removing minidump '$($closest.FullName)'."
                Remove-Item -LiteralPath $closest.FullName -Force -ErrorAction Stop
            }
        }
    }
    catch {
        Write-Warning "Failed to remove the minidump: $($_.Exception.Message)"
    }
}

function Copy-Tree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -Path $Source)) {
        Write-Warning "Source not found, skipping: $Source"
        return
    }

    if (-not (Test-Path -Path $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }

    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

$settingsFolder = Join-Path $RtManagerRoot 'Settings'
$settingsPath = Join-Path $settingsFolder 'SystemSettings.json'
$knownTestsFile = Join-Path $RtManagerRoot 'knownautomationtests.txt'

New-Item -ItemType Directory -Force -Path $settingsFolder | Out-Null

$settings = [ordered]@{
    PushToPortal    = $true
    TearDownNeeded  = $true
    ClientId        = ''
    EndpointUrl     = ''
    ApiKey          = ''
    FailoverState   = $FailoverState
    ProxyUrl        = ''
    PushThroughEmail = $false
    RegressionRunID = 0
}

if (-not [string]::IsNullOrWhiteSpace($SystemSettings)) {
    $extra = $SystemSettings | ConvertFrom-Json
    foreach ($property in $extra.PSObject.Properties) { $settings[$property.Name] = $property.Value }
}

# The explicit parameter always wins so a failover phase can rewrite only this value.
$settings['FailoverState'] = $FailoverState

Write-Host "Writing $settingsPath with FailoverState $FailoverState."
($settings | ConvertTo-Json -Depth 5) | Out-File -FilePath $settingsPath -Encoding utf8 -Force

if ($SkipDependencies) {
    Write-Host 'Dependency deployment was skipped.'
    return
}

if ([string]::IsNullOrWhiteSpace($PathToTestPackageContent)) {
    throw 'PathToTestPackageContent is required unless -SkipDependencies is used.'
}

if (-not (Test-Path -Path $PathToTestPackageContent)) {
    throw "The specified path '$PathToTestPackageContent' does not exist."
}

if (-not $SkipToolInstall) {
    $pipelineFolder = Join-Path $PathToTestPackageContent 'TestPackagePipeline'
    $toolFolder = if (Test-Path $pipelineFolder) { $pipelineFolder } else { $PathToTestPackageContent }

    Push-Location $toolFolder
    try {
        Write-Host 'Installing dotnet tool skyline.dataminer.cicd.tools.runautomationscript.'
        dotnet tool install skyline.dataminer.cicd.tools.runautomationscript --create-manifest-if-needed --add-source https://api.nuget.org/v3/index.json
        if ($LASTEXITCODE -ne 0) { throw 'Failed to install skyline.dataminer.cicd.tools.runautomationscript.' }

        dotnet tool restore
        if ($LASTEXITCODE -ne 0) { throw 'Failed to restore the dotnet tools.' }
    }
    finally {
        Pop-Location
    }
}

Stop-ProcessIfRunning -Name 'QADeviceSimulator'

$dependenciesPath = Join-Path (Join-Path $PathToTestPackageContent 'TestHarvesting') 'dependencies.generated'
if (-not (Test-Path -Path $dependenciesPath)) {
    $found = Get-ChildItem -Path $PathToTestPackageContent -Recurse -Directory -Filter 'dependencies.generated' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '(?i)[\\/]TestHarvesting[\\/]dependencies\.generated$' } |
        Select-Object -First 1

    if (-not $found) { throw "Could not find 'TestHarvesting/dependencies.generated' under '$PathToTestPackageContent'." }
    $dependenciesPath = $found.FullName
}

Write-Host "Using dependencies from $dependenciesPath."

$folders = @('GlobalDependencies', 'TeamDependencies', 'TestDependencies')
foreach ($folder in $folders) {
    Remove-PathWithRetry -TargetPath (Join-Path $RtManagerRoot $folder) -IsDirectory
}
Remove-PathWithRetry -TargetPath $knownTestsFile

$knownTestsSource = Join-Path $dependenciesPath 'knownautomationtests.generated'
if (Test-Path -Path $knownTestsSource -PathType Leaf) {
    Copy-Item -Path $knownTestsSource -Destination $knownTestsFile -Force
}
else {
    Write-Warning "No knownautomationtests.generated found in '$dependenciesPath'."
}

foreach ($folder in $folders) {
    Copy-Tree -Source (Join-Path $dependenciesPath $folder) -Destination (Join-Path $RtManagerRoot $folder)
}

Write-Host "QAFramework agent setup completed. Dependencies are in $RtManagerRoot."

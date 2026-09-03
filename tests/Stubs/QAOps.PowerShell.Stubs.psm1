# QAOps.PowerShell stub module for Pester tests.
# Provides in-memory stand-ins for the cmdlets the QAFramework library depends on.
# The shapes mirror QAOps.PowerShell (QaOpsBridge, QaOpsBridgeExecution, ...) so the library
# can be exercised without a cluster.

$script:Bridges = [System.Collections.Generic.List[object]]::new()
$script:Executions = [System.Collections.Generic.List[object]]::new()
$script:TestResults = [System.Collections.Generic.List[object]]::new()
$script:Cluster = $null
$script:TestRunContext = $null
$script:FailoverSwitches = [System.Collections.Generic.List[object]]::new()
$script:Outcomes = @{}
$script:DefaultOutcome = $null
$script:AutoComplete = $true

function Reset-QAOpsStubs {
    [CmdletBinding()]
    param()
    $script:Bridges.Clear()
    $script:Executions.Clear()
    $script:TestResults.Clear()
    $script:Cluster = $null
    $script:TestRunContext = $null
    $script:FailoverSwitches.Clear()
    $script:Outcomes = @{}
    $script:DefaultOutcome = $null
    $script:AutoComplete = $true
}

function Add-QAOpsStubBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$DisplayName = $Id,
        [string]$HostName = 'localhost',
        [bool]$IsOrchestrator = $false,
        [bool]$IsSelf = $false,
        [string]$TestPackageContentPath = 'C:\QAOps\Content',
        [Nullable[int]]$DmaId = $null,
        [bool]$HasDataMiner = $true,
        [bool]$IsFailover = $false,
        [string]$FailoverPartnerBridgeId = $null,
        [hashtable]$Labels = @{}
    )
    $bridge = [pscustomobject]@{
        Id                      = $Id
        DisplayName             = $DisplayName
        HostName                = $HostName
        IsOrchestrator          = $IsOrchestrator
        IsSelf                  = $IsSelf
        TestPackageContentPath  = $TestPackageContentPath
        DmaId                   = $DmaId
        HasDataMiner            = $HasDataMiner
        IsFailover              = $IsFailover
        FailoverPartnerBridgeId = $FailoverPartnerBridgeId
        Labels                  = $Labels
    }
    $script:Bridges.Add($bridge)
    return $bridge
}

function Set-QAOpsStubCluster {
    [CmdletBinding()]
    param(
        [string]$Name = 'TestCluster',
        [string]$DataMinerVersion = '10.5.0.0',
        [string]$DbmsType = 'Cassandra',
        [bool]$IsCentralized = $true,
        [bool]$IsRedGreen = $false,
        [hashtable]$Labels = @{},
        [hashtable]$SolutionVersions = @{}
    )
    $script:Cluster = [pscustomobject]@{
        Name             = $Name
        DataMinerVersion = $DataMinerVersion
        DbmsType         = $DbmsType
        IsCentralized    = $IsCentralized
        IsRedGreen       = $IsRedGreen
        Labels           = $Labels
        SolutionVersions = $SolutionVersions
    }
}

function Set-QAOpsStubTestRunContext {
    [CmdletBinding()]
    param(
        [string]$TestRunId = 'run-1',
        [bool]$IsOrchestrator = $true,
        [hashtable]$Labels = @{},
        [string]$SupplementaryFilesPath = $null
    )
    $script:TestRunContext = [pscustomobject]@{
        TestRunId              = $TestRunId
        IsOrchestrator         = $IsOrchestrator
        Labels                 = $Labels
        SupplementaryFilesPath = $SupplementaryFilesPath
    }
}

function Set-QAOpsStubExecutionOutcome {
    <#
        Controls how an execution ends. Matching is done on a substring of the arguments,
        which for the QAFramework library is the automation script name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string]$ArgumentsLike,
        [string]$State = 'Completed',
        [int]$ExitCode = 0,
        [string]$StandardOutput = '',
        [string]$StandardError = '',
        [string]$ErrorMessage = '',
        [switch]$StayRunning
    )
    $outcome = [pscustomobject]@{
        State          = $State
        ExitCode       = $ExitCode
        StandardOutput = $StandardOutput
        StandardError  = $StandardError
        ErrorMessage   = $ErrorMessage
        StayRunning    = [bool]$StayRunning
    }

    if ([string]::IsNullOrEmpty($ArgumentsLike)) { $script:DefaultOutcome = $outcome }
    else { $script:Outcomes[$ArgumentsLike] = $outcome }
}

function Get-QAOpsStubExecution {
    [CmdletBinding()]
    param()
    return $script:Executions | ForEach-Object { $_ }
}

function Get-QAOpsStubTestResult {
    [CmdletBinding()]
    param()
    return $script:TestResults | ForEach-Object { $_ }
}

function Get-QAOpsStubFailoverSwitch {
    [CmdletBinding()]
    param()
    return $script:FailoverSwitches | ForEach-Object { $_ }
}

function Complete-QAOpsStubExecution {
    <#
        Completes executions that were configured to stay running, so a test can simulate a
        scheduler tick where nothing finished yet.
    #>
    [CmdletBinding()]
    param([string]$Id)

    foreach ($execution in $script:Executions) {
        if ($Id -and $execution.Id -ne $Id) { continue }
        if ($execution.IsFinished) { continue }
        $execution.State = 'Completed'
        $execution.IsFinished = $true
        $execution.EndTime = [DateTime]::UtcNow
    }
}

function Get-QAOpsBridge {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $false)][string]$Id,
        [Parameter(Mandatory = $false)][switch]$ExcludeSelf,
        [Parameter(Mandatory = $false)][string]$ApiUrl
    )
    $result = $script:Bridges | ForEach-Object { $_ }
    if ($PSBoundParameters.ContainsKey('Id')) {
        $result = $result | Where-Object { $_.Id -eq $Id }
    }
    if ($ExcludeSelf) {
        $result = $result | Where-Object { -not $_.IsSelf }
    }
    return $result
}

function Start-QAOpsBridgeExecution {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]$Bridge,
        [Parameter(Position = 1, Mandatory = $true)][string]$Executable,
        [Parameter(Position = 2, Mandatory = $false)][string[]]$Arguments = @(),
        [Parameter(Mandatory = $false)][string]$WorkingDirectory,
        [Parameter(Mandatory = $false)][hashtable]$EnvironmentVariables,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $false)][string]$ApiUrl
    )

    $bridgeId = if ($Bridge -is [string]) { $Bridge } else { $Bridge.Id }
    $argumentText = ($Arguments -join ' ')

    $outcome = $script:DefaultOutcome
    foreach ($key in $script:Outcomes.Keys) {
        if ($argumentText -like "*$key*") { $outcome = $script:Outcomes[$key]; break }
    }

    $execution = [pscustomobject]@{
        Id                   = "exec-$($script:Executions.Count + 1)"
        BridgeId             = $bridgeId
        BridgeDisplayName    = $bridgeId
        Executable           = $Executable
        Arguments            = [string[]]$Arguments
        WorkingDirectory     = $WorkingDirectory
        EnvironmentVariables = $EnvironmentVariables
        TimeoutSeconds       = $TimeoutSeconds
        State                = 'Running'
        ExitCode             = $null
        StandardOutput       = ''
        StandardError        = ''
        ErrorMessage         = ''
        IsFinished           = $false
        StartTime            = [DateTime]::UtcNow
        EndTime              = $null
        StubOutcome          = $outcome
    }

    $script:Executions.Add($execution)
    return $execution
}

function Get-QAOpsBridgeExecution {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $false, ValueFromPipeline = $true)]$Execution,
        [Parameter(Mandatory = $false)][string]$ApiUrl
    )
    if (-not $Execution) { return $script:Executions | ForEach-Object { $_ } }

    $id = if ($Execution -is [string]) { $Execution } else { $Execution.Id }
    return $script:Executions | Where-Object { $_.Id -eq $id } | Select-Object -First 1
}

function Wait-QAOpsBridgeExecution {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][object[]]$Execution,
        [Parameter(Mandatory = $false)][switch]$Any,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 7200,
        [Parameter(Mandatory = $false)][int]$PollingIntervalSeconds = 5,
        [Parameter(Mandatory = $false)][string]$ApiUrl
    )

    foreach ($item in $Execution) {
        $stored = Get-QAOpsBridgeExecution -Execution $item
        if (-not $stored -or $stored.IsFinished) { continue }

        $outcome = $stored.StubOutcome
        if ($outcome -and $outcome.StayRunning) { continue }

        $stored.State = if ($outcome) { $outcome.State } else { 'Completed' }
        $stored.ExitCode = if ($outcome) { $outcome.ExitCode } else { 0 }
        $stored.StandardOutput = if ($outcome) { $outcome.StandardOutput } else { '' }
        $stored.StandardError = if ($outcome) { $outcome.StandardError } else { '' }
        $stored.ErrorMessage = if ($outcome) { $outcome.ErrorMessage } else { '' }
        $stored.IsFinished = $stored.State -in @('Completed', 'Failed', 'Cancelled', 'Rejected')
        $stored.EndTime = [DateTime]::UtcNow
    }

    return $Execution | ForEach-Object { Get-QAOpsBridgeExecution -Execution $_ }
}

function Stop-QAOpsBridgeExecution {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]$Execution,
        [Parameter(Mandatory = $false)][switch]$Wait,
        [Parameter(Mandatory = $false)][string]$ApiUrl
    )
    $stored = Get-QAOpsBridgeExecution -Execution $Execution
    if ($stored) {
        $stored.State = 'Cancelled'
        $stored.IsFinished = $true
        $stored.EndTime = [DateTime]::UtcNow
    }
    return $stored
}

function Push-TestCaseResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Ok', 'Fail', 'NotExecuted', 'NotApplicable')][string]$Outcome,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][TimeSpan]$Duration = [TimeSpan]::Zero,
        [Parameter(Mandatory = $false)][string]$Message = '',
        [Parameter(Mandatory = $false)][ValidateSet('Assertion', 'Execution')][string]$TestAspect = 'Assertion'
    )
    $script:TestResults.Add([pscustomobject]@{
            Outcome    = $Outcome
            Name       = $Name
            Duration   = $Duration
            Message    = $Message
            TestAspect = $TestAspect
        })
}

function Get-QAOpsCluster {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][string]$ApiUrl)
    return $script:Cluster
}

function Get-QAOpsTestRunContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][string]$ApiUrl)
    return $script:TestRunContext
}

function Start-QAOpsFailoverSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $false, ValueFromPipeline = $true)]$Bridge,
        [Parameter(Mandatory = $false)][string]$PairId,
        [Parameter(Mandatory = $false)][string]$ApiUrl
    )
    $switchOperation = [pscustomobject]@{
        Id                   = "fos-$($script:FailoverSwitches.Count + 1)"
        PairId               = $PairId
        BridgeId             = if ($Bridge) { $Bridge.Id } else { $null }
        State                = 'Completed'
        IsFinished           = $true
        ActiveBridgeIdBefore = if ($Bridge) { $Bridge.Id } else { $null }
        ActiveBridgeIdAfter  = if ($Bridge) { $Bridge.FailoverPartnerBridgeId } else { $null }
        CurrentOnlineAgentName = if ($Bridge.FailoverPartnerHostName) { $Bridge.FailoverPartnerHostName } else { $Bridge.HostName }
        ErrorMessage         = ''
    }
    $script:FailoverSwitches.Add($switchOperation)
    return $switchOperation
}

function Wait-QAOpsFailoverSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]${Switch},
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 900,
        [Parameter(Mandatory = $false)][int]$PollingIntervalSeconds = 5,
        [Parameter(Mandatory = $false)][string]$ApiUrl
    )
    return ${Switch}
}

Export-ModuleMember -Function @(
    'Reset-QAOpsStubs', 'Add-QAOpsStubBridge', 'Set-QAOpsStubCluster', 'Set-QAOpsStubTestRunContext',
    'Set-QAOpsStubExecutionOutcome', 'Get-QAOpsStubExecution', 'Get-QAOpsStubTestResult', 'Get-QAOpsStubFailoverSwitch',
    'Complete-QAOpsStubExecution',
    'Get-QAOpsBridge', 'Start-QAOpsBridgeExecution', 'Get-QAOpsBridgeExecution', 'Wait-QAOpsBridgeExecution', 'Stop-QAOpsBridgeExecution',
    'Push-TestCaseResult', 'Get-QAOpsCluster', 'Get-QAOpsTestRunContext', 'Start-QAOpsFailoverSwitch', 'Wait-QAOpsFailoverSwitch'
)

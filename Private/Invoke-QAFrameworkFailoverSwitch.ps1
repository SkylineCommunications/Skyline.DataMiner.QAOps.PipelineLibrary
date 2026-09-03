function Get-QAFrameworkFailoverStateValue {
    <#
    .SYNOPSIS
        Maps a QAFramework execution phase onto the FailoverState value in SystemSettings.json.
    .DESCRIPTION
        The legacy FailoverTestState enum uses BeforeSwitch = 0, AfterSwitch = 10 and
        AfterSwitchBack = 20. The runner rewrites this value on every agent before it starts a
        failover phase, and the test framework on the agent uses it to decide which of the
        BeforeSwitch, AfterSwitch and AfterSwitchBack methods to run.
    .PARAMETER Phase
        The execution plan phase.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][string]$Phase
    )

    switch -Regex ($Phase) {
        '^(?i)Failover(Direct)?AfterSwitchBack$' { return 20 }
        '^(?i)Failover(Direct)?AfterSwitch$' { return 10 }
        default { return 0 }
    }
}

function Set-QAFrameworkFailoverState {
    <#
    .SYNOPSIS
        Rewrites the FailoverState in SystemSettings.json on every DataMiner agent.
    .DESCRIPTION
        Runs the agent script with -SkipDependencies through a bridge execution, so only the
        settings file changes and the harvested dependencies stay in place.
    .PARAMETER Topology
        A cluster topology from Get-QAFrameworkClusterTopology.
    .PARAMETER State
        The FailoverState value: 0 before the switch, 10 after the switch, 20 after switching back.
    .PARAMETER Configuration
        A run configuration, for rtManagerRoot and systemSettings.
    .PARAMETER TestPackageContentPath
        The test package content root on the agents.
    .PARAMETER ScriptPath
        The agent script path relative to the content root.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$Topology,
        [Parameter(Mandatory = $true)][int]$State,
        [Parameter()][object]$Configuration,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TestPackageContentPath,
        [Parameter()][string]$ScriptPath = 'TestPackagePipeline/helpers/Initialize-QAFrameworkAgent.ps1'
    )

    $parameters = @{
        Topology         = $Topology
        FailoverState    = $State
        SkipDependencies = $true
        ScriptPath       = $ScriptPath
        ContinueOnError  = $true
    }
    if ($Configuration) { $parameters['Configuration'] = $Configuration }
    if (-not [string]::IsNullOrWhiteSpace($TestPackageContentPath)) { $parameters['TestPackageContentPath'] = $TestPackageContentPath }

    return Initialize-QAFrameworkAgents @parameters
}

function Invoke-QAFrameworkFailoverSwitch {
    <#
    .SYNOPSIS
        Switches every failover pair in the cluster and waits until both agents are back online.
    .DESCRIPTION
        Wraps Start-QAOpsFailoverSwitch and Wait-QAOpsFailoverSwitch. All pairs are switched at
        the same time and awaited together, because a large cluster would otherwise spend the
        agents-online wait once per pair.
    .PARAMETER Topology
        A cluster topology from Get-QAFrameworkClusterTopology.
    .PARAMETER TimeoutSeconds
        How long a switch may take. Defaults to 900 seconds, the legacy agents-online wait.
    .OUTPUTS
        One result object per pair with PairId, Success and Message.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$Topology,
        [Parameter()][int]$TimeoutSeconds = 900
    )

    foreach ($command in @('Start-QAOpsFailoverSwitch', 'Wait-QAOpsFailoverSwitch')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw "$command is not available. Import the QAOps.PowerShell module before running the failover phases."
        }
    }

    $pairs = [object[]]@($Topology.FailoverPairs)
    if ($pairs.Count -eq 0) { return }

    $switches = [System.Collections.Generic.List[object]]::new()

    foreach ($pair in $pairs) {
        try {
            $operation = Start-QAOpsFailoverSwitch -Bridge $pair.Primary.Bridge -PairId $pair.PairId
            $switches.Add([pscustomobject]@{ Pair = $pair; Operation = $operation })
        }
        catch {
            Write-Warning "Could not start the failover switch of pair '$($pair.PairId)': $($_.Exception.Message)"
            [pscustomobject]@{ PairId = $pair.PairId; Success = $false; ActiveBridgeId = $null; Message = $_.Exception.Message }
        }
    }

    foreach ($entry in $switches) {
        try {
            $result = Wait-QAOpsFailoverSwitch -Switch $entry.Operation -TimeoutSeconds $TimeoutSeconds
            $success = [string]::Equals([string]$result.State, 'Completed', [StringComparison]::OrdinalIgnoreCase)

            [pscustomobject]@{
                PairId         = $entry.Pair.PairId
                Success        = $success
                # The same Bridge owns the operation. The response identifies the DataMiner
                # agent that became online by name, not by another Bridge id.
                ActiveBridgeId = if ($success) { $entry.Pair.Primary.BridgeId } else { $null }
                Message        = if ($success) { "Active agent is now '$($result.CurrentOnlineAgentName)'." } else { [string]$result.ErrorMessage }
            }
        }
        catch {
            Write-Warning "The failover switch of pair '$($entry.Pair.PairId)' did not finish: $($_.Exception.Message)"
            [pscustomobject]@{ PairId = $entry.Pair.PairId; Success = $false; ActiveBridgeId = $null; Message = $_.Exception.Message }
        }
    }
}

function Initialize-QAFrameworkAgents {
    <#
    .SYNOPSIS
        Prepares every DataMiner agent in the cluster to run QAFramework tests.
    .DESCRIPTION
        Runs Templates/Initialize-QAFrameworkAgent.ps1 on every DataMiner agent through a QAOps
        Bridge execution, so the orchestrator itself never needs local access to the agents.
        That script installs the automation script runner, writes
        <RtManagerRoot>\Settings\SystemSettings.json and deploys the harvested dependencies.

        The agent script has to be part of the test package, by default at
        TestPackagePipeline/helpers/Initialize-QAFrameworkAgent.ps1 inside the content folder.
    .PARAMETER Topology
        A cluster topology from Get-QAFrameworkClusterTopology.
    .PARAMETER Configuration
        A run configuration from Get-QAFrameworkRunConfiguration. Supplies rtManagerRoot and
        systemSettings.
    .PARAMETER TestPackageContentPath
        The test package content root on the agents. Defaults to the path each bridge reports.
    .PARAMETER ScriptPath
        The path of the agent script relative to the test package content root.
    .PARAMETER FailoverState
        The failover state to write. 0 before the switch, 10 after the switch, 20 after
        switching back.
    .PARAMETER SkipDependencies
        Only rewrite SystemSettings.json. Used between failover phases.
    .PARAMETER TimeoutSeconds
        How long an agent may take to set itself up. Defaults to 1800 seconds because the
        legacy script can wait two minutes for SLAutomation on top of the dependency copy.
    .PARAMETER ContinueOnError
        Report a failing agent instead of throwing, so a run can continue on the healthy ones.
    .EXAMPLE
        Initialize-QAFrameworkAgents -Topology $topology -Configuration $config
    .OUTPUTS
        One result object per agent with BridgeId, Success, ExitCode and Message.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Topology,

        [Parameter()]
        [object]$Configuration,

        [Parameter()]
        [AllowNull()][AllowEmptyString()]
        [string]$TestPackageContentPath,

        [Parameter()]
        [string]$ScriptPath = 'TestPackagePipeline/helpers/Initialize-QAFrameworkAgent.ps1',

        [Parameter()]
        [ValidateRange(0, 100)]
        [int]$FailoverState = 0,

        [Parameter()]
        [switch]$SkipDependencies,

        [Parameter()]
        [int]$TimeoutSeconds = 1800,

        [Parameter()]
        [switch]$ContinueOnError
    )

    foreach ($command in @('Start-QAOpsBridgeExecution', 'Wait-QAOpsBridgeExecution')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw "$command is not available. Import the QAOps.PowerShell module before initialising the agents."
        }
    }

    $agents = [object[]]@($Topology.Agents)
    if ($agents.Count -eq 0) {
        throw 'The cluster topology contains no DataMiner agent to initialise.'
    }

    $rtManagerRoot = 'C:\RTManager\'
    $systemSettings = $null
    if ($Configuration) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Configuration.rtManagerRoot)) { $rtManagerRoot = [string]$Configuration.rtManagerRoot }
        if ($Configuration.systemSettings) {
            $settingsJson = $Configuration.systemSettings | ConvertTo-Json -Depth 5 -Compress
            if ($settingsJson -and $settingsJson -ne '{}' -and $settingsJson -ne 'null') { $systemSettings = $settingsJson }
        }
    }

    $started = [System.Collections.Generic.List[object]]::new()

    foreach ($agent in $agents) {
        # Paths sent to a Bridge are relative to that bridge's extracted package root.
        $scriptFullPath = ($ScriptPath -replace '\\', '/').TrimStart('/')

        $arguments = [System.Collections.Generic.List[string]]::new()
        $arguments.AddRange([string[]]@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptFullPath))
        $arguments.AddRange([string[]]@('-PathToTestPackageContent', '.'))
        $arguments.AddRange([string[]]@('-RtManagerRoot', $rtManagerRoot))
        $arguments.AddRange([string[]]@('-FailoverState', [string]$FailoverState))
        if ($systemSettings) { $arguments.AddRange([string[]]@('-SystemSettings', $systemSettings)) }
        if ($SkipDependencies) { $arguments.Add('-SkipDependencies') }

        if (-not $PSCmdlet.ShouldProcess($agent.BridgeId, 'Initialize QAFramework agent')) { continue }

        try {
            $execution = Start-QAOpsBridgeExecution -Bridge $agent.Bridge -Executable 'pwsh' -Arguments ([string[]]$arguments) -TimeoutSeconds $TimeoutSeconds
            $started.Add([pscustomobject]@{ Agent = $agent; Execution = $execution })
        }
        catch {
            $failure = [pscustomobject]@{
                BridgeId = $agent.BridgeId
                Success  = $false
                ExitCode = $null
                Message  = "Could not start the agent setup: $($_.Exception.Message)"
            }

            if (-not $ContinueOnError) { throw $failure.Message }
            Write-Warning $failure.Message
            $failure
        }
    }

    if ($started.Count -eq 0) { return }

    $null = Wait-QAOpsBridgeExecution -Execution ([object[]]@($started | ForEach-Object { $_.Execution })) -TimeoutSeconds $TimeoutSeconds

    $failures = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $started) {
        $state = Get-QAOpsBridgeExecution -Execution $entry.Execution
        $outcome = Get-QAFrameworkExecutionOutcome -Execution $state
        $success = ($outcome.Outcome -eq 'Ok')

        if (-not $success) { $failures.Add("$($entry.Agent.BridgeId): $($outcome.Message)") }

        [pscustomobject]@{
            BridgeId = $entry.Agent.BridgeId
            Success  = $success
            ExitCode = if ($state) { $state.ExitCode } else { $null }
            Message  = $outcome.Message
        }
    }

    if ($failures.Count -gt 0 -and -not $ContinueOnError) {
        throw "QAFramework agent setup failed on $($failures.Count) agent(s):$([Environment]::NewLine)$($failures -join [Environment]::NewLine)"
    }
}

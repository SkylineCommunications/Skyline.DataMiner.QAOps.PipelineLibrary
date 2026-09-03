function Invoke-QAFrameworkTestRun {
    <#
    .SYNOPSIS
        Runs a QAFramework execution plan across the QAOps cluster.
    .DESCRIPTION
        Walks the phases of an execution plan and schedules its work items on the DataMiner
        agents of the cluster through Start-QAOpsBridgeExecution, reproducing the behaviour of
        the legacy TaskSchedulerAndRunner:

        - every agent has a fixed capacity (3 by default) and every running test consumes its
          weight, so a weight 3 test owns an agent while two weight 1 tests share one,
        - maxTestsInCluster caps how many tests run simultaneously across the whole cluster,
        - the PreRun and NonConcurrent phases always run one test at a time,
        - a test pinned by TargetDMA only runs on its agent and takes precedence there.

        The orchestrator never runs a test itself, so the library also works on a QAOps Bridge
        without DataMiner, for example an Ubuntu machine in the cluster.

        Every finished work item is published immediately, so a long run reports progress
        instead of only at the end.
    .PARAMETER Plan
        An execution plan from New-QAFrameworkExecutionPlan.
    .PARAMETER Topology
        A cluster topology from Get-QAFrameworkClusterTopology.
    .PARAMETER Configuration
        A run configuration from Get-QAFrameworkRunConfiguration.
    .PARAMETER TestPackageContentPath
        The test package content root on the agents, used to locate TestPackagePipeline.
    .PARAMETER SkipPublish
        Do not publish results to QAOps. Useful for a dry run.
    .PARAMETER SkipFailoverOrchestration
        Do not switch failover pairs and do not rewrite FailoverState. The failover phases then
        run against the cluster as it is.
    .PARAMETER AgentScriptPath
        The path of Initialize-QAFrameworkAgent.ps1 relative to the test package content root,
        used to rewrite FailoverState between the failover phases.
    .PARAMETER FailoverTimeoutSeconds
        How long a failover switch may take, including waiting for both agents to come back
        online. Defaults to the legacy 900 seconds.
    .PARAMETER MaximumRunTimeSeconds
        A safety net that stops scheduling new work when the run takes longer than expected.
        Defaults to no limit.
    .EXAMPLE
        $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $topology -Configuration $config
        $run.Summary
    .OUTPUTS
        A run result object with WorkItems, Summary and Phases.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [object]$Topology,

        [Parameter()]
        [object]$Configuration,

        [Parameter()]
        [AllowNull()][AllowEmptyString()]
        [string]$TestPackageContentPath,

        [Parameter()]
        [switch]$SkipPublish,

        [Parameter()]
        [switch]$SkipFailoverOrchestration,

        [Parameter()]
        [string]$AgentScriptPath = 'TestPackagePipeline/helpers/Initialize-QAFrameworkAgent.ps1',

        [Parameter()]
        [int]$FailoverTimeoutSeconds = 900,

        [Parameter()]
        [int]$MaximumRunTimeSeconds = 0
    )

    foreach ($command in @('Start-QAOpsBridgeExecution', 'Wait-QAOpsBridgeExecution', 'Get-QAOpsBridgeExecution', 'Stop-QAOpsBridgeExecution')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw "$command is not available. Import the QAOps.PowerShell module before starting a QAFramework test run."
        }
    }

    $agents = [object[]]@($Topology.Agents)
    if ($agents.Count -eq 0) {
        throw 'The cluster topology contains no DataMiner agent to run tests on.'
    }

    $agentCapacity = 3
    $maxTestsInCluster = [int]::MaxValue
    $tickSeconds = 10

    if ($Configuration) {
        if ($Configuration.agentCapacity -gt 0) { $agentCapacity = [int]$Configuration.agentCapacity }
        if ($Configuration.maxTestsInCluster -gt 0) { $maxTestsInCluster = [int]$Configuration.maxTestsInCluster }
        if ($Configuration.schedulerTickSeconds -gt 0) { $tickSeconds = [int]$Configuration.schedulerTickSeconds }
    }

    $workItems = [object[]]@($Plan.WorkItems)
    $deadline = if ($MaximumRunTimeSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($MaximumRunTimeSeconds) } else { [DateTime]::MaxValue }

    $currentFailoverState = 0
    $switched = $false
    $switchedBack = $false
    $failoverLog = [System.Collections.Generic.List[object]]::new()

    $collectLogsOnFailure = [bool]($Configuration -and $Configuration.logCollectionOnFailure)
    $logsCollected = $false

    $publishedNames = @{}
    foreach ($item in $workItems) {
        $key = [string]$item.Name
        $publishedNames[$key] = [int]$publishedNames[$key] + 1
    }

    $updateActiveAgents = {
        param([object[]]$SwitchResults)

        foreach ($result in $SwitchResults) {
            if (-not $result.Success -or -not $result.ActiveBridgeId) { continue }

            foreach ($item in $workItems) {
                if ($item.State -ne 'Pending') { continue }
                if ($item.FailoverPairId -ne $result.PairId) { continue }
                $item.TargetBridgeId = $result.ActiveBridgeId
            }
        }
    }

    $completeItem = {
        param([object]$Item, [string]$Outcome, [string]$Message)

        $Item.State = 'Completed'
        $Item.Outcome = $Outcome
        $Item.Message = $Message
        if (-not $Item.CompletedAt) { $Item.CompletedAt = [DateTime]::UtcNow }

        if (-not $SkipPublish) {
            $includeAgent = ($publishedNames[[string]$Item.Name] -gt 1)
            $null = Publish-QAFrameworkTestResult -WorkItem $Item -IncludeAgentInName:$includeAgent
        }
    }

    $running = [System.Collections.Generic.List[object]]::new()

    try {
    foreach ($phase in $Plan.Phases) {
        $phaseItems = [object[]]@($workItems | Where-Object { $_.Phase -eq $phase })
        if ($phaseItems.Count -eq 0) { continue }

        $phaseCap = $maxTestsInCluster
        if ($phase -in @('PreRun', 'NonConcurrent', 'FailoverDirectBeforeSwitch', 'FailoverDirectAfterSwitch')) { $phaseCap = 1 }

        # Failover phases need the cluster in the right state before the tests start, and the
        # switch itself happens between the before and after phases.
        if ($phase -like 'Failover*' -and -not $SkipFailoverOrchestration) {
            $requiredState = Get-QAFrameworkFailoverStateValue -Phase $phase

            if ($requiredState -gt 0 -and -not $switched) {
                Write-Verbose 'Switching every failover pair in the cluster.'
                $switchResults = @(Invoke-QAFrameworkFailoverSwitch -Topology $Topology -TimeoutSeconds $FailoverTimeoutSeconds)
                $failoverLog.AddRange([object[]]$switchResults)
                & $updateActiveAgents $switchResults
                $switched = $true

                if (@($switchResults | Where-Object { -not $_.Success }).Count -gt 0) {
                    Write-Warning 'At least one failover pair did not switch; the failover tests of that pair will most likely fail.'
                }
            }

            if ($requiredState -eq 20 -and -not $switchedBack) {
                Write-Verbose 'Switching every failover pair back to its original agent.'
                $switchResults = @(Invoke-QAFrameworkFailoverSwitch -Topology $Topology -TimeoutSeconds $FailoverTimeoutSeconds)
                $failoverLog.AddRange([object[]]$switchResults)
                & $updateActiveAgents $switchResults
                $switchedBack = $true
            }

            if ($currentFailoverState -ne $requiredState) {
                Write-Verbose "Setting FailoverState $requiredState on every agent."
                $null = Set-QAFrameworkFailoverState -Topology $Topology -State $requiredState -Configuration $Configuration -TestPackageContentPath $TestPackageContentPath -ScriptPath $AgentScriptPath
                $currentFailoverState = $requiredState
            }
        }

        Write-Verbose "Phase '$phase': $($phaseItems.Count) work item(s), at most $phaseCap running in the cluster."

        $running = [System.Collections.Generic.List[object]]::new()

        while ($true) {
            $pending = @($phaseItems | Where-Object { $_.State -eq 'Pending' })
            if ($pending.Count -eq 0 -and $running.Count -eq 0) { break }

            $started = 0

            if ([DateTime]::UtcNow -lt $deadline) {
                foreach ($agent in $agents) {
                    while ($running.Count -lt $phaseCap) {
                        $usedWeight = 0
                        foreach ($entry in $running) {
                            if ($entry.WorkItem.RunningOnBridgeId -eq $agent.BridgeId) { $usedWeight += [int]$entry.WorkItem.Weight }
                        }

                        $free = $agentCapacity - $usedWeight
                        if ($free -le 0) { break }

                        $candidate = Select-QAFrameworkNextWorkItem -WorkItem $pending -BridgeId $agent.BridgeId -FreeWeight $free
                        if (-not $candidate) { break }

                        $contentPath = $TestPackageContentPath
                        if ([string]::IsNullOrWhiteSpace($contentPath)) { $contentPath = [string]$agent.TestPackageContentPath }

                        $command = New-QAFrameworkExecutionCommand -WorkItem $candidate -TestPackageContentPath $contentPath -Configuration $Configuration

                        try {
                            $execution = Start-QAOpsBridgeExecution -Bridge $agent.Bridge -Executable $command.Executable -Arguments $command.Arguments -WorkingDirectory $command.WorkingDirectory -TimeoutSeconds $command.TimeoutSeconds
                        }
                        catch {
                            $candidate.Attempt++
                            & $completeItem $candidate 'Fail' "Could not start the test on agent '$($agent.BridgeId)': $($_.Exception.Message)"
                            $pending = @($phaseItems | Where-Object { $_.State -eq 'Pending' })
                            continue
                        }

                        $candidate.State = 'Running'
                        $candidate.Attempt++
                        $candidate.ExecutionId = $execution.Id
                        $candidate.StartedAt = [DateTime]::UtcNow
                        Add-Member -InputObject $candidate -NotePropertyName 'RunningOnBridgeId' -NotePropertyValue $agent.BridgeId -Force

                        $running.Add([pscustomobject]@{ WorkItem = $candidate; Execution = $execution })
                        $started++

                        Write-Verbose "Started '$($candidate.Name)' (weight $($candidate.Weight)) on agent '$($agent.BridgeId)'."

                        $pending = @($phaseItems | Where-Object { $_.State -eq 'Pending' })
                    }

                    if ($running.Count -ge $phaseCap) { break }
                }
            }

            if ($running.Count -eq 0) {
                if ($started -eq 0) {
                    # Nothing runs and nothing could be started, so the rest is unschedulable.
                    foreach ($item in $pending) {
                        $reason = if ([DateTime]::UtcNow -ge $deadline) {
                            'The maximum run time of the test run was reached before this test could start.'
                        }
                        else {
                            "No agent in the cluster can run this test (TargetDMA '$($item.Test.targetDma)', weight $($item.Weight))."
                        }
                        & $completeItem $item 'NotExecuted' $reason
                    }
                    break
                }
                continue
            }

            # Wait-QAOpsBridgeExecution treats its timeout as a terminating failure. A timeout
            # here only means that no execution completed during this scheduler tick.
            try {
                $executions = [object[]]@($running | ForEach-Object { $_.Execution })
                $updated = @(Wait-QAOpsBridgeExecution -Execution $executions -Any -TimeoutSeconds $tickSeconds)
            }
            catch {
                if ($_.FullyQualifiedErrorId -notlike 'QAOpsExecutionTimeout*' -and
                    $_.Exception -isnot [System.TimeoutException]) {
                    throw
                }

                $updated = @(
                    foreach ($entry in $running) {
                        Get-QAOpsBridgeExecution -Execution $entry.Execution
                    }
                )
            }

            $now = [DateTime]::UtcNow
            $testTimeoutSeconds = if ($Configuration -and $Configuration.testTimeoutSeconds -gt 0) {
                [int]$Configuration.testTimeoutSeconds
            }
            else {
                7200
            }

            foreach ($entry in @($running)) {
                if (-not $entry.WorkItem.StartedAt) { continue }
                if (($now - [DateTime]$entry.WorkItem.StartedAt).TotalSeconds -lt $testTimeoutSeconds) { continue }

                try {
                    Stop-QAOpsBridgeExecution -Execution $entry.Execution -ErrorAction Continue
                }
                catch {
                    Write-Warning "Could not stop timed-out execution '$($entry.Execution.Id)': $($_.Exception.Message)"
                }

                $entry.WorkItem.CompletedAt = $now
                & $completeItem $entry.WorkItem 'Fail' "The test exceeded its maximum run time of $testTimeoutSeconds seconds."
                [void]$running.Remove($entry)
            }

            $finishedAny = $false
            foreach ($state in $updated) {
                if (-not $state -or -not $state.IsFinished) { continue }

                $entry = $running | Where-Object { $_.Execution.Id -eq $state.Id } | Select-Object -First 1
                if (-not $entry) { continue }

                $finishedAny = $true
                $outcome = Get-QAFrameworkExecutionOutcome -Execution $state
                $entry.WorkItem.CompletedAt = [DateTime]::UtcNow
                & $completeItem $entry.WorkItem $outcome.Outcome $outcome.Message

                if ($outcome.Outcome -eq 'Fail' -and $collectLogsOnFailure -and -not $logsCollected) {
                    $logsCollected = $true
                    $failingAgent = $agents | Where-Object { $_.BridgeId -eq $entry.WorkItem.RunningOnBridgeId } | Select-Object -First 1
                    if ($failingAgent) { $null = Invoke-QAFrameworkLogCollection -Agent $failingAgent }
                }

                Write-Verbose "Finished '$($entry.WorkItem.Name)' with outcome $($outcome.Outcome)."
                [void]$running.Remove($entry)
            }

            if (-not $finishedAny -and $started -eq 0 -and $tickSeconds -gt 0) {
                # Nothing changed during this tick; Wait already blocked, so just loop again.
                Write-Verbose "Phase '$phase': waiting for $($running.Count) running test(s)."
            }
        }
    }

    }
    finally {
        foreach ($entry in @($running)) {
            try {
                Stop-QAOpsBridgeExecution -Execution $entry.Execution -ErrorAction Continue
            }
            catch {
                Write-Warning "Could not stop execution '$($entry.Execution.Id)' while cleaning up the run: $($_.Exception.Message)"
            }
        }

        if ($switched -and -not $switchedBack -and -not $SkipFailoverOrchestration) {
            try {
                Write-Verbose 'Restoring every failover pair to its original agent.'
                $failoverLog.AddRange([object[]]@(Invoke-QAFrameworkFailoverSwitch -Topology $Topology -TimeoutSeconds $FailoverTimeoutSeconds))
                $switchedBack = $true
            }
            catch {
                Write-Warning "Could not restore the failover pairs: $($_.Exception.Message)"
            }
        }

        if ($currentFailoverState -ne 0 -and -not $SkipFailoverOrchestration) {
            try {
                $null = Set-QAFrameworkFailoverState -Topology $Topology -State 0 -Configuration $Configuration -TestPackageContentPath $TestPackageContentPath -ScriptPath $AgentScriptPath
            }
            catch {
                Write-Warning "Could not reset FailoverState to 0: $($_.Exception.Message)"
            }
        }
    }

    $summary = [ordered]@{
        Total         = $workItems.Count
        Ok            = @($workItems | Where-Object { $_.Outcome -eq 'Ok' }).Count
        Fail          = @($workItems | Where-Object { $_.Outcome -eq 'Fail' }).Count
        NotApplicable = @($workItems | Where-Object { $_.Outcome -eq 'NotApplicable' }).Count
        NotExecuted   = @($workItems | Where-Object { $_.Outcome -eq 'NotExecuted' }).Count
    }

    return [pscustomobject]@{
        Phases          = [string[]]@($Plan.Phases)
        WorkItems       = $workItems
        Summary         = [pscustomobject]$summary
        HasFailed       = ($summary.Fail -gt 0)
        FailoverSwitches = [object[]]$failoverLog
    }
}

function New-QAFrameworkExecutionPlan {
    <#
    .SYNOPSIS
        Turns selected QAFramework tests into an ordered plan of executable work items.
    .DESCRIPTION
        Assigns every test to the phases the legacy TaskSchedulerAndRunner used, expands the
        TargetDMA attribute into concrete agents and produces one work item per execution that
        has to be started through Start-QAOpsBridgeExecution.

        Phase order:

        PreRun                     - PreRunFixture tests, one at a time, honouring preRunFilter.
        DiagnosticsBefore          - DiagnosticTestFixture with run type Before or BeforeAndAfter.
        Main                       - Standard fixtures, and failover fixtures that have a
                                     BeforeSwitch method, that may run concurrently.
        NonConcurrent              - tests with CanRunConcurrently(false), cluster exclusive.
        FailoverDirectBeforeSwitch - failover tests with RunDirectBeforeSwitch.
        FailoverDirectAfterSwitch  - failover tests with RunDirectAfterSwitch.
        FailoverAfterSwitch        - failover tests with an AfterSwitch method.
        FailoverAfterSwitchBack    - failover tests with an AfterSwitchBack method.
        DiagnosticsAfter           - DiagnosticTestFixture with run type After or BeforeAndAfter.

        A single failover test legitimately produces several work items because the legacy
        runner executes the same script once per failover state.
    .PARAMETER Test
        The selected schema v1 test metadata, typically Select-QAFrameworkTest .Selected.
    .PARAMETER Topology
        A cluster topology from Get-QAFrameworkClusterTopology. Without it every work item is
        scheduled on any available agent.
    .PARAMETER Configuration
        A run configuration from Get-QAFrameworkRunConfiguration. Supplies preRunFilter,
        includeNonConcurrent, disableFailoverRun and agentCapacity.
    .EXAMPLE
        $plan = New-QAFrameworkExecutionPlan -Test $selection.Selected -Topology $topology -Configuration $config
        $plan.WorkItems | Group-Object Phase | Select-Object Name, Count
    .OUTPUTS
        A plan object with WorkItems, Phases and Skipped collections.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyCollection()]
        [object[]]$Test,

        [Parameter()]
        [object]$Topology,

        [Parameter()]
        [object]$Configuration
    )

    begin {
        $all = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Test) {
            if ($null -ne $item) { [void]$all.Add($item) }
        }
    }

    end {
        $workItems = [System.Collections.Generic.List[object]]::new()
        $skipped = [System.Collections.Generic.List[object]]::new()

        $preRunFilter = 'all'
        $includeNonConcurrent = $true
        $disableFailoverRun = $false
        $agentCapacity = 3

        if ($Configuration) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Configuration.preRunFilter)) { $preRunFilter = [string]$Configuration.preRunFilter }
            if ($null -ne $Configuration.includeNonConcurrent) { $includeNonConcurrent = [bool]$Configuration.includeNonConcurrent }
            if ($null -ne $Configuration.disableFailoverRun) { $disableFailoverRun = [bool]$Configuration.disableFailoverRun }
            if ($Configuration.agentCapacity -gt 0) { $agentCapacity = [int]$Configuration.agentCapacity }
        }

        $hasFailover = [bool]($Topology -and $Topology.HasFailover)
        $runFailoverPhases = $hasFailover -and -not $disableFailoverRun

        $addWorkItem = {
            param([object]$Metadata, [string]$Phase)

            $isFailoverFixture = [string]::Equals([string]$Metadata.fixture, 'Failover', [StringComparison]::OrdinalIgnoreCase)
            $isFailoverPhase = $Phase -like 'Failover*'
            $resolved = Resolve-QAFrameworkTargetAgent -TargetDma $Metadata.targetDma -Topology $Topology -PreferFailoverAgents:($isFailoverFixture -and $isFailoverPhase)

            if (-not $resolved.IsAnyAgent -and $resolved.Agents.Count -eq 0) {
                $skipped.Add([pscustomobject]@{
                        Name   = $Metadata.name
                        Phase  = $Phase
                        Reason = "TargetDMA '$($Metadata.targetDma)' could not be resolved. $($resolved.Reason)".Trim()
                        Test   = $Metadata
                    })
                return
            }

            $weight = 1
            if ($Metadata.weight -gt 0) { $weight = [int]$Metadata.weight }
            if ($weight -gt $agentCapacity) { $weight = $agentCapacity }

            $targets = [object[]]@($resolved.Agents)
            if ($resolved.IsAnyAgent) { $targets = [object[]]@($null) }

            $pairIds = @{}

            # A failover phase runs once per failover pair, on the agent that is active at that
            # moment. The plan pins the primary agent; the run updates it after every switch.
            if ($isFailoverPhase -and $Topology) {
                $pairs = [object[]]@($Topology.FailoverPairs)
                if ($pairs.Count -gt 0) {
                    $targets = [object[]]@($pairs | ForEach-Object { $_.Primary })
                    foreach ($pair in $pairs) { $pairIds[$pair.Primary.BridgeId] = $pair.PairId }
                }
            }

            foreach ($target in $targets) {
                $sequenceNumber = $workItems.Count + 1

                $workItems.Add([pscustomobject]@{
                        Id             = ('{0}#{1:D4}' -f $Metadata.name, $sequenceNumber)
                        Name           = [string]$Metadata.name
                        Phase          = $Phase
                        Weight         = $weight
                        TargetBridgeId = if ($target) { $target.BridgeId } else { $null }
                        TargetDmaId    = if ($target) { $target.DmaId } else { $null }
                        FailoverPairId = if ($target -and $pairIds.ContainsKey($target.BridgeId)) { $pairIds[$target.BridgeId] } else { $null }
                        Test           = $Metadata
                        State          = 'Pending'
                        ExecutionId    = $null
                        Outcome        = $null
                        Message        = $null
                        StartedAt      = $null
                        CompletedAt    = $null
                        Attempt        = 0
                    })
            }
        }

        foreach ($metadata in $all) {
            $fixture = [string]$metadata.fixture
            if ([string]::IsNullOrWhiteSpace($fixture)) { $fixture = 'Standard' }

            $failover = $metadata.failover
            $canRunConcurrently = $true
            if ($null -ne $metadata.canRunConcurrently) { $canRunConcurrently = [bool]$metadata.canRunConcurrently }

            switch -Regex ($fixture) {
                '^(?i)PreRun$' {
                    if (Test-QAFrameworkPreRunFilter -Name $metadata.name -Filter $preRunFilter) {
                        & $addWorkItem $metadata 'PreRun'
                    }
                    else {
                        $skipped.Add([pscustomobject]@{
                                Name   = $metadata.name
                                Phase  = 'PreRun'
                                Reason = "The pre-run filter '$preRunFilter' does not match this test."
                                Test   = $metadata
                            })
                    }
                    break
                }

                '^(?i)Diagnostic$' {
                    $runType = [string]$metadata.diagnosticRunType
                    if ([string]::IsNullOrWhiteSpace($runType)) { $runType = 'BeforeAndAfter' }

                    if ($runType -in @('Before', 'BeforeAndAfter')) { & $addWorkItem $metadata 'DiagnosticsBefore' }
                    if ($runType -in @('After', 'BeforeAndAfter')) { & $addWorkItem $metadata 'DiagnosticsAfter' }
                    break
                }

                '^(?i)Failover$' {
                    $runsOnNonFailover = [bool]($failover -and $failover.runOnNonFailoverSystems)

                    # The BeforeSwitch part runs in the regular pool while the cluster is still
                    # in its BeforeSwitch state, exactly as the legacy runner does.
                    if (-not $failover -or $failover.hasBeforeSwitch -or $runsOnNonFailover) {
                        $phase = if ($canRunConcurrently) { 'Main' } else { 'NonConcurrent' }
                        if ($phase -ne 'NonConcurrent' -or $includeNonConcurrent) { & $addWorkItem $metadata $phase }
                    }

                    if ($runFailoverPhases -and $failover) {
                        if ($failover.runDirectBeforeSwitch) { & $addWorkItem $metadata 'FailoverDirectBeforeSwitch' }
                        if ($failover.runDirectAfterSwitch) { & $addWorkItem $metadata 'FailoverDirectAfterSwitch' }
                        if ($failover.hasAfterSwitch) { & $addWorkItem $metadata 'FailoverAfterSwitch' }
                        if ($failover.hasAfterSwitchBack) { & $addWorkItem $metadata 'FailoverAfterSwitchBack' }
                    }
                    break
                }

                default {
                    if ($canRunConcurrently) {
                        & $addWorkItem $metadata 'Main'
                    }
                    elseif ($includeNonConcurrent) {
                        & $addWorkItem $metadata 'NonConcurrent'
                    }
                    else {
                        $skipped.Add([pscustomobject]@{
                                Name   = $metadata.name
                                Phase  = 'NonConcurrent'
                                Reason = 'Tests that cannot run concurrently are excluded from this run.'
                                Test   = $metadata
                            })
                    }
                    break
                }
            }
        }

        $order = @(
            'PreRun'
            'DiagnosticsBefore'
            'Main'
            'NonConcurrent'
            'FailoverDirectBeforeSwitch'
            'FailoverDirectAfterSwitch'
            'FailoverAfterSwitch'
            'FailoverAfterSwitchBack'
            'DiagnosticsAfter'
        )

        $used = [System.Collections.Generic.List[string]]::new()
        foreach ($phase in $order) {
            if ($workItems | Where-Object { $_.Phase -eq $phase }) { $used.Add($phase) }
        }

        return [pscustomobject]@{
            Phases    = [string[]]$used
            WorkItems = [object[]]$workItems
            Skipped   = [object[]]$skipped
        }
    }
}

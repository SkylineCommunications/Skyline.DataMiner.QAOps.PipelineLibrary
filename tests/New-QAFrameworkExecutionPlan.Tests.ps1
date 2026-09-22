BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force

    function New-PlanTest {
        param([hashtable]$Override = @{})

        $test = @{
            name               = 'RT_Sample'
            fixture            = 'Standard'
            diagnosticRunType  = $null
            failover           = $null
            weight             = 1
            canRunConcurrently = $true
            targetDma          = 'One'
        }

        foreach ($key in $Override.Keys) { $test[$key] = $Override[$key] }
        return [pscustomobject]$test
    }

    function New-Agent {
        param([string]$BridgeId, [int]$DmaId, [bool]$IsFailover = $false, [string]$Partner = $null)

        return [pscustomobject]@{
            BridgeId               = $BridgeId
            Name                   = $BridgeId
            DmaId                  = $DmaId
            IsFailover             = $IsFailover
            FailoverPartnerBridgeId = $Partner
            HasDataMiner           = $true
        }
    }

    function New-PlanTopology {
        param([object[]]$Agents, [object[]]$Pairs = @())

        return [pscustomobject]@{
            Name             = 'cluster'
            Agents           = [object[]]$Agents
            FailoverPairs    = [object[]]$Pairs
            HasFailover      = ($Pairs.Count -gt 0)
            LowestDmaId      = ($Agents | Sort-Object DmaId | Select-Object -First 1).DmaId
            HighestDmaId     = ($Agents | Sort-Object DmaId | Select-Object -Last 1).DmaId
            DataMinerVersion = $null
            DbmsType         = ''
            IsCentralized    = $false
            IsRedGreen       = $false
            Labels           = @{}
            SolutionVersions = @{}
            IsClusterKnown   = $true
        }
    }

    function New-PlanConfiguration {
        param([hashtable]$Override = @{})

        $config = @{
            preRunFilter         = 'all'
            includeNonConcurrent = $true
            disableFailoverRun   = $false
            agentCapacity        = 3
        }

        foreach ($key in $Override.Keys) { $config[$key] = $Override[$key] }
        return [pscustomobject]$config
    }

    $script:ThreeAgents = @(
        (New-Agent -BridgeId 'b1' -DmaId 10),
        (New-Agent -BridgeId 'b2' -DmaId 5),
        (New-Agent -BridgeId 'b3' -DmaId 20)
    )
}

Describe 'New-QAFrameworkExecutionPlan' {

    Context 'phase assignment' {
        It 'puts a standard test in the main phase' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest)

            $plan.WorkItems.Count | Should -Be 1
            $plan.WorkItems[0].Phase | Should -Be 'Main'
            $plan.Phases | Should -Be @('Main')
        }

        It 'puts a non-concurrent test in its own phase' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ canRunConcurrently = $false })

            $plan.WorkItems[0].Phase | Should -Be 'NonConcurrent'
        }

        It 'skips non-concurrent tests when the run excludes them' {
            $config = New-PlanConfiguration @{ includeNonConcurrent = $false }
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ canRunConcurrently = $false }) -Configuration $config

            $plan.WorkItems.Count | Should -Be 0
            $plan.Skipped[0].Reason | Should -BeLike '*cannot run concurrently*'
        }

        It 'runs a BeforeAndAfter diagnostic test twice' {
            $test = New-PlanTest @{ fixture = 'Diagnostic'; diagnosticRunType = 'BeforeAndAfter' }
            $plan = New-QAFrameworkExecutionPlan -Test $test

            $plan.WorkItems.Phase | Should -Be @('DiagnosticsBefore', 'DiagnosticsAfter')
        }

        It 'runs an After diagnostic test only afterwards' {
            $test = New-PlanTest @{ fixture = 'Diagnostic'; diagnosticRunType = 'After' }
            (New-QAFrameworkExecutionPlan -Test $test).WorkItems.Phase | Should -Be 'DiagnosticsAfter'
        }

        It 'orders the phases the way the legacy runner does' {
            $tests = @(
                (New-PlanTest @{ name = 'RT_Main' }),
                (New-PlanTest @{ name = 'RT_Diag'; fixture = 'Diagnostic'; diagnosticRunType = 'BeforeAndAfter' }),
                (New-PlanTest @{ name = 'RT_Pre'; fixture = 'PreRun' }),
                (New-PlanTest @{ name = 'RT_Serial'; canRunConcurrently = $false })
            )
            $plan = New-QAFrameworkExecutionPlan -Test $tests

            $plan.Phases | Should -Be @('PreRun', 'DiagnosticsBefore', 'Main', 'NonConcurrent', 'DiagnosticsAfter')
        }
    }

    Context 'pre-run filter' {
        It 'schedules every pre-run test for all' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ fixture = 'PreRun' }) -Configuration (New-PlanConfiguration)
            $plan.WorkItems.Count | Should -Be 1
        }

        It 'schedules no pre-run test for none' {
            $config = New-PlanConfiguration @{ preRunFilter = 'none' }
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ fixture = 'PreRun' }) -Configuration $config

            $plan.WorkItems.Count | Should -Be 0
            $plan.Skipped[0].Reason | Should -BeLike '*pre-run filter*'
        }

        It 'treats any other value as a regular expression' {
            $tests = @(
                (New-PlanTest @{ name = 'RT_PreRun_Upgrade'; fixture = 'PreRun' }),
                (New-PlanTest @{ name = 'RT_PreRun_Licenses'; fixture = 'PreRun' })
            )
            $config = New-PlanConfiguration @{ preRunFilter = 'Upgrade' }
            $plan = New-QAFrameworkExecutionPlan -Test $tests -Configuration $config

            $plan.WorkItems.Count | Should -Be 1
            $plan.WorkItems[0].Name | Should -Be 'RT_PreRun_Upgrade'
        }
    }

    Context 'TargetDMA expansion' {
        It 'leaves TargetDMA One unpinned' {
            $topology = New-PlanTopology -Agents $script:ThreeAgents
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest) -Topology $topology

            $plan.WorkItems.Count | Should -Be 1
            $plan.WorkItems[0].TargetBridgeId | Should -BeNullOrEmpty
        }

        It 'clones a TargetDMA All test once per agent' {
            $topology = New-PlanTopology -Agents $script:ThreeAgents
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ targetDma = 'All' }) -Topology $topology

            $plan.WorkItems.Count | Should -Be 3
            ($plan.WorkItems.TargetBridgeId | Sort-Object) | Should -Be @('b1', 'b2', 'b3')
            ($plan.WorkItems.Id | Select-Object -Unique).Count | Should -Be 3
        }

        It 'pins LowestDMAID to the agent with the lowest DmaId' {
            $topology = New-PlanTopology -Agents $script:ThreeAgents
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ targetDma = 'LowestDMAID' }) -Topology $topology

            $plan.WorkItems.Count | Should -Be 1
            $plan.WorkItems[0].TargetBridgeId | Should -Be 'b2'
            $plan.WorkItems[0].TargetDmaId | Should -Be 5
        }

        It 'pins HighestDMAID to the agent with the highest DmaId' {
            $topology = New-PlanTopology -Agents $script:ThreeAgents
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ targetDma = 'HighestDMAID' }) -Topology $topology

            $plan.WorkItems[0].TargetBridgeId | Should -Be 'b3'
        }

        It 'clones AllFailovers over the failover agents only' {
            $agents = @(
                (New-Agent -BridgeId 'b1' -DmaId 1 -IsFailover $true -Partner 'b2'),
                (New-Agent -BridgeId 'b2' -DmaId 2 -IsFailover $true -Partner 'b1'),
                (New-Agent -BridgeId 'b3' -DmaId 3)
            )
            $pairs = @([pscustomobject]@{ PairId = 'b1|b2'; Primary = $agents[0]; Partner = $agents[1] })
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ targetDma = 'AllFailovers' }) -Topology (New-PlanTopology -Agents $agents -Pairs $pairs)

            ($plan.WorkItems.TargetBridgeId | Sort-Object) | Should -Be @('b1', 'b2')
        }

        It 'skips an AllFailovers test when the cluster has no failover agents' {
            $topology = New-PlanTopology -Agents $script:ThreeAgents
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ targetDma = 'AllFailovers' }) -Topology $topology

            $plan.WorkItems.Count | Should -Be 0
            $plan.Skipped[0].Reason | Should -BeLike '*no failover agents*'
        }

        It 'falls back to any agent when the topology is unknown' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ targetDma = 'All' })

            $plan.WorkItems.Count | Should -Be 1
            $plan.WorkItems[0].TargetBridgeId | Should -BeNullOrEmpty
        }
    }

    Context 'failover phases' {
        BeforeAll {
            $script:FailoverAgents = @(
                (New-Agent -BridgeId 'f1' -DmaId 1 -IsFailover $true -Partner 'f2'),
                (New-Agent -BridgeId 'f2' -DmaId 2 -IsFailover $true -Partner 'f1')
            )
            $script:FailoverPairs = @([pscustomobject]@{ PairId = 'f1|f2'; Primary = $script:FailoverAgents[0]; Partner = $script:FailoverAgents[1] })

            $script:FailoverTest = New-PlanTest @{
                name     = 'RT_Failover'
                fixture  = 'Failover'
                failover = [pscustomobject]@{
                    runDirectBeforeSwitch   = $true
                    runDirectAfterSwitch    = $false
                    runOnNonFailoverSystems = $false
                    hasBeforeSwitch         = $true
                    hasAfterSwitch          = $true
                    hasAfterSwitchBack      = $true
                }
            }
        }

        It 'creates one work item per failover state' {
            $topology = New-PlanTopology -Agents $script:FailoverAgents -Pairs $script:FailoverPairs
            $plan = New-QAFrameworkExecutionPlan -Test $script:FailoverTest -Topology $topology

            $plan.Phases | Should -Be @('Main', 'FailoverDirectBeforeSwitch', 'FailoverAfterSwitch', 'FailoverAfterSwitchBack')
        }

        It 'pins failover phase work items to failover agents' {
            $agents = $script:FailoverAgents + (New-Agent -BridgeId 'b9' -DmaId 9)
            $topology = New-PlanTopology -Agents $agents -Pairs $script:FailoverPairs
            $plan = New-QAFrameworkExecutionPlan -Test $script:FailoverTest -Topology $topology

            $failoverItems = @($plan.WorkItems | Where-Object { $_.Phase -like 'Failover*' })
            $failoverItems.Count | Should -BeGreaterThan 0
            $failoverItems.TargetBridgeId | Should -Not -Contain 'b9'
        }

        It 'creates no failover phases when the cluster has no pairs' {
            $plan = New-QAFrameworkExecutionPlan -Test $script:FailoverTest -Topology (New-PlanTopology -Agents $script:ThreeAgents)

            $plan.Phases | Should -Be @('Main')
        }

        It 'creates no failover phases when the run configuration disables them' {
            $topology = New-PlanTopology -Agents $script:FailoverAgents -Pairs $script:FailoverPairs
            $config = New-PlanConfiguration @{ disableFailoverRun = $true }
            $plan = New-QAFrameworkExecutionPlan -Test $script:FailoverTest -Topology $topology -Configuration $config

            $plan.Phases | Should -Be @('Main')
        }
    }

    Context 'work item shape' {
        It 'clamps the weight to the agent capacity' {
            $config = New-PlanConfiguration @{ agentCapacity = 2 }
            $plan = New-QAFrameworkExecutionPlan -Test (New-PlanTest @{ weight = 3 }) -Configuration $config

            $plan.WorkItems[0].Weight | Should -Be 2
        }

        It 'starts every work item as pending' {
            $item = (New-QAFrameworkExecutionPlan -Test (New-PlanTest)).WorkItems[0]

            $item.State | Should -Be 'Pending'
            $item.Outcome | Should -BeNullOrEmpty
            $item.Attempt | Should -Be 0
            $item.Test.name | Should -Be 'RT_Sample'
        }

        It 'accepts input from the pipeline' {
            $tests = @((New-PlanTest @{ name = 'RT_A' }), (New-PlanTest @{ name = 'RT_B' }))
            ($tests | New-QAFrameworkExecutionPlan).WorkItems.Count | Should -Be 2
        }

        It 'returns an empty plan for an empty input' {
            $plan = New-QAFrameworkExecutionPlan -Test @()

            $plan.WorkItems.Count | Should -Be 0
            $plan.Phases.Count | Should -Be 0
        }
    }
}

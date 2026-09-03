BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'tests\Stubs\QAOps.PowerShell.Stubs.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force

    function New-SchedulerTest {
        param([string]$Name, [int]$Weight = 1, [string]$TargetDma = 'One', [string]$Fixture = 'Standard', [bool]$Concurrent = $true)

        return [pscustomobject]@{
            name               = $Name
            fixture            = $Fixture
            weight             = $Weight
            canRunConcurrently = $Concurrent
            targetDma          = $TargetDma
            failover           = $null
            diagnosticRunType  = $null
        }
    }

    function New-SchedulerConfiguration {
        param([hashtable]$Override = @{})

        $config = @{
            agentCapacity        = 3
            maxTestsInCluster    = [int]::MaxValue
            schedulerTickSeconds = 0
            testTimeoutSeconds   = 60
            preRunFilter         = 'all'
            includeNonConcurrent = $true
            disableFailoverRun   = $false
        }

        foreach ($key in $Override.Keys) { $config[$key] = $Override[$key] }
        return [pscustomobject]$config
    }
}

Describe 'Invoke-QAFrameworkTestRun' {

    BeforeEach {
        Reset-QAOpsStubs
        $null = Add-QAOpsStubBridge -Id 'orchestrator' -IsOrchestrator $true -IsSelf $true -HasDataMiner $false
        $null = Add-QAOpsStubBridge -Id 'agent1' -DmaId 10
        $null = Add-QAOpsStubBridge -Id 'agent2' -DmaId 20
        Set-QAOpsStubCluster -DataMinerVersion '10.5.0.0'

        $script:Topology = Get-QAFrameworkClusterTopology
        $script:Config = New-SchedulerConfiguration
    }

    Context 'basic execution' {
        It 'runs every test and reports success' {
            $tests = @((New-SchedulerTest -Name 'RT_A'), (New-SchedulerTest -Name 'RT_B'))
            $plan = New-QAFrameworkExecutionPlan -Test $tests -Topology $script:Topology -Configuration $script:Config
            $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $run.Summary.Total | Should -Be 2
            $run.Summary.Ok | Should -Be 2
            $run.HasFailed | Should -Be $false
            $run.WorkItems.State | Should -Be @('Completed', 'Completed')
        }

        It 'never starts an execution on the orchestrator without DataMiner' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_A') -Topology $script:Topology -Configuration $script:Config
            $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            (Get-QAOpsStubExecution).BridgeId | Should -Not -Contain 'orchestrator'
        }

        It 'starts the automation script through the dotnet tool, as the legacy runner does' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_A') -Topology $script:Topology -Configuration $script:Config
            $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $execution = Get-QAOpsStubExecution | Select-Object -First 1
            $execution.Executable | Should -Be 'dotnet'
            ($execution.Arguments -join ' ') | Should -Be 'tool run dataminer-run-automation-script Local -sn RT_A'
            $execution.WorkingDirectory | Should -BeLike '*TestPackagePipeline'
            $execution.TimeoutSeconds | Should -Be 60
        }

        It 'publishes one QAOps test case per test' {
            $tests = @((New-SchedulerTest -Name 'RT_A'), (New-SchedulerTest -Name 'RT_B'))
            $plan = New-QAFrameworkExecutionPlan -Test $tests -Topology $script:Topology -Configuration $script:Config
            $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $results = Get-QAOpsStubTestResult
            $results.Count | Should -Be 2
            ($results.Name | Sort-Object) | Should -Be @('automationscript_RT_A', 'automationscript_RT_B')
            $results[0].TestAspect | Should -Be 'Execution'
        }

        It 'does not publish anything for a dry run' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_A') -Topology $script:Topology -Configuration $script:Config
            $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config -SkipPublish

            (Get-QAOpsStubTestResult).Count | Should -Be 0
        }
    }

    Context 'outcome mapping' {
        It 'reports a non-zero exit code as a failure' {
            Set-QAOpsStubExecutionOutcome -ArgumentsLike 'RT_Bad' -State 'Completed' -ExitCode 1 -StandardOutput 'assert failed'
            $tests = @((New-SchedulerTest -Name 'RT_Good'), (New-SchedulerTest -Name 'RT_Bad'))
            $plan = New-QAFrameworkExecutionPlan -Test $tests -Topology $script:Topology -Configuration $script:Config
            $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $run.Summary.Ok | Should -Be 1
            $run.Summary.Fail | Should -Be 1
            $run.HasFailed | Should -Be $true
            ($run.WorkItems | Where-Object Name -eq 'RT_Bad').Message | Should -BeLike '*assert failed*'
        }

        It 'reports a NotSupportedException as not applicable' {
            Set-QAOpsStubExecutionOutcome -ArgumentsLike 'RT_Skip' -State 'Completed' -ExitCode 1 -StandardOutput 'System.NotSupportedException: no SRM here'
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_Skip') -Topology $script:Topology -Configuration $script:Config
            $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $run.Summary.NotApplicable | Should -Be 1
            (Get-QAOpsStubTestResult)[0].Outcome | Should -Be 'NotApplicable'
        }

        It 'reports a cancelled execution as a failure' {
            Set-QAOpsStubExecutionOutcome -ArgumentsLike 'RT_Timeout' -State 'Cancelled' -ErrorMessage 'timeout'
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_Timeout') -Topology $script:Topology -Configuration $script:Config
            $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $run.Summary.Fail | Should -Be 1
            $run.WorkItems[0].Message | Should -BeLike "*Cancelled*"
        }
    }

    Context 'weight and capacity' {
        It 'never exceeds the agent capacity' {
            $tests = 1..6 | ForEach-Object { New-SchedulerTest -Name "RT_$_" -Weight 2 }
            $plan = New-QAFrameworkExecutionPlan -Test $tests -Topology $script:Topology -Configuration $script:Config
            $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $run.Summary.Ok | Should -Be 6

            # With capacity 3 only one weight 2 test fits per agent at a time.
            $perAgent = Get-QAOpsStubExecution | Group-Object BridgeId
            $perAgent.Count | Should -Be 2
        }

        It 'runs a weight 3 test alone on its agent' {
            $tests = @((New-SchedulerTest -Name 'RT_Heavy' -Weight 3), (New-SchedulerTest -Name 'RT_Light' -Weight 1))
            $plan = New-QAFrameworkExecutionPlan -Test $tests -Topology $script:Topology -Configuration $script:Config
            $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $run.Summary.Ok | Should -Be 2
            $heavy = Get-QAOpsStubExecution | Where-Object { ($_.Arguments -join ' ') -like '*RT_Heavy*' }
            $light = Get-QAOpsStubExecution | Where-Object { ($_.Arguments -join ' ') -like '*RT_Light*' }
            $heavy.BridgeId | Should -Not -Be $light.BridgeId
        }

        It 'honours the cluster wide maximum' {
            $config = New-SchedulerConfiguration @{ maxTestsInCluster = 1 }
            $tests = 1..4 | ForEach-Object { New-SchedulerTest -Name "RT_$_" }
            $plan = New-QAFrameworkExecutionPlan -Test $tests -Topology $script:Topology -Configuration $config
            $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $config

            $run.Summary.Ok | Should -Be 4
            (Get-QAOpsStubExecution).Count | Should -Be 4
        }
    }

    Context 'TargetDMA pinning' {
        It 'runs a TargetDMA All test on every agent' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_All' -TargetDma 'All') -Topology $script:Topology -Configuration $script:Config
            $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $run.Summary.Total | Should -Be 2
            ((Get-QAOpsStubExecution).BridgeId | Sort-Object) | Should -Be @('agent1', 'agent2')
        }

        It 'appends the agent to the test case name when a test runs more than once' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_All' -TargetDma 'All') -Topology $script:Topology -Configuration $script:Config
            $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            ((Get-QAOpsStubTestResult).Name | Sort-Object) | Should -Be @('automationscript_RT_All_agent1', 'automationscript_RT_All_agent2')
        }

        It 'runs a LowestDMAID test on the agent with the lowest DmaId' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_Low' -TargetDma 'LowestDMAID') -Topology $script:Topology -Configuration $script:Config
            $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            (Get-QAOpsStubExecution | Select-Object -First 1).BridgeId | Should -Be 'agent1'
        }

        It 'reports a test that no agent can run as not executed' {
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_Ghost') -Topology $script:Topology -Configuration $script:Config
            $plan.WorkItems[0].TargetBridgeId = 'agent-that-left'

            $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $run.Summary.NotExecuted | Should -Be 1
            (Get-QAOpsStubTestResult)[0].Outcome | Should -Be 'NotExecuted'
        }
    }

    Context 'phases' {
        It 'runs the phases in order' {
            $tests = @(
                (New-SchedulerTest -Name 'RT_Main'),
                (New-SchedulerTest -Name 'RT_Pre' -Fixture 'PreRun'),
                (New-SchedulerTest -Name 'RT_Serial' -Concurrent $false)
            )
            $plan = New-QAFrameworkExecutionPlan -Test $tests -Topology $script:Topology -Configuration $script:Config
            $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $order = Get-QAOpsStubExecution | ForEach-Object { ($_.Arguments | Select-Object -Last 1) }
            $order | Should -Be @('RT_Pre', 'RT_Main', 'RT_Serial')
        }

        It 'runs diagnostics before and after the rest' {
            $tests = @(
                (New-SchedulerTest -Name 'RT_Main'),
                (New-SchedulerTest -Name 'RT_Diag' -Fixture 'Diagnostic')
            )
            $plan = New-QAFrameworkExecutionPlan -Test $tests -Topology $script:Topology -Configuration $script:Config
            $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

            $order = Get-QAOpsStubExecution | ForEach-Object { ($_.Arguments | Select-Object -Last 1) }
            $order | Should -Be @('RT_Diag', 'RT_Main', 'RT_Diag')
        }
    }

    Context 'error handling' {
        It 'throws when the cluster has no agents' {
            $empty = [pscustomobject]@{ Agents = @() }
            $plan = New-QAFrameworkExecutionPlan -Test (New-SchedulerTest -Name 'RT_A')

            { Invoke-QAFrameworkTestRun -Plan $plan -Topology $empty } | Should -Throw '*no DataMiner agent*'
        }
    }
}

Describe 'Log collection on failure' {

    BeforeEach {
        Reset-QAOpsStubs
        $null = Add-QAOpsStubBridge -Id 'agent1' -DmaId 10
        $script:Topo = Get-QAFrameworkClusterTopology
    }

    It 'starts the log collector once on the failing agent' {
        Set-QAOpsStubExecutionOutcome -State 'Completed' -ExitCode 1 -StandardOutput 'boom'
        $config = [pscustomobject]@{ agentCapacity = 3; maxTestsInCluster = 1; schedulerTickSeconds = 0; testTimeoutSeconds = 60; logCollectionOnFailure = $true }
        $tests = 1..3 | ForEach-Object { [pscustomobject]@{ name = "RT_$_"; fixture = 'Standard'; weight = 1; canRunConcurrently = $true; targetDma = 'One'; failover = $null } }
        $plan = New-QAFrameworkExecutionPlan -Test $tests -Topology $script:Topo -Configuration $config

        $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topo -Configuration $config

        $run.Summary.Fail | Should -Be 3
        $collector = @(Get-QAOpsStubExecution | Where-Object { $_.Executable -like '*SL_LogCollector*' })
        $collector.Count | Should -Be 1
        ($collector[0].Arguments -join ' ') | Should -BeLike '*--dumps=SLNet.exe*'
    }

    It 'does not collect logs when the configuration does not ask for it' {
        Set-QAOpsStubExecutionOutcome -State 'Completed' -ExitCode 1
        $config = [pscustomobject]@{ agentCapacity = 3; schedulerTickSeconds = 0; testTimeoutSeconds = 60; logCollectionOnFailure = $false }
        $test = [pscustomobject]@{ name = 'RT_A'; fixture = 'Standard'; weight = 1; canRunConcurrently = $true; targetDma = 'One'; failover = $null }
        $plan = New-QAFrameworkExecutionPlan -Test $test -Topology $script:Topo -Configuration $config

        $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topo -Configuration $config

        (Get-QAOpsStubExecution | Where-Object { $_.Executable -like '*SL_LogCollector*' }).Count | Should -Be 0
    }
}

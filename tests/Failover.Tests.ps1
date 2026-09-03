BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'tests\Stubs\QAOps.PowerShell.Stubs.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force

    function New-FailoverConfiguration {
        return [pscustomobject]@{
            agentCapacity        = 3
            maxTestsInCluster    = [int]::MaxValue
            schedulerTickSeconds = 0
            testTimeoutSeconds   = 60
            preRunFilter         = 'all'
            includeNonConcurrent = $true
            disableFailoverRun   = $false
            rtManagerRoot        = 'C:\RTManager\'
            systemSettings       = @{}
        }
    }

    function New-FailoverTestMetadata {
        param([hashtable]$FailoverOverride = @{})

        $failover = @{
            runDirectBeforeSwitch   = $false
            runDirectAfterSwitch    = $false
            runOnNonFailoverSystems = $false
            hasBeforeSwitch         = $true
            hasAfterSwitch          = $true
            hasAfterSwitchBack      = $true
        }
        foreach ($key in $FailoverOverride.Keys) { $failover[$key] = $FailoverOverride[$key] }

        return [pscustomobject]@{
            name               = 'RT_Failover'
            fixture            = 'Failover'
            weight             = 1
            canRunConcurrently = $true
            targetDma          = 'One'
            failover           = [pscustomobject]$failover
            diagnosticRunType  = $null
        }
    }

    function Get-AgentSetupArguments {
        return Get-QAOpsStubExecution | Where-Object { $_.Executable -eq 'pwsh' } | ForEach-Object { $_.Arguments -join ' ' }
    }
}

Describe 'Failover orchestration' {

    BeforeEach {
        Reset-QAOpsStubs
        $null = Add-QAOpsStubBridge -Id 'orchestrator' -IsOrchestrator $true -IsSelf $true -HasDataMiner $false
        $null = Add-QAOpsStubBridge -Id 'fo1' -DmaId 10 -IsFailover $true -FailoverPartnerBridgeId 'fo2'
        $null = Add-QAOpsStubBridge -Id 'fo2' -DmaId 11 -IsFailover $true -FailoverPartnerBridgeId 'fo1'

        $script:Topology = Get-QAFrameworkClusterTopology
        $script:Config = New-FailoverConfiguration
    }

    It 'detects the failover pair' {
        $script:Topology.HasFailover | Should -Be $true
        $script:Topology.FailoverPairs.Count | Should -Be 1
    }

    It 'switches the cluster once and switches back at the end' {
        $plan = New-QAFrameworkExecutionPlan -Test (New-FailoverTestMetadata) -Topology $script:Topology -Configuration $script:Config
        $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

        $plan.Phases | Should -Be @('Main', 'FailoverAfterSwitch', 'FailoverAfterSwitchBack')
        (Get-QAOpsStubFailoverSwitch).Count | Should -Be 2
        $run.FailoverSwitches.Count | Should -Be 2
        $run.FailoverSwitches.Success | Should -Be @($true, $true)
    }

    It 'writes the FailoverState before every failover phase' {
        $plan = New-QAFrameworkExecutionPlan -Test (New-FailoverTestMetadata) -Topology $script:Topology -Configuration $script:Config
        $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

        $states = Get-AgentSetupArguments | ForEach-Object {
            if ($_ -match '-FailoverState (\d+)') { [int]$Matches[1] }
        }

        # Two agents per phase: after the switch (10), after switching back (20) and the reset (0).
        $states | Should -Be @(10, 10, 20, 20, 0, 0)
        (Get-AgentSetupArguments)[0] | Should -BeLike '*-SkipDependencies*'
    }

    It 'runs the direct before switch tests before the switch' {
        $test = New-FailoverTestMetadata @{ runDirectBeforeSwitch = $true; hasAfterSwitch = $false; hasAfterSwitchBack = $false }
        $plan = New-QAFrameworkExecutionPlan -Test $test -Topology $script:Topology -Configuration $script:Config
        $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config

        $plan.Phases | Should -Be @('Main', 'FailoverDirectBeforeSwitch')

        # Nothing needed the AfterSwitch state, so the cluster is only switched to restore it.
        (Get-AgentSetupArguments | Where-Object { $_ -match '-FailoverState 10' }).Count | Should -Be 0
        (Get-QAOpsStubFailoverSwitch).Count | Should -Be 0
    }

    It 'leaves the cluster alone when the orchestration is skipped' {
        $plan = New-QAFrameworkExecutionPlan -Test (New-FailoverTestMetadata) -Topology $script:Topology -Configuration $script:Config
        $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config -SkipFailoverOrchestration

        (Get-QAOpsStubFailoverSwitch).Count | Should -Be 0
        (Get-AgentSetupArguments).Count | Should -Be 0
        $run.Summary.Ok | Should -Be 3
    }

    It 'runs the failover tests on the failover agents only' {
        $null = Add-QAOpsStubBridge -Id 'plain' -DmaId 50
        $topology = Get-QAFrameworkClusterTopology
        $plan = New-QAFrameworkExecutionPlan -Test (New-FailoverTestMetadata) -Topology $topology -Configuration $script:Config
        $null = Invoke-QAFrameworkTestRun -Plan $plan -Topology $topology -Configuration $script:Config

        $testExecutions = Get-QAOpsStubExecution | Where-Object { $_.Executable -eq 'dotnet' }
        $failoverPhaseAgents = @($plan.WorkItems | Where-Object { $_.Phase -like 'Failover*' }).TargetBridgeId

        $testExecutions.Count | Should -BeGreaterThan 0
        $failoverPhaseAgents | Should -Not -Contain 'plain'
    }

    It 'reports a failed switch without stopping the run' {
        Mock -CommandName 'Start-QAOpsFailoverSwitch' -ModuleName 'Skyline.DataMiner.QAOps.PipelineLibrary' -MockWith {
            throw 'bridge refused the switch'
        }

        $plan = New-QAFrameworkExecutionPlan -Test (New-FailoverTestMetadata) -Topology $script:Topology -Configuration $script:Config
        $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $script:Topology -Configuration $script:Config -WarningAction SilentlyContinue

        $run.FailoverSwitches.Success | Should -Not -Contain $true
        $run.Summary.Total | Should -Be 3
    }
}

Describe 'Get-QAFrameworkFailoverStateValue' {
    BeforeAll {
        $script:StateOf = { param($Phase) & (Get-Module Skyline.DataMiner.QAOps.PipelineLibrary) { Get-QAFrameworkFailoverStateValue -Phase $args[0] } $Phase }
    }

    It 'maps <Phase> to <Expected>' -ForEach @(
        @{ Phase = 'Main'; Expected = 0 }
        @{ Phase = 'FailoverDirectBeforeSwitch'; Expected = 0 }
        @{ Phase = 'FailoverDirectAfterSwitch'; Expected = 10 }
        @{ Phase = 'FailoverAfterSwitch'; Expected = 10 }
        @{ Phase = 'FailoverAfterSwitchBack'; Expected = 20 }
    ) {
        & $script:StateOf $Phase | Should -Be $Expected
    }
}

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'tests\Stubs\QAOps.PowerShell.Stubs.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force
}

Describe 'Initialize-QAFrameworkAgents' {

    BeforeEach {
        Reset-QAOpsStubs
        $null = Add-QAOpsStubBridge -Id 'orchestrator' -IsOrchestrator $true -IsSelf $true -HasDataMiner $false -TestPackageContentPath '/opt/qaops/content'
        $null = Add-QAOpsStubBridge -Id 'agent1' -DmaId 10 -TestPackageContentPath 'C:\QAOps\Content'
        $null = Add-QAOpsStubBridge -Id 'agent2' -DmaId 20 -TestPackageContentPath 'C:\QAOps\Content'

        $script:Topology = Get-QAFrameworkClusterTopology
    }

    It 'runs the agent script on every DataMiner agent' {
        $results = @(Initialize-QAFrameworkAgents -Topology $script:Topology)

        $results.Count | Should -Be 2
        ($results.BridgeId | Sort-Object) | Should -Be @('agent1', 'agent2')
        $results.Success | Should -Be @($true, $true)
        (Get-QAOpsStubExecution).BridgeId | Should -Not -Contain 'orchestrator'
    }

    It 'starts pwsh with paths relative to the target package root' {
        $null = Initialize-QAFrameworkAgents -Topology $script:Topology

        $execution = Get-QAOpsStubExecution | Select-Object -First 1
        $execution.Executable | Should -Be 'pwsh'
        $arguments = $execution.Arguments -join ' '
        $arguments | Should -BeLike '*-File TestPackagePipeline/helpers/Initialize-QAFrameworkAgent.ps1*'
        $arguments | Should -BeLike '*-PathToTestPackageContent .*'
        $arguments | Should -BeLike '*-FailoverState 0*'
        $execution.WorkingDirectory | Should -BeNullOrEmpty
    }

    It 'passes the configured RTManager root and system settings' {
        $config = [pscustomobject]@{
            rtManagerRoot  = 'D:\RTManager\'
            systemSettings = @{ TearDownNeeded = $false }
        }
        $null = Initialize-QAFrameworkAgents -Topology $script:Topology -Configuration $config

        $arguments = (Get-QAOpsStubExecution | Select-Object -First 1).Arguments -join ' '
        $arguments | Should -BeLike '*-RtManagerRoot D:\RTManager\*'
        $arguments | Should -BeLike '*TearDownNeeded*'
    }

    It 'can rewrite only the failover state' {
        $null = Initialize-QAFrameworkAgents -Topology $script:Topology -FailoverState 10 -SkipDependencies

        $arguments = (Get-QAOpsStubExecution | Select-Object -First 1).Arguments -join ' '
        $arguments | Should -BeLike '*-FailoverState 10*'
        $arguments | Should -BeLike '*-SkipDependencies*'
    }

    It 'throws when an agent fails to set itself up' {
        Set-QAOpsStubExecutionOutcome -State 'Completed' -ExitCode 1 -StandardError 'no disk space'

        { Initialize-QAFrameworkAgents -Topology $script:Topology } | Should -Throw '*no disk space*'
    }

    It 'reports the failure instead of throwing when asked to continue' {
        Set-QAOpsStubExecutionOutcome -State 'Failed' -ErrorMessage 'agent offline'

        $results = @(Initialize-QAFrameworkAgents -Topology $script:Topology -ContinueOnError)

        $results.Count | Should -Be 2
        $results.Success | Should -Be @($false, $false)
        $results[0].Message | Should -BeLike '*agent offline*'
    }

    It 'throws when the cluster has no agents' {
        { Initialize-QAFrameworkAgents -Topology ([pscustomobject]@{ Agents = @() }) } | Should -Throw '*no DataMiner agent*'
    }
}

Describe 'Join-QAFrameworkAgentPath' {
    BeforeAll {
        $script:Join = { param($Base, $Relative) & (Get-Module Skyline.DataMiner.QAOps.PipelineLibrary) { Join-QAFrameworkAgentPath -Base $args[0] -Relative $args[1] } $Base $Relative }
    }

    It 'keeps Windows separators for a Windows agent path' {
        & $script:Join 'C:\QAOps\Content' 'TestPackagePipeline/helpers' | Should -Be 'C:\QAOps\Content\TestPackagePipeline\helpers'
    }

    It 'keeps forward slashes for a Linux agent path' {
        & $script:Join '/opt/qaops/content' 'TestPackagePipeline/helpers' | Should -Be '/opt/qaops/content/TestPackagePipeline/helpers'
    }

    It 'handles a UNC path' {
        & $script:Join '\\server\share' 'a/b' | Should -Be '\\server\share\a\b'
    }
}

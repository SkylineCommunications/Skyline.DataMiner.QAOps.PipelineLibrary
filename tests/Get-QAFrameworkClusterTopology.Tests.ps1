BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Stubs\QAOps.PowerShell.Stubs.psm1') -Force
}

AfterAll {
    Remove-Module QAOps.PowerShell.Stubs -Force -ErrorAction SilentlyContinue
}

Describe 'Get-QAFrameworkClusterTopology' {
    BeforeEach { Reset-QAOpsStubs }

    Context 'orchestrator without DataMiner' {
        BeforeAll {
            Reset-QAOpsStubs
            Add-QAOpsStubBridge -Id 'orchestrator' -IsOrchestrator $true -IsSelf $true -HasDataMiner $false | Out-Null
            Add-QAOpsStubBridge -Id 'agent-a' -DmaId 100 -HasDataMiner $true | Out-Null
            Add-QAOpsStubBridge -Id 'agent-b' -DmaId 20 -HasDataMiner $true | Out-Null
            Set-QAOpsStubCluster -DataMinerVersion '10.5.3.0' -DbmsType 'Cassandra' -IsCentralized $true

            $script:Topology = Get-QAFrameworkClusterTopology
        }

        It 'excludes the bridge without DataMiner' {
            $script:Topology.Agents.BridgeId | Should -Be @('agent-a', 'agent-b')
        }

        It 'reports the lowest and highest DMA id' {
            $script:Topology.LowestDmaId | Should -Be 20
            $script:Topology.HighestDmaId | Should -Be 100
        }

        It 'reports the cluster facts' {
            $script:Topology.DataMinerVersion | Should -Be ([version]'10.5.3.0')
            $script:Topology.DbmsType | Should -Be 'Cassandra'
            $script:Topology.IsCentralized | Should -BeTrue
            $script:Topology.IsClusterKnown | Should -BeTrue
        }

        It 'reports no failover' {
            $script:Topology.HasFailover | Should -BeFalse
            $script:Topology.FailoverPairs.Count | Should -Be 0
        }
    }

    Context 'failover pair' {
        BeforeAll {
            Reset-QAOpsStubs
            Add-QAOpsStubBridge -Id 'fo-a' -DmaId 1 -HasDataMiner $true -IsFailover $true -FailoverPartnerBridgeId 'fo-b' | Out-Null
            Add-QAOpsStubBridge -Id 'fo-b' -DmaId 2 -HasDataMiner $true -IsFailover $true -FailoverPartnerBridgeId 'fo-a' | Out-Null
            Set-QAOpsStubCluster

            $script:Failover = Get-QAFrameworkClusterTopology
        }

        It 'builds the pair exactly once' {
            $script:Failover.FailoverPairs.Count | Should -Be 1
            $script:Failover.HasFailover | Should -BeTrue
        }

        It 'links both bridges of the pair' {
            $pair = $script:Failover.FailoverPairs[0]
            $pair.Primary.BridgeId | Should -Be 'fo-a'
            $pair.Partner.BridgeId | Should -Be 'fo-b'
        }
    }

    Context 'single-bridge failover information' {
        It 'models the pair by the bridge that hosts it' {
            Reset-QAOpsStubs
            Add-QAOpsStubBridge -Id 'fo-a' -DmaId 1 -HasDataMiner $true -IsFailover $true -FailoverPartnerBridgeId 'not-in-cluster' | Out-Null

            $topology = Get-QAFrameworkClusterTopology
            $topology.HasFailover | Should -BeTrue
            $topology.FailoverPairs.Count | Should -Be 1
            $topology.FailoverPairs[0].Primary.BridgeId | Should -Be 'fo-a'
        }
    }

    Context 'QAOps properties not implemented yet' {
        BeforeAll {
            $script:Legacy = Get-QAFrameworkClusterTopology -Cluster $null -Bridge @(
                [pscustomobject]@{ Id = 'b1'; DisplayName = 'b1'; HostName = 'h1'; IsOrchestrator = $true; IsSelf = $true }
                [pscustomobject]@{ Id = 'b2'; DisplayName = 'b2'; HostName = 'h2'; IsOrchestrator = $false; IsSelf = $false }
            )
        }

        It 'treats every bridge as an agent' { $script:Legacy.Agents.Count | Should -Be 2 }

        It 'assigns ordinal DMA ids and flags them as unknown' {
            $script:Legacy.Agents[0].DmaId | Should -Be 1
            $script:Legacy.Agents[1].DmaId | Should -Be 2
            $script:Legacy.Agents[0].DmaIdIsKnown | Should -BeFalse
        }

        It 'disables failover' { $script:Legacy.HasFailover | Should -BeFalse }

        It 'reports the cluster as unknown' { $script:Legacy.IsClusterKnown | Should -BeFalse }
    }

    Context 'ExcludeOrchestrator' {
        It 'keeps the orchestrator out of the agent pool' {
            Reset-QAOpsStubs
            Add-QAOpsStubBridge -Id 'orch' -IsOrchestrator $true -HasDataMiner $true -DmaId 1 | Out-Null
            Add-QAOpsStubBridge -Id 'agent' -HasDataMiner $true -DmaId 2 | Out-Null

            $topology = Get-QAFrameworkClusterTopology -ExcludeOrchestrator
            $topology.Agents.BridgeId | Should -Be @('agent')
        }
    }

    It 'throws a helpful error when QAOps.PowerShell is missing' {
        Remove-Module QAOps.PowerShell.Stubs -Force
        try {
            { Get-QAFrameworkClusterTopology } | Should -Throw '*Get-QAOpsBridge is not available*'
        }
        finally {
            Import-Module (Join-Path $PSScriptRoot 'Stubs\QAOps.PowerShell.Stubs.psm1') -Force
        }
    }
}

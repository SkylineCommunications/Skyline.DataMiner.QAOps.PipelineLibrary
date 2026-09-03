BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Stubs\QAOps.PowerShell.Stubs.psm1') -Force
}

AfterAll {
    Remove-Module QAOps.PowerShell.Stubs -Force -ErrorAction SilentlyContinue
}

Describe 'Get-QAFrameworkRunConfiguration' {
    BeforeEach {
        Reset-QAOpsStubs
        $script:Content = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Content 'TestPackagePipeline') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Content 'SupplementaryFiles') | Out-Null
    }

    It 'returns the legacy defaults when nothing is configured' {
        $config = Get-QAFrameworkRunConfiguration -SkipTestRunContext

        $config.agentCapacity | Should -Be 3
        $config.testTimeoutSeconds | Should -Be 7200
        $config.includeNonConcurrent | Should -BeTrue
        $config.disableFailoverRun | Should -BeFalse
        $config.preRunFilter | Should -Be 'all'
        $config.maxTestsInCluster | Should -Be ([int]::MaxValue)
        $config.keywords.Count | Should -Be 0
    }

    It 'reads the package configuration file' {
        @{
            agentCapacity      = 2
            maxTestsInCluster  = 4
            disableFailoverRun = $true
            preRunFilter       = 'none'
            filters            = @{ keywords = @('Alarming', 'Smoke'); excludeSquads = @('SquadZ') }
            systemSettings     = @{ PushToPortal = $false }
        } | ConvertTo-Json -Depth 5 |
            Set-Content -Path (Join-Path $script:Content 'TestPackagePipeline\qaframework.config.json')

        $config = Get-QAFrameworkRunConfiguration -TestPackageContentPath $script:Content -SkipTestRunContext

        $config.agentCapacity | Should -Be 2
        $config.maxTestsInCluster | Should -Be 4
        $config.disableFailoverRun | Should -BeTrue
        $config.preRunFilter | Should -Be 'none'
        $config.keywords | Should -Be @('Alarming', 'Smoke')
        $config.excludeSquads | Should -Be @('SquadZ')
        $config.systemSettings['PushToPortal'] | Should -BeFalse
    }

    It 'lets the supplementary override win over the package configuration' {
        @{ agentCapacity = 2; preRunFilter = 'none' } | ConvertTo-Json |
            Set-Content -Path (Join-Path $script:Content 'TestPackagePipeline\qaframework.config.json')
        @{ agentCapacity = 1 } | ConvertTo-Json |
            Set-Content -Path (Join-Path $script:Content 'SupplementaryFiles\qaframework.overrides.json')

        $config = Get-QAFrameworkRunConfiguration -TestPackageContentPath $script:Content -SkipTestRunContext

        $config.agentCapacity | Should -Be 1
        $config.preRunFilter | Should -Be 'none'
    }

    It 'lets test run labels win over the files' {
        @{ agentCapacity = 2; filters = @{ keywords = @('FromFile') } } | ConvertTo-Json -Depth 5 |
            Set-Content -Path (Join-Path $script:Content 'TestPackagePipeline\qaframework.config.json')

        Set-QAOpsStubTestRunContext -Labels @{
            'qaframework.agentCapacity'      = '3'
            'qaframework.keywords'           = 'Alarming, Smoke'
            'qaframework.disableFailoverRun' = 'true'
            'unrelated.label'                = 'ignored'
        }

        $config = Get-QAFrameworkRunConfiguration -TestPackageContentPath $script:Content

        $config.agentCapacity | Should -Be 3
        $config.keywords | Should -Be @('Alarming', 'Smoke')
        $config.disableFailoverRun | Should -BeTrue
    }

    It 'lets explicit parameters win over everything' {
        @{ agentCapacity = 2 } | ConvertTo-Json |
            Set-Content -Path (Join-Path $script:Content 'TestPackagePipeline\qaframework.config.json')
        Set-QAOpsStubTestRunContext -Labels @{ 'qaframework.agentCapacity' = '3' }

        $config = Get-QAFrameworkRunConfiguration -TestPackageContentPath $script:Content -AgentCapacity 1 -Keywords 'Direct'

        $config.agentCapacity | Should -Be 1
        $config.keywords | Should -Be @('Direct')
    }

    It 'records which layers contributed' {
        @{ agentCapacity = 2 } | ConvertTo-Json |
            Set-Content -Path (Join-Path $script:Content 'TestPackagePipeline\qaframework.config.json')

        $config = Get-QAFrameworkRunConfiguration -TestPackageContentPath $script:Content -SkipTestRunContext -AgentCapacity 1

        $config.sources | Should -Contain 'parameters'
        ($config.sources -join ';') | Should -Match 'qaframework.config.json'
    }

    It 'clamps nonsensical values back to a usable default' {
        $config = Get-QAFrameworkRunConfiguration -SkipTestRunContext -AgentCapacity 0 -MaxTestsInCluster 0 -TestTimeoutSeconds 0 -SchedulerTickSeconds 0

        $config.agentCapacity | Should -Be 1
        $config.maxTestsInCluster | Should -Be ([int]::MaxValue)
        $config.testTimeoutSeconds | Should -Be 7200
        $config.schedulerTickSeconds | Should -Be 1
    }

    It 'throws on invalid JSON' {
        Set-Content -Path (Join-Path $script:Content 'TestPackagePipeline\qaframework.config.json') -Value '{ nope'
        { Get-QAFrameworkRunConfiguration -TestPackageContentPath $script:Content -SkipTestRunContext } |
            Should -Throw '*not valid JSON*'
    }
}

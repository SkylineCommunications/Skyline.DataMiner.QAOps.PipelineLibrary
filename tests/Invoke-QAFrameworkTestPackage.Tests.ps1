BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'tests\Stubs\QAOps.PowerShell.Stubs.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force
}

Describe 'Invoke-QAFrameworkTestPackage' {

    BeforeEach {
        Reset-QAOpsStubs
        $null = Add-QAOpsStubBridge -Id 'orchestrator' -IsOrchestrator $true -IsSelf $true -HasDataMiner $false -TestPackageContentPath '/opt/qaops/content'
        $null = Add-QAOpsStubBridge -Id 'agent1' -DmaId 10 -TestPackageContentPath 'C:\QAOps\Content'
        $null = Add-QAOpsStubBridge -Id 'agent2' -DmaId 20 -TestPackageContentPath 'C:\QAOps\Content'

        $script:ContentPath = Join-Path ([IO.Path]::GetTempPath()) ("qafw_pkg_" + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:ContentPath 'TestHarvesting') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $script:ContentPath 'TestPackagePipeline') -Force

        $metadata = @{
            schemaVersion = 1
            tests         = @(
                @{ name = 'RT_Alpha'; fixture = 'Standard'; weight = 1 },
                @{ name = 'RT_Beta'; fixture = 'Standard'; weight = 2 },
                @{ name = 'RT_Disabled'; fixture = 'Standard'; disabled = @{ reason = 'Broken by DCP123' } }
            )
        }
        $metadata | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $script:ContentPath 'TestHarvesting\qaframework.tests.json') -Encoding utf8

        @{ schedulerTickSeconds = 0; testTimeoutSeconds = 60 } | ConvertTo-Json |
            Set-Content -Path (Join-Path $script:ContentPath 'TestPackagePipeline\qaframework.config.json') -Encoding utf8
    }

    AfterEach {
        if ($script:ContentPath -and (Test-Path $script:ContentPath)) {
            Remove-Item -Path $script:ContentPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs the enabled tests and publishes an overall result' {
        $result = Invoke-QAFrameworkTestPackage -TestPackageContentPath $script:ContentPath -PassThru

        $result.Outcome | Should -Be 'Ok'
        $result.Run.Summary.Ok | Should -Be 2

        $results = @(Get-QAOpsStubTestResult)
        ($results | Where-Object { $_.Name -eq 'automationscript_RT_Alpha' }).Outcome | Should -Be 'Ok'
        ($results | Where-Object { $_.Name -eq 'automationscript_RT_Beta' }).Outcome | Should -Be 'Ok'

        $overall = $results | Where-Object { $_.Name -eq 'pipeline_TestPackageExecution' }
        $overall | Should -Not -BeNullOrEmpty
        $overall.Outcome | Should -Be 'Ok'
    }

    It 'reports a disabled test as NotExecuted with its reason' {
        $null = Invoke-QAFrameworkTestPackage -TestPackageContentPath $script:ContentPath

        $disabled = Get-QAOpsStubTestResult | Where-Object { $_.Name -eq 'automationscript_RT_Disabled' }
        $disabled | Should -Not -BeNullOrEmpty
        $disabled.Outcome | Should -Be 'NotExecuted'
        $disabled.Message | Should -BeLike '*Broken by DCP123*'
    }

    It 'prepares the agents unless the setup is skipped' {
        $null = Invoke-QAFrameworkTestPackage -TestPackageContentPath $script:ContentPath
        @(Get-QAOpsStubExecution | Where-Object { ($_.Arguments -join ' ') -like '*Initialize-QAFrameworkAgent.ps1*' }).Count | Should -Be 2

        Reset-QAOpsStubs
        $null = Add-QAOpsStubBridge -Id 'agent1' -DmaId 10 -TestPackageContentPath 'C:\QAOps\Content'
        $null = Invoke-QAFrameworkTestPackage -TestPackageContentPath $script:ContentPath -SkipAgentSetup
        @(Get-QAOpsStubExecution | Where-Object { ($_.Arguments -join ' ') -like '*Initialize-QAFrameworkAgent.ps1*' }).Count | Should -Be 0
    }

    It 'fails overall when a test fails' {
        Set-QAOpsStubExecutionOutcome -ArgumentsLike 'RT_Beta' -State 'Completed' -ExitCode 1 -StandardOutput 'assert failed'

        $result = Invoke-QAFrameworkTestPackage -TestPackageContentPath $script:ContentPath -PassThru

        $result.Outcome | Should -Be 'Fail'
        $result.Run.HasFailed | Should -BeTrue
        (Get-QAOpsStubTestResult | Where-Object { $_.Name -eq 'pipeline_TestPackageExecution' }).Outcome | Should -Be 'Fail'
    }

    It 'publishes nothing when -SkipPublish is used' {
        $result = Invoke-QAFrameworkTestPackage -TestPackageContentPath $script:ContentPath -SkipPublish -PassThru

        $result.Run.Summary.Ok | Should -Be 2
        @(Get-QAOpsStubTestResult).Count | Should -Be 0
    }

    It 'applies the keyword filter given on the command line' {
        $metadataPath = Join-Path $script:ContentPath 'TestHarvesting\qaframework.tests.json'
        $metadata = @{
            schemaVersion = 1
            tests         = @(
                @{ name = 'RT_Alpha'; fixture = 'Standard'; keywords = @('smoke') },
                @{ name = 'RT_Beta'; fixture = 'Standard'; keywords = @('nightly') }
            )
        }
        $metadata | ConvertTo-Json -Depth 8 | Set-Content -Path $metadataPath -Encoding utf8

        $result = Invoke-QAFrameworkTestPackage -TestPackageContentPath $script:ContentPath -Keywords 'smoke' -PassThru

        $result.Selection.Selected.Count | Should -Be 1
        $result.Selection.Selected[0].name | Should -Be 'RT_Alpha'
    }
}

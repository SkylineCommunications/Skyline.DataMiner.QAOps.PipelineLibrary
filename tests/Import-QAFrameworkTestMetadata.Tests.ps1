BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force

    $script:Content = Join-Path $TestDrive 'Content'
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Content 'TestHarvesting\dependencies.generated') | Out-Null
}

Describe 'Import-QAFrameworkTestMetadata' {
    Context 'schema v1 document' {
        BeforeAll {
            $document = @{
                schemaVersion = 1
                tests         = @(
                    @{
                        name               = 'RT_One'
                        fixture            = 'Standard'
                        weight             = 2
                        canRunConcurrently = $false
                        targetDma          = 'All'
                        keywords           = @('Alarming')
                        disabled           = @{ reason = 'flaky' }
                    },
                    @{
                        name     = 'RT_Two'
                        fixture  = 'Failover'
                        failover = @{ runDirectBeforeSwitch = $true; hasAfterSwitch = $true }
                    }
                )
            }
            $document | ConvertTo-Json -Depth 6 |
                Set-Content -Path (Join-Path $script:Content 'TestHarvesting\qaframework.tests.json')

            $script:Tests = @(Import-QAFrameworkTestMetadata -TestPackageContentPath $script:Content)
        }

        It 'returns every test' { $script:Tests.Count | Should -Be 2 }

        It 'preserves schema v1 values' {
            $one = $script:Tests | Where-Object name -EQ 'RT_One'
            $one.weight | Should -Be 2
            $one.canRunConcurrently | Should -BeFalse
            $one.targetDma | Should -Be 'All'
            $one.keywords | Should -Be @('Alarming')
            $one.disabled.reason | Should -Be 'flaky'
        }

        It 'fills failover defaults' {
            $two = $script:Tests | Where-Object name -EQ 'RT_Two'
            $two.failover.runDirectBeforeSwitch | Should -BeTrue
            $two.failover.runDirectAfterSwitch | Should -BeFalse
            $two.failover.hasAfterSwitch | Should -BeTrue
        }

        It 'drops disabled tests when asked' {
            $kept = @(Import-QAFrameworkTestMetadata -TestPackageContentPath $script:Content -ExcludeDisabled)
            $kept.name | Should -Be @('RT_Two')
        }
    }

    Context 'legacy testmetadata.generated.json' {
        BeforeAll {
            $script:LegacyContent = Join-Path $TestDrive 'Legacy'
            New-Item -ItemType Directory -Force -Path (Join-Path $script:LegacyContent 'TestHarvesting') | Out-Null

            @(
                @{ Name = 'RT_Legacy'; DiagnosticRunType = $null },
                @{ Name = 'RT_Diag'; DiagnosticRunType = 'After' },
                @{ Name = 'RT_Serial'; noParallelGroup = 'GroupA'; isBaseline = $true; keywords = @('Smoke'); squads = @('SquadX') }
            ) | ConvertTo-Json -Depth 6 |
                Set-Content -Path (Join-Path $script:LegacyContent 'TestHarvesting\testmetadata.generated.json')

            $script:Legacy = @(Import-QAFrameworkTestMetadata -TestPackageContentPath $script:LegacyContent)
        }

        It 'applies the legacy defaults' {
            $legacy = $script:Legacy | Where-Object name -EQ 'RT_Legacy'
            $legacy.fixture | Should -Be 'Standard'
            $legacy.weight | Should -Be 1
            $legacy.canRunConcurrently | Should -BeTrue
            $legacy.targetDma | Should -Be 'One'
        }

        It 'infers a diagnostic fixture from the run type' {
            $diag = $script:Legacy | Where-Object name -EQ 'RT_Diag'
            $diag.fixture | Should -Be 'Diagnostic'
            $diag.diagnosticRunType | Should -Be 'After'
        }

        It 'maps noParallelGroup onto canRunConcurrently' {
            $serial = $script:Legacy | Where-Object name -EQ 'RT_Serial'
            $serial.canRunConcurrently | Should -BeFalse
            $serial.isBaseline | Should -BeTrue
            $serial.keywords | Should -Be @('Smoke')
            $serial.squads | Should -Be @('SquadX')
        }
    }

    Context 'error handling' {
        It 'throws when no metadata exists' {
            $empty = Join-Path $TestDrive 'Empty'
            New-Item -ItemType Directory -Force -Path $empty | Out-Null
            { Import-QAFrameworkTestMetadata -TestPackageContentPath $empty } | Should -Throw '*No QAFramework test metadata*'
        }

        It 'throws on invalid JSON' {
            $bad = Join-Path $TestDrive 'bad.json'
            Set-Content -Path $bad -Value '{ not json'
            { Import-QAFrameworkTestMetadata -MetadataPath $bad } | Should -Throw '*not valid JSON*'
        }

        It 'skips duplicates' {
            $dup = Join-Path $TestDrive 'dup.json'
            @(@{ name = 'RT_Dup' }, @{ name = 'RT_Dup' }) | ConvertTo-Json | Set-Content -Path $dup
            $result = @(Import-QAFrameworkTestMetadata -MetadataPath $dup -WarningAction SilentlyContinue)
            $result.Count | Should -Be 1
        }
    }
}

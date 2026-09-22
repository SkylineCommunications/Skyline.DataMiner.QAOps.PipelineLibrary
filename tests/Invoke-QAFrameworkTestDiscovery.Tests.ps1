BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'tests\Stubs\QAOps.PowerShell.Stubs.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force

    $script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures\RegressionTests'
}

Describe 'Invoke-QAFrameworkTestDiscovery' {

    BeforeEach {
        $script:ContentPath = Join-Path ([IO.Path]::GetTempPath()) ("qafw_harvest_" + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:ContentPath 'TestHarvesting') -Force
    }

    AfterEach {
        if ($script:ContentPath -and (Test-Path $script:ContentPath)) {
            Remove-Item -Path $script:ContentPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'harvests the enabled tests that have a .cs file' {
        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot

        ($report.Tests.name | Sort-Object) | Should -Be @('RT_Diagnostic', 'RT_DisabledNoReason', 'RT_Failover', 'RT_Full')

        ($report.Dropped | Where-Object { $_.Name -eq 'RT_DisabledNoReason' }).Reason | Should -BeLike '*disabled*'
        ($report.Dropped | Where-Object { $_.Name -eq 'RT_LegacyMeta' }).Reason | Should -BeLike '*no .cs file*'
    }

    It 'generates a valid DMSScript per harvested test' {
        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot -FolderTagPrefix 'QAOps\MyPkg\'

        $scriptPath = Join-Path $report.ScriptsPath 'RT_Full\script.xml'
        Test-Path $scriptPath | Should -BeTrue

        $xml = [xml](Get-Content -LiteralPath $scriptPath -Raw)
        $xml.DMSScript.options | Should -Be '272'
        $xml.DMSScript.Name | Should -Be 'RT_Full'
        $xml.DMSScript.Folder | Should -Be 'QAOps\MyPkg\TeamA\RT_Full'
        $xml.DMSScript.Script.Exe.Value.InnerText | Should -BeLike '*class RT_Full*'
        $xml.DMSScript.Script.Exe.Param.'#text' | Should -Be 'C:\RTManager\GlobalDependencies\QAHelper.dll'
    }

    It 'writes the known tests file and the schema v1 metadata' {
        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot

        (Get-Content -LiteralPath $report.KnownTestsPath | Sort-Object) | Should -Be @('RT_Diagnostic', 'RT_Failover', 'RT_Full')

        $metadata = Get-Content -LiteralPath $report.MetadataPath -Raw | ConvertFrom-Json
        $metadata.schemaVersion | Should -Be 1

        $full = $metadata.tests | Where-Object { $_.name -eq 'RT_Full' }
        $full.weight | Should -Be 2
        $full.canRunConcurrently | Should -BeFalse
        $full.targetDma | Should -Be 'All'
        $full.keywords | Should -Be @('Alarming', 'Smoke')

        $failover = $metadata.tests | Where-Object { $_.name -eq 'RT_Failover' }
        $failover.fixture | Should -Be 'Failover'
        $failover.failover.hasBeforeSwitch | Should -BeTrue
        $failover.weight | Should -Be 3

        $disabled = $metadata.tests | Where-Object { $_.name -eq 'RT_DisabledNoReason' }
        $disabled.disabled.reason | Should -BeLike '*DCP1234*'
        Test-Path (Join-Path $report.ScriptsPath 'RT_DisabledNoReason\script.xml') | Should -BeFalse
    }

    It 'writes a legacy testmetadata.generated.json that stays an array' {
        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot

        $legacy = Get-Content -LiteralPath $report.LegacyMetadataPath -Raw | ConvertFrom-Json
        @($legacy).Count | Should -Be 4
        (@($legacy) | Where-Object { $_.Name -eq 'RT_Diagnostic' }).DiagnosticRunType | Should -Be 'Before'
    }

    It 'produces metadata that Import-QAFrameworkTestMetadata can read back' {
        $null = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot

        $tests = @(Import-QAFrameworkTestMetadata -TestPackageContentPath $script:ContentPath)
        ($tests.name | Sort-Object) | Should -Be @('RT_Diagnostic', 'RT_DisabledNoReason', 'RT_Failover', 'RT_Full')
    }

    It 'copies the global, team and test dependencies' {
        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot

        Test-Path (Join-Path $report.DependenciesPath 'TeamDependencies') | Should -BeTrue
        Test-Path (Join-Path $report.DependenciesPath 'TestDependencies') | Should -BeTrue
    }

    It 'honours the only list' {
        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot -OnlyTests 'RT_Full'

        $report.Tests.name | Should -Be @('RT_Full')
    }

    It 'harvests a disabled test when it is forced' {
        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot -OnlyTests 'RT_DisabledNoReason' -ForceOnlyTests

        $report.Tests.name | Should -Be @('RT_DisabledNoReason')
        $report.Tests[0].disabled.reason | Should -BeLike 'Broken since DCP1234*'
    }

    It 'only harvests baseline tests when the baseline gate is required' {
        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot -BaselineGate 'Required'

        $report.Tests.name | Should -Be @('RT_Full')
    }

    It 'applies the harvest keyword filter' {
        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot $script:FixtureRoot -Keywords 'Smoke'

        $report.Tests.name | Should -Be @('RT_Full')
    }

    It 'reads its settings from qaframework.discovery.json' {
        $configPath = Join-Path $script:ContentPath 'TestHarvesting\qaframework.discovery.json'
        @{ regressionTestsRoot = $script:FixtureRoot; onlyTests = @('RT_Diagnostic'); folderTagPrefix = 'QAOps\FromConfig\' } |
            ConvertTo-Json | Set-Content -Path $configPath -Encoding utf8

        $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath

        $report.Tests.name | Should -Be @('RT_Diagnostic')
        ([xml](Get-Content -LiteralPath (Join-Path $report.ScriptsPath 'RT_Diagnostic\script.xml') -Raw)).DMSScript.Folder |
            Should -Be 'QAOps\FromConfig\TeamB\RT_Diagnostic'
    }

    It 'throws when no RegressionTests folder can be found' {
        { Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $script:ContentPath -RegressionTestsRoot (Join-Path $script:ContentPath 'DoesNotExist') } |
            Should -Throw '*RegressionTests*'
    }
}

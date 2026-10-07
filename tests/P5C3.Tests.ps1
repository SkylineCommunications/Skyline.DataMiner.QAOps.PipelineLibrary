BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'P5C3 transport conformance' {
    It 'P5C3_Conformance_fixtures_are_copied_from_spec_commit_with_matching_hashes' {
        $metaPath = Join-Path $script:RepoRoot 'tests\fixtures\conformance\source-metadata.json'
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        $meta.files | ForEach-Object {
            if ($_.file -eq 'runtime-lookup-vectors.json') { $_.specCommit | Should -Be 'feb12b4' }
            else { $_.specCommit | Should -Be '2a8c799' }
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path (Split-Path $metaPath -Parent) $_.file)).Hash.ToLowerInvariant()
            $actual | Should -Be $_.sha256
        }
    }

    It 'P5C3_Harvest_invokes_cache_local_tool_manifest_with_resolved_paths' {
        $content = Join-Path $TestDrive 'content'
        $repo = Join-Path $TestDrive 'repo'
        New-Item -Path (Join-Path $content 'TestHarvesting') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $content 'TestPackagePipeline') -ItemType Directory -Force | Out-Null
        New-Item -Path $repo -ItemType Directory -Force | Out-Null
        Push-Location $TestDrive
        try {
            InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = '.\content'; Repo = '.\repo' } {
                Mock Install-QAFrameworkTool { [pscustomobject]@{} }
                Mock Invoke-QAFrameworkDotNet {
                    $script:HarvestArguments = $Arguments
                    $script:HarvestWorkingDirectory = $WorkingDirectory
                    [pscustomobject]@{ ExitCode = 0; TimedOut = $false; StdOut = '{"status":"completed"}'; StdErr = '' }
                }
                $report = Invoke-DotNetTestHarvesting -TestPackageContentPath $Content -RepositoryRoot $Repo
                $report.status | Should -Be 'completed'
                $script:HarvestArguments[0..3] | Should -Be @('tool','run','qaops-qaframework','--')
                $script:HarvestWorkingDirectory | Should -Not -Be (Resolve-Path -LiteralPath $Content).ProviderPath
                $script:HarvestArguments[([array]::IndexOf($script:HarvestArguments,'--content') + 1)] | Should -Be (Resolve-Path -LiteralPath $Content).ProviderPath
                $script:HarvestArguments[([array]::IndexOf($script:HarvestArguments,'--repository-root') + 1)] | Should -Be (Resolve-Path -LiteralPath $Repo).ProviderPath
            }
        }
        finally { Pop-Location }
    }

    It 'P5C3_Canonical_keys_match_5c3_vectors' {
        $fixture = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tests\fixtures\conformance\runtime-lookup-vectors.json') -Raw | ConvertFrom-Json
        foreach ($vector in @($fixture.vectors | Where-Object { $_.change -eq '5c-3' -and $_.runtimeResult.assembly -and $_.runtimeResult.fullyQualifiedName -and $_.expected.testInvocationId -or $_.expected.testInvocationIdPattern })) {
            InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Vector = $vector } {
                $identity = New-QAOpsTestInvocationIdentity -Assembly $Vector.runtimeResult.assembly -FullyQualifiedName $Vector.runtimeResult.fullyQualifiedName -DataCaseId $Vector.runtimeResult.dataCaseId -Target $Vector.runtimeResult.target
                if ($Vector.expected.testInvocationId) { $identity.TestInvocationId | Should -Be $Vector.expected.testInvocationId }
                if ($Vector.expected.doesNotEqual) { $identity.TestInvocationId | Should -Not -Be $Vector.expected.doesNotEqual }
                if ($Vector.expected.testInvocationIdPattern) { $identity.TestInvocationId | Should -Match $Vector.expected.testInvocationIdPattern }
                if ($Vector.expected.maxLength) { $identity.TestInvocationId.Length | Should -BeLessOrEqual $Vector.expected.maxLength }
                @($identity.Diagnostics | ForEach-Object { $_.code }) | Should -Be @($Vector.expected.diagnostics | ForEach-Object { $_.code })
            }
        }
    }

    It 'P5C3_TRX_unidentifiable_parameterized_case_gets_diagnostic_not_guid_identity' {
        $trxPath = Join-Path $TestDrive 'unstable.trx'
        '<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010"><TestDefinitions><UnitTest id="2f1fd6b1-5360-4d7e-bbea-1d7aaf0e9298"><TestMethod className="Acme.Tests" name="Theory" /></UnitTest></TestDefinitions><Results><UnitTestResult testId="2f1fd6b1-5360-4d7e-bbea-1d7aaf0e9298" testName="Friendly custom name" outcome="Passed" /></Results></TestRun>' | Set-Content -LiteralPath $trxPath -Encoding UTF8
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Trx = $trxPath } {
            $row = @(Get-QAOpsTrxResult -ResultsPath $Trx -AssemblyName 'Tests.dll')[0]
            $row.DataCaseId | Should -Be ''
            $row.Comparable | Should -BeFalse
            @($row.Diagnostics | ForEach-Object { $_.code }) | Should -Be @('data-case-identity-unavailable')
        }
    }

    It 'P5C3_Runtime_publishing_redacts_publication_context_and_keeps_git_fallback_provenance' {
        $content = Join-Path $TestDrive 'content-redact'
        New-Item -Path (Join-Path (Join-Path $content 'TestHarvesting') 'dependencies.generated') -ItemType Directory -Force | Out-Null
        $dll = Join-Path $content 'Tests.dll'
        Set-Content -LiteralPath $dll -Value 'x'
        $sidecar = [pscustomobject]@{ schema='https://schema.skyline.be/qaops/maintainers/v1'; version=1; testInvocations=@([pscustomobject]@{ testInvocationId='Tests.dll|Acme.Tests.Theory|data:|target:default'; maintainers=[pscustomobject]@{ version=1; references=@([pscustomobject]@{ kind='user'; id=$null; alias='git-owner'; source='git-author'; provenance='buildTimeFallback'; resolution='unresolved' }) } }) }
        $sidecar | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $content 'TestHarvesting') 'dependencies.generated') 'qaops.maintainers.json') -Encoding UTF8
        $old = $env:QAOPS_PUBLICATION_CONTEXT
        $env:QAOPS_PUBLICATION_CONTEXT = 'opaque-secret-p5c3'
        try {
            InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $content; Dll = $dll } {
                function dotnet {
                    param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments)
                    Write-Output "X-QAOps-Publication-Context: $env:QAOPS_PUBLICATION_CONTEXT"
                    $logger = @($Arguments | Where-Object { [string]$_ -like 'trx;LogFileName=*' } | Select-Object -First 1)
                    '<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010"><TestDefinitions><UnitTest id="1"><TestMethod className="Acme.Tests" name="Theory" /></UnitTest></TestDefinitions><Results><UnitTestResult testId="1" testName="Theory" outcome="Passed" /></Results></TestRun>' | Set-Content -LiteralPath ([string]$logger).Substring('trx;LogFileName='.Length) -Encoding UTF8
                    $global:LASTEXITCODE = 0
                }
                function Push-TestRunManifest { [pscustomobject]@{ Supported=$false; Accepted=$false } }
                function Push-TestRunFinalization { [pscustomobject]@{ Supported=$false; Accepted=$false } }
                function Push-TestCaseResult { param($Maintainers) $script:MaintainersJson = $Maintainers; [pscustomobject]@{ Supported=$true; Accepted=$true } }
                $output = (& { Invoke-DotNetTestAndPublishResults -PathToTestPackageContent $Content -TestDllPath $Dll -ResultsFileName 'r.trx' } *>&1 | Out-String)
                $output | Should -Not -Match 'opaque-secret-p5c3'
                $output | Should -Match 'REDACTED-QAOPS-PUBLICATION-CONTEXT'
                $script:MaintainersJson | Should -Match '"source":"git-author"'
                $script:MaintainersJson | Should -Match '"provenance":"buildTimeFallback"'
            }
        }
        finally { $env:QAOPS_PUBLICATION_CONTEXT = $old }
    }

    It 'P5C3_Old_Q_cmdlets_degrade_to_legacy_with_warning_not_throw' {
        $content = Join-Path $TestDrive 'content-legacy'
        New-Item -Path (Join-Path (Join-Path $content 'TestHarvesting') 'dependencies.generated') -ItemType Directory -Force | Out-Null
        $dll = Join-Path $content 'Tests.dll'
        Set-Content -LiteralPath $dll -Value 'x'
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $content; Dll = $dll } {
            function dotnet {
                param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments)
                $logger = @($Arguments | Where-Object { [string]$_ -like 'trx;LogFileName=*' } | Select-Object -First 1)
                '<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010"><TestDefinitions><UnitTest id="1"><TestMethod className="Acme.Tests" name="Legacy" /></UnitTest></TestDefinitions><Results><UnitTestResult testId="1" testName="Legacy" outcome="Passed" /></Results></TestRun>' | Set-Content -LiteralPath ([string]$logger).Substring('trx;LogFileName='.Length) -Encoding UTF8
                $global:LASTEXITCODE = 0
            }
            function Push-TestRunManifest { [pscustomobject]@{ Supported=$false; Accepted=$false } }
            function Push-TestRunFinalization { [pscustomobject]@{ Supported=$false; Accepted=$false } }
            function Push-TestCaseResult { param($Outcome,$Name,$Duration,$Message,$TestAspect) $script:LegacyPublished = $Name; [pscustomobject]@{ Accepted=$true } }
            $output = (& { Invoke-DotNetTestAndPublishResults -PathToTestPackageContent $Content -TestDllPath $Dll -ResultsFileName 'legacy.trx' } *>&1 | Out-String)
            $script:LegacyPublished | Should -Be 'Legacy'
            $output | Should -Match 'legacy result publishing|unverifiable'
        }
    }
}

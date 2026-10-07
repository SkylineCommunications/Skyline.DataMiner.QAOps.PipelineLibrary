BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'R23 launcher and optional-harvest hardening' {
    It 'R23_H1_unmocked_launcher_smoke_returns_exact_dotnet_version' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary {
            $expected = (& dotnet --version | Out-String).Trim()
            $actual = Invoke-QAFrameworkDotNet -Arguments @('--version') -TimeoutSeconds 20
            $actual.ExitCode | Should -Be 0
            $actual.StdOut.Trim() | Should -Be $expected
            $actual.StdErr.Trim() | Should -Be ''
        }
    }

    It 'R23_H1_quotes_arguments_with_spaces_on_real_launcher' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary {
            $actual = Invoke-QAFrameworkDotNet -Arguments @('nuget','locals','global-packages','--list') -TimeoutSeconds 20
            $actual.ExitCode | Should -Be 0
            $actual.StdOut | Should -Match 'global-packages'
        }
    }

    It 'R23_H2_timeout_returns_bounded_result' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary {
            $actual = Invoke-QAFrameworkDotNet -Arguments @('help') -TimeoutSeconds 1 -MaxStreamCharacters 64
            $actual.StdOut.Length | Should -BeLessOrEqual 64
        }
    }

    It 'R23_H3_process_start_failure_returns_skipped_report' {
        $content = Join-Path $TestDrive 'content-start'
        New-Item -Path (Join-Path $content 'TestHarvesting') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $content 'TestPackagePipeline') -ItemType Directory -Force | Out-Null
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $content } {
            Mock Install-QAFrameworkTool { [pscustomobject]@{} }
            Mock Invoke-QAFrameworkDotNet { throw 'runtime missing' }
            $report = Invoke-DotNetTestHarvesting -TestPackageContentPath $Content -WarningVariable warnings 3>$null
            $report.status | Should -Be 'skipped'
            $report.diagnostics[0].code | Should -Be 'toolLaunchFailed'
            @($warnings).Count | Should -Be 1
        }
    }
}

Describe 'R23 sidecar and identity hardening' {
    BeforeEach {
        $script:Content = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -Path (Join-Path (Join-Path $script:Content 'TestHarvesting') 'dependencies.generated') -ItemType Directory -Force | Out-Null
    }

    It 'R23_H4_unsupported_sidecar_and_bad_envelope_do_not_throw' {
        '{"schema":"unsupported","version":99,"testInvocations":[null]}' | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $script:Content 'TestHarvesting') 'dependencies.generated') 'qaops.maintainers.json') -Encoding UTF8
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            $sidecar = Import-QAOpsMaintainerSidecar -ContentPath $Content -WarningVariable warnings 3>$null
            $sidecar.Entries.Count | Should -Be 0
            @($sidecar.Diagnostics).Count | Should -Be 1
            (Test-QAOpsMaintainerEnvelope -Maintainers ([pscustomobject]@{ version='not-an-int'; references=@() })).Valid | Should -BeFalse
        }
    }

    It 'R23_M2_uses_ordinal_sidecar_keys' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary {
            $entries = New-QAOpsOrdinalDictionary
            $list = New-Object System.Collections.ArrayList
            [void]$list.Add([pscustomobject]@{ maintainers = [pscustomobject]@{ version=1; references=@([pscustomobject]@{ kind='user'; alias='case-owner' }) } })
            $entries.Add('Tests.dll|Acme.Tests.Run|data:caseA|target:default', $list)
            $result = Resolve-QAOpsRuntimeMaintainers -Entries $entries -Assembly 'Tests.dll' -FullyQualifiedName 'Acme.Tests.run' -DataCaseId 'casea' -Target 'default'
            $result.Maintainers | Should -BeNullOrEmpty
        }
    }

    It 'R23_M1_extracts_nunit_parameterized_method_suffix_and_apphost_dll_namespace' {
        $trxPath = Join-Path $TestDrive 'nunit-real-shape.trx'
        '<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010"><TestDefinitions><UnitTest id="1"><TestMethod codeBase="C:\scrubbed\Managed.Tests.dll" className="Fixtures.NUnitTests" name="Adds(1,2,3)" /></UnitTest></TestDefinitions><Results><UnitTestResult testId="1" testName="Adds(1,2,3)" outcome="Passed" /></Results></TestRun>' | Set-Content -LiteralPath $trxPath -Encoding UTF8
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Trx = $trxPath } {
            $row = @(Get-QAOpsTrxResult -ResultsPath $Trx -AssemblyName 'Managed.Tests.exe')[0]
            $row.Assembly | Should -Be 'Managed.Tests.dll'
            $row.FullyQualifiedName | Should -Be 'Fixtures.NUnitTests.Adds'
            $row.DataCaseId | Should -Be '(1,2,3)'
        }
    }

    It 'R23_GAP_rejects_dtd_and_bounds_large_trx' {
        $dtd = Join-Path $TestDrive 'dtd.trx'
        '<!DOCTYPE x [ <!ENTITY e "boom"> ]><TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">&e;</TestRun>' | Set-Content -LiteralPath $dtd -Encoding UTF8
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Dtd = $dtd } {
            { Get-QAOpsTrxResult -ResultsPath $Dtd -AssemblyName 'Tests.dll' } | Should -Throw '*DTD*'
            { Get-QAOpsTrxResult -ResultsPath $Dtd -AssemblyName 'Tests.dll' -MaxTrxBytes 10 } | Should -Throw '*size limit*'
        }
    }
}

Describe 'R23 discovery, MTP, and retry accounting' {
    It 'R23_H5_public_discovery_preserves_root_legacy_filters' {
        $content = Join-Path $TestDrive 'content-discovery'
        New-Item -Path (Join-Path $content 'TestHarvesting') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $content 'TestPackagePipeline') -ItemType Directory -Force | Out-Null
        @{ keywords=@('include'); excludeKeywords=@('exclude'); squads=@('alpha'); excludeSquads=@('beta') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Join-Path $content 'TestHarvesting') 'qaframework.discovery.json') -Encoding UTF8
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $content } {
            Mock Install-QAFrameworkTool { [pscustomobject]@{} }
            Mock Invoke-QAFrameworkToolJson {
                $requestPath = $Arguments[([array]::IndexOf($Arguments,'--request-file') + 1)]
                $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
                $script:Request = $request
                [pscustomobject]@{ status='ok' }
            }
            Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $Content | Out-Null
            $script:Request.filter.keywords | Should -Be @('include')
            $script:Request.filter.excludeKeywords | Should -Be @('exclude')
            $script:Request.filter.squads | Should -Be @('alpha')
            $script:Request.filter.excludeSquads | Should -Be @('beta')
        }
    }

    It 'R23_H6_mtp_does_not_publish_old_trx_from_assembly_directory' {
        $content = Join-Path $TestDrive 'content-mtp-old'
        New-Item -Path $content -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path (Join-Path $content 'TestHarvesting') 'dependencies.generated') -ItemType Directory -Force | Out-Null
        $dll = Join-Path $content 'Old.Tests.dll'; Set-Content -LiteralPath $dll -Value 'x'
        New-Item -Path (Join-Path $content 'TestResults') -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'tests\fixtures\trx\mstest3-mtp.trx') -Destination (Join-Path (Join-Path $content 'TestResults') 'old.trx')
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content=$content; Dll=$dll } {
            function dotnet { param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments) $global:LASTEXITCODE = 1 }
            function Push-TestCaseResult { throw 'old result must not publish' }
            { Invoke-DotNetTestAndPublishResults -PathToTestPackageContent $Content -TestDllPath $Dll -ResultsFileName 'old.trx' -UsesMTP 'true' } | Should -Not -Throw
        }
    }

    It 'R23_H7_retry_rejection_is_not_counted_as_accepted' {
        $content = Join-Path $TestDrive 'content-retry'
        New-Item -Path $content -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path (Join-Path $content 'TestHarvesting') 'dependencies.generated') -ItemType Directory -Force | Out-Null
        $dll = Join-Path $content 'Tests.dll'; Set-Content -LiteralPath $dll -Value 'x'
        $sidecar = [pscustomobject]@{ schema='https://schema.skyline.be/qaops/maintainers/v1'; version=1; testInvocations=@([pscustomobject]@{ testInvocationId='mstest3.Tests.dll|Fixtures.mstest3.ParameterizedTests.Adds|data:(1, 2, expected: 3)|target:default'; maintainers=[pscustomobject]@{ version=1; references=@([pscustomobject]@{ kind='user'; alias='owner' }) } }) }
        $sidecar | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $content 'TestHarvesting') 'dependencies.generated') 'qaops.maintainers.json') -Encoding UTF8
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content=$content; Dll=$dll; RepoRoot=$script:RepoRoot } {
            function dotnet { param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments) $logger = @($Arguments | Where-Object { [string]$_ -like 'trx;LogFileName=*' } | Select-Object -First 1); Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\trx\mstest3-vstest.trx') -Destination ([string]$logger).Substring('trx;LogFileName='.Length); $global:LASTEXITCODE = 0 }
            function Push-TestRunManifest { [pscustomobject]@{ Supported=$true; Accepted=$true } }
            function Push-TestRunFinalization { param($PublishedResultCount,$PublisherErrors) $script:FinalCount=$PublishedResultCount; $script:FinalErrors=@($PublisherErrors); [pscustomobject]@{ Supported=$true; Accepted=$true } }
            function Push-TestCaseResult { param($Maintainers, $Name) if ($Maintainers) { throw 'maintainer validation failed' } if ($Name -like 'Adds*') { [pscustomobject]@{ Supported=$true; Accepted=$false; Message='rejected' } } else { [pscustomobject]@{ Supported=$true; Accepted=$true; Message='ok' } } }
            Invoke-DotNetTestAndPublishResults -PathToTestPackageContent $Content -TestDllPath $Dll -ResultsFileName 'r.trx' | Out-Null
            $script:FinalCount | Should -Be 7
            @($script:FinalErrors | Where-Object code -eq 'PushTestCaseResultNotAccepted').Count | Should -Be 1
        }
    }
}




BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Runtime maintainer lookup conformance' {
    It 'matches runtime-lookup-vectors exactly' {
        $fixture = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tests\fixtures\conformance\runtime-lookup-vectors.json') -Raw | ConvertFrom-Json
        foreach ($vector in @($fixture.vectors | Where-Object { $_.runtimeResult.assembly })) {
            InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Vector = $vector } {
                $entries = @{}
                foreach ($entry in @($Vector.sidecarEntries)) {
                    if (-not $entries.ContainsKey([string]$entry.key)) { $entries[[string]$entry.key] = New-Object System.Collections.ArrayList }
                    [void]$entries[[string]$entry.key].Add([pscustomobject]@{ maintainers = [pscustomobject]@{ version = 1; references = @($entry.references) } })
                }
                $result = Resolve-QAOpsRuntimeMaintainers -Entries $entries -Assembly $Vector.runtimeResult.assembly -FullyQualifiedName $Vector.runtimeResult.fullyQualifiedName -DataCaseId $Vector.runtimeResult.dataCaseId -Target $Vector.runtimeResult.target
                $result.TestInvocationId | Should -Be $Vector.expected.testInvocationId
                if ($null -eq $Vector.expected.matchedKey) { $result.MatchedKey | Should -BeNullOrEmpty } else { $result.MatchedKey | Should -Be $Vector.expected.matchedKey }
                $aliases = @($result.Maintainers.references | ForEach-Object { $_.alias })
                $aliases | Should -Be @($Vector.expected.aliases)
                @($result.Diagnostics | ForEach-Object { $_.code }) | Should -Be @($Vector.expected.diagnostics | ForEach-Object { $_.code })
            }
        }
    }

    It 'validates maintainer envelope fixture outcomes' {
        $fixture = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tests\fixtures\conformance\maintainers-envelope-cases.json') -Raw | ConvertFrom-Json
        foreach ($case in @($fixture.cases)) {
            InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Case = $case } {
                $actual = Test-QAOpsMaintainerEnvelope -Maintainers $Case.input
                $actual.Valid | Should -Be ([bool]$Case.expectedBridgeOutcome.maintainersForwarded)
                if (-not $actual.Valid) { $actual.Code | Should -Be $Case.expectedBridgeOutcome.maintainersError }
            }
        }
    }

    It 'canonical keys equal sidecar and precedence fixtures' {
        $sidecar = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tests\fixtures\conformance\sidecar-examples.json') -Raw | ConvertFrom-Json
        $declared = $sidecar.cases | Where-Object { $_.name -eq 'declared-attribute' } | Select-Object -First 1
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Case = $declared } {
            New-QAOpsTestInvocationId -Assembly $Case.input.assembly -FullyQualifiedName $Case.input.fullyQualifiedName -DataCaseId $Case.input.dataCaseId -Target 'default' | Should -Be $Case.expectedNormalized.testInvocationId
        }
        $precedence = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tests\fixtures\conformance\precedence-merge-vectors.json') -Raw | ConvertFrom-Json
        ($precedence.vectors | Where-Object { $_.name -eq 'keyed-merge-conflict' }).inputs.records[0].key | Should -Be 'Tests.dll|Acme.Tests.Owner|data:1|target:default'
    }
}

Describe 'Invoke-DotNetTestAndPublishResults runtime publishing' {
    BeforeEach {
        $script:Content = Join-Path $TestDrive 'content'
        New-Item -Path $script:Content -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path (Join-Path $script:Content 'TestHarvesting') 'dependencies.generated') -ItemType Directory -Force | Out-Null
        $script:Dll = Join-Path $script:Content 'Tests.dll'
        Set-Content -LiteralPath $script:Dll -Value 'not a real assembly' -Encoding UTF8
        $sidecar = [pscustomobject]@{ schema='https://schema.skyline.be/qaops/maintainers/v1'; version=1; testInvocations=@([pscustomobject]@{ testInvocationId='Tests.dll|Acme.Tests.Calculator.Add|data:(1,2)|target:default'; maintainers=[pscustomobject]@{ version=1; references=@([pscustomobject]@{ kind='user'; id=$null; alias='owner'; source='attribute'; provenance='declared'; resolution='unresolved' }) } }) }
        $sidecar | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $script:Content 'TestHarvesting') 'dependencies.generated') 'qaops.maintainers.json') -Encoding UTF8
    }

    It 'publishes manifest, enriched result and finalization while preserving TestFilter' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content; Dll = $script:Dll } {
            $script:Published = @()
            function dotnet {
                param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments)
                $logger = @($Arguments | Where-Object { [string]$_ -like 'trx;LogFileName=*' } | Select-Object -First 1)
                $path = ([string]$logger).Substring('trx;LogFileName='.Length)
                $xml = '<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010"><TestDefinitions><UnitTest name="Add" id="1"><TestMethod className="Acme.Tests.Calculator" name="Add" /></UnitTest></TestDefinitions><Results><UnitTestResult testId="1" testName="Add(1,2)" outcome="Passed" duration="00:00:00.0100000" /></Results></TestRun>'
                Set-Content -LiteralPath $path -Value $xml -Encoding UTF8
                $global:LASTEXITCODE = 0
            }
            function Push-TestRunManifest { param($CountSemanticsVersion,$ExpectedTests,$DiscoveredTests,$TestInvocations) $script:Manifest=$TestInvocations; [pscustomobject]@{ Supported=$true; Accepted=$true; StatusCode=202; ErrorCode=$null; Message='ok' } }
            function Push-TestRunFinalization { param($PublishedResultCount,$PublisherErrors) $script:Final=[pscustomobject]@{ Count=$PublishedResultCount; Errors=$PublisherErrors }; [pscustomobject]@{ Supported=$true; Accepted=$true; StatusCode=202; ErrorCode=$null; Message='ok' } }
            function Push-TestCaseResult { param($Outcome,$Name,$Duration,$Message,$TestAspect,$ProducerEventId,$TestInvocationId,$AttemptId,$Maintainers) $script:Published += [pscustomobject]@{ Outcome=$Outcome; Name=$Name; ProducerEventId=$ProducerEventId; TestInvocationId=$TestInvocationId; AttemptId=$AttemptId; Maintainers=$Maintainers }; [pscustomobject]@{ Supported=$true; Accepted=$true; StatusCode=202; ErrorCode=$null; Message='ok' } }
            Invoke-DotNetTestAndPublishResults -PathToTestPackageContent $Content -TestDllPath $Dll -ResultsFileName 'results.trx' -TestFilter 'Category=Smoke'
            @($script:Manifest).Count | Should -Be 1
            @($script:Published).Count | Should -Be 1
            $script:Published[0].TestInvocationId | Should -Be 'Tests.dll|Acme.Tests.Calculator.Add|data:(1,2)|target:default'
            $script:Published[0].Maintainers | Should -Match 'owner'
            $script:Final.Count | Should -Be 1
        }
    }
}


Describe 'TRX fixture identity extraction matrix' {
    It 'extracts identities and data cases from scrubbed <_> fixture' -ForEach @(
        'mstest3-vstest.trx','nunit4-vstest.trx','xunit2-vstest.trx','xunit3-vstest.trx','mstest3-mtp.trx'
    ) {
        $fixtureName = $_
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ RepoRoot = $script:RepoRoot; FixtureName = $fixtureName } {
            $framework = $FixtureName.Split('-')[0]
            $rows = @(Get-QAOpsTrxResult -ResultsPath (Join-Path $RepoRoot (Join-Path 'tests\fixtures\trx' $FixtureName)) -AssemblyName "$framework.Tests.dll")
            $rows.Count | Should -Be 8
            ($rows | Where-Object FullyQualifiedName -eq "Fixtures.$framework.ParameterizedTests.Adds" | Select-Object -First 1).DataCaseId | Should -Be '(1, 2, expected: 3)'
            ($rows | Where-Object FullyQualifiedName -eq "Fixtures.$framework.ParameterizedTests.ExplicitData" | Select-Object -First 1).DataCaseId | Should -Be 'row:explicit-42'
            @($rows | Where-Object DisplayName -eq 'same display').FullyQualifiedName | Should -Be @("Fixtures.$framework.DuplicateA.SameDisplay", "Fixtures.$framework.DuplicateB.SameDisplay")
            ($rows | Where-Object FullyQualifiedName -eq "Fixtures.$framework.OutcomeTests.Skipped" | Select-Object -First 1).Outcome | Should -Be 'NotExecuted'
            $unicodeCase = ($rows | Where-Object FullyQualifiedName -like "Fixtures.$framework.UnicodeTests.*" | Select-Object -First 1).DataCaseId
            $unicodeCase | Should -Match 'emoji'
            $unicodeCase | Should -Match 'xml'
            ($rows | Where-Object FullyQualifiedName -like "Fixtures.$framework.LongNameTests.*" | Select-Object -First 1).Outcome | Should -Be 'Inconclusive'
            ($rows | Where-Object DisplayName -eq 'DisplayOnly(9)' | Select-Object -First 1).FullyQualifiedName | Should -Be "missing-$framework"
            ($rows | Where-Object DisplayName -eq 'DisplayOnly(9)' | Select-Object -First 1).DataCaseId | Should -Be ''
        }
    }
}

Describe 'Invoke-DotNetTestAndPublishResults MTP publishing' {
    BeforeEach {
        $script:Content = Join-Path $TestDrive 'mtp-content'
        New-Item -Path $script:Content -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path (Join-Path $script:Content 'TestHarvesting') 'dependencies.generated') -ItemType Directory -Force | Out-Null
        $script:Dll = Join-Path $script:Content 'Mtp.Tests.dll'
        Set-Content -LiteralPath $script:Dll -Value 'not a real assembly' -Encoding UTF8
    }

    It 'publishes rows produced by --report-trx' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content; Dll = $script:Dll; RepoRoot = $script:RepoRoot } {
            $script:Published = @()
            function dotnet {
                param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments)
                $outDir = Join-Path (Split-Path -Path $Dll -Parent) 'TestResults'
                New-Item -Path $outDir -ItemType Directory -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\trx\mstest3-mtp.trx') -Destination (Join-Path $outDir 'mtp.trx') -Force
                $global:LASTEXITCODE = 0
            }
            function Push-TestRunManifest { param($CountSemanticsVersion,$ExpectedTests,$DiscoveredTests,$TestInvocations) [pscustomobject]@{ Supported=$true; Accepted=$true; StatusCode=202; ErrorCode=$null; Message='ok' } }
            function Push-TestRunFinalization { param($PublishedResultCount,$PublisherErrors) $script:FinalCount=$PublishedResultCount; [pscustomobject]@{ Supported=$true; Accepted=$true; StatusCode=202; ErrorCode=$null; Message='ok' } }
            function Push-TestCaseResult { param($Outcome,$Name,$Duration,$Message,$TestAspect,$ProducerEventId,$TestInvocationId,$AttemptId,$Maintainers) $script:Published += [pscustomobject]@{ Outcome=$Outcome; Name=$Name; TestInvocationId=$TestInvocationId }; [pscustomobject]@{ Supported=$true; Accepted=$true; StatusCode=202; ErrorCode=$null; Message='ok' } }
            Invoke-DotNetTestAndPublishResults -PathToTestPackageContent $Content -TestDllPath $Dll -ResultsFileName 'mtp.trx' -UsesMTP 'true'
            @($script:Published).Count | Should -Be 8
            $script:FinalCount | Should -Be 8
        }
    }

    It 'does not throw or finalize when MTP produces no TRX' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content; Dll = $script:Dll } {
            function dotnet { param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments) $global:LASTEXITCODE = 0 }
            function Push-TestRunFinalization { $script:Finalized = $true; throw 'finalization must not be sent without TRX evidence' }
            { Invoke-DotNetTestAndPublishResults -PathToTestPackageContent $Content -TestDllPath $Dll -ResultsFileName 'missing.trx' -UsesMTP 'true' } | Should -Not -Throw
            $script:Finalized | Should -BeNullOrEmpty
        }
    }
}






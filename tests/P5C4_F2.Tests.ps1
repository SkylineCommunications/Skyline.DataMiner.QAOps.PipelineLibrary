BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'P5C3F2 redacted native dotnet execution' {
    BeforeEach {
        $script:OldPath = $env:PATH
        $script:OldContext = $env:QAOPS_PUBLICATION_CONTEXT
        $env:QAOPS_PUBLICATION_CONTEXT = 'p5c3f2-secret'
        $stubDir = Join-Path $TestDrive 'stubbin'
        New-Item -Path $stubDir -ItemType Directory -Force | Out-Null
        @'
@echo off
echo X-QAOps-Publication-Context: %QAOPS_PUBLICATION_CONTEXT% 1>&2
if "%1"=="fail" exit /b 1
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $stubDir 'dotnet.cmd') -Encoding ASCII
        $env:PATH = $stubDir + [System.IO.Path]::PathSeparator + $env:PATH
    }

    AfterEach {
        $env:PATH = $script:OldPath
        $env:QAOPS_PUBLICATION_CONTEXT = $script:OldContext
    }

    It 'P5C3F2_RedactedDotNet_stderr_exit0_does_not_throw_under_EAP_Stop' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary {
            $old = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
            try {
                $output = (& { $script:ExitCode = Invoke-QAOpsRedactedDotNet -Arguments @('ok') } *>&1 | Out-String)
            }
            finally { $ErrorActionPreference = $old }
            $script:ExitCode | Should -Be 0
            $output | Should -Not -Match 'p5c3f2-secret'
            $output | Should -Match 'REDACTED-QAOPS-PUBLICATION-CONTEXT'
        }
    }

    It 'P5C3F2_RedactedDotNet_stderr_exit1_returns_nonzero_without_throw_under_EAP_Stop' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary {
            $old = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
            try {
                { $script:ExitCode = Invoke-QAOpsRedactedDotNet -Arguments @('fail') } | Should -Not -Throw
            }
            finally { $ErrorActionPreference = $old }
            $script:ExitCode | Should -Be 1
        }
    }
}

Describe 'P5C3F2 harvest assembly path resolution' {
    It 'P5C3F2_Harvest_resolves_relative_assemblies_against_content_and_leaves_absolute_paths' {
        $content = Join-Path $TestDrive 'content'
        New-Item -Path (Join-Path $content 'TestHarvesting') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $content 'TestPackagePipeline') -ItemType Directory -Force | Out-Null
        $absolute = Join-Path $TestDrive 'External.Tests.dll'
        Set-Content -LiteralPath $absolute -Value 'x'
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $content; Absolute = $absolute } {
            Mock Install-QAFrameworkTool { [pscustomobject]@{} }
            Mock Invoke-QAFrameworkDotNet {
                $script:HarvestArguments = $Arguments
                [pscustomobject]@{ ExitCode = 0; TimedOut = $false; StdOut = '{"status":"completed"}'; StdErr = '' }
            }
            Invoke-DotNetTestHarvesting -TestPackageContentPath $Content -TestAssemblyPath @('TestHarvesting\tests.generated\Rel.Tests.dll', $Absolute) | Out-Null
            $assemblyIndexes = for ($i = 0; $i -lt $script:HarvestArguments.Count; $i++) { if ($script:HarvestArguments[$i] -eq '--assembly') { $i + 1 } }
            $script:HarvestArguments[$assemblyIndexes[0]] | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $Content 'TestHarvesting\tests.generated\Rel.Tests.dll')))
            $script:HarvestArguments[$assemblyIndexes[1]] | Should -Be ([System.IO.Path]::GetFullPath($Absolute))
        }
    }
}

Describe 'P5C4 canonical identity handling' {
    It 'P5C4_Runtime_lookup_vectors_match_exact_5c4_outputs' {
        $fixture = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tests\fixtures\conformance\runtime-lookup-vectors.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($vector in @($fixture.vectors | Where-Object { $_.change -eq '5c-4' })) {
            InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Vector = $vector } {
                $identity = New-QAOpsTestInvocationIdentity -Assembly $Vector.runtimeResult.assembly -FullyQualifiedName $Vector.runtimeResult.fullyQualifiedName -DataCaseId $Vector.runtimeResult.dataCaseId -Target $Vector.runtimeResult.target
                if ($null -eq $Vector.expected.testInvocationId) { $identity.TestInvocationId | Should -BeNullOrEmpty } else { $identity.TestInvocationId | Should -Be $Vector.expected.testInvocationId }
                @($identity.Diagnostics | ForEach-Object { $_.code }) | Should -Be @($Vector.expected.diagnostics | ForEach-Object { $_.code })
                if ($Vector.expected.scalarCount) { (Get-QAOpsScalarCount -Value $identity.TestInvocationId) | Should -Be $Vector.expected.scalarCount }
            }
        }
    }

    It 'P5C4_Lone_surrogate_identity_does_not_throw_and_returns_identity_invalid' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary {
            $bad = [string][char]0xD800
            { $script:Identity = New-QAOpsTestInvocationIdentity -Assembly 'Tests.dll' -FullyQualifiedName ('Acme.Tests.' + $bad) -DataCaseId $bad -Target 'default' } | Should -Not -Throw
            $script:Identity.TestInvocationId | Should -BeNullOrEmpty
            @($script:Identity.Diagnostics | ForEach-Object { $_.code }) | Should -Be @('identity-invalid')
            (New-QAOpsTestInvocationId -Assembly 'Tests.dll' -FullyQualifiedName ('Acme.Tests.' + $bad) -DataCaseId $bad -Target 'default') | Should -BeNullOrEmpty
        }
    }

    It 'P5C4_Runtime_publishes_lone_surrogate_result_without_id_or_manifest_entry' {
        $content = Join-Path $TestDrive 'content-invalid'
        New-Item -Path (Join-Path (Join-Path $content 'TestHarvesting') 'dependencies.generated') -ItemType Directory -Force | Out-Null
        $dll = Join-Path $content 'Tests.dll'
        Set-Content -LiteralPath $dll -Value 'x'
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $content; Dll = $dll } {
            $bad = [string][char]0xD800
            function dotnet { param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments) $logger = @($Arguments | Where-Object { [string]$_ -like 'trx;LogFileName=*' } | Select-Object -First 1); '<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010" />' | Set-Content -LiteralPath ([string]$logger).Substring('trx;LogFileName='.Length) -Encoding UTF8; $global:LASTEXITCODE = 0 }
            Mock Get-QAOpsTrxResult { @([pscustomobject]@{ Assembly='Tests.dll'; FullyQualifiedName=('Acme.Tests.' + $bad); DisplayName='bad identity'; DataCaseId=$bad; Outcome='Passed'; Duration=[TimeSpan]::Zero; Message=''; Diagnostics=@(); Comparable=$true }) }
            function Push-TestRunManifest { param($TestInvocations) $script:ManifestInvocations = @($TestInvocations); [pscustomobject]@{ Supported=$true; Accepted=$true } }
            function Push-TestRunFinalization { param($PublishedResultCount,$PublisherErrors) $script:FinalCount=$PublishedResultCount; $script:FinalErrors=@($PublisherErrors); [pscustomobject]@{ Supported=$true; Accepted=$true } }
            function Push-TestCaseResult { param($Name,$TestInvocationId,$Maintainers) $script:Published = [pscustomobject]@{ Name=$Name; TestInvocationId=$TestInvocationId; Maintainers=$Maintainers }; [pscustomobject]@{ Supported=$true; Accepted=$true } }
            Invoke-DotNetTestAndPublishResults -PathToTestPackageContent $Content -TestDllPath $Dll -ResultsFileName 'invalid.trx'
            $script:Published.Name | Should -Be 'bad identity'
            $script:Published.TestInvocationId | Should -BeNullOrEmpty
            $script:Published.Maintainers | Should -BeNullOrEmpty
            @($script:ManifestInvocations).Count | Should -Be 0
            @($script:FinalErrors | Where-Object code -eq 'identity-invalid').Count | Should -Be 1
            $script:FinalCount | Should -Be 1
        }
    }
}

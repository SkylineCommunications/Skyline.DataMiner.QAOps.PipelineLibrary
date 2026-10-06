BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Invoke-DotNetTestHarvesting' {
    BeforeEach {
        $script:Content = Join-Path $TestDrive 'content'
        New-Item -Path (Join-Path $script:Content 'TestHarvesting') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:Content 'TestPackagePipeline') -ItemType Directory -Force | Out-Null
    }

    It 'returns parsed harvest report and sends token only through child environment' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            Mock Install-QAFrameworkTool { [pscustomobject]@{} }
            Mock Invoke-QAFrameworkDotNet { [pscustomobject]@{ ExitCode = 0; StdOut = '{"schemaVersion":1,"command":"harvest-dotnet","status":"completed","sidecarPath":"sidecar","assemblies":[],"counts":{"tests":1,"declared":0,"reviewedManifest":0,"gitFallback":0,"unresolved":0,"conflicts":0},"diagnostics":[]}'; StdErr = ''; TimedOut = $false } }
            $secure = ConvertTo-SecureString 'secret-token' -AsPlainText -Force
            $report = Invoke-DotNetTestHarvesting -TestPackageContentPath $Content -GitHubToken $secure -TestAssemblyPath 'tests.generated\A.dll' -GitHubOrganizations SkylineCommunications -AllowedEmailDomains skyline.be
            $report.status | Should -Be 'completed'
            Should -Invoke Invoke-QAFrameworkDotNet -Times 1 -ParameterFilter { $Arguments -contains 'harvest-dotnet' -and $Arguments -notcontains 'secret-token' -and $Environment['QAOPS_GITHUB_TOKEN'] -eq 'secret-token' }
        }
    }

    It 'synthesizes skipped when tool install fails offline' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            Mock Install-QAFrameworkTool { throw 'offline' }
            $report = Invoke-DotNetTestHarvesting -TestPackageContentPath $Content -WarningVariable warnings 3>$null
            $report.status | Should -Be 'skipped'
            $report.diagnostics[0].code | Should -Be 'toolInstallFailed'
            @($warnings).Count | Should -Be 1
        }
    }

    It 'synthesizes skipped when tool is too old' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            Mock Install-QAFrameworkTool { [pscustomobject]@{} }
            Mock Invoke-QAFrameworkDotNet { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Unrecognized command harvest-dotnet'; TimedOut = $false } }
            $report = Invoke-DotNetTestHarvesting -TestPackageContentPath $Content -WarningVariable warnings 3>$null
            $report.status | Should -Be 'skipped'
            $report.diagnostics[0].code | Should -Be 'toolTooOld'
            @($warnings).Count | Should -Be 1
        }
    }

    It 'synthesizes skipped for timeout and non-JSON output' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            Mock Install-QAFrameworkTool { [pscustomobject]@{} }
            Mock Invoke-QAFrameworkDotNet { [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $true } }
            (Invoke-DotNetTestHarvesting -TestPackageContentPath $Content -WarningVariable w1 3>$null).diagnostics[0].code | Should -Be 'toolTimeout'
            Mock Invoke-QAFrameworkDotNet { [pscustomobject]@{ ExitCode = 0; StdOut = 'not-json'; StdErr = ''; TimedOut = $false } }
            (Invoke-DotNetTestHarvesting -TestPackageContentPath $Content -WarningVariable w2 3>$null).diagnostics[0].code | Should -Be 'nonJsonOutput'
        }
    }
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'QAFramework reconstructed private helpers' {
    BeforeEach {
        $script:Content = Join-Path $TestDrive 'content'
        New-Item -Path (Join-Path $script:Content 'TestHarvesting') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:Content 'TestPackagePipeline') -ItemType Directory -Force | Out-Null
    }

    It 'resolves content paths from content root and TestHarvesting' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            $fromRoot = Resolve-QAFrameworkContentPath -Path $Content
            $fromHarvest = Resolve-QAFrameworkContentPath -Path (Join-Path $Content 'TestHarvesting')
            $fromRoot.ContentPath | Should -Be $fromHarvest.ContentPath
            $fromRoot.HarvestPath | Should -Be (Join-Path $fromRoot.ContentPath 'TestHarvesting')
            $fromRoot.PipelinePath | Should -Be (Join-Path $fromRoot.ContentPath 'TestPackagePipeline')
        }
    }

    It 'creates a request file with the override document' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary {
            $path = New-QAFrameworkRequestFile -Overrides @{ selectionPolicy = 'LegacyPipeline'; filter = @{ keywords = @('smoke') } } -Directory $TestDrive
            Test-Path -LiteralPath $path | Should -BeTrue
            $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $doc.selectionPolicy | Should -Be 'LegacyPipeline'
            $doc.filter.keywords | Should -Be @('smoke')
        }
    }

    It 'converts known legacy discovery keys' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary {
            $legacy = [pscustomobject]@{ folderTagPrefix = 'F'; excludedKeywords = @('slow'); execution = [pscustomobject]@{ timeoutSeconds = 42 }; filter = [pscustomobject]@{ attributeKeywords = @('smoke') } }
            $converted = ConvertFrom-QAFrameworkLegacyDiscoveryConfig -Document $legacy
            $converted['folderTagPrefix'] | Should -Be 'F'
            $converted['keywords'] | Should -Be @('smoke')
            $converted['excludeKeywords'] | Should -Be @('slow')
            $converted['testTimeoutSeconds'] | Should -Be 42
        }
    }

    It 'invokes the dotnet seam for tool JSON and parses stdout' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            Mock Invoke-QAFrameworkDotNet { [pscustomobject]@{ ExitCode = 0; StdOut = '{"status":"ok"}'; StdErr = ''; TimedOut = $false } }
            $report = Invoke-QAFrameworkToolJson -PipelineDirectory (Join-Path $Content 'TestPackagePipeline') -Operation discover -Arguments @('discover','--content',$Content)
            $report.status | Should -Be 'ok'
            Should -Invoke Invoke-QAFrameworkDotNet -Times 1 -ParameterFilter { $Arguments -contains '--json' }
        }
    }

    It 'reports bounded stderr for failed tool JSON' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            Mock Invoke-QAFrameworkDotNet { [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = ('x' * 5000); TimedOut = $false } }
            { Invoke-QAFrameworkToolJson -PipelineDirectory (Join-Path $Content 'TestPackagePipeline') -Operation discover -Arguments @('discover') } | Should -Throw '*exit code 2*truncated*'
        }
    }
}

Describe 'QAFramework public shims with reconstructed helpers' {
    BeforeEach {
        $script:Content = Join-Path $TestDrive 'content'
        New-Item -Path (Join-Path $script:Content 'TestHarvesting') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:Content 'TestPackagePipeline') -ItemType Directory -Force | Out-Null
    }

    It 'Initialize-QAFrameworkAgents calls setup through the tool seam' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            Mock Install-QAFrameworkTool { [pscustomobject]@{} }
            Mock Invoke-QAFrameworkToolJson { [pscustomobject]@{ agents = @([pscustomobject]@{ name = 'agent1' }) } }
            $agents = Initialize-QAFrameworkAgents -TestPackageContentPath $Content
            $agents.name | Should -Be 'agent1'
            Should -Invoke Invoke-QAFrameworkToolJson -Times 1 -ParameterFilter { $Operation -eq 'setup' -and $Arguments -contains 'setup' }
        }
    }

    It 'Invoke-QAFrameworkTestDiscovery calls discover through the tool seam' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            Mock Install-QAFrameworkTool { [pscustomobject]@{} }
            Mock Invoke-QAFrameworkToolJson { [pscustomobject]@{ status = 'completed' } }
            $report = Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $Content -Keywords smoke
            $report.status | Should -Be 'completed'
            Should -Invoke Invoke-QAFrameworkToolJson -Times 1 -ParameterFilter { $Operation -eq 'discover' -and $Arguments -contains 'discover' }
        }
    }

    It 'Invoke-QAFrameworkTestPackage calls run through the tool seam' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Content = $script:Content } {
            Mock Install-QAFrameworkTool { [pscustomobject]@{} }
            Mock Invoke-QAFrameworkToolJson { [pscustomobject]@{ overallOutcome = 'Passed'; attempts = @(); skipped = @(); errors = @() } }
            $report = Invoke-QAFrameworkTestPackage -TestPackageContentPath $Content -PassThru
            $report.overallOutcome | Should -Be 'Passed'
            Should -Invoke Invoke-QAFrameworkToolJson -Times 1 -ParameterFilter { $Operation -eq 'run' -and $Arguments -contains 'run' }
        }
    }
}

Describe 'QAFramework tool install NuGet safety' {
    BeforeEach {
        $script:Pipeline = Join-Path $TestDrive 'pipeline'
        New-Item -Path $script:Pipeline -ItemType Directory -Force | Out-Null
    }

    It 'does not create a repository NuGet.config when none exists' {
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Pipeline = $script:Pipeline } {
            $script:DotNetCalls = @()
            Mock Invoke-QAFrameworkDotNet { $script:DotNetCalls += ,@($Arguments); [pscustomobject]@{ ExitCode=0; StdOut=''; StdErr=''; TimedOut=$false } }
            Install-QAFrameworkTool -PipelineDirectory $Pipeline | Out-Null
            Test-Path -LiteralPath (Join-Path $Pipeline 'NuGet.config') | Should -BeFalse
            (@($script:DotNetCalls | ForEach-Object { $_ }) -contains '--configfile') | Should -BeFalse
        }
    }

    It 'uses but does not overwrite an existing package NuGet.config' {
        Set-Content -LiteralPath (Join-Path $script:Pipeline 'NuGet.config') -Value '<configuration><packageSources><add key="private" value="https://example.invalid/v3/index.json" /></packageSources></configuration>' -Encoding UTF8
        InModuleScope Skyline.DataMiner.QAOps.PipelineLibrary -Parameters @{ Pipeline = $script:Pipeline } {
            $script:DotNetCalls = @()
            Mock Invoke-QAFrameworkDotNet { $script:DotNetCalls += ,@($Arguments); [pscustomobject]@{ ExitCode=0; StdOut=''; StdErr=''; TimedOut=$false } }
            Install-QAFrameworkTool -PipelineDirectory $Pipeline | Out-Null
            (Get-Content -LiteralPath (Join-Path $Pipeline 'NuGet.config') -Raw) | Should -Match 'private'
            (@($script:DotNetCalls | ForEach-Object { $_ }) -contains '--configfile') | Should -BeTrue
        }
    }
}

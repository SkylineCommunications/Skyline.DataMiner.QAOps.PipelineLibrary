BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1'
    Import-Module $script:ModulePath -Force
}

Describe 'Module import' {
    It 'Imports without errors' {
        { Import-Module $script:ModulePath -Force } | Should -Not -Throw
    }

    It 'Exports Invoke-DotNetTestAndPublishResults' {
        (Get-Command -Module Skyline.DataMiner.QAOps.PipelineLibrary).Name | Should -Contain 'Invoke-DotNetTestAndPublishResults'
    }
}

Describe 'Module manifest' {
    BeforeAll {
        $script:Manifest = Import-PowerShellDataFile -Path $script:ModulePath
        $script:PublicFunctions = Get-ChildItem (Join-Path $script:RepoRoot 'Public') -Filter *.ps1 |
            ForEach-Object { $_.BaseName }
    }

    It 'exports exactly one function per file in Public' {
        ($script:Manifest.FunctionsToExport | Sort-Object) | Should -Be ($script:PublicFunctions | Sort-Object)
    }

    It 'exports every public function at runtime' {
        $exported = (Get-Command -Module Skyline.DataMiner.QAOps.PipelineLibrary).Name
        foreach ($function in $script:PublicFunctions) {
            $exported | Should -Contain $function
        }
    }

    It 'keeps private helpers out of the exported surface' {
        $exported = (Get-Command -Module Skyline.DataMiner.QAOps.PipelineLibrary).Name
        $exported | Should -Not -Contain 'Limit-String'
    }

    It 'is a valid manifest' {
        { Test-ModuleManifest -Path $script:ModulePath } | Should -Not -Throw
    }

    It 'lists every packaged module file as a file path' {
        $expectedFiles = @(
            'Skyline.DataMiner.QAOps.PipelineLibrary.psd1'
            'Skyline.DataMiner.QAOps.PipelineLibrary.psm1'
        ) + @(
            Get-ChildItem -Path @(
                (Join-Path $script:RepoRoot 'Private')
                (Join-Path $script:RepoRoot 'Public')
                (Join-Path $script:RepoRoot 'Templates')
            ) -File -Recurse |
                ForEach-Object {
                    [System.IO.Path]::GetRelativePath($script:RepoRoot, $_.FullName).Replace('\', '/')
                }
        )

        ($script:Manifest.FileList | Sort-Object) | Should -Be ($expectedFiles | Sort-Object)
        foreach ($file in $script:Manifest.FileList) {
            (Test-Path -LiteralPath (Join-Path $script:RepoRoot $file) -PathType Leaf) | Should -BeTrue
        }
    }

    It 'supports updating the module version during publishing' {
        $stagedModule = Join-Path $TestDrive 'Skyline.DataMiner.QAOps.PipelineLibrary'
        New-Item -Path $stagedModule -ItemType Directory | Out-Null

        Copy-Item -Path @(
            $script:ModulePath
            (Join-Path $script:RepoRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psm1')
            (Join-Path $script:RepoRoot 'Private')
            (Join-Path $script:RepoRoot 'Public')
            (Join-Path $script:RepoRoot 'Templates')
        ) -Destination $stagedModule -Recurse

        $stagedManifest = Join-Path $stagedModule 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1'
        { Update-ModuleManifest -Path $stagedManifest -ModuleVersion '1.4.0' } | Should -Not -Throw
        (Test-ModuleManifest -Path $stagedManifest).Version | Should -Be ([version]'1.4.0')
    }
}

Describe 'Public function documentation' {
    It 'documents <_>' -ForEach (Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) 'Public') -Filter *.ps1 | ForEach-Object { $_.BaseName }) {
        $help = Get-Help -Name $_ -ErrorAction Stop
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Description | Should -Not -BeNullOrEmpty
    }
}

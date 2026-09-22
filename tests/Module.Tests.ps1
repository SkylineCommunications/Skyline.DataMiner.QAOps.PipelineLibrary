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
}

Describe 'Public function documentation' {
    It 'documents <_>' -ForEach (Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) 'Public') -Filter *.ps1 | ForEach-Object { $_.BaseName }) {
        $help = Get-Help -Name $_ -ErrorAction Stop
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Description | Should -Not -BeNullOrEmpty
    }
}

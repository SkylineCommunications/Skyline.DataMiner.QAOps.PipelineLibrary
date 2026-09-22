BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force
    $script:Module = Get-Module Skyline.DataMiner.QAOps.PipelineLibrary
    $script:HostExecutablePath = (Get-Process -Id $PID).Path
}

Describe 'Get-QAFrameworkDiagnosticTestAspect' {
    It 'probes the QAOps Bridge executable installation path' {
        $bridgeExecutablePath = & $script:Module {
            $script:QaOpsBridgeExecutablePath
        }

        $bridgeExecutablePath | Should -Be 'C:\Program Files\Skyline Communications\DataMiner QAOpsBridge\DataMiner QAOpsBridge.exe'
    }

    It 'uses QAOps 2.13.0 as the minimum Diagnostic-capable version' {
        $minimumVersion = & $script:Module {
            $script:MinimumQaOpsBridgeFileVersionWithDiagnosticTestAspect
        }

        $minimumVersion | Should -Be ([version]'2.13.0')
    }

    It 'parses release and prerelease Bridge file versions' -ForEach @(
        @{ FileVersion = '2.13.0'; Expected = [version]'2.13.0' },
        @{ FileVersion = '2.13.0.0'; Expected = [version]'2.13.0.0' },
        @{ FileVersion = '2.13.0-62.14.59d8905e'; Expected = [version]'2.13.0' }
    ) {
        $parsedVersion = & $script:Module {
            param($fileVersion)
            ConvertTo-QAFrameworkBridgeFileVersion -FileVersion $fileVersion
        } $FileVersion

        $parsedVersion | Should -Be $Expected
    }

    It 'uses Diagnostic for a supported prerelease product version' {
        $aspect = & $script:Module {
            Get-QAFrameworkDiagnosticTestAspectFromFileVersionInfo `
                -ProductVersion '2.13.0-62.14.abcdef' `
                -FileVersion '2.12.4.457' `
                -MinimumBridgeFileVersion ([version]'2.13.0')
        }

        $aspect | Should -Be 'Diagnostic'
    }

    It 'uses Execution for an older prerelease product version' {
        $aspect = & $script:Module {
            Get-QAFrameworkDiagnosticTestAspectFromFileVersionInfo `
                -ProductVersion '2.12.4-62.11.abc7a80b' `
                -FileVersion '2.12.4.457' `
                -MinimumBridgeFileVersion ([version]'2.13.0')
        }

        $aspect | Should -Be 'Execution'
    }

    It 'uses Execution when the Bridge executable is missing' {
        $aspect = & $script:Module {
            Get-QAFrameworkDiagnosticTestAspect -BridgeExecutablePath 'Z:\does-not-exist\DataMiner QAOpsBridge.exe' -MinimumBridgeFileVersion ([version]'2.13.0')
        }

        $aspect | Should -Be 'Execution'
    }

    It 'uses Execution when the Bridge file version is malformed' {
        $aspect = & $script:Module {
            param($moduleManifestPath)
            Get-QAFrameworkDiagnosticTestAspect -BridgeExecutablePath $moduleManifestPath -MinimumBridgeFileVersion ([version]'2.13.0')
        } $script:Module.Path

        $aspect | Should -Be 'Execution'
    }

    It 'uses Execution when the Bridge file version is old' {
        $aspect = & $script:Module {
            param($hostExecutablePath)
            Get-QAFrameworkDiagnosticTestAspect -BridgeExecutablePath $hostExecutablePath -MinimumBridgeFileVersion ([version]'9999.0')
        } $script:HostExecutablePath

        $aspect | Should -Be 'Execution'
    }

    It 'falls back to a supported file version when product version is blank' {
        $aspect = & $script:Module {
            Get-QAFrameworkDiagnosticTestAspectFromFileVersionInfo `
                -ProductVersion '' `
                -FileVersion '2.13.0.0' `
                -MinimumBridgeFileVersion ([version]'2.13.0')
        }

        $aspect | Should -Be 'Diagnostic'
    }
}

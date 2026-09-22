$script:MinimumQaOpsBridgeFileVersionWithDiagnosticTestAspect = [version]'2.13.0'
$script:QaOpsBridgeExecutablePath = 'C:\Program Files\Skyline Communications\DataMiner QAOpsBridge\DataMiner QAOpsBridge.exe'

function Get-QAFrameworkDiagnosticTestAspect {
    <#
    .SYNOPSIS
        Selects the supported QAOps aspect for scheduler diagnostic results.
    .DESCRIPTION
        Reads the installed QAOps Bridge executable file properties. Diagnostic is used only
        when its file version meets the approved compatibility threshold; otherwise Execution
        preserves compatibility with older Bridges.
    #>
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$BridgeExecutablePath = $script:QaOpsBridgeExecutablePath,

        [Parameter()]
        [version]$MinimumBridgeFileVersion = $script:MinimumQaOpsBridgeFileVersionWithDiagnosticTestAspect
    )

    if (-not (Test-Path -LiteralPath $BridgeExecutablePath -PathType Leaf)) {
        Write-Verbose "QAOps Bridge executable '$BridgeExecutablePath' was not found; using Execution."
        return 'Execution'
    }

    try {
        $fileVersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($BridgeExecutablePath)
        $testAspect = Get-QAFrameworkDiagnosticTestAspectFromFileVersionInfo `
            -ProductVersion $fileVersionInfo.ProductVersion `
            -FileVersion $fileVersionInfo.FileVersion `
            -MinimumBridgeFileVersion $MinimumBridgeFileVersion
    }
    catch {
        Write-Verbose "Could not read a valid QAOps Bridge file version from '$BridgeExecutablePath'; using Execution."
        return 'Execution'
    }

    return $testAspect
}

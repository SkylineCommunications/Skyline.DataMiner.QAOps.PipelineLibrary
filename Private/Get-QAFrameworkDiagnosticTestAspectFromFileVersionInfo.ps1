function Get-QAFrameworkDiagnosticTestAspectFromFileVersionInfo {
    <#
    .SYNOPSIS
        Selects a diagnostic result aspect from QAOps Bridge version properties.
    #>
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$ProductVersion,

        [Parameter()]
        [AllowEmptyString()]
        [string]$FileVersion,

        [Parameter(Mandatory = $true)]
        [version]$MinimumBridgeFileVersion
    )

    $versionText = if ([string]::IsNullOrWhiteSpace($ProductVersion)) { $FileVersion } else { $ProductVersion }
    $bridgeVersion = ConvertTo-QAFrameworkBridgeFileVersion -FileVersion $versionText
    if ($null -eq $bridgeVersion) {
        return 'Execution'
    }

    if ($bridgeVersion -ge $MinimumBridgeFileVersion) {
        return 'Diagnostic'
    }

    return 'Execution'
}

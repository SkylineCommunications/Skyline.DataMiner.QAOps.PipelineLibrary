function ConvertTo-QAFrameworkBridgeFileVersion {
    <#
    .SYNOPSIS
        Converts a QAOps Bridge file-version value to a System.Version.
    #>
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$FileVersion
    )

    if ($FileVersion -notmatch '^\s*(\d+(?:\.\d+){1,3})(?:[-+].*)?\s*$') {
        return $null
    }

    try {
        return [version]::new($Matches[1])
    }
    catch {
        return $null
    }
}

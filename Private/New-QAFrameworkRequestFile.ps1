function New-QAFrameworkRequestFile {
    <# Inferred helper: writes a short-lived request file only when overrides exist; request-file precedence is owned by O. #>
    [CmdletBinding()]
    param([Parameter()][hashtable]$Overrides,[Parameter()][string]$Directory)
    if ($null -eq $Overrides -or $Overrides.Count -eq 0) { return $null }
    $targetDir = if ([string]::IsNullOrWhiteSpace($Directory)) { [System.IO.Path]::GetTempPath() } else { $Directory }
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) { New-Item -Path $targetDir -ItemType Directory -Force | Out-Null }
    $name = 'qaops-qaframework-request-{0}.json' -f ([guid]::NewGuid().ToString('N'))
    $path = Join-Path $targetDir $name
    $json = $Overrides | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    return $path
}

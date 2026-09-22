function Copy-QAFrameworkDependency {
    <#
    .SYNOPSIS
        Copies a dependency folder into the generated dependencies of a test package.
    .DESCRIPTION
        Cross-platform replacement for the robocopy calls in the legacy TestDiscovery.ps1.
        Nothing is copied when the source does not exist or contains no files, which
        matches the legacy behaviour of skipping empty dependency folders.
    .PARAMETER Path
        The dependency folder to copy.
    .PARAMETER Destination
        The folder to copy into. Created when it does not exist.
    .OUTPUTS
        PSCustomObject with Copied, FileCount, Path and Destination.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $result = [pscustomobject]@{
        Copied      = $false
        FileCount   = 0
        Path        = $Path
        Destination = $Destination
    }

    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)
    $result.FileCount = $files.Count
    if ($files.Count -eq 0) { return $result }

    if (-not (Test-Path -LiteralPath $Destination)) {
        $null = New-Item -ItemType Directory -Path $Destination -Force
    }

    # Copy file by file so the relative folder structure is kept on every platform.
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $target = Join-Path $Destination $relative
        $targetFolder = Split-Path -Parent $target
        if ($targetFolder -and -not (Test-Path -LiteralPath $targetFolder)) {
            $null = New-Item -ItemType Directory -Path $targetFolder -Force
        }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force -ErrorAction Stop
    }

    $result.Copied = $true
    return $result
}

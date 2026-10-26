function Resolve-QAFrameworkPackageFilePath {
    <# Inferred helper: resolves explicit package file paths either absolute or relative to TestPackageContent, rejecting missing files before arguments reach the dotnet tool. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$ContentPath,[Parameter(Mandatory=$true)][string]$Description)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Description cannot be empty." }
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $ContentPath $Path }
    $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction Stop
    if ($resolved.Provider.Name -ne 'FileSystem' -or -not (Test-Path -LiteralPath $resolved.ProviderPath -PathType Leaf)) { throw "$Description must be an existing file: $Path" }
    return $resolved.ProviderPath
}

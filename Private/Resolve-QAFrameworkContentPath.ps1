function Resolve-QAFrameworkContentPath {
    <# Inferred helper: accepts either TestPackageContent or TestHarvesting and returns canonical content, harvest, and pipeline paths used by the tool-backed public shims. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path cannot be empty.' }
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if ($resolved.Provider.Name -ne 'FileSystem' -or -not (Test-Path -LiteralPath $resolved.ProviderPath -PathType Container)) { throw "Path must be an existing directory: $Path" }
    $candidate = $resolved.ProviderPath
    if ((Split-Path -Leaf $candidate) -ieq 'TestHarvesting') { $content = Split-Path -Parent $candidate } else { $content = $candidate }
    $harvest = Join-Path $content 'TestHarvesting'
    $pipeline = Join-Path $content 'TestPackagePipeline'
    if (-not (Test-Path -LiteralPath $harvest -PathType Container)) { throw "TestHarvesting directory not found under: $content" }
    if (-not (Test-Path -LiteralPath $pipeline -PathType Container)) { throw "TestPackagePipeline directory not found under: $content" }
    [pscustomobject]@{ ContentPath = (Resolve-Path -LiteralPath $content).ProviderPath; HarvestPath = (Resolve-Path -LiteralPath $harvest).ProviderPath; PipelinePath = (Resolve-Path -LiteralPath $pipeline).ProviderPath }
}

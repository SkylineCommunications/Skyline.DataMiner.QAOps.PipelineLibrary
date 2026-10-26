function Get-QAFrameworkPackageConfigInfo {
    <# Inferred helper: finds the package-level qaframework.config.json used to decide whether legacy PipelineLibrary defaults must be forced. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ContentPath)
    $candidates = @(
        (Join-Path (Join-Path $ContentPath 'TestPackagePipeline') 'qaframework.config.json'),
        (Join-Path $ContentPath 'qaframework.config.json'),
        (Join-Path (Join-Path $ContentPath 'TestPackagePipeline') 'TestPackageCreator.config.json'),
        (Join-Path (Join-Path (Join-Path $ContentPath 'TestHarvesting') 'dependencies.generated') 'TestPackageCreator.config.json'),
        (Join-Path (Join-Path $ContentPath 'TestHarvesting') 'TestPackageCreator.config.json'),
        (Join-Path (Join-Path (Join-Path $ContentPath 'TestHarvesting') 'dependencies.generated') 'qaframework.config.json'),
        (Join-Path (Join-Path $ContentPath 'TestHarvesting') 'qaframework.config.json')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $policy = $null
            try {
                $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($doc -and $doc.PSObject.Properties.Name -contains 'selectionPolicy') { $policy = [string]$doc.selectionPolicy }
            } catch { Write-Warning "Could not read QAFramework config '$path': $($_.Exception.Message)" }
            return [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $path).ProviderPath; Policy = $policy }
        }
    }
    return $null
}

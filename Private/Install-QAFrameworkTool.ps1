function Install-QAFrameworkTool {
    <# Inferred helper: installs or updates the O dotnet tool in a local manifest. If the package supplies a NuGet.config, use it; otherwise let dotnet use the machine's configured sources so private/company feeds are never hidden by an auto-created nuget.org-only file. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PipelineDirectory,[Parameter()][int]$TimeoutSeconds = 600)
    if (-not (Test-Path -LiteralPath $PipelineDirectory -PathType Container)) { throw "The pipeline directory '$PipelineDirectory' does not exist." }
    $PipelineDirectory = (Resolve-Path -LiteralPath $PipelineDirectory).ProviderPath
    $configDir = Join-Path $PipelineDirectory '.config'
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) { New-Item -Path $configDir -ItemType Directory -Force | Out-Null }
    $manifestPath = Join-Path $configDir 'dotnet-tools.json'
    $nugetConfigPath = Join-Path $PipelineDirectory 'NuGet.config'
    $configArguments = @()
    if (Test-Path -LiteralPath $nugetConfigPath -PathType Leaf) { $configArguments = @('--configfile', $nugetConfigPath) }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $r = Invoke-QAFrameworkDotNet -Arguments @('new','tool-manifest','--force') -WorkingDirectory $PipelineDirectory -TimeoutSeconds $TimeoutSeconds
        if ($r.ExitCode -ne 0) { throw "Failed to create the local dotnet tool manifest (exit code $($r.ExitCode)): $(Limit-String $r.StdErr 2000)" }
    }
    $packageId = 'Skyline.DataMiner.QAOps.QAFrameworkOrchestrator'
    $toolIsInstalled = $false
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $toolIsInstalled = $null -ne ($manifest.tools.PSObject.Properties | Where-Object { $_.Name -ieq $packageId } | Select-Object -First 1)
    } catch { $toolIsInstalled = $false }
    $op = if ($toolIsInstalled) { 'update' } else { 'install' }
    $r = Invoke-QAFrameworkDotNet -Arguments (@('tool',$op,$packageId,'--tool-manifest',$manifestPath) + $configArguments) -WorkingDirectory $PipelineDirectory -TimeoutSeconds $TimeoutSeconds
    if ($r.ExitCode -ne 0) { throw "Failed to $op the QAFramework orchestrator (exit code $($r.ExitCode)): $(Limit-String $r.StdErr 2000)" }
    $r = Invoke-QAFrameworkDotNet -Arguments (@('tool','restore','--tool-manifest',$manifestPath) + $configArguments) -WorkingDirectory $PipelineDirectory -TimeoutSeconds $TimeoutSeconds
    if ($r.ExitCode -ne 0) { throw "Failed to restore package-local dotnet tools (exit code $($r.ExitCode)): $(Limit-String $r.StdErr 2000)" }
    [pscustomobject]@{ PipelineDirectory=$PipelineDirectory; ManifestPath=$manifestPath; NuGetConfigPath= if ($configArguments.Count -gt 0) { $nugetConfigPath } else { $null } }
}

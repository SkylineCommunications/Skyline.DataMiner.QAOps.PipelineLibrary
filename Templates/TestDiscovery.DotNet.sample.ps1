$ErrorActionPreference = 'Stop'

Import-Module Skyline.DataMiner.QAOps.PipelineLibrary -ErrorAction Stop

$contentPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Call this after test binaries have been copied to TestHarvesting\tests.generated.
# The wrapper degrades to a skipped report when the optional harvester/tool is unavailable.
$report = Invoke-DotNetTestHarvesting -TestPackageContentPath $contentPath -GitHubLookup Auto

if ($report.status -eq 'skipped') {
    Write-Warning "Maintainer harvesting skipped: $($report.diagnostics[0].code)"
}
else {
    Write-Host "Maintainer harvesting $($report.status): $($report.counts.tests) test invocation(s)." -ForegroundColor Cyan
}

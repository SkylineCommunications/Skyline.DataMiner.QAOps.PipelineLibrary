<#
Regenerates the TRX fixture matrix from the tiny projects in tests\fixtures\trx\projects.
Run manually from the repository root when package versions or TRX shapes need refreshing.
Network access to NuGet is required. Build artifacts are written outside the repository by default.
#>
param([string]$ArtifactsPath = 'D:\qg-artifacts\c9-p\trx-fixtures')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$out = Join-Path $repo 'tests\fixtures\trx'
$projects = Join-Path $out 'projects'
New-Item -Path $ArtifactsPath -ItemType Directory -Force | Out-Null
$matrix = @(
    @{ Name='mstest3'; Project='MSTestV3\MSTestV3.csproj'; VSTest='mstest3-vstest.trx'; MTP='mstest3-mtp.trx' },
    @{ Name='nunit4'; Project='NUnit4\NUnit4.csproj'; VSTest='nunit4-vstest.trx'; MTP=$null },
    @{ Name='xunit2'; Project='XUnit2\XUnit2.csproj'; VSTest='xunit2-vstest.trx'; MTP=$null },
    @{ Name='xunit3'; Project='XUnit3\XUnit3.csproj'; VSTest='xunit3-vstest.trx'; MTP=$null }
)
foreach ($item in $matrix) {
    $project = Join-Path $projects $item.Project
    $resultDir = Join-Path $ArtifactsPath $item.Name
    New-Item -Path $resultDir -ItemType Directory -Force | Out-Null
    dotnet test $project --logger "trx;LogFileName=$($item.VSTest)" --results-directory $resultDir --artifacts-path (Join-Path $ArtifactsPath 'artifacts') | Out-Host
    $trx = Get-ChildItem -Path $resultDir -Filter $item.VSTest -Recurse | Select-Object -First 1
    if ($trx) { Copy-Item -LiteralPath $trx.FullName -Destination (Join-Path $out $item.VSTest) -Force }
    if ($item.MTP) {
        $dll = Get-ChildItem -Path (Join-Path $ArtifactsPath 'artifacts') -Filter '*.dll' -Recurse | Where-Object { $_.Name -like '*MSTestV3*' } | Select-Object -First 1
        if ($dll) {
            dotnet test --test-modules $dll.FullName --report-trx --report-trx-filename $item.MTP | Out-Host
            $mtp = Get-ChildItem -Path (Split-Path -Parent $dll.FullName) -Filter $item.MTP -Recurse | Select-Object -First 1
            if ($mtp) { Copy-Item -LiteralPath $mtp.FullName -Destination (Join-Path $out $item.MTP) -Force }
        }
    }
}
foreach ($file in Get-ChildItem -Path $out -Filter '*.trx') {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    $content = $content -replace [regex]::Escape($env:USERNAME), 'SCRUBBED'
    $content = $content -replace [regex]::Escape($env:COMPUTERNAME), 'SCRUBBED'
    $content = $content -replace '[A-Za-z]:\\[^"<]+', 'SCRUBBED'
    Set-Content -LiteralPath $file.FullName -Value $content -Encoding UTF8
}

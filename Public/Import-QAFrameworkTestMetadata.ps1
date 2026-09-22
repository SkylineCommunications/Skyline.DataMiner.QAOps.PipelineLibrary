function Import-QAFrameworkTestMetadata {
    <#
    .SYNOPSIS
        Loads QAFramework test metadata produced during harvesting.
    .DESCRIPTION
        Reads qaframework.tests.json (schema v1) and normalises every record to the
        schema v1 shape. When that file is absent the older testmetadata.generated.json
        files produced by the PlatformSmokeTests harvester and by TestPackageCreator are
        accepted as well, so packages harvested by previous tooling keep running with the
        legacy defaults (weight 1, concurrent, TargetDMA One).

        Unless -IncludeDisabled is used, tests carrying a non-blank Disabled reason are
        still returned: the runtime reports them as NotExecuted with that reason. Use
        -ExcludeDisabled to drop them entirely.
    .PARAMETER TestPackageContentPath
        Root of the test package content. The standard locations underneath it are probed
        in order.
    .PARAMETER MetadataPath
        Explicit path to a metadata file, bypassing the probing logic.
    .PARAMETER ExcludeDisabled
        Drops tests that carry a disable reason instead of returning them.
    .EXAMPLE
        Import-QAFrameworkTestMetadata -TestPackageContentPath 'C:\QAOps\Content'
    .OUTPUTS
        PSCustomObject per test, following schema v1.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Content')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Content')]
        [string]$TestPackageContentPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$MetadataPath,

        [switch]$ExcludeDisabled
    )

    if ($PSCmdlet.ParameterSetName -eq 'Content') {
        $candidates = @(
            (Join-Path $TestPackageContentPath 'TestHarvesting\dependencies.generated\qaframework.tests.json')
            (Join-Path $TestPackageContentPath 'TestHarvesting\qaframework.tests.json')
            (Join-Path $TestPackageContentPath 'qaframework.tests.json')
            (Join-Path $TestPackageContentPath 'TestHarvesting\dependencies.generated\testmetadata.generated.json')
            (Join-Path $TestPackageContentPath 'TestHarvesting\testmetadata.generated.json')
            (Join-Path $TestPackageContentPath 'testmetadata.generated.json')
        )

        $MetadataPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        if (-not $MetadataPath) {
            throw "No QAFramework test metadata found under '$TestPackageContentPath'. Looked for: $($candidates -join '; ')."
        }
    }

    if (-not (Test-Path -LiteralPath $MetadataPath)) {
        throw "QAFramework test metadata file '$MetadataPath' does not exist."
    }

    Write-Verbose "Importing QAFramework test metadata from '$MetadataPath'."

    $raw = Get-Content -LiteralPath $MetadataPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    try {
        $document = $raw | ConvertFrom-Json
    }
    catch {
        throw "QAFramework test metadata file '$MetadataPath' is not valid JSON: $($_.Exception.Message)"
    }

    # Schema v1 wraps the records in a document; the legacy files are a bare array.
    $records = if ($document -is [array]) {
        $document
    }
    elseif ($document.PSObject.Properties.Name -contains 'tests') {
        $document.tests
    }
    else {
        @($document)
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($record in $records) {
        $test = ConvertTo-QAFrameworkTestMetadata -InputObject $record
        if ($null -eq $test) { continue }

        if (-not $seen.Add($test.name)) {
            Write-Warning "Duplicate QAFramework test '$($test.name)' in '$MetadataPath'; keeping the first occurrence."
            continue
        }

        if ($ExcludeDisabled -and $null -ne $test.disabled) { continue }

        $test
    }
}

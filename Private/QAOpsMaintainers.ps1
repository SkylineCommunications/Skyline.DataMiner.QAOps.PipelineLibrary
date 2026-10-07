function New-QAOpsTestInvocationId {
    <# Builds the canonical runtime sidecar key: assembly|fullyQualifiedName|data:<case>|target:<target>. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Assembly,[Parameter(Mandatory=$true)][string]$FullyQualifiedName,[Parameter()][AllowNull()][string]$DataCaseId,[Parameter()][AllowNull()][string]$Target)
    $case = if ($null -eq $DataCaseId) { '' } else { [string]$DataCaseId }
    $t = if ([string]::IsNullOrWhiteSpace($Target)) { 'default' } else { [string]$Target }
    return ('{0}|{1}|data:{2}|target:{3}' -f $Assembly,$FullyQualifiedName,$case,$t)
}

function New-QAOpsOrdinalDictionary {
    New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
}

function New-QAOpsSidecarImportResult {
    param([string]$Path,[string]$Code,[string]$Message,[switch]$Warn)
    if ($Warn -and $Message) { Write-Warning $Message }
    $diag = @()
    if ($Code) { $diag = @([pscustomobject]@{ code = $Code; message = $Message }) }
    [pscustomobject]@{ Entries = (New-QAOpsOrdinalDictionary); Diagnostics = $diag; Path = $Path }
}

function Test-QAOpsMaintainerEnvelope {
    <# Conservative non-throwing local validation of the v1 maintainer envelope before passing it to Q. #>
    [CmdletBinding()]
    param([Parameter()][object]$Maintainers)
    try {
        if ($null -eq $Maintainers -or -not ($Maintainers -is [psobject])) { return [pscustomobject]@{ Valid = $false; Code = 'missing'; Json = $null } }
        $props = @($Maintainers.PSObject.Properties.Name)
        if ($props -contains 'serializedUtf8Bytes') {
            $bytes = 0
            if (-not [int]::TryParse([string]$Maintainers.serializedUtf8Bytes, [ref]$bytes) -or $bytes -gt 8192) { return [pscustomobject]@{ Valid = $false; Code = 'maintainersOversized'; Json = $null } }
        }
        $version = 0
        if (($props -notcontains 'version') -or -not [int]::TryParse([string]$Maintainers.version, [ref]$version) -or $version -ne 1) { return [pscustomobject]@{ Valid = $false; Code = 'invalidVersion'; Json = $null } }
        if ($props -notcontains 'references') { return [pscustomobject]@{ Valid = $false; Code = 'invalidReference'; Json = $null } }
        $refs = @($Maintainers.references)
        if ($refs.Count -gt 20) { return [pscustomobject]@{ Valid = $false; Code = 'tooManyReferences'; Json = $null } }
        foreach ($ref in $refs) {
            if ($null -eq $ref -or @('user','team','emailContact') -notcontains [string]$ref.kind) { return [pscustomobject]@{ Valid = $false; Code = 'invalidReference'; Json = $null } }
        }
        $json = $Maintainers | ConvertTo-Json -Depth 20 -Compress
        if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt 8192) { return [pscustomobject]@{ Valid = $false; Code = 'maintainersOversized'; Json = $null } }
        [pscustomobject]@{ Valid = $true; Code = $null; Json = $json }
    }
    catch { [pscustomobject]@{ Valid = $false; Code = 'invalidReference'; Json = $null } }
}

function Import-QAOpsMaintainerSidecar {
    <# Loads the runtime sidecar once; invalid/unsupported sidecars produce no maintainers and one bounded diagnostic. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ContentPath)
    $path = Join-Path (Join-Path (Join-Path $ContentPath 'TestHarvesting') 'dependencies.generated') 'qaops.maintainers.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Information "Maintainer sidecar not found: $path"; return (New-QAOpsSidecarImportResult -Path $path) }
    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.Length -gt 10485760) { return (New-QAOpsSidecarImportResult -Path $path -Code 'sidecar-oversized' -Message "Maintainer sidecar is oversized and will be ignored: $path" -Warn) }
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $doc -or @($doc.PSObject.Properties.Name) -notcontains 'schema' -or [string]$doc.schema -ne 'https://schema.skyline.be/qaops/maintainers/v1') { return (New-QAOpsSidecarImportResult -Path $path -Code 'sidecar-unsupported' -Message 'Maintainer sidecar schema is unsupported and will be ignored.' -Warn) }
        $version = 0
        if (@($doc.PSObject.Properties.Name) -notcontains 'version' -or -not [int]::TryParse([string]$doc.version, [ref]$version) -or $version -ne 1) { return (New-QAOpsSidecarImportResult -Path $path -Code 'sidecar-unsupported' -Message 'Maintainer sidecar version is unsupported and will be ignored.' -Warn) }
        $map = New-QAOpsOrdinalDictionary
        foreach ($entry in @($doc.testInvocations)) {
            try {
                if ($null -eq $entry) { continue }
                $entryProps = @($entry.PSObject.Properties.Name)
                $key = $null
                if ($entryProps -contains 'testInvocationId') { $key = [string]$entry.testInvocationId }
                elseif (($entryProps -contains 'assembly') -and ($entryProps -contains 'fullyQualifiedName')) { $key = New-QAOpsTestInvocationId -Assembly ([string]$entry.assembly) -FullyQualifiedName ([string]$entry.fullyQualifiedName) -DataCaseId ([string]$entry.dataCaseId) -Target ([string]$entry.target) }
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                if (-not $map.ContainsKey($key)) { $map.Add($key, (New-Object System.Collections.ArrayList)) }
                [void]$map[$key].Add($entry)
            } catch { continue }
        }
        [pscustomobject]@{ Entries=$map; Diagnostics=@(); Path=$path }
    }
    catch { New-QAOpsSidecarImportResult -Path $path -Code 'sidecar-invalid' -Message ("Maintainer sidecar is invalid and will be ignored: {0}" -f $_.Exception.Message) -Warn }
}

function Resolve-QAOpsRuntimeMaintainers {
    <# Implements §9.2 lookup order without display-name fallback; conflicts at the same specificity return no maintainers plus a diagnostic. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$Entries,[Parameter(Mandatory=$true)][string]$Assembly,[Parameter(Mandatory=$true)][string]$FullyQualifiedName,[Parameter()][string]$DataCaseId,[Parameter()][string]$Target)
    $testInvocationId = New-QAOpsTestInvocationId -Assembly $Assembly -FullyQualifiedName $FullyQualifiedName -DataCaseId $DataCaseId -Target $Target
    $keys = @(
        $testInvocationId,
        (New-QAOpsTestInvocationId -Assembly $Assembly -FullyQualifiedName $FullyQualifiedName -DataCaseId $DataCaseId -Target 'default'),
        (New-QAOpsTestInvocationId -Assembly $Assembly -FullyQualifiedName $FullyQualifiedName -DataCaseId '' -Target $Target),
        (New-QAOpsTestInvocationId -Assembly $Assembly -FullyQualifiedName $FullyQualifiedName -DataCaseId '' -Target 'default')
    )
    foreach ($key in $keys) {
        if ($Entries.ContainsKey($key)) {
            $matches = @($Entries[$key])
            if ($matches.Count -gt 1) { return [pscustomobject]@{ TestInvocationId=$testInvocationId; MatchedKey=$null; Maintainers=$null; Diagnostics=@([pscustomobject]@{ code='maintainer-conflict'; key=$key }) } }
            return [pscustomobject]@{ TestInvocationId=$testInvocationId; MatchedKey=$key; Maintainers=$matches[0].maintainers; Diagnostics=@() }
        }
    }
    [pscustomobject]@{ TestInvocationId=$testInvocationId; MatchedKey=$null; Maintainers=$null; Diagnostics=@([pscustomobject]@{ code='maintainers-not-found' }) }
}

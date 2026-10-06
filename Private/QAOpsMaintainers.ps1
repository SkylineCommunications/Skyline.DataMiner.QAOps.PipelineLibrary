function New-QAOpsTestInvocationId {
    <# Builds the canonical runtime sidecar key: assembly|fullyQualifiedName|data:<case>|target:<target>. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Assembly,[Parameter(Mandatory=$true)][string]$FullyQualifiedName,[Parameter()][AllowNull()][string]$DataCaseId,[Parameter()][AllowNull()][string]$Target)
    $case = if ($null -eq $DataCaseId) { '' } else { [string]$DataCaseId }
    $t = if ([string]::IsNullOrWhiteSpace($Target)) { 'default' } else { [string]$Target }
    return ('{0}|{1}|data:{2}|target:{3}' -f $Assembly,$FullyQualifiedName,$case,$t)
}

function Test-QAOpsMaintainerEnvelope {
    <# Conservative local validation of the v1 maintainer envelope before passing it to Q. Invalid metadata is dropped, never allowed to suppress a result. #>
    [CmdletBinding()]
    param([Parameter()][object]$Maintainers)
    if ($null -eq $Maintainers) { return [pscustomobject]@{ Valid = $false; Code = 'missing'; Json = $null } }
    if ($Maintainers.PSObject.Properties.Name -contains 'serializedUtf8Bytes' -and [int]$Maintainers.serializedUtf8Bytes -gt 8192) { return [pscustomobject]@{ Valid = $false; Code = 'maintainersOversized'; Json = $null } }
    if ([int]$Maintainers.version -ne 1) { return [pscustomobject]@{ Valid = $false; Code = 'invalidVersion'; Json = $null } }
    $refs = @($Maintainers.references)
    if ($refs.Count -gt 20) { return [pscustomobject]@{ Valid = $false; Code = 'tooManyReferences'; Json = $null } }
    foreach ($ref in $refs) {
        if (@('user','team','emailContact') -notcontains [string]$ref.kind) { return [pscustomobject]@{ Valid = $false; Code = 'invalidReference'; Json = $null } }
    }
    $json = $Maintainers | ConvertTo-Json -Depth 20 -Compress
    if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt 8192) { return [pscustomobject]@{ Valid = $false; Code = 'maintainersOversized'; Json = $null } }
    [pscustomobject]@{ Valid = $true; Code = $null; Json = $json }
}

function Import-QAOpsMaintainerSidecar {
    <# Loads the runtime sidecar once; missing is information, malformed or oversized is warning, and all cases continue without maintainers. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ContentPath)
    $path = Join-Path (Join-Path (Join-Path $ContentPath 'TestHarvesting') 'dependencies.generated') 'qaops.maintainers.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Information "Maintainer sidecar not found: $path"; return [pscustomobject]@{ Entries = @{}; Diagnostics = @(); Path = $path } }
    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.Length -gt 10485760) { Write-Warning "Maintainer sidecar is oversized and will be ignored: $path"; return [pscustomobject]@{ Entries = @{}; Diagnostics = @([pscustomobject]@{ code='sidecar-oversized'; message='Sidecar ignored.'}); Path=$path } }
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { Write-Warning "Maintainer sidecar is invalid and will be ignored: $($_.Exception.Message)"; return [pscustomobject]@{ Entries=@{}; Diagnostics=@([pscustomobject]@{ code='sidecar-invalid'; message='Sidecar ignored.'}); Path=$path } }
    $map = @{}
    foreach ($entry in @($doc.testInvocations)) {
        $key = if ($entry.PSObject.Properties.Name -contains 'testInvocationId') { [string]$entry.testInvocationId } else { New-QAOpsTestInvocationId -Assembly ([string]$entry.assembly) -FullyQualifiedName ([string]$entry.fullyQualifiedName) -DataCaseId ([string]$entry.dataCaseId) -Target ([string]$entry.target) }
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if (-not $map.ContainsKey($key)) { $map[$key] = New-Object System.Collections.ArrayList }
        [void]$map[$key].Add($entry)
    }
    [pscustomobject]@{ Entries=$map; Diagnostics=@(); Path=$path }
}

function Resolve-QAOpsRuntimeMaintainers {
    <# Implements §9.2 lookup order without display-name fallback; conflicts at the same specificity return no maintainers plus a diagnostic. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][hashtable]$Entries,[Parameter(Mandatory=$true)][string]$Assembly,[Parameter(Mandatory=$true)][string]$FullyQualifiedName,[Parameter()][string]$DataCaseId,[Parameter()][string]$Target)
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



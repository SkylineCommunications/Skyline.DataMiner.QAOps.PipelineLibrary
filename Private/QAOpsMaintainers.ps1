function ConvertTo-QAOpsKeyComponent {
    <# Percent-encodes the v1 canonical-key variable component characters that can collide with grammar tokens. #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]
        $code = [int][char]$ch
        if ([char]::IsHighSurrogate($ch)) {
            if (($i + 1) -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$i + 1])) { throw "Canonical key component contains a lone surrogate." }
            [void]$builder.Append($ch)
            $i++
            [void]$builder.Append($Value[$i])
            continue
        }
        if ([char]::IsLowSurrogate($ch)) { throw "Canonical key component contains a lone surrogate." }
        if ($ch -eq '%' -or $ch -eq '|' -or [char]::IsControl($ch)) {
            foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes([string]$ch)) { [void]$builder.Append(('%{0:X2}' -f $byte)) }
        } else {
            [void]$builder.Append($ch)
        }
    }
    return $builder.ToString()
}

function Get-QAOpsScalarCount {
    param([Parameter()][AllowNull()][string]$Value)
    if ($null -eq $Value) { return 0 }
    $count = 0
    for ($i = 0; $i -lt $Value.Length; $i++) {
        if ([char]::IsHighSurrogate($Value[$i]) -and ($i + 1) -lt $Value.Length -and [char]::IsLowSurrogate($Value[$i + 1])) { $i++ }
        $count++
    }
    return $count
}

function Get-QAOpsScalarPrefix {
    param([Parameter()][AllowNull()][string]$Value,[Parameter(Mandatory=$true)][int]$MaxScalars)
    if ($null -eq $Value -or $MaxScalars -le 0) { return '' }
    $count = 0
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $next = $i + 1
        if ([char]::IsHighSurrogate($Value[$i]) -and $next -lt $Value.Length -and [char]::IsLowSurrogate($Value[$next])) { $i++ }
        $count++
        if ($count -ge $MaxScalars) { return $Value.Substring(0, $i + 1) }
    }
    return $Value
}

function ConvertTo-QAOpsBase64Url {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_'))
}

function New-QAOpsTestInvocationIdentity {
    <# Builds the canonical runtime sidecar key using producer-transport-v1 §9.2 percent-encoding and shortening. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Assembly,[Parameter(Mandatory=$true)][string]$FullyQualifiedName,[Parameter()][AllowNull()][string]$DataCaseId,[Parameter()][AllowNull()][string]$Target)
    try {
        $namespace = ConvertTo-QAOpsKeyComponent -Value $Assembly
        $identity = ConvertTo-QAOpsKeyComponent -Value $FullyQualifiedName
        $case = ConvertTo-QAOpsKeyComponent -Value $(if ($null -eq $DataCaseId) { '' } else { [string]$DataCaseId })
        $t = ConvertTo-QAOpsKeyComponent -Value $(if ([string]::IsNullOrWhiteSpace($Target)) { 'default' } else { [string]$Target })
    }
    catch { return [pscustomobject]@{ TestInvocationId=$null; Diagnostics=@([pscustomobject]@{ code='identity-invalid' }) } }
    $full = ('{0}|{1}|data:{2}|target:{3}' -f $namespace,$identity,$case,$t)
    $diagnostics = @()
    if ((Get-QAOpsScalarCount -Value $full) -gt 1024) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($full)) }
        finally { $sha.Dispose() }
        $hashText = ConvertTo-QAOpsBase64Url -Bytes $hash
        $fixedLength = (Get-QAOpsScalarCount -Value ($namespace + '||hash:' + $hashText + '|target:' + $t))
        if ($fixedLength -gt 1024) { return [pscustomobject]@{ TestInvocationId=$null; Diagnostics=@([pscustomobject]@{ code='identity-invalid' }) } }
        $prefixBudget = [Math]::Max(0, [Math]::Min(128, 1024 - $fixedLength))
        $identity = Get-QAOpsScalarPrefix -Value $identity -MaxScalars $prefixBudget
        $full = ('{0}|{1}|hash:{2}|target:{3}' -f $namespace,$identity,$hashText,$t)
        $diagnostics = @([pscustomobject]@{ code='identity-shortened' })
    }
    [pscustomobject]@{ TestInvocationId=$full; Diagnostics=$diagnostics }
}

function New-QAOpsTestInvocationId {
    <# Back-compat string helper for the canonical runtime sidecar key. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Assembly,[Parameter(Mandatory=$true)][string]$FullyQualifiedName,[Parameter()][AllowNull()][string]$DataCaseId,[Parameter()][AllowNull()][string]$Target)
    return (New-QAOpsTestInvocationIdentity -Assembly $Assembly -FullyQualifiedName $FullyQualifiedName -DataCaseId $DataCaseId -Target $Target).TestInvocationId
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
    $identity = New-QAOpsTestInvocationIdentity -Assembly $Assembly -FullyQualifiedName $FullyQualifiedName -DataCaseId $DataCaseId -Target $Target
    $testInvocationId = $identity.TestInvocationId
    if ([string]::IsNullOrEmpty($testInvocationId)) { return [pscustomobject]@{ TestInvocationId=$null; MatchedKey=$null; Maintainers=$null; Diagnostics=@($identity.Diagnostics) } }
    $keys = @(
        $testInvocationId,
        (New-QAOpsTestInvocationId -Assembly $Assembly -FullyQualifiedName $FullyQualifiedName -DataCaseId $DataCaseId -Target 'default'),
        (New-QAOpsTestInvocationId -Assembly $Assembly -FullyQualifiedName $FullyQualifiedName -DataCaseId '' -Target $Target),
        (New-QAOpsTestInvocationId -Assembly $Assembly -FullyQualifiedName $FullyQualifiedName -DataCaseId '' -Target 'default')
    )
    foreach ($key in $keys) {
        if ($Entries.ContainsKey($key)) {
            $matches = @($Entries[$key])
            if ($matches.Count -gt 1) { return [pscustomobject]@{ TestInvocationId=$testInvocationId; MatchedKey=$null; Maintainers=$null; Diagnostics=(@($identity.Diagnostics) + @([pscustomobject]@{ code='maintainer-conflict'; key=$key })) } }
            return [pscustomobject]@{ TestInvocationId=$testInvocationId; MatchedKey=$key; Maintainers=$matches[0].maintainers; Diagnostics=@($identity.Diagnostics) }
        }
    }
    [pscustomobject]@{ TestInvocationId=$testInvocationId; MatchedKey=$null; Maintainers=$null; Diagnostics=(@($identity.Diagnostics) + @([pscustomobject]@{ code='maintainers-not-found' })) }
}

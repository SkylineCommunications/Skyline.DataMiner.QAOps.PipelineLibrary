function Resolve-QAFrameworkFilterList {
    <#
    .SYNOPSIS
        Splits a QAFramework keyword or squad filter into an include and an exclude list.
    .DESCRIPTION
        The legacy runner accepts a single list where an entry prefixed with '!' means
        "exclude" instead of "include". This helper normalises such a list into two clean
        lists and merges it with an explicit exclude list.
    .PARAMETER Include
        The include list, which may contain '!' prefixed exclusions.
    .PARAMETER Exclude
        An additional exclude list without prefixes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Include,
        [AllowNull()][AllowEmptyCollection()][string[]]$Exclude
    )

    $includes = [System.Collections.Generic.List[string]]::new()
    $excludes = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($Include)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $value = $entry.Trim()
        if ($value.StartsWith('!')) {
            $value = $value.Substring(1).Trim()
            if ($value) { $excludes.Add($value) }
        }
        else {
            $includes.Add($value)
        }
    }

    foreach ($entry in @($Exclude)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $value = $entry.Trim().TrimStart('!').Trim()
        if ($value) { $excludes.Add($value) }
    }

    return [pscustomobject]@{
        Include = [string[]]$includes
        Exclude = [string[]]$excludes
    }
}

function Test-QAFrameworkListMatch {
    <#
    .SYNOPSIS
        Determines whether any value matches any filter entry, ignoring case and whitespace.
    .PARAMETER Value
        The values declared by the test, for example its keywords or squads.
    .PARAMETER Filter
        The filter entries to match against.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Value,
        [AllowNull()][AllowEmptyCollection()][string[]]$Filter
    )

    foreach ($entry in @($Filter)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        foreach ($candidate in @($Value)) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            if ([string]::Equals($candidate.Trim(), $entry.Trim(), [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }

    return $false
}

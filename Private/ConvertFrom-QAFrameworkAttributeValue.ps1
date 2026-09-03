function ConvertFrom-QAFrameworkAttributeValue {
    <#
    .SYNOPSIS
        Normalises a single C# attribute argument expression into a PowerShell value.
    .DESCRIPTION
        Handles string literals (regular and verbatim), booleans, integers, enum member
        references such as RunOn.All or DiagnosticRunType.Before, and nameof(...) expressions.
        Enum references are reduced to their member name only.
    .PARAMETER Expression
        The raw argument expression.
    .OUTPUTS
        String, Boolean or Int32 depending on the expression.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Expression
    )

    if ($null -eq $Expression) { return $null }

    $value = $Expression.Trim()
    if ($value -eq '') { return '' }

    # Verbatim string: @"..." (an escaped "" becomes a single ").
    if ($value.StartsWith('@"') -and $value.EndsWith('"') -and $value.Length -ge 3) {
        return $value.Substring(2, $value.Length - 3).Replace('""', '"')
    }

    # Regular string literal: "..."
    if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
        $inner = $value.Substring(1, $value.Length - 2)
        return [System.Text.RegularExpressions.Regex]::Unescape($inner)
    }

    # nameof(Something) -> Something
    if ($value -match '^nameof\s*\(\s*(.+?)\s*\)$') {
        return ($Matches[1] -split '\.')[-1]
    }

    if ($value -match '^(?i:true)$') { return $true }
    if ($value -match '^(?i:false)$') { return $false }

    $intValue = 0
    if ([int]::TryParse($value, [ref]$intValue)) { return $intValue }

    # Enum member reference such as RunOn.All or DiagnosticRunType.Before.
    if ($value -match '^[A-Za-z_][\w]*(\.[A-Za-z_][\w]*)+$') {
        return ($value -split '\.')[-1]
    }

    return $value
}

function ConvertTo-QAFrameworkAttributeArgumentMap {
    <#
    .SYNOPSIS
        Splits attribute arguments into positional values and named values.
    .DESCRIPTION
        C# attributes allow named property/field initialisers (Name = value) after the
        positional constructor arguments. This helper separates the two forms and
        normalises every value via ConvertFrom-QAFrameworkAttributeValue.
    .PARAMETER ArgumentText
        The raw text between the attribute's outer parentheses.
    .OUTPUTS
        Hashtable with 'Positional' (object[]) and 'Named' (hashtable, case-insensitive).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$ArgumentText
    )

    $positional = [System.Collections.Generic.List[object]]::new()
    $named = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($argument in (Split-QAFrameworkAttributeArgument -ArgumentText $ArgumentText)) {
        # Named property initialiser (Name = value) or C# named argument (name: value).
        if ($argument -match '^\s*([A-Za-z_]\w*)\s*(?:=|:)\s*(.+)$') {
            $named[$Matches[1]] = ConvertFrom-QAFrameworkAttributeValue -Expression $Matches[2]
        }
        else {
            $positional.Add((ConvertFrom-QAFrameworkAttributeValue -Expression $argument))
        }
    }

    return @{
        Positional = $positional.ToArray()
        Named      = $named
    }
}

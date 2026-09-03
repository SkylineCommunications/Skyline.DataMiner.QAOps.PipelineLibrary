function Get-QAFrameworkClassAttributeBlock {
    <#
    .SYNOPSIS
        Extracts the attribute block that decorates a C# class declaration.
    .DESCRIPTION
        Locates the class declaration and walks backwards collecting the contiguous
        attribute lines above it. Bracket balance is tracked so multi-line attributes
        (for example a MinVersion spanning several lines) are captured completely.
        Blank lines and comments between attributes are tolerated.
    .PARAMETER Path
        Path to the C# source file.
    .PARAMETER Content
        Raw file content. Use instead of -Path when the source is already in memory.
    .PARAMETER ClassName
        Optional class name to locate. When omitted the first class declaration wins.
    .OUTPUTS
        String containing the attribute block, or an empty string when none is found.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'Content')]
        [AllowEmptyString()]
        [string]$Content,

        [string]$ClassName
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $Content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    }

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }

    $lines = $Content -split '\r?\n'

    $classPattern = if ($ClassName) {
        '(^|\s)class\s+' + [regex]::Escape($ClassName) + '(\s|:|<|$)'
    }
    else {
        '(^|\s)class\s+[A-Za-z_]\w*'
    }

    $classLineIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.TrimStart().StartsWith('//')) { continue }
        if ($line -match $classPattern) {
            $classLineIndex = $i
            break
        }
    }

    if ($classLineIndex -lt 0) { return '' }

    $collected = [System.Collections.Generic.List[string]]::new()
    $balance = 0

    for ($i = $classLineIndex - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        $trimmed = $line.Trim()

        if ($balance -eq 0) {
            # Between attributes: tolerate blank lines and comments, stop at anything else.
            if ($trimmed -eq '') { continue }
            if ($trimmed.StartsWith('//') -or $trimmed.StartsWith('*') -or $trimmed.StartsWith('/*')) { continue }
            if (-not $trimmed.EndsWith(']')) { break }
        }

        $collected.Insert(0, $line)

        # Walking backwards, a ']' opens an attribute and a '[' closes it.
        foreach ($char in $line.ToCharArray()) {
            if ($char -eq ']') { $balance++ }
            elseif ($char -eq '[') { $balance-- }
        }

        # A negative balance means we started mid-attribute; treat as balanced.
        if ($balance -lt 0) { $balance = 0 }
    }

    return ($collected -join [Environment]::NewLine)
}

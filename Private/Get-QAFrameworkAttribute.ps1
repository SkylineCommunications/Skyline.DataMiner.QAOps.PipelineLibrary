function Get-QAFrameworkAttribute {
    <#
    .SYNOPSIS
        Extracts individual attributes from a C# attribute block.
    .DESCRIPTION
        Scans a block of attribute text and returns every attribute it contains. Handles
        grouped attributes ([A, B("x")]), attribute targets ([method: Foo]), multi-line
        argument lists and string literals containing brackets or commas.
    .PARAMETER Text
        The attribute block text.
    .OUTPUTS
        PSCustomObject with Name and ArgumentText properties, one per attribute.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $index = 0
    while ($index -lt $Text.Length) {
        if ($Text[$index] -ne '[') {
            $index++
            continue
        }

        # Find the matching closing bracket for this attribute group.
        $depth = 0
        $inString = $false
        $isVerbatim = $false
        $inChar = $false
        $scan = $index
        $closeIndex = -1

        while ($scan -lt $Text.Length) {
            $char = $Text[$scan]

            if ($inString) {
                if ($isVerbatim) {
                    if ($char -eq '"') {
                        if (($scan + 1) -lt $Text.Length -and $Text[$scan + 1] -eq '"') { $scan += 2; continue }
                        $inString = $false; $isVerbatim = $false
                    }
                }
                elseif ($char -eq '\') { $scan += 2; continue }
                elseif ($char -eq '"') { $inString = $false }
                $scan++
                continue
            }

            if ($inChar) {
                if ($char -eq '\') { $scan += 2; continue }
                if ($char -eq "'") { $inChar = $false }
                $scan++
                continue
            }

            switch ($char) {
                '"' {
                    $inString = $true
                    $isVerbatim = ($scan -gt 0 -and $Text[$scan - 1] -eq '@')
                }
                "'" { $inChar = $true }
                '[' { $depth++ }
                ']' { $depth-- }
            }

            if ($depth -eq 0 -and $char -eq ']') {
                $closeIndex = $scan
                break
            }

            $scan++
        }

        if ($closeIndex -lt 0) { break }

        $inner = $Text.Substring($index + 1, $closeIndex - $index - 1)

        # Strip an attribute target prefix such as "method:" or "assembly:".
        if ($inner -match '(?s)^\s*(?:assembly|module|field|event|method|param|property|return|type)\s*:\s*(.+)$') {
            $inner = $Matches[1]
        }

        foreach ($entry in (Split-QAFrameworkAttributeArgument -ArgumentText $inner)) {
            if ($entry -match '(?s)^\s*([A-Za-z_][\w\.]*)\s*\((.*)\)\s*$') {
                $name = ($Matches[1] -split '\.')[-1] -replace 'Attribute$', ''
                [pscustomobject]@{ Name = $name; ArgumentText = $Matches[2] }
            }
            elseif ($entry -match '(?s)^\s*([A-Za-z_][\w\.]*)\s*$') {
                $name = ($Matches[1] -split '\.')[-1] -replace 'Attribute$', ''
                [pscustomobject]@{ Name = $name; ArgumentText = '' }
            }
        }

        $index = $closeIndex + 1
    }
}

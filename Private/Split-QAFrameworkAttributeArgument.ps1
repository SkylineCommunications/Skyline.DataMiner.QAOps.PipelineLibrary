function Split-QAFrameworkAttributeArgument {
    <#
    .SYNOPSIS
        Splits a C# attribute argument list on top-level commas.
    .DESCRIPTION
        Respects string literals (including escaped quotes and verbatim strings) and nested
        parentheses/brackets/braces so that arguments such as
        new[] { "a", "b" } or "text, with comma" are not split incorrectly.
    .PARAMETER ArgumentText
        The raw text between the attribute's outer parentheses.
    .OUTPUTS
        String[] of trimmed argument expressions. Empty array when there are no arguments.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$ArgumentText
    )

    if ([string]::IsNullOrWhiteSpace($ArgumentText)) {
        return @()
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $depth = 0
    $inString = $false
    $inChar = $false
    $isVerbatim = $false
    $index = 0

    while ($index -lt $ArgumentText.Length) {
        $char = $ArgumentText[$index]

        if ($inString) {
            [void]$current.Append($char)

            if ($isVerbatim) {
                # In a verbatim string "" is an escaped quote.
                if ($char -eq '"') {
                    if (($index + 1) -lt $ArgumentText.Length -and $ArgumentText[$index + 1] -eq '"') {
                        [void]$current.Append($ArgumentText[$index + 1])
                        $index += 2
                        continue
                    }
                    $inString = $false
                    $isVerbatim = $false
                }
            }
            elseif ($char -eq '\') {
                # Escape sequence: consume the next character verbatim.
                if (($index + 1) -lt $ArgumentText.Length) {
                    [void]$current.Append($ArgumentText[$index + 1])
                    $index += 2
                    continue
                }
            }
            elseif ($char -eq '"') {
                $inString = $false
            }

            $index++
            continue
        }

        if ($inChar) {
            [void]$current.Append($char)
            if ($char -eq '\' -and ($index + 1) -lt $ArgumentText.Length) {
                [void]$current.Append($ArgumentText[$index + 1])
                $index += 2
                continue
            }
            if ($char -eq "'") { $inChar = $false }
            $index++
            continue
        }

        switch ($char) {
            '"' {
                $inString = $true
                # Detect the @"..." verbatim form.
                $isVerbatim = ($current.Length -gt 0 -and $current[$current.Length - 1] -eq '@')
                [void]$current.Append($char)
            }
            "'" {
                $inChar = $true
                [void]$current.Append($char)
            }
            '(' { $depth++; [void]$current.Append($char) }
            '[' { $depth++; [void]$current.Append($char) }
            '{' { $depth++; [void]$current.Append($char) }
            ')' { $depth--; [void]$current.Append($char) }
            ']' { $depth--; [void]$current.Append($char) }
            '}' { $depth--; [void]$current.Append($char) }
            ',' {
                if ($depth -eq 0) {
                    $arguments.Add($current.ToString().Trim())
                    [void]$current.Clear()
                }
                else {
                    [void]$current.Append($char)
                }
            }
            default { [void]$current.Append($char) }
        }

        $index++
    }

    if ($current.ToString().Trim() -ne '') {
        $arguments.Add($current.ToString().Trim())
    }

    return [string[]]$arguments.ToArray()
}

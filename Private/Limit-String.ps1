<#
.SYNOPSIS
    Truncates a string to a specified maximum length with an ellipsis indicator.

.DESCRIPTION
    Limits the length of a string by truncating it to the specified maximum number of characters.
    If the string exceeds the maximum length, it is cut off and "...(truncated)" is appended.
    Returns the original string unchanged if it's within the character limit or if it's null/empty.

.PARAMETER stringToLimit
    The string to be limited. Can be null or empty.

.PARAMETER maxCharacters
    The maximum number of characters allowed before truncation. Default is 2000.

.EXAMPLE
    Limit-String -stringToLimit "This is a very long string" -maxCharacters 10
    Returns: "This is a ...(truncated)"

.EXAMPLE
    Limit-String "Short string"
    Returns: "Short string" (unchanged because it's under the default 2000 character limit)

.NOTES
    - Returns the original string if it's null, empty, or within the character limit
    - Default maximum is 2000 characters
    - Truncated strings have "...(truncated)" appended
#>
function Limit-String {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$stringToLimit,
        [Parameter(Mandatory = $false)][int]$maxCharacters = 2000
    )

    if ([string]::IsNullOrEmpty($stringToLimit)) { return $stringToLimit }
    if ($stringToLimit.Length -le $maxCharacters) { return $stringToLimit }
    return $stringToLimit.Substring(0, $maxCharacters) + "...(truncated)"
}

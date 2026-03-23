function Invoke-DotNetTestAndPublishResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathToTestPackageContent,

        [Parameter(Mandatory = $true)]
        [string]$TestDllPath,

        [Parameter(Mandatory = $true)]
        [string]$ResultsFileName
    )

    if (-not (Test-Path -Path $TestDllPath)) {
        throw "Test assembly not found: $TestDllPath"
    }

    $resultsPath = Join-Path $PathToTestPackageContent $ResultsFileName

    if (Test-Path -Path $resultsPath) {
        Remove-Item -Path $resultsPath -Force
    }

    try {
        Write-Host "Executing: dotnet test `"$TestDllPath`"" -ForegroundColor Cyan
        & dotnet test $TestDllPath --logger "trx;LogFileName=$resultsPath"

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "dotnet test returned exit code $LASTEXITCODE for $TestDllPath (will be reported from TRX)."
        }

        if (-not (Test-Path -Path $resultsPath)) {
            throw "Expected TRX results file was not created: $resultsPath"
        }

        [xml]$trx = Get-Content -Path $resultsPath -Raw

        $ns = New-Object System.Xml.XmlNamespaceManager($trx.NameTable)
        $ns.AddNamespace('t', 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010')

        $unitResults = $trx.SelectNodes('//t:UnitTestResult', $ns)
        if (-not $unitResults) {
            throw "No UnitTestResult nodes found in TRX: $resultsPath"
        }

        foreach ($r in $unitResults) {
            $testName = $r.GetAttribute('testName')
            $outcome = $r.GetAttribute('outcome')

            if ([string]::IsNullOrWhiteSpace($testName)) {
                $testName = $r.GetAttribute('testId')
            }

            $duration = [TimeSpan]::Zero
            $durationAttribute = $r.GetAttribute('duration')
            if (-not [string]::IsNullOrWhiteSpace($durationAttribute)) {
                $parsed = [TimeSpan]::Zero
                if ([TimeSpan]::TryParse($durationAttribute, [ref]$parsed)) {
                    $duration = $parsed
                }
            }

            if ($outcome -eq 'Passed') {
                try {
                    Push-TestCaseResult -Outcome 'OK' -Name $testName -Duration $duration -Message "Test passed." -TestAspect Assertion
                }
                catch {
                    Write-Host "Skipped Push for OK on $testName"
                }

                continue
            }

            if (($outcome -eq 'Failed') -or ($outcome -eq 'Error') -or ($outcome -eq 'Timeout') -or ($outcome -eq 'Aborted')) {
                $messageNode = $r.SelectSingleNode('t:Output/t:ErrorInfo/t:Message', $ns)
                $stackNode = $r.SelectSingleNode('t:Output/t:ErrorInfo/t:StackTrace', $ns)

                if ($messageNode -and -not [string]::IsNullOrWhiteSpace($messageNode.InnerText)) {
                    $msg = $messageNode.InnerText.Trim()
                }
                else {
                    $msg = "Test failed."
                }

                if ($stackNode -and -not [string]::IsNullOrWhiteSpace($stackNode.InnerText)) {
                    $msg = $msg + "`n" + $stackNode.InnerText.Trim()
                }

                if (Get-Command -Name Limit-String -ErrorAction SilentlyContinue) {
                    $msg = Limit-String -stringToLimit $msg -maxCharacters 2000
                }

                try {
                    Push-TestCaseResult -Outcome 'Fail' -Name $testName -Duration $duration -Message $msg -TestAspect Assertion
                }
                catch {
                    Write-Host "Skipped Push for Fail on $testName"
                }

                continue
            }

            try {
                Push-TestCaseResult -Outcome 'Fail' -Name $testName -Duration $duration -Message "Unhandled test outcome '$outcome'." -TestAspect Assertion
            }
            catch {
                Write-Host "Skipped Push for Fail on $testName"
            }
        }
    }
    finally {
        if (Test-Path -Path $resultsPath) {
            try {
                Remove-Item -Path $resultsPath -Force
            }
            catch {
                Write-Warning "Failed to cleanup test output file: $resultsPath. $($_.Exception.Message)"
            }
        }
    }
}



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
        [Parameter(Mandatory=$true)][string]$stringToLimit,
        [Parameter(Mandatory=$false)][int]$maxCharacters = 2000
    )
    
    if ([string]::IsNullOrEmpty($stringToLimit)) { return $stringToLimit }
    if ($stringToLimit.Length -le $maxCharacters) { return $stringToLimit }
    return $stringToLimit.Substring(0, $maxCharacters) + "...(truncated)"
}



Export-ModuleMember -Function Invoke-DotNetTestAndPublishResults
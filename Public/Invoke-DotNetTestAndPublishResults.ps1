function Invoke-DotNetTestAndPublishResults {
    <#
    .SYNOPSIS
        Runs a .NET test assembly and publishes the results to QAOps.
    .DESCRIPTION
        Executes the given test assembly with 'dotnet test' (or the Microsoft.Testing
        Platform runner when -UsesMTP is true), writes a TRX result file into the test
        package content folder and pushes one QAOps test case result per test case.

        Tests that were not executed are published as NotExecuted unless
        -PublishNotExecuted is disabled.
    .PARAMETER PathToTestPackageContent
        Root of the test package content; the TRX file is written underneath it.
    .PARAMETER TestDllPath
        Path to the test assembly to execute.
    .PARAMETER ResultsFileName
        File name to use for the generated TRX result file.
    .PARAMETER UsesMTP
        'true' when the assembly uses the Microsoft.Testing Platform runner.
    .PARAMETER TestFilter
        Optional filter expression passed to the test runner.
    .PARAMETER PublishNotExecuted
        Publish skipped and not-executed test cases as NotExecuted results.
    .EXAMPLE
        Invoke-DotNetTestAndPublishResults -PathToTestPackageContent 'C:\Content' -TestDllPath 'C:\Content\Tests.dll' -ResultsFileName 'results.trx'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathToTestPackageContent,

        [Parameter(Mandatory = $true)]
        [string]$TestDllPath,

        [Parameter(Mandatory = $true)]
        [string]$ResultsFileName,

        [Parameter(Mandatory = $false)]
        [string]$UsesMTP = "false",

        [Parameter(Mandatory = $false)]
        [string]$TestFilter,

        [Parameter(Mandatory = $false)]
        [bool]$PublishNotExecuted = $true
    )

    $usesMtpBool = $false
    if (-not [string]::IsNullOrWhiteSpace($UsesMTP)) {
        $usesMtpBool = $UsesMTP.Trim().ToLowerInvariant() -eq "true"
    }

    if (-not (Test-Path -Path $TestDllPath)) {
        throw "Test assembly not found: $TestDllPath"
    }

    $resultsPath = Join-Path $PathToTestPackageContent $ResultsFileName
    $isExe = [System.IO.Path]::GetExtension($TestDllPath).Equals(".exe", [System.StringComparison]::OrdinalIgnoreCase)

    if (Test-Path -Path $resultsPath) {
        Remove-Item -Path $resultsPath -Force
    }

    try {
        $executionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($isExe) {
            $trxFileName = $ResultsFileName
            $exeDirectory = Split-Path -Path $TestDllPath -Parent
            $expectedTrxPath = Join-Path $exeDirectory ("TestResults\" + $trxFileName)
            $arguments = @('--report-trx', '--report-trx-filename', $trxFileName)
            if (-not [string]::IsNullOrWhiteSpace($TestFilter)) {
                $arguments = @('--filter', $TestFilter) + $arguments
            }

            Write-Host "Executing test executable with TRX output: `"$TestDllPath`"" -ForegroundColor Cyan
            if (-not [string]::IsNullOrWhiteSpace($TestFilter)) {
                Write-Host "Applying test filter: $TestFilter" -ForegroundColor Cyan
            }

            & $TestDllPath @arguments

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Test executable returned exit code $LASTEXITCODE for $TestDllPath (will be reported from TRX)."
            }

            if (-not (Test-Path -Path $expectedTrxPath)) {
                throw "Expected TRX file was not created at: $expectedTrxPath"
            }

            Copy-Item -Path $expectedTrxPath -Destination $resultsPath -Force
        }
        elseif ($usesMtpBool) {
            Write-Host "Executing: dotnet test --test-modules `"$TestDllPath`"" -ForegroundColor Cyan

            $arguments = @('test', '--test-modules', $TestDllPath)
            if (-not [string]::IsNullOrWhiteSpace($TestFilter)) {
                $arguments += @('--filter', $TestFilter)
            }

            & dotnet @arguments

            if ($LASTEXITCODE -ne 0) {
                throw "dotnet test --test-modules failed with exit code $LASTEXITCODE for expression/path: $TestDllPath"
            }

            return
        }
        else {
            Write-Host "Executing: dotnet test `"$TestDllPath`"" -ForegroundColor Cyan
            $arguments = @('test', $TestDllPath, '--logger', "trx;LogFileName=$resultsPath")
            if (-not [string]::IsNullOrWhiteSpace($TestFilter)) {
                $arguments += @('--filter', $TestFilter)
            }

            & dotnet @arguments

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "dotnet test returned exit code $LASTEXITCODE for $TestDllPath (will be reported from TRX)."
            }
        }

        $executionStopwatch.Stop()
        Write-Host "Test execution completed in $($executionStopwatch.Elapsed)." -ForegroundColor Cyan

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

        Write-Host "Publishing $($unitResults.Count) TRX test result(s) to QAOps." -ForegroundColor Cyan
        $publishedCount = 0
        $skippedNotExecutedCount = 0
        $publishStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
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
                    $publishedCount++
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
                    $publishedCount++
                }
                catch {
                    Write-Host "Skipped Push for Fail on $testName"
                }

                continue
            }

            if ($outcome -eq 'NotExecuted') {
                if (-not $PublishNotExecuted) {
                    $skippedNotExecutedCount++
                    continue
                }

                $messageNode = $r.SelectSingleNode('t:Output/t:ErrorInfo/t:Message', $ns)

                if ($messageNode -and -not [string]::IsNullOrWhiteSpace($messageNode.InnerText)) {
                    $msg = $messageNode.InnerText.Trim()
                }
                else {
                    $msg = "Test was not executed."
                }

                if (Get-Command -Name Limit-String -ErrorAction SilentlyContinue) {
                    $msg = Limit-String -stringToLimit $msg -maxCharacters 2000
                }

                try {
                    Push-TestCaseResult -Outcome 'NotExecuted' -Name $testName -Duration $duration -Message $msg -TestAspect Assertion
                    $publishedCount++
                }
                catch {
                    Write-Host "Skipped Push for NotExecuted on $testName"
                }

                continue
            }

            try {
                Push-TestCaseResult -Outcome 'Fail' -Name $testName -Duration $duration -Message "Unhandled test outcome '$outcome'." -TestAspect Assertion
                $publishedCount++
            }
            catch {
                Write-Host "Skipped Push for Fail on $testName"
            }
        }

        $publishStopwatch.Stop()
        Write-Host "Published $publishedCount QAOps assertion result(s) in $($publishStopwatch.Elapsed). Skipped NotExecuted result(s): $skippedNotExecutedCount." -ForegroundColor Cyan
    }
    finally {
        if ((-not $usesMtpBool) -and (Test-Path -Path $resultsPath)) {
            try {
                Remove-Item -Path $resultsPath -Force
            }
            catch {
                Write-Warning "Failed to cleanup test output file: $resultsPath. $($_.Exception.Message)"
            }
        }
    }
}

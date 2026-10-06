function Invoke-DotNetTestAndPublishResults {
    <#
    .SYNOPSIS
        Runs a .NET test assembly and publishes the results to QAOps.
    .DESCRIPTION
        Executes the given test assembly with 'dotnet test' or Microsoft.Testing Platform,
        requests TRX output, reads the generated results, enriches rows from the optional
        maintainer sidecar, and pushes one QAOps test case result per TRX result. New Q
        cmdlet parameters/cmdlets are used only when present, preserving old modules.
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
        [Parameter(Mandatory = $true)][string]$PathToTestPackageContent,
        [Parameter(Mandatory = $true)][string]$TestDllPath,
        [Parameter(Mandatory = $true)][string]$ResultsFileName,
        [Parameter(Mandatory = $false)][string]$UsesMTP = 'false',
        [Parameter(Mandatory = $false)][string]$TestFilter,
        [Parameter(Mandatory = $false)][bool]$PublishNotExecuted = $true
    )

    function ConvertTo-QAOpsOutcomeMessage {
        param([object]$Result)
        if ($Result.Outcome -eq 'Passed') { return [pscustomobject]@{ Outcome='OK'; Message='Test passed.' } }
        if ($Result.Outcome -eq 'NotExecuted') {
            $m = if ([string]::IsNullOrWhiteSpace($Result.Message)) { 'Test was not executed.' } else { $Result.Message }
            return [pscustomobject]@{ Outcome='NotExecuted'; Message=(Limit-String -stringToLimit $m -maxCharacters 2000) }
        }
        $msg = if ([string]::IsNullOrWhiteSpace($Result.Message)) { 'Test failed.' } else { $Result.Message }
        [pscustomobject]@{ Outcome='Fail'; Message=(Limit-String -stringToLimit $msg -maxCharacters 2000) }
    }

    function Invoke-QAOpsCapabilityCommand {
        param([string]$Name,[hashtable]$Parameters)
        $cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $cmd) { return [pscustomobject]@{ Supported=$false; Accepted=$false; StatusCode=0; ErrorCode='cmdletMissing'; Message="$Name is not available." } }
        try { & $Name @Parameters } catch { [pscustomobject]@{ Supported=$true; Accepted=$false; StatusCode=0; ErrorCode='terminatingError'; Message=$_.Exception.Message } }
    }

    $usesMtpBool = $false
    if (-not [string]::IsNullOrWhiteSpace($UsesMTP)) { $usesMtpBool = $UsesMTP.Trim().ToLowerInvariant() -eq 'true' }
    if (-not (Test-Path -LiteralPath $TestDllPath -PathType Leaf)) { throw "Test assembly not found: $TestDllPath" }

    $contentPath = (Resolve-Path -LiteralPath $PathToTestPackageContent -ErrorAction Stop).ProviderPath
    $resultsPath = Join-Path $contentPath $ResultsFileName
    $isExe = [System.IO.Path]::GetExtension($TestDllPath).Equals('.exe', [System.StringComparison]::OrdinalIgnoreCase)
    $assemblyName = [System.IO.Path]::GetFileName($TestDllPath)
    $attemptId = New-QAOpsUlid
    $publisherErrors = New-Object System.Collections.ArrayList
    $acceptedCount = 0
    $manifestSupported = $true
    $finalizationSupported = $true

    if (Test-Path -LiteralPath $resultsPath -PathType Leaf) { Remove-Item -LiteralPath $resultsPath -Force }

    try {
        $executionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($isExe) {
            $trxFileName = $ResultsFileName
            $exeDirectory = Split-Path -Path $TestDllPath -Parent
            $expectedTrxPath = Join-Path (Join-Path $exeDirectory 'TestResults') $trxFileName
            $arguments = @('--report-trx', '--report-trx-filename', $trxFileName)
            if (-not [string]::IsNullOrWhiteSpace($TestFilter)) { $arguments = @('--filter', $TestFilter) + $arguments }
            Write-Host "Executing test executable with TRX output: `"$TestDllPath`"" -ForegroundColor Cyan
            & $TestDllPath @arguments
            if ($LASTEXITCODE -ne 0) { Write-Warning "Test executable returned exit code $LASTEXITCODE for $TestDllPath (will be reported from TRX)." }
            if (-not (Test-Path -LiteralPath $expectedTrxPath -PathType Leaf)) { Write-Warning "Expected TRX file was not created at: $expectedTrxPath" } else { Copy-Item -LiteralPath $expectedTrxPath -Destination $resultsPath -Force }
        }
        elseif ($usesMtpBool) {
            Write-Host "Executing: dotnet test --test-modules `"$TestDllPath`"" -ForegroundColor Cyan
            $arguments = @('test','--test-modules',$TestDllPath,'--report-trx','--report-trx-filename',$ResultsFileName)
            if (-not [string]::IsNullOrWhiteSpace($TestFilter)) { $arguments += @('--filter',$TestFilter) }
            & dotnet @arguments
            if ($LASTEXITCODE -ne 0) { Write-Warning "dotnet test --test-modules returned exit code $LASTEXITCODE for $TestDllPath (will be reported from TRX)." }
            $candidate = Join-Path (Join-Path (Split-Path -Path $TestDllPath -Parent) 'TestResults') $ResultsFileName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { Copy-Item -LiteralPath $candidate -Destination $resultsPath -Force }
            elseif (-not (Test-Path -LiteralPath $resultsPath -PathType Leaf)) { Write-Warning 'MTP did not produce the requested TRX file. Install Microsoft.Testing.Extensions.TrxReport and ensure --report-trx is supported. No finalization will be sent for this package.'; return }
        }
        else {
            Write-Host "Executing: dotnet test `"$TestDllPath`"" -ForegroundColor Cyan
            $arguments = @('test',$TestDllPath,'--logger',("trx;LogFileName=$resultsPath"))
            if (-not [string]::IsNullOrWhiteSpace($TestFilter)) { $arguments += @('--filter',$TestFilter) }
            & dotnet @arguments
            if ($LASTEXITCODE -ne 0) { Write-Warning "dotnet test returned exit code $LASTEXITCODE for $TestDllPath (will be reported from TRX)." }
        }
        $executionStopwatch.Stop()
        Write-Host "Test execution completed in $($executionStopwatch.Elapsed)." -ForegroundColor Cyan
        if (-not (Test-Path -LiteralPath $resultsPath -PathType Leaf)) { throw "Expected TRX results file was not created: $resultsPath" }

        $sidecar = Import-QAOpsMaintainerSidecar -ContentPath $contentPath
        $rows = @(Get-QAOpsTrxResult -ResultsPath $resultsPath -AssemblyName $assemblyName)
        if ($rows.Count -eq 0) { throw "No UnitTestResult nodes found in TRX: $resultsPath" }
        $enriched = New-Object System.Collections.ArrayList
        foreach ($row in $rows) {
            $lookup = Resolve-QAOpsRuntimeMaintainers -Entries $sidecar.Entries -Assembly $row.Assembly -FullyQualifiedName $row.FullyQualifiedName -DataCaseId $row.DataCaseId -Target 'default'
            foreach ($diag in @($lookup.Diagnostics)) { if ($diag.code -eq 'maintainer-conflict') { Write-Warning "Maintainer conflict for $($diag.key); publishing without maintainers." } }
            [void]$enriched.Add([pscustomobject]@{ Result=$row; Lookup=$lookup; ProducerEventId=New-QAOpsUlid })
        }

        if ($manifestSupported) {
            $invocations = @($enriched | ForEach-Object { [pscustomobject]@{ testInvocationId=$_.Lookup.TestInvocationId; displayName=$_.Result.DisplayName; maintainers=$_.Lookup.Maintainers } })
            $manifestParams = @{ CountSemanticsVersion='qaops-counts-v1'; ExpectedTests=$invocations.Count; DiscoveredTests=$invocations.Count; TestInvocations=$invocations }
            $manifestResult = Invoke-QAOpsCapabilityCommand -Name 'Push-TestRunManifest' -Parameters $manifestParams
            if ($manifestResult -and $manifestResult.PSObject.Properties.Name -contains 'Supported' -and -not $manifestResult.Supported) { $manifestSupported = $false }
            elseif ($manifestResult -and $manifestResult.PSObject.Properties.Name -contains 'Accepted' -and -not $manifestResult.Accepted) { [void]$publisherErrors.Add([pscustomobject]@{ testInvocationId=$null; code='PushTestRunManifestNotAccepted'; message=(Limit-String -stringToLimit ([string]$manifestResult.Message) -maxCharacters 1024) }) }
        }

        Write-Host "Publishing $($rows.Count) TRX test result(s) to QAOps." -ForegroundColor Cyan
        $caseCommand = Get-Command -Name Push-TestCaseResult -ErrorAction SilentlyContinue
        if ($null -eq $caseCommand) { Write-Warning 'Push-TestCaseResult is not available; results cannot be published.' }
        foreach ($item in $enriched) {
            $r = $item.Result
            if ($r.Outcome -eq 'NotExecuted' -and -not $PublishNotExecuted) { continue }
            $om = ConvertTo-QAOpsOutcomeMessage -Result $r
            $parameters = @{ Outcome=$om.Outcome; Name=$r.DisplayName; Duration=$r.Duration; Message=$om.Message; TestAspect='Assertion' }
            if ($caseCommand) {
                $supportedParams = $caseCommand.Parameters
                if ($supportedParams.ContainsKey('ProducerEventId')) { $parameters['ProducerEventId'] = $item.ProducerEventId }
                if ($supportedParams.ContainsKey('TestInvocationId')) { $parameters['TestInvocationId'] = $item.Lookup.TestInvocationId }
                if ($supportedParams.ContainsKey('AttemptId')) { $parameters['AttemptId'] = $attemptId }
                $maintainerValidation = Test-QAOpsMaintainerEnvelope -Maintainers $item.Lookup.Maintainers
                if ($supportedParams.ContainsKey('Maintainers') -and $maintainerValidation.Valid) { $parameters['Maintainers'] = $maintainerValidation.Json }
                elseif ($item.Lookup.Maintainers -and -not $maintainerValidation.Valid) { Write-Warning "Dropping invalid maintainer envelope for $($item.Lookup.TestInvocationId): $($maintainerValidation.Code)" }
                try {
                    $pushResult = Push-TestCaseResult @parameters
                    $accepted = $true
                    if ($pushResult -and $pushResult.PSObject.Properties.Name -contains 'Accepted') { $accepted = [bool]$pushResult.Accepted }
                    if ($accepted) { $acceptedCount++ } else { [void]$publisherErrors.Add([pscustomobject]@{ testInvocationId=$item.Lookup.TestInvocationId; code='PushTestCaseResultNotAccepted'; message=(Limit-String -stringToLimit ([string]$pushResult.Message) -maxCharacters 1024) }); Write-Warning "Push-TestCaseResult was not accepted for $($item.Lookup.TestInvocationId)." }
                }
                catch {
                    if ($parameters.ContainsKey('Maintainers') -and $_.Exception.Message -match 'maintain') {
                        Write-Warning "Push-TestCaseResult rejected maintainer metadata for $($item.Lookup.TestInvocationId); retrying without maintainers."
                        $parameters.Remove('Maintainers')
                        try { $pushResult = Push-TestCaseResult @parameters; $acceptedCount++ }
                        catch { [void]$publisherErrors.Add([pscustomobject]@{ testInvocationId=$item.Lookup.TestInvocationId; code='PushTestCaseResultFailed'; message=(Limit-String -stringToLimit $_.Exception.Message -maxCharacters 1024) }); Write-Warning "Push-TestCaseResult failed for $($item.Lookup.TestInvocationId): $($_.Exception.Message)" }
                    } else { [void]$publisherErrors.Add([pscustomobject]@{ testInvocationId=$item.Lookup.TestInvocationId; code='PushTestCaseResultFailed'; message=(Limit-String -stringToLimit $_.Exception.Message -maxCharacters 1024) }); Write-Warning "Push-TestCaseResult failed for $($item.Lookup.TestInvocationId): $($_.Exception.Message)" }
                }
            }
        }

        if ($finalizationSupported) {
            $errorsForFinalization = @($publisherErrors | Select-Object -First 100)
            $finalResult = Invoke-QAOpsCapabilityCommand -Name 'Push-TestRunFinalization' -Parameters @{ PublishedResultCount=$acceptedCount; PublisherErrors=$errorsForFinalization }
            if ($finalResult -and $finalResult.PSObject.Properties.Name -contains 'Supported' -and -not $finalResult.Supported) { $finalizationSupported = $false }
            elseif ($finalResult -and $finalResult.PSObject.Properties.Name -contains 'Accepted' -and -not $finalResult.Accepted) { Write-Warning "Push-TestRunFinalization was not accepted: $($finalResult.Message)" }
        }
        Write-Host "Published $acceptedCount QAOps assertion result(s). Publisher error(s): $($publisherErrors.Count)." -ForegroundColor Cyan
    }
    finally {
        if (Test-Path -LiteralPath $resultsPath -PathType Leaf) {
            try { Remove-Item -LiteralPath $resultsPath -Force } catch { Write-Warning "Failed to cleanup test output file: $resultsPath. $($_.Exception.Message)" }
        }
    }
}



function Invoke-QAFrameworkTestPackage {
    <#
    .SYNOPSIS
        Runs a QAFramework test package from start to finish.
    .DESCRIPTION
        The one call a test package needs in its 2.TestPackageExecution.ps1. It performs the
        whole flow:

        1. read the run configuration (parameters, test run labels, supplementary file, package
           configuration and the legacy defaults),
        2. read the cluster topology from QAOps,
        3. import the harvested test metadata,
        4. drop the tests that may not run here and report them as NotExecuted with the reason,
        5. build the execution plan (phases and TargetDMA expansion),
        6. optionally prepare the agents,
        7. run the plan and publish every test as it finishes,
        8. publish the overall pipeline_TestPackageExecution result.

        The orchestrator never runs a test itself, so this works unchanged on a QAOps Bridge
        without DataMiner.
    .PARAMETER TestPackageContentPath
        The test package content root. Defaults to the parent folder of the calling script.
    .PARAMETER Keywords
        Only run tests with one of these keywords. Prefix with ! to exclude instead.
    .PARAMETER ExcludeKeywords
        Do not run tests with one of these keywords.
    .PARAMETER Squads
        Only run tests of one of these squads. Prefix with ! to exclude instead.
    .PARAMETER ExcludeSquads
        Do not run tests of one of these squads.
    .PARAMETER Customers
        Only run tests of these customers, next to the tests without a customer.
    .PARAMETER SkipAgentSetup
        Do not run Initialize-QAFrameworkAgents. Use this when 1.TestPackageSetup.ps1 already
        prepared the agents.
    .PARAMETER SkipPublish
        Do not publish anything to QAOps. Useful for a dry run.
    .PARAMETER PassThru
        Return the run result object instead of only writing the summary.
    .PARAMETER OverallResultName
        The name of the overall QAOps test case. Defaults to pipeline_TestPackageExecution.
    .EXAMPLE
        Invoke-QAFrameworkTestPackage -TestPackageContentPath (Resolve-Path "$PSScriptRoot\..")
    .OUTPUTS
        The run result object when -PassThru is used.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TestPackageContentPath,

        [Parameter()][string[]]$Keywords,
        [Parameter()][string[]]$ExcludeKeywords,
        [Parameter()][string[]]$Squads,
        [Parameter()][string[]]$ExcludeSquads,
        [Parameter()][string[]]$Customers,

        [Parameter()][switch]$SkipAgentSetup,
        [Parameter()][switch]$SkipPublish,
        [Parameter()][switch]$PassThru,

        [Parameter()][string]$OverallResultName = 'pipeline_TestPackageExecution'
    )

    $startedAt = [DateTime]::UtcNow

    try {
    $configurationParameters = @{ TestPackageContentPath = $TestPackageContentPath }
    foreach ($name in @('Keywords', 'ExcludeKeywords', 'Squads', 'ExcludeSquads')) {
        if ($PSBoundParameters.ContainsKey($name)) { $configurationParameters[$name] = $PSBoundParameters[$name] }
    }

    $configuration = Get-QAFrameworkRunConfiguration @configurationParameters
    Write-Verbose "Run configuration built from: $($configuration.sources -join ', ')."

    $topology = Get-QAFrameworkClusterTopology
    Write-Verbose "Cluster has $($topology.Agents.Count) DataMiner agent(s) and $($topology.FailoverPairs.Count) failover pair(s)."

    $tests = @(Import-QAFrameworkTestMetadata -TestPackageContentPath $TestPackageContentPath)
    Write-Verbose "Imported $($tests.Count) test(s)."

    $selectionParameters = @{ Test = $tests; Configuration = $configuration; Topology = $topology }
    if ($PSBoundParameters.ContainsKey('Customers')) { $selectionParameters['Customers'] = $Customers }

    $selection = Select-QAFrameworkTest @selectionParameters
    Write-Verbose "$($selection.Selected.Count) test(s) selected, $($selection.Dropped.Count) dropped."

    $plan = New-QAFrameworkExecutionPlan -Test $selection.Selected -Topology $topology -Configuration $configuration

    if (-not $SkipPublish) {
        foreach ($dropped in @($selection.Dropped) + @($plan.Skipped)) {
            $null = Publish-QAFrameworkTestResult -WorkItem ([pscustomobject]@{ Name = $dropped.Name; Outcome = 'NotExecuted'; Message = $dropped.Reason }) -Outcome 'NotExecuted' -Message $dropped.Reason
        }
    }

    if (-not $SkipAgentSetup) {
        Write-Verbose 'Preparing the DataMiner agents.'
        $null = Initialize-QAFrameworkAgents -Topology $topology -Configuration $configuration -TestPackageContentPath $TestPackageContentPath
    }

    $run = Invoke-QAFrameworkTestRun -Plan $plan -Topology $topology -Configuration $configuration -TestPackageContentPath $TestPackageContentPath -SkipPublish:$SkipPublish

    $duration = [DateTime]::UtcNow - $startedAt
    $overallOutcome = if ($run.HasFailed) { 'Fail' } else { 'Ok' }
    $overallMessage = 'Ok: {0}, Fail: {1}, NotApplicable: {2}, NotExecuted: {3}, dropped before the run: {4}.' -f `
        $run.Summary.Ok, $run.Summary.Fail, $run.Summary.NotApplicable, $run.Summary.NotExecuted, (@($selection.Dropped).Count + @($plan.Skipped).Count)

    Write-Host $overallMessage

    if (-not $SkipPublish) {
        try {
            Push-TestCaseResult -Outcome $overallOutcome -Name $OverallResultName -Duration $duration -Message (Limit-String -stringToLimit $overallMessage -maxCharacters 2000) -TestAspect 'Execution'
        }
        catch {
            Write-Warning "Could not publish the overall result: $($_.Exception.Message)"
        }
    }

    if ($PassThru) {
        return [pscustomobject]@{
            Configuration = $configuration
            Topology      = $topology
            Selection     = $selection
            Plan          = $plan
            Run           = $run
            Outcome       = $overallOutcome
            Duration      = $duration
            Message       = $overallMessage
        }
    }
    }
    catch {
        $failure = $_
        $duration = [DateTime]::UtcNow - $startedAt
        $message = "QAFramework orchestration failed: $($failure.Exception.Message)"

        if (-not $SkipPublish -and (Get-Command -Name 'Push-TestCaseResult' -ErrorAction SilentlyContinue)) {
            try {
                Push-TestCaseResult -Outcome 'Fail' -Name $OverallResultName -Duration $duration `
                    -Message (Limit-String -stringToLimit $message -maxCharacters 2000) -TestAspect 'Execution'
            }
            catch {
                Write-Warning "Could not publish the failed overall result: $($_.Exception.Message)"
            }
        }

        throw $failure
    }
}

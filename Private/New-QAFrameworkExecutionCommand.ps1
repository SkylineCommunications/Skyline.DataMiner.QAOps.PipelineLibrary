function New-QAFrameworkExecutionCommand {
    <#
    .SYNOPSIS
        Builds the bridge execution command that runs a QAFramework test.
    .DESCRIPTION
        A QAFramework test is an automation script on the DataMiner agent, so it is started
        exactly as the legacy runner and qaops-testrunner do:

            dotnet tool run dataminer-run-automation-script Local -sn "<test name>"

        The working directory is the folder that holds dotnet-tools.json, which is
        TestPackagePipeline inside the test package content.
    .PARAMETER WorkItem
        The work item to run.
    .PARAMETER TestPackageContentPath
        The root of the test package content on the agent.
    .PARAMETER WorkingDirectory
        Overrides the working directory that is derived from TestPackageContentPath.
    .PARAMETER Configuration
        A run configuration. Supplies testTimeoutSeconds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$WorkItem,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TestPackageContentPath,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$WorkingDirectory,
        [Parameter()][object]$Configuration
    )

    # The Bridge resolves this path against its own extracted package root. Never send the
    # orchestrator's absolute path: it may be a Linux path while the target agent is Windows.
    $directory = $WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = 'TestPackagePipeline'
    }

    $timeout = 7200
    if ($Configuration -and $Configuration.testTimeoutSeconds -gt 0) { $timeout = [int]$Configuration.testTimeoutSeconds }

    $environment = @{
        QAFRAMEWORK_TEST_NAME = [string]$WorkItem.Name
        QAFRAMEWORK_PHASE     = [string]$WorkItem.Phase
    }

    return [pscustomobject]@{
        Executable           = 'dotnet'
        Arguments            = [string[]]@('tool', 'run', 'dataminer-run-automation-script', 'Local', '-sn', [string]$WorkItem.Name)
        WorkingDirectory     = $directory
        TimeoutSeconds       = $timeout
        EnvironmentVariables = $environment
    }
}

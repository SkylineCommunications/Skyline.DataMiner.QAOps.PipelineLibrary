function Invoke-QAFrameworkLogCollection {
    <#
    .SYNOPSIS
        Starts the DataMiner log collector on an agent after a test failure.
    .DESCRIPTION
        Parity with the existing test packages: on the first failure of a run, SL_LogCollector
        is started once so the logs and process dumps of the moment of failure are captured.
        The collector is started through a bridge execution, so the orchestrator does not need
        access to the agent.

        The collector is started and awaited with a generous timeout, because it produces a
        package of several hundred megabytes.
    .PARAMETER Agent
        The agent from the cluster topology on which the failure happened.
    .PARAMETER CollectorPath
        The path of SL_LogCollector.exe on the agent.
    .PARAMETER TimeoutSeconds
        How long the collector may run.
    .PARAMETER Wait
        Wait until the collector finished instead of letting it run in the background.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$Agent,
        [Parameter()][string]$CollectorPath = 'C:\Skyline DataMiner\Tools\SLLogCollector\SL_LogCollector.exe',
        [Parameter()][int]$TimeoutSeconds = 1800,
        [Parameter()][switch]$Wait
    )

    if (-not (Get-Command -Name 'Start-QAOpsBridgeExecution' -ErrorAction SilentlyContinue)) {
        throw 'Start-QAOpsBridgeExecution is not available. Import the QAOps.PowerShell module before collecting logs.'
    }

    $arguments = [string[]]@('--console', '--folder=C:\Skyline', '--dumps=SLNet.exe,SLDataMiner.exe,SLXml.exe')

    try {
        $execution = Start-QAOpsBridgeExecution -Bridge $Agent.Bridge -Executable $CollectorPath -Arguments $arguments -TimeoutSeconds $TimeoutSeconds

        if ($Wait) {
            $null = Wait-QAOpsBridgeExecution -Execution ([object[]]@($execution)) -TimeoutSeconds $TimeoutSeconds
        }

        return [pscustomobject]@{
            BridgeId    = $Agent.BridgeId
            Success     = $true
            ExecutionId = $execution.Id
            Message     = "Log collection started on agent '$($Agent.BridgeId)'."
        }
    }
    catch {
        Write-Warning "Could not start the log collector on agent '$($Agent.BridgeId)': $($_.Exception.Message)"

        return [pscustomobject]@{
            BridgeId    = $Agent.BridgeId
            Success     = $false
            ExecutionId = $null
            Message     = $_.Exception.Message
        }
    }
}

function Publish-QAFrameworkTestResult {
    <#
    .SYNOPSIS
        Publishes the result of a QAFramework work item to QAOps.
    .DESCRIPTION
        Wraps Push-TestCaseResult so QAOps sees one test case per QAFramework test, using the
        same naming as the existing test packages: automationscript_<test name>, published with
        the Execution aspect and a message that is capped at 2000 characters.

        When the same test ran on several agents, the agent is appended to the name so the
        results do not overwrite each other.
    .PARAMETER WorkItem
        A completed work item from Invoke-QAFrameworkTestRun.
    .PARAMETER Outcome
        Overrides the outcome stored on the work item.
    .PARAMETER Message
        Overrides the message stored on the work item.
    .PARAMETER NamePrefix
        The prefix of the published test case name. Defaults to automationscript_.
    .PARAMETER IncludeAgentInName
        Append the agent to the test case name. Used for TargetDMA All and AllFailovers.
    .PARAMETER MaximumMessageLength
        The maximum message length. Defaults to 2000 characters.
    .EXAMPLE
        $run.WorkItems | Publish-QAFrameworkTestResult
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object]$WorkItem,

        [Parameter()]
        [ValidateSet('Ok', 'Fail', 'NotExecuted', 'NotApplicable')]
        [string]$Outcome,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [string]$NamePrefix = 'automationscript_',

        [Parameter()]
        [switch]$IncludeAgentInName,

        [Parameter()]
        [int]$MaximumMessageLength = 2000
    )

    begin {
        if (-not (Get-Command -Name 'Push-TestCaseResult' -ErrorAction SilentlyContinue)) {
            throw 'Push-TestCaseResult is not available. Import the QAOps.PowerShell module before publishing QAFramework results.'
        }
    }

    process {
        $resultOutcome = if ($PSBoundParameters.ContainsKey('Outcome')) { $Outcome } else { [string]$WorkItem.Outcome }
        if ([string]::IsNullOrWhiteSpace($resultOutcome)) { $resultOutcome = 'NotExecuted' }

        $resultMessage = if ($PSBoundParameters.ContainsKey('Message')) { $Message } else { [string]$WorkItem.Message }
        $resultMessage = Limit-String -stringToLimit $resultMessage -maxCharacters $MaximumMessageLength

        $name = '{0}{1}' -f $NamePrefix, $WorkItem.Name
        if ($IncludeAgentInName -and $WorkItem.TargetBridgeId) {
            $name = '{0}_{1}' -f $name, $WorkItem.TargetBridgeId
        }

        $duration = [TimeSpan]::Zero
        if ($WorkItem.StartedAt -and $WorkItem.CompletedAt) {
            $duration = [TimeSpan]($WorkItem.CompletedAt - $WorkItem.StartedAt)
            if ($duration -lt [TimeSpan]::Zero) { $duration = [TimeSpan]::Zero }
        }

        if ($PSCmdlet.ShouldProcess($name, "Push test case result '$resultOutcome'")) {
            try {
                Push-TestCaseResult -Outcome $resultOutcome -Name $name -Duration $duration -Message $resultMessage -TestAspect 'Execution'
            }
            catch {
                Write-Warning "Could not publish result '$name': $($_.Exception.Message)"
            }
        }

        return [pscustomobject]@{
            Name     = $name
            Outcome  = $resultOutcome
            Duration = $duration
            Message  = $resultMessage
        }
    }
}

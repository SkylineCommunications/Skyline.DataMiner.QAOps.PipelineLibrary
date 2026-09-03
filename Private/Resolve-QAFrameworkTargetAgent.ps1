function Resolve-QAFrameworkTargetAgent {
    <#
    .SYNOPSIS
        Resolves the TargetDMA attribute of a test into the agents it must run on.
    .DESCRIPTION
        Port of the RunOn handling in the legacy TaskSchedulerAndRunner:

        One           - the test runs once on any available agent (no pinning).
        All           - the test is cloned once per DataMiner agent.
        AllFailovers  - the test is cloned once per agent that is part of a failover pair.
        LowestDMAID   - the test is pinned to the agent with the lowest DmaId.
        HighestDMAID  - the test is pinned to the agent with the highest DmaId.

        For failover fixtures the candidate pool is restricted to failover agents whenever the
        cluster has any, so LowestDMAID on a failover test resolves to the lowest failover
        agent instead of the lowest agent overall.
    .PARAMETER TargetDma
        The TargetDMA value of the test.
    .PARAMETER Topology
        A cluster topology from Get-QAFrameworkClusterTopology.
    .PARAMETER PreferFailoverAgents
        Restrict the candidate pool to failover agents when the cluster has them.
    .OUTPUTS
        A result object with an Agents collection (empty means "any agent") and a Reason that
        explains an empty resolution that is not the "any agent" case.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$TargetDma,
        [AllowNull()][object]$Topology,
        [switch]$PreferFailoverAgents
    )

    $value = if ([string]::IsNullOrWhiteSpace($TargetDma)) { 'One' } else { $TargetDma.Trim() }

    $anyAgent = [pscustomobject]@{ Agents = [object[]]@(); IsAnyAgent = $true; Reason = '' }

    if ([string]::Equals($value, 'One', [StringComparison]::OrdinalIgnoreCase)) { return $anyAgent }

    $agents = [object[]]@()
    if ($Topology) { $agents = [object[]]@($Topology.Agents) }

    if ($agents.Count -eq 0) {
        # The topology is unknown, so the scheduler falls back to "any agent".
        return $anyAgent
    }

    $failoverAgents = [object[]]@($agents | Where-Object { $_.IsFailover })
    $pool = $agents
    if (($PreferFailoverAgents -or [string]::Equals($value, 'AllFailovers', [StringComparison]::OrdinalIgnoreCase)) -and $failoverAgents.Count -gt 0) {
        $pool = $failoverAgents
    }

    switch -Regex ($value) {
        '^(?i)All$' {
            return [pscustomobject]@{ Agents = $pool; IsAnyAgent = $false; Reason = '' }
        }
        '^(?i)AllFailovers$' {
            if ($failoverAgents.Count -eq 0) {
                return [pscustomobject]@{ Agents = [object[]]@(); IsAnyAgent = $false; Reason = 'The cluster has no failover agents.' }
            }
            return [pscustomobject]@{ Agents = $failoverAgents; IsAnyAgent = $false; Reason = '' }
        }
        '^(?i)LowestDMAID$' {
            $sorted = [object[]]@($pool | Sort-Object -Property @{ Expression = { $_.DmaId } })
            return [pscustomobject]@{ Agents = [object[]]@($sorted[0]); IsAnyAgent = $false; Reason = '' }
        }
        '^(?i)HighestDMAID$' {
            $sorted = [object[]]@($pool | Sort-Object -Property @{ Expression = { $_.DmaId } })
            return [pscustomobject]@{ Agents = [object[]]@($sorted[-1]); IsAnyAgent = $false; Reason = '' }
        }
        default {
            Write-Warning "Unknown TargetDMA value '$value'; the test is scheduled on any available agent."
            return $anyAgent
        }
    }
}

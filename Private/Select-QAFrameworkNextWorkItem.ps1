function Select-QAFrameworkNextWorkItem {
    <#
    .SYNOPSIS
        Picks the next work item that fits on an agent.
    .DESCRIPTION
        Port of the legacy GetTestWithWeight logic. An agent has a fixed capacity (3 by
        default) and every running test consumes its weight. The scheduler prefers a test that
        fills the remaining capacity exactly, and otherwise takes the first test that still
        fits.

        Work items that are pinned to this agent by their TargetDMA attribute always win from
        items that may run anywhere, so a pinned item cannot starve while the shared pool keeps
        the agent busy.
    .PARAMETER WorkItem
        The pending work items of the current phase.
    .PARAMETER BridgeId
        The agent that has capacity left.
    .PARAMETER FreeWeight
        The capacity that is still free on that agent.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$WorkItem,
        [Parameter(Mandatory = $true)][string]$BridgeId,
        [Parameter(Mandatory = $true)][int]$FreeWeight
    )

    if ($FreeWeight -le 0) { return $null }

    $pending = @($WorkItem | Where-Object { $_.State -eq 'Pending' })
    if ($pending.Count -eq 0) { return $null }

    $pinned = @($pending | Where-Object { $_.TargetBridgeId -eq $BridgeId })
    $shared = @($pending | Where-Object { -not $_.TargetBridgeId })

    foreach ($pool in @($pinned, $shared)) {
        $exact = $pool | Where-Object { $_.Weight -eq $FreeWeight } | Select-Object -First 1
        if ($exact) { return $exact }

        $fits = $pool | Where-Object { $_.Weight -lt $FreeWeight } | Select-Object -First 1
        if ($fits) { return $fits }
    }

    return $null
}

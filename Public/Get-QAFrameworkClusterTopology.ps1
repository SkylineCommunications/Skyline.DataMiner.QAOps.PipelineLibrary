function Get-QAFrameworkClusterTopology {
    <#
    .SYNOPSIS
        Describes the QAOps cluster from the QAFramework point of view.
    .DESCRIPTION
        Wraps Get-QAOpsBridge and Get-QAOpsCluster into the shape the QAFramework scheduler
        needs: the agents that may execute a test, the failover pairs, the lowest and
        highest DMA id, and the cluster-wide facts used by the legacy test filters.

        The orchestrator itself is deliberately not assumed to host a DataMiner: only
        bridges reporting HasDataMiner are eligible to run a test. Because those bridge
        properties are still being implemented in QAOps, the function degrades
        conservatively when they are absent:

          * HasDataMiner missing on every bridge  -> every bridge is treated as an agent
          * DmaId missing                          -> an ordinal is assigned by bridge order
          * IsFailover missing                     -> the cluster is treated as non-failover,
                                                      which disables the failover phases
    .PARAMETER Bridge
        Pre-fetched bridges. When omitted, Get-QAOpsBridge is called.
    .PARAMETER Cluster
        Pre-fetched cluster information. When omitted, Get-QAOpsCluster is called.
    .PARAMETER ExcludeOrchestrator
        Never execute tests on the orchestrating bridge, even when it hosts a DataMiner.
    .EXAMPLE
        Get-QAFrameworkClusterTopology
    .OUTPUTS
        PSCustomObject describing the topology.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [object[]]$Bridge,
        [object]$Cluster,
        [switch]$ExcludeOrchestrator
    )

    if (-not $PSBoundParameters.ContainsKey('Bridge')) {
        if (-not (Get-Command -Name 'Get-QAOpsBridge' -ErrorAction SilentlyContinue)) {
            throw 'Get-QAOpsBridge is not available. Import the QAOps.PowerShell module before calling Get-QAFrameworkClusterTopology.'
        }

        $Bridge = @(Get-QAOpsBridge)
    }

    $bridges = @($Bridge | Where-Object { $null -ne $_ })

    if (-not $PSBoundParameters.ContainsKey('Cluster')) {
        $Cluster = $null
        if (Get-Command -Name 'Get-QAOpsCluster' -ErrorAction SilentlyContinue) {
            try { $Cluster = Get-QAOpsCluster }
            catch { Write-Verbose "Get-QAOpsCluster failed: $($_.Exception.Message). Continuing without cluster information." }
        }
    }

    $hasProperty = {
        param([object]$Object, [string]$Name)
        return ($null -ne $Object -and $null -ne ($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1))
    }

    # When no bridge reports HasDataMiner the property is simply not implemented yet.
    $hasDataMinerKnown = @($bridges | Where-Object { (& $hasProperty $_ 'HasDataMiner') -and $_.HasDataMiner }).Count -gt 0

    $agents = [System.Collections.Generic.List[object]]::new()
    $ordinal = 0

    foreach ($item in $bridges) {
        $isAgent = if ($hasDataMinerKnown) { [bool]$item.HasDataMiner } else { $true }

        if ($isAgent -and $ExcludeOrchestrator -and $item.IsOrchestrator) {
            $isAgent = $false
        }

        if (-not $isAgent) {
            Write-Verbose "Bridge '$($item.Id)' will not execute tests."
            continue
        }

        $ordinal++
        $dmaId = if ((& $hasProperty $item 'DmaId') -and $null -ne $item.DmaId) { [int]$item.DmaId } else { $ordinal }

        $agents.Add([pscustomobject]@{
                BridgeId                = $item.Id
                DisplayName             = if ($item.DisplayName) { $item.DisplayName } else { $item.Id }
                HostName                = $item.HostName
                DmaId                   = $dmaId
                DmaIdIsKnown            = ((& $hasProperty $item 'DmaId') -and $null -ne $item.DmaId)
                IsOrchestrator          = [bool]$item.IsOrchestrator
                IsSelf                  = [bool]$item.IsSelf
                IsFailover              = if (& $hasProperty $item 'IsFailover') { [bool]$item.IsFailover } else { $false }
                FailoverPartnerBridgeId = if (& $hasProperty $item 'FailoverPartnerBridgeId') { $item.FailoverPartnerBridgeId } else { $null }
                FailoverPartnerHostName = if (& $hasProperty $item 'FailoverPartnerHostName') { $item.FailoverPartnerHostName } else { $null }
                Labels                  = if ((& $hasProperty $item 'Labels') -and $item.Labels) { $item.Labels } else { @{} }
                TestPackageContentPath  = $item.TestPackageContentPath
                Bridge                  = $item
            })
    }

    # A failover pair normally has one QAOps Bridge: the standby DataMiner machine does not
    # run another bridge. The bridge hosting the pair is therefore sufficient to identify and
    # switch it; the partner host name is informational.
    $pairs = [System.Collections.Generic.List[object]]::new()
    $paired = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($agent in $agents) {
        if (-not $agent.IsFailover) { continue }
        if ($paired.Contains($agent.BridgeId)) { continue }

        $partner = $null
        if ($agent.FailoverPartnerBridgeId) {
            $partner = $agents | Where-Object { $_.BridgeId -eq $agent.FailoverPartnerBridgeId } | Select-Object -First 1
        }

        [void]$paired.Add($agent.BridgeId)
        if ($partner) { [void]$paired.Add($partner.BridgeId) }

        $pairs.Add([pscustomobject]@{
                PairId  = if ($partner) { ('{0}|{1}' -f $agent.BridgeId, $partner.BridgeId) } else { $agent.BridgeId }
                Primary = $agent
                Partner = $partner
                PartnerHostName = $agent.FailoverPartnerHostName
            })
    }

    $dmaIds = @($agents | ForEach-Object { $_.DmaId } | Sort-Object)

    $dataMinerVersion = $null
    if ($Cluster -and $Cluster.DataMinerVersion) {
        $parsed = [version]::new()
        if ([version]::TryParse([string]$Cluster.DataMinerVersion, [ref]$parsed)) { $dataMinerVersion = $parsed }
        else { Write-Warning "Cluster reported an unparsable DataMiner version '$($Cluster.DataMinerVersion)'; version filtering is disabled." }
    }

    $solutionVersions = @{}
    if ($Cluster -and $Cluster.SolutionVersions) {
        if ($Cluster.SolutionVersions -is [System.Collections.IDictionary]) {
            foreach ($key in $Cluster.SolutionVersions.Keys) { $solutionVersions[$key] = $Cluster.SolutionVersions[$key] }
        }
        else {
            foreach ($entry in $Cluster.SolutionVersions.PSObject.Properties) { $solutionVersions[$entry.Name] = $entry.Value }
        }
    }

    return [pscustomobject]@{
        Name             = if ($Cluster) { $Cluster.Name } else { $null }
        Agents           = [object[]]$agents
        FailoverPairs    = [object[]]$pairs
        HasFailover      = ($pairs.Count -gt 0)
        LowestDmaId      = if ($dmaIds.Count -gt 0) { $dmaIds[0] } else { $null }
        HighestDmaId     = if ($dmaIds.Count -gt 0) { $dmaIds[-1] } else { $null }
        DataMinerVersion = $dataMinerVersion
        DbmsType         = if ($Cluster) { $Cluster.DbmsType } else { $null }
        IsCentralized    = if ($Cluster) { [bool]$Cluster.IsCentralized } else { $false }
        IsRedGreen       = if ($Cluster) { [bool]$Cluster.IsRedGreen } else { $false }
        Labels           = if ($Cluster -and $Cluster.Labels) { $Cluster.Labels } else { @{} }
        SolutionVersions = $solutionVersions
        IsClusterKnown   = ($null -ne $Cluster)
    }
}

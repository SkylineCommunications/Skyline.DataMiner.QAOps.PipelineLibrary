function Select-QAFrameworkTest {
    <#
    .SYNOPSIS
        Applies the QAFramework selection filters to a set of test metadata.
    .DESCRIPTION
        Port of TestFilter.FilterTests from the legacy TaskSchedulerAndRunner, extended with
        the gates that only make sense on a QAOps cluster (solution versions, failover
        availability and TargetDMA feasibility).

        The filters are evaluated in the legacy order so a test that would have been dropped
        by the old runner is dropped here for the same reason:

        Disabled, NonCentralizedTest, CentralizedTest, RedGreenTest, Squads, ExcludeSquads,
        MinVersion, LocalDB, Keywords, ExcludeKeywords, Customers, SolutionInfo, Failover and
        TargetDMA feasibility.

        Every dropped test is reported with the filter that removed it and a human readable
        reason, so a pipeline can publish them as NotExecuted instead of silently losing them.
    .PARAMETER Test
        Schema v1 test metadata objects, typically from Import-QAFrameworkTestMetadata.
    .PARAMETER Configuration
        A run configuration from Get-QAFrameworkRunConfiguration. Supplies the keyword and
        squad filters and forceRunNonCentralized.
    .PARAMETER Topology
        A cluster topology from Get-QAFrameworkClusterTopology. When omitted, every
        cluster-dependent filter is skipped so the selection stays conservative.
    .PARAMETER Customers
        Only keep tests that declare at least one of these customers. Tests without any
        customer are kept, matching the informational nature of the legacy attribute.
    .PARAMETER KeepDisabled
        Keep disabled tests in the selection instead of dropping them. Useful for a dry run
        that wants to report everything the package contains.
    .EXAMPLE
        $selection = Select-QAFrameworkTest -Test $tests -Configuration $config -Topology $topology
        $selection.Selected.Count
        $selection.Dropped | Format-Table Name, Filter, Reason
    .OUTPUTS
        A report object with a Selected and a Dropped collection.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyCollection()]
        [object[]]$Test,

        [Parameter()]
        [object]$Configuration,

        [Parameter()]
        [object]$Topology,

        [Parameter()]
        [string[]]$Customers,

        [Parameter()]
        [switch]$KeepDisabled
    )

    begin {
        $all = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Test) {
            if ($null -ne $item) { [void]$all.Add($item) }
        }
    }

    end {
        $selected = [System.Collections.Generic.List[object]]::new()
        $dropped = [System.Collections.Generic.List[object]]::new()

        $keywords = [string[]]@()
        $excludeKeywords = [string[]]@()
        $squads = [string[]]@()
        $excludeSquads = [string[]]@()
        $forceNonCentralized = $false

        if ($Configuration) {
            $keywordFilter = Resolve-QAFrameworkFilterList -Include $Configuration.keywords -Exclude $Configuration.excludeKeywords
            $squadFilter = Resolve-QAFrameworkFilterList -Include $Configuration.squads -Exclude $Configuration.excludeSquads

            $keywords = $keywordFilter.Include
            $excludeKeywords = $keywordFilter.Exclude
            $squads = $squadFilter.Include
            $excludeSquads = $squadFilter.Exclude
            $forceNonCentralized = [bool]$Configuration.forceRunNonCentralized
        }

        $clusterKnown = [bool]($Topology -and $Topology.IsClusterKnown)
        $isCentralized = [bool]($Topology -and $Topology.IsCentralized)
        $isRedGreen = [bool]($Topology -and $Topology.IsRedGreen)
        $hasFailover = [bool]($Topology -and $Topology.HasFailover)
        $dataMinerVersion = if ($Topology) { $Topology.DataMinerVersion } else { $null }
        $dbmsType = if ($Topology) { [string]$Topology.DbmsType } else { '' }

        $drop = {
            param([object]$Item, [string]$Filter, [string]$Reason)

            $dropped.Add([pscustomobject]@{
                    Name   = $Item.name
                    Filter = $Filter
                    Reason = $Reason
                    Test   = $Item
                })
        }

        foreach ($metadata in $all) {
            $testKeywords = [string[]]@($metadata.keywords)
            $testSquads = [string[]]@($metadata.squads)

            # 1. Disabled - only when a reason was supplied, exactly as the legacy attribute.
            $disabledReason = if ($metadata.disabled) { [string]$metadata.disabled.reason } else { '' }
            if (-not $KeepDisabled -and -not [string]::IsNullOrWhiteSpace($disabledReason)) {
                & $drop $metadata 'Disabled' "Test is disabled: $disabledReason"
                continue
            }

            # 2. NonCentralizedTest - cannot run on a centralized cluster.
            if ($clusterKnown -and $isCentralized -and $metadata.isNonCentralizedOnly -and -not $forceNonCentralized) {
                & $drop $metadata 'NonCentralizedTest' 'Test only runs on a non-centralized cluster.'
                continue
            }

            # 3. CentralizedTest - cannot run on a non-centralized cluster.
            if ($clusterKnown -and -not $isCentralized -and $metadata.isCentralizedOnly) {
                & $drop $metadata 'CentralizedTest' 'Test only runs on a centralized cluster.'
                continue
            }

            # 4. RedGreenTest - on a red/green cluster only red/green tests run.
            if ($clusterKnown -and $isRedGreen -and -not $metadata.isRedGreen) {
                & $drop $metadata 'RedGreenTest' 'Cluster is a red/green system and the test is not marked as a red/green test.'
                continue
            }

            # 5. Squads include.
            if ($squads.Count -gt 0 -and -not (Test-QAFrameworkListMatch -Value $testSquads -Filter $squads)) {
                & $drop $metadata 'Squads' "Test squads [$($testSquads -join ', ')] do not match the requested squads [$($squads -join ', ')]."
                continue
            }

            # 6. Squads exclude.
            if ($excludeSquads.Count -gt 0 -and (Test-QAFrameworkListMatch -Value $testSquads -Filter $excludeSquads)) {
                & $drop $metadata 'ExcludeSquads' "Test squads [$($testSquads -join ', ')] match an excluded squad."
                continue
            }

            # 7. MinVersion.
            if ($dataMinerVersion -and -not (Test-QAFrameworkVersionCompatible -DataMinerVersion $dataMinerVersion -Test $metadata)) {
                & $drop $metadata 'MinVersion' "Cluster version $dataMinerVersion does not satisfy the minimum version of the test."
                continue
            }

            # 8. LocalDB.
            if (-not (Test-QAFrameworkLocalDbCompatible -ClusterDbmsType $dbmsType -Test $metadata)) {
                & $drop $metadata 'LocalDB' "Test requires one of [$(@($metadata.localDbs) -join ', ')] but the cluster runs $dbmsType."
                continue
            }

            # 9. Keywords include.
            if ($keywords.Count -gt 0 -and -not (Test-QAFrameworkListMatch -Value $testKeywords -Filter $keywords)) {
                & $drop $metadata 'Keywords' "Test keywords [$($testKeywords -join ', ')] do not match the requested keywords [$($keywords -join ', ')]."
                continue
            }

            # 10. Keywords exclude.
            if ($excludeKeywords.Count -gt 0 -and (Test-QAFrameworkListMatch -Value $testKeywords -Filter $excludeKeywords)) {
                & $drop $metadata 'ExcludeKeywords' "Test keywords [$($testKeywords -join ', ')] match an excluded keyword."
                continue
            }

            # 11. Customers - a test without customers is not customer specific.
            if ($Customers -and $Customers.Count -gt 0) {
                $testCustomers = [string[]]@($metadata.customers)
                if ($testCustomers.Count -gt 0 -and -not (Test-QAFrameworkListMatch -Value $testCustomers -Filter $Customers)) {
                    & $drop $metadata 'Customers' "Test customers [$($testCustomers -join ', ')] do not match the requested customers [$($Customers -join ', ')]."
                    continue
                }
            }

            # 12. SolutionInfo - only enforced when the cluster reports solution versions.
            $solutionName = if ($metadata.solution) { [string]$metadata.solution.name } else { '' }
            if ($clusterKnown -and -not [string]::IsNullOrWhiteSpace($solutionName) -and $solutionName -ne 'None') {
                $solutionCheck = Test-QAFrameworkSolutionCompatible -SolutionVersions $Topology.SolutionVersions -Test $metadata
                if (-not $solutionCheck.IsCompatible) {
                    & $drop $metadata 'SolutionInfo' $solutionCheck.Reason
                    continue
                }
            }

            # 13. Failover availability.
            if ([string]::Equals([string]$metadata.fixture, 'Failover', [StringComparison]::OrdinalIgnoreCase)) {
                $runsOnNonFailover = [bool]($metadata.failover -and $metadata.failover.runOnNonFailoverSystems)
                if ($Configuration -and $Configuration.disableFailoverRun -and -not $runsOnNonFailover) {
                    & $drop $metadata 'Failover' 'Failover tests are disabled for this run.'
                    continue
                }
                if ($clusterKnown -and -not $hasFailover -and -not $runsOnNonFailover) {
                    & $drop $metadata 'Failover' 'Cluster has no failover pair and the test does not allow running on non-failover systems.'
                    continue
                }
            }

            # 14. TargetDMA feasibility.
            $targetDma = if ($metadata.targetDma) { [string]$metadata.targetDma } else { 'One' }
            if ($clusterKnown -and [string]::Equals($targetDma, 'AllFailovers', [StringComparison]::OrdinalIgnoreCase) -and -not $hasFailover) {
                & $drop $metadata 'TargetDMA' 'Test targets all failover agents but the cluster has no failover pair.'
                continue
            }

            $selected.Add($metadata)
        }

        return [pscustomobject]@{
            Selected = [object[]]$selected
            Dropped  = [object[]]$dropped
        }
    }
}

function Get-QAFrameworkRunConfiguration {
    <#
    .SYNOPSIS
        Builds the effective QAFramework run configuration.
    .DESCRIPTION
        Merges the configuration layers in the following precedence order, highest first:

          1. Explicit cmdlet parameters
          2. Test run labels coming from QAOps (Get-QAOpsTestRunContext)
          3. The supplementary file SupplementaryFiles/qaframework.overrides.json
          4. TestPackagePipeline/qaframework.config.json
          5. The built-in legacy defaults

        Labels are read from the test run context using the 'qaframework.' prefix, for
        example 'qaframework.keywords' or 'qaframework.maxTestsInCluster'. Label values
        are strings, so lists are comma separated and booleans accept true/false/1/0.
    .PARAMETER TestPackageContentPath
        Root of the test package content, used to locate the configuration files.
    .PARAMETER Keywords
        Only run tests carrying at least one of these keywords.
    .PARAMETER ExcludeKeywords
        Drop tests carrying any of these keywords.
    .PARAMETER Squads
        Only run tests owned by at least one of these squads.
    .PARAMETER ExcludeSquads
        Drop tests owned by any of these squads.
    .PARAMETER AgentCapacity
        Maximum summed test weight running on a single agent. Legacy default is 3.
    .PARAMETER MaxTestsInCluster
        Maximum number of tests running simultaneously in the whole cluster.
    .PARAMETER TestTimeoutSeconds
        Per-test maximum runtime. Legacy default is 7200 (2 hours).
    .PARAMETER SchedulerTickSeconds
        Interval between scheduler polls.
    .PARAMETER PreRunFilter
        'all', 'none' or a regular expression selecting which PreRun fixtures execute.
    .PARAMETER IncludeNonConcurrent
        Run the tests marked CanRunConcurrently(false) in their own exclusive phase.
    .PARAMETER DisableFailoverRun
        Skip the failover phases even when the cluster has failover pairs.
    .PARAMETER RerunFailedTests
        Re-queue failed tests once at the end of the run.
    .PARAMETER ForceRunNonCentralized
        Legacy force flag that keeps non-centralized tests on a centralized cluster.
    .PARAMETER LogCollectionOnFailure
        Trigger the log collector once, on the first failing agent.
    .PARAMETER RtManagerRoot
        Root folder of the RTManager settings on a DataMiner agent.
    .PARAMETER SkipTestRunContext
        Do not query QAOps for test run labels. Used by tests and by offline runs.
    .EXAMPLE
        Get-QAFrameworkRunConfiguration -TestPackageContentPath 'C:\QAOps\Content' -Keywords 'Alarming'
    .OUTPUTS
        PSCustomObject holding the effective configuration.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$TestPackageContentPath,

        [string[]]$Keywords,
        [string[]]$ExcludeKeywords,
        [string[]]$Squads,
        [string[]]$ExcludeSquads,

        [int]$AgentCapacity,
        [int]$MaxTestsInCluster,
        [int]$TestTimeoutSeconds,
        [int]$SchedulerTickSeconds,

        [string]$PreRunFilter,

        [bool]$IncludeNonConcurrent,
        [bool]$DisableFailoverRun,
        [bool]$RerunFailedTests,
        [bool]$ForceRunNonCentralized,
        [bool]$LogCollectionOnFailure,

        [string]$RtManagerRoot,

        [switch]$SkipTestRunContext
    )

    # Layer 5 - legacy defaults.
    $config = [ordered]@{
        agentCapacity          = 3
        maxTestsInCluster      = [int]::MaxValue
        testTimeoutSeconds     = 7200
        schedulerTickSeconds   = 10
        includeNonConcurrent   = $true
        disableFailoverRun     = $false
        preRunFilter           = 'all'
        rerunFailedTests       = $false
        forceRunNonCentralized = $false
        logCollectionOnFailure = $false
        rtManagerRoot          = 'C:\RTManager\'
        keywords               = [string[]]@()
        excludeKeywords        = [string[]]@()
        squads                 = [string[]]@()
        excludeSquads          = [string[]]@()
        systemSettings         = @{}
        sources                = [System.Collections.Generic.List[string]]::new()
    }

    $applyDocument = {
        param([object]$Document, [string]$Origin)

        if ($null -eq $Document) { return }

        $config['sources'].Add($Origin)

        foreach ($property in $Document.PSObject.Properties) {
            $key = $property.Name
            $value = $property.Value
            if ($null -eq $value) { continue }

            switch -Regex ($key) {
                '^filters$' {
                    # Nested filter block in the config file.
                    foreach ($filter in $value.PSObject.Properties) {
                        if ($null -ne $filter.Value) {
                            $config[$filter.Name] = [string[]]@($filter.Value)
                        }
                    }
                    continue
                }
                '^systemSettings$' {
                    $merged = @{}
                    foreach ($existing in $config['systemSettings'].Keys) { $merged[$existing] = $config['systemSettings'][$existing] }
                    foreach ($setting in $value.PSObject.Properties) { $merged[$setting.Name] = $setting.Value }
                    $config['systemSettings'] = $merged
                    continue
                }
                default {
                    $match = $config.Keys | Where-Object { $_ -eq $key } | Select-Object -First 1
                    if (-not $match) {
                        Write-Verbose "Ignoring unknown QAFramework configuration key '$key' from $Origin."
                        continue
                    }

                    $current = $config[$match]
                    if ($current -is [string[]]) { $config[$match] = [string[]]@($value) }
                    elseif ($current -is [bool]) { $config[$match] = [bool]$value }
                    elseif ($current -is [int]) { $config[$match] = [int]$value }
                    else { $config[$match] = $value }
                }
            }
        }
    }

    $readJson = {
        param([string]$Path)
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        try { return $raw | ConvertFrom-Json }
        catch { throw "QAFramework configuration file '$Path' is not valid JSON: $($_.Exception.Message)" }
    }

    if ($TestPackageContentPath) {
        # Layer 4 - package configuration file.
        $configPath = @(
            (Join-Path $TestPackageContentPath 'TestPackagePipeline\qaframework.config.json')
            (Join-Path $TestPackageContentPath 'qaframework.config.json')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        & $applyDocument (& $readJson $configPath) $configPath

        # Layer 3 - supplementary file override, shipped with the test run.
        $overridePath = @(
            (Join-Path $TestPackageContentPath 'SupplementaryFiles\qaframework.overrides.json')
            (Join-Path $TestPackageContentPath 'qaframework.overrides.json')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        & $applyDocument (& $readJson $overridePath) $overridePath
    }

    # Layer 2 - QAOps test run labels.
    if (-not $SkipTestRunContext) {
        $context = $null
        if (Get-Command -Name 'Get-QAOpsTestRunContext' -ErrorAction SilentlyContinue) {
            try { $context = Get-QAOpsTestRunContext }
            catch { Write-Verbose "Get-QAOpsTestRunContext failed: $($_.Exception.Message). Continuing without test run labels." }
        }

        if ($context -and $context.Labels) {
            $labelDocument = [ordered]@{}

            foreach ($entry in $context.Labels.GetEnumerator()) {
                if ($entry.Key -notmatch '^(?i:qaframework)\.(.+)$') { continue }
                $key = $Matches[1]

                $match = $config.Keys | Where-Object { $_ -eq $key } | Select-Object -First 1
                if (-not $match) {
                    Write-Verbose "Ignoring unknown QAFramework label 'qaframework.$key'."
                    continue
                }

                $current = $config[$match]
                $raw = [string]$entry.Value

                if ($current -is [string[]]) {
                    $labelDocument[$match] = [string[]]@($raw -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
                elseif ($current -is [bool]) {
                    $labelDocument[$match] = ($raw -match '^(?i:true|1|yes)$')
                }
                elseif ($current -is [int]) {
                    $parsed = 0
                    if ([int]::TryParse($raw, [ref]$parsed)) { $labelDocument[$match] = $parsed }
                }
                else {
                    $labelDocument[$match] = $raw
                }
            }

            if ($labelDocument.Count -gt 0) {
                & $applyDocument ([pscustomobject]$labelDocument) 'test run labels'
            }
        }
    }

    # Layer 1 - explicit parameters.
    $parameterMap = @{
        Keywords               = 'keywords'
        ExcludeKeywords        = 'excludeKeywords'
        Squads                 = 'squads'
        ExcludeSquads          = 'excludeSquads'
        AgentCapacity          = 'agentCapacity'
        MaxTestsInCluster      = 'maxTestsInCluster'
        TestTimeoutSeconds     = 'testTimeoutSeconds'
        SchedulerTickSeconds   = 'schedulerTickSeconds'
        PreRunFilter           = 'preRunFilter'
        IncludeNonConcurrent   = 'includeNonConcurrent'
        DisableFailoverRun     = 'disableFailoverRun'
        RerunFailedTests       = 'rerunFailedTests'
        ForceRunNonCentralized = 'forceRunNonCentralized'
        LogCollectionOnFailure = 'logCollectionOnFailure'
        RtManagerRoot          = 'rtManagerRoot'
    }

    $overrides = [ordered]@{}
    foreach ($parameter in $parameterMap.Keys) {
        if ($PSBoundParameters.ContainsKey($parameter)) {
            $overrides[$parameterMap[$parameter]] = $PSBoundParameters[$parameter]
        }
    }

    if ($overrides.Count -gt 0) {
        & $applyDocument ([pscustomobject]$overrides) 'parameters'
    }

    if ($config['agentCapacity'] -lt 1) { $config['agentCapacity'] = 1 }
    if ($config['maxTestsInCluster'] -lt 1) { $config['maxTestsInCluster'] = [int]::MaxValue }
    if ($config['testTimeoutSeconds'] -lt 1) { $config['testTimeoutSeconds'] = 7200 }
    if ($config['schedulerTickSeconds'] -lt 1) { $config['schedulerTickSeconds'] = 1 }
    if ([string]::IsNullOrWhiteSpace($config['preRunFilter'])) { $config['preRunFilter'] = 'all' }

    $config['sources'] = [string[]]@($config['sources'])

    return [pscustomobject]$config
}

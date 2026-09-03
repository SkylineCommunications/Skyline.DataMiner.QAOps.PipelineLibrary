function ConvertTo-QAFrameworkTestMetadata {
    <#
    .SYNOPSIS
        Normalises an arbitrary metadata record into the schema v1 test metadata shape.
    .DESCRIPTION
        Accepts records coming from qaframework.tests.json (schema v1) as well as the
        older testmetadata.generated.json shapes produced by the PlatformSmokeTests
        harvester (Name / DiagnosticRunType) and by TestPackageCreator (additionally
        noParallelGroup / isBaseline / keywords / squads).

        Every missing field is filled with the legacy default so that a package harvested
        by older tooling still runs: weight 1, canRunConcurrently true, targetDma One and
        fixture Standard.
    .PARAMETER InputObject
        A single metadata record (PSCustomObject or hashtable).
    .OUTPUTS
        PSCustomObject following schema v1.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object]$InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        if ($InputObject -is [System.Collections.IDictionary]) { $InputObject = [pscustomobject]$InputObject }

        # Reads the first property that exists, regardless of casing or naming vintage.
        $get = {
            param([string[]]$Names)
            foreach ($name in $Names) {
                $property = $InputObject.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
            }
            return $null
        }

        $toArray = {
            param([object]$Value)
            $values = [string[]]@()
            if ($null -ne $Value) {
                $values = [string[]]@($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            }
            # Comma operator keeps single-element arrays from being unrolled by the caller.
            , $values
        }

        $toBool = {
            param([object]$Value, [bool]$Default)
            if ($null -eq $Value) { return $Default }
            if ($Value -is [bool]) { return $Value }
            return ([string]$Value -match '^(?i:true|1|yes)$')
        }

        $name = [string](& $get @('name', 'Name', 'testName', 'TestName'))
        if ([string]::IsNullOrWhiteSpace($name)) { return }

        $fixture = [string](& $get @('fixture', 'Fixture'))
        $diagnosticRunType = [string](& $get @('diagnosticRunType', 'DiagnosticRunType'))

        # The legacy compat files only signal a diagnostic test through the run type.
        if ([string]::IsNullOrWhiteSpace($fixture)) {
            $fixture = if (-not [string]::IsNullOrWhiteSpace($diagnosticRunType)) { 'Diagnostic' } else { 'Standard' }
        }

        if ($fixture -eq 'Diagnostic' -and [string]::IsNullOrWhiteSpace($diagnosticRunType)) {
            $diagnosticRunType = 'BeforeAndAfter'
        }
        elseif ($fixture -ne 'Diagnostic') {
            $diagnosticRunType = $null
        }

        $failover = $null
        if ($fixture -eq 'Failover') {
            $raw = & $get @('failover', 'Failover')
            if ($null -eq $raw) { $raw = [pscustomobject]@{} }
            $failover = [pscustomobject]@{
                runDirectBeforeSwitch   = & $toBool $raw.runDirectBeforeSwitch $false
                runDirectAfterSwitch    = & $toBool $raw.runDirectAfterSwitch $false
                runOnNonFailoverSystems = & $toBool $raw.runOnNonFailoverSystems $false
                hasBeforeSwitch         = & $toBool $raw.hasBeforeSwitch $false
                hasAfterSwitch          = & $toBool $raw.hasAfterSwitch $false
                hasAfterSwitchBack      = & $toBool $raw.hasAfterSwitchBack $false
            }
        }

        $disabled = $null
        $rawDisabled = & $get @('disabled', 'Disabled')
        if ($null -ne $rawDisabled) {
            $reason = if ($rawDisabled -is [string]) { $rawDisabled } else { [string]$rawDisabled.reason }
            if (-not [string]::IsNullOrWhiteSpace($reason)) {
                $disabled = [pscustomobject]@{ reason = $reason }
            }
        }

        $weight = 1
        $rawWeight = & $get @('weight', 'Weight')
        if ($null -ne $rawWeight) {
            $parsed = 0
            if ([int]::TryParse([string]$rawWeight, [ref]$parsed)) {
                if ($parsed -le 0) { $parsed = 1 } elseif ($parsed -gt 3) { $parsed = 3 }
                $weight = $parsed
            }
        }

        # TestPackageCreator expressed "do not run me next to anything" as a noParallelGroup.
        $canRunConcurrently = & $toBool (& $get @('canRunConcurrently', 'CanRunConcurrently')) $true
        $noParallelGroup = & $get @('noParallelGroup', 'NoParallelGroup')
        if (-not [string]::IsNullOrWhiteSpace([string]$noParallelGroup)) { $canRunConcurrently = $false }

        $targetDma = [string](& $get @('targetDma', 'TargetDma', 'TargetDMA'))
        if ([string]::IsNullOrWhiteSpace($targetDma)) { $targetDma = 'One' }

        $rawMinVersion = & $get @('minVersion', 'MinVersion')
        $minVersion = [pscustomobject]@{
            featureRelease  = if ($rawMinVersion) { [string]$rawMinVersion.featureRelease } else { '' }
            nextMainRelease = if ($rawMinVersion) { [string]$rawMinVersion.nextMainRelease } else { '' }
            mainRelease     = if ($rawMinVersion) { [string]$rawMinVersion.mainRelease } else { '' }
        }

        $rawSolution = & $get @('solution', 'Solution')
        $solutionName = if ($rawSolution) { [string]$rawSolution.name } else { '' }
        if ([string]::IsNullOrWhiteSpace($solutionName)) { $solutionName = 'None' }
        $solutionMinVersion = if ($rawSolution) { [string]$rawSolution.minVersion } else { '' }
        if ([string]::IsNullOrWhiteSpace($solutionMinVersion)) { $solutionMinVersion = '0.0.0' }

        $rawSource = & $get @('source', 'Source')

        return [pscustomobject]@{
            name                 = $name
            fixture              = $fixture
            diagnosticRunType    = $diagnosticRunType
            failover             = $failover
            disabled             = $disabled
            weight               = $weight
            canRunConcurrently   = $canRunConcurrently
            targetDma            = $targetDma
            keywords             = & $toArray (& $get @('keywords', 'Keywords'))
            squads               = & $toArray (& $get @('squads', 'Squads', 'squad', 'Squad'))
            maintainers          = & $toArray (& $get @('maintainers', 'Maintainers'))
            customers            = & $toArray (& $get @('customers', 'Customers'))
            minVersion           = $minVersion
            localDbs             = & $toArray (& $get @('localDbs', 'LocalDbs', 'LocalDBs'))
            solution             = [pscustomobject]@{ name = $solutionName; minVersion = $solutionMinVersion }
            isCentralizedOnly    = & $toBool (& $get @('isCentralizedOnly', 'IsCentralizedOnly')) $false
            isNonCentralizedOnly = & $toBool (& $get @('isNonCentralizedOnly', 'IsNonCentralizedOnly')) $false
            isRedGreen           = & $toBool (& $get @('isRedGreen', 'IsRedGreen')) $false
            isBaseline           = & $toBool (& $get @('isBaseline', 'IsBaseline')) $false
            isLeakTest           = & $toBool (& $get @('isLeakTest', 'IsLeakTest')) $false
            dcpIds               = & $toArray (& $get @('dcpIds', 'DcpIds', 'DCPIDs'))
            rnIds                = & $toArray (& $get @('rnIds', 'RnIds', 'RNIDs'))
            projectIds           = & $toArray (& $get @('projectIds', 'ProjectIds', 'ProjectIDs'))
            source               = [pscustomobject]@{
                cs        = if ($rawSource) { $rawSource.cs } else { $null }
                meta      = if ($rawSource) { $rawSource.meta } else { $null }
                folderTag = if ($rawSource) { $rawSource.folderTag } else { $null }
            }
            dllReferences        = & $toArray (& $get @('dllReferences', 'DllReferences'))
        }
    }
}

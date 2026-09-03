function ConvertFrom-QAFrameworkAttributeBlock {
    <#
    .SYNOPSIS
        Converts a C# class attribute block into QAFramework test metadata.
    .DESCRIPTION
        Recognises every class-level attribute defined by QAManagement.TestFramework and
        returns a hashtable containing only the values that were actually specified. Keys
        that are absent mean "not specified", allowing .meta values and defaults to be
        layered in afterwards by New-QAFrameworkTestMetadata.

        Semantics mirror the legacy attribute constructors:
          TestFixture(testName)
          PreRunFixture(testName)
          FailoverTestFixture(testName, runDirectBeforeSwitch = false, runDirectAfterSwitch = false)
          DiagnosticTestFixture(testName[, DiagnosticRunType]) - default BeforeAndAfter
          Disabled(reason)          - only disables when the reason is not blank
          Weight(weight)            - clamped to 1..3
          CanRunConcurrently(bool)
          TargetDMA(RunOn)          - default One
          MinVersion(featureRelease, nextMainRelease = "", mainRelease = "")
          LocalDB(params DBMSType[])- empty list means every database is supported
          SolutionInfo(Solution, minSolutionVersion)
    .PARAMETER Block
        The raw attribute block text.
    .OUTPUTS
        Hashtable of specified metadata values.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Block
    )

    process {
        $result = @{}
        if ([string]::IsNullOrWhiteSpace($Block)) { return $result }

        foreach ($attribute in (Get-QAFrameworkAttribute -Text $Block)) {
            $map = ConvertTo-QAFrameworkAttributeArgumentMap -ArgumentText $attribute.ArgumentText
            $positional = $map.Positional
            $named = $map.Named

            switch ($attribute.Name) {
                'TestFixture' {
                    if (-not $result.ContainsKey('fixture')) { $result['fixture'] = 'Standard' }
                    if ($positional.Count -ge 1) { $result['name'] = [string]$positional[0] }
                }

                'PreRunFixture' {
                    $result['fixture'] = 'PreRun'
                    if ($positional.Count -ge 1) { $result['name'] = [string]$positional[0] }
                }

                'DiagnosticTestFixture' {
                    $result['fixture'] = 'Diagnostic'
                    if ($positional.Count -ge 1) { $result['name'] = [string]$positional[0] }
                    $runType = if ($positional.Count -ge 2) { [string]$positional[1] } else { 'BeforeAndAfter' }
                    if ($named.ContainsKey('runType')) { $runType = [string]$named['runType'] }
                    $result['diagnosticRunType'] = $runType
                }

                'FailoverTestFixture' {
                    $result['fixture'] = 'Failover'
                    if ($positional.Count -ge 1) { $result['name'] = [string]$positional[0] }

                    $failover = @{
                        runDirectBeforeSwitch   = $false
                        runDirectAfterSwitch    = $false
                        runOnNonFailoverSystems = $false
                    }
                    if ($positional.Count -ge 2) { $failover['runDirectBeforeSwitch'] = [bool]$positional[1] }
                    if ($positional.Count -ge 3) { $failover['runDirectAfterSwitch'] = [bool]$positional[2] }
                    if ($named.ContainsKey('runDirectBeforeSwitch')) { $failover['runDirectBeforeSwitch'] = [bool]$named['runDirectBeforeSwitch'] }
                    if ($named.ContainsKey('runDirectAfterSwitch')) { $failover['runDirectAfterSwitch'] = [bool]$named['runDirectAfterSwitch'] }
                    if ($named.ContainsKey('RunOnNonFailoverSystems')) { $failover['runOnNonFailoverSystems'] = [bool]$named['RunOnNonFailoverSystems'] }

                    $result['failover'] = $failover
                }

                'Disabled' {
                    $reason = if ($positional.Count -ge 1) { [string]$positional[0] } else { '' }
                    # A blank reason is invalid: the legacy runner executes the test anyway.
                    if (-not [string]::IsNullOrWhiteSpace($reason)) {
                        $result['disabled'] = @{ reason = $reason }
                    }
                }

                'Weight' {
                    $weight = if ($positional.Count -ge 1) { $positional[0] } else { 1 }
                    if ($weight -isnot [int]) { $weight = 1 }
                    if ($weight -le 0) { $weight = 1 }
                    elseif ($weight -gt 3) { $weight = 3 }
                    $result['weight'] = [int]$weight
                }

                'CanRunConcurrently' {
                    if ($positional.Count -ge 1 -and $positional[0] -is [bool]) {
                        $result['canRunConcurrently'] = [bool]$positional[0]
                    }
                }

                'TargetDMA' {
                    $result['targetDma'] = if ($positional.Count -ge 1) { [string]$positional[0] } else { 'One' }
                }

                'MinVersion' {
                    $result['minVersion'] = @{
                        featureRelease  = if ($positional.Count -ge 1) { [string]$positional[0] } else { '' }
                        nextMainRelease = if ($positional.Count -ge 2) { [string]$positional[1] } else { '' }
                        mainRelease     = if ($positional.Count -ge 3) { [string]$positional[2] } else { '' }
                    }
                }

                'LocalDB' {
                    # No arguments means the test supports every local database.
                    $result['localDbs'] = [string[]]@($positional | ForEach-Object { [string]$_ })
                }

                'SolutionInfo' {
                    $result['solution'] = @{
                        name       = if ($positional.Count -ge 1) { [string]$positional[0] } else { 'None' }
                        minVersion = if ($positional.Count -ge 2) { [string]$positional[1] } else { '0.0.0' }
                    }
                }

                'Keywords'    { $result['keywords'] = [string[]]@($positional | ForEach-Object { [string]$_ }) }
                'Squad'       { $result['squads'] = [string[]]@($positional | ForEach-Object { [string]$_ }) }
                'Maintainers' { $result['maintainers'] = [string[]]@($positional | ForEach-Object { [string]$_ }) }
                'Customers'   { $result['customers'] = [string[]]@($positional | ForEach-Object { [string]$_ }) }
                'DCPIDS'      { $result['dcpIds'] = [string[]]@($positional | ForEach-Object { [string]$_ }) }
                'RNIDS'       { $result['rnIds'] = [string[]]@($positional | ForEach-Object { [string]$_ }) }
                'ProjectID'   { $result['projectIds'] = [string[]]@($positional | ForEach-Object { [string]$_ }) }

                'NonCentralizedTest' { $result['isNonCentralizedOnly'] = $true }
                'CentralizedTest'    { $result['isCentralizedOnly'] = $true }
                'RedGreenTest'       { $result['isRedGreen'] = $true }
                'BaselineTest'       { $result['isBaseline'] = $true }
                'LeakTest'           { $result['isLeakTest'] = $true }
            }
        }

        return $result
    }
}

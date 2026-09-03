BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'Skyline.DataMiner.QAOps.PipelineLibrary.psd1') -Force

    function New-TestMetadata {
        param([hashtable]$Override = @{})

        $test = @{
            name                 = 'RT_Sample'
            fixture              = 'Standard'
            diagnosticRunType    = $null
            failover             = $null
            disabled             = $null
            weight               = 1
            canRunConcurrently   = $true
            targetDma            = 'One'
            keywords             = [string[]]@()
            squads               = [string[]]@()
            maintainers          = [string[]]@()
            customers            = [string[]]@()
            minVersion           = [pscustomobject]@{ featureRelease = ''; nextMainRelease = ''; mainRelease = '' }
            localDbs             = [string[]]@()
            solution             = [pscustomobject]@{ name = 'None'; minVersion = '' }
            isCentralizedOnly    = $false
            isNonCentralizedOnly = $false
            isRedGreen           = $false
            isBaseline           = $false
            isLeakTest           = $false
        }

        foreach ($key in $Override.Keys) { $test[$key] = $Override[$key] }
        return [pscustomobject]$test
    }

    function New-Topology {
        param([hashtable]$Override = @{})

        $topology = @{
            Name             = 'cluster'
            Agents           = @()
            FailoverPairs    = @()
            HasFailover      = $false
            LowestDmaId      = 1
            HighestDmaId     = 2
            DataMinerVersion = $null
            DbmsType         = ''
            IsCentralized    = $false
            IsRedGreen       = $false
            Labels           = @{}
            SolutionVersions = @{}
            IsClusterKnown   = $true
        }

        foreach ($key in $Override.Keys) { $topology[$key] = $Override[$key] }
        return [pscustomobject]$topology
    }

    function New-Configuration {
        param([hashtable]$Override = @{})

        $config = @{
            keywords               = [string[]]@()
            excludeKeywords        = [string[]]@()
            squads                 = [string[]]@()
            excludeSquads          = [string[]]@()
            forceRunNonCentralized = $false
            disableFailoverRun     = $false
        }

        foreach ($key in $Override.Keys) { $config[$key] = $Override[$key] }
        return [pscustomobject]$config
    }
}

Describe 'Select-QAFrameworkTest' {

    Context 'disabled tests' {
        It 'drops a test that carries a reason' {
            $test = New-TestMetadata @{ disabled = [pscustomobject]@{ reason = 'flaky on build agents' } }
            $result = Select-QAFrameworkTest -Test $test

            $result.Selected.Count | Should -Be 0
            $result.Dropped[0].Filter | Should -Be 'Disabled'
            $result.Dropped[0].Reason | Should -BeLike '*flaky on build agents*'
        }

        It 'keeps a test whose disabled reason is blank, as the legacy attribute does' {
            $test = New-TestMetadata @{ disabled = [pscustomobject]@{ reason = '   ' } }
            (Select-QAFrameworkTest -Test $test).Selected.Count | Should -Be 1
        }

        It 'keeps disabled tests when asked to' {
            $test = New-TestMetadata @{ disabled = [pscustomobject]@{ reason = 'nope' } }
            (Select-QAFrameworkTest -Test $test -KeepDisabled).Selected.Count | Should -Be 1
        }
    }

    Context 'centralized and red/green clusters' {
        It 'drops a non-centralized test on a centralized cluster' {
            $test = New-TestMetadata @{ isNonCentralizedOnly = $true }
            $result = Select-QAFrameworkTest -Test $test -Topology (New-Topology @{ IsCentralized = $true })

            $result.Dropped[0].Filter | Should -Be 'NonCentralizedTest'
        }

        It 'keeps a non-centralized test when the run forces it' {
            $test = New-TestMetadata @{ isNonCentralizedOnly = $true }
            $config = New-Configuration @{ forceRunNonCentralized = $true }
            $result = Select-QAFrameworkTest -Test $test -Topology (New-Topology @{ IsCentralized = $true }) -Configuration $config

            $result.Selected.Count | Should -Be 1
        }

        It 'drops a centralized test on a non-centralized cluster' {
            $test = New-TestMetadata @{ isCentralizedOnly = $true }
            $result = Select-QAFrameworkTest -Test $test -Topology (New-Topology)

            $result.Dropped[0].Filter | Should -Be 'CentralizedTest'
        }

        It 'keeps only red/green tests on a red/green cluster' {
            $tests = @(
                (New-TestMetadata @{ name = 'RT_Normal' }),
                (New-TestMetadata @{ name = 'RT_RedGreen'; isRedGreen = $true })
            )
            $result = Select-QAFrameworkTest -Test $tests -Topology (New-Topology @{ IsRedGreen = $true })

            $result.Selected.Count | Should -Be 1
            $result.Selected[0].name | Should -Be 'RT_RedGreen'
            $result.Dropped[0].Filter | Should -Be 'RedGreenTest'
        }

        It 'ignores cluster filters when the cluster is unknown' {
            $test = New-TestMetadata @{ isCentralizedOnly = $true }
            (Select-QAFrameworkTest -Test $test).Selected.Count | Should -Be 1
        }
    }

    Context 'keyword and squad filters' {
        It 'keeps only tests that carry a requested keyword' {
            $tests = @(
                (New-TestMetadata @{ name = 'RT_A'; keywords = [string[]]@('Alarming') }),
                (New-TestMetadata @{ name = 'RT_B'; keywords = [string[]]@('Trending') })
            )
            $result = Select-QAFrameworkTest -Test $tests -Configuration (New-Configuration @{ keywords = [string[]]@('alarming') })

            $result.Selected.Count | Should -Be 1
            $result.Selected[0].name | Should -Be 'RT_A'
        }

        It 'treats a bang prefixed keyword as an exclusion' {
            $tests = @(
                (New-TestMetadata @{ name = 'RT_A'; keywords = [string[]]@('Alarming') }),
                (New-TestMetadata @{ name = 'RT_B'; keywords = [string[]]@('Trending') })
            )
            $result = Select-QAFrameworkTest -Test $tests -Configuration (New-Configuration @{ keywords = [string[]]@('!Alarming') })

            $result.Selected.Count | Should -Be 1
            $result.Selected[0].name | Should -Be 'RT_B'
            $result.Dropped[0].Filter | Should -Be 'ExcludeKeywords'
        }

        It 'applies the squad filter before the keyword filter' {
            $test = New-TestMetadata @{ squads = [string[]]@('SquadA'); keywords = [string[]]@('Alarming') }
            $config = New-Configuration @{ squads = [string[]]@('SquadB'); keywords = [string[]]@('Trending') }
            $result = Select-QAFrameworkTest -Test $test -Configuration $config

            $result.Dropped[0].Filter | Should -Be 'Squads'
        }

        It 'drops a test that belongs to an excluded squad' {
            $test = New-TestMetadata @{ squads = [string[]]@('SquadA') }
            $result = Select-QAFrameworkTest -Test $test -Configuration (New-Configuration @{ excludeSquads = [string[]]@('squada') })

            $result.Dropped[0].Filter | Should -Be 'ExcludeSquads'
        }
    }

    Context 'version and database gates' {
        It 'drops a test that needs a newer feature release' {
            $test = New-TestMetadata @{ minVersion = [pscustomobject]@{ featureRelease = '10.3.5.0-CU0'; nextMainRelease = ''; mainRelease = '' } }
            $result = Select-QAFrameworkTest -Test $test -Topology (New-Topology @{ DataMinerVersion = [version]'10.3.2.0' })

            $result.Dropped[0].Filter | Should -Be 'MinVersion'
        }

        It 'keeps a test whose database is used by the cluster' {
            $test = New-TestMetadata @{ localDbs = [string[]]@('MySQL', 'Cassandra') }
            (Select-QAFrameworkTest -Test $test -Topology (New-Topology @{ DbmsType = 'cassandra' })).Selected.Count | Should -Be 1
        }

        It 'drops a test whose database is not used by the cluster' {
            $test = New-TestMetadata @{ localDbs = [string[]]@('MySQL') }
            $result = Select-QAFrameworkTest -Test $test -Topology (New-Topology @{ DbmsType = 'Cassandra' })

            $result.Dropped[0].Filter | Should -Be 'LocalDB'
        }
    }

    Context 'solution gate' {
        It 'drops a test whose solution is not installed' {
            $test = New-TestMetadata @{ solution = [pscustomobject]@{ name = 'SRM'; minVersion = '' } }
            $topology = New-Topology @{ SolutionVersions = @{ IDP = '1.0.0' } }
            $result = Select-QAFrameworkTest -Test $test -Topology $topology

            $result.Dropped[0].Filter | Should -Be 'SolutionInfo'
            $result.Dropped[0].Reason | Should -BeLike "*not installed*"
        }

        It 'drops a test that needs a newer solution version' {
            $test = New-TestMetadata @{ solution = [pscustomobject]@{ name = 'IDP'; minVersion = '2.0.0' } }
            $topology = New-Topology @{ SolutionVersions = @{ IDP = '1.5.0' } }

            (Select-QAFrameworkTest -Test $test -Topology $topology).Dropped[0].Filter | Should -Be 'SolutionInfo'
        }

        It 'keeps the test when the cluster does not report solutions' {
            $test = New-TestMetadata @{ solution = [pscustomobject]@{ name = 'IDP'; minVersion = '2.0.0' } }
            (Select-QAFrameworkTest -Test $test -Topology (New-Topology)).Selected.Count | Should -Be 1
        }
    }

    Context 'failover and TargetDMA feasibility' {
        It 'drops a failover test on a cluster without failover pairs' {
            $test = New-TestMetadata @{ fixture = 'Failover'; failover = [pscustomobject]@{ runOnNonFailoverSystems = $false } }
            $result = Select-QAFrameworkTest -Test $test -Topology (New-Topology)

            $result.Dropped[0].Filter | Should -Be 'Failover'
        }

        It 'keeps a failover test that may run on non-failover systems' {
            $test = New-TestMetadata @{ fixture = 'Failover'; failover = [pscustomobject]@{ runOnNonFailoverSystems = $true } }
            (Select-QAFrameworkTest -Test $test -Topology (New-Topology)).Selected.Count | Should -Be 1
        }

        It 'drops failover tests when the run configuration disables them' {
            $test = New-TestMetadata @{ fixture = 'Failover'; failover = [pscustomobject]@{ runOnNonFailoverSystems = $false } }
            $topology = New-Topology @{ HasFailover = $true }
            $config = New-Configuration @{ disableFailoverRun = $true }

            (Select-QAFrameworkTest -Test $test -Topology $topology -Configuration $config).Dropped[0].Filter | Should -Be 'Failover'
        }

        It 'drops an AllFailovers test on a cluster without failover pairs' {
            $test = New-TestMetadata @{ targetDma = 'AllFailovers' }
            (Select-QAFrameworkTest -Test $test -Topology (New-Topology)).Dropped[0].Filter | Should -Be 'TargetDMA'
        }
    }

    Context 'customer filter' {
        It 'keeps tests without customers' {
            (Select-QAFrameworkTest -Test (New-TestMetadata) -Customers 'ACME').Selected.Count | Should -Be 1
        }

        It 'drops a test of another customer' {
            $test = New-TestMetadata @{ customers = [string[]]@('Globex') }
            (Select-QAFrameworkTest -Test $test -Customers 'ACME').Dropped[0].Filter | Should -Be 'Customers'
        }
    }

    Context 'general behaviour' {
        It 'accepts input from the pipeline' {
            $tests = @((New-TestMetadata @{ name = 'RT_A' }), (New-TestMetadata @{ name = 'RT_B' }))
            ($tests | Select-QAFrameworkTest).Selected.Count | Should -Be 2
        }

        It 'returns empty collections for an empty input' {
            $result = Select-QAFrameworkTest -Test @()

            $result.Selected.Count | Should -Be 0
            $result.Dropped.Count | Should -Be 0
        }

        It 'keeps the original metadata object on the dropped entry' {
            $test = New-TestMetadata @{ name = 'RT_Gone'; disabled = [pscustomobject]@{ reason = 'x' } }
            (Select-QAFrameworkTest -Test $test).Dropped[0].Test.name | Should -Be 'RT_Gone'
        }
    }
}

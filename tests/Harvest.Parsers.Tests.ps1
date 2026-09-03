BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Get-ChildItem (Join-Path $script:RepoRoot 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }

    $script:Fixtures = Join-Path $PSScriptRoot 'Fixtures\RegressionTests'
}

Describe 'Split-QAFrameworkAttributeArgument' {
    It 'splits on top level commas only' {
        $result = Split-QAFrameworkAttributeArgument -ArgumentText '"a", 1, true'
        $result.Count | Should -Be 3
    }

    It 'keeps commas inside string literals together' {
        $result = Split-QAFrameworkAttributeArgument -ArgumentText '"Customer, With Comma", "Second"'
        $result.Count | Should -Be 2
        $result[0].Trim() | Should -Be '"Customer, With Comma"'
    }

    It 'keeps nested collection initialisers together' {
        $result = Split-QAFrameworkAttributeArgument -ArgumentText 'new[] { 1, 2, 3 }, "x"'
        $result.Count | Should -Be 2
    }

    It 'returns nothing for empty input' {
        @(Split-QAFrameworkAttributeArgument -ArgumentText '').Count | Should -Be 0
    }
}

Describe 'ConvertFrom-QAFrameworkAttributeValue' {
    It 'unescapes regular string literals' {
        ConvertFrom-QAFrameworkAttributeValue -Expression '"a\tb"' | Should -Be "a`tb"
    }

    It 'handles verbatim string literals' {
        ConvertFrom-QAFrameworkAttributeValue -Expression '@"C:\Temp"' | Should -Be 'C:\Temp'
    }

    It 'strips the enum type prefix' {
        ConvertFrom-QAFrameworkAttributeValue -Expression 'RunOn.All' | Should -Be 'All'
        ConvertFrom-QAFrameworkAttributeValue -Expression 'DiagnosticRunType.Before' | Should -Be 'Before'
    }

    It 'converts booleans and integers' {
        ConvertFrom-QAFrameworkAttributeValue -Expression 'true' | Should -BeOfType [bool]
        ConvertFrom-QAFrameworkAttributeValue -Expression '42' | Should -Be 42
    }
}

Describe 'ConvertTo-QAFrameworkAttributeArgumentMap' {
    It 'separates positional from named arguments' {
        $map = ConvertTo-QAFrameworkAttributeArgumentMap -ArgumentText '"Name", true, RunOnNonFailoverSystems = true'
        $map.Positional.Count | Should -Be 2
        $map.Named['RunOnNonFailoverSystems'] | Should -BeTrue
    }

    It 'supports C# named argument syntax' {
        $map = ConvertTo-QAFrameworkAttributeArgumentMap -ArgumentText '"Name", runDirectAfterSwitch: true'
        $map.Positional.Count | Should -Be 1
        $map.Named['runDirectAfterSwitch'] | Should -BeTrue
    }
}

Describe 'Get-QAFrameworkAttribute' {
    It 'expands grouped attributes' {
        $attributes = @(Get-QAFrameworkAttribute -Text '[BaselineTest, CentralizedTest]')
        $attributes.Name | Should -Be @('BaselineTest', 'CentralizedTest')
    }

    It 'ignores an attribute target prefix' {
        $attributes = @(Get-QAFrameworkAttribute -Text '[method: Order(1)]')
        $attributes[0].Name | Should -Be 'Order'
    }

    It 'strips the Attribute suffix and namespace qualifier' {
        $attributes = @(Get-QAFrameworkAttribute -Text '[QAManagement.TestFramework.Attributes.DisabledAttribute("x")]')
        $attributes[0].Name | Should -Be 'Disabled'
    }
}

Describe 'Get-QAFrameworkClassAttributeBlock' {
    It 'captures a multi-line attribute' {
        $block = Get-QAFrameworkClassAttributeBlock -Path (Join-Path $script:Fixtures 'TeamA\RT_Failover\RT_Failover.cs')
        $block | Should -Match 'FailoverTestFixture'
        $block | Should -Match 'RunOnNonFailoverSystems'
        $block | Should -Match 'Weight\(5\)'
    }

    It 'returns an empty string when the class does not exist' {
        Get-QAFrameworkClassAttributeBlock -Content 'namespace X { }' -ClassName 'Nope' | Should -Be ''
    }
}

Describe 'ConvertFrom-QAFrameworkAttributeBlock' {
    It 'ignores Disabled when the reason is blank' {
        $result = ConvertFrom-QAFrameworkAttributeBlock -Block '[TestFixture("T")][Disabled("")]'
        $result.ContainsKey('disabled') | Should -BeFalse
    }

    It 'honours Disabled when a reason is supplied' {
        $result = ConvertFrom-QAFrameworkAttributeBlock -Block '[TestFixture("T")][Disabled("broken")]'
        $result['disabled'].reason | Should -Be 'broken'
    }

    It 'clamps the weight to the 1..3 agent capacity range' {
        (ConvertFrom-QAFrameworkAttributeBlock -Block '[Weight(5)]')['weight'] | Should -Be 3
        (ConvertFrom-QAFrameworkAttributeBlock -Block '[Weight(0)]')['weight'] | Should -Be 1
    }

    It 'reads the test name from the first positional argument of every fixture' {
        (ConvertFrom-QAFrameworkAttributeBlock -Block '[PreRunFixture("A")]')['name'] | Should -Be 'A'
        (ConvertFrom-QAFrameworkAttributeBlock -Block '[DiagnosticTestFixture("B")]')['name'] | Should -Be 'B'
        (ConvertFrom-QAFrameworkAttributeBlock -Block '[FailoverTestFixture("C")]')['name'] | Should -Be 'C'
    }

    It 'defaults the diagnostic run type to BeforeAndAfter' {
        (ConvertFrom-QAFrameworkAttributeBlock -Block '[DiagnosticTestFixture("B")]')['diagnosticRunType'] | Should -Be 'BeforeAndAfter'
    }

    It 'reads failover switch booleans from positions one and two' {
        $failover = (ConvertFrom-QAFrameworkAttributeBlock -Block '[FailoverTestFixture("C", false, true)]')['failover']
        $failover['runDirectBeforeSwitch'] | Should -BeFalse
        $failover['runDirectAfterSwitch'] | Should -BeTrue
    }

    It 'treats an argument-less LocalDB as supporting every database' {
        (ConvertFrom-QAFrameworkAttributeBlock -Block '[LocalDB]')['localDbs'].Count | Should -Be 0
    }
}

Describe 'Get-QAFrameworkMethodAttributeFlag' {
    It 'detects failover switch methods' {
        $flags = Get-QAFrameworkMethodAttributeFlag -Path (Join-Path $script:Fixtures 'TeamA\RT_Failover\RT_Failover.cs')
        $flags['hasBeforeSwitch'] | Should -BeTrue
        $flags['hasAfterSwitch'] | Should -BeTrue
        $flags['hasAfterSwitchBack'] | Should -BeFalse
    }

    It 'does not confuse AfterSwitchReInit with AfterSwitch' {
        $flags = Get-QAFrameworkMethodAttributeFlag -Content "    [AfterSwitchReInit]`r`n    public void X() { }"
        $flags['hasAfterSwitch'] | Should -BeFalse
    }
}

Describe 'ConvertFrom-QAFrameworkMetaFile' {
    BeforeAll {
        $script:Meta = ConvertFrom-QAFrameworkMetaFile -Path (Join-Path $script:Fixtures 'TeamB\RT_LegacyMeta\RT_LegacyMeta.meta')
    }

    It 'reads the DLL references' {
        $script:Meta['dllReferences'].Count | Should -Be 2
    }

    It 'reads squads, customers, DCP IDs and RN IDs' {
        $script:Meta['squads'] | Should -Contain 'LegacySquad'
        $script:Meta['customers'] | Should -Contain 'LegacyCustomer'
        $script:Meta['dcpIds'] | Should -Contain 'DCP9999'
        $script:Meta['rnIds'] | Should -Contain 'RN4242'
    }

    It 'reads the baseline flag' {
        $script:Meta['isBaseline'] | Should -BeTrue
    }

    It 'returns an empty result for a missing file' {
        (ConvertFrom-QAFrameworkMetaFile -Path 'X:\does\not\exist.meta').Count | Should -Be 0
    }
}

Describe 'New-QAFrameworkTestMetadata' {
    Context 'test with the full attribute set' {
        BeforeAll {
            $script:Full = New-QAFrameworkTestMetadata `
                -CsPath (Join-Path $script:Fixtures 'TeamA\RT_Full\RT_Full.cs') `
                -MetaPath (Join-Path $script:Fixtures 'TeamA\RT_Full\RT_Full.meta') `
                -RegressionTestsRoot $script:Fixtures
        }

        It 'uses the fixture name' { $script:Full.name | Should -Be 'RT_Full' }
        It 'keeps the clamped weight' { $script:Full.weight | Should -Be 2 }
        It 'reads CanRunConcurrently' { $script:Full.canRunConcurrently | Should -BeFalse }
        It 'reads TargetDMA' { $script:Full.targetDma | Should -Be 'All' }
        It 'keeps commas inside a customer name' { $script:Full.customers | Should -Contain 'Customer, With Comma' }
        It 'reads the min version triplet' {
            $script:Full.minVersion.featureRelease | Should -Be '10.1.0.0-CU5'
            $script:Full.minVersion.nextMainRelease | Should -Be '10.2.0.0'
            $script:Full.minVersion.mainRelease | Should -Be '10.3.0.0'
        }
        It 'reads the solution info' {
            $script:Full.solution.name | Should -Be 'SRM'
            $script:Full.solution.minVersion | Should -Be '1.2.3'
        }
        It 'reads the marker attributes' {
            $script:Full.isRedGreen | Should -BeTrue
            $script:Full.isBaseline | Should -BeTrue
            $script:Full.isCentralizedOnly | Should -BeTrue
        }
        It 'ignores a Disabled attribute without a reason' { $script:Full.disabled | Should -BeNullOrEmpty }
        It 'lets attribute values win over meta values' { $script:Full.maintainers | Should -Be @('jdoe') }
        It 'falls back to meta values for gaps' { $script:Full.dllReferences.Count | Should -Be 1 }
        It 'stores relative source paths' { $script:Full.source.cs | Should -Be 'TeamA\RT_Full\RT_Full.cs' }
    }

    Context 'failover test' {
        BeforeAll {
            $script:Failover = New-QAFrameworkTestMetadata -CsPath (Join-Path $script:Fixtures 'TeamA\RT_Failover\RT_Failover.cs')
        }

        It 'is recognised as a failover fixture' { $script:Failover.fixture | Should -Be 'Failover' }
        It 'reads the positional switch booleans' {
            $script:Failover.failover.runDirectBeforeSwitch | Should -BeTrue
            $script:Failover.failover.runDirectAfterSwitch | Should -BeFalse
        }
        It 'reads the named RunOnNonFailoverSystems field' { $script:Failover.failover.runOnNonFailoverSystems | Should -BeTrue }
        It 'merges the method level switch flags' {
            $script:Failover.failover.hasBeforeSwitch | Should -BeTrue
            $script:Failover.failover.hasAfterSwitch | Should -BeTrue
            $script:Failover.failover.hasAfterSwitchBack | Should -BeFalse
        }
    }

    Context 'diagnostic test' {
        BeforeAll {
            $script:Diagnostic = New-QAFrameworkTestMetadata -CsPath (Join-Path $script:Fixtures 'TeamB\RT_Diagnostic\RT_Diagnostic.cs')
        }

        It 'is recognised as a diagnostic fixture' { $script:Diagnostic.fixture | Should -Be 'Diagnostic' }
        It 'reads the run type' { $script:Diagnostic.diagnosticRunType | Should -Be 'Before' }
        It 'reads NonCentralizedTest' { $script:Diagnostic.isNonCentralizedOnly | Should -BeTrue }
        It 'treats an empty LocalDB as all databases' { $script:Diagnostic.localDbs.Count | Should -Be 0 }
    }

    Context 'prerun test that is disabled' {
        BeforeAll {
            $script:PreRun = New-QAFrameworkTestMetadata -CsPath (Join-Path $script:Fixtures 'TeamB\RT_DisabledNoReason\RT_DisabledNoReason.cs')
        }

        It 'is recognised as a prerun fixture' { $script:PreRun.fixture | Should -Be 'PreRun' }
        It 'carries the disable reason' { $script:PreRun.disabled.reason | Should -Match 'DCP1234' }
    }

    Context 'legacy meta only test' {
        BeforeAll {
            $script:Legacy = New-QAFrameworkTestMetadata -MetaPath (Join-Path $script:Fixtures 'TeamB\RT_LegacyMeta\RT_LegacyMeta.meta')
        }

        It 'derives the name from the file' { $script:Legacy.name | Should -Be 'RT_LegacyMeta' }
        It 'defaults to a standard fixture' { $script:Legacy.fixture | Should -Be 'Standard' }
        It 'reads the weight from the meta file' { $script:Legacy.weight | Should -Be 3 }
        It 'reads concurrency from the meta file' { $script:Legacy.canRunConcurrently | Should -BeFalse }
        It 'defaults TargetDMA to One' { $script:Legacy.targetDma | Should -Be 'One' }
    }
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Get-ChildItem (Join-Path $script:RepoRoot 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }

    function New-TestStub {
        param($Feature = '', $Main = '', $NextMain = '', $LocalDbs = @())
        [pscustomobject]@{
            name       = 'RT_Stub'
            minVersion = [pscustomobject]@{ featureRelease = $Feature; mainRelease = $Main; nextMainRelease = $NextMain }
            localDbs   = [string[]]@($LocalDbs)
        }
    }
}

Describe 'ConvertTo-QAFrameworkVersion' {
    It 'turns the CU number into the revision' {
        ConvertTo-QAFrameworkVersion -Version '10.1.0.0-CU5' | Should -Be ([version]'10.1.0.5')
    }

    It 'is case insensitive on the CU marker' {
        ConvertTo-QAFrameworkVersion -Version '10.0.12.0-cu3' | Should -Be ([version]'10.0.12.3')
    }

    It 'throws on a malformed version' -ForEach @(
        @{ Value = 'RandomString' }
        @{ Value = 'RandomString-Same-Format' }
        @{ Value = '12231-Same-CU12' }
        @{ Value = '10.1.2.0-5649-0' }
        @{ Value = '' }
    ) {
        { ConvertTo-QAFrameworkVersion -Version $Value } | Should -Throw
    }
}

Describe 'Test-QAFrameworkIsMainRelease' {
    It 'treats a zero build number as a main release' {
        Test-QAFrameworkIsMainRelease -DataMinerVersion ([version]'10.5.0.0') | Should -BeTrue
        Test-QAFrameworkIsMainRelease -DataMinerVersion ([version]'10.5.13.0') | Should -BeFalse
    }
}

Describe 'Test-QAFrameworkFeatureReleaseCompatible' {
    # Ported from UnitTest_TestRunnerTypes TestFilterTests.FeatureReleaseCompatible.
    It 'matches the legacy result for <DataMiner> / <Minimum>' -ForEach @(
        @{ DataMiner = '10.0.13.0'; Minimum = '9.6.10.0-CU1';  Expected = $true }
        @{ DataMiner = '10.0.13.0'; Minimum = '9.5.12.0-CU0';  Expected = $true }
        @{ DataMiner = '10.0.13.0'; Minimum = '10.0.13.0-CU0'; Expected = $true }
        @{ DataMiner = '10.0.13.1'; Minimum = '10.0.13.0-CU1'; Expected = $true }
        @{ DataMiner = '10.1.5.0';  Minimum = '10.1.12.0-CU0'; Expected = $false }
        @{ DataMiner = '10.1.13.0'; Minimum = '10.0.12.0-CU0'; Expected = $true }
        @{ DataMiner = '10.1.13.0'; Minimum = '10.1.13.0-CU0'; Expected = $true }
        @{ DataMiner = '10.0.13.0'; Minimum = '10.1.0.0-cu0';  Expected = $false }
        @{ DataMiner = '10.0.1.0';  Minimum = '10.0.12.0-cu0'; Expected = $false }
        @{ DataMiner = '9.6.13.1';  Minimum = '10.0.12.0-cu0'; Expected = $false }
        @{ DataMiner = '10.1.10.0'; Minimum = '10.0.12.0-cu0'; Expected = $true }
        @{ DataMiner = '10.0.13.0'; Minimum = '10.1.12.0-cu0'; Expected = $false }
        @{ DataMiner = '10.0.13.0'; Minimum = '';              Expected = $true }
        @{ DataMiner = '10.5.13.0'; Minimum = $null;           Expected = $true }
    ) {
        Test-QAFrameworkFeatureReleaseCompatible -DataMinerVersion ([version]$DataMiner) -MinimalFeatureVersion $Minimum |
            Should -Be $Expected
    }
}

Describe 'Test-QAFrameworkMainReleaseCompatible' {
    # Ported from UnitTest_TestRunnerTypes TestFilterTests.MainReleaseCompatible.
    It 'matches the legacy result for <DataMiner> / <Main> / <NextMain>' -ForEach @(
        @{ DataMiner = '10.0.0.20'; Main = '9.6.0.0-CU18';  NextMain = '10.0.0.0-CU19'; Expected = $true }
        @{ DataMiner = '10.0.0.20'; Main = '9.6.0.0-CU18';  NextMain = '10.0.0.0-CU20'; Expected = $true }
        @{ DataMiner = '10.0.0.20'; Main = '10.0.0.0-CU20'; NextMain = '10.1.0.0-CU19'; Expected = $true }
        @{ DataMiner = '9.6.0.2';   Main = '9.6.0.0-CU1';   NextMain = '10.0.0.0-CU19'; Expected = $true }
        @{ DataMiner = '9.6.0.20';  Main = '9.6.0.0-CU18';  NextMain = '10.0.0.0-CU19'; Expected = $true }
        @{ DataMiner = '9.6.0.50';  Main = '9.5.0.0-CU56';  NextMain = '9.6.0.0-CU7';   Expected = $true }
        @{ DataMiner = '9.5.0.4';   Main = '9.6.0.0-CU18';  NextMain = '10.0.0.0-CU19'; Expected = $false }
        @{ DataMiner = '10.0.0.20'; Main = '9.6.0.0-CU81';  NextMain = '10.0.0.0-CU21'; Expected = $false }
        @{ DataMiner = '10.0.0.20'; Main = '10.0.0.0-CU21'; NextMain = '10.1.0.0-CU2';  Expected = $false }
        @{ DataMiner = '10.0.13.0'; Main = '';              NextMain = '';              Expected = $false }
        @{ DataMiner = '10.1.13.0'; Main = $null;           NextMain = $null;           Expected = $false }
        @{ DataMiner = '10.5.0.0';  Main = '';              NextMain = '10.5.0.0-CU0';  Expected = $true }
        @{ DataMiner = '10.5.0.0';  Main = '';              NextMain = '10.5.0.0-CU30'; Expected = $false }
        @{ DataMiner = '10.5.0.4';  Main = '';              NextMain = '10.1.0.0-CU0';  Expected = $true }
        @{ DataMiner = '10.5.0.0';  Main = '10.5.0.0-CU0';  NextMain = '';              Expected = $true }
        @{ DataMiner = '10.5.0.0';  Main = '10.5.0.0-CU30'; NextMain = '';              Expected = $false }
        @{ DataMiner = '10.5.0.4';  Main = '10.1.0.0-CU0';  NextMain = '';              Expected = $true }
    ) {
        Test-QAFrameworkMainReleaseCompatible -DataMinerVersion ([version]$DataMiner) -MinimalMainVersion $Main -MinimalNextMainVersion $NextMain |
            Should -Be $Expected
    }

    It 'throws on malformed input like the legacy runner' -ForEach @(
        @{ Main = 'RandomString'; NextMain = 'random' }
        @{ Main = 'RandomString-Same-Format'; NextMain = 'test' }
        @{ Main = '10.1.2.0-5649-0'; NextMain = '10.4.3.2-CU4' }
    ) {
        { Test-QAFrameworkMainReleaseCompatible -DataMinerVersion ([version]'10.5.13.0') -MinimalMainVersion $Main -MinimalNextMainVersion $NextMain } |
            Should -Throw
    }
}

Describe 'Test-QAFrameworkVersionCompatible' {
    It 'uses the main release rules on a main release agent' {
        $test = New-TestStub -Main '10.5.0.0-CU30'
        Test-QAFrameworkVersionCompatible -DataMinerVersion ([version]'10.5.0.0') -Test $test | Should -BeFalse
        Test-QAFrameworkVersionCompatible -DataMinerVersion ([version]'10.5.0.40') -Test $test | Should -BeTrue
    }

    It 'uses the feature release rules on a feature release agent' {
        $test = New-TestStub -Feature '10.1.12.0-CU0' -Main '10.5.0.0-CU30'
        Test-QAFrameworkVersionCompatible -DataMinerVersion ([version]'10.1.5.0') -Test $test | Should -BeFalse
        Test-QAFrameworkVersionCompatible -DataMinerVersion ([version]'10.1.13.0') -Test $test | Should -BeTrue
    }

    It 'accepts a test without any version requirement' {
        Test-QAFrameworkVersionCompatible -DataMinerVersion ([version]'10.5.0.0') -Test (New-TestStub) | Should -BeTrue
    }

    It 'excludes a test with a malformed version instead of failing the run' {
        $test = New-TestStub -Feature 'NotAVersion'
        Test-QAFrameworkVersionCompatible -DataMinerVersion ([version]'10.5.13.0') -Test $test -WarningAction SilentlyContinue |
            Should -BeFalse
    }
}

Describe 'Test-QAFrameworkLocalDbCompatible' {
    It 'accepts a test without LocalDB entries on any database' {
        Test-QAFrameworkLocalDbCompatible -ClusterDbmsType 'Cassandra' -Test (New-TestStub) | Should -BeTrue
    }

    It 'accepts a matching database regardless of casing' {
        Test-QAFrameworkLocalDbCompatible -ClusterDbmsType 'cassandra' -Test (New-TestStub -LocalDbs @('MySQL', 'Cassandra')) | Should -BeTrue
    }

    It 'rejects a non-matching database' {
        Test-QAFrameworkLocalDbCompatible -ClusterDbmsType 'Cassandra' -Test (New-TestStub -LocalDbs @('MySQL')) | Should -BeFalse
    }

    It 'keeps the test when the cluster database is unknown' {
        Test-QAFrameworkLocalDbCompatible -ClusterDbmsType '' -Test (New-TestStub -LocalDbs @('MySQL')) | Should -BeTrue
    }
}

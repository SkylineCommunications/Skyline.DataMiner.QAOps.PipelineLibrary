function Get-QAOpsTrxResult {
    <# Parses VSTest/MTP TRX UnitTestResult rows and derives assembly/FQN/data case identity conservatively for runtime sidecar lookup. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ResultsPath,[Parameter(Mandatory=$true)][string]$AssemblyName)
    [xml]$trx = Get-Content -LiteralPath $ResultsPath -Raw -ErrorAction Stop
    $ns = New-Object System.Xml.XmlNamespaceManager($trx.NameTable)
    $ns.AddNamespace('t','http://microsoft.com/schemas/VisualStudio/TeamTest/2010')
    $unitTests = @{}
    foreach ($ut in @($trx.SelectNodes('//t:UnitTest', $ns))) {
        $id = $ut.GetAttribute('id')
        $tm = $ut.SelectSingleNode('t:TestMethod', $ns)
        $class = if ($tm) { $tm.GetAttribute('className') } else { '' }
        $name = if ($tm) { $tm.GetAttribute('name') } else { $ut.GetAttribute('name') }
        $fqn = if ([string]::IsNullOrWhiteSpace($class)) { $name } elseif ($name.StartsWith($class + '.', [System.StringComparison]::Ordinal)) { $name } else { $class + '.' + $name }
        if (-not [string]::IsNullOrWhiteSpace($id)) { $unitTests[$id] = [pscustomobject]@{ FullyQualifiedName=$fqn; MethodName=$name } }
    }
    $results = New-Object System.Collections.ArrayList
    foreach ($r in @($trx.SelectNodes('//t:UnitTestResult', $ns))) {
        $testId = $r.GetAttribute('testId')
        $display = $r.GetAttribute('testName')
        $unit = if ($unitTests.ContainsKey($testId)) { $unitTests[$testId] } else { $null }
        $fqn = if ($unit) { $unit.FullyQualifiedName } else { $testId }
        $methodName = if ($unit) { $unit.MethodName } else { $fqn }
        $dataCase = ''
        foreach ($attrName in @('dataCaseId','dataRowInfo','testCaseId')) {
            $attrValue = $r.GetAttribute($attrName)
            if (-not [string]::IsNullOrWhiteSpace($attrValue)) { $dataCase = $attrValue; break }
        }
        if ([string]::IsNullOrWhiteSpace($dataCase) -and -not [string]::IsNullOrWhiteSpace($display)) {
            if ($display.StartsWith($fqn, [System.StringComparison]::Ordinal) -and $display.Length -gt $fqn.Length) {
                $suffix = $display.Substring($fqn.Length).Trim()
                if ($suffix.StartsWith('(') -and $suffix.EndsWith(')')) { $dataCase = $suffix }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($methodName) -and $display.StartsWith($methodName, [System.StringComparison]::Ordinal) -and $display.Length -gt $methodName.Length) {
                $suffix = $display.Substring($methodName.Length).Trim()
                if ($suffix.StartsWith('(') -and $suffix.EndsWith(')')) { $dataCase = $suffix }
            }
        }
        $duration = [TimeSpan]::Zero
        $rawDuration = $r.GetAttribute('duration')
        if (-not [string]::IsNullOrWhiteSpace($rawDuration)) { [TimeSpan]::TryParse($rawDuration, [ref]$duration) | Out-Null }
        $msg = ''
        $messageNode = $r.SelectSingleNode('t:Output/t:ErrorInfo/t:Message', $ns)
        $stackNode = $r.SelectSingleNode('t:Output/t:ErrorInfo/t:StackTrace', $ns)
        if ($messageNode -and -not [string]::IsNullOrWhiteSpace($messageNode.InnerText)) { $msg = $messageNode.InnerText.Trim() }
        if ($stackNode -and -not [string]::IsNullOrWhiteSpace($stackNode.InnerText)) { $msg = ($msg + "`n" + $stackNode.InnerText.Trim()).Trim() }
        [void]$results.Add([pscustomobject]@{ Assembly=$AssemblyName; FullyQualifiedName=$fqn; DisplayName=$display; DataCaseId=$dataCase; Outcome=$r.GetAttribute('outcome'); Duration=$duration; Message=$msg })
    }
    return $results.ToArray()
}


function Get-QAOpsTrxResult {
    <# Parses VSTest/MTP TRX UnitTestResult rows with encoding-aware, DTD-disabled XML loading and bounded result/message handling. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ResultsPath,
        [Parameter(Mandatory=$true)][string]$AssemblyName,
        [Parameter()][int]$MaxTrxBytes = 10485760,
        [Parameter()][int]$MaxResults = 50000,
        [Parameter()][int]$MaxMessageCharacters = 2000
    )
    $item = Get-Item -LiteralPath $ResultsPath -ErrorAction Stop
    if ($item.Length -gt $MaxTrxBytes) { throw "TRX file exceeds the supported size limit of $MaxTrxBytes bytes: $ResultsPath" }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = [Math]::Max($MaxTrxBytes * 4, 1024)
    $stream = [System.IO.File]::Open($ResultsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $reader = [System.Xml.XmlReader]::Create($stream, $settings)
        try { $trx = New-Object System.Xml.XmlDocument; $trx.XmlResolver = $null; $trx.Load($reader) }
        finally { $reader.Close() }
    }
    finally { $stream.Dispose() }

    $ns = New-Object System.Xml.XmlNamespaceManager($trx.NameTable)
    $ns.AddNamespace('t','http://microsoft.com/schemas/VisualStudio/TeamTest/2010')
    $unitTests = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($ut in @($trx.SelectNodes('//t:UnitTest', $ns))) {
        $id = $ut.GetAttribute('id')
        $tm = $ut.SelectSingleNode('t:TestMethod', $ns)
        $class = if ($tm) { $tm.GetAttribute('className') } else { '' }
        $name = if ($tm) { $tm.GetAttribute('name') } else { $ut.GetAttribute('name') }
        $methodName = $name
        $methodDataCase = ''
        if ($name -match '^(.+?)(\(.+\))$') { $methodName = $Matches[1]; $methodDataCase = $Matches[2] }
        $fqn = if ([string]::IsNullOrWhiteSpace($class)) { $methodName } elseif ($methodName.StartsWith($class + '.', [System.StringComparison]::Ordinal)) { $methodName } else { $class + '.' + $methodName }
        $codeBase = if ($tm) { $tm.GetAttribute('codeBase') } else { '' }
        $unitAssembly = $AssemblyName
        if (-not [string]::IsNullOrWhiteSpace($codeBase)) {
            $leaf = [System.IO.Path]::GetFileName($codeBase)
            if (-not [string]::IsNullOrWhiteSpace($leaf) -and $leaf.EndsWith('.dll', [System.StringComparison]::OrdinalIgnoreCase)) { $unitAssembly = $leaf }
        }
        if (-not [string]::IsNullOrWhiteSpace($id)) { $unitTests[$id] = [pscustomobject]@{ FullyQualifiedName=$fqn; MethodName=$methodName; MethodDataCase=$methodDataCase; AssemblyName=$unitAssembly } }
    }
    $nodes = @($trx.SelectNodes('//t:UnitTestResult', $ns))
    if ($nodes.Count -gt $MaxResults) { throw "TRX result count $($nodes.Count) exceeds the supported limit of $MaxResults." }
    $results = New-Object System.Collections.ArrayList
    foreach ($r in $nodes) {
        $testId = $r.GetAttribute('testId')
        $display = $r.GetAttribute('testName')
        $unit = if ($unitTests.ContainsKey($testId)) { $unitTests[$testId] } else { $null }
        $fqn = if ($unit) { $unit.FullyQualifiedName } else { $testId }
        $methodName = if ($unit) { $unit.MethodName } else { $fqn }
        $rowAssembly = if ($unit) { $unit.AssemblyName } else { $AssemblyName }
        $dataCase = if ($unit) { [string]$unit.MethodDataCase } else { '' }
        $diagnostics = @()
        $comparable = $true
        foreach ($attrName in @('dataCaseId','dataRowInfo','testCaseId')) {
            $attrValue = $r.GetAttribute($attrName)
            if (-not [string]::IsNullOrWhiteSpace($attrValue)) { $dataCase = $attrValue; break }
        }
        $hadStableDataCase = -not [string]::IsNullOrWhiteSpace($dataCase)
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
        if ([string]::IsNullOrWhiteSpace($dataCase) -and -not [string]::IsNullOrWhiteSpace($display) -and -not [string]::IsNullOrWhiteSpace($methodName)) {
            if (-not $display.Equals($methodName, [System.StringComparison]::Ordinal) -and -not $display.Equals($fqn, [System.StringComparison]::Ordinal) -and -not $display.StartsWith($fqn + ' ', [System.StringComparison]::Ordinal)) {
                $diagnostics = @([pscustomobject]@{ code='data-case-identity-unavailable' })
                $comparable = $false
            }
        }
        $duration = [TimeSpan]::Zero
        $rawDuration = $r.GetAttribute('duration')
        if (-not [string]::IsNullOrWhiteSpace($rawDuration)) { [TimeSpan]::TryParse($rawDuration, [ref]$duration) | Out-Null }
        $msg = ''
        $messageNode = $r.SelectSingleNode('t:Output/t:ErrorInfo/t:Message', $ns)
        $stackNode = $r.SelectSingleNode('t:Output/t:ErrorInfo/t:StackTrace', $ns)
        if ($messageNode -and -not [string]::IsNullOrWhiteSpace($messageNode.InnerText)) { $msg = Limit-String -stringToLimit $messageNode.InnerText.Trim() -maxCharacters $MaxMessageCharacters }
        if ($stackNode -and -not [string]::IsNullOrWhiteSpace($stackNode.InnerText)) { $msg = Limit-String -stringToLimit (($msg + "`n" + $stackNode.InnerText.Trim()).Trim()) -maxCharacters $MaxMessageCharacters }
        [void]$results.Add([pscustomobject]@{ Assembly=$rowAssembly; FullyQualifiedName=$fqn; DisplayName=$display; DataCaseId=$dataCase; Outcome=$r.GetAttribute('outcome'); Duration=$duration; Message=$msg; Diagnostics=$diagnostics; Comparable=$comparable })
    }
    return $results.ToArray()
}

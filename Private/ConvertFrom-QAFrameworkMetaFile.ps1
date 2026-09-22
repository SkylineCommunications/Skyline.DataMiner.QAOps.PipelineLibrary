function ConvertFrom-QAFrameworkMetaFile {
    <#
    .SYNOPSIS
        Parses a QAFramework .meta XML file into test metadata.
    .DESCRIPTION
        Reads the legacy .meta format and extracts DLL references, maintainers, squads,
        customers, DCP IDs, RN IDs and the optional BaselineTest flag. Only keys that are
        actually present are returned so that C# attribute values (which take precedence)
        can be layered on top by New-QAFrameworkTestMetadata.

        Expected shape:
          <Meta>
            <Dlls><Dll>...</Dll></Dlls>
            <Maintainers><Maintainer>...</Maintainer></Maintainers>
            <TestInfo>
              <DCPIDs><DCPID>...</DCPID></DCPIDs>
              <RNs><RN>...</RN></RNs>
              <Squads><Squad>...</Squad></Squads>
              <Customers><Customer>...</Customer></Customers>
            </TestInfo>
            <BaselineTest>true</BaselineTest>
          </Meta>
    .PARAMETER Path
        Path to the .meta file.
    .OUTPUTS
        Hashtable of values found in the file.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $false
        $xml.Load((Resolve-Path -LiteralPath $Path).ProviderPath)
    }
    catch {
        Write-Warning "Failed to parse meta file '$Path': $($_.Exception.Message)"
        return $result
    }

    # Reads the trimmed inner text of every node matching the XPath expression.
    $readValues = {
        param([string]$XPath)

        $nodes = $xml.SelectNodes($XPath)
        if ($null -eq $nodes -or $nodes.Count -eq 0) { return $null }

        $values = @(
            foreach ($node in $nodes) {
                $text = $node.InnerText
                if (-not [string]::IsNullOrWhiteSpace($text)) { $text.Trim() }
            }
        )

        return [string[]]$values
    }

    $mappings = @{
        dllReferences = '/Meta/Dlls/Dll'
        maintainers   = '/Meta/Maintainers/Maintainer'
        squads        = '/Meta/TestInfo/Squads/Squad'
        customers     = '/Meta/TestInfo/Customers/Customer'
        dcpIds        = '/Meta/TestInfo/DCPIDs/DCPID'
        rnIds         = '/Meta/TestInfo/RNs/RN'
        keywords      = '/Meta/TestInfo/Keywords/Keyword'
    }

    foreach ($key in $mappings.Keys) {
        $values = & $readValues $mappings[$key]
        if ($null -ne $values) { $result[$key] = $values }
    }

    $baselineNode = $xml.SelectSingleNode('/Meta/BaselineTest')
    if ($null -ne $baselineNode -and -not [string]::IsNullOrWhiteSpace($baselineNode.InnerText)) {
        $result['isBaseline'] = ($baselineNode.InnerText.Trim() -match '^(?i:true|1|yes)$')
    }

    # Legacy RTManager tests can declare concurrency and weight in the .meta file.
    $concurrentNode = $xml.SelectSingleNode('/Meta/TestInfo/AllowConcurrent')
    if ($null -ne $concurrentNode -and -not [string]::IsNullOrWhiteSpace($concurrentNode.InnerText)) {
        $result['canRunConcurrently'] = ($concurrentNode.InnerText.Trim() -match '^(?i:true|1|yes)$')
    }

    $weightNode = $xml.SelectSingleNode('/Meta/TestInfo/Weight')
    if ($null -ne $weightNode -and -not [string]::IsNullOrWhiteSpace($weightNode.InnerText)) {
        $weight = 0
        if ([int]::TryParse($weightNode.InnerText.Trim(), [ref]$weight)) {
            if ($weight -le 0) { $weight = 1 } elseif ($weight -gt 3) { $weight = 3 }
            $result['weight'] = $weight
        }
    }

    return $result
}

function ConvertFrom-QAFrameworkLegacyDiscoveryConfig {
    <# Inferred helper: maps the former PipelineLibrary discovery JSON shape to the orchestrator request-file override shape documented by O. #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$Document)
    $result = @{}
    foreach ($name in @('folderTagPrefix','regressionTestsRoot','onlyTests','forceOnlyTests','baselineGate','includeDisabled')) {
        if ($Document.PSObject.Properties.Name -contains $name) { $result[$name] = $Document.$name }
    }
    if ($Document.PSObject.Properties.Name -contains 'excludedTests') { $result['excludedTests'] = $Document.excludedTests }
    if ($Document.PSObject.Properties.Name -contains 'filter') {
        $filter = $Document.filter
        if ($filter.PSObject.Properties.Name -contains 'attributeKeywords') { $result['keywords'] = $filter.attributeKeywords }
    }
    if ($Document.PSObject.Properties.Name -contains 'excludedKeywords') { $result['excludeKeywords'] = $Document.excludedKeywords }
    if ($Document.PSObject.Properties.Name -contains 'excludedSquads') { $result['excludeSquads'] = $Document.excludedSquads }
    if ($Document.PSObject.Properties.Name -contains 'execution') {
        $execution = $Document.execution
        if ($execution.PSObject.Properties.Name -contains 'timeoutSeconds') { $result['testTimeoutSeconds'] = $execution.timeoutSeconds }
    }
    return $result
}

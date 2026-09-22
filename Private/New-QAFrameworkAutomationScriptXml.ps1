function New-QAFrameworkAutomationScriptXml {
    <#
    .SYNOPSIS
        Builds the DMSScript XML for a harvested QAFramework test.
    .DESCRIPTION
        Produces the same script.xml the legacy TestDiscovery.ps1 produces: options 272,
        the Skyline automation namespace, the folder tag, the C# source in a CDATA block
        with an escaped ]]> sequence and one Param type="ref" per DLL reference.
    .PARAMETER Name
        The automation script name, which is also the test name.
    .PARAMETER CsContent
        The raw content of the test .cs file.
    .PARAMETER FolderTag
        The automation script folder, e.g. 'QAOps\MyPackage\Team\Test'.
    .PARAMETER DllReference
        The DLL references to add as Param type="ref" entries.
    .PARAMETER Author
        The author written in the script. Defaults to SKYLINE2\QACore.
    .OUTPUTS
        The XML document as a single string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$CsContent,

        [Parameter()]
        [string]$FolderTag = '',

        [Parameter()]
        [string[]]$DllReference = @(),

        [Parameter()]
        [string]$Author = 'SKYLINE2\QACore'
    )

    $escapedContent = $CsContent -replace ']]>', ']]&gt;'

    $references = @(
        $DllReference |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Sort-Object -Unique |
            ForEach-Object { '                <Param type="ref">{0}</Param>' -f [System.Security.SecurityElement]::Escape($_) }
    )

    $dllParams = if ($references.Count -gt 0) { $references -join "`r`n" } else { '' }

    $xml = '<?xml version="1.0" encoding="utf-8" ?>' +
    '<DMSScript options="272" xmlns="http://www.skyline.be/automation">' + "`r`n" +
    "    <Name>$([System.Security.SecurityElement]::Escape($Name))</Name>`r`n" +
    '    <Description></Description>' + "`r`n" +
    '    <Type>Automation</Type>' + "`r`n" +
    "    <Author>$([System.Security.SecurityElement]::Escape($Author))</Author>`r`n" +
    '    <CheckSets>FALSE</CheckSets>' + "`r`n" +
    "    <Folder>$([System.Security.SecurityElement]::Escape($FolderTag))</Folder>`r`n" +
    '    <Interactivity>Auto</Interactivity>' + "`r`n" +
    '    <Protocols>' + "`r`n" +
    '    </Protocols>' + "`r`n" +
    '    <Memory>' + "`r`n" +
    '    </Memory>' + "`r`n" +
    '    <Parameters>' + "`r`n" +
    '    </Parameters>' + "`r`n" +
    '    <Script>' + "`r`n" +
    '        <Exe id="2" type="csharp">' + "`r`n" +
    '            <Value><![CDATA[' + "`r`n" +
    $escapedContent + "`r`n" +
    ']]></Value>' + "`r`n" +
    $dllParams + "`r`n" +
    '            <Message></Message>' + "`r`n" +
    '        </Exe>' + "`r`n" +
    '    </Script>' + "`r`n" +
    '</DMSScript>'

    return $xml
}

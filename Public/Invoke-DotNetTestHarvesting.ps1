function Invoke-DotNetTestHarvesting {
    <#
    .SYNOPSIS
        Harvests .NET test maintainer metadata for a DataMiner Test Package.
    .DESCRIPTION
        Thin PowerShell wrapper around qaops-qaframework harvest-dotnet. It installs the
        orchestrator into a per-user cache outside the repository, passes any GitHub token
        only through the child-process QAOPS_GITHUB_TOKEN environment variable, and returns
        a skipped report instead of failing the build when optional maintainer harvesting is
        unavailable.
    .PARAMETER TestPackageContentPath
        TestPackageContent directory that contains TestHarvesting and TestPackagePipeline.
    .PARAMETER TestAssemblyPath
        Optional repeatable test assembly path, relative to TestPackageContent or absolute.
    .PARAMETER RepositoryRoot
        Optional repository root used by the harvester for source and Git fallback mapping.
    .PARAMETER ReviewedManifestPath
        Optional reviewed maintainer manifest path.
    .PARAMETER GitHubLookup
        Auto to allow eligible build-time GitHub lookup; Off to disable it.
    .PARAMETER GitHubOrganizations
        Optional GitHub owner allow-list for lookup eligibility.
    .PARAMETER AllowedEmailDomains
        Optional exact email-domain allow-list.
    .PARAMETER GitHubToken
        Optional token passed only as QAOPS_GITHUB_TOKEN to the child process.
    .PARAMETER TimeBudgetSeconds
        Harvester time budget; the wrapper adds 60 seconds of process grace time.
    .OUTPUTS
        The parsed harvest-dotnet JSON report, or a synthesized skipped report.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory=$true)][string]$TestPackageContentPath,
        [Parameter()][string[]]$TestAssemblyPath,
        [Parameter()][string]$RepositoryRoot,
        [Parameter()][string]$ReviewedManifestPath,
        [Parameter()][ValidateSet('Auto','Off')][string]$GitHubLookup = 'Auto',
        [Parameter()][string[]]$GitHubOrganizations,
        [Parameter()][string[]]$AllowedEmailDomains,
        [Parameter()][System.Security.SecureString]$GitHubToken,
        [Parameter()][ValidateRange(1,[int]::MaxValue)][int]$TimeBudgetSeconds = 120
    )

    function New-SkippedHarvestReport {
        param([string]$Code,[string]$Message)
        Write-Warning $Message
        [pscustomobject]@{
            schemaVersion = 1
            command = 'harvest-dotnet'
            status = 'skipped'
            sidecarPath = $null
            assemblies = @()
            counts = [pscustomobject]@{ tests = 0; declared = 0; reviewedManifest = 0; gitFallback = 0; unresolved = 0; conflicts = 0 }
            diagnostics = @([pscustomobject]@{ code = $Code; severity = 'Warning'; message = $Message })
        }
    }

    $paths = Resolve-QAFrameworkContentPath -Path $TestPackageContentPath
    $resolvedRepositoryRoot = $null
    if ($PSBoundParameters.ContainsKey('RepositoryRoot') -and -not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        try { $resolvedRepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath }
        catch { return New-SkippedHarvestReport -Code 'invalidRepositoryRoot' -Message 'Skipped .NET maintainer harvesting because the repository root path could not be resolved.' }
    }
    $resolvedReviewedManifestPath = $null
    if ($PSBoundParameters.ContainsKey('ReviewedManifestPath') -and -not [string]::IsNullOrWhiteSpace($ReviewedManifestPath)) {
        try { $resolvedReviewedManifestPath = (Resolve-Path -LiteralPath $ReviewedManifestPath -ErrorAction Stop).ProviderPath }
        catch { return New-SkippedHarvestReport -Code 'invalidReviewedManifest' -Message 'Skipped .NET maintainer harvesting because the reviewed maintainer manifest path could not be resolved.' }
    }
    if ($null -eq (Get-Command -Name dotnet -ErrorAction SilentlyContinue)) {
        return New-SkippedHarvestReport -Code 'dotnetMissing' -Message 'Skipped .NET maintainer harvesting because dotnet is not available.'
    }

    $cacheBase = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } else { [System.IO.Path]::GetTempPath() }
    $toolDir = Join-Path (Join-Path (Join-Path $cacheBase 'Skyline') 'QAOps') 'qaops-qaframework-tool'
    try {
        if (-not (Test-Path -LiteralPath $toolDir -PathType Container)) { New-Item -Path $toolDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    }
    catch { return New-SkippedHarvestReport -Code 'toolCacheUnavailable' -Message 'Skipped .NET maintainer harvesting because the per-user tool cache is unavailable.' }
    $manifestPath = Join-Path (Join-Path $toolDir '.config') 'dotnet-tools.json'
    $mutex = $null
    $hasMutex = $false
    try {
        try { $mutex = New-Object System.Threading.Mutex($false, 'Global\Skyline.QAOps.QAFrameworkOrchestrator.ToolCache') } catch { return New-SkippedHarvestReport -Code 'toolLockUnavailable' -Message 'Skipped .NET maintainer harvesting because the tool-cache lock is unavailable.' }
        $lockTimeoutSeconds = 60
        if (-not [string]::IsNullOrWhiteSpace($env:QAOPS_QAFRAMEWORK_TOOL_LOCK_TIMEOUT_SECONDS)) { [int]::TryParse($env:QAOPS_QAFRAMEWORK_TOOL_LOCK_TIMEOUT_SECONDS, [ref]$lockTimeoutSeconds) | Out-Null; if ($lockTimeoutSeconds -lt 0) { $lockTimeoutSeconds = 0 } }
        if ($lockTimeoutSeconds -eq 0) { $hasMutex = $false } else { try { $hasMutex = $mutex.WaitOne([TimeSpan]::FromSeconds($lockTimeoutSeconds)) } catch [System.Threading.AbandonedMutexException] { $hasMutex = $true } catch { $hasMutex = $false } }
        if ($hasMutex) {
            try { $null = Install-QAFrameworkTool -PipelineDirectory $toolDir -TimeoutSeconds ([Math]::Max(120, $TimeBudgetSeconds + 60)) }
            catch {
                if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Write-Information "Using cached QAFramework orchestrator after install/update failed." }
                else { return New-SkippedHarvestReport -Code 'toolInstallFailed' -Message 'Skipped .NET maintainer harvesting because the QAFramework orchestrator tool could not be installed or restored.' }
            }
        }
        elseif (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            return New-SkippedHarvestReport -Code 'toolInstallContention' -Message 'Skipped .NET maintainer harvesting because another process held the tool-cache lock and no cached tool exists yet.'
        }
    }
    catch { return New-SkippedHarvestReport -Code 'toolInstallFailed' -Message 'Skipped .NET maintainer harvesting because the QAFramework orchestrator tool cache could not be prepared.' }
    finally {
        if ($hasMutex -and $mutex) { try { $mutex.ReleaseMutex() | Out-Null } catch {} }
        if ($mutex) { $mutex.Dispose() }
    }

    $arguments = @('tool','run','qaops-qaframework','--','harvest-dotnet','--content',$paths.ContentPath,'--github-lookup',$GitHubLookup.ToLowerInvariant(),'--time-budget-seconds',[string]$TimeBudgetSeconds,'--json')
    foreach ($assembly in @($TestAssemblyPath)) { if (-not [string]::IsNullOrWhiteSpace($assembly)) { $arguments += @('--assembly',$assembly) } }
    if ($resolvedRepositoryRoot) { $arguments += @('--repository-root',$resolvedRepositoryRoot) }
    if ($resolvedReviewedManifestPath) { $arguments += @('--reviewed-manifest',$resolvedReviewedManifestPath) }
    if ($GitHubOrganizations -and @($GitHubOrganizations).Count -gt 0) { $arguments += @('--github-orgs',($GitHubOrganizations -join ',')) }
    if ($AllowedEmailDomains -and @($AllowedEmailDomains).Count -gt 0) { $arguments += @('--allowed-email-domains',($AllowedEmailDomains -join ',')) }

    $tokenPlain = $null
    if ($PSBoundParameters.ContainsKey('GitHubToken') -and $null -ne $GitHubToken) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($GitHubToken)
        try { $tokenPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { $tokenPlain = $env:GITHUB_TOKEN }

    $envOverrides = @{}
    if (-not [string]::IsNullOrWhiteSpace($tokenPlain)) { $envOverrides['QAOPS_GITHUB_TOKEN'] = $tokenPlain }
    try {
        $result = Invoke-QAFrameworkDotNet -Arguments $arguments -WorkingDirectory $toolDir -Environment $envOverrides -TimeoutSeconds ($TimeBudgetSeconds + 60)
    }
    catch { return New-SkippedHarvestReport -Code 'toolLaunchFailed' -Message 'Skipped .NET maintainer harvesting because the QAFramework orchestrator tool could not be started.' }
    finally { $tokenPlain = $null }

    if ($result.TimedOut) { return New-SkippedHarvestReport -Code 'toolTimeout' -Message 'Skipped .NET maintainer harvesting because harvest-dotnet timed out.' }
    if ($result.ExitCode -ne 0) {
        $combined = (($result.StdErr + "`n" + $result.StdOut) | Out-String)
        if ($combined -match 'unrecognized command|No command.*harvest-dotnet|Required command was not provided') { return New-SkippedHarvestReport -Code 'toolTooOld' -Message 'Skipped .NET maintainer harvesting because the installed QAFramework orchestrator does not support harvest-dotnet yet.' }
        return New-SkippedHarvestReport -Code 'toolRunFailed' -Message 'Skipped .NET maintainer harvesting because harvest-dotnet failed.'
    }
    try { return ($result.StdOut.Trim() | ConvertFrom-Json -ErrorAction Stop) }
    catch { return New-SkippedHarvestReport -Code 'nonJsonOutput' -Message 'Skipped .NET maintainer harvesting because harvest-dotnet did not return a valid JSON report.' }
}





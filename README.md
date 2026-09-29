# Skyline.DataMiner.QAOps.PipelineLibrary

`Skyline.DataMiner.QAOps.PipelineLibrary` contains reusable PowerShell functions for QAOps pipelines. It provides three high-level QAFramework entry points and `Invoke-DotNetTestAndPublishResults`.

## Install and import

```powershell
Install-Module Skyline.DataMiner.QAOps.PipelineLibrary -Repository PSGallery -Force -Scope CurrentUser
Import-Module Skyline.DataMiner.QAOps.PipelineLibrary -Force

Get-Command -Module Skyline.DataMiner.QAOps.PipelineLibrary
```

## QAFramework orchestrator

The QAFramework entry points delegate discovery, Agent setup, scheduling, Failover, stability checks, and result publication to the standalone `Skyline.DataMiner.QAOps.QAFrameworkOrchestrator` .NET tool. The PipelineLibrary no longer contains a second implementation of those behaviors and does not invoke QAFramework cmdlets from `QAOps.PowerShell`.

The public functions are:

| Function | Tool command | Purpose |
|---|---|---|
| `Invoke-QAFrameworkTestDiscovery` | `discover` | Scan RegressionTests sources, apply source filters, and harvest package metadata and dependencies. |
| `Initialize-QAFrameworkAgents` | `setup` | Prepare eligible Windows DataMiner Agents through QAOps Bridge. |
| `Invoke-QAFrameworkTestPackage` | `run` | Revalidate Agent setup, execute the selected test package, and publish results. |

Each function resolves a package-local tool manifest under `TestPackagePipeline/.config/dotnet-tools.json`. It installs the latest stable tool if the manifest does not include it and updates the tool if it is already present. If `TestPackagePipeline/NuGet.config` does not exist, the function creates one containing only nuget.org. Existing manifests and NuGet configuration are preserved.

The machine running the scripts needs the .NET SDK/runtime required by the orchestrator. The tool package must be available from a configured NuGet source. Harvesting can run on a developer machine or build agent; setup and test execution run through QAOps Bridge. The controller does not need DataMiner installed.

### Quick start

Copy the templates into a test package:

| Template | Package path |
|---|---|
| `Templates/TestDiscovery.sample.ps1` | `TestHarvesting/TestDiscovery.ps1` |
| `Templates/1.TestPackageSetup.sample.ps1` | `TestPackagePipeline/1.TestPackageSetup.ps1` |
| `Templates/2.TestPackageExecution.sample.ps1` | `TestPackagePipeline/2.TestPackageExecution.ps1` |
| `Templates/3.TestPackageFinalize.sample.ps1` | `TestPackagePipeline/3.TestPackageFinalize.ps1` |
| `Templates/qaframework.config.sample.json` | `TestPackagePipeline/qaframework.config.json` |
| `Templates/qaframework.tests.sample.json` | `TestHarvesting/dependencies.generated/qaframework.tests.json` |

The two main entry points are:

```powershell
Invoke-QAFrameworkTestDiscovery -TestPackageContentPath $contentPath -RegressionTestsRoot $regressionTestsRoot
Invoke-QAFrameworkTestPackage -TestPackageContentPath $contentPath
```

`TestPackageContentPath` can be the package content root or its `TestHarvesting` directory. `Invoke-QAFrameworkTestDiscovery` returns the tool's JSON report, including its `Preview`, `KnownTestsFile`, and `MetadataFile` properties.

### Configuration and migration

New packages should use the versioned `qaframework.config.json` sample. Its `selectionPolicy` is `LegacyPipeline`, preserving the PipelineLibrary defaults. Configuration includes discovery paths, filter rules, execution limits, Agent settings, and optional stability/background suites.

Legacy PipelineLibrary `qaframework.config.json` files and `TestHarvesting/qaframework.discovery.json` files remain supported by the appropriate tool adapter and discovery shim. During automatic loading, a versioned package configuration takes precedence over the legacy discovery file; an explicit `-ConfigPath` remains a higher-priority override. For setup and run, place an explicit `-ConfigPath` inside `TestPackageContent` so the QAOps Bridge Agents can read it. Supplementary files can be supplied with `-SupplementaryFilesPath`.

`-WhatIf` returns before installing or updating the tool and before setup or execution. `-PassThru` on setup returns its parsed JSON report; discovery always returns its report; `-PassThru` on run returns the successful run summary. A nonzero tool exit becomes a terminating PowerShell error. `-SkipPublish` disables result publication but does not make a run a dry run.

`Invoke-QAFrameworkTestPackage` always revalidates Agent setup. `-SkipAgentSetup` and custom `-OverallResultName` values are no longer supported. Setup no longer accepts object-based `-Topology` or `-Configuration` parameters; the orchestrator reads the active QAOps context and package configuration.

The migration removes these low-level exports: `Import-QAFrameworkTestMetadata`, `Get-QAFrameworkRunConfiguration`, `Get-QAFrameworkClusterTopology`, `Select-QAFrameworkTest`, `New-QAFrameworkExecutionPlan`, `Publish-QAFrameworkTestResult`, and `Invoke-QAFrameworkTestRun`. Migrate callers to the high-level functions and their JSON reports instead of reconstructing the former object pipeline.

The QAFramework shims do not depend on `QAOps.PowerShell`. `Invoke-DotNetTestAndPublishResults` remains a separate function and continues to use the QAOps result-publishing cmdlets.

## Invoke-DotNetTestAndPublishResults

Runs `dotnet test` for a given test assembly, reads the generated `.trx` file, and publishes individual test results through `Push-TestCaseResult`.

### Parameters

- `PathToTestPackageContent` - folder where the temporary `.trx` results file is created.
- `TestDllPath` - test assembly to execute.
- `ResultsFileName` - name of the temporary `.trx` file.
- `UsesMTP` - optional; set to `true` to execute `dotnet test --test-modules`.
- `TestFilter` - optional filter expression, for example `TestCategory=MyCategory`.
- `PublishNotExecuted` - optional; defaults to `true`. Set to `false` to skip `NotExecuted` or ignored rows.

### Behavior

1. Verifies that the test assembly exists and builds the full TRX path.
2. Removes an existing results file with the same name.
3. Executes the test executable or `dotnet test` with TRX logging enabled.
4. Parses the TRX XML and loops through all `UnitTestResult` entries.
5. Publishes passed tests as `OK` and failed, error, timeout, aborted, or unexpected outcomes as `Fail`.
6. Logs the durations and counts, then removes the temporary TRX file.

### Examples

```powershell
Invoke-DotNetTestAndPublishResults `
    -PathToTestPackageContent "C:\BuildArtifacts\TestOutput" `
    -TestDllPath "C:\BuildArtifacts\Tests\MyTests.dll" `
    -ResultsFileName "test-results.trx"

Invoke-DotNetTestAndPublishResults `
    -PathToTestPackageContent "C:\BuildArtifacts\TestOutput" `
    -TestDllPath "C:\BuildArtifacts\Tests\MyTests.exe" `
    -ResultsFileName "test-results.trx" `
    -TestFilter "TestCategory=IDmsElementCreation" `
    -PublishNotExecuted $false
```

## Contributing

### Module layout

```text
Skyline.DataMiner.QAOps.PipelineLibrary.psd1   manifest and exported public surface
Skyline.DataMiner.QAOps.PipelineLibrary.psm1   dot-sources Private/*.ps1 and Public/*.ps1
Public/                                        one file per exported function
Private/                                       helpers, never exported
Templates/                                     files a test package copies into its content
tests/                                         Pester tests
```

### Adding a function

1. Add `Public/Verb-Noun.ps1` with one function, `[CmdletBinding()]`, and comment-based help containing `.SYNOPSIS`, `.DESCRIPTION`, and one `.PARAMETER` block per parameter. Put helpers in `Private/`.
2. Add the function name to `FunctionsToExport` in the `.psd1`. `tests/Module.Tests.ps1` checks that the manifest and `Public/` match and that help is present.
3. Add a `tests/Verb-Noun.Tests.ps1` file. Stub external dependencies where needed.
4. Run the tests.

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests -Output Detailed"
```

### Guidelines

- Keep functions focused and free of repository-specific paths.
- Runtime functions must work on a Linux orchestrator. Use `Join-Path` and do not assume `C:\`.
- Keep DataMiner Agent-only behavior inside the orchestrator.

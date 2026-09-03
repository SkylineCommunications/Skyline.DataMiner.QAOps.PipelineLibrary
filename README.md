# Skyline.DataMiner.QAOps.PipelineLibrary

`Skyline.DataMiner.QAOps.PipelineLibrary` is a shared PowerShell module that contains reusable helper functions for QAOps and pipeline-related automation.

The goal of this library is to centralize common PowerShell logic so it can be reused across scripts and pipelines instead of being copied into multiple repositories.

It currently contains two things:

- **[The QAFramework library](#the-qaframework-library)** – harvests, plans and runs legacy QAFramework regression tests inside a QAOps test package.
- **[`Invoke-DotNetTestAndPublishResults`](#invoke-dotnettestandpublishresults)** – runs `dotnet test` and publishes the TRX results.

## Install and import

```powershell
Install-Module Skyline.DataMiner.QAOps.PipelineLibrary -Repository PSGallery -Force -Scope CurrentUser
Import-Module Skyline.DataMiner.QAOps.PipelineLibrary -Force

Get-Command -Module Skyline.DataMiner.QAOps.PipelineLibrary
```

---

# The QAFramework library

## What it does

Test packages built from the legacy QAFramework (`QAManagement.TestFramework`) used to depend on a Windows scheduler that talks the DataMiner protocol directly. That does not work when the test package pipeline runs on a QAOps Bridge **without** DataMiner, for example a Linux orchestrator in the cluster.

This library replaces that scheduler. It never runs a test itself: every test, every agent preparation step and every diagnostic action is started on a DataMiner agent through `Start-QAOpsBridgeExecution`. The orchestrating bridge only decides *what* runs *where* and *when*.

```
Invoke-QAFrameworkTestDiscovery      (harvest time, where the sources are)
   parse attributes + .meta  ->  script.xml  ->  qaframework.tests.json

Invoke-QAFrameworkTestPackage        (run time, on the orchestrating bridge)
   Get-QAFrameworkRunConfiguration   parameters > test run labels > supplementary file > package config > defaults
   Get-QAFrameworkClusterTopology    agents, DMA ids, failover pairs, cluster properties
   Import-QAFrameworkTestMetadata    schema v1 (+ legacy metadata files)
   Select-QAFrameworkTest            disabled, keywords, squads, version, database, centralized, red/green, ...
   New-QAFrameworkExecutionPlan      phases + TargetDMA expansion
   Initialize-QAFrameworkAgents      prepare every DataMiner agent
   Invoke-QAFrameworkTestRun         weight scheduler, failover switching, result publishing
   Push-TestCaseResult               pipeline_TestPackageExecution
```

QAOps itself stays unaware that these bridge executions represent individual tests.

## Quick start for a test package

Copy the three shims and the harvest script from `Templates/` into the test package content:

| Copy | To |
|---|---|
| `Templates/TestDiscovery.sample.ps1` | `TestHarvesting/TestDiscovery.ps1` |
| `Templates/Initialize-QAFrameworkAgent.ps1` | `TestPackagePipeline/helpers/Initialize-QAFrameworkAgent.ps1` |
| `Templates/1.TestPackageSetup.sample.ps1` | `TestPackagePipeline/1.TestPackageSetup.ps1` |
| `Templates/2.TestPackageExecution.sample.ps1` | `TestPackagePipeline/2.TestPackageExecution.ps1` |
| `Templates/3.TestPackageFinalize.sample.ps1` | `TestPackagePipeline/3.TestPackageFinalize.ps1` |
| `Templates/qaframework.discovery.sample.json` | `TestHarvesting/qaframework.discovery.json` (optional) |
| `Templates/qaframework.config.sample.json` | `TestPackagePipeline/qaframework.config.json` (optional) |

The execution shim is a single call:

```powershell
Import-Module Skyline.DataMiner.QAOps.PipelineLibrary -Force
Invoke-QAFrameworkTestPackage -TestPackageContentPath (Resolve-Path "$PSScriptRoot\..")
```

## Harvesting

`Invoke-QAFrameworkTestDiscovery` walks a `RegressionTests` tree and writes everything the package needs:

```
<Content>/TestHarvesting/
    xmlautomationtests.generated/<test>/script.xml
    dependencies.generated/
        knownautomationtests.generated
        qaframework.tests.json            <- schema v1 metadata used at run time
        testmetadata.generated.json       <- compatibility with older packages
        GlobalDependencies/  TeamDependencies/  TestDependencies/
```

Both tests with a `.meta` file and attribute-only tests carrying a fixture attribute are discovered. **Attribute values always win over `.meta` values**, and the `.meta` file only fills the gaps, which keeps legacy RTManager tests without attributes working.

Harvest-time filters are the ones that do not depend on the cluster: `-OnlyTests`, `-ForceOnlyTests`, `-BaselineGate`, `-Keywords`, `-ExcludeKeywords`, `-Squads`, `-ExcludeSquads`, `-IncludeDisabled`. Everything that depends on the cluster the package will run on stays a run-time decision.

## Supported QAFramework attributes

| Attribute | Effect |
|---|---|
| `TestFixture(name)` | The test name, which is also the automation script name. |
| `PreRunFixture` | Runs in the PreRun phase, one at a time, filtered by `preRunFilter` (`all`, `none` or a regex). |
| `DiagnosticTestFixture(runType)` | Runs before, after or before and after the whole run. Never subject to failover switching. |
| `FailoverTestFixture(before, after)` | Runs the failover phases. `RunOnNonFailoverSystems` allows it on a cluster without failover pairs. |
| `[BeforeSwitch]`, `[AfterSwitch]`, `[AfterSwitchReInit]` | Decide in which failover phases the test participates. |
| `Disabled(reason)` | Dropped only when the reason is not blank, and reported as `NotExecuted` with the reason. |
| `Weight(1..3)` | Weight of the test. An agent has capacity 3, so a weight 3 test owns its agent. |
| `CanRunConcurrently(false)` | Moved to the NonConcurrent phase, where one test runs in the whole cluster. |
| `TargetDMA(RunOn)` | `One`, `All`, `AllFailovers`, `LowestDMAID`, `HighestDMAID`. `All` and `AllFailovers` are cloned once per agent. |
| `Keywords`, `Squad` | Include lists. An entry prefixed with `!` excludes instead. |
| `MinVersion(feature, nextMain, main)` | Full port of the legacy feature release / main release / release path logic. |
| `LocalDB(types)` | The test is kept when the cluster database is in the list. Empty means every database. |
| `CentralizedTest`, `NonCentralizedTest` | Filtered on the cluster type, overridable with `forceRunNonCentralized`. |
| `RedGreenTest` | On a red/green cluster only these tests run. |
| `Customers`, `SolutionInfo(solution, minVersion)` | Customer filter and solution version gate. |
| `BaselineTest`, `Maintainers`, `DCPIDS`, `RNIDS`, `ProjectID`, `LeakTest` | Carried in the metadata, not used for scheduling. |

## Execution phases

| Phase | Behaviour |
|---|---|
| Setup | `Initialize-QAFrameworkAgents` on every DataMiner agent. |
| PreRun | One at a time in the cluster. |
| DiagnosticsBefore | Diagnostic tests with run type `Before` or `BeforeAndAfter`. |
| Main | Standard tests, weight scheduler across all agents. |
| NonConcurrent | One at a time in the whole cluster. |
| FailoverDirectBeforeSwitch / FailoverBeforeSwitch | `FailoverState = 0` on every agent. |
| *switch* | `Start-QAOpsFailoverSwitch` per pair, then `Wait-QAOpsFailoverSwitch`. Pending work of that pair is retargeted to the new active agent. |
| FailoverDirectAfterSwitch / FailoverAfterSwitch | `FailoverState = 10`. |
| *switch back* | Restores the original active agent. |
| FailoverAfterSwitchBack | `FailoverState = 20`. |
| DiagnosticsAfter | Diagnostic tests with run type `After` or `BeforeAndAfter`. |

The cluster is always restored: when the run switched but the package has no after-switch-back phase, the library switches back and resets `FailoverState` to 0 before it returns.

## Scheduling

Each agent has capacity 3. The free weight of an agent is `3 - sum(weight of its running tests)`. The scheduler prefers a test whose weight exactly fills the free weight and otherwise takes the first test that fits, which is the legacy `GetTestWithWeight` behaviour. Tests pinned to an agent by `TargetDMA` are considered before the shared pool. `maxTestsInCluster` caps the total number of simultaneously running tests.

Each test is started as:

```
dotnet tool run dataminer-run-automation-script Local -sn <test name>
```

with the working directory set to the `TestPackagePipeline` folder of the agent, where `dotnet-tools.json` lives.

Outcomes: exit code 0 is `Ok`, output containing `NotSupportedException` is `NotApplicable` (an unmet prerequisite), and anything else is `Fail`. Every result is published immediately as `automationscript_<test name>` with test aspect `Execution` and a message capped at 2000 characters. The overall result is `pipeline_TestPackageExecution`.

## Configuration

`TestPackagePipeline/qaframework.config.json`, see `Templates/qaframework.config.sample.json`:

| Setting | Default | Meaning |
|---|---|---|
| `agentCapacity` | 3 | Weight capacity per agent. |
| `maxTestsInCluster` | unlimited | Cap on tests running at the same time. |
| `testTimeoutSeconds` | 7200 | Maximum run time of one test. |
| `schedulerTickSeconds` | 10 | Poll interval of the scheduler loop. |
| `includeNonConcurrent` | true | Run the NonConcurrent phase. |
| `disableFailoverRun` | false | Skip the failover phases entirely. |
| `preRunFilter` | `all` | `all`, `none` or a regex on the test name. |
| `rerunFailedTests` | false | Re-queue failed tests once. |
| `forceRunNonCentralized` | false | Ignore the centralized filter. |
| `logCollectionOnFailure` | false | Run `SL_LogCollector.exe` once on the first failing agent. |
| `rtManagerRoot` | `C:\RTManager\` | RTManager root on the agents. |
| `filters` | empty | `keywords`, `excludeKeywords`, `squads`, `excludeSquads`. |
| `systemSettings` | empty | Extra values for `SystemSettings.json` on the agents. |

Precedence, highest first: cmdlet parameters, the QAOps test run labels, `SupplementaryFiles/qaframework.overrides.json`, `qaframework.config.json`, the built-in legacy defaults.

## Cmdlet reference

| Cmdlet | Purpose |
|---|---|
| `Invoke-QAFrameworkTestDiscovery` | Harvest the regression tests into the test package. |
| `Invoke-QAFrameworkTestPackage` | Run a whole test package with one call. |
| `Import-QAFrameworkTestMetadata` | Read `qaframework.tests.json` or a legacy metadata file. |
| `Get-QAFrameworkRunConfiguration` | Merge all configuration layers into one object. |
| `Get-QAFrameworkClusterTopology` | Agents, DMA ids, failover pairs and cluster properties. |
| `Select-QAFrameworkTest` | Apply every run-time filter and explain each dropped test. |
| `New-QAFrameworkExecutionPlan` | Assign phases and expand `TargetDMA`. |
| `Initialize-QAFrameworkAgents` | Prepare every DataMiner agent through a bridge execution. |
| `Invoke-QAFrameworkTestRun` | The scheduler, the failover orchestration and the result publishing. |
| `Publish-QAFrameworkTestResult` | Publish one work item as a QAOps test case result. |

## Requirements

The library expects these QAOps cmdlets in the session: `Get-QAOpsBridge`, `Start-QAOpsBridgeExecution`, `Wait-QAOpsBridgeExecution`, `Get-QAOpsBridgeExecution`, `Push-TestCaseResult`, and for the optional features `Get-QAOpsCluster`, `Get-QAOpsTestRunContext`, `Start-QAOpsFailoverSwitch` and `Wait-QAOpsFailoverSwitch`. Everything that is not available yet is read defensively: the library then falls back to the conservative legacy behaviour, for example by treating every bridge as a DataMiner agent and by disabling the failover phases.

---

# Invoke-DotNetTestAndPublishResults

Runs `dotnet test` for a given test assembly, reads the generated `.trx` file, and publishes the individual test results through `Push-TestCaseResult`.

### Parameters

- `PathToTestPackageContent` – folder where the temporary `.trx` results file is created.
- `TestDllPath` – the test assembly to execute.
- `ResultsFileName` – name of the temporary `.trx` file.
- `UsesMTP` – optional, set to `true` to execute `dotnet test --test-modules`.
- `TestFilter` – optional filter expression, for example `TestCategory=MyCategory`.
- `PublishNotExecuted` – optional, defaults to `true`. Set to `false` to skip `NotExecuted`/ignored rows.

### Behaviour

1. Verifies that the test assembly exists and builds the full TRX path.
2. Removes an existing results file with the same name.
3. Executes the test executable or `dotnet test` with TRX logging enabled.
4. Parses the TRX XML and loops through all `UnitTestResult` entries.
5. Publishes passed tests as `OK` and failed, error, timeout, aborted or unexpected outcomes as `Fail`.
6. Logs the durations and counts and removes the temporary TRX file.

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

---

# Contributing

## Module layout

```
Skyline.DataMiner.QAOps.PipelineLibrary.psd1   manifest, FunctionsToExport is the public surface
Skyline.DataMiner.QAOps.PipelineLibrary.psm1   dot-sources Private/*.ps1 and Public/*.ps1
Public/                                        one file per exported function
Private/                                       helpers, never exported
Templates/                                     files a test package copies into its content
tests/                                         Pester 5 tests, QAOps cmdlets are stubbed
```

## Adding a function

1. Add `Public/Verb-Noun.ps1` with one function, `[CmdletBinding()]` and comment-based help containing at least `.SYNOPSIS`, `.DESCRIPTION` and one `.PARAMETER` per parameter. Helpers go in `Private/`.
2. Add the name to `FunctionsToExport` in the `.psd1`. `tests/Module.Tests.ps1` fails when the manifest and `Public/` drift apart or when help is missing.
3. Add `tests/Verb-Noun.Tests.ps1`. Stub every new QAOps dependency in `tests/Stubs/QAOps.PowerShell.Stubs.psm1` first.
4. Run the tests.

```powershell
pwsh -NoProfile -c "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests -Output Detailed"
```

Windows PowerShell ships Pester 3, so always run the tests with `pwsh`.

## Guidelines

- Keep functions focused, reusable and free of repository-specific paths.
- The run-time cmdlets must work on a Linux orchestrator: use `Join-Path`, never assume `C:\`, and never call a Windows-only tool outside the agent-side templates.
- Never work around a missing QAOps cmdlet. Add the cmdlet with a `// TODO` in the QAOps solution instead and call it defensively here.

# Skyline.DataMiner.QAOps.PipelineLibrary

`Skyline.DataMiner.QAOps.PipelineLibrary` is a shared PowerShell module that contains reusable helper functions for QAOps and pipeline-related automation.

The goal of this library is to centralize common PowerShell logic so it can be reused across scripts and pipelines instead of being copied into multiple repositories.

## What exists in this library

At the moment, the library contains the following public function:

### `Invoke-DotNetTestAndPublishResults`

Runs `dotnet test` for a given test assembly, reads the generated `.trx` file, and publishes the individual test results through `Push-TestCaseResult`.

This function is intended for pipeline scenarios where test execution must be translated into pipeline-friendly test case result reporting.

#### Parameters

- `PathToTestPackageContent`  
  Path to the folder where the temporary `.trx` results file should be created.

- `TestDllPath`  
  Path to the test assembly that should be executed with `dotnet test`.

- `ResultsFileName`  
  Name of the temporary `.trx` results file to generate and process.

#### Behavior

The function performs the following steps:

1. Verifies that the provided test assembly exists.
2. Builds the full path to the `.trx` results file.
3. Removes any existing results file with the same name.
4. Executes `dotnet test` with TRX logging enabled.
5. Verifies that the TRX file was created.
6. Parses the TRX XML.
7. Loops through all `UnitTestResult` entries.
8. Publishes:
   - passed tests as `OK`
   - failed/error/timeout/aborted tests as `Fail`
   - unexpected outcomes as `Fail`
9. Removes the temporary TRX file afterwards.

#### Dependencies

This function expects the following commands to be available in the environment:

- `dotnet`
- `Push-TestCaseResult`

## How to use the library

### Import the module

If the module is available locally, import it using the manifest or module file.

```powershell
Import-Module .\Skyline.DataMiner.QAOps.PipelineLibrary.psd1 -Force
````

You can verify that the function was loaded correctly with:

```powershell
Get-Command -Module Skyline.DataMiner.QAOps.PipelineLibrary
```

### Example usage

```powershell
$scriptStart = Get-Date

Invoke-DotNetTestAndPublishResults `
    -PathToTestPackageContent "C:\BuildArtifacts\TestOutput" `
    -ScriptStart $scriptStart `
    -TestDllPath "C:\BuildArtifacts\Tests\MyTests.dll" `
    -ResultsFileName "test-results.trx"
```

### Example in a pipeline script

```powershell
Import-Module .\Skyline.DataMiner.QAOps.PipelineLibrary.psd1 -Force

$scriptStart = Get-Date
$testOutputFolder = "C:\Agent\work\test-output"
$testDll = "C:\Agent\work\drop\MyProject.Tests.dll"

Invoke-DotNetTestAndPublishResults `
    -PathToTestPackageContent $testOutputFolder `
    -ScriptStart $scriptStart `
    -TestDllPath $testDll `
    -ResultsFileName "MyProject.Tests.trx"
```

## How the module is structured

The module currently consists of:

* `Skyline.DataMiner.QAOps.PipelineLibrary.psd1`
  The module manifest containing metadata and exported functions.

* `Skyline.DataMiner.QAOps.PipelineLibrary.psm1`
  The script module containing the implementation of the library functions.

The manifest exports the public functions defined in the module.

## How to add a new function yourself

To add a new reusable function to this library, follow the steps below.

### 1. Add the function to the `.psm1`

Open `Skyline.DataMiner.QAOps.PipelineLibrary.psm1` and add your new function.

Example:

```powershell
function Get-ExampleMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return "Hello, $Name"
}
```

### 2. Export the function from the module

At the bottom of the `.psm1`, update `Export-ModuleMember` so your function becomes publicly available.

Example:

```powershell
Export-ModuleMember -Function `
    Invoke-DotNetTestAndPublishResults, `
    Get-ExampleMessage
```

If you prefer, you can also keep this on one line:

```powershell
Export-ModuleMember -Function Invoke-DotNetTestAndPublishResults, Get-ExampleMessage
```

### 3. Add the function name to the manifest

Open `Skyline.DataMiner.QAOps.PipelineLibrary.psd1` and add the new function name to `FunctionsToExport`.

Example:

```powershell
FunctionsToExport = @(
    'Invoke-DotNetTestAndPublishResults',
    'Get-ExampleMessage'
)
```

This ensures the manifest correctly exposes the new function.

### 4. Test the module locally

After updating the module, reload it and verify the new command is available.

```powershell
Import-Module .\Skyline.DataMiner.QAOps.PipelineLibrary.psd1 -Force
Get-Command Get-ExampleMessage
```

You can then test the function:

```powershell
Get-ExampleMessage -Name 'Jan'
```

### 5. Keep functions reusable

When adding a new function, try to keep it:

* focused on one responsibility
* reusable across multiple scripts or pipelines
* independent from repository-specific paths or assumptions
* clear in naming and parameter design
* safe in error handling

### 6. Document the new function

Whenever you add a new function, update this README so other users of the library understand:

* what the function does
* which parameters it accepts
* whether it has dependencies
* how it should be used

## Recommended guidelines for new functions

When contributing a new function to this library, it is recommended to:

* use `[CmdletBinding()]`
* define clear and explicit parameters
* validate required inputs
* throw meaningful errors when required inputs are invalid
* avoid hardcoding project-specific paths
* keep output and side effects predictable
* catch exceptions only when there is a clear recovery or reporting reason

## Example workflow for extending the library

1. Add the function to `Skyline.DataMiner.QAOps.PipelineLibrary.psm1`
2. Export it with `Export-ModuleMember`
3. Add it to `FunctionsToExport` in `Skyline.DataMiner.QAOps.PipelineLibrary.psd1`
4. Reload the module locally
5. Test the function
6. Update this README

## Notes

* `ScriptStart` is currently part of the `Invoke-DotNetTestAndPublishResults` signature but is not yet used internally.
* The function assumes `Push-TestCaseResult` is available in the execution environment.
* The library is designed to grow over time as more pipeline helper functions become shared and centralized.

## Future improvements

Possible future improvements for this library include:

* splitting public functions into separate files for easier maintenance
* adding private helper functions
* adding comment-based help to each function
* adding Pester tests for the module
* publishing the module through a shared internal or public PowerShell repository

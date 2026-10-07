function Invoke-QAFrameworkDotNet {
    <# Inferred helper: the single mockable seam for dotnet. Uses a C# runner so redirected stream callbacks never execute PowerShell script blocks on reader threads. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [Parameter()][string]$WorkingDirectory = (Get-Location).ProviderPath,
        [Parameter()][hashtable]$Environment,
        [Parameter()][int]$TimeoutSeconds = 600,
        [Parameter()][int]$MaxStreamCharacters = 1048576
    )
    if (-not ('Skyline.QAOps.ProcessRunner' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Diagnostics;
using System.Text;
namespace Skyline.QAOps {
  public sealed class ProcessResult { public int ExitCode; public string StdOut; public string StdErr; public bool TimedOut; public bool OutputTruncated; }
  public static class ProcessRunner {
    public static ProcessResult Run(string fileName, string[] args, string workingDirectory, IDictionary environment, int timeoutSeconds, int maxChars) {
      if (maxChars <= 0) maxChars = 1048576;
      var psi = new ProcessStartInfo(); psi.FileName = fileName; psi.Arguments = QuoteArguments(args ?? new string[0]); psi.WorkingDirectory = workingDirectory;
      psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true; psi.CreateNoWindow = true;
      if (environment != null) { foreach (DictionaryEntry entry in environment) { string key = (string)entry.Key; object value = entry.Value; if (value == null) psi.EnvironmentVariables.Remove(key); else psi.EnvironmentVariables[key] = Convert.ToString(value); } }
      var result = new ProcessResult();
      using (var process = new Process()) {
        process.StartInfo = psi; var stdout = new BoundedBuffer(maxChars); var stderr = new BoundedBuffer(maxChars);
        try {
          if (!process.Start()) throw new InvalidOperationException("Failed to start process.");
          var outTask = process.StandardOutput.ReadToEndAsync(); var errTask = process.StandardError.ReadToEndAsync();
          int waitMs = timeoutSeconds > 0 ? checked(timeoutSeconds * 1000) : int.MaxValue;
          if (!process.WaitForExit(waitMs)) { result.TimedOut = true; KillTree(process); process.WaitForExit(5000); }
          try { outTask.Wait(5000); } catch { } try { errTask.Wait(5000); } catch { }
          stdout.Append(SafeTaskResult(outTask)); stderr.Append(SafeTaskResult(errTask));
          result.ExitCode = result.TimedOut ? -1 : (process.HasExited ? process.ExitCode : -1);
        } finally { try { if (!process.HasExited) KillTree(process); } catch { } }
        result.StdOut = stdout.Text; result.StdErr = stderr.Text; result.OutputTruncated = stdout.Truncated || stderr.Truncated; return result;
      }
    }
    static string SafeTaskResult(System.Threading.Tasks.Task<string> task) { try { return task.IsCompleted ? task.Result : String.Empty; } catch { return String.Empty; } }
    static void KillTree(Process process) {
      try { var method = typeof(Process).GetMethod("Kill", new Type[] { typeof(bool) }); if (method != null) { method.Invoke(process, new object[] { true }); return; } } catch { }
      try { if (Environment.OSVersion.Platform == PlatformID.Win32NT) { using (var killer = Process.Start(new ProcessStartInfo("taskkill", "/T /F /PID " + process.Id) { UseShellExecute = false, CreateNoWindow = true })) { if (killer != null) killer.WaitForExit(5000); } } else { process.Kill(); } } catch { try { process.Kill(); } catch { } }
    }
    static string QuoteArguments(string[] args) { var sb = new StringBuilder(); for (int i = 0; i < args.Length; i++) { if (i > 0) sb.Append(' '); sb.Append(Quote(args[i] ?? String.Empty)); } return sb.ToString(); }
    static string Quote(string arg) { if (arg.Length == 0) return "\"\""; bool quote = arg.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) >= 0; if (!quote) return arg; var sb = new StringBuilder(); sb.Append('"'); int slashCount = 0; foreach (char c in arg) { if (c == '\\') { slashCount++; continue; } if (c == '"') { sb.Append('\\', slashCount * 2 + 1); sb.Append('"'); slashCount = 0; continue; } if (slashCount > 0) { sb.Append('\\', slashCount); slashCount = 0; } sb.Append(c); } if (slashCount > 0) sb.Append('\\', slashCount * 2); sb.Append('"'); return sb.ToString(); }
    sealed class BoundedBuffer { readonly int max; readonly StringBuilder builder = new StringBuilder(); public bool Truncated; public string Text { get { return builder.ToString(); } } public BoundedBuffer(int max) { this.max = max; } public void Append(string value) { if (String.IsNullOrEmpty(value) || builder.Length >= max) { if (!String.IsNullOrEmpty(value)) Truncated = true; return; } int remaining = max - builder.Length; if (value.Length <= remaining) builder.Append(value); else { builder.Append(value.Substring(0, remaining)); Truncated = true; } } }
  }
}
'@ -ErrorAction Stop
    }
    try {
        $r = [Skyline.QAOps.ProcessRunner]::Run('dotnet', [string[]]@($Arguments), $WorkingDirectory, $Environment, $TimeoutSeconds, $MaxStreamCharacters)
        [pscustomobject]@{ ExitCode = $r.ExitCode; StdOut = $r.StdOut; StdErr = $r.StdErr; TimedOut = $r.TimedOut; OutputTruncated = $r.OutputTruncated }
    }
    catch { throw [System.InvalidOperationException]::new("Failed to invoke dotnet: $($_.Exception.Message)", $_.Exception) }
}

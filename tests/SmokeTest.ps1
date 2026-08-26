# Runs the assembled script for real and checks that it reaches the end of its startup.
#
# The rest of the chain never executes the bundle: Build-SingleFile concatenates it, StaticChecks
# parses it and greps it, Pester exercises individual functions lifted out of src/. All three pass on
# a bundle that dies the moment it is loaded - a part in the wrong position, a $script: variable read
# before the line that assigns it, a control referenced before it is created. A parser cannot see any
# of that, and every one of them is fatal on the machine of whoever downloads the file.
#
# The script itself stops at its smoke gate (see 90-Main.ps1) when WINTUNER_SMOKE=1, before any
# modal dialog and before the WinForms message loop, and prints WINTUNER_SMOKE_OK. Getting that
# marker back means every part loaded and every top-level statement ran.
#
# Runs in a CHILD process on purpose: the script calls exit, sets up WinForms and touches
# $script:-scope state that must not leak into the caller's session.
[CmdletBinding()]
param(
  [string]$ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/WinTuner_GUI_ntg.ps1'),
  [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$path = (Resolve-Path -LiteralPath $ScriptPath).Path

# A real settings file must not be read or written by a verification run: the app saves on shutdown,
# and a smoke test that rewrites the user's package path or recent logins would be a bug of its own.
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("wintuner-smoke-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)

$stdoutFile = Join-Path $sandbox 'stdout.txt'
$stderrFile = Join-Path $sandbox 'stderr.txt'

try {
  $pwsh = (Get-Process -Id $PID).Path
  if (-not $pwsh) { $pwsh = 'pwsh' }

  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $pwsh
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  # -NonInteractive plus a redirected stdin: the bootstrap asks whether to install the WinTuner
  # module with Read-Host when it is missing, and that has to hit end-of-file instead of waiting.
  $psi.RedirectStandardInput = $true
  foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $path)) {
    [void]$psi.ArgumentList.Add($a)
  }
  $psi.EnvironmentVariables['WINTUNER_SMOKE'] = '1'
  # Redirect the whole per-user profile so settings.json, the version cache and the logs land in the
  # sandbox rather than in the real profile.
  $psi.EnvironmentVariables['APPDATA'] = $sandbox
  $psi.EnvironmentVariables['LOCALAPPDATA'] = $sandbox

  $proc = [Diagnostics.Process]::Start($psi)
  # Read both streams before waiting: a full pipe buffer would deadlock a process that is being
  # waited on.
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $proc.StandardInput.Close()

  if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    try { $proc.Kill($true) } catch { }
    throw "Smoke run did not finish within $TimeoutSeconds seconds. The script is very likely waiting on a dialog or a prompt during startup."
  }
  $stdout = $stdoutTask.GetAwaiter().GetResult()
  $stderr = $stderrTask.GetAwaiter().GetResult()
  [IO.File]::WriteAllText($stdoutFile, [string]$stdout)
  [IO.File]::WriteAllText($stderrFile, [string]$stderr)

  if ($proc.ExitCode -ne 0) {
    Write-Host '--- stdout ---'; Write-Host $stdout
    Write-Host '--- stderr ---'; Write-Host $stderr
    throw "Smoke run exited with code $($proc.ExitCode); the assembled script does not start."
  }
  if ($stdout -notmatch 'WINTUNER_SMOKE_OK') {
    Write-Host '--- stdout ---'; Write-Host $stdout
    Write-Host '--- stderr ---'; Write-Host $stderr
    throw 'Smoke run exited cleanly but never reached the smoke gate; startup stopped somewhere earlier.'
  }
  # The exit code alone is not enough, and this was measured rather than assumed: a
  # statement-terminating error during startup - a method call on $null, a property on a control that
  # was never created - writes to stderr, does NOT stop the script and does NOT change the exit code.
  # Without this check the run reached the gate, printed the marker and reported success while
  # something had plainly gone wrong. A healthy run writes nothing at all to stderr.
  if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    Write-Host '--- stderr ---'; Write-Host $stderr
    throw ("Smoke run reached the end of startup but wrote {0} character(s) to stderr; startup is not clean. See the output above." -f $stderr.Length)
  }

  $reported = [regex]::Match($stdout, 'WINTUNER_SMOKE_OK version=(?<v>[^\s]+)')
  $version = if ($reported.Success) { $reported.Groups['v'].Value } else { 'unknown' }
  Write-Host "Smoke test passed: WinTuner GUI $version loaded, built its UI and reached the end of startup."
} finally {
  try { [IO.Directory]::Delete($sandbox, $true) } catch { }
}

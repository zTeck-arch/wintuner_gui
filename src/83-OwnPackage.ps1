# --- Own installers and in-place content replacement ---
# Everything else in this GUI starts from a WinGet package. These two actions close the two gaps
# that leaves: software that is not in WinGet at all, and updating an app WITHOUT creating a second
# Intune app object next to it.

# Wraps New-IntuneWinPackage. The setup file must live inside the source folder - Intune packages
# a whole directory and records which file inside it starts the install.
# The packager requires the setup file to live INSIDE the source folder - everything in that folder
# is what ends up in the .intunewin, and a setup file outside it simply would not be shipped.
#
# Its own function because the rule now has two callers: the build itself, and the live check in the
# card. Learning the constraint only from a failed build, after picking two folders and pressing the
# button, was the actual complaint - one implementation so the hint can never contradict the guard.
function Test-SetupFileInsideSource {
  param([string]$SourcePath, [string]$SetupFile)
  if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($SetupFile)) { return $false }
  if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { return $false }
  if (-not (Test-Path -LiteralPath $SetupFile -PathType Leaf)) { return $false }
  try {
    # Resolve both sides before comparing: a relative or differently-cased path would otherwise pass
    # a check that Intune later fails on.
    $srcFull = (Resolve-Path -LiteralPath $SourcePath).Path.TrimEnd([char]'\')
    $setupFull = (Resolve-Path -LiteralPath $SetupFile).Path
    return $setupFull.StartsWith($srcFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

# Windows Sandbox ships with Windows but stays switched off until the optional feature
# "Containers-DisposableClientVM" is enabled, and it does not exist at all on Home editions.
# Looked up by path rather than through Get-WindowsOptionalFeature, which needs elevation.
function Test-WindowsSandboxAvailable {
  try {
    $root = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    if (Test-Path -LiteralPath (Join-Path $root 'System32\WindowsSandbox.exe') -PathType Leaf) { return $true }
    return [bool](Get-Command 'WindowsSandbox.exe' -ErrorAction SilentlyContinue)
  } catch { return $false }
}

# Windows Sandbox allows only ONE running instance. Starting a second while one is still initialising
# is what returns "access denied (0x80070005)". The earlier UI freeze made users click the button
# twice, which is exactly how they hit that error - so this pre-check turns a confusing Windows error
# into a plain "one is already open" message.
function Test-WindowsSandboxRunning {
  try {
    foreach ($n in @('WindowsSandbox','WindowsSandboxClient','WindowsSandboxServer','WindowsSandboxRemoteSession')) {
      if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
  } catch { return $false }
}

# Why a Windows Sandbox will not start on THIS machine, asked before starting one.
#
# Measured on a real device: Virtualisation-Based Security running with Credential Guard active makes
# Windows Sandbox fail at initialisation with "Zugriff verweigert (0x80070005)" - every time, for any
# installer. Without this check the user picks a file, waits, and gets a Windows dialog that names an
# error code but not a cause; the app knew nothing and could only guess in its own message afterwards.
#
# Win32_DeviceGuard is readable WITHOUT administrator rights, so the diagnosis costs nothing.
#
# Deliberately advisory, never a hard block: this is an environment fact, Microsoft changes the
# interaction between these features between builds, and the same package works fine on a machine
# without those policies. The user is told and decides.
#
# Returns @{ Blocked; Reason; Detail } - Detail is the raw state, so a log line is enough to settle
# the question next time instead of measuring again.
$script:sandboxBlockerCache = $null

function Get-SandboxBlockerDiagnosis {
  # Cached for the session: the state cannot change without a reboot, and the card asks on every
  # click plus once at start-up.
  param([switch]$Refresh)
  if (-not $Refresh -and $null -ne $script:sandboxBlockerCache) { return $script:sandboxBlockerCache }
  $out = @{ Blocked = $false; Reason = ''; Detail = '' }
  try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
    $vbs = [int]$dg.VirtualizationBasedSecurityStatus
    $running = @(@($dg.SecurityServicesRunning) | ForEach-Object { [int]$_ })
    # 1 = Credential Guard, 2 = HVCI / memory integrity. Named rather than left as numbers, because
    # a bare "SecurityServicesRunning: 1,2" in a log means nothing to the next reader.
    $names = @()
    if ($running -contains 1) { $names += 'Credential Guard' }
    if ($running -contains 2) { $names += 'HVCI / memory integrity' }
    $out.Detail = ('VBS={0}, running=[{1}], codeIntegrityEnforcement={2}' -f
      $vbs, ($names -join ', '), [int]$dg.CodeIntegrityPolicyEnforcementStatus)
    if ($vbs -eq 2 -and ($running -contains 1)) {
      $out.Blocked = $true
      $out.Reason = 'CredentialGuard'
    }
  } catch {
    # Not knowing is not a blocker. An unreadable WMI class must never stop a test that might work.
    $out.Detail = ('device guard state could not be read: {0}' -f $_.Exception.Message)
  }
  $script:sandboxBlockerCache = $out
  return $out
}

# Closes a running Windows Sandbox.
#
# There is no supported API for this and nothing to click in the GUI: the sandbox runs as
# WindowsSandboxClient (the window) plus WindowsSandboxServer (the VM), and a leftover instance -
# after a crash, a timeout, or a test that was never closed - blocks every further test with
# "only one can run at a time". Sending people to Task Manager to hunt for a process name is not an
# answer.
#
# Graceful first: CloseMainWindow on the client is the same thing as clicking its X. Only if that is
# ignored are the processes killed. Nothing of value is lost either way - a sandbox discards its
# whole state when it closes, by design.
#
# Returns @{ Stopped = <bool>; Killed = <bool> }. Killed matters to the caller: a sandbox that had to
# be terminated leaves more for Windows to clean up than one that closed itself, and starting the next
# one too early is answered with 0x80070005.
function Stop-WindowsSandbox {
  param([int]$TimeoutSeconds = 20)
  $names = @('WindowsSandboxClient', 'WindowsSandbox', 'WindowsSandboxServer', 'WindowsSandboxRemoteSession')
  Write-Log 'Closing the running Windows Sandbox on request.'

  # 1) Ask the window to close.
  foreach ($name in @('WindowsSandboxClient', 'WindowsSandbox')) {
    foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
      try { [void]$p.CloseMainWindow() } catch { }
    }
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt ($TimeoutSeconds / 2)) {
    if (-not (Test-WindowsSandboxRunning)) {
      Write-Log 'Windows Sandbox closed on request.'
      return @{ Stopped = $true; Killed = $false }
    }
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 300
  }

  # 2) Still there - end it. The VM keeps no state worth saving.
  foreach ($name in $names) {
    foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
      try { $p.Kill() } catch { Write-Log ("Could not end {0} (PID {1}): {2}" -f $name, $p.Id, $_.Exception.Message) }
    }
  }
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    if (-not (Test-WindowsSandboxRunning)) {
      Write-Log 'Windows Sandbox was ended.'
      return @{ Stopped = $true; Killed = $true }
    }
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 300
  }
  Write-Log 'A Windows Sandbox process is still running after the attempt to close it.'
  return @{ Stopped = $false; Killed = $true }
}

# Waits for Windows to actually release the sandbox container after one was stopped.
#
# "No process left" is not the same as "ready for the next one": the log of a real run showed a
# sandbox ended at 11:53:00, the next started at 11:53:02, and Windows answered 0x80070005. The
# processes were gone by then - the container was not. A terminated sandbox needs noticeably longer
# than one that closed itself, because nothing got to tidy up on the way out.
function Wait-WindowsSandboxSettled {
  param([switch]$AfterKill)
  $graceSeconds = if ($AfterKill) { 15 } else { 5 }
  Write-Log ("Waiting {0}s for Windows to release the sandbox before starting the next one." -f $graceSeconds)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $graceSeconds) {
    # A process reappearing here means something else started a sandbox meanwhile - stop waiting and
    # let the caller's own guard deal with it rather than racing it.
    if (Test-WindowsSandboxRunning) {
      Write-Log 'A sandbox process appeared again while waiting; not starting another one.'
      return $false
    }
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250
  }
  return $true
}

# Runs the module's Test-WtSetupFile OUT OF PROCESS, with standard input redirected from an empty
# file. Two module behaviours make a direct call unusable from a GUI:
#   * it ends the run with a blocking "Press enter when you closed the sandbox" (a Read-Host). On the
#     UI thread that froze the whole window until the process was killed.
#   * it writes progress from a background thread, which spams "WriteObject ... cannot be called from
#     outside the overrides" into the host.
# A child pwsh with stdin redirected from an empty file makes that Read-Host read end-of-file and
# return at once, so the module launches the sandbox, cleans up and exits on its own; the sandbox
# window stays open for the user to inspect. All of the module's noise stays inside the child. The
# child keeps interactive mode - under -NonInteractive that Read-Host throws instead of reading EOF.
# Returns @{ Succeeded; ErrorMessage; AccessDenied; Output }.
function Invoke-WtSandboxTest {
  param(
    [Parameter(Mandatory)][string]$SetupFile,
    [string]$InstallerArguments = '',
    [int]$TimeoutMinutes = 15
  )
  # SandboxStarted: did a sandbox process actually come up? It decides whether the wait below has
  # anything to wait FOR, and the caller can tell "the VM ran" from "it never started".
  $out = @{ Succeeded = $false; ErrorMessage = $null; AccessDenied = $false; Output = ''; SandboxStarted = $false }
  $pwshExe = $null
  try { $pwshExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
  if (-not $pwshExe -or ($pwshExe -notmatch '(?i)pwsh')) {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { $pwshExe = $cmd.Source }
  }
  if (-not $pwshExe) { $out.ErrorMessage = 'PowerShell 7 (pwsh) executable not found.'; return $out }

  # Stage the installer in a clean folder under LocalAppData, and run the test from THERE. Windows
  # Sandbox maps the folder that holds the installer into the guest; the Downloads/Desktop/Documents
  # folders are usually covered by Controlled Folder Access, and mapping one of those is a common
  # cause of "access denied (0x80070005)" at sandbox start. LocalAppData is not a protected folder,
  # so the map succeeds. Old stage folders from previous runs are swept first.
  $stageBase = Join-Path (Get-LocalAppDataRoot) 'WinTunerGUI\SandboxTest'
  try {
    if (Test-Path -LiteralPath $stageBase) {
      foreach ($d in @(Get-ChildItem -LiteralPath $stageBase -Directory -ErrorAction SilentlyContinue)) {
        if ($d.LastWriteTime -lt (Get-Date).AddDays(-1)) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
      }
    }
  } catch { }
  $stageDir = Join-Path $stageBase ([guid]::NewGuid().ToString('N'))
  $stagedSetup = $SetupFile
  try {
    [void][System.IO.Directory]::CreateDirectory($stageDir)
    $dest = Join-Path $stageDir (Split-Path $SetupFile -Leaf)
    Copy-Item -LiteralPath $SetupFile -Destination $dest -Force -ErrorAction Stop
    $stagedSetup = $dest
    Write-Log ("Sandbox: installer staged into a clean folder and handed over as '{0}'." -f $dest)
  } catch {
    # Fall back to the original location; the test may still work if that folder is mappable.
    Write-Log ("Sandbox: could not stage the installer into a clean folder ({0}); using the original path." -f $_.Exception.Message)
  }

  $work = Join-Path ([IO.Path]::GetTempPath()) ("wtgui-sbx-" + [guid]::NewGuid().ToString('N'))
  try { [void][System.IO.Directory]::CreateDirectory($work) } catch { }
  $runner = Join-Path $work 'run.ps1'

  # The runner reads the paths from environment variables the child inherits, so a setup path with
  # spaces or parentheses ("OnVUE-26.15.172 (1).exe") needs no command-line escaping.
  #
  # The child runs WITHOUT -NonInteractive on purpose: the module ends with a Read-Host ("Press enter
  # when you closed the sandbox"), and under -NonInteractive that throws outright ("Read and Prompt
  # not available").
  #
  # That Read-Host is NOT a nuisance to be silenced - it is what keeps the sandbox alive. The module
  # writes the .wsb and its mapped folders into its own temp directory and deletes them as soon as
  # the prompt returns, while WindowsSandbox.exe is only a launcher that returns immediately and
  # leaves the VM still booting. Feeding the prompt an empty stdin (which is what 0.15.7 did to stop
  # the GUI freezing) therefore pulled those folders away mid-boot, and the sandbox died with
  # "Das System kann den angegebenen Pfad nicht finden. (0x80070003)".
  #
  # So stdin stays OPEN here and the newline is written only once the sandbox has actually closed.
  # The window stays responsive because the wait loop pumps DoEvents, not because the prompt was
  # short-circuited.
  #
  # Output is captured on the PROCESS level by the parent, not with a PowerShell redirection inside
  # the runner. The module writes its "INFO: [WindowsSandbox] ..." lines straight to the console, not
  # through a PowerShell stream, so "*> file" caught nothing and the log lost exactly the lines needed
  # to tell why a sandbox refused to start. The parent reads both pipes ASYNCHRONOUSLY - reading them
  # synchronously while also holding stdin open is a deadlock waiting to happen.
  $runnerBody = @'
$ErrorActionPreference = "Stop"
try {
  Import-Module WinTuner -ErrorAction Stop
  $s = $env:WTGUI_SANDBOX_SETUP
  $a = $env:WTGUI_SANDBOX_ARGS
  if ([string]::IsNullOrWhiteSpace($a)) { Test-WtSetupFile -SetupFile $s }
  else { Test-WtSetupFile -SetupFile $s -InstallerArguments $a }
  exit 0
} catch {
  $m = "$($_.Exception.Message)"
  if ($m -match "(?i)Press enter" -or $m -match "(?i)NonInteractive" -or $m -match "(?i)Read and Prompt" -or $m -match "(?i)Cannot read keys" -or $m -match "(?i)console input") {
    exit 0
  }
  Write-Error $m
  exit 1
}
'@
  Set-Content -LiteralPath $runner -Value $runnerBody -Encoding utf8 -ErrorAction Stop

  # Environment on the start info rather than on $env:, so two runs can never read each other's
  # values and nothing has to be nulled out afterwards.
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $pwshExe
  foreach ($a in @('-NoProfile','-ExecutionPolicy','Bypass','-File', $runner)) { [void]$psi.ArgumentList.Add($a) }
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $psi.EnvironmentVariables['WTGUI_SANDBOX_SETUP'] = [string]$stagedSetup
  $psi.EnvironmentVariables['WTGUI_SANDBOX_ARGS']  = [string]$InstallerArguments
  $proc = $null
  $stdoutTask = $null
  $stderrTask = $null
  try {
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()
    # ReadToEndAsync, NOT an OutputDataReceived handler: a PowerShell scriptblock attached to that
    # event is invoked on a threadpool thread, where there is no runspace, and the whole application
    # dies with "There is no Runspace available to run scripts in this thread". Letting .NET do the
    # reading keeps every line of PowerShell on the UI thread.
    #
    # Both pipes are drained continuously, so holding stdin open cannot deadlock on a full buffer.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Phase 1: wait for the sandbox to come up. If it never does, there is nothing to wait for and
    # the prompt is released so the module can report whatever went wrong.
    $sandboxSeen = $false
    while (-not $proc.HasExited -and $sw.Elapsed.TotalSeconds -lt 120) {
      if (Test-WindowsSandboxRunning) { $sandboxSeen = $true; break }
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 200
    }
    if ($sandboxSeen) {
      Write-Log 'Sandbox is up. Waiting for it to be closed before letting the module clean up its mapped folders.'
      $out.SandboxStarted = $true
    } else {
      Write-Log 'No sandbox process appeared; releasing the module prompt so it can report the reason.'
    }

    # Phase 2: while it runs, keep waiting - and keep the window alive. The module must NOT clean up
    # yet: its temp folder holds the .wsb and every mapped folder the running VM depends on.
    while ($sandboxSeen -and -not $proc.HasExited) {
      if (-not (Test-WindowsSandboxRunning)) {
        Write-Log 'Sandbox was closed; releasing the module prompt so it can collect the results.'
        break
      }
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 400
      if ($sw.Elapsed.TotalMinutes -ge $TimeoutMinutes) { break }
    }

    # Release the Read-Host. Closing the stream is what actually ends it; the newline is for the case
    # where the module reads a line rather than to end-of-file.
    if (-not $proc.HasExited) {
      try { $proc.StandardInput.WriteLine(''); $proc.StandardInput.Flush() } catch { }
      try { $proc.StandardInput.Close() } catch { }
    }

    while (-not $proc.HasExited) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 150
      if ($sw.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
        try { $proc.Kill() } catch { }
        $out.ErrorMessage = "Sandbox test timed out after $TimeoutMinutes minute(s)."
        break
      }
    }
    # The reader tasks complete when the child closes its pipes, which happens as it exits.
    $stdout = ''
    $stderr = ''
    try { if ($stdoutTask) { [void]$stdoutTask.Wait(5000); if ($stdoutTask.IsCompletedSuccessfully) { $stdout = [string]$stdoutTask.Result } } } catch { }
    try { if ($stderrTask) { [void]$stderrTask.Wait(5000); if ($stderrTask.IsCompletedSuccessfully) { $stderr = [string]$stderrTask.Result } } } catch { }
    # Strip ANSI colour escapes so the log and the error box show plain text, not "[31;1m...".
    $clean = (("$stdout`n$stderr") -replace '\x1b\[[0-9;]*[A-Za-z]', '').Trim()
    $out.Output = $clean
    if ($clean -match '0x80070005' -or $clean -match '(?i)access denied' -or $clean -match '(?i)Zugriff verweigert') {
      $out.AccessDenied = $true
    }
    if (-not $out.ErrorMessage) {
      if ($proc.ExitCode -eq 0) {
        $out.Succeeded = $true
      } else {
        $firstErr = (($stderr -replace '\x1b\[[0-9;]*[A-Za-z]', '') -split "`r?`n" | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
        $out.ErrorMessage = if ($firstErr) { $firstErr.Trim() } else { "Sandbox helper exited with code $($proc.ExitCode)." }
      }
    }
  } catch {
    $out.ErrorMessage = $_.Exception.Message
  } finally {
    try { if ($proc) { $proc.Dispose() } } catch { }
    # Only the runner/redirect scratch is safe to delete now. The staged installer under $stageDir is
    # left in place: the sandbox may still be reading it, so it is swept on a later run instead.
    try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
  return $out
}

# True when the output folder is the source folder itself or sits inside it. Either way the packager
# would be asked to write its result into the tree it is compressing, which it declines.
# Non-existent destinations are fine: the caller creates them, and a folder that is not there yet
# cannot be inside the source.
function Test-DestinationInsideSource {
  param([string]$SourcePath, [string]$DestinationPath)
  if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($DestinationPath)) { return $false }
  if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { return $false }
  try {
    $srcFull = (Resolve-Path -LiteralPath $SourcePath).Path.TrimEnd([char]'\')
    $dstFull = if (Test-Path -LiteralPath $DestinationPath) {
      (Resolve-Path -LiteralPath $DestinationPath).Path.TrimEnd([char]'\')
    } else {
      ([IO.Path]::GetFullPath($DestinationPath)).TrimEnd([char]'\')
    }
    if ([string]::Equals($srcFull, $dstFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $dstFull.StartsWith($srcFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function New-OwnIntuneWinPackage {
  param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$SetupFile,
    [Parameter(Mandatory)][string]$DestinationPath
  )
  $out = @{ Success = $false; ErrorMessage = $null; PackagePath = $null }
  if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    $out.ErrorMessage = (Get-UiString 'OwnPkgSourceMissing'); return $out
  }
  if (-not (Test-Path -LiteralPath $SetupFile -PathType Leaf)) {
    $out.ErrorMessage = (Get-UiString 'OwnPkgSetupMissing'); return $out
  }
  if (-not (Test-SetupFileInsideSource -SourcePath $SourcePath -SetupFile $SetupFile)) {
    $out.ErrorMessage = (Get-UiString 'OwnPkgSetupNotInSource'); return $out
  }
  $srcFull = (Resolve-Path -LiteralPath $SourcePath).Path.TrimEnd([char]'\')
  $setupFull = (Resolve-Path -LiteralPath $SetupFile).Path
  # The packager compresses the ENTIRE source folder, so it refuses to write its output into that
  # same folder. It signals that refusal as a WARNING rather than a terminating error, which slips
  # straight past -ErrorAction Stop: the call returns in well under a second, reports success, and
  # the only symptom left is a missing artefact. Caught here so the message names the real cause.
  if (Test-DestinationInsideSource -SourcePath $SourcePath -DestinationPath $DestinationPath) {
    $out.ErrorMessage = (Get-UiString 'OwnPkgDestInsideSource'); return $out
  }
  try {
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
      [void][System.IO.Directory]::CreateDirectory($DestinationPath)
    }
    Write-Log ("Packaging own installer: source '{0}', setup '{1}' -> '{2}'" -f $srcFull, (Split-Path $setupFull -Leaf), $DestinationPath)

    # Every stream is captured, not just the pipeline. The packager reports a refusal as a WARNING
    # and its progress as INFORMATION, so -ErrorAction Stop never fires and the only thing left to
    # go on used to be a missing file. Recording what it actually said turns "no artefact" into a
    # diagnosis. The stopwatch matters too: a refusal returns in well under a second, while real
    # packaging takes seconds, which alone tells the two apart.
    $pkgWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $packagerSaid = [System.Collections.Generic.List[string]]::new()
    try {
      New-IntuneWinPackage -SourcePath $srcFull -SetupFile $setupFull -DestinationPath $DestinationPath -ErrorAction Stop *>&1 |
        ForEach-Object {
          $line = [string]$_
          if (-not [string]::IsNullOrWhiteSpace($line)) { [void]$packagerSaid.Add($line.Trim()) }
        }
    } finally {
      $pkgWatch.Stop()
      foreach ($line in $packagerSaid) { Write-Log ("Packager: {0}" -f $line) }
      Write-Log ("Packager finished in {0:n1}s." -f $pkgWatch.Elapsed.TotalSeconds)
    }

    # Recursive on purpose: the artefact is normally written straight into the destination, but a
    # non-recursive look would silently miss it if the packager ever nests it in a subfolder.
    $built = Get-ChildItem -LiteralPath $DestinationPath -Filter '*.intunewin' -File -Recurse -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $built) {
      # Hand the packager's own words to the caller. Without them the message named the symptom and
      # left the cause in the dark, which is exactly what happened with the source/destination clash.
      $detail = if ($packagerSaid.Count -gt 0) {
        ($packagerSaid | Where-Object { $_ -match '(?i)warn|error|fail' } | Select-Object -First 3) -join ' | '
      } else { '' }
      if (-not $detail -and $packagerSaid.Count -gt 0) { $detail = ($packagerSaid | Select-Object -Last 2) -join ' | ' }
      if ($detail) { throw ((Get-UiString 'OwnPkgNoArtifactDetail') -f $detail) }
      throw (Get-UiString 'OwnPkgNoArtifact')
    }
    $out.Success = $true
    $out.PackagePath = $built.FullName
    Write-Log ("Own installer packaged: {0} ({1:n1} MB)" -f $built.FullName, ($built.Length / 1MB))
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Packaging own installer FAILED: {0}" -f $out.ErrorMessage)
  }
  return $out
}

# Wraps Deploy-WtWin32ContentVersion: uploads a new content version INTO an existing Intune app.
# The alternative used everywhere else is "create a new app and supersede the old one", which is
# what produced five parallel Firefox objects in the test tenant. Here the app id, its assignments
# and its history stay untouched - only the payload changes.
function Update-ExistingAppContent {
  param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$IntuneWinFile,
    [string]$AppName = ''
  )
  $out = @{ Success = $false; ErrorMessage = $null }
  if (-not (Test-GuidString $AppId)) { $out.ErrorMessage = 'invalid app id'; return $out }
  if (-not (Test-Path -LiteralPath $IntuneWinFile -PathType Leaf)) {
    $out.ErrorMessage = (Get-UiString 'ContentReplaceFileMissing'); return $out
  }
  try {
    Write-Log ("Replacing content of '{0}' ({1}) with '{2}'." -f $AppName, $AppId, $IntuneWinFile)
    Deploy-WtWin32ContentVersion -IntuneWinFile $IntuneWinFile -AppId $AppId -ErrorAction Stop | Out-Null
    $out.Success = $true
    Clear-Win32AppsCache   # the app changed; the next read must not serve the pre-upload state
    Write-Log ("Content replaced for '{0}' ({1})." -f $AppName, $AppId)
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Replacing content FAILED for '{0}' ({1}): {2}" -f $AppName, $AppId, $out.ErrorMessage)
  }
  return $out
}

$tabOwnPackage = New-Object System.Windows.Forms.Panel
# Four stacked cards are taller than most windows; without this the lower ones are unreachable.
$tabOwnPackage.AutoScroll = $true

$ownTitle = New-Object System.Windows.Forms.Label
$ownTitle.Text = Get-UiString 'TabOwnPackage'
$ownTitle.Location = New-Object System.Drawing.Point(16, 14)
$ownTitle.AutoSize = $true
$ownTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$tabOwnPackage.Controls.Add($ownTitle)
[void](Add-SectionInfoBadge -Parent $tabOwnPackage -AfterLabel $ownTitle -TextKey 'InfoOwnPackage')

# --- Card 1: build an .intunewin from any folder ---
$cardOwnBuild = New-Card -X 16 -Y 48 -W 726 -H 288
$tabOwnPackage.Controls.Add($cardOwnBuild)

$ownBuildLabel = New-Object System.Windows.Forms.Label
$ownBuildLabel.Text = Get-UiString 'OwnPkgSectionTitle'
$ownBuildLabel.Location = New-Object System.Drawing.Point(14, 10)
$ownBuildLabel.AutoSize = $true
$ownBuildLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardOwnBuild.Controls.Add($ownBuildLabel)
# Die drei Schrittkarten waren die einzigen im Programm ganz ohne Info-Badge - deshalb musste der
# Absatz darunter beides tragen: die Bedienung UND den Hintergrund. Jetzt: ein Satz inline, der
# Rest hier.
[void](Add-SectionInfoBadge -Parent $cardOwnBuild -AfterLabel $ownBuildLabel -TextKey 'InfoOwnStep1')

$ownSourceLabel = New-Object System.Windows.Forms.Label
$ownSourceLabel.Text = Get-UiString 'OwnPkgSourceLabel'
$ownSourceLabel.Location = New-Object System.Drawing.Point(14, 86)
$ownSourceLabel.AutoSize = $true
$cardOwnBuild.Controls.Add($ownSourceLabel)

$ownSourceBox = New-Object System.Windows.Forms.TextBox
$ownSourceBox.Width = 400
$ownSourceBox.PlaceholderText = Get-UiString 'OwnPkgSourcePlaceholder'
$ownSourceHost = New-RoundedInput -Inner $ownSourceBox -X 160 -Y 80 -W 400 -H 32
$cardOwnBuild.Controls.Add($ownSourceHost)

$ownSourceButton = New-Object System.Windows.Forms.Button
$ownSourceButton.Tag = 'btn-secondary'
$ownSourceButton.Text = Get-UiString 'BrowsePathButton'
$ownSourceButton.Location = New-Object System.Drawing.Point(572, 80)
$ownSourceButton.Size = New-Object System.Drawing.Size(140, 32)
$cardOwnBuild.Controls.Add($ownSourceButton)

$ownSetupLabel = New-Object System.Windows.Forms.Label
$ownSetupLabel.Text = Get-UiString 'OwnPkgSetupLabel'
$ownSetupLabel.Location = New-Object System.Drawing.Point(14, 46)
$ownSetupLabel.AutoSize = $true
$cardOwnBuild.Controls.Add($ownSetupLabel)

$ownSetupBox = New-Object System.Windows.Forms.TextBox
$ownSetupBox.Width = 400
$ownSetupBox.PlaceholderText = Get-UiString 'OwnPkgSetupPlaceholder'
$ownSetupHost = New-RoundedInput -Inner $ownSetupBox -X 160 -Y 40 -W 400 -H 32
$cardOwnBuild.Controls.Add($ownSetupHost)

$ownSetupButton = New-Object System.Windows.Forms.Button
$ownSetupButton.Tag = 'btn-secondary'
$ownSetupButton.Text = Get-UiString 'BrowsePathButton'
$ownSetupButton.Location = New-Object System.Drawing.Point(572, 40)
$ownSetupButton.Size = New-Object System.Drawing.Size(140, 32)
$cardOwnBuild.Controls.Add($ownSetupButton)

$ownDestLabel = New-Object System.Windows.Forms.Label
$ownDestLabel.Text = Get-UiString 'OwnPkgDestLabel'
$ownDestLabel.Location = New-Object System.Drawing.Point(14, 126)
$ownDestLabel.AutoSize = $true
$cardOwnBuild.Controls.Add($ownDestLabel)

$ownDestBox = New-Object System.Windows.Forms.TextBox
$ownDestBox.Width = 400
$ownDestBox.Text = Get-DefaultPackagePath
$ownDestHost = New-RoundedInput -Inner $ownDestBox -X 160 -Y 120 -W 400 -H 32
$cardOwnBuild.Controls.Add($ownDestHost)

$ownDestButton = New-Object System.Windows.Forms.Button
$ownDestButton.Tag = 'btn-secondary'
$ownDestButton.Text = Get-UiString 'BrowsePathButton'
$ownDestButton.Location = New-Object System.Drawing.Point(572, 120)
$ownDestButton.Size = New-Object System.Drawing.Size(140, 32)
$cardOwnBuild.Controls.Add($ownDestButton)

$ownBuildButton = New-Object System.Windows.Forms.Button
$ownBuildButton.Text = Get-UiString 'OwnPkgBuildButton'
$ownBuildButton.Location = New-Object System.Drawing.Point(14, 166)
$ownBuildButton.Size = New-Object System.Drawing.Size(220, 32)
$cardOwnBuild.Controls.Add($ownBuildButton)

$ownBuildHint = New-Object System.Windows.Forms.Label
$ownBuildHint.Tag = 'hint'
$ownBuildHint.Text = Get-UiString 'OwnPkgHint'
$ownBuildHint.Location = New-Object System.Drawing.Point(14, 204)
# 68 px: the German text runs to three wrapped lines and 48 clipped the last one mid-sentence
# ("...kann unten auch den Inhalt einer v").
# Hoehe aus dem Text statt aus einer handgezaehlten Zahl - siehe Update-StackedCards.
$ownBuildHint.AutoSize = $true
$ownBuildHint.MaximumSize = New-Object System.Drawing.Size(698, 0)
$cardOwnBuild.Controls.Add($ownBuildHint)

# --- Card 2: replace the content of an existing Intune app ---
$cardContentReplace = New-Card -X 16 -Y 1248 -W 726 -H 296
$tabOwnPackage.Controls.Add($cardContentReplace)

$replaceLabel = New-Object System.Windows.Forms.Label
$replaceLabel.Text = Get-UiString 'ContentReplaceSectionTitle'
$replaceLabel.Location = New-Object System.Drawing.Point(14, 10)
$replaceLabel.AutoSize = $true
$replaceLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardContentReplace.Controls.Add($replaceLabel)
[void](Add-SectionInfoBadge -Parent $cardContentReplace -AfterLabel $replaceLabel -TextKey 'InfoContentReplace')

$replaceAppLabel = New-Object System.Windows.Forms.Label
$replaceAppLabel.Text = Get-UiString 'ContentReplaceAppLabel'
$replaceAppLabel.Location = New-Object System.Drawing.Point(14, 46)
$replaceAppLabel.AutoSize = $true
$cardContentReplace.Controls.Add($replaceAppLabel)

$replaceAppCombo = New-Object System.Windows.Forms.ComboBox
$replaceAppCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$replaceAppCombo.Location = New-Object System.Drawing.Point(160, 42)
$replaceAppCombo.Width = 400
$cardContentReplace.Controls.Add($replaceAppCombo)

$replaceLoadButton = New-Object System.Windows.Forms.Button
$replaceLoadButton.Tag = 'btn-secondary'
$replaceLoadButton.Text = Get-UiString 'ContentReplaceLoadButton'
$replaceLoadButton.Location = New-Object System.Drawing.Point(572, 40)
$replaceLoadButton.Size = New-Object System.Drawing.Size(140, 32)
$cardContentReplace.Controls.Add($replaceLoadButton)

$replaceFileLabel = New-Object System.Windows.Forms.Label
$replaceFileLabel.Text = Get-UiString 'ContentReplaceFileLabel'
$replaceFileLabel.Location = New-Object System.Drawing.Point(14, 86)
$replaceFileLabel.AutoSize = $true
$cardContentReplace.Controls.Add($replaceFileLabel)

$replaceFileBox = New-Object System.Windows.Forms.TextBox
$replaceFileBox.Width = 400
$replaceFileBox.PlaceholderText = Get-UiString 'ContentReplaceFilePlaceholder'
$replaceFileHost = New-RoundedInput -Inner $replaceFileBox -X 160 -Y 80 -W 400 -H 32
$cardContentReplace.Controls.Add($replaceFileHost)

$replaceFileButton = New-Object System.Windows.Forms.Button
$replaceFileButton.Tag = 'btn-secondary'
$replaceFileButton.Text = Get-UiString 'BrowsePathButton'
$replaceFileButton.Location = New-Object System.Drawing.Point(572, 80)
$replaceFileButton.Size = New-Object System.Drawing.Size(140, 32)
$cardContentReplace.Controls.Add($replaceFileButton)

$replaceRunButton = New-Object System.Windows.Forms.Button
$replaceRunButton.Text = Get-UiString 'ContentReplaceRunButton'
$replaceRunButton.Location = New-Object System.Drawing.Point(14, 126)
$replaceRunButton.Size = New-Object System.Drawing.Size(260, 32)
$cardContentReplace.Controls.Add($replaceRunButton)

$replaceHint = New-Object System.Windows.Forms.Label
$replaceHint.Tag = 'hint'
$replaceHint.Text = Get-UiString 'ContentReplaceHint'
$replaceHint.Location = New-Object System.Drawing.Point(14, 166)
# Hoehe aus dem Text statt aus einer handgezaehlten Zahl - siehe Update-StackedCards.
$replaceHint.AutoSize = $true
$replaceHint.MaximumSize = New-Object System.Drawing.Size(698, 0)
$cardContentReplace.Controls.Add($replaceHint)

$script:contentReplaceApps = @()

# Live feedback for the three paths, so the two rules that used to surface only as a failed build
# are visible while you are still choosing: the installer has to sit inside the source folder, and
# the output folder must not be that same folder. Amber means "this will not work".
function Update-OwnPackageHint {
  try {
    if (-not $ownBuildHint) { return }
    $source = $ownSourceBox.Text.Trim()
    $setup  = $ownSetupBox.Text.Trim()
    $dest   = $ownDestBox.Text.Trim()
    $problem = ''
    if ($source -and $setup -and (Test-Path -LiteralPath $setup -PathType Leaf) -and
        -not (Test-SetupFileInsideSource -SourcePath $source -SetupFile $setup)) {
      $problem = Get-UiString 'OwnPkgSetupNotInSource'
    } elseif ($source -and $dest -and (Test-DestinationInsideSource -SourcePath $source -DestinationPath $dest)) {
      $problem = Get-UiString 'OwnPkgDestInsideSourceShort'
    }
    if ($problem) {
      $ownBuildHint.Text = $problem
      $ownBuildHint.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
      $ownBuildHint.Text = Get-UiString 'OwnPkgHint'
      $ownBuildHint.ForeColor = $script:currentTheme.SecondaryForeColor
    }
  } catch { }   # class 3: a hint must never block the card
}

$ownSourceButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = Get-UiString 'OwnPkgSourceLabel'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $ownSourceBox.Text = $dlg.SelectedPath
    Update-OwnPackageHint
  }
  $dlg.Dispose()
})

$ownSetupButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = 'Installer (*.exe;*.msi)|*.exe;*.msi|All files (*.*)|*.*'
  if ($ownSourceBox.Text.Trim() -and (Test-Path -LiteralPath $ownSourceBox.Text.Trim())) {
    $dlg.InitialDirectory = $ownSourceBox.Text.Trim()
  }
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $ownSetupBox.Text = $dlg.FileName
    # The source folder follows from the installer instead of being a third free choice. Picking
    # two folders that had to match, and only learning from a failed build that they did not, was
    # the actual complaint. The field stays editable for the case where the payload lives one level
    # up, and it is only overwritten when the current value does not already contain the installer.
    $currentSource = $ownSourceBox.Text.Trim()
    if (-not (Test-SetupFileInsideSource -SourcePath $currentSource -SetupFile $dlg.FileName)) {
      $derived = Split-Path -Parent $dlg.FileName
      if ($derived) {
        $ownSourceBox.Text = $derived
        Write-Log ("Source folder derived from the chosen installer: {0}" -f $derived)
      }
    }
    Update-OwnPackageHint
  }
  $dlg.Dispose()
})

$ownDestButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = Get-UiString 'OwnPkgDestLabel'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $ownDestBox.Text = $dlg.SelectedPath
    Update-OwnPackageHint
  }
  $dlg.Dispose()
})

# Typing counts too, not just browsing.
$ownSourceBox.Add_TextChanged({ Update-OwnPackageHint })
$ownSetupBox.Add_TextChanged({ Update-OwnPackageHint })
$ownDestBox.Add_TextChanged({ Update-OwnPackageHint })
Update-OwnPackageHint

$ownBuildButton.Add_Click({
  if (Test-UiBusy) { return }
  try {
    # Checked HERE, before the call: the parameters are mandatory strings, so an empty box makes
    # PowerShell refuse at parameter binding with "Cannot bind argument to parameter 'SourcePath'
    # because it is an empty string" - a .NET message about the plumbing, shown to someone who
    # simply had not filled in a field. The checks inside the function never got a chance to run.
    $sourceText = $ownSourceBox.Text.Trim()
    $setupText  = $ownSetupBox.Text.Trim()
    $destText   = $ownDestBox.Text.Trim()
    if (-not $sourceText) { Update-Status (Get-UiString 'OwnPkgSourceMissing'); return }
    if (-not $setupText)  { Update-Status (Get-UiString 'OwnPkgSetupMissing');  return }
    if (-not $destText)   { Update-Status (Get-UiString 'OwnPkgDestMissing');   return }

    $ownBuildButton.Enabled = $false
    # Said out loud before it happens: the packaging tool runs to completion without yielding, so the
    # window stops repainting for as long as it takes - measured at over four minutes for a large
    # installer. Without a word up front that looks like a hang, and people click again or kill it.
    Update-Status (Get-UiString 'OwnPkgBuildingStatus')
    Write-Log ("Packaging '{0}' into '{1}' - this can take several minutes for a large installer, and the window will not repaint while it runs. This is expected; do not close it." -f (Split-Path $setupText -Leaf), $destText)
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $result = New-OwnIntuneWinPackage -SourcePath $sourceText -SetupFile $setupText -DestinationPath $destText
    if ($result.ErrorMessage) {
      Update-Status ((Get-UiString 'OwnPkgBuildFailedStatus') -f $result.ErrorMessage)
      return
    }
    Update-Status ((Get-UiString 'OwnPkgBuiltStatus') -f $result.PackagePath)
    # Hand the fresh package to BOTH follow-up cards: step 3 (create a Win32 app) now has its own
    # visible field, and the replace card keeps its field too. Full path in the Tag, file name in
    # the box so the choice is visible at a glance.
    $replaceFileBox.Text = [string]$result.PackagePath
    $win32PackageBox.Tag = [string]$result.PackagePath
    $win32PackageBox.Text = Split-Path $result.PackagePath -Leaf
    # ... and say so. The hand-off used to happen silently, two cards further down, so it looked as
    # if the built package led nowhere and the next step had to be started from scratch.
    $ownBuildHint.Text = (Get-UiString 'OwnPkgHandedOn') -f (Split-Path $result.PackagePath -Leaf)
    $ownBuildHint.ForeColor = $script:currentTheme.ForeColor
    Write-Log ("Package handed on to the cards below: {0}" -f $result.PackagePath)
  } catch {
    Write-Log ("Own package build error: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'OwnPkgBuildFailedStatus') -f $_.Exception.Message)
  } finally {
    $ownBuildButton.Enabled = $true
  }
})

$replaceLoadButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try {
    $replaceLoadButton.Enabled = $false
    Update-Status (Get-UiString 'ContentReplaceLoadingStatus')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    # Only Win32 apps: a content version cannot be pushed into a Store or Office app.
    #
    # Read straight from Graph, not through Get-CachedWin32Apps: the module's inventory only contains
    # apps carrying its own '[WinTuner|' notes marker, so apps created by the card above this one
    # were missing from this very list - and the user's only way out was to create a duplicate app,
    # which is what this feature exists to avoid.
    $script:contentReplaceApps = @(Get-TenantWin32Apps | Sort-Object Name)
    $replaceAppCombo.Items.Clear()
    foreach ($a in $script:contentReplaceApps) {
      [void]$replaceAppCombo.Items.Add(('{0}  ({1})' -f [string]$a.Name, [string]$a.CurrentVersion))
    }
    if ($replaceAppCombo.Items.Count -gt 0) { $replaceAppCombo.SelectedIndex = 0 }
    Update-Status ((Get-UiString 'ContentReplaceLoadedStatus') -f $replaceAppCombo.Items.Count)
  } catch {
    Write-Log ("Loading Win32 apps for content replacement failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'ContentReplaceLoadFailedStatus') -f $_.Exception.Message)
  } finally {
    $replaceLoadButton.Enabled = $true
  }
})

$replaceFileButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = 'Intune package (*.intunewin)|*.intunewin|All files (*.*)|*.*'
  if ($ownDestBox.Text.Trim() -and (Test-Path -LiteralPath $ownDestBox.Text.Trim())) {
    $dlg.InitialDirectory = $ownDestBox.Text.Trim()
  }
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $replaceFileBox.Text = $dlg.FileName }
  $dlg.Dispose()
})

$replaceRunButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  $index = [int]$replaceAppCombo.SelectedIndex
  if ($index -lt 0 -or $index -ge $script:contentReplaceApps.Count) {
    Update-Status (Get-UiString 'ContentReplaceNoApp'); return
  }
  $app = $script:contentReplaceApps[$index]
  $file = $replaceFileBox.Text.Trim()
  if (-not $file) { Update-Status (Get-UiString 'ContentReplaceNoFile'); return }

  if (-not (Confirm-ChangeAction `
      -Text ((Get-UiString 'ContentReplaceConfirm') -f $app.Name, $app.CurrentVersion, (Split-Path $file -Leaf)) `
      -Title (Get-UiString 'ConfirmTitle') `
      -LogContext ("content replacement of '{0}'" -f $app.Name))) { return }

  try {
    $replaceRunButton.Enabled = $false
    Update-Status ((Get-UiString 'ContentReplaceRunningStatus') -f $app.Name)
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $result = Update-ExistingAppContent -AppId ([string]$app.GraphId) -IntuneWinFile $file -AppName ([string]$app.Name)
    if ($result.ErrorMessage) {
      Update-Status ((Get-UiString 'ContentReplaceFailedStatus') -f $result.ErrorMessage)
    } else {
      Update-Status ((Get-UiString 'ContentReplaceDoneStatus') -f $app.Name)
    }
  } catch {
    Write-Log ("Content replacement error: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'ContentReplaceFailedStatus') -f $_.Exception.Message)
  } finally {
    $replaceRunButton.Enabled = $true
  }
})

# --- Working out a detection rule ---
# Intune needs to know how to tell "installed" from "not installed". For an MSI that is simply the
# product code. For an EXE there is no such thing, so the practical route is: record the uninstall
# registry before, install, and look at what appeared. That is exactly what an admin would do by
# hand with regedit - just without missing an entry.

$script:detectionSnapshot = $null

# The three places Windows registers uninstall entries. WOW6432Node matters because a 32-bit
# installer on 64-bit Windows lands there, and that is the path the detection rule has to use.
$script:uninstallHives = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Get-UninstallSnapshot {
  $entries = @{}
  foreach ($hive in $script:uninstallHives) {
    if (-not (Test-Path -LiteralPath $hive)) { continue }
    foreach ($key in (Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue)) {
      try {
        $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
        $entries[$key.PSPath] = [pscustomobject]@{
          RegistryPath    = ($hive + '\' + $key.PSChildName)
          KeyName         = [string]$key.PSChildName
          DisplayName     = [string]$props.DisplayName
          DisplayVersion  = [string]$props.DisplayVersion
          Publisher       = [string]$props.Publisher
          InstallLocation = [string]$props.InstallLocation
          # The uninstall command, which Intune needs and which was previously discarded even
          # though it sits in the very key being read. QuietUninstallString is preferred when the
          # vendor supplies one: it already carries the silent switches, whereas UninstallString
          # usually opens a window and would leave an Intune uninstall hanging forever.
          UninstallString      = [string]$props.UninstallString
          QuietUninstallString = [string]$props.QuietUninstallString
        }
      } catch { }   # class 3: an unreadable key must not abort the snapshot
    }
  }
  return $entries
}

# What changed between two snapshots. Split out of the compare button so it can be tested without a
# machine to install on - the button is a UI handler, this is the actual answer.
#
# "New" alone is not enough: an application that is already installed is upgraded in place, its
# uninstall key is rewritten rather than added, and the comparison then reports nothing on exactly
# the machines people test on. Changed entries carry PreviousVersion so the result can say so.
function Compare-UninstallSnapshot {
  param(
    [Parameter(Mandatory)][hashtable]$Before,
    [Parameter(Mandatory)][hashtable]$After
  )
  $new = [System.Collections.Generic.List[object]]::new()
  $changed = [System.Collections.Generic.List[object]]::new()
  foreach ($k in $After.Keys) {
    if (-not $Before.ContainsKey($k)) { $new.Add($After[$k]); continue }
    # Only the version is compared. Display name and publisher can be rewritten by unrelated
    # servicing without anything being installed; a changed version means an installer ran.
    # Named $prev, not $before: PowerShell variable names are case-insensitive, so `$before = ...`
    # would assign into the [hashtable]$Before parameter and fail the cast on the first entry.
    $prev = $Before[$k]
    if ($After[$k].DisplayVersion -and $prev.DisplayVersion -ne $After[$k].DisplayVersion) {
      $entry = $After[$k].PSObject.Copy()
      Add-Member -InputObject $entry -NotePropertyName 'PreviousVersion' -NotePropertyValue ([string]$prev.DisplayVersion)
      $changed.Add($entry)
    }
  }
  return [pscustomobject]@{ New = @($new); Changed = @($changed) }
}

# Turns the newly appeared entries into text that can be pasted into an Intune detection rule.
# Holds what the last comparison (or MSI read) found, so "apply to the form" has something to work
# with. Everything the detection step discovers used to end up as text to retype by hand.
$script:detectionCandidate = $null

# Reads an MSI's own property table through the Windows Installer COM object. Deliberately not the
# module's Show-MsiInfo: this returns typed values instead of text meant for a human, and it is the
# same source the installer itself uses, so the product code is guaranteed to match what lands in
# the uninstall registry.
# The two commands Intune needs for an MSI. Quoted because paths contain spaces, /qn for silent.
# REBOOT=ReallySuppress keeps the installer from restarting the device behind Intune's back;
# restart behaviour belongs in the assignment, not in the command line.
function Get-MsiInstallCommand {
  param([Parameter(Mandatory)][string]$MsiPath)
  return ('msiexec /i "{0}" /qn /norestart REBOOT=ReallySuppress' -f (Split-Path $MsiPath -Leaf))
}

function Get-MsiUninstallCommand {
  param([Parameter(Mandatory)][string]$ProductCode)
  return ('msiexec /x {0} /qn /norestart' -f $ProductCode)
}

function Get-MsiProperties {
  param([Parameter(Mandatory)][string]$MsiPath)
  $installer = $null
  $database = $null
  try {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    # 0 = read-only; anything else would risk modifying the file being inspected.
    $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))
    $out = @{}
    foreach ($name in @('ProductCode', 'ProductVersion', 'ProductName', 'Manufacturer')) {
      try {
        $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database,
          @("SELECT Value FROM Property WHERE Property = '$name'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($record) {
          $out[$name] = [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
        }
        $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
      } catch { }   # class 3: a missing property is not fatal, the others still help
    }
    return $out
  } catch {
    Write-Log ("Reading MSI properties failed: {0}" -f $_.Exception.Message)
    return $null
  } finally {
    foreach ($com in @($database, $installer)) {
      if ($com) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($com) } catch { } }
    }
  }
}

# Changed entries are listed after the new ones, never mixed in: an app that was already installed
# updates its existing key in place instead of adding one, so a plain "what is new" comparison finds
# nothing at all on exactly the machines people test on. Measured case: the Firefox installer ran for
# 45 seconds, returned 0, and the key count stayed at 161 - because 'Mozilla Firefox' carries no
# version in its key name. The entry is still a perfectly good detection rule, so it is offered,
# just labelled for what it is.
function Format-DetectionSuggestion {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][array]$NewEntries,
    [AllowEmptyCollection()][array]$ChangedEntries = @()
  )
  if ($NewEntries.Count -eq 0 -and $ChangedEntries.Count -eq 0) { return (Get-UiString 'DetectNoChange') }
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($e in (@($NewEntries) + @($ChangedEntries))) {
    $lines.Add('--- {0} ---' -f ([string]$e.DisplayName))
    if ($null -ne $e.PreviousVersion) {
      # Doubly parenthesised on purpose: inside a method call the comma would be read as an argument
      # separator, so -f would receive only the first value and throw.
      $lines.Add((((Get-UiString 'DetectUpdatedNote') -f ([string]$e.PreviousVersion), ([string]$e.DisplayVersion))))
    }
    if ($e.Publisher)       { $lines.Add(('  {0}: {1}' -f (Get-UiString 'DetectPublisher'), $e.Publisher)) }
    if ($e.DisplayVersion)  { $lines.Add(('  {0}: {1}' -f (Get-UiString 'DetectVersion'), $e.DisplayVersion)) }
    if ($e.InstallLocation) { $lines.Add(('  {0}: {1}' -f (Get-UiString 'DetectInstallLocation'), $e.InstallLocation)) }
    $uninstall = if ($e.QuietUninstallString) { $e.QuietUninstallString } else { $e.UninstallString }
    if ($uninstall) { $lines.Add(('  {0}: {1}' -f (Get-UiString 'DetectUninstallCommand'), $uninstall)) }
    $lines.Add('')
    $lines.Add(('  ' + (Get-UiString 'DetectRuleHeading')))
    $lines.Add(('    {0}: {1}' -f (Get-UiString 'DetectRuleKeyPath'), $e.RegistryPath))
    $lines.Add(('    {0}: DisplayVersion' -f (Get-UiString 'DetectRuleValueName')))
    if ($e.DisplayVersion) {
      $lines.Add(('    {0}: {1}' -f (Get-UiString 'DetectRuleComparison'), $e.DisplayVersion))
    }
    # A 32-bit installer registers under WOW6432Node; Intune needs that flag set explicitly or the
    # rule silently never matches on 64-bit clients.
    if ($e.RegistryPath -like '*WOW6432Node*') { $lines.Add('    ' + (Get-UiString 'DetectRule32Bit')) }
    $lines.Add('')
  }
  return ($lines -join "`r`n")
}

$cardDetect = New-Card -X 16 -Y 348 -W 726 -H 430
$tabOwnPackage.Controls.Add($cardDetect)

$detectLabel = New-Object System.Windows.Forms.Label
$detectLabel.Text = Get-UiString 'DetectSectionTitle'
$detectLabel.Location = New-Object System.Drawing.Point(14, 10)
$detectLabel.AutoSize = $true
$detectLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardDetect.Controls.Add($detectLabel)
[void](Add-SectionInfoBadge -Parent $cardDetect -AfterLabel $detectLabel -TextKey 'InfoOwnStep2')

# One-click path for this whole card: primary (not 'btn-secondary') so it reads as the recommended
# action, sitting at the top-right of the card. The handler further down orchestrates the manual
# step buttons below. Placed on the title row - the shortened title ends near x=230, this starts at
# x=430, so they never overlap.
$detectAutoButton = New-Object System.Windows.Forms.Button
$detectAutoButton.Text = Get-UiString 'DetectAutoButton'
$detectAutoButton.Location = New-Object System.Drawing.Point(430, 6)
$detectAutoButton.Size = New-Object System.Drawing.Size(282, 30)
$cardDetect.Controls.Add($detectAutoButton)

# Step 2 stands on its own: the installer can be picked HERE.
#
# Everything in this card works off the installer chosen in step 1 - and it never needed step 1 to
# have BUILT anything, only to have a file selected. That was invisible: the card read as if
# "Paket erstellen" had to run first, so users sat through a package build (Logi Tune: over four
# minutes) purely to get to the detection rule.
#
# Note what this does NOT offer, on purpose: picking an .intunewin here. A detection rule can only
# be found by installing the software, and an .intunewin is a packaged archive - it cannot be
# installed. For an existing package the way in is step 3 ("Paketdatei wählen..."), which does take
# an .intunewin.
$detectSetupLabel = New-Object System.Windows.Forms.Label
$detectSetupLabel.Text = Get-UiString 'DetectInstallerLabel'
$detectSetupLabel.Location = New-Object System.Drawing.Point(14, 47)
$detectSetupLabel.AutoSize = $true
$cardDetect.Controls.Add($detectSetupLabel)

$detectSetupBox = New-Object System.Windows.Forms.TextBox
$detectSetupBox.ReadOnly = $true
$detectSetupBox.Width = 336
$detectSetupBox.PlaceholderText = Get-UiString 'DetectInstallerNone'
$detectSetupHost = New-RoundedInput -Inner $detectSetupBox -X 200 -Y 40 -W 336 -H 32
$cardDetect.Controls.Add($detectSetupHost)

$detectSetupPickButton = New-Object System.Windows.Forms.Button
$detectSetupPickButton.Tag = 'btn-secondary'
$detectSetupPickButton.Text = Get-UiString 'DetectInstallerPickButton'
$detectSetupPickButton.Location = New-Object System.Drawing.Point(546, 40)
$detectSetupPickButton.Size = New-Object System.Drawing.Size(166, 32)
$cardDetect.Controls.Add($detectSetupPickButton)

# One source of truth: the installer path lives in step 1's box, this only mirrors it. Otherwise the
# two cards could disagree about which file the detection ran against - and the rule would be
# derived from one installer while the package contained another.
function Update-DetectInstallerDisplay {
  try {
    $path = [string]$ownSetupBox.Text.Trim()
    $detectSetupBox.Text = if ($path) { Split-Path $path -Leaf } else { '' }
    try { $toolTip.SetToolTip($detectSetupBox, $path) } catch { Write-LogDebug 'detect installer tooltip' }
  } catch { }   # class 3: a mirrored label must never break the card
}

$detectSetupPickButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = 'Installer (*.exe;*.msi)|*.exe;*.msi|All files (*.*)|*.*'
  $current = [string]$ownSetupBox.Text.Trim()
  if ($current) {
    $dir = try { Split-Path -LiteralPath $current -Parent } catch { '' }
    if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) { $dlg.InitialDirectory = $dir }
  }
  if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
  $ownSetupBox.Text = $dlg.FileName
  # Deriving the source folder as well, exactly as step 1 does: the detection only needs the
  # installer, but filling it in means step 1 is ready too if a package IS wanted afterwards.
  try {
    $parent = Split-Path -LiteralPath $dlg.FileName -Parent
    if ($parent -and -not $ownSourceBox.Text.Trim()) { $ownSourceBox.Text = $parent }
  } catch { }
  Update-DetectInstallerDisplay
  Update-Status ((Get-UiString 'DetectInstallerChosenStatus') -f (Split-Path $dlg.FileName -Leaf))
})

# Keeps the mirror honest when the file is picked in step 1 instead.
$ownSetupBox.Add_TextChanged({ Update-DetectInstallerDisplay })
Update-DetectInstallerDisplay

$detectStep1Button = New-Object System.Windows.Forms.Button
$detectStep1Button.Tag = 'btn-secondary'
$detectStep1Button.Text = Get-UiString 'DetectSnapshotButton'
$detectStep1Button.Location = New-Object System.Drawing.Point(14, 80)
$detectStep1Button.Size = New-Object System.Drawing.Size(220, 32)
$cardDetect.Controls.Add($detectStep1Button)

$detectStep2Button = New-Object System.Windows.Forms.Button
$detectStep2Button.Tag = 'btn-secondary'
$detectStep2Button.Text = Get-UiString 'DetectInstallButton'
$detectStep2Button.Location = New-Object System.Drawing.Point(246, 80)
$detectStep2Button.Size = New-Object System.Drawing.Size(220, 32)
$detectStep2Button.Enabled = $false
$cardDetect.Controls.Add($detectStep2Button)

$detectStep3Button = New-Object System.Windows.Forms.Button
$detectStep3Button.Text = Get-UiString 'DetectCompareButton'
$detectStep3Button.Location = New-Object System.Drawing.Point(478, 80)
$detectStep3Button.Size = New-Object System.Drawing.Size(234, 32)
$detectStep3Button.Enabled = $false
$cardDetect.Controls.Add($detectStep3Button)

$detectMsiButton = New-Object System.Windows.Forms.Button
$detectMsiButton.Tag = 'btn-secondary'
$detectMsiButton.Text = Get-UiString 'DetectMsiButton'
$detectMsiButton.Location = New-Object System.Drawing.Point(14, 120)
$detectMsiButton.Size = New-Object System.Drawing.Size(220, 32)
$cardDetect.Controls.Add($detectMsiButton)

$detectSandboxButton = New-Object System.Windows.Forms.Button
$detectSandboxButton.Tag = 'btn-secondary'
$detectSandboxButton.Text = Get-UiString 'DetectSandboxButton'
$detectSandboxButton.Location = New-Object System.Drawing.Point(246, 120)
$detectSandboxButton.Size = New-Object System.Drawing.Size(220, 32)
$cardDetect.Controls.Add($detectSandboxButton)

$detectArgsLabel = New-Object System.Windows.Forms.Label
$detectArgsLabel.Text = Get-UiString 'DetectArgsLabel'
$detectArgsLabel.Location = New-Object System.Drawing.Point(478, 127)
$detectArgsLabel.AutoSize = $true
$cardDetect.Controls.Add($detectArgsLabel)

$detectArgsBox = New-Object System.Windows.Forms.TextBox
$detectArgsBox.Width = 150
$detectArgsBox.PlaceholderText = Get-UiString 'DetectArgsPlaceholder'
$detectArgsHost = New-RoundedInput -Inner $detectArgsBox -X 562 -Y 120 -W 150 -H 32
$cardDetect.Controls.Add($detectArgsHost)

$detectResultBox = New-Object System.Windows.Forms.TextBox
$detectResultBox.Multiline = $true
$detectResultBox.ReadOnly = $true
$detectResultBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$detectResultBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$detectResultBox.Location = New-Object System.Drawing.Point(14, 162)
$detectResultBox.Size = New-Object System.Drawing.Size(698, 150)
$cardDetect.Controls.Add($detectResultBox)

$detectApplyButton = New-Object System.Windows.Forms.Button
$detectApplyButton.Text = Get-UiString 'DetectApplyButton'
$detectApplyButton.Location = New-Object System.Drawing.Point(14, 320)
$detectApplyButton.Size = New-Object System.Drawing.Size(280, 32)
$detectApplyButton.Enabled = $false
$cardDetect.Controls.Add($detectApplyButton)

# Fills the Win32 card from whatever the detection step found. Values are only ever pre-filled,
# never sent anywhere: the form stays editable and the app is still created by its own button.
$detectApplyButton.Add_Click({
  $candidate = $script:detectionCandidate
  if (-not $candidate) { Update-Status (Get-UiString 'DetectApplyNothing'); return }
  try {
    if ($candidate.Kind -eq 'Msi') {
      $msi = $candidate.Msi
      if ($msi['ProductName'])  { $win32NameBox.Text = [string]$msi['ProductName'] }
      if ($msi['Manufacturer']) { $win32PublisherBox.Text = [string]$msi['Manufacturer'] }
      $win32InstallBox.Text   = Get-MsiInstallCommand -MsiPath $candidate.Path
      $win32UninstallBox.Text = Get-MsiUninstallCommand -ProductCode $msi['ProductCode']
      $win32DetectTypeCombo.SelectedIndex = 1          # MSI product code
      Update-Win32DetectionFields
      $win32Field1Box.Text = [string]$msi['ProductCode']
      Write-Log ("Detection applied to the form from MSI properties: {0}" -f $msi['ProductCode'])
    } else {
      $e = $candidate.Entry
      if ($e.DisplayName) { $win32NameBox.Text = [string]$e.DisplayName }
      if ($e.Publisher)   { $win32PublisherBox.Text = [string]$e.Publisher }
      # Prefer the quiet variant: the plain UninstallString usually opens a window, and an Intune
      # uninstall that waits for a click never finishes.
      $uninstall = if ($e.QuietUninstallString) { $e.QuietUninstallString } else { $e.UninstallString }
      if ($uninstall) { $win32UninstallBox.Text = [string]$uninstall }
      # The install command can only be assembled from what the user actually tried: the setup file
      # plus the switches typed in for the sandbox run. Guessing silent switches for an arbitrary
      # EXE is not possible, so an empty argument box leaves a command that still needs the switch.
      $setupLeaf = Split-Path $ownSetupBox.Text.Trim() -Leaf
      if ($setupLeaf) {
        $installerArgs = $detectArgsBox.Text.Trim()
        $win32InstallBox.Text = if ($installerArgs) { '"{0}" {1}' -f $setupLeaf, $installerArgs } else { '"{0}"' -f $setupLeaf }
      }
      $win32DetectTypeCombo.SelectedIndex = 0          # registry
      Update-Win32DetectionFields
      $win32Field1Box.Text = [string]$e.RegistryPath
      $win32Field2Box.Text = 'DisplayVersion'
      $win32Field3Box.Text = [string]$e.DisplayVersion
      # A 32-bit installer registers under WOW6432Node, and Intune needs that flag set explicitly
      # or the rule silently never matches on 64-bit clients.
      $win32Detect32Check.Checked = ([string]$e.RegistryPath -like '*WOW6432Node*')
      Write-Log ("Detection applied to the form from registry entry: {0}" -f $e.RegistryPath)
    }
    Update-Status (Get-UiString 'DetectApplyDone')
  } catch {
    Write-Log ("Applying the detection to the form failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  }
})

$detectHint = New-Object System.Windows.Forms.Label
$detectHint.Tag = 'hint'
$detectHint.Text = Get-UiString 'DetectHint'
$detectHint.Location = New-Object System.Drawing.Point(14, 360)
# 64 px: the German text needs four wrapped lines and 44 cut it off at
# "...die .intunewin-Datei kann man nicht installieren".
# Hoehe aus dem Text statt aus einer handgezaehlten Zahl - siehe Update-StackedCards.
$detectHint.AutoSize = $true
$detectHint.MaximumSize = New-Object System.Drawing.Size(698, 0)
$cardDetect.Controls.Add($detectHint)

# When the chosen installer changes, the previous detection result no longer belongs to it. Without
# this, an MSI's product code stayed in the result box and the "apply to form" candidate stayed
# armed after switching to an EXE, so the wrong data could be applied. Cleared here; the snapshot is
# left alone because it describes the machine, not a specific installer. Added after the detection
# controls exist; the handler itself runs later, when everything is loaded.
$ownSetupBox.Add_TextChanged({
  if ($detectResultBox) { $detectResultBox.Text = '' }
  $script:detectionCandidate = $null
  if ($detectApplyButton) { $detectApplyButton.Enabled = $false }
})

$detectStep1Button.Add_Click({
  try {
    Update-Status (Get-UiString 'DetectSnapshotRunning')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $script:detectionSnapshot = Get-UninstallSnapshot
    $detectResultBox.Text = (Get-UiString 'DetectSnapshotDone') -f $script:detectionSnapshot.Count
    $detectStep2Button.Enabled = $true
    $detectStep3Button.Enabled = $true
    Write-Log ("Detection snapshot taken: {0} uninstall entries." -f $script:detectionSnapshot.Count)
    Update-Status ((Get-UiString 'DetectSnapshotDone') -f $script:detectionSnapshot.Count)
  } catch {
    Write-Log ("Detection snapshot failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  }
})

$detectStep2Button.Add_Click({
  $setup = $ownSetupBox.Text.Trim()
  if (-not $setup -or -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    Update-Status (Get-UiString 'OwnPkgSetupMissing'); return
  }
  # Runs a real installer on THIS machine. Nothing here is undone automatically, so it is asked
  # for explicitly rather than being a side effect of the snapshot step.
  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'DetectInstallConfirm') -f $setup),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  try {
    $detectStep2Button.Enabled = $false
    Update-Status ((Get-UiString 'DetectInstallRunning') -f (Split-Path $setup -Leaf))
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $arguments = $detectArgsBox.Text.Trim()
    Write-Log ("Running installer locally for detection analysis: '{0}' {1}" -f $setup, $arguments)
    if ($arguments) {
      $proc = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru -ErrorAction Stop
    } else {
      $proc = Start-Process -FilePath $setup -Wait -PassThru -ErrorAction Stop
    }
    Write-Log ("Installer finished with exit code {0}." -f $proc.ExitCode)
    Update-Status ((Get-UiString 'DetectInstallDone') -f $proc.ExitCode)
  } catch {
    Write-Log ("Local installer run failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  } finally {
    $detectStep2Button.Enabled = $true
  }
})

$detectStep3Button.Add_Click({
  if (-not $script:detectionSnapshot) { Update-Status (Get-UiString 'DetectNoSnapshot'); return }
  try {
    Update-Status (Get-UiString 'DetectCompareRunning')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $diff = Compare-UninstallSnapshot -Before $script:detectionSnapshot -After (Get-UninstallSnapshot)
    $new = $diff.New
    $changed = $diff.Changed
    # Entries without a display name are components, not the application itself.
    $named = @($new | Where-Object { $_.DisplayName })
    $namedChanged = @($changed | Where-Object { $_.DisplayName })
    $detectResultBox.Text = Format-DetectionSuggestion -NewEntries $named -ChangedEntries $namedChanged
    # Keep the first named entry: with several, it is the one carrying the application's own name,
    # the rest are usually runtimes pulled in alongside. A genuinely new entry outranks an updated
    # one - if the installer registered something new, that is the application.
    $candidateEntry = if ($named.Count -gt 0) { $named[0] } elseif ($namedChanged.Count -gt 0) { $namedChanged[0] } else { $null }
    $script:detectionCandidate = if ($candidateEntry) {
      [pscustomobject]@{ Kind = 'Registry'; Entry = $candidateEntry }
    } else { $null }
    $detectApplyButton.Enabled = [bool]$script:detectionCandidate
    Write-Log ("Detection comparison: {0} new uninstall entr(y/ies), {1} with a display name; {2} updated in place, {3} with a display name." -f $new.Count, $named.Count, $changed.Count, $namedChanged.Count)
    if ($namedChanged.Count -gt 0) {
      Update-Status ((Get-UiString 'DetectCompareDoneUpdated') -f $named.Count, $namedChanged.Count)
    } else {
      Update-Status ((Get-UiString 'DetectCompareDone') -f $named.Count)
    }
  } catch {
    Write-Log ("Detection comparison failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  }
})

$detectMsiButton.Add_Click({
  $setup = $ownSetupBox.Text.Trim()
  if (-not $setup -or -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    Update-Status (Get-UiString 'OwnPkgSetupMissing'); return
  }
  if ([IO.Path]::GetExtension($setup) -ne '.msi') { Update-Status (Get-UiString 'DetectNotMsi'); return }
  try {
    Update-Status (Get-UiString 'DetectMsiRunning')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    # Read straight from the MSI property table. An MSI needs no install-and-compare round trip:
    # product code, version, name and publisher are all in the file, so everything Intune wants can
    # be derived without touching the machine.
    $msi = Get-MsiProperties -MsiPath $setup
    if (-not $msi -or -not $msi['ProductCode']) {
      # Fall back to the module's reader rather than failing outright.
      $info = Show-MsiInfo -MsiPath $setup -ErrorAction Stop
      $detectResultBox.Text = ((Get-UiString 'DetectMsiHeading') + "`r`n`r`n" + (($info | Format-List | Out-String).Trim()))
      $script:detectionCandidate = $null
    } else {
      $lines = [System.Collections.Generic.List[string]]::new()
      $lines.Add((Get-UiString 'DetectMsiHeading'))
      $lines.Add('')
      foreach ($k in @('ProductName', 'Manufacturer', 'ProductVersion', 'ProductCode')) {
        if ($msi[$k]) { $lines.Add(('  {0}: {1}' -f $k, $msi[$k])) }
      }
      $lines.Add('')
      $lines.Add('  ' + (Get-UiString 'DetectRuleHeading'))
      $lines.Add(('    {0}: {1}' -f (Get-UiString 'Win32DetectMsi'), $msi['ProductCode']))
      $lines.Add('')
      $lines.Add(('  ' + (Get-UiString 'DetectMsiCommands')))
      $lines.Add(('    {0}' -f (Get-MsiInstallCommand -MsiPath $setup)))
      $lines.Add(('    {0}' -f (Get-MsiUninstallCommand -ProductCode $msi['ProductCode'])))
      $detectResultBox.Text = ($lines -join "`r`n")
      $script:detectionCandidate = [pscustomobject]@{ Kind = 'Msi'; Msi = $msi; Path = $setup }
    }
    $detectApplyButton.Enabled = [bool]$script:detectionCandidate
    Write-Log ("MSI information read for '{0}'." -f $setup)
    Update-Status (Get-UiString 'DetectMsiDone')
  } catch {
    Write-Log ("Reading MSI information failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  }
})

# Auto mode: does the whole of step 2 in one click by driving the existing manual buttons, so the
# logic lives in exactly one place. MSI is non-destructive (reads the file). EXE really installs on
# THIS machine - the step-2 button keeps its own confirmation, which becomes the single gate of the
# automatic run; declining it simply ends with "nothing detected". The result is applied to the
# Win32 card with the same code as the manual "Apply to the form" button.
$detectAutoButton.Add_Click({
  $setup = $ownSetupBox.Text.Trim()
  if (-not $setup -or -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    Update-Status (Get-UiString 'OwnPkgSetupMissing'); return
  }
  $isMsi = ([IO.Path]::GetExtension($setup) -ieq '.msi')
  try {
    $detectAutoButton.Enabled = $false
    if ($isMsi) {
      Update-Status (Get-UiString 'DetectAutoMsiStatus')
      [System.Windows.Forms.Application]::DoEvents()
      $detectMsiButton.PerformClick()      # reads properties, sets $script:detectionCandidate
    } else {
      Update-Status (Get-UiString 'DetectAutoExeStatus')
      [System.Windows.Forms.Application]::DoEvents()
      $detectStep1Button.PerformClick()    # snapshot (also enables steps 2 and 3)
      [System.Windows.Forms.Application]::DoEvents()
      $detectStep2Button.PerformClick()    # install locally - asks the user to confirm once
      [System.Windows.Forms.Application]::DoEvents()
      $detectStep3Button.PerformClick()    # compare; sets or clears the candidate
      [System.Windows.Forms.Application]::DoEvents()
    }
    if ($script:detectionCandidate -and $detectApplyButton.Enabled) {
      $detectApplyButton.PerformClick()
      Update-Status (Get-UiString 'DetectAutoDone')
    } else {
      Update-Status (Get-UiString 'DetectAutoNothing')
    }
  } catch {
    Write-Log ("Automatic detection failed: {0}" -f (Format-ErrorDetail $_))
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  } finally {
    $detectAutoButton.Enabled = $true
  }
})

$detectSandboxButton.Add_Click({
  $setup = $ownSetupBox.Text.Trim()
  if (-not $setup -or -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    Update-Status (Get-UiString 'OwnPkgSetupMissing'); return
  }
  # Windows Sandbox is an optional Windows feature and absent on most machines until someone turns
  # it on. Without this check the failure surfaced as "An error occurred trying to start process
  # 'WindowsSandbox.exe' with working directory ..." - a message about a working directory that has
  # nothing to do with the cause, leaving the reader to guess. Checked up front instead, with the
  # one instruction that actually helps.
  if (-not (Test-WindowsSandboxAvailable)) {
    Write-Log 'Windows Sandbox is not available on this machine (optional feature not enabled).'
    $detectResultBox.Text = Get-UiString 'DetectSandboxUnavailable'
    Update-Status (Get-UiString 'DetectSandboxUnavailableStatus')
    # Offer to do it instead of leaving the reader to type commands. Enabling changes the system
    # and forces a restart, so it is never done without an explicit yes.
    $answer = [System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'DetectSandboxEnableDialog'),
      (Get-UiString 'DetectSandboxUnavailableStatus'),
      [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
      [System.Windows.Forms.MessageBoxIcon]::Question,
      [System.Windows.Forms.MessageBoxDefaultButton]::Button3)
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
      try {
        # DISM rather than Enable-WindowsOptionalFeature: that cmdlet lives in the DISM module,
        # which Windows PowerShell 5.1 has and PowerShell 7 does not. dism.exe is a plain program
        # and works from either. -Verb RunAs raises the UAC prompt; -NoRestart leaves the restart
        # to the user rather than pulling the rug out mid-session.
        Write-Log 'Enabling Windows Sandbox via dism.exe (elevation requested).'
        Start-Process -FilePath 'dism.exe' -Verb RunAs -ArgumentList @(
          '/Online', '/Enable-Feature', '/FeatureName:Containers-DisposableClientVM', '/All', '/NoRestart') -ErrorAction Stop
        Update-Status (Get-UiString 'DetectSandboxEnableStarted')
      } catch {
        Write-Log ("Enabling Windows Sandbox failed: {0}" -f $_.Exception.Message)
        Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
      }
    } elseif ($answer -eq [System.Windows.Forms.DialogResult]::No) {
      try {
        Start-Process 'optionalfeatures.exe' -ErrorAction Stop
        Write-Log 'Opened the Windows features dialog.'
      } catch {
        Write-Log ("Could not open the Windows features dialog: {0}" -f $_.Exception.Message)
        Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
      }
    }
    return
  }
  # One sandbox at a time (see Test-WindowsSandboxRunning): starting a second is what caused the
  # "access denied" the user hit after the frozen UI made them click twice.
  if (Test-WindowsSandboxRunning) {
    Write-Log 'A Windows Sandbox instance is already running.'
    # Offer to close it instead of just refusing. The old message told the user to close a window they
    # often cannot find - a leftover instance after a crash or a timeout has no visible window at all,
    # only a WindowsSandboxServer process.
    $answer = [System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'DetectSandboxCloseRunningDialog'),
      (Get-UiString 'DetectSandboxCloseRunningTitle'),
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
      $detectResultBox.Text = Get-UiString 'DetectSandboxAlreadyRunning'
      Update-Status (Get-UiString 'DetectSandboxAlreadyRunning')
      return
    }
    Update-Status (Get-UiString 'DetectSandboxClosingStatus')
    [System.Windows.Forms.Application]::DoEvents()
    $stopResult = Stop-WindowsSandbox
    if (-not $stopResult.Stopped) {
      $detectResultBox.Text = Get-UiString 'DetectSandboxCloseFailed'
      Update-Status (Get-UiString 'DetectSandboxCloseFailed')
      return
    }
    # Waiting properly, not for a token two seconds: starting straight after a kill is exactly what
    # produced "Zugriff verweigert (0x80070005)".
    Update-Status (Get-UiString 'DetectSandboxSettlingStatus')
    if (-not (Wait-WindowsSandboxSettled -AfterKill:([bool]$stopResult.Killed))) {
      $detectResultBox.Text = Get-UiString 'DetectSandboxAlreadyRunning'
      Update-Status (Get-UiString 'DetectSandboxAlreadyRunning')
      return
    }
  }
  # Asked and logged BEFORE anything is started, so the log answers "why 0x80070005" by itself.
  $blocker = Get-SandboxBlockerDiagnosis
  Write-Log ("Sandbox prerequisites: {0}" -f $blocker.Detail)
  if ($blocker.Blocked) {
    # Three real options instead of a yes/no on a doomed start. Credential Guard is active on most
    # managed devices, so for most users the sandbox is simply not available - and then the useful
    # answer is the path that DOES work, which sits in this same card.
    $choice = Show-SandboxBlockedDialog
    if ($choice -eq 'local') {
      Write-Log 'Sandbox unavailable (Credential Guard); switching to the local three-step detection instead.'
      $detectResultBox.Text = Get-UiString 'DetectSandboxBlockedResult'
      Update-Status (Get-UiString 'DetectSandboxUseLocalStatus')
      # The local route installs on THIS machine and asks for its own confirmation before doing so.
      $detectAutoButton.PerformClick()
      return
    }
    if ($choice -ne 'sandbox') {
      $detectResultBox.Text = Get-UiString 'DetectSandboxBlockedResult'
      Update-Status (Get-UiString 'DetectSandboxBlockedStatus')
      return
    }
    Write-Log 'Sandbox test started anyway on the user''s decision, despite Credential Guard being active.'
  }
  try {
    # Disabled while it runs so a slow start cannot be double-clicked into a second sandbox.
    $detectSandboxButton.Enabled = $false
    Update-Status (Get-UiString 'DetectSandboxRunning')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $arguments = $detectArgsBox.Text.Trim()
    # The ORIGINAL path used to be logged here while the staged copy was what actually got handed
    # over - which made a real diagnosis look like the Downloads folder was being mapped.
    Write-Log ("Testing setup file in Windows Sandbox (out of process): '{0}' {1}" -f $setup, $arguments)
    $sbx = Invoke-WtSandboxTest -SetupFile $setup -InstallerArguments $arguments
    if ($sbx.Output) { Write-Log ("Sandbox helper output: {0}" -f ($sbx.Output -replace '\s+', ' ')) }
    if ($sbx.Succeeded) {
      $detectResultBox.Text = Get-UiString 'DetectSandboxStarted'
      Update-Status (Get-UiString 'DetectSandboxStarted')
    } elseif ($sbx.AccessDenied) {
      Write-Log ("Sandbox init access denied (0x80070005): {0}" -f $sbx.ErrorMessage)
      $detectResultBox.Text = Get-UiString 'DetectSandboxAccessDenied'
      Update-Status (Get-UiString 'DetectSandboxAccessDeniedStatus')
    } else {
      Write-Log ("Sandbox test failed: {0}" -f $sbx.ErrorMessage)
      $detectResultBox.Text = (Get-UiString 'DetectSandboxFailed') -f $sbx.ErrorMessage
      Update-Status ((Get-UiString 'DetectFailed') -f $sbx.ErrorMessage)
    }
  } catch {
    Write-Log ("Sandbox test failed: {0}" -f (Format-ErrorDetail $_))
    $detectResultBox.Text = (Get-UiString 'DetectSandboxFailed') -f $_.Exception.Message
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  } finally {
    $detectSandboxButton.Enabled = $true
  }
})


# --- Creating a Win32 app from an own installer ---
# Closes the gap that packaging alone left: an .intunewin file is useless until an Intune app object
# carries the install command and a detection rule. Built on the same two proven pieces as the rest
# of this GUI - a plain Graph POST for the object, then Deploy-WtWin32ContentVersion for the payload.

# Intune wants the registry hive spelled out. The detection card above reports PowerShell drive
# notation (HKLM:\...), which Graph silently never matches.
function Convert-ToGraphRegistryPath {
  param([Parameter(Mandatory)][string]$Path)
  $p = $Path.Trim()
  $map = @{
    'HKLM:\' = 'HKEY_LOCAL_MACHINE\'
    'HKCU:\' = 'HKEY_CURRENT_USER\'
    'HKCR:\' = 'HKEY_CLASSES_ROOT\'
    'HKU:\'  = 'HKEY_USERS\'
  }
  foreach ($k in $map.Keys) {
    if ($p.StartsWith($k, [System.StringComparison]::OrdinalIgnoreCase)) {
      return ($map[$k] + $p.Substring($k.Length))
    }
  }
  return $p
}

# Builds the single detection rule. Intune accepts several; one covers the cases this card offers
# and keeps the rule comprehensible - a wrong detection rule is the classic reason an app installs
# over and over or never reports success.
function New-Win32DetectionRule {
  param(
    [Parameter(Mandatory)][ValidateSet('msi', 'registry', 'file')][string]$Kind,
    [string]$Value1,
    [string]$Value2,
    [string]$Value3,
    [bool]$Is32BitOn64 = $false
  )
  switch ($Kind) {
    'msi' {
      if (-not $Value1) { throw (Get-UiString 'Win32DetectMsiMissing') }
      return @{
        '@odata.type'            = '#microsoft.graph.win32LobAppProductCodeDetection'
        productCode              = $Value1.Trim()
        productVersionOperator   = 'notConfigured'
      }
    }
    'registry' {
      if (-not $Value1) { throw (Get-UiString 'Win32DetectRegistryMissing') }
      $rule = @{
        '@odata.type'         = '#microsoft.graph.win32LobAppRegistryDetection'
        check32BitOn64System  = $Is32BitOn64
        keyPath               = Convert-ToGraphRegistryPath -Path $Value1
        valueName             = $Value2
      }
      if ($Value3) {
        # A version comparison also proves the app is current enough, which a mere "exists" cannot.
        $rule.detectionType  = 'version'
        $rule.operator       = 'greaterThanOrEqual'
        $rule.detectionValue = $Value3.Trim()
      } else {
        # Both branches were 'exists' - the condition read as if it mattered and did nothing.
        # It genuinely does not: Intune documents 'exists' as "the specified registry key OR value
        # exists", and which of the two is checked is decided by valueName being set or empty,
        # not by the detection type.
        $rule.detectionType = 'exists'
        $rule.operator      = 'notConfigured'
      }
      return $rule
    }
    default {
      if (-not $Value1 -or -not $Value2) { throw (Get-UiString 'Win32DetectFileMissing') }
      return @{
        '@odata.type'         = '#microsoft.graph.win32LobAppFileSystemDetection'
        check32BitOn64System  = $Is32BitOn64
        path                  = $Value1.Trim()
        fileOrFolderName      = $Value2.Trim()
        detectionType         = 'exists'
        operator              = 'notConfigured'
      }
    }
  }
}

# Creates the app object. The content is uploaded separately afterwards - Intune needs the object
# to exist before it accepts a content version.
function New-Win32AppViaGraph {
  param(
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$Publisher,
    [string]$Description,
    [Parameter(Mandatory)][string]$InstallCommandLine,
    [Parameter(Mandatory)][string]$UninstallCommandLine,
    [Parameter(Mandatory)][hashtable]$DetectionRule,
    [ValidateSet('system', 'user')][string]$RunAsAccount = 'system',
    [string]$SetupFileName,
    [string]$PackageFileName
  )
  $token = Get-WtToken -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

  $body = @{
    '@odata.type'                   = '#microsoft.graph.win32LobApp'
    displayName                     = $DisplayName
    publisher                       = $Publisher
    description                     = $(if ($Description) { $Description } else { $DisplayName })
    installCommandLine              = $InstallCommandLine
    uninstallCommandLine            = $UninstallCommandLine
    applicableArchitectures         = 'x64'
    minimumSupportedWindowsRelease  = '1607'
    setupFilePath                   = $SetupFileName
    fileName                        = $PackageFileName
    installExperience               = @{
      runAsAccount          = $RunAsAccount
      deviceRestartBehavior = 'basedOnReturnCode'
    }
    detectionRules = @($DetectionRule)
    # The Intune defaults. Without them every non-zero exit code counts as a failure, including the
    # reboot codes that a normal installer returns on success.
    returnCodes = @(
      @{ returnCode = 0;    type = 'success' },
      @{ returnCode = 1707; type = 'success' },
      @{ returnCode = 3010; type = 'softReboot' },
      @{ returnCode = 1641; type = 'hardReboot' },
      @{ returnCode = 1618; type = 'retry' }
    )
  }

  $json = $body | ConvertTo-Json -Depth 10
  Write-Log ("Creating Win32 app over Graph: '{0}' ({1}), runAs {2}, detection {3}." -f $DisplayName, $Publisher, $RunAsAccount, $DetectionRule['@odata.type'])
  # -MaxRetries 0, und das ist keine Sparsamkeit: dieser POST LEGT EINE APP AN. Bei einem Zeitablauf
  # oder einer abgerissenen Verbindung weiss der Aufrufer nicht, ob Intune sie schon erzeugt hat -
  # ein zweiter Versuch legte dann eine zweite, nicht verknuepfte App an. Get-GraphRetryPlan
  # wiederholt zwar ohnehin nur bei einem gelesenen Status, aber hier steht es ausdruecklich da.
  $created = Invoke-GraphRest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps' `
    -Headers $headers -Body $json -MaxRetries 0 -Context 'create Win32 app'
  # A new app exists, so any cached inventory is stale. Note that the module's inventory would not
  # list THIS app at any point - it carries no '[WinTuner|' notes marker - which is why the
  # content-replacement list reads the tenant directly (Get-TenantWin32Apps). Clearing the cache
  # still matters for everything else that app count feeds.
  Clear-Win32AppsCache
  Write-Log ("Win32 app created: {0}" -f [string]$created.id)
  return $created
}

$cardWin32 = New-Card -X 16 -Y 790 -W 726 -H 446
$tabOwnPackage.Controls.Add($cardWin32)

$win32Label = New-Object System.Windows.Forms.Label
$win32Label.Text = Get-UiString 'Win32SectionTitle'
$win32Label.Location = New-Object System.Drawing.Point(14, 10)
$win32Label.AutoSize = $true
$win32Label.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardWin32.Controls.Add($win32Label)
[void](Add-SectionInfoBadge -Parent $cardWin32 -AfterLabel $win32Label -TextKey 'InfoOwnStep3')

# --- identity ---
$win32NameLabel = New-Object System.Windows.Forms.Label
$win32NameLabel.Text = Get-UiString 'Win32NameLabel'
$win32NameLabel.Location = New-Object System.Drawing.Point(14, 46)
$win32NameLabel.AutoSize = $true
$cardWin32.Controls.Add($win32NameLabel)

$win32NameBox = New-Object System.Windows.Forms.TextBox
$win32NameBox.Width = 250
$win32NameHost = New-RoundedInput -Inner $win32NameBox -X 160 -Y 40 -W 250 -H 32
$cardWin32.Controls.Add($win32NameHost)

$win32PublisherLabel = New-Object System.Windows.Forms.Label
$win32PublisherLabel.Text = Get-UiString 'Win32PublisherLabel'
$win32PublisherLabel.Location = New-Object System.Drawing.Point(424, 46)
$win32PublisherLabel.AutoSize = $true
$cardWin32.Controls.Add($win32PublisherLabel)

$win32PublisherBox = New-Object System.Windows.Forms.TextBox
$win32PublisherBox.Width = 180
$win32PublisherHost = New-RoundedInput -Inner $win32PublisherBox -X 532 -Y 40 -W 180 -H 32
$cardWin32.Controls.Add($win32PublisherHost)

# --- commands ---
$win32InstallLabel = New-Object System.Windows.Forms.Label
$win32InstallLabel.Text = Get-UiString 'Win32InstallLabel'
$win32InstallLabel.Location = New-Object System.Drawing.Point(14, 86)
$win32InstallLabel.AutoSize = $true
$cardWin32.Controls.Add($win32InstallLabel)

$win32InstallBox = New-Object System.Windows.Forms.TextBox
$win32InstallBox.Width = 552
$win32InstallBox.PlaceholderText = Get-UiString 'Win32InstallPlaceholder'
$win32InstallHost = New-RoundedInput -Inner $win32InstallBox -X 160 -Y 80 -W 552 -H 32
$cardWin32.Controls.Add($win32InstallHost)

$win32UninstallLabel = New-Object System.Windows.Forms.Label
$win32UninstallLabel.Text = Get-UiString 'Win32UninstallLabel'
$win32UninstallLabel.Location = New-Object System.Drawing.Point(14, 126)
$win32UninstallLabel.AutoSize = $true
$cardWin32.Controls.Add($win32UninstallLabel)

$win32UninstallBox = New-Object System.Windows.Forms.TextBox
$win32UninstallBox.Width = 552
$win32UninstallBox.PlaceholderText = Get-UiString 'Win32UninstallPlaceholder'
$win32UninstallHost = New-RoundedInput -Inner $win32UninstallBox -X 160 -Y 120 -W 552 -H 32
$cardWin32.Controls.Add($win32UninstallHost)

# --- context ---
$win32ContextLabel = New-Object System.Windows.Forms.Label
$win32ContextLabel.Text = Get-UiString 'Win32ContextLabel'
$win32ContextLabel.Location = New-Object System.Drawing.Point(14, 166)
$win32ContextLabel.AutoSize = $true
$cardWin32.Controls.Add($win32ContextLabel)

$win32ContextCombo = New-Object System.Windows.Forms.ComboBox
$win32ContextCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$win32ContextCombo.Location = New-Object System.Drawing.Point(160, 162)
$win32ContextCombo.Width = 250
[void]$win32ContextCombo.Items.AddRange(@((Get-UiString 'Win32ContextSystem'), (Get-UiString 'Win32ContextUser')))
$win32ContextCombo.SelectedIndex = 0
$cardWin32.Controls.Add($win32ContextCombo)

# --- detection ---
$win32DetectTypeLabel = New-Object System.Windows.Forms.Label
$win32DetectTypeLabel.Text = Get-UiString 'Win32DetectTypeLabel'
$win32DetectTypeLabel.Location = New-Object System.Drawing.Point(14, 206)
$win32DetectTypeLabel.AutoSize = $true
$cardWin32.Controls.Add($win32DetectTypeLabel)

$win32DetectTypeCombo = New-Object System.Windows.Forms.ComboBox
$win32DetectTypeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$win32DetectTypeCombo.Location = New-Object System.Drawing.Point(160, 202)
$win32DetectTypeCombo.Width = 250
[void]$win32DetectTypeCombo.Items.AddRange(@(
  (Get-UiString 'Win32DetectRegistry'),
  (Get-UiString 'Win32DetectMsi'),
  (Get-UiString 'Win32DetectFile')))
$win32DetectTypeCombo.SelectedIndex = 0
$cardWin32.Controls.Add($win32DetectTypeCombo)

$win32Detect32Check = New-Object System.Windows.Forms.CheckBox
$win32Detect32Check.Text = Get-UiString 'Win32Detect32Bit'
$win32Detect32Check.Location = New-Object System.Drawing.Point(424, 204)
$win32Detect32Check.AutoSize = $true
$cardWin32.Controls.Add($win32Detect32Check)

$win32Field1Label = New-Object System.Windows.Forms.Label
$win32Field1Label.Location = New-Object System.Drawing.Point(14, 246)
$win32Field1Label.AutoSize = $true
$cardWin32.Controls.Add($win32Field1Label)

$win32Field1Box = New-Object System.Windows.Forms.TextBox
$win32Field1Box.Width = 552
$win32Field1Host = New-RoundedInput -Inner $win32Field1Box -X 160 -Y 240 -W 552 -H 32
$cardWin32.Controls.Add($win32Field1Host)

$win32Field2Label = New-Object System.Windows.Forms.Label
$win32Field2Label.Location = New-Object System.Drawing.Point(14, 286)
$win32Field2Label.AutoSize = $true
$cardWin32.Controls.Add($win32Field2Label)

$win32Field2Box = New-Object System.Windows.Forms.TextBox
$win32Field2Box.Width = 250
$win32Field2Host = New-RoundedInput -Inner $win32Field2Box -X 160 -Y 280 -W 250 -H 32
$cardWin32.Controls.Add($win32Field2Host)

$win32Field3Label = New-Object System.Windows.Forms.Label
$win32Field3Label.Location = New-Object System.Drawing.Point(424, 286)
$win32Field3Label.AutoSize = $true
$cardWin32.Controls.Add($win32Field3Label)

$win32Field3Box = New-Object System.Windows.Forms.TextBox
$win32Field3Box.Width = 180
$win32Field3Host = New-RoundedInput -Inner $win32Field3Box -X 532 -Y 280 -W 180 -H 32
$cardWin32.Controls.Add($win32Field3Host)

# --- package file for THIS app ---
# Step 3 used to read its .intunewin silently from a field that lives in the "replace content" card
# two rows further down, so the user could neither see which package would be used nor pick a
# different one here. It now has its own visible, selectable field: filled automatically after
# step 1, and a browse button to choose ANY existing .intunewin. The full path is kept in the box's
# Tag; the box shows only the file name so a long path cannot overflow the field.
$win32PackageButton = New-Object System.Windows.Forms.Button
$win32PackageButton.Tag = 'btn-secondary'
$win32PackageButton.Text = Get-UiString 'Win32PackageButton'
$win32PackageButton.Location = New-Object System.Drawing.Point(14, 326)
$win32PackageButton.Size = New-Object System.Drawing.Size(180, 32)
$cardWin32.Controls.Add($win32PackageButton)

$win32PackageBox = New-Object System.Windows.Forms.TextBox
$win32PackageBox.ReadOnly = $true
$win32PackageBox.Width = 240
$win32PackageBox.PlaceholderText = Get-UiString 'Win32PackagePlaceholder'
$win32PackageHost = New-RoundedInput -Inner $win32PackageBox -X 202 -Y 326 -W 240 -H 32
$cardWin32.Controls.Add($win32PackageHost)

# Keeps its original 260px width so the label never clips; sits at the right end of the row.
$win32CreateButton = New-Object System.Windows.Forms.Button
$win32CreateButton.Text = Get-UiString 'Win32CreateButton'
$win32CreateButton.Location = New-Object System.Drawing.Point(452, 326)
$win32CreateButton.Size = New-Object System.Drawing.Size(260, 32)
$cardWin32.Controls.Add($win32CreateButton)

# Pick an existing .intunewin instead of the one built in step 1. Stores the full path in the box's
# Tag and shows just the file name.
$win32PackageButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = 'Intune package (*.intunewin)|*.intunewin|All files (*.*)|*.*'
  $dlg.Title = Get-UiString 'Win32PackageButton'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $win32PackageBox.Tag = $dlg.FileName
    $win32PackageBox.Text = Split-Path $dlg.FileName -Leaf
    Update-Status ((Get-UiString 'Win32PackageChosen') -f (Split-Path $dlg.FileName -Leaf))
  }
})

$win32Hint = New-Object System.Windows.Forms.Label
$win32Hint.Tag = 'hint'
$win32Hint.Text = Get-UiString 'Win32Hint'
$win32Hint.Location = New-Object System.Drawing.Point(14, 366)
# Hoehe aus dem Text statt aus einer handgezaehlten Zahl - siehe Update-StackedCards.
$win32Hint.AutoSize = $true
$win32Hint.MaximumSize = New-Object System.Drawing.Size(698, 0)
$cardWin32.Controls.Add($win32Hint)

# The three detection kinds need different inputs; relabelling three fields keeps the card compact
# and avoids three near-identical control groups fighting for space.
function Update-Win32DetectionFields {
  try {
    switch ([int]$win32DetectTypeCombo.SelectedIndex) {
      1 {  # MSI product code
        $win32Field1Label.Text = Get-UiString 'Win32FieldProductCode'
        $win32Field1Box.PlaceholderText = '{12345678-1234-1234-1234-123456789012}'
        $win32Field2Label.Text = ''
        $win32Field3Label.Text = ''
        $win32Field2Host.Visible = $false
        $win32Field3Host.Visible = $false
        $win32Detect32Check.Visible = $false
      }
      2 {  # file or folder
        $win32Field1Label.Text = Get-UiString 'Win32FieldPath'
        $win32Field1Box.PlaceholderText = 'C:\Program Files\Example'
        $win32Field2Label.Text = Get-UiString 'Win32FieldFileName'
        $win32Field3Label.Text = ''
        $win32Field2Host.Visible = $true
        $win32Field3Host.Visible = $false
        $win32Detect32Check.Visible = $true
      }
      default {  # registry
        $win32Field1Label.Text = Get-UiString 'Win32FieldKeyPath'
        $win32Field1Box.PlaceholderText = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Example'
        $win32Field2Label.Text = Get-UiString 'Win32FieldValueName'
        $win32Field3Label.Text = Get-UiString 'Win32FieldVersion'
        $win32Field2Host.Visible = $true
        $win32Field3Host.Visible = $true
        $win32Detect32Check.Visible = $true
      }
    }
  } catch { }   # class 3: relabelling must never block the card
}
$win32DetectTypeCombo.Add_SelectedIndexChanged({ Update-Win32DetectionFields })
Update-Win32DetectionFields

$win32CreateButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }

  # Read from this card's own package field (Tag holds the full path). Falls back to the file name
  # in the box only if the Tag was somehow lost.
  $packageFile = ([string]$win32PackageBox.Tag).Trim()
  if (-not $packageFile) { $packageFile = $win32PackageBox.Text.Trim() }
  $displayName = $win32NameBox.Text.Trim()
  $publisher = $win32PublisherBox.Text.Trim()
  $installCmd = $win32InstallBox.Text.Trim()
  $uninstallCmd = $win32UninstallBox.Text.Trim()

  if (-not $packageFile -or -not (Test-Path -LiteralPath $packageFile -PathType Leaf)) {
    Update-Status (Get-UiString 'Win32NoPackage'); return
  }
  if (-not $displayName -or -not $publisher) { Update-Status (Get-UiString 'Win32NoIdentity'); return }
  if (-not $installCmd -or -not $uninstallCmd) { Update-Status (Get-UiString 'Win32NoCommands'); return }

  $kind = switch ([int]$win32DetectTypeCombo.SelectedIndex) { 1 { 'msi' }; 2 { 'file' }; default { 'registry' } }
  $rule = $null
  try {
    $rule = New-Win32DetectionRule -Kind $kind -Value1 $win32Field1Box.Text -Value2 $win32Field2Box.Text -Value3 $win32Field3Box.Text -Is32BitOn64 ([bool]$win32Detect32Check.Checked)
  } catch {
    Update-Status ((Get-UiString 'Win32DetectInvalid') -f $_.Exception.Message); return
  }

  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'Win32CreateConfirm') -f $displayName, (Split-Path $packageFile -Leaf)),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

  try {
    $win32CreateButton.Enabled = $false
    Update-Status ((Get-UiString 'Win32CreatingStatus') -f $displayName)
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

    $runAs = if ([int]$win32ContextCombo.SelectedIndex -eq 1) { 'user' } else { 'system' }
    $setupName = Split-Path $ownSetupBox.Text.Trim() -Leaf
    if (-not $setupName) { $setupName = 'setup.exe' }

    $app = New-Win32AppViaGraph -DisplayName $displayName -Publisher $publisher `
      -InstallCommandLine $installCmd -UninstallCommandLine $uninstallCmd `
      -DetectionRule $rule -RunAsAccount $runAs `
      -SetupFileName $setupName -PackageFileName (Split-Path $packageFile -Leaf)

    $appId = [string]$app.id
    if (-not $appId) { throw (Get-UiString 'Win32NoAppId') }

    # The object exists but is empty until the payload is attached; without this the app would be
    # visible in Intune and fail on every device.
    Update-Status ((Get-UiString 'Win32UploadingStatus') -f $displayName)
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $upload = Update-ExistingAppContent -AppId $appId -IntuneWinFile $packageFile -AppName $displayName
    if ($upload.ErrorMessage) {
      Update-Status ((Get-UiString 'Win32UploadFailed') -f $upload.ErrorMessage)
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'Win32UploadFailedDialog') -f $displayName, $appId, $upload.ErrorMessage),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }
    Update-Status ((Get-UiString 'Win32CreatedStatus') -f $displayName)
    Write-Log ("Win32 app '{0}' ({1}) created and content uploaded." -f $displayName, $appId)
    try { Add-SessionActivity -Kind 'Deployed' -Name ([string]$displayName) -Detail (Get-UiString 'ActivityDeployed') } catch { }
  } catch {
    Write-Log ("Creating the Win32 app failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'Win32CreateFailed') -f $_.Exception.Message)
  } finally {
    $win32CreateButton.Enabled = $true
  }
})


Add-Section -Key 'ownpackage' -Panel $tabOwnPackage -Label (Get-UiString 'TabOwnPackage') -Group 'deploy'

# Die vier Karten dieser Sektion bekommen ihre Hoehe aus dem Inhalt (siehe Update-StackedCards).
# Die Y- und H-Werte an den New-Card-Aufrufen sind damit nur noch Startwerte fuer den Aufbau.
function Update-OwnPackageLayout {
  if (-not $cardOwnBuild) { return }
  Update-StackedCards -Panel $tabOwnPackage -Cards @($cardOwnBuild, $cardDetect, $cardWin32, $cardContentReplace)
}

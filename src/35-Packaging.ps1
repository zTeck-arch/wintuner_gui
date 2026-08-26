
# Der Runspace fuehrt genau eine Pipeline. Dieser Merker sagt, dass sie besetzt ist - Paketbau
# UND Inventar-Abfrage teilen ihn sich, und wer ihn besetzt findet, arbeitet inline weiter.
$script:pkgRunspaceInUse = $false

function Get-PackageRunspace {
  if ($script:pkgRunspace -and $script:pkgRunspace.RunspaceStateInfo.State -eq 'Opened') {
    return $script:pkgRunspace
  }
  try {
    if ($script:pkgRunspace) { try { $script:pkgRunspace.Dispose() } catch { } }   # class 3: teardown
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $init = [powershell]::Create()
    $init.Runspace = $rs
    [void]$init.AddScript('$ProgressPreference = ''SilentlyContinue''; $InformationPreference = ''SilentlyContinue''; Import-Module WinTuner -ErrorAction Stop')
    [void]$init.Invoke()
    if ($init.Streams.Error.Count -gt 0) {
      $msg = ($init.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
      $init.Dispose(); $rs.Dispose()
      Write-Log ("Background packaging unavailable (module import failed): {0}" -f $msg)
      return $null
    }
    $init.Dispose()
    $script:pkgRunspace = $rs
    Write-Log "Background packaging runspace ready (WinTuner module imported)."
    return $rs
  } catch {
    Write-Log ("Could not create the background packaging runspace: {0}" -f $_.Exception.Message)
    return $null
  }
}

# Runs New-WtWingetPackage in the background runspace and keeps the UI alive while it works.
# Returns @{ Succeeded; Result; ErrorMessage; TimedOut }. Falls back to a synchronous call
# (the previous behaviour) when no runspace can be created, so packaging never becomes impossible.
function Invoke-WtPackageBuild {
  param(
    [Parameter(Mandatory)][hashtable]$Arguments,
    [string]$Label = '',
    [int]$TimeoutMinutes = 30
  )
  $rs = Get-PackageRunspace
  if (-not $rs) {
    Write-Log "Falling back to synchronous packaging (UI will block until the package is built)."
    try {
      $r = New-WtWingetPackage @Arguments
      return @{ Succeeded = $true; Result = $r; ErrorMessage = $null; TimedOut = $false }
    } catch {
      return @{ Succeeded = $false; Result = $null; ErrorMessage = $_.Exception.Message; TimedOut = $false }
    }
  }

  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  # ErrorAction is passed through the hashtable by the caller; AddParameters keeps it intact.
  [void]$ps.AddCommand('New-WtWingetPackage').AddParameters($Arguments)

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $script:packagingBusy = $true
  $script:pkgRunspaceInUse = $true
  try {
    $handle = $ps.BeginInvoke()
    $timedOut = $false
    while (-not $handle.IsCompleted) {
      # This is what keeps the window responsive: the UI thread pumps its message queue while the
      # package is being built on the other thread.
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 60
      # "Stop after current app" can now abort the BUILD itself, not just wait for it: packaging
      # only writes local files, so stopping it leaves nothing half-done in Intune (unlike an
      # upload, which is why the deploy step is still never interrupted).
      if ($script:cancelBatch) {
        Write-Log ("Packaging canceled by user{0} after {1:n1}s." -f $(if ($Label) { " for $Label" } else { '' }), $sw.Elapsed.TotalSeconds)
        try { $ps.Stop() } catch { }   # class 3: best-effort abort
        return @{ Succeeded = $false; Result = $null; ErrorMessage = 'Canceled by user'; TimedOut = $false }
      }
      if ($sw.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
        $timedOut = $true
        Write-Log ("Packaging timed out after {0} minute(s){1} - stopping the build." -f $TimeoutMinutes, $(if ($Label) { " for $Label" } else { '' }))
        try { $ps.Stop() } catch { }   # class 3: best-effort abort
        break
      }
    }
    if ($timedOut) {
      return @{ Succeeded = $false; Result = $null; ErrorMessage = "Packaging timed out after $TimeoutMinutes minute(s)"; TimedOut = $true }
    }

    $out = $ps.EndInvoke($handle)
    if ($ps.Streams.Error.Count -gt 0) {
      # New-WtWingetPackage was called with ErrorAction Stop, so a terminating error arrives here
      # as an exception from EndInvoke; anything left in the stream is reported as-is.
      $msg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
      return @{ Succeeded = $false; Result = $null; ErrorMessage = $msg; TimedOut = $false }
    }
    $result = if ($out -and $out.Count -gt 0) { $out[$out.Count - 1] } else { $null }
    Write-Log ("Packaging finished in {0:n1}s{1} (background)." -f $sw.Elapsed.TotalSeconds, $(if ($Label) { " for $Label" } else { '' }))
    return @{ Succeeded = $true; Result = $result; ErrorMessage = $null; TimedOut = $false }
  } catch {
    # BeginInvoke/EndInvoke surface the module's terminating errors here - unwrap to the real
    # message so the existing 404 / "Hash mismatch" fallbacks keep matching on it.
    $em = $_.Exception.Message
    if ($_.Exception.InnerException -and $_.Exception.InnerException.Message) { $em = $_.Exception.InnerException.Message }
    return @{ Succeeded = $false; Result = $null; ErrorMessage = $em; TimedOut = $false }
  } finally {
    $script:packagingBusy = $false
    $script:pkgRunspaceInUse = $false
    try { $ps.Dispose() } catch { }   # class 3: teardown
  }
}

# Thin wrapper so the fallback logic below reads like the original synchronous code: it throws on
# failure exactly like New-WtWingetPackage -ErrorAction Stop did, and the callers keep their
# existing try/catch structure (404 -> previous version, hash mismatch -> ask the user).
function Invoke-PackageBuildOrThrow {
  param([hashtable]$Arguments, [string]$Label = '')
  $r = Invoke-WtPackageBuild -Arguments $Arguments -Label $Label
  if (-not $r.Succeeded) { throw $r.ErrorMessage }
  return $r.Result
}

# Package/CDN endpoints can answer with HTTP 429 during bursts. Retry only that transient status;
# deterministic errors (404, hash mismatch, invalid manifest, etc.) continue into their dedicated
# fallback paths immediately. Retry-After is honored when present, otherwise use bounded backoff.
function Invoke-PackageBuildWithThrottleRetry {
  param([hashtable]$Arguments, [string]$Label = '', [int]$MaxRetries = 3)
  $retry = 0
  while ($true) {
    try { return (Invoke-PackageBuildOrThrow -Arguments $Arguments -Label $Label) }
    catch {
      $message = $_.Exception.Message
      # The status code decides when the exception carries one. The text is only consulted
      # otherwise, and then 429 must stand on its own: the previous pattern matched a bare "429"
      # anywhere, so a version number such as 1.429.0 or a package id containing those digits was
      # mistaken for throttling and the build was retried three times for nothing.
      $status = Get-ErrorHttpStatus -ErrorRecord $_
      $throttled = if ($status -gt 0) {
        $status -eq 429
      } else {
        $message -match '(?i)Too Many Requests' -or $message -match '(?i)HTTP\s*429' -or $message -match '(?<![\d.])429(?![\d.])'
      }
      # "Collection was modified" / "Value cannot be null" is the module enumerating its own live
      # app list while building - it failed the FIRST click and worked on the second. Retry it
      # automatically with a short pause so the user never has to click twice. Kept distinct from
      # throttling: a race clears in under a second, a 429 needs the longer server-directed backoff.
      $raced = (-not $throttled) -and (Test-IsTransientModuleRace $message)
      if ((-not $throttled -and -not $raced) -or $retry -ge $MaxRetries) { throw }
      $retry++
      $delay = if ($raced) { 2 } elseif ($retry -eq 1) { 5 } elseif ($retry -eq 2) { 15 } else { 30 }
      if ($throttled -and $message -match '(?i)Retry-After\s*[:=]\s*(\d+)') {
        $delay = [Math]::Max(1, [Math]::Min(45, [int]$Matches[1]))
      }
      if ($raced) {
        Write-Log ("Package build hit a transient module race {0} (retry {1}/{2}) after {3}s: {4}" -f $Label, $retry, $MaxRetries, $delay, $message)
      } else {
        Write-Log ("Package source throttled {0} (HTTP 429); retry {1}/{2} after {3}s." -f $Label, $retry, $MaxRetries, $delay)
      }
      for ($remaining = $delay; $remaining -gt 0; $remaining--) {
        if ($script:cancelBatch) { throw 'Cancelled by user while waiting for a rate-limit retry.' }
        Update-Status ((Get-UiString 'RateLimitRetryStatus') -f $retry, $remaining)
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
      }
    }
  }
}

function New-WingetPackageWithFallback {
  param(
    [string]$PackageId,
    [string]$PackageFolder,
    [string]$DesiredVersion,
    [string]$LatestVersion,
    [string]$InstalledVersion,
    [string]$Architecture,
    [string]$InstallerContext,
    [string]$Locale,
    [string]$PreferredInstaller,
    [string]$InstallerArguments,
    [switch]$PackageScript,
    [switch]$AllowUserRetry,
    # Wie oft eine HTTP-429-Sperre abgewartet wird. Der automatische Favoritenlauf beim Start setzt
    # das auf 1: 5 s statt 5+15+30 s. Er laeuft unbeaufsichtigt, blockiert aber die Busy-Sperre und
    # damit die Anmeldung samt Update-Suche - im gemeldeten Protokoll 35 s Wartezeit fuer ein Paket,
    # das danach ohnehin an einer Hash-Abweichung scheiterte.
    [int]$ThrottleRetries = 3
  )
  # Base arguments splatted into every New-WtWingetPackage attempt. Optional advanced options
  # are only included when set, so the module keeps its own defaults otherwise.
  $base = @{ PackageId = $PackageId; PackageFolder = $PackageFolder; ErrorAction = 'Stop' }
  if ($Architecture)     { $base.Architecture     = $Architecture }
  if ($InstallerContext) { $base.InstallerContext = $InstallerContext }
  if ($Locale)           { $base.Locale           = $Locale }
  # The module spells the parameter "PreferedInstaller" (one 'r'). The GUI side uses the correct
  # spelling, so the typo stays contained to this one line.
  if ($PreferredInstaller) { $base.PreferedInstaller  = $PreferredInstaller }
  if ($InstallerArguments) { $base.InstallerArguments = $InstallerArguments }
  if ($PackageScript)      { $base.PackageScript = $true }

  $attemptVersion = $DesiredVersion
  if (-not $attemptVersion) { $attemptVersion = $LatestVersion }
  try {
    if ($attemptVersion) { [void](Invoke-PackageBuildWithThrottleRetry -Arguments ($base + @{ Version = $attemptVersion }) -Label $PackageId -MaxRetries $ThrottleRetries) }
    else { [void](Invoke-PackageBuildWithThrottleRetry -Arguments $base -Label $PackageId -MaxRetries $ThrottleRetries) }
    return [pscustomobject]@{ Succeeded=$true; EffectiveVersion=$attemptVersion }
  } catch {
    $m = $_.Exception.Message
    if ($m -match '404' -or $m -match 'Not Found') {
      $prev = Get-PreviousWingetVersion -PackageId $PackageId -LatestVersion $attemptVersion
      # Only allow previous if it's newer than current tenant version (if known)
      if ($prev -and ( -not $InstalledVersion -or (Test-IsNewerVersion $prev $InstalledVersion) )) {
        try { [void](Invoke-PackageBuildWithThrottleRetry -Arguments ($base + @{ Version = $prev }) -Label $PackageId -MaxRetries $ThrottleRetries); return [pscustomobject]@{ Succeeded=$true; EffectiveVersion=$prev } } catch { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; ErrorMessage=$_.Exception.Message } }
      } else { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; ErrorMessage=$m } }
    } elseif ($m -match 'Hash mismatch') {
      if ($AllowUserRetry) {
        $res = [System.Windows.Forms.MessageBox]::Show((Get-UiString 'HashMismatchDialog'), (Get-UiString 'HashMismatchTitle'), [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button1)
        if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
          try { if ($attemptVersion) { [void](Invoke-PackageBuildWithThrottleRetry -Arguments ($base + @{ Version = $attemptVersion }) -Label $PackageId -MaxRetries $ThrottleRetries) } else { [void](Invoke-PackageBuildWithThrottleRetry -Arguments $base -Label $PackageId -MaxRetries $ThrottleRetries) }; return [pscustomobject]@{ Succeeded=$true; EffectiveVersion=$attemptVersion } } catch { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; ErrorMessage=$_.Exception.Message } }
        } elseif ($res -eq [System.Windows.Forms.DialogResult]::No) {
          $latest = $attemptVersion; if (-not $latest) { $latest = $LatestVersion }
          $prev = Get-PreviousWingetVersion -PackageId $PackageId -LatestVersion $latest
          # Only allow previous if it's newer than current tenant version (if known)
          if ($prev -and ( -not $InstalledVersion -or (Test-IsNewerVersion $prev $InstalledVersion) )) {
            try { [void](Invoke-PackageBuildWithThrottleRetry -Arguments ($base + @{ Version = $prev }) -Label $PackageId -MaxRetries $ThrottleRetries); return [pscustomobject]@{ Succeeded=$true; EffectiveVersion=$prev } } catch { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; ErrorMessage=$_.Exception.Message } }
          } else { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; ErrorMessage=$m } }
        } else { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; ErrorMessage="Cancelled by user" } }
      } else { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; ErrorMessage=$m } }
    } else { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; ErrorMessage=$m } }
  }
}

# Decides whether a folder is a protected Windows location that must never receive packages.
#
# Split out of Test-PackageFolderUsable so it can be tested: the caller shows a MessageBox, which
# makes it untestable, while THIS is the part that has to be right.
#
# Both comparisons ignore case on purpose. PowerShell's -eq does so by default, but .NET's
# String.StartsWith(String) does NOT - so "c:\program files\pakete" walked straight past a guard
# that "C:\Program Files\pakete" tripped. Windows paths are case-insensitive; a guard that is not
# only protects the spelling the caller happened to type.
function Test-IsProtectedSystemFolder {
  param([Parameter(Mandatory)][string]$Folder)
  $candidate = ([string]$Folder).Trim().TrimEnd([char]'\')
  if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
  $forbidden = @(
    [Environment]::GetFolderPath('Windows'),
    [Environment]::GetFolderPath('System'),
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64",
    "$env:ProgramFiles",
    "${env:ProgramFiles(x86)}"
  ) | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd([char]'\') }

  foreach ($p in $forbidden) {
    if ([string]::Equals($candidate, $p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($candidate.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

# Single gate for the package folder, used by every packaging/update flow (this check used to be
# copy-pasted four times and only covered system paths). Verifies: not a protected system location,
# creatable, actually WRITABLE (proven with a probe file, so a missing permission surfaces here
# instead of as a cryptic packaging error), and warns on low free disk space because packaging
# downloads installers. Returns $true when packaging may proceed.
function Test-PackageFolderUsable {
  param([Parameter(Mandatory)][string]$Folder)
  try {
    if (Test-IsProtectedSystemFolder -Folder $Folder) {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'InvalidFolderDialog') -f $Folder),
        (Get-UiString 'InvalidFolderTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
      return $false
    }

    # -LiteralPath / [IO.*] throughout: a package folder like 'Intune Pakete [Kunde]' otherwise made
    # the write probe fail (the '[' is a wildcard for -Path), and a perfectly writable folder was
    # reported to the user as "not writable". New-Item has no -LiteralPath, so use [IO.Directory].
    if (-not (Test-Path -LiteralPath $Folder)) { [void][System.IO.Directory]::CreateDirectory($Folder) }

    # Prove write access rather than assuming it.
    $probe = Join-Path $Folder (".wtgui_write_test_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    [System.IO.File]::WriteAllText($probe, 'x')
    try { [System.IO.File]::Delete($probe) } catch { }

    # Low-space warning (non-blocking – the user decides whether to continue).
    try {
      $root = [System.IO.Path]::GetPathRoot($Folder)
      if ($root) {
        $drv = Get-PSDrive -Name ($root.TrimEnd(':\/')) -ErrorAction SilentlyContinue
        if ($drv -and $null -ne $drv.Free) {
          $freeGb = [math]::Round($drv.Free / (1024 * 1024 * 1024), 1)
          if ($freeGb -lt 2) {
            $go = [System.Windows.Forms.MessageBox]::Show(
              ((Get-UiString 'LowDiskSpaceDialog') -f $freeGb, $Folder),
              (Get-UiString 'LowDiskSpaceTitle'),
              [System.Windows.Forms.MessageBoxButtons]::YesNo,
              [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($go -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
          }
        }
      }
    } catch {
      # The folder stays usable, but the user loses the low-disk-space warning before a build.
      Write-Log ("Free space check for '{0}' failed: {1}" -f $Folder, $_.Exception.Message)
    }

    return $true
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'FolderNotWritableDialog') -f $Folder, $_.Exception.Message),
      (Get-UiString 'FolderNotWritableTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error)
    Write-Log "Package folder unusable ($Folder): $($_.Exception.Message)"
    return $false
  }
}

# Force-removes an app that Intune blocks because it is still the supersedence PARENT of a newer
# app: it removes the supersedence link (new -> old) from the NEW app – keeping every other
# relationship untouched – and then deletes the old app. Uses raw Graph via the already-authenticated
# Graph REST calls authenticated with WinTuner's own token. Best-effort: on ANY doubt it aborts and returns
# $false, so the caller falls back to simply keeping the old app (nothing is left in a worse state).
# NOTE: this mutates Intune relationships and deletes an app – validate on a test app first.
function Remove-SupersededByUnlinking {
  param([Parameter(Mandatory)][string]$OldAppId, [Parameter(Mandatory)][string]$NewAppId)
  if (-not (Test-GuidString $OldAppId) -or -not (Test-GuidString $NewAppId)) { Write-Log "Unlink: invalid app id(s), aborting."; return $false }
  # Use WinTuner's OWN access token. Invoke-MgGraphRequest was the first attempt, but it needs a
  # separate Connect-MgGraph session – WinTuner authenticates through its own flow, so that call
  # always failed with "Authentication needed. Please call Connect-MgGraph." Get-WtToken hands back
  # the token of the session the user is actually connected with. (Never logged.)
  $token = $null
  try { $token = Get-WtToken -ErrorAction Stop } catch { Write-Log "Unlink: could not obtain WinTuner token: $($_.Exception.Message)"; return $false }
  if ([string]::IsNullOrWhiteSpace($token)) { Write-Log "Unlink: empty token, aborting."; return $false }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  try {
    $relUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$NewAppId/relationships"
    $rels = @(Get-GraphCollectionItems -Uri $relUri -Headers $headers)
    # Keep only OUTGOING relationships (this app is the source), minus the supersedence to the old app.
    $keep = @(); $originalOutgoing = @(); $removed = 0
    foreach ($r in $rels) {
      # Invoke-RestMethod returns PSCustomObjects (Invoke-MgGraphRequest returned hashtables), so
      # properties are accessed with dot notation here.
      $type = [string]$r.'@odata.type'; $src = [string]$r.sourceId; $tid = [string]$r.targetId
      if ($src -ne $NewAppId) { continue }   # incoming relationship – not part of updateRelationships
      if ([string]::IsNullOrWhiteSpace($type) -or -not (Test-GuidString $tid)) {
        Write-Log ("Unlink: outgoing relationship on {0} is incomplete (type='{1}', target='{2}'); aborting before mutation." -f $NewAppId, $type, $tid)
        return $false
      }
      $item = @{ '@odata.type' = $type; 'targetId' = $tid }
      if ($r.PSObject.Properties['supersedenceType'] -and $r.supersedenceType) { $item['supersedenceType'] = $r.supersedenceType }
      if ($r.PSObject.Properties['dependencyType']   -and $r.dependencyType)   { $item['dependencyType']   = $r.dependencyType }
      $originalOutgoing += $item
      if ($type -match 'Supersedence' -and $tid -eq $OldAppId) { $removed++; continue }
      $keep += $item
    }
    if ($removed -eq 0) { Write-Log "Unlink: no outgoing supersedence $NewAppId -> $OldAppId found; aborting (won't risk a blind delete)."; return $false }
    $body = @{ relationships = @($keep) } | ConvertTo-Json -Depth 8
    $updUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$NewAppId/updateRelationships"
    Invoke-RestMethod -Method POST -Uri $updUri -Headers $headers -Body $body -ErrorAction Stop | Out-Null
    Write-Log ("Unlink: removed supersedence {0} -> {1}; kept {2} other outgoing relationship(s)." -f $NewAppId, $OldAppId, $keep.Count)
    Start-Sleep -Seconds 2
    try {
      Invoke-WtRemoveWin32App -AppId $OldAppId
    } catch {
      $deleteError = $_.Exception.Message
      # The relationship mutation succeeded but deletion did not. Restore the original outgoing
      # relationship set so a transient delete failure never silently breaks supersedence.
      try {
        $restoreBody = @{ relationships = @($originalOutgoing) } | ConvertTo-Json -Depth 8
        Invoke-RestMethod -Method POST -Uri $updUri -Headers $headers -Body $restoreBody -ErrorAction Stop | Out-Null
        Write-Log ("Unlink rollback: restored {0} outgoing relationship(s) on {1} after delete failed." -f $originalOutgoing.Count, $NewAppId)
      } catch {
        Write-Log ("CRITICAL: could not restore relationships on {0} after delete of {1} failed: {2}" -f $NewAppId, $OldAppId, $_.Exception.Message)
      }
      throw $deleteError
    }
    Write-Log "Unlink: old app $OldAppId deleted after removing the supersedence link."
    return $true
  } catch {
    Write-Log ("Unlink: failed for old app {0} (kept it): {1}" -f $OldAppId, $_.Exception.Message)
    return $false
  }
}


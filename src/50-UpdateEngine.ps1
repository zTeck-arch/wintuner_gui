# Keeps only the newest $KeepCount versions per app and removes everything older.
# SAFETY: a group is only touched when every version in it parses as a real version number – if any
# version string is unparseable the whole group is skipped and logged, because guessing the order
# here would mean deleting the wrong app. Groups with <= KeepCount versions are never touched, so a
# single existing version can never be deleted.
function Get-AppVersionGroups {
  param([int]$KeepCount = 2)
  # Both inventories on purpose: an old version is a candidate for trimming whether or not Intune
  # marked it as superseded. The two queries are documented as disjoint ("only apps that are
  # superseded" / "only apps that are not"), but they have been observed overlapping right after a
  # supersedence was created - which is why Remove-SupersededInventoryOverlap exists at all.
  #
  # Concatenating them without de-duplicating counted such an app TWICE. That is not cosmetic here:
  # the group size decides whether a group is trimmed at all, and the duplicate occupied one of the
  # "keep newest N" slots, pushing a version that should have been kept into the delete list.
  $all = @()
  $all += @(Get-Win32AppsResilient -Label 'version cleanup (active)')
  # Superseded stays best-effort: a version is a trimming candidate whether or not it is marked
  # superseded, so a failed superseded read must not abort the whole cleanup.
  try { $all += @(Get-Win32AppsResilient -Superseded -Label 'version cleanup (superseded)') }
  catch { Write-Log ("Version cleanup: superseded inventory read failed after retries: {0}" -f $_.Exception.Message) }
  $seenGraphIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $all = @($all | Where-Object {
    $_ -and $_.Name -and $_.GraphId -and $seenGraphIds.Add([string]$_.GraphId)
  })

  $groupModels = foreach ($app in $all) {
    $packageId = Resolve-WtWingetId -AppOrResult $app
    if (-not $packageId) {
      Write-Log ("Version cleanup: skipping '{0}' ({1}) because no authoritative PackageId is available; display-name grouping is unsafe." -f $app.Name, $app.GraphId)
      continue
    }
    $laneName = ([string]$app.Name).Trim().ToLowerInvariant()
    [pscustomobject]@{ Key = "id:$($packageId.ToLowerInvariant())|name:$laneName"; App = $app }
  }

  $result = @()
  foreach ($grp in ($groupModels | Group-Object -Property Key)) {
    if ($grp.Count -le $KeepCount) { continue }
    $parsed = @()
    $bad = $false
    foreach ($model in $grp.Group) {
      $a = $model.App
      $raw = [string]$a.CurrentVersion
      if (-not (Get-ComparableVersionParts $raw)) { $bad = $true; break }
      $parsed += [pscustomobject]@{ App = $a; Raw = $raw }
    }
    if ($bad) {
      Write-Log ("Version cleanup: skipping '{0}' - version numbers not comparable (nothing deleted)." -f $grp.Group[0].App.Name)
      continue
    }
    # Stable insertion sort uses the same arbitrary-length comparison as the update scanner.
    $sortedList = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $parsed) {
      $insertAt = $sortedList.Count
      for ($i = 0; $i -lt $sortedList.Count; $i++) {
        if (Test-IsNewerVersion -Latest $entry.Raw -Current $sortedList[$i].Raw) { $insertAt = $i; break }
      }
      $sortedList.Insert($insertAt, $entry)
    }
    $sorted = @($sortedList)
    $obsolete = @($sorted | Select-Object -Skip $KeepCount)
    if ($obsolete.Count -gt 0) {
      $result += [pscustomobject]@{
        Name     = [string]$grp.Group[0].App.Name
        PackageKey = [string]$grp.Name
        Keep     = @($sorted | Select-Object -First $KeepCount)
        Obsolete = $obsolete
      }
    }
  }
  return @($result)
}

# Runs the "keep only N versions" cleanup. -Silent skips the confirmation (used by the automatic
# post-update run); interactive callers get a Yes/No list of exactly what would be removed.
function Invoke-VersionCleanup {
  param([int]$KeepCount = 2, [switch]$Silent)
  if (-not $script:isConnected) { return }
  try {
    Update-Status (Get-UiString 'VersionCleanupScanStatus')
    [System.Windows.Forms.Application]::DoEvents()
    $groups = Get-AppVersionGroups -KeepCount $KeepCount
    $obsoleteAll = @($groups | ForEach-Object { $_.Obsolete })
    if ($obsoleteAll.Count -eq 0) {
      Write-Log ("Version cleanup: nothing to do (no app has more than {0} version(s))." -f $KeepCount)
      if (-not $Silent) { Update-Status (Get-UiString 'VersionCleanupNothingStatus') }
      return
    }

    if (-not $Silent) {
      $lines = @($groups | ForEach-Object {
        $g = $_
        "$($g.Name): " + (($g.Obsolete | ForEach-Object { $_.Raw }) -join ', ') +
        "  ->  " + (Get-UiString 'VersionCleanupKeepLabel') + " " + (($g.Keep | ForEach-Object { $_.Raw }) -join ', ')
      })
      $confirm = [System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'VersionCleanupConfirmDialog') -f $obsoleteAll.Count, $KeepCount, ($lines -join "`r`n")),
        (Get-UiString 'ConfirmTitle'),
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
      if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Update-Status (Get-UiString 'VersionCleanupCanceledStatus'); return
      }
    }

    # "Protected" and "failed" are counted apart. A version Intune still reports as assigned or
    # installed was kept exactly as designed - that is the guard working, not a fault. Reporting
    # both as one number made a correct run read like a broken one ("0 removed, 4 kept back by
    # safety checks or errors"), and the reason was only ever visible in the log.
    $removed = 0; $failed = 0
    $protectedItems = [System.Collections.Generic.List[string]]::new()
    foreach ($g in $groups) {
      # Oldest first, so the supersedence chain is unwound from the bottom.
      $oldestFirst = @($g.Obsolete)
      [array]::Reverse($oldestFirst)
      foreach ($item in $oldestFirst) {
        Update-Status ((Get-UiString 'VersionCleanupRemovingStatus') -f $g.Name, $item.Raw)
        [System.Windows.Forms.Application]::DoEvents()
        $assignmentProbe = Get-AppAssignmentProbe -AppId $item.App.GraphId -AppName $g.Name
        $installationProbe = Get-AppInstallationProbe -AppId $item.App.GraphId -AppName $g.Name
        if (-not $assignmentProbe.Succeeded -or -not $installationProbe.Succeeded -or
            $assignmentProbe.HasAssignments -or $installationProbe.HasInstallations) {
          if (-not $assignmentProbe.Succeeded -or -not $installationProbe.Succeeded) {
            # Unknown state is a genuine problem: nothing can be decided, so this one counts as an
            # error rather than as a deliberate protection.
            $failed++
            $reason = 'assignment/installation state is unknown'
            $reasonText = Get-UiString 'CleanupKeptReasonUnknown'
          } elseif ($assignmentProbe.HasAssignments) {
            $reason = 'the app still has assignments'
            $reasonText = Get-UiString 'CleanupKeptReasonAssigned'
            [void]$protectedItems.Add(("{0} {1} - {2}" -f $g.Name, $item.Raw, $reasonText))
          } else {
            $reason = 'Intune still reports successful installations'
            # Count can be $null when only the device-status path answered (it stops at the first hit
            # and never counts). Show the no-number message then instead of a misleading "0 device(s)".
            $reasonText = if ($null -ne $installationProbe.Count) {
              (Get-UiString 'CleanupKeptReasonInstalled') -f ([int]$installationProbe.Count)
            } else {
              Get-UiString 'CleanupKeptReasonInstalledNoCount'
            }
            [void]$protectedItems.Add(("{0} {1} - {2}" -f $g.Name, $item.Raw, $reasonText))
          }
          Write-Log ("Version cleanup: kept {0} {1} ({2}) because {3}." -f $g.Name, $item.Raw, $item.App.GraphId, $reason)
          continue
        }
        if (Remove-AppWithUnlinkFallback -GraphId $item.App.GraphId -AppName $g.Name -Version $item.Raw -RecordAs 'VersionRemoved') {
          $removed++
          Write-Log ("Version cleanup: removed {0} {1}" -f $g.Name, $item.Raw)
        } else { $failed++ }
      }
    }
    Write-Log ("Version cleanup finished: {0} removed, {1} protected by the safety checks, {2} failed." -f $removed, $protectedItems.Count, $failed)
    Update-Status ((Get-UiString 'VersionCleanupDoneStatus') -f $removed, $protectedItems.Count, $failed)

    # Say WHY, where the user is looking. Without this the run reads as "nothing happened" and the
    # explanation sits in a log file nobody opens mid-task.
    if ($protectedItems.Count -gt 0 -and -not $Silent) {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'CleanupKeptDialog') -f $protectedItems.Count, (($protectedItems | Select-Object -First 15) -join "`r`n")),
        (Get-UiString 'CleanupKeptTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    }
    # Only when the user started the cleanup themselves. Inside an update batch the progress bar is
    # still visible, so this click landed in Test-UiBusy and put a MODAL "another operation is
    # running" box up - usually behind the window, where it silently blocked the whole batch until
    # someone found and dismissed it (58s in one recorded run).
    if (-not $Silent) {
      try { if ($supersededSearchButton -and $supersededSearchButton.Enabled) { $supersededSearchButton.PerformClick() } } catch {}
    }
  } catch {
    Write-Log ("Version cleanup error: {0}" -f (Format-ErrorDetail $_))
    Update-Status ((Get-UiString 'VersionCleanupErrorStatus') -f $_.Exception.Message)
  }
}

# Extracts the superseding (new) app id from Intune's "parent of another app: <guid>" delete error.
function Get-SupersedingAppIdFromError {
  param([string]$Message)
  if ($Message -match 'parent of another app:\s*([0-9a-fA-F-]{36})') { return $Matches[1] }
  return $null
}

# Performs update workflow for a single app (create package + deploy)
function Update-SingleApp {
  param(
    [Parameter(Mandatory=$true)]
    [string]$AppName,
    [Parameter(Mandatory=$false)]
    [string]$CurrentVersion,
    [Parameter(Mandatory=$false)]
    [string]$LatestVersion,
    [Parameter(Mandatory=$false)]
    [string]$GraphId,
    [Parameter(Mandatory=$false)]
    [string]$PackageIdentifier,
    [Parameter(Mandatory=$false)]
    [string]$ExistingTargetGraphId,
    [Parameter(Mandatory=$true)]
    [string]$RootPackageFolder,
    [switch]$AllowUserRetry
  )

  $result = @{
    Success = $false
    Message = ""
    EffectiveVersion = $null
    OldVersionRemoved = $false
    AssignmentsMoved = $false
    NewVersionAssignmentsCleared = $false
    # Separate from OldVersionRemoved on purpose. "Superseded" and "deleted" are two different
    # outcomes for the predecessor, and the performance record used to print the word for the
    # first while reporting the second - so a run that DELETED two apps read as if it had merely
    # superseded them, and the "old versions removed" tally stayed at zero.
    SupersedenceCreated = $false
    PredecessorHadAssignments = $false
    SupersedenceSkipped = $false
    NewAppId = $ExistingTargetGraphId
  }

  try {
    Write-Log "Starting update for: $AppName (Current: $CurrentVersion, Latest: $LatestVersion)"

    # 1) Resolve Winget ID - use PackageIdentifier if available, otherwise fail
    $wingetId = $PackageIdentifier

    $wingetIdForLog = if ($wingetId) { $wingetId } else { '<none>' }
    Write-Log ("Resolved winget id for {0}: {1}" -f $AppName, $wingetIdForLog)

    if ([string]::IsNullOrWhiteSpace($wingetId)) {
      $result.Message = "Cannot determine PackageId for '$AppName'"
      Write-Log $result.Message
      return $result
    }

    # The target id captured during the scan is only a hint. Re-read Intune immediately before any
    # package build so a stale/failed scan or a concurrent administrator action cannot create the
    # same PackageId+Version twice. Any failed or ambiguous guard blocks the mutation safely.
    try {
      $freshTarget = Get-FreshExistingUpdateTarget -PackageId $wingetId -Version $LatestVersion `
        -ExcludeGraphId $GraphId -PreferredName $AppName
      if ($freshTarget -and $freshTarget.GraphId) {
        $ExistingTargetGraphId = [string]$freshTarget.GraphId
        $result.NewAppId = $ExistingTargetGraphId
      } elseif ($ExistingTargetGraphId) {
        Write-Log ("Pre-upload target guard: scan target {0} is no longer an active exact match; the fresh tenant result is authoritative." -f $ExistingTargetGraphId)
        $ExistingTargetGraphId = $null
        $result.NewAppId = $null
      }
    } catch {
      $result.Message = "Duplicate safety check failed for '$AppName'; no package was built or uploaded: $($_.Exception.Message)"
      Write-Log $result.Message
      return $result
    }

    # If the requested target version already exists, never deploy a duplicate Intune app. Treat
    # this row as consolidation of one concrete old Graph object into the existing target.
    if ($GraphId -and $ExistingTargetGraphId) {
      if ([string]::Equals($GraphId, $ExistingTargetGraphId, [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.Message = "Old and target Graph IDs are identical for '$AppName'; refusing an ambiguous consolidation."
        Write-Log $result.Message
        return $result
      }
      $result.EffectiveVersion = $LatestVersion
      $result.SupersedenceSkipped = $true
      Write-Log ("Reusing existing Intune target for {0}: {1} -> {2} (target GraphId: {3})" -f $AppName, $CurrentVersion, $LatestVersion, $ExistingTargetGraphId)

      $assignmentProbe = Get-AppAssignmentProbe -AppId $GraphId -AppName $AppName
      if (-not $assignmentProbe.Succeeded) {
        $result.Message = "Existing target found, but assignments of the old app could not be verified; no change was made."
        Write-Log ("Consolidation blocked for {0}: {1}" -f $AppName, $result.Message)
        return $result
      }
      $preInstallProbe = Get-AppInstallationProbe -AppId $GraphId -AppName $AppName

      if ($assignmentProbe.HasAssignments) {
        if (-not $script:settings.MoveAssignmentsOnUpdate) {
          $result.Message = "The latest version already exists, but the old app is assigned and assignment hand-over is disabled in Settings."
          Write-Log ("Consolidation skipped for {0}: {1}" -f $AppName, $result.Message)
          return $result
        }
        if (-not (Move-AppAssignments -OldAppId $GraphId -NewAppId $ExistingTargetGraphId -AppName $AppName)) {
          $result.Message = "The latest version already exists, but assignments could not be moved from the old app."
          Write-Log ("Consolidation failed for {0}: {1}" -f $AppName, $result.Message)
          return $result
        }
        $result.AssignmentsMoved = $true
      }

      # Re-probing only makes sense when something was actually changed in between. Without a
      # hand-over nothing touched this app, so the pre-probes still describe it exactly - asking
      # Intune again cost two extra round trips per predecessor and produced the duplicated probe
      # pairs in the log.
      $postAssignmentProbe = if ($result.AssignmentsMoved) {
        Get-AppAssignmentProbe -AppId $GraphId -AppName $AppName
      } else { $assignmentProbe }
      $postInstallProbe = if ($result.AssignmentsMoved) {
        Get-AppInstallationProbe -AppId $GraphId -AppName $AppName
      } else { $preInstallProbe }
      $zeroInstallationsConfirmed = (
        $preInstallProbe.Succeeded -and -not $preInstallProbe.HasInstallations -and
        $postInstallProbe.Succeeded -and -not $postInstallProbe.HasInstallations)
      $mayDeleteByPolicy = (-not $assignmentProbe.HasAssignments) -or [bool]$script:settings.AutoRemoveSuperseded
      $safeExceptHandover = (
        $postAssignmentProbe.Succeeded -and -not $postAssignmentProbe.HasAssignments -and
        $zeroInstallationsConfirmed -and $mayDeleteByPolicy)
      # Same reason as in the supersedence path below: when this app WAS assigned, its assignments
      # must be provably on the reused target before the source may be deleted. Asked last, and only
      # when everything else already allows the deletion - the probe costs Graph calls and a short
      # wait, and a predecessor that never had an assignment has nothing to hand over anyway.
      $handoverConfirmed = $true
      if ($safeExceptHandover -and $assignmentProbe.HasAssignments) {
        $handoverConfirmed = Test-SuccessorAssignmentsConfirmed -NewAppId $ExistingTargetGraphId -AppName $AppName
      }
      $safeToDelete = ($safeExceptHandover -and $handoverConfirmed)

      if ($safeToDelete) {
        try {
          $null = Save-AppScopeSnapshot -AppId $GraphId -AppName $AppName -Version $CurrentVersion `
            -Reason (Get-UiString 'ScopeSnapshotReasonConsolidation')
          Invoke-WtRemoveWin32App -AppId $GraphId
          $result.OldVersionRemoved = $true
          Write-Log ("Consolidation: removed unused old app {0} {1} ({2}); target {3} already existed." -f $AppName, $CurrentVersion, $GraphId, $ExistingTargetGraphId)
        } catch {
          $result.Message = "Assignments were consolidated, but the unused old version could not be removed: $($_.Exception.Message)"
          Write-Log ("Consolidation cleanup failed for {0}: {1}" -f $AppName, $_.Exception.Message)
        }
      } elseif (-not $handoverConfirmed) {
        Write-Log ("Consolidation: kept old app {0} because the reused target {1} carries no confirmed assignment; deleting the source would leave the app assigned to nobody." -f $AppName, $ExistingTargetGraphId)
      } elseif (-not $postAssignmentProbe.Succeeded -or -not $preInstallProbe.Succeeded -or -not $postInstallProbe.Succeeded) {
        Write-Log ("Consolidation: kept old app {0} because assignment/installation state was not safely verifiable." -f $AppName)
      } elseif ($postInstallProbe.HasInstallations -or $preInstallProbe.HasInstallations) {
        Write-Log ("Consolidation: kept old app {0} because Intune still reports successful installations." -f $AppName)
      } elseif (-not $mayDeleteByPolicy) {
        Write-Log ("Consolidation: kept formerly assigned old app {0} because automatic assigned-predecessor removal is disabled." -f $AppName)
      }

      $result.Success = $true
      if ([string]::IsNullOrWhiteSpace($result.Message)) {
        $result.Message = if ($result.OldVersionRemoved) {
          "Existing latest version reused; unused old version removed."
        } else {
          "Existing latest version reused; old version kept according to safety/settings."
        }
      }
      return $result
    }

    # 2) Create/refresh package using fallback logic
    Write-Log "Creating package for $AppName..."
    # Step display: name the phase the run is in. Packaging is the long, silent phase (a big
    # installer can take minutes), so saying so beats a progress bar that cannot show a percentage
    # the tools never report. The prefix carries the batch counter ("(2/8) ") or is empty.
    Update-Status ((Get-UiString 'PhasePackagingStatus') -f $script:batchProgressPrefix, $AppName, $LatestVersion)
    # For updates, ALWAYS use LatestVersion (ignore cached selectedPackageVersions)
    $desired = $LatestVersion
    Write-Log "Update workflow: forcing LatestVersion $desired (ignoring any cached selection)"

    $resPkg = New-WingetPackageWithFallback `
      -PackageId $wingetId `
      -PackageFolder $RootPackageFolder `
      -DesiredVersion $desired `
      -LatestVersion $LatestVersion `
      -InstalledVersion $CurrentVersion `
      -AllowUserRetry:$AllowUserRetry `
      -ErrorAction SilentlyContinue

    if (-not $resPkg -or -not $resPkg.Succeeded) {
      $errDetail = if ($resPkg -and $resPkg.ErrorMessage) { ": $($resPkg.ErrorMessage)" } else { "" }
      $result.Message = "Package creation failed for $AppName$errDetail"
      Write-Log $result.Message
      return $result
    }

    $effectiveVersion = if ($resPkg.EffectiveVersion) { $resPkg.EffectiveVersion } else { $LatestVersion }
    $result.EffectiveVersion = $effectiveVersion

    # Supersedence has no rollout value when the predecessor is assigned to nobody. Probe directly
    # before deployment so an unassigned update can be created as a standalone app. Deletion is a
    # separate decision: it additionally requires a confirmed zero successful-installation state,
    # both before and after deployment.
    $deployWithoutSupersedence = $false
    $preDeployInstallationProbe = $null
    if ($GraphId) {
      $assignmentProbe = Get-AppAssignmentProbe -AppId $GraphId -AppName $AppName
      # Remembered for the performance record: whether the predecessor was assigned decides whether
      # a hand-over happened at all, and the record has to say so.
      $result.PredecessorHadAssignments = [bool]($assignmentProbe.Succeeded -and $assignmentProbe.HasAssignments)
      if ($assignmentProbe.Succeeded -and -not $assignmentProbe.HasAssignments) {
        $deployWithoutSupersedence = $true
        $result.SupersedenceSkipped = $true
        $preDeployInstallationProbe = Get-AppInstallationProbe -AppId $GraphId -AppName $AppName
        if ($preDeployInstallationProbe.Succeeded -and -not $preDeployInstallationProbe.HasInstallations) {
          Write-Log ("Update mode for '{0}': predecessor has no assignment or successful installation; deploying without supersedence and allowing guarded cleanup." -f $AppName)
        } elseif ($preDeployInstallationProbe.Succeeded) {
          Write-Log ("Update mode for '{0}': predecessor has no assignment but still has successful installations; deploying without supersedence and keeping the old app." -f $AppName)
        } else {
          Write-Log ("Update mode for '{0}': predecessor has no assignment but installation state is unknown; deploying without supersedence and blocking automatic deletion." -f $AppName)
        }
      } elseif (-not $assignmentProbe.Succeeded) {
        Write-Log ("Update mode for '{0}': assignment state could not be verified; using the safe supersedence workflow." -f $AppName)
      } else {
        Write-Log ("Update mode for '{0}': predecessor is assigned; using supersedence and assignment hand-over." -f $AppName)
      }
    }

    # Genau hier beginnt die lange, blockierende Phase - und genau hier lohnt sich der Vorab-Bau:
    # das Paket DIESER App ist fertig, der Upload dauert, und der Runspace daneben kann in dieser
    # Zeit schon die naechste App bauen. Vorgemerkt hat sie der Stapellauf; laeuft keiner oder ist
    # nichts vorgemerkt, passiert hier nichts. Der Aufruf steht VOR dem Upload, weil er ihn nicht
    # aufhaelt: er stoesst nur an und kehrt sofort zurueck.
    Start-PendingPackagePrebuild

    # 3) Deploy with best available identifier
    Write-Log "Deploying $AppName version $effectiveVersion..."
    # Phase switch: the upload runs in the background upload runspace (Invoke-WtDeployOffThread), so
    # the window keeps drawing while it works. Until 0.18.0 this ran on the UI thread and the window
    # went "Not responding" - the sentence "the Graph session is per-runspace" that used to stand
    # here was wrong: GraphSession::Instance is a static singleton (GraphSessionSharing.Tests.ps1).
    Update-Status ((Get-UiString 'PhaseUploadingStatus') -f $script:batchProgressPrefix, $AppName, $effectiveVersion)
    $deploySplat = @{
      RootPackageFolder = $RootPackageFolder
      ErrorAction = 'Stop'
    }

    if ($GraphId -and -not $deployWithoutSupersedence) {
      $deploySplat.GraphId = $GraphId
      # IMPORTANT module semantics: Deploy-WtWin32App ALWAYS copies the predecessor's assignments
      # onto the new version during supersedence. -KeepAssignments does NOT stop that copy; it only
      # stops the module from emptying the OLD app afterwards. So:
      #   * hand-over ON  (default): deploy without KeepAssignments -> module copies to new AND empties
      #     old. Move-AppAssignments below is a safety net. Result: new assigned, old empty.
      #   * hand-over OFF: deploy WITH KeepAssignments -> old keeps its assignments. The new version is
      #     still assigned by the copy, so we explicitly clear it after resolution (see below) to make
      #     "the new one is deployed unassigned" actually true.
      if (-not $script:settings.MoveAssignmentsOnUpdate) { $deploySplat.KeepAssignments = $true }
      $deploySplat.PackageId = $wingetId
      $deploySplat.Version = $effectiveVersion
      Write-Log ("Deploying by GraphId ({0}) + PackageId/Version (KeepAssignments={1})" -f $GraphId, [bool]$deploySplat.KeepAssignments)
      # Handing the predecessor GraphId to the module IS the supersedence request.
      $result.SupersedenceCreated = $true
    } else {
      $deploySplat.PackageId = $wingetId
      $deploySplat.Version = $effectiveVersion
      if ($GraphId -and $deployWithoutSupersedence) {
        Write-Log "Deploying unassigned update by PackageId ($wingetId) version $effectiveVersion without GraphId/supersedence"
      } else {
        Write-Log "Deploying by PackageId ($wingetId) version $effectiveVersion"
      }
    }

    # Preserve a tenant-specific display name across the supersedence update when supported by
    # the installed module; otherwise the new app can unexpectedly revert to the WinGet title.
    $deployCommand = Get-Command Deploy-WtWin32App -ErrorAction Stop
    if ($AppName -and $deployCommand.Parameters.ContainsKey('OverrideAppName')) {
      $deploySplat.OverrideAppName = $AppName
    }

    # Capture the module return value only as a diagnostic hint. Depending on WinTuner/module
    # version, .Id may describe an operation/result object rather than the Graph mobileApp.
    # Upload and target resolution are timed separately. They used to sit between the same two log
    # lines, so a slow run could not be attributed: a large installer legitimately takes a minute to
    # upload, while a slow RESOLVE would mean Intune is late listing the new app - two different
    # problems with two different answers.
    $deployStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $deployedApp = Invoke-WtDeployOffThread -Arguments $deploySplat -Label ("{0} {1}" -f $wingetId, $effectiveVersion)
    $deployStopwatch.Stop()
    Write-Log ("Upload finished in {0:n1}s for {1} {2}." -f $deployStopwatch.Elapsed.TotalSeconds, $wingetId, $effectiveVersion)
    $returnedId = $null
    try {
      if ($deployedApp -and $deployedApp.Id) { $returnedId = [string]$deployedApp.Id }
    } catch {
      Write-Log ("Could not read the deploy return id for {0}: {1}" -f $AppName, $_.Exception.Message)
    }
    $resolveStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $resolvedTarget = Resolve-DeployedUpdateTarget -PackageId $wingetId -Version $effectiveVersion -ExcludeGraphId $GraphId -PreferredName $AppName -ReturnedId $returnedId
    $resolveStopwatch.Stop()
    Write-Log ("Target resolution took {0:n1}s for {1} {2}." -f $resolveStopwatch.Elapsed.TotalSeconds, $wingetId, $effectiveVersion)
    $newAppId = if ($resolvedTarget -and $resolvedTarget.GraphId) { [string]$resolvedTarget.GraphId } else { $null }

    # Scope hand-over: only the newest version should stay assigned. Runs even when the module
    # already moved them – Move-AppAssignments is a no-op when the old app has no assignments left.
    if ($GraphId -and -not $deployWithoutSupersedence -and $script:settings.MoveAssignmentsOnUpdate) {
      if ($newAppId) {
        if (Move-AppAssignments -OldAppId $GraphId -NewAppId $newAppId -AppName $AppName) {
          $result.AssignmentsMoved = $true
        }
        # Record the hand-over even when Move-AppAssignments found nothing left to move.
        #
        # That is the NORMAL outcome: Deploy-WtWin32App always copies the predecessor's assignments
        # onto the new version and clears the old one, so by the time we look there is nothing left.
        # Move-AppAssignments then returns early without recording, and the record showed no
        # assignment work at all for a run whose whole point was handing the scope over.
        if ($result.PredecessorHadAssignments -and -not $result.AssignmentsMoved) {
          try {
            Add-SessionActivity -Kind 'AssignmentsChanged' -Name $AppName `
              -ToVersion $effectiveVersion -Detail (Get-UiString 'ActivityAssignmentHandedOver')
          } catch { }
        }
      } else {
        Write-Log ("Assignments: the new target GraphId for {0} could not be resolved from Intune - predecessor keeps its assignments (check the portal)." -f $AppName)
      }
    }

    # Hand-over OFF: the module copied the predecessor's assignments onto the new version anyway.
    # Clear them so the new app is genuinely unassigned, matching what the update notice promised.
    # The old app keeps its assignments (KeepAssignments was set on the deploy).
    if ($GraphId -and -not $deployWithoutSupersedence -and -not $script:settings.MoveAssignmentsOnUpdate) {
      if ($newAppId) {
        if (Clear-AppAssignments -AppId $newAppId -AppName $AppName) {
          $result.NewVersionAssignmentsCleared = $true
        } else {
          Write-Log ("Assignments: could not clear the new version of {0} - it may remain assigned alongside the old one (check the portal)." -f $AppName)
        }
      } else {
        Write-Log ("Assignments: new target GraphId for {0} not resolved - cannot clear the new version's copied assignments (check the portal)." -f $AppName)
      }
    }

    $result.Success = $true
    $result.Message = "Update completed successfully for $AppName"
    Write-Log $result.Message

    # 4a) No assignment means no supersedence is needed. Re-check BOTH conditions AFTER the upload
    # to close races while packaging is running. Only confirmed zero assignments AND confirmed zero
    # successful installations before and after deployment authorize automatic deletion.
    if ($GraphId -and $deployWithoutSupersedence) {
      $postDeployProbe = Get-AppAssignmentProbe -AppId $GraphId -AppName $AppName
      $postDeployInstallationProbe = Get-AppInstallationProbe -AppId $GraphId -AppName $AppName
      $safeToDeleteUnusedPredecessor = (
        $postDeployProbe.Succeeded -and -not $postDeployProbe.HasAssignments -and
        $preDeployInstallationProbe -and $preDeployInstallationProbe.Succeeded -and -not $preDeployInstallationProbe.HasInstallations -and
        $postDeployInstallationProbe.Succeeded -and -not $postDeployInstallationProbe.HasInstallations)
      if ($safeToDeleteUnusedPredecessor) {
        try {
          $null = Save-AppScopeSnapshot -AppId $GraphId -AppName $AppName -Version $CurrentVersion `
            -Reason (Get-UiString 'ScopeSnapshotReasonUpdateCleanup')
          Invoke-WtRemoveWin32App -AppId $GraphId
          $result.Message += " (unused old version removed; no supersedence created)"
          $result.OldVersionRemoved = $true
          Write-Log "Update cleanup: removed predecessor without assignments or successful installations for $AppName (old GraphId: $GraphId); no supersedence was created."
        } catch {
          $rawMsg = $_.Exception.Message
          if (Test-IsNotFoundError -ErrorRecord $_ -Context $AppName) {
            $result.Message += " (unused old version already removed; no supersedence created)"
            $result.OldVersionRemoved = $true
            Write-Log "Update cleanup: unused predecessor for $AppName was already absent; no supersedence was created."
          } else {
            $result.Message += " (no supersedence; old unused version could not be removed: $rawMsg)"
            Write-Log "Update cleanup: could not remove unused predecessor for ${AppName}: $rawMsg"
          }
        }
      } elseif ($postDeployProbe.Succeeded -and $postDeployProbe.HasAssignments) {
        $result.Message += " (no supersedence; old version kept because it received an assignment during the update)"
        Write-Log "Update cleanup: kept old version of $AppName because it received an assignment during the update."
      } elseif (($preDeployInstallationProbe -and $preDeployInstallationProbe.Succeeded -and $preDeployInstallationProbe.HasInstallations) -or
                ($postDeployInstallationProbe.Succeeded -and $postDeployInstallationProbe.HasInstallations)) {
        $result.Message += " (no supersedence; old version kept because Intune reports successful installations)"
        Write-Log "Update cleanup: kept old version of $AppName because Intune reports successful installations."
      } else {
        $result.Message += " (no supersedence; old version kept because assignment/installation state could not be safely verified)"
        Write-Log "Update cleanup: kept old version of $AppName because assignment or installation state could not be safely verified."
      }
    }
    $result.NewAppId = $newAppId

    # 4b) Assigned predecessors use the regular supersedence workflow. Remove the old app right
    # away only when the user enabled that option; otherwise Intune keeps it for rollout handling.
    if ($GraphId -and -not $deployWithoutSupersedence -and $script:settings.AutoRemoveSuperseded) {
      if (-not $newAppId -or -not $result.AssignmentsMoved) {
        $result.Message += " (old version kept - assignment hand-over was not confirmed)"
        Write-Log ("Ablöse: kept the old version of {0}; automatic deletion requires both an authoritative target GraphId and a confirmed assignment hand-over." -f $AppName)
        return $result
      }
      # AssignmentsMoved is already satisfied by "the old app has nothing left to move" - which is
      # what the module leaves behind after it handed the assignments over itself, and equally what
      # a silently failed hand-over looks like. Ask the successor directly before deleting the only
      # other object that could still be in scope.
      if (-not (Test-SuccessorAssignmentsConfirmed -NewAppId $newAppId -AppName $AppName)) {
        $result.Message += " (old version kept - the new version carries no confirmed assignment)"
        Write-Log ("Ablöse: kept the old version of {0}; successor {1} has no confirmed assignment, so deleting the predecessor would leave the app assigned to nobody. Check the assignments in Intune." -f $AppName, $newAppId)
        return $result
      }
      try {
        Invoke-WtRemoveWin32App -AppId $GraphId
        $result.Message += " (old version removed)"
        $result.OldVersionRemoved = $true
        Write-Log "Ablöse: removed superseded app for $AppName (old GraphId: $GraphId)"
      } catch {
        $rawMsg = $_.Exception.Message
        # Intune refuses to delete an app while it is still referenced as the predecessor
        # (supersedence parent) of the freshly deployed version. That is EXPECTED: the old version
        # stays until devices have migrated to the new one, then it can be removed via the
        # "Superseded apps" cleanup. So treat this as a benign, explained outcome – not a failure.
        if ($rawMsg -match 'parent of another app' -or $rawMsg -match 'Cannot delete this app') {
          # Blocked because the freshly deployed app still references the old one via supersedence.
          # Remove that link from the NEW app (found in the error), then delete the old app.
          $newId = Get-SupersedingAppIdFromError $rawMsg
          if ($newId -and (Remove-SupersededByUnlinking -OldAppId $GraphId -NewAppId $newId)) {
            $result.Message += " (old version removed via supersedence unlink)"
            $result.OldVersionRemoved = $true
            Write-Log "Ablöse: removed the old version of $AppName by unlinking the supersedence on the new app ($newId)."
          } else {
            $result.Message += " (old version kept - still the supersedence predecessor)"
            Write-Log "Ablöse: kept the old version of $AppName - Intune still references it as the predecessor of the new version. It can be removed later via 'Superseded apps'."
          }
        } else {
          $result.Message += " (old version NOT removed: $rawMsg)"
          Write-Log "Ablöse: failed to remove superseded app for ${AppName}: $rawMsg"
        }
      }
    }

  } catch {
    # The user-facing message stays short; the log gets the full detail (type, inner exception,
    # HTTP status, line) so a failed update can actually be diagnosed from the log afterwards.
    $result.Message = "Update failed for ${AppName}: $($_.Exception.Message)"
    Write-Log ("Update failed for {0}: {1}" -f $AppName, (Format-ErrorDetail $_))
  }

  return $result
}

# Builds a short, ticket-system-ready text for the currently connected tenant. The dialog shows
# timestamp and tenant separately; only the action sentence and application list are copyable.
# The performance record (Leistungsnachweis) has its OWN language, independent of the app UI
# language, because it is pasted into a ticket system. Default German; switchable in the dialog.
$script:leistungLang = 'de'
# Der Kunde ist die DOMAENE, nicht das Konto: beim Dienstleister liegen die Rechte oft auf einem
# zweiten Konto desselben Tenants. Leer bleibt leer - ein Eintrag ohne Tenant wird nie einem
# Kunden zugeschlagen.
function Get-ActivityTenantDomain {
  param([string]$Upn)
  if ([string]::IsNullOrWhiteSpace($Upn) -or $Upn -notmatch '@') { return "" }
  try { return ($Upn -split '@')[-1].Trim().ToLowerInvariant() } catch { return "" }
}

function Get-SessionLeistungstext {
  param([string]$Lang)
  if ([string]::IsNullOrWhiteSpace($Lang)) { $Lang = $script:leistungLang }
  if ([string]::IsNullOrWhiteSpace($Lang)) { $Lang = 'de' }
  $tpl = if ($Lang -eq 'en') {
    @{ Intro = "The following applications were updated and deployed in the customer's Intune environment, including the required assignments and supersedence of old applications:"
       None = "Nothing has been recorded for this tenant in this session yet."
       NotSignedIn = "Sign in to a tenant to see its performance record."
       OrphanHead = "Note: {0} entr(y/ies) below could not be attributed to a tenant - they were recorded while the session was disconnected. Please check whether they belong to this customer:"
       Superseded = " (predecessor superseded, kept in Intune)"
       SupersededMany = " ({0} predecessors superseded, kept in Intune)"
       Removed = " (predecessor deleted)"
       RemovedMany = " ({0} predecessors deleted)"
       SupersededAndRemoved = " ({0} superseded and kept, {1} deleted)"
       HeadUpdates = "Updated:"
       HeadDeployed = "Newly deployed:"
       HeadVersionRemoved = "Old versions removed:"
       HeadSupersededRemoved = "Superseded apps deleted:"
       HeadAssignments = "Assignments changed:"
       Summary = "Summary: {0} app(s) updated, {1} predecessor(s) superseded and kept, {2} predecessor(s) deleted during the update, {3} newly deployed, {4} assignment change(s), {5} old version(s) removed by the version cleanup, {6} superseded app(s) deleted manually." }
  } else {
    @{ Intro = "Folgende Anwendungen in der Intune Kundenumgebung aktualisiert und bereitgestellt sowie benötigte Zuweisungen und Ablöse von alten Anwendungen vorgenommen:"
       None = "Für diesen Tenant wurde in dieser Sitzung noch nichts erfasst."
       NotSignedIn = "Bitte an einem Tenant anmelden, um dessen Leistungsnachweis zu sehen."
       OrphanHead = "Hinweis: {0} Eintrag/Einträge konnten keinem Tenant zugeordnet werden - sie wurden erfasst, während die Sitzung getrennt war. Bitte prüfen, ob sie zu diesem Kunden gehören:"
       Superseded = " (Vorgänger abgelöst, in Intune behalten)"
       SupersededMany = " ({0} Vorgänger abgelöst, in Intune behalten)"
       Removed = " (Vorgänger gelöscht)"
       RemovedMany = " ({0} Vorgänger gelöscht)"
       SupersededAndRemoved = " ({0} abgelöst und behalten, {1} gelöscht)"
       HeadUpdates = "Aktualisiert:"
       HeadDeployed = "Neu bereitgestellt:"
       HeadVersionRemoved = "Alte Versionen entfernt:"
       HeadSupersededRemoved = "Abgelöste Apps gelöscht:"
       HeadAssignments = "Zuweisungen geändert:"
       Summary = "Zusammenfassung: {0} App(s) aktualisiert, {1} Vorgänger abgelöst und behalten, {2} Vorgänger beim Update gelöscht, {3} neu bereitgestellt, {4} Zuweisungsänderung(en), {5} alte Version(en) durch die Versionsbereinigung entfernt, {6} abgelöste App(s) manuell gelöscht." }
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add($tpl.Intro)
  $lines.Add("")

  # A performance record belongs to the tenant currently shown in the dialog. The timestamp and
  # tenant are displayed in a separate, read-only header and intentionally excluded from this
  # copyable ticket text.
  $tenant = [string]$script:currentUserUpn
  # No tenant = signed out: NEVER fall back to "all tenants". This text is meant to be pasted into a
  # customer ticket, so showing another customer's activity here would leak it. Ask to sign in instead.
  if ([string]::IsNullOrWhiteSpace($tenant)) {
    $lines.Add($tpl.NotSignedIn)
    return ($lines -join "`r`n")
  }
  # The previous session's record is filtered by tenant just like the current one - a record for
  # customer A must never appear while customer B is signed in.
  #
  # Verglichen wird die DOMAENE, nicht die ganze Adresse: beim Dienstleister liegen die Rechte
  # regelmaessig auf einem zweiten Konto desselben Kunden, und wer sich damit anmeldet, sah seinen
  # eigenen Nachweis nicht mehr. Dieselbe Grenze wie bei den Gruppen-Favoriten - der Kunde ist die
  # Domaene, nicht das Konto.
  $tenantDomain = Get-ActivityTenantDomain -Upn $tenant
  $source = if ($script:leistungShowPrevious) { $script:previousSessionActivity } else { $script:sessionActivity }
  $all = if ($source) { @($source) } else { @() }
  $entries = @($all | Where-Object {
    $d = Get-ActivityTenantDomain -Upn ([string]$_.Tenant)
    $d -and $tenantDomain -and [string]::Equals($d, $tenantDomain, [System.StringComparison]::OrdinalIgnoreCase)
  })
  # Eintraege OHNE Tenant konnten nicht zugeordnet werden - so etwas entstand, wenn waehrend eines
  # Laufs getrennt wurde (behoben, aber alte Aufzeichnungen tragen es noch). Sie werden getrennt und
  # ausdruecklich benannt angehaengt, statt sie stillschweigend diesem Kunden zuzuschlagen: sie
  # koennten von einem anderen sein, und dieser Text landet in einem Kundenticket.
  $orphans = @($all | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Tenant) })
  $orphanLines = [System.Collections.Generic.List[string]]::new()
  if ($orphans.Count -gt 0) {
    $orphanLines.Add("")
    $orphanLines.Add($tpl.OrphanHead -f $orphans.Count)
    foreach ($o in $orphans) {
      $from = [string]$o.FromVersion; $to = [string]$o.ToVersion
      $versions = if ($from -and $to) { "$from -> $to" } elseif ($to) { $to } else { $from }
      $stamp = ''
      $ts = $o.Timestamp -as [datetime]
      if ($null -ne $ts) { $stamp = " [{0:dd.MM.yyyy HH:mm}]" -f $ts }
      $orphanLines.Add("- $([string]$o.Name)$(if ($versions) { ": $versions" })$stamp")
    }
    Write-Log ("Performance record: {0} entr(y/ies) without a tenant were listed separately - they were recorded while the session was disconnected." -f $orphans.Count)
  }
  if ($entries.Count -eq 0) {
    $lines.Add($tpl.None)
    foreach ($l in $orphanLines) { $lines.Add($l) }
    return (($lines -join "`r`n").TrimEnd())
  }

  # Entries from older releases carry no Kind - they were always updates.
  function Get-EntryKind { param($Entry)
    $k = [string]$Entry.Kind
    if ([string]::IsNullOrWhiteSpace($k)) { return 'Update' }
    return $k
  }
  $byKind = @{}
  foreach ($item in $entries) {
    $k = Get-EntryKind $item
    if (-not $byKind.ContainsKey($k)) { $byKind[$k] = [System.Collections.Generic.List[object]]::new() }
    $byKind[$k].Add($item)
  }

  $removedCount = 0
  $supersededKeptCount = 0
  $updates = @(if ($byKind.ContainsKey('Update')) { $byKind['Update'] } else { @() })
  $updateGroupCount = 0
  if ($updates.Count -gt 0) {
    $lines.Add($tpl.HeadUpdates)
    # Several old versions of one app routinely land on the SAME new version - that is one update
    # with several predecessors, not several updates. Listed line by line it read as if the app had
    # been updated twice, which is exactly what a customer should not have to decode from a record.
    # Grouped by app + target version, in first-appearance order.
    $groupOrder = [System.Collections.Generic.List[string]]::new()
    $groups = @{}
    foreach ($item in $updates) {
      $key = ("{0}|{1}" -f [string]$item.Name, [string]$item.ToVersion)
      if (-not $groups.ContainsKey($key)) {
        $groups[$key] = [pscustomobject]@{
          Name = [string]$item.Name; ToVersion = [string]$item.ToVersion
          From = [System.Collections.Generic.List[string]]::new()
          SortKeys = [System.Collections.Generic.List[string]]::new(); Removed = 0; Superseded = 0
        }
        [void]$groupOrder.Add($key)
      }
      $from = [string]$item.FromVersion
      if ($from -and -not $groups[$key].From.Contains($from)) {
        [void]$groups[$key].From.Add($from)
        # Sort key computed HERE, not inside the Sort-Object scriptblock below: such a scriptblock
        # runs in its own scope and cannot reliably resolve script functions, so calling the version
        # parser from inside it failed silently and left the predecessors unordered.
        $parts = Get-ComparableVersionParts -Value $from
        $padded = if ($parts) { @($parts.Core) + @(0, 0, 0, 0) } else { @(0, 0, 0, 0) }
        [void]$groups[$key].SortKeys.Add(('{0:D10}.{1:D10}.{2:D10}.{3:D10}' -f
          [uint64]$padded[0], [uint64]$padded[1], [uint64]$padded[2], [uint64]$padded[3]))
      }
      # Deleted and superseded-but-kept are counted apart, so the line can name what really
      # happened to each predecessor instead of calling every outcome "superseded".
      if ($item.OldVersionRemoved) {
        $groups[$key].Removed++; $removedCount++
      } elseif ($item.PSObject.Properties['SupersedenceCreated'] -and $item.SupersedenceCreated) {
        $groups[$key].Superseded++; $supersededKeptCount++
      }
    }
    $updateGroupCount = $groupOrder.Count
    foreach ($key in $groupOrder) {
      $g = $groups[$key]
      # Predecessors oldest first, so the line reads as a range that ends at the new version.
      # Sorted on the pre-computed padded keys - plain string ordering is correct for those.
      $pairs = @()
      for ($i = 0; $i -lt $g.From.Count; $i++) {
        $pairs += [pscustomobject]@{ Version = $g.From[$i]; Key = $g.SortKeys[$i] }
      }
      $ordered = @($pairs | Sort-Object -Property Key | ForEach-Object { $_.Version })
      $suffix = ""
      if ($g.Removed -gt 0 -and $g.Superseded -gt 0) {
        $suffix = $tpl.SupersededAndRemoved -f $g.Superseded, $g.Removed
      } elseif ($g.Removed -gt 0) {
        $suffix = if ($g.Removed -eq 1) { $tpl.Removed } else { $tpl.RemovedMany -f $g.Removed }
      } elseif ($g.Superseded -gt 0) {
        $suffix = if ($g.Superseded -eq 1) { $tpl.Superseded } else { $tpl.SupersededMany -f $g.Superseded }
      }
      $lines.Add("- $($g.Name): $($ordered -join ', ') -> $($g.ToVersion)$suffix")
    }
    $lines.Add("")
  }

  # One rendering per remaining section; only sections that actually happened are printed, so a
  # pure cleanup session produces a record about cleanups instead of "nothing was updated".
  foreach ($section in @(
      @{ Kind = 'Deployed';          Head = $tpl.HeadDeployed },
      @{ Kind = 'VersionRemoved';    Head = $tpl.HeadVersionRemoved },
      @{ Kind = 'SupersededRemoved'; Head = $tpl.HeadSupersededRemoved },
      @{ Kind = 'AssignmentsChanged';Head = $tpl.HeadAssignments })) {
    $items = @(if ($byKind.ContainsKey($section.Kind)) { $byKind[$section.Kind] } else { @() })
    if ($items.Count -eq 0) { continue }
    $lines.Add($section.Head)
    foreach ($item in $items) {
      $version = [string]$item.FromVersion
      if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$item.ToVersion }
      $detail = [string]$item.Detail
      $text = "- $($item.Name)"
      if ($version) { $text += ": $version" }
      if ($detail)  { $text += " ($detail)" }
      $lines.Add($text)
    }
    $lines.Add("")
  }

  # Assignment changes ARE tracked now (deploy, settings change, and the hand-over during an update
  # - including the case where the module had already moved them, which used to go unrecorded), so
  # the summary counts them instead of staying silent about them.
  $countOf = { param($k) @(if ($byKind.ContainsKey($k)) { $byKind[$k] } else { @() }).Count }
  $lines.Add(($tpl.Summary -f $updateGroupCount, $supersededKeptCount, $removedCount,
    (& $countOf 'Deployed'), (& $countOf 'AssignmentsChanged'),
    (& $countOf 'VersionRemoved'), (& $countOf 'SupersededRemoved')))
  foreach ($l in $orphanLines) { $lines.Add($l) }

  return (($lines -join "`r`n").TrimEnd())
}

function Get-SessionLeistungsHeader {
  param([string]$Lang)
  if ([string]::IsNullOrWhiteSpace($Lang)) { $Lang = $script:leistungLang }
  $tenant = [string]$script:currentUserUpn
  if ([string]::IsNullOrWhiteSpace($tenant)) { $tenant = if ($Lang -eq 'en') { '(unknown tenant)' } else { '(unbekannter Tenant)' } }
  if ($Lang -eq 'en') {
    return "App update record - created on $(Get-Date -Format 'dd.MM.yyyy HH:mm')`r`n`r`nCustomer / Tenant: $tenant"
  }
  return "Leistungsnachweis App-Updates - erstellt am $(Get-Date -Format 'dd.MM.yyyy HH:mm')`r`n`r`nKunde / Tenant: $tenant"
}


# --- Performance record across sessions ---
# The record used to live in memory only, so closing the GUI lost it. That is exactly the wrong
# moment: the ticket is usually written after the work, often after the tool was already closed.
# Each entry is therefore appended to disk as it happens - not only at shutdown, which a crash or
# a forced close would skip.
# Held in LocalApplicationData (per-user, not roamed), like the logs: it contains customer data
# (tenant UPNs, app names, versions) and must not follow the user to other machines. The old Roaming
# copy is migrated once on first start. See SECURITY.md for what it holds and how long.
$script:activityHistoryPath = Join-Path (Get-LocalAppDataRoot) 'WinTunerGUI\activity-history.json'
# Zwei Altlasten, in der Reihenfolge ihrer Entstehung: erst lag die Datei im Roaming-Profil,
# dann unter dem alten Anwendungsnamen. Beide werden beim ersten Start berücksichtigt, damit
# ein Nachweis aus einer der beiden Epochen nicht verschwindet - er ist nicht rekonstruierbar.
$script:activityHistoryLegacyPaths = @(
  (Join-Path (Get-AppDataRoot) 'WinTunerGUI\activity-history.json'),
  (Join-Path (Get-LocalAppDataRoot) 'WinTunerGUI\activity-history.json'),
  (Join-Path (Get-AppDataRoot) 'WinTunerGUI\activity-history.json')
)
$script:previousSessionActivity = @()

# Drops entries older than the retention window (same window as the logs). The record only ever needs
# the last and the previous session, not months of customer history sitting on disk.
function Select-RecentActivity {
  param([object[]]$Entries, [int]$RetentionWeeks = $script:logRetentionWeeks, [datetime]$Now = (Get-Date))
  $cutoff = $Now.AddDays(-7 * $RetentionWeeks)
  return @($Entries | Where-Object {
    # After JSON load Timestamp is already a DateTime; -as handles that and a parseable string, and
    # yields $null for anything unreadable - which we keep rather than silently lose data.
    $ts = $_.Timestamp -as [datetime]
    if ($null -ne $ts) { $ts -ge $cutoff } else { $true }
  })
}

function Import-PreviousSessionActivity {
  try {
    # Einmal-Übernahme aus den alten Ablageorten. KOPIERT statt verschoben: wer auf eine Fassung
    # vor der Umbenennung zurückrollt, muss seinen Nachweis dort noch vorfinden.
    if (-not (Test-Path -LiteralPath $script:activityHistoryPath)) {
      foreach ($legacy in @($script:activityHistoryLegacyPaths)) {
        if (-not (Test-Path -LiteralPath $legacy)) { continue }
        try {
          $dir = Split-Path $script:activityHistoryPath -Parent
          if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
          Copy-Item -LiteralPath $legacy -Destination $script:activityHistoryPath -Force -ErrorAction Stop
          Write-Log ("Performance record taken over from its previous location: {0}" -f $legacy)
        } catch {
          Write-Log ("Performance record could not be taken over from {0}: {1}" -f $legacy, $_.Exception.Message)
        }
        break   # der erste vorhandene Ort gewinnt, in der Reihenfolge der Liste
      }
    }
    if (-not (Test-Path -LiteralPath $script:activityHistoryPath)) { return }
    $raw = Get-Content -LiteralPath $script:activityHistoryPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $loaded = @($raw | ConvertFrom-Json)
    $script:previousSessionActivity = Select-RecentActivity -Entries $loaded
    if ($script:previousSessionActivity.Count -lt $loaded.Count) {
      # Rewrite the file trimmed so the stale entries do not linger even if this session records nothing.
      try {
        $json = @($script:previousSessionActivity) | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($script:activityHistoryPath, $json, [Text.UTF8Encoding]::new($false))
      } catch { Write-Log ("Trimmed performance record could not be rewritten: {0}" -f $_.Exception.Message) }
      Write-Log ("Performance record: dropped {0} entr(y/ies) older than {1} week(s)." -f ($loaded.Count - $script:previousSessionActivity.Count), $script:logRetentionWeeks)
    }
    Write-Log ("Performance record of the previous session loaded: {0} entr(y/ies)." -f $script:previousSessionActivity.Count)
  } catch {
    $script:previousSessionActivity = @()
    Write-Log ("Previous performance record could not be read: {0}" -f $_.Exception.Message)
  }
}

# Records one thing worth putting in a ticket. Kind decides which section of the record it lands in.
#
# Entries written by older versions have no Kind; the renderer treats those as 'Update', so a
# history file from a previous release still reads correctly.
function Add-SessionActivity {
  param(
    [Parameter(Mandatory)][ValidateSet('Update','VersionRemoved','SupersededRemoved','Deployed','AssignmentsChanged')][string]$Kind,
    [Parameter(Mandatory)][string]$Name,
    [string]$FromVersion = '',
    [string]$ToVersion = '',
    [bool]$OldVersionRemoved = $false,
    # "The predecessor was superseded and kept" is a different outcome from "the predecessor was
    # deleted". Both used to collapse into OldVersionRemoved, which the record then printed with the
    # word for the first while counting it as neither.
    [bool]$SupersedenceCreated = $false,
    [string]$Detail = ''
  )
  try {
    # Explicit null check: an EMPTY List is falsy in PowerShell, so "-not $list" is true for every
    # fresh session - which would have silently dropped every entry until the list was non-empty,
    # i.e. always.
    if ($null -eq $script:sessionActivity) { return }
    # NICHT $script:currentUserUpn allein: das Feld wird beim Trennen geleert. Wurde waehrend eines
    # Laufs getrennt, landeten alle danach erfassten Updates mit LEEREM Tenant im Nachweis - und
    # waren beim naechsten Start unter "Letzte Sitzung" nicht mehr auffindbar, weil der Nachweis
    # nach Tenant filtert. Genau so sind drei Updates aus einem echten Lauf verloren gegangen.
    # $script:activityTenantUpn haelt die zuletzt angemeldete Adresse und ueberlebt das Trennen.
    $tenantForEntry = [string]$script:currentUserUpn
    if ([string]::IsNullOrWhiteSpace($tenantForEntry)) { $tenantForEntry = [string]$script:activityTenantUpn }
    $script:sessionActivity.Add([pscustomobject]@{
      Kind              = $Kind
      Tenant            = $tenantForEntry
      Name              = $Name
      FromVersion       = $FromVersion
      ToVersion         = $ToVersion
      OldVersionRemoved = $OldVersionRemoved
      SupersedenceCreated = $SupersedenceCreated
      Detail            = $Detail
      Timestamp         = Get-Date
    })
    # Saved immediately, like the update entries: the ticket is usually written after the tool has
    # been closed, and a crash must not take the record with it.
    Save-SessionActivity
    # Jeder erfasste Eingriff aendert die Kachelzahlen des Dashboards. Der Merker sitzt HIER, weil
    # das die eine Stelle ist, die jeder schreibende Weg durchlaeuft - Update-Lauf, Bereitstellung,
    # Versionsbereinigung, Loeschen einer abgeloesten App, Zuweisungsaenderung. Sonst haette jeder
    # dieser Wege daran denken muessen, und einer haette es vergessen.
    $script:dashboardStale = $true
  } catch {
    Write-Log ("Performance record entry could not be added ({0} / {1}): {2}" -f $Kind, $Name, $_.Exception.Message)
  }
}

# Writes the CURRENT session. Called after every recorded update, so the file always reflects what
# has actually been done.
function Save-SessionActivity {
  try {
    $dir = Split-Path $script:activityHistoryPath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $json = @($script:sessionActivity) | ConvertTo-Json -Depth 6
    # Written through a temp file: a half-written record would be unreadable next time.
    $tmp = $script:activityHistoryPath + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $script:activityHistoryPath -Force -ErrorAction Stop
  } catch {
    Write-Log ("Performance record could not be saved: {0}" -f $_.Exception.Message)
  }
}

# Removes the performance record for good: both in-memory records (current AND the previous session,
# which is otherwise re-offered as "last session") and the on-disk file. Without deleting the file
# the customer data returned on the next start, so "cannot be undone" was not true.
function Clear-SessionActivityRecord {
  if ($null -ne $script:sessionActivity) { $script:sessionActivity.Clear() }
  $script:previousSessionActivity = @()
  try {
    if (Test-Path -LiteralPath $script:activityHistoryPath) {
      Remove-Item -LiteralPath $script:activityHistoryPath -Force -ErrorAction Stop
    }
    Write-Log "Performance record cleared: in-memory records emptied and activity-history.json deleted."
  } catch {
    Write-Log ("Performance record file could not be deleted: {0}" -f $_.Exception.Message)
  }
}

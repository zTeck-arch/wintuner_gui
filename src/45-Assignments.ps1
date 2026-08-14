# Moves the group assignments from the OLD (now superseded) app to the NEW one, so only the newest
# version stays in scope. Without this both versions remain assigned and someone has to unassign the
# predecessor by hand in the portal.
#
# Order matters: the new app is assigned FIRST and only when that succeeded is the old one cleared.
# If the second step fails the worst case is the state we already had (both assigned) – never a gap
# where nothing is assigned.
#
# Uses raw Graph with WinTuner's own token for the same reason as Remove-SupersededByUnlinking:
# Invoke-MgGraphRequest needs its own Connect-MgGraph session, Get-WtToken does not.
# NOTE: this REMOVES assignments in Intune – validate on a test app first.
function Move-AppAssignments {
  param([Parameter(Mandatory)][string]$OldAppId, [Parameter(Mandatory)][string]$NewAppId, [string]$AppName = '')
  $guid = '^[0-9a-fA-F-]{36}$'
  if ($OldAppId -notmatch $guid -or $NewAppId -notmatch $guid) { Write-Log "Assignments: invalid app id(s), aborting."; return $false }
  if ($OldAppId -eq $NewAppId) { Write-Log "Assignments: old and new app are identical, nothing to move."; return $false }

  $token = $null
  try { $token = Get-WtToken -ErrorAction Stop } catch { Write-Log "Assignments: could not obtain WinTuner token: $($_.Exception.Message)"; return $false }
  if ([string]::IsNullOrWhiteSpace($token)) { Write-Log "Assignments: empty token, aborting."; return $false }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  $base = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps"

  try {
    $oldAssignments = @(Get-GraphCollectionItems -Uri "$base/$OldAppId/assignments" -Headers $headers)
    if ($oldAssignments.Count -eq 0) {
      Write-Log ("Assignments: old app {0} has none - nothing to move." -f $OldAppId)
      return $true
    }
    if (@($oldAssignments | Where-Object { $_.source -and [string]$_.source -ne 'direct' }).Count -gt 0) {
      Write-Log ("Assignments: {0} contains policy-set/inherited assignments; automatic hand-over is blocked because those assignments must be changed at their source." -f $AppName)
      return $false
    }

    # Rebuild each assignment WITHOUT its id (Intune assigns new ids) but with target, intent and
    # settings preserved, so a "Required for group X" stays exactly that on the new version.
    $payload = @()
    foreach ($a in $oldAssignments) {
      $target = $a.target
      if (-not $target) { Write-Log "Assignments: an assignment has no target - aborting to avoid guessing."; return $false }
      $entry = @{ '@odata.type' = '#microsoft.graph.mobileAppAssignment'; intent = [string]$a.intent; target = $target }
      if ($a.settings) { $entry.settings = $a.settings }
      $payload += $entry
    }
    $desc = ($oldAssignments | ForEach-Object {
      "{0}->{1}" -f $_.intent, ($(if ($_.target.groupId) { $_.target.groupId } else { [string]$_.target.'@odata.type' }))
    }) -join ', '

    # 1) put them on the new app (merged with whatever it already has, so nothing is lost)
    $existingNew = @(Get-GraphCollectionItems -Uri "$base/$NewAppId/assignments" -Headers $headers)
    $merged = @($payload)
    foreach ($n in $existingNew) {
      $dupe = $false
      foreach ($p in $payload) {
        $sameIdentity = (
          [string]$n.intent -eq [string]$p.intent -and
          [string]$n.target.groupId -eq [string]$p.target.groupId -and
          [string]$n.target.'@odata.type' -eq [string]$p.target.'@odata.type' -and
          [string]$n.target.deviceAndAppManagementAssignmentFilterType -eq [string]$p.target.deviceAndAppManagementAssignmentFilterType -and
          [string]$n.target.deviceAndAppManagementAssignmentFilterId -eq [string]$p.target.deviceAndAppManagementAssignmentFilterId)
        if ($sameIdentity) {
          $newSettings = if ($n.settings) { $n.settings | ConvertTo-Json -Compress -Depth 12 } else { '' }
          $oldSettings = if ($p.settings) { $p.settings | ConvertTo-Json -Compress -Depth 12 } else { '' }
          if ($newSettings -ne $oldSettings) {
            Write-Log ("Assignments: conflicting settings for the same intent/target/filter while consolidating {0}; kept both source apps and aborted instead of discarding a policy." -f $AppName)
            return $false
          }
          $dupe = $true
          break
        }
      }
      if (-not $dupe) {
        $e = @{ '@odata.type' = '#microsoft.graph.mobileAppAssignment'; intent = [string]$n.intent; target = $n.target }
        if ($n.settings) { $e.settings = $n.settings }
        $merged += $e
      }
    }
    $bodyNew = @{ mobileAppAssignments = @($merged) } | ConvertTo-Json -Depth 12
    Invoke-RestMethod -Method POST -Uri "$base/$NewAppId/assign" -Headers $headers -Body $bodyNew -ErrorAction Stop | Out-Null
    Write-Log ("Assignments: new app {0} now has {1} assignment(s) [{2}]" -f $NewAppId, $merged.Count, $desc)

    # 2) only now clear the old app
    $bodyOld = @{ mobileAppAssignments = @() } | ConvertTo-Json -Depth 4
    Invoke-RestMethod -Method POST -Uri "$base/$OldAppId/assign" -Headers $headers -Body $bodyOld -ErrorAction Stop | Out-Null
    Write-Log ("Assignments: removed {0} assignment(s) from superseded app {1} ({2}) [{3}]" -f $oldAssignments.Count, $OldAppId, $AppName, $desc)
    return $true
  } catch {
    Write-Log ("Assignments: move failed for {0} (old {1} -> new {2}): {3}" -f $AppName, $OldAppId, $NewAppId, $_.Exception.Message)
    return $false
  }
}

# Confirms that the SUCCESSOR really carries assignments before its predecessor may be deleted.
#
# Move-AppAssignments returning $true is not sufficient evidence: it reports success for "the old
# app has nothing left to move", which is also the normal state after WinTuner itself handed the
# assignments over during a supersedence deploy - and it looks exactly the same when that hand-over
# silently dropped them, or when someone unassigned the old app in the portal meanwhile. Deleting on
# that flag alone can therefore remove the last object anybody was scoped to.
#
# A negative answer is retried: Intune is eventually consistent right after an assign, and a "not
# yet visible" must not be mistaken for "never arrived". DoEvents keeps the window responsive during
# the wait, like the other post-deploy resolution loops. Unknown (probe failed) counts as NOT
# confirmed - the predecessor then stays, which is the recoverable outcome.
function Test-SuccessorAssignmentsConfirmed {
  param(
    [Parameter(Mandatory)][string]$NewAppId,
    [string]$AppName = '',
    [int]$Attempts = 3
  )
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $probe = Get-AppAssignmentProbe -AppId $NewAppId -AppName $AppName
    if ($probe.Succeeded -and $probe.HasAssignments) {
      Write-Log ("Assignment hand-over verified: successor {0} ({1}) carries {2} assignment(s)." -f $NewAppId, $AppName, $probe.Count)
      return $true
    }
    if ($attempt -lt $Attempts) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Seconds 2
    }
  }
  Write-Log ("Assignment hand-over NOT verified for successor {0} ({1}) after {2} attempt(s); the predecessor is kept so the app cannot end up assigned to nobody." -f $NewAppId, $AppName, $Attempts)
  return $false
}

# ---------------------------------------------------------------------------------------------
# App assignment settings (end-user notifications, availability, deadline, auto-update)
#
# These live on the ASSIGNMENT, not on the app: Intune stores them per assignment as
# win32LobAppAssignmentSettings. That is why they can only be set once an app HAS an assignment,
# and why applying them means rewriting the app's assignment list with the settings attached.
#
# Deploy-WtWin32App does not expose them, so this goes through Graph with WinTuner's own token -
# the same approach (and the same reason) as Move-AppAssignments.
# ---------------------------------------------------------------------------------------------

# Builds the settings object Intune expects. Every part is optional: what is not set stays
# 'notConfigured' / absent, so the tenant default keeps applying instead of being overwritten.
function New-AssignmentSettingsObject {
  param(
    [ValidateSet('showAll','showReboot','hideAll','')][string]$Notifications = '',
    [datetime]$AvailableFrom,
    [datetime]$Deadline,
    [switch]$ClearAvailableFrom,
    [switch]$ClearDeadline,
    [bool]$UseLocalTime = $true,
    [int]$RestartGraceMinutes = 0,
    [int]$RestartCountdownMinutes = 0,
    [int]$RestartSnoozeMinutes = 0,
    [switch]$DisableRestartGrace,
    [ValidateSet('notConfigured','foreground','')][string]$DeliveryOptimizationPriority = '',
    [ValidateSet('enabled','notConfigured','')][string]$AutoUpdateSuperseded = ''
  )
  $s = @{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings' }
  if ($Notifications) { $s.notifications = $Notifications }

  # Absence of restartSettings means "disabled/unchanged". When enabled, Intune accepts a
  # maximum grace period of 14 days; countdown and snooze must fit inside that window. A snooze
  # value of 0 represents "do not allow snoozing" while keeping the grace period itself enabled.
  if ($RestartGraceMinutes -gt 0) {
    if ($RestartGraceMinutes -gt 20160) { throw 'Restart grace period cannot exceed 20160 minutes (14 days).' }
    if ($RestartCountdownMinutes -lt 1 -or $RestartCountdownMinutes -gt $RestartGraceMinutes) {
      throw 'Restart countdown must be between 1 minute and the configured grace period.'
    }
    if ($RestartSnoozeMinutes -lt 0 -or $RestartSnoozeMinutes -gt $RestartGraceMinutes) {
      throw 'Restart snooze duration cannot exceed the configured grace period.'
    }
    $s.restartSettings = @{
      '@odata.type' = '#microsoft.graph.win32LobAppRestartSettings'
      gracePeriodInMinutes = $RestartGraceMinutes
      countdownDisplayBeforeRestartInMinutes = $RestartCountdownMinutes
      restartNotificationSnoozeDurationInMinutes = $RestartSnoozeMinutes
    }
  }
  if ($DisableRestartGrace) { $s['__removeRestartSettings'] = $true }

  # Time handling – this is easy to get wrong and shifts every deadline by the UTC offset:
  #   useLocalTime = TRUE  -> Intune reads the time as DEVICE LOCAL wall-clock time. The picked
  #                           time must therefore be sent AS TYPED (only tagged with Z), exactly
  #                           like the Intune portal does. Converting to UTC here would move an
  #                           08:00 deadline to 06:00 on every device in CEST.
  #   useLocalTime = FALSE -> the instant is absolute, so the local time IS converted to UTC.
  $fmt = 'yyyy-MM-ddTHH:mm:ss.fffffffZ'
  $conv = { param($dt) if ($UseLocalTime) { $dt.ToString($fmt) } else { $dt.ToUniversalTime().ToString($fmt) } }
  $its = @{}
  if ($PSBoundParameters.ContainsKey('AvailableFrom')) { $its.startDateTime    = & $conv $AvailableFrom }
  if ($PSBoundParameters.ContainsKey('Deadline'))      { $its.deadlineDateTime = & $conv $Deadline }
  if ($its.Count -gt 0) {
    $its.useLocalTime = $UseLocalTime
    $s.installTimeSettings = $its
  }
  if ($ClearAvailableFrom) { $s['__removeAvailableFrom'] = $true }
  if ($ClearDeadline) { $s['__removeDeadline'] = $true }

  if ($DeliveryOptimizationPriority) { $s.deliveryOptimizationPriority = $DeliveryOptimizationPriority }
  if ($AutoUpdateSuperseded) { $s.autoUpdateSettings = @{ autoUpdateSupersededApps = $AutoUpdateSuperseded } }
  return $s
}

# Applies only the fields selected in the dialog to an assignment's current settings. Replacing
# the whole settings object would silently erase unrelated values such as restart grace periods,
# delivery optimization priority or an existing deadline whenever the user changed just one field.
function Merge-AppAssignmentSettings {
  param([object]$Existing, [Parameter(Mandatory)][hashtable]$Changes)
  $merged = @{}
  if ($Existing) {
    try { $merged = ($Existing | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable) } catch {
      Write-Log ("Could not clone existing assignment settings; aborting safe merge: {0}" -f $_.Exception.Message)
      throw
    }
  }
  if (-not $merged.ContainsKey('@odata.type')) { $merged['@odata.type'] = '#microsoft.graph.win32LobAppAssignmentSettings' }

  if ($Changes.ContainsKey('notifications')) { $merged.notifications = $Changes.notifications }
  if ($Changes.ContainsKey('installTimeSettings')) {
    $install = if ($merged.ContainsKey('installTimeSettings') -and $merged.installTimeSettings) {
      [hashtable]$merged.installTimeSettings
    } else { @{} }
    foreach ($key in $Changes.installTimeSettings.Keys) { $install[$key] = $Changes.installTimeSettings[$key] }
    $merged.installTimeSettings = $install
  }
  if ($Changes.ContainsKey('__removeAvailableFrom') -or $Changes.ContainsKey('__removeDeadline')) {
    if ($merged.ContainsKey('installTimeSettings') -and $merged.installTimeSettings) {
      $install = [hashtable]$merged.installTimeSettings
      if ($Changes.ContainsKey('__removeAvailableFrom')) { [void]$install.Remove('startDateTime') }
      if ($Changes.ContainsKey('__removeDeadline')) { [void]$install.Remove('deadlineDateTime') }
      if (-not $install.ContainsKey('startDateTime') -and -not $install.ContainsKey('deadlineDateTime')) {
        [void]$merged.Remove('installTimeSettings')
      } else { $merged.installTimeSettings = $install }
    }
  }
  if ($Changes.ContainsKey('restartSettings')) {
    $restart = if ($merged.ContainsKey('restartSettings') -and $merged.restartSettings) {
      [hashtable]$merged.restartSettings
    } else { @{} }
    foreach ($key in $Changes.restartSettings.Keys) { $restart[$key] = $Changes.restartSettings[$key] }
    $merged.restartSettings = $restart
  }
  if ($Changes.ContainsKey('__removeRestartSettings')) { [void]$merged.Remove('restartSettings') }
  if ($Changes.ContainsKey('deliveryOptimizationPriority')) {
    $merged.deliveryOptimizationPriority = $Changes.deliveryOptimizationPriority
  }
  if ($Changes.ContainsKey('autoUpdateSettings')) {
    $auto = if ($merged.ContainsKey('autoUpdateSettings') -and $merged.autoUpdateSettings) {
      [hashtable]$merged.autoUpdateSettings
    } else { @{} }
    foreach ($key in $Changes.autoUpdateSettings.Keys) { $auto[$key] = $Changes.autoUpdateSettings[$key] }
    $merged.autoUpdateSettings = $auto
  }
  return $merged
}

# Human-readable one-liner for the log/status, so a bulk run is auditable afterwards.
function Get-AssignmentSettingsSummary {
  param([hashtable]$Settings)
  $parts = @()
  if ($Settings.notifications) { $parts += "notifications=$($Settings.notifications)" }
  if ($Settings.installTimeSettings) {
    if ($Settings.installTimeSettings.startDateTime)    { $parts += "availableFrom=$($Settings.installTimeSettings.startDateTime)" }
    if ($Settings.installTimeSettings.deadlineDateTime) { $parts += "deadline=$($Settings.installTimeSettings.deadlineDateTime)" }
    $parts += "useLocalTime=$($Settings.installTimeSettings.useLocalTime)"
  }
  if ($Settings.ContainsKey('__removeAvailableFrom')) { $parts += 'availability=as soon as possible' }
  if ($Settings.ContainsKey('__removeDeadline')) { $parts += 'deadline=as soon as possible' }
  if ($Settings.restartSettings) {
    $parts += "restartGrace=$($Settings.restartSettings.gracePeriodInMinutes)m"
    $parts += "restartCountdown=$($Settings.restartSettings.countdownDisplayBeforeRestartInMinutes)m"
    $parts += "restartSnooze=$($Settings.restartSettings.restartNotificationSnoozeDurationInMinutes)m"
  }
  if ($Settings.ContainsKey('__removeRestartSettings')) { $parts += 'restartGrace=disabled' }
  if ($Settings.deliveryOptimizationPriority) { $parts += "deliveryPriority=$($Settings.deliveryOptimizationPriority)" }
  if ($Settings.autoUpdateSettings) { $parts += "autoUpdateSuperseded=$($Settings.autoUpdateSettings.autoUpdateSupersededApps)" }
  if ($parts.Count -eq 0) { return '(nothing to change)' }
  return ($parts -join ', ')
}

# Applies $Settings to EVERY assignment of one app. Intent and target stay untouched, and the
# selected fields are merged into the existing settings so unrelated assignment options survive.
# Returns @{ Changed; Skipped; ErrorMessage }.
function Set-AppAssignmentSettings {
  param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][hashtable]$Settings,
    [hashtable]$TargetChanges = @{},
    [string]$AppName = ''
  )
  $out = @{ Changed = 0; Skipped = $false; ErrorMessage = $null }
  if (-not (Test-GuidString $AppId)) { $out.ErrorMessage = 'invalid app id'; return $out }

  $token = $null
  try { $token = Get-WtToken -ErrorAction Stop } catch { $out.ErrorMessage = "no token: $($_.Exception.Message)"; return $out }
  if ([string]::IsNullOrWhiteSpace($token)) { $out.ErrorMessage = 'empty token'; return $out }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  $base = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps"

  try {
    $existing = @(Get-GraphCollectionItems -Uri "$base/$AppId/assignments" -Headers $headers)
    if ($existing.Count -eq 0) {
      # Nothing to attach the settings to - assignment settings only exist ON an assignment.
      $out.Skipped = $true
      Write-Log ("Assignment settings: '{0}' has no assignment - skipped (assign the app first)." -f $AppName)
      return $out
    }
    if (@($existing | Where-Object { $_.source -and [string]$_.source -ne 'direct' }).Count -gt 0) {
      $out.ErrorMessage = 'policy-set/inherited assignments cannot be rewritten directly'
      Write-Log ("Assignment settings: '{0}' contains policy-set/inherited assignments; skipped to preserve their source policy." -f $AppName)
      return $out
    }
    if ($TargetChanges.ContainsKey('AssignmentMode') -and [string]$TargetChanges.AssignmentMode -eq 'exclude' -and
        $TargetChanges.ContainsKey('FilterType') -and [string]$TargetChanges.FilterType -ne 'none') {
      $out.ErrorMessage = 'excluded group mode cannot be combined with an assignment filter'
      return $out
    }
    $payload = @()
    $convertedExclusion = $false
    foreach ($a in $existing) {
      if (-not $a.target) { $out.ErrorMessage = 'an assignment has no target'; return $out }
      $mergedSettings = Merge-AppAssignmentSettings -Existing $a.settings -Changes $Settings
      try { $mergedTarget = ($a.target | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable) } catch {
        $out.ErrorMessage = "could not clone assignment target: $($_.Exception.Message)"; return $out
      }
      if ($TargetChanges.ContainsKey('AssignmentMode')) {
        $mode = [string]$TargetChanges.AssignmentMode
        if ($mode -eq 'exclude') {
          # Retain All Users/All Devices include rows as the base scope and convert only concrete
          # group targets. A standalone exclusion would otherwise target nobody.
          if ($mergedTarget.groupId) {
            $mergedTarget['@odata.type'] = '#microsoft.graph.exclusionGroupAssignmentTarget'
            $convertedExclusion = $true
          }
        } elseif ($mode -eq 'include' -and [string]$mergedTarget['@odata.type'] -match 'exclusionGroupAssignmentTarget') {
          $mergedTarget['@odata.type'] = '#microsoft.graph.groupAssignmentTarget'
        }
      }
      if ($TargetChanges.ContainsKey('FilterType')) {
        $filterType = [string]$TargetChanges.FilterType
        $mergedTarget.deviceAndAppManagementAssignmentFilterType = $filterType
        if ($filterType -eq 'none') {
          [void]$mergedTarget.Remove('deviceAndAppManagementAssignmentFilterId')
        } else {
          $filterId = [string]$TargetChanges.FilterId
          if (-not (Test-GuidString $filterId)) { $out.ErrorMessage = 'invalid assignment filter id'; return $out }
          $mergedTarget.deviceAndAppManagementAssignmentFilterId = $filterId
        }
      }
      $payload += @{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent        = [string]$a.intent
        target        = $mergedTarget
        settings      = $mergedSettings
      }
    }
    # Runs once the whole payload exists: an exclusion on its own excludes from nothing, so Intune
    # needs a matching include for the same intent. Without it an "exclude" assignment is silently
    # meaningless.
    if ($TargetChanges.ContainsKey('AssignmentMode') -and [string]$TargetChanges.AssignmentMode -eq 'exclude') {
      if (-not $convertedExclusion) { $out.ErrorMessage = 'excluded mode requires at least one custom group assignment'; return $out }
      foreach ($exclusion in @($payload | Where-Object { [string]$_.target.'@odata.type' -match 'exclusionGroupAssignmentTarget' })) {
        $sameIntentIncludes = @($payload | Where-Object {
          [string]$_.intent -eq [string]$exclusion.intent -and [string]$_.target.'@odata.type' -notmatch 'exclusionGroupAssignmentTarget'
        })
        if ($sameIntentIncludes.Count -eq 0) {
          $payload += @{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent = [string]$exclusion.intent
            target = @{
              '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget'
              deviceAndAppManagementAssignmentFilterType = 'none'
            }
            settings = $exclusion.settings
          }
        }
      }
    }

    $body = @{ mobileAppAssignments = @($payload) } | ConvertTo-Json -Depth 12
    Invoke-RestMethod -Method POST -Uri "$base/$AppId/assign" -Headers $headers -Body $body -ErrorAction Stop | Out-Null
    $out.Changed = $payload.Count
    Write-Log ("Assignment settings applied to '{0}' ({1} assignment(s)): {2}" -f $AppName, $payload.Count, (Get-AssignmentSettingsSummary $Settings))
    return $out
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Assignment settings FAILED for '{0}': {1}" -f $AppName, $out.ErrorMessage)
    return $out
  }
}

# WinGet Store apps use a narrower settings resource than Win32 LOB apps. Convert explicitly so
# Win32-only fields (availability start, delivery optimization and auto-update) never leak into a
# Store assignment payload.
function Convert-ToWinGetAssignmentSettings {
  param([Parameter(Mandatory)][hashtable]$Changes)
  $settings = @{ '@odata.type' = '#microsoft.graph.winGetAppAssignmentSettings' }
  if ($Changes.ContainsKey('notifications')) { $settings.notifications = $Changes.notifications }
  if ($Changes.ContainsKey('restartSettings') -and $Changes.restartSettings) {
    $settings.restartSettings = @{
      '@odata.type' = '#microsoft.graph.winGetAppRestartSettings'
      gracePeriodInMinutes = [int]$Changes.restartSettings.gracePeriodInMinutes
      countdownDisplayBeforeRestartInMinutes = [int]$Changes.restartSettings.countdownDisplayBeforeRestartInMinutes
      restartNotificationSnoozeDurationInMinutes = [int]$Changes.restartSettings.restartNotificationSnoozeDurationInMinutes
    }
  }
  if ($Changes.ContainsKey('installTimeSettings') -and $Changes.installTimeSettings.deadlineDateTime) {
    $settings.installTimeSettings = @{
      '@odata.type' = '#microsoft.graph.winGetAppInstallTimeSettings'
      useLocalTime = [bool]$Changes.installTimeSettings.useLocalTime
      deadlineDateTime = [string]$Changes.installTimeSettings.deadlineDateTime
    }
  }
  return $settings
}

# Creates the first direct assignment for a newly uploaded app in one Graph operation. The app is
# uploaded unassigned first, so no temporary scope exists. Exclusion mode means "all licensed
# users except this Entra group" and therefore creates both the required include and exclude rows.
function New-AppAssignmentConfiguration {
  param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$TargetValue,
    [ValidateSet('available','required','uninstall')][string]$Intent = 'available',
    [ValidateSet('include','exclude')][string]$AssignmentMode = 'include',
    [ValidateSet('AllUsers','AllDevices')][string]$ExcludeBaseTarget = 'AllUsers',
    [ValidateSet('none','include','exclude')][string]$FilterType = 'none',
    [string]$FilterId,
    [Parameter(Mandatory)][hashtable]$Settings,
    [ValidateSet('win32','winget')][string]$AppKind = 'win32',
    [string]$AppName = ''
  )
  $out = @{ Changed = 0; Skipped = $false; ErrorMessage = $null }
  if (-not (Test-GuidString $AppId)) { $out.ErrorMessage = 'invalid app id'; return $out }
  if ($FilterType -ne 'none' -and -not (Test-GuidString $FilterId)) { $out.ErrorMessage = 'invalid assignment filter id'; return $out }
  if ($AssignmentMode -eq 'exclude' -and $FilterType -ne 'none') {
    $out.ErrorMessage = 'assignment filters cannot be combined with the implicit All Users + excluded group mode'
    return $out
  }

  $target = switch ($TargetValue) {
    'AllUsers' {
      if ($AssignmentMode -eq 'exclude') { $out.ErrorMessage = 'all users cannot be an exclusion target'; return $out }
      @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' }
    }
    'AllDevices' {
      if ($AssignmentMode -eq 'exclude') { $out.ErrorMessage = 'all devices cannot be an exclusion target'; return $out }
      @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' }
    }
    default {
      if (-not (Test-GuidString $TargetValue)) { $out.ErrorMessage = 'invalid group id'; return $out }
      if ($AssignmentMode -eq 'exclude') {
        @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = $TargetValue }
      } else {
        @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $TargetValue }
      }
    }
  }
  if ($out.ErrorMessage) { return $out }
  $target.deviceAndAppManagementAssignmentFilterType = $FilterType
  if ($FilterType -ne 'none') { $target.deviceAndAppManagementAssignmentFilterId = $FilterId }

  try {
    $token = Get-WtToken -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $safeSettings = if ($AppKind -eq 'winget') {
      Convert-ToWinGetAssignmentSettings -Changes $Settings
    } else {
      # Normalize through the same merge routine used by the bulk editor. Besides giving every
      # Win32 assignment the correct @odata.type, this removes internal clear markers.
      Merge-AppAssignmentSettings -Existing $null -Changes $Settings
    }
    $assignment = @{
      '@odata.type' = '#microsoft.graph.mobileAppAssignment'
      intent = $Intent
      target = $target
      settings = $safeSettings
    }
    $assignments = @($assignment)
    if ($AssignmentMode -eq 'exclude') {
      # A standalone exclusion assignment targets nobody. Pair it with the include baseline in the
      # same atomic assign request; the selected custom group remains the exclusion target.
      $includeType = if ($ExcludeBaseTarget -eq 'AllDevices') {
        '#microsoft.graph.allDevicesAssignmentTarget'
      } else {
        '#microsoft.graph.allLicensedUsersAssignmentTarget'
      }
      $includeTarget = @{
        '@odata.type' = $includeType
        deviceAndAppManagementAssignmentFilterType = 'none'
      }
      $assignments = @(
        @{
          '@odata.type' = '#microsoft.graph.mobileAppAssignment'
          intent = $Intent
          target = $includeTarget
          settings = $safeSettings
        },
        $assignment
      )
    }
    $body = @{ mobileAppAssignments = @($assignments) } | ConvertTo-Json -Depth 14
    Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assign" -Headers $headers -Body $body -ErrorAction Stop | Out-Null
    $out.Changed = $assignments.Count
    Write-Log ("Created {0} assignment(s) for '{1}' ({2}): intent={3}, mode={4}, target={5}, exclusionBase={6}, filter={7}, kind={8}, {9}" -f $assignments.Count, $AppName, $AppId, $Intent, $AssignmentMode, $TargetValue, $ExcludeBaseTarget, $FilterType, $AppKind, (Get-AssignmentSettingsSummary $Settings))
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Creating assignment FAILED for '{0}' ({1}): {2}" -f $AppName, $AppId, $out.ErrorMessage)
  }
  return $out
}

# Deletes an app, transparently handling Intune's "still the supersedence parent" refusal by
# unlinking first. Returns $true when the app is gone. Shared by every cleanup path.
#
# Every successful deletion is recorded for the performance record here, in the one place all three
# cleanup paths go through - version trimming, the bulk superseded cleanup and the single delete.
# Recording it at each call site instead would have meant three chances to forget one, which is how
# a session that deleted eight app versions could still report "no apps updated".
function Remove-AppWithUnlinkFallback {
  param(
    [Parameter(Mandatory)][string]$GraphId,
    [string]$AppName = '',
    [string]$Version = '',
    [ValidateSet('VersionRemoved','SupersededRemoved')][string]$RecordAs = 'VersionRemoved'
  )
  try {
    Invoke-WtRemoveWin32App -AppId $GraphId
    Add-SessionActivity -Kind $RecordAs -Name $AppName -FromVersion $Version
    return $true
  } catch {
    $m = $_.Exception.Message
    # Already gone counts as success - but nothing was deleted here, so nothing is recorded.
    if (Test-IsNotFoundError -ErrorRecord $_ -Context $AppName) { return $true }
    if ($m -match 'parent of another app' -or $m -match 'Cannot delete this app') {
      $newId = Get-SupersedingAppIdFromError $m
      if ($newId -and (Remove-SupersededByUnlinking -OldAppId $GraphId -NewAppId $newId)) {
        Add-SessionActivity -Kind $RecordAs -Name $AppName -FromVersion $Version
        return $true
      }
    }
    Write-Log ("Version cleanup: could not remove {0} ({1}): {2}" -f $AppName, $GraphId, $m)
    return $false
  }
}


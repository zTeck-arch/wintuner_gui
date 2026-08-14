# Reads only enough assignment data to answer whether an app is in scope. Every Intune assignment
# counts here, including groups, All Users, All Devices and filtered assignments. A failed probe is
# NEVER interpreted as "unassigned" because that could otherwise delete an app which is in use.
function Get-GraphCollectionItems {
  param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][hashtable]$Headers, [int]$MaxPages = 100)
  $items = [System.Collections.Generic.List[object]]::new()
  $next = $Uri; $page = 0
  while (-not [string]::IsNullOrWhiteSpace($next)) {
    $page++
    if ($page -gt $MaxPages) { throw "Graph pagination exceeded $MaxPages pages for $Uri" }
    $response = Invoke-RestMethod -Method GET -Uri $next -Headers $Headers -ErrorAction Stop
    foreach ($item in @($response.value)) { if ($null -ne $item) { $items.Add($item) } }
    $next = [string]$response.'@odata.nextLink'
  }
  return @($items.ToArray())
}

# Reads the HTTP status out of an error record, whatever shape the thrown exception has.
# Invoke-RestMethod, the Graph SDK and the WinTuner module all surface it differently, and some
# wrap the real exception one or two levels deep. Returns 0 when no status can be found.
function Get-ErrorHttpStatus {
  param([Parameter(Mandatory)]$ErrorRecord)
  $ex = $ErrorRecord.Exception
  for ($depth = 0; $ex -and $depth -lt 4; $depth++) {
    foreach ($property in 'StatusCode', 'Response') {
      try {
        $value = $ex.PSObject.Properties[$property]
        if (-not $value) { continue }
        $candidate = if ($property -eq 'Response') { $ex.Response.StatusCode } else { $ex.StatusCode }
        if ($null -ne $candidate) {
          $number = [int]$candidate
          if ($number -gt 0) { return $number }
        }
      } catch { }   # class 3: a status we cannot read is simply "unknown"
    }
    $ex = $ex.InnerException
  }
  return 0
}

# "Was this a 404, i.e. the object is already gone?"
#
# Deletion paths treat that as success - nothing left to delete. That decision used to rest on the
# English substring 'not found' alone, so a localized or reworded message would have turned a failed
# deletion into a reported success. The status code is checked first and is authoritative; the text
# remains only as a fallback for callers whose exception carries no status, and taking that path is
# logged so it is visible when it happens.
function Test-IsNotFoundError {
  param([Parameter(Mandatory)]$ErrorRecord, [string]$Context = '')
  $status = Get-ErrorHttpStatus -ErrorRecord $ErrorRecord
  if ($status -eq 404) { return $true }
  if ($status -gt 0) { return $false }   # a real status that is not 404 settles it

  $message = [string]$ErrorRecord.Exception.Message
  if ($message -match '(?i)\bnot found\b' -or $message -match '(?<![\d.])404(?![\d.])') {
    Write-Log ("Treating '{0}' as already deleted based on the error TEXT, because the exception carried no HTTP status: {1}" -f $Context, $message)
    return $true
  }
  return $false
}

function Get-AppAssignmentProbe {
  param([Parameter(Mandatory)][string]$AppId, [string]$AppName = '')

  $out = [pscustomobject]@{
    Succeeded      = $false
    HasAssignments = $true
    Count          = $null
    ErrorMessage   = $null
  }
  if (-not (Test-GuidString $AppId)) {
    $out.ErrorMessage = 'invalid app id'
    Write-Log ("Assignment probe: invalid app id for '{0}'; treating assignment state as unknown." -f $AppName)
    return $out
  }

  try {
    $token = Get-WtToken -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'WinTuner returned an empty access token.' }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments?`$top=1"
    $assignments = @((Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop).value)
    $out.Succeeded = $true
    $out.HasAssignments = ($assignments.Count -gt 0)
    $out.Count = $assignments.Count
    Write-Log ("Assignment probe: '{0}' ({1}) has assignments={2}." -f $AppName, $AppId, $out.HasAssignments)
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Assignment probe failed for '{0}' ({1}); assignment state stays unknown: {2}" -f $AppName, $AppId, $out.ErrorMessage)
  }
  return $out
}

# Reads the complete assignment identity for multi-version consolidation. The normalized signature
# includes intent, target type/group and assignment filter. Settings such as notification style are
# intentionally excluded: they do not change WHO is in scope and Move-AppAssignments preserves them.
function Get-AppAssignmentScopeProbe {
  param([Parameter(Mandatory)][string]$AppId, [string]$AppName = '')
  $out = [pscustomobject]@{ Succeeded = $false; Signature = $null; Summary = $null; Count = $null; ErrorMessage = $null }
  if (-not (Test-GuidString $AppId)) { $out.ErrorMessage = 'invalid app id'; return $out }
  try {
    $token = Get-WtToken -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments"
    $assignments = @(Get-GraphCollectionItems -Uri $uri -Headers $headers)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $assignments) {
      $target = $a.target
      $targetType = if ($target) { [string]$target.'@odata.type' } else { '<missing-target>' }
      $targetType = $targetType -replace '^#?microsoft\.graph\.', ''
      $targetId = if ($target -and $target.groupId) { [string]$target.groupId } else { $targetType }
      $filterType = if ($target -and $target.deviceAndAppManagementAssignmentFilterType) { [string]$target.deviceAndAppManagementAssignmentFilterType } else { 'none' }
      $filterId = if ($target -and $target.deviceAndAppManagementAssignmentFilterId) { [string]$target.deviceAndAppManagementAssignmentFilterId } else { '-' }
      $source = if ($a.source) { [string]$a.source } else { 'direct' }
      $settingsTag = 'none'
      if ($a.settings) {
        $settingsJson = $a.settings | ConvertTo-Json -Compress -Depth 12
        $settingsHash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($settingsJson))
        $settingsTag = [System.Convert]::ToHexString($settingsHash).Substring(0, 12).ToLowerInvariant()
      }
      $parts.Add(("{0}|{1}|{2}|{3}|source:{4}|settings:{5}" -f ([string]$a.intent).ToLowerInvariant(), $targetId.ToLowerInvariant(), $filterType.ToLowerInvariant(), $filterId.ToLowerInvariant(), $source.ToLowerInvariant(), $settingsTag))
    }
    $normalized = @($parts | Sort-Object -Unique)
    $out.Succeeded = $true
    $out.Count = $assignments.Count
    $out.Signature = if ($normalized.Count -eq 0) { '<none>' } else { $normalized -join ';' }
    $out.Summary = if ($normalized.Count -eq 0) { Get-UiString 'UpdateScopeNone' } else { $normalized -join ', ' }
    Write-Log ("Scope probe: '{0}' ({1}) -> {2}" -f $AppName, $AppId, $out.Signature)
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    $out.Summary = Get-UiString 'UpdateScopeUnknown'
    Write-Log ("Scope probe failed for '{0}' ({1}): {2}" -f $AppName, $AppId, $out.ErrorMessage)
  }
  return $out
}

# Collapse several historical Intune objects into ONE visible update target. The concrete
# predecessors stay attached to the group and are processed one-by-one after the target has been
# created once. Only groups with multiple predecessors need the extra scope probes.
function Group-UpdateCandidates {
  # AllowEmptyCollection: a scan where every app already has an up-to-date target legitimately
  # produces no candidates at all. Without this the mandatory parameter refused the empty array and
  # the whole scan died at the very end - after all the work, and only in tenants that are fully
  # up to date.
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)
  if ($Candidates.Count -eq 0) { return @() }
  $models = @($Candidates | Group-Object -Property {
    ("{0}|{1}" -f ([string]$_.PackageId).Trim().ToLowerInvariant(), ([string]$_.LatestVersion).Trim().ToLowerInvariant())
  })
  $result = [System.Collections.Generic.List[object]]::new()
  foreach ($group in $models) {
    $members = @($group.Group)
    if ($members.Count -eq 0) { continue }
    $primary = $members[0]
    foreach ($candidate in $members) {
      if (Test-IsNewerVersion -Latest ([string]$candidate.CurrentVersion) -Current ([string]$primary.CurrentVersion)) { $primary = $candidate }
    }
    # Process the newest predecessor first. If packaging falls back from the requested newest
    # version, that fallback must still be newer than this member and therefore also newer than
    # every older member that follows; otherwise no historical app is accidentally downgraded.
    $orderedMembers = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $members) {
      $insertAt = $orderedMembers.Count
      for ($i = 0; $i -lt $orderedMembers.Count; $i++) {
        if (Test-IsNewerVersion -Latest ([string]$candidate.CurrentVersion) -Current ([string]$orderedMembers[$i].CurrentVersion)) { $insertAt = $i; break }
      }
      $orderedMembers.Insert($insertAt, $candidate)
    }
    $members = @($orderedMembers)
    $primary = $members[0]
    $scopeWarning = $false
    # Stays false for single-app rows: the scope probe below only runs for grouped predecessors,
    # and "unknown" must not be shown as "no assignment".
    $noAssignment = $false
    $scopeLines = [System.Collections.Generic.List[string]]::new()
    if ($members.Count -gt 1) {
      # A different tenant display name can indicate intentionally separate deployment lanes even
      # when the WinGet package id is identical (for example training, pilot or department apps).
      if (@($members | ForEach-Object { ([string]$_.Name).Trim().ToLowerInvariant() } | Sort-Object -Unique).Count -gt 1) {
        $scopeWarning = $true
      }
      $deployedTargetIds = @($members | Where-Object { $_.ExistingTargetGraphId } | ForEach-Object { [string]$_.ExistingTargetGraphId } | Sort-Object -Unique)
      if ($deployedTargetIds.Count -gt 1) {
        $scopeWarning = $true
        $scopeLines.Add(("Multiple copies of the requested target already exist: {0}" -f ($deployedTargetIds -join ', ')))
      }
      $signatures = [System.Collections.Generic.List[string]]::new()
      $probeSummaries = [System.Collections.Generic.List[string]]::new()
      foreach ($candidate in $members) {
        $probe = Get-AppAssignmentScopeProbe -AppId ([string]$candidate.GraphId) -AppName ([string]$candidate.Name)
        if ($probe.Succeeded) { $signatures.Add([string]$probe.Signature); $probeSummaries.Add([string]$probe.Summary) } else { $scopeWarning = $true }
        $scopeLines.Add(("{0} {1} ({2}): {3}" -f $candidate.Name, $candidate.CurrentVersion, $candidate.GraphId, $probe.Summary))
      }
      # Only when EVERY probe succeeded and reported no target: an unverified probe must never be
      # presented as "no assignment", because that is exactly the state a cleanup would act on.
      $noAssignment = ($probeSummaries.Count -eq $members.Count -and
                       @($probeSummaries | Where-Object { $_ -ne '<none>' }).Count -eq 0)
      if (@($signatures | Sort-Object -Unique).Count -gt 1) { $scopeWarning = $true }
    }
    $versions = @($members | ForEach-Object { [string]$_.CurrentVersion } | Sort-Object -Unique)
    $existingTarget = @($members | Where-Object { $_.ExistingTargetGraphId } | Select-Object -First 1)
    $targetId = if ($existingTarget.Count) { [string]$existingTarget[0].ExistingTargetGraphId } else { $null }
    $targetName = if ($existingTarget.Count) { [string]$existingTarget[0].ExistingTargetName } else { $null }
    $result.Add([pscustomobject]@{
      Name                  = [string]$primary.Name
      CurrentVersion        = ($versions -join ', ')
      LatestVersion         = [string]$primary.LatestVersion
      GraphId               = [string]$primary.GraphId
      PackageId             = [string]$primary.PackageId
      LaneKey               = ([string]$primary.PackageId).Trim().ToLowerInvariant()
      ExistingTargetGraphId = $targetId
      ExistingTargetName    = $targetName
      TargetAlreadyDeployed = -not [string]::IsNullOrWhiteSpace($targetId)
      Predecessors          = $members
      ConcreteCount         = $members.Count
      ScopeWarning          = $scopeWarning
      NoAssignment          = $noAssignment
      ScopeDetails          = ($scopeLines -join "`r`n")
      # Carried over deliberately: if ANY member of the group cannot be updated safely (currently
      # a duplicate package id + version in Intune), the whole grouped row must stay read-only.
      # Rebuilding the object without these dropped the flag and the row looked actionable again.
      BlockedReason         = [string]($members | Where-Object { $_.PSObject.Properties['IsBlocked'] -and $_.IsBlocked } | Select-Object -First 1 -ExpandProperty BlockedReason)
      IsBlocked             = [bool]@($members | Where-Object { $_.PSObject.Properties['IsBlocked'] -and $_.IsBlocked }).Count
      Checked               = $false
    })
    if ($members.Count -gt 1) {
      Write-Log ("Grouped {0} predecessor(s) for {1} -> {2}; scopeWarning={3}." -f $members.Count, $primary.PackageId, $primary.LatestVersion, $scopeWarning)
    }
  }
  return @($result.ToArray())
}

function Expand-UpdateCandidateGroups {
  # Same reason as Group-UpdateCandidates: an empty selection is a legitimate state, not an error.
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups)
  $expanded = [System.Collections.Generic.List[object]]::new()
  foreach ($group in $Groups) {
    $members = if ($group.PSObject.Properties['Predecessors'] -and $group.Predecessors) { @($group.Predecessors) } else { @($group) }
    foreach ($member in $members) { if ($member) { $expanded.Add($member) } }
  }
  return @($expanded)
}

function Confirm-UpdateScopeConsolidation {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups)
  $warnings = @($Groups | Where-Object { $_.ScopeWarning })
  if ($warnings.Count -eq 0) { return $true }
  $lines = @($warnings | ForEach-Object { "{0} -> {1}`r`n{2}" -f $_.Name, $_.LatestVersion, $_.ScopeDetails })
  if (-not $script:settings.MoveAssignmentsOnUpdate) { $lines += "`r`n" + (Get-UiString 'UpdateScopeHandoverOff') }
  $answer = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'UpdateScopeWarningDialog') -f ($lines -join "`r`n`r`n")),
    (Get-UiString 'UpdateScopeWarningTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Determines whether Intune still reports successful installations for an app. The deprecated
# installSummary path is intentionally not used. The documented device-status collection is paged
# without a server-side filter (some tenants reject that filter) and evaluated locally. Any error
# remains "unknown" and therefore blocks automatic deletion.
function Get-AppInstallationProbe {
  param([Parameter(Mandatory)][string]$AppId, [string]$AppName = '')

  $out = [pscustomobject]@{
    Succeeded        = $false
    HasInstallations = $true
    Count            = $null
    ErrorMessage     = $null
  }
  if (-not (Test-GuidString $AppId)) {
    $out.ErrorMessage = 'invalid app id'
    Write-Log ("Installation probe: invalid app id for '{0}'; treating installation state as unknown." -f $AppName)
    return $out
  }

  try {
    $token = Get-WtToken -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'WinTuner returned an empty access token.' }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $base = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId"

    # Some Intune tenants reject $filter on this beta navigation property with HTTP 400 even
    # though the unfiltered endpoint is supported. Page through the plain documented collection
    # and evaluate installState client-side. Stop as soon as one successful state is found.
    $uri = "$base/deviceStatuses"
    $hasInstalledStatus = $false
    # Bounded like every other paging loop here: an endless nextLink chain would hang the UI thread
    # in a probe whose answer decides whether an app version may be deleted.
    $statusPages = 0
    do {
      $statusPages++
      if ($statusPages -gt 100) { throw "Device status pagination exceeded 100 pages for app $AppId." }
      $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
      foreach ($status in @($response.value)) {
        if ([string]::Equals([string]$status.installState, 'installed', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals([string]$status.mobileAppInstallStatusValue, 'installed', [System.StringComparison]::OrdinalIgnoreCase)) {
          $hasInstalledStatus = $true
          break
        }
      }
      if ($hasInstalledStatus) { break }
      $uri = [string]$response.'@odata.nextLink'
    } while (-not [string]::IsNullOrWhiteSpace($uri))
    $out.Succeeded = $true
    $out.HasInstallations = $hasInstalledStatus
    $out.Count = if ($hasInstalledStatus) { 1 } else { 0 }
    Write-Log ("Installation probe: '{0}' ({1}) has successful installations={2} (device statuses)." -f $AppName, $AppId, $out.HasInstallations)
  } catch {
    $statusError = $_.Exception.Message
    # Some tenants answer /deviceStatuses with a flat HTTP 400 for every app. That left the
    # installation state permanently "unknown", and because unknown blocks every deletion, the
    # version cleanup could never remove a single old version there - it reported "kept back" for
    # all of them, run after run. installSummary is the aggregate counterpart of the same data and
    # answers where the per-device collection does not.
    Write-LogDebug ("Installation probe: device statuses unavailable for '{0}' ({1}), falling back to install summary: {2}" -f $AppName, $AppId, $statusError)
    try {
      $summary = Invoke-RestMethod -Method GET -Uri "$base/installSummary" -Headers $headers -ErrorAction Stop
      # Absent counters read as 0. A missing property means "none reported", which is exactly the
      # zero-installation case; only a failed CALL counts as unknown.
      $installedDevices = [int]$summary.installedDeviceCount
      $installedUsers = [int]$summary.installedUserCount
      $out.Succeeded = $true
      $out.Count = $installedDevices + $installedUsers
      $out.HasInstallations = ($out.Count -gt 0)
      Write-Log ("Installation probe: '{0}' ({1}) has successful installations={2} (install summary: {3} device(s), {4} user(s))." -f $AppName, $AppId, $out.HasInstallations, $installedDevices, $installedUsers)
    } catch {
      $summaryError = $_.Exception.Message
      # Third and last source: the reporting endpoint the Intune portal itself uses for app install
      # status. Measured in a tenant that answers HTTP 400 to EVERY per-app navigation property -
      # deviceStatuses, userStatuses and installSummary alike, on both beta and v1.0, with and
      # without the win32LobApp type cast. This one answered. Without it the installation state
      # stayed permanently unknown there, and unknown blocks every deletion, so the version cleanup
      # reported "0 removed, N kept back" run after run and could never do its job.
      try {
        $report = Get-AppInstallCountsFromReport -AppId $AppId -Headers $headers
        $out.Succeeded = $true
        $out.Count = $report.InstalledCount
        $out.HasInstallations = ($report.InstalledCount -gt 0)
        Write-Log ("Installation probe: '{0}' ({1}) has successful installations={2} (app status report: {3} installed device(s) across {4} row(s))." -f $AppName, $AppId, $out.HasInstallations, $report.InstalledCount, $report.RowCount)
      } catch {
        $out.ErrorMessage = ("device statuses: {0}; install summary: {1}; app status report: {2}" -f $statusError, $summaryError, $_.Exception.Message)
        Write-Log ("Installation probe failed for '{0}' ({1}); installation state stays unknown: {2}" -f $AppName, $AppId, $out.ErrorMessage)
      }
    }
  }
  return $out
}

# Reads the installed-device count from the app status overview report.
#
# The response is column-oriented: a Schema array naming the columns, and a Values array of rows.
# The column index is therefore looked up BY NAME - relying on a fixed position would silently read
# the wrong number the day Microsoft adds a column, and that number decides deletions.
#
# Anything unexpected throws, which the caller turns into "unknown". That direction is deliberate:
# an unreadable report must block a deletion, never permit one. The worst case is a cleanup that
# does not run - recoverable - instead of a version removed on a misparsed field.
function Get-AppInstallCountsFromReport {
  param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][hashtable]$Headers
  )
  $body = @{ filter = ("(ApplicationId eq '{0}')" -f $AppId); skip = 0; top = 50 } | ConvertTo-Json -Depth 4
  $response = Invoke-RestMethod -Method POST -Headers $Headers -Body $body -ErrorAction Stop `
    -Uri 'https://graph.microsoft.com/beta/deviceManagement/reports/getAppStatusOverviewReport'

  $schema = @($response.Schema)
  if ($schema.Count -eq 0) { throw 'The app status report returned no schema.' }
  $columnIndex = -1
  for ($i = 0; $i -lt $schema.Count; $i++) {
    if ([string]::Equals([string]$schema[$i].Column, 'InstalledDeviceCount', [System.StringComparison]::OrdinalIgnoreCase)) {
      $columnIndex = $i; break
    }
  }
  if ($columnIndex -lt 0) { throw 'The app status report contains no InstalledDeviceCount column.' }

  # No rows means Intune holds no installation record for this app - the same thing an administrator
  # sees as an empty install-status list in the portal. That is a confirmed zero, not unknown.
  $rows = @($response.Values)
  $installed = 0
  foreach ($row in $rows) {
    $cells = @($row)
    if ($cells.Count -le $columnIndex) { throw 'An app status report row is shorter than its schema.' }
    $installed += [int]$cells[$columnIndex]
  }
  return [pscustomobject]@{ InstalledCount = $installed; RowCount = $rows.Count }
}

# Describes what THIS run will do, read from the settings that are actually in effect right now.
# The notice used to be one of two fixed paragraphs, driven by a single option, so the confirmation
# could not tell the user whether assignments would move or whether older versions would be trimmed
# afterwards - both of which delete or re-scope things in Intune.
function Get-UpdateCleanupNotice {
  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add((Get-UiString 'UpdateNoticeHeader'))
  $lines.Add($(if ($script:settings.MoveAssignmentsOnUpdate) {
    Get-UiString 'UpdateNoticeHandoverOn'
  } else {
    Get-UiString 'UpdateNoticeHandoverOff'
  }))
  # Always true: an unassigned, never-installed predecessor is cleaned up regardless of the options.
  $lines.Add((Get-UiString 'UpdateNoticeUnassigned'))
  $lines.Add($(if ($script:settings.AutoRemoveSuperseded) {
    Get-UiString 'UpdateNoticeAssignedRemove'
  } else {
    Get-UiString 'UpdateNoticeAssignedKeep'
  }))
  # Only worth a line when it will actually run; it is mutually exclusive with the option above.
  if ($script:settings.AutoVersionCleanup) {
    $keep = if ($script:keepVersionCount -ge 1) { [int]$script:keepVersionCount } else { 2 }
    $lines.Add(((Get-UiString 'UpdateNoticeVersionCleanup') -f $keep))
  }
  return ($lines -join "`r`n")
}


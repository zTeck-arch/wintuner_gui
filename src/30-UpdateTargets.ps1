# Some WinTuner/module versions can return an app through both inventory calls immediately after
# supersedence was created. GraphId is authoritative: an object reported by the superseded query
# must not also appear as an active update candidate or active reuse target.
function Remove-SupersededInventoryOverlap {
  param(
    # AllowEmptyCollection is essential: a tenant whose apps are ALL superseded (managed=0,
    # superseded>0) hands an empty active inventory here. Without it PowerShell rejected the empty
    # array at binding time - "Cannot bind argument to parameter 'ActiveApps' because it is an empty
    # array" - which aborted the whole "load apps" step, so the Updates section never loaded even
    # though the tenant plainly had superseded apps to show.
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ActiveApps,
    [object[]]$SupersededApps = @()
  )
  $supersededIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($app in @($SupersededApps)) {
    if ($app -and -not [string]::IsNullOrWhiteSpace([string]$app.GraphId)) {
      [void]$supersededIds.Add([string]$app.GraphId)
    }
  }
  if ($supersededIds.Count -eq 0) { return @($ActiveApps) }

  $filtered = @($ActiveApps | Where-Object {
    $_ -and (-not $_.GraphId -or -not $supersededIds.Contains([string]$_.GraphId))
  })
  $removed = $ActiveApps.Count - $filtered.Count
  if ($removed -gt 0) {
    Write-Log ("Inventory classification: excluded {0} app object(s) from the active update scan because the same GraphId is already superseded." -f $removed)
    # Named individually, not just counted: an object dropped here is invisible to the scan for the
    # rest of the run - including as a REUSABLE TARGET. If a version that plainly exists in the
    # portal is reported as "to be created", this list is where that shows up.
    foreach ($app in @($ActiveApps)) {
      if ($app -and $app.GraphId -and $supersededIds.Contains([string]$app.GraphId)) {
        Write-Log ("  excluded from the active scan: {0} {1} ({2})" -f $app.Name, $app.CurrentVersion, $app.GraphId)
      }
    }
  }
  return $filtered
}

# Module objects may expose LatestVersion as read-only. Update rows therefore use a small mutable
# view model with the exact version and package id selected by the fresh scan.
function New-UpdateCandidateModel {
  param(
    [Parameter(Mandatory)]$App,
    # AllowEmptyString: eine gesperrte Zeile ("keine WinGet-Id zuordenbar") hat keine Zielversion -
    # sie existiert ja gerade, weil nichts zu vergleichen war. Ohne das lehnte der Pflichtparameter
    # den Leerstring ab und die App waere wieder nur im Protokoll gelandet.
    [Parameter(Mandatory)][AllowEmptyString()][string]$LatestVersion,
    [string]$PackageId,
    [string]$ExistingTargetGraphId,
    [string]$ExistingTargetName,
    # Set when the tenant state prevents a safe update (currently: two Intune apps share the same
    # package id AND version, so no single target can be chosen). Such a row is shown read-only:
    # dropping it silently left the user unable to see - let alone fix - the duplicate.
    [string]$BlockedReason
  )
  [pscustomobject]@{
    Name           = [string]$App.Name
    CurrentVersion = [string]$App.CurrentVersion
    LatestVersion  = $LatestVersion
    GraphId        = [string]$App.GraphId
    PackageId      = $PackageId
    LaneKey        = ("{0}|{1}" -f $PackageId.Trim().ToLowerInvariant(), ([string]$App.Name).Trim().ToLowerInvariant())
    ExistingTargetGraphId = $ExistingTargetGraphId
    ExistingTargetName    = $ExistingTargetName
    TargetAlreadyDeployed = -not [string]::IsNullOrWhiteSpace($ExistingTargetGraphId)
    BlockedReason  = $BlockedReason
    IsBlocked      = -not [string]::IsNullOrWhiteSpace($BlockedReason)
    # Traegt die Quell-App keine WinTuner-Marke, stammt die Paket-Id aus dem Namensabgleich und nicht
    # aus dem Notizfeld. Das ist der einzige Unterschied, den der Techniker vor dem Haken sehen muss -
    # ohne ihn saehe eine ueber den Namen zugeordnete Zeile aus wie eine belegte.
    IsUnmanaged    = [bool]($App.PSObject.Properties['IsUnmanaged'] -and $App.IsUnmanaged)
    # Die Id stand im Notizfeld, sie wurde nicht ueber den Namen erraten. Die Zeile sagt das, weil
    # der Unterschied fuer die Entscheidung zaehlt: aufgeschrieben ist belastbar, zugeordnet ist
    # eine Vermutung.
    PackageIdFromNotes = [bool]($App.PSObject.Properties['PackageIdFromNotes'] -and $App.PackageIdFromNotes)
    # Einmal hier ausgewertet statt an jeder Anzeigestelle erneut: die Liste, die Rueckfrage vor dem
    # Lauf und die Zeilenfarbe muessen ueber DASSELBE Urteil reden. Wird die Liste waehrend der
    # Anzeige geaendert (Rechtsklick), zeichnet Update-UpdateListRows die Zeilen mit neuem Wert.
    IsProtected    = [bool](Test-IsProtectedApp -Name ([string]$App.Name) -Patterns $script:settings.ProtectedApps)
    Checked        = $false
  }
}

# An already deployed target only needs an update-list row while the old source app still has an
# assignment that may need to be handed over. A safely verified unassigned predecessor can remain
# in Intune because devices still report installations, but that is not another update and must not
# reappear after every successful scan. Unknown assignment state stays visible and fail-safe.
function Test-RequiresExistingTargetFollowUp {
  param(
    [Parameter(Mandatory)]$SourceApp,
    [Parameter(Mandatory)]$ExistingTarget
  )
  $probe = Get-AppAssignmentProbe -AppId ([string]$SourceApp.GraphId) -AppName ([string]$SourceApp.Name)
  if ($probe.Succeeded -and -not $probe.HasAssignments) {
    Write-Log ("No update action required: {0} {1} ({2}) has existing target {3} ({4}) and no remaining source assignment; row omitted." -f $SourceApp.Name, $SourceApp.CurrentVersion, $SourceApp.GraphId, $ExistingTarget.CurrentVersion, $ExistingTarget.GraphId)
    return $false
  }
  if (-not $probe.Succeeded) {
    Write-Log ("Existing-target follow-up kept visible for {0} {1} ({2}) because source assignments could not be verified safely." -f $SourceApp.Name, $SourceApp.CurrentVersion, $SourceApp.GraphId)
  }
  return $true
}

function Find-ExistingUpdateTarget {
  param(
    # AllowEmptyCollection: a brand-new tenant (or one whose apps are all superseded) hands an empty
    # active inventory here. Without it PowerShell rejects @() at binding time and the very first
    # upload into every new customer tenant fails permanently - there is no self-healing path.
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Apps,
    [Parameter(Mandatory)][string]$PackageId,
    [Parameter(Mandatory)][string]$Version,
    [string]$ExcludeGraphId,
    [string]$PreferredName,
    [hashtable]$ResolvedIds
  )
  $matches = [System.Collections.Generic.List[object]]::new()
  foreach ($candidate in $Apps) {
    if (-not $candidate -or -not $candidate.GraphId -or -not $candidate.CurrentVersion) { continue }
    if ($ExcludeGraphId -and [string]::Equals([string]$candidate.GraphId, $ExcludeGraphId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    $candidateId = $null
    if ($ResolvedIds -and $ResolvedIds.ContainsKey([string]$candidate.GraphId)) {
      $candidateId = [string]$ResolvedIds[[string]$candidate.GraphId]
    } else {
      $candidateId = Resolve-WtWingetId -AppOrResult $candidate
    }
    if (-not [string]::Equals($candidateId, $PackageId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-VersionsEquivalent -Left ([string]$candidate.CurrentVersion) -Right $Version) { $matches.Add($candidate) }
  }
  $allMatches = @($matches)
  $candidateMatches = $allMatches
  if ($PreferredName) {
    $namedMatches = @($allMatches | Where-Object {
      [string]::Equals(([string]$_.Name).Trim(), $PreferredName.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($namedMatches.Count -eq 1) { return $namedMatches[0] }
    if ($namedMatches.Count -gt 1) { $candidateMatches = $namedMatches }
  }
  if ($candidateMatches.Count -gt 1) {
    $ids = @($candidateMatches | ForEach-Object { [string]$_.GraphId }) -join ', '
    throw "Ambiguous existing target for $PackageId $Version (name '$PreferredName'): $ids"
  }
  if ($candidateMatches.Count -eq 1) { return $candidateMatches[0] }
  return $null
}

function Find-NewerTenantPackageTarget {
  param(
    # See Find-ExistingUpdateTarget: an empty active inventory is legitimate and must bind.
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Apps,
    [Parameter(Mandatory)][string]$PackageId,
    [Parameter(Mandatory)][string]$Version,
    [string]$ExcludeGraphId,
    [hashtable]$ResolvedIds
  )
  $newer = [System.Collections.Generic.List[object]]::new()
  foreach ($candidate in $Apps) {
    if (-not $candidate -or -not $candidate.GraphId -or -not $candidate.CurrentVersion) { continue }
    if ($ExcludeGraphId -and [string]::Equals([string]$candidate.GraphId, $ExcludeGraphId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    $candidateId = if ($ResolvedIds -and $ResolvedIds.ContainsKey([string]$candidate.GraphId)) {
      [string]$ResolvedIds[[string]$candidate.GraphId]
    } else {
      Resolve-WtWingetId -AppOrResult $candidate
    }
    if (-not [string]::Equals($candidateId, $PackageId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-IsNewerVersion -Latest ([string]$candidate.CurrentVersion) -Current $Version) { $newer.Add($candidate) }
  }
  if ($newer.Count -eq 0) { return $null }
  $newest = $newer[0]
  foreach ($candidate in $newer) {
    if (Test-IsNewerVersion -Latest ([string]$candidate.CurrentVersion) -Current ([string]$newest.CurrentVersion)) { $newest = $candidate }
  }
  return $newest
}

# Re-checks the tenant immediately before an update can build or upload a package. The scan result
# is only a UI snapshot and must never be the final duplicate guard: another administrator may
# deploy the target afterwards, or an earlier PackageId/name resolution may have been incomplete.
#
# The active (non-superseded) inventory is authoritative for reuse. If an equal package/version is
# found only among superseded objects, the upload is blocked instead of assigning users back to an
# already superseded target. Likewise, an equal-name/equal-version object whose PackageId cannot be
# resolved is treated as a potential duplicate and blocks mutation until the ambiguity is fixed.
function Get-FreshExistingUpdateTarget {
  param(
    [Parameter(Mandatory)][string]$PackageId,
    [Parameter(Mandatory)][string]$Version,
    [string]$ExcludeGraphId,
    [string]$PreferredName
  )

  # Through the resilient wrapper on purpose. This is the duplicate guard that runs immediately
  # before an upload, inside a batch that is pumping DoEvents - exactly the conditions that trigger
  # the module's "Collection was modified" race. A bare call would abort the app with "Duplicate
  # safety check failed" on the first attempt, which is the failure 0.15.7 set out to remove.
  # Deliberately NOT cached: see the cache comment in 25-WinGetData.ps1.
  $activeApps = @(Get-Win32AppsResilient -Label 'fresh update target (active)')
  $supersededApps = @(Get-Win32AppsResilient -Superseded -Label 'fresh update target (superseded)')
  $activeApps = @(Remove-SupersededInventoryOverlap -ActiveApps $activeApps -SupersededApps $supersededApps)
  $resolvedIds = @{}
  $unresolvedPotential = [System.Collections.Generic.List[object]]::new()
  foreach ($candidate in $activeApps) {
    if (-not $candidate -or -not $candidate.GraphId) { continue }
    $candidateId = [string](Resolve-WtWingetId -AppOrResult $candidate)
    # Most WinTuner objects expose PackageId directly. Only perform a package-index name lookup for
    # an equal display name; resolving every unrelated tenant app before each update is needlessly
    # slow and can trigger package-source throttling.
    if ([string]::IsNullOrWhiteSpace($candidateId) -and $PreferredName -and
        [string]::Equals(([string]$candidate.Name).Trim(), $PreferredName.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
      try { $candidateId = [string](Resolve-WingetIdForApp -App $candidate) } catch {
        Write-Log ("Pre-upload target guard: PackageId resolution failed for '{0}' ({1}): {2}" -f $candidate.Name, $candidate.GraphId, $_.Exception.Message)
      }
    }
    $resolvedIds[[string]$candidate.GraphId] = $candidateId
    if ([string]::IsNullOrWhiteSpace($candidateId) -and
        (Test-VersionsEquivalent -Left ([string]$candidate.CurrentVersion) -Right $Version) -and
        $PreferredName -and
        [string]::Equals(([string]$candidate.Name).Trim(), $PreferredName.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
      $unresolvedPotential.Add($candidate)
    }
  }

  $newerTarget = Find-NewerTenantPackageTarget -Apps $activeApps -PackageId $PackageId -Version $Version `
    -ExcludeGraphId $ExcludeGraphId -ResolvedIds $resolvedIds
  if ($newerTarget -and $newerTarget.GraphId) {
    throw "Intune already contains newer active version $($newerTarget.CurrentVersion) for $PackageId (GraphId: $($newerTarget.GraphId)). The older requested target $Version will not be uploaded."
  }

  $target = Find-ExistingUpdateTarget -Apps $activeApps -PackageId $PackageId -Version $Version `
    -ExcludeGraphId $ExcludeGraphId -PreferredName $PreferredName -ResolvedIds $resolvedIds
  if ($target -and $target.GraphId) {
    Write-Log ("Pre-upload target guard: reusing active Intune target {0} for {1} {2}; package build/upload skipped." -f $target.GraphId, $PackageId, $Version)
    return $target
  }

  if ($unresolvedPotential.Count -gt 0) {
    $ids = @($unresolvedPotential | ForEach-Object { [string]$_.GraphId }) -join ', '
    throw "A potential existing target for $PackageId $Version could not be verified because its PackageId is unresolved (GraphId: $ids). Upload was blocked to prevent a duplicate."
  }

  # An exact version may still exist as an old/superseded object. It must not be uploaded a second
  # time, but it is also not a valid rollout target. Surface this tenant inconsistency explicitly.
  if ($supersededApps.Count -gt 0) {
    $supersededIds = @{}
    foreach ($candidate in $supersededApps) {
      if (-not $candidate -or -not $candidate.GraphId) { continue }
      $candidateId = [string](Resolve-WtWingetId -AppOrResult $candidate)
      if ([string]::IsNullOrWhiteSpace($candidateId) -and $PreferredName -and
          [string]::Equals(([string]$candidate.Name).Trim(), $PreferredName.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        try { $candidateId = [string](Resolve-WingetIdForApp -App $candidate) } catch { $candidateId = '' }
      }
      $supersededIds[[string]$candidate.GraphId] = $candidateId
    }
    $supersededTarget = Find-ExistingUpdateTarget -Apps $supersededApps -PackageId $PackageId -Version $Version `
      -ExcludeGraphId $ExcludeGraphId -PreferredName $PreferredName -ResolvedIds $supersededIds
    if ($supersededTarget -and $supersededTarget.GraphId) {
      throw "Package $PackageId $Version already exists in Intune as superseded app $($supersededTarget.GraphId). It cannot be reused as an active target and will not be uploaded again."
    }
  }

  Write-Log ("Pre-upload target guard: no existing tenant target found for {0} {1}; package creation is allowed." -f $PackageId, $Version)
  return $null
}

# Resolve the exact Microsoft Store package before mutating Intune. WinTuner's SearchQuery mode
# deliberately chooses the first result, so the GUI resolves that result through the same msstore
# source and subsequently deploys by PackageId. Parsing is independent of localized column labels:
# only result rows ending in the fixed source name are considered.
# Returns EVERY distinct Microsoft Store hit for $Query instead of insisting on exactly one.
# Resolve-MsStorePackage below needs a single authoritative id and throws when the query is
# ambiguous - which is correct for an unattended deployment, but useless when the user simply
# does not know the exact Store name yet ("Spotify" matches several entries). The picker in the
# Store card uses this function so an ambiguous query becomes a choice rather than an error.
function Search-MsStorePackage {
  param([Parameter(Mandatory)][string]$Query)
  $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
  if (-not $winget) { $winget = Get-Command winget -ErrorAction SilentlyContinue }
  if (-not $winget) { throw (Get-UiString 'StoreResolveFailed') }

  $raw = @(& $winget.Source search --query $Query --source msstore --count 25 --accept-source-agreements --disable-interactivity 2>&1)
  # 0x8A15002B ("no package found matching input criteria") is a normal empty result, not a
  # failure - reporting it as an error made a harmless "nothing found" look like a broken search.
  $noMatchExitCode = -1978335212
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $noMatchExitCode) {
    throw ((Get-UiString 'StoreResolveFailed') + " (winget exit $LASTEXITCODE)")
  }
  if ($LASTEXITCODE -eq $noMatchExitCode) { return @() }

  # winget prints a fixed-width table and localises the column headings, so the layout is read from
  # the header rather than guessed. Two earlier assumptions were both wrong:
  #   - there is NO source column when --source is passed, so anchoring on "msstore" never matched
  #   - cells are not always separated by two spaces; a name that exactly fills its column leaves
  #     only one ("Spotify - Music and Podcasts 9NCBCSZSJRSB Unknown")
  # Column start offsets taken from the header handle both cases.
  $lines = @($raw | ForEach-Object { [string]$_ })
  $separatorIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^-{5,}$') { $separatorIndex = $i; break }
  }
  $storeRows = [System.Collections.Generic.List[object]]::new()
  if ($separatorIndex -lt 1) { return @() }   # no table at all (e.g. "No package found")

  $header = $lines[$separatorIndex - 1]
  $columnStarts = [System.Collections.Generic.List[int]]::new()
  for ($c = 0; $c -lt $header.Length; $c++) {
    if ($header[$c] -ne ' ' -and ($c -eq 0 -or $header[$c - 1] -eq ' ')) { $columnStarts.Add($c) }
  }
  if ($columnStarts.Count -lt 2) { return @() }

  $nameStart = $columnStarts[0]
  $idStart = $columnStarts[1]
  foreach ($line in $lines[($separatorIndex + 1)..($lines.Count - 1)]) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^-{5,}$') { continue }
    if ($line.Length -le $idStart) { continue }
    $name = $line.Substring($nameStart, [Math]::Min($idStart - $nameStart, $line.Length - $nameStart)).Trim()
    $idEnd = if ($columnStarts.Count -gt 2) { [Math]::Min($columnStarts[2], $line.Length) } else { $line.Length }
    $id = $line.Substring($idStart, $idEnd - $idStart).Trim()
    if ($name -and $id) {
      $storeRows.Add([pscustomobject]@{ Name = $name; PackageIdentifier = $id })
    }
  }
  $seenStoreIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  return @($storeRows | Where-Object { $seenStoreIds.Add([string]$_.PackageIdentifier) })
}

function Resolve-MsStorePackage {
  param([Parameter(Mandatory)][string]$Query)
  $unique = @(Search-MsStorePackage -Query $Query)
  if ($unique.Count -eq 0) { throw (Get-UiString 'StoreResolveFailed') }
  $exact = @($unique | Where-Object {
    [string]::Equals([string]$_.PackageIdentifier, $Query.Trim(), [System.StringComparison]::OrdinalIgnoreCase) -or
    [string]::Equals([string]$_.Name, $Query.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
  })
  if ($exact.Count -eq 1) { return $exact[0] }
  if ($exact.Count -gt 1) { throw (Get-UiString 'StoreResolveFailed') }
  # This is the same first-result behavior documented for Deploy-WtMsStoreApp -SearchQuery, but the
  # chosen identity is now visible to and enforceable by the duplicate check.
  return $unique[0]
}

function Resolve-DeployedStoreTarget {
  param([Parameter(Mandatory)][string]$PackageIdentifier, [string]$ReturnedId)
  for ($attempt = 1; $attempt -le 8; $attempt++) {
    $apps = @(Get-TenantStoreApps)
    $matches = @($apps | Where-Object {
      [string]::Equals([string]$_.PackageIdentifier, $PackageIdentifier, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -gt 1) { throw "Multiple Intune Store apps exist for package $PackageIdentifier; assignment was not guessed." }
    if ($matches.Count -eq 1) {
      if ($ReturnedId -and -not [string]::Equals([string]$matches[0].Id, $ReturnedId, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log ("Store deploy return id '{0}' differs from authoritative GraphId '{1}'." -f $ReturnedId, $matches[0].Id)
      }
      return $matches[0]
    }
    if ($attempt -lt 8) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Seconds ([Math]::Min(5, $attempt))
    }
  }
  return $null
}

# Deploy-WtWin32App return shapes differ between module versions; an .Id value is not guaranteed
# to be the Graph mobileApp id. Resolve the authoritative target back from Intune by package id +
# version and tolerate the short eventual-consistency delay after creation.
function Resolve-DeployedUpdateTarget {
  param(
    [Parameter(Mandatory)][string]$PackageId,
    [Parameter(Mandatory)][string]$Version,
    [string]$ExcludeGraphId,
    [string]$PreferredName,
    [string]$ReturnedId
  )
  for ($attempt = 1; $attempt -le 8; $attempt++) {
    try {
      # -MaxRetries 0: this loop is already the retry, with escalating delays, and it also covers the
      # "app not visible yet" case. Going through the wrapper anyway keeps one inventory code path
      # and picks up the truncation check.
      $apps = @(Get-Win32AppsResilient -Label ("deployed target resolution (attempt {0}/8)" -f $attempt) -MaxRetries 0)
      $target = Find-ExistingUpdateTarget -Apps $apps -PackageId $PackageId -Version $Version -ExcludeGraphId $ExcludeGraphId -PreferredName $PreferredName
      if ($target -and $target.GraphId) {
        $resolved = [string]$target.GraphId
        if ($ReturnedId -and -not [string]::Equals($ReturnedId, $resolved, [System.StringComparison]::OrdinalIgnoreCase)) {
          Write-Log ("Deploy return id '{0}' is not the Intune target GraphId; resolved authoritative target '{1}'." -f $ReturnedId, $resolved)
        } else {
          Write-Log ("Resolved deployed Intune target: {0} {1} -> {2}" -f $PackageId, $Version, $resolved)
        }
        return $target
      }
    } catch { Write-Log ("Target resolution attempt {0}/8 failed: {1}" -f $attempt, $_.Exception.Message) }
    if ($attempt -lt 8) {
      # Intune usually lists a freshly created app within a second or two. Starting at +1 instead of
      # +2 keeps the same total patience (~28s) but returns sooner in the common case.
      $delay = [Math]::Min(7, $attempt)
      for ($second = 0; $second -lt $delay; $second++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
      }
    }
  }
  Write-Log ("Could not resolve deployed target from Intune for {0} {1}; the deploy return id will not be trusted." -f $PackageId, $Version)
  return $null
}

# WinTuner renamed the removal parameter from -GraphId to -AppId. Detect the installed command at
# runtime so both older deployments and the current 1.4.x module work.
#
# Laeuft seit 0.18.0 im Hintergrund-Runspace, aus demselben Grund wie der Upload. Gemeldet am
# 03.09.2026: waehrend des Aufraeumens stand das Fenster still und "Nach aktueller App stoppen" tat
# nichts. Gemessen am Protokoll desselben Laufs kostete jede FEHLGESCHLAGENE Loeschung 5 bis 7
# Sekunden (Zoom 09:07:16-09:07:21, Firefox 09:07:09-09:07:14) - bei drei Apps je Aufraeumlauf rund
# 20 Sekunden Standbild, und genau darin tut der Abbruchknopf nichts.
#
# Derselbe Riegel wie beim Upload: KEIN Abbruch und KEIN Zeitablauf. Eine halb ausgefuehrte Loeschung
# ist so wenig zurueckzunehmen wie ein halber Upload - Intune haengt an einer App ihre
# Abloesebeziehungen, und nach einem Abbruch mitten darin ist nicht feststellbar, was schon weg ist.
# Der Abbruchknopf wirkt weiterhin ZWISCHEN den Apps.
function Invoke-WtRemoveWin32App {
  param([Parameter(Mandatory)][string]$AppId)
  $command = Get-Command Remove-WtWin32App -ErrorAction Stop
  $removeArgs = @{ ErrorAction = 'Stop' }
  if ($command.Parameters.ContainsKey('AppId')) {
    $removeArgs.AppId = $AppId
  } elseif ($command.Parameters.ContainsKey('GraphId')) {
    $removeArgs.GraphId = $AppId
  } else {
    throw 'The installed Remove-WtWin32App command exposes neither -AppId nor -GraphId.'
  }
  # Echter Vorwaertsbezug ueber eine Teilgrenze: der Trichter steht in 35-Packaging, diese Datei
  # laedt davor. NUR dafuer ist ein Get-Command-Gatter berechtigt (siehe PATTERNS.md) - und die
  # Unit-Tests, die diese Funktion einzeln aus der Quelle laden, kommen so ohne echten Runspace aus.
  if (Get-Command Invoke-WtModuleCallOffThread -ErrorAction SilentlyContinue) {
    $off = Invoke-WtModuleCallOffThread -CommandName $command.Name -Arguments $removeArgs -Label ("delete {0}" -f $AppId)
    if ($off.Ran) { return $off.Result }
    Write-Log ("Deleting {0} on the UI thread (no background runspace); the window will not respond until it finishes." -f $AppId)
  }
  & $command @removeArgs
}

function Get-PreviousWingetVersion {
  param([string]$PackageId, [string]$LatestVersion)

  $allVersions = @(Get-WingetVersions -PackageId $PackageId)
  if (-not $allVersions -or $allVersions.Count -eq 0) { return $null }

  $candidates = @($allVersions | Where-Object { -not (Test-VersionsEquivalent -Left ([string]$_) -Right $LatestVersion) })
  if ($candidates.Count -gt 0) { return $candidates[0] }
  return $null
}

# Word-set similarity as a Jaccard index (shared words / total distinct words), 0..100.
#
# The denominator MUST be the union, not [math]::Min: with Min, any name that is a subset of another
# scored 100 ("Adobe Acrobat" vs "Adobe Acrobat Reader DC"), so a shorter, WRONG candidate could
# overbid the correct longer match and be auto-resolved as the WinGet package. Union makes a subset
# score by how much it actually overlaps, so identical names = 100 and disjoint names = 0.
function Get-StringSimilarity {
  param($str1, $str2)
  if (-not $str1 -or -not $str2) { return 0 }
  $clean1 = $str1.ToLower() -replace '[^\w\s]', ' '
  $clean2 = $str2.ToLower() -replace '[^\w\s]', ' '
  $set1 = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($clean1 -split '\s+' | Where-Object { $_.Trim() -ne '' }), [StringComparer]::OrdinalIgnoreCase)
  $set2 = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($clean2 -split '\s+' | Where-Object { $_.Trim() -ne '' }), [StringComparer]::OrdinalIgnoreCase)
  if ($set1.Count -eq 0 -or $set2.Count -eq 0) { return 0 }

  $intersection = [System.Collections.Generic.HashSet[string]]::new($set1, [StringComparer]::OrdinalIgnoreCase)
  $intersection.IntersectWith($set2)
  $union = [System.Collections.Generic.HashSet[string]]::new($set1, [StringComparer]::OrdinalIgnoreCase)
  $union.UnionWith($set2)
  return [math]::Round(($intersection.Count / $union.Count) * 100)
}


# Counts how many app objects really have a newer version available.
#
# This exists because the dashboard tile and the update scan were answering two DIFFERENT questions
# with the same word. The tile asked Intune ("-Update $true", i.e. Intune's own UpdateAvailable
# flag); the scan compares the deployed version against the newest one WinTuner and WinGet know
# about. The two numbers can differ by any amount, and the tile is the first number anyone sees.
#
# It uses exactly the helpers the scan uses - Resolve-WingetIdForApp, Get-FreshLatestPackageVersion,
# Test-IsNewerVersion, Find-NewerTenantPackageTarget - so the VERDICT on a single app cannot drift
# apart from the scan's. What it deliberately does not do is the scan's other work: resolving upload
# targets, grouping predecessors, marking blocked rows. A tile needs a number, not a work list.
#
# Returns a hashtable so nothing is silently unaccounted for:
#   Outdated              - a newer version exists and Intune does not already have it
#   UpToDate              - checked, nothing newer
#   AlreadyNewerInTenant  - newer version exists but is ALREADY deployed, so there is nothing to do
#   NoWingetId            - no package id could be resolved, so it cannot be compared at all
#   Failed                - the lookup itself failed
#   Checked               - how many were actually looked at
# Outdated + UpToDate + AlreadyNewerInTenant + NoWingetId + Failed == Checked, by construction.
# Die Bilanz der Suche: jedes App-Objekt aus dem Inventar taucht genau einmal auf.
#
# Herausgezogen, weil die Rechnung inline falsch war und niemand es sehen konnte: die Apps ohne
# WinGet-Id wurden auch als "check failed" gezaehlt, zweimal abgezogen, und "aktuell" kam auf null.
# Als reine Funktion laesst sich das pruefen, ohne einen Tenant zu befragen - und Balanced sagt,
# ob die Zeile ueberhaupt aufgeht.
function Measure-ScanReconciliation {
  param(
    [Parameter(Mandatory)][int]$InventoryCount,
    [Parameter(Mandatory)][int]$OutdatedCount,
    [Parameter(Mandatory)][int]$NoWingetIdCount,
    [Parameter(Mandatory)][int]$FailedCount,
    [Parameter(Mandatory)][int]$IncompleteCount
  )
  $upToDate = $InventoryCount - $IncompleteCount - $OutdatedCount - $NoWingetIdCount - $FailedCount
  [pscustomobject]@{
    UpToDate = $upToDate
    # Negativ heisst: irgendetwas wurde doppelt gezaehlt. Das ist keine Kosmetik - eine uebersehene
    # App sieht im Fenster genauso aus wie eine aktuelle.
    Balanced = ($upToDate -ge 0)
  }
}

function Measure-AvailableUpdates {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Apps,
    # Called per app so a caller with a progress bar can show movement. Kept optional: the dashboard
    # has no bar of its own.
    [scriptblock]$OnProgress
  )
  $out = @{ Outdated = 0; UpToDate = 0; AlreadyNewerInTenant = 0; NoWingetId = 0; Failed = 0; Checked = 0 }
  $usable = @($Apps | Where-Object { $_ -and $_.CurrentVersion -and $_.GraphId })
  if ($usable.Count -eq 0) { return $out }

  # Resolved once per app up front, exactly as the scan does - Find-NewerTenantPackageTarget needs
  # the whole map to answer "is a newer version already in the tenant".
  $resolvedIds = @{}
  foreach ($a in $usable) {
    try { $resolvedIds[[string]$a.GraphId] = [string](Resolve-WingetIdForApp -App $a) }
    catch { $resolvedIds[[string]$a.GraphId] = '' }
  }

  # One lookup per PACKAGE, not per app: several deployed versions of the same product share it.
  $freshByPackageId = @{}
  $index = 0
  foreach ($app in $usable) {
    $index++
    $out.Checked++
    if ($OnProgress) { try { & $OnProgress $index $usable.Count ([string]$app.Name) } catch { } }

    $wingetId = [string]$resolvedIds[[string]$app.GraphId]
    if ([string]::IsNullOrWhiteSpace($wingetId)) { $out.NoWingetId++; continue }
    try {
      $cacheKey = $wingetId.ToLowerInvariant()
      if (-not $freshByPackageId.ContainsKey($cacheKey)) {
        $freshByPackageId[$cacheKey] = Get-FreshLatestPackageVersion -PackageId $wingetId
      }
      $fresh = $freshByPackageId[$cacheKey]
      if (-not $fresh -or -not $fresh.Latest) { $out.Failed++; continue }
      $latest = [string]$fresh.Latest
      if (-not (Test-IsNewerVersion $latest $app.CurrentVersion)) { $out.UpToDate++; continue }
      # A newest version Intune ALREADY holds is not an outstanding update - counting it would make
      # the tile demand an upload that could only produce a duplicate.
      #
      # Two ways it can already be there, and BOTH have to be checked. Find-NewerTenantPackageTarget
      # only matches something STRICTLY newer than $latest; the ordinary case is the tenant holding
      # exactly $latest, which needs the equal-version lookup. Missing that counted every already
      # updated product as outstanding again.
      $alreadyThere = $false
      $tenantNewer = Find-NewerTenantPackageTarget -Apps $usable -PackageId $wingetId -Version $latest `
        -ExcludeGraphId ([string]$app.GraphId) -ResolvedIds $resolvedIds
      if ($tenantNewer -and $tenantNewer.GraphId) {
        $alreadyThere = $true
      } else {
        try {
          $sameVersion = Find-ExistingUpdateTarget -Apps $usable -PackageId $wingetId -Version $latest `
            -ExcludeGraphId ([string]$app.GraphId) -ResolvedIds $resolvedIds
          if ($sameVersion -and $sameVersion.GraphId) { $alreadyThere = $true }
        } catch {
          # Ambiguous means several objects carry that package id AND version - it is emphatically
          # present, just messily. Either way it is not a missing upload.
          $alreadyThere = $true
        }
      }
      if ($alreadyThere) { $out.AlreadyNewerInTenant++ } else { $out.Outdated++ }
    } catch {
      $out.Failed++
    }
  }
  return $out
}

function Show-VersionPickerDialog {
  param([string]$Title,[string[]]$Versions)
  $f = New-Object System.Windows.Forms.Form
  $f.Text = $Title
  $f.Size = New-Object System.Drawing.Size(400,500)
  $lb = New-Object System.Windows.Forms.ListBox
  $lb.Location = New-Object System.Drawing.Point(10,10)
  $lb.Size = New-Object System.Drawing.Size(360,400)
  foreach ($v in @($Versions)) { [void]$lb.Items.Add($v) }
  if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = Get-UiString 'OkButton'
  $ok.Location = New-Object System.Drawing.Point(210,420)
  $ok.Add_Click({ $f.Tag = $lb.SelectedItem; $f.DialogResult = [System.Windows.Forms.DialogResult]::OK; $f.Close() })
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = Get-UiString 'CancelButton'
  $cancel.Location = New-Object System.Drawing.Point(290,420)
  $cancel.Add_Click({ $f.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $f.Close() })
  $f.Controls.Add($lb)
  $f.Controls.Add($ok)
  $f.Controls.Add($cancel)
  [void]$f.ShowDialog()
  return [string]$f.Tag
}

# ---------------------------------------------------------------------------------------------
# Background packaging
#
# New-WtWingetPackage is the one call that blocks for minutes (download + building the .intunewin).
# Running it on the UI thread is what made the window go "Not responding" mid-batch. It needs NO
# Graph context - only Deploy-WtWin32App does - so it can safely run in a background runspace while
# the UI thread keeps pumping messages.
#
# Deliberately NOT a BackgroundWorker: a worker thread has no PowerShell runspace, which is exactly
# why the earlier dashboard attempt failed. A dedicated runspace has its own module state.
#
# Side effect worth having: the WinTuner module's internal .NET logger writes into the host of ITS
# runspace, so the "[ERROR] Write log to PowerShell failed: WriteObject ... same thread" noise no
# longer lands in our UI host.
#
# The runspace is created once and reused - importing the module costs several seconds.
$script:pkgRunspace = $null
$script:packagingBusy = $false

# --- Direct Store app creation over Graph ---
# Deploy-WtMsStoreApp goes through the Graph .NET SDK. In this GUI that call fails reproducibly
# with a retried "ServiceUnavailable", while the very same tenant answers our own Invoke-RestMethod
# calls (inventory, assignments) without a single hiccup from the same UI thread. The difference is
# the SDK's async pipeline running under a WinForms SynchronizationContext, not the tenant.
#
# Creating a winGetApp is a single plain POST, so the fallback below does exactly that. It is only
# used after the module call failed, so nothing that already works changes.

# Title and publisher come from the public Store catalog - the same source winget uses. Both are
# required by Graph and are not part of the search result.
function Get-MsStoreCatalogInfo {
  param([Parameter(Mandatory)][string]$PackageIdentifier)
  $culture = [Globalization.CultureInfo]::CurrentUICulture
  $market = 'US'; $language = 'en-us'
  try {
    if ($culture.Name -match '^[a-z]{2}-([A-Z]{2})$') { $market = $Matches[1]; $language = $culture.Name.ToLowerInvariant() }
  } catch { }
  $attempts = @(
    @{ Market = $market; Language = $language },
    @{ Market = 'US';    Language = 'en-us' }   # every product is listed in the US catalogue
  )
  foreach ($a in $attempts) {
    try {
      $uri = "https://displaycatalog.mp.microsoft.com/v7.0/products/$PackageIdentifier`?market=$($a.Market)&languages=$($a.Language)&fieldsTemplate=Details"
      $response = Invoke-RestMethod -Uri $uri -TimeoutSec 30 -ErrorAction Stop
      $localized = @($response.Product.LocalizedProperties)[0]
      $title = [string]$localized.ProductTitle
      $publisher = [string]$localized.PublisherName
      if (-not $publisher) { $publisher = [string]$localized.DeveloperName }
      if ($title) {
        return [pscustomobject]@{ DisplayName = $title; Publisher = $publisher; Description = [string]$localized.ProductDescription }
      }
    } catch {
      Write-LogDebug ("Store catalogue lookup failed for {0} ({1}/{2}): {3}" -f $PackageIdentifier, $a.Market, $a.Language, $_.Exception.Message)
    }
  }
  return $null
}

# Creates the winGetApp itself. Returns the new Graph object so the caller can resolve and assign
# it exactly as it would after a successful module call.
function New-TenantStoreAppViaGraph {
  param(
    [Parameter(Mandatory)][string]$PackageIdentifier,
    [string]$DisplayName,
    [string]$Publisher,
    [string[]]$Categories,
    # Store apps install in the user context by default; that is also what the Intune portal
    # pre-selects. Kept as a parameter so a system-context app can be handled later.
    [ValidateSet('user', 'system')][string]$RunAsAccount = 'user'
  )
  $token = Get-WtToken -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

  # The catalogue is queried for publisher and description regardless, so the app does not appear
  # in Intune with an empty publisher and no description the way a bare payload would leave it.
  $info = Get-MsStoreCatalogInfo -PackageIdentifier $PackageIdentifier
  if ($info) {
    if (-not $DisplayName) { $DisplayName = $info.DisplayName }
    if (-not $Publisher)   { $Publisher = $info.Publisher }
  }
  if (-not $DisplayName) { $DisplayName = $PackageIdentifier }
  if (-not $Publisher)   { $Publisher = 'Microsoft Store' }

  $body = @{
    '@odata.type'       = '#microsoft.graph.winGetApp'
    displayName         = $DisplayName
    publisher           = $Publisher
    packageIdentifier   = $PackageIdentifier
    installExperience   = @{ runAsAccount = $RunAsAccount }
  }
  # Intune caps the description; the Store text can be far longer than that.
  if ($info -and $info.Description) {
    $description = [string]$info.Description
    if ($description.Length -gt 1000) { $description = $description.Substring(0, 997) + '...' }
    $body.description = $description
  }
  if ($Categories -and $Categories.Count -gt 0) {
    $body.categories = @($Categories | ForEach-Object { @{ '@odata.type' = '#microsoft.graph.mobileAppCategory'; displayName = [string]$_ } })
  }

  $json = $body | ConvertTo-Json -Depth 8
  Write-Log ("Creating Store app directly over Graph: '{0}' ({1}), publisher '{2}', runAs {3}." -f $DisplayName, $PackageIdentifier, $Publisher, $RunAsAccount)
  # -MaxRetries 0: dieser POST LEGT EINE APP AN. Bei einem Zeitablauf ist unbekannt, ob Intune sie
  # schon erzeugt hat, und ein zweiter Versuch erzeugte eine zweite Store-App im Tenant.
  $created = Invoke-GraphRest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps' `
    -Headers $headers -Body $json -MaxRetries 0 -Context ("create Store app {0}" -f $PackageIdentifier)
  Clear-Win32AppsCache   # a new app exists; a cached inventory would not contain it
  Write-Log ("Store app created over Graph: {0}" -f [string]$created.id)
  return $created
}

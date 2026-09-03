# Helper: resolve Winget Package Identifier across possible property names
function Resolve-WtWingetId {
    param([object]$AppOrResult)

    if (-not $AppOrResult) { return $null }
    # Do NOT consider Graph 'Id' as Winget Id
    foreach ($prop in 'PackageId','PackageID','WingetId','PackageIdentifier') {
        $p = $AppOrResult.PSObject.Properties[$prop]
        if ($p -and $AppOrResult.$prop) { return [string]$AppOrResult.$prop }
    }
    if ($AppOrResult -is [hashtable]) {
        foreach ($prop in 'PackageId','PackageID','WingetId','PackageIdentifier') {
            if ($AppOrResult.ContainsKey($prop) -and $AppOrResult[$prop]) { return [string]$AppOrResult[$prop] }
        }
    }
    return $null
}

# Load the modern Microsoft Store apps already present in Intune. These are Graph winGetApp
# resources; packageIdentifier is the Store/WinGet identity and is the reliable duplicate key.
# The query is deliberately fresh whenever deployment is attempted so another administrator's
# recent change cannot slip through a stale GUI cache.
function Get-TenantStoreApps {
  $token = Get-WtToken -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  # Microsoft documents list-winGetApps on the base mobileApps collection. Some tenants reject the
  # derived-type path (/microsoft.graph.winGetApp) or a $select containing derived properties with
  # HTTP 400. Page the compatible base endpoint and filter @odata.type locally instead.
  $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=100"
  $result = [System.Collections.Generic.List[object]]::new()
  # Bounded like Get-GraphCollectionItems. A nextLink chain that never ends - a service fault, or a
  # cursor that keeps handing back the same page - would otherwise loop forever on the UI thread,
  # with a window that only looks frozen. 100 pages of 100 is far beyond any real tenant.
  $maxPages = 100
  $page = 0
  do {
    $page++
    if ($page -gt $maxPages) { throw "Graph pagination exceeded $maxPages pages while listing Store apps." }
    # -MaxRetries 0: die Aufrufer dieser Inventarwege haben ihre EIGENE Wiederholungsschleife
    # (Get-Win32AppsResilient, Get-CachedWin32Apps). Zwei Ebenen Wiederholung multiplizieren sich -
    # drei aeussere Versuche mal drei innere mal bis zu 30 s Pause waeren Minuten Wartezeit fuer
    # eine Liste. Geholt wird hier der Zeitablauf, und der war das Loch.
    $response = Invoke-GraphRest -Method GET -Uri $uri -Headers $headers -MaxRetries 0 `
      -Context ("Store app inventory (page {0})" -f $page)
    foreach ($app in @($response.value)) {
      if (-not $app -or -not $app.id) { continue }
      $odataType = [string]$app.'@odata.type'
      if (-not [string]::Equals($odataType.TrimStart([char]'#'), 'microsoft.graph.winGetApp', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      $result.Add([pscustomobject]@{
        Id                = [string]$app.id
        DisplayName       = [string]$app.displayName
        PackageIdentifier = [string]$app.packageIdentifier
        Publisher         = [string]$app.publisher
        PublishingState   = [string]$app.publishingState
        IsAssigned        = [bool]$app.isAssigned
      })
    }
    $uri = [string]$response.'@odata.nextLink'
  } while (-not [string]::IsNullOrWhiteSpace($uri))
  return @($result.ToArray())
}

# Every Win32 app in the tenant, not just the ones WinTuner made.
#
# Get-WtWin32Apps cannot answer this question: the module filters server-side on
# contains(notes,'[WinTuner|') or contains(notes,'[WingetIntune|'), so an app created any other way -
# including by this GUI's own "own installer" card, which writes no such marker - is invisible to it.
# The "replace the content of an existing app" list was built on that call and therefore could not
# offer the very apps this GUI had just created, pushing the user into creating a duplicate instead:
# exactly what Update-ExistingAppContent exists to prevent.
#
# The marker is deliberately NOT written on creation instead. A '[WinTuner|' prefix would pull these
# apps into the update scan, the version cleanup and the deletion paths as well, and all three expect
# a resolvable WinGet PackageId that a hand-built app does not have. Reading the collection directly
# fixes the one broken list without touching those.
#
# Paged like Get-TenantStoreApps, and type-filtered locally for the same reason documented there.
# Shaped like the module's objects (Name / CurrentVersion / GraphId) so callers do not care which
# source they got.
function Get-TenantWin32Apps {
  $token = Get-WtToken -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=100"
  $result = [System.Collections.Generic.List[object]]::new()
  $maxPages = 100
  $page = 0
  do {
    $page++
    if ($page -gt $maxPages) { throw "Graph pagination exceeded $maxPages pages while listing Win32 apps." }
    # -MaxRetries 0: siehe oben, der Aufrufer wiederholt selbst.
    $response = Invoke-GraphRest -Method GET -Uri $uri -Headers $headers -MaxRetries 0 `
      -Context ("Win32 app inventory (page {0})" -f $page)
    foreach ($app in @($response.value)) {
      if (-not $app -or -not $app.id) { continue }
      $odataType = [string]$app.'@odata.type'
      if (-not [string]::Equals($odataType.TrimStart([char]'#'), 'microsoft.graph.win32LobApp', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      $result.Add([pscustomobject]@{
        Name           = [string]$app.displayName
        CurrentVersion = [string]$app.displayVersion
        GraphId        = [string]$app.id
        Publisher      = [string]$app.publisher
        IsAssigned     = [bool]$app.isAssigned
        # Empty for anything this GUI or a human created by hand; that is the point of this read.
        WinTunerNotes  = [string]$app.notes
      })
    }
    $uri = [string]$response.'@odata.nextLink'
  } while (-not [string]::IsNullOrWhiteSpace($uri))
  Write-Log ("Tenant Win32 app list read directly from Graph: {0} app(s) over {1} page(s)." -f $result.Count, $page)
  return @($result.ToArray())
}

# Find Store apps that make a new SearchQuery deployment unsafe. An exact package id or display
# name is authoritative. For a textual query, contains matches are also shown/blocked because
# Deploy-WtMsStoreApp itself selects the FIRST search result; without resolving that external
# result first, continuing could create the already-present app under a broad query such as
# "portal". The user can enter the exact Store package id when a different result is intended.
function Find-TenantStoreAppMatch {
  param([Parameter(Mandatory)][object[]]$Apps, [Parameter(Mandatory)][string]$Query)
  $q = $Query.Trim()
  if (-not $q) { return @() }
  $exact = @($Apps | Where-Object {
    [string]::Equals([string]$_.PackageIdentifier, $q, [System.StringComparison]::OrdinalIgnoreCase) -or
    [string]::Equals([string]$_.DisplayName, $q, [System.StringComparison]::OrdinalIgnoreCase)
  })
  if ($exact.Count -gt 0) { return $exact }
  return @($Apps | Where-Object {
    ([string]$_.DisplayName).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
    ([string]$_.PackageIdentifier).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
  })
}

function Resolve-WingetIdForApp {
  param([object]$App)

  if (-not $App -or [string]::IsNullOrWhiteSpace([string]$App.Name)) { return $null }

  # A saved override is authoritative. This is especially useful where the Intune display name
  # differs from the WinGet package name (for example a vendor suffix or installer type).
  if ($App -and $App.Name -and $script:settings.WingetOverrides) {
    $appName = ([string]$App.Name).Trim()
    foreach ($overrideName in @($script:settings.WingetOverrides.Keys)) {
      if ([string]::Equals(([string]$overrideName).Trim(), $appName, [System.StringComparison]::OrdinalIgnoreCase)) {
        $overrideId = [string]$script:settings.WingetOverrides[$overrideName]
        if (-not [string]::IsNullOrWhiteSpace($overrideId)) {
          Write-Log ("Using WinGet override for {0}: {1}" -f $appName, $overrideId.Trim())
          return $overrideId.Trim()
        }
      }
    }
  }

  $id = Resolve-WtWingetId -AppOrResult $App
  if (-not [string]::IsNullOrWhiteSpace($id)) { return $id }
  try {
    $res = @(Search-WtWinGetPackage -SearchQuery $App.Name -ErrorAction Stop)
  } catch {
    Write-Log ("WinGet package search failed for {0}: {1}" -f $App.Name, $_.Exception.Message)
    $res = @()
  }
  if ($res -and $res.Count -gt 0) {
    # An arbitrary first search hit is unsafe in an update workflow: a fuzzy vendor/product match
    # could package the wrong application and supersede the real one in Intune. Accept an exact
    # display-name match, or one clearly dominant high-confidence match; otherwise require an
    # explicit WingetOverrides mapping in settings.json.
    $exact = @($res | Where-Object { $_.Name -and [string]::Equals([string]$_.Name, [string]$App.Name, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($exact.Count -eq 1) {
      $exactId = Resolve-WtWingetId -AppOrResult $exact[0]
      if ($exactId) { return $exactId }
    }

    $scored = @($res | ForEach-Object {
      $candidateId = Resolve-WtWingetId -AppOrResult $_
      if ($candidateId) {
        [pscustomobject]@{ Item = $_; Id = $candidateId; Score = (Get-StringSimilarity ([string]$App.Name) ([string]$_.Name)) }
      }
    } | Sort-Object Score -Descending)
    if ($scored.Count -gt 0) {
      $runnerUp = if ($scored.Count -gt 1) { [int]$scored[1].Score } else { 0 }
      if ([int]$scored[0].Score -ge 80 -and ([int]$scored[0].Score - $runnerUp) -ge 15) {
        Write-Log ("Resolved WinGet id by high-confidence name match for {0}: {1} (score {2})" -f $App.Name, $scored[0].Id, $scored[0].Score)
        return [string]$scored[0].Id
      }
    }
    Write-Log ("No safe WinGet match for '{0}' ({1} result(s)); add a WingetOverrides mapping instead of guessing." -f $App.Name, $res.Count)
  }
  return $null
}

# Reads the "Assign to" ComboBox + optional group-id TextBox and returns the value to
# pass as Deploy-WtWin32App's -AvailableFor, or $null if the app should stay unassigned.
# The four fixed entries of every assignment target combo, in the order Update-AssignTargetCombo
# builds them. Saved favorites follow from index 4 onwards.
$script:assignTargetIndexNotAssigned = 0
$script:assignTargetIndexAllUsers    = 1
$script:assignTargetIndexAllDevices  = 2
$script:assignTargetIndexCustomGroup = 3
$script:assignTargetFixedEntryCount  = 4

# Pure core of the selection: index in, target out. Kept free of WinForms so it can be tested.
#
# This used to compare $TargetCombo.SelectedItem against Get-UiString 'AssignAllUsers' and friends.
# The combo's items are built once, in the language active at that moment, while Get-UiString answers
# in the language active NOW - so after switching language at runtime nothing matched any more, the
# function fell through to its final "return $null", and an app the user had explicitly pointed at
# All Users was deployed with no assignment at all. Nothing failed and nothing was logged.
# The index carries the same meaning in every language, and the rest of this file already relies on
# it (index 3 == custom group, >= 4 == favorite).
function Resolve-AssignmentTargetFromIndex {
  param(
    [Parameter(Mandatory)][int]$Index,
    [string]$GroupId = '',
    [string[]]$FavoriteIds = @()
  )
  if ($Index -eq $script:assignTargetIndexAllUsers)   { return 'AllUsers' }
  if ($Index -eq $script:assignTargetIndexAllDevices) { return 'AllDevices' }
  if ($Index -eq $script:assignTargetIndexCustomGroup) {
    $gid = ([string]$GroupId).Trim()
    if ([string]::IsNullOrWhiteSpace($gid)) { return $null }
    return $gid
  }
  if ($Index -ge $script:assignTargetFixedEntryCount) {
    $favIndex = $Index - $script:assignTargetFixedEntryCount
    if ($favIndex -ge 0 -and $favIndex -lt $FavoriteIds.Count) {
      $favId = [string]$FavoriteIds[$favIndex]
      if (-not [string]::IsNullOrWhiteSpace($favId)) { return $favId }
    }
  }
  # Index 0 ("not assigned"), -1 (nothing selected) and a favorite that no longer exists all mean
  # the same thing: deploy without an assignment.
  return $null
}

function Get-SelectedAssignmentTarget {
  param(
    [Parameter(Mandatory=$true)][System.Windows.Forms.ComboBox]$TargetCombo,
    [Parameter(Mandatory=$true)][System.Windows.Forms.TextBox]$GroupIdBox
  )
  # The id of a favorite comes from the stored favorite, never from the text box, which is hidden
  # for those entries.
  $favoriteIds = @(@(Get-GroupFavorites) | ForEach-Object { [string]$_.Id })
  return Resolve-AssignmentTargetFromIndex -Index ([int]$TargetCombo.SelectedIndex) `
    -GroupId ([string]$GroupIdBox.Text) -FavoriteIds $favoriteIds
}

# Resolves a favorite entry selected in a target combo back to its group id, or "" for any of the
# four fixed entries. Kept separate so the validation paths can ask "is this a group?" without
# duplicating the index arithmetic.
function Get-FavoriteIdForSelection {
  param([Parameter(Mandatory=$true)][System.Windows.Forms.ComboBox]$TargetCombo)
  $idx = [int]$TargetCombo.SelectedIndex
  if ($idx -lt 4) { return "" }
  $favorites = @(Get-GroupFavorites)
  $favIndex = $idx - 4
  if ($favIndex -lt 0 -or $favIndex -ge $favorites.Count) { return "" }
  return [string]$favorites[$favIndex].Id
}

# True when the selection targets a specific Entra group - either the manual "custom group" entry
# or a saved favorite. The exclude/filter validation needs this: excluding requires a group, and a
# favorite is just as much a group as a pasted GUID.
function Test-IsGroupSelection {
  param([Parameter(Mandatory=$true)][System.Windows.Forms.ComboBox]$TargetCombo)
  if ([int]$TargetCombo.SelectedIndex -eq 3) { return $true }
  return [bool](Get-FavoriteIdForSelection -TargetCombo $TargetCombo)
}

# Rebuilds a target combo: the four fixed entries plus this tenant's favorites. Called after login
# and whenever the favorites change, for every combo that picks an assignment target.
function Update-AssignTargetCombo {
  param([System.Windows.Forms.ComboBox]$TargetCombo)
  if (-not $TargetCombo) { return }
  # Remember the selection by IDENTITY, not by the text on screen. Matching the display text back
  # meant two things went wrong: after a language switch nothing matched (harmless - falls back to
  # "not assigned"), and two tenants whose favorites share a name - "Pilot", "Test" and "IT" are
  # everyday names at an MSP - matched each other, so the combo silently pointed at a DIFFERENT
  # customer's group while looking unchanged. That is the outcome the comment below promises not to
  # produce.
  $previousIndex = [int]$TargetCombo.SelectedIndex
  $previousFavoriteId = if ($previousIndex -ge $script:assignTargetFixedEntryCount) {
    $oldFavorites = @(Get-GroupFavorites)
    $oldFavIndex = $previousIndex - $script:assignTargetFixedEntryCount
    if ($oldFavIndex -ge 0 -and $oldFavIndex -lt $oldFavorites.Count) { [string]$oldFavorites[$oldFavIndex].Id } else { '' }
  } else { '' }

  $TargetCombo.BeginUpdate()
  try {
    $TargetCombo.Items.Clear()
    [void]$TargetCombo.Items.AddRange(@(
      (Get-UiString 'AssignNotAssigned'), (Get-UiString 'AssignAllUsers'),
      (Get-UiString 'AssignAllDevices'), (Get-UiString 'AssignCustomGroup')))
    $favorites = @(Get-GroupFavorites)
    foreach ($f in $favorites) {
      [void]$TargetCombo.Items.Add(((Get-UiString 'AssignFavoriteEntry') -f [string]$f.Name))
    }
    # Restore the previous choice when it still exists; otherwise fall back to "not assigned"
    # rather than silently landing on a different group after a tenant switch.
    $restore = -1
    if ($previousFavoriteId) {
      # A favorite is only the same favorite if its group id is the same one.
      for ($i = 0; $i -lt $favorites.Count; $i++) {
        if ([string]::Equals([string]$favorites[$i].Id, $previousFavoriteId, [System.StringComparison]::OrdinalIgnoreCase)) {
          $restore = $script:assignTargetFixedEntryCount + $i
          break
        }
      }
    } elseif ($previousIndex -gt 0 -and $previousIndex -lt $script:assignTargetFixedEntryCount) {
      # One of the fixed entries: the index means the same thing in every language.
      $restore = $previousIndex
    }
    $TargetCombo.SelectedIndex = if ($restore -ge 0 -and $restore -lt $TargetCombo.Items.Count) { $restore } else { 0 }
  } finally { $TargetCombo.EndUpdate() }
}

# Housekeeping bounds for the on-disk version cache. Reads already refuse anything older than six
# hours (see Get-WingetVersions), so an expired entry can never be SERVED - but nothing ever removed
# one either, and the file grew for the lifetime of the installation, one entry per package ever
# looked up. These two limits keep it to what is actually useful.
$script:versionCacheMaxAgeDays = 7
$script:versionCacheMaxEntries = 2000

# Steht auf $true, sobald ein Paket neue Versionen geliefert hat und die Datei noch nicht
# nachgezogen wurde. Geschrieben wird erst, wenn eine Schleife fertig ist - siehe
# Save-PendingVersionDiskCache.
$script:diskCacheDirty = $false

# Pure so the pruning rules can be tested without touching the disk or the clock.
function Select-LiveVersionCacheEntries {
  param(
    [Parameter(Mandatory)][hashtable]$Cache,
    [datetime]$Now = [datetime]::UtcNow,
    [int]$MaxAgeDays = $script:versionCacheMaxAgeDays,
    [int]$MaxEntries = $script:versionCacheMaxEntries
  )
  $kept = @{}
  $candidates = [System.Collections.Generic.List[object]]::new()
  foreach ($key in @($Cache.Keys)) {
    $entry = $Cache[$key]
    if (-not $entry -or -not $entry.timestamp) { continue }
    $stamp = [datetime]$entry.timestamp
    if ($MaxAgeDays -gt 0) {
      $ageDays = ($Now - $stamp.ToUniversalTime()).TotalDays
      if ($ageDays -gt $MaxAgeDays) { continue }
      # A timestamp in the future means a clock change or a hand-edited file; treating it as fresh
      # would pin a stale entry forever, so it goes too.
      if ($ageDays -lt -1) { continue }
    }
    $candidates.Add([pscustomobject]@{ Key = $key; Stamp = $stamp; Entry = $entry })
  }
  # Newest first, so a cap keeps what is most likely to still be asked for.
  $ordered = @($candidates | Sort-Object -Property Stamp -Descending)
  if ($MaxEntries -gt 0 -and $ordered.Count -gt $MaxEntries) {
    $ordered = @($ordered | Select-Object -First $MaxEntries)
  }
  foreach ($c in $ordered) { $kept[$c.Key] = $c.Entry }
  return $kept
}

# Schreibt den Plattencache, wenn seit dem letzten Schreiben etwas dazugekommen ist.
#
# Der Gegenpart zu $script:diskCacheDirty: Get-WingetVersions sammelt nur noch, das Schreiben macht
# der Aufrufer EINMAL, wenn seine Schleife durch ist. Aufgerufen am Ende der Update-Suche, nach dem
# Dashboard-Vollscan und beim Schliessen des Fensters. Zusaetzliche Aufrufstellen sind unschaedlich -
# ohne Aenderung tut die Funktion nichts.
function Save-PendingVersionDiskCache {
  if (-not $script:diskCacheDirty) { return $false }
  Save-VersionDiskCache -Cache $script:diskCache
  $script:diskCacheDirty = $false
  return $true
}

function Get-VersionDiskCache {
  if (-not $script:versionCachePath) { return @{} }
  try {
    if (Test-Path -LiteralPath $script:versionCachePath) {
      $raw = Get-Content -LiteralPath $script:versionCachePath -Raw -Encoding utf8 -ErrorAction Stop
      $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
      $ht = @{}
      $skipped = 0
      foreach ($prop in $parsed.PSObject.Properties) {
        # One entry per try: a single unparseable timestamp used to throw out of the loop and
        # discard the ENTIRE cache, so one bad line cost every package's cached versions.
        try {
          $ht[$prop.Name] = @{
            versions  = @($prop.Value.versions)
            timestamp = [datetime]::Parse($prop.Value.timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
          }
        } catch { $skipped++ }
      }
      if ($skipped -gt 0) { Write-Log ("Version cache: skipped {0} unreadable entr(y/ies); the rest was kept." -f $skipped) }
      $live = Select-LiveVersionCacheEntries -Cache $ht
      $dropped = $ht.Count - $live.Count
      if ($dropped -gt 0) { Write-Log ("Version cache: dropped {0} entr(y/ies) past the {1}-day limit or over the {2}-entry cap." -f $dropped, $script:versionCacheMaxAgeDays, $script:versionCacheMaxEntries) }
      return $live
    }
  } catch {
    Write-Log "Warning: Could not read version cache: $($_.Exception.Message)"
  }
  return @{}
}

function Save-VersionDiskCache {
  param([hashtable]$Cache)
  if (-not $script:versionCachePath) { return }
  try {
    # Prune on the way out as well as on the way in, so a long-running session cannot write back a
    # file that has grown past the limits since it was loaded.
    $live = Select-LiveVersionCacheEntries -Cache $Cache
    $obj = @{}
    foreach ($key in $live.Keys) {
      $obj[$key] = @{
        versions  = $live[$key].versions
        timestamp = $live[$key].timestamp.ToString('o')
      }
    }
    # The cache moved from a loose file in LocalAppData into the application's own folder with the
    # rename to WinTuner GUI. That folder may not exist yet on a fresh profile, and Set-Content does
    # not create one - without this the cache silently never persisted and every search re-fetched.
    $cacheDir = Split-Path -Parent $script:versionCachePath
    if ($cacheDir -and -not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
      [void][System.IO.Directory]::CreateDirectory($cacheDir)
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:versionCachePath -Encoding utf8 -ErrorAction SilentlyContinue
  } catch {
    Write-Log "Warning: Could not save version cache: $($_.Exception.Message)"
  }
}

function Get-WingetVersions {
  param(
    [Parameter(Mandatory=$true)][string]$PackageId,
    [switch]$ForceRefresh
  )

  if ($ForceRefresh) {
    # A user-triggered update scan must reflect what is currently available. Both caches are
    # deliberately bypassed; a successful fresh result replaces the stored value below.
    if (-not $script:diskCacheLoaded) {
      $script:diskCache = Get-VersionDiskCache
      $script:diskCacheLoaded = $true
    }
    Write-Log "Refreshing available WinGet versions for $PackageId"
  }

  # 1) RAM cache
  if (-not $ForceRefresh -and $script:wingetVersionCache.ContainsKey($PackageId)) {
    return $script:wingetVersionCache[$PackageId]
  }

  # 2) Disk cache (TTL 6h) – loaded once per session
  if (-not $script:diskCacheLoaded) {
    $script:diskCache = Get-VersionDiskCache
    $script:diskCacheLoaded = $true
  }
  if (-not $ForceRefresh -and $script:diskCache.ContainsKey($PackageId)) {
    $entry = $script:diskCache[$PackageId]
    $ageHours = ([datetime]::UtcNow - $entry.timestamp.ToUniversalTime()).TotalHours
    if ($ageHours -lt 6 -and $entry.versions -and $entry.versions.Count -gt 0) {
      $script:wingetVersionCache[$PackageId] = $entry.versions
      Write-Log "Version cache hit (disk) for $PackageId (age: $([math]::Round($ageHours,1))h)"
      return $entry.versions
    }
  }

  # 3) Query winget
  try {
    $wingetOutput = @(& winget show --id $PackageId --exact --versions --accept-source-agreements --disable-interactivity 2>&1)
    $wingetExitCode = $LASTEXITCODE
  } catch {
    Write-Log ("WinGet version query failed for {0}: {1}" -f $PackageId, $_.Exception.Message)
    return @()
  }
  if ($wingetExitCode -ne 0) {
    $detail = (@($wingetOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()
    Write-Log ("WinGet version query failed for {0} (exit {1}): {2}" -f $PackageId, $wingetExitCode, $detail)
    return @()
  }
  if (-not $wingetOutput) {
    Write-Log "WinGet returned no version data for $PackageId"
    return @()
  }

  $cand = @()
  foreach ($line in @($wingetOutput)) {
    $t = ($line -replace '^[\s\-•]+','').Trim()
    if (-not $t) { continue }
    # Accept standard semantic versions and vendor formats such as "7.1.5 (43453)". Restrict the
    # character set and require a leading digit so localized headers/messages cannot become data.
    if ($t -match '^[vV]?\d[0-9A-Za-z.()+_\- ]*$' -and $t -match '\d') { $cand += $t }
  }

  $unique = @($cand | Select-Object -Unique)
  $sortedVersions = [System.Collections.Generic.List[string]]::new()
  foreach ($versionText in $unique) {
    $insertAt = $sortedVersions.Count
    for ($i = 0; $i -lt $sortedVersions.Count; $i++) {
      if (Test-IsNewerVersion -Latest $versionText -Current $sortedVersions[$i]) { $insertAt = $i; break }
    }
    $sortedVersions.Insert($insertAt, $versionText)
  }
  $result = @($sortedVersions)

  if ($result.Count -eq 0) {
    Write-Log "WinGet output for $PackageId contained no parseable versions"
    return @()
  }

  # 4) Store in RAM cache
  $script:wingetVersionCache[$PackageId] = $result

  # 5) In den Plattencache legen - aber NICHT sofort schreiben.
  #
  # Hier stand ein Save-VersionDiskCache je Paket, und das war die einzige Aufrufstelle. Eine
  # Update-Suche ueber 100 Apps schrieb damit 100 Mal die GANZE Tabelle: jedes Mal ein
  # Select-LiveVersionCacheEntries ueber alle Eintraege (Deckel 2000), ein ConvertTo-Json darueber
  # und eine vollstaendige Datei. Und das auf dem UI-Faden, zwischen zwei Netzabfragen.
  #
  # Der Inhalt liegt ohnehin in $script:diskCache; geschrieben wird jetzt, wenn eine Schleife fertig
  # ist und beim Schliessen (Save-PendingVersionDiskCache). Schlimmster Fall bei einem Abschuss der
  # Anwendung: die Zugewinne dieser Sitzung fehlen und eine Suche ist einmal langsamer - dieselbe
  # Risikoklasse wie bei den Einstellungen, die auch erst beim Beenden geschrieben werden.
  $script:diskCache[$PackageId] = @{
    versions  = $result
    timestamp = [datetime]::UtcNow
  }
  $script:diskCacheDirty = $true

  return $result
}

# Where the WinTuner module caches the community package index. Not our file - we only look at it,
# never write it. Measured: 3.2 MB, pulled from raw.githubusercontent.com.
$script:wingetIndexCachePath = Join-Path (Get-LocalAppDataRoot) 'WingetCommunityRepo\index.v2.json'

# Is the module about to download the package index rather than read it from disk?
#
# This matters because that download is synchronous and lands on the UI thread, so the window has no
# message pump for its whole duration and Windows paints it as "not responding". Measured on
# 2026-08-21: 130 seconds between "Prüfe Favorit (1/4)" and its result, with the cache file's
# LastWriteTime landing on the exact second the wait ended. The following favourites took ~1 s each.
#
# The module's own expiry rule is not readable from outside (it lives in IL, and the only hint is a
# "cache still valid" log message), so this is a heuristic: missing, empty, or older than a day.
# Being wrong is cheap in both directions - a false positive shows a notice for a fetch that turns
# out to be fast, a false negative just restores today's behaviour.
function Test-WingetIndexCacheCold {
  param([string]$CachePath = $script:wingetIndexCachePath, [int]$MaxAgeHours = 24)
  $result = [pscustomobject]@{ Cold = $true; Path = $CachePath; AgeHours = $null; Reason = 'missing' }
  try {
    $file = Get-Item -LiteralPath $CachePath -ErrorAction Stop
    if ($file.Length -le 0) { $result.Reason = 'empty'; return $result }
    $age = ([datetime]::Now - $file.LastWriteTime).TotalHours
    $result.AgeHours = [Math]::Round($age, 1)
    if ($age -gt $MaxAgeHours) { $result.Reason = 'stale'; return $result }
    $result.Cold = $false
    $result.Reason = 'fresh'
  } catch {
    # A path we cannot read is treated as cold: the notice is harmless, a silent freeze is not.
  }
  return $result
}

# Queries WinTuner's online package index directly. This is intentionally separate from the local
# `winget show` source: the online index can already know a new version while a workstation's
# configured WinGet source is stale (the TeamViewer case that prompted this change).
function Get-WtPackageIndexLatestVersion {
  param([Parameter(Mandatory)][string]$PackageId)
  try {
    $results = @(Search-WtWinGetPackage -SearchQuery $PackageId -ErrorAction Stop)
    $exact = @($results | Where-Object {
      $candidateId = Resolve-WtWingetId -AppOrResult $_
      $candidateId -and [string]::Equals($candidateId, $PackageId, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($exact.Count -eq 0) {
      Write-Log "WinTuner online index returned no exact package match for $PackageId"
      return $null
    }

    $latest = $null
    foreach ($item in $exact) {
      $value = $null
      foreach ($propertyName in 'Version','LatestVersion') {
        $property = $item.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
          $value = ([string]$property.Value).Trim()
          break
        }
      }
      if ($value -and (-not $latest -or (Test-IsNewerVersion -Latest $value -Current $latest))) { $latest = $value }
    }
    if ($latest) { Write-Log "WinTuner online index latest for $PackageId`: $latest" }
    return $latest
  } catch {
    Write-Log ("WinTuner online index query failed for {0}: {1}" -f $PackageId, $_.Exception.Message)
    return $null
  }
}

# Fresh update scans consult BOTH authoritative paths and pick the newer version. No GUI cache is
# used here. The returned object retains the per-source values so discrepancies are visible in the
# log instead of being silently treated as "no update".
# Kurzzeit-Zwischenspeicher fuer die teuerste Frage der Anwendung: "welche Version ist die neueste?"
#
# Jede Antwort kostet zwei Abfragen (WinTuner-Index + lokale WinGet-Quelle) und dauert 1-3 s. Beim
# Anmelden wurde sie ZWEIMAL je App gestellt: erst von der Dashboard-Kachel (voller Versionsvergleich),
# Sekunden spaeter von der automatischen Update-Suche - dieselben Pakete, dasselbe Ergebnis. Im
# Protokoll stehen die Zeilen "Refreshing available WinGet versions for X" deshalb doppelt.
#
# Fuenf Minuten sind lang genug, damit die zweite Runde frei ist, und kurz genug, dass niemand mit
# einer veralteten Antwort arbeitet. Wer ausdruecklich nachsieht (Knopf "Nach Updates suchen"),
# bekommt mit -Force garantiert eine frische Antwort.
$script:latestVersionCache = @{}
$script:latestVersionCacheSeconds = 300

function Clear-LatestVersionCache {
  $script:latestVersionCache = @{}
}

function Get-FreshLatestPackageVersion {
  param(
    [Parameter(Mandatory)][string]$PackageId,
    [switch]$Force
  )
  $cacheKey = ([string]$PackageId).Trim().ToLowerInvariant()
  if (-not $Force -and $script:latestVersionCache.ContainsKey($cacheKey)) {
    $entry = $script:latestVersionCache[$cacheKey]
    $age = ([datetime]::UtcNow - $entry.Time).TotalSeconds
    if ($age -lt $script:latestVersionCacheSeconds) {
      Write-LogDebug ("Latest version for {0} served from the session cache ({1:n0}s old)." -f $PackageId, $age)
      return $entry.Result
    }
  }
  # Announced here rather than at the three call sites (favourites, update scan, batch): this is the
  # one place they all pass through, and the guard inside makes every call after the first free.
  Initialize-WingetPackageIndex
  $moduleLatest = Get-WtPackageIndexLatestVersion -PackageId $PackageId
  Complete-WingetPackageIndexWarmup
  $wingetVersions = @(Get-WingetVersions -PackageId $PackageId -ForceRefresh)
  $wingetLatest = if ($wingetVersions.Count -gt 0) { [string]$wingetVersions[0] } else { $null }

  $latest = $moduleLatest
  $source = if ($moduleLatest) { 'WinTuner online index' } else { $null }
  if ($wingetLatest -and (-not $latest -or (Test-IsNewerVersion -Latest $wingetLatest -Current $latest))) {
    $latest = $wingetLatest
    $source = 'local WinGet source'
  }
  if ($moduleLatest -and $wingetLatest -and $moduleLatest -ne $wingetLatest) {
    Write-Log ("Version source mismatch for {0}: WinTuner index={1}, local WinGet={2}; using {3} from {4}." -f $PackageId, $moduleLatest, $wingetLatest, $latest, $source)
  }
  $result = [pscustomobject]@{
    Latest       = $latest
    Source       = $source
    ModuleLatest = $moduleLatest
    WingetLatest = $wingetLatest
  }
  # Auch ein leeres Ergebnis wird gemerkt: ein Paket ohne auffindbare Version findet auch die zweite
  # Abfrage zehn Sekunden spaeter nicht, und genau die kostete die Zeit.
  $script:latestVersionCache[$cacheKey] = @{ Time = [datetime]::UtcNow; Result = $result }
  return $result
}

# WinTuner stores built packages beneath <root>\<PackageId>\<Version>. Use those version folders
# as the local source of truth for favorites, matching the layout already produced by the module.
function Test-LocalPackageVersionComplete {
  param([Parameter(Mandatory)][string]$VersionFolder)
  try {
    if (-not (Test-Path -LiteralPath $VersionFolder -PathType Container)) { return $false }
    # A folder name alone is not proof of a completed build: canceled/failed downloads can leave
    # the version directory behind. Count only a non-empty deployable package artifact.
    $artifact = Get-ChildItem -LiteralPath $VersionFolder -File -Recurse -ErrorAction Stop |
      Where-Object { $_.Length -gt 0 -and $_.Extension -in @('.intunewin','.wtpackage') } |
      Select-Object -First 1
    return ($null -ne $artifact)
  } catch { return $false }
}

function Get-LocalFavoritePackageVersion {
  param([Parameter(Mandatory)][string]$PackageId, [Parameter(Mandatory)][string]$RootPackageFolder)
  try {
    $packageFolder = Join-Path $RootPackageFolder $PackageId
    if (-not (Test-Path -LiteralPath $packageFolder -PathType Container)) { return $null }
    $latest = $null
    foreach ($folder in @(Get-ChildItem -LiteralPath $packageFolder -Directory -ErrorAction Stop)) {
      $candidate = [string]$folder.Name
      if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
      if ($candidate -notmatch '^\s*[vV]?\d+(?:\.\d+)*') { continue }
      if (-not (Test-LocalPackageVersionComplete -VersionFolder $folder.FullName)) { continue }
      if (-not $latest -or (Test-IsNewerVersion -Latest $candidate -Current $latest)) { $latest = $candidate }
    }
    return $latest
  } catch {
    Write-Log ("Favorite local-version scan failed for {0}: {1}" -f $PackageId, $_.Exception.Message)
    return $null
  }
}

# Finds package IDs already maintained below the selected root. Only folders containing at least
# one numeric version subfolder qualify, so unrelated directories are never handed to WinTuner.
function Get-LocalPackageIds {
  param([Parameter(Mandatory)][string]$RootPackageFolder)
  $ids = [System.Collections.Generic.List[string]]::new()
  try {
    if (-not (Test-Path -LiteralPath $RootPackageFolder -PathType Container)) { return @() }
    foreach ($packageFolder in @(Get-ChildItem -LiteralPath $RootPackageFolder -Directory -ErrorAction Stop)) {
      $packageId = [string]$packageFolder.Name
      if ([string]::IsNullOrWhiteSpace($packageId)) { continue }
      $hasVersionFolder = $false
      foreach ($versionFolder in @(Get-ChildItem -LiteralPath $packageFolder.FullName -Directory -ErrorAction SilentlyContinue)) {
        if ([string]$versionFolder.Name -match '^\s*[vV]?\d+(?:\.\d+)*' -and
            (Test-LocalPackageVersionComplete -VersionFolder $versionFolder.FullName)) { $hasVersionFolder = $true; break }
      }
      if ($hasVersionFolder) { $ids.Add($packageId) }
    }
  } catch {
    Write-Log ("Local package inventory scan failed for {0}: {1}" -f $RootPackageFolder, $_.Exception.Message)
    return @()
  }
  return @($ids | Sort-Object -Unique)
}


# --- Pruning the local package folder ---------------------------------------------------------
#
# Built packages pile up: every version ever created stays on disk under <Root>\<PackageId>\<Version>.
# Over months that is tens of gigabytes of installers nobody needs. This works out WHAT would go,
# without deleting anything - the caller shows the plan and asks first. Deleting build output is
# safe in a way deleting tenant apps is not (it can always be rebuilt), but "safe" is not "silent".

# Sort key that orders version folder names the same way the rest of the tool compares versions.
# Anything unparseable sorts last and is therefore never a deletion candidate ahead of a real
# version - a folder we cannot read is a folder we do not touch.
function Get-VersionSortKey {
  param([string]$Value)
  $parts = Get-ComparableVersionParts -Value $Value
  if (-not $parts) { return $null }
  $padded = @($parts.Core) + @(0, 0, 0, 0)
  return ,@($padded[0], $padded[1], $padded[2], $padded[3])
}

function Get-LocalPackagePrunePlan {
  param(
    [Parameter(Mandatory)][string]$RootPackageFolder,
    [int]$KeepCount = 2
  )
  $plan = [System.Collections.Generic.List[object]]::new()
  if ($KeepCount -lt 1) { return @() }
  if (-not (Test-Path -LiteralPath $RootPackageFolder -PathType Container)) { return @() }
  try {
    foreach ($packageFolder in @(Get-ChildItem -LiteralPath $RootPackageFolder -Directory -ErrorAction Stop)) {
      $versions = @()
      foreach ($versionFolder in @(Get-ChildItem -LiteralPath $packageFolder.FullName -Directory -ErrorAction SilentlyContinue)) {
        $key = Get-VersionSortKey -Value ([string]$versionFolder.Name)
        if (-not $key) { continue }   # not a version folder: leave it completely alone
        $versions += [pscustomobject]@{
          PackageId = [string]$packageFolder.Name
          Version   = [string]$versionFolder.Name
          Path      = [string]$versionFolder.FullName
          SortKey   = $key
        }
      }
      if ($versions.Count -le $KeepCount) { continue }
      $ordered = @($versions | Sort-Object -Property @{ Expression = { $_.SortKey[0] } }, @{ Expression = { $_.SortKey[1] } },
                                                     @{ Expression = { $_.SortKey[2] } }, @{ Expression = { $_.SortKey[3] } } -Descending)
      foreach ($victim in @($ordered | Select-Object -Skip $KeepCount)) { [void]$plan.Add($victim) }
    }
  } catch {
    Write-Log ("Local package prune scan failed for {0}: {1}" -f $RootPackageFolder, $_.Exception.Message)
    return @()
  }
  return @($plan)
}

# Size of one planned entry, in bytes. Separate from the plan so the scan stays fast and a folder
# that cannot be measured still shows up in the list rather than vanishing from it.
function Get-FolderSizeBytes {
  param([string]$Path)
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0 }
    return [long](Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
      Measure-Object -Property Length -Sum).Sum
  } catch { return 0 }
}

function Format-ByteSize {
  param([long]$Bytes)
  if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
  return ('{0} B' -f $Bytes)
}

# Deletes what the plan lists and reports what actually went. A failure on one folder (file in use,
# for example) must not abort the rest, so each removal stands on its own.
function Invoke-LocalPackagePrune {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan)
  $removed = 0
  $failed = 0
  $freed = [long]0
  foreach ($entry in $Plan) {
    $size = Get-FolderSizeBytes -Path $entry.Path
    try {
      Remove-Item -LiteralPath $entry.Path -Recurse -Force -ErrorAction Stop
      $removed++
      $freed += $size
      Write-Log ("Local package prune: removed {0} {1}" -f $entry.PackageId, $entry.Version)
    } catch {
      $failed++
      Write-Log ("Local package prune: could NOT remove {0} {1}: {2}" -f $entry.PackageId, $entry.Version, $_.Exception.Message)
    }
  }
  return [pscustomobject]@{ Removed = $removed; Failed = $failed; FreedBytes = $freed }
}

# --- Short-lived cache for the tenant app inventory ---
# Every Get-WtWin32Apps call makes the WinTuner module log "Getting list of published apps", and a
# single screen refresh triggers several. Reusing a result for a few seconds removes the repetition
# without hiding real changes.
#
# NOT used for the safety checks. Get-FreshExistingUpdateTarget and Resolve-DeployedUpdateTarget
# exist precisely BECAUSE the inventory may have changed a moment ago - another administrator may
# have deployed the same target, and Intune needs a moment to report a freshly created app. Serving
# those from a cache would reintroduce the duplicate uploads they were written to prevent. The same
# applies to the version cleanup, which decides what gets deleted.
$script:win32AppsCache = @{}
$script:win32AppsCacheSeconds = 10

# The module asks Graph for the inventory with $top=999 and does NOT follow @odata.nextLink (checked
# against WinTuner 1.4.1: MobileAppsRequestBuilderExtensions+<GetWinTunerAppsAsync> calls GetAsync
# once and reads response.Value - no PageIterator). A tenant with more WinTuner-managed apps than
# one page therefore hands us a SILENT partial inventory: no error, no warning, just a short list.
# Every decision built on it - which apps have updates, which versions get deleted - would then be
# made on incomplete data, which is the same failure class as 0.15.8.
#
# The GUI cannot fix this inside the module, so it does the next best thing: it notices. A result at
# or above the page size means "possibly truncated" (exactly 999 matching apps is indistinguishable
# from more than 999 from out here), and that gets said out loud instead of being assumed complete.
$script:win32AppsModulePageSize = 999
# Warn once per session per inventory kind; a per-read warning would flood the log during a batch.
$script:win32InventoryTruncationWarned = @{}

# Pure so it can be tested without Graph: is a result of this size possibly a truncated first page?
function Test-Win32InventoryTruncated {
  param([Parameter(Mandatory)][int]$Count, [int]$PageSize = $script:win32AppsModulePageSize)
  if ($PageSize -le 0) { return $false }
  return ($Count -ge $PageSize)
}

# Reads the WinGet package id back out of the notes marker the module writes.
#
# Format verified against WinTuner 1.4.1, whose own parser is
#   \[WinTuner\|(?<source>[^\|]+)\|(?<packageId>[^\]]+)\]
# with '[WingetIntune|' as the historical spelling. The module derives the PackageId property from
# exactly this string, so reading the inventory without the module means reading this too.
# Pure, so the format can be tested without a tenant.
function Get-PackageIdFromNotes {
  param([string]$Notes)
  if ([string]::IsNullOrWhiteSpace($Notes)) { return '' }
  $m = [regex]::Match($Notes, '\[(?:WinTuner|WingetIntune)\|(?<source>[^|]+)\|(?<packageId>[^\]]+)\]')
  if (-not $m.Success) { return '' }
  return ([string]$m.Groups['packageId'].Value).Trim()
}

# Der Massstab fuer "das sieht aus wie eine WinGet-Paket-Id": Hersteller.Produkt, mindestens ein
# Punkt, mindestens ein Buchstabe.
#
# Gebraucht von der losen Notizsuche unten UND vom Zuordnungsdialog, damit beide dieselbe Grenze
# ziehen. Ohne ihn liest "WinTuner 1.4.1" die Versionsnummer als Paket-Id und "WinGet setup.exe"
# einen Dateinamen - beides erfuellt das Punktmuster und ist trotzdem keine Id. Eine falsche Id
# waere hier besonders teuer: sie paketiert das falsche Produkt und loest die echte App ab.
function Test-IsPlausiblePackageId {
  param([string]$Value)
  $v = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($v)) { return $false }
  if ($v -notmatch '^[A-Za-z0-9][A-Za-z0-9\-+_]*(?:\.[A-Za-z0-9][A-Za-z0-9\-+_]*)+$') { return $false }
  # Eine reine Versionsnummer erfuellt das Muster ebenfalls - sie hat nur keinen Buchstaben.
  if ($v -notmatch '[A-Za-z]') { return $false }
  # Ein Dateiname erfuellt es auch. Die Endungen, die in Notizfeldern wirklich vorkommen.
  if ($v -match '(?i)\.(exe|msi|msix|appx|ps1|cmd|bat|zip|intunewin|log|txt|json|xml)$') { return $false }
  return $true
}

# Die LOSE Lesart des Notizfelds: das blosse Wort 'WinGet' oder 'WinTuner' vor einer Paket-Id.
#
# Die geklammerte Marke ist der Sonderfall, nicht die Regel. Im Betrieb steht im Notizfeld, was ein
# Mensch hingeschrieben hat - "installiert mit WinGet: Google.Chrome", "WinTuner - Zoom.ZoomRooms".
# Diese Notiz traegt dieselbe Auskunft wie die Marke und wurde bisher weggeworfen, obwohl sie die
# Zuordnung ohne jedes Raten moeglich macht.
#
# Bewusst KEINE Marke: eine so gelesene App bleibt unmarkiert (IsUnmanaged) und damit in genau der
# Liste, in der sie vorher schon stand. Die lose Lesart kann eine Id nur HINZUFUEGEN, niemals eine
# App aus der Suche entfernen - haette sie die Marke gesetzt, waere die App aus dem markierten
# Inventar und aus der Unmarkiert-Liste zugleich gefallen und gar nicht mehr geprueft worden.
#
# Alle Treffer werden durchgegangen, nicht nur der erste: "WinTuner GUI 0.16.0, WinGet Google.Chrome"
# hat vor der Id noch eine Erwaehnung ohne Id.
function Get-LoosePackageIdFromNotes {
  param([string]$Notes)
  if ([string]::IsNullOrWhiteSpace($Notes)) { return '' }
  foreach ($m in [regex]::Matches($Notes, '(?i)\b(?:WinTuner|WingetIntune|WinGet)\b[\s:=|\-]*(?<packageId>[^\s,;)\]]+)')) {
    # Satzzeichen um die Id herum abraeumen: "(Google.Chrome)." ist im Notizfeld haeufiger als die
    # nackte Id, und Test-IsPlausiblePackageId wuerde die Klammern zu Recht ablehnen.
    $candidate = ([string]$m.Groups['packageId'].Value).Trim() -replace '^[(\[{''"]+', '' -replace '[.,;:)\]}''"]+$', ''
    if (Test-IsPlausiblePackageId -Value $candidate) { return $candidate }
  }
  return ''
}

# Decides whether an app counts as superseded (= an OLD version), from the Graph counters.
#
# ACHTUNG, die beiden Zaehler sind vertauschbar - und sie WAREN hier vertauscht. Richtig ist:
#   supersededAppCount  = wie viele Apps diese App SELBST abloest   -> > 0 auf der NEUEN App
#   supersedingAppCount = von wie vielen Apps sie ABGELOEST WIRD    -> > 0 auf der ALTEN App
# "Abgeloest", also das, was die Oberflaeche eine alte Version nennt, ist demnach
# supersedingAppCount > 0.
#
# Bis 0.18.0 stand hier das Gegenteil, mit einer Begruendung, die sich auf die Graph-Dokumentation
# berief. Widerlegt am Protokoll eines echten Laufs vom 03.09.2026 (10:36:14), in dem der paginierte
# Graph-Weg mit dem Filter "supersededAppCount == 0" genau diese sechs Apps als AKTIV lieferte:
#   Adobe Acrobat 26.001.21771, Airtame 4.15.1, Chrome 151.0.7922.72,
#   WebView2 151.0.4129.78, VS Code 1.136.0, Zoom 7.1.43453
# Fuenf davon sind die ALTEN Versionen, die derselbe Lauf 30 Minuten vorher abgeloest hatte. Und
# es fehlten genau die sechs NEUEN (7-Zip 26.02, Adobe .21789, Airtame 4.16.0, WebView2
# 152.0.4191.53, WatchGuard 2026.2.2, Zoom 7.1.46825) - also genau die, die je eine App abloesen.
# Die einzige Ausnahme in der Liste, VS Code 1.136.0, war im selben Lauf OHNE Abloesung
# bereitgestellt ("deploying without supersedence") und loest deshalb wirklich nichts ab.
#
# Das Muster ist eindeutig: der Filter hat "loest nichts ab" ausgewaehlt, nicht "wird nicht
# abgeloest". Wirkung des Fehlers: auf jedem Tenant, auf dem der paginierte Weg zum Zuge kommt
# (mehr als 999 App-Objekte, oder das Modul antwortet leer), waren aktiv und abgeloest VERTAUSCHT -
# die Update-Suche haette alte Versionen verglichen, und die Versionsbereinigung haette die NEUEN
# fuer die alten gehalten. Gehalten hat sie dort nur, dass jede Loeschung zusaetzlich Zuweisung und
# erfolgreiche Installationen prueft.
function Test-IsSupersededApp {
  param([Parameter(Mandatory)][AllowNull()]$SupersedingAppCount)
  if ($null -eq $SupersedingAppCount) { return $false }
  return ([int]$SupersedingAppCount -gt 0)
}

# The full WinTuner-managed inventory, read straight from Graph WITH pagination.
#
# Exists because the module asks for one page of 999 and never follows @odata.nextLink, so on a large
# tenant its answer is a silent partial list. This reproduces the module's own server-side filter -
# win32LobApp carrying a '[WinTuner|' or '[WingetIntune|' notes marker - and the same partition into
# active and superseded, then hands back objects shaped like the module's (Name / CurrentVersion /
# GraphId / PackageId), which is the whole contract the rest of the application reads.
#
# NOT the default path: it is used only when the module's answer looks truncated. Normal tenants keep
# running on the module, so this code cannot change what the vast majority of runs see - and the one
# case it does change is the case that is otherwise provably wrong.
# Der ROHE Durchlauf durch alle App-Objekte, 30 Sekunden gemerkt.
#
# Die Abfrage liefert die ganze Liste und wird LOKAL in aktiv/abgeloest geteilt - zwei Aufrufe
# hintereinander (genau das passiert bei jeder Dashboard-Aktualisierung, wenn das Modul leer
# antwortet) waren deshalb zweimal derselbe Netzdurchlauf, bei einem grossen Tenant zweimal neun
# Seiten. Der zweite Aufruf kostet jetzt nichts.
$script:graphInventoryRaw = $null
$script:graphInventoryRawTime = [datetime]::MinValue
$script:graphInventoryRawSeconds = 30
# Die ausfuehrliche Erklaerung zu einem leeren Inventar wird einmal pro Sitzung geschrieben.
$script:emptyInventoryExplained = $false

function Clear-GraphInventoryRawCache {
  $script:graphInventoryRaw = $null
  $script:graphInventoryRawTime = [datetime]::MinValue
}

function Get-RawWin32AppsFromGraph {
  # Eigener Standard, falls die Konstante (noch) nicht gesetzt ist: ein $null in dieser Rechnung
  # macht jeden Vergleich falsch, und der Cache greift dann nie - lautlos.
  $maxAge = if ([int]$script:graphInventoryRawSeconds -gt 0) { [int]$script:graphInventoryRawSeconds } else { 30 }
  $age = ([datetime]::UtcNow - $script:graphInventoryRawTime).TotalSeconds
  if ($null -ne $script:graphInventoryRaw -and $age -lt $maxAge) {
    Write-LogDebug ("Paged Graph inventory served from the short-term cache ({0:n0}s old)." -f $age)
    return @($script:graphInventoryRaw)
  }
  $token = Get-WtToken -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=100"
  $raw = [System.Collections.Generic.List[object]]::new()
  $maxPages = 200   # 20000 apps; far beyond any real tenant, and stops a broken cursor looping forever
  $page = 0
  do {
    $page++
    if ($page -gt $maxPages) { throw "Graph pagination exceeded $maxPages pages while reading the app inventory." }
    # -MaxRetries 0: siehe oben, der Aufrufer wiederholt selbst.
    $response = Invoke-GraphRest -Method GET -Uri $uri -Headers $headers -MaxRetries 0 `
      -Context ("app inventory over Graph (page {0})" -f $page)
    foreach ($app in @($response.value)) { $raw.Add($app) }
    $uri = [string]$response.'@odata.nextLink'
  } while (-not [string]::IsNullOrWhiteSpace($uri))
  $script:graphInventoryRaw = @($raw.ToArray())
  $script:graphInventoryRawTime = [datetime]::UtcNow
  Write-Log ("Paged Graph inventory read: {0} app object(s) of any type over {1} page(s)." -f $script:graphInventoryRaw.Count, $page)
  return @($script:graphInventoryRaw)
}

function Get-Win32AppInventoryViaGraph {
  param([switch]$Superseded)
  $result = [System.Collections.Generic.List[object]]::new()
  foreach ($app in (Get-RawWin32AppsFromGraph)) {
      if (-not $app -or -not $app.id) { continue }
      $odataType = [string]$app.'@odata.type'
      if (-not [string]::Equals($odataType.TrimStart([char]'#'), 'microsoft.graph.win32LobApp', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      $packageId = Get-PackageIdFromNotes -Notes ([string]$app.notes)
      # No marker means the module would not list it either. Staying identical to the module here
      # matters more than being more complete: every consumer downstream expects a resolvable
      # PackageId, and the deletion paths in particular must not suddenly see hand-built apps.
      if (-not $packageId) { continue }
      $isSuperseded = Test-IsSupersededApp -SupersedingAppCount $app.supersedingAppCount
      if ($isSuperseded -ne [bool]$Superseded) { continue }
      $result.Add([pscustomobject]@{
        Name           = [string]$app.displayName
        CurrentVersion = [string]$app.displayVersion
        GraphId        = [string]$app.id
        PackageId      = $packageId
        IsAssigned     = [bool]$app.isAssigned
      })
  }
  Write-Log ("Paged Graph inventory: {0} WinTuner-managed {1} app(s)." -f $result.Count, $(if ($Superseded) { 'superseded' } else { 'active' }))
  return @($result.ToArray())
}

# Die Gegenstueck-Liste: alle Win32-Apps des Tenants OHNE WinTuner-Marke.
#
# Die Marke im Notizfeld sagt, WER die App angelegt hat - nicht, WAS sie enthaelt. Ein handgebautes
# Paket ist genauso ein win32LobApp aus einer .intunewin, und die Marke wird im Betrieb auch wieder
# entfernt. Die Update-Suche an sie zu binden hat deshalb Apps ausgeschlossen, die sehr wohl ein
# WinGet-Gegenstueck haben: im Protokoll vom 28.08.2026 waren es 3 von 13 Win32-Apps.
#
# Was hier NICHT passiert: eine Paket-Id raten. Die Objekte kommen mit leerer PackageId zurueck,
# damit Resolve-WingetIdForApp seine strengen Regeln anwenden MUSS (exakter Name, Score >= 80 mit
# 15 Punkten Abstand, oder ein WingetOverrides-Eintrag). Eine falsch geratene Id wuerde das falsche
# Produkt paketieren und die echte App ablösen - bei einem handgebauten Paket, das niemand schnell
# nachbaut, ist das der Totalverlust.
#
# Rein gehalten, damit die Auswahl ohne Tenant pruefbar ist.
function Select-UnmanagedWin32Apps {
  param(
    [AllowNull()][object[]]$RawApps,
    [switch]$Superseded
  )
  $result = [System.Collections.Generic.List[object]]::new()
  foreach ($app in @($RawApps)) {
    if (-not $app -or -not $app.id) { continue }
    $odataType = [string]$app.'@odata.type'
    if (-not [string]::Equals($odataType.TrimStart([char]'#'), 'microsoft.graph.win32LobApp', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    # Mit Marke gehoert die App dem Modul. Sie kommt ueber das regulaere Inventar - MIT belastbarer
    # PackageId - und wuerde hier nur ein zweites Mal auftauchen.
    if (Get-PackageIdFromNotes -Notes ([string]$app.notes)) { continue }
    $isSuperseded = Test-IsSupersededApp -SupersedingAppCount $app.supersedingAppCount
    if ($isSuperseded -ne [bool]$Superseded) { continue }
    # Steht im Notizfeld eine Paket-Id ohne die geklammerte Marke ("WinGet: Google.Chrome"), wird sie
    # genommen. Sie ist AUFGESCHRIEBEN und nicht geraten und deshalb belastbarer als jeder
    # Namensabgleich; die App bleibt trotzdem als unmarkiert gekennzeichnet.
    $loosePackageId = Get-LoosePackageIdFromNotes -Notes ([string]$app.notes)
    $result.Add([pscustomobject]@{
      Name           = [string]$app.displayName
      CurrentVersion = [string]$app.displayVersion
      GraphId        = [string]$app.id
      PackageId      = $loosePackageId
      IsAssigned     = [bool]$app.isAssigned
      # Bleibt am Objekt haengen, damit die Zeile in der Update-Liste sagen kann, woher sie kommt.
      IsUnmanaged    = $true
      # Getrennt vom Namensabgleich gefuehrt, weil die Zeile beides unterschiedlich benennen muss:
      # "im Notizfeld gefunden" ist eine Auskunft, "ueber den Namen zugeordnet" eine Vermutung.
      PackageIdFromNotes = [bool]$loosePackageId
    })
  }
  return @($result.ToArray())
}

function Get-UnmanagedWin32Apps {
  param([switch]$Superseded)
  $apps = @(Select-UnmanagedWin32Apps -RawApps (Get-RawWin32AppsFromGraph) -Superseded:$Superseded)
  $fromNotes = @($apps | Where-Object { $_.PSObject.Properties['PackageIdFromNotes'] -and $_.PackageIdFromNotes })
  Write-Log ("Paged Graph inventory: {0} {1} Win32 app(s) WITHOUT a WinTuner marker; {2} of them carry a WinGet id in the notes text anyway." -f `
    $apps.Count, $(if ($Superseded) { 'superseded' } else { 'active' }), $fromNotes.Count)
  foreach ($a in $fromNotes) {
    Write-Log ("  WinGet id read from the notes text of '{0}': {1} (no bracketed marker, so the app stays flagged as not WinTuner-built)." -f [string]$a.Name, [string]$a.PackageId)
  }
  return $apps
}

# Haengt die unmarkierten Apps an das Modul-Inventar. Bei gleicher GraphId gewinnt das Modul-Objekt:
# es traegt die PackageId aus dem Notizfeld, das Graph-Objekt nur einen Anzeigenamen.
# Rein, damit die Zusammenfuehrung ohne Tenant pruefbar ist.
function Merge-UnmanagedInventory {
  param(
    [AllowNull()][object[]]$ManagedApps,
    [AllowNull()][object[]]$UnmanagedApps
  )
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $result = [System.Collections.Generic.List[object]]::new()
  foreach ($a in @($ManagedApps)) {
    if (-not $a -or -not $a.GraphId) { continue }
    if ($seen.Add([string]$a.GraphId)) { $result.Add($a) }
  }
  foreach ($a in @($UnmanagedApps)) {
    if (-not $a -or -not $a.GraphId) { continue }
    if ($seen.Add([string]$a.GraphId)) { $result.Add($a) }
  }
  return @($result.ToArray())
}

# Das aktive Inventar, ueber das die Update-Suche UND die Kachel rechnen. Eine Stelle, damit die
# beiden nicht wieder verschiedene Fragen beantworten - genau dafuer gibt es Measure-AvailableUpdates.
function Get-ScanInventory {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ManagedApps)
  if (-not $script:settings.ScanUnmanagedWin32Apps) { return @($ManagedApps) }
  $unmanaged = @()
  try {
    $unmanaged = @(Get-UnmanagedWin32Apps)
  } catch {
    # Kein Abbruch: die markierten Apps sind vollstaendig gelesen, und eine kuerzere Suche ist besser
    # als gar keine. Gesagt wird es trotzdem, sonst sieht niemand die Luecke.
    Write-Log ("Update scan: the Win32 apps without a WinTuner marker could not be read ({0}); continuing with the marked apps only." -f $_.Exception.Message)
    return @($ManagedApps)
  }
  if ($unmanaged.Count -eq 0) { return @($ManagedApps) }
  $merged = @(Merge-UnmanagedInventory -ManagedApps $ManagedApps -UnmanagedApps $unmanaged)
  Write-Log ("Update scan inventory: {0} WinTuner-marked + {1} unmarked Win32 app(s) = {2}. An unmarked app carries no package id in its notes, so a WinGet id is only accepted from an exact name match, a high-confidence match, or a WingetOverrides entry." -f `
    @($ManagedApps).Count, $unmanaged.Count, $merged.Count)
  return $merged
}

# The WinTuner module hands back a live collection it is still filling and enumerates it internally
# ("Getting list of published apps"). Under WinForms - where the UI thread pumps DoEvents while the
# module works - that race surfaces as "Collection was modified; enumeration operation may not
# execute" or "Value cannot be null". It is transient: the SAME call succeeds a moment later, which
# is exactly why users saw packaging and cleanup fail on the first click and work on the second.
# Test-WtConnected already treats these as retryable at sign-in; this does the same for every other
# inventory read. Only the known race/throttle shapes are retried - a real error (missing
# permission, no Intune license) still fails immediately, because retrying cannot fix it.
function Test-IsTransientModuleRace {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
  return (
    $Message -match 'Collection was modified' -or
    $Message -match 'Value cannot be null' -or
    $Message -match 'timed out' -or
    $Message -match 'ServiceUnavailable' -or
    $Message -match 'temporarily unavailable' -or
    $Message -match 'Too Many Requests' -or
    $Message -match '\b(429|500|503|504)\b')
}

function Invoke-WithTransientRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [string]$Label = '',
    [int]$MaxRetries = 3
  )
  $attempt = 0
  while ($true) {
    try { return (& $Action) }
    catch {
      $m = $_.Exception.Message
      if (-not (Test-IsTransientModuleRace $m) -or $attempt -ge $MaxRetries) { throw }
      $attempt++
      Write-Log ("Transient module race{0} (attempt {1}/{2}): {3}. Retrying." -f `
        $(if ($Label) { " for $Label" } else { '' }), $attempt, $MaxRetries, $m)
      try { [System.Windows.Forms.Application]::DoEvents() } catch { }
      Start-Sleep -Milliseconds (250 * $attempt)
    }
  }
}

# Inventory read with the transient-race retry above. Use this instead of a bare Get-WtWin32Apps for
# any read that would otherwise abort a user action on the first attempt.
#
# -Update is a FILTER on UpdateAvailable, not "also evaluate updates" - and the module declares it
# as Nullable[bool], so "unset" and "$false" mean two different things: unset = no filter,
# $false = ONLY apps that are already up to date. 0.15.7 always bound -Update:$false here, which
# removed every app WITH an update from the inventory the update scan works on. The scan then
# reported "no update candidates" on tenants that plainly had them (Java 8, Jabra Direct 6.27.3702
# -> 8.1.14601): the outdated apps never reached the comparison at all. The parameter is bound only
# when a caller explicitly asks for one side of that filter.
# Fuehrt die Inventar-Abfrage im Paket-Runspace aus, damit das Fenster waehrenddessen zeichnet.
#
# Rueckgabe:
#   $null                      - der Runspace war nicht zu haben; der Aufrufer macht es inline
#   @(...)                     - das Ergebnis der Abfrage
#   wirft                      - der Fehler AUS der Abfrage, unveraendert, auf dem UI-Thread
#
# Der letzte Punkt ist der wichtige: Invoke-WithTransientRetry und die Truncation-Pruefung sollen
# denselben Fehler sehen wie bei einem Inline-Aufruf, sonst waere die Auslagerung eine stille
# Verhaltensaenderung an einer Stelle, an der Apps geloescht werden.
function Get-Win32AppsOffThread {
  param(
    [Parameter(Mandatory)][hashtable]$Query,
    [string]$Label = 'inventory read'
  )
  # Der Runspace fuehrt GENAU EINE Pipeline. Waehrend dieser Abfrage laeuft die Nachrichtenschleife
  # weiter (das ist der Zweck), ein Klick auf "Dashboard" kann also eine zweite Inventar-Abfrage
  # starten - und die lief in "The pipeline was not run because a pipeline is already running.
  # Pipelines cannot be run concurrently.", woraufhin das Fenster "Laden der Apps aus Intune
  # fehlgeschlagen" meldete (26.08.2026, 09:28:26). Ist der Runspace besetzt, wird nicht gewartet
  # und nicht gedraengelt: $null heisst "mach es inline", und der Aufrufer kommt zum Ergebnis.
  if ($script:pkgRunspaceInUse -or $script:packagingBusy) {
    Write-LogDebug ("Inventory read '{0}': the background runspace is busy - running inline instead." -f $Label)
    return $null
  }
  $rs = $null
  try { $rs = Get-PackageRunspace } catch { $rs = $null }
  if (-not $rs) { return $null }

  $ps = $null
  $script:pkgRunspaceInUse = $true
  try {
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    # Der Aufruf bekommt die Abfrage als Parameter - eine Variable aus dem UI-Runspace ist im
    # zweiten Runspace nicht sichtbar.
    [void]$ps.AddScript('param($q) Get-WtWin32Apps @q').AddArgument($Query)
    $async = $ps.BeginInvoke()
    # Nachrichtenschleife weiterlaufen lassen, waehrend der andere Thread arbeitet. Das ist der
    # ganze Gewinn: das Fenster zeichnet und reagiert, statt als "Keine Rueckmeldung" dazustehen.
    while (-not $async.AsyncWaitHandle.WaitOne(50)) {
      [System.Windows.Forms.Application]::DoEvents()
    }
    $result = $ps.EndInvoke($async)
    if ($ps.Streams.Error.Count -gt 0) {
      # Fehler aus dem Runspace als echten Fehler auf diesem Thread weiterreichen.
      throw ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
    }
    return @($result)
  } catch {
    # Zwei Faelle sind hier nicht zu unterscheiden: "Runspace kaputt" und "Abfrage fehlgeschlagen".
    # Im Zweifel den Fehler weiterreichen - ihn zu schlucken und inline zu wiederholen wuerde eine
    # echte Stoerung in eine doppelt so lange Wartezeit verwandeln.
    Write-Log ("Inventory read '{0}' (off-thread) failed: {1}" -f $Label, $_.Exception.Message)
    throw
  } finally {
    $script:pkgRunspaceInUse = $false
    if ($ps) { try { $ps.Dispose() } catch { } }
  }
}

function Get-Win32AppsResilient {
  param(
    [switch]$Superseded,
    [Nullable[bool]]$UpdateAvailable,
    [string]$Label = 'inventory read',
    # Callers that already sit in their own retry loop (Resolve-DeployedUpdateTarget waits for Intune
    # to list a freshly created app) pass 0: they still get the single code path and the truncation
    # check, without nesting 3 retries inside their own 8 attempts.
    [int]$MaxRetries = 3
  )
  $query = @{ Superseded = [bool]$Superseded; ErrorAction = 'Stop' }
  if ($null -ne $UpdateAvailable) { $query['Update'] = [bool]$UpdateAvailable }
  $read = {
    # Bevorzugt im Paket-Runspace, damit das Fenster waehrend der laengsten Abfrage des Programms
    # zeichnet. $null heisst nur "Runspace nicht verfuegbar" - dann wie bisher inline.
    #
    # Die Pruefung auf die Funktion ist kein Zierrat: die Unit-Tests laden diese Funktion einzeln aus
    # der Quelle und stellen Get-WtWin32Apps als Mock bereit. Ohne die Pruefung wuerden sie einen
    # echten Runspace aufmachen, das Modul importieren und am Mock vorbeilaufen - sie pruefen die
    # Logik dieses Wrappers, nicht die Nebenlaeufigkeit.
    if (Get-Command Get-Win32AppsOffThread -ErrorAction SilentlyContinue) {
      $offThread = Get-Win32AppsOffThread -Query $query -Label $Label
      if ($null -ne $offThread) { return $offThread }
    }
    Get-WtWin32Apps @query
  }
  $apps = @(Invoke-WithTransientRetry -Label $Label -MaxRetries $MaxRetries -Action $read)

  # Eine LEERE Antwort ist kein Fehler - und das ist die Falle, die einen Kunden mit 11 Apps als
  # "Keine Apps in Intune gefunden" dastehen liess: die Modul-Wettlaufsituation ("Collection was
  # modified") schlaegt nicht immer als Ausnahme durch, manchmal kommt einfach eine leere Liste
  # zurueck. Invoke-WithTransientRetry sieht dann nichts, was es wiederholen koennte.
  #
  # Deshalb wird eine leere Antwort EINMAL gegengelesen, bevor sie geglaubt wird. Ein Tenant ohne
  # verwaltete Apps kostet dadurch eine zusaetzliche Abfrage - eine Sekunde fuer die Zusicherung,
  # dass "leer" wirklich leer heisst. Kommen beim zweiten Mal Apps, war die erste Antwort der Wettlauf.
  if ($apps.Count -eq 0 -and $MaxRetries -gt 0) {
    Write-Log ("Inventory read '{0}' came back EMPTY. An empty answer is not an error, so it was not retried - re-reading once to tell a real empty tenant from the module's enumeration race." -f $Label)
    try { [System.Windows.Forms.Application]::DoEvents() } catch { }
    $second = @(Invoke-WithTransientRetry -Label ("{0} (empty re-read)" -f $Label) -MaxRetries $MaxRetries -Action $read)
    if ($second.Count -gt 0) {
      Write-Log ("Inventory read '{0}': the re-read returned {1} app(s) - the first, empty answer was the module's race and is discarded." -f $Label, $second.Count)
      $apps = $second
    } else {
      # Zweite Meinung von einer ANDEREN Stelle. Get-Win32AppInventoryViaGraph fragt Graph selbst,
      # paginiert, und bildet denselben Filter nach (win32LobApp mit '[WinTuner|'-Marke). Sagt Graph
      # ebenfalls null, ist "leer" belastbar und keine Vermutung mehr - genau diese Auskunft braucht
      # die Meldung darueber, ob der Tenant leer ist oder die Abfrage kaputt war.
      try {
        # Der Graph-Weg kennt den Update-Filter NICHT. Wurde nach "nur Apps mit Update" gefragt,
        # darf seine Antwort die leere Modulantwort nicht ersetzen - sie beantwortet eine andere
        # Frage, und zwar eine weiter gefasste.
        #
        # Gesehen am 03.09.2026 (10:36:14): die Kachel fragte nach Apps MIT Update, das Modul
        # antwortete leer, der Graph-Weg lieferte alle 6 aktiven - und das Protokoll meldete
        # daraufhin "Intune flags an update for" fuer alle sechs, darunter Visual Studio Code
        # 1.136.0, die 36 Minuten vorher selbst als neueste Version hochgeladen worden war.
        $viaGraph = if ($null -ne $UpdateAvailable) { @() } else { @(Get-Win32AppInventoryViaGraph -Superseded:$Superseded) }
        if ($null -ne $UpdateAvailable) {
          Write-Log ("Inventory read '{0}': the module returned nothing. The direct Graph cross-check is SKIPPED here because this read asks for apps with an update available and the Graph path cannot reproduce that filter - it would answer a wider question and every app would be reported as having an update." -f $Label)
        }
        if ($viaGraph.Count -gt 0) {
          Write-Log ("Inventory read '{0}': the module returned nothing, but a direct paged Graph read found {1} app(s) - using the Graph result." -f $Label, $viaGraph.Count)
          $apps = $viaGraph
        } elseif ($null -ne $UpdateAvailable) {
          # Schon oben begruendet; hier nur nicht als "Tenant ist leer" verbuchen.
        } elseif (-not $script:emptyInventoryExplained) {
          # Die ausfuehrliche Fassung EINMAL pro Sitzung. Bei einem Tenant ohne WinTuner-Apps stand
          # dieser Absatz sonst dreimal hintereinander im Protokoll (aktiv, abgeloest, Kachel) und
          # verdeckte alles andere.
          $script:emptyInventoryExplained = $true
          Write-Log ("Inventory read '{0}': confirmed empty by the module AND by a direct Graph read - this tenant really has no WinTuner-managed {1} app(s). Apps created by hand or by another tool carry no '[WinTuner|' marker and are deliberately not listed here; they are visible under 'All tenant apps'. (Said once per session; later empty reads are logged in one line.)" -f $Label, $(if ($Superseded) { 'superseded' } else { 'active' }))
        } else {
          Write-Log ("Inventory read '{0}': confirmed empty by the module and by Graph (no WinTuner-managed {1} apps)." -f $Label, $(if ($Superseded) { 'superseded' } else { 'active' }))
        }
      } catch {
        Write-Log ("Inventory read '{0}': the direct Graph cross-check failed ({1}); staying with the module's empty answer." -f $Label, $_.Exception.Message)
      }
    }
  }

  # Central truncation check: every inventory read that matters goes through here, so one place is
  # enough to notice a partial first page - and to do something about it.
  if (Test-Win32InventoryTruncated -Count $apps.Count) {
    $kind = if ($Superseded) { 'superseded' } else { 'active' }
    if (-not $script:win32InventoryTruncationWarned.ContainsKey($kind)) {
      $script:win32InventoryTruncationWarned[$kind] = $true
      Write-Log ("Inventory read '{0}' returned {1} apps, which is the module's page size - the module does not follow @odata.nextLink, so this list is very likely INCOMPLETE. Re-reading the inventory directly from Graph with pagination." -f $Label, $apps.Count)
    }
    # Swap in the complete list. Deliberately only in this branch: a normal tenant never reaches it,
    # so the code path everyone else runs on is untouched, while the one case that is provably wrong
    # gets a correct answer instead of only a warning.
    # Auch hier gilt: der Graph-Weg kennt den Update-Filter nicht. Eine abgeschnittene Liste ist
    # schlecht, eine vollstaendige Liste zur falschen Frage ist schlechter - sie wuerde jede aktive
    # App als "hat ein Update" ausgeben.
    if ($null -ne $UpdateAvailable) {
      Write-Log ("Inventory read '{0}': the list looks truncated, but the paged Graph substitution is SKIPPED because this read asks for apps with an update available and the Graph path cannot reproduce that filter. The count may be incomplete; the full version comparison in Settings answers this question without the flag." -f $Label)
      return $apps
    }
    try {
      $paged = @(Get-Win32AppInventoryViaGraph -Superseded:$Superseded)
      if ($paged.Count -ge $apps.Count) {
        Write-Log ("Inventory read '{0}': using the paged Graph result ({1} apps) instead of the module's truncated {2}." -f $Label, $paged.Count, $apps.Count)
        return $paged
      }
      # Fewer apps than the module returned means the reproduction of the module's filter does not
      # match this tenant. Keeping the module's list is the conservative choice: too few apps in a
      # deletion path is dangerous, and a short list here would be silent.
      Write-Log ("Inventory read '{0}': the paged Graph result had FEWER apps ({1}) than the module returned ({2}); keeping the module result and staying with the warning." -f $Label, $paged.Count, $apps.Count)
    } catch {
      Write-Log ("Inventory read '{0}': the paged Graph fallback failed ({1}); continuing with the module's possibly truncated list." -f $Label, $_.Exception.Message)
    }
  }
  return $apps
}

# Ein Inventar, das KEINE aktive App nennt, aber abgeloeste Versionen kennt, ist in sich
# widerspruechlich: eine App ist nur deshalb abgeloest, weil eine neuere, aktive sie abgeloest hat.
# Genau diese Kombination stand im Protokoll (managed=0, superseded=6) - der Tenant hatte Apps, die
# Abfrage war kaputt. Als reine Rechnung testbar gehalten.
function Test-InventoryContradiction {
  param([int]$ActiveCount, [int]$SupersededCount)
  return ($ActiveCount -eq 0 -and $SupersededCount -gt 0)
}

function Get-CachedWin32Apps {
  param(
    [switch]$Superseded,
    # Set wherever the user explicitly asked for current data.
    [switch]$Force
  )
  $key = if ($Superseded) { 'superseded' } else { 'active' }
  if (-not $Force -and $script:win32AppsCache.ContainsKey($key)) {
    $entry = $script:win32AppsCache[$key]
    $age = ([datetime]::UtcNow - $entry.Time).TotalSeconds
    if ($age -lt $script:win32AppsCacheSeconds) {
      Write-LogDebug ("App inventory served from cache ({0}, {1:n1}s old)." -f $key, $age)
      return @($entry.Apps)
    }
  }
  # Routed through the resilient wrapper rather than calling the module directly: this read serves
  # the screens, so the module's "Collection was modified" race must not surface as a failed refresh,
  # and it gets the truncation check with everything else.
  $apps = @(Get-Win32AppsResilient -Superseded:$Superseded -Label ("cached inventory ({0})" -f $key))
  # Ein leeres Ergebnis wird NICHT ueber ein vorher gefuelltes geschrieben. Der Cache wird beim
  # Tenant-Wechsel geleert, also gehoert ein vorhandener Eintrag zu DIESEM Kunden - und "vorhin 11,
  # jetzt 0" ist keine Aenderung, die zwischen zwei Abfragen passiert. So wanderte die kaputte
  # Antwort der Kachel-Abfrage in die Update-Suche, die daraufhin "Keine Apps" meldete.
  if ($apps.Count -eq 0 -and $script:win32AppsCache.ContainsKey($key)) {
    $previous = @($script:win32AppsCache[$key].Apps)
    if ($previous.Count -gt 0) {
      Write-Log ("Inventory ({0}): the fresh read returned 0 app(s) while {1} were known from this tenant - keeping the previous list and NOT caching the empty answer. Click the refresh again to re-read." -f $key, $previous.Count)
      return $previous
    }
  }
  $script:win32AppsCache[$key] = @{ Time = [datetime]::UtcNow; Apps = $apps }
  return $apps
}

# Called after anything that changes the tenant, so the next read cannot serve a stale list.
function Clear-Win32AppsCache {
  $script:win32AppsCache = @{}
  # Die rohe Graph-Liste gehoert zum Tenant, und die Erklaerung zum leeren Inventar darf beim
  # naechsten Kunden wieder ausfuehrlich sein - dort ist sie eine neue Auskunft.
  Clear-GraphInventoryRawCache
  $script:emptyInventoryExplained = $false
  # A different tenant deserves its own truncation verdict - the previous customer's "list is fine"
  # says nothing about this one's app count.
  $script:win32InventoryTruncationWarned = @{}
}

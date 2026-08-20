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
    $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
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
function Get-SelectedAssignmentTarget {
  param(
    [Parameter(Mandatory=$true)][System.Windows.Forms.ComboBox]$TargetCombo,
    [Parameter(Mandatory=$true)][System.Windows.Forms.TextBox]$GroupIdBox
  )
  $selected = $TargetCombo.SelectedItem
  if ($selected -eq (Get-UiString 'AssignAllUsers'))   { return 'AllUsers' }
  if ($selected -eq (Get-UiString 'AssignAllDevices')) { return 'AllDevices' }
  if ($selected -eq (Get-UiString 'AssignCustomGroup')) {
    $gid = $GroupIdBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($gid)) { return $null }
    return $gid
  }
  # Saved group favorites sit AFTER the four fixed entries, so every existing SelectedIndex check
  # (index 3 == "custom group") keeps its meaning. The id comes from the stored favorite, never
  # from the text box, which is hidden for these entries.
  $favId = Get-FavoriteIdForSelection -TargetCombo $TargetCombo
  if ($favId) { return $favId }
  return $null
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
  $previous = [string]$TargetCombo.SelectedItem
  $TargetCombo.BeginUpdate()
  try {
    $TargetCombo.Items.Clear()
    [void]$TargetCombo.Items.AddRange(@(
      (Get-UiString 'AssignNotAssigned'), (Get-UiString 'AssignAllUsers'),
      (Get-UiString 'AssignAllDevices'), (Get-UiString 'AssignCustomGroup')))
    foreach ($f in @(Get-GroupFavorites)) {
      [void]$TargetCombo.Items.Add(((Get-UiString 'AssignFavoriteEntry') -f [string]$f.Name))
    }
    # Restore the previous choice when it still exists; otherwise fall back to "not assigned"
    # rather than silently landing on a different group after a tenant switch.
    $restore = if ($previous) { $TargetCombo.Items.IndexOf($previous) } else { -1 }
    $TargetCombo.SelectedIndex = if ($restore -ge 0) { $restore } else { 0 }
  } finally { $TargetCombo.EndUpdate() }
}

function Get-VersionDiskCache {
  if (-not $script:versionCachePath) { return @{} }
  try {
    if (Test-Path $script:versionCachePath) {
      $raw = Get-Content $script:versionCachePath -Raw -Encoding utf8 -ErrorAction Stop
      $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
      $ht = @{}
      foreach ($prop in $parsed.PSObject.Properties) {
        $ht[$prop.Name] = @{
          versions  = @($prop.Value.versions)
          timestamp = [datetime]::Parse($prop.Value.timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
      }
      return $ht
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
    $obj = @{}
    foreach ($key in $Cache.Keys) {
      $obj[$key] = @{
        versions  = $Cache[$key].versions
        timestamp = $Cache[$key].timestamp.ToString('o')
      }
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $script:versionCachePath -Encoding utf8 -ErrorAction SilentlyContinue
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

  # 5) Store in disk cache (update script-level cache variable and persist to disk)
  $script:diskCache[$PackageId] = @{
    versions  = $result
    timestamp = [datetime]::UtcNow
  }
  Save-VersionDiskCache -Cache $script:diskCache

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
function Get-FreshLatestPackageVersion {
  param([Parameter(Mandatory)][string]$PackageId)
  $moduleLatest = Get-WtPackageIndexLatestVersion -PackageId $PackageId
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
  [pscustomobject]@{
    Latest       = $latest
    Source       = $source
    ModuleLatest = $moduleLatest
    WingetLatest = $wingetLatest
  }
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
function Get-Win32AppsResilient {
  param([switch]$Superseded, [switch]$Update, [string]$Label = 'inventory read')
  return @(Invoke-WithTransientRetry -Label $Label -Action {
    Get-WtWin32Apps -Superseded:([bool]$Superseded) -Update:([bool]$Update) -ErrorAction Stop
  })
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
  # Cast required: the module declares -Superseded as Nullable[bool], and handing it a raw
  # SwitchParameter fails to bind.
  $apps = @(Get-WtWin32Apps -Superseded:([bool]$Superseded) -ErrorAction Stop)
  $script:win32AppsCache[$key] = @{ Time = [datetime]::UtcNow; Apps = $apps }
  return $apps
}

# Called after anything that changes the tenant, so the next read cannot serve a stale list.
function Clear-Win32AppsCache {
  $script:win32AppsCache = @{}
}

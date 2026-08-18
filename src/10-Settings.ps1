# One persistent log per ISO calendar week. Existing logs are deliberately kept; a new week simply
# starts a new file (for example WinTuner_GUI_2026-W32.log) instead of growing one endless history.
function Get-WeeklyLogFileName {
  param([datetime]$Date = (Get-Date))
  $isoYear = [System.Globalization.ISOWeek]::GetYear($Date)
  $isoWeek = [System.Globalization.ISOWeek]::GetWeekOfYear($Date)
  return ("WinTuner_GUI_{0}-W{1:D2}.log" -f $isoYear, $isoWeek)
}

# Canonical current-week path used by Settings, Help and all foreground log writers. Background
# delegates calculate the same ISO filename locally because they do not reliably inherit functions.
#
# The log used to sit next to the script, which for the documented way of running it means the
# Downloads folder. That is the wrong home for this content: measured over three weeks it held 137
# distinct Intune app and Entra group ids from several customer tenants, in clear text. Under
# LocalAppData it is inside the user profile and ACL-protected like the package folder already is.
$script:logDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinTunerGUI\Logs'
try {
  if (-not (Test-Path -LiteralPath $script:logDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $script:logDirectory -Force -ErrorAction Stop | Out-Null
  }
} catch {
  # Never let logging be the reason the application cannot start: fall back to the profile root.
  $script:logDirectory = [Environment]::GetFolderPath('LocalApplicationData')
}
$script:logFileBase = $script:logDirectory
$script:logFilePath = Join-Path $script:logFileBase (Get-WeeklyLogFileName)

# Weekly logs are deleted after this many weeks. An MSP tool accumulates customer group ids and app
# inventories across tenants; without a limit that pile simply grows for years on a technician's
# machine. Two weeks keeps recent troubleshooting possible without building an archive.
$script:logRetentionWeeks = 2

# Removes weekly logs older than the retention window. Matched on the ISO week encoded in the file
# name rather than on the file date, because copying or syncing a file rewrites its timestamps and
# would then keep old content alive indefinitely.
function Remove-ExpiredLogs {
  param([int]$RetentionWeeks = $script:logRetentionWeeks, [datetime]$Now = (Get-Date))
  $removed = 0
  if ($RetentionWeeks -lt 1) { return 0 }
  try {
    if (-not (Test-Path -LiteralPath $script:logDirectory -PathType Container)) { return 0 }
    # RetentionWeeks counts the weeks that are KEPT, the current one included. Subtracting the full
    # retention would keep one week too many: with a two-week limit and "now" in week 10, a cutoff
    # in week 8 would preserve weeks 8, 9 and 10.
    $cutoff = $Now.AddDays(-7 * ($RetentionWeeks - 1))
    $cutoffYear = [System.Globalization.ISOWeek]::GetYear($cutoff)
    $cutoffWeek = [System.Globalization.ISOWeek]::GetWeekOfYear($cutoff)
    foreach ($file in @(Get-ChildItem -LiteralPath $script:logDirectory -Filter 'WinTuner_GUI_*.log' -File -ErrorAction SilentlyContinue)) {
      $m = [regex]::Match($file.Name, '^WinTuner_GUI_(?<y>\d{4})-W(?<w>\d{2})\.log$')
      if (-not $m.Success) { continue }
      $year = [int]$m.Groups['y'].Value
      $week = [int]$m.Groups['w'].Value
      # Compare year and week as one sortable number so a December/January boundary is handled.
      if ((($year * 100) + $week) -lt (($cutoffYear * 100) + $cutoffWeek)) {
        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $removed++ } catch { }
      }
    }
  } catch { }   # class 3: housekeeping must never break startup
  return $removed
}

# Where packages are built by default. NOT C:\Temp, which used to be the default: that directory
# grants Modify to "Authenticated Users" on a standard Windows install, so any other signed-in user
# of this machine could alter a finished .intunewin between build and upload - and that package then
# goes to Intune and onto endpoints. LocalAppData is per-user and ACL-protected.
$script:legacyPackagePath = 'C:\Temp'
function Get-DefaultPackagePath {
  return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinTunerGUI\Packages')
}
$script:settings = @{
  WingetOverrides = @{}
  DefaultPackagePath = ''   # filled by Get-DefaultPackagePath below
  # Ship defaults: everything that changes Intune state stays OFF until the user opts in.
  # The login-time update search is off by default too: in large tenants it scans every app and
  # can take a long time, so it only runs once the user explicitly enables it in the settings.
  AutoCheckUpdates = $false
  AutoRemoveSuperseded = $false
  AutoVersionCleanup = $false
  # Exception to the "off by default" rule above, explicitly requested: after an update only the
  # NEWEST version may stay in scope, otherwise the predecessor has to be unassigned by hand.
  MoveAssignmentsOnUpdate = $true
  KeepVersionCount = 2
  ThemeName = "Light"
  Language = "en"
  RecentLogins = @()   # most-recent-first list of previously used UPNs, for quick re-selection
  MaxRecentLogins = 8
  # Entra group favorites, keyed by TENANT DOMAIN: @{ 'kunde.de' = @(@{Id=..; Name=..}) }.
  # Keyed per tenant on purpose - this is an MSP tool, and offering customer A's groups while
  # connected to customer B would invite assigning an app to the wrong organisation entirely.
  GroupFavorites = @{}
  WindowWidth = 0      # 0 = use the built-in default size
  WindowHeight = 0
  WindowMaximized = $false
  WindowLayoutVersion = 2
  # Persisted WinGet package ids which can be checked/built together into DefaultPackagePath.
  WingetFavorites = @()
  AutoUpdateFavoritesOnStartup = $false
  # One-time explanation of the intentionally disabled assigned-predecessor removal option.
  CleanupNoticeShown = $false
  # Re-confirm the production-risk warning after every GUI version change.
  ProductionWarningAcceptedVersion = ""
}

# Set when Load-Settings had to resolve a conflict, so the change can be logged and explained once
# the UI exists (Write-Log and the form are not available this early).
$script:cleanupConflictResolved = $false

# The two cleanup options are mutually exclusive BY CONSTRUCTION, not just by convention:
#   AutoRemoveSuperseded deletes the predecessor inside every successful update, so exactly one
#   version is ever left behind. AutoVersionCleanup keeps the newest KeepVersionCount versions and
#   trims the rest afterwards.
# With both enabled the first one always wins - it runs during the update, the second only after the
# whole batch - and "keep the newest 2" silently never applied to the app just updated. The Settings
# card offers them as an either/or; this function is the authority that also normalizes a settings
# file edited by hand. The conflict is resolved towards the NON-destructive option: a predecessor
# that is still there can be deleted later, one that is gone cannot be brought back.
function Resolve-CleanupOptionConflict {
  if (-not ($script:settings.AutoRemoveSuperseded -and $script:settings.AutoVersionCleanup)) { return $false }
  $script:settings.AutoRemoveSuperseded = $false
  if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
    Write-Log 'Cleanup options: both were active at the same time. Immediate removal of assigned predecessors was switched off; keeping the newest versions stays active.'
  }
  return $true
}

# Readers that cannot throw. The whole of Load-Settings used to sit in one try block, so a single
# unusable value - "KeepVersionCount": "abc" makes the [int] cast throw - abandoned everything after
# it and silently reset those settings to their defaults. The user lost the package path and the
# recent logins because of one bad number, and the catch could not even log it: Write-Log does not
# exist yet this early. Each value is now read on its own and falls back individually.
function Get-SettingValue {
  param(
    [Parameter(Mandatory)]$Source,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][ValidateSet('Bool', 'Int', 'String', 'StringArray')][string]$Type,
    [Parameter(Mandatory)]$Default,
    [int]$Minimum
  )
  try {
    if (-not $Source.PSObject.Properties[$Name]) { return $Default }
    $raw = $Source.$Name
    switch ($Type) {
      'Bool'   { return [bool]$raw }
      'Int'    {
        $number = [int]$raw
        if ($PSBoundParameters.ContainsKey('Minimum') -and $number -lt $Minimum) { return $Default }
        return $number
      }
      'String' { return [string]$raw }
      'StringArray' { return @([string[]]$raw) }
    }
    return $Default
  } catch {
    # Deliberately silent: this runs before Write-Log exists. The corrected value is what the user
    # sees in Settings, and it is written back on the next save.
    return $Default
  }
}

function Load-Settings {
  try {
    if (Test-Path $script:settingsPath) {
      $o = Get-Content -Path $script:settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($o) {
        # New settings with defaults
        if ($o.PSObject.Properties['DefaultPackagePath']) {
          $saved = [string]$o.DefaultPackagePath
          # Anyone still on the old C:\Temp default is moved to the per-user location. That value
          # was never a deliberate choice - it was ours - and the directory is writable by every
          # signed-in user of the machine. Existing packages stay where they are; only the target
          # for NEW builds changes, and it is logged so the move is never silent.
          if ([string]::Equals($saved.TrimEnd([char]'\'), $script:legacyPackagePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:settings.DefaultPackagePath = Get-DefaultPackagePath
            $script:packagePathMigrated = $true
          } else {
            $script:settings.DefaultPackagePath = $saved
          }
        } else {
          $script:settings.DefaultPackagePath = Get-DefaultPackagePath
        }

        $script:settings.AutoCheckUpdates        = Get-SettingValue -Source $o -Name 'AutoCheckUpdates'        -Type Bool -Default $false
        $script:settings.AutoRemoveSuperseded    = Get-SettingValue -Source $o -Name 'AutoRemoveSuperseded'    -Type Bool -Default $false
        $script:settings.AutoVersionCleanup      = Get-SettingValue -Source $o -Name 'AutoVersionCleanup'      -Type Bool -Default $false
        $script:settings.MoveAssignmentsOnUpdate = Get-SettingValue -Source $o -Name 'MoveAssignmentsOnUpdate' -Type Bool -Default $true
        # A missing/invalid KeepVersionCount only resets THAT value - it must never silently
        # re-enable the auto-removal opt-in the user just turned off.
        $script:settings.KeepVersionCount        = Get-SettingValue -Source $o -Name 'KeepVersionCount'        -Type Int  -Default 2 -Minimum 1
        $script:settings.ThemeName               = Get-SettingValue -Source $o -Name 'ThemeName'               -Type String -Default 'Light'
        $script:settings.Language                = Get-SettingValue -Source $o -Name 'Language'                -Type String -Default 'en'
        $script:settings.RecentLogins            = Get-SettingValue -Source $o -Name 'RecentLogins'            -Type StringArray -Default @()
        $script:settings.MaxRecentLogins         = Get-SettingValue -Source $o -Name 'MaxRecentLogins'         -Type Int  -Default 8 -Minimum 1

        # Restore the last user-selected window state. Releases before 0.13.2 saved these
        # values but never loaded them. Migrate only the exact former built-in default;
        # genuinely user-selected sizes must remain untouched.
        $savedLayoutVersion = Get-SettingValue -Source $o -Name 'WindowLayoutVersion' -Type Int -Default 1
        $savedWindowWidth   = Get-SettingValue -Source $o -Name 'WindowWidth'  -Type Int -Default 0
        $savedWindowHeight  = Get-SettingValue -Source $o -Name 'WindowHeight' -Type Int -Default 0
        if ($savedLayoutVersion -lt 2 -and $savedWindowWidth -eq 1040 -and $savedWindowHeight -eq 1026) {
          $savedWindowWidth = 0
          $savedWindowHeight = 0
        }
        $script:settings.WindowWidth = $savedWindowWidth
        $script:settings.WindowHeight = $savedWindowHeight
        $script:settings.WindowMaximized = Get-SettingValue -Source $o -Name 'WindowMaximized' -Type Bool -Default $false
        $script:settings.WindowLayoutVersion = 2

        if ($o.PSObject.Properties['WingetFavorites']) {
          $script:settings.WingetFavorites = @([string[]]$o.WingetFavorites |
            ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        } else {
          $script:settings.WingetFavorites = @()
        }
        if ($o.PSObject.Properties['AutoUpdateFavoritesOnStartup']) {
          $script:settings.AutoUpdateFavoritesOnStartup = [bool]$o.AutoUpdateFavoritesOnStartup
        } else {
          $script:settings.AutoUpdateFavoritesOnStartup = $false
        }
        if ($o.PSObject.Properties['CleanupNoticeShown']) {
          $script:settings.CleanupNoticeShown = [bool]$o.CleanupNoticeShown
        } else {
          $script:settings.CleanupNoticeShown = $false
        }
        if ($o.PSObject.Properties['ProductionWarningAcceptedVersion']) {
          $script:settings.ProductionWarningAcceptedVersion = [string]$o.ProductionWarningAcceptedVersion
        } else {
          $script:settings.ProductionWarningAcceptedVersion = ""
        }

        if ($o.PSObject.Properties['WingetOverrides']) {
          # Convert PSCustomObject to hashtable
          $ht = @{}
          foreach ($p in $o.WingetOverrides.PSObject.Properties) { $ht[$p.Name] = [string]$p.Value }
          $script:settings.WingetOverrides = $ht
        } else { $script:settings.WingetOverrides = @{} }

        # Group favorites per tenant domain. Anything malformed is dropped rather than repaired:
        # a half-read favorite would put an unverified GUID in front of an assignment action.
        if ($o.PSObject.Properties['GroupFavorites']) {
          $fav = @{}
          foreach ($p in $o.GroupFavorites.PSObject.Properties) {
            $entries = @()
            foreach ($e in @($p.Value)) {
              $id = [string]$e.Id
              $name = [string]$e.Name
              if ($id -match '^[0-9a-fA-F-]{36}$' -and -not [string]::IsNullOrWhiteSpace($name)) {
                $entries += @{ Id = $id; Name = $name }
              }
            }
            if ($entries.Count -gt 0) { $fav[$p.Name] = $entries }
          }
          $script:settings.GroupFavorites = $fav
        } else { $script:settings.GroupFavorites = @{} }
      }
    }
  } catch {
    # Load-Settings runs very early – before Write-Log is defined – so guard the call so a
    # malformed settings file logs a warning where possible but never throws a secondary
    # "Write-Log not recognized" error on top of it. Defaults are kept either way.
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
      Write-Log "Warning: Failed to load settings from $($script:settingsPath): $($_.Exception.Message)"
    }
    # Continue with default settings
  }
  # Runs outside the try block on purpose: a settings file that failed to parse leaves the defaults
  # in place, and those must be normalized just the same.
  if (Resolve-CleanupOptionConflict) { $script:cleanupConflictResolved = $true }
}

function Save-Settings {
  try {
    $dir = Split-Path -Parent $script:settingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # -Depth 6 is required, not cosmetic: the default of 2 silently serialises anything deeper as
    # the literal string "System.Collections.Hashtable". GroupFavorites is tenant -> list of
    # objects and would be destroyed on the first save without this.
    $json = $script:settings | ConvertTo-Json -Compress -Depth 6
    # Never write straight into the live settings file: a crash/power loss mid-write leaves it
    # truncated and the next start loses the package path + recent logins. Write a temp file,
    # verify it parses, then swap it in – the real file is only ever replaced by a complete one.
    $tmp = "$($script:settingsPath).tmp"
    Set-Content -Path $tmp -Value $json -Encoding utf8 -NoNewline -ErrorAction Stop
    $null = (Get-Content -Raw -Path $tmp -ErrorAction Stop | ConvertFrom-Json)   # integrity gate
    Move-Item -Path $tmp -Destination $script:settingsPath -Force -ErrorAction Stop
  } catch {
    Write-Log "Error: Failed to save settings to $($script:settingsPath): $($_.Exception.Message)"
    try { Remove-Item "$($script:settingsPath).tmp" -Force -ErrorAction SilentlyContinue } catch { }   # class 3: temp cleanup
  }
}

# Records a successful login UPN at the front of the recent-logins list (deduped, capped)
# and persists it, so it can be re-selected quickly from the header dropdown next time.
function Add-RecentLogin {
  param([string]$Upn)
  if ([string]::IsNullOrWhiteSpace($Upn)) { return }
  $max = if ($script:settings.MaxRecentLogins -gt 0) { $script:settings.MaxRecentLogins } else { 8 }
  $list = [System.Collections.Generic.List[string]]::new()
  $list.Add($Upn)
  foreach ($u in @($script:settings.RecentLogins)) {
    if ($u -and ($u -ne $Upn) -and (-not $list.Contains($u))) { $list.Add($u) }
  }
  while ($list.Count -gt $max) { $list.RemoveAt($list.Count - 1) }
  $script:settings.RecentLogins = $list.ToArray()
  Save-Settings
}

# --- Entra group favorites, scoped to the signed-in tenant ---------------------------------------
#
# The key is the domain part of the signed-in UPN, so each customer keeps its own list and no group
# of another tenant is ever offered. Without a session there is no key, and therefore no favorites:
# a GUID from the wrong tenant would simply fail at assignment time, but showing it at all would
# invite the mistake.

function Get-TenantFavoriteKey {
  $upn = [string]$script:currentUserUpn
  if ([string]::IsNullOrWhiteSpace($upn) -or $upn -notmatch '@') { return "" }
  try { return ($upn -split '@')[-1].Trim().ToLowerInvariant() } catch { return "" }
}

function Get-GroupFavorites {
  $key = Get-TenantFavoriteKey
  if (-not $key) { return @() }
  if (-not $script:settings.GroupFavorites) { return @() }
  if (-not $script:settings.GroupFavorites.ContainsKey($key)) { return @() }
  return @($script:settings.GroupFavorites[$key])
}

# Adds or renames a favorite for the current tenant. The id is validated here rather than at the
# call site, because this is the only door into the stored list.
function Add-GroupFavorite {
  param([string]$Id, [string]$Name)
  $key = Get-TenantFavoriteKey
  if (-not $key) { return $false }
  $gid = ([string]$Id).Trim()
  $label = ([string]$Name).Trim()
  if ($gid -notmatch '^[0-9a-fA-F-]{36}$') { return $false }
  if ([string]::IsNullOrWhiteSpace($label)) { return $false }
  if (-not $script:settings.GroupFavorites) { $script:settings.GroupFavorites = @{} }
  $existing = @(Get-GroupFavorites)
  $updated = @()
  $replaced = $false
  foreach ($e in $existing) {
    if (([string]$e.Id) -eq $gid) { $updated += @{ Id = $gid; Name = $label }; $replaced = $true }
    else { $updated += $e }
  }
  if (-not $replaced) { $updated += @{ Id = $gid; Name = $label } }
  $script:settings.GroupFavorites[$key] = $updated
  Save-Settings
  return $true
}

function Remove-GroupFavorite {
  param([string]$Id)
  $key = Get-TenantFavoriteKey
  if (-not $key) { return $false }
  $gid = ([string]$Id).Trim()
  $kept = @(Get-GroupFavorites | Where-Object { ([string]$_.Id) -ne $gid })
  if ($kept.Count -eq 0) { $null = $script:settings.GroupFavorites.Remove($key) }
  else { $script:settings.GroupFavorites[$key] = $kept }
  Save-Settings
  return $true
}

# Full logout hygiene: deletes the on-disk Microsoft.Graph token cache so a later login
# cannot silently resume the old session, and forces the next login to bypass the Windows
# auth broker (WAM). Shared by the Logout button and the tenant-switch nudge.
function Clear-GraphTokenCache {
  try {
    $mgCacheDir = Join-Path $env:LOCALAPPDATA ".IdentityService"
    Get-ChildItem -Path $mgCacheDir -Filter "mg.msal.cache*" -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  } catch {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
      Write-Log "Could not clear Graph token cache: $($_.Exception.Message)"
    }
  }
  $script:forceFreshLogin = $true
  $script:lastTenantDomain = ""
}

Load-Settings


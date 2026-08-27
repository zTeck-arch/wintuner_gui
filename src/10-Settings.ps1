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
$script:logDirectory = Join-Path (Get-LocalAppDataRoot) 'WinTunerGUI\Logs'
try {
  if (-not (Test-Path -LiteralPath $script:logDirectory -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($script:logDirectory)
  }
} catch {
  # Never let logging be the reason the application cannot start: fall back to the profile root.
  $script:logDirectory = Get-LocalAppDataRoot
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
  return (Join-Path (Get-LocalAppDataRoot) 'WinTunerGUI\Packages')
}

# Maps a stored DefaultPackagePath to the value the app should actually use. Empty/whitespace OR the
# old C:\Temp default both resolve to the safe per-user path; anything else is kept. Returns
# @{ Path = <string>; Migrated = <bool> } - Migrated is $true only when C:\Temp was replaced, so the
# caller can flag the one-time move. Split out from Load-Settings so it can be unit-tested.
function Resolve-PackagePathSetting {
  param([string]$Saved)
  if ([string]::IsNullOrWhiteSpace($Saved)) {
    return @{ Path = (Get-DefaultPackagePath); Migrated = $false }
  }
  if ([string]::Equals($Saved.TrimEnd([char]'\'), $script:legacyPackagePath, [System.StringComparison]::OrdinalIgnoreCase)) {
    return @{ Path = (Get-DefaultPackagePath); Migrated = $true }
  }
  return @{ Path = $Saved; Migrated = $false }
}
$script:settings = @{
  WingetOverrides = @{}
  # Seed with the safe per-user default so a fresh install (no settings.json) is NEVER empty - an
  # empty value made the Settings card fall back to C:\Temp. Load-Settings overrides it from disk.
  DefaultPackagePath = (Get-DefaultPackagePath)
  # Ship defaults: everything that changes Intune state stays OFF until the user opts in.
  # The login-time update search is off by default too: in large tenants it scans every app and
  # can take a long time, so it only runs once the user explicitly enables it in the settings.
  AutoCheckUpdates = $false
  # Optionale Leseberechtigungen (Gruppennamen, erkannte Apps) schon bei der Anmeldung holen.
  # Aus, weil es einen zweiten Anmeldevorgang kostet und ohne sie alles ausser diesen zwei
  # Auskuenften funktioniert - wer sie regelmaessig braucht, schaltet es ein und spart die Nachfrage.
  RequestOptionalScopesOnLogin = $false
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
  # Aufgeklapptes Aktivitätsprotokoll belegte 120 px im Ruhezustand und bis zu 40 % der Fensterhöhe
  # während eines Laufs - und zeigte dabei dieselbe Zeile, die schon in der Statuszeile steht.
  # Eingeklappt als Standard; wer es aufklappt, findet es beim nächsten Start wieder offen, wie bei
  # der Fenstergröße auch.
  LogExpanded = $false
  # Suche nach Programm-Updates beim Start. EIN als Standard, weil das dem bisherigen, fest
  # verdrahteten Verhalten entspricht - abschaltbar ist neu, nicht das Suchen selbst. Ohne
  # konfiguriertes Repository ($script:githubRepo) passiert ohnehin nichts.
  CheckAppUpdateOnStartup = $true
  # Persisted WinGet package ids which can be checked/built together into DefaultPackagePath.
  WingetFavorites = @()
  AutoUpdateFavoritesOnStartup = $false
  # One-time explanation of the intentionally disabled assigned-predecessor removal option.
  CleanupNoticeShown = $false
  # Re-confirm the production-risk warning after every GUI version change.
  ProductionWarningAcceptedVersion = ""
  # Safety net: read and keep an app's assignments BEFORE it is deleted, so a scope that turns out
  # to have been needed can still be looked up afterwards. On by default - it costs one Graph read
  # per deletion and is the only record of a scope once the app object is gone.
  SaveScopeBeforeRemoval = $true
  # Friendly names for tenants, keyed by UPN: @{ 'admin@kunde.de' = 'Kunde GmbH' }. Only affects
  # what is DISPLAYED; every sign-in still uses the UPN.
  TenantDisplayNames = @{}
  # Lets an experienced technician turn off the "are you sure?" prompts for changes. Guarded by
  # RiskAcceptedVersion below, so it has to be acknowledged once per version.
  SuppressChangeConfirmations = $false
  ChangeConfirmationRiskAcceptedVersion = ""
  # Dashboard "Updates available" tile: compare versions for real instead of trusting Intune's own
  # UpdateAvailable flag. OFF by default because it costs one package lookup per app - the same work
  # the update scan does - and the dashboard is what you see first after signing in.
  DashboardUpdatesFullScan = $false
}

# Set when Load-Settings had to resolve a conflict, so the change can be logged and explained once
# the UI exists (Write-Log and the form are not available this early).
$script:cleanupConflictResolved = $false

# Der Abdruck der wirksamen Einstellungen fuer das Protokoll.
#
# Angefragt fuer die Fehlersuche: ohne zu wissen, WIE die Anwendung eingestellt ist, laesst sich ein
# fremdes Protokoll nicht lesen - "warum sucht er beim Anmelden Updates?" und "warum fragt er nicht
# nach?" haengen beide an einem Haken, den man nicht sieht.
#
# Was NICHT hineingehoert: Kundennamen, Anmeldeadressen, Gruppen-IDs. Das Protokoll wird
# weitergegeben (Ticket, Rueckfrage beim Hersteller), und diese Angaben sind Kundendaten. Von solchen
# Listen steht deshalb nur die ANZAHL da - die beantwortet die Frage "hat die Person ueberhaupt
# Favoriten/Gruppen gepflegt?" genauso gut. Pfade bleiben vollstaendig: der Benutzername steht
# ohnehin schon in der Umgebungszeile, und ein halber Pfad hat noch nie einen Fehler erklaert.
#
# Rein: gibt Zeilen zurueck, schreibt nichts. So ist der Inhalt pruefbar, ohne ein Protokoll zu
# brauchen - und der Aufrufer entscheidet, ob er sie beim Start oder nach dem Speichern schreibt.
function Get-SettingsSnapshotLines {
  param(
    $Settings = $script:settings,
    [string]$Prefix = 'Settings',
    [string]$SettingsPath = $script:settingsPath,
    [string]$LogFolder = $script:logDirectory,
    [int]$RetentionWeeks = $script:logRetentionWeeks
  )
  $lines = [System.Collections.Generic.List[string]]::new()
  if (-not $Settings) {
    $lines.Add("$Prefix | (no settings loaded)")
    return @($lines.ToArray())
  }
  # Hilfsfunktionen: fehlende Schluessel sollen '-' bzw. 0 ergeben, nicht die Zeile sprengen.
  $val = { param($name, $fallback = '-')
    try { if ($null -ne $Settings[$name] -and "$($Settings[$name])" -ne '') { return $Settings[$name] } } catch { }
    return $fallback
  }
  $count = { param($name)
    try {
      $v = $Settings[$name]
      if ($null -eq $v) { return 0 }
      if ($v -is [hashtable]) { return $v.Keys.Count }
      return @($v).Count
    } catch { return 0 }
  }

  $lines.Add(("{0} | file={1} | packageFolder={2} | logFolder={3} | logRetentionWeeks={4}" -f `
    $Prefix, $SettingsPath, (& $val 'DefaultPackagePath'), $LogFolder, $RetentionWeeks))
  $lines.Add(("{0} | theme={1} | lang={2} | window={3}x{4} maximized={5} logExpanded={6}" -f `
    $Prefix, (& $val 'ThemeName'), (& $val 'Language'), (& $val 'WindowWidth' 0), (& $val 'WindowHeight' 0),
    (& $val 'WindowMaximized' $false), (& $val 'LogExpanded' $false)))
  # Die Zeile, die die meisten Rueckfragen beantwortet: was passiert von selbst?
  $lines.Add(("{0} | onLogin: updateSearch={1} optionalScopes={2} | onStartup: selfUpdateCheck={3} favouritesRun={4} | dashboardFullScan={5}" -f `
    $Prefix, (& $val 'AutoCheckUpdates' $false), (& $val 'RequestOptionalScopesOnLogin' $false),
    (& $val 'CheckAppUpdateOnStartup' $false), (& $val 'AutoUpdateFavoritesOnStartup' $false),
    (& $val 'DashboardUpdatesFullScan' $false)))
  $lines.Add(("{0} | update run: moveAssignments={1} removePredecessor={2} versionCleanup={3} keepNewest={4} saveScopeBeforeRemoval={5}" -f `
    $Prefix, (& $val 'MoveAssignmentsOnUpdate' $false), (& $val 'AutoRemoveSuperseded' $false),
    (& $val 'AutoVersionCleanup' $false), (& $val 'KeepVersionCount' 0), (& $val 'SaveScopeBeforeRemoval' $false)))
  $lines.Add(("{0} | confirmations suppressed={1} (accepted for version '{2}') | production warning accepted for version '{3}'" -f `
    $Prefix, (& $val 'SuppressChangeConfirmations' $false), (& $val 'ChangeConfirmationRiskAcceptedVersion' ''),
    (& $val 'ProductionWarningAcceptedVersion' '')))
  # Nur Anzahlen: Namen, Adressen und Gruppen-IDs sind Kundendaten.
  $lines.Add(("{0} | counts only (customer data is deliberately not logged): favourites={1} recentLogins={2} groupFavouriteTenants={3} tenantDisplayNames={4} wingetOverrides={5}" -f `
    $Prefix, (& $count 'WingetFavorites'), (& $count 'RecentLogins'), (& $count 'GroupFavorites'),
    (& $count 'TenantDisplayNames'), (& $count 'WingetOverrides')))
  return @($lines.ToArray())
}

# Set when the settings file existed but could not be read. Holds the path of the copy that was put
# aside, so the UI can tell the user where their old values went instead of losing them in silence.
$script:settingsCorruptBackupPath = $null

# Preserves an unreadable settings file before the defaults can overwrite it.
#
# A settings file that fails to parse used to be handled by simply keeping the defaults - and the
# next Save-Settings then wrote those defaults straight over it. Whatever was still recoverable by
# hand (package path, recent logins, per-tenant group favourites) was gone for good, and nothing ever
# said so. Copying first costs nothing and makes the loss reversible.
#
# Returns the backup path, or $null when there was nothing to preserve. Never throws: this runs
# before Write-Log exists, and failing to make a backup must not stop the application from starting.
function Backup-CorruptSettingsFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    # Injectable so a test does not depend on the clock.
    [datetime]$Now = (Get-Date)
  )
  try {
    if (-not [IO.File]::Exists($Path)) { return $null }
    # An empty file carries nothing worth preserving, and a stray 0-byte backup would only confuse.
    if (([IO.FileInfo]::new($Path)).Length -eq 0) { return $null }
    $backup = '{0}.corrupt-{1}' -f $Path, $Now.ToString('yyyyMMdd-HHmmss')
    # Suffix on collision instead of overwriting: two bad starts in the same second must not cost
    # the first backup, which is the one closest to the user's real data.
    $candidate = $backup
    $suffix = 1
    while ([IO.File]::Exists($candidate)) {
      $candidate = '{0}-{1}' -f $backup, $suffix
      $suffix++
      if ($suffix -gt 50) { return $null }
    }
    [IO.File]::Copy($Path, $candidate)
    return $candidate
  } catch {
    return $null
  }
}

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

# --- Einmal-Übernahme der Daten aus einer Vorabfassung -------------------------------------------
#
# Zwischen 0.15.8 und 0.16.0 hieß die Anwendung eine Zeit lang "Verteilwerk" und legte ihre Daten
# unter %APPDATA%\Verteilwerk bzw. %LOCALAPPDATA%\Verteilwerk ab. Diese Umbenennung ist
# zurückgenommen - der Name ist wieder "WinTuner GUI", die Ordner heißen wieder WinTunerGUI.
# Veröffentlicht wurde die Zwischenfassung nie; wer sie aber aus dem Quellbaum gebaut und benutzt
# hat, hätte seine Einstellungen sonst scheinbar verloren. Deshalb bleibt die Übernahme stehen, nur
# in die andere Richtung.
#
# KOPIEREN, nicht verschieben. Der Rückweg ist mehr wert als der aufgeräumte Ordner; der Preis ist
# ein verwaister Ordner von wenigen Kilobyte.
$script:legacyDataFolderName = 'Verteilwerk'

# Kopiert eine einzelne Datei aus dem alten in den neuen Ordner, wenn es dort noch keine gibt.
# Gibt den Quellpfad zurück, wenn kopiert wurde - sonst $null, damit der Aufrufer protokollieren
# kann, was tatsächlich passiert ist. Wirft nie: das läuft vor Write-Log und darf den Start nicht
# verhindern.
function Copy-LegacyDataFile {
  param(
    [Parameter(Mandatory)][string]$CurrentPath,
    # BEWUSST nicht Mandatory: der Aufrufer übergibt das Ergebnis von Get-LegacyDataPath, und das
    # ist $null, wenn der neue Pfad den Anwendungsordner nicht enthält. Mit [Parameter(Mandatory)]
    # hätte genau dieser Fall am Aufruf geworfen - beim Start, vor Write-Log, also als Anwendung,
    # die nicht startet. Die Prüfung unten fängt es ab und tut schlicht nichts.
    [string]$LegacyPath = ''
  )
  try {
    if ([string]::IsNullOrWhiteSpace($LegacyPath)) { return $null }
    # Eine schon vorhandene neue Datei ist immer die Wahrheit - eine zweite Übernahme würde sie
    # durch einen älteren Stand ersetzen.
    if ([IO.File]::Exists($CurrentPath)) { return $null }
    if (-not [IO.File]::Exists($LegacyPath)) { return $null }
    if (([IO.FileInfo]::new($LegacyPath)).Length -eq 0) { return $null }
    $dir = Split-Path -Parent $CurrentPath
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
      [void][System.IO.Directory]::CreateDirectory($dir)
    }
    [IO.File]::Copy($LegacyPath, $CurrentPath)
    return $LegacyPath
  } catch {
    return $null
  }
}

# Baut den Pfad derselben Datei im Ordner der Vorabfassung. Ersetzt nur das letzte Vorkommen des
# Ordnernamens, damit ein Benutzerprofil, das selbst "WinTunerGUI" heißt, nicht mitverbogen wird.
$script:currentDataFolderName = 'WinTunerGUI'
function Get-LegacyDataPath {
  param([Parameter(Mandatory)][string]$CurrentPath)
  try {
    $idx = $CurrentPath.LastIndexOf($script:currentDataFolderName)
    if ($idx -lt 0) { return $null }
    return $CurrentPath.Substring(0, $idx) + $script:legacyDataFolderName + $CurrentPath.Substring($idx + $script:currentDataFolderName.Length)
  } catch { return $null }
}

# Was übernommen wird und was nicht:
#   settings.json        - ja. Enthält Paketordner, gemerkte Anmeldungen, Gruppenfavoriten,
#                          Tenant-Namen und die Aufräum-Optionen. Der eigentliche Wert.
#   activity-history.json- ja. Speist den Leistungsnachweis; ein verlorener Nachweis ist nicht
#                          rekonstruierbar. Wird in 50-UpdateEngine mit übernommen.
#   Protokolle           - nein. Laufen ohnehin nach zwei Wochen aus, und der alte Ordner bleibt
#                          lesbar. Sie zu kopieren würde Kundendaten verdoppeln, statt sie zu
#                          bewegen - genau das, was die Löschfrist verhindern soll.
#   Pakete               - nein. Der Pfad steht IN settings.json und wandert damit mit; gebaute
#                          Pakete bleiben liegen, wo sie sind. Gigabytes zu verschieben, um einen
#                          Ordnernamen zu ändern, wäre das falsche Geschäft.
#   version-cache.json   - nein. Ein Cache. Die nächste Suche baut ihn neu auf.
$script:legacySettingsCopied = $null
$script:legacySettingsCopied = Copy-LegacyDataFile -CurrentPath $script:settingsPath -LegacyPath (Get-LegacyDataPath -CurrentPath $script:settingsPath)

function Load-Settings {
  try {
    # Unterscheidet einen Bestandsnutzer von einer frischen Installation. Nur der Bestand bekommt
    # den Umzugshinweis; wer heute zum ersten Mal startet, hat nie einen alten Ort gekannt.
    # ($script:settingsFileExisted ist entfallen: der einzige Leser war der Umzugshinweis.)
    if (Test-Path -LiteralPath $script:settingsPath) {
      $o = Get-Content -LiteralPath $script:settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($o) {
        # New settings with defaults
        # Missing, empty, or the legacy C:\Temp default all resolve to the safe per-user path. The
        # C:\Temp move is logged via $script:packagePathMigrated so it is never silent; existing
        # packages stay where they are, only the target for NEW builds changes.
        $saved = if ($o.PSObject.Properties['DefaultPackagePath']) { [string]$o.DefaultPackagePath } else { '' }
        $resolvedPath = Resolve-PackagePathSetting -Saved $saved
        $script:settings.DefaultPackagePath = $resolvedPath.Path
        if ($resolvedPath.Migrated) { $script:packagePathMigrated = $true }

        $script:settings.AutoCheckUpdates        = Get-SettingValue -Source $o -Name 'AutoCheckUpdates'        -Type Bool -Default $false
        $script:settings.RequestOptionalScopesOnLogin = Get-SettingValue -Source $o -Name 'RequestOptionalScopesOnLogin' -Type Bool -Default $false
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
        $script:settings.LogExpanded = Get-SettingValue -Source $o -Name 'LogExpanded' -Type Bool -Default $false
        $script:settings.CheckAppUpdateOnStartup = Get-SettingValue -Source $o -Name 'CheckAppUpdateOnStartup' -Type Bool -Default $true
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
        $script:settings.SaveScopeBeforeRemoval = Get-SettingValue -Source $o -Name 'SaveScopeBeforeRemoval' -Type Bool -Default $true
        $script:settings.DashboardUpdatesFullScan = Get-SettingValue -Source $o -Name 'DashboardUpdatesFullScan' -Type Bool -Default $false
        $script:settings.SuppressChangeConfirmations = Get-SettingValue -Source $o -Name 'SuppressChangeConfirmations' -Type Bool -Default $false
        $script:settings.ChangeConfirmationRiskAcceptedVersion = Get-SettingValue -Source $o -Name 'ChangeConfirmationRiskAcceptedVersion' -Type String -Default ''
        # Friendly tenant names: a plain UPN -> string map. Anything that is not a usable pair is
        # dropped rather than repaired, like the group favourites above.
        if ($o.PSObject.Properties['TenantDisplayNames']) {
          $names = @{}
          foreach ($prop in $o.TenantDisplayNames.PSObject.Properties) {
            $upn = [string]$prop.Name
            $label = [string]$prop.Value
            if (-not [string]::IsNullOrWhiteSpace($upn) -and -not [string]::IsNullOrWhiteSpace($label)) {
              $names[$upn] = $label
            }
          }
          $script:settings.TenantDisplayNames = $names
        } else { $script:settings.TenantDisplayNames = @{} }
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
    # Preserve the unreadable file BEFORE anything can save the defaults over it. Without this the
    # first Save-Settings destroyed the only copy of the user's package path, recent logins and
    # group favourites, and the loss was never mentioned anywhere.
    $script:settingsCorruptBackupPath = Backup-CorruptSettingsFile -Path $script:settingsPath
    if ($script:settingsCorruptBackupPath -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
      Write-Log "Unreadable settings file was copied to $($script:settingsCorruptBackupPath) before defaults were applied."
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
    # New-Item has no -LiteralPath, so the .NET call is used for a settings folder whose name
    # may contain brackets.
    if (-not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    # -Depth 6 is required, not cosmetic: the default of 2 silently serialises anything deeper as
    # the literal string "System.Collections.Hashtable". GroupFavorites is tenant -> list of
    # objects and would be destroyed on the first save without this.
    $json = $script:settings | ConvertTo-Json -Compress -Depth 6
    # Never write straight into the live settings file: a crash/power loss mid-write leaves it
    # truncated and the next start loses the package path + recent logins. Write a temp file,
    # verify it parses, then swap it in – the real file is only ever replaced by a complete one.
    $tmp = "$($script:settingsPath).tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8 -NoNewline -ErrorAction Stop
    $null = (Get-Content -Raw -LiteralPath $tmp -ErrorAction Stop | ConvertFrom-Json)   # integrity gate
    Move-Item -LiteralPath $tmp -Destination $script:settingsPath -Force -ErrorAction Stop
  } catch {
    Write-Log "Error: Failed to save settings to $($script:settingsPath): $($_.Exception.Message)"
    try { Remove-Item -LiteralPath "$($script:settingsPath).tmp" -Force -ErrorAction SilentlyContinue } catch { }   # class 3: temp cleanup
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

# Names the MSAL/Graph cache files this application writes under %LOCALAPPDATA%\.IdentityService.
# The WinTuner module registers its own named client, so the actual session cache is
# 'WinTuner-PowerShell.nocae' - NOT 'mg.msal.cache*', which is why the old single-filter delete
# missed the file that held the refresh token. The generic Graph SDK caches are included too so a
# session opened through either path is cleared.
$script:tokenCacheFilePatterns = @('WinTuner-PowerShell*', 'msal.cache*', 'mg.msal.cache*')

# Deletes the application-owned token-cache files from $Directory and returns how many were removed.
# Split out from Clear-GraphTokenCache so the logout guarantee in SECURITY.md can be unit-tested.
function Remove-TokenCacheFiles {
  param(
    [Parameter(Mandatory)][string]$Directory,
    [string[]]$Patterns = $script:tokenCacheFilePatterns
  )
  $removed = 0
  if (-not (Test-Path -LiteralPath $Directory)) { return 0 }
  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($pattern in $Patterns) {
    foreach ($f in @(Get-ChildItem -LiteralPath $Directory -Filter $pattern -File -ErrorAction SilentlyContinue)) {
      if (-not $seen.Add($f.FullName)) { continue }   # a file can match more than one pattern
      try {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        $removed++
      } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
          Write-Log "Token cache: could not delete '$($f.Name)': $($_.Exception.Message)"
        }
      }
    }
  }
  return $removed
}

# Full logout hygiene: deletes the on-disk MSAL/Graph token cache so a later login cannot silently
# resume the old session, and forces the next login to bypass the Windows auth broker (WAM). Shared
# by the Logout button and the tenant-switch nudge.
function Clear-GraphTokenCache {
  try {
    $cacheDir = Join-Path $env:LOCALAPPDATA ".IdentityService"
    $removed = Remove-TokenCacheFiles -Directory $cacheDir
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
      if ($removed -gt 0) {
        Write-Log "Token cache: removed $removed file(s)."
      } else {
        # Zero hits is exactly how the old broken filter hid itself - worth a warning, not silence.
        Write-Log "Token cache: no cache files found to remove (expected 'WinTuner-PowerShell.nocae' under .IdentityService)."
      }
    }
  } catch {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
      Write-Log "Could not clear Graph token cache: $($_.Exception.Message)"
    }
  }
  $script:forceFreshLogin = $true
  $script:lastTenantDomain = ""
}

Load-Settings


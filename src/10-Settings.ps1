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
  # 15 statt 8: ein MSP betreut mehr Kunden als das, und der neunte fiel bisher lautlos hinten
  # heraus - im Verlauf sah es dann aus, als haette man sich dort nie angemeldet. Die Liste ist
  # eine reine Bequemlichkeit (Adresse vorschlagen), sie haelt keine Sitzung offen; laenger zu sein
  # kostet nichts ausser Menuehoehe. Wer mehr oder weniger will, setzt MaxRecentLogins in der
  # settings.json.
  MaxRecentLogins = 15
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
  # Update-Suche auch ueber Win32-Apps OHNE '[WinTuner|'-Marke laufen lassen.
  #
  # AN, weil die Marke die falsche Frage beantwortet: sie sagt, wer die App angelegt hat, nicht ob
  # es ein WinGet-Gegenstueck gibt. Handgebaute Pakete sind ebenfalls .intunewin-Apps, und die Marke
  # wird im Betrieb auch wieder entfernt - beides liess Apps aus der Suche verschwinden, die sehr
  # wohl aktualisierbar sind. Die Sicherheit liegt nicht an dieser Einstellung, sondern an
  # Resolve-WingetIdForApp: ohne exakten Namen, hochsicheren Treffer oder Override wird KEINE
  # Paket-Id angenommen, und ohne Paket-Id passiert an der App nichts.
  ScanUnmanagedWin32Apps = $true
  # Apps, die nie versehentlich abgelöst werden sollen: selbst paketierte Kundensoftware wie
  # Splashtop, TeamViewer oder ein Passwortmanager. Namen oder Muster mit '*'.
  #
  # GLOBAL, nicht je Tenant - anders als die Gruppen-Favoriten. Der Unterschied ist Absicht: eine
  # Liste je Kunde fängt bei jeder NEUEN Umgebung leer an, und genau dort passiert der Unfall.
  # Produktnamen sind ausserdem keine Kundendaten, es gibt also nichts zu trennen.
  ProtectedApps = @()
  # Welche Werksmuster schon einmal eingetragen wurden. Ohne diesen Merker gaebe es nur zwei
  # schlechte Moeglichkeiten: die Werksliste bei jedem Start erzwingen (dann kann der Benutzer
  # keines davon loswerden - es kaeme beim naechsten Start zurueck) oder sie nur bei einer frischen
  # Installation setzen (dann bekaeme sie niemand, der die Anwendung schon benutzt). Der Merker
  # trennt "hat der Benutzer bewusst entfernt" von "kannte er noch nicht".
  ProtectedAppsSeeded = @()
}

# Set when Load-Settings had to resolve a conflict, so the change can be logged and explained once
# the UI exists (Write-Log and the form are not available this early).
$script:cleanupConflictResolved = $false

# Welche Werksmuster dieser Start ergaenzt hat. Wird gesetzt, solange es noch kein Protokoll gibt,
# und beim Anzeigen des Fensters einmal protokolliert und gespeichert (90-Main).
$script:protectedAppsSeeded = @()

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
  $lines.Add(("{0} | onLogin: updateSearch={1} optionalScopes={2} | onStartup: selfUpdateCheck={3} favouritesRun={4} | dashboardFullScan={5} scanUnmarkedWin32={6}" -f `
    $Prefix, (& $val 'AutoCheckUpdates' $false), (& $val 'RequestOptionalScopesOnLogin' $false),
    (& $val 'CheckAppUpdateOnStartup' $false), (& $val 'AutoUpdateFavoritesOnStartup' $false),
    (& $val 'DashboardUpdatesFullScan' $false), (& $val 'ScanUnmanagedWin32Apps' $true)))
  $lines.Add(("{0} | update run: moveAssignments={1} removePredecessor={2} versionCleanup={3} keepNewest={4} saveScopeBeforeRemoval={5}" -f `
    $Prefix, (& $val 'MoveAssignmentsOnUpdate' $false), (& $val 'AutoRemoveSuperseded' $false),
    (& $val 'AutoVersionCleanup' $false), (& $val 'KeepVersionCount' 0), (& $val 'SaveScopeBeforeRemoval' $false)))
  $lines.Add(("{0} | confirmations suppressed={1} (accepted for version '{2}') | production warning accepted for version '{3}'" -f `
    $Prefix, (& $val 'SuppressChangeConfirmations' $false), (& $val 'ChangeConfirmationRiskAcceptedVersion' ''),
    (& $val 'ProductionWarningAcceptedVersion' '')))
  # Nur Anzahlen: Namen, Adressen und Gruppen-IDs sind Kundendaten.
  $lines.Add(("{0} | counts only (customer data is deliberately not logged): favourites={1} recentLogins={2} groupFavouriteTenants={3} tenantDisplayNames={4} wingetOverrides={5} protectedApps={6}" -f `
    $Prefix, (& $count 'WingetFavorites'), (& $count 'RecentLogins'), (& $count 'GroupFavorites'),
    (& $count 'TenantDisplayNames'), (& $count 'WingetOverrides'), (& $count 'ProtectedApps')))
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
    [int]$Minimum,
    # Obergrenze, gleiche Behandlung wie -Minimum: ausserhalb des Bereichs gilt die Vorgabe.
    #
    # Wichtig ist, wo sie NICHT hingehoert: eine Obergrenze auf KeepVersionCount waere gefaehrlich.
    # Ein zu hoher Wert bewahrt dort nur mehr Versionen (harmlose Richtung) - ein Rueckfall auf die
    # Vorgabe 2 wuerde genau die Versionen LOESCHEN, die der Benutzer behalten wollte. Grenzen also
    # nur dort, wo ein absurder Wert wirklich stoert und ein Rueckfall nichts kaputt macht.
    [int]$Maximum
  )
  try {
    if (-not $Source.PSObject.Properties[$Name]) { return $Default }
    $raw = $Source.$Name
    switch ($Type) {
      'Bool'   { return [bool]$raw }
      'Int'    {
        $number = [int]$raw
        if ($PSBoundParameters.ContainsKey('Minimum') -and $number -lt $Minimum) { return $Default }
        if ($PSBoundParameters.ContainsKey('Maximum') -and $number -gt $Maximum) { return $Default }
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

# --- Geschützte Apps ----------------------------------------------------------------------------
#
# Selbst paketierte Kundensoftware (Splashtop, TeamViewer, Passwortmanager) darf nie versehentlich
# abgelöst werden - aber sichtbar bleiben muss sie, sonst kann niemand die Umgebung pflegen.
# Deshalb kein Filter, sondern eine Markierung: die Zeile steht in der Liste, ist anhakbar, und der
# Lauf fragt vorher ausdrücklich nach (und zwar auch dann, wenn Rückfragen abgeschaltet sind).
#
# Diese drei Funktionen sind rein und stehen hier oben, weil Load-Settings am Ende dieser Datei
# schon läuft, wenn die späteren Teile noch gar nicht geladen sind.

# Ein Muster OHNE '*' oder '?' trifft den Namen exakt (Gross-/Kleinschreibung egal), eines MIT
# Platzhalter wird als Muster ausgewertet. Absicht: 'Zoom Rooms' schuetzt genau diese App und nicht
# auch 'Zoom Workplace'; wer breiter schuetzen will, schreibt 'Zoom*' und sieht das dem Eintrag an.
function Test-IsProtectedApp {
  param(
    [string]$Name,
    [AllowNull()][object[]]$Patterns
  )
  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  $n = ([string]$Name).Trim()
  foreach ($raw in @($Patterns)) {
    $pattern = ([string]$raw).Trim()
    if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
    if ($pattern.IndexOfAny([char[]]@('*', '?')) -ge 0) {
      # -like ist in PowerShell ohnehin ohne Gross-/Kleinschreibung.
      if ($n -like $pattern) { return $true }
    } elseif ([string]::Equals($n, $pattern, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

# Bringt eine Liste in die Form, in der sie gespeichert wird: getrimmt, ohne Leereintraege, ohne
# Doppelte (ohne Gross-/Kleinschreibung), alphabetisch. Eine Stelle fuer die Oberflaeche UND fuer
# eine von Hand bearbeitete settings.json - sonst haengt die Ordnung davon ab, wer zuletzt geschrieben hat.
function Set-ProtectedAppPatterns {
  param([AllowNull()][object[]]$Patterns)
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $out = [System.Collections.Generic.List[string]]::new()
  foreach ($raw in @($Patterns)) {
    $p = ([string]$raw).Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if ($seen.Add($p)) { $out.Add($p) }
  }
  return @($out.ToArray() | Sort-Object)
}

# Hinzufuegen/Entfernen als reine Rechnung: Liste rein, neue Liste raus. Die Oberflaeche schreibt das
# Ergebnis in die Einstellungen und speichert - so gibt es keine zweite Fassung dieser Logik.
function Add-ProtectedAppPattern {
  param([AllowNull()][object[]]$Patterns, [string]$Pattern)
  if ([string]::IsNullOrWhiteSpace($Pattern)) { return @(Set-ProtectedAppPatterns -Patterns $Patterns) }
  return @(Set-ProtectedAppPatterns -Patterns (@($Patterns) + @([string]$Pattern)))
}

# Werksseitig geschuetzte Namen.
#
# Diese Programme werden in der Praxis fast immer SELBST paketiert - mit kundeneigener
# Konfiguration, eigener Lizenz oder eingebauten Zugangsdaten. Ein Update darauf baut eine neue App,
# loest die vorhandene ab und zieht deren Zuweisungen mit; bei einem von Hand gebauten Paket laesst
# sich das durch keinen zweiten Lauf zurueckholen. Genau dieser Unfall soll nicht davon abhaengen,
# dass jemand in einer neuen Umgebung zuerst an die Schutzliste denkt.
#
# Alle mit '*', weil es um JEDE Fassung des Produkts geht ("TeamViewer", "TeamViewer Host",
# "TeamViewer Meeting"). Geschuetzt heisst nicht gesperrt: die App bleibt sichtbar und anhakbar, der
# Lauf fragt bei ihr nur ausdruecklich nach - auch bei abgeschalteten Rueckfragen. Ein zu breites
# Muster kostet daher eine Rueckfrage, ein fehlendes eine App.
#
# Wer sie erweitert, traegt hier ein: der Merker ProtectedAppsSeeded sorgt dafuer, dass Nachtraege
# auch bei Bestandsinstallationen ankommen, ohne von Hand entfernte Muster zurueckzuholen.
#
# Zwei Klassen, und beide aus demselben Grund:
#
# 1. Fernwartung und RMM. Der Installer traegt die Zuordnung zum Betreuer in sich - Mandanten-Id,
#    Kundenschluessel, oft ein eigens erzeugtes Installationspaket. Ein aus WinGet gebautes Paket
#    hat das nicht: es installiert dasselbe Produkt "leer", und danach meldet sich der Rechner bei
#    niemandem mehr. Bei einer Fernwartung ist das genau der Zugang, ueber den man den Fehler
#    haette beheben koennen.
# 2. Passwortmanager. Sie werden mit Richtliniendatei, SSO-Anbindung oder fest eingestelltem
#    Server ausgerollt. Ein Ersatz durch die nackte Herstellerfassung nimmt dem Benutzer nicht die
#    Passwoerter, aber die Anmeldung an den Tresor - und das faellt erst am Endgeraet auf.
#
# Alle mit '*', weil die Produkte in mehreren Fassungen auftreten ("ConnectWise Control",
# "ConnectWise Automate", "ScreenConnect Client (abc123)"). Das kostet im schlechtesten Fall eine
# Rueckfrage bei einer App, die man doch aktualisieren wollte - ein fehlendes Muster kostet die App.
$script:defaultProtectedApps = @(
  # Fernwartung / RMM
  'TeamViewer*'
  'Jamf*'
  'Splashtop*'
  'AnyDesk*'
  'ScreenConnect*'
  'ConnectWise*'
  'N-able*'
  'N-central*'
  'Datto*'
  # Nachtrag 03.09.2026, dieselbe Klasse: der Agent traegt die Mandanten- oder Organisations-Id im
  # Installer. Bewusst 'NinjaOne*'/'NinjaRMM*' statt 'Ninja*' - 'NinjaTrader' ist ein voellig
  # fremdes Produkt, das aus WinGet aktualisiert werden soll, und ein zu breites Muster kostet
  # genau dort eine Rueckfrage, die sich nicht wegdruecken laesst.
  'NinjaOne*'
  'NinjaRMM*'
  'Atera*'
  'Action1*'
  # BeyondTrust breit, und das mit Absicht: Remote Support, Privileged Remote Access und
  # Privilege Management binden alle an die Appliance beziehungsweise an eine Richtlinie des
  # Kunden (Jump-Client mit Site-Schluessel, Konsole mit Appliance-Adresse). Ein aus WinGet
  # gebautes Paket kennt beides nicht.
  'BeyondTrust*'
  # Passwortmanager
  'Keeper*'
  '1Password*'
  'Bitwarden*'
  'LastPass*'
  'KeePass*'
)

# Reine Rechnung: welche Werksmuster fehlen noch, und wie sehen die beiden Listen danach aus.
# Getrennt von der Oberflaeche, damit die Regel "einmal eintragen, danach nie wieder aufzwingen"
# ohne Anmeldung und ohne Fenster pruefbar ist.
function Get-SeededProtectedApps {
  param(
    [AllowNull()][object[]]$Patterns,
    [AllowNull()][object[]]$Seeded,
    [AllowNull()][object[]]$Defaults
  )
  $already = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($s in @($Seeded)) {
    $t = ([string]$s).Trim()
    if (-not [string]::IsNullOrWhiteSpace($t)) { [void]$already.Add($t) }
  }
  $added = [System.Collections.Generic.List[string]]::new()
  $result = @($Patterns)
  foreach ($d in @($Defaults)) {
    $t = ([string]$d).Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { continue }
    if ($already.Contains($t)) { continue }   # schon einmal angeboten - Entscheidung des Benutzers gilt
    $result = @(Add-ProtectedAppPattern -Patterns $result -Pattern $t)
    $added.Add($t)
  }
  return @{
    Patterns = @(Set-ProtectedAppPatterns -Patterns $result)
    # Der Merker fuehrt IMMER die vollstaendige Werksliste, nicht nur das eben Ergaenzte: sonst
    # wuerde ein Muster, das der Benutzer entfernt, beim naechsten Start erneut eingetragen.
    Seeded   = @(Set-ProtectedAppPatterns -Patterns (@($Seeded) + @($Defaults)))
    Added    = @($added.ToArray())
  }
}

function Remove-ProtectedAppPattern {
  param([AllowNull()][object[]]$Patterns, [string]$Pattern)
  $target = ([string]$Pattern).Trim()
  if ([string]::IsNullOrWhiteSpace($target)) { return @(Set-ProtectedAppPatterns -Patterns $Patterns) }
  $kept = @($Patterns | Where-Object {
    -not [string]::Equals(([string]$_).Trim(), $target, [System.StringComparison]::OrdinalIgnoreCase)
  })
  return @(Set-ProtectedAppPatterns -Patterns $kept)
}

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
        # Obergrenze 50: die settings.json ist ausdruecklich von Hand bearbeitbar (der Kommentar am
        # Vorgabeblock sagt es), und ein Tippfehler wie 1500 baut ein Menue, das ueber den unteren
        # Bildschirmrand hinauslaeuft. Die Liste ist reine Bequemlichkeit, ein Rueckfall auf 15
        # kostet also nichts. KeepVersionCount bekommt bewusst KEINE Obergrenze - warum, steht in
        # Get-SettingValue.
        $script:settings.MaxRecentLogins         = Get-SettingValue -Source $o -Name 'MaxRecentLogins'         -Type Int  -Default 15 -Minimum 1 -Maximum 50

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
        # Standard $true: eine settings.json aus einer aelteren Fassung kennt den Schluessel nicht,
        # und "nicht gespeichert" heisst hier "noch nie entschieden", nicht "abgewaehlt".
        $script:settings.ScanUnmanagedWin32Apps = Get-SettingValue -Source $o -Name 'ScanUnmanagedWin32Apps' -Type Bool -Default $true
        # Ueber Set-ProtectedAppPatterns, damit eine von Hand bearbeitete Datei denselben
        # Normalisierungs- und Doppelten-Filter durchlaeuft wie die Oberflaeche.
        $script:settings.ProtectedApps = @(Set-ProtectedAppPatterns -Patterns (Get-SettingValue -Source $o -Name 'ProtectedApps' -Type StringArray -Default @()))
        $script:settings.ProtectedAppsSeeded = @(Set-ProtectedAppPatterns -Patterns (Get-SettingValue -Source $o -Name 'ProtectedAppsSeeded' -Type StringArray -Default @()))
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

  # Ebenfalls ausserhalb des try: die Werksmuster gelten fuer die frische Installation UND fuer den
  # Bestand. Gespeichert wird hier NICHT - das passiert einmal, sobald das Fenster steht
  # (Add_Shown in 90-Main), wie beim Aufraeum-Konflikt daneben. Load-Settings laeuft so frueh, dass
  # es weder Write-Log noch ein Fenster gibt.
  $seed = Get-SeededProtectedApps -Patterns $script:settings.ProtectedApps `
                                  -Seeded $script:settings.ProtectedAppsSeeded `
                                  -Defaults $script:defaultProtectedApps
  $script:settings.ProtectedApps = @($seed.Patterns)
  $script:settings.ProtectedAppsSeeded = @($seed.Seeded)
  if (@($seed.Added).Count -gt 0) { $script:protectedAppsSeeded = @($seed.Added) }
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
  $max = if ([int]$script:settings.MaxRecentLogins -gt 0) { [int]$script:settings.MaxRecentLogins } else { 15 }
  $script:settings.RecentLogins = @(Add-RecentLoginEntry -Entries $script:settings.RecentLogins -Upn $Upn -Max $max)
  Save-Settings
}

# Der reine Kern davon: Liste rein, Liste raus. Getrennt, damit die Reihenfolge und die Grenze ohne
# Anmeldung pruefbar sind.
#
# Verglichen wird OHNE Ruecksicht auf Gross-/Kleinschreibung: eine Adresse ist bei Entra ID
# unabhaengig davon dieselbe, und "Adm@Kunde.de" neben "adm@kunde.de" hat vorher zwei Plaetze im
# Verlauf belegt - bei acht Plaetzen fiel dafuer ein echter Kunde hinten heraus. Die zuletzt
# benutzte Schreibweise gewinnt, weil sie die ist, die der Benutzer gerade getippt hat.
function Add-RecentLoginEntry {
  param(
    [AllowNull()][string[]]$Entries,
    [Parameter(Mandatory)][string]$Upn,
    [int]$Max = 15
  )
  if ($Max -lt 1) { $Max = 15 }
  $trimmed = ([string]$Upn).Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed)) { return @($Entries) }
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $list = [System.Collections.Generic.List[string]]::new()
  $list.Add($trimmed)
  [void]$seen.Add($trimmed)
  foreach ($u in @($Entries)) {
    $candidate = ([string]$u).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if ($seen.Add($candidate)) { $list.Add($candidate) }
  }
  while ($list.Count -gt $Max) { $list.RemoveAt($list.Count - 1) }
  return @($list.ToArray())
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


# --- Self-update source (GitHub) ---
# Repository in der Form "owner/repo", gegen dessen Releases die Selbstaktualisierung prueft.
# Ist der Wert leer (""), sind Knopf und Startsuche stillschweigend abgeschaltet.
#
# Der Release-Arbeitsablauf ueberschreibt diese Zeile beim Bauen des Release-Artefakts mit
# $env:GITHUB_REPOSITORY (siehe .github/workflows/release.yml, "Validate tag and build release
# assets"). Eine heruntergeladene Fassung traegt also immer das Repository, aus dem sie stammt -
# auch nach einer Umbenennung. Der Eintrag hier gilt fuer selbst gebaute Kopien aus src\.
$script:githubRepo  = "zTeck-arch/wintuner_gui"
$script:githubApiUrl = if ($script:githubRepo) { "https://api.github.com/repos/$($script:githubRepo)/releases/latest" } else { "" }
$script:updateAssetName = 'WinTuner_GUI_ntg.ps1'
$script:updateHashAssetName = 'WinTuner_GUI_ntg.ps1.sha256'
$script:skipLowValueWingetCandidates = $false  # keep all apps by default; set $true for faster scans with possible omissions

# --- Graph-Transport ------------------------------------------------------------------------------
#
# Zeitablauf fuer jeden Graph-Aufruf dieser Anwendung.
#
# Ohne -TimeoutSec wartet Invoke-RestMethod in PowerShell 7 UNBEGRENZT. Gemessen am 31.08.2026: von
# 22 Aufrufstellen trugen sieben eine Angabe, fuenfzehn nicht - und alle laufen auf dem UI-Faden.
# Eine Antwort, die nie kommt, war damit ein eingefrorenes Fenster ohne Abbruchweg; nur das Beenden
# der Anwendung half. 100 s ist bewusst grosszuegig (der Store-Katalog antwortet nachweislich
# langsam), aber endlich: ein Graph-Aufruf, der laenger braucht, ist kein langsamer, sondern ein
# verlorener. Hier und nicht in 40-Graph, damit auch die Teile 25-35 den Wert ohne Vorwaertsbezug
# lesen koennen.
$script:graphTimeoutSeconds = 100

# Welche Antworten einen zweiten Versuch verdienen. 429 ist im Betrieb aufgetreten (Intune drosselt
# mehrere Zuweisungsschreibvorgaenge kurz hintereinander); 5xx sind Zustaende des Dienstes, nicht der
# Anfrage. Ausgewertet in Get-GraphRetryPlan (40-Graph).
$script:graphRetryStatuses = @(429, 500, 502, 503, 504)

# --- Runtime state (set during execution) ---
# $script:isConnected      – whether the user is logged in to a tenant
# $script:currentUserUpn   – UPN of the currently logged-in user
# $script:builtVersions    – tracks effective built package versions per PackageId
# $script:wingetVersionCache – in-memory cache for winget version lookups
# $script:versionCachePath – path to the on-disk version cache JSON file
# $script:themeName        – key of the active theme (Dark/Light/Win2000/WinXP/WinVista/Win7)
# $script:currentTheme     – active theme hashtable, looked up from $script:availableThemes
# $script:diskCache        – in-memory copy of the on-disk version cache (loaded once)
# $script:diskCacheLoaded  – whether $script:diskCache has been populated from disk
# $script:forceFreshLogin  – set by Logout; forces the next Connect-WtWinTuner call to
#                            bypass the Windows auth broker (WAM) so a real sign-in is
#                            required instead of a silent SSO reuse of the broker session

$script:forceFreshLogin = $false

# --- Wohin die eigenen Daten gehen ---------------------------------------------------------------
#
# [Environment]::GetFolderPath('ApplicationData') fragt Windows nach dem bekannten Ordner und
# ignoriert $env:APPDATA. SmokeTest und LayoutProbe setzten genau diese Umgebungsvariable und hielten
# sich damit fuer gekapselt - in Wahrheit lasen und schrieben sie das ECHTE Profil. Zwei Folgen:
# ein Prueflauf konnte die Einstellungen des Benutzers anfassen, und der Zustand "frisches Profil"
# (also jeder CI-Laeufer) wurde nie geprueft. Genau dort wartet ein Erstlauf-Dialog.
#
# $env:WINTUNER_DATA_DIR ist die eine Naht dafuer: gesetzt landen Einstellungen, Protokolle,
# Zwischenspeicher und Verlauf darunter, sonst unveraendert im Profil. Nur die Prueflaeufer setzen
# sie; im Auslieferungsfall ist sie leer.
function Get-AppDataRoot {
  if ($env:WINTUNER_DATA_DIR) { return $env:WINTUNER_DATA_DIR }
  return [Environment]::GetFolderPath('ApplicationData')
}
function Get-LocalAppDataRoot {
  if ($env:WINTUNER_DATA_DIR) { return $env:WINTUNER_DATA_DIR }
  return [Environment]::GetFolderPath('LocalApplicationData')
}

# --- Persisted settings – loaded here, before any UI is built, so every control can
# read its saved value directly at creation time instead of needing a resync pass later. ---
$script:settingsPath = Join-Path (Get-AppDataRoot) 'WinTunerGUI\settings.json'

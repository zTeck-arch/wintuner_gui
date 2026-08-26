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

# --- Persisted settings – loaded here, before any UI is built, so every control can
# read its saved value directly at creation time instead of needing a resync pass later. ---
$script:settingsPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'WinTunerGUI\settings.json'

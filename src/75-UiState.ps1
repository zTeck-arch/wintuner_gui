# Helper: toggle UI based on connection state
function Set-ConnectedUIState {
  param([bool]$Connected)
  # Toggle the LOGIN group (rounded UPN field host + its recent-menu button + Login) vs the
  # CONNECTED group (status dot + "logged in as" + Disconnect + Logout). Hiding the host (not
  # just the inner TextBox) is what prevents the empty field overlapping the status text.
  if ($Connected) {
    $loginButton.Visible = $false
    if ($usernameHost)  { $usernameHost.Visible  = $false }
    if ($recentButton)  { $recentButton.Visible  = $false }
    $usernameLabel.Visible = $false
    if ($mainPanel) { $mainPanel.Visible = $true }
    $logoutButton.Visible = $true
    if ($disconnectButton) { $disconnectButton.Visible = $true }
    if ($authInfoBadge) { $authInfoBadge.Visible = $true; $authInfoBadge.BringToFront() }
  } else {
    $loginButton.Visible = $true
    if ($usernameHost)  { $usernameHost.Visible  = $true }
    if ($recentButton)  { $recentButton.Visible  = $true }
    $usernameLabel.Visible = $true
    if ($mainPanel) { $mainPanel.Visible = $true }
    $logoutButton.Visible = $false
    if ($disconnectButton) { $disconnectButton.Visible = $false }
    if ($authInfoBadge) { $authInfoBadge.Visible = $false }
  }
  # Action buttons stay ALWAYS enabled (consistent look signed in or out); the handlers gate
  # themselves via Test-Connected and show a sign-in popup when needed.

  if ($loginInfoLabel) {
    $loginInfoLabel.Visible = $Connected
    if ($Connected -and $script:currentUserUpn) {
      # Show the friendly tenant name with a leading filled dot (connected indicator, folded into
      # the text so the dot and label always share a baseline); full UPN is available on hover.
      $loginInfoLabel.Text = ([System.Char]::ConvertFromUtf32(0x25CF) + "  " + ((Get-UiString 'LoggedInAs') -f (Get-TenantDisplayName $script:currentUserUpn)))
      if ($toolTip) { try { $toolTip.SetToolTip($loginInfoLabel, $script:currentUserUpn) } catch { Write-LogDebug ("Login tooltip: {0}" -f $_.Exception.Message) } }
    }
  }
  # Die Stand-Zeile des Dashboards folgt dem Verbindungszustand: getrennt steht dort wieder der
  # Hinweis, dass es einen Tenant braucht, statt eines Standes, der nicht mehr gilt.
  if (Get-Command Update-DashboardFreshness -ErrorAction SilentlyContinue) {
    try { Update-DashboardFreshness } catch { }
  }
  # The connected indicator is folded into $loginInfoLabel's text, so the standalone dot stays hidden.
  if ($connStatusDot) { $connStatusDot.Visible = $false }
  # Titelleiste und Taskleiste sagen, WELCHER Kunde in diesem Fenster haengt - der teuerste Fehler
  # dieses Werkzeugs ist, im Fenster des falschen Tenants zu arbeiten.
  try {
    if ($Connected -and $script:currentUserUpn) {
      $form.Text = ('{0} - {1}' -f $script:appName, (Get-TenantDisplayName $script:currentUserUpn))
    } else {
      $form.Text = $script:appName
    }
  } catch { Write-LogDebug 'window title' }
  # Die Leerzustaende der Listen tragen den Verbindungszustand; hier laeuft jede Aenderung daran
  # durch. Vor Clear-TenantViews, damit das Leeren der Listen den frischen Text schon vorfindet.
  foreach ($gate in @(
      @{ Label = $updatesEmptyLabel;    Key = 'UpdatesEmptyHint' },
      @{ Label = $supersededEmptyLabel; Key = 'SupersededEmptyHint' },
      @{ Label = $discoveredEmptyLabel; Key = 'DiscoveredEmptyHint' })) {
    if ($gate.Label -and (Get-Command Set-ListEmptyText -ErrorAction SilentlyContinue)) {
      try { Set-ListEmptyText -Label $gate.Label -NormalKey $gate.Key } catch { }
    }
  }
  # Every way OUT of a session runs through here - disconnect, sign-out and a failed sign-in alike -
  # so the tenant views are dropped in one place instead of at each call site.
  if (-not $Connected -and (Get-Command Clear-TenantViews -ErrorAction SilentlyContinue)) {
    try { Clear-TenantViews } catch { }
  }
  # Forced: a fresh sign-in must always show this tenant's real numbers, never a cooled-down
  # snapshot from the previous session.
  if ($Connected -and (Get-Command Refresh-Dashboard -ErrorAction SilentlyContinue)) { Refresh-Dashboard -Force }
}

$script:isConnected = $false
$script:currentUserUpn = ""

# Domain of the last tenant we connected to; survives Disconnect (cleared only on Logout).
# Used to nudge toward a full Logout when switching to a different customer tenant.
$script:lastTenantDomain = ""

# Session-wide activity log across ALL customers worked on this session. Each entry:
# { Tenant; Name; FromVersion; ToVersion; OldVersionRemoved; Timestamp }. Feeds the
# on-demand Leistungstext, grouped per tenant.
$script:sessionActivity = [System.Collections.Generic.List[object]]::new()
# Die Adresse, unter der der Nachweis erfasst wird. Getrennt von $script:currentUserUpn, weil das
# beim Trennen geleert wird: ein Lauf, der nach dem Trennen noch Eintraege schreibt, haette sonst
# Eintraege ohne Tenant erzeugt (genau so gingen drei Updates im Nachweis verloren). Gesetzt bei
# der Anmeldung, geleert nur beim Abmelden.
$script:activityTenantUpn = ""

# Track effective built versions per PackageId
$script:builtVersions = @{}
# Cache for winget version lookups (speeds up repeated searches)
$script:wingetVersionCache = @{}
$script:versionCachePath = Join-Path (Get-LocalAppDataRoot) 'WinTunerGUI\version-cache.json'
# Disk cache loaded once at first use (Fix 1)
$script:diskCache = @{}
$script:diskCacheLoaded = $false

# Create form
$form = New-Object System.Windows.Forms.Form
# Der Anwendungsname steht an genau einer Stelle: Titelleiste, Kopfzeile und About lesen ihn hier.
# Set-ConnectedUIState haengt den verbundenen Kunden an - bei einem MSP-Werkzeug sind regelmaessig
# zwei Fenster fuer zwei Tenants offen, und in der Taskleiste waren die bisher nicht zu unterscheiden.
$script:appName = "WinTuner GUI"
$form.Text = $script:appName
$form.ShowIcon = $false   # hide the default (generic pwsh) title-bar icon for a cleaner look
# Wider than before to make room for the left sidebar next to the content region.
# Resizable: MinimumSize keeps content from clipping while allowing the window to grow.
# Controls are laid out against THIS size while they are being added (WinForms captures each
# anchor margin at that moment), so it must stay the size the positions were designed for. The
# larger default window is applied at the very END of the script, where a real resize pass runs.
# 1060 wide so the four dashboard tiles fit with room to spare: they span 748px of content, and the
# window chrome plus sidebar costs 256px. The minimum is raised to match - below it the fourth tile
# would be clipped, which is exactly what happened when it was added.
$form.Size = New-Object System.Drawing.Size(1060, 850)
$form.MinimumSize = New-Object System.Drawing.Size(1010, 680)
# Restore the last window size (saved on close). Clamped to the working area so a window saved on a
# larger/second monitor can never open bigger than the current screen.
try {
  $sw = [int]$script:settings.WindowWidth; $sh = [int]$script:settings.WindowHeight
  # Guarded against the CURRENT minimum, not a stale one: a size saved before the dashboard grew a
  # fourth tile would otherwise be restored too narrow and clip it again.
  if ($sw -ge $form.MinimumSize.Width -and $sh -ge $form.MinimumSize.Height) {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size([Math]::Min($sw, $wa.Width), [Math]::Min($sh, $wa.Height))
  }
  if ($script:settings.WindowMaximized) { $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized }
} catch {}
# Modern default font for every control that doesn't set its own (ambient inheritance) –
# the previous default was the pre-Vista "Microsoft Sans Serif".
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Padding = '5,5,5,5'

# --- Ein Einzug fuer alles Linke ---------------------------------------------------------------
# Kopfzeile und Seitenleiste sind zwei getrennte Baustellen mit je eigenen Pixelwerten gewesen; der
# Titel sass dadurch 9 px weiter links als die Navigationseintraege darunter. Diese vier Werte sind
# jetzt die EINZIGE Quelle fuer den linken Einzug - wer einen davon aendert, verschiebt Titel und
# Leiste gemeinsam.
$script:formPadding      = 5    # $form.Padding: verschiebt alles ANGEDOCKTE (Kopfzeile) nach innen
$script:mainPanelIndent  = 10   # linke Kante von $mainPanel (und damit der Seitenleiste)
$script:navButtonIndent  = 8    # linke Kante eines Navigationsknopfs innerhalb der Leiste
$script:navButtonTextPad = 12   # Innenabstand des Knopfs bis zum Symbol
# Absoluter X-Wert der Symbolspalte der Seitenleiste: 10 + 8 + 12 = 30. Daran richtet sich der
# Titel in der Kopfzeile aus (dort minus $formPadding, weil die Kopfzeile angedockt ist).
$script:navContentIndent = $script:mainPanelIndent + $script:navButtonIndent + $script:navButtonTextPad

# --- Hoehe der Kopfzeile ------------------------------------------------------------------------
# 78 px waren fuer eine 36 px hohe Knopfreihe reichlich: 22 oben, 20 unten. Gemeldet als "oben ist
# Platz zu holen" - der fehlt naemlich unten in den Listen. 64 px lassen der Reihe 14 px Luft oben
# und 12 px bis zur Akzentlinie. $mainPanelTop haengt daran, sonst klebt der Inhalt an der Linie
# oder es bleibt ein leerer Streifen - beides schon passiert, als die Hoehe hier einzeln geaendert
# wurde.
$script:headerHeight  = 64
$script:headerRowTop  = 14
$script:menuBarHeight = 24
$script:mainPanelTop  = $script:menuBarHeight + $script:headerHeight + 10

# Erste Fenstergroesse: aus dem BILDSCHIRM, nicht aus einer Entwurfszahl.
#
# Als reine Rechnung herausgeloest, weil an ihr drei Grenzen gleichzeitig haengen und jede einzelne
# schon einmal falsch war: zu gross (Fenster unter der Taskleiste), zu klein (vierte Dashboard-Kachel
# abgeschnitten), und eine gespeicherte Groesse, die kleiner als das Minimum ist, darf nicht gewinnen.
# Reihenfolge: gespeicherte Groesse > 80 % der Arbeitsflaeche > Entwurfsgroesse, danach begrenzt auf
# [Minimum .. Arbeitsflaeche - 8].
function Get-InitialWindowSize {
  param(
    [Parameter(Mandatory)][int]$WorkWidth,
    [Parameter(Mandatory)][int]$WorkHeight,
    [int]$SavedWidth = 0,
    [int]$SavedHeight = 0,
    [int]$MinWidth = 1010,
    [int]$MinHeight = 680,
    [int]$DesignWidth = 1060,
    [int]$DesignHeight = 850,
    [double]$Fraction = 0.80
  )
  $hasSaved = ($SavedWidth -ge $MinWidth -and $SavedHeight -ge $MinHeight)
  $wantW = if ($hasSaved) { $SavedWidth } else { [Math]::Max($DesignWidth, [int]($WorkWidth * $Fraction)) }
  $wantH = if ($hasSaved) { $SavedHeight } else { [Math]::Max($DesignHeight, [int]($WorkHeight * $Fraction)) }
  return [pscustomobject]@{
    Width  = [Math]::Max($MinWidth,  [Math]::Min($wantW, $WorkWidth - 8))
    Height = [Math]::Max($MinHeight, [Math]::Min($wantH, $WorkHeight - 8))
    Source = if ($hasSaved) { 'settings' } else { 'screen' }
  }
}

# Header panel – contains all login/top controls so they stay in one row
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = $script:headerHeight
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(38, 38, 40)
$form.Controls.Add($headerPanel)

# --- Menu bar (docks above the header; gives a discoverable home for the on-demand
# Leistungsnachweis and other tools). Added after the header so it docks to the top edge. ---
$menuStrip = New-Object System.Windows.Forms.MenuStrip
# Keep the standard system menu look (readable in every theme) rather than letting the
# theme recolor it to a dark strip with unreadable default-colored items.
$menuStrip.Tag = 'no-theme'

$menuTools = New-Object System.Windows.Forms.ToolStripMenuItem
$menuTools.Text = Get-UiString 'MenuTools'
$miClearCache = New-Object System.Windows.Forms.ToolStripMenuItem
$miClearCache.Text = Get-UiString 'MenuClearCache'
$miClearCache.Add_Click({ if ($clearCacheButton) { $clearCacheButton.PerformClick() } })
$miClearRecent = New-Object System.Windows.Forms.ToolStripMenuItem
$miClearRecent.Text = Get-UiString 'MenuClearRecentLogins'
$miClearRecent.Add_Click({
  $confirm = [System.Windows.Forms.MessageBox]::Show(
    (Get-UiString 'ClearRecentLoginsConfirm'),
    (Get-UiString 'ClearRecentLoginsTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )
  if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
    $script:settings.RecentLogins = @()
    Save-Settings
    # Drop the recent-logins history (type-ahead + menu); keep whatever is typed.
    Update-RecentLoginsUI
    Update-Status (Get-UiString 'RecentLoginsClearedStatus')
  }
})

# Open the persistent activity log file – the fastest way to hand a full history to support
# (the in-window log only shows the current session and is capped by the textbox).
$miOpenLog = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpenLog.Text = Get-UiString 'MenuOpenLogFile'
$miOpenLog.Add_Click({
  try {
    $logPath = $script:logFilePath
    if (Test-Path -LiteralPath $logPath) {
      Start-Process -FilePath $logPath -ErrorAction Stop
    } else {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'LogFileMissingDialog') -f $logPath),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    }
  } catch { Write-Log "Open log failed: $($_.Exception.Message)" }
})

# Der Sammel-Editor fuer Bereitstellungseinstellungen stand hier als Menueeintrag. Er ist ENTFALLEN:
# derselbe Editor ist ein eigener Bereich in der Seitenleiste ("App-Zuweisungseinstellungen") und
# zusaetzlich als Knopf in "Alle Tenant-Apps" erreichbar. Ein Menueeintrag, der eine Sektion aus der
# Leiste dupliziert, macht die Leiste unglaubwuerdig - man sucht dann an drei Stellen dasselbe.

# Friendly names for the tenants this technician signs in to.
$miTenantNames = New-Object System.Windows.Forms.ToolStripMenuItem
$miTenantNames.Text = Get-UiString 'MenuTenantNames'
$miTenantNames.Add_Click({ try { Show-TenantNamesDialog } catch { Write-Log ("Tenant names dialog failed: {0}" -f $_.Exception.Message) } })

# The assignments kept before an app was deleted in this session - the safety net for "what scope
# did that app have again?" after a deletion turns out to have been wrong.
$miScopeSnapshots = New-Object System.Windows.Forms.ToolStripMenuItem
$miScopeSnapshots.Text = Get-UiString 'MenuScopeSnapshots'
$miScopeSnapshots.Add_Click({ try { Show-ScopeSnapshotDialog } catch { Write-Log ("Scope snapshot dialog failed: {0}" -f $_.Exception.Message) } })
# Reachable without starting a test: a leftover sandbox blocks every further test and has no window
# to close, so the only other way out was hunting a process name in Task Manager.
$miCloseSandbox = New-Object System.Windows.Forms.ToolStripMenuItem
$miCloseSandbox.Text = Get-UiString 'MenuCloseSandbox'
$miCloseSandbox.Add_Click({
  if (-not (Test-WindowsSandboxRunning)) {
    Update-Status (Get-UiString 'SandboxNoneRunning')
    return
  }
  Update-Status (Get-UiString 'DetectSandboxClosingStatus')
  [System.Windows.Forms.Application]::DoEvents()
  $stopResult = Stop-WindowsSandbox
  if ($stopResult.Stopped) {
    # Same settle wait as before a test run: someone who closes a sandbox here often starts one
    # straight afterwards, and Windows would refuse it.
    [void](Wait-WindowsSandboxSettled -AfterKill:([bool]$stopResult.Killed))
    Update-Status (Get-UiString 'SandboxClosedStatus')
  } else {
    Update-Status (Get-UiString 'DetectSandboxCloseFailed')
  }
})

# The three persisted switches that used to sit here - keep assignments before deleting, dashboard
# full scan, skip confirmations - now live on the Settings page with the rest of the settings. In a
# menu they saved themselves on click while every option on that page waited for "Save settings",
# so the same kind of setting behaved differently depending on where the user found it.

[void]$menuStrip.Items.Add($menuTools)

# Ansicht: Anzeigevorlieben, beide als Untermenue statt als eigener Platz in der Leiste.
$menuView = New-Object System.Windows.Forms.ToolStripMenuItem
$menuView.Text = Get-UiString 'MenuView'
[void]$menuStrip.Items.Add($menuView)

$menuHelp = New-Object System.Windows.Forms.ToolStripMenuItem
$menuHelp.Text = Get-UiString 'MenuHelp'

$miAbout = New-Object System.Windows.Forms.ToolStripMenuItem
$miAbout.Text = Get-UiString 'MenuAbout'
$miAbout.Add_Click({
  # Show where the log and settings actually live – the paths are derived at runtime, so users can
  # find/hand over the right files without guessing.
  [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'AboutDialog') -f $script:appVersion, $script:logFilePath, $script:settingsPath),
    (Get-UiString 'AboutTitle'),
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information)
})
[void]$menuHelp.DropDownItems.Add($miAbout)

# "Sign-in & session explained": the dialog text existed in both dictionaries but was never
# reachable - no menu item ever opened it. It answers the two questions that actually come up
# (why no password is asked again, and Disconnect vs Logout), so it is wired up here.
$miSignInHelp = New-Object System.Windows.Forms.ToolStripMenuItem
$miSignInHelp.Text = Get-UiString 'MenuSignInHelp'
$miSignInHelp.Add_Click({
  $cacheDir = Join-Path $env:LOCALAPPDATA ".IdentityService"
  [void][System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'SignInHelpDialog') -f $cacheDir),
    (Get-UiString 'SignInHelpTitle'),
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information)
})
[void]$menuHelp.DropDownItems.Add($miSignInHelp)

# Which Graph permissions this tool needs, and which account should carry them. Its own entry
# rather than a paragraph inside the sign-in help: it is the question a customer's administrator
# asks BEFORE granting anything, and it has to be findable without reading everything else.
$miPermissions = New-Object System.Windows.Forms.ToolStripMenuItem
$miPermissions.Text = Get-UiString 'MenuPermissions'
$miPermissions.Add_Click({
  [void][System.Windows.Forms.MessageBox]::Show(
    (Get-UiString 'PermissionsDialog'),
    (Get-UiString 'PermissionsTitle'),
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information)
})
[void]$menuHelp.DropDownItems.Add($miPermissions)
[void]$menuStrip.Items.Add($menuHelp)

# Performance record as its own top-level entry next to Tools/Help (moved off the sidebar).
# Fruehere oberste Menueebene: "Extras | Hilfe | Leistungsnachweis anzeigen... | Design | Sprache" -
# ein Menue, ein Menue, eine AKTION, und zwei einzelne Radiolisten. Drei verschiedene Arten von Ding
# auf derselben Ebene. Jetzt: Extras (mit dem Leistungsnachweis), Ansicht (Design + Sprache), Hilfe.
# Der Leistungsnachweis war ein Menueeintrag unter Extras. Er ist jetzt ein eigener Bereich in der
# Seitenleiste (siehe 85-Rows, Sektion 'workrecord'): eine Auswertung, die man liest und kopiert,
# gehoert an einen Ort, den man sieht - nicht hinter ein Menue.
# --- Reihenfolge des Extras-Menues, an einer Stelle statt verteilt ------------------------------
#
# Gruppiert nach dem, WORAUF eine Aktion wirkt - dieselbe Frage, nach der die Seitenleiste, die
# Uebersicht und die Einstellungsseite inzwischen ordnen.
#
# Zwei Eintraege gibt es auch als Knopf auf der Einstellungsseite: "Protokolldatei oeffnen" und
# "Versions-Cache leeren". Das bleibt so - im Stoerungsfall sucht man das Protokoll im Menue und
# nicht auf einer Seite, die man dafuer erst aufschlagen muesste.
$script:menuToolsGroups = @(
  # Wirkt auf den verbundenen Tenant
  @($miScopeSnapshots, $miTenantNames),
  # Wirkt nur auf diesen Rechner
  @($miOpenLog, $miClearCache, $miClearRecent, $miCloseSandbox)
)
$firstToolsGroup = $true
foreach ($group in $script:menuToolsGroups) {
  if (-not $firstToolsGroup) {
    [void]$menuTools.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  }
  $firstToolsGroup = $false
  foreach ($entry in $group) {
    if ($entry) { [void]$menuTools.DropDownItems.Add($entry) }
  }
}

# Theme picker (moved here from Settings): one radio-checked entry per available theme.
$menuTheme = New-Object System.Windows.Forms.ToolStripMenuItem
$menuTheme.Text = Get-UiString 'ThemeMenu'
$script:themeMenuItems = @{}
function Update-ThemeMenuChecks {
  foreach ($k in $script:themeMenuItems.Keys) {
    try { $script:themeMenuItems[$k].Checked = ($k -eq $script:themeName) } catch { Write-LogDebug ("Theme menu check {0}: {1}" -f $k, $_.Exception.Message) }
  }
}
foreach ($tKey in $script:availableThemes.Keys) {
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem
  $mi.Text = $script:themeDisplayNames[$tKey]
  $mi.Name = "theme_$tKey"
  $mi.Add_Click({
    param($sender, $e)
    try {
      $key = $sender.Name.Substring(6)   # strip "theme_"
      Set-ActiveTheme -ThemeName $key
      $script:settings.ThemeName = $key
      Update-ThemeMenuChecks
    } catch { try { Write-Log ("Theme switch error: {0}" -f $_.Exception.Message) } catch {} }
  })
  $script:themeMenuItems[$tKey] = $mi
  [void]$menuTheme.DropDownItems.Add($mi)
}
[void]$menuView.DropDownItems.Add($menuTheme)
Update-ThemeMenuChecks

# Language picker, next to the Theme picker (moved out of Settings for the same reason: it is a
# display preference, not an Intune setting). Radio-checked like the themes. Switching only stores
# the choice - re-localising every already-built control at runtime is error-prone, so the change
# takes effect on the next start (same behaviour as the old combo, which said so in its dialog).
$menuLanguage = New-Object System.Windows.Forms.ToolStripMenuItem
$menuLanguage.Text = Get-UiString 'MenuLanguage'
$script:languageMenuItems = @{}
function Update-LanguageMenuChecks {
  foreach ($k in $script:languageMenuItems.Keys) {
    try { $script:languageMenuItems[$k].Checked = ($k -eq $script:uiLanguage) } catch { Write-LogDebug ("Language menu check {0}: {1}" -f $k, $_.Exception.Message) }
  }
}
foreach ($lKey in @('en','de')) {
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem
  $mi.Text = if ($lKey -eq 'de') { Get-UiString 'LanguageGerman' } else { Get-UiString 'LanguageEnglish' }
  # Key carried on .Name and read from the sender – a GetNewClosure handler could not resolve the
  # script-scope functions it calls (see the nav-button incident).
  $mi.Name = "lang_$lKey"
  $mi.Add_Click({
    param($sender, $e)
    try {
      $key = $sender.Name.Substring(5)   # strip "lang_"
      if ($key -eq $script:settings.Language) { return }
      $script:settings.Language = $key
      Save-Settings
      $script:uiLanguage = $key
      Update-LanguageMenuChecks
      Update-Status (Get-UiString 'LanguageChangeNote')
      [void][System.Windows.Forms.MessageBox]::Show(
        (Get-UiString 'LanguageChangeNote'),
        (Get-UiString 'MenuLanguage'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    } catch { try { Write-Log ("Language switch error: {0}" -f $_.Exception.Message) } catch {} }
  })
  $script:languageMenuItems[$lKey] = $mi
  [void]$menuLanguage.DropDownItems.Add($mi)
}
[void]$menuView.DropDownItems.Add($menuLanguage)
Update-LanguageMenuChecks

# Die Menueleiste stand auf 20 px, Titel und Nav-Symbole auf 30 - drei Kanten, die dasselbe meinen.
# Der Wert ist GEMESSEN, nicht gerechnet: mit Innenabstand 10 begann "Extras" auf 24 px (Bildschirm-
# kopie des laufenden Fensters), der ToolStrip legt also 14 px aus sich heraus dazu (Fensterrand
# plus Eintragsabstand). Fuer die 30 des Titels bleiben 16.
$script:menuBarOwnIndent = 14
$menuStrip.Padding = New-Object System.Windows.Forms.Padding(($script:navContentIndent - $script:menuBarOwnIndent), 0, 0, 0)
$form.MainMenuStrip = $menuStrip
$form.Controls.Add($menuStrip)

# Accent line separating the header from the content below
$headerAccentBar = New-Object System.Windows.Forms.Panel
$headerAccentBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$headerAccentBar.Height = 2
$headerAccentBar.BackColor = $script:accentColor
$headerAccentBar.Tag = 'no-theme'
$headerPanel.Controls.Add($headerAccentBar)


# App title (left) – replaces the former logo; follows the theme foreground colour.
#
# Der Einzug ist NICHT frei gewaehlt: er muss auf der Symbolspalte der Seitenleiste sitzen, sonst
# stehen Titel und Navigation sichtbar unterschiedlich weit vom Fensterrand weg (16 + 5 px Rand =
# 21 gegen 30 - genau der Versatz, der aufgefallen ist). $script:navContentIndent ist der absolute
# X-Wert dieser Spalte; die Kopfzeile ist im Fenster-Innenabstand angedockt, also 5 px davon ab.
$appTitleLabel = New-Object System.Windows.Forms.Label
$appTitleLabel.Text = $script:appName
$appTitleLabel.Location = New-Object System.Drawing.Point(($script:navContentIndent - $script:formPadding), ($script:headerRowTop + 4))
$appTitleLabel.AutoSize = $true
$appTitleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 15, [System.Drawing.FontStyle]::Bold)
$headerPanel.Controls.Add($appTitleLabel)

# "Sign in" caption left of the UPN field (right-anchored with the rest of the login group).
$usernameLabel = New-Object System.Windows.Forms.Label
$usernameLabel.Text = Get-UiString 'UsernameLabel'
$usernameLabel.Location = New-Object System.Drawing.Point(410, 32)
$usernameLabel.AutoSize = $true
$usernameLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$headerPanel.Controls.Add($usernameLabel)

# UPN entry: a plain TextBox (dark-themeable, unlike an editable ComboBox which renders a
# white edit field under visual styles) with type-ahead from recent logins. A small "recent"
# button opens the full list as a menu. Wrapped in a rounded input host and right-anchored.
$usernameBox = New-Object System.Windows.Forms.TextBox
$usernameBox.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
$usernameBox.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::CustomSource
$usernameBox.Add_KeyDown({
  param($sender, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    if ($loginButton -and $loginButton.Enabled) {
      $loginButton.PerformClick()
    } else {
      [void][System.Windows.Forms.MessageBox]::Show(
        (Get-UiString 'UsernameError'),
        (Get-UiString 'ValidationTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
      )
    }
    $e.SuppressKeyPress = $true
  }
})
$usernameHost = New-RoundedInput -Inner $usernameBox -X 486 -Y 22 -W 320 -H 36
$usernameHost.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$headerPanel.Controls.Add($usernameHost)

# The caption is placed relative to the input field, not at a fixed X. It is AutoSize, and the
# German "Benutzername:" is wider than the English "Username:" - at a fixed left edge it ran
# underneath the field. Measuring the actual text and right-aligning it against the field keeps
# the gap constant in every language, and survives a different font or DPI as well.
function Update-UsernameLabelPosition {
  try {
    if (-not $usernameLabel -or -not $usernameHost) { return }
    $textWidth = [System.Windows.Forms.TextRenderer]::MeasureText($usernameLabel.Text, $usernameLabel.Font).Width
    $left = $usernameHost.Left - $textWidth - 10
    if ($left -lt 8) { $left = 8 }   # never push it off the panel on a very narrow window
    $top = $usernameHost.Top + [int](($usernameHost.Height - $usernameLabel.Height) / 2)
    $usernameLabel.Location = New-Object System.Drawing.Point($left, $top)
  } catch { }   # class 3: a mispositioned caption must never stop the header from building
}
Update-UsernameLabelPosition

# Recent-logins menu + trigger button (replaces the old editable-ComboBox dropdown).
$recentMenu = New-Object System.Windows.Forms.ContextMenuStrip
$recentMenu.Tag = 'no-theme'
$recentButton = New-Object System.Windows.Forms.Button
$recentButton.Tag = 'btn-secondary'
$recentButton.Text = [System.Char]::ConvertFromUtf32(0x25BE)   # ▾
$recentButton.Location = New-Object System.Drawing.Point(808, 22)
$recentButton.Size = New-Object System.Drawing.Size(34, 36)
$recentButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$recentButton.Add_Click({
  # Always open the menu – Update-RecentLoginsUI guarantees at least a disabled placeholder item
  # so the button never looks "dead" when there are no recent logins yet.
  $recentMenu.Show($recentButton, (New-Object System.Drawing.Point(0, $recentButton.Height)))
})
$headerPanel.Controls.Add($recentButton)

# Rebuilds both the type-ahead source and the recent-logins menu from settings.
function Update-RecentLoginsUI {
  $src = New-Object System.Windows.Forms.AutoCompleteStringCollection
  $recentMenu.Items.Clear()
  foreach ($u in @($script:settings.RecentLogins)) {
    if ($u) {
      # Type-ahead keeps working on the ADDRESS - that is what actually gets signed in.
      [void]$src.Add($u)
      # The entry reads as the customer name when one is set, with the address next to it and in the
      # tooltip. Never name-only: picking the wrong customer is the one mistake that must not be easy.
      $mi = $recentMenu.Items.Add((Get-TenantDisplayLabel -Upn $u))
      # Tag carries the address, so the click cannot depend on the label text.
      $mi.Tag = $u
      $mi.ToolTipText = $u
      $mi.Add_Click({ param($s, $ev) $usernameBox.Text = [string]$s.Tag })
    }
  }
  # Empty-state: a single disabled hint so the dropdown always shows something meaningful.
  if ($recentMenu.Items.Count -eq 0) {
    # Kept enabled (click is a no-op) so the hint text stays readable in dark mode – a disabled
    # ToolStripMenuItem is force-rendered in grey, which is unreadable on the dark menu background.
    [void]$recentMenu.Items.Add((Get-UiString 'RecentLoginsEmpty'))
  }
  $usernameBox.AutoCompleteCustomSource = $src
  # Re-apply dark menu styling (items were just rebuilt).
  if (Get-Command Update-MenuTheme -ErrorAction SilentlyContinue) { try { Update-MenuTheme } catch {} }
}
Update-RecentLoginsUI

# Kept only for existing references (live validation + Set-ConnectedUIState). The invalid-UPN
# state is now conveyed by the disabled Connect button + tooltip, so this label is not shown
# (monochrome design avoids a red error strip). Not added to any parent.
$usernameError = New-Object System.Windows.Forms.Label
$usernameError.Text = ""
$usernameError.Visible = $false

# Live validation for username field
$usernameBox.add_TextChanged({
  if ($script:winTunerModuleImported -and (Test-ValidM365UserName -UserName $usernameBox.Text)) {
    $usernameError.Text = ""
    if ($loginButton) { $loginButton.Enabled = $true }
  } else {
    $usernameError.Text = Get-UiString 'UsernameError'
    if ($loginButton) { $loginButton.Enabled = $false }
  }
})

# Dedicated lower container. Docking this panel is the invariant that keeps Activity Log and the
# status line at the real client bottom; the child layout below only controls compact spacing.
# This remains correct even if a DPI/theme/resize callback fails later.
$bottomPanel = New-Object System.Windows.Forms.Panel
$bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$bottomPanel.Height = 184
$form.Controls.Add($bottomPanel)

# Status label
$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Text = ""
$script:statusLabel.Location = New-Object System.Drawing.Point(10, 158)
$script:statusLabel.Width = 964
$script:statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$bottomPanel.Controls.Add($script:statusLabel)

# Output textbox (Log area below tabs and progress bar)
$script:outputBox = New-Object System.Windows.Forms.TextBox
$script:outputBox.Location = New-Object System.Drawing.Point(10, 32)
$script:outputBox.Size = New-Object System.Drawing.Size(964, 120)
$script:outputBox.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:outputBox.Multiline = $true
$script:outputBox.ScrollBars = "Vertical"
$script:outputBox.ReadOnly = $true
$bottomPanel.Controls.Add($script:outputBox)

# Fortschritt als TEXT, nicht als Balken (erscheint zwischen Bereich und Protokoll).
#
# Ein Balken behauptet Bewegung, wo keine ist: Paketieren und Hochladen laufen auf dem UI-Thread,
# waehrend eines Uploads pumpt niemand die Nachrichtenschleife - der Marquee stand still und der
# fortlaufende Balken blieb minutenlang auf demselben Wert. Beides las sich wie ein Absturz.
# Eine Prozentangabe sagt genau das, was bekannt ist: welcher Schritt von wie vielen erledigt ist.
# Ist die Gesamtzahl nicht bekannt (Marquee-Faelle), steht dort nur, dass etwas laeuft.
$script:progressLabel = New-Object System.Windows.Forms.Label
$script:progressLabel.Location = New-Object System.Drawing.Point(10, 2)
$script:progressLabel.Width = 964
$script:progressLabel.Height = 20
$script:progressLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:progressLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:progressLabel.Visible = $false
$bottomPanel.Controls.Add($script:progressLabel)

# Abbruch-Knopf, rechts in derselben Zeile wie die Fortschrittsanzeige.
#
# Einen solchen Knopf gab es schon einmal; er wurde entfernt, weil er neben einem Balken sass, der
# waehrend der langen Schritte einfror - der Klick wurde erst nach dem Upload sichtbar. Was sich
# seither geaendert hat: der Paketbau laeuft in einem eigenen Runspace und die Warteschleifen
# pumpen die Nachrichtenschleife (35-Packaging), waehrend Upload und Zuweisungen weiter auf dem
# UI-Thread liegen. Damit ist der Knopf waehrend Paketbau und Wiederholungspausen wirklich
# klickbar, und waehrend eines Uploads greift er am naechsten App-Wechsel. Er wird deshalb nur
# gezeigt, wo der Merker auch abgefragt wird (Show-Progress -Cancellable).
$script:cancelRunButton = New-Object System.Windows.Forms.Button
$script:cancelRunButton.Tag = 'btn-secondary'
$script:cancelRunButton.Text = Get-UiString 'CancelRunButton'
$script:cancelRunButton.Size = New-Object System.Drawing.Size(140, 26)
$script:cancelRunButton.Location = New-Object System.Drawing.Point(834, 0)
$script:cancelRunButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$script:cancelRunButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:cancelRunButton.Visible = $false
$bottomPanel.Controls.Add($script:cancelRunButton)

# 0 = Gesamtzahl unbekannt (frueher: Marquee). Sonst die Anzahl der Schritte des Laufs.
$script:progressTotal = 0
$script:progressCurrent = 0

# Schreibt den Text neu. Prozent wird aus ERLEDIGTEN Schritten gerechnet, nie aufgerundet - 100 %
# steht erst da, wenn wirklich alles durch ist.
function Update-ProgressDisplay {
  if (-not $script:progressLabel) { return }
  if ($script:progressTotal -gt 0) {
    $done = [Math]::Min([Math]::Max(0, $script:progressCurrent), $script:progressTotal)
    $percent = [int][Math]::Floor(($done * 100.0) / $script:progressTotal)
    $script:progressLabel.Text = (Get-UiString 'ProgressPercentText') -f $percent, $done, $script:progressTotal
  } else {
    $script:progressLabel.Text = Get-UiString 'ProgressRunningText'
  }
}

# Beginnt eine Anzeige. -Total 0 (Standard) heisst: Anzahl der Schritte unbekannt.
#
# -Cancellable darf NUR setzen, wer $script:cancelBatch in seiner Schleife auch abfragt. Ein
# Abbruch-Knopf, der nichts tut, ist schlimmer als keiner: der Benutzer klickt, nichts passiert,
# und er glaubt dem Programm beim naechsten Mal nichts mehr.
function Show-Progress {
  param([int]$Total = 0, [switch]$Cancellable)
  $script:progressTotal = [Math]::Max(0, $Total)
  $script:progressCurrent = 0
  Update-ProgressDisplay
  if ($script:progressLabel) { $script:progressLabel.Visible = $true }
  if ($script:cancelRunButton) {
    $script:cancelRunButton.Text = Get-UiString 'CancelRunButton'
    $script:cancelRunButton.Enabled = $true
    $script:cancelRunButton.Visible = [bool]$Cancellable
  }
}

# Ein einziger Weg, einen Lauf zu stoppen - Knopf, Trennen und Fensterschluss benutzen denselben.
# Der Merker wird gesetzt, nicht der Vorgang abgeschossen: abgefragt wird er an Punkten, an denen
# nichts halb erledigt zurueckbleibt (zwischen zwei Apps, im Paketbau, in einer Wartepause).
function Request-RunCancel {
  param([string]$Reason = 'user')
  $script:cancelBatch = $true
  if ($script:cancelRunButton -and $script:cancelRunButton.Visible) {
    # Bleibt sichtbar (der Lauf laeuft ja noch), aber ein zweiter Klick aendert nichts mehr.
    $script:cancelRunButton.Enabled = $false
  }
  Write-Log ("Run cancel requested ({0}); stopping at the next safe point." -f $Reason)
}

# Zahl der ERLEDIGTEN Schritte.
function Set-ProgressValue {
  param([int]$Current)
  $script:progressCurrent = [Math]::Max(0, $Current)
  Update-ProgressDisplay
}

function Hide-Progress {
  $script:progressTotal = 0
  $script:progressCurrent = 0
  if ($script:progressLabel) {
    $script:progressLabel.Text = ''
    $script:progressLabel.Visible = $false
  }
  if ($script:cancelRunButton) { $script:cancelRunButton.Visible = $false }
}

function Test-ProgressVisible {
  return [bool]($script:progressLabel -and $script:progressLabel.Visible)
}

# Batch step counter shown in the packaging/upload status lines, e.g. "(2/8) ". Empty outside a batch.
$script:batchProgressPrefix = ''

# Der eine Merker fuer "diesen Lauf beenden". Gesetzt wird er ueber Request-RunCancel - von drei
# Stellen: dem Abbruch-Knopf, "Trennen"/"Abmelden" waehrend eines Laufs und dem Fensterschluss.
# Abgefragt wird er nur dort, wo nichts halb erledigt zurueckbleibt: zwischen zwei Apps
# (60-Batch), im Paketbau und in den Wiederholungspausen (35-Packaging) sowie in der Update-Suche.
# Ein laufender Upload nach Intune wird NIE unterbrochen.
$script:cancelBatch = $false

# Collapsible activity log: a slim toggle above the log box. Collapsing hides the log and
# lets the main content area grow into the reclaimed space.
#
# Startzustand aus den Einstellungen, standardmaessig EINGEKLAPPT. Aufgeklappt nahm das Protokoll
# 120 px weg (waehrend eines Laufs bis zu 40 % der Fensterhoehe) und wiederholte in seiner letzten
# Zeile, was die Statuszeile ohnehin sagt - Update-Status schreibt in beide.
$script:logExpanded = [bool]$script:settings.LogExpanded
$logToggle = New-Object System.Windows.Forms.Button
$logToggle.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$logToggle.FlatAppearance.BorderSize = 0
$logToggle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$logToggle.Location = New-Object System.Drawing.Point(10, 0)
$logToggle.Size = New-Object System.Drawing.Size(220, 26)
$logToggle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$logToggle.Cursor = [System.Windows.Forms.Cursors]::Hand
$logToggle.Tag = 'no-theme'
$bottomPanel.Controls.Add($logToggle)

function Set-LogExpanded {
  param(
    [bool]$Expanded,
    # Beim Aufbau des Fensters wird der gespeicherte Zustand nur angewandt, nicht erneut gespeichert.
    [switch]$SkipSave
  )
  $script:logExpanded = $Expanded
  if (-not $SkipSave -and $script:settings -and [bool]$script:settings.LogExpanded -ne $Expanded) {
    $script:settings.LogExpanded = $Expanded
    try { Save-Settings } catch { Write-LogDebug 'save log state' }
  }
  $chevron = if ($Expanded) { [System.Char]::ConvertFromUtf32(0x25BE) } else { [System.Char]::ConvertFromUtf32(0x25B8) }
  $logToggle.Text = "$chevron " + (Get-UiString 'ActivityLog')
  $script:outputBox.Visible = $Expanded
  Update-BottomLayout
  # Collapsing/expanding the log changes the content height WITHOUT a form resize, so the elastic
  # updates layout has to be recomputed here as well – otherwise the list keeps its old height.
  try { if (Get-Command Update-UpdatesLayout -ErrorAction SilentlyContinue) { Update-UpdatesLayout } } catch {}
}

# Compact the controls inside the docked lower container. The container itself owns the Bottom
# invariant; this routine only chooses its required height and gives the remaining area to content.
function Update-BottomLayout {
  if (-not $form -or -not $bottomPanel -or -not $mainPanel -or -not $script:statusLabel -or -not $script:outputBox -or -not $logToggle) { return }

  $margin = 10
  $gap = 6
  $statusHeight = [Math]::Max(18, $script:statusLabel.Height)
  $progressVisible = [bool]$script:progressLabel.Visible

  # Der Protokollbereich behaelt seine Hoehe - IMMER.
  #
  # Vorher wuchs er waehrend eines Laufs von 120 auf 210 px und schrumpfte danach zurueck. Gedacht
  # war das als Hilfe (waehrend eines Laufs schaut man ins Protokoll), gemeldet wurde es als Fehler:
  # der Inhalt darueber verliert 90 px mitten in der Arbeit, jede Liste bekommt Bildlaufleisten, und
  # nach dem Lauf springt alles zurueck. Eine Oberflaeche, die ihre Groessen von selbst aendert,
  # verliert genau die Verlaesslichkeit, die man beim Arbeiten braucht.
  $logHeight = 120
  $maxLogHeight = [int]($form.ClientSize.Height * 0.40)
  if ($logHeight -gt $maxLogHeight) { $logHeight = [Math]::Max(80, $maxLogHeight) }

  # Fortschrittstext und Abbruch-Knopf teilen die Zeile MIT dem Protokoll-Umschalter, statt eine
  # eigene zu bekommen.
  #
  # Vorher wuchs der untere Bereich beim Start eines Laufs um 32 px und schrumpfte danach zurueck -
  # derselbe Effekt, der beim Protokollkasten gemeldet wurde, nur kleiner. Der Umschalter ist 220 px
  # breit und 26 px hoch, der Knopf ebenfalls 26: rechts daneben ist genug Platz fuer beide, und die
  # Hoehe des Bereichs aendert sich damit NIE - egal ob gerade etwas laeuft.
  $cancelVisible = [bool]($script:cancelRunButton -and $script:cancelRunButton.Visible)

  # Height is derived solely from visible rows. No invisible placeholder remains below the log.
  $requiredHeight = $margin + $statusHeight
  if ($script:logExpanded) { $requiredHeight += $gap + $logHeight }
  $requiredHeight += $gap + $logToggle.Height
  $bottomPanel.Height = $requiredHeight

  $contentWidth = [Math]::Max(100, $bottomPanel.ClientSize.Width - (2 * $margin))

  $script:statusLabel.Left = $margin
  $script:statusLabel.Width = $contentWidth
  $script:statusLabel.Top = $bottomPanel.ClientSize.Height - $margin - $statusHeight

  if ($script:logExpanded) {
    $script:outputBox.Left = $margin
    $script:outputBox.Width = $contentWidth
    $script:outputBox.Height = $logHeight
    $script:outputBox.Top = $script:statusLabel.Top - $gap - $script:outputBox.Height
    $logToggle.Top = $script:outputBox.Top - $gap - $logToggle.Height
  } else {
    $logToggle.Top = $script:statusLabel.Top - $gap - $logToggle.Height
  }

  # Die Zeile des Umschalters von rechts nach links auffuellen: erst der Abbruch-Knopf (an SEINER
  # Beschriftung gemessen - die deutsche ist laenger als die englische), dann der Fortschrittstext
  # mit dem Rest zwischen Umschalter und Knopf.
  $rowRight = $margin + $contentWidth
  $btnWidth = 0
  if ($cancelVisible) {
    $needed = 120
    try {
      $needed = [System.Windows.Forms.TextRenderer]::MeasureText([string]$script:cancelRunButton.Text, $script:cancelRunButton.Font).Width + 24
    } catch { Write-LogDebug 'measure cancel button' }
    $btnWidth = [Math]::Min([Math]::Max($needed, 100), [Math]::Max(100, [int]($contentWidth / 2)))
    $script:cancelRunButton.Size = New-Object System.Drawing.Size($btnWidth, $script:cancelRunButton.Height)
    $script:cancelRunButton.Left = $rowRight - $btnWidth
    # Mittig zur Zeile des Umschalters, damit die beiden eine Linie bilden.
    $script:cancelRunButton.Top = $logToggle.Top + [int](($logToggle.Height - $script:cancelRunButton.Height) / 2)
  }
  $progressLeft = $logToggle.Left + $logToggle.Width + $gap
  $progressWidth = $rowRight - $progressLeft - $(if ($cancelVisible) { $btnWidth + $gap } else { 0 })
  $script:progressLabel.Left = $progressLeft
  $script:progressLabel.Top = $logToggle.Top + [int](($logToggle.Height - $script:progressLabel.Height) / 2)
  $script:progressLabel.Width = [Math]::Max(60, $progressWidth)

  $mainPanel.Width = [Math]::Max(100, $form.ClientSize.Width - $mainPanel.Left - $margin)
  $mainPanel.Height = [Math]::Max(120, $bottomPanel.Top - $mainPanel.Top - 8)
}
$logToggle.Add_Click({ Set-LogExpanded (-not $script:logExpanded) })
$script:progressLabel.Add_VisibleChanged({ try { Update-BottomLayout } catch {} })
# Show-Progress zeigt erst den Text und dann den Knopf; ohne diesen zweiten Durchgang bliebe die
# Zeile auf der Hoehe ohne Knopf stehen und der Text laege unter ihm.
$script:cancelRunButton.Add_VisibleChanged({ try { Update-BottomLayout } catch {} })
# --- Kopfzeile: Breiten aus den Beschriftungen, nicht aus Pixelkonstanten ------------------------
#
# "Bei Tenant anmelden" braucht 118 px, der Knopf war 120 px breit - mit dem Innenabstand eines
# Buttons heisst das: abgeschnitten, und zwar seit es die deutsche Fassung gibt. Dasselbe droht bei
# jeder weiteren Sprache und bei jedem Design mit breiterer Schrift.
#
# Beide Gruppen der Kopfzeile - die Anmeldegruppe und die Verbunden-Gruppe - werden deshalb von der
# RECHTEN Kante her ausgerichtet und die Knoepfe an ihrem Text gemessen. Die Reihenfolge im Code ist
# die Reihenfolge auf dem Schirm, von rechts nach links.
function Update-HeaderLayout {
  try {
    if (-not $headerPanel) { return }
    # Rechter Rand wie bisher: bei der Entwurfsbreite von 1044 px endete der Anmelde-Knopf bei 968.
    $rightMargin = 76
    $top = $script:headerRowTop
    $height = 36
    $gap = 6

    # Misst die Textbreite eines Steuerelements mit SEINER Schrift - die wechselt mit dem Design.
    $measure = {
      param($ctrl, $minimum)
      $w = $minimum
      try {
        $t = [string]$ctrl.Text
        if ($t) {
          # +30: Innenabstand des Buttons plus Rahmen. Ohne Zuschlag beruehrt der Text den Rand.
          $needed = [System.Windows.Forms.TextRenderer]::MeasureText($t, $ctrl.Font).Width + 30
          if ($needed -gt $w) { $w = $needed }
        }
      } catch { }
      return [int]$w
    }

    $right = $headerPanel.ClientSize.Width - $rightMargin
    if ($right -lt 400) { return }   # Fenster zu schmal zum Ausrichten; Anker halten die Optik

    # --- Anmeldegruppe, von rechts nach links: Knopf, Verlauf-Knopf, Eingabefeld, Beschriftung ---
    if ($loginButton) {
      $w = & $measure $loginButton 120
      $loginButton.Size = New-Object System.Drawing.Size($w, $height)
      $loginButton.Location = New-Object System.Drawing.Point(($right - $w), $top)
      $cursor = $right - $w - $gap
    } else { $cursor = $right }
    if ($recentButton) {
      $recentButton.Location = New-Object System.Drawing.Point(($cursor - $recentButton.Width), $top)
      $cursor = $recentButton.Left - 2
    }
    if ($usernameHost) {
      $usernameHost.Location = New-Object System.Drawing.Point(($cursor - $usernameHost.Width), $top)
      $cursor = $usernameHost.Left - $gap
    }
    if ($usernameLabel) {
      $usernameLabel.Location = New-Object System.Drawing.Point(($cursor - $usernameLabel.PreferredWidth), ($top + 10))
    }

    # --- Verbunden-Gruppe: Abmelden, Trennen, dann der Kundenname mit dem Rest der Breite --------
    $cursor = $right
    if ($logoutButton) {
      $w = & $measure $logoutButton 100
      $logoutButton.Size = New-Object System.Drawing.Size($w, $height)
      $logoutButton.Location = New-Object System.Drawing.Point(($cursor - $w), $top)
      $cursor = $logoutButton.Left - $gap
    }
    if ($disconnectButton) {
      $w = & $measure $disconnectButton 100
      $disconnectButton.Size = New-Object System.Drawing.Size($w, $height)
      $disconnectButton.Location = New-Object System.Drawing.Point(($cursor - $w), $top)
      $cursor = $disconnectButton.Left - $gap
    }
    if ($loginInfoLabel) {
      # Der Kundenname bekommt, was zwischen Anwendungsnamen und den Knoepfen uebrig ist - er ist
      # die wichtigste Angabe der Kopfzeile und darf nicht als erstes gekuerzt werden.
      $labelLeft = 0
      if ($appTitleLabel) { $labelLeft = $appTitleLabel.Left + $appTitleLabel.PreferredWidth + 24 }
      $badgeRoom = if ($authInfoBadge) { $authInfoBadge.Width + $gap } else { 0 }
      $width = $cursor - $labelLeft - $badgeRoom
      if ($width -gt 120) {
        $loginInfoLabel.Location = New-Object System.Drawing.Point($labelLeft, $top)
        $loginInfoLabel.Size = New-Object System.Drawing.Size($width, $height)
        if ($authInfoBadge) {
          $authInfoBadge.Location = New-Object System.Drawing.Point(($labelLeft + $width + $gap), ($top + 10))
        }
      }
    }
  } catch { Write-LogDebug 'header layout' }
}

# Recompute child widths/content height on every resize; Bottom placement is guaranteed by docking.
# Every card is positioned at a fixed design width. Growing them with the window is what makes the
# extra space usable at all - before this, maximising only added empty area on the right while
# version numbers stayed truncated in the update list.
function Update-CardWidths {
  try {
    if (-not $contentPanel) { return }
    foreach ($section in $contentPanel.Controls) {
      # Measured per SECTION, not once from the content panel: a section that scrolls vertically
      # has ~17 px less client width. Sizing every card to the panel width made those cards wider
      # than their own section, which produced a horizontal scrollbar and cards of differing width
      # in the same view.
      $available = $section.ClientSize.Width - 32   # 16 px margin on each side
      if ($available -lt 400) { continue }
      foreach ($child in $section.Controls) {
        if ([string]$child.Tag -ne 'card') { continue }
        # Only cards designed to span the section grow. Narrow cards placed side by side - the
        # dashboard tiles - keep their width; stretching them put all three in the same place.
        $designWidth = $null
        if ($script:cardDesignWidths) { $designWidth = $script:cardDesignWidths[$child.GetHashCode()] }
        if ($null -eq $designWidth -or [int]$designWidth -lt 700) { continue }
        if ($child.Width -ne $available) { $child.Width = $available }
      }
    }
    # A wider card gives its explanations more room, so they need fewer lines - without re-stacking,
    # the rows keep the spacing of the narrow layout and the cards end up with a block of empty
    # space at the bottom.
    if (Get-Command Update-SettingsLayout -ErrorAction SilentlyContinue) { Update-SettingsLayout }
    # Cards clip themselves to a rounded region that is rebuilt on every resize. Without
    # invalidating the container, the previous outline can stay on screen and the card looks
    # like two overlapping frames.
    $contentPanel.Invalidate($true)
  } catch { }   # class 3: a layout hiccup must never break the window
}

$form.Add_Resize({
  try { if ($script:logExpanded -ne $null) { Update-BottomLayout } } catch {}
  try { Update-HeaderLayout } catch {}
  try { Update-CardWidths } catch {}
  # Re-flow the updates section so its list keeps filling the available height.
  try { if (Get-Command Update-UpdatesLayout -ErrorAction SilentlyContinue) { Update-UpdatesLayout } } catch {}
  try { if (Get-Command Update-TenantAppsLayout -ErrorAction SilentlyContinue) { Update-TenantAppsLayout } } catch {}
  try { if (Get-Command Update-StoreLayout -ErrorAction SilentlyContinue) { Update-StoreLayout } } catch {}
  try { if (Get-Command Update-LocalPackagesLayout -ErrorAction SilentlyContinue) { Update-LocalPackagesLayout } } catch {}
  try { if (Get-Command Update-AppSettingsLayout -ErrorAction SilentlyContinue) { Update-AppSettingsLayout } } catch {}
  try { if (Get-Command Update-WorkRecordSectionLayout -ErrorAction SilentlyContinue) { Update-WorkRecordSectionLayout } } catch {}
})

# Disconnect button – quick session end, keeps the cached sign-in for a fast reconnect
$disconnectButton = New-Object System.Windows.Forms.Button
$disconnectButton.Tag = 'btn-secondary'
$disconnectButton.Text = Get-UiString 'DisconnectButton'
$disconnectButton.Location = New-Object System.Drawing.Point(738, 22)
$disconnectButton.Size = New-Object System.Drawing.Size(110, 36)
$disconnectButton.Visible = $false
$disconnectButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$headerPanel.Controls.Add($disconnectButton)

# Logout button – full logout, clears the cached session and forces a real sign-in next time
$logoutButton = New-Object System.Windows.Forms.Button
$logoutButton.Text = Get-UiString 'LogoutButton'
$logoutButton.Location = New-Object System.Drawing.Point(858, 22)
$logoutButton.Size = New-Object System.Drawing.Size(110, 36)
$logoutButton.Visible = $false
$logoutButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$headerPanel.Controls.Add($logoutButton)

# Connection status: a filled dot + "logged in as" text, shown only while connected. The dot
# follows the theme foreground (monochrome) instead of a status colour.
$connStatusDot = New-Object System.Windows.Forms.Label
$connStatusDot.Text = [System.Char]::ConvertFromUtf32(0x25CF)   # ●
$connStatusDot.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$connStatusDot.Location = New-Object System.Drawing.Point(430, 31)
$connStatusDot.AutoSize = $true
$connStatusDot.Visible = $false
$connStatusDot.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$headerPanel.Controls.Add($connStatusDot)

# Fixed-width, right-truncated (ellipsis) so a long UPN never overflows into the window edge
# or the Disconnect button. Sits just right of the status dot, ending before Disconnect (738).
$loginInfoLabel = New-Object System.Windows.Forms.Label
$loginInfoLabel.Text = ""
$loginInfoLabel.Location = New-Object System.Drawing.Point(438, 22)
$loginInfoLabel.AutoSize = $false
$loginInfoLabel.Size = New-Object System.Drawing.Size(294, 36)
$loginInfoLabel.AutoEllipsis = $true
# Right-aligned so the status (incl. the leading ● dot, folded into the text) sits tidily next
# to the Disconnect button and shares the buttons' vertical centre, instead of floating mid-header.
$loginInfoLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$loginInfoLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$loginInfoLabel.Visible = $false
$headerPanel.Controls.Add($loginInfoLabel)

# "What is the difference between Disconnect and Logout?" – answered right where the two buttons
# are, instead of only in a tooltip on each button. Placed in the gap between the status text and
# Disconnect; the label above was shortened by the same amount so nothing overlaps. Shown only
# while connected (both buttons are), toggled in Set-ConnectedUIState.
$loginInfoLabel.Size = New-Object System.Drawing.Size(272, 36)
$authInfoBadge = Add-SectionInfoBadge -Parent $headerPanel -AfterLabel $loginInfoLabel -TextKey 'InfoAuth'
$authInfoBadge.Location = New-Object System.Drawing.Point(716, 32)
$authInfoBadge.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$authInfoBadge.Visible = $false

# --- Main area: left sidebar navigation + content region (replaces the old tab control) ---
# $mainPanel sits where the tab control used to; inside it a Dock=Left sidebar and a
# Dock=Fill content panel split the space. Each former "tab" is now a Panel added to the
# content panel and toggled by the sidebar buttons.
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Location = New-Object System.Drawing.Point($script:mainPanelIndent, $script:mainPanelTop)
$mainPanel.Size = New-Object System.Drawing.Size(974, 476)
$mainPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$form.Controls.Add($mainPanel)

$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

$sidebarPanel = New-Object System.Windows.Forms.Panel
$sidebarPanel.Dock = [System.Windows.Forms.DockStyle]::Left
$sidebarPanel.Width = 220
$sidebarPanel.Tag = 'no-theme'   # styled by Update-SidebarTheme, not the generic themer

# Add content FIRST (innermost/fill), sidebar LAST (outer/left) – WinForms docks in
# reverse z-order, so the last-added docked control claims its edge first.
$mainPanel.Controls.Add($contentPanel)
$mainPanel.Controls.Add($sidebarPanel)

# Section registry + switcher --------------------------------------------------
$script:sections = [System.Collections.Generic.List[object]]::new()
$script:activeSection = $null

# $Group teilt die Navigation in die zwei Aufgaben, die die Info-Texte bisher dreimal in Worten
# erklaeren mussten ("Dieser Bereich ist fuer Apps, die es in Intune noch NICHT gibt", "Das ist
# NICHT die Liste Ihrer bereitgestellten Apps"). Was die Anordnung sagt, muss kein Text sagen.
# Leer = kein Gruppentitel darueber (Uebersicht und Einstellungen stehen fuer sich).
function Add-Section {
  param([string]$Key, [System.Windows.Forms.Panel]$Panel, [string]$Label, [string]$Group = '')
  $Panel.Dock = [System.Windows.Forms.DockStyle]::Fill
  $Panel.Visible = $false
  $contentPanel.Controls.Add($Panel)
  $script:sections.Add([pscustomobject]@{ Key = $Key; Panel = $Panel; Label = $Label; Group = $Group; NavButton = $null })
}

# Sidebar colors are derived from the active theme so the nav stays readable in every theme.
$script:sidebarBackColor  = [System.Drawing.Color]::FromArgb(48,48,51)
$script:sidebarForeColor  = [System.Drawing.Color]::FromArgb(232,232,232)

# Sidebar icons use the Windows "Segoe MDL2 Assets" font (real vector icon glyphs), rendered
# to small bitmaps so their colour can follow the theme + active state.
$script:navGlyphs = @{
  dashboard  = 0xE80F   # home
  winget     = 0xE710   # add (plus)
  store      = 0xE719   # shop bag - Microsoft Store apps
  updates    = 0xE72C   # refresh
  tenant     = 0xE71D   # all apps
  ownpackage = 0xE7B8   # package / box
  localpackages = 0xE8B7   # folder - Paketkopien auf der Platte
  appsettings = 0xE8B3     # select-all - Einstellungen fuer MEHRERE Apps auf einmal;
                           # bewusst nicht das Listensymbol der Nachbarn darueber
  discovered = 0xE721   # search
  workrecord = 0xE9D9   # analytics - der Leistungsnachweis dieser/der letzten Sitzung
  settings   = 0xE713   # settings gear
  leistung   = 0xE9D9   # report / chart
}
$script:navIconFont = $null
try { $script:navIconFont = New-Object System.Drawing.Font("Segoe MDL2 Assets", 12) } catch {}

function Get-NavIconBitmap {
  param([int]$Glyph, [System.Drawing.Color]$Color, [int]$Size = 20, [int]$Dpi = 96)
  if (-not $script:navIconFont) { return $null }
  # Render the glyph crisply and CENTERED. The old version used a fixed 20px bitmap with a
  # hand-tuned (-2,1) offset (off-centre + slightly clipped) and no DPI scaling, so the icons
  # looked rough and small on high-DPI displays. Now: scale the bitmap by the monitor DPI, size
  # the glyph to ~78% of the box, and centre it via a StringFormat. GridFit hinting keeps the
  # thin icon strokes sharp.
  $scale = if ($Dpi -ge 96) { [double]$Dpi / 96.0 } else { 1.0 }
  $px = [int][math]::Round($Size * $scale)
  if ($px -lt 1) { $px = $Size }
  $bmp = New-Object System.Drawing.Bitmap $px, $px
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $f = New-Object System.Drawing.Font("Segoe MDL2 Assets", [single]($px * 0.78), [System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = [System.Drawing.StringAlignment]::Center
  $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
  $br = New-Object System.Drawing.SolidBrush $Color
  $g.DrawString([System.Char]::ConvertFromUtf32($Glyph), $f, $br, (New-Object System.Drawing.RectangleF(0, 0, [single]$px, [single]$px)), $sf)
  $br.Dispose(); $sf.Dispose(); $f.Dispose(); $g.Dispose()
  return $bmp
}

function Set-NavButtonIcon {
  param($Button, [int]$Glyph, [System.Drawing.Color]$Color)
  if (-not $script:navIconFont -or -not $Button) { return }
  $old = $Button.Image
  $dpi = 96; try { if ($Button.DeviceDpi) { $dpi = $Button.DeviceDpi } } catch { Write-LogDebug ("Nav icon DPI: {0}" -f $_.Exception.Message) }
  $Button.Image = Get-NavIconBitmap -Glyph $Glyph -Color $Color -Dpi $dpi
  $Button.ImageAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $Button.TextImageRelation = [System.Windows.Forms.TextImageRelation]::ImageBeforeText
  if ($old) { $old.Dispose() }
}

function Update-SidebarTheme {
  $t = $script:currentTheme
  $script:sidebarBackColor = $t.ButtonSecondaryBackColor
  $script:sidebarForeColor = $t.ForeColor
  if ($sidebarPanel) { $sidebarPanel.BackColor = $script:sidebarBackColor }
  # Die Gruppentitel tragen 'no-theme' (wie die Nav-Knoepfe) und werden deshalb hier gefaerbt, nicht
  # vom allgemeinen Themer - sonst bekaemen sie die Farben des Inhaltsbereichs statt der Leiste.
  foreach ($gl in @($script:navGroupLabelList)) {
    if (-not $gl) { continue }
    try {
      $gl.BackColor = $script:sidebarBackColor
      $gl.ForeColor = Get-DimmedColor -Fore $script:sidebarForeColor -Back $script:sidebarBackColor -Ratio 0.45
    } catch { }
  }
  if ($navFlow) { $navFlow.BackColor = $script:sidebarBackColor }
  if ($script:activeSection) { Show-Section $script:activeSection }
}

# Explicitly theme the bottom status strip (status label, activity-log box, log toggle).
# A ReadOnly multiline TextBox in particular keeps a white background unless its BackColor is
# forced, so we set these here rather than relying only on the generic themer.
function Update-StatusStripTheme {
  $t = $script:currentTheme
  if ($script:outputBox) {
    $script:outputBox.BackColor = $t.TextBoxBackColor
    $script:outputBox.ForeColor = $t.TextBoxForeColor
    $script:outputBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  }
  if ($script:statusLabel) {
    $script:statusLabel.BackColor = $t.BackColor
    $script:statusLabel.ForeColor = $t.SecondaryForeColor
  }
  if ($logToggle) {
    $logToggle.BackColor = $t.BackColor
    $logToggle.ForeColor = $t.SecondaryForeColor
    $logToggle.FlatAppearance.MouseOverBackColor = Get-DimmedColor -Fore $t.ForeColor -Back $t.BackColor -Ratio 0.1
  }
}

# The classic menu bar is 'no-theme' (Set-GuiTheme skips ToolStrips). A plain BackColor is
# not enough: the ProfessionalRenderer draws light dropdown chrome, so menu text became
# invisible. We give it a proper theme-coloured ColorTable + renderer instead.
# Färbt einen Menüeintrag und ALLE seine Untereinträge, beliebig tief.
#
# Ein Separator hat kein ForeColor, das Setzen wirft aber auch nicht - der Versuch wird trotzdem
# einzeln abgesichert, damit ein einzelner unpassender Eintragstyp nicht den Rest des Menüs
# ungefärbt lässt.
function Set-MenuItemColorsDeep {
  param(
    $Item,
    [System.Drawing.Color]$Back,
    [System.Drawing.Color]$Fore,
    [System.Drawing.Color]$Disabled
  )
  if (-not $Item) { return }
  try {
    $Item.BackColor = $Back
    $Item.ForeColor = if ($Item.Enabled) { $Fore } else { $Disabled }
  } catch { }
  try {
    if ($Item.HasDropDownItems) {
      # Auch die Fläche des Klappmenüs selbst, nicht nur die Einträge darauf: sonst bleibt der Rand
      # um die Einträge herum in der Systemfarbe stehen.
      try { $Item.DropDown.BackColor = $Back } catch { }
      foreach ($child in $Item.DropDownItems) {
        Set-MenuItemColorsDeep -Item $child -Back $Back -Fore $Fore -Disabled $Disabled
      }
    }
  } catch { }
}

function Update-MenuTheme {
  if (-not $menuStrip) { return }
  $t = $script:currentTheme
  if (-not ('DarkMenuColorTable' -as [type])) {
    try {
    Add-Type -ReferencedAssemblies @('System.Drawing', 'System.Drawing.Primitives', 'System.Windows.Forms') @"
using System.Drawing; using System.Windows.Forms;
public class DarkMenuColorTable : ProfessionalColorTable {
  Color _bg,_sel,_bor;
  public DarkMenuColorTable(Color bg, Color sel, Color bor){ _bg=bg; _sel=sel; _bor=bor; UseSystemColors=false; }
  public override Color ToolStripDropDownBackground { get { return _bg; } }
  public override Color ImageMarginGradientBegin { get { return _bg; } }
  public override Color ImageMarginGradientMiddle { get { return _bg; } }
  public override Color ImageMarginGradientEnd { get { return _bg; } }
  public override Color MenuStripGradientBegin { get { return _bg; } }
  public override Color MenuStripGradientEnd { get { return _bg; } }
  public override Color ToolStripGradientBegin { get { return _bg; } }
  public override Color ToolStripGradientMiddle { get { return _bg; } }
  public override Color ToolStripGradientEnd { get { return _bg; } }
  public override Color MenuBorder { get { return _bor; } }
  public override Color MenuItemBorder { get { return _sel; } }
  public override Color MenuItemSelected { get { return _sel; } }
  public override Color MenuItemSelectedGradientBegin { get { return _sel; } }
  public override Color MenuItemSelectedGradientEnd { get { return _sel; } }
  public override Color MenuItemPressedGradientBegin { get { return _bg; } }
  public override Color MenuItemPressedGradientEnd { get { return _bg; } }
  public override Color SeparatorDark { get { return _bor; } }
  public override Color SeparatorLight { get { return _bor; } }
}
"@
    } catch { }
  }
  $bg  = Get-HeaderBackColor $t
  $sel = Get-DimmedColor -Fore $t.ForeColor -Back $bg -Ratio 0.18
  $bor = Get-DimmedColor -Fore $t.ForeColor -Back $bg -Ratio 0.30
  try { $menuStrip.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object DarkMenuColorTable($bg, $sel, $bor))) } catch {}
  $menuStrip.BackColor = $bg
  $menuStrip.ForeColor = $t.ForeColor
  # REKURSIV, nicht eine Ebene tief.
  #
  # Die frühere Fassung färbte die obersten Einträge und deren direkte Kinder. Das reichte genau so
  # lange, wie das Menü zwei Ebenen hatte. Mit "Ansicht > Design > Heller Modus" liegen die
  # Themennamen auf Ebene DREI - sie wurden nie erreicht, behielten die Systemfarbe und standen
  # dunkelgrau auf dunklem Grund. Sichtbar wurde das erst im dunklen Design, weil die Systemfarbe
  # für einen hellen Hintergrund gedacht ist.
  #
  # Deshalb rekursiv statt zwei geschachtelter Schleifen: eine dritte Ebene, die morgen dazukommt,
  # darf nicht wieder unlesbar sein. Deaktivierte Einträge bekommen die gedämpfte Farbe - mit der
  # normalen Vordergrundfarbe sähen sie aus wie anklickbar.
  foreach ($it in $menuStrip.Items) {
    Set-MenuItemColorsDeep -Item $it -Back $bg -Fore $t.ForeColor -Disabled $t.SecondaryForeColor
  }
  # Recent-logins context menu shares the same dark renderer/colors as the main menu bar so its
  # dropdown is readable in the dark theme (it is 'no-theme', i.e. skipped by the generic themer).
  if ($recentMenu) {
    try { $recentMenu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object DarkMenuColorTable($bg, $sel, $bor))) } catch {}
    $recentMenu.BackColor = $bg
    $recentMenu.ForeColor = $t.ForeColor
    foreach ($it in $recentMenu.Items) {
      Set-MenuItemColorsDeep -Item $it -Back $bg -Fore $t.ForeColor -Disabled $t.SecondaryForeColor
    }
  }
}

function Show-Section {
  param([string]$Key)
  $script:activeSection = $Key
  try { Write-Log ("Section -> {0}" -f $Key) } catch {}
  # 1) Switch panels FIRST and unconditionally – per-panel guarded so nothing can prevent the
  #    switch, and forced to repaint so the new section is actually shown.
  foreach ($s in $script:sections) {
    try {
      $isActive = ($s.Key -eq $Key)
      $s.Panel.Visible = $isActive
      if ($isActive) { $s.Panel.BringToFront() }
    } catch { try { Write-Log ("Nav switch error ({0}): {1}" -f $s.Key, $_.Exception.Message) } catch {} }
  }
  try { if ($contentPanel) { $contentPanel.Refresh() } } catch {}
  # A hidden panel reports a stale ClientSize, so cards resized while it was invisible can end up
  # wider than their section - which is what produced the horizontal scrollbar and the mismatched
  # card widths. Re-measure now that this section is actually shown.
  try { Update-CardWidths } catch {}
  # Das Dashboard fragt NICHT mehr bei jedem Besuch drei Mal den Tenant ab. Gemeldet als "es hängt
  # kurz, wenn ich auf Dashboard klicke": jeder Besuch kostete Inventar + Update-Kennzeichen +
  # abgeloeste Apps, und weil das auf dem UI-Thread laeuft, fror das Fenster dabei ein. Aktualisiert
  # wird jetzt bei der Anmeldung, nach einem Lauf, der die Zahlen aendert (dashboardStale), und auf
  # Knopfdruck. Der Stand steht unter den Kacheln, damit die Zahlen nie stumm veralten.
  if ($Key -eq 'dashboard' -and $script:isConnected -and (Get-Command Refresh-Dashboard -ErrorAction SilentlyContinue)) {
    $neverLoaded = ($script:dashboardLastRefresh -eq [datetime]::MinValue)
    if ($neverLoaded -or $script:dashboardStale) {
      try { Refresh-Dashboard -Force } catch { try { Write-Log ("Dashboard refresh (nav) error: {0}" -f $_.Exception.Message) } catch {} }
    } else {
      try { Update-DashboardFreshness } catch {}
    }
  }
  # Size the updates list to the panel the moment the section becomes visible (its ClientSize is
  # only meaningful once shown).
  if ($Key -eq 'updates' -and (Get-Command Update-UpdatesLayout -ErrorAction SilentlyContinue)) {
    try { Update-UpdatesLayout } catch {}
  }
  if ($Key -eq 'tenant' -and (Get-Command Update-TenantAppsLayout -ErrorAction SilentlyContinue)) {
    try { Update-TenantAppsLayout } catch {}
  }
  if ($Key -eq 'ownpackage' -and (Get-Command Update-OwnPackageLayout -ErrorAction SilentlyContinue)) {
    try { Update-OwnPackageLayout } catch {}
  }
  if ($Key -eq 'localpackages' -and (Get-Command Update-LocalPackagesLayout -ErrorAction SilentlyContinue)) {
    try { Update-LocalPackagesLayout } catch {}
  }
  if ($Key -eq 'store' -and (Get-Command Update-StoreLayout -ErrorAction SilentlyContinue)) {
    try { Update-StoreLayout } catch {}
  }
  # Der Editor laedt die App-Liste beim OEFFNEN, nicht beim Aufbau des Fensters - vorher ist niemand
  # angemeldet. Nur einmal je Sitzung; der Knopf "Neu laden" im Bereich holt den Rest.
  if ($Key -eq 'workrecord' -and (Get-Command Update-WorkRecordSectionLayout -ErrorAction SilentlyContinue)) {
    try { Update-WorkRecordSectionLayout } catch {}
  }
  if ($Key -eq 'appsettings' -and (Get-Command Update-AppSettingsLayout -ErrorAction SilentlyContinue)) {
    try { Update-AppSettingsLayout } catch {}
  }
  if ($Key -eq 'appsettings' -and $script:isConnected -and $script:appSettingsLoad -and -not $script:appSettingsLoaded) {
    $script:appSettingsLoaded = $true
    try { & $script:appSettingsLoad } catch { Write-Log ("App settings load failed: {0}" -f $_.Exception.Message) }
  }
  # 2) Restyle the nav buttons (purely cosmetic). Guarded per button so a single failure
  #    (e.g. an icon-render hiccup) can neither abort the loop nor break navigation.
  $activeFill = Get-DimmedColor -Fore $script:currentTheme.ForeColor -Back $script:sidebarBackColor -Ratio 0.16
  $hoverFill  = Get-DimmedColor -Fore $script:currentTheme.ForeColor -Back $script:sidebarBackColor -Ratio 0.09
  foreach ($s in $script:sections) {
    if (-not $s.NavButton) { continue }
    try {
      $isActive = ($s.Key -eq $Key)
      if ($isActive) {
        $s.NavButton.BackColor = $activeFill
        $s.NavButton.ForeColor = $script:currentTheme.ForeColor
      } else {
        $s.NavButton.BackColor = $script:sidebarBackColor
        $s.NavButton.ForeColor = $script:currentTheme.SecondaryForeColor
      }
      $s.NavButton.FlatAppearance.BorderColor = $s.NavButton.BackColor   # border == fill → no outline
      $s.NavButton.FlatAppearance.MouseOverBackColor = if ($isActive) { $activeFill } else { $hoverFill }
      $s.NavButton.FlatAppearance.MouseDownBackColor = $activeFill
      $glyph = $script:navGlyphs[$s.Key]
      if ($glyph) {
        $iconColor = if ($isActive) { $script:currentTheme.ForeColor } else { $script:currentTheme.SecondaryForeColor }
        Set-NavButtonIcon -Button $s.NavButton -Glyph $glyph -Color $iconColor
      }
      $s.NavButton.Invalidate()
    } catch {
      try { Write-Log ("Nav restyle error ({0}): {1}" -f $s.Key, $_.Exception.Message) } catch {}
    }
  }
}



# --- Entra group favorites: shared dialog and the button that opens it ---------------------------
#
# Every place that picks an assignment target registers its combo here, so saving or removing a
# favorite refreshes all of them at once instead of leaving one list stale until the next restart.
$script:assignTargetCombos = [System.Collections.Generic.List[object]]::new()

function Register-AssignTargetCombo {
  param([System.Windows.Forms.ComboBox]$TargetCombo)
  if ($TargetCombo -and -not $script:assignTargetCombos.Contains($TargetCombo)) {
    [void]$script:assignTargetCombos.Add($TargetCombo)
  }
}

function Update-AllAssignTargetCombos {
  foreach ($c in $script:assignTargetCombos) {
    try { Update-AssignTargetCombo -TargetCombo $c } catch {
      try { Write-Log ("Could not refresh an assignment target list: {0}" -f $_.Exception.Message) } catch {}
    }
  }
}

# Save the id currently in $GroupIdBox under a name, and manage what is already stored. Favorites
# belong to the signed-in tenant, so without a session there is nothing to write and the dialog
# says so rather than silently storing under an empty key.
function Show-GroupFavoriteDialog {
  param([System.Windows.Forms.TextBox]$GroupIdBox)

  if (-not (Get-TenantFavoriteKey)) {
    [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'FavDialogNoTenant'), (Get-UiString 'FavDialogTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    return
  }

  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = Get-UiString 'FavDialogTitle'
  $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
  $dlg.ClientSize = New-Object System.Drawing.Size(520, 380)

  $pendingId = ([string]$GroupIdBox.Text).Trim()

  $nameLabel = New-Object System.Windows.Forms.Label
  $nameLabel.Text = Get-UiString 'FavDialogPromptName'
  $nameLabel.Location = New-Object System.Drawing.Point(14, 14)
  $nameLabel.Size = New-Object System.Drawing.Size(490, 20)
  $dlg.Controls.Add($nameLabel)

  $nameBox = New-Object System.Windows.Forms.TextBox
  $nameBox.Location = New-Object System.Drawing.Point(14, 38)
  $nameBox.Width = 370
  $dlg.Controls.Add($nameBox)

  $idLabel = New-Object System.Windows.Forms.Label
  $idLabel.Text = $pendingId
  $idLabel.Location = New-Object System.Drawing.Point(14, 68)
  $idLabel.Size = New-Object System.Drawing.Size(490, 20)
  $dlg.Controls.Add($idLabel)

  $saveButton = New-Object System.Windows.Forms.Button
  $saveButton.Text = Get-UiString 'FavSaveButton'
  $saveButton.Location = New-Object System.Drawing.Point(394, 36)
  $saveButton.Size = New-Object System.Drawing.Size(110, 26)
  $dlg.Controls.Add($saveButton)

  $listLabel = New-Object System.Windows.Forms.Label
  $listLabel.Text = Get-UiString 'FavManageLabel'
  $listLabel.Location = New-Object System.Drawing.Point(14, 100)
  $listLabel.AutoSize = $true
  $dlg.Controls.Add($listLabel)

  $list = New-Object System.Windows.Forms.ListBox
  $list.Location = New-Object System.Drawing.Point(14, 124)
  $list.Size = New-Object System.Drawing.Size(490, 190)
  $dlg.Controls.Add($list)

  $removeButton = New-Object System.Windows.Forms.Button
  $removeButton.Text = Get-UiString 'FavRemoveButton'
  $removeButton.Location = New-Object System.Drawing.Point(14, 326)
  $removeButton.Size = New-Object System.Drawing.Size(130, 30)
  $dlg.Controls.Add($removeButton)

  $closeButton = New-Object System.Windows.Forms.Button
  $closeButton.Text = Get-UiString 'FavCloseButton'
  $closeButton.Location = New-Object System.Drawing.Point(374, 326)
  $closeButton.Size = New-Object System.Drawing.Size(130, 30)
  $dlg.Controls.Add($closeButton)

  $refreshList = {
    $list.Items.Clear()
    foreach ($f in @(Get-GroupFavorites)) {
      [void]$list.Items.Add(("{0}  -  {1}" -f [string]$f.Name, [string]$f.Id))
    }
  }
  & $refreshList

  # Saving is only offered when the field actually held a well-formed id; otherwise the dialog is
  # still useful for removing entries, so it opens rather than refusing outright.
  $saveButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($pendingId)) {
      [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'FavDialogNoId'), (Get-UiString 'FavDialogTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
      return
    }
    if (-not (Test-GuidString $pendingId)) {
      [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'FavDialogBadId'), (Get-UiString 'FavDialogTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }
    $label = ([string]$nameBox.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($label)) { return }
    if (Add-GroupFavorite -Id $pendingId -Name $label) {
      Write-Log ("Group favorite saved for this tenant: {0} ({1})" -f $label, $pendingId)
      Update-Status ((Get-UiString 'FavAddedStatus') -f $label)
      & $refreshList
      Update-AllAssignTargetCombos
    }
  })

  $removeButton.Add_Click({
    $idx = [int]$list.SelectedIndex
    $favorites = @(Get-GroupFavorites)
    if ($idx -lt 0 -or $idx -ge $favorites.Count) { return }
    $victim = $favorites[$idx]
    if (Remove-GroupFavorite -Id ([string]$victim.Id)) {
      Write-Log ("Group favorite removed: {0} ({1})" -f [string]$victim.Name, [string]$victim.Id)
      Update-Status ((Get-UiString 'FavRemovedStatus') -f [string]$victim.Name)
      & $refreshList
      Update-AllAssignTargetCombos
    }
  })

  $closeButton.Add_Click({ $dlg.Close() })
  try { Set-GuiTheme -control $dlg -theme $script:currentTheme } catch { }   # class 3: an unthemed dialog is still usable
  [void]$dlg.ShowDialog()
  $dlg.Dispose()
}

# NOTE: the favorite buttons are built inline at each of the three assignment cards rather than by
# a shared factory. A factory would have to capture the group-id box via .GetNewClosure(), and a
# closure created that way cannot resolve script functions here - Show-GroupFavoriteDialog would
# fail at click time, not at build time. Inline handlers see the script-scope box directly.

# Section: Dashboard (registered first so it is the top nav item + default view). Its
# content (stat tiles, quick actions) is built in the dashboard stage; title placeholder here.
$tabDashboard = New-Object System.Windows.Forms.Panel
Add-Section -Key 'dashboard' -Panel $tabDashboard -Label (Get-UiString 'NavDashboard') -Group 'start'
$dashTitle = New-Object System.Windows.Forms.Label
$dashTitle.Text = Get-UiString 'NavDashboard'
$dashTitle.Location = New-Object System.Drawing.Point(16, 12)
$dashTitle.AutoSize = $true
$dashTitle.Font = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$tabDashboard.Controls.Add($dashTitle)
[void](Add-SectionInfoBadge -Parent $tabDashboard -AfterLabel $dashTitle -TextKey 'InfoDashboard')


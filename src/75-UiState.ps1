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
  # The connected indicator is folded into $loginInfoLabel's text, so the standalone dot stays hidden.
  if ($connStatusDot) { $connStatusDot.Visible = $false }
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

# Track effective built versions per PackageId
$script:builtVersions = @{}
# Cache for winget version lookups (speeds up repeated searches)
$script:wingetVersionCache = @{}
$script:versionCachePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinTuner_VersionCache.json'
# Disk cache loaded once at first use (Fix 1)
$script:diskCache = @{}
$script:diskCacheLoaded = $false

# Create form
$form = New-Object System.Windows.Forms.Form
$form.Text = "WinTuner GUI"
$form.ShowIcon = $false   # hide the default (generic pwsh) title-bar icon for a cleaner look
# Wider than before to make room for the left sidebar next to the content region.
# Resizable: MinimumSize keeps content from clipping while allowing the window to grow.
# Controls are laid out against THIS size while they are being added (WinForms captures each
# anchor margin at that moment), so it must stay the size the positions were designed for. The
# larger default window is applied at the very END of the script, where a real resize pass runs.
$form.Size = New-Object System.Drawing.Size(1010, 850)
$form.MinimumSize = New-Object System.Drawing.Size(940, 680)
# Restore the last window size (saved on close). Clamped to the working area so a window saved on a
# larger/second monitor can never open bigger than the current screen.
try {
  $sw = [int]$script:settings.WindowWidth; $sh = [int]$script:settings.WindowHeight
  if ($sw -ge 940 -and $sh -ge 680) {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size([Math]::Min($sw, $wa.Width), [Math]::Min($sh, $wa.Height))
  }
  if ($script:settings.WindowMaximized) { $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized }
} catch {}
# Modern default font for every control that doesn't set its own (ambient inheritance) –
# the previous default was the pre-Vista "Microsoft Sans Serif".
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Padding = '5,5,5,5'

# Header panel – contains all login/top controls so they stay in one row
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 78
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
[void]$menuTools.DropDownItems.Add($miClearCache)
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
[void]$menuTools.DropDownItems.Add($miClearRecent)

# Open the persistent activity log file – the fastest way to hand a full history to support
# (the in-window log only shows the current session and is capped by the textbox).
$miOpenLog = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpenLog.Text = Get-UiString 'MenuOpenLogFile'
$miOpenLog.Add_Click({
  try {
    $logPath = $script:logFilePath
    if (Test-Path $logPath) {
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
[void]$menuTools.DropDownItems.Add($miOpenLog)

# Bulk editor for assignment settings of apps already in Intune (notifications, availability,
# deadline, auto-update of superseded versions).
$miAppSettings = New-Object System.Windows.Forms.ToolStripMenuItem
$miAppSettings.Text = Get-UiString 'MenuAppSettings'
$miAppSettings.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try { Show-AppSettingsDialog } catch { Write-Log ("App settings dialog failed: {0}" -f $_.Exception.Message) }
})
[void]$menuTools.DropDownItems.Add($miAppSettings)
[void]$menuStrip.Items.Add($menuTools)

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
$menuLeistung = New-Object System.Windows.Forms.ToolStripMenuItem
$menuLeistung.Text = Get-UiString 'MenuShowLeistung'
$menuLeistung.Add_Click({ Show-LeistungstextDialog })
[void]$menuStrip.Items.Add($menuLeistung)

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
[void]$menuStrip.Items.Add($menuTheme)
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
[void]$menuStrip.Items.Add($menuLanguage)
Update-LanguageMenuChecks

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
$appTitleLabel = New-Object System.Windows.Forms.Label
$appTitleLabel.Text = "WinTuner"
$appTitleLabel.Location = New-Object System.Drawing.Point(16, 22)
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
      [void]$src.Add($u)
      $mi = $recentMenu.Items.Add($u)
      $mi.Add_Click({ param($s, $ev) $usernameBox.Text = $s.Text })
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

# Progress bar (appears between tabs and log when active)
$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location = New-Object System.Drawing.Point(10, 2)
$script:progressBar.Width = 964
$script:progressBar.Height = 20
$script:progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:progressBar.Visible = $false
$bottomPanel.Controls.Add($script:progressBar)

# "Stop after current app": packaging a single app blocks the UI thread (the module call is
# synchronous), so the window can show "Not responding" for minutes on big installers. A click here
# is queued by Windows and picked up at the next DoEvents – i.e. between two apps – which lets a
# long batch be ended cleanly without killing the app mid-upload.
$script:cancelBatch = $false
$cancelBatchButton = New-Object System.Windows.Forms.Button
$cancelBatchButton.Tag = 'btn-secondary'
$cancelBatchButton.Text = Get-UiString 'CancelBatchButton'
$cancelBatchButton.Location = New-Object System.Drawing.Point(830, 0)
$cancelBatchButton.Size = New-Object System.Drawing.Size(144, 28)
$cancelBatchButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$cancelBatchButton.Visible = $false
$cancelBatchButton.Add_Click({
  $script:cancelBatch = $true
  try { Update-Status (Get-UiString 'CancelBatchRequestedStatus') } catch {}
  try { Write-Log "Batch cancel requested by user - stopping after the current app." } catch {}
})
$bottomPanel.Controls.Add($cancelBatchButton)

function Set-CancelBatchButtonVisible {
  param([bool]$Visible)
  if (-not $cancelBatchButton -or -not $script:progressBar) { return }
  $gap = 10
  if ($Visible) {
    # The button occupies its own area; the progress bar ends before it instead of continuing
    # underneath. Both controls are right-anchored, so the gap survives window resizing.
    $script:progressBar.Width = [Math]::Max(100, $cancelBatchButton.Left - $script:progressBar.Left - $gap)
    $cancelBatchButton.Visible = $true
    $cancelBatchButton.BringToFront()
  } else {
    $cancelBatchButton.Visible = $false
    $script:progressBar.Width = [Math]::Max(100, $bottomPanel.ClientSize.Width - $script:progressBar.Left - 10)
  }
}

# Collapsible activity log: a slim toggle above the log box. Collapsing hides the log and
# lets the main content area grow into the reclaimed space.
$script:logExpanded = $true
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
  param([bool]$Expanded)
  $script:logExpanded = $Expanded
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
  $progressVisible = ($script:progressBar.Visible -or $cancelBatchButton.Visible)

  # While an operation runs, the activity log is what the user actually watches - the section above
  # is mostly an empty list at that moment. So the log grows during a run and shrinks back after.
  # Capped at 40% of the window so the content area can never be squeezed out.
  $logHeight = if ($progressVisible) { 210 } else { 120 }
  $maxLogHeight = [int]($form.ClientSize.Height * 0.40)
  if ($logHeight -gt $maxLogHeight) { $logHeight = [Math]::Max(120, $maxLogHeight) }

  # Height is derived solely from visible rows. No invisible placeholder remains below the log.
  $requiredHeight = $margin + $statusHeight
  if ($script:logExpanded) { $requiredHeight += $gap + $logHeight }
  $requiredHeight += $gap + $logToggle.Height
  if ($progressVisible) { $requiredHeight += $gap + [Math]::Max($script:progressBar.Height, $cancelBatchButton.Height) }
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

  # A running operation gets one extra row above the toggle; otherwise it consumes no height.
  $progressTop = $logToggle.Top - $gap - $script:progressBar.Height
  $script:progressBar.Left = $margin
  $script:progressBar.Top = $progressTop
  $cancelBatchButton.Top = $progressTop - [Math]::Max(0, [int](($cancelBatchButton.Height - $script:progressBar.Height) / 2))
  $cancelBatchButton.Left = [Math]::Max($margin, $bottomPanel.ClientSize.Width - $margin - $cancelBatchButton.Width)
  if ($cancelBatchButton.Visible) {
    $script:progressBar.Width = [Math]::Max(100, $cancelBatchButton.Left - $script:progressBar.Left - 10)
  } else {
    $script:progressBar.Width = $contentWidth
  }

  $mainPanel.Width = [Math]::Max(100, $form.ClientSize.Width - $mainPanel.Left - $margin)
  $mainPanel.Height = [Math]::Max(120, $bottomPanel.Top - $mainPanel.Top - 8)
}
$logToggle.Add_Click({ Set-LogExpanded (-not $script:logExpanded) })
$script:progressBar.Add_VisibleChanged({ try { Update-BottomLayout } catch {} })
$cancelBatchButton.Add_VisibleChanged({ try { Update-BottomLayout } catch {} })
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
    # Cards clip themselves to a rounded region that is rebuilt on every resize. Without
    # invalidating the container, the previous outline can stay on screen and the card looks
    # like two overlapping frames.
    $contentPanel.Invalidate($true)
  } catch { }   # class 3: a layout hiccup must never break the window
}

$form.Add_Resize({
  try { if ($script:logExpanded -ne $null) { Update-BottomLayout } } catch {}
  try { Update-CardWidths } catch {}
  # Re-flow the updates section so its list keeps filling the available height.
  try { if (Get-Command Update-UpdatesLayout -ErrorAction SilentlyContinue) { Update-UpdatesLayout } } catch {}
  try { if (Get-Command Update-TenantAppsLayout -ErrorAction SilentlyContinue) { Update-TenantAppsLayout } } catch {}
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
$mainPanel.Location = New-Object System.Drawing.Point(10, 112)
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

function Add-Section {
  param([string]$Key, [System.Windows.Forms.Panel]$Panel, [string]$Label)
  $Panel.Dock = [System.Windows.Forms.DockStyle]::Fill
  $Panel.Visible = $false
  $contentPanel.Controls.Add($Panel)
  $script:sections.Add([pscustomobject]@{ Key = $Key; Panel = $Panel; Label = $Label; NavButton = $null })
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
  discovered = 0xE721   # search
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
  foreach ($it in $menuStrip.Items) {
    $it.ForeColor = $t.ForeColor
    if ($it.HasDropDownItems) {
      try { $it.DropDown.BackColor = $bg } catch {}
      foreach ($d in $it.DropDownItems) {
        $d.BackColor = $bg
        $d.ForeColor = $t.ForeColor
      }
    }
  }
  # Recent-logins context menu shares the same dark renderer/colors as the main menu bar so its
  # dropdown is readable in the dark theme (it is 'no-theme', i.e. skipped by the generic themer).
  if ($recentMenu) {
    try { $recentMenu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object DarkMenuColorTable($bg, $sel, $bor))) } catch {}
    $recentMenu.BackColor = $bg
    $recentMenu.ForeColor = $t.ForeColor
    foreach ($it in $recentMenu.Items) {
      $it.BackColor = $bg
      if ($it.Enabled) { $it.ForeColor = $t.ForeColor } else { $it.ForeColor = $t.SecondaryForeColor }
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
  # Refresh the dashboard tiles whenever the dashboard becomes visible while connected, so the
  # counts reflect the latest tenant state (e.g. after an update scan) instead of a stale value.
  if ($Key -eq 'dashboard' -and $script:isConnected -and (Get-Command Refresh-Dashboard -ErrorAction SilentlyContinue)) {
    try { Refresh-Dashboard } catch { try { Write-Log ("Dashboard refresh (nav) error: {0}" -f $_.Exception.Message) } catch {} }
  }
  # Size the updates list to the panel the moment the section becomes visible (its ClientSize is
  # only meaningful once shown).
  if ($Key -eq 'updates' -and (Get-Command Update-UpdatesLayout -ErrorAction SilentlyContinue)) {
    try { Update-UpdatesLayout } catch {}
  }
  if ($Key -eq 'tenant' -and (Get-Command Update-TenantAppsLayout -ErrorAction SilentlyContinue)) {
    try { Update-TenantAppsLayout } catch {}
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



# Section: Dashboard (registered first so it is the top nav item + default view). Its
# content (stat tiles, quick actions) is built in the dashboard stage; title placeholder here.
$tabDashboard = New-Object System.Windows.Forms.Panel
Add-Section -Key 'dashboard' -Panel $tabDashboard -Label (Get-UiString 'NavDashboard')
$dashTitle = New-Object System.Windows.Forms.Label
$dashTitle.Text = Get-UiString 'NavDashboard'
$dashTitle.Location = New-Object System.Drawing.Point(16, 12)
$dashTitle.AutoSize = $true
$dashTitle.Font = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$tabDashboard.Controls.Add($dashTitle)
[void](Add-SectionInfoBadge -Parent $tabDashboard -AfterLabel $dashTitle -TextKey 'InfoDashboard')


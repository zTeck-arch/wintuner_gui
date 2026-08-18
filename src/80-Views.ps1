# Stat tiles: big number + caption inside a rounded card. Numbers load on connect.
function New-DashTile {
  param([int]$X, [string]$Caption, [string]$Target)
  $card = New-Card -X $X -Y 56 -W 170 -H 96
  $tabDashboard.Controls.Add($card)
  $num = New-Object System.Windows.Forms.Label
  $num.Text = [System.Char]::ConvertFromUtf32(0x2014)   # em dash placeholder
  $num.Location = New-Object System.Drawing.Point(18, 10)
  $num.AutoSize = $true
  # 22pt (was 26pt): a 26pt number label is 54px tall and its bottom (Y=66) overlapped the caption
  # at Y=64 – a real 2–3 digit count would collide with the caption text. 22pt + the positions below
  # give a clean ~6px gap, and number/caption share the same left edge (x=18).
  $num.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
  $card.Controls.Add($num)
  $cap = New-Object System.Windows.Forms.Label
  $cap.Text = $Caption
  $cap.Location = New-Object System.Drawing.Point(18, 62)
  $cap.AutoSize = $true
  $card.Controls.Add($cap)
  # Make the whole tile a click target that jumps to the relevant section (card + both labels share
  # the handler so a click anywhere on the tile works).
  # IMPORTANT: no .GetNewClosure() here. A closure runs in its own dynamic module, which cannot see
  # SCRIPT-scope functions – the previous version threw "Show-Section is not recognized" on every
  # tile click. The target is carried on the control's .Name and read back from the sender instead
  # (same proven pattern as the sidebar nav buttons). .Name is free; .Tag is taken by the themer.
  if ($Target) {
    foreach ($c in @($card, $num, $cap)) {
      $c.Cursor = [System.Windows.Forms.Cursors]::Hand
      $c.Name = "dashtile_$Target"
      $c.Add_Click({
        param($sender, $e)
        try { Show-Section ($sender.Name.Substring(9)) }   # strip "dashtile_"
        catch { try { Write-Log ("Dashboard tile click error: {0}" -f $_.Exception.Message) } catch {} }
      })
    }
  }
  return $num
}
$script:dashManagedVal    = New-DashTile -X 16  -Caption (Get-UiString 'DashManaged')    -Target 'updates'
$script:dashUpdatesVal    = New-DashTile -X 198 -Caption (Get-UiString 'DashUpdates')    -Target 'updates'
$script:dashSupersededVal = New-DashTile -X 380 -Caption (Get-UiString 'DashSuperseded') -Target 'updates'
# Fourth tile, and the only one that needs no tenant: the package folder grows quietly over months
# and nothing ever pointed at it. Clicking lands in the settings, where the prune button lives.
$script:dashPackagesVal = New-DashTile -X 562 -Caption (Get-UiString 'DashLocalPackages') -Target 'settings'

# Size of the local package folder, formatted for the tile. Deliberately cheap to fail: an
# unreadable or missing folder shows a dash rather than blocking the dashboard.
function Update-LocalPackagesTile {
  try {
    if (-not $script:dashPackagesVal) { return }
    $root = [string]$script:settings.DefaultPackagePath
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
      $script:dashPackagesVal.Text = [System.Char]::ConvertFromUtf32(0x2014)
      return
    }
    $bytes = Get-FolderSizeBytes -Path $root
    $script:dashPackagesVal.Text = if ($bytes -ge 1GB) { '{0:n1} GB' -f ($bytes / 1GB) }
                                   elseif ($bytes -ge 1MB) { '{0:n0} MB' -f ($bytes / 1MB) }
                                   else { '{0:n0} KB' -f ($bytes / 1KB) }
  } catch { }   # class 3: a tile must never break the dashboard
}
Update-LocalPackagesTile

$dashHint = New-Object System.Windows.Forms.Label
$dashHint.Text = Get-UiString 'DashConnectHint'
$dashHint.Location = New-Object System.Drawing.Point(18, 160)
$dashHint.AutoSize = $true
$tabDashboard.Controls.Add($dashHint)

$dashActionsLabel = New-Object System.Windows.Forms.Label
$dashActionsLabel.Text = Get-UiString 'DashQuickActions'
$dashActionsLabel.Location = New-Object System.Drawing.Point(16, 196)
$dashActionsLabel.AutoSize = $true
$dashActionsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$tabDashboard.Controls.Add($dashActionsLabel)

$dashAddBtn = New-Object System.Windows.Forms.Button
$dashAddBtn.Text = Get-UiString 'DashAddApp'
$dashAddBtn.Location = New-Object System.Drawing.Point(16, 228)
$dashAddBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashAddBtn.Add_Click({ Show-Section 'winget' })
$tabDashboard.Controls.Add($dashAddBtn)

$dashUpdBtn = New-Object System.Windows.Forms.Button
$dashUpdBtn.Tag = 'btn-secondary'
$dashUpdBtn.Text = Get-UiString 'DashCheckUpdates'
$dashUpdBtn.Location = New-Object System.Drawing.Point(256, 228)
$dashUpdBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashUpdBtn.Add_Click({ Show-Section 'updates' })
$tabDashboard.Controls.Add($dashUpdBtn)

$dashScanBtn = New-Object System.Windows.Forms.Button
$dashScanBtn.Tag = 'btn-secondary'
$dashScanBtn.Text = Get-UiString 'DashScanDiscovered'
$dashScanBtn.Location = New-Object System.Drawing.Point(496, 228)
$dashScanBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashScanBtn.Add_Click({ Show-Section 'discovered' })
$tabDashboard.Controls.Add($dashScanBtn)

# Row two: these DO something instead of only navigating. All three are local-only - no tenant is
# touched - which is why they are safe one click away. Anything that writes to Intune stays behind
# its own section and confirmation, as the security model requires.
$dashFavBtn = New-Object System.Windows.Forms.Button
$dashFavBtn.Tag = 'btn-secondary'
$dashFavBtn.Text = Get-UiString 'DashCheckFavorites'
$dashFavBtn.Location = New-Object System.Drawing.Point(16, 276)
$dashFavBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashFavBtn.Add_Click({
  # Switch first, so the run is visible where its results appear - the way the login auto-check does.
  Show-Section 'winget'
  [System.Windows.Forms.Application]::DoEvents()
  try { if ($favoriteRefreshButton -and $favoriteRefreshButton.Enabled) { $favoriteRefreshButton.PerformClick() } }
  catch { Write-Log ("Dashboard favourite check failed: {0}" -f $_.Exception.Message) }
})
$tabDashboard.Controls.Add($dashFavBtn)

$dashLocalBtn = New-Object System.Windows.Forms.Button
$dashLocalBtn.Tag = 'btn-secondary'
$dashLocalBtn.Text = Get-UiString 'DashUpdateLocal'
$dashLocalBtn.Location = New-Object System.Drawing.Point(256, 276)
$dashLocalBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashLocalBtn.Add_Click({
  Show-Section 'winget'
  [System.Windows.Forms.Application]::DoEvents()
  try { if ($favoriteAllLocalButton -and $favoriteAllLocalButton.Enabled) { $favoriteAllLocalButton.PerformClick() } }
  catch { Write-Log ("Dashboard local update failed: {0}" -f $_.Exception.Message) }
})
$tabDashboard.Controls.Add($dashLocalBtn)

$dashRecordBtn = New-Object System.Windows.Forms.Button
$dashRecordBtn.Tag = 'btn-secondary'
$dashRecordBtn.Text = Get-UiString 'DashShowRecord'
$dashRecordBtn.Location = New-Object System.Drawing.Point(496, 276)
$dashRecordBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashRecordBtn.Add_Click({
  try { Show-LeistungstextDialog } catch { Write-Log ("Dashboard record dialog failed: {0}" -f $_.Exception.Message) }
})
$tabDashboard.Controls.Add($dashRecordBtn)

# Loads the tile numbers in the background (safe no-op when not connected).
$script:dashboardLastRefresh = [datetime]::MinValue
$script:dashboardRefreshing = $false
$script:dashboardRefreshCooldownSeconds = 30

function Refresh-Dashboard {
  param(
    # Set by the manual refresh path; navigation always goes through the cooldown.
    [switch]$Force
  )
  if (-not $script:isConnected) { return }

  # Re-entrancy guard. The DoEvents call below pumps the message loop, so a second navigation to
  # the dashboard could start this function again while the first run was still enumerating -
  # which produced "Collection was modified; enumeration operation may not execute".
  if ($script:dashboardRefreshing) { return }

  # Every run costs three tenant queries, and each one makes the WinTuner module log "Getting list
  # of published apps". Refreshing on every single navigation turned normal clicking around into a
  # constant stream of queries, so repeat visits reuse the tiles until the cooldown has passed.
  if (-not $Force) {
    $age = ([datetime]::UtcNow - $script:dashboardLastRefresh).TotalSeconds
    if ($age -lt $script:dashboardRefreshCooldownSeconds) { return }
  }
  $script:dashboardRefreshing = $true
  # Fetch the counts synchronously on the UI thread. Running these through Invoke-AsyncOperation
  # (a BackgroundWorker) fails silently because the Graph/WinTuner auth session lives only in the
  # main runspace – a worker thread has no runspace/Graph context, so Get-WtWin32Apps returns
  # nothing and the tiles stayed on "—". The managed-apps queries are quick enough to run inline.
  try {
    Update-Status (Get-UiString 'LoadingAppsStatus')
    [System.Windows.Forms.Application]::DoEvents()
    # Read-only tiles: a few seconds of cache is invisible here and removes three module queries
    # per visit. -Force honours the explicit refresh after sign-in.
    $all = @(Get-CachedWin32Apps -Force:$Force)
    $sup = @(Get-CachedWin32Apps -Superseded -Force:$Force)
    $upd = @(Get-WtWin32Apps -Update $true -Superseded $false -ErrorAction SilentlyContinue)
    if ($script:dashManagedVal)    { $script:dashManagedVal.Text    = "$($all.Count)" }
    if ($script:dashUpdatesVal)    { $script:dashUpdatesVal.Text    = "$($upd.Count)" }
    if ($script:dashSupersededVal) { $script:dashSupersededVal.Text = "$($sup.Count)" }
    Write-Log ("Dashboard refreshed: managed={0} updates={1} superseded={2}" -f $all.Count, $upd.Count, $sup.Count)
    Update-Status (Get-UiString 'DashLoadedStatus')
    $script:dashboardLastRefresh = [datetime]::UtcNow
  } catch {
    Write-Log ("Dashboard refresh failed: {0}" -f $_.Exception.Message)
    Update-Status (Get-UiString 'LoadAppsFailedStatus')
  } finally {
    $script:dashboardRefreshing = $false
  }
}

# Section: WinGet Apps
$tabCreate = New-Object System.Windows.Forms.Panel
Add-Section -Key 'winget' -Panel $tabCreate -Label (Get-UiString 'TabWinGetApps')

# Section title
$wingetTitle = New-Object System.Windows.Forms.Label
$wingetTitle.Text = Get-UiString 'SectionWingetTitle'
$wingetTitle.Location = New-Object System.Drawing.Point(16, 12)
$wingetTitle.AutoSize = $true
$wingetTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabCreate.Controls.Add($wingetTitle)
[void](Add-SectionInfoBadge -Parent $tabCreate -AfterLabel $wingetTitle -TextKey 'InfoWinget')

# --- Card 1: Find package ---
$cardFind = New-Card -X 16 -Y 48 -W 726 -H 118
$tabCreate.Controls.Add($cardFind)

$step1Label = New-Object System.Windows.Forms.Label
$step1Label.Text = Get-UiString 'Step1FindPackage'
$step1Label.Location = New-Object System.Drawing.Point(14, 10)
$step1Label.AutoSize = $true
$step1Label.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardFind.Controls.Add($step1Label)
[void](Add-SectionInfoBadge -Parent $cardFind -AfterLabel $step1Label -TextKey 'InfoCardFind')

$appSearchBox = New-Object System.Windows.Forms.TextBox
if ($null -ne $appSearchBox) {
  $appSearchBox.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
      if ($searchButton -and $searchButton.Enabled) { $searchButton.PerformClick() }
      $e.SuppressKeyPress = $true
    }
  })
}
$appSearchBox.Width = 532
$appSearchHost = New-RoundedInput -Inner $appSearchBox -X 14 -Y 40 -W 532 -H 32
$cardFind.Controls.Add($appSearchHost)

$searchButton = New-Object System.Windows.Forms.Button
$searchButton.Text = Get-UiString 'SearchButton'
$searchButton.Location = New-Object System.Drawing.Point(558, 40)
$searchButton.Width = 152
$searchButton.Height = 32
$cardFind.Controls.Add($searchButton)

$dropdown = New-Object System.Windows.Forms.ComboBox
$dropdown.Width = 374
$dropdown.DropDownWidth = 532
$dropdown.MaxDropDownItems = 14
$dropdown.IntegralHeight = $true
$dropdown.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
# ComboBoxes are placed directly (no rounded input host): the host's rounded border behind the
# combo's own square dropdown box just looked like a box-in-a-box. The square themed combo alone
# is the intended look here.
$dropdown.Location = New-Object System.Drawing.Point(14, 84)
$cardFind.Controls.Add($dropdown)

$favoriteAddButton = New-Object System.Windows.Forms.Button
$favoriteAddButton.Tag = 'btn-secondary'
$favoriteAddButton.Text = Get-UiString 'FavoriteAddButton'
$favoriteAddButton.Location = New-Object System.Drawing.Point(400, 78)
$favoriteAddButton.Width = 146
$favoriteAddButton.Height = 32
$cardFind.Controls.Add($favoriteAddButton)

$versionsButton = New-Object System.Windows.Forms.Button
$versionsButton.Tag = 'btn-secondary'
$versionsButton.Text = Get-UiString 'VersionsButton'
$versionsButton.Location = New-Object System.Drawing.Point(558, 78)
$versionsButton.Width = 152
$versionsButton.Height = 32
$cardFind.Controls.Add($versionsButton)

# Keep the effective version visible next to the step heading. Previously it was only written to
# the transient status/activity area at the bottom, so it was easy to miss before packaging.
$selectedVersionLabel = New-Object System.Windows.Forms.Label
$selectedVersionLabel.Tag = 'hint'
$selectedVersionLabel.Text = (Get-UiString 'SelectedVersionLabel') -f (Get-UiString 'SelectedVersionNone')
$selectedVersionLabel.Location = New-Object System.Drawing.Point(352, 10)
$selectedVersionLabel.Size = New-Object System.Drawing.Size(358, 20)
$selectedVersionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$selectedVersionLabel.AutoEllipsis = $true
$cardFind.Controls.Add($selectedVersionLabel)

# --- Card 2: Package & deploy ---
$cardDeploy = New-Card -X 16 -Y 178 -W 726 -H 214
$tabCreate.Controls.Add($cardDeploy)

$step2Label = New-Object System.Windows.Forms.Label
$step2Label.Text = Get-UiString 'Step2Deploy'
$step2Label.Location = New-Object System.Drawing.Point(14, 10)
$step2Label.AutoSize = $true
$step2Label.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardDeploy.Controls.Add($step2Label)
[void](Add-SectionInfoBadge -Parent $cardDeploy -AfterLabel $step2Label -TextKey 'InfoCardDeploy')

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text = Get-UiString 'PathLabel'
$pathLabel.Location = New-Object System.Drawing.Point(14, 50)
$pathLabel.AutoSize = $true
$cardDeploy.Controls.Add($pathLabel)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Width = 450
$pathBox.Text = Get-DefaultPackagePath
$pathHost = New-RoundedInput -Inner $pathBox -X 112 -Y 42 -W 434 -H 32
$cardDeploy.Controls.Add($pathHost)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Tag = 'btn-secondary'
$browseButton.Text = Get-UiString 'SelectButton'
$browseButton.Location = New-Object System.Drawing.Point(558, 42)
$browseButton.Width = 152
$browseButton.Height = 32
$cardDeploy.Controls.Add($browseButton)
$browseButton.Add_Click({
  $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
  if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $pathBox.Text = $folderBrowser.SelectedPath
  }
})

# Assignment target – without this, a newly created app has NO Intune assignment at all
# and someone has to go set it manually in the portal after every upload.
$assignLabel = New-Object System.Windows.Forms.Label
$assignLabel.Text = Get-UiString 'AssignLabel'
$assignLabel.Location = New-Object System.Drawing.Point(14, 90)
$assignLabel.AutoSize = $true
$cardDeploy.Controls.Add($assignLabel)

$assignTargetCombo = New-Object System.Windows.Forms.ComboBox
$assignTargetCombo.Width = 250
$assignTargetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$assignTargetCombo.Items.AddRange(@((Get-UiString 'AssignNotAssigned'), (Get-UiString 'AssignAllUsers'), (Get-UiString 'AssignAllDevices'), (Get-UiString 'AssignCustomGroup')))
$assignTargetCombo.SelectedIndex = 0
$assignTargetCombo.Location = New-Object System.Drawing.Point(112, 88)
$cardDeploy.Controls.Add($assignTargetCombo)

$assignGroupIdBox = New-Object System.Windows.Forms.TextBox
$assignGroupIdBox.Width = 194
$assignGroupIdHost = New-RoundedInput -Inner $assignGroupIdBox -X 372 -Y 82 -W 180 -H 32
$assignGroupIdHost.Visible = $false
$cardDeploy.Controls.Add($assignGroupIdHost)

$assignFavButton = New-Object System.Windows.Forms.Button
$assignFavButton.Tag = 'btn-secondary'
$assignFavButton.Text = Get-UiString 'FavAddButton'
$assignFavButton.Location = New-Object System.Drawing.Point(558, 82)
$assignFavButton.Size = New-Object System.Drawing.Size(32, 32)
$assignFavButton.Visible = $false
$assignFavButton.Add_Click({ Show-GroupFavoriteDialog -GroupIdBox $assignGroupIdBox })
$cardDeploy.Controls.Add($assignFavButton)

$assignTargetCombo.Add_SelectedIndexChanged({
  $isCustom = ($assignTargetCombo.SelectedItem -eq (Get-UiString 'AssignCustomGroup'))
  $assignGroupIdHost.Visible = $isCustom
  $assignFavButton.Visible = $isCustom
})
Register-AssignTargetCombo -TargetCombo $assignTargetCombo

# Assignment intent (Available / Required / Uninstall) → Deploy-WtWin32App -AvailableFor /
# -RequiredFor / -UninstallFor. Read by SelectedIndex so it is language-independent.
$assignIntentLabel = New-Object System.Windows.Forms.Label
$assignIntentLabel.Text = Get-UiString 'AssignIntentLabel'
$assignIntentLabel.Location = New-Object System.Drawing.Point(14, 130)
$assignIntentLabel.AutoSize = $true
$cardDeploy.Controls.Add($assignIntentLabel)

$script:assignIntentCombo = New-Object System.Windows.Forms.ComboBox
$script:assignIntentCombo.Width = 250
$script:assignIntentCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:assignIntentCombo.Items.AddRange(@((Get-UiString 'IntentAvailable'), (Get-UiString 'IntentRequired'), (Get-UiString 'IntentUninstall')))
$script:assignIntentCombo.SelectedIndex = 0
$script:assignIntentCombo.Location = New-Object System.Drawing.Point(112, 128)
$cardDeploy.Controls.Add($script:assignIntentCombo)

$createButton = New-Object System.Windows.Forms.Button
$createButton.Text = Get-UiString 'CreateButton'
$createButton.Location = New-Object System.Drawing.Point(14, 168)
$createButton.Width = 180
$createButton.Height = 32
$cardDeploy.Controls.Add($createButton)

$uploadButton = New-Object System.Windows.Forms.Button
$uploadButton.Text = Get-UiString 'UploadButton'
$uploadButton.Location = New-Object System.Drawing.Point(204, 168)
$uploadButton.Width = 180
$uploadButton.Height = 32
$uploadButton.Visible = $true
$uploadButton.Enabled = $false
$cardDeploy.Controls.Add($uploadButton)

# Advanced package options (collapsible): architecture / install context / locale, passed to
# New-WtWingetPackage. Empty = keep the module's own default. Hidden until expanded; expanding
# grows the card (its rounded region re-applies on resize).
$advToggle = New-Object System.Windows.Forms.Button
$advToggle.Tag = 'btn-secondary'
$advToggle.Text = (Get-UiString 'AdvancedOptions') + "  " + [System.Char]::ConvertFromUtf32(0x25BE)
$advToggle.Location = New-Object System.Drawing.Point(400, 168)
$advToggle.Size = New-Object System.Drawing.Size(200, 32)
$cardDeploy.Controls.Add($advToggle)

$archLabel = New-Object System.Windows.Forms.Label
$archLabel.Text = Get-UiString 'ArchLabel'
$archLabel.Location = New-Object System.Drawing.Point(14, 214)
$archLabel.AutoSize = $true
$archLabel.Visible = $false
$cardDeploy.Controls.Add($archLabel)

$script:archCombo = New-Object System.Windows.Forms.ComboBox
$script:archCombo.Width = 150
$script:archCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:archCombo.Items.AddRange(@((Get-UiString 'OptDefault'), 'x64', 'x86', 'arm64'))
$script:archCombo.SelectedIndex = 0
$archHost = New-RoundedInput -Inner $script:archCombo -X 150 -Y 208 -W 150 -H 32
$archHost.Visible = $false
$cardDeploy.Controls.Add($archHost)

$contextLabel = New-Object System.Windows.Forms.Label
$contextLabel.Text = Get-UiString 'ContextLabel'
$contextLabel.Location = New-Object System.Drawing.Point(320, 214)
$contextLabel.AutoSize = $true
$contextLabel.Visible = $false
$cardDeploy.Controls.Add($contextLabel)

$script:contextCombo = New-Object System.Windows.Forms.ComboBox
$script:contextCombo.Width = 140
$script:contextCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:contextCombo.Items.AddRange(@((Get-UiString 'OptDefault'), 'System', 'User'))
$script:contextCombo.SelectedIndex = 0
$contextHost = New-RoundedInput -Inner $script:contextCombo -X 470 -Y 208 -W 140 -H 32
$contextHost.Visible = $false
$cardDeploy.Controls.Add($contextHost)

$localeLabel = New-Object System.Windows.Forms.Label
$localeLabel.Text = Get-UiString 'LocaleLabel'
$localeLabel.Location = New-Object System.Drawing.Point(14, 252)
$localeLabel.AutoSize = $true
$localeLabel.Visible = $false
$cardDeploy.Controls.Add($localeLabel)

$script:localeBox = New-Object System.Windows.Forms.TextBox
$script:localeBox.Width = 150
$localeHost = New-RoundedInput -Inner $script:localeBox -X 150 -Y 246 -W 150 -H 32
$localeHost.Visible = $false
$cardDeploy.Controls.Add($localeHost)

# Preferred installer type → New-WtWingetPackage -PreferedInstaller (note the module's spelling).
# A winget manifest can offer several installers; this picks which one is packaged. Index 0 keeps
# the module's own choice, so nothing is passed unless the user really wants a specific type.
$installerTypeLabel = New-Object System.Windows.Forms.Label
$installerTypeLabel.Text = Get-UiString 'InstallerTypeLabel'
$installerTypeLabel.Location = New-Object System.Drawing.Point(320, 252)
$installerTypeLabel.AutoSize = $true
$installerTypeLabel.Visible = $false
$cardDeploy.Controls.Add($installerTypeLabel)

$script:installerTypeCombo = New-Object System.Windows.Forms.ComboBox
$script:installerTypeCombo.Width = 140
$script:installerTypeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
# Values are the WingetIntune.Models.InstallerType enum names; 'Unknown' is the enum default and
# is deliberately not offered - "Default" already means "pass nothing".
[void]$script:installerTypeCombo.Items.AddRange(@((Get-UiString 'OptDefault'),
  'Msi', 'Msix', 'Appx', 'Exe', 'Zip', 'Inno', 'Nullsoft', 'Wix', 'Burn', 'Pwa', 'Portable'))
$script:installerTypeCombo.SelectedIndex = 0
$installerTypeHost = New-RoundedInput -Inner $script:installerTypeCombo -X 470 -Y 246 -W 140 -H 32
$installerTypeHost.Visible = $false
$cardDeploy.Controls.Add($installerTypeHost)

# Installer arguments → New-WtWingetPackage -InstallerArguments. Replaces the silent switches
# winget would derive, so it is left empty unless the user knows the installer needs something else.
$installerArgsLabel = New-Object System.Windows.Forms.Label
$installerArgsLabel.Text = Get-UiString 'InstallerArgsLabel'
$installerArgsLabel.Location = New-Object System.Drawing.Point(14, 290)
$installerArgsLabel.AutoSize = $true
$installerArgsLabel.Visible = $false
$cardDeploy.Controls.Add($installerArgsLabel)

$script:installerArgsBox = New-Object System.Windows.Forms.TextBox
$script:installerArgsBox.Width = 460
$script:installerArgsBox.PlaceholderText = Get-UiString 'InstallerArgsPlaceholder'
$installerArgsHost = New-RoundedInput -Inner $script:installerArgsBox -X 150 -Y 284 -W 460 -H 32
$installerArgsHost.Visible = $false
$cardDeploy.Controls.Add($installerArgsHost)

# Optional Intune display name and role-scope tags exposed by Deploy-WtWin32App.
$overrideAppNameLabel = New-Object System.Windows.Forms.Label
$overrideAppNameLabel.Text = Get-UiString 'OverrideAppNameLabel'
$overrideAppNameLabel.Location = New-Object System.Drawing.Point(14, 328)
$overrideAppNameLabel.AutoSize = $true
$overrideAppNameLabel.Visible = $false
$cardDeploy.Controls.Add($overrideAppNameLabel)

$script:overrideAppNameBox = New-Object System.Windows.Forms.TextBox
$script:overrideAppNameBox.Width = 460
$script:overrideAppNameBox.PlaceholderText = Get-UiString 'OverrideAppNamePlaceholder'
$overrideAppNameHost = New-RoundedInput -Inner $script:overrideAppNameBox -X 150 -Y 322 -W 460 -H 32
$overrideAppNameHost.Visible = $false
$cardDeploy.Controls.Add($overrideAppNameHost)

$roleScopeTagsLabel = New-Object System.Windows.Forms.Label
$roleScopeTagsLabel.Text = Get-UiString 'RoleScopeTagsLabel'
$roleScopeTagsLabel.Location = New-Object System.Drawing.Point(14, 366)
$roleScopeTagsLabel.AutoSize = $true
$roleScopeTagsLabel.Visible = $false
$cardDeploy.Controls.Add($roleScopeTagsLabel)

$script:roleScopeTagsBox = New-Object System.Windows.Forms.TextBox
$script:roleScopeTagsBox.Width = 460
$script:roleScopeTagsBox.PlaceholderText = Get-UiString 'RoleScopeTagsPlaceholder'
$roleScopeTagsHost = New-RoundedInput -Inner $script:roleScopeTagsBox -X 150 -Y 360 -W 460 -H 32
$roleScopeTagsHost.Visible = $false
$cardDeploy.Controls.Add($roleScopeTagsHost)

# Intune app categories (comma-separated) → Deploy-WtWin32App -Categories.
$categoriesLabel = New-Object System.Windows.Forms.Label
$categoriesLabel.Text = Get-UiString 'CategoriesLabel'
$categoriesLabel.Location = New-Object System.Drawing.Point(14, 404)
$categoriesLabel.AutoSize = $true
$categoriesLabel.Visible = $false
$cardDeploy.Controls.Add($categoriesLabel)

$script:categoriesBox = New-Object System.Windows.Forms.TextBox
$script:categoriesBox.Width = 460
$script:categoriesBox.PlaceholderText = Get-UiString 'CategoriesPlaceholder'
# X=150 lines this up with the Locale and Installer-arguments fields directly above it.
$categoriesHost = New-RoundedInput -Inner $script:categoriesBox -X 150 -Y 398 -W 460 -H 32
$categoriesHost.Visible = $false
$cardDeploy.Controls.Add($categoriesHost)

# Optional assignment lane details. Included is the normal mode. Excluded is intentionally
# limited to a custom group; Intune does not support an "exclude all users/devices" target.
$deployGroupModeLabel = New-Object System.Windows.Forms.Label
$deployGroupModeLabel.Text = Get-UiString 'DeployAssignmentModeLabel'
$deployGroupModeLabel.Location = New-Object System.Drawing.Point(14, 442)
$deployGroupModeLabel.AutoSize = $true
$deployGroupModeLabel.Visible = $false
$cardDeploy.Controls.Add($deployGroupModeLabel)
$script:deployGroupModeCombo = New-Object System.Windows.Forms.ComboBox
$script:deployGroupModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployGroupModeCombo.Location = New-Object System.Drawing.Point(150, 439)
$script:deployGroupModeCombo.Width = 150
[void]$script:deployGroupModeCombo.Items.AddRange(@((Get-UiString 'DeployAssignmentIncluded'), (Get-UiString 'DeployAssignmentExcluded')))
$script:deployGroupModeCombo.SelectedIndex = 0
$script:deployGroupModeCombo.Visible = $false
$cardDeploy.Controls.Add($script:deployGroupModeCombo)

$deployExcludeBaseLabel = New-Object System.Windows.Forms.Label
$deployExcludeBaseLabel.Text = Get-UiString 'DeployExcludeBaseLabel'
$deployExcludeBaseLabel.Location = New-Object System.Drawing.Point(14, 480)
$deployExcludeBaseLabel.AutoSize = $true
$deployExcludeBaseLabel.Visible = $false
$deployExcludeBaseLabel.Enabled = $false
$cardDeploy.Controls.Add($deployExcludeBaseLabel)
$script:deployExcludeBaseCombo = New-Object System.Windows.Forms.ComboBox
$script:deployExcludeBaseCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployExcludeBaseCombo.Location = New-Object System.Drawing.Point(150, 477)
$script:deployExcludeBaseCombo.Width = 150
[void]$script:deployExcludeBaseCombo.Items.AddRange(@((Get-UiString 'DeployExcludeBaseUsers'), (Get-UiString 'DeployExcludeBaseDevices')))
$script:deployExcludeBaseCombo.SelectedIndex = 0
$script:deployExcludeBaseCombo.Visible = $false
$script:deployExcludeBaseCombo.Enabled = $false
$cardDeploy.Controls.Add($script:deployExcludeBaseCombo)
$script:deployGroupModeCombo.Add_SelectedIndexChanged({
  $isExcluded = ($script:deployGroupModeCombo.SelectedIndex -eq 1)
  $deployExcludeBaseLabel.Enabled = $isExcluded
  $script:deployExcludeBaseCombo.Enabled = $isExcluded
})

$deployFilterModeLabel = New-Object System.Windows.Forms.Label
$deployFilterModeLabel.Text = Get-UiString 'DeployFilterModeLabel'
$deployFilterModeLabel.Location = New-Object System.Drawing.Point(320, 442)
$deployFilterModeLabel.AutoSize = $true
$deployFilterModeLabel.Visible = $false
$cardDeploy.Controls.Add($deployFilterModeLabel)
$script:deployFilterModeCombo = New-Object System.Windows.Forms.ComboBox
$script:deployFilterModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployFilterModeCombo.Location = New-Object System.Drawing.Point(470, 439)
$script:deployFilterModeCombo.Width = 140
[void]$script:deployFilterModeCombo.Items.AddRange(@((Get-UiString 'DeployFilterNone'), (Get-UiString 'DeployFilterInclude'), (Get-UiString 'DeployFilterExclude')))
$script:deployFilterModeCombo.SelectedIndex = 0
$script:deployFilterModeCombo.Visible = $false
$cardDeploy.Controls.Add($script:deployFilterModeCombo)

$deployFilterIdLabel = New-Object System.Windows.Forms.Label
$deployFilterIdLabel.Text = Get-UiString 'DeployFilterIdLabel'
$deployFilterIdLabel.Location = New-Object System.Drawing.Point(320, 480)
$deployFilterIdLabel.AutoSize = $true
$deployFilterIdLabel.Visible = $false
$cardDeploy.Controls.Add($deployFilterIdLabel)
$script:deployFilterIdBox = New-Object System.Windows.Forms.TextBox
$script:deployFilterIdBox.Width = 140
$script:deployFilterIdBox.PlaceholderText = Get-UiString 'DeployFilterIdPlaceholder'
$deployFilterIdHost = New-RoundedInput -Inner $script:deployFilterIdBox -X 470 -Y 474 -W 140 -H 32
$deployFilterIdHost.Visible = $false
$deployFilterIdHost.Enabled = $false
$cardDeploy.Controls.Add($deployFilterIdHost)
$script:deployFilterModeCombo.Add_SelectedIndexChanged({
  $deployFilterIdHost.Enabled = ($script:deployFilterModeCombo.SelectedIndex -gt 0)
})

$script:packageScriptCheckbox = New-Object System.Windows.Forms.CheckBox
$script:packageScriptCheckbox.Text = Get-UiString 'PackageScriptCheckbox'
$script:packageScriptCheckbox.Location = New-Object System.Drawing.Point(14, 514)
$script:packageScriptCheckbox.AutoSize = $true
$script:packageScriptCheckbox.Visible = $false
$cardDeploy.Controls.Add($script:packageScriptCheckbox)

# Turn on Intune's built-in auto-update for the app after deploy → Update-WtIntuneApp -EnableAutoUpdate.
$script:autoUpdateCheckbox = New-Object System.Windows.Forms.CheckBox
$script:autoUpdateCheckbox.Text = Get-UiString 'AutoUpdateCheckbox'
$script:autoUpdateCheckbox.Location = New-Object System.Drawing.Point(14, 542)
$script:autoUpdateCheckbox.AutoSize = $true
$script:autoUpdateCheckbox.Visible = $false
$cardDeploy.Controls.Add($script:autoUpdateCheckbox)

# Assignment settings for THIS deployment (same options as the bulk dialog). They are applied
# right after the upload, because the settings hang on the assignment - which only exists once the
# app has been created with a target. Without a target group these controls have nothing to write to.
$deployAppSettingsLabel = New-Object System.Windows.Forms.Label
$deployAppSettingsLabel.Text = Get-UiString 'DeployAppSettingsLabel'
$deployAppSettingsLabel.Location = New-Object System.Drawing.Point(14, 572)
$deployAppSettingsLabel.AutoSize = $true
$deployAppSettingsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$deployAppSettingsLabel.Visible = $false
$cardDeploy.Controls.Add($deployAppSettingsLabel)

$deployNotifyLabel = New-Object System.Windows.Forms.Label
$deployNotifyLabel.Text = Get-UiString 'AppSettingsNotifyLabel'
$deployNotifyLabel.Location = New-Object System.Drawing.Point(14, 604)
$deployNotifyLabel.AutoSize = $true
$deployNotifyLabel.Visible = $false
$cardDeploy.Controls.Add($deployNotifyLabel)

$script:deployNotifyCombo = New-Object System.Windows.Forms.ComboBox
$script:deployNotifyCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployNotifyCombo.Location = New-Object System.Drawing.Point(240, 601)
$script:deployNotifyCombo.Width = 300
$script:deployNotifyCombo.Visible = $false
[void]$script:deployNotifyCombo.Items.AddRange(@(
  (Get-UiString 'AppSettingsNotifyKeep'),
  (Get-UiString 'AppSettingsNotifyAll'),
  (Get-UiString 'AppSettingsNotifyReboot'),
  (Get-UiString 'AppSettingsNotifyHide')))
$script:deployNotifyCombo.SelectedIndex = 0
$cardDeploy.Controls.Add($script:deployNotifyCombo)

$script:deployAvailCheck = New-Object System.Windows.Forms.CheckBox
$script:deployAvailCheck.Text = Get-UiString 'DeployAvailableFrom'
$script:deployAvailCheck.Location = New-Object System.Drawing.Point(14, 636)
$script:deployAvailCheck.AutoSize = $true
$script:deployAvailCheck.Visible = $false
$cardDeploy.Controls.Add($script:deployAvailCheck)

$script:deployAvailPicker = New-Object System.Windows.Forms.DateTimePicker
$script:deployAvailPicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$script:deployAvailPicker.CustomFormat = "dd.MM.yyyy  HH:mm"
$script:deployAvailPicker.ShowUpDown = $true
$script:deployAvailPicker.Location = New-Object System.Drawing.Point(240, 633)
$script:deployAvailPicker.Width = 300
$script:deployAvailPicker.Enabled = $false
$script:deployAvailPicker.Visible = $false
$cardDeploy.Controls.Add($script:deployAvailPicker)
$script:deployAvailCheck.Add_CheckedChanged({ $script:deployAvailPicker.Enabled = $script:deployAvailCheck.Checked })

$script:deployDeadlineCheck = New-Object System.Windows.Forms.CheckBox
$script:deployDeadlineCheck.Text = Get-UiString 'DeployDeadline'
$script:deployDeadlineCheck.Location = New-Object System.Drawing.Point(14, 668)
$script:deployDeadlineCheck.AutoSize = $true
$script:deployDeadlineCheck.Visible = $false
$cardDeploy.Controls.Add($script:deployDeadlineCheck)

$script:deployDeadlinePicker = New-Object System.Windows.Forms.DateTimePicker
$script:deployDeadlinePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$script:deployDeadlinePicker.CustomFormat = "dd.MM.yyyy  HH:mm"
$script:deployDeadlinePicker.ShowUpDown = $true
$script:deployDeadlinePicker.Location = New-Object System.Drawing.Point(240, 665)
$script:deployDeadlinePicker.Width = 300
$script:deployDeadlinePicker.Enabled = $false
$script:deployDeadlinePicker.Visible = $false
$cardDeploy.Controls.Add($script:deployDeadlinePicker)
$script:deployDeadlineCheck.Add_CheckedChanged({ $script:deployDeadlinePicker.Enabled = $script:deployDeadlineCheck.Checked })

$script:deployLocalTimeCheck = New-Object System.Windows.Forms.CheckBox
$script:deployLocalTimeCheck.Text = Get-UiString 'AppSettingsUseLocalTime'
$script:deployLocalTimeCheck.Location = New-Object System.Drawing.Point(14, 700)
$script:deployLocalTimeCheck.AutoSize = $true
$script:deployLocalTimeCheck.Checked = $true
$script:deployLocalTimeCheck.Visible = $false
$cardDeploy.Controls.Add($script:deployLocalTimeCheck)

$script:deployRestartEnableCheck = New-Object System.Windows.Forms.CheckBox
$script:deployRestartEnableCheck.Text = Get-UiString 'DeployRestartEnable'
$script:deployRestartEnableCheck.Location = New-Object System.Drawing.Point(14, 730)
$script:deployRestartEnableCheck.AutoSize = $true
$script:deployRestartEnableCheck.Visible = $false
$cardDeploy.Controls.Add($script:deployRestartEnableCheck)

$deployRestartGraceLabel = New-Object System.Windows.Forms.Label
$deployRestartGraceLabel.Text = Get-UiString 'AppSettingsRestartGrace'
$deployRestartGraceLabel.Location = New-Object System.Drawing.Point(32, 762)
$deployRestartGraceLabel.AutoSize = $true
$deployRestartGraceLabel.Visible = $false
$deployRestartGraceLabel.Enabled = $false
$cardDeploy.Controls.Add($deployRestartGraceLabel)
$script:deployRestartGraceValue = New-Object System.Windows.Forms.NumericUpDown
$script:deployRestartGraceValue.Location = New-Object System.Drawing.Point(240, 759)
$script:deployRestartGraceValue.Width = 110
$script:deployRestartGraceValue.Minimum = 1
$script:deployRestartGraceValue.Maximum = 20160
$script:deployRestartGraceValue.Value = 1440
$script:deployRestartGraceValue.Visible = $false
$script:deployRestartGraceValue.Enabled = $false
$cardDeploy.Controls.Add($script:deployRestartGraceValue)

$deployRestartCountdownLabel = New-Object System.Windows.Forms.Label
$deployRestartCountdownLabel.Text = Get-UiString 'AppSettingsRestartCountdown'
$deployRestartCountdownLabel.Location = New-Object System.Drawing.Point(32, 794)
$deployRestartCountdownLabel.AutoSize = $true
$deployRestartCountdownLabel.Visible = $false
$deployRestartCountdownLabel.Enabled = $false
$cardDeploy.Controls.Add($deployRestartCountdownLabel)
$script:deployRestartCountdownValue = New-Object System.Windows.Forms.NumericUpDown
$script:deployRestartCountdownValue.Location = New-Object System.Drawing.Point(240, 791)
$script:deployRestartCountdownValue.Width = 110
$script:deployRestartCountdownValue.Minimum = 1
$script:deployRestartCountdownValue.Maximum = 20160
$script:deployRestartCountdownValue.Value = 15
$script:deployRestartCountdownValue.Visible = $false
$script:deployRestartCountdownValue.Enabled = $false
$cardDeploy.Controls.Add($script:deployRestartCountdownValue)

$script:deployRestartSnoozeCheck = New-Object System.Windows.Forms.CheckBox
$script:deployRestartSnoozeCheck.Text = Get-UiString 'AppSettingsRestartSnooze'
$script:deployRestartSnoozeCheck.Location = New-Object System.Drawing.Point(380, 762)
$script:deployRestartSnoozeCheck.AutoSize = $true
$script:deployRestartSnoozeCheck.Checked = $true
$script:deployRestartSnoozeCheck.Visible = $false
$script:deployRestartSnoozeCheck.Enabled = $false
$cardDeploy.Controls.Add($script:deployRestartSnoozeCheck)
$deployRestartSnoozeLabel = New-Object System.Windows.Forms.Label
$deployRestartSnoozeLabel.Text = Get-UiString 'AppSettingsRestartSnoozeMinutes'
$deployRestartSnoozeLabel.Location = New-Object System.Drawing.Point(380, 794)
$deployRestartSnoozeLabel.AutoSize = $true
$deployRestartSnoozeLabel.Visible = $false
$deployRestartSnoozeLabel.Enabled = $false
$cardDeploy.Controls.Add($deployRestartSnoozeLabel)
$script:deployRestartSnoozeValue = New-Object System.Windows.Forms.NumericUpDown
$script:deployRestartSnoozeValue.Location = New-Object System.Drawing.Point(570, 791)
$script:deployRestartSnoozeValue.Width = 110
$script:deployRestartSnoozeValue.Minimum = 1
$script:deployRestartSnoozeValue.Maximum = 20160
$script:deployRestartSnoozeValue.Value = 240
$script:deployRestartSnoozeValue.Visible = $false
$script:deployRestartSnoozeValue.Enabled = $false
$cardDeploy.Controls.Add($script:deployRestartSnoozeValue)
$script:deployRestartEnableCheck.Add_CheckedChanged({
  $enabled = [bool]$script:deployRestartEnableCheck.Checked
  $deployRestartGraceLabel.Enabled = $enabled; $script:deployRestartGraceValue.Enabled = $enabled
  $deployRestartCountdownLabel.Enabled = $enabled; $script:deployRestartCountdownValue.Enabled = $enabled
  $script:deployRestartSnoozeCheck.Enabled = $enabled; $deployRestartSnoozeLabel.Enabled = $enabled
  $script:deployRestartSnoozeValue.Enabled = ($enabled -and $script:deployRestartSnoozeCheck.Checked)
})
$script:deployRestartSnoozeCheck.Add_CheckedChanged({
  $script:deployRestartSnoozeValue.Enabled = ($script:deployRestartEnableCheck.Checked -and $script:deployRestartSnoozeCheck.Checked)
})

$deployDeliveryLabel = New-Object System.Windows.Forms.Label
$deployDeliveryLabel.Text = Get-UiString 'AppSettingsDeliveryPriority'
$deployDeliveryLabel.Location = New-Object System.Drawing.Point(14, 832)
$deployDeliveryLabel.AutoSize = $true
$deployDeliveryLabel.Visible = $false
$cardDeploy.Controls.Add($deployDeliveryLabel)
$script:deployDeliveryCombo = New-Object System.Windows.Forms.ComboBox
$script:deployDeliveryCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployDeliveryCombo.Location = New-Object System.Drawing.Point(240, 829)
$script:deployDeliveryCombo.Width = 300
[void]$script:deployDeliveryCombo.Items.AddRange(@((Get-UiString 'AppSettingsDeliveryBackground'), (Get-UiString 'AppSettingsDeliveryForeground')))
$script:deployDeliveryCombo.SelectedIndex = 0
$script:deployDeliveryCombo.Visible = $false
$cardDeploy.Controls.Add($script:deployDeliveryCombo)

# Builds the settings object from the deploy card, or $null when the user changed nothing.
function Get-DeployAssignmentSettings {
  $a = @{}
  switch ($script:deployNotifyCombo.SelectedIndex) {
    1 { $a.Notifications = 'showAll' }
    2 { $a.Notifications = 'showReboot' }
    3 { $a.Notifications = 'hideAll' }
  }
  if ($script:deployAvailCheck.Checked)    { $a.AvailableFrom = $script:deployAvailPicker.Value }
  if ($script:deployDeadlineCheck.Checked) { $a.Deadline      = $script:deployDeadlinePicker.Value }
  $a.UseLocalTime = [bool]$script:deployLocalTimeCheck.Checked
  if ($script:deployRestartEnableCheck.Checked) {
    $grace = [int]$script:deployRestartGraceValue.Value
    $countdown = [int]$script:deployRestartCountdownValue.Value
    $snooze = if ($script:deployRestartSnoozeCheck.Checked) { [int]$script:deployRestartSnoozeValue.Value } else { 0 }
    if ($countdown -gt $grace -or $snooze -gt $grace) { throw (Get-UiString 'AppSettingsRestartInvalid') }
    $a.RestartGraceMinutes = $grace
    $a.RestartCountdownMinutes = $countdown
    $a.RestartSnoozeMinutes = $snooze
  }
  # Background/normal is Intune's default and is represented by omitting the property. This also
  # keeps new-app assignments compatible with national clouds where DO priority is unsupported.
  if ($script:deployDeliveryCombo.SelectedIndex -eq 1) { $a.DeliveryOptimizationPriority = 'foreground' }
  # The existing "Enable Intune auto-update" checkbox already covers auto-update for new apps via
  # Update-WtIntuneApp, so it is not duplicated here.
  $s = New-AssignmentSettingsObject @a
  if ((Get-AssignmentSettingsSummary $s) -eq '(nothing to change)') { return $null }
  return $s
}

function Get-DeployAssignmentTargetChanges {
  $mode = if ($script:deployGroupModeCombo.SelectedIndex -eq 1) { 'exclude' } else { 'include' }
  $filterType = switch ($script:deployFilterModeCombo.SelectedIndex) {
    1 { 'include' }
    2 { 'exclude' }
    default { 'none' }
  }
  $excludeBase = if ($script:deployExcludeBaseCombo.SelectedIndex -eq 1) { 'AllDevices' } else { 'AllUsers' }
  $changes = @{ AssignmentMode = $mode; ExcludeBaseTarget = $excludeBase; FilterType = $filterType }
  if ($filterType -ne 'none') { $changes.FilterId = $script:deployFilterIdBox.Text.Trim() }
  return $changes
}

# The section scrolls if the expanded Advanced area is taller than the visible content height.
$tabCreate.AutoScroll = $true

$script:advExpanded = $false
$advControls = @($archLabel, $archHost, $contextLabel, $contextHost, $localeLabel, $localeHost,
                 $installerTypeLabel, $installerTypeHost, $installerArgsLabel, $installerArgsHost,
                 $overrideAppNameLabel, $overrideAppNameHost, $roleScopeTagsLabel, $roleScopeTagsHost,
                 $categoriesLabel, $categoriesHost, $deployGroupModeLabel, $script:deployGroupModeCombo,
                 $deployExcludeBaseLabel, $script:deployExcludeBaseCombo,
                 $deployFilterModeLabel, $script:deployFilterModeCombo, $deployFilterIdLabel, $deployFilterIdHost,
                 $script:packageScriptCheckbox, $script:autoUpdateCheckbox,
                 $deployAppSettingsLabel, $deployNotifyLabel, $script:deployNotifyCombo, $script:deployAvailCheck, $script:deployAvailPicker,
                 $script:deployDeadlineCheck, $script:deployDeadlinePicker, $script:deployLocalTimeCheck,
                 $script:deployRestartEnableCheck, $deployRestartGraceLabel, $script:deployRestartGraceValue,
                 $deployRestartCountdownLabel, $script:deployRestartCountdownValue, $script:deployRestartSnoozeCheck,
                 $deployRestartSnoozeLabel, $script:deployRestartSnoozeValue, $deployDeliveryLabel, $script:deployDeliveryCombo)
$advToggle.Add_Click({
  $script:advExpanded = -not $script:advExpanded
  foreach ($c in $advControls) { $c.Visible = $script:advExpanded }
  $cardDeploy.Height = if ($script:advExpanded) { 874 } else { 214 }
  # Keep the favorites card just below the (now taller/shorter) deploy card so they never overlap.
  # The Microsoft Store card used to sit between the two; it has its own section now.
  if ($cardFavorites) { $cardFavorites.Top = $cardDeploy.Bottom + 12 }
  $chev = if ($script:advExpanded) { [System.Char]::ConvertFromUtf32(0x25B4) } else { [System.Char]::ConvertFromUtf32(0x25BE) }
  $advToggle.Text = (Get-UiString 'AdvancedOptions') + "  " + $chev
})

# Section: Microsoft Store apps
#
# Its own section rather than a third card inside "WinGet Apps": a Store app is never packaged and
# never uploaded - Intune creates it from a package identifier. Sitting under the packaging section
# it also had to borrow that section's assignment controls, so the deployment hint pointed at a card
# titled "Package and deploy" and users could not tell that setting a target there was what governed
# the Store deployment. The assignment controls below belong to this section alone.
$tabStore = New-Object System.Windows.Forms.Panel
Add-Section -Key 'store' -Panel $tabStore -Label (Get-UiString 'TabStore')
$tabStore.AutoScroll = $true

$storeSectionTitle = New-Object System.Windows.Forms.Label
$storeSectionTitle.Text = Get-UiString 'StoreSectionTitle'
$storeSectionTitle.Location = New-Object System.Drawing.Point(16, 12)
$storeSectionTitle.AutoSize = $true
$storeSectionTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabStore.Controls.Add($storeSectionTitle)
[void](Add-SectionInfoBadge -Parent $tabStore -AfterLabel $storeSectionTitle -TextKey 'InfoStore')

# --- Card A: assignment for the Store app about to be deployed ---
# Only the options a Store app actually honours. Availability date, delivery optimisation and Intune
# auto-update are deliberately absent: the deploy path already reported them as unsupported, so
# offering them here would only invite settings that silently do nothing.
$cardStoreAssign = New-Card -X 16 -Y 48 -W 726 -H 180
$tabStore.Controls.Add($cardStoreAssign)

$storeAssignTitle = New-Object System.Windows.Forms.Label
$storeAssignTitle.Text = Get-UiString 'StoreAssignCardTitle'
$storeAssignTitle.Location = New-Object System.Drawing.Point(14, 10)
$storeAssignTitle.AutoSize = $true
$storeAssignTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardStoreAssign.Controls.Add($storeAssignTitle)

$storeAssignCardHint = New-Object System.Windows.Forms.Label
$storeAssignCardHint.Text = Get-UiString 'StoreAssignCardHint'
$storeAssignCardHint.Location = New-Object System.Drawing.Point(14, 34)
$storeAssignCardHint.Size = New-Object System.Drawing.Size(698, 20)
$cardStoreAssign.Controls.Add($storeAssignCardHint)

$storeAssignTargetLabel = New-Object System.Windows.Forms.Label
$storeAssignTargetLabel.Text = Get-UiString 'AssignLabel'
$storeAssignTargetLabel.Location = New-Object System.Drawing.Point(14, 68)
$storeAssignTargetLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeAssignTargetLabel)

$script:storeAssignTargetCombo = New-Object System.Windows.Forms.ComboBox
$script:storeAssignTargetCombo.Width = 250
$script:storeAssignTargetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeAssignTargetCombo.Items.AddRange(@((Get-UiString 'AssignNotAssigned'), (Get-UiString 'AssignAllUsers'), (Get-UiString 'AssignAllDevices'), (Get-UiString 'AssignCustomGroup')))
$script:storeAssignTargetCombo.SelectedIndex = 0
$script:storeAssignTargetCombo.Location = New-Object System.Drawing.Point(140, 64)
$cardStoreAssign.Controls.Add($script:storeAssignTargetCombo)

$script:storeAssignGroupIdBox = New-Object System.Windows.Forms.TextBox
$script:storeAssignGroupIdBox.Width = 244
$storeAssignGroupIdHost = New-RoundedInput -Inner $script:storeAssignGroupIdBox -X 400 -Y 62 -W 250 -H 32
$storeAssignGroupIdHost.Visible = $false
$cardStoreAssign.Controls.Add($storeAssignGroupIdHost)

$storeAssignFavButton = New-Object System.Windows.Forms.Button
$storeAssignFavButton.Tag = 'btn-secondary'
$storeAssignFavButton.Text = Get-UiString 'FavAddButton'
$storeAssignFavButton.Location = New-Object System.Drawing.Point(656, 62)
$storeAssignFavButton.Size = New-Object System.Drawing.Size(32, 32)
$storeAssignFavButton.Visible = $false
$storeAssignFavButton.Add_Click({ Show-GroupFavoriteDialog -GroupIdBox $script:storeAssignGroupIdBox })
$cardStoreAssign.Controls.Add($storeAssignFavButton)

$script:storeAssignTargetCombo.Add_SelectedIndexChanged({
  $isCustom = ($script:storeAssignTargetCombo.SelectedItem -eq (Get-UiString 'AssignCustomGroup'))
  $storeAssignGroupIdHost.Visible = $isCustom
  $storeAssignFavButton.Visible = $isCustom
})
Register-AssignTargetCombo -TargetCombo $script:storeAssignTargetCombo

$storeAssignIntentLabel = New-Object System.Windows.Forms.Label
$storeAssignIntentLabel.Text = Get-UiString 'AssignIntentLabel'
$storeAssignIntentLabel.Location = New-Object System.Drawing.Point(14, 108)
$storeAssignIntentLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeAssignIntentLabel)

$script:storeAssignIntentCombo = New-Object System.Windows.Forms.ComboBox
$script:storeAssignIntentCombo.Width = 250
$script:storeAssignIntentCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeAssignIntentCombo.Items.AddRange(@((Get-UiString 'IntentAvailable'), (Get-UiString 'IntentRequired'), (Get-UiString 'IntentUninstall')))
$script:storeAssignIntentCombo.SelectedIndex = 0
$script:storeAssignIntentCombo.Location = New-Object System.Drawing.Point(140, 104)
$cardStoreAssign.Controls.Add($script:storeAssignIntentCombo)

$storeAdvToggle = New-Object System.Windows.Forms.Button
$storeAdvToggle.Tag = 'btn-secondary'
$storeAdvToggle.Text = (Get-UiString 'StoreAdvancedOptions') + "  " + [System.Char]::ConvertFromUtf32(0x25BE)
$storeAdvToggle.Location = New-Object System.Drawing.Point(14, 142)
$storeAdvToggle.Size = New-Object System.Drawing.Size(260, 30)
$cardStoreAssign.Controls.Add($storeAdvToggle)

# --- advanced assignment options (hidden until expanded) ---
$storeGroupModeLabel = New-Object System.Windows.Forms.Label
$storeGroupModeLabel.Text = Get-UiString 'DeployAssignmentModeLabel'
$storeGroupModeLabel.Location = New-Object System.Drawing.Point(14, 190)
$storeGroupModeLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeGroupModeLabel)

$script:storeGroupModeCombo = New-Object System.Windows.Forms.ComboBox
$script:storeGroupModeCombo.Width = 250
$script:storeGroupModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeGroupModeCombo.Items.AddRange(@((Get-UiString 'DeployAssignmentIncluded'), (Get-UiString 'DeployAssignmentExcluded')))
$script:storeGroupModeCombo.SelectedIndex = 0
$script:storeGroupModeCombo.Location = New-Object System.Drawing.Point(240, 186)
$cardStoreAssign.Controls.Add($script:storeGroupModeCombo)

$storeExcludeBaseLabel = New-Object System.Windows.Forms.Label
$storeExcludeBaseLabel.Text = Get-UiString 'DeployExcludeBaseLabel'
$storeExcludeBaseLabel.Location = New-Object System.Drawing.Point(14, 226)
$storeExcludeBaseLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeExcludeBaseLabel)

$script:storeExcludeBaseCombo = New-Object System.Windows.Forms.ComboBox
$script:storeExcludeBaseCombo.Width = 250
$script:storeExcludeBaseCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeExcludeBaseCombo.Items.AddRange(@((Get-UiString 'TargetAllUsers'), (Get-UiString 'TargetAllDevices')))
$script:storeExcludeBaseCombo.SelectedIndex = 0
$script:storeExcludeBaseCombo.Location = New-Object System.Drawing.Point(240, 222)
$cardStoreAssign.Controls.Add($script:storeExcludeBaseCombo)

$storeFilterModeLabel = New-Object System.Windows.Forms.Label
$storeFilterModeLabel.Text = Get-UiString 'DeployFilterModeLabel'
$storeFilterModeLabel.Location = New-Object System.Drawing.Point(14, 262)
$storeFilterModeLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeFilterModeLabel)

$script:storeFilterModeCombo = New-Object System.Windows.Forms.ComboBox
$script:storeFilterModeCombo.Width = 250
$script:storeFilterModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeFilterModeCombo.Items.AddRange(@((Get-UiString 'DeployFilterNone'), (Get-UiString 'DeployFilterInclude'), (Get-UiString 'DeployFilterExclude')))
$script:storeFilterModeCombo.SelectedIndex = 0
$script:storeFilterModeCombo.Location = New-Object System.Drawing.Point(240, 258)
$cardStoreAssign.Controls.Add($script:storeFilterModeCombo)

$storeFilterIdLabel = New-Object System.Windows.Forms.Label
$storeFilterIdLabel.Text = Get-UiString 'DeployFilterIdLabel'
$storeFilterIdLabel.Location = New-Object System.Drawing.Point(14, 298)
$storeFilterIdLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeFilterIdLabel)

$script:storeFilterIdBox = New-Object System.Windows.Forms.TextBox
$script:storeFilterIdBox.Width = 244
$storeFilterIdHost = New-RoundedInput -Inner $script:storeFilterIdBox -X 240 -Y 294 -W 250 -H 32
$cardStoreAssign.Controls.Add($storeFilterIdHost)

$storeNotifyLabel = New-Object System.Windows.Forms.Label
$storeNotifyLabel.Text = Get-UiString 'AppSettingsNotifyLabel'
$storeNotifyLabel.Location = New-Object System.Drawing.Point(14, 338)
$storeNotifyLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeNotifyLabel)

$script:storeNotifyCombo = New-Object System.Windows.Forms.ComboBox
$script:storeNotifyCombo.Width = 250
$script:storeNotifyCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeNotifyCombo.Items.AddRange(@((Get-UiString 'AppSettingsNotifyKeep'), (Get-UiString 'AppSettingsNotifyAll'), (Get-UiString 'AppSettingsNotifyReboot'), (Get-UiString 'AppSettingsNotifyHide')))
$script:storeNotifyCombo.SelectedIndex = 0
$script:storeNotifyCombo.Location = New-Object System.Drawing.Point(240, 334)
$cardStoreAssign.Controls.Add($script:storeNotifyCombo)

# "Leave unchanged" does not mean "no notifications": the property is simply not sent, and Intune
# then applies its own default, which is showAll. Naming that here saves guessing what the neutral
# option actually produces on the device.
$storeNotifyDefaultHint = New-Object System.Windows.Forms.Label
$storeNotifyDefaultHint.Text = Get-UiString 'NotifyDefaultHint'
$storeNotifyDefaultHint.Location = New-Object System.Drawing.Point(500, 336)
$storeNotifyDefaultHint.Size = New-Object System.Drawing.Size(212, 30)
$cardStoreAssign.Controls.Add($storeNotifyDefaultHint)

$script:storeDeadlineCheck = New-Object System.Windows.Forms.CheckBox
$script:storeDeadlineCheck.Text = Get-UiString 'DeployDeadline'
$script:storeDeadlineCheck.Location = New-Object System.Drawing.Point(14, 374)
$script:storeDeadlineCheck.AutoSize = $true
$cardStoreAssign.Controls.Add($script:storeDeadlineCheck)

$script:storeDeadlinePicker = New-Object System.Windows.Forms.DateTimePicker
$script:storeDeadlinePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$script:storeDeadlinePicker.CustomFormat = "yyyy-MM-dd HH:mm"
$script:storeDeadlinePicker.Width = 250
$script:storeDeadlinePicker.Location = New-Object System.Drawing.Point(440, 370)
$cardStoreAssign.Controls.Add($script:storeDeadlinePicker)

$script:storeLocalTimeCheck = New-Object System.Windows.Forms.CheckBox
$script:storeLocalTimeCheck.Text = Get-UiString 'AppSettingsUseLocalTime'
$script:storeLocalTimeCheck.Location = New-Object System.Drawing.Point(14, 406)
$script:storeLocalTimeCheck.AutoSize = $true
$cardStoreAssign.Controls.Add($script:storeLocalTimeCheck)

$script:storeRestartEnableCheck = New-Object System.Windows.Forms.CheckBox
$script:storeRestartEnableCheck.Text = Get-UiString 'DeployRestartEnable'
$script:storeRestartEnableCheck.Location = New-Object System.Drawing.Point(14, 438)
$script:storeRestartEnableCheck.AutoSize = $true
$cardStoreAssign.Controls.Add($script:storeRestartEnableCheck)

$storeRestartGraceLabel = New-Object System.Windows.Forms.Label
$storeRestartGraceLabel.Text = Get-UiString 'AppSettingsRestartGrace'
$storeRestartGraceLabel.Location = New-Object System.Drawing.Point(34, 474)
$storeRestartGraceLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeRestartGraceLabel)

$script:storeRestartGraceValue = New-Object System.Windows.Forms.NumericUpDown
$script:storeRestartGraceValue.Minimum = 0
$script:storeRestartGraceValue.Maximum = 10080
$script:storeRestartGraceValue.Value = 1440
$script:storeRestartGraceValue.Width = 90
$script:storeRestartGraceValue.Location = New-Object System.Drawing.Point(440, 470)
$cardStoreAssign.Controls.Add($script:storeRestartGraceValue)

$storeRestartCountdownLabel = New-Object System.Windows.Forms.Label
$storeRestartCountdownLabel.Text = Get-UiString 'AppSettingsRestartCountdown'
$storeRestartCountdownLabel.Location = New-Object System.Drawing.Point(34, 510)
$storeRestartCountdownLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeRestartCountdownLabel)

$script:storeRestartCountdownValue = New-Object System.Windows.Forms.NumericUpDown
$script:storeRestartCountdownValue.Minimum = 0
$script:storeRestartCountdownValue.Maximum = 10080
$script:storeRestartCountdownValue.Value = 15
$script:storeRestartCountdownValue.Width = 90
$script:storeRestartCountdownValue.Location = New-Object System.Drawing.Point(440, 506)
$cardStoreAssign.Controls.Add($script:storeRestartCountdownValue)

$script:storeRestartSnoozeCheck = New-Object System.Windows.Forms.CheckBox
$script:storeRestartSnoozeCheck.Text = Get-UiString 'AppSettingsRestartSnooze'
$script:storeRestartSnoozeCheck.Location = New-Object System.Drawing.Point(34, 542)
$script:storeRestartSnoozeCheck.AutoSize = $true
$cardStoreAssign.Controls.Add($script:storeRestartSnoozeCheck)

$script:storeRestartSnoozeValue = New-Object System.Windows.Forms.NumericUpDown
$script:storeRestartSnoozeValue.Minimum = 0
$script:storeRestartSnoozeValue.Maximum = 10080
$script:storeRestartSnoozeValue.Value = 240
$script:storeRestartSnoozeValue.Width = 90
$script:storeRestartSnoozeValue.Location = New-Object System.Drawing.Point(440, 538)
$cardStoreAssign.Controls.Add($script:storeRestartSnoozeValue)

$storeCategoriesLabel = New-Object System.Windows.Forms.Label
$storeCategoriesLabel.Text = Get-UiString 'CategoriesLabel'
$storeCategoriesLabel.Location = New-Object System.Drawing.Point(14, 582)
$storeCategoriesLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeCategoriesLabel)

# Its own field rather than the WinGet card's: reading that one meant categories typed for a WinGet
# package silently ended up on a Store app deployed afterwards.
$script:storeCategoriesBox = New-Object System.Windows.Forms.TextBox
$script:storeCategoriesBox.Width = 294
$script:storeCategoriesBox.PlaceholderText = Get-UiString 'CategoriesPlaceholder'
$storeCategoriesHost = New-RoundedInput -Inner $script:storeCategoriesBox -X 240 -Y 578 -W 300 -H 32
$cardStoreAssign.Controls.Add($storeCategoriesHost)

$storeUnsupportedNote = New-Object System.Windows.Forms.Label
$storeUnsupportedNote.Text = Get-UiString 'StoreUnsupportedNote'
$storeUnsupportedNote.Location = New-Object System.Drawing.Point(14, 620)
$storeUnsupportedNote.Size = New-Object System.Drawing.Size(698, 32)
$cardStoreAssign.Controls.Add($storeUnsupportedNote)

$script:storeAdvControls = @($storeGroupModeLabel, $script:storeGroupModeCombo,
                             $storeExcludeBaseLabel, $script:storeExcludeBaseCombo,
                             $storeFilterModeLabel, $script:storeFilterModeCombo,
                             $storeFilterIdLabel, $storeFilterIdHost,
                             $storeNotifyLabel, $script:storeNotifyCombo, $storeNotifyDefaultHint,
                             $script:storeDeadlineCheck, $script:storeDeadlinePicker, $script:storeLocalTimeCheck,
                             $script:storeRestartEnableCheck, $storeRestartGraceLabel, $script:storeRestartGraceValue,
                             $storeRestartCountdownLabel, $script:storeRestartCountdownValue,
                             $script:storeRestartSnoozeCheck, $script:storeRestartSnoozeValue,
                             $storeCategoriesLabel, $storeCategoriesHost,
                             $storeUnsupportedNote)
foreach ($c in $script:storeAdvControls) { $c.Visible = $false }

$script:storeAdvExpanded = $false
$storeAdvToggle.Add_Click({
  $script:storeAdvExpanded = -not $script:storeAdvExpanded
  foreach ($c in $script:storeAdvControls) { $c.Visible = $script:storeAdvExpanded }
  $cardStoreAssign.Height = if ($script:storeAdvExpanded) { 664 } else { 180 }
  $chev = if ($script:storeAdvExpanded) { [System.Char]::ConvertFromUtf32(0x25B4) } else { [System.Char]::ConvertFromUtf32(0x25BE) }
  $storeAdvToggle.Text = (Get-UiString 'StoreAdvancedOptions') + "  " + $chev
  # Keep the deployment card directly below the (now taller/shorter) assignment card.
  if ($cardStore) { $cardStore.Top = $cardStoreAssign.Bottom + 12 }
})

# --- Card B: Microsoft Store app (deployed directly, no packaging) ---
# Includes a tenant inventory so duplicate Store package IDs are visible before deployment.
$cardStore = New-Card -X 16 -Y 240 -W 726 -H 310
$tabStore.Controls.Add($cardStore)

$storeTitle = New-Object System.Windows.Forms.Label
$storeTitle.Text = Get-UiString 'StoreCardTitle'
$storeTitle.Location = New-Object System.Drawing.Point(14, 10)
$storeTitle.AutoSize = $true
$storeTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardStore.Controls.Add($storeTitle)

$storeQueryLabel = New-Object System.Windows.Forms.Label
$storeQueryLabel.Text = Get-UiString 'StoreQueryLabel'
$storeQueryLabel.Location = New-Object System.Drawing.Point(14, 44)
$storeQueryLabel.AutoSize = $true
$cardStore.Controls.Add($storeQueryLabel)

$storeQueryBox = New-Object System.Windows.Forms.TextBox
$storeQueryBox.Width = 344
$storeQueryBox.PlaceholderText = Get-UiString 'StoreQueryPlaceholder'
$storeQueryHost = New-RoundedInput -Inner $storeQueryBox -X 158 -Y 38 -W 344 -H 32
$cardStore.Controls.Add($storeQueryHost)

$storeTenantSearchButton = New-Object System.Windows.Forms.Button
$storeTenantSearchButton.Tag = 'btn-secondary'
$storeTenantSearchButton.Text = Get-UiString 'StoreTenantSearchButton'
$storeTenantSearchButton.Location = New-Object System.Drawing.Point(514, 38)
$storeTenantSearchButton.Size = New-Object System.Drawing.Size(198, 32)
$cardStore.Controls.Add($storeTenantSearchButton)

# Deploy sits AFTER the catalog search: searching is the first step, and the search fills this
# card's input field with the exact package id that deploying then relies on.
$storeDeployButton = New-Object System.Windows.Forms.Button
$storeDeployButton.Text = Get-UiString 'StoreDeployButton'
$storeDeployButton.Location = New-Object System.Drawing.Point(226, 78)
$storeDeployButton.Size = New-Object System.Drawing.Size(200, 32)
$cardStore.Controls.Add($storeDeployButton)

# Searches the Store CATALOG, unlike the two tenant-inventory buttons. Deploying needs one exact
# package id, so this fills the input field above from a picker instead of forcing the user to
# already know the precise Store name.
$storeCatalogSearchButton = New-Object System.Windows.Forms.Button
$storeCatalogSearchButton.Tag = 'btn-secondary'
$storeCatalogSearchButton.Text = Get-UiString 'StoreCatalogSearchButton'
$storeCatalogSearchButton.Location = New-Object System.Drawing.Point(14, 78)
$storeCatalogSearchButton.Size = New-Object System.Drawing.Size(200, 32)
$cardStore.Controls.Add($storeCatalogSearchButton)

$storeShowAllButton = New-Object System.Windows.Forms.Button
$storeShowAllButton.Tag = 'btn-secondary'
$storeShowAllButton.Text = Get-UiString 'StoreTenantShowAllButton'
$storeShowAllButton.Location = New-Object System.Drawing.Point(438, 78)
$storeShowAllButton.Size = New-Object System.Drawing.Size(200, 32)
$cardStore.Controls.Add($storeShowAllButton)

# Live preview of what deploying will actually do. The target, intent and advanced settings live in
# the "Package and deploy" card ABOVE this one and were easy to miss entirely - the old static hint
# only said so in prose, so an app was deployed unassigned without the user noticing why.
$storeHintLabel = New-Object System.Windows.Forms.Label
$storeHintLabel.Text = Get-UiString 'StoreHint'
$storeHintLabel.Location = New-Object System.Drawing.Point(14, 116)
$storeHintLabel.Size = New-Object System.Drawing.Size(698, 46)
$cardStore.Controls.Add($storeHintLabel)

# Builds the assignment settings object from THIS section's controls, or $null when nothing was
# changed. Deliberately narrower than Get-DeployAssignmentSettings: no availability date and no
# delivery optimisation, because Microsoft Store apps do not honour either.
function Get-StoreAssignmentSettings {
  $a = @{}
  switch ($script:storeNotifyCombo.SelectedIndex) {
    1 { $a.Notifications = 'showAll' }
    2 { $a.Notifications = 'showReboot' }
    3 { $a.Notifications = 'hideAll' }
  }
  if ($script:storeDeadlineCheck.Checked) { $a.Deadline = $script:storeDeadlinePicker.Value }
  $a.UseLocalTime = [bool]$script:storeLocalTimeCheck.Checked
  if ($script:storeRestartEnableCheck.Checked) {
    $grace = [int]$script:storeRestartGraceValue.Value
    $countdown = [int]$script:storeRestartCountdownValue.Value
    $snooze = if ($script:storeRestartSnoozeCheck.Checked) { [int]$script:storeRestartSnoozeValue.Value } else { 0 }
    if ($countdown -gt $grace -or $snooze -gt $grace) { throw (Get-UiString 'AppSettingsRestartInvalid') }
    $a.RestartGraceMinutes = $grace
    $a.RestartCountdownMinutes = $countdown
    $a.RestartSnoozeMinutes = $snooze
  }
  $s = New-AssignmentSettingsObject @a
  if ((Get-AssignmentSettingsSummary $s) -eq '(nothing to change)') { return $null }
  return $s
}

function Get-StoreAssignmentTargetChanges {
  $mode = if ($script:storeGroupModeCombo.SelectedIndex -eq 1) { 'exclude' } else { 'include' }
  $filterType = switch ($script:storeFilterModeCombo.SelectedIndex) {
    1 { 'include' }
    2 { 'exclude' }
    default { 'none' }
  }
  $excludeBase = if ($script:storeExcludeBaseCombo.SelectedIndex -eq 1) { 'AllDevices' } else { 'AllUsers' }
  $changes = @{ AssignmentMode = $mode; ExcludeBaseTarget = $excludeBase; FilterType = $filterType }
  if ($filterType -ne 'none') { $changes.FilterId = $script:storeFilterIdBox.Text.Trim() }
  return $changes
}

function Update-StoreAssignmentPreview {
  try {
    if (-not $storeHintLabel) { return }
    $target = Get-SelectedAssignmentTarget -TargetCombo $script:storeAssignTargetCombo -GroupIdBox $script:storeAssignGroupIdBox
    if (-not $target) {
      $storeHintLabel.Text = Get-UiString 'StoreAssignPreviewNone'
      $storeHintLabel.ForeColor = [System.Drawing.Color]::DarkOrange
      return
    }
    $intentIndex = if ($script:storeAssignIntentCombo) { [int]$script:storeAssignIntentCombo.SelectedIndex } else { 0 }
    $intentText = switch ($intentIndex) {
      1 { Get-UiString 'IntentRequired' }
      2 { Get-UiString 'IntentUninstall' }
      default { Get-UiString 'IntentAvailable' }
    }
    $scopeText = switch ([int]$script:storeAssignTargetCombo.SelectedIndex) {
      1 { Get-UiString 'TargetAllUsers' }
      2 { Get-UiString 'TargetAllDevices' }
      3 { (Get-UiString 'TargetGroup') -f [string]$target }
      default { [string]$target }
    }
    $storeHintLabel.Text = (Get-UiString 'StoreAssignPreview') -f $scopeText, $intentText
    $storeHintLabel.ForeColor = $script:currentTheme.ForeColor
  } catch { }   # class 3: a preview must never block deployment
}

# Kept in sync with the controls it mirrors, so the Store card always states what will happen.
$script:storeAssignTargetCombo.Add_SelectedIndexChanged({ Update-StoreAssignmentPreview })
$script:storeAssignGroupIdBox.Add_TextChanged({ Update-StoreAssignmentPreview })
if ($script:storeAssignIntentCombo) { $script:storeAssignIntentCombo.Add_SelectedIndexChanged({ Update-StoreAssignmentPreview }) }
Update-StoreAssignmentPreview

$storeTenantListView = New-Object System.Windows.Forms.ListView
$storeTenantListView.Location = New-Object System.Drawing.Point(14, 170)
$storeTenantListView.Size = New-Object System.Drawing.Size(698, 126)
$storeTenantListView.View = [System.Windows.Forms.View]::Details
$storeTenantListView.FullRowSelect = $true
$storeTenantListView.MultiSelect = $false
$storeTenantListView.HideSelection = $false
$storeTenantListView.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
[void]$storeTenantListView.Columns.Add((Get-UiString 'StoreColName'), 230)
[void]$storeTenantListView.Columns.Add((Get-UiString 'StoreColPackageId'), 210)
[void]$storeTenantListView.Columns.Add((Get-UiString 'StoreColAssigned'), 95)
[void]$storeTenantListView.Columns.Add((Get-UiString 'StoreColState'), 135)
$cardStore.Controls.Add($storeTenantListView)
$script:tenantStoreApps = @()

function Update-TenantStoreListView {
  param([string]$Query = '')
  $filtered = @($script:tenantStoreApps)
  if (-not [string]::IsNullOrWhiteSpace($Query)) {
    $q = $Query.Trim()
    $filtered = @($filtered | Where-Object {
      ([string]$_.DisplayName).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
      ([string]$_.PackageIdentifier).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
      ([string]$_.Publisher).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    })
  }
  $storeTenantListView.BeginUpdate()
  try {
    $storeTenantListView.Items.Clear()
    foreach ($app in $filtered) {
      $row = New-Object System.Windows.Forms.ListViewItem([string]$app.DisplayName)
      $row.Tag = $app
      [void]$row.SubItems.Add([string]$app.PackageIdentifier)
      [void]$row.SubItems.Add($(if ($app.IsAssigned) { Get-UiString 'StoreAssignedYes' } else { Get-UiString 'StoreAssignedNo' }))
      [void]$row.SubItems.Add([string]$app.PublishingState)
      [void]$storeTenantListView.Items.Add($row)
    }
  } finally { $storeTenantListView.EndUpdate() }
  if ($filtered.Count -eq 0) { Update-Status (Get-UiString 'StoreTenantNoMatchesStatus') }
  else { Update-Status ((Get-UiString 'StoreTenantLoadedStatus') -f $filtered.Count) }
}

function Refresh-TenantStoreApps {
  param([string]$Query = '')
  Update-Status (Get-UiString 'StoreTenantLoadingStatus')
  [System.Windows.Forms.Application]::DoEvents()
  $script:tenantStoreApps = @(Get-TenantStoreApps)
  Update-TenantStoreListView -Query $Query
}

# Highlights one entry after a deployment, so the app that was just created is the one in view.
# Matched on the Graph id when it is known and on the package identifier otherwise - the id is the
# authoritative handle, but it stays $null when the tenant could not be re-read.
function Select-StoreListEntry {
  param([string]$PackageIdentifier, [string]$GraphId)
  if (-not $storeTenantListView) { return }
  foreach ($row in $storeTenantListView.Items) {
    $app = $row.Tag
    if (-not $app) { continue }
    $isMatch = if ($GraphId) { ([string]$app.Id) -eq $GraphId }
               else { ([string]$app.PackageIdentifier) -eq $PackageIdentifier }
    if ($isMatch) {
      $row.Selected = $true
      $row.EnsureVisible()
      try { $storeTenantListView.Focus() } catch { }   # class 3: focus is cosmetic here
      return
    }
  }
}

# Catalog search: unlike the tenant buttons this needs no Graph connection, because it only asks
# winget. The picked package id is written back into the query box, so the existing deploy path
# then resolves unambiguously instead of failing on a name like "Spotify".
$storeCatalogSearchButton.Add_Click({
  if (Test-UiBusy) { return }
  $query = $storeQueryBox.Text.Trim()
  if (-not $query) { Update-Status (Get-UiString 'StoreQueryEmptyStatus'); return }
  try {
    $storeCatalogSearchButton.Enabled = $false
    Update-Status ((Get-UiString 'StoreSearchingStatus') -f $query)
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

    $results = @(Search-MsStorePackage -Query $query)
    if ($results.Count -eq 0) {
      Update-Status ((Get-UiString 'StoreSearchNoResultsStatus') -f $query)
      Write-Log ("Microsoft Store search returned no result for '{0}'." -f $query)
      return
    }

    Write-Log ("Microsoft Store search for '{0}' returned {1} distinct package(s)." -f $query, $results.Count)
    $picked = Show-StorePickerDialog -Results $results
    if (-not $picked) { Update-Status ''; return }

    $storeQueryBox.Text = [string]$picked.PackageIdentifier
    Update-Status ((Get-UiString 'StoreSearchPickedStatus') -f $picked.Name, $picked.PackageIdentifier)
    Write-Log ("Selected Microsoft Store package '{0}' ({1}) for deployment." -f $picked.Name, $picked.PackageIdentifier)
  } catch {
    Write-Log ("Microsoft Store search failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'StoreSearchFailedStatus') -f $_.Exception.Message)
  } finally {
    $storeCatalogSearchButton.Enabled = $true
  }
})

$storeTenantSearchButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try {
    $storeTenantSearchButton.Enabled = $false; $storeShowAllButton.Enabled = $false
    Refresh-TenantStoreApps -Query $storeQueryBox.Text.Trim()
  } catch {
    Write-Log ("Store tenant search failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'StoreTenantLoadFailedStatus') -f $_.Exception.Message)
  } finally {
    $storeTenantSearchButton.Enabled = $true; $storeShowAllButton.Enabled = $true
  }
})

$storeShowAllButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try {
    $storeTenantSearchButton.Enabled = $false; $storeShowAllButton.Enabled = $false
    Refresh-TenantStoreApps
  } catch {
    Write-Log ("Store tenant inventory failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'StoreTenantLoadFailedStatus') -f $_.Exception.Message)
  } finally {
    $storeTenantSearchButton.Enabled = $true; $storeShowAllButton.Enabled = $true
  }
})

$storeDeployButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  $q = $storeQueryBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($q)) { Update-Status (Get-UiString 'StoreQueryEmptyStatus'); return }
  try {
    $storeDeployButton.Enabled = $false
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $script:progressBar.MarqueeAnimationSpeed = 30
    $script:progressBar.Visible = $true
    Update-Status ((Get-UiString 'StoreDeployingStatus') -f $q)
    [System.Windows.Forms.Application]::DoEvents()

    # Resolve the first Store search result to an exact package identity before changing Intune.
    # Deployment then uses PackageId, so the duplicate guard and the mutation refer to the same app.
    $storePackage = Resolve-MsStorePackage -Query $q
    $storePackageId = [string]$storePackage.PackageIdentifier
    Write-Log ("Store query '{0}' resolved to '{1}' ({2})." -f $q, $storePackage.Name, $storePackageId)
    $script:tenantStoreApps = @(Get-TenantStoreApps)
    $duplicates = @(Find-TenantStoreAppMatch -Apps $script:tenantStoreApps -Query $storePackageId)
    Update-TenantStoreListView -Query $q
    if ($duplicates.Count -gt 0) {
      $lines = @($duplicates | Select-Object -First 8 | ForEach-Object {
        $assigned = if ($_.IsAssigned) { Get-UiString 'StoreAssignedYes' } else { Get-UiString 'StoreAssignedNo' }
        "{0} | {1} | Intune {2} | {3} | {4}" -f $_.DisplayName, $_.PackageIdentifier, $_.Id, $assigned, $_.PublishingState
      })
      if ($duplicates.Count -gt 8) { $lines += '...' }
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'StoreAlreadyExistsDialog') -f ($lines -join "`r`n")),
        (Get-UiString 'StoreAlreadyExistsTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
      Write-Log ("Store deploy blocked for '{0}': {1} matching tenant app(s) already exist." -f $q, $duplicates.Count)
      return
    }

    # This section's own assignment controls. They used to be borrowed from the "Package and deploy"
    # card in the WinGet section, which is why the hint below pointed at a card that was not even on
    # screen once the Store moved into its own section.
    $assignTarget = Get-SelectedAssignmentTarget -TargetCombo $script:storeAssignTargetCombo -GroupIdBox $script:storeAssignGroupIdBox
    $targetChanges = Get-StoreAssignmentTargetChanges
    $plannedDeploySettings = Get-StoreAssignmentSettings
    $intentIdx = if ($script:storeAssignIntentCombo) { [int]$script:storeAssignIntentCombo.SelectedIndex } else { 0 }
    $assignmentIntent = switch ($intentIdx) { 1 { 'required' }; 2 { 'uninstall' }; default { 'available' } }
    if (-not $assignTarget -and ($plannedDeploySettings -or $intentIdx -ne 0 -or $targetChanges.AssignmentMode -eq 'exclude' -or $targetChanges.FilterType -ne 'none')) {
      throw (Get-UiString 'DeployAssignmentTargetRequired')
    }
    if ($script:storeAssignTargetCombo.SelectedIndex -eq 3 -and -not (Test-GuidString ([string]$assignTarget))) {
      throw (Get-UiString 'DeployGroupIdRequired')
    }
    if ($assignTarget -and $targetChanges.AssignmentMode -eq 'exclude' -and -not (Test-IsGroupSelection -TargetCombo $script:storeAssignTargetCombo)) {
      throw (Get-UiString 'DeployExcludedRequiresGroup')
    }
    if ($targetChanges.AssignmentMode -eq 'exclude' -and $targetChanges.FilterType -ne 'none') {
      throw (Get-UiString 'DeployExcludeFilterConflict')
    }
    if ($targetChanges.FilterType -ne 'none' -and -not (Test-GuidString ([string]$targetChanges.FilterId))) {
      throw (Get-UiString 'DeployFilterIdRequired')
    }
    # Upload unassigned. The complete assignment is created only after the authoritative Graph ID
    # has been resolved from packageIdentifier.
    $splat = @{ PackageId = $storePackageId; ErrorAction = 'Stop' }
    if ($script:storeCategoriesBox -and -not [string]::IsNullOrWhiteSpace($script:storeCategoriesBox.Text)) {
      $cats = @($script:storeCategoriesBox.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      if ($cats.Count -gt 0) { $splat.Categories = $cats }
    }

    # Creating the app over Graph directly is the primary path. Deploy-WtMsStoreApp drives the
    # Graph .NET SDK, which in this GUI fails every single time with a retried ServiceUnavailable -
    # reproduced across two days, two apps and module versions 1.3.2 and 1.4.1 - and burns roughly
    # 22 seconds on retries before giving up. Our own Invoke-RestMethod reaches the same tenant from
    # the same thread in about a second. The module stays as a fallback in case a future version
    # sets properties this payload does not.
    $storeResult = $null
    try {
      $storeResult = New-TenantStoreAppViaGraph -PackageIdentifier $storePackageId -DisplayName ([string]$storePackage.Name) -Categories $splat.Categories
    } catch {
      $graphError = $_.Exception.Message
      Write-Log ("Direct Graph creation of the Store app failed ({0}); falling back to Deploy-WtMsStoreApp." -f $graphError)
      Update-Status (Get-UiString 'StoreFallbackStatus')
      [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
      $storeResult = Deploy-WtMsStoreApp @splat
    }
    $returnedStoreId = if ($storeResult -and $storeResult.Id) { [string]$storeResult.Id } else { $null }
    if (-not $returnedStoreId -and $storeResult -and $storeResult.id) { $returnedStoreId = [string]$storeResult.id }
    $resolvedStoreApp = Resolve-DeployedStoreTarget -PackageIdentifier $storePackageId -ReturnedId $returnedStoreId
    $storeGraphId = if ($resolvedStoreApp) { [string]$resolvedStoreApp.Id } else { $null }
    $storeProblems = [System.Collections.Generic.List[string]]::new()
    if ($assignTarget -and $storeGraphId) {
      $settings = if ($plannedDeploySettings) { $plannedDeploySettings } else { @{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings' } }
      $assignmentResult = New-AppAssignmentConfiguration -AppId $storeGraphId -TargetValue $assignTarget -Intent $assignmentIntent `
        -AssignmentMode ([string]$targetChanges.AssignmentMode) -ExcludeBaseTarget ([string]$targetChanges.ExcludeBaseTarget) -FilterType ([string]$targetChanges.FilterType) `
        -FilterId ([string]$targetChanges.FilterId) -Settings $settings -AppKind winget -AppName $storePackageId
      if ($assignmentResult.ErrorMessage) { $storeProblems.Add([string]$assignmentResult.ErrorMessage) }
    } elseif ($assignTarget) {
      $storeProblems.Add('The authoritative Intune Store app ID could not be resolved; no assignment was created.')
    }
    # The settings Store apps cannot honour are no longer offered in this section, so there is
    # nothing left to warn about here - the note in the assignment card states it up front instead.
    Write-Log ("Store deploy: '{0}' ({1}) -> {2}" -f $q, $storePackageId, $(if ($storeGraphId) { $storeGraphId } else { 'unresolved' }))
    # Keep the freshly deployed app in view. The query box used to be cleared and the inventory
    # reloaded unfiltered, so the list jumped to every Store app in the tenant and the one just
    # created was lost among them - in a large tenant, off screen entirely.
    $storeQueryBox.Text = $storePackageId
    try {
      Refresh-TenantStoreApps -Query $storePackageId
      Select-StoreListEntry -PackageIdentifier $storePackageId -GraphId $storeGraphId
    } catch { Write-Log ("Store inventory refresh after deploy failed: {0}" -f $_.Exception.Message) }
    if ($storeProblems.Count -gt 0) {
      Update-Status ((Get-UiString 'StorePartialStatus') -f ($storeProblems -join '; '))
    } else {
      Update-Status ((Get-UiString 'StoreDeployedSelectedStatus') -f $storePackage.Name)
    }
  } catch {
    $m = $_.Exception.Message
    # Intune answering "ServiceUnavailable" to the create call has nothing to do with the user's
    # input - the package was already resolved successfully above. The raw message repeats the same
    # retry text four times and tells the user nothing actionable, so it is replaced by a dialog
    # that names the cause and offers the portal as a way through.
    if ($m -match 'ServiceUnavailable' -or $m -match 'Too many retries') {
      Write-Log "Store deploy failed for '$q' with a Microsoft-side ServiceUnavailable after the module's retries: $m"
      Update-Status ((Get-UiString 'StoreDeployFailedStatus') -f 'ServiceUnavailable')
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'StoreServiceUnavailable') -f $q),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    } else {
      Update-Status ((Get-UiString 'StoreDeployFailedStatus') -f $m)
      Write-Log "Store deploy failed for '$q': $m"
    }
  } finally {
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $script:progressBar.Visible = $false
    $script:progressBar.Value = 0
    $storeDeployButton.Enabled = $true
  }
})

# --- Card 4: Persisted local package favorites ---
# Y follows the deploy card directly now that the Microsoft Store card no longer sits between them.
$cardFavorites = New-Card -X 16 -Y 404 -W 726 -H 230
$tabCreate.Controls.Add($cardFavorites)

$favoriteTitle = New-Object System.Windows.Forms.Label
$favoriteTitle.Text = Get-UiString 'FavoriteCardTitle'
$favoriteTitle.Location = New-Object System.Drawing.Point(14, 10)
$favoriteTitle.AutoSize = $true
$favoriteTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardFavorites.Controls.Add($favoriteTitle)
[void](Add-SectionInfoBadge -Parent $cardFavorites -AfterLabel $favoriteTitle -TextKey 'InfoCardFavorites')

$favoriteListView = New-Object System.Windows.Forms.ListView
$favoriteListView.Location = New-Object System.Drawing.Point(14, 36)
$favoriteListView.Size = New-Object System.Drawing.Size(698, 108)
$favoriteListView.View = [System.Windows.Forms.View]::Details
$favoriteListView.FullRowSelect = $true
$favoriteListView.MultiSelect = $true
$favoriteListView.HideSelection = $false
[void]$favoriteListView.Columns.Add((Get-UiString 'ColFavoritePackage'), 280)
[void]$favoriteListView.Columns.Add((Get-UiString 'ColFavoriteLocal'), 105)
[void]$favoriteListView.Columns.Add((Get-UiString 'ColFavoriteOnline'), 105)
[void]$favoriteListView.Columns.Add((Get-UiString 'ColFavoriteStatus'), 202)
$cardFavorites.Controls.Add($favoriteListView)

$favoriteRefreshButton = New-Object System.Windows.Forms.Button
$favoriteRefreshButton.Text = Get-UiString 'FavoriteRefreshButton'
$favoriteRefreshButton.Location = New-Object System.Drawing.Point(14, 154)
$favoriteRefreshButton.Size = New-Object System.Drawing.Size(230, 32)
$cardFavorites.Controls.Add($favoriteRefreshButton)

$favoriteRemoveButton = New-Object System.Windows.Forms.Button
$favoriteRemoveButton.Tag = 'btn-secondary'
$favoriteRemoveButton.Text = Get-UiString 'FavoriteRemoveButton'
$favoriteRemoveButton.Location = New-Object System.Drawing.Point(254, 154)
$favoriteRemoveButton.Size = New-Object System.Drawing.Size(180, 32)
$cardFavorites.Controls.Add($favoriteRemoveButton)

$favoriteAllLocalButton = New-Object System.Windows.Forms.Button
$favoriteAllLocalButton.Tag = 'btn-secondary'
$favoriteAllLocalButton.Text = Get-UiString 'FavoriteAllLocalButton'
$favoriteAllLocalButton.Location = New-Object System.Drawing.Point(444, 154)
$favoriteAllLocalButton.Size = New-Object System.Drawing.Size(268, 32)
$cardFavorites.Controls.Add($favoriteAllLocalButton)

$favoriteAutoCheckbox = New-Object System.Windows.Forms.CheckBox
$favoriteAutoCheckbox.Text = Get-UiString 'FavoriteAutoCheckbox'
$favoriteAutoCheckbox.Location = New-Object System.Drawing.Point(14, 198)
$favoriteAutoCheckbox.AutoSize = $true
$favoriteAutoCheckbox.Checked = [bool]$script:settings.AutoUpdateFavoritesOnStartup
$cardFavorites.Controls.Add($favoriteAutoCheckbox)

function Get-FavoriteListRow {
  param([Parameter(Mandatory)][string]$PackageId)
  foreach ($row in @($favoriteListView.Items)) {
    if ([string]::Equals([string]$row.Tag, $PackageId, [System.StringComparison]::OrdinalIgnoreCase)) { return $row }
  }
  return $null
}

function Update-FavoritePackageList {
  $favoriteListView.BeginUpdate()
  try {
    $favoriteListView.Items.Clear()
    $root = if ($pathBox -and $pathBox.Text.Trim()) { $pathBox.Text.Trim() } else { [string]$script:settings.DefaultPackagePath }
    foreach ($packageId in @($script:settings.WingetFavorites | Sort-Object)) {
      if ([string]::IsNullOrWhiteSpace([string]$packageId)) { continue }
      $local = Get-LocalFavoritePackageVersion -PackageId $packageId -RootPackageFolder $root
      $row = New-Object System.Windows.Forms.ListViewItem([string]$packageId)
      $row.Tag = [string]$packageId
      [void]$row.SubItems.Add($(if ($local) { $local } else { Get-UiString 'FavoriteLocalMissing' }))
      [void]$row.SubItems.Add('-')
      [void]$row.SubItems.Add('')
      [void]$favoriteListView.Items.Add($row)
    }
  } finally {
    $favoriteListView.EndUpdate()
  }
}

function Invoke-LocalPackageSetUpdate {
  param(
    [Parameter(Mandatory)][string[]]$PackageIds,
    [switch]$Automatic,
    [ValidateSet('Favorites','AllLocal')][string]$Mode = 'Favorites'
  )

  $packages = @($PackageIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
  if ($packages.Count -eq 0) { return }

  $root = try { [System.IO.Path]::GetFullPath($pathBox.Text.Trim()) } catch { $null }
  if (-not $root -or -not (Test-PackageFolderUsable -Folder $root)) { return }
  if ($Mode -eq 'Favorites') { Update-FavoritePackageList }

  $downloaded = 0; $current = 0; $failed = 0; $index = 0
  $favoriteRefreshButton.Enabled = $false
  $favoriteAddButton.Enabled = $false
  $favoriteRemoveButton.Enabled = $false
  $favoriteAllLocalButton.Enabled = $false
  $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
  $script:progressBar.Minimum = 0
  $script:progressBar.Maximum = [Math]::Max(1, $packages.Count)
  $script:progressBar.Value = 0
  $script:progressBar.Visible = $true
  try {
    foreach ($packageId in $packages) {
      $index++
      $checkingKey = if ($Mode -eq 'AllLocal') { 'LocalPackageCheckingStatus' } else { 'FavoriteCheckingStatus' }
      Update-Status ((Get-UiString $checkingKey) -f $index, $packages.Count, $packageId)
      [System.Windows.Forms.Application]::DoEvents()
      $row = Get-FavoriteListRow -PackageId $packageId
      $local = Get-LocalFavoritePackageVersion -PackageId $packageId -RootPackageFolder $root
      if ($row) { $row.SubItems[1].Text = if ($local) { $local } else { Get-UiString 'FavoriteLocalMissing' } }

      $latestInfo = Get-FreshLatestPackageVersion -PackageId $packageId
      $latest = [string]$latestInfo.Latest
      if ([string]::IsNullOrWhiteSpace($latest)) {
        $failed++
        if ($row) { $row.SubItems[2].Text = '-'; $row.SubItems[3].Text = Get-UiString 'FavoriteLookupFailed' }
        Write-Log "Favorite update: no current online version for $packageId."
        $script:progressBar.Value = $index
        continue
      }
      if ($row) { $row.SubItems[2].Text = $latest }

      if ($local -and -not (Test-IsNewerVersion -Latest $latest -Current $local)) {
        $current++
        if ($row) { $row.SubItems[3].Text = Get-UiString 'FavoriteUpToDate' }
        $script:progressBar.Value = $index
        continue
      }

      if ($row) { $row.SubItems[3].Text = (Get-UiString 'FavoriteDownloading') -f $latest }
      [System.Windows.Forms.Application]::DoEvents()
      $build = New-WingetPackageWithFallback -PackageId $packageId -PackageFolder $root `
        -DesiredVersion $latest -LatestVersion $latest -InstalledVersion $local `
        -AllowUserRetry:(-not $Automatic) -ErrorAction SilentlyContinue
      if ($build -and $build.Succeeded) {
        $effective = if ($build.EffectiveVersion) { [string]$build.EffectiveVersion } else { $latest }
        $downloaded++
        if ($row) {
          $row.SubItems[1].Text = $effective
          $row.SubItems[3].Text = (Get-UiString 'FavoriteDownloaded') -f $effective
        }
        Write-Log "Favorite update: built/downloaded $packageId version $effective into $root."
      } else {
        $failed++
        if ($row) { $row.SubItems[3].Text = Get-UiString 'FavoriteDownloadFailed' }
        $detail = if ($build -and $build.ErrorMessage) { $build.ErrorMessage } else { 'unknown package build error' }
        Write-Log "Favorite update failed for ${packageId}: $detail"
      }
      $script:progressBar.Value = $index
    }
    $doneKey = if ($Mode -eq 'AllLocal') { 'LocalPackageBatchDoneStatus' } else { 'FavoriteBatchDoneStatus' }
    Update-Status ((Get-UiString $doneKey) -f $downloaded, $current, $failed)
  } finally {
    $script:progressBar.Visible = $false
    $script:progressBar.Value = 0
    $favoriteRefreshButton.Enabled = $true
    $favoriteAddButton.Enabled = $true
    $favoriteRemoveButton.Enabled = $true
    $favoriteAllLocalButton.Enabled = $true
  }
}

function Invoke-FavoritePackagesUpdate {
  param([switch]$Automatic)
  if (Test-UiBusy) { return }
  $favorites = @($script:settings.WingetFavorites | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  if ($favorites.Count -eq 0) { Update-Status (Get-UiString 'FavoriteNoneStatus'); return }
  Invoke-LocalPackageSetUpdate -PackageIds $favorites -Automatic:$Automatic -Mode Favorites
}

function Invoke-AllLocalPackagesUpdate {
  if (Test-UiBusy) { return }
  $root = try { [System.IO.Path]::GetFullPath($pathBox.Text.Trim()) } catch { $null }
  if (-not $root -or -not (Test-PackageFolderUsable -Folder $root)) { return }
  $localPackages = @(Get-LocalPackageIds -RootPackageFolder $root)
  if ($localPackages.Count -eq 0) {
    Update-Status ((Get-UiString 'LocalPackageNoneStatus') -f $root)
    return
  }
  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'LocalPackageConfirmDialog') -f $localPackages.Count, $root),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  Write-Log ("Local package bulk update: checking {0} package folder(s) below {1}." -f $localPackages.Count, $root)
  Invoke-LocalPackageSetUpdate -PackageIds $localPackages -Mode AllLocal
}

$favoriteAddButton.Add_Click({
  if (Test-UiBusy) { return }
  if (-not $dropdown.SelectedItem) { Update-Status (Get-UiString 'SelectPackageFirstStatus'); return }
  $package = $script:packageMap[[string]$dropdown.SelectedItem]
  $packageId = if ($package) { [string]$package.PackageID } else { '' }
  if ([string]::IsNullOrWhiteSpace($packageId)) { Update-Status (Get-UiString 'InvalidSelectionStatus'); return }
  if (@($script:settings.WingetFavorites) -contains $packageId) {
    Update-Status ((Get-UiString 'FavoriteAlreadySavedStatus') -f $packageId)
    return
  }
  $script:settings.WingetFavorites = @($script:settings.WingetFavorites) + $packageId
  Save-Settings
  Update-FavoritePackageList
  Update-Status ((Get-UiString 'FavoriteAddedStatus') -f $packageId)
})

$favoriteRemoveButton.Add_Click({
  if (Test-UiBusy) { return }
  if ($favoriteListView.SelectedItems.Count -eq 0) { Update-Status (Get-UiString 'FavoriteNoSelectionStatus'); return }
  $removeIds = @($favoriteListView.SelectedItems | ForEach-Object { [string]$_.Tag })
  $script:settings.WingetFavorites = @($script:settings.WingetFavorites | Where-Object { $removeIds -notcontains [string]$_ })
  Save-Settings
  Update-FavoritePackageList
  Update-Status ((Get-UiString 'FavoriteRemovedStatus') -f $removeIds.Count)
})

$favoriteRefreshButton.Add_Click({ Invoke-FavoritePackagesUpdate })
$favoriteAllLocalButton.Add_Click({ Invoke-AllLocalPackagesUpdate })
$favoriteAutoCheckbox.Add_CheckedChanged({
  if (Test-UiBusy) { return }
  $script:settings.AutoUpdateFavoritesOnStartup = [bool]$favoriteAutoCheckbox.Checked
  Save-Settings
  Update-Status (Get-UiString 'FavoriteAutoSavedStatus')
})
$pathBox.Add_TextChanged({ if ($favoriteListView) { Update-FavoritePackageList } })
Update-FavoritePackageList

# Section: Updates
$tabUpdate = New-Object System.Windows.Forms.Panel
Add-Section -Key 'updates' -Panel $tabUpdate -Label (Get-UiString 'TabUpdates')

# Section title
$updateHeaderLabel = New-Object System.Windows.Forms.Label
$updateHeaderLabel.Text = Get-UiString 'UpdateHeaderLabel'
$updateHeaderLabel.Location = New-Object System.Drawing.Point(16,12)
$updateHeaderLabel.AutoSize = $true
$updateHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabUpdate.Controls.Add($updateHeaderLabel)
[void](Add-SectionInfoBadge -Parent $tabUpdate -AfterLabel $updateHeaderLabel -TextKey 'InfoUpdates')

# --- Card 1: Available updates ---
$cardUpdates = New-Card -X 16 -Y 48 -W 726 -H 258
$tabUpdate.Controls.Add($cardUpdates)

$updatesStepLabel = New-Object System.Windows.Forms.Label
$updatesStepLabel.Text = Get-UiString 'UpdatesCardAvailable'
$updatesStepLabel.Location = New-Object System.Drawing.Point(14,10)
$updatesStepLabel.AutoSize = $true
$updatesStepLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardUpdates.Controls.Add($updatesStepLabel)
[void](Add-SectionInfoBadge -Parent $cardUpdates -AfterLabel $updatesStepLabel -TextKey 'InfoCardAvailableUpdates')

$updateSearchButton = New-Object System.Windows.Forms.Button
$updateSearchButton.Text = Get-UiString 'UpdateSearchButton'
$updateSearchButton.Location = New-Object System.Drawing.Point(14,38)
$updateSearchButton.Width = 180
$updateSearchButton.Enabled = $false
$cardUpdates.Controls.Add($updateSearchButton)

$updateFilterLabel = New-Object System.Windows.Forms.Label
$updateFilterLabel.Text = Get-UiString 'UpdateFilterLabel'
$updateFilterLabel.Location = New-Object System.Drawing.Point(206,42)
$updateFilterLabel.AutoSize = $true
$cardUpdates.Controls.Add($updateFilterLabel)

$updateFilterBox = New-Object System.Windows.Forms.TextBox
$updateFilterBox.Width = 462
$updateFilterBox.PlaceholderText = Get-UiString 'UpdateFilterPlaceholder'
# Wrapped in a rounded input host so the placeholder/typed text has proper left padding (a bare
# TextBox put "Type to filter..." hard against the left border) and matches the other fields.
$updateFilterHost = New-RoundedInput -Inner $updateFilterBox -X 250 -Y 37 -W 462 -H 30
$cardUpdates.Controls.Add($updateFilterHost)

# Detail ListView (was a CheckedListBox): shows the version columns that matter for an update
# decision instead of just the app name. $script:updateApps stays the source of truth; the rows
# only mirror it, and each row keeps the app name in .Text so the existing lookups keep working.
$updateListBox = New-Object System.Windows.Forms.ListView
$updateListBox.Location = New-Object System.Drawing.Point(14,72)
$updateListBox.Width = 698
$updateListBox.Height = 142
$updateListBox.View = [System.Windows.Forms.View]::Details
$updateListBox.CheckBoxes = $true
$updateListBox.FullRowSelect = $true
$updateListBox.MultiSelect = $false
$updateListBox.HideSelection = $false
$updateListBox.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
# Widths add up to just under the fixed list width (698) so no horizontal scrollbar appears.
# The state column holds only what the target IS; anything qualifying it goes into the separate
# note column, which previously truncated the state text into an unreadable "... | scope...".
[void]$updateListBox.Columns.Add((Get-UiString 'ColApp'), 235)
[void]$updateListBox.Columns.Add((Get-UiString 'ColCurrentVersion'), 100)
[void]$updateListBox.Columns.Add((Get-UiString 'ColLatestVersion'), 100)
[void]$updateListBox.Columns.Add((Get-UiString 'ColUpdateState'), 110)
[void]$updateListBox.Columns.Add((Get-UiString 'ColUpdateNote'), 145)
$cardUpdates.Controls.Add($updateListBox)


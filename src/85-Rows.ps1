# Builds a row for one update candidate (name + both versions), mirroring its checked state.
function New-UpdateRow {
  param($App)
  $it = New-Object System.Windows.Forms.ListViewItem([string]$App.Name)
  $it.Tag = $App
  [void]$it.SubItems.Add([string]$App.CurrentVersion)
  [void]$it.SubItems.Add([string]$App.LatestVersion)
  # A blocked row exists only to make a tenant problem visible; it must never look actionable.
  if ($App.PSObject.Properties['IsBlocked'] -and $App.IsBlocked) {
    [void]$it.SubItems.Add((Get-UiString 'UpdateStateBlocked'))
    [void]$it.SubItems.Add([string]$App.BlockedReason)
    $it.ForeColor = [System.Drawing.Color]::IndianRed
    return $it
  }

  # Target column answers "what is the target in Intune?", note column answers "what has to happen?".
  # Both used to sit in the target column, which is why an action phrase appeared under that heading.
  $targetState = if ($App.TargetAlreadyDeployed) { Get-UiString 'UpdateTargetExisting' } else { Get-UiString 'UpdateTargetToCreate' }

  $noteParts = [System.Collections.Generic.List[string]]::new()
  $actionNote = if ($App.TargetAlreadyDeployed) { Get-UiString 'UpdateStateExisting' } else { Get-UiString 'UpdateStateNew' }
  $noteParts.Add([string]$actionNote)
  if ($App.PSObject.Properties['ScopeWarning'] -and $App.ScopeWarning) {
    $noteParts.Add((Get-UiString 'UpdateStateScopeWarning'))
    $it.ForeColor = [System.Drawing.Color]::DarkOrange
  }
  # Only shown when every scope probe succeeded and came back empty - see Group-UpdateCandidates.
  if ($App.PSObject.Properties['NoAssignment'] -and $App.NoAssignment) {
    $noteParts.Add((Get-UiString 'UpdateStateNoAssignment'))
  }
  [void]$it.SubItems.Add($targetState)
  [void]$it.SubItems.Add(($noteParts -join '; '))
  if ($App.Checked) { $it.Checked = $true }
  return $it
}

# Hovering a row shows its full content. The card has a fixed width and does not grow with the
# window, so long app names or notes are still cut off at the column edge - and a ListView in
# Details view only offers a horizontal scrollbar once the columns are WIDER than the control,
# which is deliberately not the case here. The tooltip is the recovery path.
#
# ShowItemToolTips is deliberately not used: it is known to interfere with checkbox hit-testing,
# and these checkboxes decide which apps actually get updated.
$updateListTooltip = New-Object System.Windows.Forms.ToolTip
$updateListTooltip.InitialDelay = 350
$updateListTooltip.ReshowDelay = 80
$updateListTooltip.AutoPopDelay = 20000
$script:updateListTipRow = $null

$updateListBox.Add_MouseMove({
  param($listSender, $e)
  try {
    $hit = $listSender.HitTest($e.X, $e.Y)
    $row = if ($hit) { $hit.Item } else { $null }
    if ($script:updateListTipRow -eq $row) { return }   # only rebuild when the row changes
    $script:updateListTipRow = $row
    if (-not $row) { $updateListTooltip.Hide($listSender); return }

    $lines = @([string]$row.Text)
    $labels = @('ColCurrentVersion', 'ColLatestVersion', 'ColUpdateState', 'ColUpdateNote')
    for ($i = 0; $i -lt $labels.Count; $i++) {
      $subIndex = $i + 1
      if ($row.SubItems.Count -le $subIndex) { break }
      $value = [string]$row.SubItems[$subIndex].Text
      if ($value) { $lines += ('{0}: {1}' -f (Get-UiString $labels[$i]), $value) }
    }
    # Shown explicitly instead of via SetToolTip: WinForms only raises a tooltip when the mouse
    # ENTERS a control, so assigning new text while the pointer is already inside the list never
    # displayed anything. Offset below the cursor so the pointer does not cover the first line.
    $updateListTooltip.Show(($lines -join "`r`n"), $listSender, ($e.X + 16), ($e.Y + 20), 20000)
  } catch { }   # class 3: a failed tooltip must never disturb the list
})

# Blocked rows cannot be selected for an update. Cancelling here rather than hiding the checkbox
# keeps the list uniform, and "Check all" cannot silently pick up an app that must not be touched.
$updateListBox.Add_ItemCheck({
  param($listSender, $e)
  try {
    $row = $listSender.Items[$e.Index]
    $model = if ($row) { $row.Tag } else { $null }
    if ($model -and $model.PSObject.Properties['IsBlocked'] -and $model.IsBlocked) {
      $e.NewValue = [System.Windows.Forms.CheckState]::Unchecked
    }
  } catch { }   # class 3: never let the guard break normal checking
})

$updateListBox.Add_MouseLeave({
  try { $script:updateListTipRow = $null; $updateListTooltip.Hide($updateListBox) } catch { }
})

# Empty-state hint shown INSTEAD of the native list. It stays transparent so the card remains one
# continuous surface; using the list background here produced the visible side-edge overlap from
# the screenshot when the elastic card was resized.
$updatesEmptyLabel = New-Object System.Windows.Forms.Label
$updatesEmptyLabel.Tag = 'hint'
$updatesEmptyLabel.Text = Get-UiString 'UpdatesEmptyHint'
$updatesEmptyLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$updatesEmptyLabel.Location = $updateListBox.Location
$updatesEmptyLabel.Size = $updateListBox.Size
$cardUpdates.Controls.Add($updatesEmptyLabel)
# Start empty: show the hint, hide the (empty) list so the native control can't paint over it.
$updateListBox.Visible = $false
$updatesEmptyLabel.Visible = $true
$updatesEmptyLabel.BringToFront()

$checkAllButton = New-Object System.Windows.Forms.Button
$checkAllButton.Tag = 'btn-secondary'
$checkAllButton.Text = Get-UiString 'CheckAllButton'
$checkAllButton.Location = New-Object System.Drawing.Point(14,222)
$checkAllButton.Width = 120
$checkAllButton.Enabled = $false
$cardUpdates.Controls.Add($checkAllButton)

$uncheckAllButton = New-Object System.Windows.Forms.Button
$uncheckAllButton.Tag = 'btn-secondary'
$uncheckAllButton.Text = Get-UiString 'UncheckAllButton'
$uncheckAllButton.Location = New-Object System.Drawing.Point(140,222)
$uncheckAllButton.Width = 120
$uncheckAllButton.Enabled = $false
$cardUpdates.Controls.Add($uncheckAllButton)

$updateSelectedButton = New-Object System.Windows.Forms.Button
$updateSelectedButton.Text = Get-UiString 'UpdateSelectedButton'
$updateSelectedButton.Location = New-Object System.Drawing.Point(266,222)
$updateSelectedButton.Width = 196
$updateSelectedButton.Enabled = $false
$cardUpdates.Controls.Add($updateSelectedButton)

$updateAllButton = New-Object System.Windows.Forms.Button
$updateAllButton.Text = Get-UiString 'UpdateAllButton'
$updateAllButton.Location = New-Object System.Drawing.Point(468,222)
$updateAllButton.Width = 244
$updateAllButton.Enabled = $false
$cardUpdates.Controls.Add($updateAllButton)

# --- Card 2: Superseded (old) app versions ---
# Scrolls if the window is too short for both cards (the updates list got taller).
# The updates list GROWS WITH THE WINDOW instead of using fixed pixel heights: the available height
# is split between the (elastic) updates card and the fixed-height superseded card below it.
# Sizes are computed explicitly here rather than via Anchor, because anchor margins are captured at
# construction time – when this panel was still tiny – which previously over-stretched a card far
# beyond the window (see the Discovered card incident).
$script:supersededCardHeight = 120
function Update-UpdatesLayout {
  try {
    if (-not $tabUpdate -or -not $cardUpdates -or -not $cardSuperseded) { return }
    $avail = $tabUpdate.ClientSize.Height
    if ($avail -lt 200) { return }
    $topY = 48; $gap = 12; $bottomPad = 6
    $updH = $avail - $topY - $gap - $script:supersededCardHeight - $bottomPad
    if ($updH -lt 180) { $updH = 180 }          # never collapse below a usable size
    $cardUpdates.Height  = $updH
    # Inside the card: list fills everything between the filter row (Y=72) and the button row.
    # The button HEIGHT is set here as well: the layout reserved 32px while the buttons kept their
    # 23px default, so the row floated in the reserved space and ended up visually crowding the
    # card's bottom border ("the card overlaps the buttons"). Reserving and setting the same value
    # keeps a clean, constant 16px below the row.
    $btnH = 30; $btnGap = 10; $btnPadBottom = 16
    $listH = $updH - 72 - $btnH - $btnGap - $btnPadBottom
    if ($listH -lt 80) { $listH = 80 }
    $updateListBox.Height = $listH

    # Width follows the card, and the extra space is handed to the columns that actually truncate:
    # long app names first, then the note, and a little to the version columns so build numbers
    # like "150.0.7871.187" stay readable.
    $listW = [Math]::Max(698, $cardUpdates.ClientSize.Width - 28)
    $updateListBox.Width = $listW
    $extra = $listW - 698
    if ($extra -gt 0 -and $updateListBox.Columns.Count -ge 5) {
      $updateListBox.Columns[0].Width = 235 + [int]($extra * 0.40)
      $updateListBox.Columns[1].Width = 100 + [int]($extra * 0.13)
      $updateListBox.Columns[2].Width = 100 + [int]($extra * 0.13)
      $updateListBox.Columns[3].Width = 110 + [int]($extra * 0.14)
      $updateListBox.Columns[4].Width = 145 + [int]($extra * 0.20)
    }
    if ($updatesEmptyLabel) { $updatesEmptyLabel.Size = $updateListBox.Size }
    $btnY = 72 + $listH + $btnGap
    foreach ($b in @($checkAllButton, $uncheckAllButton, $updateSelectedButton, $updateAllButton)) {
      if ($b) { $b.Top = $btnY; $b.Height = $btnH }
    }
    $cardSuperseded.Top    = $cardUpdates.Bottom + $gap
    $cardSuperseded.Height = $script:supersededCardHeight
  } catch { Write-LogDebug ("Updates layout: {0}" -f $_.Exception.Message) }
}

$cardSuperseded = New-Card -X 16 -Y 318 -W 726 -H 120
$tabUpdate.Controls.Add($cardSuperseded)

$supersededHeaderLabel = New-Object System.Windows.Forms.Label
$supersededHeaderLabel.Text = Get-UiString 'UpdatesCardSuperseded'
$supersededHeaderLabel.Location = New-Object System.Drawing.Point(14,10)
$supersededHeaderLabel.AutoSize = $true
$supersededHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardSuperseded.Controls.Add($supersededHeaderLabel)
[void](Add-SectionInfoBadge -Parent $cardSuperseded -AfterLabel $supersededHeaderLabel -TextKey 'InfoCardSuperseded')

$supersededSearchButton = New-Object System.Windows.Forms.Button
$supersededSearchButton.Text = Get-UiString 'SupersededSearchButton'
$supersededSearchButton.Location = New-Object System.Drawing.Point(14,38)
$supersededSearchButton.Width = 250
$supersededSearchButton.Enabled = $false
$cardSuperseded.Controls.Add($supersededSearchButton)

$supersededDropdown = New-Object System.Windows.Forms.ComboBox
$supersededDropdown.Location = New-Object System.Drawing.Point(272,38)
$supersededDropdown.Width = 440
$supersededDropdown.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cardSuperseded.Controls.Add($supersededDropdown)

$deleteSelectedAppButton = New-Object System.Windows.Forms.Button
$deleteSelectedAppButton.Text = Get-UiString 'DeleteSelectedAppButton'
$deleteSelectedAppButton.Location = New-Object System.Drawing.Point(14,76)
$deleteSelectedAppButton.Width = 250
$deleteSelectedAppButton.Enabled = $false
$cardSuperseded.Controls.Add($deleteSelectedAppButton)

$removeOldAppsButton = New-Object System.Windows.Forms.Button
$removeOldAppsButton.Text = Get-UiString 'RemoveOldAppsButton'
$removeOldAppsButton.Location = New-Object System.Drawing.Point(272,76)
$script:keepVersionCount = if ([int]$script:settings.KeepVersionCount -ge 1) { [int]$script:settings.KeepVersionCount } else { 2 }
$removeOldAppsButton.Width = 230
$removeOldAppsButton.Enabled = $false
$cardSuperseded.Controls.Add($removeOldAppsButton)

# "Keep only N versions": trims each app's version history down to the newest N (default 2), i.e.
# the current one plus its predecessor. Apps that only have one version are never touched.
$versionCleanupButton = New-Object System.Windows.Forms.Button
$versionCleanupButton.Tag = 'btn-secondary'
$versionCleanupButton.Text = (Get-UiString 'VersionCleanupButton') -f $script:keepVersionCount
$versionCleanupButton.Location = New-Object System.Drawing.Point(512,76)
$versionCleanupButton.Width = 200
$cardSuperseded.Controls.Add($versionCleanupButton)
$versionCleanupButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  Invoke-VersionCleanup -KeepCount $script:keepVersionCount
})

# ==================================================
# Section: Discovered Apps
# ==================================================
$tabDiscovered = New-Object System.Windows.Forms.Panel
Add-Section -Key 'discovered' -Panel $tabDiscovered -Label (Get-UiString 'TabDiscovered')

# Section title
$discoveredHeaderLabel = New-Object System.Windows.Forms.Label
$discoveredHeaderLabel.Text = Get-UiString 'DiscoveredHeaderLabel'
$discoveredHeaderLabel.Location = New-Object System.Drawing.Point(16,12)
$discoveredHeaderLabel.AutoSize = $true
$discoveredHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabDiscovered.Controls.Add($discoveredHeaderLabel)
[void](Add-SectionInfoBadge -Parent $tabDiscovered -AfterLabel $discoveredHeaderLabel -TextKey 'InfoDiscovered')

# --- Card 1: Scan and deploy (actions + assignment) ---
$cardScan = New-Card -X 16 -Y 48 -W 726 -H 142
$tabDiscovered.Controls.Add($cardScan)

$scanStepLabel = New-Object System.Windows.Forms.Label
$scanStepLabel.Text = Get-UiString 'DiscoveredCardScan'
$scanStepLabel.Location = New-Object System.Drawing.Point(14,8)
$scanStepLabel.AutoSize = $true
$scanStepLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardScan.Controls.Add($scanStepLabel)
[void](Add-SectionInfoBadge -Parent $cardScan -AfterLabel $scanStepLabel -TextKey 'InfoCardScan')

$scanDiscoveredButton = New-Object System.Windows.Forms.Button
$scanDiscoveredButton.Tag = 'btn-secondary'
$scanDiscoveredButton.Text = Get-UiString 'ScanDiscoveredButton'
$scanDiscoveredButton.Location = New-Object System.Drawing.Point(14,32)
$scanDiscoveredButton.Width = 210
$scanDiscoveredButton.Enabled = $false
$cardScan.Controls.Add($scanDiscoveredButton)

$deployDiscoveredButton = New-Object System.Windows.Forms.Button
$deployDiscoveredButton.Tag = 'btn-secondary'
$deployDiscoveredButton.Text = Get-UiString 'DeployDiscoveredButton'
$deployDiscoveredButton.Location = New-Object System.Drawing.Point(232,32)
$deployDiscoveredButton.Width = 210
$deployDiscoveredButton.Enabled = $false
$cardScan.Controls.Add($deployDiscoveredButton)

$exportDiscoveredCsvButton = New-Object System.Windows.Forms.Button
$exportDiscoveredCsvButton.Tag = 'btn-secondary'
$exportDiscoveredCsvButton.Text = Get-UiString 'ExportDiscoveredCsvButton'
$exportDiscoveredCsvButton.Location = New-Object System.Drawing.Point(450,32)
$exportDiscoveredCsvButton.Width = 262
$exportDiscoveredCsvButton.Enabled = $false
$cardScan.Controls.Add($exportDiscoveredCsvButton)

$discoveredAssignLabel = New-Object System.Windows.Forms.Label
$discoveredAssignLabel.Text = Get-UiString 'DiscoveredAssignLabel'
$discoveredAssignLabel.Location = New-Object System.Drawing.Point(14,74)
$discoveredAssignLabel.AutoSize = $true
$cardScan.Controls.Add($discoveredAssignLabel)

$discoveredAssignTargetCombo = New-Object System.Windows.Forms.ComboBox
$discoveredAssignTargetCombo.Location = New-Object System.Drawing.Point(100,72)
$discoveredAssignTargetCombo.Width = 250
$discoveredAssignTargetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$discoveredAssignTargetCombo.Items.AddRange(@((Get-UiString 'AssignNotAssigned'), (Get-UiString 'AssignAllUsers'), (Get-UiString 'AssignAllDevices'), (Get-UiString 'AssignCustomGroup')))
$discoveredAssignTargetCombo.SelectedIndex = 0
$cardScan.Controls.Add($discoveredAssignTargetCombo)

$discoveredAssignGroupIdBox = New-Object System.Windows.Forms.TextBox
$discoveredAssignGroupIdBox.Location = New-Object System.Drawing.Point(360,72)
$discoveredAssignGroupIdBox.Width = 200
$discoveredAssignGroupIdBox.BorderStyle = 'FixedSingle'
$discoveredAssignGroupIdBox.Visible = $false
$cardScan.Controls.Add($discoveredAssignGroupIdBox)

$discoveredAssignTargetCombo.Add_SelectedIndexChanged({
  $discoveredAssignGroupIdBox.Visible = ($discoveredAssignTargetCombo.SelectedItem -eq (Get-UiString 'AssignCustomGroup'))
})

$discoveredAssignmentHint = New-Object System.Windows.Forms.Label
$discoveredAssignmentHint.Text = Get-UiString 'DiscoveredAssignmentHint'
$discoveredAssignmentHint.Location = New-Object System.Drawing.Point(14,102)
$discoveredAssignmentHint.AutoSize = $true
$discoveredAssignmentHint.Tag = 'hint'
# Use the established theme palette. A null Color assignment aborts form construction before the
# later full-theme pass can repair it, so the removed auxiliary palette must not be used here.
$hintColor = if ($script:currentTheme -and $script:currentTheme.SecondaryForeColor -is [System.Drawing.Color]) {
  $script:currentTheme.SecondaryForeColor
} else {
  [System.Drawing.SystemColors]::GrayText
}
$discoveredAssignmentHint.ForeColor = $hintColor
$cardScan.Controls.Add($discoveredAssignmentHint)

# --- Card 2: Detected apps (filters + list, fills remaining space) ---
$cardDetected = New-Card -X 16 -Y 202 -W 726 -H 270
# Fixed size (Top+Left only – like every other card). It must NOT anchor Right: its right-anchor
# margin was computed while the section panel was still tiny, so on a wide/maximised window the card
# over-stretched to ~2200px (wider than the window), pushing the centred empty-state hint far right.
# A fixed 726px-wide card (matching the Scan card above) keeps the hint centred and on-screen.
$cardDetected.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$tabDiscovered.Controls.Add($cardDetected)

$detectedStepLabel = New-Object System.Windows.Forms.Label
$detectedStepLabel.Text = Get-UiString 'DiscoveredCardResults'
$detectedStepLabel.Location = New-Object System.Drawing.Point(14,8)
$detectedStepLabel.AutoSize = $true
$detectedStepLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardDetected.Controls.Add($detectedStepLabel)
[void](Add-SectionInfoBadge -Parent $cardDetected -AfterLabel $detectedStepLabel -TextKey 'InfoCardScanResults')

$discoveredAppSearchLabel = New-Object System.Windows.Forms.Label
$discoveredAppSearchLabel.Text = Get-UiString 'DiscoveredAppSearchLabel'
$discoveredAppSearchLabel.Location = New-Object System.Drawing.Point(14, 36)
$discoveredAppSearchLabel.AutoSize = $true
$cardDetected.Controls.Add($discoveredAppSearchLabel)

# The three filter label+field pairs are positioned by CASCADE from each label's actual rendered
# width (PreferredWidth), not fixed X coordinates – otherwise the longer German labels
# ("Herausgeber:", "App suchen:") overlapped their fields. gap = label→field, ggap = field→next label.
$gap = 8; $ggap = 18
$discoveredAppSearchBox = New-Object System.Windows.Forms.TextBox
$discoveredAppSearchBox.Top = 33
$discoveredAppSearchBox.Left = $discoveredAppSearchLabel.Left + $discoveredAppSearchLabel.PreferredWidth + $gap
$discoveredAppSearchBox.Width = 150
$cardDetected.Controls.Add($discoveredAppSearchBox)

$discoveredPublisherLabel = New-Object System.Windows.Forms.Label
$discoveredPublisherLabel.Text = Get-UiString 'DiscoveredPublisherLabel'
$discoveredPublisherLabel.AutoSize = $true
$discoveredPublisherLabel.Top = 36
$discoveredPublisherLabel.Left = $discoveredAppSearchBox.Left + $discoveredAppSearchBox.Width + $ggap
$cardDetected.Controls.Add($discoveredPublisherLabel)

$discoveredPublisherBox = New-Object System.Windows.Forms.ComboBox
$discoveredPublisherBox.Top = 33
$discoveredPublisherBox.Left = $discoveredPublisherLabel.Left + $discoveredPublisherLabel.PreferredWidth + $gap
$discoveredPublisherBox.Width = 140
$discoveredPublisherBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$discoveredPublisherBox.Items.Add("<All Publishers>")
$discoveredPublisherBox.SelectedIndex = 0
$cardDetected.Controls.Add($discoveredPublisherBox)

$discoveredSortLabel = New-Object System.Windows.Forms.Label
$discoveredSortLabel.Text = Get-UiString 'DiscoveredSortLabel'
$discoveredSortLabel.AutoSize = $true
$discoveredSortLabel.Top = 36
$discoveredSortLabel.Left = $discoveredPublisherBox.Left + $discoveredPublisherBox.Width + $ggap
$cardDetected.Controls.Add($discoveredSortLabel)

$discoveredSortBox = New-Object System.Windows.Forms.ComboBox
$discoveredSortBox.Top = 33
$discoveredSortBox.Left = $discoveredSortLabel.Left + $discoveredSortLabel.PreferredWidth + $gap
$discoveredSortBox.Width = 120
$discoveredSortBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$discoveredSortBox.Items.Add("Device Count")
[void]$discoveredSortBox.Items.Add("Alphabetical")
$discoveredSortBox.SelectedIndex = 0
$cardDetected.Controls.Add($discoveredSortBox)

$checkAllDiscoveredButton = New-Object System.Windows.Forms.Button
$checkAllDiscoveredButton.Tag = 'btn-secondary'
$checkAllDiscoveredButton.Text = Get-UiString 'CheckAllDiscoveredButton'
$checkAllDiscoveredButton.Location = New-Object System.Drawing.Point(14,66)
$checkAllDiscoveredButton.Width = 110
$checkAllDiscoveredButton.Enabled = $false
$cardDetected.Controls.Add($checkAllDiscoveredButton)

$uncheckAllDiscoveredButton = New-Object System.Windows.Forms.Button
$uncheckAllDiscoveredButton.Tag = 'btn-secondary'
$uncheckAllDiscoveredButton.Text = Get-UiString 'UncheckAllDiscoveredButton'
$uncheckAllDiscoveredButton.Location = New-Object System.Drawing.Point(132,66)
$uncheckAllDiscoveredButton.Width = 120
$uncheckAllDiscoveredButton.Enabled = $false
$cardDetected.Controls.Add($uncheckAllDiscoveredButton)

# Detail ListView (was a CheckedListBox): the publisher / device count / matched WinGet ID are now
# separate columns instead of one concatenated string. Each row carries its source object in .Tag,
# so the checked state maps back to the model without fragile text matching.
$discoveredListBox = New-Object System.Windows.Forms.ListView
$discoveredListBox.Location = New-Object System.Drawing.Point(14,100)
$discoveredListBox.Width = 698
$discoveredListBox.Height = 158
$discoveredListBox.View = [System.Windows.Forms.View]::Details
$discoveredListBox.CheckBoxes = $true
$discoveredListBox.FullRowSelect = $true
$discoveredListBox.MultiSelect = $false
$discoveredListBox.HideSelection = $false
$discoveredListBox.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
[void]$discoveredListBox.Columns.Add((Get-UiString 'ColApp'), 250)
[void]$discoveredListBox.Columns.Add((Get-UiString 'ColPublisher'), 160)
[void]$discoveredListBox.Columns.Add((Get-UiString 'ColDevices'), 70)
[void]$discoveredListBox.Columns.Add((Get-UiString 'ColWingetId'), 200)
$discoveredListBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$cardDetected.Controls.Add($discoveredListBox)

# Builds a row for one discovered app; .Tag keeps the source object for the checked-state sync.
function New-DiscoveredRow {
  param($Obj)
  $it = New-Object System.Windows.Forms.ListViewItem([string]$Obj.DisplayName)
  [void]$it.SubItems.Add([string]$Obj.Publisher)
  [void]$it.SubItems.Add([string]$Obj.DeviceCount)
  [void]$it.SubItems.Add([string]$Obj.WingetApp.PackageID)
  $it.Tag = $Obj
  if ($Obj.Checked) { $it.Checked = $true }
  return $it
}

# Empty-state hint. IMPORTANT: it does NOT overlay the list – a native CheckedListBox HWND paints
# over an overlapping managed label (that was the mis-positioned/garbled hint). Instead the label
# occupies the exact list rectangle, and Update-DiscoveredListUI shows EITHER the list OR this label
# (never both), so the centred hint always renders cleanly.
$discoveredEmptyLabel = New-Object System.Windows.Forms.Label
$discoveredEmptyLabel.Tag = 'list-overlay'
$discoveredEmptyLabel.Text = Get-UiString 'DiscoveredEmptyHint'
$discoveredEmptyLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$discoveredEmptyLabel.Location = $discoveredListBox.Location
$discoveredEmptyLabel.Size = $discoveredListBox.Size
$discoveredEmptyLabel.Anchor = $discoveredListBox.Anchor
$cardDetected.Controls.Add($discoveredEmptyLabel)
# Start empty: show the hint, hide the (empty) list.
$discoveredListBox.Visible = $false
$discoveredEmptyLabel.Visible = $true

$script:discoveredRaw = @()

# ==================================================
# Section: Settings
# ==================================================
$tabSettings = New-Object System.Windows.Forms.Panel
# Three stacked cards (General / App updates / Files) exceed the panel on small windows -> scroll.
$tabSettings.AutoScroll = $true
Add-Section -Key 'settings' -Panel $tabSettings -Label (Get-UiString 'TabSettings')

# Section title
$settingsHeaderLabel = New-Object System.Windows.Forms.Label
$settingsHeaderLabel.Text = Get-UiString 'SettingsHeaderLabel'
$settingsHeaderLabel.Location = New-Object System.Drawing.Point(16,12)
$settingsHeaderLabel.AutoSize = $true
$settingsHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabSettings.Controls.Add($settingsHeaderLabel)
[void](Add-SectionInfoBadge -Parent $tabSettings -AfterLabel $settingsHeaderLabel -TextKey 'InfoSettings')

# --- Card 1: General ---
$cardGeneral = New-Card -X 16 -Y 48 -W 726 -H 296
$tabSettings.Controls.Add($cardGeneral)

$generalStepLabel = New-Object System.Windows.Forms.Label
$generalStepLabel.Text = Get-UiString 'SettingsCardGeneral'
$generalStepLabel.Location = New-Object System.Drawing.Point(14,8)
$generalStepLabel.AutoSize = $true
$generalStepLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardGeneral.Controls.Add($generalStepLabel)
[void](Add-SectionInfoBadge -Parent $cardGeneral -AfterLabel $generalStepLabel -TextKey 'InfoCardGeneral')

# Default Package Path
$defaultPathLabel = New-Object System.Windows.Forms.Label
$defaultPathLabel.Text = Get-UiString 'DefaultPathLabel'
$defaultPathLabel.Location = New-Object System.Drawing.Point(14,42)
$defaultPathLabel.AutoSize = $true
$cardGeneral.Controls.Add($defaultPathLabel)

# Wrapped in a rounded input host (like the deploy path field) instead of a bare FixedSingle box:
# a plain TextBox has almost no left text padding, so the first character (the drive letter "C")
# looked clipped against the border. The host gives it the consistent rounded look + 10px padding.
$defaultPathTextBox = New-Object System.Windows.Forms.TextBox
$defaultPathTextBox.Text = if ($script:settings.DefaultPackagePath) { $script:settings.DefaultPackagePath } else { "C:\Temp" }
$defaultPathHost = New-RoundedInput -Inner $defaultPathTextBox -X 180 -Y 36 -W 386 -H 30
$cardGeneral.Controls.Add($defaultPathHost)

$browsePathButton = New-Object System.Windows.Forms.Button
$browsePathButton.Tag = 'btn-secondary'
$browsePathButton.Text = Get-UiString 'BrowsePathButton'
$browsePathButton.Location = New-Object System.Drawing.Point(578,36)
$browsePathButton.Width = 134
$browsePathButton.Height = 30
$cardGeneral.Controls.Add($browsePathButton)

# Auto-Check Updates on Login
$autoCheckUpdatesCheckbox = New-Object System.Windows.Forms.CheckBox
$autoCheckUpdatesCheckbox.Text = Get-UiString 'AutoCheckUpdatesCheckbox'
$autoCheckUpdatesCheckbox.Location = New-Object System.Drawing.Point(14,78)
$autoCheckUpdatesCheckbox.AutoSize = $true
$autoCheckUpdatesCheckbox.Checked = [bool]$script:settings.AutoCheckUpdates
# NOTE: this setting runs the INTUNE app update search right after login (see the login handler)
# – it has nothing to do with the GitHub self-update of the GUI itself. It was previously gated
# on $script:githubRepo, which forced the box permanently off/inert whenever no self-update repo
# was configured. That gate is gone; the option works standalone and is off by default, because in
# large tenants the login-time scan walks every app and can take a long time.
$cardGeneral.Controls.Add($autoCheckUpdatesCheckbox)

# Ablöse: auto-remove the old (now superseded) app right after a successful update
$autoRemoveSupersededCheckbox = New-Object System.Windows.Forms.CheckBox
$autoRemoveSupersededCheckbox.Text = Get-UiString 'AutoRemoveSupersededCheckbox'
$autoRemoveSupersededCheckbox.Location = New-Object System.Drawing.Point(14,106)
$autoRemoveSupersededCheckbox.AutoSize = $true
$autoRemoveSupersededCheckbox.Checked = [bool]$script:settings.AutoRemoveSuperseded
$cardGeneral.Controls.Add($autoRemoveSupersededCheckbox)

# Automatic version trimming after an update run: keeps the newest N versions per app.
$autoVersionCleanupCheckbox = New-Object System.Windows.Forms.CheckBox
$autoVersionCleanupCheckbox.Text = (Get-UiString 'AutoVersionCleanupCheckbox') -f $script:keepVersionCount
$autoVersionCleanupCheckbox.Location = New-Object System.Drawing.Point(14,130)
$autoVersionCleanupCheckbox.AutoSize = $true
$autoVersionCleanupCheckbox.Checked = [bool]$script:settings.AutoVersionCleanup
$cardGeneral.Controls.Add($autoVersionCleanupCheckbox)

# Scope hand-over: only the newest version stays assigned after an update.
$moveAssignmentsCheckbox = New-Object System.Windows.Forms.CheckBox
$moveAssignmentsCheckbox.Text = Get-UiString 'MoveAssignmentsCheckbox'
$moveAssignmentsCheckbox.Location = New-Object System.Drawing.Point(14,154)
$moveAssignmentsCheckbox.AutoSize = $true
$moveAssignmentsCheckbox.Checked = [bool]$script:settings.MoveAssignmentsOnUpdate
$cardGeneral.Controls.Add($moveAssignmentsCheckbox)

# Either/or, enforced here as well as in the settings model (Resolve-CleanupOptionConflict): ticking
# one of the two cleanup options clears the other, so the state that silently deleted a predecessor
# while "keep the newest versions" was also ticked cannot be produced in the first place.
# The guard flag stops the two CheckedChanged handlers from bouncing the change back and forth.
# Plain scriptblocks on purpose - a .GetNewClosure() handler runs in its own dynamic module and
# cannot resolve script-scope functions such as Get-UiString when it fires from the message loop.
$script:cleanupOptionSyncing = $false
$autoRemoveSupersededCheckbox.Add_CheckedChanged({
  if ($script:cleanupOptionSyncing) { return }
  if (-not $autoRemoveSupersededCheckbox.Checked -or -not $autoVersionCleanupCheckbox.Checked) { return }
  $script:cleanupOptionSyncing = $true
  try {
    $autoVersionCleanupCheckbox.Checked = $false
    Update-Status (Get-UiString 'CleanupExclusiveStatus')
  } finally { $script:cleanupOptionSyncing = $false }
})
$autoVersionCleanupCheckbox.Add_CheckedChanged({
  if ($script:cleanupOptionSyncing) { return }
  if (-not $autoVersionCleanupCheckbox.Checked -or -not $autoRemoveSupersededCheckbox.Checked) { return }
  $script:cleanupOptionSyncing = $true
  try {
    $autoRemoveSupersededCheckbox.Checked = $false
    Update-Status (Get-UiString 'CleanupExclusiveStatus')
  } finally { $script:cleanupOptionSyncing = $false }
})

# How many versions survive. The number appears in three places - this checkbox, the button in the
# superseded card and that button's tooltip - so they are refreshed together from one helper rather
# than each reading the setting whenever it happens to be rebuilt.
$keepVersionCountLabel = New-Object System.Windows.Forms.Label
$keepVersionCountLabel.Text = Get-UiString 'KeepVersionCountLabel'
$keepVersionCountLabel.Location = New-Object System.Drawing.Point(14, 182)
$keepVersionCountLabel.AutoSize = $true
$cardGeneral.Controls.Add($keepVersionCountLabel)

$keepVersionCountInput = New-Object System.Windows.Forms.NumericUpDown
$keepVersionCountInput.Minimum = 1     # keeping zero versions would mean deleting the current one
$keepVersionCountInput.Maximum = 20
$keepVersionCountInput.Value = $script:keepVersionCount
$keepVersionCountInput.Location = New-Object System.Drawing.Point(250, 178)
$keepVersionCountInput.Width = 60
$cardGeneral.Controls.Add($keepVersionCountInput)

function Update-KeepVersionCountUi {
  $count = $script:keepVersionCount
  try { $autoVersionCleanupCheckbox.Text = (Get-UiString 'AutoVersionCleanupCheckbox') -f $count } catch { Write-LogDebug 'keep-count checkbox text' }
  try { $versionCleanupButton.Text = (Get-UiString 'VersionCleanupButton') -f $count } catch { Write-LogDebug 'keep-count button text' }
  # $toolTip is created later (90-Main); at runtime it exists, before that this is simply skipped.
  try { if ($toolTip) { $toolTip.SetToolTip($versionCleanupButton, ((Get-UiString 'TtVersionCleanupButton') -f $count)) } } catch { Write-LogDebug 'keep-count tooltip' }
}

$keepVersionCountInput.Add_ValueChanged({
  $script:keepVersionCount = [int]$keepVersionCountInput.Value
  Update-KeepVersionCountUi
})

$cleanupExclusiveHint = New-Object System.Windows.Forms.Label
$cleanupExclusiveHint.Tag = 'hint'
$cleanupExclusiveHint.Text = Get-UiString 'CleanupExclusiveHint'
$cleanupExclusiveHint.Location = New-Object System.Drawing.Point(14, 210)
$cleanupExclusiveHint.Size = New-Object System.Drawing.Size(698, 34)   # two wrapped lines in both languages
$cardGeneral.Controls.Add($cleanupExclusiveHint)

# Theme selection lives in the top-menu "Theme" picker now (not here). $themeSelectorCombo is kept
# as $null so later references (tooltips etc.) stay harmless.
$themeSelectorCombo = $null

# Language selection lives in the top-menu "Language" picker now (next to "Theme"), like the theme
# it is a display preference rather than a tenant/Intune setting. $languageSelectorCombo is kept as
# $null so later references (tooltips etc.) stay harmless.
$languageSelectorCombo = $null

# Settings-tab action buttons share one width so the stacked column lines up (wide enough
# for the longest German label, "Einstellungen speichern").
$script:settingsButtonWidth = 200

# Save Settings + Clear Version Cache buttons (same width, side by side)
$saveSettingsButton = New-Object System.Windows.Forms.Button
$saveSettingsButton.Text = Get-UiString 'SaveSettingsButton'
$saveSettingsButton.Location = New-Object System.Drawing.Point(14,250)
$saveSettingsButton.Width = $script:settingsButtonWidth
$saveSettingsButton.Height = 34
$cardGeneral.Controls.Add($saveSettingsButton)

$clearCacheButton = New-Object System.Windows.Forms.Button
$clearCacheButton.Tag = 'btn-secondary'
$clearCacheButton.Text = Get-UiString 'ClearCacheButton'
$clearCacheButton.Location = New-Object System.Drawing.Point(224,250)
$clearCacheButton.Width = $script:settingsButtonWidth
$clearCacheButton.Height = 34
$cardGeneral.Controls.Add($clearCacheButton)

# Browse Path Button Handler
$browsePathButton.Add_Click({
  $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
  $folderBrowser.Description = Get-UiString 'SelectDefaultFolderTitle'
  $folderBrowser.SelectedPath = $defaultPathTextBox.Text

  if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $defaultPathTextBox.Text = $folderBrowser.SelectedPath
    Update-Status (Get-UiString 'PathUpdatedStatus')
  }
})

# Save Settings Button Handler
$saveSettingsButton.Add_Click({
  if (Test-UiBusy) { return }
  try {
    $script:settings.DefaultPackagePath = $defaultPathTextBox.Text
    $script:settings.AutoCheckUpdates = $autoCheckUpdatesCheckbox.Checked
    $script:settings.AutoRemoveSuperseded = $autoRemoveSupersededCheckbox.Checked
    if ($autoVersionCleanupCheckbox) { $script:settings.AutoVersionCleanup = $autoVersionCleanupCheckbox.Checked }
    if ($moveAssignmentsCheckbox) { $script:settings.MoveAssignmentsOnUpdate = $moveAssignmentsCheckbox.Checked }
    if ($keepVersionCountInput) {
      $script:keepVersionCount = [int]$keepVersionCountInput.Value
      $script:settings.KeepVersionCount = $script:keepVersionCount
      Update-KeepVersionCountUi
    }
    # The checkboxes already exclude each other, so this normally changes nothing. It is the last
    # gate before the values are persisted: no combination that the update engine must not see can
    # reach settings.json, whatever produced it.
    if (Resolve-CleanupOptionConflict) {
      $script:cleanupOptionSyncing = $true
      try {
        $autoRemoveSupersededCheckbox.Checked = [bool]$script:settings.AutoRemoveSuperseded
        $autoVersionCleanupCheckbox.Checked = [bool]$script:settings.AutoVersionCleanup
      } finally { $script:cleanupOptionSyncing = $false }
      Update-Status (Get-UiString 'CleanupExclusiveStatus')
    }

    # Update pathBox on WinGet Apps tab with new default
    if ($pathBox) {
      $pathBox.Text = $script:settings.DefaultPackagePath
    }

    Save-Settings
    Update-Status (Get-UiString 'SettingsSavedStatus')

    [System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'SettingsSavedDialog'),
      (Get-UiString 'SettingsSavedTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    )
  } catch {
    Update-Status ((Get-UiString 'SaveSettingsFailedStatus') -f $_.Exception.Message)
    Write-Log "Settings save error: $($_.Exception.Message)"

    [System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'SaveSettingsFailedDialog') -f $_.Exception.Message),
      (Get-UiString 'ErrorTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    )
  }
})

# Clear Version Cache Button Handler
$clearCacheButton.Add_Click({
  if (Test-UiBusy) { return }
  $script:wingetVersionCache = @{}
  $script:diskCache = @{}
  $script:diskCacheLoaded = $false
  Remove-Item $script:versionCachePath -Force -ErrorAction SilentlyContinue
  Write-Log "Version cache cleared."
  Update-Status (Get-UiString 'CacheClearedStatus')
})

# --- Card 2: Application Updates (self-update of this tool) ---
$cardAppUpdates = New-Card -X 16 -Y 356 -W 726 -H 112
$tabSettings.Controls.Add($cardAppUpdates)

$updateSectionLabel = New-Object System.Windows.Forms.Label
$updateSectionLabel.Text = Get-UiString 'UpdateSectionLabel'
$updateSectionLabel.Location = New-Object System.Drawing.Point(14, 8)
$updateSectionLabel.AutoSize = $true
$updateSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardAppUpdates.Controls.Add($updateSectionLabel)
[void](Add-SectionInfoBadge -Parent $cardAppUpdates -AfterLabel $updateSectionLabel -TextKey 'InfoCardAppUpdates')

$currentVersionLabel = New-Object System.Windows.Forms.Label
$currentVersionLabel.Text = (Get-UiString 'CurrentVersionLabel') -f $script:appVersion
$currentVersionLabel.Location = New-Object System.Drawing.Point(14, 36)
$currentVersionLabel.AutoSize = $true
$cardAppUpdates.Controls.Add($currentVersionLabel)

$checkUpdateButton = New-Object System.Windows.Forms.Button
$checkUpdateButton.Text = Get-UiString 'CheckUpdateButton'
$checkUpdateButton.Location = New-Object System.Drawing.Point(14, 64)
$checkUpdateButton.Width = $script:settingsButtonWidth
$checkUpdateButton.Height = 34
# Disabled until a self-update repo is configured (see $script:githubRepo).
if ([string]::IsNullOrWhiteSpace($script:githubRepo)) { $checkUpdateButton.Enabled = $false }
$cardAppUpdates.Controls.Add($checkUpdateButton)

$checkUpdateButton.Add_Click({
  if (Test-UiBusy) { return }
  $checkUpdateButton.Enabled = $false
  # Runs on the UI thread, like every other long call in this app. It used to go through
  # Invoke-AsyncOperation (a BackgroundWorker), where the scriptblock never executed at all - a
  # worker thread has no PowerShell runspace - so the result was always $null and the check
  # silently reported "up to date". One HTTP GET with a 10s timeout is fine inline.
  Update-Status (Get-UiString 'UpdCheckingStatus')
  [System.Windows.Forms.Application]::DoEvents()
  try {
    Invoke-UpdateCheckFeedback -UpdateResult (Test-AppUpdateAvailable) -Context 'Manual'
  } finally {
    $checkUpdateButton.Enabled = $true
  }
})

# --- Card 3: Files & diagnostics ---
# The log path was only visible inside Help > About, which nobody opens while troubleshooting.
# Showing both paths here (selectable read-only fields, so they can be copied into a ticket)
# plus a button to open the folder makes them findable for a technician.
$cardFiles = New-Card -X 16 -Y 480 -W 726 -H 192
$tabSettings.Controls.Add($cardFiles)

$filesSectionLabel = New-Object System.Windows.Forms.Label
$filesSectionLabel.Text = Get-UiString 'FilesSectionLabel'
$filesSectionLabel.Location = New-Object System.Drawing.Point(14, 8)
$filesSectionLabel.AutoSize = $true
$filesSectionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardFiles.Controls.Add($filesSectionLabel)
[void](Add-SectionInfoBadge -Parent $cardFiles -AfterLabel $filesSectionLabel -TextKey 'InfoCardFiles')

$logPathLabel = New-Object System.Windows.Forms.Label
$logPathLabel.Text = Get-UiString 'LogFilePathLabel'
$logPathLabel.Location = New-Object System.Drawing.Point(14, 42)
$logPathLabel.AutoSize = $true
$cardFiles.Controls.Add($logPathLabel)

$logPathBox = New-Object System.Windows.Forms.TextBox
$logPathBox.Text = $script:logFilePath
$logPathBox.ReadOnly = $true
$logPathBox.Width = 546
$logPathHost = New-RoundedInput -Inner $logPathBox -X 150 -Y 36 -W 546 -H 28
$cardFiles.Controls.Add($logPathHost)

$settingsPathLabel = New-Object System.Windows.Forms.Label
$settingsPathLabel.Text = Get-UiString 'SettingsFilePathLabel'
$settingsPathLabel.Location = New-Object System.Drawing.Point(14, 76)
$settingsPathLabel.AutoSize = $true
$cardFiles.Controls.Add($settingsPathLabel)

$settingsPathBox = New-Object System.Windows.Forms.TextBox
$settingsPathBox.Text = $script:settingsPath
$settingsPathBox.ReadOnly = $true
$settingsPathBox.Width = 546
$settingsPathHost = New-RoundedInput -Inner $settingsPathBox -X 150 -Y 70 -W 546 -H 28
$cardFiles.Controls.Add($settingsPathHost)

$openLogButton = New-Object System.Windows.Forms.Button
$openLogButton.Tag = 'btn-secondary'
$openLogButton.Text = Get-UiString 'MenuOpenLogFile'
$openLogButton.Location = New-Object System.Drawing.Point(14, 144)
$openLogButton.Width = $script:settingsButtonWidth
$openLogButton.Height = 30
$cardFiles.Controls.Add($openLogButton)
$openLogButton.Add_Click({
  try {
    if (Test-Path $script:logFilePath) {
      Start-Process -FilePath $script:logFilePath -ErrorAction Stop
    } else {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'LogFileMissingDialog') -f $script:logFilePath),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    }
  } catch { Write-Log "Open log failed: $($_.Exception.Message)" }
})

$openLogFolderButton = New-Object System.Windows.Forms.Button
$openLogFolderButton.Tag = 'btn-secondary'
$openLogFolderButton.Text = Get-UiString 'OpenLogFolderButton'
$openLogFolderButton.Location = New-Object System.Drawing.Point(224, 144)
$openLogFolderButton.Width = $script:settingsButtonWidth
$openLogFolderButton.Height = 30
$cardFiles.Controls.Add($openLogFolderButton)
$filesHintLabel = New-Object System.Windows.Forms.Label
$filesHintLabel.Tag = 'hint'
$filesHintLabel.Text = Get-UiString 'FilesSectionHint'
$filesHintLabel.Location = New-Object System.Drawing.Point(14, 100)
$filesHintLabel.Size = New-Object System.Drawing.Size(698, 38)   # two full lines: the sentence wraps and was clipped at 26 px
$cardFiles.Controls.Add($filesHintLabel)

$openLogFolderButton.Add_Click({
  # Select the log in Explorer when it exists, otherwise just open the folder it would go to.
  try {
    if (Test-Path $script:logFilePath) {
      Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:logFilePath) -ErrorAction Stop
    } else {
      Start-Process explorer.exe -ArgumentList (Split-Path -Parent $script:logFilePath) -ErrorAction Stop
    }
  } catch { Write-Log "Open log folder failed: $($_.Exception.Message)" }
})

# Hashtable: AppName -> {PackageID, Version}
$script:packageMap = @{}

# Optional: user-chosen versions per PackageID
$script:selectedPackageVersions = @{}

function Update-SelectedPackageVersionLabel {
  if (-not $selectedVersionLabel) { return }
  $shownVersion = Get-UiString 'SelectedVersionNone'
  if ($dropdown -and $dropdown.SelectedItem) {
    $package = $script:packageMap[[string]$dropdown.SelectedItem]
    if ($package -and $package.PackageID) {
      $packageId = [string]$package.PackageID
      if ($script:selectedPackageVersions.ContainsKey($packageId)) {
        $shownVersion = [string]$script:selectedPackageVersions[$packageId]
      } elseif ($script:builtVersions -and $script:builtVersions.ContainsKey($packageId)) {
        $shownVersion = [string]$script:builtVersions[$packageId]
      } elseif (-not [string]::IsNullOrWhiteSpace([string]$package.Version)) {
        $shownVersion = (Get-UiString 'SelectedVersionLatest') -f ([string]$package.Version)
      }
    }
  }
  $selectedVersionLabel.Text = (Get-UiString 'SelectedVersionLabel') -f $shownVersion
}

# Drops every view and cached list that belongs to a specific tenant. Called on sign-in, disconnect
# and sign-out.
#
# Without this, signing in with a different account left the previous tenant's app lists on screen -
# in whichever section happened to be open. That is not just stale: acting on a row that belongs to
# another customer's tenant is exactly the mistake this tool must not invite. Nothing here talks to
# Graph; it only clears what is already on screen.
function Clear-TenantViews {
  try {
    # First and most important: a cached inventory belongs to the previous tenant.
    if (Get-Command Clear-Win32AppsCache -ErrorAction SilentlyContinue) { Clear-Win32AppsCache }
    # Update scan
    $script:updateApps = @()
    if ($updateListBox) { $updateListBox.Items.Clear() }
    if (Get-Command Update-UpdatesEmptyState -ErrorAction SilentlyContinue) {
      try { Update-UpdatesEmptyState } catch { }
    }
    # Only the two selection helpers: they belong to a scan result that no longer exists. The two
    # update buttons are force-enabled once at startup by design and gate themselves via
    # Test-Connected - disabling them here left them dead for the rest of the session, because
    # nothing switches them back on.
    foreach ($b in @($checkAllButton, $uncheckAllButton)) {
      if ($b) { $b.Enabled = $false }
    }

    # Superseded apps
    $script:supersededApps = @()
    if ($supersededDropdown) { $supersededDropdown.Items.Clear(); $supersededDropdown.Text = '' }

    # Tenant-wide app list
    $script:tenantApps = @()
    if ($tenantListView) { $tenantListView.Items.Clear() }
    if ($tenantDetailBox) { $tenantDetailBox.Text = '' }
    foreach ($b in @($tenantAssignButton, $tenantEditButton)) { if ($b) { $b.Enabled = $false } }

    # Microsoft Store inventory
    if ($storeTenantListView) { $storeTenantListView.Items.Clear() }

    # Discovered apps
    $script:discoveredRaw = @()
    if ($discoveredListBox) { $discoveredListBox.Items.Clear() }

    # Target list of the content replacement
    $script:contentReplaceApps = @()
    if ($replaceAppCombo) { $replaceAppCombo.Items.Clear() }

    # Dashboard tiles fall back to their placeholder until the next refresh delivers real numbers.
    $emDash = [System.Char]::ConvertFromUtf32(0x2014)
    foreach ($tile in @($script:dashManagedVal, $script:dashUpdatesVal, $script:dashSupersededVal)) {
      if ($tile) { $tile.Text = $emDash }
    }
    # Force the next refresh: a cooled-down snapshot would show the previous tenant's counts.
    $script:dashboardLastRefresh = [datetime]::MinValue

    Write-Log 'Tenant-specific views cleared.'
  } catch {
    Write-Log ("Clearing the tenant views failed: {0}" -f $_.Exception.Message)
  }
}

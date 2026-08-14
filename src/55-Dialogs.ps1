# Shows the session Leistungsnachweis in an editable, copyable dialog for the current tenant.
# Bulk editor for assignment settings of apps that are ALREADY in Intune: pick apps, pick the
# settings, apply. Deliberately a modal dialog rather than another nav section - it is an
# occasional maintenance task, not a daily view.
#
# "Leave unchanged" is the default everywhere: only what the user explicitly picks is written, so
# an unrelated setting can never be reset by accident.
function Show-AppSettingsDialog {
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = Get-UiString 'AppSettingsTitle'
  $dlg.ClientSize = New-Object System.Drawing.Size(720, 790)
  $dlg.MinimumSize = New-Object System.Drawing.Size(660, 730)
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)
  $dlg.ShowIcon = $false

  $intro = New-Object System.Windows.Forms.Label
  $intro.Tag = 'hint'
  $intro.Text = Get-UiString 'AppSettingsIntro'
  $intro.Location = New-Object System.Drawing.Point(12, 10)
  $intro.Size = New-Object System.Drawing.Size(696, 46)
  $intro.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $dlg.Controls.Add($intro)

  $listLabel = New-Object System.Windows.Forms.Label
  $listLabel.Text = Get-UiString 'AppSettingsListLabel'
  $listLabel.Location = New-Object System.Drawing.Point(12, 62)
  $listLabel.AutoSize = $true
  $listLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
  $dlg.Controls.Add($listLabel)

  $list = New-Object System.Windows.Forms.ListView
  $list.Location = New-Object System.Drawing.Point(12, 84)
  $list.Size = New-Object System.Drawing.Size(696, 220)
  $list.View = [System.Windows.Forms.View]::Details
  $list.CheckBoxes = $true
  $list.FullRowSelect = $true
  $list.HideSelection = $false
  $list.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
  $list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  [void]$list.Columns.Add((Get-UiString 'ColApp'), 300)
  [void]$list.Columns.Add((Get-UiString 'ColCurrentVersion'), 130)
  # Assignments are loaded per row on selection, not for the whole list: that would be one Graph
  # call per app and would make the dialog unusable in a tenant with a few hundred apps.
  [void]$list.Columns.Add((Get-UiString 'ColAssignment'), 260)
  $dlg.Controls.Add($list)

  $checkAll = New-Object System.Windows.Forms.Button
  $checkAll.Tag = 'btn-secondary'
  $checkAll.Text = Get-UiString 'CheckAllButton'
  $checkAll.Location = New-Object System.Drawing.Point(12, 312)
  $checkAll.Size = New-Object System.Drawing.Size(130, 30)
  $checkAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($checkAll)

  $uncheckAll = New-Object System.Windows.Forms.Button
  $uncheckAll.Tag = 'btn-secondary'
  $uncheckAll.Text = Get-UiString 'UncheckAllButton'
  $uncheckAll.Location = New-Object System.Drawing.Point(150, 312)
  $uncheckAll.Size = New-Object System.Drawing.Size(130, 30)
  $uncheckAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($uncheckAll)

  $reload = New-Object System.Windows.Forms.Button
  $reload.Tag = 'btn-secondary'
  $reload.Text = Get-UiString 'AppSettingsReloadButton'
  $reload.Location = New-Object System.Drawing.Point(288, 312)
  $reload.Size = New-Object System.Drawing.Size(160, 30)
  $reload.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($reload)

  # --- settings block ---
  $notifyLabel = New-Object System.Windows.Forms.Label
  $notifyLabel.Text = Get-UiString 'AppSettingsNotifyLabel'
  $notifyLabel.Location = New-Object System.Drawing.Point(12, 364)
  $notifyLabel.AutoSize = $true
  $notifyLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($notifyLabel)

  $notifyCombo = New-Object System.Windows.Forms.ComboBox
  $notifyCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $notifyCombo.Location = New-Object System.Drawing.Point(240, 361)
  $notifyCombo.Width = 300
  $notifyCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  [void]$notifyCombo.Items.AddRange(@(
    (Get-UiString 'AppSettingsNotifyKeep'),
    (Get-UiString 'AppSettingsNotifyAll'),
    (Get-UiString 'AppSettingsNotifyReboot'),
    (Get-UiString 'AppSettingsNotifyHide')))
  $notifyCombo.SelectedIndex = 0
  $dlg.Controls.Add($notifyCombo)

  # Explicit mode selectors replace the former three-state checkboxes. The indeterminate square
  # was technically correct but visually opaque; these choices state the resulting Intune action.
  $availLabel = New-Object System.Windows.Forms.Label
  $availLabel.Text = Get-UiString 'AppSettingsAvailableFrom'
  $availLabel.Location = New-Object System.Drawing.Point(12, 398)
  $availLabel.AutoSize = $true
  $availLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($availLabel)

  $availModeCombo = New-Object System.Windows.Forms.ComboBox
  $availModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $availModeCombo.Location = New-Object System.Drawing.Point(240, 395)
  $availModeCombo.Width = 160
  [void]$availModeCombo.Items.AddRange(@((Get-UiString 'AppSettingsNotifyKeep'), (Get-UiString 'AppSettingsModeAsap'), (Get-UiString 'AppSettingsModeScheduled')))
  $availModeCombo.SelectedIndex = 0
  $availModeCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($availModeCombo)

  $availPicker = New-Object System.Windows.Forms.DateTimePicker
  $availPicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
  $availPicker.CustomFormat = "dd.MM.yyyy  HH:mm"
  $availPicker.ShowUpDown = $true
  $availPicker.Location = New-Object System.Drawing.Point(410, 395)
  $availPicker.Width = 298
  $availPicker.Enabled = $false
  $availPicker.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($availPicker)
  $availModeCombo.Add_SelectedIndexChanged({ $availPicker.Enabled = ($availModeCombo.SelectedIndex -eq 2) })

  $deadlineLabel = New-Object System.Windows.Forms.Label
  $deadlineLabel.Text = Get-UiString 'AppSettingsDeadline'
  $deadlineLabel.Location = New-Object System.Drawing.Point(12, 430)
  $deadlineLabel.AutoSize = $true
  $deadlineLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($deadlineLabel)

  $deadlineModeCombo = New-Object System.Windows.Forms.ComboBox
  $deadlineModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $deadlineModeCombo.Location = New-Object System.Drawing.Point(240, 427)
  $deadlineModeCombo.Width = 160
  [void]$deadlineModeCombo.Items.AddRange(@((Get-UiString 'AppSettingsNotifyKeep'), (Get-UiString 'AppSettingsModeAsap'), (Get-UiString 'AppSettingsModeScheduled')))
  $deadlineModeCombo.SelectedIndex = 0
  $deadlineModeCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($deadlineModeCombo)

  $deadlinePicker = New-Object System.Windows.Forms.DateTimePicker
  $deadlinePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
  $deadlinePicker.CustomFormat = "dd.MM.yyyy  HH:mm"
  $deadlinePicker.ShowUpDown = $true
  $deadlinePicker.Location = New-Object System.Drawing.Point(410, 427)
  $deadlinePicker.Width = 298
  $deadlinePicker.Enabled = $false
  $deadlinePicker.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($deadlinePicker)
  $deadlineModeCombo.Add_SelectedIndexChanged({ $deadlinePicker.Enabled = ($deadlineModeCombo.SelectedIndex -eq 2) })

  $localTimeCheck = New-Object System.Windows.Forms.CheckBox
  $localTimeCheck.Text = Get-UiString 'AppSettingsUseLocalTime'
  $localTimeCheck.Location = New-Object System.Drawing.Point(12, 462)
  $localTimeCheck.AutoSize = $true
  $localTimeCheck.Checked = $true
  $localTimeCheck.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($localTimeCheck)

  $restartModeLabel = New-Object System.Windows.Forms.Label
  $restartModeLabel.Text = Get-UiString 'AppSettingsRestartEnable'
  $restartModeLabel.Location = New-Object System.Drawing.Point(12, 496)
  $restartModeLabel.AutoSize = $true
  $restartModeLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($restartModeLabel)

  $restartModeCombo = New-Object System.Windows.Forms.ComboBox
  $restartModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $restartModeCombo.Location = New-Object System.Drawing.Point(240, 491)
  $restartModeCombo.Width = 300
  [void]$restartModeCombo.Items.AddRange(@((Get-UiString 'AppSettingsNotifyKeep'), (Get-UiString 'AppSettingsModeDisabled'), (Get-UiString 'AppSettingsModeEnabled')))
  $restartModeCombo.SelectedIndex = 0
  $restartModeCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($restartModeCombo)

  $restartGraceLabel = New-Object System.Windows.Forms.Label
  $restartGraceLabel.Text = Get-UiString 'AppSettingsRestartGrace'
  $restartGraceLabel.Location = New-Object System.Drawing.Point(32, 524)
  $restartGraceLabel.AutoSize = $true
  $restartGraceLabel.Enabled = $false
  $restartGraceLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($restartGraceLabel)
  $restartGraceValue = New-Object System.Windows.Forms.NumericUpDown
  $restartGraceValue.Location = New-Object System.Drawing.Point(240, 521)
  $restartGraceValue.Width = 110
  $restartGraceValue.Minimum = 1
  $restartGraceValue.Maximum = 20160
  $restartGraceValue.Value = 1440
  $restartGraceValue.Enabled = $false
  $restartGraceValue.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($restartGraceValue)

  $restartCountdownLabel = New-Object System.Windows.Forms.Label
  $restartCountdownLabel.Text = Get-UiString 'AppSettingsRestartCountdown'
  $restartCountdownLabel.Location = New-Object System.Drawing.Point(32, 556)
  $restartCountdownLabel.AutoSize = $true
  $restartCountdownLabel.Enabled = $false
  $restartCountdownLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($restartCountdownLabel)
  $restartCountdownValue = New-Object System.Windows.Forms.NumericUpDown
  $restartCountdownValue.Location = New-Object System.Drawing.Point(240, 553)
  $restartCountdownValue.Width = 110
  $restartCountdownValue.Minimum = 1
  $restartCountdownValue.Maximum = 20160
  $restartCountdownValue.Value = 15
  $restartCountdownValue.Enabled = $false
  $restartCountdownValue.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($restartCountdownValue)

  $restartSnoozeCheck = New-Object System.Windows.Forms.CheckBox
  $restartSnoozeCheck.Text = Get-UiString 'AppSettingsRestartSnooze'
  $restartSnoozeCheck.Location = New-Object System.Drawing.Point(380, 524)
  $restartSnoozeCheck.AutoSize = $true
  $restartSnoozeCheck.Checked = $true
  $restartSnoozeCheck.Enabled = $false
  $restartSnoozeCheck.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($restartSnoozeCheck)
  $restartSnoozeLabel = New-Object System.Windows.Forms.Label
  $restartSnoozeLabel.Text = Get-UiString 'AppSettingsRestartSnoozeMinutes'
  $restartSnoozeLabel.Location = New-Object System.Drawing.Point(380, 556)
  $restartSnoozeLabel.AutoSize = $true
  $restartSnoozeLabel.Enabled = $false
  $restartSnoozeLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($restartSnoozeLabel)
  $restartSnoozeValue = New-Object System.Windows.Forms.NumericUpDown
  $restartSnoozeValue.Location = New-Object System.Drawing.Point(570, 553)
  $restartSnoozeValue.Width = 110
  $restartSnoozeValue.Minimum = 1
  $restartSnoozeValue.Maximum = 20160
  $restartSnoozeValue.Value = 240
  $restartSnoozeValue.Enabled = $false
  $restartSnoozeValue.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($restartSnoozeValue)

  $restartModeCombo.Add_SelectedIndexChanged({
    $enabled = ($restartModeCombo.SelectedIndex -eq 2)
    $restartGraceLabel.Enabled = $enabled; $restartGraceValue.Enabled = $enabled
    $restartCountdownLabel.Enabled = $enabled; $restartCountdownValue.Enabled = $enabled
    $restartSnoozeCheck.Enabled = $enabled; $restartSnoozeLabel.Enabled = $enabled
    $restartSnoozeValue.Enabled = ($enabled -and $restartSnoozeCheck.Checked)
  })
  $restartSnoozeCheck.Add_CheckedChanged({ $restartSnoozeValue.Enabled = ($restartModeCombo.SelectedIndex -eq 2 -and $restartSnoozeCheck.Checked) })

  $deliveryLabel = New-Object System.Windows.Forms.Label
  $deliveryLabel.Text = Get-UiString 'AppSettingsDeliveryPriority'
  $deliveryLabel.Location = New-Object System.Drawing.Point(12, 594)
  $deliveryLabel.AutoSize = $true
  $deliveryLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($deliveryLabel)
  $deliveryCombo = New-Object System.Windows.Forms.ComboBox
  $deliveryCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $deliveryCombo.Location = New-Object System.Drawing.Point(240, 591)
  $deliveryCombo.Width = 300
  [void]$deliveryCombo.Items.AddRange(@((Get-UiString 'AppSettingsDeliveryKeep'), (Get-UiString 'AppSettingsDeliveryBackground'), (Get-UiString 'AppSettingsDeliveryForeground')))
  $deliveryCombo.SelectedIndex = 0
  $deliveryCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($deliveryCombo)

  $autoUpdLabel = New-Object System.Windows.Forms.Label
  $autoUpdLabel.Text = Get-UiString 'AppSettingsAutoUpdate'
  $autoUpdLabel.Location = New-Object System.Drawing.Point(12, 626)
  $autoUpdLabel.Size = New-Object System.Drawing.Size(376, 38)
  $autoUpdLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($autoUpdLabel)

  $autoUpdModeCombo = New-Object System.Windows.Forms.ComboBox
  $autoUpdModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $autoUpdModeCombo.Location = New-Object System.Drawing.Point(400, 629)
  $autoUpdModeCombo.Width = 140
  [void]$autoUpdModeCombo.Items.AddRange(@((Get-UiString 'AppSettingsNotifyKeep'), (Get-UiString 'AppSettingsModeDisabled'), (Get-UiString 'AppSettingsModeEnabled')))
  $autoUpdModeCombo.SelectedIndex = 0
  $autoUpdModeCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($autoUpdModeCombo)

  $applyButton = New-Object System.Windows.Forms.Button
  $applyButton.Text = Get-UiString 'AppSettingsApplyButton'
  $applyButton.Location = New-Object System.Drawing.Point(12, 674)
  $applyButton.Size = New-Object System.Drawing.Size(260, 34)
  $applyButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($applyButton)

  $closeButton = New-Object System.Windows.Forms.Button
  $closeButton.Tag = 'btn-secondary'
  $closeButton.Text = Get-UiString 'AppSettingsCloseButton'
  $closeButton.Location = New-Object System.Drawing.Point(284, 674)
  $closeButton.Size = New-Object System.Drawing.Size(140, 34)
  $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $closeButton.Add_Click({ $dlg.Close() })
  $dlg.Controls.Add($closeButton)

  $dlgStatus = New-Object System.Windows.Forms.Label
  $dlgStatus.Tag = 'hint'
  $dlgStatus.Location = New-Object System.Drawing.Point(12, 718)
  $dlgStatus.Size = New-Object System.Drawing.Size(696, 32)
  $dlgStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $dlg.Controls.Add($dlgStatus)

  # Apps are held on the rows themselves (.Tag), the same pattern the discovered list uses -
  # no fragile name matching.
  $loadApps = {
    $dlgStatus.Text = Get-UiString 'AppSettingsLoadingStatus'
    [System.Windows.Forms.Application]::DoEvents()
    $list.Items.Clear()
    try {
      $apps = @(Get-CachedWin32Apps | Sort-Object Name)
      foreach ($a in $apps) {
        if (-not $a -or -not $a.Name) { continue }
        $it = New-Object System.Windows.Forms.ListViewItem([string]$a.Name)
        [void]$it.SubItems.Add([string]$a.CurrentVersion)
        [void]$it.SubItems.Add((Get-UiString 'AssignmentNotLoaded'))
        $it.Tag = $a
        [void]$list.Items.Add($it)
      }
      $dlgStatus.Text = ''
      Write-Log ("App settings dialog: loaded {0} managed app(s)." -f $list.Items.Count)
    } catch {
      $dlgStatus.Text = $_.Exception.Message
      Write-Log ("App settings dialog: loading apps failed: {0}" -f $_.Exception.Message)
    }
  }

  # Selecting a row fetches that app's real assignments once and keeps them. Without this the
  # dialog let you change delivery settings without ever seeing WHO the app is assigned to.
  $list.Add_SelectedIndexChanged({
    if ($list.SelectedItems.Count -eq 0) { return }
    $row = $list.SelectedItems[0]
    if ($row.SubItems.Count -lt 3) { return }
    if ($row.SubItems[2].Text -ne (Get-UiString 'AssignmentNotLoaded')) { return }   # already fetched
    $app = $row.Tag
    if (-not $app -or -not $app.GraphId) { return }
    try {
      $row.SubItems[2].Text = Get-UiString 'AssignmentLoading'
      [System.Windows.Forms.Application]::DoEvents()
      # One line per assignment would not fit a list cell, so they are joined with " / ".
      $text = (Get-TenantAppAssignmentText -AppId ([string]$app.GraphId)) -replace "`r`n", ' / '
      $row.SubItems[2].Text = $text
    } catch {
      $row.SubItems[2].Text = Get-UiString 'AssignmentLoadFailed'
      Write-Log ("App settings dialog: assignments for '{0}' could not be read: {1}" -f $app.Name, $_.Exception.Message)
    }
  })

  $checkAll.Add_Click({ foreach ($r in $list.Items) { $r.Checked = $true } })
  $uncheckAll.Add_Click({ foreach ($r in $list.Items) { $r.Checked = $false } })
  $reload.Add_Click({ & $loadApps })

  $applyButton.Add_Click({
    $checked = @($list.Items | Where-Object { $_.Checked })
    if ($checked.Count -eq 0) {
      [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'AppSettingsNoSelection'), (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
      return
    }

    # Build the settings from what the user actually touched - untouched controls write nothing.
    # NICHT `$args nennen: das ist in einem Event-Handler die automatische Argumentliste.
    $setArgs = @{}
    switch ($notifyCombo.SelectedIndex) {
      1 { $setArgs.Notifications = 'showAll' }
      2 { $setArgs.Notifications = 'showReboot' }
      3 { $setArgs.Notifications = 'hideAll' }
    }
    if ($availModeCombo.SelectedIndex -eq 1) { $setArgs.ClearAvailableFrom = $true }
    elseif ($availModeCombo.SelectedIndex -eq 2) { $setArgs.AvailableFrom = $availPicker.Value }
    if ($deadlineModeCombo.SelectedIndex -eq 1) { $setArgs.ClearDeadline = $true }
    elseif ($deadlineModeCombo.SelectedIndex -eq 2) { $setArgs.Deadline = $deadlinePicker.Value }
    if ($availModeCombo.SelectedIndex -ne 0 -or $deadlineModeCombo.SelectedIndex -ne 0) {
      $setArgs.UseLocalTime = [bool]$localTimeCheck.Checked
    }
    if ($restartModeCombo.SelectedIndex -eq 2) {
      $grace = [int]$restartGraceValue.Value
      $countdown = [int]$restartCountdownValue.Value
      $snooze = if ($restartSnoozeCheck.Checked) { [int]$restartSnoozeValue.Value } else { 0 }
      if ($countdown -gt $grace -or $snooze -gt $grace) {
        [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'AppSettingsRestartInvalid'), (Get-UiString 'ValidationTitle'),
          [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
      }
      $setArgs.RestartGraceMinutes = $grace
      $setArgs.RestartCountdownMinutes = $countdown
      $setArgs.RestartSnoozeMinutes = $snooze
    } elseif ($restartModeCombo.SelectedIndex -eq 1) {
      $setArgs.DisableRestartGrace = $true
    }
    if ($deliveryCombo.SelectedIndex -eq 1) { $setArgs.DeliveryOptimizationPriority = 'notConfigured' }
    elseif ($deliveryCombo.SelectedIndex -eq 2) { $setArgs.DeliveryOptimizationPriority = 'foreground' }
    if ($autoUpdModeCombo.SelectedIndex -eq 2) { $setArgs.AutoUpdateSuperseded = 'enabled' }
    elseif ($autoUpdModeCombo.SelectedIndex -eq 1) { $setArgs.AutoUpdateSuperseded = 'notConfigured' }

    $settings = New-AssignmentSettingsObject @setArgs
    $summary = Get-AssignmentSettingsSummary $settings
    if ($summary -eq '(nothing to change)') {
      [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'AppSettingsNoChange'), (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
      return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'AppSettingsConfirm') -f $checked.Count, $summary),
      (Get-UiString 'ConfirmTitle'),
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $applyButton.Enabled = $false
    $ok = 0; $skipped = 0; $failed = 0; $i = 0
    foreach ($row in $checked) {
      $i++
      $app = $row.Tag
      $dlgStatus.Text = ((Get-UiString 'AppSettingsApplyingStatus') -f $i, $checked.Count, $app.Name)
      [System.Windows.Forms.Application]::DoEvents()
      $res = Set-AppAssignmentSettings -AppId ([string]$app.GraphId) -Settings $settings -AppName ([string]$app.Name)
      if     ($res.ErrorMessage) { $failed++ }
      elseif ($res.Skipped)      { $skipped++ }
      else                       { $ok++ }
    }
    $applyButton.Enabled = $true
    $msg = (Get-UiString 'AppSettingsDoneStatus') -f $ok, $skipped, $failed
    $dlgStatus.Text = $msg
    Update-Status $msg
    Write-Log $msg
  })

  Set-GuiTheme -control $dlg -theme $script:currentTheme
  $dlg.Add_Shown({ & $loadApps })
  [void]$dlg.ShowDialog()
  $dlg.Dispose()
}

function Show-LeistungstextDialog {
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = Get-UiString 'LeistungDialogTitle'
  $dlg.ClientSize = New-Object System.Drawing.Size(584, 430)
  $dlg.MinimumSize = New-Object System.Drawing.Size(460, 360)
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

  # Language selector for the record itself (independent of the app UI language).
  $langLabel = New-Object System.Windows.Forms.Label
  $langLabel.Text = Get-UiString 'LeistungLangLabel'
  $langLabel.Location = New-Object System.Drawing.Point(10, 14)
  $langLabel.AutoSize = $true
  $langLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($langLabel)

  $langCombo = New-Object System.Windows.Forms.ComboBox
  $langCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $langCombo.Location = New-Object System.Drawing.Point(185, 11)
  $langCombo.Width = 130
  $langCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
  [void]$langCombo.Items.AddRange(@("Deutsch", "English"))
  $langCombo.SelectedIndex = if ($script:leistungLang -eq 'en') { 1 } else { 0 }
  $dlg.Controls.Add($langCombo)

  # The record is normally written into a ticket after the work - often after the GUI was closed.
  # The previous session is therefore selectable here, read from the file written during that run.
  $sessionCombo = New-Object System.Windows.Forms.ComboBox
  $sessionCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $sessionCombo.Location = New-Object System.Drawing.Point(325, 11)
  $sessionCombo.Width = 200
  $sessionCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
  [void]$sessionCombo.Items.AddRange(@((Get-UiString 'LeistungSessionCurrent'), (Get-UiString 'LeistungSessionPrevious')))
  $sessionCombo.SelectedIndex = if ($script:leistungShowPrevious) { 1 } else { 0 }
  $dlg.Controls.Add($sessionCombo)
  $sessionCombo.Add_SelectedIndexChanged({
    $script:leistungShowPrevious = ($sessionCombo.SelectedIndex -eq 1)
    $box.Text = Get-SessionLeistungstext
    $header.Text = Get-SessionLeistungsHeader
  })

  $header = New-Object System.Windows.Forms.Label
  $header.Tag = 'hint'
  $header.Location = New-Object System.Drawing.Point(10,44)
  $header.Size = New-Object System.Drawing.Size(564, 66)
  $header.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $header.Text = Get-SessionLeistungsHeader
  $dlg.Controls.Add($header)

  $box = New-Object System.Windows.Forms.TextBox
  $box.Multiline = $true
  $box.ScrollBars = "Vertical"
  $box.Font = New-Object System.Drawing.Font("Consolas", 9)
  $box.Location = New-Object System.Drawing.Point(10,116)
  $box.Size = New-Object System.Drawing.Size(564, 256)
  $box.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $box.Text = Get-SessionLeistungstext
  $dlg.Controls.Add($box)

  # NOTE: plain scriptblock (NO .GetNewClosure()) – a closure snapshots variables but loses access
  # to script-scope functions, so Get-SessionLeistungstext failed with "not recognized". A plain
  # handler keeps both the captured locals ($langCombo/$box) and the script functions in scope.
  $langCombo.Add_SelectedIndexChanged({
    $script:leistungLang = if ($langCombo.SelectedIndex -eq 1) { 'en' } else { 'de' }
    $header.Text = Get-SessionLeistungsHeader
    $box.Text = Get-SessionLeistungstext
  })

  $copyButton = New-Object System.Windows.Forms.Button
  $copyButton.Text = Get-UiString 'LeistungCopyButton'
  $copyButton.Location = New-Object System.Drawing.Point(10, 384)
  $copyButton.Width = 230
  $copyButton.Height = 32
  $copyButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $copyButton.Add_Click({
    try { [System.Windows.Forms.Clipboard]::SetText($box.Text) ; $copyButton.Text = Get-UiString 'LeistungCopiedButton' } catch { Write-Log "Clipboard copy failed: $($_.Exception.Message)" }
  })
  $dlg.Controls.Add($copyButton)

  $clearButton = New-Object System.Windows.Forms.Button
  $clearButton.Tag = 'btn-secondary'
  $clearButton.Text = Get-UiString 'LeistungClearButton'
  $clearButton.Location = New-Object System.Drawing.Point(250, 384)
  $clearButton.Width = 180
  $clearButton.Height = 32
  $clearButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $clearButton.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'LeistungClearConfirm'),
      (Get-UiString 'LeistungClearTitle'),
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
      $script:sessionActivity.Clear()
      $header.Text = Get-SessionLeistungsHeader
      $box.Text = Get-SessionLeistungstext
    }
  })
  $dlg.Controls.Add($clearButton)

  $closeButton = New-Object System.Windows.Forms.Button
  $closeButton.Text = Get-UiString 'CloseButton'
  $closeButton.Location = New-Object System.Drawing.Point(454, 384)
  $closeButton.Width = 120
  $closeButton.Height = 32
  $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
  $closeButton.Add_Click({ $dlg.Close() })
  $dlg.Controls.Add($closeButton)

  Set-GuiTheme -control $dlg -theme $script:currentTheme
  [void]$dlg.ShowDialog()
}

function Show-StorePickerDialog {
  param(
    [Parameter(Mandatory)][array]$Results,
    # Overridable so the same two-column picker can serve the Entra group lookup instead of
    # duplicating an identical dialog with different captions.
    [string]$TitleKey = 'StorePickerTitle',
    [string]$HintKey = 'StorePickerHint',
    [string]$NameColumnKey = 'StoreColName',
    [string]$IdColumnKey = 'StoreColPackageId'
  )

  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = Get-UiString $TitleKey
  $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.MinimizeBox = $false
  $dlg.MaximizeBox = $false
  $dlg.ClientSize = New-Object System.Drawing.Size(560, 400)

  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = Get-UiString $HintKey
  $hint.Location = New-Object System.Drawing.Point(14, 12)
  $hint.Size = New-Object System.Drawing.Size(532, 32)
  $dlg.Controls.Add($hint)

  $list = New-Object System.Windows.Forms.ListView
  $list.Location = New-Object System.Drawing.Point(14, 50)
  $list.Size = New-Object System.Drawing.Size(532, 300)
  $list.View = [System.Windows.Forms.View]::Details
  $list.FullRowSelect = $true
  $list.MultiSelect = $false
  $list.HideSelection = $false
  $list.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
  [void]$list.Columns.Add((Get-UiString $NameColumnKey), 330)
  [void]$list.Columns.Add((Get-UiString $IdColumnKey), 190)
  foreach ($entry in $Results) {
    $row = New-Object System.Windows.Forms.ListViewItem([string]$entry.Name)
    [void]$row.SubItems.Add([string]$entry.PackageIdentifier)
    $row.Tag = $entry
    [void]$list.Items.Add($row)
  }
  if ($list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
  $dlg.Controls.Add($list)

  $okButton = New-Object System.Windows.Forms.Button
  $okButton.Text = Get-UiString 'OkButton'
  $okButton.Location = New-Object System.Drawing.Point(366, 360)
  $okButton.Size = New-Object System.Drawing.Size(86, 30)
  $okButton.Add_Click({
    if ($list.SelectedItems.Count -gt 0) { $dlg.Tag = $list.SelectedItems[0].Tag }
    $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Close()
  })
  $dlg.Controls.Add($okButton)

  # Double-clicking a row is the same as selecting it and confirming.
  $list.Add_DoubleClick({ $okButton.PerformClick() })

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Tag = 'btn-secondary'
  $cancelButton.Text = Get-UiString 'CancelButton'
  $cancelButton.Location = New-Object System.Drawing.Point(460, 360)
  $cancelButton.Size = New-Object System.Drawing.Size(86, 30)
  $cancelButton.Add_Click({
    $dlg.Tag = $null
    $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Close()
  })
  $dlg.Controls.Add($cancelButton)

  $dlg.AcceptButton = $okButton
  $dlg.CancelButton = $cancelButton
  Set-GuiTheme -control $dlg -theme $script:currentTheme
  $result = $dlg.ShowDialog()
  $picked = if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $dlg.Tag } else { $null }
  $dlg.Dispose()
  return $picked
}

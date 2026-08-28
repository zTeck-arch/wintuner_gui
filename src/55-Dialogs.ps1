# Shows the session Leistungsnachweis in an editable, copyable dialog for the current tenant.
# Bulk editor for assignment settings of apps that are ALREADY in Intune: pick apps, pick the
# settings, apply. Deliberately a modal dialog rather than another nav section - it is an
# occasional maintenance task, not a daily view.
#
# "Leave unchanged" is the default everywhere: only what the user explicitly picks is written, so
# an unrelated setting can never be reset by accident.
#
# -PreselectApp (optional): a tenant app object with .Id. When given, that app is pre-checked and
# selected once the list has loaded, so the caller can open the dialog "for one app" without ever
# touching assignment targets - the dialog only ever writes settings, never rewrites targets.
function Show-AppSettingsDialog {
  param(
    [object]$PreselectApp,
    # Wird ein Panel uebergeben, baut die Funktion ihren Inhalt DORT hinein statt in ein eigenes
    # Fenster: derselbe Editor als fester Bereich in der Seitenleiste. Alles dazwischen ist
    # identisch - die Steuerelemente kennen nur ein Elternobjekt, keinen Fenstertyp.
    [System.Windows.Forms.Control]$HostPanel
  )
  $embedded = [bool]$HostPanel
  if ($embedded) {
    $dlg = $HostPanel
  } else {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = Get-UiString 'AppSettingsTitle'
    $dlg.ClientSize = New-Object System.Drawing.Size(720, 790)
    $dlg.MinimumSize = New-Object System.Drawing.Size(660, 730)
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dlg.ShowIcon = $false
  }

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

  # Suchfeld. In einem Tenant mit dreistelliger App-Zahl ist Scrollen die falsche Antwort auf
  # "ich will die drei Firefox-Objekte markieren".
  $filterBox = New-Object System.Windows.Forms.TextBox
  $filterBox.PlaceholderText = Get-UiString 'AppSettingsFilterPlaceholder'
  $filterBox.Location = New-Object System.Drawing.Point(240, 60)
  $filterBox.Width = 300
  $dlg.Controls.Add($filterBox)

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

  # Reihenfolge nach Arbeitsablauf: erst die Liste holen, dann darin auswaehlen. Als Bereich in der
  # Seitenleiste ist die Liste beim Oeffnen leer, solange keine Verbindung besteht - "alle
  # auswaehlen" an erster Stelle hat dort auf eine leere Liste gezeigt.
  $reload = New-Object System.Windows.Forms.Button
  $reload.Tag = 'btn-secondary'
  $reload.Text = Get-UiString 'AppSettingsReloadButton'
  $reload.Location = New-Object System.Drawing.Point(12, 312)
  $reload.Size = New-Object System.Drawing.Size(160, 30)
  $reload.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($reload)

  $checkAll = New-Object System.Windows.Forms.Button
  $checkAll.Tag = 'btn-secondary'
  $checkAll.Text = Get-UiString 'CheckAllButton'
  $checkAll.Location = New-Object System.Drawing.Point(182, 312)
  $checkAll.Size = New-Object System.Drawing.Size(130, 30)
  $checkAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($checkAll)

  $uncheckAll = New-Object System.Windows.Forms.Button
  $uncheckAll.Tag = 'btn-secondary'
  $uncheckAll.Text = Get-UiString 'UncheckAllButton'
  $uncheckAll.Location = New-Object System.Drawing.Point(320, 312)
  $uncheckAll.Size = New-Object System.Drawing.Size(130, 30)
  $uncheckAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $dlg.Controls.Add($uncheckAll)

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
  # WARUM JEDES EREIGNIS HIER UEBER $script:appSettingsUi GEHT
  #
  # Als eingebetteter Bereich wird diese Funktion einmal beim Aufbau des Fensters durchlaufen und
  # kehrt sofort zurueck. Danach sind ihre lokalen Variablen weg, und jedes Ereignis, das spaeter
  # feuert, sah $null - genau das waren die beiden Meldungen aus dem Protokoll:
  #   "App settings load failed: The property 'Text' cannot be found on this object."
  #   "FATAL UI ERROR: The expression after '&' ... must result in a command name, a script block".
  #
  # .GetNewClosure() waere der naheliegende Griff und ist hier trotzdem falsch: eine Closure haelt
  # zwar die Steuerelemente fest, bindet den Block aber an ein dynamisches Modul. Dort zeigt
  # $script: nicht mehr auf das Hauptskript, und die Funktionen des Skripts (Get-UiString,
  # Write-Log, ...) werden nur gefunden, solange das Skript zufaellig das oberste ist - wird es aus
  # einem anderen Skript heraus aufgerufen, meldet jedes Ereignis "Get-UiString is not recognized".
  # Dieselbe Falle steht schon einmal weiter unten bei Show-LeistungstextDialog beschrieben.
  #
  # Deshalb: einfache Skriptbloecke (die finden Funktionen und $script: zuverlaessig) und die
  # Steuerelemente in EINEM Beutel im Skript-Bereich. Der modale Dialog legt seinen eigenen Beutel
  # an und stellt den vorherigen beim Schliessen zurueck (siehe unten), sonst haetten die Ereignisse
  # des eingebetteten Bereichs danach auf die verworfenen Steuerelemente des Dialogs gezeigt.
  $availModeCombo.Add_SelectedIndexChanged({
    $ui = $script:appSettingsUi
    $ui.AvailPicker.Enabled = ($ui.AvailModeCombo.SelectedIndex -eq 2)
  })

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
  $deadlineModeCombo.Add_SelectedIndexChanged({
    $ui = $script:appSettingsUi
    $ui.DeadlinePicker.Enabled = ($ui.DeadlineModeCombo.SelectedIndex -eq 2)
  })

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
  Set-LabelDimmed -Label $restartGraceLabel -Dimmed $true
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
  Set-LabelDimmed -Label $restartCountdownLabel -Dimmed $true
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
  Set-LabelDimmed -Label $restartSnoozeLabel -Dimmed $true
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
    $ui = $script:appSettingsUi
    $enabled = ($ui.RestartModeCombo.SelectedIndex -eq 2)
    # Beschriftungen werden GEDAEMPFT, nicht deaktiviert: WinForms zeichnet eine deaktivierte
    # Label in SystemColors.GrayText und ignoriert dabei jede Designfarbe (siehe 65-Theme).
    Set-LabelDimmed -Label $ui.RestartGraceLabel -Dimmed (-not $enabled)
    Set-LabelDimmed -Label $ui.RestartCountdownLabel -Dimmed (-not $enabled)
    Set-LabelDimmed -Label $ui.RestartSnoozeLabel -Dimmed (-not $enabled)
    $ui.RestartGraceValue.Enabled = $enabled
    $ui.RestartCountdownValue.Enabled = $enabled
    $ui.RestartSnoozeCheck.Enabled = $enabled
    $ui.RestartSnoozeValue.Enabled = ($enabled -and $ui.RestartSnoozeCheck.Checked)
  })
  $restartSnoozeCheck.Add_CheckedChanged({
    $ui = $script:appSettingsUi
    $ui.RestartSnoozeValue.Enabled = ($ui.RestartModeCombo.SelectedIndex -eq 2 -and $ui.RestartSnoozeCheck.Checked)
  })

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
  # 240 wie alle anderen: die Auswahllisten dieser Karte stehen in einer Flucht. Diese eine stand
  # auf 400, weil ihre Beschriftung 314 px breit war - die ist jetzt gekuerzt.
  $autoUpdModeCombo.Location = New-Object System.Drawing.Point(240, 629)
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
  # Einen Bereich schliesst man nicht - im eingebetteten Fall verschwindet der Knopf.
  if ($embedded) { $closeButton.Visible = $false } else { $closeButton.Add_Click({ $script:appSettingsUi.Dlg.Close() }) }
  $dlg.Controls.Add($closeButton)

  $dlgStatus = New-Object System.Windows.Forms.Label
  $dlgStatus.Tag = 'hint'
  $dlgStatus.Location = New-Object System.Drawing.Point(12, 718)
  $dlgStatus.Size = New-Object System.Drawing.Size(696, 32)
  $dlgStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $dlg.Controls.Add($dlgStatus)

  # Der Zustandsbeutel dieser Ausgabe des Editors. Alles, was ein Ereignis anfassen muss, steht
  # hier - Ereignisse laufen lange nachdem diese Funktion zurueckgekehrt ist (siehe oben).
  $previousAppSettingsUi = $script:appSettingsUi
  $script:appSettingsUi = @{
    Dlg                   = $dlg
    Embedded              = $embedded
    Intro                 = $intro
    ListLabel             = $listLabel
    FilterBox             = $filterBox
    List                  = $list
    AllApps               = @()
    # Die Auswahl wird an der Graph-Id gemerkt, nicht an der Zeile: sonst verliert jeder Filter die
    # Haken der gerade ausgeblendeten Apps - gefunden von der eigenen Messung, nicht im Code gesehen.
    CheckedIds            = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # Gelesene Zuweisungstexte je Graph-Id. Ueberlebt jeden Filterwechsel (der die Zeilen neu baut)
    # und verhindert, dass dieselbe App zweimal aus Intune gelesen wird.
    AssignmentText        = @{}
    AssignmentsLoading    = $false
    Rebuilding            = $false
    Reload                = $reload
    CheckAll              = $checkAll
    UncheckAll            = $uncheckAll
    Status                = $dlgStatus
    PreselectApp          = $PreselectApp
    ApplyButton           = $applyButton
    CloseButton           = $closeButton
    NotifyLabel           = $notifyLabel
    AvailLabel            = $availLabel
    DeadlineLabel         = $deadlineLabel
    RestartModeLabel      = $restartModeLabel
    DeliveryLabel         = $deliveryLabel
    AutoUpdLabel          = $autoUpdLabel
    NotifyCombo           = $notifyCombo
    AvailModeCombo        = $availModeCombo
    AvailPicker           = $availPicker
    DeadlineModeCombo     = $deadlineModeCombo
    DeadlinePicker        = $deadlinePicker
    LocalTimeCheck        = $localTimeCheck
    RestartModeCombo      = $restartModeCombo
    RestartGraceLabel     = $restartGraceLabel
    RestartGraceValue     = $restartGraceValue
    RestartCountdownLabel = $restartCountdownLabel
    RestartCountdownValue = $restartCountdownValue
    RestartSnoozeCheck    = $restartSnoozeCheck
    RestartSnoozeLabel    = $restartSnoozeLabel
    RestartSnoozeValue    = $restartSnoozeValue
    DeliveryCombo         = $deliveryCombo
    AutoUpdModeCombo      = $autoUpdModeCombo
  }

  # Apps are held on the rows themselves (.Tag), the same pattern the discovered list uses -
  # no fragile name matching.
  $loadApps = {
    $ui = $script:appSettingsUi
    $list = $ui.List
    $dlgStatus = $ui.Status
    $dlgStatus.Text = Get-UiString 'AppSettingsLoadingStatus'
    [System.Windows.Forms.Application]::DoEvents()
    $list.Items.Clear()
    try {
      $apps = @(Get-CachedWin32Apps | Sort-Object Name)
      # Die vollstaendige Liste bleibt im Beutel; angezeigt wird, was der Filter durchlaesst.
      $ui.AllApps = $apps
      # "Neu laden" soll auch die Zuweisungen neu lesen - sonst blieben gemerkte Fehlschlaege stehen.
      if ($ui.AssignmentText) { $ui.AssignmentText.Clear() }
      Update-AppSettingsListRows
      $dlgStatus.Text = ''
      Write-Log ("App settings dialog: loaded {0} managed app(s)." -f @($apps).Count)
      # Die Spalte "Zuweisung" stand auf "(zum Laden anklicken)" - eine Liste, die ihre wichtigste
      # Auskunft erst nach einem Klick je Zeile herausgibt. Sie wird jetzt von selbst gefuellt.
      Update-AppSettingsAssignments
      if ($ui.PreselectApp -and $ui.PreselectApp.Id) {
        $wanted = [string]$ui.PreselectApp.Id
        foreach ($it in $list.Items) {
          if ([string]$it.Tag.GraphId -eq $wanted) {
            $it.Checked = $true
            $it.Selected = $true    # triggers SelectedIndexChanged, which loads this app's assignments
            $it.EnsureVisible()
            break
          }
        }
      }
    } catch {
      $dlgStatus.Text = $_.Exception.Message
      Write-Log ("App settings dialog: loading apps failed: {0}" -f $_.Exception.Message)
    }
  }

  # Selecting a row fetches that app's real assignments once and keeps them. Without this the
  # dialog let you change delivery settings without ever seeing WHO the app is assigned to.
  $list.Add_SelectedIndexChanged({
    $list = $script:appSettingsUi.List
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
      $script:appSettingsUi.AssignmentText[[string]$app.GraphId] = $text
    } catch {
      $row.SubItems[2].Text = Get-UiString 'AssignmentLoadFailed'
      Write-Log ("App settings dialog: assignments for '{0}' could not be read: {1}" -f $app.Name, $_.Exception.Message)
    }
  })

  # Tippen filtert sofort. Die Haken bleiben: gemerkt wird die Graph-Id, nicht die Zeilennummer -
  # sonst waere jede Auswahl beim ersten Buchstaben weg.
  $filterBox.Add_TextChanged({ Update-AppSettingsListRows })

  # "Alle" heisst: alle SICHTBAREN. Bei aktivem Filter waere alles andere eine Falle - man sieht
  # zehn Zeilen und aendert dreihundert Apps.
  $checkAll.Add_Click({
    foreach ($r in $script:appSettingsUi.List.Items) { $r.Checked = $true }
    Sync-AppSettingsChecked
  })
  $uncheckAll.Add_Click({
    foreach ($r in $script:appSettingsUi.List.Items) { $r.Checked = $false }
    Sync-AppSettingsChecked
  })
  # Ein Klick auf ein Kaestchen landet sofort in der gemerkten Auswahl.
  $list.Add_ItemChecked({ Sync-AppSettingsChecked })
  # Der Ladeblock liegt im Beutel, nicht in einer lokalen Variablen: der Knopf wird lange nach dem
  # Ende dieser Funktion gedrueckt, und "& $loadApps" traf dann auf $null.
  $reload.Add_Click({ & $script:appSettingsUi.LoadApps })

  $applyButton.Add_Click({
    $ui = $script:appSettingsUi
    $list = $ui.List; $dlgStatus = $ui.Status; $applyButton = $ui.ApplyButton
    $notifyCombo = $ui.NotifyCombo
    $availModeCombo = $ui.AvailModeCombo; $availPicker = $ui.AvailPicker
    $deadlineModeCombo = $ui.DeadlineModeCombo; $deadlinePicker = $ui.DeadlinePicker
    $localTimeCheck = $ui.LocalTimeCheck
    $restartModeCombo = $ui.RestartModeCombo
    $restartGraceValue = $ui.RestartGraceValue; $restartCountdownValue = $ui.RestartCountdownValue
    $restartSnoozeCheck = $ui.RestartSnoozeCheck; $restartSnoozeValue = $ui.RestartSnoozeValue
    $deliveryCombo = $ui.DeliveryCombo; $autoUpdModeCombo = $ui.AutoUpdModeCombo

    # Ausgewaehlt ist, was gemerkt ist - auch Apps, die der Filter gerade ausblendet.
    $checked = @(Get-AppSettingsSelectedApps)
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
    foreach ($app in $checked) {
      $i++
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

  $script:appSettingsUi.LoadApps = $loadApps

  Set-GuiTheme -control $dlg -theme $script:currentTheme
  Update-AppSettingsEditorLayout
  if ($embedded) {
    # NICHT sofort laden: das fragt Intune ab, und beim Aufbau des Fensters ist niemand angemeldet.
    # Show-Section holt das nach, sobald der Bereich geoeffnet wird und eine Sitzung besteht.
    $script:appSettingsLoad = $loadApps
    return
  }
  # Der modale Dialog blockiert den eingebetteten Bereich, solange er offen ist; danach muss dessen
  # Beutel zurueck, sonst zeigen seine Ereignisse auf die verworfenen Steuerelemente des Dialogs.
  $dlg.Add_Resize({ Update-AppSettingsEditorLayout })
  $dlg.Add_Shown({ Update-AppSettingsEditorLayout; & $script:appSettingsUi.LoadApps })
  try {
    [void]$dlg.ShowDialog()
  } finally {
    $script:appSettingsUi = $previousAppSettingsUi
    # Die drei gedaempften Beschriftungen dieses Fensters gehen mit ihm - ihre Merker auch.
    Clear-LabelDimmedState -Labels @($restartGraceLabel, $restartCountdownLabel, $restartSnoozeLabel)
    $dlg.Dispose()
  }
}

# --- Anordnung des Editors: gemessen, nicht gezaehlt ---------------------------------------------
#
# Die Steuerelemente standen auf handgezaehlten Pixelkoordinaten eines 720x790-Fensters. Als
# derselbe Editor ein Bereich wurde, stimmte davon nichts mehr:
#   - "Neustart-Countdown vorher anzeigen (Minuten):" ist 270 px breit und begann bei x=32; das
#     Eingabefeld stand bei x=240 und lag damit UNTER der Beschriftung.
#   - "Auto-Update abgeloester Versionen:" war 376 px breit; die Auswahlliste bei x=240 war dahinter
#     komplett unsichtbar - im Bild fehlte sie einfach.
#   - Der Inhalt war 838 px hoch, sichtbar waren 625: der Knopf "Auf markierte Apps anwenden" lag
#     unter der Kante und war nur nach dem Scrollen erreichbar.
#
# Deshalb rechnet diese Funktion die Anordnung aus dem Inhalt: Beschriftungen werden gemessen, die
# Spalte der Bedienelemente beginnt hinter der breitesten, und ab einer gewissen Breite stehen die
# Einstellungen in ZWEI Spalten - die Seite ist breit, sie war nur nie genutzt. Die Liste bekommt,
# was uebrig bleibt. Damit passt der Bereich ohne Bildlaufleiste, und ein Schriftwechsel (jedes
# Retro-Design bringt einen) verschiebt nichts mehr.
function Get-ControlTextHeight {
  param([System.Windows.Forms.Control]$Control, [int]$Width)
  try {
    $size = [System.Windows.Forms.TextRenderer]::MeasureText(
      [string]$Control.Text, $Control.Font,
      (New-Object System.Drawing.Size($Width, 0)),
      [System.Windows.Forms.TextFormatFlags]::WordBreak)
    return [Math]::Max(18, $size.Height + 2)
  } catch { return [Math]::Max(18, $Control.Height) }
}

# Breite, die eine Beschriftung wirklich braucht (eine Zeile).
function Get-ControlTextWidth {
  param([System.Windows.Forms.Control]$Control)
  try {
    return [System.Windows.Forms.TextRenderer]::MeasureText([string]$Control.Text, $Control.Font).Width + 4
  } catch { return $Control.Width }
}

# Eine Zeile besteht aus Zellen; jede Zelle ist eine Beschriftung mit ihrem Bedienelement. Die
# ERSTE Zelle jeder Zeile richtet sich an der gemeinsamen Beschriftungsspalte aus, weitere Zellen
# folgen direkt dahinter (so bleiben "Schlummern zulassen" und seine Dauer in einer Zeile).
function Get-AppSettingsLabelColumn {
  param([object[]]$Rows, [int]$Width)
  $labelW = 0
  foreach ($row in $Rows) {
    $first = @($row.Cells)[0]
    if ($first.L) {
      $w = (Get-ControlTextWidth $first.L) + [int]$row.Indent + 12
      if ($w -gt $labelW) { $labelW = $w }
    }
  }
  return [Math]::Min($labelW, [int]($Width * 0.62))
}

function Set-AppSettingsRowBlock {
  # -LabelWidth erzwingt eine gemeinsame Beschriftungsspalte ueber mehrere Bloecke hinweg. Ohne das
  # rechnete jeder Block seine eigene aus, und untereinander standen die Auswahllisten versetzt.
  param([object[]]$Rows, [int]$X, [int]$Y, [int]$Width, [int]$Gap = 8, [int]$LabelWidth = 0)
  $labelW = if ($LabelWidth -gt 0) { $LabelWidth } else { Get-AppSettingsLabelColumn -Rows $Rows -Width $Width }
  $y = $Y
  foreach ($row in $Rows) {
    $cells = @($row.Cells)
    $rowH = 0
    foreach ($c in $cells) {
      if ($c.L) { $rowH = [Math]::Max($rowH, $c.L.Height) }
      if ($c.C) { $rowH = [Math]::Max($rowH, $c.C.Height) }
    }
    $cursor = $X + [int]$row.Indent
    for ($i = 0; $i -lt $cells.Count; $i++) {
      $cell = $cells[$i]
      if ($cell.L) {
        $cell.L.Left = $cursor
        $cell.L.Top = $y + [int](($rowH - $cell.L.Height) / 2)
      }
      if ($i -eq 0) {
        # Eine Zeile ohne Beschriftung, die eine ganze Aussage traegt ("Zeiten in der lokalen
        # Geraetezeit auswerten"), gehoert an den linken Rand - nicht in die Spalte der
        # Bedienelemente. Dort saehe sie aus wie der Wert einer Beschriftung, die fehlt.
        if (-not $cell.L -and $row.FullWidth) { }
        else { $cursor = $X + $labelW }
      } elseif ($cell.L) {
        $cursor = $cell.L.Right + 8
      }
      if ($cell.C) {
        $available = ($X + $Width) - $cursor
        $want = [int]$cell.W
        $cw = if ($want -gt 0) { [Math]::Min($want, [Math]::Max(60, $available)) } else { [Math]::Max(60, $available) }
        $cell.C.Left = $cursor
        $cell.C.Top = $y + [int](($rowH - $cell.C.Height) / 2)
        $cell.C.Width = $cw
        $cursor = $cell.C.Right + 24
      }
    }
    $y += $rowH + $Gap
  }
  return $y
}

# Uebernimmt die Haken der SICHTBAREN Zeilen in die gemerkte Auswahl. Muss vor jedem Neuaufbau
# laufen, sonst gehen die Haken der gerade angezeigten Zeilen verloren.
function Sync-AppSettingsChecked {
  $ui = $script:appSettingsUi
  if (-not $ui -or -not $ui.List -or $ui.Rebuilding) { return }
  foreach ($row in @($ui.List.Items)) {
    if (-not $row.Tag -or -not $row.Tag.GraphId) { continue }
    $id = [string]$row.Tag.GraphId
    if ($row.Checked) { [void]$ui.CheckedIds.Add($id) } else { [void]$ui.CheckedIds.Remove($id) }
  }
}

# Alle ausgewaehlten Apps - auch die, die der Filter gerade ausblendet.
function Get-AppSettingsSelectedApps {
  $ui = $script:appSettingsUi
  if (-not $ui) { return @() }
  Sync-AppSettingsChecked
  return @(@($ui.AllApps) | Where-Object { $_ -and $_.GraphId -and $ui.CheckedIds.Contains([string]$_.GraphId) })
}

# Liest die Zuweisungen aller noch nicht gelesenen Zeilen und schreibt sie in die dritte Spalte.
#
# Eine Graph-Abfrage je App. Deshalb: nur EINMAL je App (Zwischenspeicher im Beutel), Abbruch sobald
# der Bereich nicht mehr sichtbar ist, die Sitzung endet oder der Benutzer stoppt - und keine
# Busy-Sperre, damit man waehrenddessen weiterarbeiten kann. Die Statuszeile sagt, wie weit es ist.
function Update-AppSettingsAssignments {
  $ui = $script:appSettingsUi
  if (-not $ui -or -not $ui.List) { return }
  if ($ui.AssignmentsLoading) { return }
  if (-not $script:isConnected) { return }
  $notLoaded = Get-UiString 'AssignmentNotLoaded'
  $rows = @($ui.List.Items | Where-Object {
    $_ -and $_.SubItems.Count -ge 3 -and [string]$_.SubItems[2].Text -eq $notLoaded -and $_.Tag -and $_.Tag.GraphId
  })
  if ($rows.Count -eq 0) { return }
  $ui.AssignmentsLoading = $true
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $done = 0; $failed = 0; $index = 0
  try {
    foreach ($row in $rows) {
      $index++
      if (-not $script:isConnected -or $script:cancelBatch) { break }
      # Wer den Bereich verlassen hat, wartet nicht auf diese Liste.
      try { if ($ui.Dlg -and -not $ui.Dlg.Visible) { break } } catch { }
      $app = $row.Tag
      $id = [string]$app.GraphId
      $row.SubItems[2].Text = Get-UiString 'AssignmentLoading'
      if ($ui.Status) { $ui.Status.Text = (Get-UiString 'AssignmentAutoLoadStatus') -f $index, $rows.Count }
      [System.Windows.Forms.Application]::DoEvents()
      try {
        $text = (Get-TenantAppAssignmentText -AppId $id) -replace "`r`n", ' / '
        $row.SubItems[2].Text = $text
        $ui.AssignmentText[$id] = $text
        $done++
      } catch {
        # Auch der Fehlschlag wird gemerkt: ohne das haette jeder Filter-Neubau die Zeile erneut
        # aus Intune gelesen - bei fehlender Berechtigung also bei jedem Tastendruck.
        # Ein neuer Versuch geht ueber "Neu laden", das den Zwischenspeicher leert.
        $row.SubItems[2].Text = Get-UiString 'AssignmentLoadFailed'
        $ui.AssignmentText[$id] = Get-UiString 'AssignmentLoadFailed'
        $failed++
        Write-Log ("App settings: assignments for '{0}' could not be read: {1}" -f [string]$app.Name, $_.Exception.Message)
      }
    }
  } finally {
    $ui.AssignmentsLoading = $false
    if ($ui.Status) { $ui.Status.Text = (Get-UiString 'AssignmentAutoLoadDoneStatus') -f $done, $failed }
    Write-Log ("App settings: read assignments for {0} app(s) in {1:n1}s ({2} failed)." -f $done, $sw.Elapsed.TotalSeconds, $failed)
  }
}

# Baut die Zeilen der Liste aus $ui.AllApps auf und wendet den Filter an. Die Auswahl kommt aus
# $ui.CheckedIds und ueberlebt damit jeden Filterwechsel.
function Update-AppSettingsListRows {
  $ui = $script:appSettingsUi
  if (-not $ui -or -not $ui.List) { return }
  Sync-AppSettingsChecked
  $needle = if ($ui.FilterBox) { ([string]$ui.FilterBox.Text).Trim() } else { '' }
  $ui.Rebuilding = $true
  $ui.List.BeginUpdate()
  try {
    $ui.List.Items.Clear()
    foreach ($a in @($ui.AllApps)) {
      if (-not $a -or -not $a.Name) { continue }
      if ($needle) {
        $name = [string]$a.Name
        $version = [string]$a.CurrentVersion
        if ($name.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $version.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
      }
      $it = New-Object System.Windows.Forms.ListViewItem([string]$a.Name)
      [void]$it.SubItems.Add([string]$a.CurrentVersion)
      # Gelesene Zuweisungen kommen aus dem Beutel, nicht aus der Zeile: beim Filtern werden alle
      # Zeilen neu gebaut, und ohne diesen Zwischenspeicher waere jeder Tastendruck ein erneutes
      # Lesen aller Zuweisungen aus Intune gewesen.
      $cached = $null
      if ($a.GraphId -and $ui.AssignmentText.ContainsKey([string]$a.GraphId)) {
        $cached = [string]$ui.AssignmentText[[string]$a.GraphId]
      }
      [void]$it.SubItems.Add($(if ($cached) { $cached } else { Get-UiString 'AssignmentNotLoaded' }))
      $it.Tag = $a
      if ($a.GraphId -and $ui.CheckedIds.Contains([string]$a.GraphId)) { $it.Checked = $true }
      [void]$ui.List.Items.Add($it)
    }
  } finally {
    $ui.List.EndUpdate()
    $ui.Rebuilding = $false
  }
  # Beim Filtern sagt die Zeile, wie viel ausgeblendet ist UND wie viele Apps ausgewaehlt sind -
  # sonst waere eine Auswahl, die der Filter versteckt, unsichtbar.
  if ($needle) {
    $ui.Status.Text = (Get-UiString 'AppSettingsFilterStatus') -f $ui.List.Items.Count, @($ui.AllApps).Count, $ui.CheckedIds.Count
  }
}

function Update-AppSettingsEditorLayout {
  $ui = $script:appSettingsUi
  if (-not $ui -or -not $ui.Dlg) { return }
  try {
    $panel = $ui.Dlg
    $cw = $panel.ClientSize.Width
    $ch = $panel.ClientSize.Height
    if ($cw -lt 420 -or $ch -lt 320) { return }

    # Die Entwurfsanker stammen aus dem Dialogfenster und wuerden gegen diese Anordnung arbeiten.
    $all = @($ui.Intro, $ui.ListLabel, $ui.FilterBox, $ui.List, $ui.Reload, $ui.CheckAll, $ui.UncheckAll,
      $ui.NotifyLabel, $ui.NotifyCombo, $ui.AvailLabel, $ui.AvailModeCombo, $ui.AvailPicker,
      $ui.DeadlineLabel, $ui.DeadlineModeCombo, $ui.DeadlinePicker, $ui.LocalTimeCheck,
      $ui.RestartModeLabel, $ui.RestartModeCombo, $ui.RestartGraceLabel, $ui.RestartGraceValue,
      $ui.RestartCountdownLabel, $ui.RestartCountdownValue, $ui.RestartSnoozeCheck,
      $ui.RestartSnoozeLabel, $ui.RestartSnoozeValue, $ui.DeliveryLabel, $ui.DeliveryCombo,
      $ui.AutoUpdLabel, $ui.AutoUpdModeCombo, $ui.ApplyButton, $ui.CloseButton, $ui.Status)
    foreach ($c in $all) {
      if ($c) { $c.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left }
    }
    # Diese beiden standen auf fester Groesse und massen sich nie an ihrem Text.
    if ($ui.AutoUpdLabel) { $ui.AutoUpdLabel.AutoSize = $true }

    $m = 12
    $gap = 8
    # Der Block der Einstellungen steht enger als der Kopf: neun Zeilen mal drei Pixel sind der
    # Unterschied zwischen "passt" und "der Anwenden-Knopf liegt unter der Kante".
    $rowGap = 5
    $contentW = $cw - (2 * $m)

    # --- Kopf: Einleitung, Beschriftung, Liste --------------------------------------------------
    $ui.Intro.Left = $m
    $ui.Intro.Top = 10
    $ui.Intro.Width = $contentW
    $ui.Intro.Height = Get-ControlTextHeight $ui.Intro $contentW
    $ui.ListLabel.Left = $m
    $ui.ListLabel.Top = $ui.Intro.Bottom + $gap
    if ($ui.FilterBox) {
      $ui.FilterBox.Left = $ui.ListLabel.Right + 16
      $ui.FilterBox.Width = [Math]::Min(360, [Math]::Max(160, $contentW - $ui.ListLabel.Width - 32))
      $ui.FilterBox.Top = $ui.ListLabel.Top - [int](($ui.FilterBox.Height - $ui.ListLabel.Height) / 2)
    }
    $listTop = [Math]::Max($ui.ListLabel.Bottom, $(if ($ui.FilterBox) { $ui.FilterBox.Bottom } else { 0 })) + 6
    $ui.List.Left = $m
    $ui.List.Top = $listTop
    $ui.List.Width = $contentW

    # --- Knopfreihe unter der Liste -------------------------------------------------------------
    $rowButtons = @($ui.Reload, $ui.CheckAll, $ui.UncheckAll) | Where-Object { $_ }
    $buttonH = 0
    foreach ($b in $rowButtons) {
      $b.Width = [Math]::Max($b.Width, (Get-ControlTextWidth $b) + 28)
      $buttonH = [Math]::Max($buttonH, $b.Height)
    }

    # --- Die Einstellungen selbst ---------------------------------------------------------------
    # Zwei Spalten, sobald beide wirklich hineinpassen - gemessen an den Beschriftungen dieser
    # Sprache und dieses Designs, nicht an einer Pixelschwelle. Zu schmal: eine Spalte, dann
    # scrollt der Bereich (unten wird das Wirtspanel dafuer hoehergesetzt).
    $comboW = 260
    $pickerW = 160
    $leftLabelW = 0
    foreach ($c in @($ui.NotifyLabel, $ui.AvailLabel, $ui.DeadlineLabel, $ui.DeliveryLabel)) {
      if ($c) { $leftLabelW = [Math]::Max($leftLabelW, (Get-ControlTextWidth $c)) }
    }
    $rightLabelW = 0
    foreach ($c in @($ui.RestartModeLabel, $ui.AutoUpdLabel)) {
      if ($c) { $rightLabelW = [Math]::Max($rightLabelW, (Get-ControlTextWidth $c)) }
    }
    foreach ($c in @($ui.RestartGraceLabel, $ui.RestartCountdownLabel, $ui.RestartSnoozeLabel)) {
      if ($c) { $rightLabelW = [Math]::Max($rightLabelW, (Get-ControlTextWidth $c) + 20) }
    }
    $leftNeed = $leftLabelW + 12 + 160 + 24 + $pickerW
    $rightNeed = $rightLabelW + 12 + $comboW
    $twoColumns = ($contentW -ge ($leftNeed + $rightNeed + 24))
    if (-not $twoColumns) { $pickerW = 250 }
    $rowsA = @(
      @{ Cells = @(@{ L = $ui.NotifyLabel;   C = $ui.NotifyCombo;   W = $comboW }) }
      @{ Cells = @(@{ L = $ui.AvailLabel;    C = $ui.AvailModeCombo; W = 160 }, @{ L = $null; C = $ui.AvailPicker; W = $pickerW }) }
      @{ Cells = @(@{ L = $ui.DeadlineLabel; C = $ui.DeadlineModeCombo; W = 160 }, @{ L = $null; C = $ui.DeadlinePicker; W = $pickerW }) }
      @{ FullWidth = $true; Cells = @(@{ L = $null; C = $ui.LocalTimeCheck; W = (Get-ControlTextWidth $ui.LocalTimeCheck) + 24 }) }
      @{ Cells = @(@{ L = $ui.DeliveryLabel; C = $ui.DeliveryCombo; W = $comboW }) }
    )
    if ($twoColumns) {
      $rowsB = @(
        @{ Cells = @(@{ L = $ui.RestartModeLabel; C = $ui.RestartModeCombo; W = $comboW }) }
        @{ Indent = 20; Cells = @(@{ L = $ui.RestartGraceLabel;     C = $ui.RestartGraceValue;     W = 110 }) }
        @{ Indent = 20; Cells = @(@{ L = $ui.RestartCountdownLabel; C = $ui.RestartCountdownValue; W = 110 }) }
        @{ Indent = 20; FullWidth = $true; Cells = @(@{ L = $null; C = $ui.RestartSnoozeCheck; W = (Get-ControlTextWidth $ui.RestartSnoozeCheck) + 24 }) }
        @{ Indent = 20; Cells = @(@{ L = $ui.RestartSnoozeLabel; C = $ui.RestartSnoozeValue; W = 110 }) }
        @{ Cells = @(@{ L = $ui.AutoUpdLabel; C = $ui.AutoUpdModeCombo; W = 200 }) }
      )
    } else {
      # Schmal (das Dialogfenster): die Nebenwerte bleiben in ihrer Zeile, sonst wird es zu hoch.
      $rowsB = @(
        @{ Cells = @(@{ L = $ui.RestartModeLabel; C = $ui.RestartModeCombo; W = $comboW }) }
        @{ Indent = 20; Cells = @(@{ L = $ui.RestartGraceLabel; C = $ui.RestartGraceValue; W = 100 }, @{ L = $null; C = $ui.RestartSnoozeCheck; W = (Get-ControlTextWidth $ui.RestartSnoozeCheck) + 24 }) }
        @{ Indent = 20; Cells = @(@{ L = $ui.RestartCountdownLabel; C = $ui.RestartCountdownValue; W = 100 }, @{ L = $ui.RestartSnoozeLabel; C = $ui.RestartSnoozeValue; W = 100 }) }
        @{ Cells = @(@{ L = $ui.AutoUpdLabel; C = $ui.AutoUpdModeCombo; W = 200 }) }
      )
    }

    # Hoehe des Einstellungsblocks vorab bestimmen, damit die Liste den Rest bekommt. Gerechnet
    # wird mit denselben Zeilenhoehen, die das Setzen unten verwendet.
    $measure = {
      param($rows)
      $h = 0
      foreach ($row in $rows) {
        $rh = 0
        foreach ($c in @($row.Cells)) {
          if ($c.L) { $rh = [Math]::Max($rh, $c.L.Height) }
          if ($c.C) { $rh = [Math]::Max($rh, $c.C.Height) }
        }
        $h += $rh + $rowGap
      }
      return $h
    }
    $settingsH = if ($twoColumns) {
      [Math]::Max((& $measure $rowsA), (& $measure $rowsB))
    } else {
      (& $measure $rowsA) + (& $measure $rowsB)
    }

    $applyH = [Math]::Max(30, $ui.ApplyButton.Height)
    $statusH = 20
    $belowList = 10 + $buttonH + 12 + $settingsH + 8 + [Math]::Max($applyH, $statusH) + $m
    $listH = $ch - $listTop - $belowList
    if ($listH -lt 110) { $listH = 110 }
    $ui.List.Height = $listH
    # Zusaetzliche Breite geht an die Spalte mit der Zuweisung - dort stehen ganze Saetze.
    $extraCol = $contentW - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2 - 690
    if ($extraCol -gt 0 -and $ui.List.Columns.Count -ge 3) {
      $ui.List.Columns[0].Width = 300 + [int]($extraCol * 0.35)
      $ui.List.Columns[2].Width = 260 + [int]($extraCol * 0.65)
    }

    $y = $ui.List.Bottom + 10
    $bx = $m
    foreach ($b in $rowButtons) {
      $b.Left = $bx
      $b.Top = $y
      $bx = $b.Right + 10
    }
    $y += $buttonH + 12

    if ($twoColumns) {
      $colGap = 24
      # Links stehen die Zeilen mit Datumsfeldern, sie brauchen mehr Platz.
      $leftW = [int](($contentW - $colGap) * 0.58)
      $rightW = $contentW - $colGap - $leftW
      $endA = Set-AppSettingsRowBlock -Rows $rowsA -X $m -Y $y -Width $leftW -Gap $rowGap
      $endB = Set-AppSettingsRowBlock -Rows $rowsB -X ($m + $leftW + $colGap) -Y $y -Width $rightW -Gap $rowGap
      $y = [Math]::Max($endA, $endB)
    } else {
      $sharedLabelW = [Math]::Max((Get-AppSettingsLabelColumn -Rows $rowsA -Width $contentW),
                                  (Get-AppSettingsLabelColumn -Rows $rowsB -Width $contentW))
      $y = Set-AppSettingsRowBlock -Rows $rowsA -X $m -Y $y -Width $contentW -Gap $rowGap -LabelWidth $sharedLabelW
      $y = Set-AppSettingsRowBlock -Rows $rowsB -X $m -Y $y -Width $contentW -Gap $rowGap -LabelWidth $sharedLabelW
    }

    $y += 3
    $ui.ApplyButton.Left = $m
    $ui.ApplyButton.Top = $y
    $ui.ApplyButton.Width = [Math]::Max(260, (Get-ControlTextWidth $ui.ApplyButton) + 40)
    if ($ui.CloseButton -and $ui.CloseButton.Visible) {
      $ui.CloseButton.Left = $ui.ApplyButton.Right + 12
      $ui.CloseButton.Top = $y
    }
    # Die Statuszeile steht NEBEN dem Knopf, nicht darunter: sie ist kurz ("11 App(s) geaendert"),
    # und eine eigene Zeile dafuer war genau die Zeile, die unten fehlte.
    $statusLeft = if ($ui.CloseButton -and $ui.CloseButton.Visible) { $ui.CloseButton.Right + 16 } else { $ui.ApplyButton.Right + 16 }
    $ui.Status.Left = $statusLeft
    $ui.Status.Top = $ui.ApplyButton.Top + [int](($applyH - $statusH) / 2)
    $ui.Status.Width = [Math]::Max(120, ($m + $contentW) - $statusLeft)
    $ui.Status.Height = $statusH

    # Passt der Inhalt trotz Mindesthoehe der Liste nicht (sehr niedriges Fenster), waechst das
    # Wirtspanel - dann scrollt der BEREICH. Ohne das wurde der Knopf einfach abgeschnitten: keine
    # Bildlaufleiste, kein Hinweis, die Hauptaktion unerreichbar.
    $needed = $ui.Status.Bottom + $m
    if ($ui.Embedded -and $needed -gt $ch) { $panel.Height = $needed }
    Write-LogDebug ("App settings editor layout: contentW={0} twoColumns={1} list={2}px needed={3}px avail={4}px" -f $contentW, $twoColumns, $listH, $needed, $ch)
  } catch { Write-LogDebug 'app settings editor layout' }
}

# Der Leistungsnachweis - entweder als eigenes Fenster oder, mit -HostPanel, als Bereich in der
# Seitenleiste. Derselbe Aufbau wie bei Show-AppSettingsDialog, aus demselben Grund: es ist eine
# Auswertung, die man liest, kopiert und zwischen Sitzungen umschaltet, und dafuer ist ein Bereich
# der richtige Ort. Die Ereignisse gehen ueber $script:workRecordUi, weil die lokalen Variablen
# dieser Funktion im eingebetteten Fall langst weg sind, wenn jemand klickt (siehe die ausfuehrliche
# Begruendung bei Show-AppSettingsDialog).
function Show-LeistungstextDialog {
  param([System.Windows.Forms.Control]$HostPanel)
  $embedded = [bool]$HostPanel
  if ($embedded) {
    $dlg = $HostPanel
  } else {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = Get-UiString 'LeistungDialogTitle'
    $dlg.ClientSize = New-Object System.Drawing.Size(584, 430)
    $dlg.MinimumSize = New-Object System.Drawing.Size(460, 360)
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)
  }

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
    $ui = $script:workRecordUi
    $script:leistungShowPrevious = ($ui.SessionCombo.SelectedIndex -eq 1)
    Update-WorkRecordText -Force
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

  # Einfache Skriptbloecke (KEIN .GetNewClosure()): eine Closure haelt zwar die Steuerelemente fest,
  # verliert aber die Funktionen des Skripts. Die Steuerelemente kommen daher aus dem Beutel.
  $langCombo.Add_SelectedIndexChanged({
    $ui = $script:workRecordUi
    $script:leistungLang = if ($ui.LangCombo.SelectedIndex -eq 1) { 'en' } else { 'de' }
    Update-WorkRecordText -Force
  })

  $copyButton = New-Object System.Windows.Forms.Button
  $copyButton.Text = Get-UiString 'LeistungCopyButton'
  $copyButton.Location = New-Object System.Drawing.Point(10, 384)
  $copyButton.Width = 230
  $copyButton.Height = 32
  $copyButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $copyButton.Add_Click({
    $ui = $script:workRecordUi
    try {
      [System.Windows.Forms.Clipboard]::SetText($ui.Box.Text)
      $ui.CopyButton.Text = Get-UiString 'LeistungCopiedButton'
    } catch { Write-Log "Clipboard copy failed: $($_.Exception.Message)" }
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
      Clear-SessionActivityRecord
      Update-WorkRecordText -Force
    }
  })
  $dlg.Controls.Add($clearButton)

  $closeButton = New-Object System.Windows.Forms.Button
  $closeButton.Text = Get-UiString 'CloseButton'
  $closeButton.Location = New-Object System.Drawing.Point(454, 384)
  $closeButton.Width = 120
  $closeButton.Height = 32
  $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
  if ($embedded) { $closeButton.Visible = $false } else { $closeButton.Add_Click({ $script:workRecordUi.Dlg.Close() }) }
  $dlg.Controls.Add($closeButton)

  $previousWorkRecordUi = $script:workRecordUi
  $script:workRecordUi = @{
    Dlg = $dlg; Embedded = $embedded
    LangLabel = $langLabel; LangCombo = $langCombo; SessionCombo = $sessionCombo
    Header = $header; Box = $box
    CopyButton = $copyButton; ClearButton = $clearButton; CloseButton = $closeButton
    # Der zuletzt SELBST erzeugte Text. Update-WorkRecordText vergleicht damit, um eine
    # Hand-Aenderung im Feld nicht beim naechsten Bereichswechsel zu ueberschreiben.
    LastGenerated = [string]$box.Text
  }

  Set-GuiTheme -control $dlg -theme $script:currentTheme
  Update-WorkRecordLayout
  if ($embedded) { return }
  try {
    [void]$dlg.ShowDialog()
  } finally {
    $script:workRecordUi = $previousWorkRecordUi
    $dlg.Dispose()
  }
}

# Zieht Kopfzeile und Textfeld nach.
#
# Der Text entsteht beim AUFBAU des Bereichs - und der Bereich wird gebaut, bevor sich jemand
# angemeldet hat. Ohne dieses Nachziehen stand nach einem vollstaendigen Update-Lauf immer noch
# "Bitte an einem Tenant anmelden, um dessen Leistungsnachweis zu sehen." im Feld: gemeldet am
# 28.08.2026, Protokoll 08:25:35 zwei Apps erfolgreich aktualisiert, 08:29:47 Wechsel in den
# Bereich - und dort der Anmelde-Hinweis. Sichtbar wurde der echte Text nur, wenn man zufaellig die
# Sprache oder die Sitzung umschaltete, denn nur diese beiden Handler haben ihn je neu erzeugt.
#
# Eine HAND-Aenderung wird nicht ueberschrieben: das Feld ist bearbeitbar, weil der Text in ein
# Ticket wandert, und wer dort etwas ergaenzt hat, darf es nicht durch einen Bereichswechsel
# verlieren. Erkannt wird das am Vergleich mit dem zuletzt selbst erzeugten Text; -Force ist fuer
# die Faelle, in denen der Inhalt sich WIRKLICH aendert (Sprache, Sitzung, Loeschen).
function Update-WorkRecordText {
  param([switch]$Force)
  $ui = $script:workRecordUi
  if (-not $ui -or -not $ui.Box) { return }
  try {
    if (-not $Force -and $null -ne $ui.LastGenerated -and
        -not [string]::Equals([string]$ui.Box.Text, [string]$ui.LastGenerated, [System.StringComparison]::Ordinal)) {
      Write-LogDebug 'Work record: the text was edited by hand - keeping it instead of regenerating.'
      return
    }
    $text = Get-SessionLeistungstext
    $ui.Box.Text = $text
    $ui.LastGenerated = $text
    if ($ui.Header) { $ui.Header.Text = Get-SessionLeistungsHeader }
  } catch { Write-LogDebug 'work record text' }
}

# Anordnung aus dem vorhandenen Platz, nicht aus Pixelkonstanten: als Bereich ist das Feld so hoch
# wie die Sektion, im Fenster so hoch wie der Dialog.
function Update-WorkRecordLayout {
  $ui = $script:workRecordUi
  if (-not $ui -or -not $ui.Dlg) { return }
  try {
    $panel = $ui.Dlg
    $cw = $panel.ClientSize.Width
    $ch = $panel.ClientSize.Height
    if ($cw -lt 380 -or $ch -lt 240) { return }
    foreach ($c in @($ui.LangLabel, $ui.LangCombo, $ui.SessionCombo, $ui.Header, $ui.Box,
                     $ui.CopyButton, $ui.ClearButton, $ui.CloseButton)) {
      if ($c) { $c.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left }
    }
    $m = 12
    $contentW = $cw - (2 * $m)
    $ui.LangLabel.Left = $m
    $ui.LangCombo.Left = $ui.LangLabel.Right + 10
    $ui.SessionCombo.Left = $ui.LangCombo.Right + 12
    $rowH = [Math]::Max($ui.LangCombo.Height, $ui.LangLabel.Height)
    $ui.LangLabel.Top = 10 + [int](($rowH - $ui.LangLabel.Height) / 2)
    $ui.LangCombo.Top = 10
    $ui.SessionCombo.Top = 10
    $y = 10 + $rowH + 10
    $ui.Header.Left = $m
    $ui.Header.Top = $y
    $ui.Header.Width = $contentW
    $ui.Header.Height = [Math]::Max(34, (Get-ControlTextHeight $ui.Header $contentW))
    $y = $ui.Header.Bottom + 8
    $buttonH = [Math]::Max(30, $ui.CopyButton.Height)
    $ui.Box.Left = $m
    $ui.Box.Top = $y
    $ui.Box.Width = $contentW
    $ui.Box.Height = [Math]::Max(120, $ch - $y - $buttonH - 12 - $m)
    $by = $ui.Box.Bottom + 12
    $bx = $m
    foreach ($b in @($ui.CopyButton, $ui.ClearButton)) {
      if (-not $b) { continue }
      $b.Left = $bx; $b.Top = $by
      $bx = $b.Right + 10
    }
    if ($ui.CloseButton -and $ui.CloseButton.Visible) { $ui.CloseButton.Left = $bx; $ui.CloseButton.Top = $by }
  } catch { Write-LogDebug 'work record layout' }
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
# Read-only view of the assignments kept before a deletion in this session. Deliberately a plain
# text box: it is meant to be selected and pasted into a ticket while someone rebuilds a scope.
function Show-ScopeSnapshotDialog {
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = Get-UiString 'ScopeSnapshotTitle'
  $dlg.Size = New-Object System.Drawing.Size(760, 520)
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.MinimizeBox = $false
  $dlg.MaximizeBox = $false

  $box = New-Object System.Windows.Forms.TextBox
  $box.Multiline = $true
  $box.ReadOnly = $true
  $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
  $box.Location = New-Object System.Drawing.Point(14, 14)
  $box.Size = New-Object System.Drawing.Size(716, 420)
  $box.Font = New-Object System.Drawing.Font('Consolas', 9)
  $box.Text = Get-ScopeSnapshotText
  $dlg.Controls.Add($box)

  $copyButton = New-Object System.Windows.Forms.Button
  $copyButton.Tag = 'btn-secondary'
  $copyButton.Text = Get-UiString 'LeistungCopyButton'
  $copyButton.Location = New-Object System.Drawing.Point(14, 446)
  $copyButton.Width = 200
  $copyButton.Height = 30
  $copyButton.Add_Click({
    try { if ($box.Text) { [System.Windows.Forms.Clipboard]::SetText($box.Text) } } catch { Write-LogDebug 'scope snapshot copy' }
  })
  $dlg.Controls.Add($copyButton)

  $closeButton = New-Object System.Windows.Forms.Button
  $closeButton.Text = Get-UiString 'CloseButton'
  $closeButton.Location = New-Object System.Drawing.Point(600, 446)
  $closeButton.Width = 130
  $closeButton.Height = 30
  $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dlg.Controls.Add($closeButton)
  $dlg.AcceptButton = $closeButton
  $dlg.CancelButton = $closeButton

  Set-GuiTheme -control $dlg -theme $script:currentTheme
  [void]$dlg.ShowDialog()
  $dlg.Dispose()
}

# Lets the technician name the tenants they sign in to. Only the DISPLAY changes - the address is
# shown next to the name here and stays the value used for signing in.
function Show-TenantNamesDialog {
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = Get-UiString 'TenantNamesTitle'
  $dlg.Size = New-Object System.Drawing.Size(700, 480)
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.MinimizeBox = $false
  $dlg.MaximizeBox = $false

  $hint = New-Object System.Windows.Forms.Label
  $hint.Tag = 'hint'
  $hint.Text = Get-UiString 'TenantNamesHint'
  $hint.Location = New-Object System.Drawing.Point(14, 12)
  $hint.Size = New-Object System.Drawing.Size(656, 48)
  $dlg.Controls.Add($hint)

  $list = New-Object System.Windows.Forms.ListView
  $list.View = [System.Windows.Forms.View]::Details
  $list.FullRowSelect = $true
  $list.MultiSelect = $false
  $list.HideSelection = $false
  $list.Location = New-Object System.Drawing.Point(14, 68)
  $list.Size = New-Object System.Drawing.Size(656, 320)
  [void]$list.Columns.Add((Get-UiString 'TenantNamesColUpn'), 330)
  [void]$list.Columns.Add((Get-UiString 'TenantNamesColName'), 300)
  $dlg.Controls.Add($list)

  # Everything the technician has ever signed in to, plus the current session even when it has not
  # been persisted to RecentLogins yet.
  $known = [System.Collections.Generic.List[string]]::new()
  foreach ($u in @($script:settings.RecentLogins)) {
    if ($u -and -not $known.Contains([string]$u)) { [void]$known.Add([string]$u) }
  }
  if ($script:currentUserUpn -and -not $known.Contains([string]$script:currentUserUpn)) {
    [void]$known.Add([string]$script:currentUserUpn)
  }

  $fillList = {
    $list.Items.Clear()
    foreach ($u in $known) {
      $item = New-Object System.Windows.Forms.ListViewItem([string]$u)
      $name = Get-TenantDisplayName -Upn ([string]$u)
      $shown = if ([string]::Equals($name, [string]$u, [System.StringComparison]::OrdinalIgnoreCase)) { '' } else { $name }
      [void]$item.SubItems.Add($shown)
      $item.Tag = [string]$u
      [void]$list.Items.Add($item)
    }
    if ($list.Items.Count -eq 0) {
      $empty = New-Object System.Windows.Forms.ListViewItem((Get-UiString 'TenantNamesEmpty'))
      [void]$empty.SubItems.Add('')
      [void]$list.Items.Add($empty)
    }
  }
  & $fillList

  $renameButton = New-Object System.Windows.Forms.Button
  $renameButton.Tag = 'btn-secondary'
  $renameButton.Text = Get-UiString 'TenantNamesEditButton'
  $renameButton.Location = New-Object System.Drawing.Point(14, 400)
  $renameButton.Width = 200
  $renameButton.Height = 30
  $renameButton.Add_Click({
    if ($list.SelectedItems.Count -eq 0) { return }
    $upn = [string]$list.SelectedItems[0].Tag
    if ([string]::IsNullOrWhiteSpace($upn)) { return }
    $current = Get-TenantDisplayName -Upn $upn
    if ([string]::Equals($current, $upn, [System.StringComparison]::OrdinalIgnoreCase)) { $current = '' }
    # An empty answer clears the name and falls back to the address - that is the way back.
    $entered = Show-TextInputDialog -Title (Get-UiString 'TenantNamesEditTitle') -Prompt ((Get-UiString 'TenantNamesEditPrompt') -f $upn) -Value $current
    if ($null -eq $entered) { return }
    Set-TenantDisplayName -Upn $upn -Name $entered
    Save-Settings
    Write-Log ("Tenant display name set: {0} -> '{1}'" -f $upn, (Get-TenantDisplayName -Upn $upn))
    & $fillList
    try { Update-RecentLoginsUI } catch { Write-LogDebug 'recent logins refresh' }
  })
  $dlg.Controls.Add($renameButton)

  $closeButton = New-Object System.Windows.Forms.Button
  $closeButton.Text = Get-UiString 'CloseButton'
  $closeButton.Location = New-Object System.Drawing.Point(540, 400)
  $closeButton.Width = 130
  $closeButton.Height = 30
  $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dlg.Controls.Add($closeButton)
  $dlg.AcceptButton = $closeButton
  $dlg.CancelButton = $closeButton

  Set-GuiTheme -control $dlg -theme $script:currentTheme
  [void]$dlg.ShowDialog()
  $dlg.Dispose()
}

# Die Schutzliste dort bearbeiten, wo die Entscheidung faellt: an der Update-Liste.
#
# Der Weg ueber die Einstellungsseite gibt es weiterhin und bleibt der Ort fuer die Erklaerung. Was
# er nicht kann: waehrend man auf die Treffer schaut, ein Muster wie 'Splashtop*' nachtragen und
# sofort sehen, welche Zeilen es jetzt trifft - dafuer muesste man den Bereich wechseln und wieder
# zurueck. Beide Wege schreiben in dieselbe Liste und speichern sofort (siehe 85-Rows).
#
# -SuggestedPattern kommt aus der angeklickten Zeile: der haeufigste Fall ist "diese App hier", und
# das Eingabefeld steht dann schon richtig ausgefuellt da.
function Show-ProtectedAppsDialog {
  param([string]$SuggestedPattern = '')

  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = Get-UiString 'ProtectedDialogTitle'
  $dlg.Size = New-Object System.Drawing.Size(660, 500)
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.MinimizeBox = $false
  $dlg.MaximizeBox = $false
  $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog

  $hint = New-Object System.Windows.Forms.Label
  $hint.Tag = 'hint'
  $hint.Text = Get-UiString 'HintProtectedApps'
  $hint.Location = New-Object System.Drawing.Point(14, 12)
  $hint.Size = New-Object System.Drawing.Size(616, 96)
  $dlg.Controls.Add($hint)

  $list = New-Object System.Windows.Forms.ListBox
  $list.Location = New-Object System.Drawing.Point(14, 116)
  $list.Size = New-Object System.Drawing.Size(616, 228)
  $list.IntegralHeight = $false   # sonst kuerzt WinForms die Hoehe auf ganze Zeilen und der Dialog rechnet daneben
  $dlg.Controls.Add($list)

  $fillList = {
    $list.BeginUpdate()
    try {
      $list.Items.Clear()
      foreach ($p in @($script:settings.ProtectedApps)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$p)) { [void]$list.Items.Add([string]$p) }
      }
    } finally { $list.EndUpdate() }
  }
  & $fillList

  # Gemessen statt gezaehlt: "Ausgewaehlten entfernen" braucht 136 px, die feste Breite gab ihm 134 -
  # die Probe hat das gefunden, das Auge haette es als "sieht eng aus" durchgehen lassen. Die zwei
  # Knoepfe stehen rechtsbuendig am Rand, das Eingabefeld bekommt den Rest der Zeile.
  $rightEdge = 630
  $addButton = New-Object System.Windows.Forms.Button
  $addButton.Text = Get-UiString 'ProtectedAddButton'
  $removeButton = New-Object System.Windows.Forms.Button
  $removeButton.Tag = 'btn-secondary'
  $removeButton.Text = Get-UiString 'ProtectedRemoveButton'
  # +20 fuer die Innenraender des Knopfes; die Mindestbreite haelt kurze Woerter ("Add") ansehnlich.
  $addWidth = [Math]::Max(120, (Get-ControlTextWidth -Control $addButton) + 20)
  $removeWidth = [Math]::Max(134, (Get-ControlTextWidth -Control $removeButton) + 20)
  $removeX = $rightEdge - $removeWidth
  $addX = $removeX - 10 - $addWidth
  $inputWidth = $addX - 10 - 14

  $inputBox = New-Object System.Windows.Forms.TextBox
  $inputBox.PlaceholderText = Get-UiString 'ProtectedInputPlaceholder'
  $inputBox.Text = ([string]$SuggestedPattern).Trim()
  $inputHost = New-RoundedInput -Inner $inputBox -X 14 -Y 356 -W $inputWidth -H 30
  $dlg.Controls.Add($inputHost)

  $addButton.Location = New-Object System.Drawing.Point($addX, 356)
  $addButton.Width = $addWidth
  $addButton.Height = 30
  $addButton.Add_Click({
    $pattern = $inputBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($pattern)) { return }
    $script:settings.ProtectedApps = @(Add-ProtectedAppPattern -Patterns $script:settings.ProtectedApps -Pattern $pattern)
    Save-Settings
    Write-Log ("Protected apps: added pattern '{0}' from the update view (now {1} entr(y/ies))." -f $pattern, @($script:settings.ProtectedApps).Count)
    $inputBox.Text = ''
    & $fillList
    # Beide anderen Anzeigen derselben Liste nachziehen: die Einstellungskarte und die Zeilenfarben.
    # Ohne das behauptet die eine Stelle etwas anderes als die andere.
    try { Update-ProtectedAppsList } catch { Write-LogDebug 'protected apps settings list' }
    try { Update-UpdateListRows } catch { Write-LogDebug 'update list rows after protect' }
    Update-Status ((Get-UiString 'ProtectedAddedStatus') -f $pattern)
  })
  $dlg.Controls.Add($addButton)
  $dlg.AcceptButton = $addButton

  $removeButton.Location = New-Object System.Drawing.Point($removeX, 356)
  $removeButton.Width = $removeWidth
  $removeButton.Height = 30
  $removeButton.Add_Click({
    $sel = [string]$list.SelectedItem
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $script:settings.ProtectedApps = @(Remove-ProtectedAppPattern -Patterns $script:settings.ProtectedApps -Pattern $sel)
    Save-Settings
    Write-Log ("Protected apps: removed pattern '{0}' from the update view (now {1} entr(y/ies))." -f $sel, @($script:settings.ProtectedApps).Count)
    & $fillList
    try { Update-ProtectedAppsList } catch { Write-LogDebug 'protected apps settings list' }
    try { Update-UpdateListRows } catch { Write-LogDebug 'update list rows after unprotect' }
    Update-Status ((Get-UiString 'ProtectedRemovedStatus') -f $sel)
  })
  $dlg.Controls.Add($removeButton)

  $closeButton = New-Object System.Windows.Forms.Button
  $closeButton.Tag = 'btn-secondary'
  $closeButton.Text = Get-UiString 'CloseButton'
  $closeWidth = [Math]::Max(130, (Get-ControlTextWidth -Control $closeButton) + 20)
  $closeButton.Location = New-Object System.Drawing.Point(($rightEdge - $closeWidth), 404)
  $closeButton.Width = $closeWidth
  $closeButton.Height = 30
  $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dlg.Controls.Add($closeButton)
  $dlg.CancelButton = $closeButton

  Set-GuiTheme -control $dlg -theme $script:currentTheme
  [void]$dlg.ShowDialog()
  $dlg.Dispose()
}

# Small one-line text prompt. WinForms has no InputBox, and pulling in the VisualBasic assembly just
# for this would add a load to startup. Returns $null when cancelled, so "cleared" ('') and
# "cancelled" stay distinguishable - clearing a name is a real action here.
function Show-TextInputDialog {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Value = ''
  )
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = $Title
  $dlg.Size = New-Object System.Drawing.Size(560, 200)
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.MinimizeBox = $false
  $dlg.MaximizeBox = $false
  $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Prompt
  $label.Location = New-Object System.Drawing.Point(14, 14)
  $label.Size = New-Object System.Drawing.Size(516, 36)
  $dlg.Controls.Add($label)

  $inputBox = New-Object System.Windows.Forms.TextBox
  $inputBox.Text = $Value
  $inputBox.Location = New-Object System.Drawing.Point(14, 58)
  $inputBox.Width = 516
  $dlg.Controls.Add($inputBox)

  $okButton = New-Object System.Windows.Forms.Button
  $okButton.Text = Get-UiString 'OkButton'
  $okButton.Location = New-Object System.Drawing.Point(296, 110)
  $okButton.Width = 110
  $okButton.Height = 30
  $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dlg.Controls.Add($okButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Tag = 'btn-secondary'
  $cancelButton.Text = Get-UiString 'CancelButton'
  $cancelButton.Location = New-Object System.Drawing.Point(416, 110)
  $cancelButton.Width = 110
  $cancelButton.Height = 30
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $dlg.Controls.Add($cancelButton)

  $dlg.AcceptButton = $okButton
  $dlg.CancelButton = $cancelButton
  Set-GuiTheme -control $dlg -theme $script:currentTheme
  $answer = $dlg.ShowDialog()
  $text = [string]$inputBox.Text
  $dlg.Dispose()
  if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
  return $text.Trim()
}
# Die optionale Gruppen-Leseberechtigung: selbst erteilen, anderes Konto, oder gar nicht.
#
# Vorher stand hier eine Ja/Nein-Frage mit dem Wort "anfordern". Das las sich, als muesse jemand
# anders die Berechtigung erteilen - dabei oeffnet sich ein Anmeldefenster, in dem ein Konto mit den
# passenden Rechten (Cloud-Anwendungsadministrator, Anwendungsadministrator, Globaler Administrator)
# die Zustimmung SELBST gibt, fuer sich oder fuer die ganze Organisation. Erst wenn das Konto das
# nicht darf, wird daraus eine Anfrage an einen Administrator.
#
# Der zweite Weg ist der Alltag beim Dienstleister: die Administratorrechte liegen auf einem zweiten
# Konto. Dafuer wird der Token-Cache der Graph-PowerShell geleert - und NUR dieser, der
# WinTuner-Cache bleibt, damit die Tenant-Verbindung bestehen bleibt.
#
# Gibt 'self' | 'other' | 'cancel' zurueck. Der Text kommt ueber -TextKey, weil dieselbe Frage fuer
# mehrere optionale Berechtigungen gestellt wird (Gruppensuche, erkannte Apps).
function Show-GraphScopeConsentDialog {
  param([string]$TextKey = 'GroupLookupConsentDialog')
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = Get-UiString 'GroupLookupConsentTitle'
  $dlg.ClientSize = New-Object System.Drawing.Size(700, 396)
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dlg.MinimizeBox = $false
  $dlg.MaximizeBox = $false
  $dlg.ShowIcon = $false

  $text = New-Object System.Windows.Forms.TextBox
  $text.Multiline = $true
  $text.ReadOnly = $true
  $text.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
  $text.Location = New-Object System.Drawing.Point(14, 14)
  $text.Size = New-Object System.Drawing.Size(672, 300)
  $text.Text = Get-UiString $TextKey
  # Ohne das bekommt das Textfeld den Fokus und markiert seinen ganzen Inhalt blau - der Dialog
  # sieht dann aus, als haette jemand alles ausgewaehlt.
  $text.TabStop = $false
  $dlg.Controls.Add($text)

  $script:groupConsentChoice = 'cancel'

  $selfButton = New-Object System.Windows.Forms.Button
  $selfButton.Text = Get-UiString 'GroupLookupSelfButton'
  $selfButton.Location = New-Object System.Drawing.Point(14, 328)
  $selfButton.Size = New-Object System.Drawing.Size(260, 34)
  $selfButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $selfButton.Add_Click({ $script:groupConsentChoice = 'self' })
  $dlg.Controls.Add($selfButton)

  $otherButton = New-Object System.Windows.Forms.Button
  $otherButton.Tag = 'btn-secondary'
  $otherButton.Text = Get-UiString 'GroupLookupOtherAccountButton'
  $otherButton.Location = New-Object System.Drawing.Point(284, 328)
  $otherButton.Size = New-Object System.Drawing.Size(260, 34)
  $otherButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $otherButton.Add_Click({ $script:groupConsentChoice = 'other' })
  $dlg.Controls.Add($otherButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Tag = 'btn-secondary'
  $cancelButton.Text = Get-UiString 'CancelButton'
  $cancelButton.Location = New-Object System.Drawing.Point(554, 328)
  $cancelButton.Size = New-Object System.Drawing.Size(132, 34)
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $cancelButton.Add_Click({ $script:groupConsentChoice = 'cancel' })
  $dlg.Controls.Add($cancelButton)
  $dlg.CancelButton = $cancelButton

  Set-GuiTheme -control $dlg -theme $script:currentTheme
  [void]$dlg.ShowDialog()
  $dlg.Dispose()
  return $script:groupConsentChoice
}

# Windows Sandbox is unavailable on this machine - what now?
#
# A yes/no box is the wrong shape here. Credential Guard is active on most managed devices, so for
# most users the sandbox will never work, and the question is not "try anyway?" but "what else?".
# The answer sits in the same card: the three-step local detection. So the dialog offers the working
# route first, the doomed one second, and a way out.
#
# Returns 'local' | 'sandbox' | 'cancel'.
function Show-SandboxBlockedDialog {
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = Get-UiString 'DetectSandboxBlockedTitle'
  $dlg.Size = New-Object System.Drawing.Size(700, 430)
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dlg.MinimizeBox = $false
  $dlg.MaximizeBox = $false

  $text = New-Object System.Windows.Forms.TextBox
  $text.Multiline = $true
  $text.ReadOnly = $true
  $text.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
  $text.Location = New-Object System.Drawing.Point(14, 14)
  $text.Size = New-Object System.Drawing.Size(656, 296)
  $text.Text = Get-UiString 'DetectSandboxBlockedDialog'
  $text.TabStop = $false
  $dlg.Controls.Add($text)

  $script:sandboxBlockedChoice = 'cancel'

  # The working route is the primary button, on the left where the eye starts.
  $localButton = New-Object System.Windows.Forms.Button
  $localButton.Text = Get-UiString 'DetectSandboxUseLocalButton'
  $localButton.Location = New-Object System.Drawing.Point(14, 324)
  $localButton.Size = New-Object System.Drawing.Size(280, 34)
  $localButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $localButton.Add_Click({ $script:sandboxBlockedChoice = 'local' })
  $dlg.Controls.Add($localButton)

  $anywayButton = New-Object System.Windows.Forms.Button
  $anywayButton.Tag = 'btn-secondary'
  $anywayButton.Text = Get-UiString 'DetectSandboxTryAnywayButton'
  $anywayButton.Location = New-Object System.Drawing.Point(304, 324)
  $anywayButton.Size = New-Object System.Drawing.Size(210, 34)
  $anywayButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $anywayButton.Add_Click({ $script:sandboxBlockedChoice = 'sandbox' })
  $dlg.Controls.Add($anywayButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Tag = 'btn-secondary'
  $cancelButton.Text = Get-UiString 'CancelButton'
  $cancelButton.Location = New-Object System.Drawing.Point(524, 324)
  $cancelButton.Size = New-Object System.Drawing.Size(146, 34)
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $cancelButton.Add_Click({ $script:sandboxBlockedChoice = 'cancel' })
  $dlg.Controls.Add($cancelButton)

  $dlg.AcceptButton = $localButton
  $dlg.CancelButton = $cancelButton
  Set-GuiTheme -control $dlg -theme $script:currentTheme
  [void]$dlg.ShowDialog()
  $dlg.Dispose()
  return $script:sandboxBlockedChoice
}

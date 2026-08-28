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
    $it.ForeColor = Get-RowAlertColor -Level 'blocked'
    return $it
  }

  # Target column answers "what is the target in Intune?", note column answers "what has to happen?".
  # Both used to sit in the target column, which is why an action phrase appeared under that heading.
  $targetState = if ($App.TargetAlreadyDeployed) { Get-UiString 'UpdateTargetExisting' } else { Get-UiString 'UpdateTargetToCreate' }

  $noteParts = [System.Collections.Generic.List[string]]::new()
  $actionNote = if ($App.TargetAlreadyDeployed) { Get-UiString 'UpdateStateExisting' } else { Get-UiString 'UpdateStateNew' }
  $noteParts.Add([string]$actionNote)
  # Ganz vorn, weil es die wichtigste Aussage der Zeile ist: diese App ist als selbst paketiert
  # markiert. Sie bleibt anhakbar - Umgebungen muss man pflegen koennen - aber der Lauf fragt vorher
  # ausdruecklich nach, auch bei abgeschalteten Bestaetigungen (Confirm-ProtectedAppsInRun).
  # Die Farbe wird am ENDE einmal gesetzt, nicht hier. Vorher setzte jede der folgenden Regeln ihr
  # Orange nach - die geschuetzte App stand zuerst und wurde von der naechsten Regel wieder
  # ueberschrieben. Bei einer selbst paketierten App, deren Zuweisungen unklar sind, verschwand die
  # rote Kennzeichnung also genau dann, wenn sie am wichtigsten ist.
  $alertLevel = ''
  if ($App.PSObject.Properties['IsProtected'] -and $App.IsProtected) {
    $noteParts.Add((Get-UiString 'UpdateStateProtected'))
    $alertLevel = 'protected'
  }
  # Zuerst genannt, weil es die Herkunft der ganzen Zeile relativiert: bei einer App ohne
  # WinTuner-Marke kommt die Paket-Id aus dem Namensabgleich, nicht aus dem Notizfeld. Der Lauf
  # loest diese App ab und zieht ihre Zuweisungen mit - das soll niemand versehentlich anhaken.
  if ($App.PSObject.Properties['IsUnmanaged'] -and $App.IsUnmanaged) {
    # Zwei verschiedene Aussagen, die nicht denselben Satz vertragen: eine im Notizfeld
    # AUFGESCHRIEBENE Id ist belastbar, eine ueber den Namen zugeordnete ist eine Vermutung. Beide
    # Zeilen bleiben orange, weil der Lauf in beiden Faellen eine App abloest, die WinTuner nicht
    # gebaut hat.
    if ($App.PSObject.Properties['PackageIdFromNotes'] -and $App.PackageIdFromNotes) {
      $noteParts.Add((Get-UiString 'UpdateStateNotesId'))
    } else {
      $noteParts.Add((Get-UiString 'UpdateStateUnmanaged'))
    }
    if (-not $alertLevel) { $alertLevel = 'warn' }
  }
  # Two separate statements, because they mean different things to the reader: "the predecessors
  # really carry different assignments" versus "one of them could not be read". A predecessor with no
  # assignment at all is neither - it has nothing to hand over, so it is not mentioned here.
  if ($App.PSObject.Properties['ScopeWarning'] -and $App.ScopeWarning) {
    $noteParts.Add((Get-UiString 'UpdateStateScopeWarning'))
    if (-not $alertLevel) { $alertLevel = 'warn' }
  }
  if ($App.PSObject.Properties['ScopeUnknown'] -and $App.ScopeUnknown) {
    $noteParts.Add((Get-UiString 'UpdateStateScopeUnknown'))
    if (-not $alertLevel) { $alertLevel = 'warn' }
  }
  # Only shown when every scope probe succeeded and came back empty - see Group-UpdateCandidates.
  if ($App.PSObject.Properties['NoAssignment'] -and $App.NoAssignment) {
    $noteParts.Add((Get-UiString 'UpdateStateNoAssignment'))
  }
  # Eine Zeile, eine Farbe - und 'protected' gewinnt gegen jede Randbemerkung.
  if ($alertLevel) { $it.ForeColor = Get-RowAlertColor -Level $alertLevel }
  [void]$it.SubItems.Add($targetState)
  [void]$it.SubItems.Add(($noteParts -join '; '))
  if ($App.Checked) { $it.Checked = $true }
  return $it
}

# Zeichnet die vorhandenen Zeilen neu, OHNE den Tenant erneut zu befragen.
#
# Gebraucht, wenn sich die Schutzliste waehrend der Anzeige aendert (Rechtsklick auf eine Zeile):
# der Scan bleibt gueltig, nur das Urteil ueber diese Zeile nicht. Einen kompletten Scan dafuer zu
# wiederholen waere eine halbe Minute Wartezeit fuer eine Textaenderung.
#
# Der Haken wird vor dem Neuaufbau ins Modell zurueckgeschrieben und von New-UpdateRow wieder
# gesetzt - sonst verliert man beim Schuetzen einer App die Auswahl aller anderen.
function Update-UpdateListRows {
  if (-not $updateListBox) { return }
  $models = @()
  foreach ($it in @($updateListBox.Items)) {
    $m = $it.Tag
    if (-not $m) { continue }
    $m.Checked = [bool]$it.Checked
    if ($m.PSObject.Properties['IsProtected']) {
      $m.IsProtected = [bool](Test-IsProtectedApp -Name ([string]$m.Name) -Patterns $script:settings.ProtectedApps)
    }
    $models += $m
  }
  # Der Merker haelt den ItemChecked-Handler still: der Neuaufbau setzt Haken, und das ist keine
  # Benutzereingabe, auf die etwas reagieren soll.
  $script:updateListRefreshing = $true
  $updateListBox.BeginUpdate()
  try {
    $updateListBox.Items.Clear()
    foreach ($m in $models) { [void]$updateListBox.Items.Add((New-UpdateRow -App $m)) }
  } finally {
    $updateListBox.EndUpdate()
    $script:updateListRefreshing = $false
  }
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
# Beim Aufbau schon MIT Verbindungszustand: ohne Anmeldung stand hier "auf 'Nach Updates suchen'
# klicken" - und genau das geht dann nicht. Set-ConnectedUIState pflegt den Text spaeter weiter,
# lief aber nur bei An- und Abmeldung, nie beim Start.
Set-ListEmptyText -Label $updatesEmptyLabel -NormalKey 'UpdatesEmptyHint'
$updatesEmptyLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$updatesEmptyLabel.Location = $updateListBox.Location
$updatesEmptyLabel.Size = $updateListBox.Size
$cardUpdates.Controls.Add($updatesEmptyLabel)
# Start empty: show the hint, hide the (empty) list so the native control can't paint over it.
$updateListBox.Visible = $false
$updatesEmptyLabel.Visible = $true
$updatesEmptyLabel.BringToFront()

# Die Schutzliste von hier aus pflegen, ohne den Bereich zu wechseln.
#
# Der Rechtsklick auf eine Zeile deckt "genau diese App" ab; was er nicht kann, sind Muster
# ('Splashtop*', 'TeamViewer*') und das Nachsehen, was ueberhaupt drinsteht. Beides ist genau dann
# gefragt, wenn man auf die Trefferliste schaut - deshalb steht der Knopf hier und nicht nur in den
# Einstellungen. Rechtsbuendig in der Kopfzeile der Karte: die Knopfreihe unten ist voll, und dort
# stehen die Aktionen, die etwas im Tenant tun. Diese hier tut das nicht.
$protectedManageButton = New-Object System.Windows.Forms.Button
$protectedManageButton.Tag = 'btn-secondary'
$protectedManageButton.Text = Get-UiString 'UpdateProtectedManageButton'
$protectedManageButton.Location = New-Object System.Drawing.Point(530,6)
$protectedManageButton.Size = New-Object System.Drawing.Size(182,26)
$cardUpdates.Controls.Add($protectedManageButton)
try { if ($toolTip) { $toolTip.SetToolTip($protectedManageButton, (Get-UiString 'TtProtectedManage')) } } catch { Write-LogDebug 'protected manage tooltip' }

$protectedManageButton.Add_Click({
  # Die ausgewaehlte Zeile fuellt das Eingabefeld vor: der haeufigste Fall ist "diese App hier".
  $suggested = ''
  try {
    $sel = @($updateListBox.SelectedItems)
    if ($sel.Count -gt 0 -and $sel[0].Tag) { $suggested = [string]$sel[0].Tag.Name }
  } catch { Write-LogDebug 'protected dialog suggestion' }
  Show-ProtectedAppsDialog -SuggestedPattern $suggested
})

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

# Zurueckgenommen auf btn-secondary und mit der Zahl im Text (siehe Update-UpdatesEmptyState):
# "Ausgewaehlte aktualisieren" und "ALLE aktualisieren" standen gleich gross und gleich betont
# nebeneinander, und die ganze Warnung hing an der Grossschreibung. Wer die Liste gefiltert hatte,
# sah nicht mehr, wie viele Apps "ALLE" bedeutet - die Zahl steht jetzt VOR dem Klick da.
$updateAllButton = New-Object System.Windows.Forms.Button
$updateAllButton.Tag = 'btn-secondary'
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
# Hoehe der Abgeloeste-Karte: nach INHALT, nicht fest.
#
# Sie ersetzt ein einzeiliges Auswahlfeld und braucht sichtbare Zeilen, sonst waere die
# Mehrfachauswahl nur theoretisch bedienbar. Eine feste Hoehe von 220 px nahm sie sich aber auch
# dann, wenn die Liste leer ist - und das ist der Normalfall, solange man auf die Update-Liste
# darueber schaut. Zusammen mit der dritten Karte fehlten der Update-Liste damit 200 px: bei einem
# 853 px hohen Fenster blieben ihr 97 px, also vier Zeilen mit Bildlaufleiste bei zwei Treffern.
#
# Jetzt: drei Zeilen im Leerzustand, waechst mit dem Inhalt bis acht. Die Karte, in der etwas steht,
# bekommt den Platz - und die Update-Liste bekommt ihn zurueck, sobald die andere leer ist.
# Leer: drei Zeilen, damit die Update-Liste darueber den Platz bekommt. MIT Inhalt: mindestens
# fuenf sichtbare Zeilen. Vorher wurden bei sechs gefundenen Apps zwei angezeigt - nicht wegen
# dieser Rechnung, sondern weil nach dem Fuellen der Liste niemand die Anordnung neu berechnete
# (siehe Update-SupersededListState). Beides gehoert zusammen: Zahl UND Zeitpunkt.
$script:supersededRowsMin = 3
$script:supersededRowsWithContent = 5
$script:supersededRowsMax = 10
$script:supersededCardHeight = 220
function Get-SupersededCardHeight {
  $rows = $script:supersededRowsMin
  try {
    $count = [int]$supersededListBox.Items.Count
    if ($count -gt 0) {
      $rows = [Math]::Max($script:supersededRowsWithContent, [Math]::Min($count, $script:supersededRowsMax))
    }
  } catch { }
  # Untergrenze 18: eine CheckedListBox zeichnet ihre Zeile hoeher, als ItemHeight beim Aufbau
  # sagt. Mit 17 gerechnet passten von drei eingeplanten Zeilen nur zwei ins Bild (gemessen).
  $rowHeight = 18
  try { if ([int]$supersededListBox.ItemHeight -gt $rowHeight) { $rowHeight = [int]$supersededListBox.ItemHeight } } catch { }
  # 72 ueber der Liste (Titel + Suchknopf), 10 Abstand + 30 Knopfreihe + 16 Rand darunter,
  # +4 fuer den Rahmen der Liste - sonst kostet er die letzte eingeplante Zeile.
  return (72 + ($rows * $rowHeight) + 4 + 10 + 30 + 16)
}
# Die dritte Karte traegt eine erklaerende Zeile, deren Hoehe von der Schrift abhaengt - sie wird
# deshalb aus dem Label gelesen statt geraten, sobald es existiert.
$script:versionCleanupCardHeight = 96
function Update-UpdatesLayout {
  try {
    if (-not $tabUpdate -or -not $cardUpdates -or -not $cardSuperseded) { return }
    $avail = $tabUpdate.ClientSize.Height
    if ($avail -lt 200) { return }
    $topY = 48; $gap = 12; $bottomPad = 6
    # Masse der Knopfreihe, gebraucht sowohl fuer die Mindesthoehe der Karte als auch weiter unten.
    $btnHMin = 30; $btnGapMin = 10; $btnPadMin = 16
    if ($versionCleanupHintLabel) {
      $script:versionCleanupCardHeight = [Math]::Max(96, $versionCleanupHintLabel.Bottom + 14)
    }
    if ($supersededListBox) { $script:supersededCardHeight = Get-SupersededCardHeight }
    $updH = $avail - $topY - (2 * $gap) - $script:supersededCardHeight - $script:versionCleanupCardHeight - $bottomPad
    # Die Mindesthoehe der Karte muss aus ihrem Inhalt kommen, nicht aus einer runden Zahl. Solange
    # hier 180 stand und die Liste getrennt davon auf 80 begrenzt war, widersprachen sich die beiden
    # Grenzen: 72 (Filterzeile) + 80 (Liste) + 40 (Knopfreihe) + 16 = 208 passen nicht in 180, und
    # die Knopfreihe stand halb ausserhalb der Karte. Aufgefallen, als die Abgeloeste-Karte von 120
    # auf 220 px wuchs und die Rechnung erstmals in diesen Bereich geriet. Die Sektion scrollt.
    $minUpdH = 72 + 80 + $btnGapMin + $btnHMin + $btnPadMin
    if ($updH -lt $minUpdH) { $updH = $minUpdH }
    $cardUpdates.Height  = $updH
    # Inside the card: list fills everything between the filter row (Y=72) and the button row.
    # The button HEIGHT is set here as well: the layout reserved 32px while the buttons kept their
    # 23px default, so the row floated in the reserved space and ended up visually crowding the
    # card's bottom border ("the card overlaps the buttons"). Reserving and setting the same value
    # keeps a clean, constant 16px below the row.
    $btnH = $btnHMin; $btnGap = $btnGapMin; $btnPadBottom = $btnPadMin
    $listH = $updH - 72 - $btnH - $btnGap - $btnPadBottom
    if ($listH -lt 80) { $listH = 80 }
    $updateListBox.Height = $listH

    # Width follows the card, and the extra space is handed to the columns that actually truncate:
    # long app names first, then the note, and a little to the version columns so build numbers
    # like "150.0.7871.187" stay readable.
    $listW = [Math]::Max(698, $cardUpdates.ClientSize.Width - 28)
    $updateListBox.Width = $listW
    # Die vertikale Bildlaufleiste liegt INNERHALB der Liste und verkleinert die Flaeche, auf der
    # die Spalten Platz haben. Ohne diesen Abzug ergab die Verteilung 1577 px Spalten in 1568 px
    # Sichtflaeche - neun Pixel zu viel, und die Liste bekam zusaetzlich eine waagerechte
    # Bildlaufleiste. Immer abziehen, nicht nur wenn sie gerade sichtbar ist: sie erscheint, sobald
    # eine Zeile mehr dazukommt, und dann waere die Verteilung wieder falsch.
    $listW = $listW - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2
    $extra = $listW - 698
    if ($extra -gt 0 -and $updateListBox.Columns.Count -ge 5) {
      $updateListBox.Columns[0].Width = 235 + [int]($extra * 0.40)
      $updateListBox.Columns[1].Width = 100 + [int]($extra * 0.13)
      $updateListBox.Columns[2].Width = 100 + [int]($extra * 0.13)
      $updateListBox.Columns[3].Width = 110 + [int]($extra * 0.14)
      $updateListBox.Columns[4].Width = 145 + [int]($extra * 0.20)
    }
    if ($updatesEmptyLabel) { $updatesEmptyLabel.Size = $updateListBox.Size }
    # Die Knopfreihe wird an ihren Beschriftungen gemessen und von links aufgereiht, statt vier
    # Pixelbreiten zu pflegen: "Ausgewaehlte Apps aktualisieren" und "ALLE aktualisieren (auch nicht
    # ausgewaehlte)" waren in der deutschen Fassung beide abgeschnitten - und bei einem Knopf, der
    # einen Update-Lauf im Kundentenant startet, ist eine halbe Beschriftung das falsche Detail zum
    # Sparen. Reicht die Breite nicht, behaelt der letzte Knopf den Rest; abgeschnitten wird dann
    # immer noch, aber erst als letzte Massnahme und nicht schon bei der Entwurfsbreite.
    $btnY = 72 + $listH + $btnGap
    $btnX = 14
    $btnSpacing = 6
    $row = @($checkAllButton, $uncheckAllButton, $updateSelectedButton, $updateAllButton)
    foreach ($b in $row) {
      if (-not $b) { continue }
      $b.Top = $btnY
      $b.Height = $btnH
      $needed = 120
      try {
        $t = [string]$b.Text
        if ($t) { $needed = [Math]::Max(110, [System.Windows.Forms.TextRenderer]::MeasureText($t, $b.Font).Width + 26) }
      } catch { }
      $b.Left = $btnX
      $b.Width = $needed
      $btnX += $needed + $btnSpacing
    }
    # Ueberhang nach rechts abfangen: lieber alle vier gleichmaessig schmaler als einen aus der Karte.
    $rowRight = $btnX - $btnSpacing
    $rowRoom = $cardUpdates.ClientSize.Width - 28
    if ($rowRight -gt $rowRoom -and $rowRight -gt 0) {
      $factor = $rowRoom / $rowRight
      $btnX = 14
      foreach ($b in $row) {
        if (-not $b) { continue }
        $b.Left = $btnX
        $b.Width = [Math]::Max(70, [int]($b.Width * $factor))
        $btnX += $b.Width + $btnSpacing
      }
    }
    $cardSuperseded.Top    = $cardUpdates.Bottom + $gap
    $cardSuperseded.Height = $script:supersededCardHeight
    # Liste und Knopfreihe der Abgeloeste-Karte an die Kartenbreite bringen.
    if ($supersededListBox) {
      $supW = [Math]::Max(698, $cardSuperseded.ClientSize.Width - 28)
      $supH = [Math]::Max(51, $script:supersededCardHeight - 72 - 30 - 10 - 16)
      $supersededListBox.Size = New-Object System.Drawing.Size($supW, $supH)
      if ($supersededEmptyLabel) { $supersededEmptyLabel.Size = $supersededListBox.Size }
      $supRowY = 72 + $supH + 10
      $supX = 14
      foreach ($b in @($supersededCheckAllButton, $supersededUncheckAllButton, $deleteSelectedAppButton, $removeOldAppsButton)) {
        if (-not $b) { continue }
        $w = 120
        try {
          $t = [string]$b.Text
          if ($t) { $w = [Math]::Max(110, [System.Windows.Forms.TextRenderer]::MeasureText($t, $b.Font).Width + 26) }
        } catch { }
        $b.Top = $supRowY; $b.Height = 30; $b.Left = $supX; $b.Width = $w
        $supX += $w + 6
      }
    }
    if ($cardVersionCleanup) {
      # Der Hinweis stand auf festen 430 px Umbruchbreite und brach auf einem breiten Bildschirm
      # nach einem Drittel der Karte um, waehrend rechts daneben nichts stand.
      if ($versionCleanupHintLabel) {
        $hintW = [Math]::Max(400, $cardVersionCleanup.ClientSize.Width - 300)
        $versionCleanupHintLabel.MaximumSize = New-Object System.Drawing.Size($hintW, 0)
        $script:versionCleanupCardHeight = [Math]::Max(96, $versionCleanupHintLabel.Bottom + 14)
      }
      $cardVersionCleanup.Top    = $cardSuperseded.Bottom + $gap
      $cardVersionCleanup.Height = $script:versionCleanupCardHeight
    }
  } catch { Write-LogDebug ("Updates layout: {0}" -f $_.Exception.Message) }
}

$cardSuperseded = New-Card -X 16 -Y 318 -W 726 -H 220
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

# Auswahlliste statt Auswahlfeld: in einer ComboBox war genau eine App sichtbar, die Anzahl gar
# nicht, und mehrere gezielt zu loeschen war unmoeglich - waehrend daneben "Alle abgeloesten Apps
# loeschen" stand. Man konnte also EINE oder ALLE loeschen und nichts dazwischen. Die Update-Karte
# darueber macht es in derselben Sektion mit Checkboxen vor; jetzt tun es beide gleich.
$supersededListBox = New-Object System.Windows.Forms.CheckedListBox
$supersededListBox.Location = New-Object System.Drawing.Point(14,72)
$supersededListBox.Size = New-Object System.Drawing.Size(698, 96)
$supersededListBox.CheckOnClick = $true
$supersededListBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$cardSuperseded.Controls.Add($supersededListBox)

# Leerzustand als Beschriftung UEBER der Liste, nach demselben Muster wie in der Update-Karte:
# entweder Liste oder Hinweis, niemals beides - ein natives Listenfeld malt sonst darueber.
$supersededEmptyLabel = New-Object System.Windows.Forms.Label
$supersededEmptyLabel.Tag = 'list-overlay'
Set-ListEmptyText -Label $supersededEmptyLabel -NormalKey 'SupersededEmptyHint'
$supersededEmptyLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$supersededEmptyLabel.Location = $supersededListBox.Location
$supersededEmptyLabel.Size = $supersededListBox.Size
$cardSuperseded.Controls.Add($supersededEmptyLabel)
$supersededListBox.Visible = $false
$supersededEmptyLabel.Visible = $true
$supersededEmptyLabel.BringToFront()

$supersededCheckAllButton = New-Object System.Windows.Forms.Button
$supersededCheckAllButton.Tag = 'btn-secondary'
$supersededCheckAllButton.Text = Get-UiString 'CheckAllButton'
$supersededCheckAllButton.Location = New-Object System.Drawing.Point(14,178)
$supersededCheckAllButton.Height = 30
$supersededCheckAllButton.Enabled = $false
$cardSuperseded.Controls.Add($supersededCheckAllButton)

$supersededUncheckAllButton = New-Object System.Windows.Forms.Button
$supersededUncheckAllButton.Tag = 'btn-secondary'
$supersededUncheckAllButton.Text = Get-UiString 'UncheckAllButton'
$supersededUncheckAllButton.Location = New-Object System.Drawing.Point(150,178)
$supersededUncheckAllButton.Height = 30
$supersededUncheckAllButton.Enabled = $false
$cardSuperseded.Controls.Add($supersededUncheckAllButton)

$supersededCheckAllButton.Add_Click({
  for ($i = 0; $i -lt $supersededListBox.Items.Count; $i++) { $supersededListBox.SetItemChecked($i, $true) }
})
$supersededUncheckAllButton.Add_Click({
  for ($i = 0; $i -lt $supersededListBox.Items.Count; $i++) { $supersededListBox.SetItemChecked($i, $false) }
})

$deleteSelectedAppButton = New-Object System.Windows.Forms.Button
$deleteSelectedAppButton.Text = Get-UiString 'DeleteSelectedAppButton'
$deleteSelectedAppButton.Location = New-Object System.Drawing.Point(286,178)
$deleteSelectedAppButton.Height = 30
$deleteSelectedAppButton.Enabled = $false
$cardSuperseded.Controls.Add($deleteSelectedAppButton)

$removeOldAppsButton = New-Object System.Windows.Forms.Button
$removeOldAppsButton.Tag = 'btn-secondary'
$removeOldAppsButton.Text = Get-UiString 'RemoveOldAppsButton'
$removeOldAppsButton.Location = New-Object System.Drawing.Point(430,178)
$script:keepVersionCount = if ([int]$script:settings.KeepVersionCount -ge 1) { [int]$script:settings.KeepVersionCount } else { 2 }
$removeOldAppsButton.Height = 30
$removeOldAppsButton.Enabled = $false
$cardSuperseded.Controls.Add($removeOldAppsButton)

# Zustand der Liste: Hinweis ODER Liste, und die vier Knoepfe nur dann bedienbar, wenn es etwas
# zu bedienen gibt. Der Suchknopf bleibt immer aktiv - er ist der Weg zu einem Ergebnis.
function Update-SupersededListState {
  try {
    $count = $supersededListBox.Items.Count
    Set-ListEmptyText -Label $supersededEmptyLabel -NormalKey 'SupersededEmptyHint'
    $supersededListBox.Visible = ($count -gt 0)
    $supersededEmptyLabel.Visible = ($count -eq 0)
    if ($count -eq 0) { $supersededEmptyLabel.BringToFront() }
    foreach ($b in @($supersededCheckAllButton, $supersededUncheckAllButton, $deleteSelectedAppButton)) {
      if ($b) { $b.Enabled = ($count -gt 0) }
    }
    # Die Karte richtet sich nach der ZEILENZAHL - also muss sie neu vermessen werden, sobald die
    # Liste gefuellt ist. Ohne diesen Aufruf behielt sie die Hoehe des Leerzustands (drei Zeilen),
    # und von sechs gefundenen Apps waren zwei zu sehen.
    if (Get-Command Update-UpdatesLayout -ErrorAction SilentlyContinue) {
      try { Update-UpdatesLayout } catch { Write-LogDebug 'superseded layout after fill' }
    }
  } catch { Write-LogDebug 'superseded list state' }
}

# --- Card 3: version history of ALL managed apps ---
#
# Eigene Karte, weil die REICHWEITE eine andere ist. Der Knopf stand in der Karte "Abgelöste (alte)
# App-Versionen", direkt neben einer Liste abgelöster Apps - und wirkte auf jede verwaltete App im
# Tenant. Sein Tooltip musste die Karte um ihn herum richtigstellen ("Wirkt auf ALLE verwalteten
# Apps, nicht nur auf die hier gelisteten abgelösten"). Ein Tooltip, der seine Umgebung korrigieren
# muss, ist der Beweis, dass die Umgebung falsch ist - erst recht bei einem Knopf, der löscht.
$cardVersionCleanup = New-Card -X 16 -Y 450 -W 726 -H 96
$tabUpdate.Controls.Add($cardVersionCleanup)

$versionCleanupHeaderLabel = New-Object System.Windows.Forms.Label
$versionCleanupHeaderLabel.Text = Get-UiString 'UpdatesCardVersionCleanup'
$versionCleanupHeaderLabel.Location = New-Object System.Drawing.Point(14,10)
$versionCleanupHeaderLabel.AutoSize = $true
$versionCleanupHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardVersionCleanup.Controls.Add($versionCleanupHeaderLabel)
[void](Add-SectionInfoBadge -Parent $cardVersionCleanup -AfterLabel $versionCleanupHeaderLabel -TextKey 'InfoCardVersionCleanup')

# "Keep only N versions": trims each app's version history down to the newest N (default 2), i.e.
# the current one plus its predecessor. Apps that only have one version are never touched.
$versionCleanupButton = New-Object System.Windows.Forms.Button
$versionCleanupButton.Tag = 'btn-secondary'
$versionCleanupButton.Text = (Get-UiString 'VersionCleanupButton') -f $script:keepVersionCount
$versionCleanupButton.Location = New-Object System.Drawing.Point(14,38)
$versionCleanupButton.Width = 250
$versionCleanupButton.Height = 30
$cardVersionCleanup.Controls.Add($versionCleanupButton)
$versionCleanupButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  Invoke-VersionCleanup -KeepCount $script:keepVersionCount
})

$versionCleanupHintLabel = New-Object System.Windows.Forms.Label
$versionCleanupHintLabel.Tag = 'hint'
$versionCleanupHintLabel.Text = Get-UiString 'HintVersionCleanupCard'
$versionCleanupHintLabel.AutoSize = $true
$versionCleanupHintLabel.MaximumSize = New-Object System.Drawing.Size(430, 0)
$versionCleanupHintLabel.Location = New-Object System.Drawing.Point(280, 34)
$cardVersionCleanup.Controls.Add($versionCleanupHintLabel)

# ==================================================
# Section: Discovered Apps
# ==================================================
$tabDiscovered = New-Object System.Windows.Forms.Panel
Add-Section -Key 'discovered' -Panel $tabDiscovered -Label (Get-UiString 'TabDiscovered') -Group 'manage'

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

$discoveredAssignFavButton = New-Object System.Windows.Forms.Button
$discoveredAssignFavButton.Tag = 'btn-secondary'
$discoveredAssignFavButton.Text = Get-UiString 'FavAddButton'
$discoveredAssignFavButton.Location = New-Object System.Drawing.Point(566, 70)
$discoveredAssignFavButton.Size = New-Object System.Drawing.Size(96, 26)
$discoveredAssignFavButton.Visible = $true
$discoveredAssignFavButton.Add_Click({ Show-GroupFavoriteDialog -GroupIdBox $discoveredAssignGroupIdBox })
$cardScan.Controls.Add($discoveredAssignFavButton)

$discoveredAssignTargetCombo.Add_SelectedIndexChanged({
  $isCustom = ($discoveredAssignTargetCombo.SelectedItem -eq (Get-UiString 'AssignCustomGroup'))
  $discoveredAssignGroupIdBox.Visible = $isCustom
})
Register-AssignTargetCombo -TargetCombo $discoveredAssignTargetCombo

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
# 176 statt 140: "<Alle Herausgeber>" ist laenger als "<All Publishers>" und wurde abgeschnitten -
# dieselbe Klasse Fehler wie bei den Knoepfen (F17), nur in einem Auswahlfeld.
$discoveredPublisherBox.Width = 176
$discoveredPublisherBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$discoveredPublisherBox.Items.Add((Get-UiString 'DiscoveredPublisherAll'))
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
[void]$discoveredSortBox.Items.Add((Get-UiString 'DiscoveredSortByDevices'))
[void]$discoveredSortBox.Items.Add((Get-UiString 'DiscoveredSortAlphabetical'))
$discoveredSortBox.SelectedIndex = 0
$cardDetected.Controls.Add($discoveredSortBox)

$checkAllDiscoveredButton = New-Object System.Windows.Forms.Button
$checkAllDiscoveredButton.Tag = 'btn-secondary'
$checkAllDiscoveredButton.Text = Get-UiString 'CheckAllDiscoveredButton'
$checkAllDiscoveredButton.Location = New-Object System.Drawing.Point(14,66)
# 124 statt 110: "Alle auswaehlen" samt Haken braucht 111 px plus Innenabstand - es fehlte genau
# ein Pixel, und das letzte Zeichen wurde abgeschnitten.
$checkAllDiscoveredButton.Width = 124
$checkAllDiscoveredButton.Enabled = $false
$cardDetected.Controls.Add($checkAllDiscoveredButton)

$uncheckAllDiscoveredButton = New-Object System.Windows.Forms.Button
$uncheckAllDiscoveredButton.Tag = 'btn-secondary'
$uncheckAllDiscoveredButton.Text = Get-UiString 'UncheckAllDiscoveredButton'
$uncheckAllDiscoveredButton.Location = New-Object System.Drawing.Point(146,66)
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
Set-ListEmptyText -Label $discoveredEmptyLabel -NormalKey 'DiscoveredEmptyHint'
$discoveredEmptyLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$discoveredEmptyLabel.Location = $discoveredListBox.Location
$discoveredEmptyLabel.Size = $discoveredListBox.Size
$discoveredEmptyLabel.Anchor = $discoveredListBox.Anchor
$cardDetected.Controls.Add($discoveredEmptyLabel)
# Start empty: show the hint, hide the (empty) list.
$discoveredListBox.Visible = $false
$discoveredEmptyLabel.Visible = $true

# Die Ergebnisliste stand auf festen 158 px - vier Zeilen, egal wie gross das Fenster war. Gemessen
# bei 1146x854: die Karte endete auf 472, der Bereich hat 639 - 167 px blieben ungenutzt, waehrend
# man in einer Vier-Zeilen-Liste durch dreissig erkannte Apps scrollte.
#
# Aufgebaut wie Update-StoreLayout, weil es dasselbe Muster ist: die obere Karte bekommt ihre Hoehe
# aus dem Inhalt, die untere den Rest.
function Update-DiscoveredLayout {
  try {
    if (-not $tabDiscovered -or -not $cardScan -or -not $cardDetected -or -not $discoveredListBox) { return }
    $avail = $tabDiscovered.ClientSize.Height
    if ($avail -lt 200) { return }
    $topY = 48; $gap = 12; $bottomPad = 6

    # Karte 1 misst sich selbst (setzt Top einschliesslich Scrollversatz und Height).
    Update-StackedCards -Panel $tabDiscovered -Cards @($cardScan) -Top $topY -Gap $gap

    # Was ueber der Liste steht (Titel, Filterzeile, Knopfreihe), wird an der Liste abgelesen statt
    # gezaehlt - sonst muesste diese Zahl bei jeder neuen Filterzeile von Hand nachgezogen werden.
    $chrome = $discoveredListBox.Top + 16
    $detectedH = $avail - $topY - $cardScan.Height - $gap - $bottomPad
    $minDetectedH = $chrome + 120
    if ($detectedH -lt $minDetectedH) { $detectedH = $minDetectedH }
    $cardDetected.Top = $cardScan.Bottom + $gap
    $cardDetected.Height = $detectedH

    # Nur die Hoehe: die Breite haengt am Right-Anker der Liste und wird von Update-CardWidths
    # gefuehrt. Wer sie hier zusaetzlich setzt, kaempft gegen den Anker.
    $listH = $detectedH - $chrome
    $discoveredListBox.Height = $listH
    # Der Leerzustand belegt exakt das Rechteck der Liste (siehe Kommentar dort) - er muss also
    # mitwachsen, sonst steht der zentrierte Hinweis nach einem Resize nicht mehr in der Mitte.
    if ($discoveredEmptyLabel) { $discoveredEmptyLabel.Height = $listH }
  } catch { Write-LogDebug 'discovered layout' }
}

$script:discoveredRaw = @()

# ==================================================
# Section: Delivery settings (bulk editor)
# ==================================================
#
# Derselbe Editor, der frueher nur als Modaldialog hinter "Extras" lag. Fuer ein Feature, mit dem
# man Benachrichtigungen, Verfuegbarkeit, Fristen, Neustartverhalten und Zustellprioritaet fuer
# beliebig viele Apps auf einmal setzt, war das zu wenig Platz und zu tief versteckt.
#
# Der Inhalt wird von Show-AppSettingsDialog gebaut - dieselbe Funktion, dasselbe Verhalten, nur
# mit einem Panel statt einem Fenster als Elternobjekt. Der Dialogweg bleibt: der Einzelfall-Knopf
# in "Alle Tenant-Apps" ruft ihn weiterhin ohne -HostPanel auf.
$tabAppSettings = New-Object System.Windows.Forms.Panel
$tabAppSettings.AutoScroll = $true
Add-Section -Key 'appsettings' -Panel $tabAppSettings -Label (Get-UiString 'TabAppSettings') -Group 'manage'

$appSettingsHeaderLabel = New-Object System.Windows.Forms.Label
$appSettingsHeaderLabel.Text = Get-UiString 'AppSettingsTitle'
$appSettingsHeaderLabel.Location = New-Object System.Drawing.Point(16, 12)
$appSettingsHeaderLabel.AutoSize = $true
$appSettingsHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabAppSettings.Controls.Add($appSettingsHeaderLabel)
[void](Add-SectionInfoBadge -Parent $tabAppSettings -AfterLabel $appSettingsHeaderLabel -TextKey 'InfoAppSettings')

# Eigenes Panel statt direkt in die Sektion: der Editor setzt seine Steuerelemente ab y=10, das
# wuerde sonst unter dem Titel liegen. Die Groesse ist die des frueheren Dialogs - die Anker darin
# beziehen sich darauf, und Update-AppSettingsLayout zieht sie auf die Sektionsbreite.
$appSettingsHost = New-Object System.Windows.Forms.Panel
$appSettingsHost.Location = New-Object System.Drawing.Point(16, 48)
$appSettingsHost.Size = New-Object System.Drawing.Size(726, 790)
$tabAppSettings.Controls.Add($appSettingsHost)
Show-AppSettingsDialog -HostPanel $appSettingsHost

# ==================================================
# Section: Leistungsnachweis
# ==================================================
#
# War ein Menueeintrag unter "Extras". Eine Auswertung, die man liest, umschaltet und in ein Ticket
# kopiert, gehoert an einen sichtbaren Ort - und sie ist eine Sache DIESES Rechners: gespeist wird
# sie aus der lokalen Aufzeichnung (%LOCALAPPDATA%\WinTunerGUI\activity-history.json), nicht aus
# Intune. Deshalb steht sie in der Gruppe "Dieser Rechner".
$tabWorkRecord = New-Object System.Windows.Forms.Panel
$tabWorkRecord.AutoScroll = $true
Add-Section -Key 'workrecord' -Panel $tabWorkRecord -Label (Get-UiString 'NavWorkRecord') -Group 'local'

$workRecordHeaderLabel = New-Object System.Windows.Forms.Label
$workRecordHeaderLabel.Text = Get-UiString 'LeistungDialogTitle'
$workRecordHeaderLabel.Location = New-Object System.Drawing.Point(16, 12)
$workRecordHeaderLabel.AutoSize = $true
$workRecordHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabWorkRecord.Controls.Add($workRecordHeaderLabel)
[void](Add-SectionInfoBadge -Parent $tabWorkRecord -AfterLabel $workRecordHeaderLabel -TextKey 'InfoWorkRecord')

$workRecordHost = New-Object System.Windows.Forms.Panel
$workRecordHost.Location = New-Object System.Drawing.Point(16, 48)
$workRecordHost.Size = New-Object System.Drawing.Size(726, 480)
$tabWorkRecord.Controls.Add($workRecordHost)
Show-LeistungstextDialog -HostPanel $workRecordHost

function Update-WorkRecordSectionLayout {
  try {
    if (-not $tabWorkRecord -or -not $workRecordHost) { return }
    $w = [Math]::Max(560, $tabWorkRecord.ClientSize.Width - 32)
    $h = [Math]::Max(300, $tabWorkRecord.ClientSize.Height - 54)
    $workRecordHost.Size = New-Object System.Drawing.Size($w, $h)
    if ((Get-Command Update-WorkRecordLayout -ErrorAction SilentlyContinue) -and
        $script:workRecordUi -and $script:workRecordUi.Embedded) {
      Update-WorkRecordLayout
    }
  } catch { Write-LogDebug 'work record section layout' }
}

# ==================================================
# Section: Kundendaten
# ==================================================
#
# Fuehrt die drei kundenbezogenen Datenbestaende zusammen, die vorher an drei Stellen lagen:
# Gruppen-Favoriten (nur ueber den Knopf "Gruppen..." neben einem Zuweisungsziel erreichbar),
# Kundennamen (ein Menuepunkt unter Extras) und gemerkte Anmeldungen (Kopfzeile plus ein zweiter
# Menuepunkt unter Extras). Wer wissen wollte, was diese Anwendung ueber seine Kunden gespeichert
# hat, musste das an drei Orten nachsehen - und die Gruppen-Favoriten fand ohne Vorwissen niemand.
#
# Gruppe "Dieser Rechner": es sind rein lokale Daten. Kein Aufruf von hier schreibt oder liest
# etwas in Intune.
#
# Die vorhandenen Bearbeitungswege bleiben und werden von hier aus geoeffnet, statt sie ein zweites
# Mal zu bauen - zwei Fassungen derselben Bearbeitung waeren zwei Fassungen ihrer Regeln.
$tabCustomerData = New-Object System.Windows.Forms.Panel
$tabCustomerData.AutoScroll = $true
Add-Section -Key 'customerdata' -Panel $tabCustomerData -Label (Get-UiString 'NavCustomerData') -Group 'local'

$customerDataHeaderLabel = New-Object System.Windows.Forms.Label
$customerDataHeaderLabel.Text = Get-UiString 'CustomerDataTitle'
$customerDataHeaderLabel.Location = New-Object System.Drawing.Point(16, 12)
$customerDataHeaderLabel.AutoSize = $true
$customerDataHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabCustomerData.Controls.Add($customerDataHeaderLabel)
[void](Add-SectionInfoBadge -Parent $tabCustomerData -AfterLabel $customerDataHeaderLabel -TextKey 'InfoCustomerData')

# --- Karte 1: Kundennamen ---
$cardCustomerNames = New-Card -X 16 -Y 48 -W 726 -H 230
$tabCustomerData.Controls.Add($cardCustomerNames)

$customerNamesTitle = New-Object System.Windows.Forms.Label
$customerNamesTitle.Text = Get-UiString 'CustomerNamesCardTitle'
$customerNamesTitle.Location = New-Object System.Drawing.Point(14, 10)
$customerNamesTitle.AutoSize = $true
$customerNamesTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardCustomerNames.Controls.Add($customerNamesTitle)

$customerNamesHint = New-Object System.Windows.Forms.Label
$customerNamesHint.Tag = 'hint'
$customerNamesHint.Text = Get-UiString 'CustomerNamesCardHint'
$customerNamesHint.Location = New-Object System.Drawing.Point(14, 32)
$customerNamesHint.Size = New-Object System.Drawing.Size(690, 20)
$cardCustomerNames.Controls.Add($customerNamesHint)

$customerNamesList = New-Object System.Windows.Forms.ListView
$customerNamesList.Location = New-Object System.Drawing.Point(14, 58)
$customerNamesList.Size = New-Object System.Drawing.Size(698, 120)
$customerNamesList.View = [System.Windows.Forms.View]::Details
$customerNamesList.FullRowSelect = $true
$customerNamesList.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
$customerNamesList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
[void]$customerNamesList.Columns.Add((Get-UiString 'ColCustomerDomain'), 330)
[void]$customerNamesList.Columns.Add((Get-UiString 'ColCustomerName'), 340)
$cardCustomerNames.Controls.Add($customerNamesList)

$customerNamesEditButton = New-Object System.Windows.Forms.Button
$customerNamesEditButton.Tag = 'btn-secondary'
$customerNamesEditButton.Text = Get-UiString 'CustomerNamesEditButton'
$customerNamesEditButton.Location = New-Object System.Drawing.Point(14, 186)
$customerNamesEditButton.Width = 230
$customerNamesEditButton.Height = 32
$customerNamesEditButton.Add_Click({
  Show-TenantNamesDialog
  Update-CustomerDataLists
})
$cardCustomerNames.Controls.Add($customerNamesEditButton)

# --- Karte 2: Gruppen-Favoriten des aktuellen Kunden ---
$cardGroupFavorites = New-Card -X 16 -Y 290 -W 726 -H 230
$tabCustomerData.Controls.Add($cardGroupFavorites)

$groupFavoritesTitle = New-Object System.Windows.Forms.Label
$groupFavoritesTitle.Text = Get-UiString 'GroupFavoritesCardTitle'
$groupFavoritesTitle.Location = New-Object System.Drawing.Point(14, 10)
$groupFavoritesTitle.AutoSize = $true
$groupFavoritesTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardGroupFavorites.Controls.Add($groupFavoritesTitle)

$groupFavoritesHint = New-Object System.Windows.Forms.Label
$groupFavoritesHint.Tag = 'hint'
$groupFavoritesHint.Text = Get-UiString 'GroupFavoritesCardHint'
$groupFavoritesHint.Location = New-Object System.Drawing.Point(14, 32)
$groupFavoritesHint.Size = New-Object System.Drawing.Size(690, 20)
$cardGroupFavorites.Controls.Add($groupFavoritesHint)

$groupFavoritesList = New-Object System.Windows.Forms.ListView
$groupFavoritesList.Location = New-Object System.Drawing.Point(14, 58)
$groupFavoritesList.Size = New-Object System.Drawing.Size(698, 120)
$groupFavoritesList.View = [System.Windows.Forms.View]::Details
$groupFavoritesList.FullRowSelect = $true
$groupFavoritesList.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
$groupFavoritesList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
[void]$groupFavoritesList.Columns.Add((Get-UiString 'GroupColName'), 330)
[void]$groupFavoritesList.Columns.Add((Get-UiString 'GroupColId'), 340)
$cardGroupFavorites.Controls.Add($groupFavoritesList)

$groupFavoritesEditButton = New-Object System.Windows.Forms.Button
$groupFavoritesEditButton.Tag = 'btn-secondary'
$groupFavoritesEditButton.Text = Get-UiString 'GroupFavoritesEditButton'
$groupFavoritesEditButton.Location = New-Object System.Drawing.Point(14, 186)
$groupFavoritesEditButton.Width = 230
$groupFavoritesEditButton.Height = 32
$groupFavoritesEditButton.Add_Click({
  # Ohne Zieltextfeld: hier wird gepflegt, nicht ausgewaehlt. Show-GroupFavoriteDialog kommt damit
  # zurecht - der Parameter ist optional und wird nur zum Uebernehmen einer Auswahl gebraucht.
  Show-GroupFavoriteDialog
  Update-CustomerDataLists
})
$cardGroupFavorites.Controls.Add($groupFavoritesEditButton)

# --- Karte 3: gemerkte Anmeldungen ---
$cardRecentLogins = New-Card -X 16 -Y 532 -W 726 -H 230
$tabCustomerData.Controls.Add($cardRecentLogins)

$recentLoginsTitle = New-Object System.Windows.Forms.Label
$recentLoginsTitle.Text = Get-UiString 'RecentLoginsCardTitle'
$recentLoginsTitle.Location = New-Object System.Drawing.Point(14, 10)
$recentLoginsTitle.AutoSize = $true
$recentLoginsTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardRecentLogins.Controls.Add($recentLoginsTitle)

$recentLoginsHint = New-Object System.Windows.Forms.Label
$recentLoginsHint.Tag = 'hint'
$recentLoginsHint.Text = Get-UiString 'RecentLoginsCardHint'
$recentLoginsHint.Location = New-Object System.Drawing.Point(14, 32)
$recentLoginsHint.Size = New-Object System.Drawing.Size(690, 20)
$cardRecentLogins.Controls.Add($recentLoginsHint)

$recentLoginsList = New-Object System.Windows.Forms.ListBox
$recentLoginsList.Location = New-Object System.Drawing.Point(14, 58)
$recentLoginsList.Size = New-Object System.Drawing.Size(698, 120)
$recentLoginsList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$cardRecentLogins.Controls.Add($recentLoginsList)

$recentLoginsRemoveButton = New-Object System.Windows.Forms.Button
$recentLoginsRemoveButton.Tag = 'btn-secondary'
$recentLoginsRemoveButton.Text = Get-UiString 'RecentLoginsRemoveButton'
$recentLoginsRemoveButton.Location = New-Object System.Drawing.Point(14, 186)
$recentLoginsRemoveButton.Width = 230
$recentLoginsRemoveButton.Height = 32
$recentLoginsRemoveButton.Add_Click({
  $sel = [string]$recentLoginsList.SelectedItem
  if ([string]::IsNullOrWhiteSpace($sel)) { return }
  $script:settings.RecentLogins = @($script:settings.RecentLogins | Where-Object {
    -not [string]::Equals(([string]$_).Trim(), $sel.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
  })
  Save-Settings
  # Die Adresse selbst gehoert NICHT ins Protokoll - siehe der Datenschutzkommentar in 10-Settings.
  Write-Log ("Customer data: one saved login removed ({0} left)." -f @($script:settings.RecentLogins).Count)
  try { Update-RecentLoginsUI } catch { Write-LogDebug 'recent logins ui after removal' }
  Update-CustomerDataLists
})
$cardRecentLogins.Controls.Add($recentLoginsRemoveButton)

$recentLoginsClearButton = New-Object System.Windows.Forms.Button
$recentLoginsClearButton.Tag = 'btn-secondary'
$recentLoginsClearButton.Text = Get-UiString 'RecentLoginsClearButton'
$recentLoginsClearButton.Location = New-Object System.Drawing.Point(256, 186)
$recentLoginsClearButton.Width = 230
$recentLoginsClearButton.Height = 32
$recentLoginsClearButton.Add_Click({
  # Dieselbe Rueckfrage wie im Menuepunkt - eine Liste zu leeren ist eine Aenderung, kein Blick.
  $confirm = [System.Windows.Forms.MessageBox]::Show(
    (Get-UiString 'ClearRecentLoginsConfirm'),
    (Get-UiString 'ClearRecentLoginsTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  $script:settings.RecentLogins = @()
  Save-Settings
  Write-Log 'Customer data: all saved logins removed.'
  try { Update-RecentLoginsUI } catch { Write-LogDebug 'recent logins ui after clear' }
  Update-CustomerDataLists
  Update-Status (Get-UiString 'RecentLoginsClearedStatus')
})
$cardRecentLogins.Controls.Add($recentLoginsClearButton)

# Fuellt alle drei Listen aus den Einstellungen. Eine Funktion, weil jede Aenderung an einem der
# drei Bestaende diesen Bereich betrifft - und weil er beim Betreten den STAND zeigen muss, nicht
# den von seinem Aufbau: die Kundennamen aendert man im Dialog, die Favoriten am Zuweisungsziel.
function Update-CustomerDataLists {
  try {
    if (-not $customerNamesList) { return }

    $customerNamesList.BeginUpdate()
    try {
      $customerNamesList.Items.Clear()
      $names = if ($script:settings.TenantDisplayNames) { $script:settings.TenantDisplayNames } else { @{} }
      foreach ($k in @($names.Keys | Sort-Object)) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$k)
        [void]$it.SubItems.Add([string]$names[$k])
        [void]$customerNamesList.Items.Add($it)
      }
    } finally { $customerNamesList.EndUpdate() }

    $groupFavoritesList.BeginUpdate()
    try {
      $groupFavoritesList.Items.Clear()
      foreach ($f in @(Get-GroupFavorites)) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$f.Name)
        [void]$it.SubItems.Add([string]$f.Id)
        [void]$groupFavoritesList.Items.Add($it)
      }
    } finally { $groupFavoritesList.EndUpdate() }

    $recentLoginsList.BeginUpdate()
    try {
      $recentLoginsList.Items.Clear()
      foreach ($u in @($script:settings.RecentLogins)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$u)) { [void]$recentLoginsList.Items.Add([string]$u) }
      }
    } finally { $recentLoginsList.EndUpdate() }

    # Eine leere Liste erklaert sich nicht von selbst - und bei Kundendaten ist "leer" die eine
    # Aussage, bei der man sicher sein will, dass sie stimmt. Der Hinweis der Karte traegt sie,
    # statt eines Overlay-Labels: ein natives ListView-HWND uebermalt jede ueberlappende Label
    # (siehe der Leerzustand bei den erkannten Apps).
    if ($customerNamesList.Items.Count -eq 0) {
      $customerNamesHint.Text = Get-UiString 'CustomerNamesEmpty'
    } else {
      $customerNamesHint.Text = Get-UiString 'CustomerNamesCardHint'
    }

    # Die Favoriten haengen am angemeldeten Kunden. Ohne Anmeldung ist die leere Liste keine
    # Aussage ueber den Bestand, sondern ueber die fehlende Sitzung - das muss dastehen, sonst
    # sieht es aus, als waere etwas verlorengegangen.
    $hasTenant = [bool](Get-TenantFavoriteKey)
    $groupFavoritesEditButton.Enabled = $hasTenant
    $groupFavoritesHint.Text = if (-not $hasTenant) { Get-UiString 'GroupFavoritesNoTenant' }
                               elseif ($groupFavoritesList.Items.Count -eq 0) { Get-UiString 'GroupFavoritesEmpty' }
                               else { Get-UiString 'GroupFavoritesCardHint' }

    $recentLoginsRemoveButton.Enabled = ($recentLoginsList.Items.Count -gt 0)
    $recentLoginsClearButton.Enabled = ($recentLoginsList.Items.Count -gt 0)

    # Nur ZAHLEN, nie die Eintraege - dieselbe Regel wie im Protokoll (10-Settings): eine
    # Statuszeile wird abfotografiert und in ein Ticket geklebt.
    Update-Status ((Get-UiString 'CustomerDataCountStatus') -f `
      $customerNamesList.Items.Count, $groupFavoritesList.Items.Count, $recentLoginsList.Items.Count)
  } catch { Write-LogDebug 'customer data lists' }
}

function Update-CustomerDataLayout {
  try {
    if (-not $tabCustomerData -or -not $cardCustomerNames) { return }

    # Die drei Listen teilen sich, was uebrig bleibt. Mit festen 120 px je Liste ragte die dritte
    # Karte bei 1146x854 unten aus dem Bild - gerendert und nachgesehen. Und feste Hoehen waeren
    # hier besonders schade: auf einem grossen Schirm ist genau der Platz da, den eine Kundenliste
    # braucht.
    $lists = @($customerNamesList, $groupFavoritesList, $recentLoginsList)
    $listTop = 58          # ueber der Liste: Kartentitel und Hinweiszeile
    $belowList = 8 + 32    # Abstand und Knopfreihe
    $cardChrome = $listTop + $belowList + 16   # + Innenabstand von Update-StackedCards
    $avail = $tabCustomerData.ClientSize.Height - 48 - (2 * 12) - 6
    $perList = [int](($avail - (3 * $cardChrome)) / 3)
    # Untergrenze: unter sechs Zeilen wird eine Liste zum Guckloch. Passt das nicht mehr ins
    # Fenster, scrollt der Bereich - wie die Einstellungen, und aus demselben Grund.
    if ($perList -lt 120) { $perList = 120 }
    foreach ($l in $lists) {
      if (-not $l) { continue }
      $l.Height = $perList
      # Die Knopfreihe wandert mit der Liste; sie steht in jeder der drei Karten an derselben Stelle.
      foreach ($sibling in $l.Parent.Controls) {
        if ($sibling -is [System.Windows.Forms.Button]) { $sibling.Top = $l.Bottom + 8 }
      }
    }

    Update-StackedCards -Panel $tabCustomerData -Cards @($cardCustomerNames, $cardGroupFavorites, $cardRecentLogins)
  } catch { Write-LogDebug 'customer data layout' }
}

function Update-AppSettingsLayout {
  try {
    if (-not $tabAppSettings -or -not $appSettingsHost) { return }
    $w = [Math]::Max(726, $tabAppSettings.ClientSize.Width - 32)
    # Die feste Mindesthoehe von 790 px war der Grund fuer die Bildlaufleiste: der Editor bekam
    # immer seine Dialoghoehe, auch wenn der Bereich nur 625 px hoch war - und der Knopf "Auf
    # markierte Apps anwenden" lag damit unter der Kante. Jetzt bekommt er genau den Platz, den es
    # gibt, und ordnet seinen Inhalt darin an (siehe Update-AppSettingsEditorLayout).
    $h = [Math]::Max(420, $tabAppSettings.ClientSize.Height - 54)
    $appSettingsHost.Size = New-Object System.Drawing.Size($w, $h)
    if ((Get-Command Update-AppSettingsEditorLayout -ErrorAction SilentlyContinue) -and
        $script:appSettingsUi -and $script:appSettingsUi.Embedded) {
      Update-AppSettingsEditorLayout
    }
  } catch { Write-LogDebug 'app settings layout' }
}

# ==================================================
# Section: Settings
# ==================================================
#
# One card per QUESTION the technician actually has, in the order those questions come up:
#   1 Packaging      - where does this machine build packages, and how do I clean that up
#   2 Update search  - does the tool look for updates on its own (and it only ever LOOKS)
#   3 After an update- what happens to the old version in Intune; the only deleting options
#   4 Prompts        - does a change still ask before it reaches the tenant
#   5 Tool updates   - self-update of this script, nothing to do with Intune apps
#   6 Files          - log and settings paths, and the sanitized export for a ticket
#
# Grouping matters more than it looks: the previous page had "check for updates on login" sitting
# directly above two options that DELETE apps in Intune, in one card called "General", with no
# explanation on any of them. Three switches that only differ in what they destroy read as
# interchangeable when they are stacked like that. Every option now carries a line stating what it
# does, whether it only reads, and what it costs - see Add-SettingRow in 65-Theme.
#
# Two switches that used to hide in the Tools menu (keep assignments before deleting, dashboard
# full scan) and one that hid there behind a risk dialog (skip confirmations) live here now: they
# are settings, they are persisted like settings, and having them in a menu meant they were saved
# on click while everything on this page waited for "Save settings" - the same kind of setting
# behaving in two different ways depending on where it was found.
$tabSettings = New-Object System.Windows.Forms.Panel
# Six stacked cards exceed the panel on any normal window -> scroll.
$tabSettings.AutoScroll = $true
Add-Section -Key 'settings' -Panel $tabSettings -Label (Get-UiString 'TabSettings') -Group 'local'

# Section title
$settingsHeaderLabel = New-Object System.Windows.Forms.Label
$settingsHeaderLabel.Text = Get-UiString 'SettingsHeaderLabel'
$settingsHeaderLabel.Location = New-Object System.Drawing.Point(16,12)
$settingsHeaderLabel.AutoSize = $true
$settingsHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabSettings.Controls.Add($settingsHeaderLabel)
[void](Add-SectionInfoBadge -Parent $tabSettings -AfterLabel $settingsHeaderLabel -TextKey 'InfoSettings')

# Cards are re-stacked by Update-SettingsLayout in this order, so a card that grows (longer
# explanations in German, a bigger retro-theme font) pushes the ones below it down instead of
# overlapping them. The old page positioned every card at a fixed Y and did overlap.
$script:settingsCards = New-Object 'System.Collections.Generic.List[object]'
$script:settingsCardWidth = 726

# Adds a card with its bold title and info badge, and registers it for the stacking pass.
function New-SettingsCard {
  param([Parameter(Mandatory)][string]$TitleKey, [Parameter(Mandatory)][string]$InfoKey)
  $card = New-Card -X 16 -Y 48 -W $script:settingsCardWidth -H 120
  $tabSettings.Controls.Add($card)
  $title = New-Object System.Windows.Forms.Label
  $title.Text = Get-UiString $TitleKey
  $title.Location = New-Object System.Drawing.Point(14,8)
  $title.AutoSize = $true
  $title.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
  $card.Controls.Add($title)
  [void](Add-SectionInfoBadge -Parent $card -AfterLabel $title -TextKey $InfoKey)
  $script:settingsCards.Add($card)
  return $card
}

# Settings-tab action buttons share one width so the stacked column lines up (wide enough
# for the longest German label, "Einstellungen speichern").
$script:settingsButtonWidth = 200

# --- Card 1: packaging on this computer ----------------------------------------------------------
$cardPackaging = New-SettingsCard -TitleKey 'SettingsCardPackaging' -InfoKey 'InfoCardPackaging'

# Label + field + browse button on one line, hosted in a panel so the whole row can be stacked as
# a unit like every other option.
$pathRow = New-Object System.Windows.Forms.Panel
$pathRow.Tag = 'row-host'
$pathRow.Size = New-Object System.Drawing.Size(698, 32)

$defaultPathLabel = New-Object System.Windows.Forms.Label
$defaultPathLabel.Text = Get-UiString 'DefaultPathLabel'
$defaultPathLabel.Location = New-Object System.Drawing.Point(0,7)
$defaultPathLabel.AutoSize = $true
$pathRow.Controls.Add($defaultPathLabel)

# Wrapped in a rounded input host (like the deploy path field) instead of a bare FixedSingle box:
# a plain TextBox has almost no left text padding, so the first character (the drive letter "C")
# looked clipped against the border. The host gives it the consistent rounded look + 10px padding.
$defaultPathTextBox = New-Object System.Windows.Forms.TextBox
# Fall back to the safe per-user default, NOT "C:\Temp": that folder grants Modify to Authenticated
# Users, so another signed-in user could tamper with a finished .intunewin between build and upload.
# Get-DefaultPackagePath is the single source for that safe location (also used in 80-Views/83-OwnPackage).
$defaultPathTextBox.Text = if ($script:settings.DefaultPackagePath) { $script:settings.DefaultPackagePath } else { Get-DefaultPackagePath }
$defaultPathHost = New-RoundedInput -Inner $defaultPathTextBox -X 166 -Y 1 -W 386 -H 30
$pathRow.Controls.Add($defaultPathHost)

$browsePathButton = New-Object System.Windows.Forms.Button
$browsePathButton.Tag = 'btn-secondary'
$browsePathButton.Text = Get-UiString 'BrowsePathButton'
$browsePathButton.Location = New-Object System.Drawing.Point(564,1)
$browsePathButton.Width = 134
$browsePathButton.Height = 30
$pathRow.Controls.Add($browsePathButton)

[void](Add-SettingRow -Card $cardPackaging -Control $pathRow -Hint (Get-UiString 'HintPackagePath'))

# Local disk housekeeping. Both act on this machine only - neither touches the tenant, which is
# what separates them from every other button on this page.
$packagingButtonRow = New-Object System.Windows.Forms.Panel
$packagingButtonRow.Tag = 'row-host'
$packagingButtonRow.Size = New-Object System.Drawing.Size(698, 34)

$prunePackagesButton = New-Object System.Windows.Forms.Button
$prunePackagesButton.Tag = 'btn-secondary'
$prunePackagesButton.Text = Get-UiString 'PrunePackagesButton'
$prunePackagesButton.Location = New-Object System.Drawing.Point(0,0)
$prunePackagesButton.Width = $script:settingsButtonWidth
$prunePackagesButton.Height = 34
$packagingButtonRow.Controls.Add($prunePackagesButton)

$clearCacheButton = New-Object System.Windows.Forms.Button
$clearCacheButton.Tag = 'btn-secondary'
$clearCacheButton.Text = Get-UiString 'ClearCacheButton'
$clearCacheButton.Location = New-Object System.Drawing.Point(210,0)
$clearCacheButton.Width = $script:settingsButtonWidth
$clearCacheButton.Height = 34
$packagingButtonRow.Controls.Add($clearCacheButton)

[void](Add-SettingRow -Card $cardPackaging -Control $packagingButtonRow -SpaceBefore 4)

# Umgezogen aus dem Bereich "Lokale Pakete": eine Startup-Entscheidung gehoert zu den anderen. Sie
# folgt jetzt auch derselben Regel wie der Rest dieser Seite - sie gilt nach "Einstellungen
# speichern", nicht schon beim Anhaken.
$favoriteAutoCheckbox = New-Object System.Windows.Forms.CheckBox
$favoriteAutoCheckbox.Text = Get-UiString 'FavoriteAutoCheckbox'
$favoriteAutoCheckbox.AutoSize = $true
$favoriteAutoCheckbox.Checked = [bool]$script:settings.AutoUpdateFavoritesOnStartup
[void](Add-SettingRow -Card $cardPackaging -Control $favoriteAutoCheckbox -Hint (Get-UiString 'HintFavoriteAuto') -SpaceBefore 6)

# --- Card 2: searching for app updates -----------------------------------------------------------
$cardUpdateSearch = New-SettingsCard -TitleKey 'SettingsCardUpdateSearch' -InfoKey 'InfoCardUpdateSearch'

# The answer to "does this thing update apps on its own?", stated before the two options rather
# than left to be inferred from them.
$noAutoUpdateLabel = New-Object System.Windows.Forms.Label
$noAutoUpdateLabel.Tag = 'hint'
$noAutoUpdateLabel.Text = Get-UiString 'SettingsNoAutoUpdateHint'
$noAutoUpdateLabel.AutoSize = $true
$noAutoUpdateLabel.MaximumSize = New-Object System.Drawing.Size(680, 0)
[void](Add-SettingRow -Card $cardUpdateSearch -Control $noAutoUpdateLabel)

# NOTE: this setting runs the INTUNE app update search right after login (see the login handler)
# - it has nothing to do with the GitHub self-update of the GUI itself. It was previously gated
# on $script:githubRepo, which forced the box permanently off/inert whenever no self-update repo
# was configured. That gate is gone; the option works standalone and is off by default, because in
# large tenants the login-time scan walks every app and can take a long time.
$autoCheckUpdatesCheckbox = New-Object System.Windows.Forms.CheckBox
$autoCheckUpdatesCheckbox.Text = Get-UiString 'AutoCheckUpdatesCheckbox'
$autoCheckUpdatesCheckbox.AutoSize = $true
$autoCheckUpdatesCheckbox.Checked = [bool]$script:settings.AutoCheckUpdates
[void](Add-SettingRow -Card $cardUpdateSearch -Control $autoCheckUpdatesCheckbox -Hint (Get-UiString 'HintAutoCheckUpdates') -SpaceBefore 6)

# Steht hier, weil es dieselbe Frage beantwortet wie die Zeile darueber: was passiert direkt nach
# der Anmeldung, ohne dass jemand klickt.
$elevatedLoginCheckbox = New-Object System.Windows.Forms.CheckBox
$elevatedLoginCheckbox.Text = Get-UiString 'ElevatedLoginCheckbox'
$elevatedLoginCheckbox.AutoSize = $true
$elevatedLoginCheckbox.Checked = [bool]$script:settings.RequestOptionalScopesOnLogin
[void](Add-SettingRow -Card $cardUpdateSearch -Control $elevatedLoginCheckbox -Hint (Get-UiString 'HintElevatedLogin') -SpaceBefore 6)

# The dashboard tile can either trust Intune's flag (instant) or do the real comparison (one package
# lookup per app). Off by default because the dashboard is the first thing shown after signing in.
# Moved here out of the Tools menu: it decides how a NUMBER is counted, which is nobody's idea of a
# tool, and it belongs next to the update search that pays the same cost.
$dashboardFullScanCheckbox = New-Object System.Windows.Forms.CheckBox
$dashboardFullScanCheckbox.Text = Get-UiString 'DashboardFullScanCheckbox'
$dashboardFullScanCheckbox.AutoSize = $true
$dashboardFullScanCheckbox.Checked = [bool]$script:settings.DashboardUpdatesFullScan
[void](Add-SettingRow -Card $cardUpdateSearch -Control $dashboardFullScanCheckbox -Hint (Get-UiString 'HintDashboardFullScan'))

# Steht in dieser Karte, weil es den UMFANG der Suche festlegt - nicht ihren Zeitpunkt und nicht,
# was danach mit der alten Version passiert. AN als Standard: die WinTuner-Marke sagt, wer eine App
# angelegt hat, nicht ob sie aktualisierbar ist, und daran gebunden fielen handgebaute Pakete und
# Apps mit entfernter Marke lautlos aus der Suche.
$scanUnmanagedCheckbox = New-Object System.Windows.Forms.CheckBox
$scanUnmanagedCheckbox.Text = Get-UiString 'ScanUnmanagedCheckbox'
$scanUnmanagedCheckbox.AutoSize = $true
$scanUnmanagedCheckbox.Checked = [bool]$script:settings.ScanUnmanagedWin32Apps
[void](Add-SettingRow -Card $cardUpdateSearch -Control $scanUnmanagedCheckbox -Hint (Get-UiString 'HintScanUnmanaged') -SpaceBefore 6)

# --- Card 2b: apps that must not be superseded by accident ---------------------------------------
#
# Eigene Karte und nicht eine Zeile in der Karte darueber: das hier ist keine Ja/Nein-Einstellung,
# sondern eine Liste, die man ueber Monate pflegt. Der uebliche Weg fuehrt ohnehin ueber den
# Rechtsklick in der Update-Liste; diese Karte ist zum Nachsehen, Entfernen und fuer Muster.
$cardProtected = New-SettingsCard -TitleKey 'SettingsCardProtected' -InfoKey 'InfoCardProtected'

$protectedHintLabel = New-Object System.Windows.Forms.Label
$protectedHintLabel.Tag = 'hint'
$protectedHintLabel.Text = Get-UiString 'HintProtectedApps'
$protectedHintLabel.AutoSize = $true
$protectedHintLabel.MaximumSize = New-Object System.Drawing.Size(680, 0)
[void](Add-SettingRow -Card $cardProtected -Control $protectedHintLabel)

$protectedListBox = New-Object System.Windows.Forms.ListBox
$protectedListBox.Size = New-Object System.Drawing.Size(560, 112)
$protectedListBox.IntegralHeight = $false   # sonst kuerzt WinForms die Hoehe auf ganze Zeilen und die Karte rechnet daneben
[void](Add-SettingRow -Card $cardProtected -Control $protectedListBox -SpaceBefore 6)

# Eingabefeld + zwei Knoepfe in einer Zeile, wie die Pfadzeile in Karte 1.
$protectedRow = New-Object System.Windows.Forms.Panel
$protectedRow.Tag = 'row-host'
$protectedRow.Size = New-Object System.Drawing.Size(698, 32)

$protectedInputBox = New-Object System.Windows.Forms.TextBox
$protectedInputBox.PlaceholderText = Get-UiString 'ProtectedInputPlaceholder'
$protectedInputHost = New-RoundedInput -Inner $protectedInputBox -X 0 -Y 1 -W 330 -H 30
$protectedRow.Controls.Add($protectedInputHost)

$protectedAddButton = New-Object System.Windows.Forms.Button
$protectedAddButton.Text = Get-UiString 'ProtectedAddButton'
$protectedAddButton.Location = New-Object System.Drawing.Point(342,1)
$protectedAddButton.Width = 170
$protectedAddButton.Height = 30
$protectedRow.Controls.Add($protectedAddButton)

$protectedRemoveButton = New-Object System.Windows.Forms.Button
$protectedRemoveButton.Tag = 'btn-secondary'
$protectedRemoveButton.Text = Get-UiString 'ProtectedRemoveButton'
$protectedRemoveButton.Location = New-Object System.Drawing.Point(524,1)
$protectedRemoveButton.Width = 170
$protectedRemoveButton.Height = 30
$protectedRow.Controls.Add($protectedRemoveButton)

[void](Add-SettingRow -Card $cardProtected -Control $protectedRow -SpaceBefore 6)

# Fuellt die Anzeige aus den Einstellungen. Gerufen beim Aufbau, beim Oeffnen des Bereichs und nach
# jeder Aenderung - auch nach einer, die im Rechtsklick der Update-Liste passiert ist.
function Update-ProtectedAppsList {
  if (-not $protectedListBox) { return }
  $protectedListBox.BeginUpdate()
  try {
    $protectedListBox.Items.Clear()
    foreach ($p in @($script:settings.ProtectedApps)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$p)) { [void]$protectedListBox.Items.Add([string]$p) }
    }
  } finally { $protectedListBox.EndUpdate() }
}
Update-ProtectedAppsList

# Diese beiden Knoepfe wirken SOFORT, nicht erst nach "Einstellungen speichern". Das weicht bewusst
# vom Rest der Seite ab: der Rechtsklick in der Update-Liste schreibt ebenfalls sofort, und zwei
# Schreiber auf dieselbe Liste - einer sofort, einer beim Speichern - wuerden sich gegenseitig
# ueberschreiben. Der Hinweis ueber der Liste sagt es.
$protectedAddButton.Add_Click({
  $pattern = $protectedInputBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($pattern)) { return }
  $script:settings.ProtectedApps = @(Add-ProtectedAppPattern -Patterns $script:settings.ProtectedApps -Pattern $pattern)
  Save-Settings
  Write-Log ("Protected apps: added pattern '{0}' (now {1} entr(y/ies))." -f $pattern, @($script:settings.ProtectedApps).Count)
  $protectedInputBox.Text = ''
  Update-ProtectedAppsList
  # Die Update-Liste kann offen sein und Zeilen zeigen, die dieses Muster ab jetzt trifft.
  try { Update-UpdateListRows } catch { Write-LogDebug 'update list rows after protect' }
  Update-Status ((Get-UiString 'ProtectedAddedStatus') -f $pattern)
})

$protectedRemoveButton.Add_Click({
  $sel = [string]$protectedListBox.SelectedItem
  if ([string]::IsNullOrWhiteSpace($sel)) { return }
  $script:settings.ProtectedApps = @(Remove-ProtectedAppPattern -Patterns $script:settings.ProtectedApps -Pattern $sel)
  Save-Settings
  Write-Log ("Protected apps: removed pattern '{0}' (now {1} entr(y/ies))." -f $sel, @($script:settings.ProtectedApps).Count)
  Update-ProtectedAppsList
  try { Update-UpdateListRows } catch { Write-LogDebug 'update list rows after unprotect' }
  Update-Status ((Get-UiString 'ProtectedRemovedStatus') -f $sel)
})

# --- Card 3: what happens to the old version after an update -------------------------------------
$cardAfterUpdate = New-SettingsCard -TitleKey 'SettingsCardAfterUpdate' -InfoKey 'InfoCardAfterUpdate'

# Scope hand-over: only the newest version stays assigned after an update.
$moveAssignmentsCheckbox = New-Object System.Windows.Forms.CheckBox
$moveAssignmentsCheckbox.Text = Get-UiString 'MoveAssignmentsCheckbox'
$moveAssignmentsCheckbox.AutoSize = $true
$moveAssignmentsCheckbox.Checked = [bool]$script:settings.MoveAssignmentsOnUpdate
[void](Add-SettingRow -Card $cardAfterUpdate -Control $moveAssignmentsCheckbox -Hint (Get-UiString 'HintMoveAssignments'))

# The either/or pair gets a heading of its own and an indent, so "at most one of these two" is
# visible in the layout and not only in a sentence underneath them.
$cleanupGroupLabel = New-Object System.Windows.Forms.Label
$cleanupGroupLabel.Text = Get-UiString 'CleanupGroupLabel'
$cleanupGroupLabel.AutoSize = $true
$cleanupGroupLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
[void](Add-SettingRow -Card $cardAfterUpdate -Control $cleanupGroupLabel -SpaceBefore 10)

# Das Sicherheitsnetz als eigene Aussage, nicht als Nebensatz in einem Optionshinweis.
#
# Es ist fest verdrahtet (Get-AppAssignmentProbe + Get-AppInstallationProbe) und war deshalb nie
# eine Einstellung - genau darum hat es jemand hier gesucht und nicht gefunden. Eine Regel, die
# immer gilt, gehoert ueber die Optionen, nicht in eine davon.
# Fette Kopfzeile in normaler Textfarbe: als grauer Absatz zwischen grauen Absaetzen ging die
# Aussage unter - genau die Rueckmeldung. Ein WinForms-Label kann nicht teilweise fett, also zwei
# Beschriftungen: die Regel als Ueberschrift, die Begruendung als Hinweis darunter.
$cleanupSafetyNetTitle = New-Object System.Windows.Forms.Label
$cleanupSafetyNetTitle.Text = Get-UiString 'CleanupSafetyNetTitle'
$cleanupSafetyNetTitle.AutoSize = $true
$cleanupSafetyNetTitle.MaximumSize = New-Object System.Drawing.Size(680, 0)
$cleanupSafetyNetTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
[void](Add-SettingRow -Card $cardAfterUpdate -Control $cleanupSafetyNetTitle -Indent 32)

$cleanupSafetyNetLabel = New-Object System.Windows.Forms.Label
$cleanupSafetyNetLabel.Tag = 'hint'
$cleanupSafetyNetLabel.Text = Get-UiString 'CleanupSafetyNetAlways'
$cleanupSafetyNetLabel.AutoSize = $true
$cleanupSafetyNetLabel.MaximumSize = New-Object System.Drawing.Size(680, 0)
[void](Add-SettingRow -Card $cardAfterUpdate -Control $cleanupSafetyNetLabel -Indent 32)

# Ablöse: auto-remove the old (now superseded) app right after a successful update
$autoRemoveSupersededCheckbox = New-Object System.Windows.Forms.CheckBox
$autoRemoveSupersededCheckbox.Text = Get-UiString 'AutoRemoveSupersededCheckbox'
$autoRemoveSupersededCheckbox.AutoSize = $true
$autoRemoveSupersededCheckbox.Checked = [bool]$script:settings.AutoRemoveSuperseded
[void](Add-SettingRow -Card $cardAfterUpdate -Control $autoRemoveSupersededCheckbox -Hint (Get-UiString 'HintAutoRemoveSuperseded') -Indent 32)

# Automatic version trimming after an update run: keeps the newest N versions per app.
$autoVersionCleanupCheckbox = New-Object System.Windows.Forms.CheckBox
$autoVersionCleanupCheckbox.Text = (Get-UiString 'AutoVersionCleanupCheckbox') -f $script:keepVersionCount
$autoVersionCleanupCheckbox.AutoSize = $true
$autoVersionCleanupCheckbox.Checked = [bool]$script:settings.AutoVersionCleanup
[void](Add-SettingRow -Card $cardAfterUpdate -Control $autoVersionCleanupCheckbox -Hint (Get-UiString 'HintAutoVersionCleanup') -Indent 32)

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

# How many versions survive. The number appears in three places - the checkbox above, the button in
# the superseded card and that button's tooltip - so they are refreshed together from one helper
# rather than each reading the setting whenever it happens to be rebuilt.
$keepVersionRow = New-Object System.Windows.Forms.Panel
$keepVersionRow.Tag = 'row-host'
$keepVersionRow.Size = New-Object System.Drawing.Size(660, 28)

$keepVersionCountLabel = New-Object System.Windows.Forms.Label
$keepVersionCountLabel.Text = Get-UiString 'KeepVersionCountLabel'
$keepVersionCountLabel.Location = New-Object System.Drawing.Point(0,5)
$keepVersionCountLabel.AutoSize = $true
$keepVersionRow.Controls.Add($keepVersionCountLabel)

$keepVersionCountInput = New-Object System.Windows.Forms.NumericUpDown
$keepVersionCountInput.Minimum = 1     # keeping zero versions would mean deleting the current one
$keepVersionCountInput.Maximum = 20
$keepVersionCountInput.Value = $script:keepVersionCount
$keepVersionCountInput.Location = New-Object System.Drawing.Point(236,1)
$keepVersionCountInput.Width = 60
$keepVersionRow.Controls.Add($keepVersionCountInput)

[void](Add-SettingRow -Card $cardAfterUpdate -Control $keepVersionRow -Hint (Get-UiString 'HintKeepVersionCount') -Indent 32)

function Update-KeepVersionCountUi {
  $count = $script:keepVersionCount
  try { $autoVersionCleanupCheckbox.Text = (Get-UiString 'AutoVersionCleanupCheckbox') -f $count } catch { Write-LogDebug 'keep-count checkbox text' }
  try { $versionCleanupButton.Text = (Get-UiString 'VersionCleanupButton') -f $count } catch { Write-LogDebug 'keep-count button text' }
  # $toolTip is created later (90-Main); at runtime it exists, before that this is simply skipped.
  try { if ($toolTip) { $toolTip.SetToolTip($versionCleanupButton, ((Get-UiString 'TtVersionCleanupButton') -f $count)) } } catch { Write-LogDebug 'keep-count tooltip' }
}

# Deliberately does NOT change $script:keepVersionCount.
#
# That variable is what "Clean up versions" and the automatic post-batch cleanup delete by, and the
# automatic one runs without asking. Spinning this box used to change how many versions survive in
# the tenant immediately - before saving, and with the button next to it still showing the old
# number. Turning the dial in a settings card must not silently widen a deletion.
#
# The labels stay on the saved value on purpose too: the cleanup button states what it will actually
# do, and a preview number here would make it lie until the user happens to press Save.
$keepVersionCountInput.Add_ValueChanged({
  if ([int]$keepVersionCountInput.Value -ne [int]$script:keepVersionCount) {
    try { Update-Status (Get-UiString 'KeepVersionCountUnsaved') } catch { Write-LogDebug 'keep-count unsaved hint' }
  }
})

# Safety net for a deletion that turns out to have been wrong. Moved out of the Tools menu for the
# same reason as the two above - and it belongs in the card whose options do the deleting.
$saveScopeCheckbox = New-Object System.Windows.Forms.CheckBox
$saveScopeCheckbox.Text = Get-UiString 'SaveScopeCheckbox'
$saveScopeCheckbox.AutoSize = $true
$saveScopeCheckbox.Checked = [bool]$script:settings.SaveScopeBeforeRemoval
[void](Add-SettingRow -Card $cardAfterUpdate -Control $saveScopeCheckbox -Hint (Get-UiString 'HintSaveScope') -SpaceBefore 10)

# --- Card 4: confirmation prompts ----------------------------------------------------------------
$cardSafety = New-SettingsCard -TitleKey 'SettingsCardSafety' -InfoKey 'InfoCardSafety'

$suppressConfirmationsCheckbox = New-Object System.Windows.Forms.CheckBox
$suppressConfirmationsCheckbox.Text = Get-UiString 'SuppressConfirmationsCheckbox'
$suppressConfirmationsCheckbox.AutoSize = $true
$suppressConfirmationsCheckbox.Checked = (Test-ChangeConfirmationsSuppressed)
[void](Add-SettingRow -Card $cardSafety -Control $suppressConfirmationsCheckbox -Hint (Get-UiString 'HintSuppressConfirmations'))

# Turning the prompts OFF has to be acknowledged; turning them back on never does - that direction
# is always the safe one. The acknowledgement is asked at tick time rather than at save time,
# because a risk notice that appears minutes later, attached to a "Save settings" click, is not a
# notice anybody connects to the box they ticked.
$script:suppressConfirmSyncing = $false
$suppressConfirmationsCheckbox.Add_CheckedChanged({
  if ($script:suppressConfirmSyncing) { return }
  if (-not $suppressConfirmationsCheckbox.Checked) { return }
  $answer = [System.Windows.Forms.MessageBox]::Show(
    (Get-UiString 'SuppressConfirmationsRiskDialog'),
    (Get-UiString 'SuppressConfirmationsRiskTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
    $script:suppressConfirmSyncing = $true
    try { $suppressConfirmationsCheckbox.Checked = $false } finally { $script:suppressConfirmSyncing = $false }
  }
})

# --- Card 5: updates of this tool (self-update) --------------------------------------------------
$cardAppUpdates = New-SettingsCard -TitleKey 'UpdateSectionLabel' -InfoKey 'InfoCardAppUpdates'

$currentVersionLabel = New-Object System.Windows.Forms.Label
$currentVersionLabel.Text = (Get-UiString 'CurrentVersionLabel') -f $script:appVersion
$currentVersionLabel.AutoSize = $true
[void](Add-SettingRow -Card $cardAppUpdates -Control $currentVersionLabel)

# Ohne konfiguriertes Repository tut hier nichts etwas - dann sagt der Hinweis genau das, statt
# eine Option anzubieten, deren Wirkung ausbleibt und die man fuer defekt haelt.
$checkUpdateOnStartupCheckbox = New-Object System.Windows.Forms.CheckBox
$checkUpdateOnStartupCheckbox.Text = Get-UiString 'CheckUpdateOnStartupCheckbox'
$checkUpdateOnStartupCheckbox.AutoSize = $true
$checkUpdateOnStartupCheckbox.Checked = [bool]$script:settings.CheckAppUpdateOnStartup
$script:selfUpdateConfigured = -not [string]::IsNullOrWhiteSpace($script:githubRepo)
if (-not $script:selfUpdateConfigured) { $checkUpdateOnStartupCheckbox.Enabled = $false }
[void](Add-SettingRow -Card $cardAppUpdates -Control $checkUpdateOnStartupCheckbox `
  -Hint (Get-UiString $(if ($script:selfUpdateConfigured) { 'HintCheckUpdateOnStartup' } else { 'HintCheckUpdateNoRepo' })) `
  -SpaceBefore 4)

$checkUpdateButton = New-Object System.Windows.Forms.Button
$checkUpdateButton.Text = Get-UiString 'CheckUpdateButton'
$checkUpdateButton.Width = $script:settingsButtonWidth
$checkUpdateButton.Height = 34
# Disabled until a self-update repo is configured (see $script:githubRepo).
if ([string]::IsNullOrWhiteSpace($script:githubRepo)) { $checkUpdateButton.Enabled = $false }
[void](Add-SettingRow -Card $cardAppUpdates -Control $checkUpdateButton -Hint (Get-UiString 'HintSelfUpdate') -SpaceBefore 4)

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

# --- Card 6: files & diagnostics -----------------------------------------------------------------
# The log path was only visible inside Help > About, which nobody opens while troubleshooting.
# Showing both paths here (selectable read-only fields, so they can be copied into a ticket)
# plus a button to open the folder makes them findable for a technician.
$cardFiles = New-SettingsCard -TitleKey 'FilesSectionLabel' -InfoKey 'InfoCardFiles'

$logPathRow = New-Object System.Windows.Forms.Panel
$logPathRow.Tag = 'row-host'
$logPathRow.Size = New-Object System.Drawing.Size(698, 30)

$logPathLabel = New-Object System.Windows.Forms.Label
$logPathLabel.Text = Get-UiString 'LogFilePathLabel'
$logPathLabel.Location = New-Object System.Drawing.Point(0,6)
$logPathLabel.AutoSize = $true
$logPathRow.Controls.Add($logPathLabel)

$logPathBox = New-Object System.Windows.Forms.TextBox
$logPathBox.Text = $script:logFilePath
$logPathBox.ReadOnly = $true
$logPathBox.Width = 546
$logPathHost = New-RoundedInput -Inner $logPathBox -X 136 -Y 0 -W 546 -H 28
$logPathRow.Controls.Add($logPathHost)
[void](Add-SettingRow -Card $cardFiles -Control $logPathRow)

$settingsPathRow = New-Object System.Windows.Forms.Panel
$settingsPathRow.Tag = 'row-host'
$settingsPathRow.Size = New-Object System.Drawing.Size(698, 30)

$settingsPathLabel = New-Object System.Windows.Forms.Label
$settingsPathLabel.Text = Get-UiString 'SettingsFilePathLabel'
$settingsPathLabel.Location = New-Object System.Drawing.Point(0,6)
$settingsPathLabel.AutoSize = $true
$settingsPathRow.Controls.Add($settingsPathLabel)

$settingsPathBox = New-Object System.Windows.Forms.TextBox
$settingsPathBox.Text = $script:settingsPath
$settingsPathBox.ReadOnly = $true
$settingsPathBox.Width = 546
$settingsPathHost = New-RoundedInput -Inner $settingsPathBox -X 136 -Y 0 -W 546 -H 28
$settingsPathRow.Controls.Add($settingsPathHost)
[void](Add-SettingRow -Card $cardFiles -Control $settingsPathRow -Hint (Get-UiString 'FilesSectionHint'))

$filesButtonRow = New-Object System.Windows.Forms.Panel
$filesButtonRow.Tag = 'row-host'
$filesButtonRow.Size = New-Object System.Drawing.Size(698, 32)

$openLogButton = New-Object System.Windows.Forms.Button
$openLogButton.Tag = 'btn-secondary'
$openLogButton.Text = Get-UiString 'MenuOpenLogFile'
$openLogButton.Location = New-Object System.Drawing.Point(0, 0)
$openLogButton.Width = $script:settingsButtonWidth
$openLogButton.Height = 30
$filesButtonRow.Controls.Add($openLogButton)

$openLogFolderButton = New-Object System.Windows.Forms.Button
$openLogFolderButton.Tag = 'btn-secondary'
$openLogFolderButton.Text = Get-UiString 'OpenLogFolderButton'
$openLogFolderButton.Location = New-Object System.Drawing.Point(210, 0)
$openLogFolderButton.Width = $script:settingsButtonWidth
$openLogFolderButton.Height = 30
$filesButtonRow.Controls.Add($openLogFolderButton)

# Writes a pseudonymized copy of the log to %TEMP% so it can be attached to a bug report without
# leaking customer identifiers (UPNs, GUIDs, user name/profile path -> stable placeholders).
$exportLogButton = New-Object System.Windows.Forms.Button
$exportLogButton.Tag = 'btn-secondary'
$exportLogButton.Text = Get-UiString 'ExportSanitizedLogButton'
$exportLogButton.Location = New-Object System.Drawing.Point(420, 0)
$exportLogButton.Width = $script:settingsButtonWidth
$exportLogButton.Height = 30
$filesButtonRow.Controls.Add($exportLogButton)

# Die drei Knoepfe an ihren Beschriftungen messen und aufreihen. Bei fester Breite von 200 px war
# "Log fuer Fehlerbericht exportieren" abgeschnitten - und gerade dieser Knopf ist der, den jemand
# im Stoerungsfall zum ersten Mal sucht.
$filesButtonX = 0
foreach ($b in @($openLogButton, $openLogFolderButton, $exportLogButton)) {
  if (-not $b) { continue }
  $w = $script:settingsButtonWidth
  try {
    $t = [string]$b.Text
    if ($t) { $w = [Math]::Max($w, [System.Windows.Forms.TextRenderer]::MeasureText($t, $b.Font).Width + 26) }
  } catch { }
  $b.Left = $filesButtonX
  $b.Width = $w
  $filesButtonX += $w + 10
}
$filesButtonRow.Width = [Math]::Max($filesButtonRow.Width, $filesButtonX)

[void](Add-SettingRow -Card $cardFiles -Control $filesButtonRow -SpaceBefore 4)

$openLogButton.Add_Click({
  try {
    if (Test-Path -LiteralPath $script:logFilePath) {
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

$exportLogButton.Add_Click({
  try {
    if (-not (Test-Path -LiteralPath $script:logFilePath)) {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'LogFileMissingDialog') -f $script:logFilePath),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
      return
    }
    $raw = Get-Content -LiteralPath $script:logFilePath -Raw -ErrorAction Stop
    $sanitized = (Get-UiString 'SanitizedLogHeader') + "`r`n`r`n" + (Get-SanitizedLogText -Text $raw)
    $out = Join-Path ([IO.Path]::GetTempPath()) ("WinTuner_GUI-log-sanitized-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [IO.File]::WriteAllText($out, $sanitized, [Text.UTF8Encoding]::new($false))
    Write-Log "Sanitized log exported for a bug report."
    try { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $out) -ErrorAction SilentlyContinue } catch { }
    [void][System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'SanitizedLogDoneDialog') -f $out),
      (Get-UiString 'InfoTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information)
  } catch { Write-Log "Sanitized log export failed: $($_.Exception.Message)" }
})

$openLogFolderButton.Add_Click({
  # Select the log in Explorer when it exists, otherwise just open the folder it would go to.
  try {
    if (Test-Path -LiteralPath $script:logFilePath) {
      Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:logFilePath) -ErrorAction Stop
    } else {
      Start-Process explorer.exe -ArgumentList (Split-Path -Parent $script:logFilePath) -ErrorAction Stop
    }
  } catch { Write-Log "Open log folder failed: $($_.Exception.Message)" }
})

# --- Save bar ------------------------------------------------------------------------------------
# One Save for the whole page. It used to sit in the middle of the first card, which read as "save
# the general options" while three more cards below it were saved by the same click.
$cardSave = New-Card -X 16 -Y 48 -W $script:settingsCardWidth -H 100
$tabSettings.Controls.Add($cardSave)
$script:settingsCards.Add($cardSave)
# No card title here, so the first row starts at the top padding instead of below one.
$script:settingRowStart[$cardSave.GetHashCode()] = 14

$saveSettingsButton = New-Object System.Windows.Forms.Button
$saveSettingsButton.Text = Get-UiString 'SaveSettingsButton'
$saveSettingsButton.Width = $script:settingsButtonWidth
$saveSettingsButton.Height = 34
[void](Add-SettingRow -Card $cardSave -Control $saveSettingsButton -Hint (Get-UiString 'SettingsSaveHint'))

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
    $script:settings.RequestOptionalScopesOnLogin = $elevatedLoginCheckbox.Checked
    $script:settings.AutoRemoveSuperseded = $autoRemoveSupersededCheckbox.Checked
    if ($autoVersionCleanupCheckbox) { $script:settings.AutoVersionCleanup = $autoVersionCleanupCheckbox.Checked }
    if ($moveAssignmentsCheckbox) { $script:settings.MoveAssignmentsOnUpdate = $moveAssignmentsCheckbox.Checked }
    if ($saveScopeCheckbox) { $script:settings.SaveScopeBeforeRemoval = $saveScopeCheckbox.Checked }
    if ($favoriteAutoCheckbox) { $script:settings.AutoUpdateFavoritesOnStartup = $favoriteAutoCheckbox.Checked }
    if ($checkUpdateOnStartupCheckbox) { $script:settings.CheckAppUpdateOnStartup = $checkUpdateOnStartupCheckbox.Checked }
    # The tile has to be recounted when this changed, otherwise the number on the dashboard was
    # produced by the other method and no longer matches the setting.
    $fullScanChanged = $false
    if ($dashboardFullScanCheckbox) {
      $fullScanChanged = ([bool]$script:settings.DashboardUpdatesFullScan -ne [bool]$dashboardFullScanCheckbox.Checked)
      $script:settings.DashboardUpdatesFullScan = $dashboardFullScanCheckbox.Checked
    }
    # Aendert ebenfalls die Grundlage der Kachel - beim echten Versionsvergleich rechnet sie ueber
    # Get-ScanInventory. Ohne das Neuzaehlen stuende dort weiter die Zahl aus dem alten Umfang.
    if ($scanUnmanagedCheckbox) {
      if ([bool]$script:settings.ScanUnmanagedWin32Apps -ne [bool]$scanUnmanagedCheckbox.Checked) { $fullScanChanged = $true }
      $script:settings.ScanUnmanagedWin32Apps = $scanUnmanagedCheckbox.Checked
    }
    if ($suppressConfirmationsCheckbox) {
      # The risk notice was already answered when the box was ticked (see its CheckedChanged), so a
      # ticked box here means it was accepted. Tied to the version: a new release may add prompts
      # the user has never seen, so the acknowledgement is asked again after an update.
      $script:settings.SuppressChangeConfirmations = [bool]$suppressConfirmationsCheckbox.Checked
      $script:settings.ChangeConfirmationRiskAcceptedVersion =
        if ($suppressConfirmationsCheckbox.Checked) { [string]$script:appVersion } else { "" }
    }
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
    # Derselbe Abdruck wie beim Start, nur mit anderem Vorsatz: im Protokoll steht damit an beiden
    # Stellen dasselbe Format, und man sieht, was ab hier gilt.
    foreach ($line in (Get-SettingsSnapshotLines -Prefix 'Settings saved')) { Write-Log $line }
    Update-Status (Get-UiString 'SettingsSavedStatus')
    if ($fullScanChanged) {
      try { if ($script:isConnected) { Refresh-Dashboard -Force } } catch { Write-LogDebug 'dashboard refresh after save' }
    }

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
  Remove-Item -LiteralPath $script:versionCachePath -Force -ErrorAction SilentlyContinue
  Write-Log "Version cache cleared."
  Update-Status (Get-UiString 'CacheClearedStatus')
})

$prunePackagesButton.Add_Click({
  if (Test-UiBusy) { return }
  $root = $defaultPathTextBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
    [void][System.Windows.Forms.MessageBox]::Show(((Get-UiString 'PruneNoFolder') -f $root), (Get-UiString 'PruneTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    return
  }
  $keep = if ([int]$keepVersionCountInput.Value -ge 1) { [int]$keepVersionCountInput.Value } else { 2 }
  try {
    $prunePackagesButton.Enabled = $false
    Update-Status (Get-UiString 'PruneScanning')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

    $plan = @(Get-LocalPackagePrunePlan -RootPackageFolder $root -KeepCount $keep)
    if ($plan.Count -eq 0) {
      Update-Status ((Get-UiString 'PruneNothing') -f $keep)
      [void][System.Windows.Forms.MessageBox]::Show(((Get-UiString 'PruneNothing') -f $keep), (Get-UiString 'PruneTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
      return
    }

    # Show what would go BEFORE anything is deleted, with the total it frees. A silent bulk delete
    # of a folder the user picked themselves is exactly the kind of surprise this tool avoids.
    $totalBytes = [long]0
    foreach ($e in $plan) { $totalBytes += (Get-FolderSizeBytes -Path $e.Path) }
    $preview = @($plan | Select-Object -First 15 | ForEach-Object { '  {0}  {1}' -f $_.PackageId, $_.Version })
    if ($plan.Count -gt 15) { $preview += ('  ... (+{0})' -f ($plan.Count - 15)) }

    $answer = [System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'PruneConfirm') -f $plan.Count, (Format-ByteSize $totalBytes), $keep, ($preview -join "`r`n")),
      (Get-UiString 'PruneTitle'),
      [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
      [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { Update-Status ''; return }

    Write-Log ("Local package prune starting: {0} folder(s), keeping newest {1} per package, root {2}" -f $plan.Count, $keep, $root)
    $result = Invoke-LocalPackagePrune -Plan $plan
    if ($result.Failed -gt 0) {
      Update-Status ((Get-UiString 'PruneDoneWithErrors') -f $result.Removed, $result.Failed, (Format-ByteSize $result.FreedBytes))
    } else {
      Update-Status ((Get-UiString 'PruneDone') -f $result.Removed, (Format-ByteSize $result.FreedBytes))
    }
    Write-Log ("Local package prune finished: {0} removed, {1} failed, {2} freed." -f $result.Removed, $result.Failed, (Format-ByteSize $result.FreedBytes))
  } catch {
    Write-Log ("Local package prune failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'PruneDoneWithErrors') -f 0, 0, '0 B')
  } finally {
    $prunePackagesButton.Enabled = $true
  }
})

# Theme selection lives in the top-menu "Theme" picker now (not here). $themeSelectorCombo is kept
# as $null so later references (tooltips etc.) stay harmless.
$themeSelectorCombo = $null

# Language selection lives in the top-menu "Language" picker now (next to "Theme"), like the theme
# it is a display preference rather than a tenant/Intune setting. $languageSelectorCombo is kept as
# $null so later references (tooltips etc.) stay harmless.
$languageSelectorCombo = $null

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
    # Der Sammel-Editor haelt eine Liste des VORIGEN Tenants; beim naechsten Oeffnen neu laden.
    $script:appSettingsLoaded = $false
    # First and most important: a cached inventory belongs to the previous tenant.
    if (Get-Command Clear-Win32AppsCache -ErrorAction SilentlyContinue) { Clear-Win32AppsCache }
    # Gruppennamen gehoeren genauso zum Kunden wie das Inventar - eine GUID des vorigen Tenants
    # duerfte hier nie mit dem Namen von dort auftauchen.
    if (Get-Command Clear-EntraGroupNameCache -ErrorAction SilentlyContinue) { Clear-EntraGroupNameCache }
    # Versionen sind kundenunabhaengig - aber ein Tenant-Wechsel ist der Punkt, an dem man frische
    # Zahlen erwartet, und die zweite Anmeldung soll nicht auf der ersten sitzen.
    if (Get-Command Clear-LatestVersionCache -ErrorAction SilentlyContinue) { Clear-LatestVersionCache }
    # Welche Installationsquelle antwortet, ist eine Eigenschaft DES TENANTS.
    if (Get-Command Clear-InstallProbeSource -ErrorAction SilentlyContinue) { Clear-InstallProbeSource }
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
    if ($supersededListBox) { $supersededListBox.Items.Clear() }
    if (Get-Command Update-SupersededListState -ErrorAction SilentlyContinue) {
      try { Update-SupersededListState } catch { }
    }

    # Tenant-wide app list
    $script:tenantApps = @()
    if ($tenantListView) { $tenantListView.Items.Clear() }
    if ($tenantDetailBox) { $tenantDetailBox.Text = '' }
    foreach ($b in @($tenantAssignButton, $tenantEditButton)) { if ($b) { $b.Enabled = $false } }

    # Microsoft Store inventory - the cached list belongs to the previous tenant too.
    $script:tenantStoreApps = @()
    if ($storeTenantListView) { $storeTenantListView.Items.Clear() }

    # Group / filter id text fields: these hold Entra group and assignment-filter GUIDs of the
    # PREVIOUS customer and are read straight into new assignments. Clear them so nothing carries over.
    foreach ($idBox in @($assignGroupIdBox, $script:storeAssignGroupIdBox, $discoveredAssignGroupIdBox, $script:deployFilterIdBox)) {
      if ($idBox) { $idBox.Text = '' }
    }
    # Rebuild the assignment-target combos: without a session Get-GroupFavorites returns @(), so the
    # combos fall back to the fixed entries and the selection to "unassigned".
    if (Get-Command Update-AllAssignTargetCombos -ErrorAction SilentlyContinue) {
      try { Update-AllAssignTargetCombos } catch { }
    }

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

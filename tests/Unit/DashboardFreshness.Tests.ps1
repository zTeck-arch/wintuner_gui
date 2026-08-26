# Das Dashboard fragt den Tenant nicht mehr bei jedem Besuch ab.
#
# Gemeldet: "es haengt manchmal, wenn ich auf Dashboard klicke". Jeder Besuch kostete drei
# Tenant-Abfragen (Inventar, Update-Kennzeichen, abgeloeste Apps) auf dem UI-Thread. Gleichzeitig
# darf es nicht ins andere Extrem fallen: nach einem Update-Lauf zeigte es die Zahlen von vorher,
# was als "8 veraltete Apps stimmt nicht" zurueckkam.
#
# Die Regel, die beides zusammenhaelt: aktualisiert wird bei der Anmeldung, wenn seit dem letzten
# Stand etwas geschrieben wurde ($script:dashboardStale) und auf Knopfdruck - und der Stand steht
# unter den Kacheln.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '80-Views.ps1' -Name 'Update-DashboardFreshness')))
  $script:uiText = Get-SourcePartText -Part '75-UiState.ps1'
  $script:engineText = Get-SourcePartText -Part '50-UpdateEngine.ps1'
}

Describe 'Update-DashboardFreshness' {

  BeforeEach {
    $script:dashboardStale = $false
    $script:dashboardLastRefresh = [datetime]::MinValue
    $script:isConnected = $false
    # Nur die zwei Steuerelemente, die die Funktion anfasst.
    $global:dashHint = New-Object System.Windows.Forms.Label
    $global:dashHint.AutoSize = $true
    Set-Variable -Name dashHint -Scope Script -Value $global:dashHint
  }

  It 'sagt ohne Sitzung, dass ein Tenant fehlt' {
    Update-DashboardFreshness
    $dashHint.Text | Should -Be (Get-UiString 'DashConnectHint')
  }

  It 'nennt den Stand, sobald Zahlen geladen sind' {
    $script:isConnected = $true
    $script:dashboardLastRefresh = ([datetime]'2026-08-26T07:45:28Z')
    Update-DashboardFreshness
    $dashHint.Text | Should -Match ([regex]::Escape($script:dashboardLastRefresh.ToLocalTime().ToString('HH:mm')))
  }

  It 'sagt es, wenn sich seit dem Stand etwas geaendert hat' {
    $script:isConnected = $true
    $script:dashboardLastRefresh = ([datetime]'2026-08-26T07:45:28Z')
    $script:dashboardStale = $true
    Update-DashboardFreshness
    $expected = (Get-UiString 'DashStaleHint') -f $script:dashboardLastRefresh.ToLocalTime().ToString('HH:mm')
    $dashHint.Text | Should -Be $expected
  }

  It 'bietet keinen Knopf "Jetzt aktualisieren" mehr an' {
    # Auf Wunsch entfernt: die Zeile sagt den Stand, geladen wird bei der Anmeldung und nach jedem
    # Eingriff. Ein Knopf daneben hat nur Platz gekostet.
    $views = Get-SourcePartText -Part '80-Views.ps1'
    $views | Should -Not -Match 'dashRefreshBtn'
    (Get-SourcePartText -Part '15-Strings.ps1') | Should -Not -Match 'DashRefreshButton'
  }
}

Describe 'Wann das Dashboard neu laedt' {

  It 'laedt beim Navigieren nur, wenn es noch nie geladen wurde oder etwas veraltet ist' {
    # Die Bedingung selbst ist die Aussage - ohne sie war jeder Klick auf "Dashboard" drei Abfragen.
    $script:uiText | Should -Match '\$neverLoaded = \(\$script:dashboardLastRefresh -eq \[datetime\]::MinValue\)'
    $script:uiText | Should -Match 'if \(\$neverLoaded -or \$script:dashboardStale\)'
  }

  It 'merkt sich jede erfasste Aenderung als Grund zum Neuladen' {
    # Der Merker sitzt in Add-SessionActivity: die eine Stelle, die jeder schreibende Weg durchlaeuft.
    $add = Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Add-SessionActivity'
    $add | Should -Match '\$script:dashboardStale = \$true'
  }

  It 'setzt den Merker nach einem erfolgreichen Laden zurueck' {
    $refresh = Get-SourceFunctionText -Part '80-Views.ps1' -Name 'Refresh-Dashboard'
    $refresh | Should -Match '\$script:dashboardStale = \$false'
  }
}

Describe 'Hoehe des Protokollbereichs' {

  It 'bleibt konstant - auch waehrend eines Laufs' {
    # Vorher: 120 px normal, 210 px waehrend eines Laufs. Der Inhalt darueber verlor mitten in der
    # Arbeit 90 px, bekam Bildlaufleisten, und nach dem Lauf sprang alles zurueck.
    $fn = Get-SourceFunctionText -Part '75-UiState.ps1' -Name 'Update-BottomLayout'
    $fn | Should -Match '\$logHeight = 120'
    $fn | Should -Not -Match 'if \(\$progressVisible\) \{ 210 \}'
  }

  It 'kostet auch die Fortschrittszeile keine zusaetzliche Hoehe mehr' {
    # Der Rest desselben Effekts: ein Lauf legte eine eigene Zeile an (32 px), die danach wieder
    # verschwand. Fortschrittstext und Abbruch-Knopf teilen jetzt die Zeile des Umschalters.
    # Gemessen am gebauten Skript (1146x854, 1366x768, 1920x1080): unterer Bereich 191 px und
    # Inhaltshoehe unveraendert vor, waehrend und nach einem Lauf.
    $fn = Get-SourceFunctionText -Part '75-UiState.ps1' -Name 'Update-BottomLayout'
    $fn | Should -Not -Match 'requiredHeight \+= \$gap \+ \$progressRowHeight'
    $fn | Should -Match '\$progressLeft = \$logToggle\.Left \+ \$logToggle\.Width \+ \$gap'
    $fn | Should -Match '\$script:cancelRunButton\.Top = \$logToggle\.Top'
  }
}

Describe 'Fortschrittstext ohne Stueckzahl' {

  It 'sagt nur, dass etwas laeuft - ohne den Zusatz ueber die fehlende Stueckzahl' {
    # "(fuer diesen Schritt gibt es keine Stueckzahl)" war eine Erklaerung fuer eine Frage, die
    # niemand gestellt hat.
    (Get-UiString 'ProgressRunningText') | Should -Not -Match 'Stückzahl|step count'
    (Get-UiString 'ProgressRunningText') | Should -Not -Match '\('
  }
}

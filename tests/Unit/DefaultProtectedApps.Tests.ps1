# Werksseitig geschuetzte Apps: TeamViewer, Jamf, Splashtop und was sonst selbst paketiert wird.
# Die Schutzliste startete leer - in einer neuen Umgebung war also nichts geschuetzt, bis jemand
# daran dachte. Genau dort passiert der Unfall: ein Lauf loest die selbst gebaute App ab, zieht ihre
# Zuweisungen mit, und bei einem von Hand gebauten Paket holt das kein zweiter Lauf zurueck.
#
# Die eigentliche Schwierigkeit ist nicht das Eintragen, sondern das Nicht-wieder-Eintragen: die
# Muster muessen auch bei einer BESTEHENDEN Installation ankommen, duerfen aber nach dem Entfernen
# durch den Benutzer nicht beim naechsten Start zurueckkommen. Das leistet der Merker
# ProtectedAppsSeeded, und genau das pruefen diese Faelle.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name @(
    'Test-IsProtectedApp', 'Set-ProtectedAppPatterns',
    'Add-ProtectedAppPattern', 'Remove-ProtectedAppPattern', 'Get-SeededProtectedApps'))))

  $script:factory = @('TeamViewer*', 'Jamf*', 'Splashtop*')
}

Describe 'Get-SeededProtectedApps' {

  It 'traegt die Werksmuster bei einer frischen Installation ein' {
    $r = Get-SeededProtectedApps -Patterns @() -Seeded @() -Defaults $script:factory
    $r.Patterns | Should -Be @('Jamf*', 'Splashtop*', 'TeamViewer*')   # Set-ProtectedAppPatterns sortiert
    @($r.Added).Count | Should -Be 3
  }

  It 'traegt sie auch bei einer BESTEHENDEN Installation nach, ohne Vorhandenes zu verlieren' {
    # Der Fall, der den Punkt ausmacht: wer die Anwendung schon benutzt, hat eine settings.json ohne
    # diese Muster - und bekaeme sie sonst nie.
    $r = Get-SeededProtectedApps -Patterns @('Eigenbau Kassensystem') -Seeded @() -Defaults $script:factory
    $r.Patterns | Should -Contain 'Eigenbau Kassensystem'
    $r.Patterns | Should -Contain 'TeamViewer*'
    @($r.Patterns).Count | Should -Be 4
  }

  It 'holt ein vom Benutzer entferntes Werksmuster NICHT zurueck' {
    # Der zweite Start: der Merker fuehrt alle drei, die Liste nur noch zwei. Kaeme das dritte
    # wieder, koennte man es nie loswerden - und die Liste waere nicht mehr die des Benutzers.
    $r = Get-SeededProtectedApps -Patterns @('Jamf*', 'Splashtop*') -Seeded $script:factory -Defaults $script:factory
    $r.Patterns | Should -Not -Contain 'TeamViewer*'
    @($r.Added).Count | Should -Be 0
  }

  It 'ergaenzt ein SPAETER hinzugekommenes Werksmuster, ohne die entfernten zurueckzuholen' {
    $spaeter = @($script:factory + 'AnyDesk*')
    $r = Get-SeededProtectedApps -Patterns @('Jamf*') -Seeded $script:factory -Defaults $spaeter
    $r.Added | Should -Be @('AnyDesk*')
    $r.Patterns | Should -Not -Contain 'TeamViewer*'
    $r.Patterns | Should -Contain 'AnyDesk*'
  }

  It 'meldet beim zweiten Lauf nichts mehr - der Start speichert also nur einmal' {
    $erst = Get-SeededProtectedApps -Patterns @() -Seeded @() -Defaults $script:factory
    $zweit = Get-SeededProtectedApps -Patterns $erst.Patterns -Seeded $erst.Seeded -Defaults $script:factory
    @($zweit.Added).Count | Should -Be 0
    $zweit.Patterns | Should -Be $erst.Patterns
  }

  It 'fuehrt im Merker immer die VOLLE Werksliste, nicht nur das eben Ergaenzte' {
    $r = Get-SeededProtectedApps -Patterns @() -Seeded @() -Defaults $script:factory
    foreach ($p in $script:factory) { $r.Seeded | Should -Contain $p }
  }
}

Describe 'Die Werksmuster treffen, was sie treffen sollen' {

  It 'schuetzt jede Fassung von TeamViewer, Jamf und Splashtop' {
    $seed = (Get-SeededProtectedApps -Patterns @() -Seeded @() -Defaults $script:factory).Patterns
    foreach ($name in @('TeamViewer', 'TeamViewer Host', 'TeamViewer Meeting',
                        'Jamf Connect', 'Jamf Pro', 'Splashtop Streamer', 'Splashtop Business')) {
      Test-IsProtectedApp -Name $name -Patterns $seed | Should -BeTrue -Because "$name wird selbst paketiert"
    }
  }

  It 'schuetzt nicht versehentlich fremde Produkte' {
    $seed = (Get-SeededProtectedApps -Patterns @() -Seeded @() -Defaults $script:factory).Patterns
    foreach ($name in @('Google Chrome', 'Microsoft Edge WebView2', '7-Zip', 'Adobe Acrobat')) {
      Test-IsProtectedApp -Name $name -Patterns $seed | Should -BeFalse
    }
  }
}

Describe 'Verdrahtung im Quelltext' {

  It 'spielt die Werksmuster in Load-Settings ein - fuer Datei UND Vorgaben' {
    # Ausserhalb des try-Blocks, wie der Aufraeum-Konflikt daneben: eine settings.json, die sich
    # nicht lesen laesst, hinterlaesst die Vorgaben - und die brauchen dieselbe Behandlung.
    $fn = Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Load-Settings'
    $fn | Should -Match 'Get-SeededProtectedApps'
  }

  It 'speichert den Merker beim Start, sonst kaeme die Ergaenzung bei jedem Start erneut' {
    $main = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\90-Main.ps1')
    $main | Should -Match 'protectedAppsSeeded'
    $main | Should -Match 'Save-Settings'
  }
}

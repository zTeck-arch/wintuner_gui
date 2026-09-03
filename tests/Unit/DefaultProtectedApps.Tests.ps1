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

  # Die Faelle zur Einspiel-Logik pruefen die RECHNUNG, nicht den Inhalt - dafuer reicht eine kurze
  # Beispielliste.
  $script:factory = @('TeamViewer*', 'Jamf*', 'Splashtop*')

  # Fuer die Faelle zum INHALT dagegen die echte Liste aus der Quelle, nicht eine Kopie: eine Kopie
  # laeuft auseinander, und dann prueft der Test eine Werksliste, die niemand ausliefert. Ueber den
  # Parser statt per Textsuche, damit eine auskommentierte Zeile nicht als Eintrag durchgeht.
  $script:settingsAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Get-SourcePartPath -Part '10-Settings.ps1'), [ref]$null, [ref]$null)
  $assign = $script:settingsAst.Find({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$script:defaultProtectedApps'
  }, $true)
  if (-not $assign) { throw 'Werksliste $script:defaultProtectedApps nicht gefunden - umbenannt?' }
  . ([scriptblock]::Create($assign.Extent.Text))
  $script:realFactory = @($script:defaultProtectedApps)
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

  # Genau der Weg, auf dem die Erweiterung vom 02.09.2026 bei einer bestehenden Installation
  # ankommt. Das Beispielmuster steht bewusst NICHT in der echten Werksliste, sonst prueft der Fall
  # beim naechsten Nachtrag versehentlich etwas anderes.
  It 'ergaenzt ein SPAETER hinzugekommenes Werksmuster, ohne die entfernten zurueckzuholen' {
    $spaeter = @($script:factory + 'Frei Erfundenes RMM*')
    $r = Get-SeededProtectedApps -Patterns @('Jamf*') -Seeded $script:factory -Defaults $spaeter
    $r.Added | Should -Be @('Frei Erfundenes RMM*')
    $r.Patterns | Should -Not -Contain 'TeamViewer*'
    $r.Patterns | Should -Contain 'Frei Erfundenes RMM*'
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

# Diese Faelle pruefen die AUSGELIEFERTE Liste, nicht die Rechnung darueber.
Describe 'Die ausgelieferte Werksliste' {

  It 'traegt an jedem Eintrag einen Platzhalter' {
    # Ohne '*' trifft ein Eintrag den Anzeigenamen exakt - und genau diese Produkte treten in
    # mehreren Fassungen auf ("ConnectWise Control", "ConnectWise Automate").
    foreach ($p in $script:realFactory) { $p | Should -BeLike '*`**' }
  }

  It 'enthaelt keinen Eintrag doppelt' {
    $distinct = @($script:realFactory | Sort-Object -Unique)
    @($distinct).Count | Should -Be @($script:realFactory).Count
  }

  # Fernwartung und RMM: der Installer traegt die Zuordnung zum Betreuer in sich. Ein aus WinGet
  # gebautes Paket installiert dasselbe Produkt "leer" - danach meldet sich der Rechner bei
  # niemandem mehr, und ausgerechnet der Zugang zum Reparieren ist weg.
  It 'schuetzt die Fernwartungs- und RMM-Produkte in ihren gaengigen Fassungen' {
    foreach ($name in @(
      'TeamViewer', 'TeamViewer Host', 'Jamf Connect', 'Splashtop Streamer',
      'AnyDesk', 'AnyDesk Custom Client',
      'ScreenConnect Client (a1b2c3)', 'ConnectWise Control', 'ConnectWise Automate',
      'N-able Take Control', 'N-central Agent', 'Datto RMM', 'Datto Windows Agent',
      # Nachtrag 03.09.2026
      'NinjaOne Agent', 'NinjaRMMAgent', 'Atera Agent', 'AteraAgent', 'Action1 Agent',
      'BeyondTrust Remote Support Jump Client', 'BeyondTrust Privileged Remote Access',
      'BeyondTrust Privilege Management for Windows')) {
      Test-IsProtectedApp -Name $name -Patterns $script:realFactory |
        Should -BeTrue -Because "$name traegt die Kundenzuordnung im Installer"
    }
  }

  # Passwortmanager: ausgerollt mit Richtliniendatei, SSO-Anbindung oder festem Server. Der Ersatz
  # durch die nackte Herstellerfassung nimmt nicht die Passwoerter, aber die Anmeldung am Tresor.
  It 'schuetzt die gaengigen Passwortmanager' {
    foreach ($name in @('Keeper Password Manager', '1Password', 'Bitwarden', 'LastPass', 'KeePass')) {
      Test-IsProtectedApp -Name $name -Patterns $script:realFactory |
        Should -BeTrue -Because "$name wird mit kundeneigener Konfiguration ausgerollt"
    }
  }

  # Die Gegenrichtung, und der eigentliche Preis der Liste: jedes Muster hier kostet bei einer
  # falsch getroffenen App eine Rueckfrage, die sich auch mit abgeschalteten Rueckfragen nicht
  # wegdruecken laesst. Diese Namen muessen ohne Frage durchlaufen.
  It 'laesst alles durch, was aus WinGet aktualisiert werden soll' {
    foreach ($name in @(
      'Google Chrome', 'Microsoft Edge WebView2', 'Mozilla Firefox', '7-Zip', 'Notepad++',
      'Adobe Acrobat Reader DC', 'Visual Studio Code', 'Microsoft Teams', 'Zoom', 'VLC media player',
      'Java 8 Update 421', 'PDF24 Creator', 'Greenshot', 'FileZilla',
      # Der Grund, aus dem 'NinjaOne*'/'NinjaRMM*' dort steht und nicht 'Ninja*': ein fremdes
      # Produkt, dessen Name genauso anfaengt. Faellt das Muster je zusammen, schlaegt dieser Fall an.
      'NinjaTrader')) {
      Test-IsProtectedApp -Name $name -Patterns $script:realFactory |
        Should -BeFalse -Because "$name wird nicht selbst paketiert und soll ohne Rueckfrage laufen"
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

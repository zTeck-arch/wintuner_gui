BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name @(
    'Add-RecentLoginEntry', 'Get-SeededMaxRecentLogins'))))

  # Die Vorgabe aus der Quelle holen, nicht als Zahl abschreiben: sie ist die Parametervorgabe von
  # Add-RecentLoginEntry, und eine Kopie im Test wuerde bei der naechsten Anhebung auseinanderlaufen
  # - der Test prueefte dann eine Grenze, die niemand ausliefert. Ueber den Parser, damit eine
  # auskommentierte Zeile nicht als Zuweisung durchgeht.
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Get-SourcePartPath -Part '10-Settings.ps1'), [ref]$null, [ref]$null)
  $assign = $ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$script:maxRecentLoginsDefault'
  }, $true)
  if (-not $assign) { throw 'Vorgabe $script:maxRecentLoginsDefault nicht gefunden - umbenannt?' }
  . ([scriptblock]::Create($assign.Extent.Text))
  $script:defaultMax = [int]$script:maxRecentLoginsDefault
}

Describe 'Add-RecentLoginEntry' {
  It 'setzt die zuletzt benutzte Adresse nach ganz oben' {
    $r = @(Add-RecentLoginEntry -Entries @('a@alt.de', 'b@alt.de') -Upn 'neu@kunde.de')
    $r[0] | Should -Be 'neu@kunde.de'
    $r.Count | Should -Be 3
  }

  It 'holt eine bekannte Adresse nach oben, statt sie zu verdoppeln' {
    $r = @(Add-RecentLoginEntry -Entries @('a@kunde.de', 'b@kunde.de', 'c@kunde.de') -Upn 'c@kunde.de')
    $r.Count | Should -Be 3
    $r[0] | Should -Be 'c@kunde.de'
    @($r) | Should -Be @('c@kunde.de', 'a@kunde.de', 'b@kunde.de')
  }

  It 'behandelt Gross- und Kleinschreibung als dieselbe Adresse' {
    # Bei Entra ID ist die Adresse unabhaengig von der Schreibweise dieselbe. Vorher belegten
    # 'Adm@Kunde.de' und 'adm@kunde.de' zwei Plaetze - bei acht Plaetzen fiel dafuer ein echter
    # Kunde hinten heraus. Die zuletzt getippte Schreibweise gewinnt.
    $r = @(Add-RecentLoginEntry -Entries @('Adm@Kunde.de', 'b@kunde.de') -Upn 'adm@kunde.de')
    $r.Count | Should -Be 2
    $r[0] | Should -Be 'adm@kunde.de'
  }

  It 'haelt die Grenze ein und wirft den aeltesten Eintrag heraus' {
    $entries = 1..15 | ForEach-Object { "u$_@kunde.de" }
    $r = @(Add-RecentLoginEntry -Entries $entries -Upn 'neu@kunde.de' -Max 15)
    $r.Count | Should -Be 15
    $r[0] | Should -Be 'neu@kunde.de'
    $r | Should -Not -Contain 'u15@kunde.de'
    $r | Should -Contain 'u14@kunde.de'
  }

  It 'nimmt die Vorgabe aus der Quelle, nicht mehr die alten 8' {
    # Der Punkt der Aenderung: ein MSP betreut mehr als acht Kunden, und der neunte fiel lautlos
    # hinten heraus - im Verlauf sah es aus, als haette man sich dort nie angemeldet. Angehoben
    # wurde danach zweimal (8 -> 15 -> 20); der Test nennt die Zahl deshalb nicht selbst.
    $entries = 1..40 | ForEach-Object { "u$_@kunde.de" }
    @(Add-RecentLoginEntry -Entries $entries -Upn 'neu@kunde.de').Count | Should -Be $script:defaultMax
  }

  It 'haelt die heutige Vorgabe bei 20' {
    # Zugesagt am 07.09.2026. Bewusst als eigene Pruefung mit der ausgeschriebenen Zahl: alles
    # andere hier vergleicht gegen die Quelle und wuerde eine versehentliche Senkung mitmachen.
    $script:defaultMax | Should -Be 20
  }

  It 'faellt bei einer unsinnigen Grenze auf die Vorgabe zurueck, statt die Liste zu leeren' {
    $entries = 1..40 | ForEach-Object { "u$_@kunde.de" }
    @(Add-RecentLoginEntry -Entries $entries -Upn 'neu@kunde.de' -Max 0).Count | Should -Be $script:defaultMax
  }

  It 'schneidet Leerzeichen ab und ueberspringt leere Eintraege' {
    $r = @(Add-RecentLoginEntry -Entries @('', '  ', 'b@kunde.de') -Upn '  a@kunde.de  ')
    @($r) | Should -Be @('a@kunde.de', 'b@kunde.de')
  }

  It 'laesst die Liste unveraendert, wenn nichts uebergeben wurde' {
    @(Add-RecentLoginEntry -Entries @('a@kunde.de') -Upn '   ').Count | Should -Be 1
    @(Add-RecentLoginEntry -Entries $null -Upn 'a@kunde.de').Count | Should -Be 1
  }
}

Describe 'Get-SeededMaxRecentLogins' {
  # Gemeldet am 03.09.2026: "aktuell kann ich nur 8 Logins speichern". Im Programm gab es keine
  # solche Grenze - die Vorgabe war schon 15. Eine BESTEHENDE settings.json behaelt aber ihren
  # alten Wert, und das galt fuer jeden Bestandsnutzer: eine erhoehte Vorgabe erreichte nur neue
  # Installationen. Angehoben wird deshalb einmalig, und der Merker haelt fest, dass es geschehen
  # ist - sonst waere ein danach bewusst kleiner gesetzter Wert bei jedem Start wieder weg.

  It 'hebt einen alten Wert einmalig auf die Vorgabe' {
    $r = Get-SeededMaxRecentLogins -Current 8 -Seeded $false -Default 20
    $r.Value | Should -Be 20
    $r.Raised | Should -BeTrue
    $r.Seeded | Should -BeTrue
    $r.Previous | Should -Be 8
  }

  It 'hebt auch die vorherige Vorgabe 15 an' {
    (Get-SeededMaxRecentLogins -Current 15 -Seeded $false -Default 20).Value | Should -Be 20
  }

  It 'laesst einen Wert oberhalb der Vorgabe stehen' {
    # Den hat jemand bewusst hochgesetzt. Ihn auf die Vorgabe zu ZIEHEN waere eine Senkung.
    $r = Get-SeededMaxRecentLogins -Current 50 -Seeded $false -Default 20
    $r.Value | Should -Be 50
    $r.Raised | Should -BeFalse
  }

  It 'ruehrt nach dem Merker keinen Wert mehr an - auch keinen kleinen' {
    # Der eigentliche Punkt: wer die Liste nach der Anhebung bewusst kurz haelt, behaelt seinen
    # Wert. Ohne diese Regel waere die Einstellung bei jedem Start ueberschrieben, und das waere
    # kein Nachtrag mehr, sondern eine Zwangsvorgabe.
    $r = Get-SeededMaxRecentLogins -Current 5 -Seeded $true -Default 20
    $r.Value | Should -Be 5
    $r.Raised | Should -BeFalse
    $r.Seeded | Should -BeTrue
  }

  It 'setzt den Merker auch dann, wenn nichts anzuheben war' {
    # Sonst liefe die Rechnung bei jedem Start erneut - und ein danach gesenkter Wert waere weg.
    (Get-SeededMaxRecentLogins -Current 20 -Seeded $false -Default 20).Seeded | Should -BeTrue
  }
}

Describe 'Verdrahtung der Anhebung' {
  It 'rechnet sie in Load-Settings, ausserhalb des try-Blocks' {
    # Wie beim Werksschutz daneben: eine settings.json, die sich nicht lesen laesst, hinterlaesst
    # die Vorgaben - und die brauchen dieselbe Behandlung.
    $fn = Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Load-Settings'
    $fn | Should -Match 'Get-SeededMaxRecentLogins'
  }

  It 'speichert den Merker beim Start und schreibt eine Protokollzeile' {
    # Ohne das Speichern liefe die Anhebung bei jedem Start erneut. Load-Settings laeuft zu frueh
    # fuer Write-Log und fuer ein Fenster, also gehoert beides in den Add_Shown-Handler.
    $main = Get-SourcePartText -Part '90-Main.ps1'
    $block = [regex]::Match($main, '(?s)\$form\.Add_Shown\(\{[^{}]*maxRecentLoginsRaisedFrom.*?\n\}\)').Value
    $block | Should -Not -BeNullOrEmpty
    $block | Should -Match 'Save-Settings'
    $block | Should -Match 'Write-Log'
  }

  It 'liest die Vorgabe an allen Stellen aus der einen Variablen' {
    # Eine Anhebung, die den Vorgabeblock erwischt und den Loader nicht, kappt die Liste
    # stillschweigend an der alten Zahl. Gegengeprueft: eine der drei Stellen auf eine Zahl
    # zurueckgesetzt -> dieser Fall schlaegt an.
    $text = Get-SourcePartText -Part '10-Settings.ps1'
    $text | Should -Match 'MaxRecentLogins = \$script:maxRecentLoginsDefault'
    $text | Should -Match "-Name 'MaxRecentLogins'\s+-Type Int\s+-Default \`$script:maxRecentLoginsDefault"
    $text | Should -Match '\[int\]\$Max = \$script:maxRecentLoginsDefault'
    $text | Should -Match 'else \{ \$script:maxRecentLoginsDefault \}'
  }
}

Describe 'Die Schutzliste ist von der Update-Ansicht aus erreichbar' {
  # Ein Dialog laesst sich nicht ohne Fenster aufrufen - geprueft wird die Verdrahtung. Ohne diese
  # Regeln waere der Dialog eine Funktion, die niemand ruft.
  BeforeAll {
    $script:dialogText = Get-SourcePartText -Part '55-Dialogs.ps1'
    $script:rowsText = Get-SourcePartText -Part '85-Rows.ps1'
  }

  It 'hat den Knopf in der Update-Karte und oeffnet damit den Dialog' {
    $script:rowsText | Should -Match '\$cardUpdates\.Controls\.Add\(\$protectedManageButton\)'
    $script:rowsText | Should -Match 'Show-ProtectedAppsDialog -SuggestedPattern \$suggested'
  }

  It 'fuellt das Eingabefeld aus der angeklickten Zeile vor' {
    $script:dialogText | Should -Match '\$inputBox\.Text = \(\[string\]\$SuggestedPattern\)\.Trim\(\)'
  }

  It 'rechnet die Knopfbreiten aus dem Text, statt sie zu setzen' {
    # Gemessen am 28.08.2026: mit fester Breite brauchte "Ausgewaehlten entfernen" 136 px und hatte
    # 134 - abgeschnitten in einer von zwei Sprachen, und zwar in der, in der der Text laenger ist.
    $script:dialogText | Should -Match 'Get-ControlTextWidth -Control \$removeButton'
    $script:dialogText | Should -Match 'Get-ControlTextWidth -Control \$addButton'
  }

  It 'zieht nach jeder Aenderung BEIDE anderen Anzeigen derselben Liste nach' {
    # Einstellungskarte und Zeilenfarben lesen dieselbe Liste. Bliebe eine davon stehen, behauptete
    # die eine Stelle etwas anderes als die andere - und die Zeilenfarbe ist die, an der der
    # Techniker vor dem Haken entscheidet.
    $addBlock = [regex]::Match($script:dialogText, '(?s)\$addButton\.Add_Click\(\{.*?\}\)').Value
    $removeBlock = [regex]::Match($script:dialogText, '(?s)\$removeButton\.Add_Click\(\{.*?\}\)').Value
    foreach ($block in @($addBlock, $removeBlock)) {
      $block | Should -Match 'Update-ProtectedAppsList'
      $block | Should -Match 'Update-UpdateListRows'
      $block | Should -Match 'Save-Settings'
    }
  }
}

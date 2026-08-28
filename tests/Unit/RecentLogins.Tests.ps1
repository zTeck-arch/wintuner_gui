BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Add-RecentLoginEntry')))
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

  It 'nimmt 15 als Standard, nicht mehr die alten 8' {
    # Der Punkt der Aenderung: ein MSP betreut mehr als acht Kunden, und der neunte fiel lautlos
    # hinten heraus - im Verlauf sah es aus, als haette man sich dort nie angemeldet.
    $entries = 1..20 | ForEach-Object { "u$_@kunde.de" }
    @(Add-RecentLoginEntry -Entries $entries -Upn 'neu@kunde.de').Count | Should -Be 15
  }

  It 'faellt bei einer unsinnigen Grenze auf 15 zurueck, statt die Liste zu leeren' {
    $entries = 1..20 | ForEach-Object { "u$_@kunde.de" }
    @(Add-RecentLoginEntry -Entries $entries -Upn 'neu@kunde.de' -Max 0).Count | Should -Be 15
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

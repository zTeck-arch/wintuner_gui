#requires -Version 7
# Der Bereich "Kundendaten" fuehrt drei Datenbestaende zusammen, die vorher an drei Stellen lagen.
# Zwei Dinge muessen dabei stimmen, und beide sind hier gepruefte Zusagen und keine Absicht:
#
#   1. FEATURE-PARITAET - jeder Weg, den es vorher gab, muss es weiter geben. Ein Sammelbereich,
#      der weniger kann als die Stellen, die er ersetzt, macht die Sache schlimmer.
#   2. DATENSCHUTZ - Kundennamen, Anmeldeadressen und Gruppen-IDs duerfen NICHT ins Protokoll.
#      Ein Protokoll gibt man aus der Hand; der Kommentar in 10-Settings sagt das seit jeher, und
#      genau deshalb ist eine neue Sektion, die drei Kundenbestaende anfasst, der Ort, an dem man
#      es nachprueft statt es anzunehmen.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient

  $script:rowsText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\85-Rows.ps1')
  $script:uiText   = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\75-UiState.ps1')
  $script:strText  = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\15-Strings.ps1')

  # Der Abschnitt der Sektion - alles zwischen ihrer Add-Section-Zeile und der naechsten Sektion.
  $start = $script:rowsText.IndexOf("Add-Section -Key 'customerdata'")
  $end = $script:rowsText.IndexOf("function Update-AppSettingsLayout")
  $script:sectionText = if ($start -ge 0 -and $end -gt $start) { $script:rowsText.Substring($start, $end - $start) } else { '' }
}

Describe 'Der Bereich existiert und haengt in der richtigen Gruppe' {

  It 'ist eine Sektion der Gruppe "Dieser Rechner" - es sind rein lokale Daten' {
    $script:rowsText | Should -Match "Add-Section -Key 'customerdata'[^\r\n]*-Group 'local'"
  }

  It 'wird beim Betreten neu gefuellt UND neu angeordnet' {
    # Kundennamen aendert man im Dialog, Favoriten am Zuweisungsziel: ein Bereich, der den Stand
    # seines Aufbaus zeigt, behauptet etwas Falsches ueber Kundendaten.
    $script:uiText | Should -Match "Key -eq 'customerdata'"
    $script:uiText | Should -Match 'Update-CustomerDataLists'
    $script:uiText | Should -Match 'Update-CustomerDataLayout'
  }
}

Describe 'Feature-Paritaet zu den drei bisherigen Wegen' {

  It 'oeffnet den vorhandenen Kundennamen-Dialog, statt ihn nachzubauen' {
    $script:sectionText | Should -Match 'Show-TenantNamesDialog'
  }

  It 'oeffnet den vorhandenen Gruppen-Favoriten-Dialog' {
    $script:sectionText | Should -Match 'Show-GroupFavoriteDialog'
  }

  It 'kann gemerkte Anmeldungen einzeln UND komplett entfernen' {
    # Einzeln konnte das vorher niemand - im Menue gab es nur "alle leeren".
    $script:sectionText | Should -Match 'RecentLoginsRemoveButton'
    $script:sectionText | Should -Match 'RecentLoginsClearButton'
  }

  It 'fragt vor dem Leeren nach - mit derselben Rueckfrage wie der Menuepunkt' {
    $script:sectionText | Should -Match 'ClearRecentLoginsConfirm'
  }

  It 'zieht die Kopfzeile nach, wenn eine Anmeldung entfernt wurde' {
    # Sonst bietet das Auswahlfeld im Kopf weiter eine Adresse an, die es nicht mehr gibt.
    ([regex]::Matches($script:sectionText, 'Update-RecentLoginsUI')).Count | Should -BeGreaterOrEqual 2
  }
}

Describe 'Show-GroupFavoriteDialog vertraegt den Aufruf ohne Zieltextfeld' {

  It 'liest die vorgemerkte Id nur, wenn es ein Feld gibt' {
    # Der Bereich oeffnet den Dialog zum PFLEGEN, nicht zum Auswaehlen - ohne $GroupIdBox.
    $fn = Get-SourceFunctionText -Part '75-UiState.ps1' -Name 'Show-GroupFavoriteDialog'
    $fn | Should -Match '\$pendingId = if \(\$GroupIdBox\)'
  }
}

Describe 'Datenschutz: Kundendaten gehoeren nicht ins Protokoll' {

  It 'protokolliert beim Entfernen einer Anmeldung nur die ANZAHL, nie die Adresse' {
    # Die Log-Zeilen dieser Sektion duerfen keine Variable mit einem Einzelwert einsetzen.
    $logLines = [regex]::Matches($script:sectionText, 'Write-Log[^\r\n]*')
    @($logLines).Count | Should -BeGreaterThan 0
    foreach ($m in $logLines) {
      $m.Value | Should -Not -Match '\$sel'
      $m.Value | Should -Not -Match 'SelectedItem'
      $m.Value | Should -Not -Match '\$u\b'
      $m.Value | Should -Not -Match 'TenantDisplayNames'
      $m.Value | Should -Not -Match '\.Id'
    }
  }

  It 'setzt in die Statuszeile nur Anzahlen ein' {
    # Auch die Statuszeile wird abfotografiert und in ein Ticket geklebt.
    $script:sectionText | Should -Match 'CustomerDataCountStatus'
    $script:strText | Should -Match 'CustomerDataCountStatus = "Customer data: \{0\} customer name\(s\)'
    # Der Text selbst darf keine Platzhalter fuer Namen o. ae. anbieten - drei Zahlen, sonst nichts.
    $en = [regex]::Match($script:strText, 'CustomerDataCountStatus = "([^"]*)"').Groups[1].Value
    ([regex]::Matches($en, '\{\d\}')).Count | Should -Be 3
  }
}

# Der Bereich brauchte bei 1146x854 mehr Platz, als er hatte, und scrollte deshalb: gemessen 761 px
# Bedarf bei 639 px Sicht. Die 122 px steckten in der Knopfreihe UNTER jeder Liste (8 + 32 px je
# Karte) und in einer festen Untergrenze von 120 px je Liste. Nach dem Umbau: 627 px, also kein
# Bildlauf mehr - und auf 1920x1080 wuchsen die Listen von 148 auf 188 px.
Describe 'Anordnung des Kundendaten-Bereichs' {

  BeforeAll {
    $script:layoutFn = Get-SourceFunctionText -Part '85-Rows.ps1' -Name 'Update-CustomerDataLayout'
  }

  It 'rechnet unter der Liste keinen Platz mehr fuer die Knopfreihe ein' {
    $script:layoutFn | Should -Match '\$belowList = 0'
    $script:layoutFn | Should -Not -Match '\$belowList = 8 \+ 32'
  }

  It 'setzt die Knoepfe in die Titelzeile und nicht unter die Liste' {
    $script:layoutFn | Should -Not -Match '\$sibling\.Top = \$l\.Bottom'
    $script:layoutFn | Should -Match '\$b\.Top = 12'
  }

  # Sieben Designs bringen verschiedene Schriftgroessen mit. Eine feste Zahl, die in einem davon
  # sechs Zeilen ergibt, ergibt in einem anderen vier.
  It 'leitet die Untergrenze aus der Schrifthoehe ab statt sie festzuschreiben' {
    $script:layoutFn | Should -Match '\$rowHeight'
    $script:layoutFn | Should -Match '\$minList = 7 \* \$rowHeight'
    $script:layoutFn | Should -Not -Match 'if \(\$perList -lt 120\)'
  }

  # Ohne das laeuft das Rechteck der Hinweiszeile unter die Knoepfe. Sichtbar faellt es nicht auf,
  # weil der Text kuerzer ist als sein Feld - bei einem laengeren deutschen Text waere es echt.
  It 'kuerzt die Hinweiszeile vor dem linken Knopf' {
    $script:layoutFn | Should -Match "Tag -eq 'hint'"
    $script:layoutFn | Should -Match '\$hint\.Width'
  }
}

Describe 'UI-Texte in beiden Sprachen' {

  It 'definiert jeden neuen Schluessel genau zweimal - EN und DE' {
    foreach ($key in @('NavCustomerData', 'CustomerDataTitle', 'CustomerNamesCardTitle',
                       'CustomerNamesCardHint', 'CustomerNamesEditButton', 'CustomerNamesEmpty',
                       'GroupFavoritesCardTitle', 'GroupFavoritesCardHint', 'GroupFavoritesEditButton',
                       'GroupFavoritesEmpty', 'GroupFavoritesNoTenant', 'RecentLoginsCardTitle',
                       'RecentLoginsCardHint', 'RecentLoginsRemoveButton', 'RecentLoginsClearButton',
                       'ColCustomerDomain', 'ColCustomerName', 'CustomerDataCountStatus')) {
      $n = ([regex]::Matches($script:strText, ('(?m)^    {0} = ' -f [regex]::Escape($key)))).Count
      $n | Should -Be 2 -Because "$key muss in beiden Sprachbloecken stehen"
    }
  }
}

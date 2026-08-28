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

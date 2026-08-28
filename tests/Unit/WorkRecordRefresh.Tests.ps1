BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Update-WorkRecordText')))

  # Steht fuer Kopfzeile und Textfeld. Ein PSCustomObject mit .Text reicht - die Funktion fasst
  # nichts an, was ein echtes WinForms-Control waere, und ein Fenster im Test waere nur Ballast.
  function New-FakeWorkRecordUi {
    param([string]$BoxText = '')
    @{
      Box           = [pscustomobject]@{ Text = $BoxText }
      Header        = [pscustomobject]@{ Text = 'alte Kopfzeile' }
      LastGenerated = $BoxText
    }
  }

  Set-Item -Path function:global:Get-SessionLeistungstext -Value { $global:FakeRecordText }
  Set-Item -Path function:global:Get-SessionLeistungsHeader -Value { 'Kunde: kunde.de' }
}

AfterAll {
  Remove-Item -Path function:global:Get-SessionLeistungstext -ErrorAction SilentlyContinue
  Remove-Item -Path function:global:Get-SessionLeistungsHeader -ErrorAction SilentlyContinue
}

Describe 'Update-WorkRecordText' {
  BeforeEach { $global:FakeRecordText = 'Aktualisiert: Google Chrome 151 -> 152' }

  It 'erzeugt den Text neu, wenn im Feld noch der selbst erzeugte Stand steht' {
    # Der gemeldete Fehler: der Bereich wird VOR der Anmeldung gebaut, also stand dort der
    # Anmelde-Hinweis - auch nach zwei erfolgreich aktualisierten Apps (Protokoll 28.08.2026,
    # 08:25:35 fertig, 08:29:47 Bereich geoeffnet).
    $script:workRecordUi = New-FakeWorkRecordUi -BoxText 'Bitte an einem Tenant anmelden, um dessen Leistungsnachweis zu sehen.'
    Update-WorkRecordText
    $script:workRecordUi.Box.Text | Should -Be 'Aktualisiert: Google Chrome 151 -> 152'
  }

  It 'zieht die Kopfzeile mit' {
    $script:workRecordUi = New-FakeWorkRecordUi -BoxText 'alter Stand'
    Update-WorkRecordText
    $script:workRecordUi.Header.Text | Should -Be 'Kunde: kunde.de'
  }

  It 'merkt sich den erzeugten Stand, damit der naechste Aufruf ihn nicht fuer eine Hand-Aenderung haelt' {
    $script:workRecordUi = New-FakeWorkRecordUi -BoxText 'alter Stand'
    Update-WorkRecordText
    $script:workRecordUi.LastGenerated | Should -Be 'Aktualisiert: Google Chrome 151 -> 152'
  }

  It 'ueberschreibt eine Hand-Aenderung NICHT' {
    # Das Feld ist bearbeitbar, weil der Text in ein Ticket wandert. Wer dort eine Zeile ergaenzt und
    # kurz in einen anderen Bereich wechselt, darf sie nicht verlieren.
    $ui = New-FakeWorkRecordUi -BoxText 'erzeugter Stand'
    $ui.Box.Text = 'erzeugter Stand + meine Ergaenzung fuer das Ticket'
    $script:workRecordUi = $ui
    Update-WorkRecordText
    $script:workRecordUi.Box.Text | Should -Be 'erzeugter Stand + meine Ergaenzung fuer das Ticket'
  }

  It 'ueberschreibt eine Hand-Aenderung mit -Force - dort aendert sich der Inhalt wirklich' {
    # Sprache, Sitzung, Loeschen: da ist der alte Text nicht mehr die Antwort auf die gestellte Frage.
    $ui = New-FakeWorkRecordUi -BoxText 'erzeugter Stand'
    $ui.Box.Text = 'meine Ergaenzung'
    $script:workRecordUi = $ui
    Update-WorkRecordText -Force
    $script:workRecordUi.Box.Text | Should -Be 'Aktualisiert: Google Chrome 151 -> 152'
  }

  It 'kommt ohne aufgebauten Bereich aus' {
    # Der Bereichswechsel ruft die Funktion auch, bevor der Nachweis je gebaut wurde.
    $script:workRecordUi = $null
    { Update-WorkRecordText } | Should -Not -Throw
  }
}

Describe 'Der Bereichswechsel zieht den Nachweis nach' {
  It 'ruft beim Oeffnen des Bereichs nicht nur das Layout, sondern auch den Inhalt' {
    # Ohne diesen Aufruf ist Update-WorkRecordText eine Funktion, die niemand ruft: alles gruen, und
    # im Bereich stuende weiter der Anmelde-Hinweis. Layout und Inhalt sind zwei verschiedene Dinge.
    $text = Get-SourcePartText -Part '75-UiState.ps1'
    $text | Should -Match "if \(\`$Key -eq 'workrecord' -and \(Get-Command Update-WorkRecordText"
    $text | Should -Match 'try \{ Update-WorkRecordText \} catch'
  }

  It 'laesst alle Neuerzeugungen ueber dieselbe Funktion laufen' {
    # Ein direktes $ui.Box.Text = Get-SessionLeistungstext wuerde LastGenerated nicht mitfuehren -
    # danach haelt JEDER spaetere Bereichswechsel den Stand fuer eine Hand-Aenderung und zieht nie
    # wieder nach. Genau der Zustand, der den Fehler ueberhaupt so lange unsichtbar gemacht hat.
    $fn = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Show-LeistungstextDialog'
    $assignments = [regex]::Matches($fn, '\$ui\.Box\.Text\s*=\s*Get-SessionLeistungstext')
    $assignments.Count | Should -Be 0
    $fn | Should -Match 'LastGenerated = \[string\]\$box\.Text'
  }
}

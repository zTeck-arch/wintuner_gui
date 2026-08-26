BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Show-StartupDialog')))
  $DialogSource = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Show-StartupDialog'
}

Describe 'Show-StartupDialog' {
  # Die Regressionspruefung zu dem Fehler, der die CI von 0.16.0 haengen liess: auf einem Rechner
  # ohne WinTuner-Modul schlaegt Import-Module beim Start fehl, und der Fehlerzweig zeigte eine
  # MessageBox. Ein Lauf ohne Benutzer klickt nie - der Smoke-Test lief nach 180 s in seinen
  # Zeitablauf, und nur dort, weil auf dem Entwicklungsrechner das Modul vorhanden ist.

  AfterEach { Remove-Item -LiteralPath Env:WINTUNER_SMOKE -ErrorAction SilentlyContinue }

  It 'returns without showing a dialog while the smoke flag is set' {
    $env:WINTUNER_SMOKE = '1'
    # Kehrt der Aufruf zurueck, war keine modale MessageBox im Spiel - eine solche wartet auf einen
    # Klick, und dieser Test laeuft ohne Benutzer. Der Zeitablauf ist die eigentliche Aussage.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Show-StartupDialog -Text 'Import failed' -Title 'Module' 6>$null
    $sw.Stop()
    $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
  }

  It 'reports the suppressed dialog on standard output instead of swallowing it' {
    $env:WINTUNER_SMOKE = '1'
    # Write-Host schreibt in den Informationsstrom (6); der Smoke-Test wertet den FEHLERstrom aus,
    # eine Meldung dort wuerde den Lauf rot machen.
    $written = @(Show-StartupDialog -Text "Import failed:`r`n  no module" -Title 'Module' 6>&1) -join ' '
    $written | Should -Match 'Module'
    $written | Should -Match 'Import failed'
    # Einzeilig: eine mehrzeilige Meldung im CI-Protokoll ist nicht mehr einer Ursache zuzuordnen.
    $written | Should -Not -Match "`n"
  }

  It 'keeps the message box behind the smoke check' {
    # Ohne die Reihenfolge ist die Funktion wirkungslos: erst die Abfrage der Umgebungsvariable
    # mit ihrem return, dann der Dialog.
    $flagIndex = $DialogSource.IndexOf('WINTUNER_SMOKE')
    # Gesucht ist der AUFRUF, nicht die Typangabe des -Icon-Parameters weiter oben.
    $boxIndex = $DialogSource.IndexOf('MessageBox]::Show')
    $flagIndex | Should -BeGreaterThan -1
    $boxIndex | Should -BeGreaterThan $flagIndex
    $DialogSource | Should -Match 'return'
  }
}

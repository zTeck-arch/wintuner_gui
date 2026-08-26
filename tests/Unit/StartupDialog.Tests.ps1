BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Test-UnattendedRun', 'Show-StartupDialog')))
  $DialogSource = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Show-StartupDialog'
}

Describe 'Show-StartupDialog' {
  # Die Regressionspruefung zu dem Fehler, der die CI von 0.16.0 zweimal haengen liess: auf einem
  # Rechner ohne WinTuner-Modul schlaegt Import-Module beim Start fehl, und der Fehlerzweig zeigte
  # eine MessageBox. Ein Lauf ohne Benutzer klickt nie - erst lief der Smoke-Test nach 180 s in
  # seinen Zeitablauf, dann die Layout-Probe nach 240 s, weil die erste Fassung nur die
  # Smoke-Kennung kannte. Beide Kennungen werden deshalb hier geprueft.

  AfterEach {
    Remove-Item -LiteralPath Env:WINTUNER_SMOKE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Env:WINTUNER_LAYOUT -ErrorAction SilentlyContinue
  }

  It 'recognises <Flag> as an unattended run' -ForEach @(
    @{ Flag = 'WINTUNER_SMOKE' }, @{ Flag = 'WINTUNER_LAYOUT' }
  ) {
    Set-Item -LiteralPath ("Env:" + $Flag) -Value '1'
    Test-UnattendedRun | Should -BeTrue
  }

  It 'treats a start without any probe flag as attended' {
    Test-UnattendedRun | Should -BeFalse
  }

  It 'returns without showing a dialog under <Flag>' -ForEach @(
    @{ Flag = 'WINTUNER_SMOKE' }, @{ Flag = 'WINTUNER_LAYOUT' }
  ) {
    Set-Item -LiteralPath ("Env:" + $Flag) -Value '1'
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

  It 'keeps the message box behind the unattended check' {
    # Ohne die Reihenfolge ist die Funktion wirkungslos: erst die Abfrage mit ihrem return, dann
    # der Dialog.
    $flagIndex = $DialogSource.IndexOf('Test-UnattendedRun')
    # Gesucht ist der AUFRUF, nicht die Typangabe des -Icon-Parameters weiter oben.
    $boxIndex = $DialogSource.IndexOf('MessageBox]::Show')
    $flagIndex | Should -BeGreaterThan -1
    $boxIndex | Should -BeGreaterThan $flagIndex
    $DialogSource | Should -Match 'return'
  }
}

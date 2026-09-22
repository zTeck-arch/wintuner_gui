#requires -Version 7
# Was das Protokoll und die Statuszeile BEHAUPTEN, muss stimmen.
#
# Alle drei Faelle hier stammen aus einem echten Protokoll vom 08.09.2026. Keiner davon war ein
# Datenverlust - aber jeder hat den Leser in die Irre gefuehrt, und genau deshalb wurde jedes Mal
# gefragt, ob etwas kaputt ist:
#
#   1. "Removing old version: Notepad++ 8.9.4" stand VOR den Sicherheitspruefungen, die die Version
#      dann behielten. Wer nur Chrome aktualisiert hatte, las eine Loeschung an einer fremden App.
#   2. "confirmations suppressed=True (accepted for version '0.16.0')" bei laufender 0.18.1: das
#      Unterdruecken war NICHT wirksam, die Zeile sah aber wie das Gegenteil aus.
#   3. "Version cleanup ... 3 failed" und eine Zeile spaeter "3 successful, 0 failed" - beide
#      Bilanzen richtig, aber die letzte sichtbare Meldung verschwieg die drei Fehlschlaege.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name @(
    'Get-SettingsSnapshotLines'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Get-BatchSummaryStatus')))
}

Describe 'Die Pruefmeldung des Versionsaufraeumens' {
  It 'sagt PRUEFEN, nicht ENTFERNEN - die Pruefungen kommen erst danach' {
    # Die Zeile wird geschrieben, bevor Zuweisungs- und Installationssonde gelaufen sind. Sie darf
    # deshalb keine Loeschung behaupten.
    $script:uiLanguage = 'en'
    (Get-UiString 'VersionCleanupRemovingStatus') | Should -Match 'Checking whether'
    (Get-UiString 'VersionCleanupRemovingStatus') | Should -Not -Match '^Removing'
    $script:uiLanguage = 'de'
    (Get-UiString 'VersionCleanupRemovingStatus') | Should -Match 'Prüfe'
  }

  It 'wird im Quelltext auch wirklich VOR den Sonden geschrieben' {
    # Waere sie nach den Sonden, waere der neue Text falsch - dann wuesste man an dieser Stelle
    # schon, ob geloescht wird.
    $engine = Get-SourcePartText -Part '50-UpdateEngine.ps1'
    $statusPos = $engine.IndexOf("VersionCleanupRemovingStatus")
    $probePos = $engine.IndexOf('$assignmentProbe = Get-AppAssignmentProbe -AppId $item.App.GraphId')
    $statusPos | Should -BeGreaterThan 0
    $probePos | Should -BeGreaterThan 0
    $statusPos | Should -BeLessThan $probePos
  }

  It 'nennt im Kopf, dass ueber den GANZEN Tenant geprueft wird' {
    # Ohne das liest ein Techniker, der nur Chrome aktualisiert hat, Zeilen zu Notepad++ und haelt
    # sie fuer eine Nebenwirkung seines Klicks.
    $batch = Get-SourcePartText -Part '60-Batch.ps1'
    $batch | Should -Match 'checking EVERY app in the tenant'
  }
}

Describe 'Get-SettingsSnapshotLines: die Wirkung, nicht nur der Schalter' {
  BeforeEach {
    $script:appVersion = '0.18.1'
  }

  It 'sagt NICHT wirksam, wenn das Risiko fuer eine ANDERE Version bestaetigt wurde' {
    # Der gemeldete Fall: Schalter an, bestaetigt fuer 0.16.0, laufend 0.18.1 - die Rueckfragen
    # kommen also. Die Zeile muss das sagen, sonst sucht man den Fehler an der falschen Stelle.
    $settings = @{ SuppressChangeConfirmations = $true; ChangeConfirmationRiskAcceptedVersion = '0.16.0' }
    $line = @(Get-SettingsSnapshotLines -Settings $settings | Where-Object { $_ -match 'confirmations suppressed' })[0]
    $line | Should -Match 'NOT in effect'
    $line | Should -Match '0\.16\.0'
    $line | Should -Match '0\.18\.1'
  }

  It 'sagt wirksam, wenn die Bestaetigung zur laufenden Version passt' {
    $settings = @{ SuppressChangeConfirmations = $true; ChangeConfirmationRiskAcceptedVersion = '0.18.1' }
    $line = @(Get-SettingsSnapshotLines -Settings $settings | Where-Object { $_ -match 'confirmations suppressed' })[0]
    $line | Should -Match 'IN EFFECT'
    $line | Should -Not -Match 'NOT in effect'
  }

  It 'sagt aus, wenn der Schalter gar nicht gesetzt ist' {
    $settings = @{ SuppressChangeConfirmations = $false; ChangeConfirmationRiskAcceptedVersion = '' }
    $line = @(Get-SettingsSnapshotLines -Settings $settings | Where-Object { $_ -match 'confirmations suppressed' })[0]
    $line | Should -Match 'off'
  }
}

Describe 'Die Abschlussmeldung verschweigt keinen Aufraeum-Fehlschlag' {
  BeforeAll {
    $script:main = Get-SourcePartText -Part '90-Main.ps1'
    $script:batch = Get-SourcePartText -Part '60-Batch.ps1'
    $script:engine = Get-SourcePartText -Part '50-UpdateEngine.ps1'
  }

  It 'reicht die Zahl der gescheiterten Loeschungen aus dem Aufraeumen durch' {
    $script:engine | Should -Match '\$script:lastVersionCleanupFailed = \$failed'
    $script:main | Should -Match 'CleanupFailed \(\[int\]\$script:lastVersionCleanupFailed\)'
  }

  # Seit 0.21.1 gilt dasselbe fuer den Erfolg: ein Lauf, der sieben alte Versionen ENTFERNT hat,
  # endete sichtbar mit "0 fehlgeschlagen" und sonst nichts (gemeldet am 22.09.2026). Wer loescht,
  # muss das sagen - nicht nur, wer beim Loeschen scheitert.
  It 'reicht die Zahl der entfernten Versionen genauso durch' {
    $script:engine | Should -Match '\$script:lastVersionCleanupRemoved = \$removed'
    $script:main | Should -Match 'CleanupRemoved \(\[int\]\$script:lastVersionCleanupRemoved\)'
  }

  # Gegen die Fundstelle zu pruefen war der Fehler der ersten Fassung: die Zusicherung hing an
  # einem Textschluessel IN 90-Main, und eine Verschiebung derselben Entscheidung in eine eigene
  # Rechnung liess sie rot werden, obwohl sich am Verhalten nichts geaendert hatte. Gefragt wird
  # jetzt die Rechnung selbst, in beiden Sprachen.
  It 'nennt beides in der Statuszeile, statt es mit "0 fehlgeschlagen" zu ueberschreiben' {
    foreach ($lang in @('en', 'de')) {
      $script:uiLanguage = $lang
      $failedOnly = Get-BatchSummaryStatus -SuccessCount 3 -FailedCount 0 -CleanupFailed 3
      $removedOnly = Get-BatchSummaryStatus -SuccessCount 3 -FailedCount 0 -CleanupRemoved 7
      $plain = Get-BatchSummaryStatus -SuccessCount 3 -FailedCount 0

      $failedOnly | Should -Match '3'
      $failedOnly | Should -Not -Be $plain
      $removedOnly | Should -Match '7'
      $removedOnly | Should -Not -Be $plain
      $removedOnly | Should -Not -Be $failedOnly
    }
  }

  It 'setzt den Merker VOR der Bedingung zurueck, nicht darin' {
    # Sonst stammte die Zahl bei abgeschaltetem Aufraeumen aus einem FRUEHEREN Lauf, und die
    # Abschlussmeldung meldete einen Fehlschlag, den es in diesem Lauf nicht gab. Genau dieser
    # Fehler stand einen Moment in der ersten Fassung dieser Aenderung.
    # Beide Merker, aus demselben Grund: eine stehengebliebene Zahl aus einem frueheren Lauf
    # behauptet Loeschungen, die dieser Lauf nicht gemacht hat.
    $ifPos = $script:batch.IndexOf('if ($successCount -gt 0 -and $script:settings.AutoVersionCleanup)')
    $ifPos | Should -BeGreaterThan 0
    foreach ($marker in @('$script:lastVersionCleanupFailed = 0', '$script:lastVersionCleanupRemoved = 0')) {
      $resetPos = $script:batch.IndexOf($marker)
      $resetPos | Should -BeGreaterThan 0
      $resetPos | Should -BeLessThan $ifPos
    }
  }
}

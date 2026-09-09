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
    $script:main | Should -Match '\$cleanupFailed = \[int\]\$script:lastVersionCleanupFailed'
  }

  It 'nennt sie in der Statuszeile, statt sie mit "0 fehlgeschlagen" zu ueberschreiben' {
    $script:main | Should -Match 'CheckedAppsUpdatedCleanupFailedStatus'
    foreach ($lang in @('en', 'de')) {
      $script:uiLanguage = $lang
      (Get-UiString 'CheckedAppsUpdatedCleanupFailedStatus') | Should -Not -BeNullOrEmpty
    }
  }

  It 'setzt den Merker VOR der Bedingung zurueck, nicht darin' {
    # Sonst stammte die Zahl bei abgeschaltetem Aufraeumen aus einem FRUEHEREN Lauf, und die
    # Abschlussmeldung meldete einen Fehlschlag, den es in diesem Lauf nicht gab. Genau dieser
    # Fehler stand einen Moment in der ersten Fassung dieser Aenderung.
    $resetPos = $script:batch.IndexOf('$script:lastVersionCleanupFailed = 0')
    $ifPos = $script:batch.IndexOf('if ($successCount -gt 0 -and $script:settings.AutoVersionCleanup)')
    $resetPos | Should -BeGreaterThan 0
    $ifPos | Should -BeGreaterThan 0
    $resetPos | Should -BeLessThan $ifPos
  }
}

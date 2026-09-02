# Trennen/Abmelden waehrend eines Laufs, und der Lauf ohne Sitzung.
#
# Der Fehler, der das ausgeloest hat: waehrend eines Update-Laufs wurde "Trennen" geklickt. Die
# Sitzung war sofort weg, der Lauf lief weiter - paketierte, wartete Wiederholungspausen ab und
# lud gegen einen Tenant, den es nicht mehr gab. Genau das darf nicht mehr passieren:
#
#   1. "Trennen"/"Abmelden" waehrend eines Laufs trennt NICHT sofort, sondern stoppt erst den Lauf
#      und stellt die Trennung zurueck (ausgefuehrt vom Pumpen der zurueckgestellten Aktionen).
#   2. Ohne Sitzung bricht der Stapellauf am naechsten App-Wechsel ab.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name @(
    'Add-DeferredAction', 'Test-OperationRunning', 'Invoke-PendingDeferredActions', 'Format-ErrorDetail'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '75-UiState.ps1' -Name @(
    'Test-ProgressVisible', 'Request-RunCancel'))))
  # Request-RunCancel stoppt seit 0.18.0 auch den Vorab-Bau: ein Abbruch soll keinen Paketbau
  # stehenlassen, der fuer einen Lauf baut, den es nicht mehr gibt.
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '35-Packaging.ps1' -Name 'Stop-PackagePrebuild')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '90-Main.ps1' -Name 'Test-DeferWhileRunning')))
}

Describe 'Trennen waehrend eines Laufs' {

  BeforeEach {
    $script:deferredActions = [ordered]@{}
    $script:deferredRunning = $false
    $script:packagingBusy = $false
    $script:cancelBatch = $false
    $script:cancelRunButton = $null
    $global:TestDisconnected = $false
    # Sichtbare Fortschrittsanzeige = laufender Vorgang (so entscheidet Test-OperationRunning).
    $script:progressLabel = New-Object System.Windows.Forms.Label
    $script:progressLabel.Visible = $true
  }

  It 'trennt nicht sofort, sondern stoppt den Lauf und stellt die Trennung zurueck' {
    $deferred = Test-DeferWhileRunning -Key 'disconnect' -Action { $global:TestDisconnected = $true } -Label 'Trennen'

    $deferred | Should -BeTrue
    $global:TestDisconnected | Should -BeFalse       # noch nicht getrennt
    $script:cancelBatch | Should -BeTrue             # aber der Lauf ist gestoppt
    $script:deferredActions.Count | Should -Be 1
    $global:TestStatus | Should -Be (Get-UiString 'DisconnectDuringRunStatus')
  }

  It 'trennt sofort, wenn kein Vorgang laeuft' {
    $script:progressLabel.Visible = $false

    $deferred = Test-DeferWhileRunning -Key 'disconnect' -Action { $global:TestDisconnected = $true } -Label 'Trennen'

    $deferred | Should -BeFalse                      # der Aufrufer trennt selbst
    $script:cancelBatch | Should -BeFalse
    $script:deferredActions.Count | Should -Be 0
  }

  It 'fuehrt die zurueckgestellte Trennung aus, sobald der Lauf beendet ist' {
    [void](Test-DeferWhileRunning -Key 'disconnect' -Action { $global:TestDisconnected = $true } -Label 'Trennen')

    # Solange der Lauf laeuft, passiert nichts.
    Invoke-PendingDeferredActions
    $global:TestDisconnected | Should -BeFalse

    # Lauf zu Ende (Hide-Progress), naechster Timer-Tick.
    $script:progressLabel.Visible = $false
    Invoke-PendingDeferredActions
    $global:TestDisconnected | Should -BeTrue
    $script:deferredActions.Count | Should -Be 0
  }
}

Describe 'Stapellauf ohne Tenant-Sitzung' {

  It 'bricht laut ab, statt gegen eine getrennte Sitzung weiterzuarbeiten' {
    # Geprueft wird die Regel im Quelltext: die Schleife ueber die Apps muss VOR der Arbeit an einer
    # App auf $script:isConnected sehen. Der Lauf selbst ist ohne Tenant nicht ausfuehrbar, die
    # Bedingung dafuer aber sehr wohl pruefbar - und sie war der Fehler.
    $batch = Get-SourceFunctionText -Part '60-Batch.ps1' -Name 'Invoke-AppUpdateBatch'
    $batch | Should -Match '\$script:isConnected'
    $batch | Should -Match 'BatchAbortedDisconnectedStatus'
  }
}

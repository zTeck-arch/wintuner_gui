# Read-AssignmentSettingsControls ist die zusammengeführte Semantik der Zuweisungs-Oberfläche
# (Befund F23). Vorher stand sie zweimal Zeile für Zeile da - einmal für den WinGet-Weg, einmal für
# den Store-Weg -, und eine Korrektur an einer Kopie wäre in der anderen unbemerkt ausgeblieben.
#
# Was hier geprüft wird, ist genau das, was bei einer Abweichung falsche Einstellungen in einem
# Kundentenant erzeugt: die Zuordnung von Auswahlindex zu Benachrichtigungsstufe, wann eine Frist
# überhaupt mitgeschickt wird, welche Neustart-Kombination unzulässig ist, und dass "nichts zu
# ändern" gar nichts schickt statt ein leeres Objekt, das Bestehendes überschreiben würde.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '80-Views.ps1' -Name 'Read-AssignmentSettingsControls')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' `
    -Name 'New-AssignmentSettingsObject', 'Get-AssignmentSettingsSummary')))

  # Attrappen mit genau den Eigenschaften, die der Leser anfasst.
  function New-Combo { param([int]$Index) [pscustomobject]@{ SelectedIndex = $Index } }
  function New-Check { param([bool]$On)   [pscustomobject]@{ Checked = $On } }
  function New-Value { param($Value)      [pscustomobject]@{ Value = $Value } }

  # Der volle Satz (WinGet-Weg), standardmäßig auf "nichts eingeschaltet".
  function New-Controls {
    param(
      [int]$Notify = 0, [bool]$Avail = $false, [bool]$Deadline = $false, [bool]$LocalTime = $false,
      [bool]$Restart = $false, [int]$Grace = 120, [int]$Countdown = 15,
      [bool]$Snooze = $false, [int]$SnoozeMinutes = 30, [int]$Delivery = 0
    )
    return @{
      NotifyCombo           = New-Combo $Notify
      AvailCheck            = New-Check $Avail
      AvailPicker           = New-Value ([datetime]'2026-09-01T08:00:00')
      DeadlineCheck         = New-Check $Deadline
      DeadlinePicker        = New-Value ([datetime]'2026-09-08T18:00:00')
      LocalTimeCheck        = New-Check $LocalTime
      RestartEnableCheck    = New-Check $Restart
      RestartGraceValue     = New-Value $Grace
      RestartCountdownValue = New-Value $Countdown
      RestartSnoozeCheck    = New-Check $Snooze
      RestartSnoozeValue    = New-Value $SnoozeMinutes
      DeliveryCombo         = New-Combo $Delivery
    }
  }
}

Describe 'Read-AssignmentSettingsControls - Benachrichtigungsstufen' {
  It 'schickt bei Index 0 (unverändert lassen) keine Stufe mit' {
    $s = Read-AssignmentSettingsControls -Controls (New-Controls -LocalTime $true)
    # UseLocalTime allein zählt nicht als Änderung der Benachrichtigung.
    "$($s.notifications)" | Should -BeNullOrEmpty
  }
  It 'bildet Index 1/2/3 auf showAll / showReboot / hideAll ab' {
    (Read-AssignmentSettingsControls -Controls (New-Controls -Notify 1)).notifications | Should -Be 'showAll'
    (Read-AssignmentSettingsControls -Controls (New-Controls -Notify 2)).notifications | Should -Be 'showReboot'
    (Read-AssignmentSettingsControls -Controls (New-Controls -Notify 3)).notifications | Should -Be 'hideAll'
  }
}

Describe 'Read-AssignmentSettingsControls - Daten nur mit gesetztem Haken' {
  It 'schickt kein Verfügbarkeitsdatum, solange der Haken fehlt' {
    $s = Read-AssignmentSettingsControls -Controls (New-Controls -Notify 1 -Avail $false)
    "$($s.startDateTime)" | Should -BeNullOrEmpty
  }
  It 'schickt das Verfügbarkeitsdatum, wenn der Haken gesetzt ist' {
    $s = Read-AssignmentSettingsControls -Controls (New-Controls -Avail $true)
    $s | Should -Not -BeNullOrEmpty
  }
  It 'schickt keine Frist, solange der Haken fehlt' {
    $s = Read-AssignmentSettingsControls -Controls (New-Controls -Notify 1 -Deadline $false)
    "$($s.deadlineDateTime)" | Should -BeNullOrEmpty
  }
}

Describe 'Read-AssignmentSettingsControls - Neustart-Grenzen' {
  It 'nimmt eine zulässige Kombination an' {
    { Read-AssignmentSettingsControls -Controls (New-Controls -Restart $true -Grace 120 -Countdown 15) } |
      Should -Not -Throw
  }
  It 'lehnt einen Countdown ab, der länger als die Kulanzzeit ist' {
    # Sonst liefe die Frist in Intune vor ihrer eigenen Ankündigung ab.
    { Read-AssignmentSettingsControls -Controls (New-Controls -Restart $true -Grace 10 -Countdown 60) } |
      Should -Throw
  }
  It 'lehnt einen Aufschub ab, der länger als die Kulanzzeit ist' {
    { Read-AssignmentSettingsControls -Controls (New-Controls -Restart $true -Grace 10 -Countdown 5 -Snooze $true -SnoozeMinutes 600) } |
      Should -Throw
  }
  It 'zählt den Aufschub nur, wenn sein Haken gesetzt ist' {
    { Read-AssignmentSettingsControls -Controls (New-Controls -Restart $true -Grace 10 -Countdown 5 -Snooze $false -SnoozeMinutes 600) } |
      Should -Not -Throw
  }
  It 'prüft gar nicht, solange der Neustart-Block aus ist' {
    { Read-AssignmentSettingsControls -Controls (New-Controls -Restart $false -Grace 1 -Countdown 9999) } |
      Should -Not -Throw
  }
}

Describe 'Read-AssignmentSettingsControls - Store-Variante ohne die zwei Felder' {
  It 'kommt ohne AvailCheck und DeliveryCombo aus' {
    # Genau der Satz, den Get-StoreAssignmentSettings übergibt: kein Verfügbarkeitsdatum, keine
    # Zustellpriorität. Fehlende Schlüssel dürfen nicht in einen Fehler laufen.
    $store = @{
      NotifyCombo           = New-Combo 2
      DeadlineCheck         = New-Check $true
      DeadlinePicker        = New-Value ([datetime]'2026-09-08T18:00:00')
      LocalTimeCheck        = New-Check $true
      RestartEnableCheck    = New-Check $false
      RestartGraceValue     = New-Value 120
      RestartCountdownValue = New-Value 15
      RestartSnoozeCheck    = New-Check $false
      RestartSnoozeValue    = New-Value 30
    }
    # Getrennt aufrufen statt im Scriptblock von Should -Not -Throw: eine Zuweisung dort landet in
    # dessen eigenem Scope, und $s bliebe hier draußen $null - der Test hätte sich selbst geprüft.
    { Read-AssignmentSettingsControls -Controls $store } | Should -Not -Throw
    $s = Read-AssignmentSettingsControls -Controls $store
    $s.notifications | Should -Be 'showReboot'
  }
  It 'setzt ohne DeliveryCombo niemals die Zustellpriorität' {
    $store = @{ NotifyCombo = New-Combo 1; LocalTimeCheck = New-Check $false }
    $s = Read-AssignmentSettingsControls -Controls $store
    "$($s.deliveryOptimizationPriority)" | Should -BeNullOrEmpty
  }
}

Describe 'Read-AssignmentSettingsControls - nichts zu ändern' {
  It 'gibt $null zurück, wenn nichts gesetzt wurde' {
    # Ein leeres Settings-Objekt würde in Intune bestehende Werte überschreiben statt sie in Ruhe
    # zu lassen - deshalb gar nichts schicken.
    Read-AssignmentSettingsControls -Controls (New-Controls) | Should -BeNullOrEmpty
  }
  It 'gibt $null auch bei einem völlig leeren Steuerelementsatz zurück' {
    Read-AssignmentSettingsControls -Controls @{} | Should -BeNullOrEmpty
  }
}

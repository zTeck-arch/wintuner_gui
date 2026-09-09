#requires -Version 7
# Installationen auf Geraeten, die seit Wochen oder Monaten nicht mehr einchecken.
#
# Gemeldet am 09.09.2026 aus dem Betrieb: in gewachsenen Kundenumgebungen liegen stille Geraete. Auf
# ihnen ist eine uralte App-Fassung installiert, und genau dieser Eintrag verhindert dauerhaft, dass
# die Fassung abgeloest und geloescht werden kann - obwohl niemand mehr etwas davon hat. Die Probe
# brach bis dahin beim ERSTEN gemeldeten "installiert" ab und las kein Datum: "irgendwann hat
# irgendein Geraet gemeldet" schuetzte fuer immer.
#
# Zur Einordnung, weil es die Entscheidung traegt: eine geloeschte App wird auf dem Geraet NICHT
# deinstalliert. Die Software bleibt; Intune verliert Bericht, Zuweisung und die Moeglichkeit zur
# Neuinstallation aus diesem Objekt. Das Netz schuetzt also die Verwaltbarkeit, nicht die Geraete.
#
# Angesagt am 09.09.2026: Aktivitaetsfenster als Kriterium, und NUR beim Aufraeumen von Hand.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name @(
    'Test-InstallStatusStillActive', 'Measure-InstalledDeviceActivity'))))

  # 'now' ist fest, damit die Faelle nicht von der Uhr abhaengen.
  $script:now = [datetime]::Parse('2026-09-09T12:00:00Z').ToUniversalTime()

  function New-Status {
    param([string]$State = 'installed', [AllowNull()][string]$DaysAgo = $null, [switch]$NoDateProperty)
    if ($NoDateProperty) { return [pscustomobject]@{ installState = $State } }
    $sync = if ($null -eq $DaysAgo -or $DaysAgo -eq '') { '' } else { $script:now.AddDays(-[double]$DaysAgo).ToString('o') }
    [pscustomobject]@{ installState = $State; lastSyncDateTime = $sync }
  }
}

Describe 'Test-InstallStatusStillActive' {
  It 'zaehlt ein Geraet als aktiv, das innerhalb des Fensters synchronisiert hat' {
    Test-InstallStatusStillActive -Status (New-Status -DaysAgo 10) -Now $script:now -QuietDays 90 | Should -BeTrue
  }

  It 'zaehlt ein Geraet ausserhalb des Fensters als still' {
    # Der gemeldete Fall: letzter Kontakt vor 214 Tagen.
    Test-InstallStatusStillActive -Status (New-Status -DaysAgo 214) -Now $script:now -QuietDays 90 | Should -BeFalse
  }

  It 'zaehlt genau am Rand noch als aktiv' {
    Test-InstallStatusStillActive -Status (New-Status -DaysAgo 90) -Now $script:now -QuietDays 90 | Should -BeTrue
  }

  It 'zaehlt OHNE Fenster (0) jede Installation als aktiv - das Verhalten bis 0.18.1' {
    Test-InstallStatusStillActive -Status (New-Status -DaysAgo 999) -Now $script:now -QuietDays 0 | Should -BeTrue
    Test-InstallStatusStillActive -Status (New-Status -DaysAgo 999) -Now $script:now | Should -BeTrue
  }

  It 'zaehlt ein Geraet OHNE Datum als aktiv' {
    # Fail-safe in die vorsichtige Richtung. "Ich weiss nicht, wann das Geraet zuletzt da war" ist
    # keine Erlaubnis zu loeschen - genau die Regel, die auch beim Aufraeumen und beim Loeschen gilt.
    Test-InstallStatusStillActive -Status (New-Status -DaysAgo $null) -Now $script:now -QuietDays 30 | Should -BeTrue
    Test-InstallStatusStillActive -Status (New-Status -NoDateProperty) -Now $script:now -QuietDays 30 | Should -BeTrue
  }

  It 'zaehlt ein unlesbares Datum als aktiv' {
    $broken = [pscustomobject]@{ installState = 'installed'; lastSyncDateTime = 'gestern' }
    Test-InstallStatusStillActive -Status $broken -Now $script:now -QuietDays 30 | Should -BeTrue
  }

  It 'vertraegt einen leeren Zustand' {
    Test-InstallStatusStillActive -Status $null -Now $script:now -QuietDays 30 | Should -BeTrue
  }
}

Describe 'Measure-InstalledDeviceActivity' {
  It 'zaehlt nur "installiert", nicht jeden gemeldeten Zustand' {
    # Ein fehlgeschlagener oder ausstehender Zustand ist keine Installation und darf nichts
    # blockieren - genauso wie vorher.
    $statuses = @(
      (New-Status -State 'installed' -DaysAgo 5),
      (New-Status -State 'failed' -DaysAgo 1),
      (New-Status -State 'pendingInstall' -DaysAgo 1),
      (New-Status -State 'notInstalled' -DaysAgo 1)
    )
    $m = Measure-InstalledDeviceActivity -Statuses $statuses -Now $script:now -QuietDays 90
    $m.Installed | Should -Be 1
    $m.Active | Should -Be 1
  }

  It 'trennt aktive von stillen Installationen und nennt den juengsten Kontakt' {
    $statuses = @(
      (New-Status -DaysAgo 5),
      (New-Status -DaysAgo 200),
      (New-Status -DaysAgo 400)
    )
    $m = Measure-InstalledDeviceActivity -Statuses $statuses -Now $script:now -QuietDays 90
    $m.Installed | Should -Be 3
    $m.Active | Should -Be 1
    $m.Stale | Should -Be 2
    $m.NewestDaysAgo | Should -Be 5
  }

  It 'der gemeldete Fall: alle Installationen liegen auf stillen Geraeten' {
    $statuses = @((New-Status -DaysAgo 214), (New-Status -DaysAgo 300))
    $m = Measure-InstalledDeviceActivity -Statuses $statuses -Now $script:now -QuietDays 90
    $m.Installed | Should -Be 2
    $m.Active | Should -Be 0
    $m.NewestDaysAgo | Should -Be 214
  }

  It 'ein einziges AKTIVES Geraet blockiert weiterhin - auch neben zwanzig stillen' {
    # Genau der Grund, aus dem eine ANZAHL-Schwelle das schlechtere Kriterium waere.
    $statuses = @((New-Status -DaysAgo 3)) + (1..20 | ForEach-Object { New-Status -DaysAgo 500 })
    $m = Measure-InstalledDeviceActivity -Statuses $statuses -Now $script:now -QuietDays 90
    $m.Installed | Should -Be 21
    $m.Active | Should -Be 1
  }

  It 'zaehlt Installationen ohne Datum und meldet sie getrennt' {
    $statuses = @((New-Status -DaysAgo 500), (New-Status -DaysAgo $null))
    $m = Measure-InstalledDeviceActivity -Statuses $statuses -Now $script:now -QuietDays 90
    $m.Installed | Should -Be 2
    $m.Active | Should -Be 1      # die ohne Datum gilt als aktiv
    $m.WithoutDate | Should -Be 1
  }

  It 'meldet ohne Fenster alle als aktiv' {
    $statuses = @((New-Status -DaysAgo 500), (New-Status -DaysAgo 900))
    $m = Measure-InstalledDeviceActivity -Statuses $statuses -Now $script:now -QuietDays 0
    $m.Active | Should -Be 2
    $m.Stale | Should -Be 0
  }

  It 'vertraegt eine leere Liste' {
    $m = Measure-InstalledDeviceActivity -Statuses @() -Now $script:now -QuietDays 90
    $m.Installed | Should -Be 0
    $m.NewestDaysAgo | Should -BeNullOrEmpty
  }
}

Describe 'Verdrahtung: das Fenster gilt NUR von Hand' {
  BeforeAll {
    $script:engine = Get-SourcePartText -Part '50-UpdateEngine.ps1'
    $script:graph = Get-SourcePartText -Part '40-Graph.ps1'
  }

  It 'gibt beim automatischen Aufraeumen 0 mit' {
    # $Silent ist der automatische Lauf nach einem Update. Dort bleibt die strenge Regel: ohne Klick
    # und ohne Blick soll nichts geloescht werden, was Intune noch als installiert meldet.
    $script:engine | Should -Match '\$quietDays = if \(\$Silent\) \{ 0 \} else \{ \[int\]\$script:settings\.IgnoreDevicesQuietForDays \}'
    $script:engine | Should -Match '-IgnoreDevicesQuietForDays \$quietDays'
  }

  It 'sammelt mit Fenster ALLE Zustaende, statt beim ersten Treffer abzubrechen' {
    # Sonst faende die Abkuerzung genau ein stilles Geraet und blockierte damit, was das Fenster
    # gerade freigeben soll.
    $script:graph | Should -Match '\$collectAll = \(\$IgnoreDevicesQuietForDays -gt 0\)'
    $script:graph | Should -Match 'if \(\$collectAll\) \{ \[void\]\$collected\.Add\(\$status\); continue \}'
  }

  It 'behaelt die Abkuerzung, wenn kein Fenster gilt' {
    # Sie spart bei grossen Tenants echte Zeit, und ohne Fenster aendert sie am Ergebnis nichts.
    $fn = Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Get-AppInstallationProbe'
    $fn | Should -Match '\} elseif \(\$hasInstalledStatus\) \{'
  }

  It 'nennt beim Behalten das Alter des juengsten Kontakts' {
    # "behalten, weil noch installiert" ist ohne "letzter Kontakt vor 214 Tagen" keine Auskunft,
    # mit der jemand etwas entscheiden kann - genau daran ist die Frage entstanden.
    $script:engine | Should -Match 'CleanupKeptReasonNewestContact'
  }

  It 'begruendet eine Loeschung trotz gemeldeter Installationen im Protokoll' {
    $script:engine | Should -Match 'ALL of them are on devices that have not synced'
    $script:engine | Should -Match 'the software stays installed on those devices'
  }

  It 'hat die Vorgabe 0 - eine Einstellung, die Loeschungen freigibt, schaltet sich nicht selbst ein' {
    $settings = Get-SourcePartText -Part '10-Settings.ps1'
    $settings | Should -Match 'IgnoreDevicesQuietForDays = 0'
    $settings | Should -Match "-Name 'IgnoreDevicesQuietForDays' -Type Int -Default 0 -Minimum 0 -Maximum 3650"
  }

  It 'schreibt die Wirkung in den Einstellungs-Abdruck' {
    $settings = Get-SourcePartText -Part '10-Settings.ps1'
    $settings | Should -Match 'manual version cleanup'
    $settings | Should -Match 'every reported installation blocks a deletion'
  }

  It 'hat die neuen Texte in BEIDEN Sprachbloecken' {
    $strings = Get-SourcePartText -Part '15-Strings.ps1'
    foreach ($key in @('QuietDaysLabel', 'HintQuietDays', 'CleanupKeptReasonNewestContact')) {
      ([regex]::Matches($strings, ("(?m)^\s*{0}\s*=" -f [regex]::Escape($key)))).Count |
        Should -Be 2 -Because "$key muss einmal in EN und einmal in DE stehen"
    }
  }

  It 'legt das Eingabefeld GEMESSEN hinter seine Beschriftung' {
    # Ohne Location laege es auf x=0 mitten in der Beschriftung; die feste 236 der Zeile darueber
    # ist Altbestand und fuer diesen laengeren Text falsch.
    $rows = Get-SourcePartText -Part '85-Rows.ps1'
    $rows | Should -Match 'Get-ControlTextWidth -Control \$quietDaysLabel'
  }

  It 'uebernimmt den Wert beim Speichern, nicht beim Drehen' {
    $rows = Get-SourcePartText -Part '85-Rows.ps1'
    $rows | Should -Match '\$script:settings\.IgnoreDevicesQuietForDays = \[int\]\$quietDaysInput\.Value'
  }
}

Describe 'Leistungsnachweis: kein Zustand aus der vorigen Sitzung' {
  BeforeAll {
    $script:dialogs = Get-SourcePartText -Part '55-Dialogs.ps1'
    $script:rows = Get-SourcePartText -Part '85-Rows.ps1'
  }

  It 'stellt den Kopierknopf zurueck, wenn der Text neu erzeugt wird' {
    # Gemeldet am 09.09.2026: nach dem Wechsel zum naechsten Kunden stand dort weiter "Kopiert!" -
    # eine Aussage ueber einen Text, den es nicht mehr gibt.
    $fn = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Update-WorkRecordText'
    $fn | Should -Match "CopyButton\.Text = Get-UiString 'LeistungCopyButton'"
  }

  It 'erzeugt den Leistungsnachweis beim Tenant-Wechsel neu' {
    # Wer den Bereich offen hat, sah sonst weiter den Text des vorigen Kunden - der Bereich wird
    # nur beim BETRETEN nachgezogen.
    $fn = Get-SourceFunctionText -Part '85-Rows.ps1' -Name 'Clear-TenantViews'
    $fn | Should -Match 'Update-WorkRecordText -Force'
  }

  It 'benutzt dafuer kein Get-Command-Gatter' {
    # 55-Dialogs laedt vor 85-Rows, ein Vorwaertsbezug liegt also nicht vor - und ein Gatter wuerde
    # eine Umbenennung in ein stilles "wird uebersprungen" verwandeln. Dieselbe Regel wie fuer die
    # fuenf Cache-Leerer daneben.
    $fn = Get-SourceFunctionText -Part '85-Rows.ps1' -Name 'Clear-TenantViews'
    $fn | Should -Not -Match 'Get-Command Update-WorkRecordText'
  }
}

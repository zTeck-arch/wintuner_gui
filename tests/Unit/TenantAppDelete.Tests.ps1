# Apps aus "Alle Tenant-Apps" von Hand loeschen.
#
# Wunsch aus dem Betrieb (03.09.2026): einzelne Apps auswaehlen und loeschen. Die Auswahl ist
# ausdruecklich, die Loeschung ist unumkehrbar - und genau dazwischen liegt diese Regel.
#
# Zwei Klassen werden ausgelassen, und beide aus einem Grund, der schon fuer die Bereinigung gilt:
#   * GESCHUETZT - selbst paketierte Apps. Ein Klick darf nicht denselben Totalverlust anrichten,
#     den die Schutzliste bei einem ganzen Lauf verhindert. Wer eine geschuetzte App loeschen will,
#     hebt zuerst den Schutz auf - eine bewusste zweite Handlung.
#   * UNBEKANNT - Intune hat auf eine der Sonden nicht geantwortet. "Ich weiss es nicht" ist keine
#     Erlaubnis; dieselbe Regel wie beim Loeschen abgeloester Apps.
# In BENUTZUNG wird NICHT ausgelassen - das ist die Entscheidung des Benutzers -, aber es muss in
# der Rueckfrage stehen, sonst ist die Entscheidung keine.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name @(
    'Test-IsProtectedApp', 'Set-ProtectedAppPatterns'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '82-TenantApps.ps1' -Name 'Get-TenantAppDeletePlan')))

  function New-Candidate {
    param(
      [string]$Name,
      [string]$Version = '1.0',
      [string]$GraphId = '',
      [bool]$ProbeSucceeded = $true,
      [bool]$HasAssignments = $false,
      [bool]$HasInstallations = $false
    )
    if (-not $GraphId) { $GraphId = [guid]::NewGuid().ToString() }
    [pscustomobject]@{
      Name = $Name; CurrentVersion = $Version; GraphId = $GraphId
      ProbeSucceeded = $ProbeSucceeded; HasAssignments = $HasAssignments; HasInstallations = $HasInstallations
    }
  }
}

Describe 'Get-TenantAppDeletePlan' {

  It 'loescht eine unbenutzte, ungeschuetzte App' {
    $plan = Get-TenantAppDeletePlan -Apps @((New-Candidate -Name '7-Zip')) -ProtectedPatterns @()
    @($plan.Delete).Count | Should -Be 1
    @($plan.Excluded).Count | Should -Be 0
    @($plan.InUse).Count | Should -Be 0
  }

  # Der wichtigste Fall der ganzen Datei.
  It 'laesst eine geschuetzte App aus und nennt den Grund' {
    $plan = Get-TenantAppDeletePlan -Apps @((New-Candidate -Name 'TeamViewer Host')) -ProtectedPatterns @('TeamViewer*')
    @($plan.Delete).Count | Should -Be 0
    @($plan.Excluded).Count | Should -Be 1
    $plan.Excluded[0].Reason | Should -Be 'protected'
    $plan.Excluded[0].App.Name | Should -Be 'TeamViewer Host'
  }

  # Dieselbe Regel wie beim Loeschen abgeloester Apps: ein unbekannter Zustand erlaubt nichts.
  It 'laesst eine App aus, deren Zustand Intune nicht gemeldet hat' {
    $plan = Get-TenantAppDeletePlan -Apps @((New-Candidate -Name 'Zoom' -ProbeSucceeded $false)) -ProtectedPatterns @()
    @($plan.Delete).Count | Should -Be 0
    $plan.Excluded[0].Reason | Should -Be 'state unknown'
  }

  # Auch dann, wenn die Sonde "unbenutzt" GEMELDET haette - nicht geantwortet ist nicht unbenutzt.
  It 'traut einem unbekannten Zustand auch dann nicht, wenn er unbenutzt aussieht' {
    $plan = Get-TenantAppDeletePlan -Apps @(
      (New-Candidate -Name 'Zoom' -ProbeSucceeded $false -HasAssignments $false -HasInstallations $false)) -ProtectedPatterns @()
    @($plan.Delete).Count | Should -Be 0
  }

  It 'loescht eine benutzte App, fuehrt sie aber als Warnung' {
    $plan = Get-TenantAppDeletePlan -Apps @(
      (New-Candidate -Name 'Google Chrome' -HasInstallations $true),
      (New-Candidate -Name 'Notepad++' -HasAssignments $true),
      (New-Candidate -Name '7-Zip')) -ProtectedPatterns @()
    @($plan.Delete).Count | Should -Be 3 -Because 'die Auswahl ist ausdruecklich'
    @($plan.InUse).Count | Should -Be 2 -Because 'und die Rueckfrage muss sagen, welche in Benutzung sind'
    @($plan.InUse | ForEach-Object { $_.Name }) | Should -Contain 'Google Chrome'
    @($plan.InUse | ForEach-Object { $_.Name }) | Should -Contain 'Notepad++'
  }

  It 'geht die ganze Auswahl durch und mischt die Klassen richtig' {
    $plan = Get-TenantAppDeletePlan -Apps @(
      (New-Candidate -Name '7-Zip'),
      (New-Candidate -Name 'Splashtop Streamer'),
      (New-Candidate -Name 'Firefox' -ProbeSucceeded $false),
      (New-Candidate -Name 'VLC' -HasAssignments $true)) -ProtectedPatterns @('Splashtop*')
    @($plan.Delete | ForEach-Object { $_.Name }) | Should -Be @('7-Zip', 'VLC')
    @($plan.Excluded | ForEach-Object { $_.App.Name }) | Should -Be @('Splashtop Streamer', 'Firefox')
    @($plan.InUse | ForEach-Object { $_.Name }) | Should -Be @('VLC')
  }

  # Eine App ohne Graph-Id kann nicht geloescht werden, und ein leerer Aufruf darf nicht fliegen -
  # der Handler ruft das mitten in einer Auswahl.
  It 'ueberspringt Eintraege ohne Graph-Id und vertraegt eine leere Auswahl' {
    $ohneId = [pscustomobject]@{ Name = 'Kaputt'; CurrentVersion = '1'; GraphId = ''; ProbeSucceeded = $true }
    $plan = Get-TenantAppDeletePlan -Apps @($ohneId) -ProtectedPatterns @()
    @($plan.Delete).Count | Should -Be 0
    @($plan.Excluded).Count | Should -Be 0
    @((Get-TenantAppDeletePlan -Apps @() -ProtectedPatterns @()).Delete).Count | Should -Be 0
    @((Get-TenantAppDeletePlan -Apps $null -ProtectedPatterns $null).Delete).Count | Should -Be 0
  }

  # Die Schutzliste gilt hier mit denselben Mustern wie ueberall - nicht mit einer eigenen Lesart.
  It 'benutzt die Musterlogik der Schutzliste, nicht einen eigenen Namensvergleich' {
    $plan = Get-TenantAppDeletePlan -Apps @(
      (New-Candidate -Name 'Zoom Rooms'),
      (New-Candidate -Name 'Zoom Workplace')) -ProtectedPatterns @('Zoom Rooms')
    @($plan.Delete | ForEach-Object { $_.Name }) | Should -Be @('Zoom Workplace') -Because 'ohne Platzhalter trifft der Eintrag genau'
  }
}

Describe 'Verdrahtung im Quelltext' {

  BeforeAll {
    $script:part = Get-SourcePartText -Part '82-TenantApps.ps1'
    # Nur der Loeschhandler. Die ganze Datei zu pruefen war zu grob: `SuppressChangeConfirmations`
    # steht dort an anderer Stelle zu Recht, und der Fall wurde rot, ohne dass am Loeschen etwas
    # falsch war.
    $start = $script:part.IndexOf('$tenantDeleteButton.Add_Click({')
    if ($start -lt 0) { throw 'Loeschhandler nicht gefunden - umbenannt?' }
    $end = $script:part.IndexOf('$tenantHintLabel = New-Object', $start)
    if ($end -lt 0) { $end = $script:part.Length }
    $script:handler = $script:part.Substring($start, $end - $start)
  }

  It 'erlaubt Mehrfachauswahl in der Liste' {
    $script:part | Should -Match '\$tenantListView\.MultiSelect = \$true'
  }

  # Beide Sonden, wie bei jeder anderen Loeschung - sonst kann der Plan "unbekannt" nicht kennen.
  It 'fragt vor der Rueckfrage Zuweisungen UND Installationen ab' {
    $script:handler | Should -Match 'Get-AppAssignmentProbe'
    $script:handler | Should -Match 'Get-AppInstallationProbe'
  }

  # Eine Loeschung ist von hier aus nicht rueckholbar; "Rueckfragen abschalten" darf sie nicht
  # wegdruecken, und der Vorgabeknopf muss der harmlose sein.
  It 'fragt immer nach, mit Nein als Vorgabe' {
    $script:handler | Should -Match 'TenantAppDeleteConfirmDialog'
    # Nach dem ZUGRIFF fragen, nicht nach dem Wort: im Kommentar daneben steht es zu Recht, und
    # eine Regel, die den Kommentar trifft, prueft die Absicht statt des Codes.
    $script:handler | Should -Not -Match '\$script:settings\.SuppressChangeConfirmations'
    $script:handler | Should -Match 'MessageBoxDefaultButton\]::Button2'
  }

  # Derselbe Weg wie jede andere Loeschung: Geltungsbereich sichern, Abloesebeziehung abhaengen,
  # Leistungsnachweis - alles steckt in dieser einen Funktion.
  It 'loescht ueber den gemeinsamen Trichter, nicht direkt am Modul' {
    $script:handler | Should -Match 'Remove-AppWithUnlinkFallback'
    $script:handler | Should -Not -Match 'Remove-WtWin32App'
  }

  # Die Sichtbarkeit der Fortschrittsanzeige IST die Busy-Sperre (siehe PATTERNS).
  It 'gibt die Busy-Sperre wieder frei' {
    $idxShow = $script:part.IndexOf('Show-Progress -Total ([Math]::Max(1, $selected.Count))')
    $idxShow | Should -BeGreaterThan 0
    $tail = $script:part.Substring($idxShow)
    $tail | Should -Match 'finally\s*\{[\s\S]{0,120}?Hide-Progress'
  }

  It 'raeumt den Inventar-Zwischenspeicher nach dem Loeschen auf' {
    $script:handler | Should -Match 'Clear-Win32AppsCache'
  }
}
